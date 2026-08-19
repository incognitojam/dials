import XCTest
@testable import neqMac

final class PolicyPersistenceTests: XCTestCase {
    func testPolicyRoundTripsThroughUserDefaults() throws {
        let suiteName = "dev.neqmac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPolicyStore(defaults: defaults)
        let expected = PersistedPolicy(
            automationEnabled: true,
            includeSystemSounds: false,
            inputRules: [rule("safe-mic", direction: .input, excluded: false)],
            outputRules: [rule("headphones", direction: .output, excluded: true)]
        )

        store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    func testMissingPolicyUsesSafeDefaults() throws {
        let suiteName = "dev.neqmac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let result = UserDefaultsPolicyStore(defaults: defaults).load()

        XCTAssertFalse(result.automationEnabled)
        XCTAssertTrue(result.includeSystemSounds)
        XCTAssertTrue(result.inputRules.isEmpty)
        XCTAssertTrue(result.outputRules.isEmpty)
    }

    private func rule(
        _ uid: String,
        direction: DeviceDirection,
        excluded: Bool
    ) -> DeviceRule {
        DeviceRule(
            uid: uid,
            direction: direction,
            name: uid,
            transportLabel: "Test",
            isExcluded: excluded
        )
    }
}
