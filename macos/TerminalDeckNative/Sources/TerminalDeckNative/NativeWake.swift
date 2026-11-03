import Foundation
import Observation

/// One wait that ends at the first poke or when its time is up, whichever comes first.
/// For screens that would otherwise poll: what they wait on pokes it, and the time is
/// only the fallback.
@MainActor
final class NativeWake {
    private var waiting: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?

    func wait(upTo limit: Duration) async {
        guard !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                timer = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    self?.poke()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.poke() }
        }
    }

    func poke() {
        timer?.cancel()
        timer = nil
        waiting?.resume()
        waiting = nil
    }

    /// Waits until something `read` touches on an observable model changes, or `limit` passes.
    func waitForChange(of read: () -> Void, upTo limit: Duration) async {
        withObservationTracking(read) { [weak self] in
            Task { @MainActor in self?.poke() }
        }
        await wait(upTo: limit)
    }
}
