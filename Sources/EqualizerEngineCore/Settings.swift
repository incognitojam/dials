import EqualizerCore
import Foundation
import RoutingCore

package struct EqualizerSettings: Codable, Equatable {
    package let enabled: Bool
    package let assignments: [Assignment]

    enum CodingKeys: CodingKey { case enabled, assignments }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.contains(.enabled) && c.decode(Bool.self, forKey: .enabled)
        assignments = try c.contains(.assignments) ? c.decode([Assignment].self, forKey: .assignments) : []
    }

    package struct Assignment: Codable, Equatable {
        let uid: String
        let name: String
        let transport: String
        let enabled: Bool
        enum Choice: String, Codable { case profile, none }
        let choice: Choice
        let profile: EQInfo?

        enum CodingKeys: CodingKey { case uid, name, transport, enabled, choice, profile }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uid = try c.decode(String.self, forKey: .uid)
            guard !uid.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .uid, in: c, debugDescription: "Empty device UID")
            }
            name = try c.contains(.name) ? c.decode(String.self, forKey: .name) : ""
            transport = try c.contains(.transport) ? c.decode(String.self, forKey: .transport) : ""
            enabled = try c.contains(.enabled) && c.decode(Bool.self, forKey: .enabled)
            choice = try c.decode(Choice.self, forKey: .choice)
            if choice == .none && c.contains(.profile) {
                throw DecodingError.dataCorruptedError(forKey: .profile, in: c, debugDescription: "Unexpected profile for none")
            }
            profile = choice == .profile ? try c.decode(EQInfo.self, forKey: .profile) : nil
        }

        func matches(_ device: any RoutingDevice) -> Bool {
            DeviceRule(uid: uid, direction: .output, name: name, transportLabel: transport, isExcluded: false).matches(device)
        }
    }
}

package enum SettingsFile: Equatable {
    case absent, loaded(EqualizerSettings), invalid(String)

    package init(at url: URL) {
        do {
            self = .loaded(try JSONDecoder().decode(EqualizerSettings.self, from: Data(contentsOf: url)))
        } catch CocoaError.fileReadNoSuchFile {
            self = .absent
        } catch {
            self = .invalid(String(describing: error))
        }
    }
}

package enum DesiredEqualizer {
    case off, suspended(String), process(EQInfo, EqualizerPlan)

    package static func eligible(_ device: any RoutingDevice) -> Bool {
        device.direction == .output && device.transportLabel == "USB"
    }

    package static func resolve(_ file: SettingsFile, device: (any RoutingDevice)?, rate: Double?) -> Self {
        if case let .invalid(reason) = file { return .suspended("Invalid equalizer settings: " + reason) }
        guard case let .loaded(settings) = file, settings.enabled, let device,
              let assignment = settings.assignments.first(where: { $0.matches(device) }),
              assignment.enabled, let profile = assignment.profile else { return .off }
        guard eligible(device) else { return .suspended("Unsupported output transport") }
        guard let rate, rate.isFinite else { return .suspended("Output format unavailable") }
        guard rate >= 32_000 else { return .suspended("Output rate below 32 kHz") }
        do { return .process(profile, try EqualizerPlan(profile.parameters, sampleRate: rate)) }
        catch { return .suspended("Invalid equalizer plan: " + String(describing: error)) }
    }
}
