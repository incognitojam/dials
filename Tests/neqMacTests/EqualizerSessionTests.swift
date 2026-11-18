import CoreAudio
import EqualizerCore
import EqualizerEngineCore
import EqualizerIO
import XCTest
@testable import neqMac

final class EqualizerSessionTests: XCTestCase {
    final class Backend: TapDevice {
        var calls: [String] = []
        var rates: [Double] = []
        var failure: String?
        var onStop: (() -> Void)?
        var onConfigure: (() -> Void)?
        var deviceGone = false
        var zeroOutputChannels = false
        var onRemovalRead: (() -> Void)?
        var removed: Bool { onRemovalRead?(); return deviceGone }
        var layoutMismatch = false
        var otherProcessPlaying = false
        var heartbeat: UInt64 = 0
        func step(_ name: String) throws {
            calls.append(name)
            if failure == name { throw TapError(message: name) }
        }
        func createTap() throws { try step("tap") }
        func createAggregate() throws { try step("aggregate") }
        func configure(_ profile: EQInfo, plan: EqualizerPlan) throws {
            try step("configure")
            rates.append(plan.sampleRate)
            onConfigure?()
        }
        func createIO() throws { try step("io") }
        func startIO() throws { try step("start") }
        func destroyTap() { calls.append("unmute") }
        func stopIO() { onStop?(); calls.append("stop") }
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
            monitor.setPlaying(true)
            XCTAssertNil(monitor.check(now: 11))
            XCTAssertNil(monitor.check(now: 11.34))
            audio.heartbeat += 1
            XCTAssertNil(monitor.check(now: 11.36))
            monitor.setPlaying(false)
            XCTAssertNil(monitor.check(now: 14))
            monitor.setPlaying(true)
            XCTAssertNil(monitor.check(now: 20))
            audio.deviceGone = true
            audio.zeroOutputChannels = !notificationFirst
            for notification in [notificationFirst, !notificationFirst] {
                if notification {
                    if engine.session != nil { engine.reconcile(desired, output: output) { _ in audio } }
                } else if let reason = monitor.check(now: 20.55) {
                    engine.finish(session, reason: reason)
                }
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
        XCTAssertEqual(audio.rates, [48_000, 96_000])
        let next = AudioDevice(audioObjectID: 102, uid: "second", name: "Second DAC", direction: .output, transportType: kAudioDeviceTransportTypeUSB)
        let other = Backend()
        engine.reconcile(desired, output: next) { _ in other }
        XCTAssertEqual(Array(audio.calls.suffix(4)), teardown)
        let session = try XCTUnwrap(engine.session)
        session.monitor.setPlaying(true)
        XCTAssertNil(session.monitor.check(now: 1))
        let reason = try XCTUnwrap(session.monitor.check(now: 1.36))
        other.onStop = { XCTAssertEqual(engine.status, .failed("Audio callback stalled")) }
        engine.finish(session, reason: reason)
        other.onStop = nil
        XCTAssertEqual(engine.status, .failed("Audio callback stalled"))
        XCTAssertEqual(Array(other.calls.suffix(4)), teardown)
    }

    func testLowRateSuspendsAndSwitchingOffReleasesTheResumedSession() {
        var stops = 0
        let engine = SessionEngine(didTearDown: { stops += 1 }) { _ in }
        let audio = Backend()
        engine.reconcile(desired, output: output) { _ in audio }
        engine.reconcile(.suspended("Output rate below 32 kHz"), output: output) { _ in XCTFail(); return audio }
        XCTAssertEqual(engine.status, .suspended("Output rate below 32 kHz"))
        XCTAssertEqual(Array(audio.calls.suffix(4)), teardown)
        let resumed = Backend()
        engine.reconcile(desired, output: output) { _ in resumed }
        XCTAssertEqual(engine.status, .running)
        engine.reconcile(.off, output: output) { _ in XCTFail(); return resumed }
        XCTAssertEqual(engine.status, .idle)
        XCTAssertEqual(Array(resumed.calls.suffix(4)), teardown)
        XCTAssertEqual(stops, 2)
    }

