import AppKit
import CoreAudio
import EqualizerEngineCore
import Foundation
import OSLog
import os.lock

protocol OutputEqualizing: AnyObject {
    func settled(output: AudioDevice?)
    func disconnected(_ device: AudioDevice)
}

@available(macOS 14.2, *)
protocol EqualizerHardware {
    func isCurrent(_ device: AudioDevice) -> Bool
    func rate(_ device: AudioDevice) -> Double?
    func observeRate(_ device: AudioDevice, queue: DispatchQueue, changed: @escaping () -> Void) throws -> () -> Void
    func tap(_ device: AudioDevice, duplex: Bool, queue: DispatchQueue, diagnostic: @escaping (String) -> Void,
             wanted: @escaping () -> Bool, changed: @escaping () -> Void) -> TapDevice
}

@available(macOS 14.2, *)
struct SystemEqualizerHardware: EqualizerHardware {
    func isCurrent(_ device: AudioDevice) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let scope = kAudioObjectPropertyScopeGlobal
        let id: AudioObjectID? = try? CoreAudioClient.readScalar(objectID: system, selector: kAudioHardwarePropertyDefaultOutputDevice, scope: scope)
        guard id == device.audioObjectID else { return false }
        let alive: UInt32? = try? CoreAudioClient.readScalar(objectID: device.audioObjectID, selector: kAudioDevicePropertyDeviceIsAlive, scope: scope)
        let devices: [AudioObjectID]? = try? CoreAudioClient.readArray(objectID: system, selector: kAudioHardwarePropertyDevices, scope: scope)
        return alive == 1 && devices?.contains(device.audioObjectID) == true
    }

    func rate(_ device: AudioDevice) -> Double? {
        try? CoreAudioClient.readScalar(objectID: device.audioObjectID, selector: kAudioDevicePropertyNominalSampleRate,
                                        scope: kAudioObjectPropertyScopeGlobal)
    }

    func observeRate(_ device: AudioDevice, queue: DispatchQueue, changed: @escaping () -> Void) throws -> () -> Void {
        let listener = try AudioObservation(device.audioObjectID, kAudioDevicePropertyNominalSampleRate, queue: queue, change: changed)
        return listener.cancel
    }

    func tap(_ device: AudioDevice, duplex: Bool, queue: DispatchQueue, diagnostic: @escaping (String) -> Void,
             wanted: @escaping () -> Bool, changed: @escaping () -> Void) -> TapDevice {
        CoreAudioTap(output: device, queue: queue, allowDuplexInput: duplex, diagnostic: diagnostic,
                     stillWanted: wanted, changed: changed)
    }
}

@available(macOS 14.2, *)
final class EqualizerController: OutputEqualizing {
    private let queue: DispatchQueue
    private let hardware: EqualizerHardware
    let engine: SessionEngine
    private let url: URL
    private let diagnostic: (String) -> Void
    private var output: AudioDevice?
    private var lastRate: Double?
    private var generation = UUID()
    private var cancelRate: (() -> Void)?
    private var fileBytes: Data?
    private var watcher: SettingsWatcher?
    private var file: SettingsFile = .absent
    private let asleep = OSAllocatedUnfairLock(initialState: false)
    private var power: [NSObjectProtocol] = []

