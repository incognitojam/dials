import CoreAudio
import EqualizerCore
import EqualizerIO
import Foundation

struct TapError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func check(_ status: OSStatus, _ call: String) throws {
        if status != noErr { throw TapError(message: "\(call) (OSStatus \(status))") }
    }
}

struct AudioObservation {
    let object: AudioObjectID
    let queue: DispatchQueue
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue, change: @escaping () -> Void) throws {
        self.object = object
        self.queue = queue
        address = .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        block = { _, _ in change() }
        try TapError.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "Observe audio property")
    }

    func cancel() {
        var key = address
        AudioObjectRemovePropertyListenerBlock(object, &key, queue, block)
    }
}

@available(macOS 14.2, *)
final class CoreAudioTap: TapDevice {
    let output: AudioDevice
    private let queue: DispatchQueue
    private let changed: () -> Void
    private var ownProcess: AudioObjectID = 0
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var uuid = UUID()
    private var io: AudioDeviceIOProcID?
    private var render: UnsafeMutablePointer<RenderContext>?
    private var observations: [AudioObservation] = []
    private let global = kAudioObjectPropertyScopeGlobal

    init(output: AudioDevice, queue: DispatchQueue, changed: @escaping () -> Void) {
        self.output = output
        self.queue = queue
        self.changed = changed
    }

    func createTap() throws {
        var key = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: global, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        for attempt in 0..<10 {
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess)
            if status == noErr && ownProcess != 0 { break }
            ownProcess = 0
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard ownProcess != 0 else { throw TapError(message: "Audio process unavailable") }
        let description = CATapDescription(__excludingProcesses: [NSNumber(value: ownProcess)],
                                          andDeviceUID: output.uid, withStream: 0)
        description.name = "neqMac equalizer"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        uuid = description.uuid
        try TapError.check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")
    }

    func createAggregate() throws {
        let spec: [String: Any] = [
            kAudioAggregateDeviceUIDKey: CoreAudioClient.equalizerAggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceNameKey: "neqMac equalizer",
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try TapError.check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), "Create aggregate")
    }

    func configure(_ profile: EQInfo) throws {
        if observations.isEmpty {
            for (object, selector, scope) in [
                (tap, kAudioTapPropertyFormat, global),
                (output.audioObjectID, kAudioDevicePropertyDeviceIsAlive, global),
                (aggregate, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
                (aggregate, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
                (aggregate, kAudioDevicePropertyNominalSampleRate, global),
                (aggregate, kAudioDevicePropertyBufferFrameSize, global)
            ] {
                observations.append(try AudioObservation(object, selector, scope: scope, queue: queue, change: changed))
            }
        }
        let format: AudioStreamBasicDescription = try CoreAudioClient.readScalar(objectID: tap,
            selector: kAudioTapPropertyFormat, scope: global)
        guard format.mSampleRate >= 32_000 else { throw SessionError.lowRate }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0 else {
            throw TapError(message: "Unsupported tap format")
        }
        let plan = try EqualizerPlan(profile.parameters, sampleRate: format.mSampleRate)
        let inputs: [AudioStreamID] = try CoreAudioClient.readArray(objectID: output.audioObjectID,
            selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        if let render {
            RenderContext.publish(render, plan: plan, channels: Int(format.mChannelsPerFrame), firstInput: UInt32(inputs.count))
        } else {
            let context = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
            context.initialize(to: RenderContext(plan: plan, channels: Int(format.mChannelsPerFrame), firstInput: UInt32(inputs.count)))
            render = context
        }
        let preferred: UInt32 = 128
        let current: UInt32 = try CoreAudioClient.readScalar(objectID: aggregate, selector: kAudioDevicePropertyBufferFrameSize, scope: global)
        if current != preferred {
            try CoreAudioClient.writeScalar(preferred, objectID: aggregate, selector: kAudioDevicePropertyBufferFrameSize, scope: global)
        }
    }

    func createIO() throws {
        try TapError.check(AudioDeviceCreateIOProcID(aggregate, { _, _, input, _, output, _, context in
            RenderContext.render(context!.assumingMemoryBound(to: RenderContext.self), input: input, output: output)
            return noErr
        }, render, &io), "Create IO proc")
    }

    func startIO() throws { try TapError.check(AudioDeviceStart(aggregate, io), "Start aggregate IO") }
    func destroyTap() { AudioHardwareDestroyProcessTap(tap) }
    func stopIO() { AudioDeviceStop(aggregate, io) }
    func destroyIO() {
        if let io, AudioDeviceDestroyIOProcID(aggregate, io) == noErr { self.io = nil }
    }
    func destroyAggregate() {
        observations.forEach { $0.cancel() }
        observations.removeAll()
        let destroyed = AudioHardwareDestroyAggregateDevice(aggregate) == noErr
        if let render, io == nil || destroyed {
            render.deinitialize(count: 1)
            render.deallocate()
            self.render = nil
        }
    }

    var heartbeat: UInt64 { EQHeartbeat(render!.pointee.meter) }
    func takeNonfinite() -> Bool { EQTakeNonfinite(render!.pointee.meter) }

    var removed: Bool {
        let alive: UInt32? = try? CoreAudioClient.readScalar(objectID: output.audioObjectID, selector: kAudioDevicePropertyDeviceIsAlive, scope: global)
        guard alive == 1 else { return true }
        var key = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &key, 0, nil, &size) == noErr, size > 0 else { return true }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(aggregate, &key, 0, nil, &size, storage) == noErr else { return true }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return !buffers.contains { $0.mNumberChannels > 0 }
    }

    var otherProcessPlaying: Bool {
        let objects: [AudioObjectID] = (try? CoreAudioClient.readArray(objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList, scope: global)) ?? []
        return objects.contains { object in
            guard object != ownProcess else { return false }
            let running: UInt32? = try? CoreAudioClient.readScalar(objectID: object, selector: kAudioProcessPropertyIsRunningOutput, scope: global)
            guard running == 1 else { return false }
            let devices: [AudioObjectID]? = try? CoreAudioClient.readArray(objectID: object, selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput)
            return devices?.contains(output.audioObjectID) == true
        }
    }
}
