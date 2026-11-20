import Foundation
import EqualizerCore
import EqualizerEngineCore

enum SessionStatus: Equatable {
    case idle, starting, reconfiguring, running, failed(String), suspended(String)
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
    case deviceRemoved, lowRate, superseded, layout(String)
    var errorDescription: String? {
        switch self {
        case let .layout(reason): reason
        case .deviceRemoved: "Device removed"
        case .lowRate: "Output rate below 32 kHz"
        case .superseded: "Output or settings changed while starting"
        }
    }
}

// Coordinates the watchdog thread and the serial session queue. Never entered from IO.
final class SessionGuard {
    static let callbackTolerance: TimeInterval = 0.350
    static let activityFreshness: TimeInterval = 0.250
    static let reconfigurationWindow: TimeInterval = 2
    static let restartIO = SessionStatus.suspended("IO did not resume after reconfiguration")
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

    private var deadline: TimeInterval?
    private var verified = false
    private var openingBeat: UInt64 = 0
    var recoveringIO = false

    func formatChanged(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        guard ended == nil else { return }
        if deadline == nil {
            deadline = now + Self.reconfigurationWindow
            openingBeat = device.heartbeat
        }
        verified = false
    }

    func verifiedFormat() {
        lock.lock()
        defer { lock.unlock() }
        verified = true
    }

    func check(now: TimeInterval) -> SessionStatus? {
        lock.lock()
        defer { lock.unlock() }
        if let ended { return ended }
        let beat = device.heartbeat
        let idle = lastPoll.map { playing == false && now - $0 <= Self.activityFreshness } == true
        if lastBeat != beat {
            since = now
            lastBeat = beat
        }
        if let deadline {
            guard now >= deadline else { return nil }
            self.deadline = nil
            if verified && (idle || (beat != openingBeat && now - since < Self.callbackTolerance)) {
                return .running
            }
            release()
            if device.removed { ended = .suspended("Device removed") }
            else if recoveringIO && beat == 0 { ended = .failed("Rebuilt audio callback stalled") }
            else { ended = Self.restartIO }
            return ended
        }
        guard !idle, now - since >= Self.callbackTolerance else {
            if idle { lastBeat = nil }
            return nil
        }
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
                    if reason != .running { return }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    let verification = DispatchQueue(label: "dev.neqmac.equalizer.verify")

    func update(profile: EQInfo, plan: EqualizerPlan) throws { try backend.configure(profile, plan: plan) }

    func closeIO() {
        verification.sync {}
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
    private var applied: (profile: EQInfo, plan: EqualizerPlan)?
    private let queue: DispatchQueue
    private var checking = false
    private var dirty = false
    private var requiresEdit = false
    private var layoutRetryToken: UUID?
    private var usedLayoutRetry = false
    var scheduleLayoutRetry: ((UUID) -> Void)?

    private let diagnostic: (String) -> Void
    private var failures: [String: Int] = [:]
    private let didTearDown: () -> Void
    private let report: (SessionStatus) -> Void

    init(queue: DispatchQueue = .main, diagnostic: @escaping (String) -> Void = { _ in }, didTearDown: @escaping () -> Void = {}, report: @escaping (SessionStatus) -> Void) {
        self.queue = queue
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

    func formatChanged(retrySettling: Bool = true) {
        guard let session, let applied else { return }
        session.monitor.formatChanged()
        publish(.reconfiguring)
        if checking { dirty = true; return }
        checking = true
        session.verification.async { [weak self] in
            let result = Result {
                if session.removed { throw SessionError.deviceRemoved }
                try session.update(profile: applied.profile, plan: applied.plan)
            }
            self?.queue.async { [weak self] in
                guard let self, self.session === session else { return }
                checking = false
                if case .failure(SessionError.deviceRemoved) = result {
                    finish(session, reason: .suspended("Device removed"))
                } else if case .failure(SessionError.lowRate) = result {
                    finish(session, reason: .suspended(SessionError.lowRate.localizedDescription))
                } else if dirty {
                    dirty = false
                    formatChanged()
                } else if case .success = result {
                    session.monitor.verifiedFormat()
                } else if retrySettling {
                    queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                        guard let self, self.session === session, status == .reconfiguring, !checking else { return }
                        formatChanged(retrySettling: false)
                    }
                }
            }
        }
    }

    func observed(_ old: EqualizerSession, _ reason: SessionStatus, evaluate: () -> Void) {
        guard session === old else { return }
        if reason == .running {
            if !checking { publish(.running) }
        } else {
            finish(old, reason: reason)
            if status == SessionGuard.restartIO {
                evaluate()
            }
        }
    }

    func reconcile(_ desired: DesiredEqualizer, output: AudioDevice?, retry: Bool = false,
                   make: (AudioDevice) -> TapDevice) {
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
            if session != nil {
                guard applied?.profile != profile || applied?.plan.sampleRate != plan.sampleRate else { return }
                applied = (profile, plan)
                formatChanged()
            } else {
                let recovering = status == SessionGuard.restartIO
                publish(.starting)
                let new = EqualizerSession(make(output))
                new.monitor.recoveringIO = recovering
                session = new
                try new.start(profile: profile, plan: plan, diagnostic: diagnostic)
                applied = (profile, plan)
                publish(.running)
            }
        } catch {
            if let session {
                if status == .starting { session.monitor.unmuteBeforeDiagnosis() }
                let next: SessionStatus
                if session.removed {
                    next = .suspended("Device removed")
                } else if case SessionError.lowRate = error {
                    next = .suspended(error.localizedDescription)
                } else if let error = error as? SessionError {
                    if case .layout = error, session.monitor.recoveringIO {
                        next = .failed(error.localizedDescription)
                    } else {
                        if case .layout = error { requiresEdit = true }
                        next = .suspended(error.localizedDescription)
                    }
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
        checking = false
        dirty = false
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
