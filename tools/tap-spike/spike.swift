import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// ================================================================ shared helpers

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T? {
    var property = address(selector, scope)
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

func allDevices() -> [AudioObjectID] {
    var property = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &ids)
    return ids
}

func device(uid: String) -> AudioObjectID? {
    allDevices().first { stringValue($0, kAudioDevicePropertyDeviceUID) == uid }
}

func processObject(for pid: pid_t) -> AudioObjectID? {
    var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var input = pid
    var result = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                                            UInt32(MemoryLayout<pid_t>.size), &input, &size, &result)
    return status == noErr ? result : nil
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let ticksToNanoseconds = Double(timebase.numer) / Double(timebase.denom)

@inline(__always)
func channelPointer(_ list: UnsafePointer<AudioBufferList>, _ channel: Int) -> (UnsafeMutablePointer<Float>, Int, Int)? {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    var remaining = channel
    for buffer in buffers {
        let channels = Int(buffer.mNumberChannels)
        if remaining < channels {
            guard let data = buffer.mData else { return nil }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            return (data.assumingMemoryBound(to: Float.self).advanced(by: remaining), channels, frames)
        }
        remaining -= channels
    }
    return nil
}

@inline(__always)
func layout(_ list: UnsafePointer<AudioBufferList>) -> (buffers: Int, channels: Int) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    return (buffers.count, buffers.reduce(0) { $0 + Int($1.mNumberChannels) })
}

func writeFloats(_ samples: ArraySlice<Float>, to path: String) {
    samples.withUnsafeBufferPointer {
        _ = FileManager.default.createFile(atPath: path, contents: Data(buffer: $0))
    }
}

func fail(_ message: String, _ status: OSStatus? = nil) -> Never {
    if let status {
        var code = status.bigEndian
        let text = withUnsafeBytes(of: &code) { String(bytes: $0, encoding: .ascii) ?? "" }
        print("FAILED: \(message) (status \(status) '\(text)')")
    } else {
        print("FAILED: \(message)")
    }
    exit(1)
}

// ================================================================ arguments

var options: [String: String] = [:]
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
    arguments.removeFirst()
    guard flag.hasPrefix("--"), let argument = arguments.first else { fail("bad argument \(flag)") }
    arguments.removeFirst()
    options[String(flag.dropFirst(2))] = argument
}

if let logPath = options["log"] {
    freopen(logPath, "w", stdout)
    freopen(logPath, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
}

let role = options["role"] ?? "parent"
let seconds = Double(options["seconds"] ?? "6") ?? 6
let prefix = options["prefix"] ?? "/tmp/tap-spike/run"

// ================================================================ player role

if role == "player" {
    guard let outputUID = options["out-uid"], let outputDevice = device(uid: outputUID) else {
        fail("player needs --out-uid naming a real device")
    }
    let sampleRate = value(outputDevice, kAudioDevicePropertyNominalSampleRate, default: Float64(48000)) ?? 48000
    let noiseLevel = Float(options["noise-level"] ?? "0.05") ?? 0.05
    let clickLevel = Float(options["click-level"] ?? "0.35") ?? 0.35
    let clickPeriod = Int(sampleRate * 0.5)
    let clickLength = Int(sampleRate * 0.001)

    // Pre-render the click so the render thread only copies.
    var click = [Float](repeating: 0, count: clickLength)
    for index in 0..<clickLength {
        let phase = Double(index) / Double(clickLength)
        let window = 0.5 - 0.5 * cos(2 * Double.pi * phase)
        click[index] = Float(window * sin(2 * Double.pi * 3000 * Double(index) / sampleRate)) * clickLevel
    }

    var frameCounter = 0
    var clickTimes: [String] = []
    var randomState = SystemRandomNumberGenerator()
    var noise = [Float](repeating: 0, count: 1 << 16)
    for index in 0..<noise.count {
        noise[index] = Float.random(in: -1...1, using: &randomState) * noiseLevel
    }

    var procID: AudioDeviceIOProcID?
    let created = AudioDeviceCreateIOProcIDWithBlock(&procID, outputDevice, nil) { _, _, _, outputData, outputTime in
        let output = layout(outputData)
        guard output.channels > 0, let (_, _, frames) = channelPointer(outputData, 0) else { return }

        let baseNanoseconds = Double(outputTime.pointee.mHostTime) * ticksToNanoseconds

        for channel in 0..<output.channels {
            guard let (pointer, stride, _) = channelPointer(outputData, channel) else { continue }
            for frame in 0..<frames {
                let position = frameCounter + frame
                var sample = noise[position & (noise.count - 1)]
                let phase = position % clickPeriod
                if phase < clickLength {
                    sample += click[phase]
                    if channel == 0, phase == 0 {
                        let nanoseconds = baseNanoseconds + Double(frame) / sampleRate * 1_000_000_000
                        clickTimes.append(String(format: "%.0f", nanoseconds))
                    }
                }
                pointer[frame * stride] = sample
            }
        }
        frameCounter += frames
    }
    guard created == noErr, let procID else { fail("player AudioDeviceCreateIOProcIDWithBlock", created) }
    guard AudioDeviceStart(outputDevice, procID) == noErr else { fail("player AudioDeviceStart") }
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(outputDevice, procID)
    AudioDeviceDestroyIOProcID(outputDevice, procID)
    try? clickTimes.joined(separator: "\n").write(toFile: prefix + "-clicks.txt", atomically: true, encoding: .utf8)
    print("player: \(clickTimes.count) clicks, \(frameCounter) frames at \(sampleRate) Hz")
    exit(0)
}

// ================================================================ parent role

let mode = options["mode"] ?? "lowpass"
let useTap = mode != "control"

let systemObject = AudioObjectID(kAudioObjectSystemObject)
var outputDevice = value(systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0)) ?? 0
if let uid = options["out-uid"], let match = device(uid: uid) { outputDevice = match }
guard outputDevice != 0, let outputUID = stringValue(outputDevice, kAudioDevicePropertyDeviceUID) else {
    fail("no output device")
}
let sampleRate = value(outputDevice, kAudioDevicePropertyNominalSampleRate, default: Float64(48000)) ?? 48000

