import Combine
import CoreAudio
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultInputID: AudioObjectID = kAudioObjectUnknown
    @Published private(set) var defaultOutputID: AudioObjectID = kAudioObjectUnknown
    @Published private(set) var systemOutputID: AudioObjectID = kAudioObjectUnknown
    @Published private(set) var events: [RoutingEvent] = []
    @Published private(set) var lastError: String?

    @Published var policy: PersistedPolicy {
        didSet {
            persistence.save(policy)
            scheduleReconciliation(reason: "Policy updated")
        }
    }

    @Published private(set) var manualOverrideUIDs: [DeviceDirection: String] = [:]

    private let audioClient: AudioDeviceClient
    private let persistence: PolicyPersisting
    private let scheduler: ReconciliationScheduling
    private var pendingReconciliation: AnyCancellable?
    private var lastDeviceIDs = Set<String>()
    private var hasLoadedInitialState = false

    init(
        audioClient: AudioDeviceClient = CoreAudioClient(),
        persistence: PolicyPersisting = UserDefaultsPolicyStore(),
        scheduler: ReconciliationScheduling = MainQueueScheduler()
    ) {
        self.audioClient = audioClient
        self.persistence = persistence
        self.scheduler = scheduler
        self.policy = persistence.load()

        audioClient.onHardwareChange = { [weak self] in
            Task { @MainActor in
                self?.handleHardwareChange()
            }
        }

        refreshHardwareState()
        appendEvent("Device guardian is ready", level: .success)
        if policy.automationEnabled {
            scheduleReconciliation(reason: "App launched", delay: 0.8)
        }
    }

    var outputDevices: [AudioDevice] {
        devices.filter { $0.direction == .output }
    }

    func defaultID(for direction: DeviceDirection) -> AudioObjectID {
        direction == .input ? defaultInputID : defaultOutputID
    }

    func currentDevice(for direction: DeviceDirection) -> AudioDevice? {
        devices.first { $0.direction == direction && $0.audioObjectID == defaultID(for: direction) }
    }

    func manualOverrideUID(for direction: DeviceDirection) -> String? {
        manualOverrideUIDs[direction]
    }

    func rules(for direction: DeviceDirection) -> [DeviceRule] {
        policy[rules: direction]
    }

    func device(for rule: DeviceRule) -> AudioDevice? {
        let matches = devices.filter { rule.matches($0) }
        let currentID = defaultID(for: rule.direction)
        return matches.first { $0.audioObjectID == currentID }
            ?? matches.first { $0.uid == rule.uid }
            ?? matches.first
    }

    func isCurrent(_ rule: DeviceRule) -> Bool {
        device(for: rule)?.audioObjectID == defaultID(for: rule.direction)
    }

    func setAutomationEnabled(_ enabled: Bool) {
        policy.automationEnabled = enabled
        appendEvent(
            enabled ? "Automatic routing enabled" : "Automatic routing paused",
            level: enabled ? .success : .info
        )
        if enabled {
            scheduleReconciliation(reason: "Automation enabled", delay: 0.1)
        }
    }

    func setIncludeSystemSounds(_ enabled: Bool) {
        policy.includeSystemSounds = enabled
        appendEvent(
            enabled ? "System sounds will follow the output" : "System sounds will stay independent",
            level: .info
        )
        if enabled, let currentOutput = currentDevice(for: .output) {
            switchTo(currentOutput, reason: "System sounds enabled")
        }
    }

    func setExcluded(_ excluded: Bool, ruleID: String) {
        updateRule(id: ruleID) { $0.isExcluded = excluded }
        guard let rule = policy.allRules.first(where: { $0.id == ruleID }) else { return }
        noteExclusionChange(of: rule)
    }

    /// Applies the allowed and Never use groups from preferences in one change.
    func arrange(direction: DeviceDirection, allowed: [String], excluded: [String]) {
        let currentRules = rules(for: direction)
        let arrangedRules = RuleOrdering.arranged(currentRules, allowed: allowed, excluded: excluded)
        guard arrangedRules != currentRules else { return }

        policy[rules: direction] = arrangedRules

        let changedRules = arrangedRules.filter { rule in
            currentRules.first { $0.id == rule.id }?.isExcluded != rule.isExcluded
        }
        if changedRules.isEmpty {
            appendEvent("Changed \(direction.rawValue) priority", level: .info)
        }
        changedRules.forEach(noteExclusionChange)
    }

    private func noteExclusionChange(of rule: DeviceRule) {
        if rule.isExcluded, manualOverrideUIDs[rule.direction] == rule.uid {
            manualOverrideUIDs[rule.direction] = nil
        }
        appendEvent(
            rule.isExcluded
                ? "Excluded \(rule.name) as an \(rule.direction.rawValue)"
                : "Allowed \(rule.name) as an \(rule.direction.rawValue)",
            level: rule.isExcluded ? .warning : .info
        )
    }

    /// Connected devices are skipped: discovery would add them straight back.
    func removeRules(direction: DeviceDirection, ids: Set<String>) {
        let removable = rules(for: direction).filter { ids.contains($0.id) && device(for: $0) == nil }
        guard !removable.isEmpty else { return }
        let removedIDs = Set(removable.map(\.id))

        policy[rules: direction].removeAll { removedIDs.contains($0.id) }
        appendEvent(
            removable.count == 1
                ? "Removed \(removable[0].name) from the \(direction.rawValue) list"
                : "Removed \(removable.count) devices from the \(direction.rawValue) list",
            level: .info
        )
    }

    func useNow(_ rule: DeviceRule) {
        guard let device = device(for: rule), !rule.isExcluded else { return }
        manualOverrideUIDs[rule.direction] = rule.uid
        switchTo(device, reason: "Manual override")
    }

    func clearManualOverride(for direction: DeviceDirection) {
        manualOverrideUIDs[direction] = nil
        appendEvent("Cleared manual \(direction.rawValue) override", level: .info)
        scheduleReconciliation(reason: "Manual override cleared", delay: 0.1)
    }

    func refreshHardwareState() {
        do {
            let refreshedDevices = RuleMerging.restoringKnownNames(in: try audioClient.devices(), from: policy.allRules)
            devices = refreshedDevices
            defaultInputID = try audioClient.defaultDeviceID(for: .input)
            defaultOutputID = try audioClient.defaultDeviceID(for: .output)
            systemOutputID = (try? audioClient.defaultSystemOutputDeviceID()) ?? kAudioObjectUnknown
            lastError = nil
            mergeRules(with: refreshedDevices)

            let connectedRules = policy.allRules.filter { device(for: $0) != nil }
            let newIDs = Set(connectedRules.map(\.id))
            if hasLoadedInitialState {
                for connectedID in newIDs.subtracting(lastDeviceIDs) {
                    if let rule = connectedRules.first(where: { $0.id == connectedID }) {
                        appendEvent("Connected \(rule.name) · \(rule.direction.title)", level: .success)
                    }
                }
                for disconnectedID in lastDeviceIDs.subtracting(newIDs) {
                    if let rule = policy.allRules.first(where: { $0.id == disconnectedID }) {
                        appendEvent("Disconnected \(rule.name) · \(rule.direction.title)", level: .warning)
                    }
                }
            }
            lastDeviceIDs = newIDs
            hasLoadedInitialState = true
            clearUnavailableOverrides()
        } catch {
            lastError = error.localizedDescription
            appendEvent(error.localizedDescription, level: .warning)
        }
    }

    private func updateRule(id: String, mutate: (inout DeviceRule) -> Void) {
        for direction in DeviceDirection.allCases {
            if let index = policy[rules: direction].firstIndex(where: { $0.id == id }) {
                mutate(&policy[rules: direction][index])
                return
            }
        }
    }

    private func mergeRules(with devices: [AudioDevice]) {
        var updatedPolicy = policy
        for direction in DeviceDirection.allCases {
            updatedPolicy[rules: direction] = RuleMerging.merged(
                existing: updatedPolicy[rules: direction],
                discovered: devices.filter { $0.direction == direction }
            )
        }
        if updatedPolicy != policy {
            policy = updatedPolicy
        }
    }

    func handleHardwareChange() {
        refreshHardwareState()
        scheduleReconciliation(reason: "Audio hardware changed")
    }

    private func scheduleReconciliation(reason: String, delay: TimeInterval = 0.65) {
        pendingReconciliation?.cancel()
        pendingReconciliation = scheduler.schedule(after: delay) { [weak self] in
            self?.reconcile(reason: reason)
        }
    }

    private func reconcile(reason: String) {
        guard policy.automationEnabled else { return }
        reconcile(direction: .output, reason: reason)
        reconcile(direction: .input, reason: reason)
    }

    private func reconcile(direction: DeviceDirection, reason: String) {
        let directionalRules = rules(for: direction)
        let availableUIDs = Set(directionalRules.filter { device(for: $0) != nil }.map(\.uid))
        let override = manualOverrideUIDs[direction]
        guard let targetUID = RoutingDecisionEngine.targetUID(
            rules: directionalRules,
            availableUIDs: availableUIDs,
            manualOverrideUID: override
        ), let targetRule = directionalRules.first(where: { $0.uid == targetUID }),
           let target = device(for: targetRule) else {
            appendEvent("No allowed \(direction.rawValue) device is available", level: .warning)
            return
        }

        guard target.audioObjectID != defaultID(for: direction) else { return }
        switchTo(target, reason: reason)
    }

    private func switchTo(_ device: AudioDevice, reason: String) {
        do {
            try audioClient.setDefaultDevice(device, includeSystemSounds: policy.includeSystemSounds)
            if device.direction == .input {
                defaultInputID = device.audioObjectID
            } else {
                defaultOutputID = device.audioObjectID
                if policy.includeSystemSounds {
                    systemOutputID = device.audioObjectID
                }
            }
            lastError = nil
            appendEvent("Selected \(device.name) as \(device.direction.rawValue) · \(reason)", level: .success)
        } catch {
            lastError = error.localizedDescription
            appendEvent(error.localizedDescription, level: .warning)
        }
    }

    private func clearUnavailableOverrides() {
        for direction in DeviceDirection.allCases {
            guard let uid = manualOverrideUIDs[direction],
                  !policy[rules: direction].contains(where: { $0.uid == uid && device(for: $0) != nil })
            else { continue }
            manualOverrideUIDs[direction] = nil
            appendEvent("\(direction.title) override ended because the device disconnected", level: .info)
        }
    }

    private func appendEvent(_ message: String, level: RoutingEvent.Level) {
        guard events.first?.message != message else { return }
        events.insert(RoutingEvent(id: UUID(), date: Date(), message: message, level: level), at: 0)
        if events.count > 80 {
            events.removeLast(events.count - 80)
        }
    }
}
