// Opens the Samsung vendor RFCOMM channel read-only and parses what the earbuds send.
// It writes nothing at all by default, so it cannot change a setting: Galaxy Buds push
// their state unprompted, which is the behaviour worth measuring.

import Foundation
import IOBluetooth

let sppStandardUUID: [UInt8] = [0x00, 0x00, 0x11, 0x01, 0x00, 0x00, 0x10, 0x00,
                                0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb]
let startOfMessage: UInt8 = 0xFD, endOfMessage: UInt8 = 0xDD

let crcTable: [UInt16] = {
    (0..<256).map { index -> UInt16 in
        var value = UInt16(index) << 8
        for _ in 0..<8 { value = (value & 0x8000) != 0 ? (value << 1) ^ 0x1021 : value << 1 }
        return value
    }
}()

func crc16(_ bytes: [UInt8]) -> UInt16 {
    bytes.reduce(UInt16(0)) { crcTable[Int(($0 >> 8) ^ UInt16($1))] ^ ($0 << 8) }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

func stamp() -> String {
    let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

let messageNames: [UInt8: String] = [
    46: "UNKNOWN_46", 47: "UNKNOWN_47", 99: "VERSION_INFO", 116: "UNKNOWN_116",
    156: "VOICE_WAKE_UP_LISTENING_STATUS", 242: "DEBUG_EVENT",
    96: "STATUS_UPDATED", 97: "EXTENDED_STATUS_UPDATED", 98: "RESET",
    119: "NOISE_CONTROLS_UPDATE", 120: "NOISE_CONTROLS", 128: "SET_AMBIENT_MODE",
    129: "AMBIENT_MODE_UPDATED", 131: "NOISE_REDUCTION_LEVEL", 134: "EQUALIZER",
    152: "SET_NOISE_REDUCTION", 155: "NOISE_REDUCTION_MODE_UPDATE",
    163: "MUTE_EARBUD_STATUS_UPDATED",
]

let equalizerPresets = ["bass boost", "soft", "dynamic", "clear", "treble boost"]
let placements = ["disconnected", "wearing", "idle", "in case"]
// Buds Live touchpad assignments; 2 is the noise-control toggle this probe relies on.
let touchOptions = ["voice command", "ambient", "noise controls", "volume", "spotify"]

func name(_ table: [String], _ value: UInt8) -> String {
    Int(value) < table.count ? table[Int(value)] : "\(value)"
}

func describeEqualizer(_ mode: UInt8) -> String {
    guard mode != 0 else { return "off" }
    let preset = Int(mode) - 1
    return "on, \(preset < equalizerPresets.count ? equalizerPresets[preset] : "preset \(preset)")"
}

// Field offsets are the Buds Live layout: every model after Buds+ shifts these around,
// so this decode is deliberately not generic.
func decodeExtendedStatus(_ p: [UInt8]) -> [String] {
    guard p.count >= 14 else { return ["payload too short: \(p.count) bytes"] }
    var lines = [
        "revision \(p[0]), ear type \(p[1])",
        "battery L \(p[2])%  R \(p[3])%  case \(p[7])%",
        "placement L \(name(placements, p[6] >> 4))  R \(name(placements, p[6] & 0x0F)), coupled \(p[4] == 1)",
        "equalizer: \(describeEqualizer(p[9]))",
        "noise cancelling: \(p[12] == 1 ? "ON" : "off")",
        "touch and hold L \(name(touchOptions, (p[11] & 0xF0) >> 4))  R \(name(touchOptions, p[11] & 0x0F))",
        "touchpad lock \(p[10] == 1), adjust sound sync \(p[8] == 1)",
    ]
    if p.count > 21, p[0] >= 5 { lines.append("relieve ambient \(p[21] == 1)") }
    return lines
}

func decode(id: UInt8, payload p: [UInt8]) -> [String] {
    switch id {
    case 97: return decodeExtendedStatus(p)
    case 96 where p.count >= 7:
        return ["battery L \(p[1])%  R \(p[2])%  case \(p[6])%",
                "placement L \(name(placements, p[5] >> 4))  R \(name(placements, p[5] & 0x0F))"]
    case 155 where !p.isEmpty: return ["noise cancelling: \(p[0] == 1 ? "ON" : "off")"]
    case 134 where !p.isEmpty: return ["equalizer: \(describeEqualizer(p[0]))"]
    default: return []
    }
}

final class ChannelDelegate: NSObject {
    var buffer: [UInt8] = []

    @objc func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else { print("open failed: \(error)"); exit(1) }
        print("\(stamp())  channel open, listening only\n")
    }

    @objc func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!,
                                 data pointer: UnsafeMutableRawPointer!, length: Int) {
        buffer += Array(UnsafeRawBufferPointer(start: pointer, count: length))
        while let start = buffer.firstIndex(of: startOfMessage) {
            buffer.removeSubrange(..<start)
            guard buffer.count >= 6 else { return }
            let size = Int(UInt16(buffer[1]) | UInt16(buffer[2]) << 8) & 0x3FF
            let total = 3 + size + 1
            guard size >= 3, buffer.count >= total else { return }
            guard buffer[total - 1] == endOfMessage else { buffer.removeFirst(); continue }

            let id = buffer[3]
            let payload = Array(buffer[4..<(total - 3)])
            // The two checksum bytes are swapped before the frame is verified, and a
            // correct frame checksums to zero.
            let checked = [id] + payload + [buffer[total - 2], buffer[total - 3]]
            let name = messageNames[id] ?? "id \(id)"
            let valid = crc16(checked) == 0 ? "" : "  [BAD CRC]"
            print("\(stamp())  <- \(name)\(valid)  \(payload.count) bytes  [\(hex(payload))]")
            for line in decode(id: id, payload: payload) { print("                 ==> \(line)") }
            buffer.removeFirst(total)
        }
    }

    @objc func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        print("\(stamp())  channel closed by device"); exit(0)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Galaxy Buds"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 60 : 60

guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
      let device = devices.first(where: { ($0.name ?? "").contains(wanted) }) else {
    print("no paired device matching \(wanted)"); exit(1)
}
guard device.isConnected() else { print("\(wanted) is not connected"); exit(1) }

let uuid = IOBluetoothSDPUUID(bytes: sppStandardUUID, length: 16)
guard let record = device.getServiceRecord(for: uuid) else {
    print("no service record for the standard SPP UUID"); exit(1)
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

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { print("\n\(stamp())  done"); exit(0) }
RunLoop.current.run()
