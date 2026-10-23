import XCTest
@testable import neqMac

final class DeviceRuleTests: XCTestCase {
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

    func testPortlessUSBKeyIgnoresUIDsThatCarryASerial() {
        XCTAssertNil(DeviceRule.portlessUSBKey(for: "AppleUSBAudioEngine:Google:Adapter:SERIAL0C:2"))
        XCTAssertNil(DeviceRule.portlessUSBKey(for: "BuiltInSpeakerDevice"))
    }

    private func rule(_ uid: String, transport: String) -> DeviceRule {
        DeviceRule(uid: uid, direction: .output, name: "Test Device", transportLabel: transport, isExcluded: false)
    }
}