print("mode          : \(mode)")
print("output        : \(stringValue(outputDevice, kAudioObjectPropertyName) ?? "?") @ \(sampleRate) Hz")

// ---------------------------------------------------------------- tap + aggregate

var tap = AudioObjectID(kAudioObjectUnknown)
var aggregate = AudioObjectID(kAudioObjectUnknown)
var tapDescription: CATapDescription?

if useTap {
    guard let ownProcess = processObject(for: getpid()) else { fail("no process object for self") }
    let scope = options["tap-scope"] ?? "device"
    let description: CATapDescription
    if scope == "global" {
        description = CATapDescription(__stereoGlobalTapButExcludeProcesses: [NSNumber(value: ownProcess)])
    } else {
        description = CATapDescription(__excludingProcesses: [NSNumber(value: ownProcess)],
                                       andDeviceUID: outputUID,
                                       withStream: 0)
    }
    description.name = "dials eq spike"
    description.isPrivate = (options["private"] ?? "yes") == "yes"
    switch options["mute"] ?? "mutedWhenTapped" {
    case "unmuted": description.muteBehavior = CATapMuteBehavior.unmuted
    case "muted": description.muteBehavior = CATapMuteBehavior.muted
    default: description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
    }
    tapDescription = description
    print("tap config    : scope \(scope)  exclusive \(description.isExclusive)  private \(description.isPrivate)  mute \(description.muteBehavior.rawValue)  processes \(description.__processes)")

    let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
    guard tapStatus == noErr, tap != kAudioObjectUnknown else { fail("AudioHardwareCreateProcessTap", tapStatus) }

    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceUIDKey: "dials.eq.spike.\(UUID().uuidString)",
        kAudioAggregateDeviceNameKey: "dials eq spike",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapUIDKey: description.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: (options["drift"] ?? "yes") == "yes",
        ]],
    ]
    let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
    guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
        AudioHardwareDestroyProcessTap(tap)
        fail("AudioHardwareCreateAggregateDevice", aggregateStatus)
    }
    Thread.sleep(forTimeInterval: 0.5)
    if let requested = options["buffer-frames"], let frames = UInt32(requested) {
        var property = address(kAudioDevicePropertyBufferFrameSize)
        var wanted = frames
        let status = AudioObjectSetPropertyData(aggregate, &property, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &wanted)
        let actual = value(aggregate, kAudioDevicePropertyBufferFrameSize, default: UInt32(0)) ?? 0
        print("buffer frames : requested \(frames)  status \(status)  actual \(actual)")
    }
    print("tap           : object \(tap)  aggregate \(aggregate)")
}

