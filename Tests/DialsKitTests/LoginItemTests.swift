import ServiceManagement
import XCTest
@testable import DialsKit

final class LoginItemTests: XCTestCase {
    func testEveryStatusExplainsItself() {
        let statuses: [SMAppService.Status] = [.enabled, .requiresApproval, .notRegistered, .notFound]
        for status in statuses {
            XCTAssertFalse(LoginItem.explanation(for: status).isEmpty)
        }
    }

    func testApprovalAndMissingBundleAreNotDescribedAsOn() {
        XCTAssertNotEqual(
            LoginItem.explanation(for: .requiresApproval),
            LoginItem.explanation(for: .enabled)
        )
        XCTAssertNotEqual(
            LoginItem.explanation(for: .notFound),
            LoginItem.explanation(for: .notRegistered)
        )
    }
}
