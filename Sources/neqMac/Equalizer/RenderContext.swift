import CoreAudio
import EqualizerCore
import EqualizerIO

private struct RenderBank: ~Copyable {
    static var chunk: UInt32 { 128 }
    var processor: EqualizerProcessor
    let scratch: UnsafeMutablePointer<Float>

    init(plan: EqualizerPlan, channels: Int) {
        processor = EqualizerProcessor(plan: plan, channels: channels)
        scratch = .allocate(capacity: channels * Int(Self.chunk))
    }
    deinit { scratch.deallocate() }
}

private struct PlanChange {
    let plan: EqualizerPlan
    let mode: EqualizerProcessor.Mode
    let firstInput: UInt32
}

struct RenderContext: ~Copyable {
    private var lock = os_unfair_lock()
    private var pending: PlanChange?
    private var replacement: UnsafeMutablePointer<RenderBank>?
    private var retired: UnsafeMutablePointer<RenderBank>?
    private var active: UnsafeMutablePointer<RenderBank>
    private var configuredChannels: Int
    private var firstInput: UInt32
    let meter = EQMeterCreate()!

    init(plan: EqualizerPlan, channels: Int, firstInput: UInt32) {
        configuredChannels = channels
        self.firstInput = firstInput
        active = .allocate(capacity: 1)
        active.initialize(to: RenderBank(plan: plan, channels: channels))
    }

    deinit {
        for bank in [active, replacement, retired].compactMap({ $0 }) {
            bank.deinitialize(count: 1)
            bank.deallocate()
        }
        EQMeterFree(meter)
    }

    // Use field pointers so publisher and callback never open overlapping Swift accesses to self.
    static func publish(_ p: UnsafeMutablePointer<Self>, plan: EqualizerPlan, channels: Int, firstInput: UInt32) {
        os_unfair_lock_lock(&p.pointee.lock)
        defer { os_unfair_lock_unlock(&p.pointee.lock) }
        if let old = p.pointee.retired {
            old.deinitialize(count: 1)
            old.deallocate()
            p.pointee.retired = nil
        }
        if channels != p.pointee.configuredChannels {
            if let unused = p.pointee.replacement {
                unused.deinitialize(count: 1)
                unused.deallocate()
            }
            let bank = UnsafeMutablePointer<RenderBank>.allocate(capacity: 1)
            bank.initialize(to: RenderBank(plan: plan, channels: channels))
            p.pointee.replacement = bank
            p.pointee.configuredChannels = channels
        }
        p.pointee.pending = PlanChange(plan: plan, mode: .processing, firstInput: firstInput)
    }

    @_optimize(speed)
    static func render(_ p: UnsafeMutablePointer<Self>, input: UnsafePointer<AudioBufferList>,
                       output: UnsafeMutablePointer<AudioBufferList>) {
        if os_unfair_lock_trylock(&p.pointee.lock) {
            let change = p.pointee.pending
            p.pointee.pending = nil
            if let next = p.pointee.replacement {
                p.pointee.retired = p.pointee.active
                p.pointee.active = next
                p.pointee.replacement = nil
            }
            os_unfair_lock_unlock(&p.pointee.lock)
            if let change {
                p.pointee.firstInput = change.firstInput
                p.pointee.active.pointee.processor.update(to: change.plan, mode: change.mode)
            }
        }
        let bank = p.pointee.active
        let healthy = EQRender(input, output, p.pointee.firstInput, UInt32(truncatingIfNeeded: bank.pointee.processor.channels),
                               bank.pointee.scratch, RenderBank.chunk, bank) { pointer, samples, frames in
            guard let pointer, let samples else { return false }
            return pointer.assumingMemoryBound(to: RenderBank.self).pointee.processor.process(interleaved: samples, frames: frames)
        }
        EQDidRender(p.pointee.meter, healthy)
    }
}