// ---------------------------------------------------------------- filter

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func lowpass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let cosw = cos(w)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = ((1 - cosw) / 2) / a0
        filter.b1 = (1 - cosw) / a0
        filter.b2 = filter.b0
        filter.a1 = (-2 * cosw) / a0
        filter.a2 = (1 - alpha) / a0
        return filter
    }

    @inline(__always)
    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = input
        y2 = y1; y1 = output
        return output
    }
}

var filters = [Biquad](repeating: .lowpass(frequency: 500, q: 0.707, sampleRate: sampleRate), count: 8)

// ---------------------------------------------------------------- capture state

let capacity = Int(sampleRate * (seconds + 3)) * 2
var rawCapture = [Float](repeating: 0, count: capacity)
var processedCapture = [Float](repeating: 0, count: capacity)
var captureFrames = 0

var latencies = [Double](repeating: 0, count: 400_000)
var latencyCount = 0
var callbackCount = 0
var observedInput = (buffers: -1, channels: -1)
var observedOutput = (buffers: -1, channels: -1)

var micCapture = [Float](repeating: 0, count: capacity)
var micFrames = 0
var micChannels = 0
var micTimeline: [String] = []
var micCallbacks = 0

// ---------------------------------------------------------------- tap io proc

var tapProcID: AudioDeviceIOProcID?
if useTap {
    let status = AudioDeviceCreateIOProcIDWithBlock(&tapProcID, aggregate, nil) {
        _, inputData, inputTime, outputData, outputTime in

        callbackCount += 1
        let input = layout(inputData)
        let output = layout(outputData)
        if observedInput.buffers < 0 { observedInput = input; observedOutput = output }

        let inputFlags = AudioTimeStampFlags(rawValue: inputTime.pointee.mFlags.rawValue)
        let outputFlags = AudioTimeStampFlags(rawValue: outputTime.pointee.mFlags.rawValue)
        if inputFlags.contains(.hostTimeValid), outputFlags.contains(.hostTimeValid), latencyCount < latencies.count {
            let delta = Double(outputTime.pointee.mHostTime) - Double(inputTime.pointee.mHostTime)
            latencies[latencyCount] = delta * ticksToNanoseconds / 1_000_000
            latencyCount += 1
        }

        guard output.channels > 0 else { return }
        var framesThisCycle = 0

        for channel in 0..<output.channels {
            guard let (outputPointer, outputStride, outputFrames) = channelPointer(outputData, channel) else { continue }
            guard input.channels > 0,
                  let (inputPointer, inputStride, inputFrames) = channelPointer(inputData, min(channel, input.channels - 1))
            else {
                for frame in 0..<outputFrames { outputPointer[frame * outputStride] = 0 }
                continue
            }

            let frames = min(outputFrames, inputFrames)
            framesThisCycle = max(framesThisCycle, frames)
            for frame in 0..<frames {
                let sample = Double(inputPointer[frame * inputStride])
                let processed: Double
                switch mode {
                case "passthrough": processed = sample
                case "silence": processed = 0
                default: processed = filters[channel].process(sample)
                }
                outputPointer[frame * outputStride] = Float(processed)

                let slot = (captureFrames + frame) * 2 + channel
                if channel < 2, slot < capacity {
                    rawCapture[slot] = Float(sample)
                    processedCapture[slot] = Float(processed)
                }
            }
            for frame in frames..<outputFrames { outputPointer[frame * outputStride] = 0 }
        }
        captureFrames = min(captureFrames + framesThisCycle, capacity / 2 - 1)
    }
    guard status == noErr, tapProcID != nil else { fail("tap AudioDeviceCreateIOProcIDWithBlock", status) }
}

// ---------------------------------------------------------------- microphone io proc

var micDevice = AudioObjectID(kAudioObjectUnknown)
var micProcID: AudioDeviceIOProcID?
var micSampleRate: Float64 = 48000

