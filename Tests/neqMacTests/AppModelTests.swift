import CoreAudio
import XCTest
@testable import neqMac

@MainActor
final class AppModelTests: XCTestCase {
    private var scheduler: ManualScheduler!

    override func setUp() async throws {
        scheduler = ManualScheduler()
    }

    func testSelectionAndReconnectPreserveOneAirPlayRule() throws {
        let expectedUIDs = ["usb", "saved-receiver", "other-room", "tv"]
        let receiver = device(1, uid: "live-receiver")
        let usb = device(2, uid: "usb", transport: kAudioDeviceTransportTypeUSB)
        let microphone = device(3, uid: "microphone", direction: .input)
        let store = MemoryPolicyStore(PersistedPolicy(outputRules: [
            rule("usb", transport: "USB"),
            rule("saved-receiver"),
            rule("other-room", name: "Meeting Room"),
            rule("duplicate-receiver", excluded: true),
            rule("tv", name: "Living Room TV"),
            rule("tv-alias", name: "Living Room TV")
        ]))
        let client = TestAudioClient(devices: [receiver, usb, microphone], outputID: usb.audioObjectID)
        let model = AppModel(audioClient: client, persistence: store, scheduler: scheduler)

        XCTAssertEqual(model.policy.outputRules.map(\.uid), expectedUIDs)
        XCTAssertEqual(model.policy.inputRules.map(\.uid), ["microphone"])
        XCTAssertTrue(model.policy.outputRules[1].isExcluded)
        XCTAssertEqual(model.device(for: model.policy.outputRules[0]), usb)
        XCTAssertEqual(model.device(for: model.policy.outputRules[1]), receiver)
        XCTAssertEqual(store.savedPolicy, model.policy)

        model.setExcluded(false, ruleID: model.policy.outputRules[1].id)
        let airPlayRule = model.policy.outputRules[1]
        model.useNow(airPlayRule)
        XCTAssertEqual(client.selections, [receiver])
        XCTAssertEqual(model.systemOutputID, receiver.audioObjectID)
        let initialEvents = model.events

        for id: AudioObjectID in 4...6 {
            let replacement = device(id, uid: "replacement-\(id)")
            client.availableDevices = [replacement, usb, microphone]
            client.outputID = replacement.audioObjectID
            model.refreshHardwareState()

            XCTAssertEqual(model.policy.outputRules.map(\.uid), expectedUIDs)
            XCTAssertEqual(model.device(for: airPlayRule), replacement)
            XCTAssertTrue(model.isCurrent(airPlayRule))
            XCTAssertEqual(model.manualOverrideUID(for: .output), "saved-receiver")
            XCTAssertEqual(model.events, initialEvents)
        }

        client.availableDevices = [usb, microphone]
        client.outputID = usb.audioObjectID
        model.refreshHardwareState()
        XCTAssertNil(model.manualOverrideUID(for: .output))
        XCTAssertNil(model.device(for: airPlayRule))

        let reconnected = device(7, uid: "reconnected")
        let alias = device(8, uid: "another-alias")
        client.availableDevices += [alias, reconnected]
        client.outputID = reconnected.audioObjectID
        model.refreshHardwareState()
        model.useNow(airPlayRule)

        XCTAssertEqual(model.policy.outputRules.map(\.uid), expectedUIDs)
        XCTAssertEqual(client.selections.last, reconnected)
        XCTAssertTrue(model.isCurrent(airPlayRule))
        XCTAssertEqual(store.savedPolicy, model.policy)

        let television = device(9, uid: "live-tv", name: "Living Room TV")
        client.availableDevices += [television, device(10, uid: "live-tv-alias", name: television.name)]
        model.refreshHardwareState()
        model.useNow(model.policy.outputRules[3])

        XCTAssertEqual(model.policy.outputRules.map(\.uid), expectedUIDs)
        XCTAssertEqual(client.selections.last, television)
        XCTAssertTrue(model.isCurrent(model.policy.outputRules[3]))
        XCTAssertEqual(store.savedPolicy, model.policy)
    }

