import CoreAudio
import Foundation

enum DeviceDirection: String, Codable, CaseIterable, Sendable {
    case input
    case output

    var title: String {
        switch self {
        case .input: "Input"
        case .output: "Output"
        }
    }

    var systemImage: String {
        switch self {
        case .input: "mic.fill"
        case .output: "speaker.wave.2.fill"
        }
    }
}

struct AudioDevice: Identifiable, Equatable, Sendable {
    static let unknownName = "Unknown device"

    let audioObjectID: AudioObjectID
    let uid: String
    let name: String
    let direction: DeviceDirection
    let transportType: UInt32

    var id: String { "\(direction.rawValue):\(uid)" }

    var transportLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        default: "Audio device"
        }
    }
}

struct DeviceRule: Identifiable, Codable, Equatable, Sendable {
    let uid: String
    let direction: DeviceDirection
    var name: String
    var transportLabel: String
    var isExcluded: Bool

    var id: String { "\(direction.rawValue):\(uid)" }

    var airPlayName: String? {
        guard transportLabel == "AirPlay", name != AudioDevice.unknownName, !name.isEmpty else {
            return nil
        }
        return name
    }

    /// Older builds saved "Audio device" when Core Audio reported no transport.
    /// Most of those UIDs still say how the device is attached.
    var displayTransport: String {
        guard transportLabel == "Audio device" else { return transportLabel }
        if uid.hasPrefix("AppleUSBAudioEngine:") { return "USB" }
        if uid.hasPrefix("BuiltIn") { return "Built-in" }
        if uid.range(of: #"^(?:[0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}:(?:input|output)$"#, options: .regularExpression) != nil {
            return "Bluetooth"
        }
        return transportLabel
    }

    /// Rules that describe the same device and should collapse into one.
    var mergeKey: String? {
        airPlayName.map { "AirPlay:\($0)" } ?? Self.portlessUSBKey(for: uid)
    }

    /// USB audio UIDs end in `serial:interface`. A device without a serial
    /// number gets its USB location ID there instead, so each port it is
    /// plugged into produces a new UID. Location IDs are short hex numbers
    /// that end in zero; dropping them leaves manufacturer, product and interface.
    static func portlessUSBKey(for uid: String) -> String? {
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[0] == "AppleUSBAudioEngine",
              parts[parts.count - 2].range(of: #"^[0-9A-Fa-f]{1,7}0$"#, options: .regularExpression) != nil
        else { return nil }
        return (parts.dropLast(2) + [parts[parts.count - 1]]).joined(separator: ":")
    }

    func matches(_ device: AudioDevice) -> Bool {
        guard direction == device.direction else { return false }
        if uid == device.uid { return true }
        if let key = Self.portlessUSBKey(for: uid), key == Self.portlessUSBKey(for: device.uid) { return true }
        return device.transportType == kAudioDeviceTransportTypeAirPlay && airPlayName == device.name
    }
}

struct RoutingEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let message: String
    let level: Level

    enum Level: String, Sendable {
        case info
        case success
        case warning
    }
}
