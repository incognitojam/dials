import EqualizerCore
import Foundation
import XCTest

final class ProcessorTests: XCTestCase {
    private func render(_ samples: [Float], with processor: inout EqualizerProcessor, block: Int = 256) -> [Float] {
        var output = samples
        output.withUnsafeMutableBufferPointer { bp in
            for offset in stride(from: 0, to: samples.count, by: block) {
                XCTAssertTrue(processor.process(interleaved: bp.baseAddress! + offset, frames: min(block, bp.count - offset)))
            }
        }
        return output
    }

    func testMeasuredSineGain() throws {
        let cases: [(Double, Double, Band.Kind, Double, Double)] = [
            (192000, 20, .peakDip, 20, 2), (192000, 8.5, .lowShelf, 10, 0.15),
            (96000, 20, .lowShelf, 5, 0.7), (48000, 20000, .peakDip, 20000, 12),
            (44100, 20000, .highShelf, 18000, 12), (44100, 6000, .highShelf, 9000, 1),
            (48000, 8000, .bandPass, 5000, 3), (48000, 8000, .bandStop, 6000, 1),
            (48000, 2000, .lowPass, 4000, 1), (48000, 2000, .highPass, 1000, 1)
        ]
        for (rate, f, kind, tone, q) in cases {
            let p = try plan([Band(kind, frequency: f, gainDB: 6, q: q)], gain: -3, rate: rate)
            var processor = EqualizerProcessor(plan: p, channels: 1)
            let n = Int(rate)
            let input = (0..<(2 * n)).map { Float(0.2 * sin(2 * .pi * tone * Double($0) / rate)) }
            let output = render(input, with: &processor)
            func power(_ data: [Float]) -> Double {
                data.suffix(n).reduce(0) { $0 + Double($1) * Double($1) }
            }
            let measured = 10 * log10(power(output) / power(input))
            XCTAssertEqual(measured, p.magnitudeDB(at: tone), accuracy: 0.01)
        }
    }

    func testExtremePolesAndImpulseRemainFinite() throws {
        for rate in [44100.0, 48000, 96000, 192000] {
            for f in [8.5, 20000] {
                for q in [0.15, 12] {
                    for kind: Band.Kind in [.peakDip, .lowShelf, .highShelf, .lowPass, .highPass, .bandPass, .bandStop] {
                        let p = try plan([Band(kind, frequency: f, gainDB: 9, q: q)], rate: rate)
                        let k = p.sections[0]
                        XCTAssertLessThan(abs(k.a2), 1)
                        XCTAssertLessThan(abs(k.a1), 1 + k.a2)
                        var processor = EqualizerProcessor(plan: p, channels: 1)
                        var impulse = [Float](repeating: 0, count: 8192)
                        impulse[0] = 1
                        let out = render(impulse, with: &processor)
                        XCTAssertTrue(out.allSatisfy { $0.isFinite && abs($0) < 16 })
                    }
                }
            }
        }
    }

