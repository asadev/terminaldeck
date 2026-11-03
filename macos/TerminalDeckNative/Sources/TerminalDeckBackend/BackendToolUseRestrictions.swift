import Foundation
import TerminalDeckNativeCore

/// Identity comes only from app-owned task/session facts. Arguments never select
/// the profile. Reassignment cannot switch an in-flight call to a looser policy.
public struct BackendToolUseRestrictions: Sendable {
    public static func authenticatedSessionCaller(_ context: BackendDeckCoreSecurityCallContext,
                                                   endpoint: BackendDeckCoreSessionEndpoint?) async throws -> BackendDeckCoreSecurityCaller {
        guard context.caller.kind == .session else { throw BackendDeckCoreSecurityRefusal(.notGranted, "A verified session caller is required.") }
        if let proof = context.relaySessionProof { return try await proof.currentCaller(for: context) }
        guard let endpoint else { throw BackendDeckCoreSecurityRefusal(.notGranted, "The original session registration is unavailable.") }
        return try await endpoint.currentCaller(for: context.native)
    }
    public struct Subject: Equatable, Sendable {
        public let stamp: String
        public let profileID: String?
        public init(stamp: String, profileID: String? = nil) { self.stamp = stamp; self.profileID = profileID }
    }
    public let subject: @Sendable (BackendDeckCoreSecurityCallContext) async throws -> Subject
    public let profile: @Sendable (String) async throws -> NativeRPCValue?
    public init(subject: @escaping @Sendable (BackendDeckCoreSecurityCallContext) async throws -> Subject,
                profile: @escaping @Sendable (String) async throws -> NativeRPCValue?) { self.subject = subject; self.profile = profile }
    public func inspect(_ context: BackendDeckCoreSecurityCallContext, tool: String, arguments: NativeRPCValue, expected: String?) async throws -> String {
        let first = try await subject(context)
        if let expected, first.stamp != expected { throw refused() }
        if let id = first.profileID {
            guard let row = try await profile(id), row["id"].string == id else { throw refused() }
            do { try ToolUseRestrictions.require(row["toolUseRestrictions"], tool: tool, arguments: arguments) }
            catch { throw refused() }
        }
        guard try await subject(context) == first, !context.cancellation.isCancelled else { throw refused() }
        // Subject validation can itself suspend. Read the current policy last,
        // rather than returning an earlier policy snapshot after those waits.
        if let id = first.profileID {
            guard let row = try await profile(id), row["id"].string == id else { throw refused() }
            do { try ToolUseRestrictions.require(row["toolUseRestrictions"], tool: tool, arguments: arguments) } catch { throw refused() }
        }
        guard !context.cancellation.isCancelled else { throw refused() }
        return first.stamp
    }
    public static func resolve(caller: BackendDeckCoreSecurityCaller, live: BackendSessionMeta?, task: BackendTaskRecord?, namedProfile: String?, lead: Bool) throws -> Subject {
        guard caller.kind == .session else { return .init(stamp: "independent:" + caller.kind.rawValue + ":" + (caller.keyID ?? "")) }
        guard let id = caller.sessionID, !id.isEmpty, (caller.machineID ?? "").isEmpty,
              let live, live.id == id, live.exitCode == nil else { throw BackendDeckCoreSecurityRefusal(.notGranted, "The local agent session could not be verified.") }
        let base = id + ":" + String(live.createdAt)
        if let task {
            guard task.sessionID == id, task.value["stopped"].bool != true, task.value["archivedAt"].isNullish else { throw BackendDeckCoreSecurityRefusal(.notGranted, "This session no longer holds its saved agent task.") }
            if task.assigneeKind == "agent" {
                guard let id = task.value["assignee"]["agentId"].string, !id.isEmpty else { throw BackendDeckCoreSecurityRefusal(.notGranted, "This task has no valid saved agent binding.") }
                return .init(stamp: "task:" + base + ":" + task.id + ":" + id, profileID: id)
            }
            guard lead else { throw BackendDeckCoreSecurityRefusal(.notGranted, "This task is no longer assigned to its saved worker.") }
        }
        if let namedProfile { return .init(stamp: "profile:" + base + ":" + namedProfile, profileID: namedProfile) }
        if lead { return .init(stamp: "lead:" + base) }
        return .init(stamp: "unprofiled:" + base)
    }
    private func refused() -> BackendDeckCoreSecurityRefusal { .init(.notGranted, "This verified agent's current Deck tool rules or binding refuse the operation.") }
}
