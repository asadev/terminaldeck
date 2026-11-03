import Foundation

/// `cost:watch` per folder, counted, so one reader letting go never stops another's.
@MainActor
enum NativeCostWatch {
    private static var counts: [String: Int] = [:]

    /// Counted at once; the task answers whether the engine is watching (`summary.watching`).
    @discardableResult
    static func retain(_ cwd: String) -> Task<Bool, Never> {
        counts[cwd, default: 0] += 1
        return Task {
            let summary = try? await EngineBridge.shared.invoke("cost:watch", [cwd]) as? [String: Any]
            return summary?["watching"] as? Bool == true
        }
    }

    static func release(_ cwd: String) {
        let count = counts[cwd] ?? 0
        if count <= 1 {
            counts[cwd] = nil
            Task { _ = try? await EngineBridge.shared.invoke("cost:unwatch", [cwd]) }
        } else {
            counts[cwd] = count - 1
        }
    }
}