    func testProfileCrossfadeEnvelopeAndResidual() throws {
        let a = try [Band(.lowShelf, frequency: 260, gainDB: 8, q: 0.8),
                     Band(.peakDip, frequency: 2400, gainDB: -11, q: 3),
                     Band(.highShelf, frequency: 7300, gainDB: 4, q: 1)]
        let b = try [Band(.peakDip, frequency: 9200, gainDB: 7, q: 5),
                     Band(.highShelf, frequency: 1300, gainDB: -7, q: 1.3),
                     Band(.lowShelf, frequency: 160, gainDB: -5, q: 0.65)]
        let first = try plan(a, gain: -4)
        let tone = 2500.0
        let omega = 2 * Double.pi * tone / 48000
        let cycle = (0..<4800).map { Float(0.25 * sin(omega * Double($0) + 0.9)) }
        let reordered = try [Band(.peakDip, frequency: 2650, gainDB: 3, q: 2)] + a.reversed()
        let unrelated = try plan(b, gain: -5)
        let inserted = try plan(reordered, gain: -5)
        let switches: [(EqualizerPlan, EqualizerProcessor.Mode, EqualizerPlan, EqualizerProcessor.Mode)] = [
            (first, .processing, unrelated, .processing), (first, .processing, inserted, .processing),
            (first, .processing, first, .compare), (first, .compare, first, .processing)
        ]
        for (old, oldMode, next, newMode) in switches {
            var switcher = EqualizerProcessor(plan: old, channels: 1, mode: oldMode)
            var reference = EqualizerProcessor(plan: next, channels: 1, mode: newMode)
            _ = render(cycle, with: &switcher)
            let before = render(cycle, with: &switcher)
            _ = render(cycle, with: &reference)
            let after = render(cycle, with: &reference)
            switcher.update(to: next, mode: newMode)
            let transition = render(cycle, with: &switcher)
            XCTAssertEqual(transition.suffix(256), after.suffix(256))
            var excess = 0.0
            var residual = [Double](repeating: 0, count: transition.count)
            var y1 = Double(before.last!), y2 = Double(before[before.count - 2])
            for i in transition.indices {
                let y = Double(transition[i])
                let low = Double(min(before[i], after[i])), high = Double(max(before[i], after[i]))
                excess = max(excess, low - y, y - high)
                residual[i] = (y - 2 * cos(omega) * y1 + y2) / (2 + 2 * cos(omega))
                y2 = y1
                y1 = y
            }
            XCTAssertLessThan(excess, 0.0001)
            // Windowed-sinc high-pass at 8 kHz, after the unity-at-Nyquist tone notch.
            let taps = (-31...31).map { n -> Double in
                let window = 0.5 + 0.5 * cos(.pi * Double(n) / 31)
                if n == 0 { return 1 - 1.0 / 3 }
                return -window * sin(.pi * Double(n) / 3) / (.pi * Double(n))
            }
            var peak = 0.0
            for i in residual.indices {
                var high = 0.0
                for j in 0...min(i, taps.count - 1) { high += taps[j] * residual[i - j] }
                peak = max(peak, abs(high))
            }
            XCTAssertLessThan(20 * log10(peak), -95)
        }
    }

    func testLatestPendingUpdateDuringAudibleFade() throws {
        let a = try plan([], gain: -12)
        let b = try plan([], gain: -6)
        let skipped = try plan([], gain: 9)
        let c = try plan([], gain: -3)
        var processor = EqualizerProcessor(plan: a, channels: 1)
        processor.update(to: b)
        _ = render(Array(repeating: 1, count: 600), with: &processor)
        processor.update(to: skipped)
        processor.update(to: c)
        let audio = render(Array(repeating: 1, count: 3500), with: &processor, block: 3500)
        XCTAssertEqual(audio[839], Float(b.preampGain))
        XCTAssertEqual(audio[1799], Float((b.preampGain + c.preampGain) / 2), accuracy: 1e-7)
        XCTAssertEqual(audio[2279], Float(c.preampGain))
        XCTAssertEqual(audio.last, Float(c.preampGain))
        XCTAssertLessThanOrEqual(audio.max()!, Float(c.preampGain))
    }

    func testPlanarAndInterleavedUpdateAllChannelsTogether() throws {
        let a = try plan([Band(.peakDip, frequency: 830, gainDB: 7, q: 2)])
        let b = try plan([Band(.lowPass, frequency: 2300, slope: 24)], gain: -4)
        let frames = 3583
        for channels in [1, 2, 6] {
            var p = EqualizerProcessor(plan: a, channels: channels)
            var q = EqualizerProcessor(plan: a, channels: channels)
            var input = (0..<(frames * channels)).map { Float(sin(Double($0) * 0.037)) }
            let original = input
            let planes = (0..<channels).map { channel -> UnsafeMutablePointer<Float> in
                let ptr = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                for i in 0..<frames { (ptr + i).initialize(to: original[i * channels + channel]) }
                return ptr
            }
            defer { for plane in planes { plane.deinitialize(count: frames); plane.deallocate() } }
            p.update(to: b)
            q.update(to: b)
            input.withUnsafeMutableBufferPointer { XCTAssertTrue(p.process(interleaved: $0.baseAddress!, frames: frames)) }
            planes.withUnsafeBufferPointer { XCTAssertTrue(q.process(planar: $0.baseAddress!, frames: frames)) }
            for channel in 0..<channels {
                let mono = stride(from: channel, to: input.count, by: channels).map { original[$0] }
                var independent = EqualizerProcessor(plan: a, channels: 1)
                independent.update(to: b)
                let expected = render(mono, with: &independent)
                XCTAssertEqual(Array(UnsafeBufferPointer(start: planes[channel], count: frames)), expected)
                XCTAssertEqual(stride(from: channel, to: input.count, by: channels).map { input[$0] }, expected)
            }
        }
    }

