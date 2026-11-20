import FrameRingStress
import EqualizerIO
import XCTest
#if os(macOS)
import CoreAudio
#endif

final class FrameRingTests: XCTestCase {
    private func write(_ samples: [Float], channels: Int = 1, to ring: OpaquePointer) -> Int {
        samples.withUnsafeBytes { bytes in
            var buffer = EQRingBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count),
                                      mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress))
            return Int(EQRingWriteBuffers(ring, &buffer, 1, UInt32(samples.count / channels)))
        }
    }

    func testSkipAtEveryWrapPhase() throws {
        XCTAssertNil(EQRingCreate(3, 1))
        XCTAssertNil(EQRingCreate(0, 1))
        XCTAssertNil(EQRingCreate(4, 0))
        for offset in 0..<8 {
            for discard in 0...9 {
                let ring = try XCTUnwrap(EQRingCreate(8, 1))
                defer { EQRingFree(ring) }
                XCTAssertEqual(write(Array(repeating: 0, count: offset), to: ring), offset)
                EQRingSkip(ring, .max)
                XCTAssertEqual(EQRingRead(ring, nil, 0), 0)
                XCTAssertEqual(write([], to: ring), 0)
                let samples = (0..<8).map(Float.init)
                XCTAssertEqual(write(samples, to: ring), 8)
                XCTAssertEqual(write([99], to: ring), 0)
                XCTAssertEqual(EQRingOverruns(ring), 1)
                EQRingSkip(ring, UInt64(discard))
                var output = [Float](repeating: -1, count: 9)
                let expected = Array(samples.dropFirst(discard))
                XCTAssertEqual(EQRingFill(ring), UInt64(expected.count))
                XCTAssertEqual(EQRingRead(ring, &output, 9), UInt32(expected.count))
                XCTAssertEqual(output, expected + Array(repeating: -1, count: 9 - expected.count))
                XCTAssertEqual(EQRingUnderruns(ring), UInt64(9 - expected.count))
            }
        }
    }

    func testPlanarAndMalformedInput() throws {
        let ring = try XCTUnwrap(EQRingCreate(2, 2))
        defer { EQRingFree(ring) }
        let samples: [Float] = [1, 2, 3, 4, 5, 6]
        samples.withUnsafeBytes { bytes in
            let base = UnsafeMutableRawPointer(mutating: bytes.baseAddress!)
            var buffers = [EQRingBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: base),
                           EQRingBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: base + 12)]
            XCTAssertEqual(EQRingWriteBuffers(ring, &buffers, 2, 3), 0)
            XCTAssertEqual(EQRingWriteBuffers(ring, &buffers, 1, 2), 0)
            XCTAssertEqual(EQRingFill(ring), 0)
            buffers[1].mDataByteSize = 12
            XCTAssertEqual(EQRingWriteBuffers(ring, &buffers, 2, 3), 2)
        }
        XCTAssertEqual(EQRingOverruns(ring), 1)
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(EQRingRead(ring, &output, 2), 2)
        XCTAssertEqual(output, [1, 4, 2, 5])
    }

    #if os(macOS)
    func testAudioBufferListWriter() throws {
        let ring = try XCTUnwrap(EQRingCreate(2, 2))
        defer { EQRingFree(ring) }
        let samples: [Float] = [1, -1, 2, -2]
        samples.withUnsafeBytes { bytes in
            let buffer = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count),
                                     mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress))
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            XCTAssertEqual(EQRingWrite(ring, &list, 2), 2)
        }
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(EQRingRead(ring, &output, 2), 2)
        XCTAssertEqual(output, samples)
    }
    #endif

    func testConcurrentSequence() {
        XCTAssertEqual(EQTestConcurrentRing(), 0)
    }
}
