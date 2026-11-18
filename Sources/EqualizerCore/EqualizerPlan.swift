import Foundation

package struct BiquadCoefficients: Equatable, Sendable, BitwiseCopyable {
    package let b0, b1, b2, a1, a2: Double

    static let identity = Self(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

extension BiquadCoefficients {
    private init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    // RBJ Audio EQ Cookbook, using the Q form of alpha for shelves.
    fileprivate static func design(_ band: Band, rate: Double) -> [Self] {
        let w = 2 * Double.pi * (min(band.frequency / rate, 0.49))
        let c = cos(w)
        if let slope = band.slope {
            let order = slope / 6
            let low = band.kind == .lowPass
            var sections = [Self]()
            if !order.isMultiple(of: 2) {
                let k = tan(w / 2)
                sections.append(Self(low ? k : 1, low ? k : -1, 0, 1 + k, k - 1, 0))
            }
            for i in 0..<(order / 2) {
                let alpha = sin(w) * sin(Double.pi * Double(2 * i + 1) / Double(2 * order))
                let b = low ? pow(sin(w / 2), 2) : pow(cos(w / 2), 2)
                sections.append(Self(b, low ? 2 * b : -2 * b, b, 1 + alpha, -2 * c, 1 - alpha))
            }
            return sections
        }
        let alpha = sin(w) / (2 * band.q!)
        let a = pow(10, band.gainDB / 40)
        switch band.kind {
        case .peakDip:
            return [Self(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)]
        case .lowShelf, .highShelf:
            let sign = band.kind == .lowShelf ? 1.0 : -1.0
            let sum = a + 1, diff = a - 1
            let n = sum - sign * diff * c, d = sum + sign * diff * c
            let s = 2 * sqrt(a) * alpha
            return [Self(a * (n + s), 2 * a * (sign * diff - sum * c), a * (n - s),
                         d + s, -2 * (sign * diff + sum * c), d - s)]
        case .bandPass:
            return [Self(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha)]
        case .bandStop:
            return [Self(1, -2 * c, 1, 1 + alpha, -2 * c, 1 - alpha)]
        case .lowPass, .highPass:
            preconditionFailure("Pass filters have a slope")
        }
    }

    // ITU-R BS.1770-5 Annex 1, tables 1 and 2. Evaluate the reference at physical Hz.
    fileprivate static func kWeightPower(at frequency: Double) -> Double {
        let shelf = Self(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                         a1: -1.69065929318241, a2: 0.73248077421585)
        let highPass = Self(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
        let angle = 2 * Double.pi * frequency / 48_000
        let c = cos(angle), s = sin(angle)
        return pow(10, (shelf.magnitudeDB(cosine: c, sine: s) + highPass.magnitudeDB(cosine: c, sine: s)) / 10)
    }

    fileprivate func magnitudeDB(cosine: Double, sine: Double) -> Double {
        // Rotate H by one sample: z*b0 + b1 + z^-1*b2.
        let n = hypot((b0 + b2) * cosine + b1, (b0 - b2) * sine)
        let d = hypot((1 + a2) * cosine + a1, (1 - a2) * sine)
        return 20 * log10(n / d)
    }
}

package struct BiquadSections: Sendable, BitwiseCopyable {
    package static let capacity = 24
    private typealias C = BiquadCoefficients
    private var storage = (
        C.identity, C.identity, C.identity, C.identity, C.identity, C.identity,
        C.identity, C.identity, C.identity, C.identity, C.identity, C.identity,
        C.identity, C.identity, C.identity, C.identity, C.identity, C.identity,
        C.identity, C.identity, C.identity, C.identity, C.identity, C.identity
    )
    package private(set) var count = 0

    package subscript(index: Int) -> BiquadCoefficients {
        precondition(index >= 0 && index < count)
        return withUnsafePointer(to: storage) {
            $0.withMemoryRebound(to: BiquadCoefficients.self, capacity: Self.capacity) { $0[index] }
        }
    }

    @_noLocks
    func copy(to destination: UnsafeMutablePointer<BiquadCoefficients>) {
        withUnsafeBytes(of: storage) { bytes in
            UnsafeMutableRawPointer(destination).copyMemory(from: bytes.baseAddress!,
                                                            byteCount: count * MemoryLayout<BiquadCoefficients>.stride)
        }
    }

    fileprivate mutating func append(_ section: BiquadCoefficients) {
        precondition(count < Self.capacity)
        withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: BiquadCoefficients.self, capacity: Self.capacity) { $0[count] = section }
        }
        count += 1
    }
}

package struct EqualizerPlan: Sendable, BitwiseCopyable {
    package enum Invalid: Error { case sampleRate, preamp, coefficients(band: Int), compareGain }

    package let sections: BiquadSections
    package private(set) var headroomDB = 0.0
    package private(set) var preampGain: Double
    package let sampleRate: Double
    package private(set) var compareGain: Double

    /// Playback applies headroom to the compiled response, preserving the stored profile.
    package static func playback(_ profile: ParametricEQ, sampleRate: Double) throws -> Self {
        var plan = try Self(profile, sampleRate: sampleRate)
        let upper = sampleRate / 2
        let lower = min(20, upper)
        var peak = -Double.infinity
        func measure(_ hz: Double) throws -> Double {
            let db = plan.magnitudeDB(at: hz)
            guard db.isFinite || db == -.infinity else { throw Invalid.preamp }
            peak = max(peak, db)
            return db
        }
        if plan.sections.count == 0 {
            peak = profile.gainDB
        } else {
            let bins = 4096
            var frequencies = (0...bins).map { lower * pow(upper / lower, Double($0) / Double(bins)) }
            frequencies[bins] = upper
            for band in profile.bands {
                let center = min(band.frequency, sampleRate * 0.49)
                if center >= lower { frequencies.append(center) }
                if (lower...upper).contains(band.frequency) { frequencies.append(band.frequency) }
            }
            frequencies.sort()
            let response = try frequencies.map(measure)
            for i in 1..<(response.count - 1) where response[i] >= response[i-1] && response[i] > response[i+1] {
                var lo = frequencies[i-1], hi = frequencies[i+1]
                for _ in 0..<24 {
                    let third = (hi - lo) / 3
                    if try measure(lo + third) < measure(hi - third) { lo += third } else { hi -= third }
                }
            }
        }
        if peak > 0 {
            plan.headroomDB = peak
            let scale = pow(10, -peak / 20)
            plan.preampGain *= scale
            plan.compareGain *= scale
        }
        return plan
    }

    package static func thumbnail(_ profile: ParametricEQ, sampleRate: Double = 48_000) throws -> Self {
        try Self(profile, sampleRate: sampleRate)
    }

    package init(_ profile: ParametricEQ, sampleRate: Double) throws {
        var dropped = [Int]()
        try self.init(profile, sampleRate: sampleRate, droppedBandIndices: &dropped)
    }

    package init(_ profile: ParametricEQ, sampleRate: Double, droppedBandIndices: inout [Int]) throws {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate < Double(Int.max) else { throw Invalid.sampleRate }
        self.sampleRate = sampleRate
        preampGain = pow(10, profile.gainDB / 20)
        guard preampGain.isFinite, preampGain > 0 else { throw Invalid.preamp }
        var sections = BiquadSections()
        var dropped = [Int]()
        var full = false
        for (index, band) in profile.bands.enumerated() {
            let aboveNyquist = band.frequency >= sampleRate / 2
            guard !full, !(aboveNyquist && band.kind == .lowPass) else {
                dropped.append(index)
                continue
            }
            let design: [BiquadCoefficients]
            if aboveNyquist && band.kind == .lowShelf {
                design = [.init(b0: pow(10, band.gainDB / 20), b1: 0, b2: 0, a1: 0, a2: 0)]
            } else {
                design = BiquadCoefficients.design(band, rate: sampleRate)
            }
            guard sections.count + design.count <= BiquadSections.capacity else {
                full = true
                dropped.append(index)
                continue
            }
            for k in design {
                guard k.b0.isFinite, k.b1.isFinite, k.b2.isFinite, abs(k.a2) < 1, abs(k.a1) < 1 + k.a2
                else { throw Invalid.coefficients(band: index) }
                sections.append(k)
            }
        }
        self.sections = sections
        compareGain = preampGain
        if sections.count > 0 {
            let upper = min(20_000, sampleRate / 2)
            let lower = min(20, upper / 2)
            let bins = 256
            var power = 0.0, weightSum = 0.0
            for bin in 0..<bins {
                let frequency = lower * pow(upper / lower, (Double(bin) + 0.5) / Double(bins))
                let weight = BiquadCoefficients.kWeightPower(at: frequency)
                weightSum += weight
                power += weight * pow(10, magnitudeDB(at: frequency) / 10)
            }
            compareGain = sqrt(power / weightSum)
            guard compareGain.isFinite else { throw Invalid.compareGain }
        }
        droppedBandIndices = dropped
    }

    @_noLocks
    func matches(_ other: borrowing Self) -> Bool {
        guard sampleRate == other.sampleRate, preampGain == other.preampGain,
              compareGain == other.compareGain, sections.count == other.sections.count else { return false }
        for i in 0..<sections.count where sections[i] != other.sections[i] { return false }
        return true
    }

    package func magnitudeDB(at frequencies: [Double]) -> [Double] {
        frequencies.map { magnitudeDB(at: $0) }
    }

    /// Returns negative infinity at a filter zero and NaN outside DC through Nyquist.
    package func magnitudeDB(at frequency: Double) -> Double {
        guard frequency >= 0, frequency <= sampleRate / 2 else { return .nan }
        let w = 2 * Double.pi * (frequency / sampleRate)
        let c = cos(w), s = frequency == sampleRate / 2 ? 0 : sin(w)
        var db = 20 * log10(preampGain)
        for i in 0..<sections.count { db += sections[i].magnitudeDB(cosine: c, sine: s) }
        return db
    }
}
