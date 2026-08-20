// Prints every audio device with the properties the tap rig needs: the UID to
// address it by, its rate and buffer size, and the latency it declares.

import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
              default fallback: T) -> T? {
    var property = address(selector, scope, element)
    var size = UInt32(MemoryLayout<T>.size)
    var result = fallback
    let status = withUnsafeMutablePointer(to: &result) {
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
    }
    return status == noErr ? result : nil
}

func stringValue(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var result: CFString?
    let status = withUnsafeMutablePointer(to: &result) {
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
    }
    guard status == noErr, let result else { return nil }
    return result as String
}

func channels(_ object: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var property = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func fourCharacterCode(_ code: UInt32) -> String {
    var bigEndian = code.bigEndian
    return withUnsafeBytes(of: &bigEndian) { String(bytes: $0, encoding: .ascii) ?? "?" }
        .trimmingCharacters(in: .whitespaces)
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)
let defaultOutput = value(systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0)) ?? 0
let defaultInput = value(systemObject, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0)) ?? 0

var property = address(kAudioHardwarePropertyDevices)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(systemObject, &property, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(systemObject, &property, 0, nil, &size, &ids)

for id in ids {
    let inputChannels = channels(id, kAudioObjectPropertyScopeInput)
    let outputChannels = channels(id, kAudioObjectPropertyScopeOutput)
    let scope = outputChannels > 0 ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput

    var markers: [String] = []
    if id == defaultOutput { markers.append("default output") }
    if id == defaultInput { markers.append("default input") }
    let marker = markers.isEmpty ? "" : "  <- \(markers.joined(separator: ", "))"

    let rate = value(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)) ?? 0
    let buffer = value(id, kAudioDevicePropertyBufferFrameSize, default: UInt32(0)) ?? 0
    let latency = value(id, kAudioDevicePropertyLatency, scope, default: UInt32(0)) ?? 0
    let safety = value(id, kAudioDevicePropertySafetyOffset, scope, default: UInt32(0)) ?? 0
    let transport = fourCharacterCode(value(id, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0)
    let volume = value(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1, default: Float(0))
        .map { String(format: "%.3f", $0) } ?? "n/a"

    let milliseconds = rate > 0 ? Double(latency + safety) / rate * 1000 : 0

    print("\(stringValue(id, kAudioObjectPropertyName) ?? "?")\(marker)")
    print("  uid       \(stringValue(id, kAudioDevicePropertyDeviceUID) ?? "?")")
    print("  channels  in \(inputChannels)  out \(outputChannels)")
    print(String(format: "  timing    %.0f Hz, buffer %u, latency %u + safety %u (%.2f ms)",
                 rate, buffer, latency, safety, milliseconds))
    print("  transport \(transport)  volume \(volume)")
}
