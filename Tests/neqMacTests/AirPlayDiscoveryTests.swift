import CoreAudio
import XCTest
@testable import neqMac

@MainActor
final class AirPlayDiscoveryTests: XCTestCase {
    func testMigrationSelectionAndReconnectPreserveOneAirPlayRule() throws {
        let unrecognizedLegacyUID = "02:00:00:00:00:01-session-legacy"
        let legacyUID = "02:00:00:00:00:01-session-airplay"
        let genericUID = "00000000-0000-0000-0000-000000000001-Audio"
        let mirroringUID = "02:00:00:00:00:02-session-1-screen"
        let otherTVUID = "02:00:00:00:00:03-session-1-screen"
        let expectedUIDs = ["usb", unrecognizedLegacyUID, "other-room", genericUID, mirroringUID, otherTVUID]
        let receiver = device(1, uid: "live-receiver")
        let usb = device(2, uid: "usb", transport: kAudioDeviceTransportTypeUSB)
        let microphone = device(3, uid: "microphone", direction: .input)
        let store = MemoryPolicyStore(PersistedPolicy(outputRules: [
            rule("usb", transport: "Audio device"),
            rule(unrecognizedLegacyUID, transport: "Audio device"),
            rule(legacyUID, transport: "Audio device"),
            rule("other-room", name: "Meeting Room"),
            rule("duplicate-receiver", excluded: true),
            rule(genericUID, name: "AirPlay", transport: "Audio device"),
            rule("00000000-0000-0000-0000-000000000002-Audio", name: "AirPlay", transport: "Audio device"),
            rule(mirroringUID, name: "Living Room TV", transport: "Audio device"),
            rule("02:00:00:00:00:02-session-2-screen", name: "Living Room TV", transport: "Audio device"),
            rule(otherTVUID, name: "Guest Room TV", transport: "Audio device")
        ]))
        let client = TestAudioClient(devices: [receiver, usb, microphone], outputID: usb.audioObjectID)
        let model = AppModel(audioClient: client, persistence: store)

        XCTAssertEqual(model.policy.outputRules.map(\.uid), expectedUIDs)
        XCTAssertEqual(model.policy.inputRules.map(\.uid), ["microphone"])
        XCTAssertTrue(model.policy.outputRules[1].isExcluded)
        XCTAssertEqual(model.policy.outputRules[1].transportLabel, "AirPlay")
        XCTAssertEqual(model.policy.outputRules[0].transportLabel, "USB")
        XCTAssertEqual(model.policy.outputRules.suffix(2).map(\.transportLabel), ["AirPlay", "AirPlay"])
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
            XCTAssertEqual(model.manualOutputOverrideUID, unrecognizedLegacyUID)
            XCTAssertEqual(model.events, initialEvents)
        }

        client.availableDevices = [usb, microphone]
        client.outputID = usb.audioObjectID
        model.refreshHardwareState()
        XCTAssertNil(model.manualOutputOverrideUID)
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
        model.useNow(model.policy.outputRules[4])

