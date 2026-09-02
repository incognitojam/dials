import XCTest
@testable import neqMac

final class RuleOrderingTests: XCTestCase {
    func testMovingRuleToFirstPreservesOtherRulesOrder() {
        let rules = [rule("one"), rule("two"), rule("three"), rule("four")]

        let reordered = RuleOrdering.moving(rules[2].id, to: .first, in: rules)

        XCTAssertEqual(reordered.map(\.uid), ["three", "one", "two", "four"])
    }

    func testMovingRuleToLastPreservesOtherRulesOrder() {
        let rules = [rule("one"), rule("two"), rule("three"), rule("four")]

        let reordered = RuleOrdering.moving(rules[1].id, to: .last, in: rules)

        XCTAssertEqual(reordered.map(\.uid), ["one", "three", "four", "two"])
    }

    func testUnknownRuleLeavesOrderUnchanged() {
        let rules = [rule("one"), rule("two")]

        XCTAssertEqual(RuleOrdering.moving("missing", to: .first, in: rules), rules)
    }

    private func rule(_ uid: String) -> DeviceRule {
        DeviceRule(
            uid: uid,
            direction: .output,
            name: uid,
            transportLabel: "Test",
            isExcluded: false
        )
    }
}
