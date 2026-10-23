import Combine
import CoreAudio
import Foundation
@testable import neqMac

final class MemoryPolicyStore: PolicyPersisting {
    private let initialPolicy: PersistedPolicy
    private(set) var savedPolicy: PersistedPolicy?

    init(_ policy: PersistedPolicy = PersistedPolicy()) {
        initialPolicy = policy
    }

    func load() -> PersistedPolicy { initialPolicy }
    func save(_ policy: PersistedPolicy) { savedPolicy = policy }
}

final class TestAudioClient: AudioDeviceClient {
    var onHardwareChange: (() -> Void)?
    var availableDevices: [AudioDevice]
    var outputID: AudioObjectID
    private(set) var selections: [AudioDevice] = []

    init(devices: [AudioDevice] = [], outputID: AudioObjectID = kAudioObjectUnknown) {
        availableDevices = devices
        self.outputID = outputID
    }

    func devices() throws -> [AudioDevice] { availableDevices }
    func defaultDeviceID(for direction: DeviceDirection) throws -> AudioObjectID {
        direction == .output ? outputID : kAudioObjectUnknown
    }
    func defaultSystemOutputDeviceID() throws -> AudioObjectID { outputID }
    func setDefaultDevice(_ device: AudioDevice, includeSystemSounds: Bool) throws {
        selections.append(device)
        if device.direction == .output { outputID = device.audioObjectID }
    }
}

@MainActor
final class ManualScheduler: ReconciliationScheduling {
    private var pending: [(id: UUID, work: @MainActor () -> Void)] = []

    var pendingCount: Int { pending.count }

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        let id = UUID()
        pending.append((id, work))
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated { self?.pending.removeAll { $0.id == id } }
        }
    }

    func runPending() {
        let due = pending
        pending = []
        due.forEach { $0.work() }
    }
}
