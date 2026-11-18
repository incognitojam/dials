import Foundation
import XCTest
import EqualizerEngineCore
@testable import neqMac

final class SettingsWatcherTests: XCTestCase {
    func testCreateEditReplaceRemove() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("neqMac")
        let file = parent.appendingPathComponent("equalizer.json")
        let queue = DispatchQueue(label: "test.settings.watch")
        let changes = DispatchSemaphore(value: 0)
        let watcher = SettingsWatcher(url: file, queue: queue) { _ in changes.signal() }
        queue.sync { watcher.arm() }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(changes.wait(timeout: .now() + 3), .success)
        for (value, atomic) in [("{}", false), ("{", false), (#"{"enabled":true}"#, true)] {
            try Data(value.utf8).write(to: file, options: atomic ? .atomic : [])
            XCTAssertEqual(changes.wait(timeout: .now() + 3), .success)
            let snapshot = SettingsFile(at: file)
            if value == "{" {
                guard case .invalid = snapshot else { return XCTFail() }
            } else {
                guard case .loaded = snapshot else { return XCTFail() }
            }
        }
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(changes.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(SettingsFile(at: file), .absent)
        withExtendedLifetime(watcher) {}
    }
}
