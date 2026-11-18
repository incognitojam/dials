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
    private let diagnostic: (String) -> Void
    private let stillWanted: () -> Bool
    private var bufferRequest: (rate: Double, frames: UInt32)?
    private var observingOverloads = false
    private var overloads: UInt64 = 0
    private var lastDiagnostics: TimeInterval = 0
    private var ownProcess: AudioObjectID = 0
    private var tap: AudioObjectID = 0
    private var tapDestroyed = false
    private var aggregate: AudioObjectID = 0
    private var uuid = UUID()
    private var io: AudioDeviceIOProcID?
    private var render: UnsafeMutablePointer<RenderContext>?
    private var observations: [AudioObservation] = []
    private let global = kAudioObjectPropertyScopeGlobal

    init(output: AudioDevice, queue: DispatchQueue, diagnostic: @escaping (String) -> Void = { _ in },
         stillWanted: @escaping () -> Bool = { true }, changed: @escaping () -> Void) {
        self.diagnostic = diagnostic
        self.stillWanted = stillWanted
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
        guard stillWanted() else { throw SessionError.superseded }
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
        // HAL publishes the aggregate and its streams separately.
        for attempt in 0..<10 {
            do {
                try configureStreams(profile)
                return
            } catch let error as SessionError { throw error }
            catch {
                if attempt == 9 { throw error }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
    }

    private func configureStreams(_ profile: EQInfo) throws {
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
        let aggregateInputs: [AudioStreamID] = try CoreAudioClient.readArray(objectID: aggregate,
            selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let aggregateOutputs: [AudioStreamID] = try CoreAudioClient.readArray(objectID: aggregate,
            selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard aggregateInputs.count > inputs.count, !aggregateOutputs.isEmpty else {
            throw TapError(message: "Aggregate has no tap input or output stream")
        }
        for stream in Array(aggregateInputs.dropFirst(inputs.count)) + aggregateOutputs {
            let virtual: AudioStreamBasicDescription = try CoreAudioClient.readScalar(objectID: stream,
                selector: kAudioStreamPropertyVirtualFormat, scope: global)
            guard virtual.mFormatID == kAudioFormatLinearPCM, virtual.mBitsPerChannel == 32,
                  virtual.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  virtual.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
                throw TapError(message: "Unsupported aggregate stream format")
            }
        }
        if let render {
            RenderContext.publish(render, plan: plan, channels: Int(format.mChannelsPerFrame), firstInput: UInt32(inputs.count))
        } else {
            let context = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
            context.initialize(to: RenderContext(plan: plan, channels: Int(format.mChannelsPerFrame), firstInput: UInt32(inputs.count)))
            observingOverloads = EQObserveOverloads(aggregate, context.pointee.meter, true) == noErr
            render = context
        }
        let preferred: UInt32 = 128
        let current: UInt32 = try CoreAudioClient.readScalar(objectID: aggregate, selector: kAudioDevicePropertyBufferFrameSize, scope: global)
        if current == preferred { bufferRequest = nil; return }
        if bufferRequest?.rate == format.mSampleRate, bufferRequest?.frames == current { return }
        bufferRequest = (format.mSampleRate, current)
        do {
            try CoreAudioClient.writeScalar(preferred, objectID: aggregate, selector: kAudioDevicePropertyBufferFrameSize, scope: global)
        } catch { diagnostic("Could not set the preferred equalizer buffer size: " + error.localizedDescription) }
    }

    @_optimize(speed)
    func createIO() throws {
        try TapError.check(AudioDeviceCreateIOProcID(aggregate, { _, _, input, _, output, _, context in
            guard let context else { return -50 }
            RenderContext.render(context.assumingMemoryBound(to: RenderContext.self), input: input, output: output)
            return 0
        }, render, &io), "Create IO proc")
    }

    func startIO() throws {
        guard stillWanted() else { throw SessionError.superseded }
        try TapError.check(AudioDeviceStart(aggregate, io), "Start aggregate IO")
    }

    private func cleaned(_ status: OSStatus, _ step: String) -> Bool {
        if status == noErr || status == kAudioHardwareBadObjectError { return true }
        diagnostic("\(step) (OSStatus \(status))")
        return false
    }

    func destroyTap() {
        if tap != 0, !tapDestroyed { tapDestroyed = cleaned(AudioHardwareDestroyProcessTap(tap), "Destroy process tap") }
    }
    func stopIO() { _ = cleaned(AudioDeviceStop(aggregate, io), "Stop aggregate IO") }
    func destroyIO() {
        if let io, cleaned(AudioDeviceDestroyIOProcID(aggregate, io), "Destroy IO proc") { self.io = nil }
    }
    func destroyAggregate() {
        observations.forEach { $0.cancel() }
        observations.removeAll()
        if observingOverloads, let render {
            observingOverloads = !cleaned(EQObserveOverloads(aggregate, render.pointee.meter, false), "Remove overload listener")
        }
        let destroyed = cleaned(AudioHardwareDestroyAggregateDevice(aggregate), "Destroy aggregate")
        if let render, destroyed || (io == nil && !observingOverloads) {
            render.deinitialize(count: 1)
            render.deallocate()
            self.render = nil
        }
    }

    deinit { destroyTap() }

    var heartbeat: UInt64 {
        let meter = render!.pointee.meter
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDiagnostics >= 1 {
            lastDiagnostics = now
            if EQTakeNonfinite(meter) { diagnostic("Equalizer recovered from non-finite samples") }
            overloads += EQTakeOverloads(meter)
            if overloads > 1 {
                diagnostic("Repeated equalizer IO overloads")
                overloads = 0
            }
        }
        return EQHeartbeat(meter)
    }

    var removed: Bool {
        let alive: UInt32? = try? CoreAudioClient.readScalar(objectID: output.audioObjectID, selector: kAudioDevicePropertyDeviceIsAlive, scope: global)
        if alive == 0 { return true }
        if alive == nil {
            let connected: [AudioObjectID]? = try? CoreAudioClient.readArray(objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDevices, scope: global)
            if connected?.contains(output.audioObjectID) == false { return true }
        }
        var key = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &key, 0, nil, &size) == noErr else { return false }
        guard size >= MemoryLayout<UInt32>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(aggregate, &key, 0, nil, &size, storage) == noErr else { return false }
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
