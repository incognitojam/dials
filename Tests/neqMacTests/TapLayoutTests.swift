import CoreAudio
import EqualizerCore
import EqualizerIO
import XCTest
@testable import neqMac

final class TapLayoutTests: XCTestCase {
    struct Buffer {
        let channels: Int
        let frames: Int
        let sample: Float?
        init(_ channels: Int, _ sample: Float?, _ frames: Int = 512) {
            self.channels = channels
            self.sample = sample
            self.frames = frames
        }
    }

    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        init(_ specs: [Buffer]) {
            list = AudioBufferList.allocate(maximumBuffers: max(1, specs.count))
            list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(specs.count)
            for (i, b) in specs.enumerated() {
                let count = b.channels * b.frames
                let ptr = b.sample.map { value in
                    let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
                    p.initialize(repeating: value, count: count)
                    return p
                }
                list[i] = AudioBuffer(mNumberChannels: UInt32(b.channels), mDataByteSize: UInt32(count * 4), mData: ptr)
            }
        }
        func values(_ i: Int) -> [Float] {
            let b = list[i]
            return Array(UnsafeBufferPointer(start: b.mData!.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize)/4))
        }
        deinit {
            for b in list { b.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    private func format(_ planar: Bool) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: planar ? 4 : 8, mFramesPerPacket: 1, mBytesPerFrame: planar ? 4 : 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }

    private func run(_ layout: EQInputLayout, _ inputs: [Buffer], _ outputs: [Buffer], gain: Double = 0) throws -> [[Float]] {
        let plan = try EqualizerPlan(.init(gainDB: gain, bands: []), sampleRate: 48_000)
        let p = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
        p.initialize(to: RenderContext(plan: plan, channels: 2, layout: layout))
        defer { p.deinitialize(count: 1); p.deallocate() }
        let src = Buffers(inputs), dst = Buffers(outputs)
        RenderContext.render(p, input: src.list.unsafePointer, output: dst.list.unsafeMutablePointer)
        return outputs.indices.map { outputs[$0].sample == nil ? [] : dst.values($0) }
    }

    func testVerifiedStreamIdentityAcrossBufferOrders() throws {
        // Physical input stream 11 has two mono planes. Stream 22 is the attested tap.
        for tapFirst in [false, true] {
            for planar in [false, true] {
                let tap = planar ? [Buffer(1, 0.1), Buffer(1, 0.2)] : [Buffer(2, 0.1)]
                let mic = [Buffer(1, nil), Buffer(1, nil)]
                let specs = tapFirst ? tap + mic : mic + tap
                let f = format(planar)
                let selected = try TapLayout(tapID: 22, streams: tapFirst ? [22, 11] : [11, 22],
                    startingChannel: tapFirst ? 1 : 3, bufferWidths: specs.map { UInt32($0.channels) }, format: f, streamFormat: f)
                let samples = try run(selected.buffers, specs, [Buffer(2, 7)])[0]
                XCTAssertEqual(samples[1000], 0.1)
                XCTAssertEqual(samples[1001], planar ? 0.2 : 0.1)
                let liveMic = [Buffer(1, 0.9), Buffer(1, 0.8)]
                let ambiguous = tapFirst ? tap + liveMic : liveMic + tap
                XCTAssertTrue(try run(selected.buffers, ambiguous, [Buffer(2, 7)])[0].allSatisfy { $0 == 0 })
            }
        }
    }

    func testRejectsUnattestedStreamOrFormatAndIncompleteRange() {
        let f = format(false)
        for (ids, widths, start, virtual) in [([11], [2], 1, f), ([22,22], [2,2], 1, f),
            ([22], [1], 1, f), ([22], [2], 2, f), ([22], [2], 1, format(true))] {
            XCTAssertThrowsError(try TapLayout(tapID: 22, streams: ids.map(UInt32.init), startingChannel: UInt32(start),
                                               bufferWidths: widths.map(UInt32.init), format: f, streamFormat: virtual))
        }
    }

    func testShortAbsentAndDisabledBuffersOverwriteEveryWritableSample() throws {
        let layout = EQInputLayout(firstBuffer: 0, bufferCount: 1, totalBuffers: 1, channelsPerBuffer: 2)
        let out = try run(layout, [Buffer(2, 0.1, 100)], [Buffer(2, 7, 300), Buffer(4, 7), Buffer(1, 7, 50)])
        XCTAssertTrue(out[0][200...].allSatisfy { $0 == 0 })
        XCTAssertFalse(out.flatMap { $0 }.contains(7))
        XCTAssertTrue(try run(layout, [], [Buffer(2, 7)])[0].allSatisfy { $0 == 0 })
        XCTAssertTrue(try run(layout, [Buffer(2, 0.1)], [Buffer(2, nil), Buffer(2, 7)])[1].allSatisfy { $0 == 0 })
    }

    func testRenderClampsBothPolaritiesEvenForAnUncappedPlan() throws {
        let layout = EQInputLayout(firstBuffer: 0, bufferCount: 1, totalBuffers: 1, channelsPerBuffer: 2)
        for value: Float in [-0.05, 0.05] {
            let samples = try run(layout, [Buffer(2, value)], [Buffer(2, 7)], gain: 30)[0]
            XCTAssertTrue(samples.allSatisfy { (-1...1).contains($0) })
            XCTAssertEqual(samples.last, value < 0 ? -1 : 1)
        }
    }
}
