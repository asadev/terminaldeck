import Foundation
import XCTest
@testable import TerminalDeckBackend

/// 18 Oct (#89, #527): removing an account while a session runs as it is refused, naming that session; a tab
/// whose agent has ended no longer counts, so it never blocks the removal.
final class U38AccountRemoveInUseTests: XCTestCase, @unchecked Sendable {
    func testRemoveIsRefusedNamingTheRunningSessionAndAllowedOnceItsAgentEnded() async throws {
        let r = try await BackendF4Runtime.wire()
        do {
            let account = try await r.create("work@example.com")
            _ = await r.put(account.id, BackendF4ClaudeLogin("fixture-work"))
            var input = BackendCreateSessionInput(cwd: r.root.path, provider: "claude")
            input.profileId = account.id
            let launch = try await r.adapter.resolve(input, provider: BackendProviderSpec(id: "claude", command: "/fixture/never-run", args: [], resumeArgs: []),
                loginPath: "/usr/bin:/bin", context: BackendLaunchContext(isAppComposed: true))
            let meta = BackendSessionMeta(id: "fixture-live", input: input,
                spawn: BackendSpawnSpec(provider: "claude", command: "/fixture/never-run", args: [], path: "/usr/bin:/bin"))
            try await r.adapter.bind(launch, session: meta)

            do { _ = try await r.rpc.invoke("profiles:delete", args: [.string(account.id)], context: BackendF4Runtime.context); XCTFail("A running account must stay") }
            catch { XCTAssertTrue(error.localizedDescription.contains("This account is in use by “\(meta.title)”"), error.localizedDescription) }
            let kept = try await r.profiles.find(account.id), held = await r.vault.has(account.id)
            XCTAssertNotNil(kept); XCTAssertTrue(held)
            let renamed = await BackendAccountRPC.use(account.id, accounts: r.adapter, title: { _ in "Fix login" })
            XCTAssertEqual(renamed, BackendAccountUse(sessions: ["Fix login"]))

            // The tab finished; its helpers may still be closing, but the account is no longer in use.
            await r.adapter.agentEnded(sessionID: meta.id)
            let inUse = await r.adapter.apiProfileInUse(account.id)
            XCTAssertFalse(inUse)
            let removed = try await r.rpc.invoke("profiles:delete", args: [.string(account.id)], context: BackendF4Runtime.context)
            XCTAssertEqual(removed["removed"].bool, true)
            await r.adapter.exited(sessionID: meta.id)
        } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }
}
