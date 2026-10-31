import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("AGT an AI typed into a Terminal Deck shell tab resumes with the tab")
struct AGTShellAgentsTests {
    // A Terminal Deck shell tab (zsh 701 under the session host) where Asad typed `claude --resume …`,
    // which in turn started Codex; a second tab (801) whose AI has ended.
    static let tree: [AGTProcess] = [
        .init(pid: 700, ppid: 1, name: "TerminalDeckNat", path: "/Users/u/Library/Application Support/terminaldeck/host/agents/x/TerminalDeckNativeHelper"),
        .init(pid: 701, ppid: 700, name: "zsh", path: "/bin/zsh", startedAt: 100),
        .init(pid: 702, ppid: 701, name: "claude.exe", path: "/Users/u/.nvm/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
              args: ["/Users/u/.nvm/bin/claude", "--resume", "2c6070f9-282c-404b-a8e2-8a7d3007fddd"], cwd: "/Users/u/ClaudeCRM", startedAt: 200),
        .init(pid: 703, ppid: 702, name: "codex", path: "/Users/u/.codex/bin/codex", args: ["codex", "exec"], cwd: "/Users/u/ClaudeCRM", startedAt: 300),
        .init(pid: 801, ppid: 700, name: "zsh", path: "/bin/zsh", startedAt: 100),
        .init(pid: 802, ppid: 801, name: "vim", path: "/usr/bin/vim", startedAt: 150),
    ]
    static let files = AGTDeviceDetect.Files(claudeSession: { _ in nil }, claudeTranscript: { _, _ in nil }, tail: { _, _ in nil })

    @Test func findsTheAIInsideOneShellTabOnly() {
        #expect(AGTShellAgents.descendants(of: 701, in: Self.tree).map(\.pid).sorted() == [702, 703])
        let found = AGTShellAgents.innerAgent(root: 701, processes: Self.tree, files: Self.files, now: 1_000)
        // Codex has no session id here, so the Claude conversation (with one) is the tab's.
        #expect(found?.ai == "claude" && found?.sessionID == "2c6070f9-282c-404b-a8e2-8a7d3007fddd" && found?.project == "/Users/u/ClaudeCRM")
        #expect(AGTShellAgents.innerAgent(root: 801, processes: Self.tree, files: Self.files, now: 1_000) == nil)
    }

    @Test func recordChangesOnlyWhenTheShellLivesOn() {
        let found = AGTShellAgents.innerAgent(root: 701, processes: Self.tree, files: Self.files, now: 1_000)
        let set = AGTShellAgents.change(current: nil, found: found, shellAlive: true, cwd: "/Users/u", now: 1_000)
        guard case .set(let record) = set else { Issue.record("Not recorded"); return }
        #expect(record.provider == "claude" && record.conversationID == "2c6070f9-282c-404b-a8e2-8a7d3007fddd" && record.cwd == "/Users/u/ClaudeCRM")
        #expect(AGTShellAgents.change(current: record, found: found, shellAlive: true, cwd: "/Users/u", now: 2_000) == .keep)
        // The AI ended and the shell is still there: do not resume it next time.
        #expect(AGTShellAgents.change(current: record, found: nil, shellAlive: true, cwd: "/Users/u", now: 2_000) == .clear)
        // The tab (or its session host) died with the AI still in it: resume it next time.
        #expect(AGTShellAgents.change(current: record, found: nil, shellAlive: false, cwd: "/Users/u", now: 2_000) == .keep)
    }

    @Test func resumeCommandsAreExactAndNothingElseRuns() {
        #expect(AGTShellAgents.resumeCommand(provider: "claude", conversationID: "abc-1") == "claude --resume abc-1")
        #expect(AGTShellAgents.resumeCommand(provider: "codex", conversationID: "abc-1") == "codex resume abc-1")
        #expect(AGTShellAgents.resumeCommand(provider: "gemini", conversationID: "abc-1") == "gemini --resume abc-1")
        #expect(AGTShellAgents.resumeCommand(provider: "claude", conversationID: "x; rm -rf ~") == nil)
        #expect(AGTShellAgents.resumeCommand(provider: "bash", conversationID: "abc") == nil)
        let agent = AGTShellAgent(provider: "claude", conversationID: "abc-1", cwd: "/Users/u/My 'CRM'", updatedAt: 0)
        #expect(AGTShellAgents.shellArguments(shell: "/bin/zsh", agent: agent)
                == ["-l", "-i", "-c", "cd '/Users/u/My '\\''CRM'\\''' && claude --resume abc-1; exec /bin/zsh -l"])
        #expect(AGTShellAgents.shellArguments(shell: "/bin/zsh", agent: nil) == ["-l"])
        #expect(AGTShellAgents.shellArguments(shell: "/bin/zsh", agent: AGTShellAgent(provider: "claude", conversationID: "$(x)", cwd: "/", updatedAt: 0)) == ["-l"])
        #expect(AGTShellAgent.decode(agent.wireValue) == agent)
    }

    @Test func atWorkShowsAShellTabOnlyWhileAnAIRunsInIt() {
        let plain = NativeRPCValue.object([.init("id", .string("s1")), .init("provider", .string("shell")), .init("cwd", .string("/w")), .init("title", .string("Session 1"))])
        let busy = plain.setting("id", .string("s2")).setting("innerAgent", AGTShellAgent(provider: "claude", conversationID: "c1", cwd: "/w/crm", updatedAt: 0).wireValue)
        let rows = AWWatchProjection.inventory(sessions: [plain, busy], tasks: [])
        #expect(rows.map(\.sourceID) == ["s2"])
        #expect(rows.first?.provider == "claude" && rows.first?.project == "/w/crm")
    }
}
