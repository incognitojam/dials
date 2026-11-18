import Foundation

package enum RuleMerging {
    /// Updates rules for devices already known and inserts rules for new ones.
    package static func merged(existing: [DeviceRule], discovered: [any RoutingDevice]) -> [DeviceRule] {
        var rules = existing
        for device in discovered {
            if let index = rules.firstIndex(where: { $0.matches(device) }) {
                if device.name != unknownDeviceName {
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

    package static func restoringKnownNames<Device: RoutingDevice>(in discovered: [Device], from rules: [DeviceRule]) -> [Device] {
        discovered.map { device in
            guard device.name == unknownDeviceName,
                  let knownRule = knownRule(for: device.uid, in: rules) else {
                return device
            }
            var restored = device
            restored.name = knownRule.name
            return restored
        }
    }

    private static func knownRule(for uid: String, in rules: [DeviceRule]) -> DeviceRule? {
        rules.first {
            $0.uid == uid && $0.name != unknownDeviceName
        } ?? rules.first {
            physicalUID($0.uid) == physicalUID(uid) && $0.name != unknownDeviceName
        }
    }

    private static func physicalUID(_ uid: String) -> String {
        for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }
}
