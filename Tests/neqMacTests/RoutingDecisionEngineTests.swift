import XCTest
@testable import neqMac

final class RoutingDecisionEngineTests: XCTestCase {
    func testChoosesFirstAvailableAllowedRule() {
        let rules = [
            rule("headphones"),
            rule("speakers"),
            rule("built-in")
        ]

        let result = RoutingDecisionEngine.targetUID(
            rules: rules,
            availableUIDs: ["speakers", "built-in"],
            manualOverrideUID: nil
        )

        XCTAssertEqual(result, "speakers")
    }

    func testExcludedDeviceNeverWins() {
        let rules = [
            rule("headset-mic", excluded: true),
            rule("mac-mic")
        ]

        let result = RoutingDecisionEngine.targetUID(
            rules: rules,
            availableUIDs: ["headset-mic", "mac-mic"],
            manualOverrideUID: nil
        )

        XCTAssertEqual(result, "mac-mic")
    }

    func testConnectedManualOverrideWins() {
        let rules = [rule("headphones"), rule("speakers")]

        let result = RoutingDecisionEngine.targetUID(
            rules: rules,
            availableUIDs: ["headphones", "speakers"],
            manualOverrideUID: "speakers"
        )

        XCTAssertEqual(result, "speakers")
    }

    func testUnavailableManualOverrideFallsBackToPriority() {
        let rules = [rule("headphones"), rule("speakers")]

        let result = RoutingDecisionEngine.targetUID(
            rules: rules,
            availableUIDs: ["headphones"],
            manualOverrideUID: "speakers"
        )

        XCTAssertEqual(result, "headphones")
    }

    func testExcludedManualOverrideIsIgnored() {
        let rules = [rule("headphones"), rule("speakers", excluded: true)]

        let result = RoutingDecisionEngine.targetUID(
            rules: rules,
            availableUIDs: ["headphones", "speakers"],
            manualOverrideUID: "speakers"
        )

        XCTAssertEqual(result, "headphones")
    }

    func testReturnsNilWhenEveryAvailableDeviceIsExcluded() {
        let rules = [rule("headset-mic", excluded: true)]

        let result = RoutingDecisionEngine.targetUID(
            rules: rules,
            availableUIDs: ["headset-mic"],
            manualOverrideUID: nil
        )

        XCTAssertNil(result)
    }

    private func rule(_ uid: String, excluded: Bool = false) -> DeviceRule {
        DeviceRule(
            uid: uid,
            direction: .output,
            name: uid,
            transportLabel: "Test",
            isExcluded: excluded
        )
    }
}
