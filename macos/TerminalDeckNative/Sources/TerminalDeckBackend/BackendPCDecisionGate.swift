import Foundation
import CryptoKit
import TerminalDeckNativeCore

public enum BackendPCDecisionMarker {
    public static func fingerprint(_ task: BackendTaskRecord) -> String {
        let value = NativeRPCValue.object(PCDecisions.scopeKeys.map { .init($0, task.value[$0].isNullish ? .null : task.value[$0]) })
        return SHA256.hash(data: (try? value.encodedJSON()) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    public static func executionReference(_ task: BackendTaskRecord) -> String {
        NativeRPCValue.object([.init("task", .string(task.id)), .init("scope", .string(fingerprint(task))),
            .init("decisionID", task.value["decisionID"].isNullish ? .null : task.value["decisionID"]),
            .init("decisionEpoch", task.value["decisionEpoch"].isNullish ? .null : task.value["decisionEpoch"])]).compact
    }
}
/// Intersect the arrival grant with the freshly read credential. A broader
/// replacement key never widens an already pending decision request.
public enum BackendPCDecisionGrant {
    public static func require(original: BackendDeckCoreSecurityCaller, current: BackendDeckCoreSecurityCaller,
                               key: NativeRPCValue = .null, tool: String, folder: String, mutation: Bool) throws {
        let tier: BackendMCPTier = mutation ? (tool == "decisions.owner" || tool == "decisions_owner" ? .alter : .act) : .read
        guard current.kind == original.kind, current.tiers.contains(.read), original.tiers.contains(.read), current.tiers.contains(tier), original.tiers.contains(tier) else {
            throw NativeRPCError(code: "not-granted", message: "This decision request's current permission was revoked.")
        }
        if original.kind == .key {
            let latest = BackendDeckCoreSecurityCaller(kind: .key, tiers: BackendDeckCoreSecurityAccessKeys.tiersFor(key["level"].string ?? "look"), keyID: key["id"].string, tasks: key["tasks"].bool == true, folders: key["folders"].elements?.compactMap(\.string))
            guard original.keyID != nil, original.keyID == current.keyID, key["id"].string == original.keyID,
                  original.tasks, current.tasks, latest.tasks, key["crmOnly"].bool != true,
                  latest.tiers.contains(.read), latest.tiers.contains(tier),
                  [original, current, latest].allSatisfy({ BackendTAGProjectGrant.permits(folder, caller: $0, openProjects: [], allowedFolders: []) }) else {
                throw NativeRPCError(code: "not-granted", message: "This key no longer has this task, tool tier or folder grant.")
            }
        } else if original.kind == .session {
            guard original.sessionID == current.sessionID, original.machineID == current.machineID,
                  original.projectRoot == current.projectRoot, original.taskProject == current.taskProject else {
                throw NativeRPCError(code: "not-granted", message: "The original session decision scope changed.")
            }
        }
    }
}
/// A capable execution owner must call this again after its own awaits, just
/// before the actual start/send. Current hosted production owners cannot yet.
public enum BackendPCDecisionDelivery {
    @TaskLocal public static var validate: (@Sendable () async throws -> Void)?
    @TaskLocal public static var required = false
    @TaskLocal public static var hostedReference: String?
    @TaskLocal public static var finalEffect: (@Sendable (BackendPCDecisionHostValidation.Effect) async throws -> Void)?
    public static func verify(required explicitlyRequired: Bool = false) async throws {
        guard let validate else {
            if required || explicitlyRequired { throw NativeRPCError(code: "decision-held", message: "Required decision validation did not reach this execution owner. Work is held.") }
            return
        }
        try await validate()
    }
    public static func verifyFinal(_ effect: BackendPCDecisionHostValidation.Effect, required explicitlyRequired: Bool = false) async throws {
        if let finalEffect { try await finalEffect(effect); return }
        try await verify(required: explicitlyRequired)
    }
    /// An app-local closure cannot validate another process after its preparation.
    public static func refuseUnvalidatedHostedBoundary() throws {
        guard !required else { throw NativeRPCError(code: "decision-held", message: "Required work cannot cross an unvalidated helper execution boundary. Work is held.") }
    }
}
