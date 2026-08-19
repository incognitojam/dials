import Foundation

enum RoutingDecisionEngine {
    static func targetUID(
        rules: [DeviceRule],
        availableUIDs: Set<String>,
        manualOverrideUID: String?
    ) -> String? {
        if let manualOverrideUID,
           availableUIDs.contains(manualOverrideUID),
           rules.first(where: { $0.uid == manualOverrideUID })?.isExcluded == false {
            return manualOverrideUID
        }

        return rules.first {
            !$0.isExcluded && availableUIDs.contains($0.uid)
        }?.uid
    }
}