if let micUID = options["mic-uid"], let found = device(uid: micUID) {
    micDevice = found
    micSampleRate = value(micDevice, kAudioDevicePropertyNominalSampleRate, default: Float64(48000)) ?? 48000
    print("microphone    : \(stringValue(micDevice, kAudioObjectPropertyName) ?? "?") @ \(micSampleRate) Hz")

    let status = AudioDeviceCreateIOProcIDWithBlock(&micProcID, micDevice, nil) {
        _, inputData, inputTime, _, _ in
        micCallbacks += 1
        let input = layout(inputData)
        guard input.channels > 0, let (_, _, frames) = channelPointer(inputData, 0) else { return }
        if micChannels == 0 { micChannels = min(input.channels, 2) }

        let flags = AudioTimeStampFlags(rawValue: inputTime.pointee.mFlags.rawValue)
        if flags.contains(.hostTimeValid) {
            let nanoseconds = Double(inputTime.pointee.mHostTime) * ticksToNanoseconds
            micTimeline.append("\(micFrames) \(String(format: "%.0f", nanoseconds))")
        }

        for channel in 0..<micChannels {
            guard let (pointer, stride, _) = channelPointer(inputData, channel) else { continue }
            for frame in 0..<frames {
                let slot = (micFrames + frame) * 2 + channel
                if slot < capacity { micCapture[slot] = pointer[frame * stride] }
            }
        }
        micFrames = min(micFrames + frames, capacity / 2 - 1)
    }
    if status != noErr { print("microphone    : could not create io proc (\(status))") ; micProcID = nil }
}

// ---------------------------------------------------------------- run

if let tapProcID {
    let status = AudioDeviceStart(aggregate, tapProcID)
    if status != noErr { print("tap start failed \(status)") }
}
if let micProcID {
    let status = AudioDeviceStart(micDevice, micProcID)
    if status != noErr { print("mic start failed \(status)") }
}

var player: Process?
if options["play"] == "yes" {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--role", "player",
                         "--out-uid", outputUID,
                         "--seconds", String(seconds - 1),
                         "--prefix", prefix,
                         "--noise-level", options["noise-level"] ?? "0.05",
                         "--click-level", options["click-level"] ?? "0.35"]
    try? process.run()
    player = process
    print("player        : pid \(process.processIdentifier)")
}

Thread.sleep(forTimeInterval: seconds)
player?.waitUntilExit()

if let tapProcID {
    AudioDeviceStop(aggregate, tapProcID)
    AudioDeviceDestroyIOProcID(aggregate, tapProcID)
}
if let micProcID {
    AudioDeviceStop(micDevice, micProcID)
    AudioDeviceDestroyIOProcID(micDevice, micProcID)
}
if useTap {
    AudioHardwareDestroyAggregateDevice(aggregate)
    AudioHardwareDestroyProcessTap(tap)
}

// ---------------------------------------------------------------- report

func rootMeanSquare(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
}

writeFloats(rawCapture[0..<(captureFrames * 2)], to: prefix + "-tapraw.f32")
writeFloats(processedCapture[0..<(captureFrames * 2)], to: prefix + "-tapproc.f32")
writeFloats(micCapture[0..<(micFrames * 2)], to: prefix + "-mic.f32")
try? micTimeline.joined(separator: "\n").write(toFile: prefix + "-mictimes.txt", atomically: true, encoding: .utf8)

let sorted = latencies[0..<latencyCount].sorted()
func percentile(_ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]
}

print("")
print("tap callbacks : \(callbackCount)  frames \(captureFrames)")
print("tap layout    : in \(observedInput.channels)ch  out \(observedOutput.channels)ch")
print(String(format: "tap→out delay : min %.2f  p50 %.2f  p95 %.2f  max %.2f ms  (n=%d)",
             sorted.first ?? 0, percentile(0.5), percentile(0.95), sorted.last ?? 0, latencyCount))
print(String(format: "tap rms       : raw %.6f  processed %.6f", rootMeanSquare(rawCapture[0..<(captureFrames * 2)]),
             rootMeanSquare(processedCapture[0..<(captureFrames * 2)])))
print("mic callbacks : \(micCallbacks)  frames \(micFrames)  channels \(micChannels)")
print(String(format: "mic rms       : %.6f", rootMeanSquare(micCapture[0..<(micFrames * 2)])))
print("dumps         : \(prefix)-{tapraw,tapproc,mic}.f32")
print("rates         : output \(sampleRate)  mic \(micSampleRate)")
