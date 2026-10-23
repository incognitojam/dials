import CoreAudio
import XCTest
@testable import neqMac

final class RuleMergingTests: XCTestCase {
    private let unknown = AudioDevice.unknownName

    func testMergeCollapsesDuplicatesAndKeepsAnyExclusion() {
        let existing = [
            rule("first", name: "Kitchen", transport: "AirPlay"),
            rule("usb", transport: "USB"),
            rule("second", name: "Kitchen", transport: "AirPlay", excluded: true)
        ]

        let merged = RuleMerging.merged(existing: existing, discovered: [])

        XCTAssertEqual(merged.map(\.uid), ["first", "usb"])
        XCTAssertEqual(merged.map(\.isExcluded), [true, false])
    }

    func testDeduplicationKeepsDirectionsApart() {
        let rules = [
            rule("speaker", name: "Kitchen", transport: "AirPlay"),
            rule("mic", name: "Kitchen", direction: .input, transport: "AirPlay")
        ]

        XCTAssertEqual(RuleMerging.deduplicated(rules), rules)
    }

    func testMergeUpdatesKnownRulesWithoutLosingTheirNames() {
        let existing = [rule("dac", name: "Desk DAC", transport: "Audio device")]
        let discovered = [device("dac", name: unknown, transport: kAudioDeviceTransportTypeUSB)]

        let merged = RuleMerging.merged(existing: existing, discovered: discovered)

        XCTAssertEqual(merged.map(\.name), ["Desk DAC"])
        XCTAssertEqual(merged.map(\.transportLabel), ["USB"])
    }

    func testMergeInsertsNewDevicesByTransport() {
        let existing = [
            rule("headphones", transport: "Bluetooth"),
            rule("speakers", transport: "Built-in")
        ]
        let discovered = [device("dac", transport: kAudioDeviceTransportTypeUSB)]

        let merged = RuleMerging.merged(existing: existing, discovered: discovered)

        XCTAssertEqual(merged.map(\.uid), ["headphones", "dac", "speakers"])
        XCTAssertEqual(merged[1].isExcluded, false)
    }

    func testRestoringKnownNamesOnlyFillsUnknownNames() {
        let rules = [rule("dac", name: "Desk DAC"), rule("02-00-00-00-00-0A:output", name: "Test Headphones")]
        let discovered = [
            device("dac", name: unknown),
            device("02-00-00-00-00-0A:input", name: unknown, direction: .input),
            device("speakers", name: "Built-in Speakers"),
            device("new", name: unknown)
        ]

        let restored = RuleMerging.restoringKnownNames(in: discovered, from: rules)

        XCTAssertEqual(restored.map(\.name), ["Desk DAC", "Test Headphones", "Built-in Speakers", unknown])
    }

    private func rule(
        _ uid: String,
        name: String = "Test Device",
        direction: DeviceDirection = .output,
        transport: String = "Audio device",
        excluded: Bool = false
    ) -> DeviceRule {
        DeviceRule(uid: uid, direction: direction, name: name, transportLabel: transport, isExcluded: excluded)
    }

    private func device(
        _ uid: String,
        name: String = "Test Device",
        direction: DeviceDirection = .output,
        transport: UInt32 = kAudioDeviceTransportTypeUnknown
    ) -> AudioDevice {
        AudioDevice(audioObjectID: 1, uid: uid, name: name, direction: direction, transportType: transport)
    }
}
