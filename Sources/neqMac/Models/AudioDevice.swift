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

    func matches(_ device: AudioDevice) -> Bool {
        guard direction == device.direction else { return false }
        if uid == device.uid { return true }
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
