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
        let watcher = SettingsWatcher(url: file, queue: queue) { changes.signal() }
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
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: parent, to: moved)
        XCTAssertEqual(changes.wait(timeout: .now() + 3), .success)
        try Data("{}".utf8).write(to: moved.appendingPathComponent("equalizer.json"))
        XCTAssertEqual(changes.wait(timeout: .now() + 0.3), .timedOut)
        try FileManager.default.moveItem(at: moved, to: parent)
        XCTAssertEqual(changes.wait(timeout: .now() + 3), .success)
        _ = SettingsFile(at: file)
        XCTAssertEqual(changes.wait(timeout: .now() + 0.3), .timedOut)
        try FileManager.default.removeItem(at: parent)
        XCTAssertEqual(changes.wait(timeout: .now() + 3), .success)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file, options: .atomic)
        XCTAssertEqual(changes.wait(timeout: .now() + 3), .success)
        guard case .loaded = SettingsFile(at: file) else { return XCTFail() }
        withExtendedLifetime(watcher) {}
    }
}
