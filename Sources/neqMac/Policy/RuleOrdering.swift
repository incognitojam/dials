import Foundation

enum RuleOrdering {
    /// Rebuilds a priority list from the allowed and Never use groups shown in
    /// preferences. Excluded rules are stored after every allowed rule, since
    /// their position never affects routing. Rules missing from both groups
    /// keep their relative order at the end.
    static func arranged(_ rules: [DeviceRule], allowed: [String], excluded: [String]) -> [DeviceRule] {
        let rulesByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func place(_ ids: [String], excluded: Bool) -> [DeviceRule] {
            ids.compactMap { id in
                guard var rule = rulesByID[id] else { return nil }
                rule.isExcluded = excluded
                return rule
            }
        }

        let placedIDs = Set(allowed + excluded)
        return place(allowed, excluded: false)
            + place(excluded, excluded: true)
            + rules.filter { !placedIDs.contains($0.id) }
    }
}
