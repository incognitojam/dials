import Foundation

struct PersistedPolicy: Codable, Equatable {
    var automationEnabled = false
    var includeSystemSounds = true
    var inputRules: [DeviceRule] = []
    var outputRules: [DeviceRule] = []
}

protocol PolicyPersisting {
    func load() -> PersistedPolicy
    func save(_ policy: PersistedPolicy)
}

struct UserDefaultsPolicyStore: PolicyPersisting {
    private let defaults: UserDefaults
    private let key = "neqmac.routing-policy.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedPolicy {
        guard let data = defaults.data(forKey: key),
              let policy = try? JSONDecoder().decode(PersistedPolicy.self, from: data) else {
            return PersistedPolicy()
        }
        return policy
    }

    func save(_ policy: PersistedPolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: key)
    }
}
