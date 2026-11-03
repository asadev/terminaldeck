import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Team chats: Codex keeps its app tools and restrictions")
struct TeamChats20ToolLeaseTests {
    @Test func aCodexTeamJobKeepsTheNativeToolLeaseAndItsRestrictions() throws {
        let flags = ["-c", "mcp_servers.deck-control.url=\"http://127.0.0.1:9999/mcp\"",
            "-c", "mcp_servers.deck-control.bearer_token_env_var=\"TD_TEST_AUTH\"",
            "-c", "mcp_servers.deck-control.disabled_tools=[\"forbidden\"]",
            "-c", "mcp_servers.other.enabled=false", "--model", "test-model"]
        let recipe = BackendSessionChats.Recipe(provider: .codex, executable: "/fake/codex", arguments: flags,
            environment: [:], cwd: "/scratch/job", conversation: nil, sessionTools: true)
        let plan = try BackendSessionChats.plan(recipe, cliSession: nil, again: false)
        #expect(plan.arguments == ["app-server", "--stdio"] + Array(flags.dropLast(2)))
        #expect(plan.setup?.session["model"].string == "test-model")
        #expect(plan.setup?.session["config"]["mcp_servers"].isNullish == true)
        // A restart keeps the same lease. No account file or token is read by this check.
        #expect(try BackendSessionChats.plan(recipe, cliSession: "thread", again: true).arguments == plan.arguments)
    }
    @Test func hootStillRequiresItsOwnSeparateToolLease() throws {
        let flags = ["-c", "mcp_servers.deck-control.url=\"http://127.0.0.1:9999/mcp\""]
        #expect(throws: (any Error).self) {
            try BackendHootChatLaunchPlan(provider: .codex, cwd: "/scratch", sessionID: nil, extra: flags)
        }
        #expect(BackendSessionChats.rpcExtra(flags, provider: .codex).isEmpty)
        #expect(BackendSessionChats.rpcExtra(flags, provider: .codex, keepSessionTools: true) == flags)
    }
}
