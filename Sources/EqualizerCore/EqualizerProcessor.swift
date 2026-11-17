private struct History {
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    mutating func filter(_ x: Double, _ k: BiquadCoefficients) -> Double {
        let y = k.b0 * x + k.b1 * x1 + k.b2 * x2 - k.a1 * y1 - k.a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = abs(y) < Double(Float.leastNormalMagnitude) ? 0 : y
        return y1
    }
}

private struct Chain: ~Copyable {
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let histories: UnsafeMutablePointer<History>
    private let channelStride = BiquadSections.capacity
    private let historyCount: Int
    private var count = 0
    private var gain = 1.0

    init(channels: Int) {
        historyCount = channels * BiquadSections.capacity
        coefficients = .allocate(capacity: BiquadSections.capacity)
        coefficients.initialize(repeating: .identity, count: BiquadSections.capacity)
        histories = .allocate(capacity: historyCount)
        histories.initialize(repeating: History(), count: historyCount)
    }

    deinit {
        histories.deinitialize(count: historyCount)
        histories.deallocate()
        coefficients.deinitialize(count: BiquadSections.capacity)
        coefficients.deallocate()
    }

    mutating func load(_ plan: borrowing EqualizerPlan, mode: EqualizerProcessor.Mode) {
        count = mode == .processing ? plan.sections.count : 0
        switch mode {
        case .processing: gain = plan.preampGain
        case .compare: gain = plan.compareGain
        case .off: gain = 1
        }
        plan.sections.copy(to: coefficients)
        histories.update(repeating: History(), count: historyCount)
    }

    func reset(channel: Int) {
        (histories + channel * channelStride).update(repeating: History(), count: count)
    }

    func filter(_ input: Double, channel: Int) -> Double {
        let state = histories + channel * channelStride
        var x = input * gain
        for i in 0..<count { x = state[i].filter(x, coefficients[i]) }
        return x
    }
}

package struct EqualizerProcessor: ~Copyable {
    package enum Mode: Sendable { case processing, compare, off }

    private enum Buffer {
        case interleaved(UnsafeMutablePointer<Float>)
        case planar(UnsafePointer<UnsafeMutablePointer<Float>>)

        func sample(frame: Int, channel: Int, channels: Int) -> UnsafeMutablePointer<Float> {
            switch self {
            case .interleaved(let p): return p + frame * channels + channel
            case .planar(let planes): return planes[channel] + frame
            }
        }
    }

    private struct Update {
        let plan: EqualizerPlan
        let mode: Mode
    }

    package let channels: Int
    package let maximumFrames: Int
    private let chains: UnsafeMutablePointer<Chain>
    private var active = 0
    private var pending: Update?
    private var sampleRate: Double
    private var fadeLength = 0
    private var fadePosition = 0
    private let recovery: UnsafeMutablePointer<Int>
    private var recoveryLength: Int

    package init(plan: EqualizerPlan, channels: Int, maximumFrames: Int, mode: Mode = .processing) {
        precondition(channels > 0 && maximumFrames > 0)
        self.channels = channels
        self.maximumFrames = maximumFrames
        chains = .allocate(capacity: 2)
        chains.initialize(to: Chain(channels: channels))
        (chains + 1).initialize(to: Chain(channels: channels))
        sampleRate = plan.sampleRate
        recoveryLength = max(1, Int(sampleRate * 0.005))
        recovery = .allocate(capacity: channels)
        recovery.initialize(repeating: 0, count: channels)
        chains[active].load(plan, mode: mode)
    }

    deinit {
        chains.deinitialize(count: 2)
        chains.deallocate()
        recovery.deinitialize(count: channels)
        recovery.deallocate()
    }

    /// The IO thread calls this between buffers with exclusive access to the processor.
    /// The publisher compiles off-thread and protects its pending plan. After a successful
    /// try-lock the IO thread copies that value, unlocks, then calls update. Only that
    /// copy must live through this call. The processor owns everything needed afterwards.
    @_noLocks
    package mutating func update(to plan: borrowing EqualizerPlan, mode: Mode = .processing) {
        if plan.sampleRate != sampleRate {
            sampleRate = plan.sampleRate
            recoveryLength = max(1, Int(sampleRate * 0.005))
            recovery.update(repeating: recoveryLength, count: channels)
            chains[active].load(plan, mode: mode)
            fadeLength = 0
            pending = nil
        } else if fadeLength > 0 {
            pending = Update(plan: copy plan, mode: mode)
        } else {
            chains[1 - active].load(plan, mode: mode)
            fadeLength = max(1, Int(sampleRate * 0.030))
            fadePosition = 0
        }
    }

    @_noLocks
    @discardableResult
    package mutating func process(interleaved samples: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        process(.interleaved(samples), frames: frames)
    }

    @_noLocks
    @discardableResult
    package mutating func process(planar planes: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) -> Bool {
        process(.planar(planes), frames: frames)
    }

    private mutating func process(_ buffer: Buffer, frames: Int) -> Bool {
        precondition(frames >= 0)
        var healthy = true
        var offset = 0
        while offset < frames {
            var length = min(maximumFrames, frames - offset)
            if fadeLength > 0 { length = min(length, fadeLength - fadePosition) }
            for frame in offset..<(offset + length) {
                var mix = 0.0
                if fadeLength > 0 {
                    fadePosition += 1
                    let warmup = fadeLength / 3
                    let t = Double(max(0, fadePosition - warmup)) / Double(fadeLength - warmup)
                    // Quintic smoothstep has zero slope and curvature at both endpoints.
                    mix = t * t * t * (10 + t * (6 * t - 15))
                }
                for channel in 0..<channels {
                    let p = buffer.sample(frame: frame, channel: channel, channels: channels)
                    let input = Double(p.pointee)
                    let x = input.isFinite ? input : 0
                    var y = chains[active].filter(x, channel: channel)
                    if fadeLength > 0 {
                        y = (1 - mix) * y + mix * chains[1 - active].filter(x, channel: channel)
                    }
                    if !input.isFinite || !Float(y).isFinite {
                        chains[active].reset(channel: channel)
                        chains[1 - active].reset(channel: channel)
                        recovery[channel] = recoveryLength
                        p.pointee = 0
                        healthy = false
                    } else if recovery[channel] > 0 {
                        recovery[channel] -= 1
                        p.pointee = Float(y * Double(recoveryLength - recovery[channel]) / Double(recoveryLength))
                    } else {
                        p.pointee = Float(y)
                    }
                }
            }
            offset += length
            if fadeLength > 0 && fadePosition == fadeLength {
                active = 1 - active
                fadeLength = 0
                if let next = pending {
                    pending = nil
                    update(to: next.plan, mode: next.mode)
                }
            }
        }
        return healthy
    }
}
