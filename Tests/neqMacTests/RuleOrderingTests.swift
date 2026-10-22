import XCTest
@testable import neqMac

final class RuleOrderingTests: XCTestCase {
    func testArrangingPlacesAllowedBeforeExcluded() {
        let rules = [rule("one"), rule("two", excluded: true), rule("three"), rule("four")]

        let arranged = RuleOrdering.arranged(rules, allowed: ids("four", "one"), excluded: ids("two", "three"))

        XCTAssertEqual(arranged.map(\.uid), ["four", "one", "two", "three"])
        XCTAssertEqual(arranged.map(\.isExcluded), [false, false, true, true])
    }

    func testArrangingAllowsAPreviouslyExcludedRule() {
        let rules = [rule("one"), rule("two", excluded: true)]

        let arranged = RuleOrdering.arranged(rules, allowed: ids("two", "one"), excluded: [])

        XCTAssertEqual(arranged.map(\.uid), ["two", "one"])
        XCTAssertEqual(arranged.map(\.isExcluded), [false, false])
    }

    func testArrangingKeepsUnmentionedRulesAndIgnoresUnknownIDs() {
        let rules = [rule("one"), rule("two"), rule("three")]

        let arranged = RuleOrdering.arranged(rules, allowed: ids("three", "missing"), excluded: [])

        XCTAssertEqual(arranged.map(\.uid), ["three", "one", "two"])
    }

    func testInsertingEachDeviceInTurnSortsByConnectionType() {
        let discovered = [
            rule("speakers", transport: "Built-in"),
            rule("steam", transport: "Virtual"),
            rule("dac", transport: "USB"),
            rule("tv", transport: "AirPlay"),
            rule("monitor", transport: "DisplayPort"),
            rule("headphones", transport: "Bluetooth"),
            rule("unknown", transport: "Audio device")
        ]

        let rules = discovered.reduce(into: [DeviceRule]()) { rules, rule in
            rules.insert(rule, at: RuleOrdering.insertionIndex(for: rule, in: rules))
        }

        XCTAssertEqual(rules.map(\.uid), ["headphones", "tv", "dac", "monitor", "speakers", "unknown", "steam"])
    }

    func testNewDeviceJoinsTheEndOfItsTypeAndKeepsManualOrder() {
        let rules = [
            rule("dac", transport: "USB"),
            rule("headphones", transport: "Bluetooth"),
            rule("speakers", transport: "Built-in"),
            rule("old-headset", transport: "Bluetooth", excluded: true)
        ]

        let buds = rule("02-00-00-00-00-0B:output", transport: "Audio device")
        XCTAssertEqual(RuleOrdering.insertionIndex(for: buds, in: rules), 2)
        XCTAssertEqual(RuleOrdering.insertionIndex(for: rule("steam", transport: "Virtual"), in: rules), 3)
    }

    func testFirstPreferredDeviceGoesAboveEverythingAllowed() {
        let rules = [rule("excluded", transport: "Bluetooth", excluded: true), rule("dac", transport: "USB")]

        XCTAssertEqual(RuleOrdering.insertionIndex(for: rule("headphones", transport: "Bluetooth"), in: rules), 1)
        XCTAssertEqual(RuleOrdering.insertionIndex(for: rule("first", transport: "USB"), in: []), 0)
    }

    private func ids(_ uids: String...) -> [String] {
        uids.map { rule($0).id }
    }

    private func rule(_ uid: String, transport: String = "Test", excluded: Bool = false) -> DeviceRule {
        DeviceRule(
            uid: uid,
            direction: .output,
            name: uid,
            transportLabel: transport,
            isExcluded: excluded
        )
    }
}
