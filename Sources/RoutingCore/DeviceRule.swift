import Foundation

package enum DeviceDirection: String, Codable, CaseIterable, Sendable {
    case input
    case output
}

package let unknownDeviceName = "Unknown device"

package protocol RoutingDevice {
    var uid: String { get }
    var direction: DeviceDirection { get }
    var name: String { get set }
    var transportLabel: String { get }
}

package struct DeviceRule: Identifiable, Codable, Equatable, Sendable {
    package let uid: String
    package let direction: DeviceDirection
    package var name: String
    package var transportLabel: String
    package var isExcluded: Bool

    package init(uid: String, direction: DeviceDirection, name: String, transportLabel: String, isExcluded: Bool) {
        self.uid = uid
        self.direction = direction
        self.name = name
        self.transportLabel = transportLabel
        self.isExcluded = isExcluded
    }

    package var id: String { "\(direction.rawValue):\(uid)" }

    var airPlayName: String? {
        guard transportLabel == "AirPlay", name != unknownDeviceName, !name.isEmpty else {
            return nil
        }
        return name
    }

    /// Older builds saved "Audio device" when Core Audio reported no transport.
    /// Most of those UIDs still say how the device is attached.
    package var displayTransport: String {
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

    package func matches(_ device: any RoutingDevice) -> Bool {
        guard direction == device.direction else { return false }
        if uid == device.uid { return true }
        if let key = Self.portlessUSBKey(for: uid), key == Self.portlessUSBKey(for: device.uid) { return true }
        return device.transportLabel == "AirPlay" && airPlayName == device.name
    }
}
