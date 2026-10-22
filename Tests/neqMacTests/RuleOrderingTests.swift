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