    func testExpiryReleasesMuteBeforeBlockingRemovalQuery() throws {
        let audio = Backend()
        let engine = SessionEngine { _ in }
        engine.reconcile(desired, output: output) { _ in audio }
        let session = try XCTUnwrap(engine.session)
        let entered = expectation(description: "removal read")
        let done = expectation(description: "watchdog finished")
        let release = DispatchSemaphore(value: 0)
        audio.onRemovalRead = {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
        }
        session.monitor.setPlaying(true)
        XCTAssertNil(session.monitor.check(now: 0))
        DispatchQueue.global().async {
            XCTAssertEqual(session.monitor.check(now: 1), .failed("Audio callback stalled"))
            done.fulfill()
        }
        wait(for: [entered], timeout: 1)
        XCTAssertEqual(audio.calls.last, "unmute")
        release.signal()
        wait(for: [done], timeout: 1)
        engine.finish(session, reason: .idle)
        XCTAssertEqual(audio.calls.filter { $0 == "unmute" }.count, 1)
    }

    func testFormatNotificationsResetDeadlineAndRetryWithoutFailure() throws {
        let audio = Backend()
        let engine = SessionEngine { _ in }
        engine.reconcile(desired, output: output) { _ in audio }
        let session = try XCTUnwrap(engine.session)
        session.monitor.setPlaying(true)
        XCTAssertNil(session.monitor.check(now: 0))
        audio.zeroOutputChannels = true
        audio.failure = "configure"
        engine.reconcile(desired, output: output, formatChanged: true) { _ in XCTFail(); return audio }
        XCTAssertNil(session.monitor.check(now: 0.6))
        XCTAssertTrue(engine.session === session)
        audio.zeroOutputChannels = false
        audio.failure = nil
        engine.reconcile(desired, output: output, formatChanged: true) { _ in XCTFail(); return audio }
        XCTAssertEqual(engine.status, .running)
        audio.failure = "configure"
        for _ in 0..<3 { engine.reconcile(desired, output: output, formatChanged: true) { _ in audio } }
        XCTAssertEqual(engine.status, .suspended("Format unavailable after three configuration notifications"))
        XCTAssertEqual(Array(audio.calls.suffix(4)), teardown)
    }

    func testUnplugDuringBuildSuspends() {
        let audio = Backend()
        audio.onConfigure = { audio.deviceGone = true }
        audio.failure = "io"
        let engine = SessionEngine { _ in }
        engine.reconcile(desired, output: output) { _ in audio }
        XCTAssertEqual(engine.status, .suspended("Device removed"))
        XCTAssertEqual(Array(audio.calls.suffix(2)), ["unmute", "destroyAggregate"])
        audio.onConfigure = nil
    }

    func testPermissionWaitPrecedesWatchdog() {
        let entered = expectation(description: "waiting for permission")
        let running = expectation(description: "running after permission")
        let allow = DispatchSemaphore(value: 0)
        let audio = Backend()
        audio.otherProcessPlaying = true
        audio.onConfigure = {
            entered.fulfill()
            _ = allow.wait(timeout: .now() + 3)
        }
        let engine = SessionEngine { status in
            if status == .running { running.fulfill() }
            if case .failed = status { XCTFail("Prompt wait armed watchdog") }
        }
        let queue = DispatchQueue(label: "test.build")
        queue.async { [self] in
            engine.reconcile(desired, output: output) { _ in audio }
            if let session = engine.session {
                session.watch(on: queue) { engine.finish($0, reason: $1) }
                engine.finish(session, reason: .idle)
            }
        }
        wait(for: [entered], timeout: 2)
        DispatchQueue.global().asyncAfter(deadline: .now() + SessionGuard.callbackTolerance * 2) { allow.signal() }
        wait(for: [running], timeout: 2)
        queue.sync { XCTAssertEqual(Array(audio.calls.suffix(4)), teardown) }
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
        p.initialize(to: RenderContext(plan: plan, channels: 2, layout: EQInputLayout(firstBuffer: 0, bufferCount: 1, totalBuffers: 1, channelsPerBuffer: 2)))
        defer { p.deinitialize(count: 1); p.deallocate() }
        for channels in [2, 1, 6] {
            RenderContext.publish(p, plan: plan, channels: channels, layout: EQInputLayout(firstBuffer: 0, bufferCount: 1, totalBuffers: 1, channelsPerBuffer: UInt32(channels)))
            var samples = [Float](repeating: 0.1, count: 513 * channels)
            var result = [Float](repeating: 0, count: samples.count)
            samples.withUnsafeMutableBytes { src in
                result.withUnsafeMutableBytes { dst in
                    var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                    var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                    RenderContext.render(p, input: &input, output: &output)
                }
            }
            XCTAssertTrue(result[0] < 0.001)
            XCTAssertTrue(result.dropFirst(240 * channels).allSatisfy { abs($0 - 0.0501187) < 0.00001 })
        }
    }
}
