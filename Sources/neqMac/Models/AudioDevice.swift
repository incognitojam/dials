import CoreAudio
import Foundation
import RoutingCore

extension DeviceDirection {
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

struct AudioDevice: RoutingDevice, Identifiable, Equatable, Sendable {
    let audioObjectID: AudioObjectID
    let uid: String
    var name: String
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
