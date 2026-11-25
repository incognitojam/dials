import CoreAudio
import EqualizerCore
import Foundation
import XCTest
@testable import neqMac

@available(macOS 14.2, *)
final class EqualizerControllerTests: XCTestCase {
    final class Hardware: EqualizerHardware {
        var readError: Error?
        var present = true
        var rateValue: Double? = 48_000
        var rateChanged: (() -> Void)?
        var hasOwnInputs = false
        var fail = false
        var playingOnFirstSession = false
        var mismatchOnFirstSession = false
        var backends: [EqualizerSessionTests.Backend] = []
        var callbacks: [() -> Void] = []
        var wanted: [() -> Bool] = []
        func isCurrent(_ device: AudioDevice) throws -> Bool {
            if let readError { throw readError }
            return present
        }
        func rate(_ device: AudioDevice) throws -> Double {
            guard let rateValue else { throw TapError(message: "Rate unavailable") }
            return rateValue
        }
        func observeRate(_ device: AudioDevice, queue: DispatchQueue, changed: @escaping () -> Void) throws -> () -> Void {
            rateChanged = changed
            return { self.rateChanged = nil }
        }
        func tap(_ device: AudioDevice, queue: DispatchQueue, diagnostic: @escaping (String) -> Void,
                 wanted: @escaping () -> Bool, changed: @escaping () -> Void) -> TapDevice {
            let backend = EqualizerSessionTests.Backend()
            if playingOnFirstSession && backends.isEmpty { backend.otherProcessPlaying = true }
            if mismatchOnFirstSession && backends.isEmpty {
                backend.otherProcessPlaying = true
                backend.layoutMismatch = true
            }
            backend.hasOwnInputs = hasOwnInputs
            if fail { backend.failure = "tap" }
            backends.append(backend)
            callbacks.append(changed)
            self.wanted.append(wanted)
            return backend
        }
    }