    func testAutomaticRoutingHonorsExclusionAndFallsBackOnDisconnect() {
        let receiver = device(1, uid: "live-receiver")
        let speakers = device(2, uid: "speakers", name: "Built-in Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
        let usb = device(3, uid: "usb", name: "USB Speakers", transport: kAudioDeviceTransportTypeUSB)
        let client = TestAudioClient(devices: [receiver, speakers, usb], outputID: speakers.audioObjectID)
        let store = MemoryPolicyStore(PersistedPolicy(outputRules: [
            rule("saved-receiver"),
            rule(usb.uid, name: usb.name, transport: "USB"),
            rule("duplicate-receiver", excluded: true),
            rule(speakers.uid, name: speakers.name, transport: "Built-in")
        ]))
        let model = AppModel(audioClient: client, persistence: store, scheduler: scheduler)

        model.setAutomationEnabled(true)
        XCTAssertEqual(client.selections, [])
        scheduler.runPending()
        XCTAssertEqual(client.selections, [usb])

        client.availableDevices = [receiver, speakers]
        client.outputID = kAudioObjectUnknown
        model.handleHardwareChange()
        scheduler.runPending()
        XCTAssertEqual(client.selections.last, speakers)

        model.setExcluded(false, ruleID: model.policy.outputRules[0].id)
        scheduler.runPending()

        XCTAssertEqual(client.selections, [usb, speakers, receiver])
        XCTAssertEqual(model.policy.outputRules.map(\.uid), ["saved-receiver", "usb", "speakers"])
        XCTAssertEqual(model.defaultOutputID, receiver.audioObjectID)
        XCTAssertTrue(model.isCurrent(model.policy.outputRules[0]))
        XCTAssertNil(model.lastError)
    }

    func testChangesBeforeReconciliationRunCollapseIntoOne() {
        let speakers = device(1, uid: "speakers", name: "Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
        let usb = device(2, uid: "usb", name: "USB Speakers", transport: kAudioDeviceTransportTypeUSB)
        let client = TestAudioClient(devices: [speakers, usb], outputID: speakers.audioObjectID)
        let store = MemoryPolicyStore(PersistedPolicy(outputRules: [
            rule(usb.uid, name: usb.name, transport: "USB"),
            rule(speakers.uid, name: speakers.name, transport: "Built-in")
        ]))
        let model = AppModel(audioClient: client, persistence: store, scheduler: scheduler)

        model.setAutomationEnabled(true)
        model.handleHardwareChange()
        model.setIncludeSystemSounds(false)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.runPending()
        XCTAssertEqual(client.selections, [usb])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testPausedAutomationDoesNotSwitchDevices() {
        let speakers = device(1, uid: "speakers", name: "Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
        let usb = device(2, uid: "usb", name: "USB Speakers", transport: kAudioDeviceTransportTypeUSB)
        let client = TestAudioClient(devices: [speakers, usb], outputID: speakers.audioObjectID)
        let store = MemoryPolicyStore(PersistedPolicy(outputRules: [
            rule(usb.uid, name: usb.name, transport: "USB"),
            rule(speakers.uid, name: speakers.name, transport: "Built-in")
        ]))
        let model = AppModel(audioClient: client, persistence: store, scheduler: scheduler)

        model.handleHardwareChange()
        scheduler.runPending()

        XCTAssertEqual(client.selections, [])
    }

    func testRemovingRulesSkipsConnectedDevices() {
        let usb = device(1, uid: "usb", transport: kAudioDeviceTransportTypeUSB)
        let store = MemoryPolicyStore(PersistedPolicy(outputRules: [
            rule("usb", transport: "USB"),
            rule("old-monitor", name: "Old Monitor", transport: "Audio device"),
            rule("old-dac", name: "Old DAC", transport: "USB")
        ]))
        let model = AppModel(
            audioClient: TestAudioClient(devices: [usb], outputID: usb.audioObjectID),
            persistence: store,
            scheduler: scheduler
        )

        model.removeRules(direction: .output, ids: Set(model.policy.outputRules.map(\.id)))

        XCTAssertEqual(model.policy.outputRules.map(\.uid), ["usb"])
        XCTAssertEqual(store.savedPolicy, model.policy)
    }

    func testArrangingAPinnedDeviceIntoNeverUseClearsThePin() {
        let speakers = device(1, uid: "speakers", name: "Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
        let dac = device(2, uid: "dac", name: "DAC", transport: kAudioDeviceTransportTypeUSB)
        let store = MemoryPolicyStore(PersistedPolicy(outputRules: [
            rule("speakers", name: "Speakers", transport: "Built-in"),
            rule("dac", name: "DAC", transport: "USB")
        ]))
        let model = AppModel(
            audioClient: TestAudioClient(devices: [speakers, dac], outputID: speakers.audioObjectID),
            persistence: store,
            scheduler: scheduler
        )
        let ids = model.policy.outputRules.map(\.id)

        model.useNow(model.policy.outputRules[1])
        XCTAssertEqual(model.manualOverrideUID(for: .output), "dac")

        model.arrange(direction: .output, allowed: [ids[0]], excluded: [ids[1]])

        XCTAssertNil(model.manualOverrideUID(for: .output))
        XCTAssertEqual(model.policy.outputRules.map(\.isExcluded), [false, true])
        XCTAssertEqual(model.events.first?.message, "Excluded DAC as an output")
        XCTAssertEqual(store.savedPolicy, model.policy)
    }

    func testSerialLessUSBDeviceKeepsOneRuleAcrossPorts() {
        let dock = "AppleUSBAudioEngine:Vendor:Desk DAC:1100000:1"
        let directPort = "AppleUSBAudioEngine:Vendor:Desk DAC:120000:1"
        let serialA = "AppleUSBAudioEngine:Vendor:Adapter:SERIAL0A:1"
        let serialB = "AppleUSBAudioEngine:Vendor:Adapter:SERIAL0B:1"
        let livePort = device(1, uid: "AppleUSBAudioEngine:Vendor:Desk DAC:2200000:1", name: "Desk DAC", transport: kAudioDeviceTransportTypeUSB)
        let store = MemoryPolicyStore(PersistedPolicy(outputRules: [
            rule(dock, name: "Desk DAC", transport: "USB"),
            rule(serialA, name: "Adapter", transport: "USB"),
            rule(directPort, name: "Desk DAC", transport: "Audio device", excluded: true),
            rule(serialB, name: "Adapter", transport: "USB")
        ]))
        let model = AppModel(
            audioClient: TestAudioClient(devices: [livePort], outputID: livePort.audioObjectID),
            persistence: store,
            scheduler: scheduler
        )

        XCTAssertEqual(model.policy.outputRules.map(\.uid), [dock, serialA, serialB])
        XCTAssertTrue(model.policy.outputRules[0].isExcluded)
        XCTAssertEqual(model.device(for: model.policy.outputRules[0]), livePort)
        XCTAssertTrue(model.isCurrent(model.policy.outputRules[0]))
    }

    private func device(
        _ id: AudioObjectID,
        uid: String,
        name: String = "Studio Speaker",
        direction: DeviceDirection = .output,
        transport: UInt32 = kAudioDeviceTransportTypeAirPlay
    ) -> AudioDevice {
        AudioDevice(audioObjectID: id, uid: uid, name: name, direction: direction, transportType: transport)
    }

    private func rule(
        _ uid: String,
        name: String = "Studio Speaker",
        transport: String = "AirPlay",
        excluded: Bool = false
    ) -> DeviceRule {
        DeviceRule(uid: uid, direction: .output, name: name, transportLabel: transport, isExcluded: excluded)
    }
}
