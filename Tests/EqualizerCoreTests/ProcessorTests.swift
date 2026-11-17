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
            var processor = EqualizerProcessor(plan: p, channels: 1, maximumFrames: 256)
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
                        var processor = EqualizerProcessor(plan: p, channels: 1, maximumFrames: 256)
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
            var switcher = EqualizerProcessor(plan: old, channels: 1, maximumFrames: 64, mode: oldMode)
            var reference = EqualizerProcessor(plan: next, channels: 1, maximumFrames: 64, mode: newMode)
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

    func testLatestPendingUpdateAndChunking() throws {
        let a = try plan([], gain: -12)
        let b = try plan([], gain: -6)
        let skipped = try plan([], gain: 9)
        let c = try plan([], gain: -3)
        var processor = EqualizerProcessor(plan: a, channels: 1, maximumFrames: 37)
        processor.update(to: b)
        _ = render(Array(repeating: 1, count: 100), with: &processor)
        processor.update(to: skipped)
        processor.update(to: c)
        let audio = render(Array(repeating: 1, count: 3500), with: &processor, block: 3500)
        XCTAssertEqual(audio[1339], Float(b.preampGain))
        XCTAssertEqual(audio[2299], Float((b.preampGain + c.preampGain) / 2), accuracy: 1e-7)
        XCTAssertEqual(audio[2779], Float(c.preampGain))
        XCTAssertEqual(audio.last, Float(c.preampGain))
        XCTAssertLessThanOrEqual(audio.max()!, Float(c.preampGain))
    }

    func testPlanarAndInterleavedUpdateAllChannelsTogether() throws {
        let a = try plan([Band(.peakDip, frequency: 830, gainDB: 7, q: 2)])
        let b = try plan([Band(.lowPass, frequency: 2300, slope: 24)], gain: -4)
        let frames = 3583
        for channels in [1, 2, 6] {
            var p = EqualizerProcessor(plan: a, channels: channels, maximumFrames: 51)
            var q = EqualizerProcessor(plan: a, channels: channels, maximumFrames: 67)
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
                var independent = EqualizerProcessor(plan: a, channels: 1, maximumFrames: 73)
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
        var processor = EqualizerProcessor(plan: p, channels: 1, maximumFrames: 512)
        _ = render(input, with: &processor)
        let corrected = render(input, with: &processor)
        processor.update(to: p, mode: .compare)
        _ = render(input, with: &processor)
        let compare = render(input, with: &processor)
        XCTAssertEqual(compare, input.map { Float(Double($0) * p.compareGain) })
        func power(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1) * Double($1) } }
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
            var processor = EqualizerProcessor(plan: p, channels: 2, maximumFrames: 17)
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
        var processor = EqualizerProcessor(plan: p, channels: 1, maximumFrames: 31)
        _ = render(Array(repeating: 0.5, count: 4000), with: &processor)
        var samples = [Float.nan] + Array(repeating: Float(0.25), count: 1000)
        samples.withUnsafeMutableBufferPointer {
            XCTAssertFalse(processor.process(interleaved: $0.baseAddress!, frames: $0.count))
        }
        var fresh = EqualizerProcessor(plan: p, channels: 1, maximumFrames: 64)
        let reference = render(Array(repeating: 0.25, count: 1000), with: &fresh)
        XCTAssertEqual(samples[0], 0)
        for i in reference.indices {
            XCTAssertEqual(samples[i + 1], reference[i] * Float(min(i + 1, 240)) / 240, accuracy: 5e-8)
        }
    }

    func testRateChangeFlushesPendingAndFadesAtNewRate() throws {
        let a = try plan([Band(.lowPass, frequency: 50)])
        var p = EqualizerProcessor(plan: a, channels: 1, maximumFrames: 128)
        p.update(to: a)
        p.update(to: a, mode: .off)
        _ = render([1, 1, 1], with: &p)
        let b = try plan([], gain: -6, rate: 96000)
        p.update(to: b)
        let audio = render(Array(repeating: 1, count: 4096), with: &p)
        XCTAssertEqual(audio[0], Float(b.preampGain / 480))
        XCTAssertEqual(audio[239], Float(b.preampGain / 2))
        XCTAssertEqual(audio[479], Float(b.preampGain))
        XCTAssertEqual(audio.last!, Float(b.preampGain))
    }

    func testDecayAndBitExactBypass() throws {
        let p = try plan([Band(.lowPass, frequency: 1000)])
        var processor = EqualizerProcessor(plan: p, channels: 1, maximumFrames: 64)
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
