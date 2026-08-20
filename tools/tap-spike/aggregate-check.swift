import CoreAudio
import Darwin
import Foundation

func address(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func value<T>(_ o: AudioObjectID, _ s: AudioObjectPropertySelector, default d: T) -> T? {
    var p = address(s); var size = UInt32(MemoryLayout<T>.size); var r = d
    return withUnsafeMutablePointer(to: &r) { AudioObjectGetPropertyData(o, &p, 0, nil, &size, $0) } == noErr ? r : nil
}
func stringValue(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String? {
    var p = address(s); var size = UInt32(MemoryLayout<CFString?>.size); var r: CFString?
    guard withUnsafeMutablePointer(to: &r) { AudioObjectGetPropertyData(o, &p, 0, nil, &size, $0) } == noErr, let r else { return nil }
    return r as String
}

let system = AudioObjectID(kAudioObjectSystemObject)
let output = value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))!
let uid = stringValue(output, kAudioDevicePropertyDeviceUID)!
let useAggregate = CommandLine.arguments.contains("--aggregate")

var target = output
var aggregate = AudioObjectID(kAudioObjectUnknown)
if useAggregate {
    let description: [String: Any] = [
        kAudioAggregateDeviceUIDKey: "dials.iotest.\(UUID().uuidString)",
        kAudioAggregateDeviceNameKey: "dials iotest",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceMainSubDeviceKey: uid,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
    ]
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
    print("aggregate create status \(status), id \(aggregate)")
    target = aggregate
    Thread.sleep(forTimeInterval: 0.5)
}

var callbacks = 0
var procID: AudioDeviceIOProcID?
let created = AudioDeviceCreateIOProcIDWithBlock(&procID, target, nil) { _, _, _, outputData, _ in
    callbacks += 1
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
}
print("create io proc status \(created)")
let started = AudioDeviceStart(target, procID!)
print("start status \(started)")
Thread.sleep(forTimeInterval: 2)
print("callbacks: \(callbacks)")
AudioDeviceStop(target, procID!)
AudioDeviceDestroyIOProcID(target, procID!)
if useAggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
