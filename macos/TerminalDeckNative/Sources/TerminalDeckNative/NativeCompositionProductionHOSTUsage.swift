#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installHOSTUsage(excludingToolIDs: Set<String>) async throws -> BackendCompositionUsage {
        guard let sessions else { throw BackendHOSTFailure.unavailable }
        let suppliers = try wired(self.suppliers, "suppliers")
        guard let managed = hostManaged else {
            guard let accounts = sessions.accounts as? BackendAccountLaunchAdapter else { throw BackendHOSTFailure.unavailable }
            return try await root.installUsage(accounts: accounts, lifecycle: sessions.lifecycle,
                dependencies: suppliers.usageDependencies(), excludingToolIDs: excludingToolIDs)
        }
        return try await root.installHostedUsage(profiles: sessions.profiles, lifecycle: sessions.lifecycle,
            dependencies: suppliers.usageDependencies(), actualProbe: { account, cancellation in
                await managed.usage(account, cancellation: cancellation)
            }, sessionLookup: { id in
                guard let meta = sessions.manager.list().first(where: { $0.id == id }) else { return nil }
                let row = await sessions.lifecycle.metadata(sessionID: id)
                return (meta: meta, observedProvider: row?.observedAgentProvider,
                    account: await sessions.lifecycle.sessionAccount(sessionID: id), screen: sessions.manager.screen(id))
            }, excludingToolIDs: excludingToolIDs)
    }
}
#endif
