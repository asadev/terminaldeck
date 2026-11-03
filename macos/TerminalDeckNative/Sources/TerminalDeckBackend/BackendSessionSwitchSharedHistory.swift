import Foundation

/// The switch's half of shared-projects.ts (session-switch-run.ts `subject`,
/// "the whole of the D1 fix"): both accounts are put on one history when both
/// can be, so the replacement reads the store the plan described.
///
/// 18 Oct (#428): planning only asks whether both would join (`wouldJoin`) and
/// describes the joined store; nothing on disk changes until the switch is made
/// (`joinBoth`, from `BackendSessionSwitchCoordinator.replace`). A second join
/// that fails puts the first one back, so no half-made join is left behind.
///
/// A link that cannot be made is not a switch that cannot happen: the failure
/// is answered as a reason to log and planning goes on over two stores.
public struct BackendSessionSwitchSharedHistory: Sendable {
    public var canJoin: @Sendable (BackendAccountProfile) async -> Bool
    /// What the join changed (nil: nothing, it already read the shared history).
    public var join: @Sendable (BackendAccountProfile) async throws -> BackendAppSharedProjects.JoinChange?
    public var undo: @Sendable (BackendAppSharedProjects.JoinChange) async throws -> Void
    /// The shared history's own folder, which every joined account reads.
    public var root: @Sendable () async -> String?
    public init(canJoin: @escaping @Sendable (BackendAccountProfile) async -> Bool,
                join: @escaping @Sendable (BackendAccountProfile) async throws -> BackendAppSharedProjects.JoinChange?,
                undo: @escaping @Sendable (BackendAppSharedProjects.JoinChange) async throws -> Void = { _ in },
                root: @escaping @Sendable () async -> String? = { nil }) {
        self.canJoin = canJoin; self.join = join; self.undo = undo; self.root = root
    }
    /// TS canJoinSharedHistory / joinSharedHistory over the native service.
    public static func projects(_ service: BackendAppSharedProjects) -> BackendSessionSwitchSharedHistory {
        BackendSessionSwitchSharedHistory(canJoin: { await service.canJoin($0) }, join: { try await service.joinRecorded($0) },
                                          undo: { try await service.undo($0) }, root: { service.root.path })
    }
    /// Whether a switch between the two would put both on one history. Reads only.
    public func wouldJoin(source: BackendAccountProfile, target: BackendAccountProfile) async -> Bool {
        guard await canJoin(source) else { return false }
        return await canJoin(target)
    }
    /// Join both sides when both can join. Answers nil when nothing went
    /// wrong, or the reason the link could not be made (TS logs it as a warning).
    public func joinBoth(source: BackendAccountProfile, target: BackendAccountProfile) async -> String? {
        guard await wouldJoin(source: source, target: target) else { return nil }
        let reason = "could not join the shared conversation history (from \(source.id) to \(target.id)): "
        let first: BackendAppSharedProjects.JoinChange?
        do { first = try await join(source) } catch { return reason + error.localizedDescription }
        do { _ = try await join(target); return nil }
        catch {
            let failed = reason + error.localizedDescription
            guard let first else { return failed }
            do { try await undo(first) }
            catch { return failed + "; \(source.id) could not be put back on its own history either: " + error.localizedDescription }
            return failed
        }
    }
}
