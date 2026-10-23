import Combine
import Foundation

@MainActor
protocol ReconciliationScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable
}

struct MainQueueScheduler: ReconciliationScheduling {
    nonisolated init() {}

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        let item = DispatchWorkItem {
            Task { @MainActor in work() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return AnyCancellable(item.cancel)
    }
}