        XCTAssertEqual(model.policy.outputRules.map(\.uid), expectedUIDs)
        XCTAssertEqual(client.selections.last, television)
        XCTAssertTrue(model.isCurrent(model.policy.outputRules[4]))
        XCTAssertEqual(store.savedPolicy, model.policy)
    }

    func testAutomaticRoutingHonorsExclusionAndFallsBackOnDisconnect() async {
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
        let model = AppModel(audioClient: client, persistence: store)
        let selectedUSB = expectation(description: "Skip excluded AirPlay and select USB")
        client.onSelection = { selectedUSB.fulfill() }
        model.setAutomationEnabled(true)
        await fulfillment(of: [selectedUSB], timeout: 2)
        XCTAssertEqual(client.selections, [usb])

        let selectedFallback = expectation(description: "Fall back to built-in speakers when USB disconnects")
        client.onSelection = { selectedFallback.fulfill() }
        client.availableDevices = [receiver, speakers]
        client.outputID = kAudioObjectUnknown
        client.onHardwareChange?()
        await fulfillment(of: [selectedFallback], timeout: 2)
        XCTAssertEqual(client.selections.last, speakers)

        let selectedAirPlay = expectation(description: "Resolve the saved AirPlay UID after allowing the receiver")
        client.onSelection = { selectedAirPlay.fulfill() }
        model.setExcluded(false, ruleID: model.policy.outputRules[0].id)
        await fulfillment(of: [selectedAirPlay], timeout: 2)

        XCTAssertEqual(client.selections, [usb, speakers, receiver])
        XCTAssertEqual(model.policy.outputRules.map(\.uid), ["saved-receiver", "usb", "speakers"])
        XCTAssertEqual(model.defaultOutputID, receiver.audioObjectID)
        XCTAssertTrue(model.isCurrent(model.policy.outputRules[0]))
        XCTAssertNil(model.lastError)
    }

    func testCoreAudioDiscoveryReadsLiveTransportMetadata() throws {
        let devices = try CoreAudioClient().devices()
        var checkedDevices = 0
        for device in devices {
            var transport: UInt32 = kAudioDeviceTransportTypeUnknown
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(device.audioObjectID, &address, 0, nil, &size, &transport)
            guard status == noErr, transport != kAudioDeviceTransportTypeUnknown else { continue }
            checkedDevices += 1
            XCTAssertEqual(device.transportType, transport)
        }
        try XCTSkipIf(checkedDevices == 0, "No audio devices with readable transport metadata are available")
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
            persistence: store
        )

        model.removeRules(direction: .output, ids: Set(model.policy.outputRules.map(\.id)))

        XCTAssertEqual(model.policy.outputRules.map(\.uid), ["usb"])
        XCTAssertEqual(store.savedPolicy, model.policy)
    }

    func testDisplayTransportRecoversGenericLabelsFromUID() {
        let labels = [
            "AppleUSBAudioEngine:Vendor:DAC:1100000:1",
            "BuiltInHeadphoneOutputDevice",
            "02-00-00-00-00-0A:output",
            "02-00-00-00-00-0A:input",
            "00000000-0000-0000-0000-000000000003"
        ].map { rule($0, transport: "Audio device").displayTransport }

        XCTAssertEqual(labels, ["USB", "Built-in", "Bluetooth", "Bluetooth", "Audio device"])
        XCTAssertEqual(rule("AppleUSBAudioEngine:Vendor:DAC:1:1", transport: "HDMI").displayTransport, "HDMI")
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

private final class MemoryPolicyStore: PolicyPersisting {
    private let initialPolicy: PersistedPolicy
    private(set) var savedPolicy: PersistedPolicy?

    init(_ policy: PersistedPolicy = PersistedPolicy()) {
        initialPolicy = policy
    }

    func load() -> PersistedPolicy { initialPolicy }
    func save(_ policy: PersistedPolicy) { savedPolicy = policy }
}

private final class TestAudioClient: AudioDeviceClient {
    var onHardwareChange: (() -> Void)?
    var onSelection: (() -> Void)?
    var availableDevices: [AudioDevice]
    var outputID: AudioObjectID
    private(set) var selections: [AudioDevice] = []

    init(devices: [AudioDevice] = [], outputID: AudioObjectID = kAudioObjectUnknown) {
        availableDevices = devices
        self.outputID = outputID
    }

    func devices() throws -> [AudioDevice] { availableDevices }
    func defaultDeviceID(for direction: DeviceDirection) throws -> AudioObjectID {
        direction == .output ? outputID : kAudioObjectUnknown
    }
    func defaultSystemOutputDeviceID() throws -> AudioObjectID { outputID }
    func setDefaultDevice(_ device: AudioDevice, includeSystemSounds: Bool) throws {
        selections.append(device)
        if device.direction == .output { outputID = device.audioObjectID }
        onSelection?()
    }
}
