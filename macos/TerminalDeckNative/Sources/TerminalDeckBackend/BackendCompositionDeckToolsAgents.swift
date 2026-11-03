import Foundation
import TerminalDeckNativeCore

/// `BackendDeckToolsSessionsAgents` over the native owners (INT-A, 7 Oct 2026).
///
/// agents-area-live.ts:142-152 wires each dep to the function its channel
/// calls: `detect` is index.ts:2736 `detectAllProviders` (the body of
/// `providers:detect`), `added/add/remove` are `core.agents` — the store
/// `registerCustomAgentsIpc` serves, here `BackendCustomAgentsStore`, the one
/// `agents:list/add/remove` already use — and `readControls/models/apply` are
/// agent-controls.ts over `core.controlAccess`, here the one
/// `BackendCompositionAgentControlsOwning` that the task driver's
/// `setAgentControl` also types through.
///
/// The factory (`BackendDeckToolsSessionsArea.agentDefinitions`) has already
/// entered the running call through the gate at the effective tier and checked
/// the session through the caller's own view. This adapter still resolves the
/// caller from its credential on every call and re-proves the session through
/// `authority.requireSession`, so it can never be reached with a broader reach.
public struct BackendCompositionDeckToolsAgents: BackendDeckToolsSessionsAgents, Sendable {
    private let gate: BackendCompositionDeckToolsGate
    private let providers: BackendNativeProviders
    private let store: BackendCustomAgentsStore
    private let owner: any BackendCompositionAgentControlsOwning

    public init(gate: BackendCompositionDeckToolsGate, providers: BackendNativeProviders,
                customAgents: BackendCustomAgentsStore, controls: any BackendCompositionAgentControlsOwning) {
        self.gate = gate; self.providers = providers; self.store = customAgents; self.owner = controls
    }

    /// index.ts:2736 detectAllProviders: the catalogue's agents measured by
    /// running them (providers.ts:651 `canStart` = a runnable binary), the shell
    /// always, then every added agent by command lookup on the login PATH.
    public func detect(context: BackendMCPCallContext) async throws -> NativeRPCValue {
        _ = try await gate.authority.resolve(context)
        let path = try await providers.loginPath()
        var answer = NativeRPCValue.object([])
        for id in ["claude", "codex", "gemini"] {
            let binary = await providers.resolveBinary(id, path: path)
            answer = answer.setting(id, .bool(binary.runnable != nil))
        }
        answer = answer.setting("shell", .bool(true))
        // custom-agents.ts lookupCommand: presence only, never an unknown agent's --version.
        let lookup = BackendCustomAgentsStore.nativeLookup(loginPath: { path })
        for agent in await store.list().elements ?? [] {
            guard let id = agent["id"].string, let command = agent["command"].string else { continue }
            if context.cancellation.isCancelled { throw CancellationError() }
            let found = try? await lookup(command)
            answer = answer.setting(id, .bool(found != nil))
        }
        return answer
    }

    public func added(context: BackendMCPCallContext) async throws -> [NativeRPCValue] {
        _ = try await gate.authority.resolve(context)
        return await store.list().elements ?? []
    }

    /// custom-agents.ts add: `{ ok: true, agent }` or `{ ok: false, problems }`.
    public func add(draft: NativeRPCValue, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        _ = try await gate.authority.resolve(context)
        return try await store.add(draft)
    }

    /// The prefix check `registerCustomAgentsIpc` makes, kept: a built-in id never reaches the store.
    public func remove(agentID: String, context: BackendMCPCallContext) async throws -> Bool {
        _ = try await gate.authority.resolve(context)
        guard BackendCustomAgentsRules.isCustom(agentID) else { return false }
        return try await store.remove(agentID)
    }

    /// agents-area-live.ts:149 `readControls(controlAccess, sessionId, cwd, provider)` —
    /// no scope argument, so a session on this computer.
    public func controls(sessionID: String, cwd: String, provider: String, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let session = try await gate.authority.requireSession(sessionID, native: context)
        return await owner.read(sessionID: session.id, cwd: session.cwd, provider: session.provider, onThisMachine: true)
    }

    /// agents-area-live.ts:150 `discoverModels(controlAccess, sessionId, provider)`.
    public func models(sessionID: String, provider: String, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let session = try await gate.authority.requireSession(sessionID, native: context)
        return try await owner.models(sessionID: session.id, provider: session.provider)
    }

    /// agents-area-live.ts:151 `applyControl(controlAccess, request)`; the cwd and
    /// provider are the session's own, never the request's.
    public func apply(request: NativeRPCValue, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let session = try await gate.authority.requireSession(request["sessionId"].string ?? "", native: context)
        guard let control = request["control"].string, let value = request["value"].string else {
            throw BackendDeckToolsArgs.bad("control and value are required")
        }
        return try await owner.apply(sessionID: session.id, cwd: session.cwd, control: control, value: value,
                                        provider: session.provider, onThisMachine: true)
    }
}
