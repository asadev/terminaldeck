import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// App-dependent tools re-enter the current core gate with one sealed helper-session proof.
/// No app endpoint token is created, and neither tool arguments nor session-looking metadata
/// can mint this proof. The original grant is intersected with current helper adoption anew.
public struct BackendHOSTSessionToolRelay: Sendable {
    /// 30 Oct (Decker): which adoption check refused a relayed call. It goes back to the AI in words (it names a check,
    /// never a secret), where before every refusal read "could not authorize or complete this tool".
    public struct Refusal: Error, LocalizedError, Sendable {
        public let check: String
        public init(check: String) { self.check = check }
        public var errorDescription: String? { "This tool call was refused: \(check). Nothing was run." }
    }
    /// A snapshot read before a suspended retained-grant lookup cannot authorize a later
    /// same-PID account/conversation change. Call this after that await with current metadata.
    public static func matchesCurrentSession(_ snapshot: BackendHOSTProtocol.Snapshot, current: BackendSessionMeta?, pid: Int32?) -> Bool {
        guard let current, snapshot.pid != nil, snapshot.pid == pid,
              snapshot.session.exitCode == nil, current.exitCode == nil else { return false }
        let original = snapshot.session
        return original.id == current.id && original.createdAt == current.createdAt && original.provider == current.provider &&
            original.cwd == current.cwd && original.profileId == current.profileId && original.homeProfileId == current.homeProfileId &&
            original.agentSessionId == current.agentSessionId
    }
    public static func argumentsDigest(_ value: NativeRPCValue) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value.foundation ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public struct Adoption: Sendable {
        public let snapshot: BackendHOSTProtocol.Snapshot
        public let currentTools: Set<String>
        public let currentTiers: Set<BackendMCPTier>
        public let originalSessionLimits: NativeRPCValue
        public init(snapshot: BackendHOSTProtocol.Snapshot, currentTools: Set<String>, currentTiers: Set<BackendMCPTier>, originalSessionLimits: NativeRPCValue) {
            self.snapshot = snapshot; self.currentTools = currentTools; self.currentTiers = currentTiers; self.originalSessionLimits = originalSessionLimits
        }
    }
    private let core: BackendDeckCoreSecurityControl
    private let current: @Sendable (BackendHOSTAppRelayCall) async throws -> Adoption
    public init(core: BackendDeckCoreSecurityControl,
                currentAdoption: @escaping @Sendable (BackendHOSTAppRelayCall) async throws -> Adoption) {
        self.core = core; current = currentAdoption
    }
    private struct Bound: Sendable {
        let caller: BackendDeckCoreSecurityCaller
        let tools: Set<String>
        let identity: Data
        let limits: NativeRPCValue
        let agentProfileID: String?
    }
    public func invoke(_ call: BackendHOSTAppRelayCall) async throws -> BackendMCPToolReply {
        guard !call.context.cancellation.isCancelled else { throw CancellationError() }
        let initial = try bind(call, adoption: await current(call))
        // Bind the canonical inner call. tools_run keeps its ordinary gate/alias behavior,
        // while an unrelated or nested direct core call cannot borrow this relay proof.
        let canonical: String, arguments: NativeRPCValue
        guard let outer = await core.policy(named: call.toolID) else { throw BackendHOSTFailure.authentication }
        if outer.tool.id == "tools.run" {
            let target = try BackendDeckCoreCatalogueRunTarget.parse(call.arguments)
            // The same plain answer as a direct call names: a tool this app does not have, or one outside this session's grant.
            guard let inner = await core.policy(named: target.name), inner.tool.id != "tools.run",
                  inner.visible(to: initial.tools, caller: initial.caller) else { return .failure("no tool called \(target.name)") }
            canonical = inner.tool.id; arguments = target.arguments
        } else { canonical = outer.tool.id; arguments = call.arguments }
        let live = try bind(call, adoption: await current(call))
        guard same(initial, live) else { throw BackendHOSTFailure.authentication }
        let proof = BackendDeckCoreRelaySessionProof(caller: live.caller, tools: live.tools, tool: canonical, arguments: arguments,
            cancellation: call.context.cancellation, attended: call.context.attended, agentProfileID: live.agentProfileID, refresh: {
                guard !call.context.cancellation.isCancelled else { throw CancellationError() }
                let latest = try self.bind(call, adoption: await self.current(call))
                guard self.same(live, latest), !call.context.cancellation.isCancelled else { throw BackendHOSTFailure.authentication }
                return latest.caller
            })
        defer { proof.end() }
        let result = await core.call(name: call.toolID, arguments: call.arguments, options: .init(caller: live.caller,
            attended: call.context.attended, granted: live.tools, cancellation: call.context.cancellation,
            sessionLimits: live.limits, relaySessionProof: proof))
        guard !call.context.cancellation.isCancelled else { throw CancellationError() }
        return result.reply
    }
    private func bind(_ call: BackendHOSTAppRelayCall, adoption proof: Adoption) throws -> Bound {
        guard !call.context.cancellation.isCancelled, proof.snapshot.session.id == call.context.sessionID,
              proof.snapshot.pid != nil, proof.snapshot.session.exitCode == nil,
              call.context.machineID.isEmpty,
              let input = proof.snapshot.input, let scope = proof.snapshot.scope,
              (input.chat == true || (input.taskID == nil && input.taskProject == nil)),
              !scope.isAppComposed, scope.appFenceID == nil, scope.deviceBoundary == nil,
              call.taskProject == input.taskProject,
              call.context.projectRoot == (input.taskID == nil ? nil : input.taskProject) else { throw BackendHOSTFailure.authentication }
        let original = BackendTAGToolPolicy.filter(call.context.allowedTools, server: "deck-control", allowed: input.allowedTools, denied: input.deniedTools ?? [])
        let granted = original.intersection(proof.currentTools), tiers = call.context.allowedTiers.intersection(proof.currentTiers)
        guard tiers.contains(call.tier), BackendMCPToolNames.permits(call.toolID, granted: granted)
                || BackendMCPToolNames.permits(call.wireName, granted: granted) else { throw BackendHOSTFailure.authentication }
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: tiers, sessionID: call.context.sessionID,
            machineID: call.context.machineID, projectRoot: call.context.projectRoot, taskProject: call.taskProject)
        // Exclude changing output/status/title from identity; bind immutable launch/account,
        // session birth and current process facts, including the exact saved-agent launch.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = try NativeRPCValue.object([
            .init("id", .string(proof.snapshot.session.id)), .init("createdAt", .number(proof.snapshot.session.createdAt)),
            .init("pid", .number(Double(proof.snapshot.pid!))), .init("provider", .string(proof.snapshot.session.provider)),
            .init("cwd", .string(proof.snapshot.session.cwd)), .init("profileId", proof.snapshot.session.profileId.map(NativeRPCValue.string) ?? .null),
            .init("homeProfileId", proof.snapshot.session.homeProfileId.map(NativeRPCValue.string) ?? .null),
            .init("agentSessionId", proof.snapshot.session.agentSessionId.map(NativeRPCValue.string) ?? .null),
            .init("input", try NativeRPCValue.parseJSON(encoder.encode(input))),
            .init("scope", try NativeRPCValue.parseJSON(encoder.encode(scope)))
        ]).encodedJSON()
        return .init(caller: caller, tools: granted, identity: identity, limits: proof.originalSessionLimits, agentProfileID: input.agentProfileID)
    }
    private func same(_ a: Bound, _ b: Bound) -> Bool {
        a.identity == b.identity && a.tools == b.tools && a.caller.tiers == b.caller.tiers && a.limits == b.limits
    }
}
