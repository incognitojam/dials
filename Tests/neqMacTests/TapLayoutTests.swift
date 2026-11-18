import CoreAudio
import EqualizerCore
import EqualizerIO
import EqualizerEngineCore
import os.lock
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

    private func run(_ layout: EQInputLayout, _ inputs: [Buffer], _ outputs: [Buffer], gain: Double = 0,
                     prepare: (UnsafeMutablePointer<RenderContext>, EqualizerPlan) -> Void = { _, _ in }) throws -> [[Float]] {
        let plan = try EqualizerPlan(.init(gainDB: gain, bands: []), sampleRate: 48_000)
        let p = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
        p.initialize(to: RenderContext(plan: plan, channels: 2, layout: layout))
        defer { p.deinitialize(count: 1); p.deallocate() }
        prepare(p, plan)
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

    func testInvalidationDiscardsStalePendingSelectionUntilReverified() throws {
        let layout = EQInputLayout(firstBuffer: 0, bufferCount: 1, totalBuffers: 1, channelsPerBuffer: 2)
        for reverified in [false, true] {
            let samples = try run(layout, [Buffer(2, 0.1)], [Buffer(2, 7)]) { p, plan in
                RenderContext.publish(p, plan: plan, channels: 2, layout: layout)
                RenderContext.invalidate(p)
                if reverified { RenderContext.publish(p, plan: plan, channels: 2, layout: layout) }
            }
            XCTAssertEqual(samples[0].last, reverified ? 0.1 : 0)
        }
    }

    func testOutputOnlyReissuedIDAndDuplexEdgeIdentity() throws {
        XCTAssertEqual(try TapLayout.identify(initial: 22, streams: [33], physicalCount: 0, duplex: false), 33)
        for streams: [AudioStreamID] in [[22, 4, 5], [4, 5, 22]] {
            XCTAssertEqual(try TapLayout.identify(initial: 22, streams: streams, physicalCount: 2, duplex: true), 22)
        }
        for (streams, count, duplex) in [([4, 22, 5], 2, true), ([4, 5, 33], 2, true),
                                         ([4, 22], 2, true), ([33], 0, true), ([22, 4], 0, false)] {
            XCTAssertThrowsError(try TapLayout.identify(initial: 22, streams: streams.map(UInt32.init), physicalCount: count, duplex: duplex))
        }
    }

    func testSoleTapUUIDIgnoresCaseAndRejectsInvalidMembers() {
        let uuid = UUID()
        XCTAssertTrue(TapLayout.containsOnlyTap([uuid.uuidString.lowercased()], uuid))
        for members in [[], ["invalid"], [UUID().uuidString], [uuid.uuidString, uuid.uuidString]] {
            XCTAssertFalse(TapLayout.containsOnlyTap(members, uuid))
        }
    }

    @available(macOS 14.2, *)
    func testCreateTapChecksConsentBeforeCapture() throws {
        final class CaptureSpy: CoreAudioTap {
            var captures = 0
            override func physicalInputsBeforeCapture() throws -> (streams: Int, widths: [UInt32]) { (1, [2]) }
            override func createProcessTap() throws { captures += 1 }
        }
        let dac = AudioDevice(audioObjectID: 90, uid: "test-dac", name: "Test DAC", direction: .output, transportType: kAudioDeviceTransportTypeUSB)
        for consent in [false, true] {
            let tap = CaptureSpy(output: dac, queue: .main, allowDuplexInput: consent, changed: {})
            if consent { try tap.createTap() } else { XCTAssertThrowsError(try tap.createTap()) }
            XCTAssertEqual(tap.captures, consent ? 1 : 0)
        }
    }

    func testDuplexGateRequiresExplicitConsentBeforeCapture() {
        XCTAssertNoThrow(try TapLayout.requireConsent(inputStreams: 0, bufferWidths: [], allowed: false))
        XCTAssertThrowsError(try TapLayout.requireConsent(inputStreams: 1, bufferWidths: [], allowed: false))
        XCTAssertThrowsError(try TapLayout.requireConsent(inputStreams: 0, bufferWidths: [2], allowed: false))
        XCTAssertNoThrow(try TapLayout.requireConsent(inputStreams: 2, bufferWidths: [1, 1], allowed: true))
    }

    func testHandEditedBoostIsAttenuatedBeforeRendering() throws {
        let json = #"{"enabled":true,"assignments":[{"uid":"test-dac","enabled":true,"choice":"profile","profile":{"author":"Example","type":"parametric_eq","parameters":{"gain_db":30,"bands":[{"type":"peak_dip","frequency":1000,"gain_db":20,"q":1}]}}}]}"#
        let dac = AudioDevice(audioObjectID: 90, uid: "test-dac", name: "Test DAC", direction: .output, transportType: kAudioDeviceTransportTypeUSB)
        let desired = DesiredEqualizer.resolve(.init(data: Data(json.utf8)), device: dac, rate: 48_000)
        guard case let .process(_, plan) = desired else { return XCTFail("Expected a protected plan") }
        XCTAssertEqual(plan.headroomDB, 50, accuracy: 1e-6)
        XCTAssertEqual(plan.magnitudeDB(at: 1000), 0, accuracy: 1e-6)
        let layout = EQInputLayout(firstBuffer: 0, bufferCount: 1, totalBuffers: 1, channelsPerBuffer: 2)
        let p = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
        p.initialize(to: RenderContext(plan: plan, channels: 2, layout: layout))
        defer { p.deinitialize(count: 1); p.deallocate() }
        let src = Buffers([Buffer(2, 0.05, 2048)]), dest = Buffers([Buffer(2, 7, 2048)])
        RenderContext.render(p, input: src.list.unsafePointer, output: dest.list.unsafeMutablePointer)
        let samples = dest.values(0)
        XCTAssertEqual(try XCTUnwrap(samples.last), 0.005, accuracy: 0.00001)
        XCTAssertLessThan(samples.map(abs).max()!, 0.05)
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

extension TapLayoutTests {
    func testMaskWritesOnStartAndRepairsOnlyDriftedReadback() {
        struct Mask {
            var flags: [UInt32] = [1, 1]
            var calls: [String] = []
            static let state = OSAllocatedUnfairLock(initialState: Mask())
        }
        let access: EQUsageAccess = { write, _, _, usage in
            guard let usage else { return -1 }
            let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
            let flags = UnsafeMutableRawPointer(usage).advanced(by: offset).assumingMemoryBound(to: UInt32.self)
            let written = write ? [flags[0], flags[1]] : nil
            let current = Mask.state.withLock { state in
                state.calls.append(write ? "write" : "read")
                if let written { state.flags = written }
                return state.flags
            }
            if !write { flags[0] = current[0]; flags[1] = current[1] }
            return noErr
        }
        let io: AudioDeviceIOProc = { _, _, _, _, _, _, _ in 0 }
        for (install, flags, expected) in [(true, [0, 1], ["write", "read"]), (false, [0, 1], ["read"]),
                                           (false, [1, 1], ["read", "write", "read"])] {
            Mask.state.withLock { $0 = Mask(flags: flags.map(UInt32.init)) }
            XCTAssertEqual(EQTapStreamUsage(1, io, 2, 1, install, access), noErr)
            XCTAssertEqual(Mask.state.withLock { $0.calls }, expected)
            XCTAssertEqual(Mask.state.withLock { $0.flags }, [0, 1])
        }
    }

    func testIOProcInputMaskAndReadback() {
        let io: AudioDeviceIOProc = { _, _, _, _, _, _, _ in 0 }
        // Model three streams with the tap in the middle. Change the returned mask
        // or truncate the variable-length response to exercise the fail-closed paths.
        let access: EQUsageAccess = { write, scenario, size, usage in
            guard let usage, let size else { return -1 }
            XCTAssertNotNil(usage.pointee.mIOProc)
            let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
            XCTAssertEqual(Int(size.pointee), offset + 3 * MemoryLayout<UInt32>.size)
            let flags = UnsafeMutableRawPointer(usage).advanced(by: offset).assumingMemoryBound(to: UInt32.self)
            if write {
                XCTAssertEqual(usage.pointee.mNumberStreams, 3)
                XCTAssertEqual(Array(UnsafeBufferPointer(start: flags, count: 3)), [0,1,0])
            } else {
                usage.pointee.mNumberStreams = 3
                flags[0] = scenario == 2 ? 1 : 0
                flags[1] = 1
                flags[2] = 0
                if scenario == 3 { size.pointee -= 4 }
            }
            return 0
        }
        XCTAssertEqual(EQTapStreamUsage(1, io, 3, 1, true, access), noErr)
        XCTAssertNotEqual(EQTapStreamUsage(2, io, 3, 1, true, access), noErr)
        XCTAssertNotEqual(EQTapStreamUsage(3, io, 3, 1, false, access), noErr)
        XCTAssertNotEqual(EQTapStreamUsage(1, io, 3, 3, true, access), noErr)
    }
}
