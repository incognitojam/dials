import Foundation
import EqualizerCore
import EqualizerEngineCore

enum SessionStatus: Equatable {
    case idle, starting, running, failed(String), suspended(String)
}

protocol TapDevice: AnyObject {
    func createTap() throws
    func createAggregate() throws
    func configure(_ profile: EQInfo) throws
    func createIO() throws
    func startIO() throws
    func destroyTap()
    func stopIO()
    func destroyIO()
    func destroyAggregate()

    var removed: Bool { get }
    var otherProcessPlaying: Bool { get }
    var heartbeat: UInt64 { get }
}

enum SessionError: LocalizedError {
    case lowRate
    var errorDescription: String? { "Output rate below 32 kHz" }
}

// Coordinates the watchdog thread and the serial session queue. Never entered from IO.
final class SessionGuard {
    static let callbackTolerance: TimeInterval = 0.350
    private let lock = NSLock()
    private let device: TapDevice
    private var lastBeat: UInt64?
    private var since: TimeInterval = 0
    private var ended: SessionStatus?
    private var hasTap = false

    init(_ device: TapDevice) { self.device = device }

    func createTap() throws {
        try device.createTap()
        hasTap = true
    }

    func check(now: TimeInterval, notification: Bool = false) -> SessionStatus? {
        lock.lock()
        defer { lock.unlock() }
        if let ended { return ended }
        if device.removed { return finish(.suspended("Device removed")) }
        guard !notification else { return nil }
        guard device.otherProcessPlaying else {
            lastBeat = nil
            return nil
        }
        let beat = device.heartbeat
        if lastBeat != beat {
            since = now
            lastBeat = beat
        }
        guard now - since >= Self.callbackTolerance else { return nil }
        return finish(device.removed ? .suspended("Device removed") : .failed("Audio callback stalled"))
    }

    func end(_ status: SessionStatus) -> SessionStatus {
        lock.lock()
        defer { lock.unlock() }
        return ended ?? finish(status)
    }

    private func finish(_ status: SessionStatus) -> SessionStatus {
        ended = status
        if hasTap { device.destroyTap() }
        return status
    }
}

final class EqualizerSession {
    private let backend: TapDevice
    let monitor: SessionGuard
    private var aggregate = false
    private var io = false
    private var startAttempted = false

    init(_ backend: TapDevice) {
        self.backend = backend
        monitor = SessionGuard(backend)
    }

    func start(profile: EQInfo) throws {
        try monitor.createTap()
        try backend.createAggregate()
        aggregate = true
        try backend.configure(profile)
        try backend.createIO()
        io = true
        startAttempted = true
        try backend.startIO()
    }

    func watch(on queue: DispatchQueue, ended: @escaping (EqualizerSession, SessionStatus) -> Void) {
        Thread.detachNewThread { [self] in
            Thread.current.name = "neqMac equalizer watchdog"
            while true {
                let reason = autoreleasepool { monitor.check(now: ProcessInfo.processInfo.systemUptime) }
                if let reason {
                    queue.async { ended(self, reason) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func update(profile: EQInfo) throws { try backend.configure(profile) }

    func close(_ reason: SessionStatus) -> SessionStatus {
        let result = monitor.end(reason)
        if startAttempted { backend.stopIO(); startAttempted = false }
        if io { backend.destroyIO(); io = false }
        if aggregate { backend.destroyAggregate(); aggregate = false }
        return result
    }
}

// All lifecycle methods run on the controller's serial queue.
final class SessionEngine {
    private(set) var session: EqualizerSession?
    private(set) var status: SessionStatus = .idle
    private var target: AudioDevice?
    private var applied: EQInfo?
    let report: (SessionStatus) -> Void

    init(report: @escaping (SessionStatus) -> Void) { self.report = report }

    func reconcile(_ desired: DesiredEqualizer, output: AudioDevice?, retry: Bool = false,
                   formatChanged: Bool = false, make: (AudioDevice) -> TapDevice) {
        if let session, session.monitor.check(now: 0, notification: true) != nil {
            finish(session, reason: .suspended("Device removed"))
            if output == target || output == nil { target = output; return }
        }
        let changed = target != output
        if changed {
            if let session { finish(session, reason: .idle) }
            target = output
        }
        guard case let .process(profile, _) = desired, let output else {
            let next: SessionStatus
            if case let .suspended(reason) = desired { next = .suspended(reason) } else { next = .idle }
            if let session { finish(session, reason: next) } else { publish(next) }
            return
        }
        if !changed && !retry, case .failed = status { return }
        do {
            if let session {
                if applied != profile || formatChanged {
                    try session.update(profile: profile)
                    report(.running)
                }
            } else {
                publish(.starting)
                let new = EqualizerSession(make(output))
                session = new
                try new.start(profile: profile)
                publish(.running)
            }
            applied = profile
        } catch {
            if let session {
                let next: SessionStatus = error is SessionError ? .suspended(error.localizedDescription) : .failed(error.localizedDescription)
                finish(session, reason: next)
            }
        }
    }

    func finish(_ old: EqualizerSession, reason: SessionStatus) {
        guard old === session else { return }
        let result = old.close(reason)
        session = nil
        applied = nil
        if result != .idle { report(.idle) }
        publish(result)
    }

    private func publish(_ next: SessionStatus) {
        guard status != next else { return }
        status = next
        report(next)
    }
}
