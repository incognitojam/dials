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

    /// Connection types in the order a typical setup prefers them: devices you
    /// connect on purpose first, the Mac's own hardware and virtual devices last.
    static func transportRank(of transport: String) -> Int {
        switch transport {
        case "Bluetooth": 0
        case "AirPlay": 1
        case "USB": 2
        case "HDMI", "DisplayPort": 3
        case "Built-in": 4
        case "Virtual", "Aggregate": 6
        default: 5
        }
    }

    /// Where a newly discovered device joins the list: after the last allowed
    /// device of the same or a preferred connection type, so a new pair of
    /// headphones lands with the other wireless devices rather than at the
    /// bottom. Applied to every device on first launch, this sorts by type.
    static func insertionIndex(for rule: DeviceRule, in rules: [DeviceRule]) -> Int {
        let rank = transportRank(of: rule.displayTransport)
        if let index = rules.lastIndex(where: {
            !$0.isExcluded && transportRank(of: $0.displayTransport) <= rank
        }) {
            return index + 1
        }
        return rules.firstIndex { !$0.isExcluded } ?? rules.count
    }
}
