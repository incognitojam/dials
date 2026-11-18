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
class CoreAudioTap: TapDevice {
    let output: AudioDevice
    private let queue: DispatchQueue
    private let changed: () -> Void
    private let diagnostic: (String) -> Void
    private let stillWanted: () -> Bool
    private let allowDuplexInput: Bool
    private var initialTapStream: AudioStreamID?
    private var hadPhysicalInputs = false
    private var activeSubTap: AudioObjectID?
    private var attachedOutput = false
    private var layout: TapLayout?
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

    init(output: AudioDevice, queue: DispatchQueue, allowDuplexInput: Bool = false, diagnostic: @escaping (String) -> Void = { _ in },
         stillWanted: @escaping () -> Bool = { true }, changed: @escaping () -> Void) {
        self.allowDuplexInput = allowDuplexInput
        self.diagnostic = diagnostic
        self.stillWanted = stillWanted
        self.output = output
        self.queue = queue
        self.changed = changed
    }

    private func streams(_ object: AudioObjectID, _ scope: UInt32) throws -> [AudioStreamID] {
        try CoreAudioClient.readArray(objectID: object, selector: kAudioDevicePropertyStreams, scope: scope)
    }

    private func widths(_ object: AudioObjectID, _ scope: UInt32) throws -> [UInt32] {
        var key = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try TapError.check(AudioObjectGetPropertyDataSize(object, &key, 0, nil, &size), "Read buffer list size")
        if size == 0 { return [] }
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard size >= offset else { throw SessionError.layout("Incomplete HAL buffer list") }
        let capacity = size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try TapError.check(AudioObjectGetPropertyData(object, &key, 0, nil, &size, storage), "Read buffer configuration")
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard size <= capacity, size >= offset, Int(list.pointee.mNumberBuffers) <= (Int(size) - offset) / MemoryLayout<AudioBuffer>.stride else {
            throw SessionError.layout("Incomplete HAL buffer configuration")
        }
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }

    private func members(_ selector: UInt32) throws -> [String] {
        let list: Unmanaged<CFArray>? = try CoreAudioClient.readScalar(objectID: aggregate, selector: selector, scope: global)
        guard let members = list?.takeRetainedValue() as? [String] else { throw SessionError.layout("Invalid aggregate membership") }
        return members
    }

    func physicalInputsBeforeCapture() throws -> (streams: Int, widths: [UInt32]) {
        let inputs = try streams(output.audioObjectID, kAudioObjectPropertyScopeInput)
        let outputs = try streams(output.audioObjectID, kAudioObjectPropertyScopeOutput)
        let inputWidths = try widths(output.audioObjectID, kAudioObjectPropertyScopeInput)
        let outputWidths = try widths(output.audioObjectID, kAudioObjectPropertyScopeOutput)
        diagnostic("USB input: \(inputs.count) streams, buffers \(inputWidths); output: \(outputs.count) streams, buffers \(outputWidths)")
        return (inputs.count, inputWidths)
    }

    func createTap() throws {
        let input = try physicalInputsBeforeCapture()
        try TapLayout.requireConsent(inputStreams: input.streams, bufferWidths: input.widths, allowed: allowDuplexInput)
        hadPhysicalInputs = input.streams > 0 || input.widths.contains(where: { $0 > 0 })
        try createProcessTap()
    }

