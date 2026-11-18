import CoreAudio
import EqualizerCore
import EqualizerEngineCore
import XCTest
@testable import neqMac

final class EqualizerSessionTests: XCTestCase {
    final class Backend: TapDevice {
        var calls: [String] = []
        var failure: String?
        var removed = false
        var otherProcessPlaying = false
        var heartbeat: UInt64 = 0
        func step(_ name: String) throws {
            calls.append(name)
            if failure == name { throw TapError(message: name) }
        }
        func createTap() throws { try step("tap") }
        func createAggregate() throws { try step("aggregate") }
        func configure(_ profile: EQInfo) throws { try step("configure") }
        func createIO() throws { try step("io") }
        func startIO() throws { try step("start") }
        func destroyTap() { calls.append("unmute") }
        func stopIO() { calls.append("stop") }
        func destroyIO() { calls.append("destroyIO") }
        func destroyAggregate() { calls.append("destroyAggregate") }
    }

    let output = AudioDevice(audioObjectID: 101, uid: "test-output", name: "Test DAC", direction: .output, transportType: kAudioDeviceTransportTypeUSB)
    let profile = EQInfo(author: "Example", parameters: ParametricEQ(gainDB: -6, bands: []))
    let teardown = ["unmute", "stop", "destroyIO", "destroyAggregate"]
    var desired: DesiredEqualizer { .process(profile, try! EqualizerPlan(profile.parameters, sampleRate: 48_000)) }

    func testPartialBuildAndFailureBackoff() {
        for (failure, cleanup) in [("tap", []), ("aggregate", ["unmute"]), ("configure", ["unmute", "destroyAggregate"]),
                                   ("io", ["unmute", "destroyAggregate"]), ("start", teardown)] {
            let audio = Backend()
            audio.failure = failure
            let engine = SessionEngine { _ in }
            engine.reconcile(desired, output: output) { _ in audio }
            XCTAssertEqual(engine.status, .failed(failure))
            XCTAssertEqual(Array(audio.calls.drop { $0 != failure }.dropFirst()), cleanup)
            engine.reconcile(desired, output: output) { _ in XCTFail("Unexpected retry"); return audio }
        }
    }

    func testWatchdogAndIdempotentLoss() throws {
        for notificationFirst in [false, true] {
            let audio = Backend()
            let engine = SessionEngine { _ in }
            engine.reconcile(desired, output: output) { _ in audio }
            let session = try XCTUnwrap(engine.session)
            let monitor = session.monitor
            XCTAssertNil(monitor.check(now: 0))
            XCTAssertNil(monitor.check(now: 10))
            audio.otherProcessPlaying = true
            XCTAssertNil(monitor.check(now: 11))
            XCTAssertNil(monitor.check(now: 11.34))
            audio.heartbeat += 1
            XCTAssertNil(monitor.check(now: 11.36))
            audio.otherProcessPlaying = false
            XCTAssertNil(monitor.check(now: 14))
            audio.otherProcessPlaying = true
            XCTAssertNil(monitor.check(now: 20))
            audio.removed = true
            for notification in [notificationFirst, !notificationFirst] {
                let reason = try XCTUnwrap(monitor.check(now: 20.55, notification: notification))
                engine.finish(session, reason: reason)
            }
            XCTAssertEqual(engine.status, .suspended("Device removed"))
            XCTAssertEqual(audio.calls.filter { $0 == "unmute" }.count, 1)
            XCTAssertEqual(Array(audio.calls.suffix(4)), teardown)
        }
    }

    func testActiveExpiryFormatAndRetarget() throws {
        let audio = Backend()
        let engine = SessionEngine { _ in }
        engine.reconcile(desired, output: output) { _ in audio }
        engine.reconcile(.process(profile, try EqualizerPlan(profile.parameters, sampleRate: 96_000)), output: output, formatChanged: true) { _ in XCTFail(); return audio }
        XCTAssertEqual(audio.calls, ["tap","aggregate","configure","io","start","configure"])
        let next = AudioDevice(audioObjectID: 102, uid: "second", name: "Second DAC", direction: .output, transportType: kAudioDeviceTransportTypeUSB)
        let other = Backend()
        engine.reconcile(desired, output: next) { _ in other }
        XCTAssertEqual(Array(audio.calls.suffix(4)), teardown)
        let session = try XCTUnwrap(engine.session)
        other.otherProcessPlaying = true
        XCTAssertNil(session.monitor.check(now: 1))
        let reason = try XCTUnwrap(session.monitor.check(now: 1.36))
        engine.finish(session, reason: reason)
        XCTAssertEqual(engine.status, .failed("Audio callback stalled"))
        XCTAssertEqual(Array(other.calls.suffix(4)), teardown)
    }

    func testInactiveSettingsNeverReachTapCreation() throws {
        let off = try JSONDecoder().decode(EqualizerSettings.self, from: Data("{}".utf8))
        let engine = SessionEngine { _ in }
        for file in [SettingsFile.absent, .loaded(off), .invalid("Malformed assignment")] {
            engine.reconcile(.resolve(file, device: output, rate: 48_000), output: output) { _ in XCTFail("Permission path reached"); return Backend() }
        }
    }

    func testDiscoverySkipsPrivateAggregateUIDs() {
        XCTAssertFalse(CoreAudioClient.routable(uid: CoreAudioClient.equalizerAggregatePrefix + "synthetic"))
        XCTAssertTrue(CoreAudioClient.routable(uid: "test-output"))
    }
}

extension EqualizerSessionTests {
    func testRenderChangesSizeAndChannelCountBetweenCallbacks() throws {
        let plan = try EqualizerPlan(profile.parameters, sampleRate: 48_000)
        let p = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
        p.initialize(to: RenderContext(plan: plan, channels: 2, firstInput: 0))
        defer { p.deinitialize(count: 1); p.deallocate() }
        for channels in [2, 1, 6] {
            RenderContext.publish(p, plan: plan, channels: channels, firstInput: 0)
            var samples = [Float](repeating: 0.1, count: 513 * channels)
            var result = [Float](repeating: 0, count: samples.count)
            samples.withUnsafeMutableBytes { src in
                result.withUnsafeMutableBytes { dst in
                    var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                    var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                    RenderContext.render(p, input: &input, output: &output)
                }
            }
            XCTAssertTrue(result.allSatisfy { abs($0 - 0.0501187) < 0.00001 })
        }
    }
}
