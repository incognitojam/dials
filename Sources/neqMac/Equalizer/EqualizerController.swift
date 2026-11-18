import AppKit
import CoreAudio
import EqualizerEngineCore
import Foundation

protocol OutputEqualizing: AnyObject {
    func settled(output: AudioDevice?)
}

@available(macOS 14.2, *)
final class EqualizerController: OutputEqualizing {
    private let queue = DispatchQueue(label: "dev.neqmac.equalizer.session")
    private let engine: SessionEngine
    private let url: URL
    private let diagnostic: (String) -> Void
    private var output: AudioDevice?
    private var rateListener: AudioObservation?
    private var watcher: SettingsWatcher?
    private var file: SettingsFile = .absent
    private var asleep = false
    private var power: [NSObjectProtocol] = []

    init(url: URL, report: @escaping (SessionStatus) -> Void, diagnostic: @escaping (String) -> Void) {
        self.url = url
        self.diagnostic = diagnostic
        engine = SessionEngine(report: report)
        let center = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            power.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.powerChanged(sleeping)
            })
        }
        queue.async { [self] in
            watcher = SettingsWatcher(url: url, queue: queue) { [weak self] edited in
                self?.reload(edited: edited)
            }
            watcher?.arm()
            reload(edited: false)
        }
    }

    deinit { power.forEach(NSWorkspace.shared.notificationCenter.removeObserver); rateListener?.cancel() }

    private func powerChanged(_ sleeping: Bool) {
        queue.async { [self] in
            asleep = sleeping
            if sleeping {
                if let session = engine.session { engine.finish(session, reason: .idle) }
            } else {
                queue.asyncAfter(deadline: .now() + 1) { [self] in evaluate() }
            }
        }
    }

    func settled(output: AudioDevice?) {
        queue.async { [self] in
            let changed = self.output != output
            self.output = output
            if changed { observeRate() }
            evaluate()
        }
    }

    private func reload(edited: Bool) {
        let next = SettingsFile(at: url)
        let changed = next != file
        file = next
        if changed { observeRate() }
        if changed || edited { evaluate(retry: true) }
    }

    private func observeRate() {
        rateListener?.cancel()
        rateListener = nil
        guard case let .loaded(settings) = file, settings.enabled, let output, DesiredEqualizer.eligible(output) else { return }
        do {
            rateListener = try AudioObservation(output.audioObjectID, kAudioDevicePropertyNominalSampleRate, queue: queue) { [weak self] in
                self?.evaluate(formatChanged: true)
            }
        } catch { diagnostic(error.localizedDescription) }
    }

    private func evaluate(retry: Bool = false, formatChanged: Bool = false) {
        guard !asleep else { return }
        let current: AudioDevice?
        if let output, case let .loaded(settings) = file, settings.enabled {
            let id: AudioObjectID? = try? CoreAudioClient.readScalar(objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            current = id == output.audioObjectID ? output : nil
        } else { current = output }
        let rate: Double?
        if let current, rateListener != nil {
            rate = try? CoreAudioClient.readScalar(objectID: current.audioObjectID,
                selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
        } else { rate = nil }
        let desired = DesiredEqualizer.resolve(file, device: current, rate: rate)
        let previous = engine.session
        engine.reconcile(desired, output: current, retry: retry, formatChanged: formatChanged) { device in
            CoreAudioTap(output: device, queue: queue) { [weak self] in self?.evaluate(formatChanged: true) }
        }
        if let session = engine.session, session !== previous {
            session.watch(on: queue) { [weak self] old, reason in self?.engine.finish(old, reason: reason) }
        }
    }
}