    let device = AudioDevice(audioObjectID: 90, uid: "test-dac", name: "Test DAC", direction: .output, transportType: kAudioDeviceTransportTypeUSB)
    let json = #"{"enabled":true,"assignments":[{"uid":"test-dac","enabled":true,"choice":"profile","profile":{"author":"Example","type":"parametric_eq","parameters":{"gain_db":-12,"bands":[]}}}]}"#
    let queue = DispatchQueue(label: "test.controller")
    let hardware = Hardware()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var url: URL { directory.appendingPathComponent("equalizer.json") }
    var controller: EqualizerController!
    var statuses: [SessionStatus] = []
    var onStatus: ((SessionStatus) -> Void)?
    var messages: [String] = []

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        controller = EqualizerController(url: url, hardware: hardware, queue: queue, didTearDown: {},
            report: { [weak self] status in
                self?.statuses.append(status)
                self?.onStatus?(status)
            }, diagnostic: { [weak self] in self?.messages.append($0) })
    }

    override func tearDownWithError() throws {
        controller = nil
        queue.sync {}
        try FileManager.default.removeItem(at: directory)
    }

    private let refused = SessionStatus.suspended("Outputs with their own inputs are not supported")

    private func refuseRunningSession() throws {
        controller.settled(output: device)
        let session = try queue.sync {
            let session = try XCTUnwrap(controller.engine.session)
            hardware.backends.last?.onConfigure = { throw SessionError.ownInputs }
            hardware.callbacks.last?()
            return session
        }
        session.verification.sync {}
        queue.sync { XCTAssertEqual(statuses.last, refused) }
    }

    @MainActor
    func testUnrelatedDiscoveryAndRateNotificationHoldUntilTargetEntryChanges() throws {
        let scheduler = ManualScheduler()
        let client = TestAudioClient(devices: [device], outputID: device.audioObjectID)
        let model = AppModel(audioClient: client, persistence: MemoryPolicyStore(), scheduler: scheduler, equalizer: controller)
        try refuseRunningSession()

        client.availableDevices.append(AudioDevice(audioObjectID: 91, uid: "other", name: "Other",
            direction: .output, transportType: kAudioDeviceTransportTypeUSB))
        model.handleHardwareChange()
        scheduler.runPending()
        try queue.sync {
            hardware.rateValue = 96_000
            try XCTUnwrap(hardware.rateChanged)()
            XCTAssertEqual(hardware.backends.count, 1)
            XCTAssertEqual(statuses.last, refused)
        }

        client.availableDevices[0].name = "Renamed DAC"
        model.handleHardwareChange()
        scheduler.runPending()
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 2)
            XCTAssertEqual(statuses.last, .running)
        }
    }

    func testStartTimeRefusalHoldsUntilTargetDisappearsAndReturns() {
        hardware.hasOwnInputs = true
        controller.settled(output: device)
        queue.sync {
            XCTAssertEqual(statuses.suffix(2), [.starting, refused])
            XCTAssertEqual(hardware.backends.first?.calls, [])
            hardware.hasOwnInputs = false
        }
        controller.settled(output: device)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 1)
            XCTAssertEqual(statuses.last, refused)
        }
        controller.disconnected(device)
        controller.settled(output: device)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 2)
            XCTAssertEqual(statuses.last, .running)
        }
    }

    func testSettingsEditRetriesWhileHeldAndMasterSwitchRestoresProcessing() throws {
        try refuseRunningSession()
        func edit(_ contents: String, expecting status: SessionStatus) throws {
            let observed = expectation(description: "settings change produces \(status)")
            queue.sync { onStatus = { if $0 == status { observed.fulfill() } } }
            try Data(contents.utf8).write(to: url, options: .atomic)
            wait(for: [observed], timeout: 3)
            queue.sync { onStatus = nil }
        }
        queue.sync { hardware.hasOwnInputs = true }
        let profileEdit = json.replacingOccurrences(of: "-12", with: "-9")
        try edit(profileEdit, expecting: refused)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 2)
            XCTAssertEqual(hardware.backends.last?.calls, [])
            XCTAssertEqual(statuses.suffix(2), [.starting, refused])
        }

        let disabled = profileEdit.replacingOccurrences(of: #"{"enabled":true"#, with: #"{"enabled":false"#)
        try edit(disabled, expecting: .idle)
        queue.sync { hardware.hasOwnInputs = false }
        try edit(profileEdit, expecting: .running)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 3)
            XCTAssertEqual(statuses.last, .running)
        }
    }

    func testDuplexUSBOutputSuspendsBeforeBuildingSession() {
        var duplex = device
        duplex.hasInputStreams = true
        controller.settled(output: duplex)
        queue.sync {
            XCTAssertEqual(statuses.last, .suspended("Outputs with their own inputs are not supported"))
            XCTAssertTrue(hardware.backends.isEmpty)
        }
    }

    func testCurrentOutputReadFailureExplainsIdle() {
        hardware.readError = TapError(message: "default output unavailable")
        controller.settled(output: device)
        queue.sync {
            XCTAssertTrue(messages.contains("Equalizer idle · default output unavailable"))
            XCTAssertTrue(hardware.backends.isEmpty)
        }
    }

    func testPhysicalRemovalAndSameIDReconnectIgnoreOldGeneration() {
        controller.settled(output: device)
        let old = queue.sync {
            let old = controller.engine.session
            XCTAssertTrue(hardware.wanted[0]())
            hardware.present = false
            hardware.backends[0].deviceGone = true
            XCTAssertFalse(hardware.wanted[0]())
            hardware.callbacks[0]()
            return old
        }
        guard let old else { return XCTFail("Missing initial session") }
        old.verification.sync {}
        queue.sync {
            XCTAssertTrue(statuses.contains(.suspended("Device removed")))
        }
        controller.settled(output: device)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 1)
            hardware.present = true
        }
        controller.settled(output: device)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 2)
            XCTAssertFalse(hardware.wanted[0]())
            hardware.callbacks[0]()
            XCTAssertEqual(hardware.backends[1].rates, [48_000])
            hardware.callbacks[1]()
            XCTAssertEqual(statuses.last, .reconfiguring)
            XCTAssertTrue(messages.contains { $0.hasPrefix("Create tap: ") })
        }
    }

    func testSettledOutputKeepsRateVerifiedByTap() throws {
        controller.settled(output: device)
        let session = try queue.sync {
            let session = try XCTUnwrap(controller.engine.session)
            hardware.rateValue = 96_000
            hardware.backends[0].negotiatedRate = 96_000
            hardware.callbacks[0]()
            return session
        }
        session.verification.sync {}
        queue.sync { controller.engine.observed(session, .running) { XCTFail() } }
        controller.settled(output: device)
        queue.sync {
            XCTAssertEqual(statuses, [.starting, .running, .reconfiguring, .running])
            XCTAssertEqual(session.verifiedRate, 96_000)
        }
    }

    func testSleepWakeAndSettingsCheckBeforeStart() throws {
        controller.settled(output: device)
        try queue.sync { _ = try XCTUnwrap(hardware.backends.first) }
        controller.powerChanged(true)
        controller.settled(output: device)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 1)
            XCTAssertFalse(hardware.wanted[0]())
            XCTAssertEqual(hardware.backends[0].calls.suffix(4), ["unmute", "stop", "destroyIO", "destroyAggregate"])
        }
        controller.powerChanged(false)
        let wake = expectation(description: "wake reconciliation")
        queue.asyncAfter(deadline: .now() + 1.1) { wake.fulfill() }
        wait(for: [wake], timeout: 3)
        try queue.sync {
            XCTAssertEqual(hardware.backends.count, 2)
            try Data("{}".utf8).write(to: url)
            XCTAssertFalse(hardware.wanted[1]())
        }
    }

    func testWatchdogLayoutSuspensionRetriesAfterSettleWithoutFileEdit() {
        let recovered = expectation(description: "verified replacement session")
        var suspendedAt: TimeInterval?
        hardware.mismatchOnFirstSession = true
        onStatus = { status in
            if status == .suspended("Tap input layout no longer verified") {
                suspendedAt = ProcessInfo.processInfo.systemUptime
            }
            if status == .running, let suspendedAt {
                XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - suspendedAt, 0.5)
                recovered.fulfill()
            }
        }
        controller.settled(output: device)
        wait(for: [recovered], timeout: 4)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 2)
            XCTAssertFalse(hardware.wanted[0]())
            XCTAssertTrue(hardware.wanted[1]())
        }
    }

    func testStoppedIOAfterRateChangeRebuildsAtNewRateWithoutFileEdit() {
        hardware.playingOnFirstSession = true
        let restarted = expectation(description: "replacement applied at new rate")
        onStatus = { [weak self] status in
            if status == .running, self?.hardware.backends.count == 2 { restarted.fulfill() }
        }
        controller.settled(output: device)
        queue.sync {
            hardware.rateValue = 96_000
            for _ in 0..<17 { hardware.callbacks[0]() }
        }
        wait(for: [restarted], timeout: 4)
        queue.sync {
            XCTAssertEqual(statuses.filter { $0 == .reconfiguring }.count, 1)
            XCTAssertEqual(hardware.backends[0].calls.suffix(4), ["unmute", "stop", "destroyIO", "destroyAggregate"])
            XCTAssertEqual(hardware.backends.dropFirst().first?.rates, [96_000])
        }
    }

    func testTurningOffWhileLayoutRetryIsPendingPreventsCapture() throws {
        let suspended = expectation(description: "layout suspended")
        hardware.mismatchOnFirstSession = true
        onStatus = { status in
            if status == .suspended("Tap input layout no longer verified") { suspended.fulfill() }
        }
        controller.settled(output: device)
        wait(for: [suspended], timeout: 3)
        try Data("{}".utf8).write(to: url, options: .atomic)
        let settled = expectation(description: "retry deadline passed")
        queue.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        queue.sync {
            XCTAssertEqual(hardware.backends.count, 1)
            XCTAssertEqual(statuses.last, .idle)
        }
    }

    func testAttributeOnlyEventAndReadsDoNotRetryFailedBuild() throws {
        hardware.fail = true
        controller.settled(output: device)
        queue.sync { XCTAssertEqual(hardware.backends.count, 1) }
        XCTAssertEqual(url.withUnsafeFileSystemRepresentation { setxattr($0, "com.example.test", "x", 1, 0, 0) }, 0)
        let attrs = expectation(description: "watcher has processed attribute event")
        queue.asyncAfter(deadline: .now() + 0.4) { attrs.fulfill() }
        wait(for: [attrs], timeout: 2)
        queue.sync { XCTAssertEqual(hardware.backends.count, 1) }
        try Data((json + "\n").utf8).write(to: url, options: .atomic)
        let content = expectation(description: "watcher has processed content edit")
        queue.asyncAfter(deadline: .now() + 0.4) { content.fulfill() }
        wait(for: [content], timeout: 2)
        queue.sync { XCTAssertEqual(hardware.backends.count, 2) }
    }
}
