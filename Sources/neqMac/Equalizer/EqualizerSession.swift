import Foundation
import EqualizerCore
import EqualizerEngineCore

enum SessionStatus: Equatable {
    case idle, starting, running, failed(String), suspended(String)
}

protocol TapDevice: AnyObject {
    func createTap() throws
    func createAggregate() throws
    func configure(_ profile: EQInfo, plan: EqualizerPlan) throws
    func createIO() throws
    func startIO() throws
    func destroyTap()
    func stopIO()
    func destroyIO()
    func destroyAggregate()

    var removed: Bool { get }
    var otherProcessPlaying: Bool? { get }
    var heartbeat: UInt64 { get }
    var layoutMismatch: Bool { get }
}

enum SessionError: LocalizedError {
    case lowRate, superseded, layout(String)
    var errorDescription: String? {
        switch self {
        case let .layout(reason): reason
        case .lowRate: "Output rate below 32 kHz"
        case .superseded: "Output or settings changed while starting"
        }
    }
}

// Coordinates the watchdog thread and the serial session queue. Never entered from IO.
final class SessionGuard {
    static let callbackTolerance: TimeInterval = 0.350
    static let activityFreshness: TimeInterval = 0.250
    private let lock = NSLock()
    private let device: TapDevice
    private var lastBeat: UInt64?
    private var since: TimeInterval = 0
    private var ended: SessionStatus?
    private(set) var hasTap = false

    init(_ device: TapDevice) { self.device = device }

    func createTap() throws {
        try device.createTap()
        hasTap = true
    }

    private var released = false
    private var playing: Bool?
    private var lastPoll: TimeInterval?

    func setPlaying(_ value: Bool?, at completed: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        lastPoll = completed
        if value == false { lastBeat = nil }
        playing = value
    }

    func formatChanged() {
        lock.lock()
        defer { lock.unlock() }
        lastBeat = nil
    }

    func check(now: TimeInterval) -> SessionStatus? {
        lock.lock()
        defer { lock.unlock() }
        if let ended { return ended }
        let beat = device.heartbeat
        if let lastPoll, playing == false, now - lastPoll <= Self.activityFreshness { return nil }
        if lastBeat != beat {
            since = now
            lastBeat = beat
        }
        guard now - since >= Self.callbackTolerance else { return nil }
        release()
        if device.removed { ended = .suspended("Device removed") }
        else if device.layoutMismatch { ended = .suspended("Tap input layout no longer verified") }
        else { ended = .failed("Audio callback stalled") }
        return ended
    }

    func end(_ status: SessionStatus) -> SessionStatus {
        lock.lock()
        defer { lock.unlock() }
        if let ended { return ended }
        release()
        ended = status
        return status
    }

    func unmuteBeforeDiagnosis() {
        lock.lock()
        defer { lock.unlock() }
        release()
    }

    private func release() {
        if hasTap && !released {
            device.destroyTap()
            released = true
        }
    }
}

final class EqualizerSession {
    private let backend: TapDevice
    let monitor: SessionGuard
    private var aggregate = false
    private var io = false
    private var activityPoll: DispatchSourceTimer?
    private var startAttempted = false
    var removed: Bool { backend.removed }

    init(_ backend: TapDevice) {
        self.backend = backend
        monitor = SessionGuard(backend)
    }

    func start(profile: EQInfo, plan: EqualizerPlan, diagnostic: (String) -> Void) throws {
        func timed(_ name: String, _ work: () throws -> Void) rethrows {
            let start = DispatchTime.now().uptimeNanoseconds
            defer {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                diagnostic(String(format: "%@: %.2f ms", name, ms))
            }
            try work()
        }
        try timed("Create tap", monitor.createTap)
        try timed("Create aggregate", backend.createAggregate)
        aggregate = true
        try timed("Configure aggregate") { try backend.configure(profile, plan: plan) }
        try timed("Create IO proc", backend.createIO)
        io = true
        startAttempted = true
        try timed("Start IO", backend.startIO)
    }

