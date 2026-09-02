import Foundation

enum RuleOrderEdge {
    case first
    case last
}

enum RuleOrdering {
    static func moving(_ id: String, to edge: RuleOrderEdge, in rules: [DeviceRule]) -> [DeviceRule] {
        guard let sourceIndex = rules.firstIndex(where: { $0.id == id }) else { return rules }

        var reordered = rules
        let rule = reordered.remove(at: sourceIndex)
        switch edge {
        case .first:
            reordered.insert(rule, at: 0)
        case .last:
            reordered.append(rule)
        }
        return reordered
    }
}
