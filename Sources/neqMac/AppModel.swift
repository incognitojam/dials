import AppKit
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
    @Published private(set) var isReconciling = false

    @Published var policy: PersistedPolicy {
        didSet {
            persistence.save(policy)
            scheduleReconciliation(reason: "Policy updated")
        }
    }

    @Published private(set) var manualInputOverrideUID: String?
    @Published private(set) var manualOutputOverrideUID: String?

    private let audioClient: CoreAudioClient
    private let persistence: PolicyPersisting
    private var reconciliationWorkItem: DispatchWorkItem?
    private var lastDeviceIDs = Set<String>()
    private var hasLoadedInitialState = false

    init(
        audioClient: CoreAudioClient = CoreAudioClient(),
        persistence: PolicyPersisting = UserDefaultsPolicyStore()
    ) {
        self.audioClient = audioClient
        self.persistence = persistence
        let loadedPolicy = persistence.load()
        let repairedPolicy = Self.repairUnknownRuleNames(in: loadedPolicy)
        self.policy = repairedPolicy
        if repairedPolicy != loadedPolicy {
            persistence.save(repairedPolicy)
        }

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

    var inputDevices: [AudioDevice] {
        devices.filter { $0.direction == .input }
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
        devices.first { $0.uid == rule.uid && $0.direction == rule.direction }
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
        if excluded {
            if rule.direction == .input, manualInputOverrideUID == rule.uid {
                manualInputOverrideUID = nil
            } else if rule.direction == .output, manualOutputOverrideUID == rule.uid {
                manualOutputOverrideUID = nil
            }
        }
        appendEvent(
            excluded ? "Excluded \(rule.name) as an \(rule.direction.rawValue)" : "Allowed \(rule.name) as an \(rule.direction.rawValue)",
            level: excluded ? .warning : .info
        )
    }

    func moveRule(direction: DeviceDirection, fromOffsets: IndexSet, toOffset: Int) {
        if direction == .input {
            policy.inputRules.move(fromOffsets: fromOffsets, toOffset: toOffset)
        } else {
            policy.outputRules.move(fromOffsets: fromOffsets, toOffset: toOffset)
        }
    }

    func moveRule(direction: DeviceDirection, id: String, offset: Int) {
        var rules = self.rules(for: direction)
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), rules.count - 1)
        guard destination != index else { return }
        rules.swapAt(index, destination)
        if direction == .input {
            policy.inputRules = rules
        } else {
            policy.outputRules = rules
        }
        appendEvent("Changed \(direction.rawValue) priority", level: .info)
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

            let newIDs = Set(refreshedDevices.map(\.id))
            if hasLoadedInitialState {
                for connectedID in newIDs.subtracting(lastDeviceIDs) {
                    if let device = refreshedDevices.first(where: { $0.id == connectedID }) {
                        appendEvent("Connected \(device.name) · \(device.direction.title)", level: .success)
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
            discovered: devices.filter { $0.direction == .input },
            currentID: defaultInputID
        )
        updatedPolicy.outputRules = merged(
            existing: updatedPolicy.outputRules,
            discovered: devices.filter { $0.direction == .output },
            currentID: defaultOutputID
        )
        if updatedPolicy != policy {
            policy = updatedPolicy
        }
    }

    private func merged(
        existing: [DeviceRule],
        discovered: [AudioDevice],
        currentID: AudioObjectID
    ) -> [DeviceRule] {
        var rules = existing
        for device in discovered {
            if let index = rules.firstIndex(where: { $0.uid == device.uid }) {
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
                if device.audioObjectID == currentID {
                    rules.insert(newRule, at: 0)
                } else {
                    rules.append(newRule)
                }
            }
        }
        return rules
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

    private static func repairUnknownRuleNames(in policy: PersistedPolicy) -> PersistedPolicy {
        var repaired = policy
        let knownRules = (policy.inputRules + policy.outputRules).filter {
            $0.name != AudioDevice.unknownName
        }

        for index in repaired.inputRules.indices
            where repaired.inputRules[index].name == AudioDevice.unknownName {
            if let known = knownRule(for: repaired.inputRules[index].uid, in: knownRules) {
                repaired.inputRules[index].name = known.name
            }
        }
        for index in repaired.outputRules.indices
            where repaired.outputRules[index].name == AudioDevice.unknownName {
            if let known = knownRule(for: repaired.outputRules[index].uid, in: knownRules) {
                repaired.outputRules[index].name = known.name
            }
        }
        return repaired
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
        isReconciling = true
        defer { isReconciling = false }
        reconcile(direction: .output, reason: reason)
        reconcile(direction: .input, reason: reason)
    }

    private func reconcile(direction: DeviceDirection, reason: String) {
        let directionalDevices = devices.filter { $0.direction == direction }
        let availableUIDs = Set(directionalDevices.map(\.uid))
        let override = direction == .input ? manualInputOverrideUID : manualOutputOverrideUID
        guard let targetUID = RoutingDecisionEngine.targetUID(
            rules: rules(for: direction),
            availableUIDs: availableUIDs,
            manualOverrideUID: override
        ), let target = directionalDevices.first(where: { $0.uid == targetUID }) else {
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
           !inputDevices.contains(where: { $0.uid == manualInputOverrideUID }) {
            self.manualInputOverrideUID = nil
            appendEvent("Input override ended because the device disconnected", level: .info)
        }
        if let manualOutputOverrideUID,
           !outputDevices.contains(where: { $0.uid == manualOutputOverrideUID }) {
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