    func watch(on queue: DispatchQueue, ended: @escaping (EqualizerSession, SessionStatus) -> Void) {
        // HAL queries can wait behind IO. Keep them off the heartbeat thread and outside its lock.
        let poll = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.neqmac.equalizer.activity"))
        monitor.setPlaying(false)
        poll.setEventHandler { [backend, monitor] in monitor.setPlaying(backend.otherProcessPlaying) }
        poll.schedule(deadline: .now(), repeating: .milliseconds(50))
        activityPoll = poll
        poll.resume()
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

    func update(profile: EQInfo, plan: EqualizerPlan) throws { try backend.configure(profile, plan: plan) }

    func closeIO() {
        activityPoll?.cancel()
        activityPoll = nil
        if startAttempted { backend.stopIO(); startAttempted = false }
        if io { backend.destroyIO(); io = false }
        if aggregate { backend.destroyAggregate(); aggregate = false }
    }
}

// All lifecycle methods run on the controller's serial queue.
final class SessionEngine {
    private(set) var session: EqualizerSession?
    private(set) var status: SessionStatus = .idle
    private var target: AudioDevice?
    private var applied: EQInfo?
    private var appliedRate: Double?
    private var formatRetries = 0
    private var requiresEdit = false
    private var layoutRetryToken: UUID?
    private var usedLayoutRetry = false
    var scheduleLayoutRetry: ((UUID) -> Void)?

    private let diagnostic: (String) -> Void
    private var failures: [String: Int] = [:]
    private let didTearDown: () -> Void
    private let report: (SessionStatus) -> Void

    init(diagnostic: @escaping (String) -> Void = { _ in }, didTearDown: @escaping () -> Void = {}, report: @escaping (SessionStatus) -> Void) {
        self.diagnostic = diagnostic
        self.didTearDown = didTearDown
        self.report = report
    }

    func resumeLayoutRetry(_ token: UUID) -> Bool {
        guard layoutRetryToken == token else { return false }
        layoutRetryToken = nil
        requiresEdit = false
        return true
    }

    func reconcile(_ desired: DesiredEqualizer, output: AudioDevice?, retry: Bool = false,
                   formatChanged: Bool = false, make: (AudioDevice) -> TapDevice) {
        if formatChanged { session?.monitor.formatChanged() }
        if let session, session.removed {
            finish(session, reason: .suspended("Device removed"))
            if output == target || output == nil { target = output; return }
        }
        let changed = target != output
        if changed {
            if let session { finish(session, reason: .idle) }
            target = output
        }
        if changed || retry {
            layoutRetryToken = nil
            usedLayoutRetry = false
            requiresEdit = false
        }
        guard case let .process(profile, plan) = desired, let output else {
            let next: SessionStatus
            if case let .suspended(reason) = desired { next = .suspended(reason) } else { next = .idle }
            if let session { finish(session, reason: next) } else { publish(next) }
            return
        }
        if retry { failures.removeValue(forKey: output.uid) }
        if requiresEdit { return }
        if !changed && !retry, case .failed = status { return }
        if failures[output.uid, default: 0] >= 2 {
            publish(.failed("Repeated failures on this output; edit equalizer settings to retry"))
            return
        }
        do {
            if let session {
                if applied != profile || appliedRate != plan.sampleRate || formatChanged {
                    try session.update(profile: profile, plan: plan)
                    formatRetries = 0
                }
            } else {
                publish(.starting)
                let new = EqualizerSession(make(output))
                session = new
                try new.start(profile: profile, plan: plan, diagnostic: diagnostic)
                publish(.running)
            }
            applied = profile
            appliedRate = plan.sampleRate
        } catch {
            if let session {
                if status == .starting { session.monitor.unmuteBeforeDiagnosis() }
                let next: SessionStatus
                if session.removed {
                    next = .suspended("Device removed")
                } else if case SessionError.lowRate = error {
                    next = .suspended(error.localizedDescription)
                } else if formatChanged && status == .running {
                    formatRetries += 1
                    if formatRetries < 3 {
                        diagnostic("Format unavailable; waiting for configuration notification (\(formatRetries)/3)")
                        return
                    }
                    requiresEdit = true
                    next = .suspended("Format unavailable after three configuration notifications")
                    diagnostic(error.localizedDescription)
                } else if let error = error as? SessionError {
                    if case .layout = error { requiresEdit = true }
                    next = .suspended(error.localizedDescription)
                } else { next = .failed(error.localizedDescription) }
                finish(session, reason: next)
            }
        }
    }

    func finish(_ old: EqualizerSession, reason: SessionStatus) {
        guard old === session else { return }
        let result = old.monitor.end(reason)
        if result == .suspended("Tap input layout no longer verified") { requiresEdit = true }
        session = nil
        applied = nil
        appliedRate = nil
        formatRetries = 0
        if case .failed = result, let target { failures[target.uid, default: 0] += 1 }
        publish(result)
        old.closeIO()
        if old.monitor.hasTap { didTearDown() }
        if result == .suspended("Tap input layout no longer verified"), !usedLayoutRetry {
            usedLayoutRetry = true
            let token = UUID()
            layoutRetryToken = token
            scheduleLayoutRetry?(token)
        }
    }

    private func publish(_ next: SessionStatus) {
        guard status != next else { return }
        status = next
        report(next)
    }
}