    func createProcessTap() throws {
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
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try TapError.check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), "Create aggregate")
    }

    func configure(_ profile: EQInfo, plan: EqualizerPlan) throws {
        if !attachedOutput {
            // The tap is the aggregate's only source at this point. Retain its actual stream ID.
            var initial: [AudioStreamID] = []
            for _ in 0..<10 {
                initial = try streams(aggregate, kAudioObjectPropertyScopeInput)
                if !initial.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            guard initial.count == 1, try members(kAudioAggregateDevicePropertyFullSubDeviceList).isEmpty,
                  try TapLayout.containsOnlyTap(members(kAudioAggregateDevicePropertyTapList), uuid) else { throw SessionError.layout("Could not identify one input on the tap-only aggregate") }
            let subtaps: [AudioObjectID] = try CoreAudioClient.readArray(objectID: aggregate,
                selector: kAudioAggregateDevicePropertySubTapList, scope: global)
            guard subtaps.count == 1 else { throw SessionError.layout("Tap-only aggregate has no unique active sub-tap") }
            activeSubTap = subtaps[0]
            initialTapStream = initial[0]
            diagnostic("Tap-only aggregate input stream ID \(initial[0]), active sub-tap ID \(subtaps[0])")
            try CoreAudioClient.writeScalar([output.uid] as CFArray, objectID: aggregate,
                selector: kAudioAggregateDevicePropertyFullSubDeviceList, scope: global)
            try CoreAudioClient.writeScalar(output.uid as CFString, objectID: aggregate,
                selector: kAudioAggregateDevicePropertyMainSubDevice, scope: global)
            attachedOutput = true
        }
        if observations.isEmpty {
            for (object, selector, scope) in [
                (tap, kAudioTapPropertyFormat, global),
                (output.audioObjectID, kAudioDevicePropertyDeviceIsAlive, global),
                (aggregate, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
                (aggregate, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
                (aggregate, kAudioDevicePropertyNominalSampleRate, global),
                (aggregate, kAudioDevicePropertyBufferFrameSize, global),
                (aggregate, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            ] {
                observations.append(try AudioObservation(object, selector, scope: scope, queue: queue) { [weak self] in
                    guard let self else { return }
                    if selector == kAudioDevicePropertyStreams || selector == kAudioDevicePropertyStreamConfiguration ||
                        selector == kAudioTapPropertyFormat, let render { RenderContext.invalidate(render) }
                    changed()
                })
            }
        }
        // HAL publishes the aggregate and its streams separately.
        for attempt in 0..<10 {
            do {
                try configureStreams(profile, proposed: plan)
                return
            } catch {
                if let render { RenderContext.invalidate(render) }
                // A running session retries on the next notification. A new aggregate can
                // still be publishing its initial streams before listeners have run.
                if io != nil || attempt == 9 { throw error }
                if case SessionError.lowRate = error { throw error }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
    }

    private func configureStreams(_ profile: EQInfo, proposed: EqualizerPlan) throws {
        let format: AudioStreamBasicDescription = try CoreAudioClient.readScalar(objectID: tap,
            selector: kAudioTapPropertyFormat, scope: global)
        guard format.mSampleRate >= 32_000 else { throw SessionError.lowRate }
        let plan = proposed.sampleRate == format.mSampleRate ? proposed : try EqualizerPlan.playback(profile.parameters, sampleRate: format.mSampleRate)
        let inputs = try streams(aggregate, kAudioObjectPropertyScopeInput)
        let outputs = try streams(aggregate, kAudioObjectPropertyScopeOutput)
        let inputWidths = try widths(aggregate, kAudioObjectPropertyScopeInput)
        let outputWidths = try widths(aggregate, kAudioObjectPropertyScopeOutput)
        let physicalInputs = try streams(output.audioObjectID, kAudioObjectPropertyScopeInput)
        let physicalWidths = try widths(output.audioObjectID, kAudioObjectPropertyScopeInput)
        try TapLayout.requireConsent(inputStreams: physicalInputs.count, bufferWidths: physicalWidths, allowed: allowDuplexInput)
        hadPhysicalInputs = hadPhysicalInputs || !physicalInputs.isEmpty || physicalWidths.contains(where: { $0 > 0 })
        let frames: UInt32 = try CoreAudioClient.readScalar(objectID: aggregate, selector: kAudioDevicePropertyBufferFrameSize, scope: global)
        diagnostic("Tap format \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, flags \(format.mFormatFlags), \(format.mBitsPerChannel) bits, \(format.mBytesPerFrame) bytes/frame. Aggregate input IDs \(inputs), buffers \(inputWidths); outputs \(outputs), buffers \(outputWidths); IO buffer \(frames) frames")
        guard !outputs.isEmpty, outputWidths.contains(where: { $0 > 0 }), !inputs.isEmpty else {
            throw TapError(message: "Aggregate stream configuration is settling")
        }
        let tapStream = try TapLayout.identify(initial: initialTapStream, streams: inputs,
            physicalCount: physicalInputs.count, duplex: hadPhysicalInputs)
        let devices: [AudioObjectID] = try CoreAudioClient.readArray(objectID: aggregate,
            selector: kAudioAggregateDevicePropertyActiveSubDeviceList, scope: global)
        let subtaps: [AudioObjectID] = try CoreAudioClient.readArray(objectID: aggregate,
            selector: kAudioAggregateDevicePropertySubTapList, scope: global)
        guard let activeSubTap, subtaps == [activeSubTap], devices.count == 1, try members(kAudioAggregateDevicePropertyFullSubDeviceList) == [output.uid],
              try TapLayout.containsOnlyTap(members(kAudioAggregateDevicePropertyTapList), uuid) else { throw SessionError.layout("Aggregate output is unverified") }
        let virtual: AudioStreamBasicDescription = try CoreAudioClient.readScalar(objectID: tapStream,
            selector: kAudioStreamPropertyVirtualFormat, scope: global)
        let start: UInt32 = try CoreAudioClient.readScalar(objectID: tapStream, selector: kAudioStreamPropertyStartingChannel, scope: global)
        let selection = try TapLayout(tapID: tapStream, streams: inputs, startingChannel: start, bufferWidths: inputWidths,
                                      format: format, streamFormat: virtual)
        for stream in outputs {
            let outputFormat: AudioStreamBasicDescription = try CoreAudioClient.readScalar(objectID: stream,
                selector: kAudioStreamPropertyVirtualFormat, scope: global)
            guard TapLayout.supported(outputFormat) else { throw SessionError.layout("Unsupported aggregate output format") }
        }
        if let io, let render {
            RenderContext.invalidate(render)
            try verifyUsage(io, selection, install: false)
        }
        layout = selection
        let evidence = hadPhysicalInputs ? "retained tap-only ID" : "sole input on output-only device"
        diagnostic("Verified \(evidence), stream ID \(tapStream) at input stream \(selection.streamIndex), starting channel \(start), first buffer \(selection.buffers.firstBuffer), \(selection.buffers.bufferCount) buffer(s)")
        if plan.headroomDB > 0 { diagnostic(String(format: "Applied %.2f dB of equalizer headroom", plan.headroomDB)) }
        if let render {
            RenderContext.publish(render, plan: plan, channels: Int(format.mChannelsPerFrame), layout: selection.buffers)
        } else {
            let context = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
            context.initialize(to: RenderContext(plan: plan, channels: Int(format.mChannelsPerFrame), layout: selection.buffers))
            observingOverloads = EQObserveOverloads(aggregate, context.pointee.meter, true) == noErr
            render = context
        }
    }

    private func verifyUsage(_ io: AudioDeviceIOProcID, _ selection: TapLayout, install: Bool) throws {
        let before = try streams(aggregate, kAudioObjectPropertyScopeInput)
        let tapStream = selection.tapID
        guard before.count == selection.streamCount, before[Int(selection.streamIndex)] == tapStream else {
            throw SessionError.layout("Tap stream moved before input mask verification")
        }
        let format: AudioStreamBasicDescription = try CoreAudioClient.readScalar(objectID: tap, selector: kAudioTapPropertyFormat, scope: global)
        let virtual: AudioStreamBasicDescription = try CoreAudioClient.readScalar(objectID: tapStream, selector: kAudioStreamPropertyVirtualFormat, scope: global)
        let start: UInt32 = try CoreAudioClient.readScalar(objectID: tapStream, selector: kAudioStreamPropertyStartingChannel, scope: global)
        let current = try TapLayout(tapID: tapStream, streams: before, startingChannel: start,
                                    bufferWidths: widths(aggregate, kAudioObjectPropertyScopeInput), format: format, streamFormat: virtual)
        guard current.buffers.firstBuffer == selection.buffers.firstBuffer, current.buffers.totalBuffers == selection.buffers.totalBuffers,
              current.buffers.bufferCount == selection.buffers.bufferCount, current.buffers.channelsPerBuffer == selection.buffers.channelsPerBuffer else {
            throw SessionError.layout("Tap buffer range changed before IO mask verification")
        }
        let status = EQTapStreamUsage(aggregate, io, selection.streamCount, selection.streamIndex, install, EQHALStreamUsage)
        guard status == noErr, try streams(aggregate, kAudioObjectPropertyScopeInput) == before else { throw SessionError.layout("Tap-only input stream usage could not be verified (OSStatus \(status))") }
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
        guard let io, let layout else { throw SessionError.layout("Missing input stream selection") }
        try verifyUsage(io, layout, install: true)
        diagnostic("IO proc input mask verified; only tap stream \(layout.streamIndex) enabled")
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

    var layoutMismatch: Bool { EQLayoutMismatch(render!.pointee.meter) }

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
        let connected: [AudioObjectID]? = try? CoreAudioClient.readArray(objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices, scope: global)
        return connected?.contains(output.audioObjectID) == false
    }

    var otherProcessPlaying: Bool? {
        do {
            let objects: [AudioObjectID] = try CoreAudioClient.readArray(objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList, scope: global)
            for object in objects where object != ownProcess {
                let running: UInt32 = try CoreAudioClient.readScalar(objectID: object, selector: kAudioProcessPropertyIsRunningOutput, scope: global)
                if running == 0 { continue }
                let devices: [AudioObjectID] = try CoreAudioClient.readArray(objectID: object, selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeOutput)
                if devices.contains(output.audioObjectID) { return true }
            }
            return false
        } catch { return nil }
    }
}
