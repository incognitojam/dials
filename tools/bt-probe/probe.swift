// Read-only look at what paired Bluetooth devices advertise over SDP.
// Without --query it only reads records macOS already cached at pairing time,
// so it neither connects to nor writes anything to a device.

import Foundation
import IOBluetooth

let forceQuery = CommandLine.arguments.contains("--query")

func uuidStrings(_ record: IOBluetoothSDPServiceRecord) -> [String] {
    guard let list = record.getAttributeDataElement(1) else { return [] }
    var found: [String] = []

    func walk(_ element: IOBluetoothSDPDataElement) {
        if let uuid = element.getUUIDValue() {
            let data = uuid as NSData
            var bytes = [UInt8](repeating: 0, count: data.length)
            data.getBytes(&bytes, length: data.length)
            if bytes.count == 2 {
                found.append(String(format: "0x%02X%02X", bytes[0], bytes[1]))
            } else if bytes.count == 16 {
                let hex = bytes.map { String(format: "%02X", $0) }.joined()
                let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                             hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
                found.append(parts.map(String.init).joined(separator: "-"))
            } else {
                found.append(bytes.map { String(format: "%02X", $0) }.joined())
            }
            return
        }
        if let array = element.getArrayValue() as? [IOBluetoothSDPDataElement] {
            array.forEach(walk)
        }
    }

    walk(list)
    return found
}

guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice], !devices.isEmpty else {
    print("No paired devices visible. If this is a fresh binary, Bluetooth access may be refused.")
    exit(1)
}

for device in devices {
    let name = device.name ?? "?"
    print("\(name)  [\(device.isConnected() ? "connected" : "not connected")]")

    if forceQuery {
        let status = device.performSDPQuery(nil)
        if status != kIOReturnSuccess { print("  sdp query failed: \(status)") }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
    }

    guard let services = device.services as? [IOBluetoothSDPServiceRecord], !services.isEmpty else {
        print("  no cached service records\n")
        continue
    }

    for record in services {
        var channel: BluetoothRFCOMMChannelID = 0
        let hasChannel = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
        let serviceName = record.getServiceName() ?? "(unnamed)"
        let uuids = uuidStrings(record)
        let channelText = hasChannel ? "rfcomm \(channel)" : "no rfcomm"
        print("  \(serviceName.padding(toLength: max(28, serviceName.count), withPad: " ", startingAt: 0)) \(channelText)")
        for uuid in uuids { print("      \(uuid)") }
    }
    print("")
}
