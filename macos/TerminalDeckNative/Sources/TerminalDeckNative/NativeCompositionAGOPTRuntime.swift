import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Callers approve the profile action before entering this adapter. The
    /// original ledger and task store alone establish session ownership.
    func agoptRuntimeAccess(config: BackendTaskConfiguration, store: BackendTaskStore) throws -> BackendAGOPTAgentRuntimeAccess {
        guard let sessions, let usage, let authority, let files else {
            throw NativeRPCError(code: "composition-incomplete", message: "Agent runtime needs the retained session, usage and account owners.")
        }
        let state = root.state
        let standalone: @Sendable (String) async throws -> [BackendSessionMeta] = { id in
            let entries = try await sessions.ledger.entries()
            let ids = Set(entries.filter { $0.saved["agentInstructions"].string == id &&
                $0.saved["taskID"].isNullish && $0.saved["taskId"].isNullish }.map(\.id))
            return sessions.manager.list().filter { ids.contains($0.id) && $0.exitCode == nil }
        }
        return BackendAGOPTAgentRuntimeAccess(standaloneSessions: standalone, stopStandalone: { id, session in
            guard let exact = try await standalone(id).first(where: { $0.id == session }) else {
                throw NativeRPCError(code: "not-permitted", message: "That session is no longer owned by this agent.")
            }
            let rpc: NativeRPCContext
            #if TD_HOST_ACCOUNT_BRIDGE
            rpc = try BackendHOSTProfileScope.requireCurrent()
            #else
            guard let original = NativeCompositionCallContext.rpc else {
                throw NativeRPCError(code: "not-permitted", message: "Stopping this session needs the original approved caller.")
            }
            rpc = original
            #endif
            _ = try await files.authority.authorize(exact.cwd, context: rpc)
            guard try await standalone(id).contains(where: { $0.id == session }) else { throw CancellationError() }
            try await sessions.lifecycle.close(sessionID: session)
        }, billing: { id, requestedAccount in
            guard let agent = try await config.agent(id) else {
                throw NativeRPCError(code: "missing-agent", message: "That saved agent no longer exists.")
            }
            let preferred = await state.getPreferences()["defaultProvider"].string ?? "claude"
            let provider = agent["provider"].string ?? preferred
            // ACCOUNTS (FORK-L1, 11 Oct): the same account the launcher picks for this agent (its own if it
            // still has one → its seat → its project → the whole app), so the limits shown are the ones its
            // sessions really run on. Without a seat answer it is the agent's own / project / app as before.
            var effective = agent["account"].string
            if let seat = await BackendAGTMemoryOwners.shared?.seatKey(agent: agent) {
                var input: [NativeRPCValue.Field] = [.init("provider", .string(provider)), .init("seat", .string(seat)),
                    .init("sessionProfileId", effective.map(NativeRPCValue.string) ?? .null)]
                if let folder = agent["defaultProject"].string { input.append(.init("projectPath", .string(folder))) }
                if let answer = try? await sessions.accountRPC.invoke("profiles:effective", args: [.object(input)], context: try authority.localContext()),
                   let id = answer["accountId"].string { effective = id }
            }
            let chosen = effective
            let profile: BackendAccountProfile
            #if TD_HOST_ACCOUNT_BRIDGE
            profile = try await BackendHOSTProfileScope.withContext(try authority.localContext()) {
                try await sessions.profiles.resolve(sessionProfileID: chosen,
                    projectPath: agent["defaultProject"].string, provider: provider)
            }
            #else
            profile = try await sessions.profiles.resolve(sessionProfileID: chosen,
                projectPath: agent["defaultProject"].string, provider: provider)
            #endif
            if let requestedAccount, requestedAccount != profile.id {
                return .object([.init("kind", .string("unknown")), .init("source", .string("account-changed"))])
            }
            let cached = await state.getAccountLimit(profile.configDir)["billing"].string
            let tasks = try await store.all()
            let sessionIDs = Set(tasks.filter { $0.value["agoptAgentID"].string == id &&
                $0.value["agoptProfileID"].string == profile.id }.compactMap(\.sessionID))
            let candidates = sessions.manager.list().filter { sessionIDs.contains($0.id) && $0.exitCode == nil }
                .sorted { $0.createdAt > $1.createdAt }
            for session in candidates {
                let observed = try await usage.usage.account(sessionID: session.id, provider: provider)
                let reported = await usage.usage.planLimits.billing(session.id)
                if let kind = BackendAGOPTBilling.kind(provider: provider, accountID: profile.id, configDirectory: profile.configDir,
                    observedAccount: observed, sessionBilling: reported, cachedBilling: cached) {
                    return .object([.init("kind", .string(kind)), .init("source", .string(reported == kind ? "attributed-session-billing" : "account-billing-cache"))])
                }
            }
            let kind = BackendAGOPTBilling.kind(provider: provider, accountID: profile.id, configDirectory: profile.configDir,
                observedAccount: nil, sessionBilling: nil, cachedBilling: cached)
            return .object([.init("kind", .string(kind ?? "unknown")),
                .init("source", .string(kind == nil ? "not-reported" : "account-billing-cache"))])
        })
    }
}
