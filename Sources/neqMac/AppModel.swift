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

    @Published private(set) var manualInputOverrideUID: String?
    @Published private(set) var manualOutputOverrideUID: String?

    private let audioClient: AudioDeviceClient
    private let persistence: PolicyPersisting
    private var reconciliationWorkItem: DispatchWorkItem?
    private var lastDeviceIDs = Set<String>()
    private var hasLoadedInitialState = false

    init(
        audioClient: AudioDeviceClient = CoreAudioClient(),
        persistence: PolicyPersisting = UserDefaultsPolicyStore()
    ) {
        self.audioClient = audioClient
        self.persistence = persistence
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

    var currentInput: AudioDevice? {
        devices.first { $0.direction == .input && $0.audioObjectID == defaultInputID }
    }

    var currentOutput: AudioDevice? {
        devices.first { $0.direction == .output && $0.audioObjectID == defaultOutputID }
    }

    func rules(for direction: DeviceDirection) -> [DeviceRule] {
        direction == .input ? policy.inputRules : policy.outputRules
    }

    func device(for rule: DeviceRule) -> AudioDevice? {
        let matches = devices.filter { rule.matches($0) }
        let currentID = rule.direction == .input ? defaultInputID : defaultOutputID
        return matches.first { $0.audioObjectID == currentID }
            ?? matches.first { $0.uid == rule.uid }
            ?? matches.first
    }

    func isCurrent(_ rule: DeviceRule) -> Bool {
        guard let device = device(for: rule) else { return false }
        return rule.direction == .input
            ? device.audioObjectID == defaultInputID
            : device.audioObjectID == defaultOutputID
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
        if enabled, let currentOutput {
            switchTo(currentOutput, reason: "System sounds enabled")
        }
    }

    func setExcluded(_ excluded: Bool, ruleID: String) {
        updateRule(id: ruleID) { $0.isExcluded = excluded }
        guard let rule = allRules.first(where: { $0.id == ruleID }) else { return }
        noteExclusionChange(of: rule)
    }

    /// Applies the allowed and Never use groups from preferences in one change.
    func arrange(direction: DeviceDirection, allowed: [String], excluded: [String]) {
        let currentRules = rules(for: direction)
        let arrangedRules = RuleOrdering.arranged(currentRules, allowed: allowed, excluded: excluded)
        guard arrangedRules != currentRules else { return }

        if direction == .input {
            policy.inputRules = arrangedRules
        } else {
            policy.outputRules = arrangedRules
        }

        let changedRules = arrangedRules.filter { rule in
            currentRules.first { $0.id == rule.id }?.isExcluded != rule.isExcluded
        }
        if changedRules.isEmpty {
            appendEvent("Changed \(direction.rawValue) priority", level: .info)
        }
        changedRules.forEach(noteExclusionChange)
    }

    private func noteExclusionChange(of rule: DeviceRule) {
        if rule.isExcluded {
            if rule.direction == .input, manualInputOverrideUID == rule.uid {
                manualInputOverrideUID = nil
            } else if rule.direction == .output, manualOutputOverrideUID == rule.uid {
                manualOutputOverrideUID = nil
            }
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

        if direction == .input {
            policy.inputRules.removeAll { removedIDs.contains($0.id) }
        } else {
            policy.outputRules.removeAll { removedIDs.contains($0.id) }
        }
        appendEvent(
            removable.count == 1
                ? "Removed \(removable[0].name) from the \(direction.rawValue) list"
                : "Removed \(removable.count) devices from the \(direction.rawValue) list",
            level: .info
        )
    }

    func useNow(_ rule: DeviceRule) {
        guard let device = device(for: rule), !rule.isExcluded else { return }
        if rule.direction == .input {
            manualInputOverrideUID = rule.uid
        } else {
            manualOutputOverrideUID = rule.uid
        }
        switchTo(device, reason: "Manual override")
    }

    func clearManualOverride(for direction: DeviceDirection) {
        if direction == .input {
            manualInputOverrideUID = nil
        } else {
            manualOutputOverrideUID = nil
        }
        appendEvent("Cleared manual \(direction.rawValue) override", level: .info)
        scheduleReconciliation(reason: "Manual override cleared", delay: 0.1)
    }

    func refreshHardwareState() {
        do {
            let refreshedDevices = restoreKnownNames(in: try audioClient.devices())
            devices = refreshedDevices
            defaultInputID = try audioClient.defaultDeviceID(for: .input)
            defaultOutputID = try audioClient.defaultDeviceID(for: .output)
            systemOutputID = (try? audioClient.defaultSystemOutputDeviceID()) ?? kAudioObjectUnknown
            lastError = nil
            mergeRules(with: refreshedDevices)

            let connectedRules = allRules.filter { device(for: $0) != nil }
            let newIDs = Set(connectedRules.map(\.id))
            if hasLoadedInitialState {
                for connectedID in newIDs.subtracting(lastDeviceIDs) {
                    if let rule = connectedRules.first(where: { $0.id == connectedID }) {
                        appendEvent("Connected \(rule.name) · \(rule.direction.title)", level: .success)
                    }
                }
                for disconnectedID in lastDeviceIDs.subtracting(newIDs) {
                    if let rule = allRules.first(where: { $0.id == disconnectedID }) {
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

    private var allRules: [DeviceRule] {
        policy.inputRules + policy.outputRules
    }

    private func updateRule(id: String, mutate: (inout DeviceRule) -> Void) {
        if let index = policy.inputRules.firstIndex(where: { $0.id == id }) {
            mutate(&policy.inputRules[index])
        } else if let index = policy.outputRules.firstIndex(where: { $0.id == id }) {
            mutate(&policy.outputRules[index])
        }
    }

    private func mergeRules(with devices: [AudioDevice]) {
        var updatedPolicy = policy
        updatedPolicy.inputRules = merged(
            existing: updatedPolicy.inputRules,
            discovered: devices.filter { $0.direction == .input }
        )
        updatedPolicy.outputRules = merged(
            existing: updatedPolicy.outputRules,
            discovered: devices.filter { $0.direction == .output }
        )
        if updatedPolicy != policy {
            policy = updatedPolicy
        }
    }

    private func merged(
        existing: [DeviceRule],
        discovered: [AudioDevice]
    ) -> [DeviceRule] {
        var rules = existing
        for device in discovered {
            if let index = rules.firstIndex(where: { $0.matches(device) }) {
                if device.name != AudioDevice.unknownName {
                    rules[index].name = device.name
                }
                rules[index].transportLabel = device.transportLabel
            } else {
                let newRule = DeviceRule(
                    uid: device.uid,
                    direction: device.direction,
                    name: device.name,
                    transportLabel: device.transportLabel,
                    isExcluded: false
                )
                rules.insert(newRule, at: RuleOrdering.insertionIndex(for: newRule, in: rules))
            }
        }
        return Self.deduplicatedRules(in: rules)
    }

    private static func deduplicatedRules(in rules: [DeviceRule]) -> [DeviceRule] {
        var uniqueRules: [DeviceRule] = []
        for rule in rules {
            if let key = rule.mergeKey,
               let index = uniqueRules.firstIndex(where: {
                   $0.direction == rule.direction && $0.mergeKey == key
               }) {
                // Keep the highest priority and honor any saved "Never use" choice.
                uniqueRules[index].isExcluded = uniqueRules[index].isExcluded || rule.isExcluded
            } else {
                uniqueRules.append(rule)
            }
        }
        return uniqueRules
    }

    private func restoreKnownNames(in discovered: [AudioDevice]) -> [AudioDevice] {
        let rules = allRules
        return discovered.map { device in
            guard device.name == AudioDevice.unknownName,
                  let knownRule = Self.knownRule(for: device.uid, in: rules) else {
                return device
            }
            return AudioDevice(
                audioObjectID: device.audioObjectID,
                uid: device.uid,
                name: knownRule.name,
                direction: device.direction,
                transportType: device.transportType
            )
        }
    }

    private static func knownRule(for uid: String, in rules: [DeviceRule]) -> DeviceRule? {
        rules.first {
            $0.uid == uid && $0.name != AudioDevice.unknownName
        } ?? rules.first {
            physicalUID($0.uid) == physicalUID(uid) && $0.name != AudioDevice.unknownName
        }
    }

    private static func physicalUID(_ uid: String) -> String {
        for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }

    private func handleHardwareChange() {
        refreshHardwareState()
        scheduleReconciliation(reason: "Audio hardware changed")
    }

    private func scheduleReconciliation(reason: String, delay: TimeInterval = 0.65) {
        reconciliationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.reconcile(reason: reason)
            }
        }
        reconciliationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reconcile(reason: String) {
        guard policy.automationEnabled else { return }
        reconcile(direction: .output, reason: reason)
        reconcile(direction: .input, reason: reason)
    }

    private func reconcile(direction: DeviceDirection, reason: String) {
        let directionalRules = rules(for: direction)
        let availableUIDs = Set(directionalRules.filter { device(for: $0) != nil }.map(\.uid))
        let override = direction == .input ? manualInputOverrideUID : manualOutputOverrideUID
        guard let targetUID = RoutingDecisionEngine.targetUID(
            rules: directionalRules,
            availableUIDs: availableUIDs,
            manualOverrideUID: override
        ), let targetRule = directionalRules.first(where: { $0.uid == targetUID }),
           let target = device(for: targetRule) else {
            appendEvent("No allowed \(direction.rawValue) device is available", level: .warning)
            return
        }

        let currentID = direction == .input ? defaultInputID : defaultOutputID
        guard target.audioObjectID != currentID else { return }
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
        if let manualInputOverrideUID,
           !policy.inputRules.contains(where: { $0.uid == manualInputOverrideUID && device(for: $0) != nil }) {
            self.manualInputOverrideUID = nil
            appendEvent("Input override ended because the device disconnected", level: .info)
        }
        if let manualOutputOverrideUID,
           !policy.outputRules.contains(where: { $0.uid == manualOutputOverrideUID && device(for: $0) != nil }) {
            self.manualOutputOverrideUID = nil
            appendEvent("Output override ended because the device disconnected", level: .info)
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
