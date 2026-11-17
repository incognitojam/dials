import Foundation

package struct PersistedPolicy: Codable, Equatable {
    package var automationEnabled = false
    package var includeSystemSounds = true
    package var inputRules: [DeviceRule] = []
    package var outputRules: [DeviceRule] = []

    package var allRules: [DeviceRule] { inputRules + outputRules }

    package subscript(rules direction: DeviceDirection) -> [DeviceRule] {
        get { direction == .input ? inputRules : outputRules }
        set {
            if direction == .input {
                inputRules = newValue
            } else {
                outputRules = newValue
            }
        }
    }
}

package protocol PolicyPersisting {
    func load() -> PersistedPolicy
    func save(_ policy: PersistedPolicy)
}

package struct UserDefaultsPolicyStore: PolicyPersisting {
    private let defaults: UserDefaults
    private let key = "neqmac.routing-policy.v1"

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func load() -> PersistedPolicy {
        guard let data = defaults.data(forKey: key),
              let policy = try? JSONDecoder().decode(PersistedPolicy.self, from: data) else {
            return PersistedPolicy()
        }
        return policy
    }

    package func save(_ policy: PersistedPolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: key)
    }
}
