import Foundation

enum RuleMerging {
    /// Updates rules for devices already known and inserts rules for new ones.
    static func merged(existing: [DeviceRule], discovered: [AudioDevice]) -> [DeviceRule] {
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
        return deduplicated(rules)
    }

    /// Collapses rules for the same device into the highest-priority one,
    /// keeping it excluded if any of them was.
    static func deduplicated(_ rules: [DeviceRule]) -> [DeviceRule] {
        var uniqueRules: [DeviceRule] = []
        for rule in rules {
            if let key = rule.mergeKey,
               let index = uniqueRules.firstIndex(where: {
                   $0.direction == rule.direction && $0.mergeKey == key
               }) {
                uniqueRules[index].isExcluded = uniqueRules[index].isExcluded || rule.isExcluded
            } else {
                uniqueRules.append(rule)
            }
        }
        return uniqueRules
    }

    static func restoringKnownNames(in discovered: [AudioDevice], from rules: [DeviceRule]) -> [AudioDevice] {
        discovered.map { device in
            guard device.name == AudioDevice.unknownName,
                  let knownRule = knownRule(for: device.uid, in: rules) else {
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
}