    init(url: URL, hardware: EqualizerHardware = SystemEqualizerHardware(),
         queue: DispatchQueue = DispatchQueue(label: "dev.neqmac.equalizer.session"), didTearDown: @escaping () -> Void, report: @escaping (SessionStatus) -> Void, diagnostic: @escaping (String) -> Void) {
        self.url = url
        self.hardware = hardware
        self.queue = queue
        let logger = Logger(subsystem: "dev.neqmac.app", category: "equalizer")
        let log: (String) -> Void = { message in
            logger.notice("\(message, privacy: .public)")
            diagnostic(message)
        }
        self.diagnostic = log
        engine = SessionEngine(queue: queue, diagnostic: log, didTearDown: didTearDown) { status in
            logger.notice("Equalizer status: \(String(describing: status), privacy: .public)")
            report(status)
        }
        engine.scheduleLayoutRetry = { [weak self] token in
            self?.queue.asyncAfter(deadline: .now() + .milliseconds(750)) { [weak self] in
                guard let self, engine.resumeLayoutRetry(token) else { return }
                evaluate()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            power.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.powerChanged(sleeping)
            })
        }
        queue.async { [self] in
            watcher = SettingsWatcher(url: url, queue: queue) { [weak self] in
                self?.reload()
            }
            watcher?.arm()
            reload()
        }
    }

    deinit {
        power.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        cancelRate?()
        queue.async { [engine] in
            if let session = engine.session { engine.finish(session, reason: .idle) }
        }
    }

    func powerChanged(_ sleeping: Bool) {
        asleep.withLock { $0 = sleeping }
        queue.async { [self] in
            if sleeping {
                if let session = engine.session { engine.finish(session, reason: .idle) }
            } else {
                queue.asyncAfter(deadline: .now() + 1) { [self] in evaluate() }
            }
        }
    }

    func disconnected(_ device: AudioDevice) {
        queue.async { [self] in
            guard output?.audioObjectID == device.audioObjectID else { return }
            output = nil
            lastRate = nil
            observeRate()
            if let session = engine.session { engine.finish(session, reason: .suspended("Device removed")) }
        }
    }

    func settled(output: AudioDevice?) {
        queue.async { [self] in
            let changed = self.output != output
            self.output = output
            if changed {
                lastRate = nil
                observeRate()
            }
            evaluate()
        }
    }

    private func reload() {
        let bytes: Data?
        let next: SettingsFile
        do {
            let data = try Data(contentsOf: url)
            if fileBytes == data { return }
            bytes = data
            next = SettingsFile(data: data)
        } catch CocoaError.fileReadNoSuchFile {
            bytes = nil
            next = .absent
        } catch {
            bytes = nil
            next = .invalid(error.localizedDescription)
        }
        guard bytes != fileBytes || next != file else { return }
        if let output, let session = engine.session, case let .loaded(old) = file, case let .loaded(new) = next,
           old.allowsDuplex(output) && !new.allowsDuplex(output) { engine.finish(session, reason: .idle) }
        fileBytes = bytes
        file = next
        observeRate()
        evaluate(retry: true)
    }

    private func observeRate() {
        cancelRate?()
        cancelRate = nil
        guard case let .loaded(settings) = file, settings.enabled, let output, DesiredEqualizer.eligible(output) else { return }
        do {
            cancelRate = try hardware.observeRate(output, queue: queue) { [weak self] in
                self?.evaluate(formatChanged: true)
            }
        } catch { diagnostic(error.localizedDescription) }
    }

    private func evaluate(retry: Bool = false, formatChanged: Bool = false) {
        guard !asleep.withLock({ $0 }) else { return }
        if formatChanged, engine.session != nil { engine.formatChanged(); return }
        let current: AudioDevice?
        if let output, case let .loaded(settings) = file, settings.enabled {
            current = hardware.isCurrent(output) ? output : nil
        } else { current = output }
        let rate: Double?
        if let current, case let .loaded(settings) = file, settings.enabled, DesiredEqualizer.eligible(current) {
            if let observed = hardware.rate(current) {
                lastRate = observed
                rate = observed
            } else {
                // The live tap still verifies its negotiated format during clock relock.
                rate = engine.session == nil ? nil : lastRate
            }
        } else { rate = nil }
        let desired = DesiredEqualizer.resolve(file, device: current, rate: rate)
        let previous = engine.session
        engine.reconcile(desired, output: current, retry: retry) { device in
            let token = UUID()
            generation = token
            guard case let .loaded(settings) = file else { preconditionFailure("Processing requires settings") }
            return hardware.tap(device, duplex: settings.allowsDuplex(device), queue: queue, diagnostic: diagnostic,
                                wanted: { [weak self, hardware, url, file] in
                guard let self, generation == token, engine.session != nil, !asleep.withLock({ $0 }) else { return false }
                return hardware.isCurrent(device) && SettingsFile(at: url) == file
            }) { [weak self] in
                guard let self, generation == token, engine.session != nil else { return }
                evaluate(formatChanged: true)
            }
        }
        if let session = engine.session, session !== previous {
            session.watch(on: queue) { [weak self] old, reason in
                guard let self else { return }
                engine.observed(old, reason) { self.evaluate() }
            }
        }
    }
}
