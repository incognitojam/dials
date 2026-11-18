import Foundation
import RoutingCore
import XCTest
@testable import EqualizerEngineCore

final class SettingsTests: XCTestCase {
    struct Device: RoutingDevice {
        var uid = "AppleUSBAudioEngine:Example:DAC:2000:1"
        var name = "Test DAC"
        var direction = DeviceDirection.output
        var transportLabel = "USB"
    }

    let assignment = #"{"uid":"AppleUSBAudioEngine:Example:DAC:1000:1","enabled":true,"choice":"profile","profile":{"author":"Example","type":"parametric_eq","parameters":{"gain_db":-6,"bands":[]}}}"#

    func testSettingsAndResolver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("equalizer.json")
        XCTAssertEqual(SettingsFile(at: url), .absent)
        func read(_ json: String) throws -> SettingsFile {
            try Data(json.utf8).write(to: url)
            return SettingsFile(at: url)
        }
        let valid = try read(#"{"enabled":true,"future":1,"assignments":["# + assignment + "]}")
        guard case let .loaded(settings) = valid else { return XCTFail() }
        XCTAssertEqual(try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(settings)), settings)
        guard case let .process(_, plan) = DesiredEqualizer.resolve(valid, device: Device(), rate: 32_000) else { return XCTFail() }
        XCTAssertEqual(plan.sampleRate, 32_000)
        for label in ["Bluetooth","Built-in","AirPlay","HDMI","DisplayPort","Virtual","Aggregate","Audio device"] {
            let device = Device(transportLabel: label)
            XCTAssertFalse(DesiredEqualizer.eligible(device))
            guard case .suspended = DesiredEqualizer.resolve(valid, device: device, rate: 48_000) else { return XCTFail(label) }
        }
        XCTAssertFalse(DesiredEqualizer.eligible(Device(direction: .input)))
        for rate: Double? in [nil, 31_999] {
            guard case .suspended = DesiredEqualizer.resolve(valid, device: Device(), rate: rate) else { return XCTFail() }
        }
        for json in ["{", #"{"enabled":null}"#, #"{"assignments":[{}]}"#, #"{"assignments":[{"uid":"test","choice":"profile"}]}"#] {
            guard case .invalid = try read(json) else { return XCTFail(json) }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), json)
        }
        for json in ["{}", #"{"enabled":true}"#, #"{"assignments":["# + assignment + "]}",
                     #"{"enabled":true,"assignments":["# + assignment.replacingOccurrences(of: #""enabled":true,"#, with: "") + "]}",
                     #"{"enabled":true,"assignments":[{"uid":"AppleUSBAudioEngine:Example:DAC:2000:1","choice":"none","enabled":true}]}"#] {
            guard case .off = DesiredEqualizer.resolve(try read(json), device: Device(), rate: 48_000) else { return XCTFail(json) }
        }
    }
}