    func testLevelMatchedCompareOnEqualEnergyPerOctaveSignal() throws {
        let p = try plan([Band(.lowShelf, frequency: 500, gainDB: 10, q: 0.7),
                          Band(.peakDip, frequency: 3400, gainDB: -5, q: 2)], gain: -8)
        var input = [Float](repeating: 0, count: 48000)
        for i in 0..<64 {
            let f = (20 * pow(1000, (Double(i) + 0.5) / 64)).rounded()
            for n in input.indices {
                input[n] += Float(0.004 * sin(2 * .pi * f * Double(n) / 48000 + Double(i)))
            }
        }
        var processor = EqualizerProcessor(plan: p, channels: 1)
        _ = render(input, with: &processor)
        let corrected = render(input, with: &processor)
        processor.update(to: p, mode: .compare)
        _ = render(input, with: &processor)
        let compare = render(input, with: &processor)
        XCTAssertEqual(compare, input.map { Float(Double($0) * p.compareGain) })
        func power(_ samples: [Float]) -> Double {
            func filter(_ input: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
                var z1 = 0.0, z2 = 0.0
                return input.map { x in
                    let y = b[0] * x + z1
                    z1 = b[1] * x - a[0] * y + z2
                    z2 = b[2] * x - a[1] * y
                    return y
                }
            }
            let shelf = filter(samples.map(Double.init), [1.53512485958697, -2.69169618940638, 1.19839281085285],
                               [-1.69065929318241, 0.73248077421585])
            let weighted = filter(shelf, [1, -2, 1], [-1.99004745483398, 0.99007225036621])
            return weighted.reduce(0) { $0 + $1 * $1 }
        }
        XCTAssertEqual(10 * log10(power(compare) / power(corrected)), 0, accuracy: 0.05)
        processor.update(to: p, mode: .processing)
        _ = render(input, with: &processor)
        XCTAssertEqual(render(input, with: &processor), corrected)
        processor.update(to: p, mode: .off)
        XCTAssertEqual(render(input, with: &processor).suffix(4000), input.suffix(4000))
    }

