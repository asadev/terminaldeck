import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("AGT shell-tab AIs: recorded from hooks and process trees, kept across restarts, resumed on restore")
struct AGTShellAgentsStoreTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AGT-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func shell(_ id: String = "s1", tabKey: String = "tab-1", exited: Bool = false) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("provider", .string("shell")), .init("cwd", .string("/Users/u")),
                 .init("tabKey", .string(tabKey)), .init("exitCode", exited ? .number(0) : .null)])
    }
    private func hook(_ event: String, provider: String = "claude", id: String? = "2c6070f9-282c-404b-a8e2-8a7d3007fddd", sidechain: Bool = false) -> BackendSessionHookEvent {
        var body: [String: Any] = ["cwd": "/Users/u/ClaudeCRM"]
        if let id { body["session_id"] = id }
        if sidechain { body["isSidechain"] = true }
        return BackendSessionHookEvent.parse(provider: provider, event: event, sessionID: "s1", body: try! JSONSerialization.data(withJSONObject: body), environmentHeader: nil, peerPID: 1)
    }

    @Test func hooksRecordAndClearAndTheRecordSurvivesARestart() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendAGTShellAgents(dataRoot: root)
        store.accept(hook("SessionStart", sidechain: true), session: shell())
        #expect(store.record(tabKey: "tab-1") == nil)
        store.accept(hook("SessionStart"), session: shell().setting("provider", .string("claude"))) // an agent tab keeps its own record
        #expect(store.record(tabKey: "tab-1") == nil)
        store.accept(hook("SessionStart"), session: shell())
        #expect(store.record(tabKey: "tab-1")?.conversationID == "2c6070f9-282c-404b-a8e2-8a7d3007fddd")
        #expect(store.record(tabKey: "tab-1")?.cwd == "/Users/u/ClaudeCRM")
        // A new app (or a new session host) reads the same record.
        #expect(BackendAGTShellAgents(dataRoot: root).record(tabKey: "tab-1")?.provider == "claude")
        store.accept(hook("SessionEnd"), session: shell())
        #expect(store.record(tabKey: "tab-1") == nil)
        #expect(BackendAGTShellAgents(dataRoot: root).record(tabKey: "tab-1") == nil)
    }

    @Test func processTreeScanRecordsAgentsWithoutHooksAndForgetsOnlyWhenTheShellLives() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendAGTShellAgents(dataRoot: root, home: root.path)
        let withCodex: () -> [AGTProcess] = {
            [AGTProcess(pid: 10, ppid: 1, name: "zsh", path: "/bin/zsh"),
             AGTProcess(pid: 11, ppid: 10, name: "codex", path: "/x/codex", args: ["codex", "resume", "01a11874-3909-70b0-85e7-984c56605aff"], cwd: "/Users/u/repo", startedAt: 5)]
        }
        store.scan(session: shell(), rootPID: 10, snapshot: withCodex)
        #expect(store.record(tabKey: "tab-1")?.provider == "codex")
        #expect(store.record(tabKey: "tab-1")?.conversationID == "01a11874-3909-70b0-85e7-984c56605aff")
        // The tab died (app quit, host lost): keep it for the restore.
        store.scan(session: shell(tabKey: "tab-1", exited: true), rootPID: nil, snapshot: { [] })
        #expect(store.record(tabKey: "tab-1") != nil)
        // A second tab whose AI ended while its shell lives: forgotten (throttle is per tab).
        store.scan(session: shell("s2", tabKey: "tab-2"), rootPID: 10, snapshot: withCodex)
        #expect(store.record(tabKey: "tab-2") != nil)
        Thread.sleep(forTimeInterval: 2.1)
        store.scan(session: shell("s2", tabKey: "tab-2"), rootPID: 10, snapshot: { [AGTProcess(pid: 10, ppid: 1, name: "zsh", path: "/bin/zsh")] })
        #expect(store.record(tabKey: "tab-2") == nil)
    }

    @Test func restoreGivesTheShellItsResumeAndOldInputsStillDecode() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendAGTShellAgents(dataRoot: root)
        store.accept(hook("SessionStart"), session: shell())
        BackendAGTShellAgents.install(store); defer { BackendAGTShellAgents.install(nil) }
        var input = BackendCreateSessionInput(cwd: "/Users/u", provider: "shell"); input.tabKey = "tab-1"
        BackendAGTShellAgents.applyResume(to: &input)
        #expect(input.shellAgent == .init(provider: "claude", conversationId: "2c6070f9-282c-404b-a8e2-8a7d3007fddd", cwd: "/Users/u/ClaudeCRM"))
        var other = BackendCreateSessionInput(cwd: "/Users/u", provider: "shell"); other.tabKey = "tab-9"
        BackendAGTShellAgents.applyResume(to: &other)
        #expect(other.shellAgent == nil)
        var agent = BackendCreateSessionInput(cwd: "/Users/u", provider: "claude"); agent.tabKey = "tab-1"
        BackendAGTShellAgents.applyResume(to: &agent)
        #expect(agent.shellAgent == nil)
        // Inputs written before AGT decode unchanged; the new field round-trips (the session host gets it whole).
        let old = try JSONDecoder().decode(BackendCreateSessionInput.self, from: Data(#"{"cwd":"/w","cols":80,"rows":24,"provider":"shell"}"#.utf8))
        #expect(old.shellAgent == nil)
        let again = try JSONDecoder().decode(BackendCreateSessionInput.self, from: JSONEncoder().encode(input))
        #expect(again.shellAgent == input.shellAgent)
        // What the restored shell runs.
        let resumed = AGTShellAgent(provider: input.shellAgent!.provider, conversationID: input.shellAgent!.conversationId, cwd: input.shellAgent!.cwd, updatedAt: 0)
        #expect(AGTShellAgents.shellArguments(shell: "/bin/zsh", agent: resumed)
                == ["-l", "-i", "-c", "cd /Users/u/ClaudeCRM && claude --resume 2c6070f9-282c-404b-a8e2-8a7d3007fddd; exec /bin/zsh -l"])
        // At work sees the tab's AI.
        #expect(store.decorate([shell()]).first?["innerAgent"]["provider"].string == "claude")
    }
}
