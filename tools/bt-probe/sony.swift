// Opens the Sony vendor RFCOMM channel read-only: sends GET commands, acknowledges
// what comes back, then listens for unsolicited state changes. It never sends a SET.

import Foundation
import IOBluetooth

let serviceUUIDBytes: [UInt8] = [0x96, 0xcc, 0x20, 0x3e, 0x50, 0x68, 0x46, 0xad,
                                 0xb3, 0x2d, 0xe3, 0x16, 0xf5, 0xe0, 0x69, 0xba]
let startMarker: UInt8 = 0x3E, endMarker: UInt8 = 0x3C, escapeMarker: UInt8 = 0x3D
let typeMDR: UInt8 = 0x0C, typeACK: UInt8 = 0x01

func escape(_ bytes: [UInt8]) -> [UInt8] {
    bytes.flatMap { $0 == startMarker || $0 == endMarker || $0 == escapeMarker
        ? [escapeMarker, $0 & 0xEF] : [$0] }
}

func unescape(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [], index = 0
    while index < bytes.count {
        if bytes[index] == escapeMarker, index + 1 < bytes.count {
            out.append(bytes[index + 1] | 0x10); index += 2
        } else { out.append(bytes[index]); index += 1 }
    }
    return out
}

func frame(type: UInt8, sequence: UInt8, payload: [UInt8]) -> [UInt8] {
    let length = UInt32(payload.count)
    var inner: [UInt8] = [type, sequence]
    inner += [UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
              UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)]
    inner += payload
    inner.append(inner.reduce(0) { UInt8(truncatingIfNeeded: Int($0) + Int($1)) })
    return [startMarker] + escape(inner) + [endMarker]
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

func stamp() -> String {
    let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

func decodeNCASM(_ p: [UInt8]) -> String? {
    guard p.count >= 8, p[0] == 0x67 || p[0] == 0x69, p[1] == 0x02 else { return nil }
    let effect = p[2], dualSingle = p[4], ambientIdentifier = p[6], ambientLevel = p[7]
    if effect == 0 { return "OFF (no noise cancelling, no ambient)" }
    if dualSingle != 0 {
        return "NOISE CANCELLING (\(dualSingle == 2 ? "dual" : "single") mic)"
    }
    return "AMBIENT SOUND level \(ambientLevel)\(ambientIdentifier == 1 ? ", voice focus" : "")"
}

func describe(_ payload: [UInt8]) -> String {
    guard let command = payload.first else { return "empty" }
    let names: [UInt8: String] = [0x66: "GET", 0x67: "RET", 0x68: "SET",
                                  0x56: "EQ GET", 0x57: "EQ RET", 0x58: "EQ SET",
                                  0x22: "BATTERY GET", 0x23: "BATTERY RET",
                                  0x00: "INIT", 0x01: "INIT RET", 0x69: "NOTIFY", 0x59: "EQ NOTIFY"]
    let name = names[command] ?? String(format: "cmd 0x%02X", command)
    let inquired = payload.count > 1 ? String(format: " type 0x%02X", payload[1]) : ""
    return "\(name)\(inquired)"
}

final class ChannelDelegate: NSObject {
    var buffer: [UInt8] = []
    var sequence: UInt8 = 0
    var channel: IOBluetoothRFCOMMChannel?

    @objc func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else { print("open failed: \(error)"); exit(1) }
        print("\(stamp())  channel open")
        channel = rfcommChannel
        var delay = 0.3
        for (label, payload) in probes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.send(label, payload) }
            delay += 1.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            print("\n\(stamp())  --- listening 30s, toggle ANC on the headphones now ---\n")
        }
        delay += 30
        for (label, payload) in lateProbes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.send(label, payload) }
            delay += 1.5
        }
    }

    func send(_ label: String, _ payload: [UInt8]) {
        print("\(stamp())  -> \(label)  [\(hex(payload))]")
        var bytes = frame(type: typeMDR, sequence: sequence, payload: payload)
        sequence = 1 - sequence
        channel?.writeSync(&bytes, length: UInt16(bytes.count))
    }

    @objc func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                 data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        buffer += Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        while let start = buffer.firstIndex(of: startMarker),
              let end = buffer[(start + 1)...].firstIndex(of: endMarker) {
            let inner = unescape(Array(buffer[(start + 1)..<end]))
            buffer.removeSubrange(...end)
            guard inner.count >= 7 else { continue }
            let type = inner[0], receivedSequence = inner[1]
            let payload = Array(inner[6..<(inner.count - 1)])
            if type == typeACK { print("\(stamp())  <- ack"); continue }
            let decoded = decodeNCASM(payload).map { "  ==> \($0)" } ?? ""
            print("\(stamp())  <- \(describe(payload))  [\(hex(payload))]\(decoded)")
            var ack = frame(type: typeACK, sequence: 1 - receivedSequence, payload: [])
            rfcommChannel.writeSync(&ack, length: UInt16(ack.count))
        }
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        print("\(stamp())  channel closed by device"); exit(0)
    }
}

let probes: [(String, [UInt8])] = [
    ("init", [0x00, 0x00]),
    ("ANC get, NCASM type 0x02", [0x66, 0x02]),
]

// Sent only after the listen window, so an unsupported command cannot close the
// channel before the interesting part.
let lateProbes: [(String, [UInt8])] = [
    ("EQ get, preset type 0x00", [0x56, 0x00]),
    ("EQ get, EBB type 0x01", [0x56, 0x01]),
    ("EQ get, non-customisable type 0x02", [0x56, 0x02]),
]

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "WH-1000XM4"
guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
      let device = devices.first(where: { ($0.name ?? "").contains(wanted) }) else {
    print("no paired device matching \(wanted)"); exit(1)
}
guard device.isConnected() else { print("\(wanted) is not connected"); exit(1) }

let uuid = IOBluetoothSDPUUID(bytes: serviceUUIDBytes, length: 16)
guard let record = device.getServiceRecord(for: uuid) else {
    print("no service record for the Sony UUID"); exit(1)
}
var channelID: BluetoothRFCOMMChannelID = 0
guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
    print("service record has no rfcomm channel"); exit(1)
}
print("\(stamp())  \(device.name ?? "?") -> rfcomm channel \(channelID)")

let delegate = ChannelDelegate()
var channel: IOBluetoothRFCOMMChannel?
let status = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: delegate)
guard status == kIOReturnSuccess else { print("openRFCOMMChannelAsync failed: \(status)"); exit(1) }

DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("\n\(stamp())  done"); exit(0) }
RunLoop.current.run()
