import Foundation

/// The switch's half of shared-projects.ts (session-switch-run.ts `subject`,
/// "the whole of the D1 fix"): before the restore planner reads the target's
/// conversation store, both accounts are put on one history when both can be,
/// so the plan describes the store the replacement will really read.
///
/// A link that cannot be made is not a switch that cannot happen: the failure
/// is answered as a reason to log and planning goes on over two stores.
public struct BackendSessionSwitchSharedHistory: Sendable {
    public var canJoin: @Sendable (BackendAccountProfile) async -> Bool
    public var join: @Sendable (BackendAccountProfile) async throws -> Bool
    public init(canJoin: @escaping @Sendable (BackendAccountProfile) async -> Bool,
                join: @escaping @Sendable (BackendAccountProfile) async throws -> Bool) {
        self.canJoin = canJoin; self.join = join
    }
    /// TS canJoinSharedHistory / joinSharedHistory over the native service.
    public static func projects(_ service: BackendAppSharedProjects) -> BackendSessionSwitchSharedHistory {
        BackendSessionSwitchSharedHistory(canJoin: { await service.canJoin($0) }, join: { try await service.join($0) })
    }
    /// Join both sides when both can join. Answers nil when nothing went
    /// wrong, or the reason the link could not be made (TS logs it as a warning).
    public func joinBoth(source: BackendAccountProfile, target: BackendAccountProfile) async -> String? {
        guard await canJoin(source), await canJoin(target) else { return nil }
        do {
            _ = try await join(source)
            _ = try await join(target)
            return nil
        } catch {
            return "could not join the shared conversation history (from \(source.id) to \(target.id)): " + error.localizedDescription
        }
    }
}