    func testFaultIsolationAndFiveMillisecondRecovery() throws {
        let p = try plan([], gain: 6)
        for fault: Float in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            var processor = EqualizerProcessor(plan: p, channels: 2)
            var audio = [Float](repeating: 0.25, count: 600)
            audio[18] = fault
            audio.withUnsafeMutableBufferPointer {
                XCTAssertFalse(processor.process(interleaved: $0.baseAddress!, frames: 300))
            }
            let steady = Float(0.25 * p.preampGain)
            XCTAssertEqual(audio[18], 0)
            XCTAssertEqual(audio[20], steady / 240, accuracy: 1e-7)
            XCTAssertEqual(audio[258], steady / 2, accuracy: 1e-7)
            XCTAssertEqual(audio[498], steady)
            XCTAssertTrue(stride(from: 1, to: 600, by: 2).allSatisfy { audio[$0] == steady })
        }
    }

    func testFaultDiscardsRingingState() throws {
        let p = try plan([Band(.lowPass, frequency: 850, slope: 24)])
        var processor = EqualizerProcessor(plan: p, channels: 1)
        _ = render(Array(repeating: 0.5, count: 4000), with: &processor)
        var samples = [Float.nan] + Array(repeating: Float(0.25), count: 1000)
        samples.withUnsafeMutableBufferPointer {
            XCTAssertFalse(processor.process(interleaved: $0.baseAddress!, frames: $0.count))
        }
        var fresh = EqualizerProcessor(plan: p, channels: 1)
        let reference = render(Array(repeating: 0.25, count: 1000), with: &fresh)
        XCTAssertEqual(samples[0], 0)
        for i in reference.indices {
            XCTAssertEqual(samples[i + 1], reference[i] * Float(min(i + 1, 240)) / 240, accuracy: 5e-8)
        }
    }

    func testFlowingRateChangeStaysBetweenEndpoints() throws {
        let a = try plan([Band(.peakDip, frequency: 600, gainDB: 5, q: 1)])
        let b = try plan([Band(.peakDip, frequency: 1800, gainDB: -6, q: 2)], gain: -3, rate: 96000)
        var p = EqualizerProcessor(plan: a, channels: 1)
        var old = EqualizerProcessor(plan: a, channels: 1)
        var new = EqualizerProcessor(plan: b, channels: 1)
        let first = (0..<4800).map { Float(0.5 * cos(2 * .pi * Double($0) / 480)) }
        let next = (0..<9600).map { Float(0.5 * cos(2 * .pi * Double($0) / 960)) }
        _ = render(first, with: &p)
        _ = render(first, with: &old)
        _ = render(next, with: &new)
        p.update(to: b)
        let audio = render(next, with: &p)
        let lo = render(next, with: &old), hi = render(next, with: &new)
        XCTAssertEqual(audio[0], lo[0])
        for i in audio.indices {
            XCTAssertGreaterThanOrEqual(audio[i], min(lo[i], hi[i]) - 1e-6)
            XCTAssertLessThanOrEqual(audio[i], max(lo[i], hi[i]) + 1e-6)
        }
        XCTAssertEqual(audio.suffix(512), hi.suffix(512))
    }

    func testRateChangeSupersedesQueuedPlanWithoutInterruptingAudibleFade() throws {
        let a = try plan([], gain: -9), b = try plan([], gain: -6)
        let obsolete = try plan([], gain: 12), next = try plan([], gain: -3, rate: 96000)
        var p = EqualizerProcessor(plan: a, channels: 1)
        var reference = EqualizerProcessor(plan: a, channels: 1)
        p.update(to: b)
        reference.update(to: b)
        let prefix = [Float](repeating: 1, count: 960)
        let before = render(prefix, with: &p)
        _ = render(prefix, with: &reference)
        p.update(to: obsolete)
        p.update(to: next)
        reference.update(to: next)
        let suffix = [Float](repeating: 1, count: 4800)
        let after = render(suffix, with: &p)
        XCTAssertEqual(after, render(suffix, with: &reference))
        XCTAssertEqual(after.first!, before.last!, accuracy: 0.001)
        XCTAssertEqual(after.last!, Float(next.preampGain))
        XCTAssertEqual(after.max()!, Float(next.preampGain))
    }

    func testResetInstallsLatestRequestAndFadesInAtStreamRate() throws {
        let a = try plan([Band(.lowPass, frequency: 50)])
        var p = EqualizerProcessor(plan: a, channels: 1)
        p.update(to: a, mode: .off)
        _ = render(Array(repeating: 1, count: 700), with: &p)
        let b = try plan([], gain: -6, rate: 96000)
        p.update(to: b)
        p.reset()
        let audio = render(Array(repeating: 1, count: 4096), with: &p)
        XCTAssertEqual(audio[0], Float(b.preampGain / 480))
        XCTAssertEqual(audio[239], Float(b.preampGain / 2))
        XCTAssertEqual(audio[479], Float(b.preampGain))
        XCTAssertEqual(audio.last!, Float(b.preampGain))
    }

    func testWarmupReplacementAndDuplicatePlans() throws {
        let bands = try [Band(.peakDip, frequency: 50, gainDB: 8, q: 6)]
        let a = try plan([]), skipped = try plan([], gain: 12), b = try plan(bands)
        var p = EqualizerProcessor(plan: a, channels: 1)
        var reference = EqualizerProcessor(plan: a, channels: 1)
        p.update(to: skipped)
        _ = render(Array(repeating: 1, count: 300), with: &p)
        p.update(to: b)
        reference.update(to: b)
        let duplicate = try plan(bands)
        for _ in 0..<64 {
            p.update(to: duplicate)
            let x = (0..<97).map { Float(sin(Double($0) * 0.02)) }
            XCTAssertEqual(render(x, with: &p), render(x, with: &reference))
        }
    }

    func testFaultResetsBothAudibleChainsAndIsolatesChannels() throws {
        let a = try plan([Band(.lowShelf, frequency: 250, gainDB: 12, q: 2)])
        let b = try plan([Band(.peakDip, frequency: 150, gainDB: 9, q: 3)])
        var p = EqualizerProcessor(plan: a, channels: 2)
        var clean = EqualizerProcessor(plan: a, channels: 2)
        var freshA = EqualizerProcessor(plan: a, channels: 1)
        var freshB = EqualizerProcessor(plan: b, channels: 1)
        p.update(to: b)
        clean.update(to: b)
        let faultFrame = 850
        var stereo = [Float](repeating: 0.3, count: 4000)
        var reference = stereo
        reference.withUnsafeMutableBufferPointer { XCTAssertTrue(clean.process(interleaved: $0.baseAddress!, frames: 2000)) }
        stereo[2 * faultFrame] = .nan
        stereo.withUnsafeMutableBufferPointer { XCTAssertFalse(p.process(interleaved: $0.baseAddress!, frames: 2000)) }
        let remaining = [Float](repeating: 0.3, count: 2000 - faultFrame - 1)
        let old = render(remaining, with: &freshA), new = render(remaining, with: &freshB)
        for frame in 0..<2000 {
            XCTAssertEqual(stereo[2 * frame + 1].bitPattern, reference[2 * frame + 1].bitPattern)
            if frame > faultFrame {
                let i = frame - faultFrame - 1
                let t = min(1, Double(frame + 1 - 480) / 960)
                let mix = t * t * t * (10 + t * (6 * t - 15))
                let expected = ((1 - mix) * Double(old[i]) + mix * Double(new[i])) * min(1, Double(i + 1) / 240)
                XCTAssertEqual(Double(stereo[2 * frame]), expected, accuracy: 1e-7)
            }
        }
    }

    func testReloadClearsHistoryAndBassPeakSettles() throws {
        let flat = try plan([])
        let bass = try plan([Band(.peakDip, frequency: 20, gainDB: 12, q: 12)], gain: -12)
        var p = EqualizerProcessor(plan: bass, channels: 1)
        let cycle = (0..<144000).map { Float(0.5 * sin(2 * .pi * 20 * Double($0) / 48000)) }
        _ = render(cycle, with: &p)
        let steady = render(cycle, with: &p)
        p.update(to: flat)
        _ = render(cycle, with: &p)
        p.update(to: bass)
        var fresh = EqualizerProcessor(plan: flat, channels: 1)
        fresh.update(to: bass)
        let actual = render(cycle, with: &p)
        XCTAssertEqual(actual, render(cycle, with: &fresh))
        let errors = zip(actual, steady).map { abs($0 - $1) }
        XCTAssertGreaterThan(errors[1440..<2400].max()!, 0.01)
        XCTAssertLessThan(errors.suffix(from: 132000).max()!, 0.0005) // −60 dB relative to the tone after 2.75 s
    }

    func testDecayAndBitExactBypass() throws {
        let p = try plan([Band(.lowPass, frequency: 1000)])
        var processor = EqualizerProcessor(plan: p, channels: 1)
        var input = [Float](repeating: 0, count: 8192)
        input[0] = 1
        let decay = render(input, with: &processor)
        XCTAssertGreaterThan(decay[1], 0)
        XCTAssertTrue(decay.suffix(256).allSatisfy { $0 == 0 })
        XCTAssertFalse(decay.contains(where: \.isSubnormal))
        processor.update(to: p, mode: .off)
        _ = render(input, with: &processor)
        let bits: [Float] = [0, -0.0, .leastNonzeroMagnitude, -.leastNormalMagnitude, 1, -7]
        XCTAssertEqual(render(bits, with: &processor).map(\.bitPattern), bits.map(\.bitPattern))
    }
}
