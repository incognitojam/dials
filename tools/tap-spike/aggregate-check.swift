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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("aggregate-check: \(message)\n".utf8))
    exit(1)
}

let usage = "usage: aggregate-check --out-uid <uid> [--aggregate]; list UIDs with ./build/devices"
var useAggregate = false
var requestedUID: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--aggregate": useAggregate = true
    case "--out-uid" where requestedUID == nil && !(arguments.first ?? "--").hasPrefix("--"):
        requestedUID = arguments.removeFirst()
    default: fail(usage)
    }
}
guard let uid = requestedUID else { fail(usage) }

func outputChannels(_ device: AudioObjectID) -> Int {
    var property = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

let system = AudioObjectID(kAudioObjectSystemObject)
var devicesAddress = address(kAudioHardwarePropertyDevices)
var devicesSize: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &devicesSize)
var deviceIDs = [AudioObjectID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &devicesSize, &deviceIDs)
guard let output = deviceIDs.first(where: { stringValue($0, kAudioDevicePropertyDeviceUID) == uid }) else {
    fail("no audio device has UID \(uid)")
}
guard outputChannels(output) > 0 else { fail("\(uid) is not an output device") }

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
    guard status == noErr, aggregate != kAudioObjectUnknown else { fail("could not create the aggregate") }
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
guard created == noErr, let procID else {
    if useAggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
    fail("could not create the IO proc")
}
let started = AudioDeviceStart(target, procID)
print("start status \(started)")
if started == noErr { Thread.sleep(forTimeInterval: 2) }
print("callbacks: \(callbacks)")
AudioDeviceStop(target, procID)
AudioDeviceDestroyIOProcID(target, procID)
if useAggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
if started != noErr { exit(1) }
