import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("AGT agents on this Mac: scanner, files, conversation and cost")
struct AGTDeviceScannerTests {
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AGT-device-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/projects/-Users-u-app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/sessions/2026/10/09"), withIntermediateDirectories: true)
        return root
    }

    @Test func scansFixtureTreeReadsOnlyTheirFilesAndFollowsConversations() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let session = "aaaaaaaa-1111-2222-3333-444444444444"
        try Data(#"{"pid":11,"sessionId":"\#(session)","cwd":"/Users/u/app","status":"idle","name":"Fix login"}"#.utf8)
            .write(to: root.appendingPathComponent(".claude/sessions/11.json"))
        let transcript = root.appendingPathComponent(".claude/projects/-Users-u-app/\(session).jsonl")
        try Data("""
        {"type":"user","sessionId":"\(session)","message":{"role":"user","content":"Fix the login"},"uuid":"u1","timestamp":"2026-10-09T01:00:00Z"}
        {"type":"assistant","message":{"model":"claude-opus-5-5","id":"m1","content":[{"type":"text","text":"Fixed and tested."}]},"uuid":"a1","timestamp":"2026-10-09T01:00:09Z"}

        """.utf8).write(to: transcript)
        let rollout = root.appendingPathComponent(".codex/sessions/2026/10/09/rollout-2026-10-09T01-00-00-01a11874-3909-70b0-85e7-984c56605aff.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"01a11874-3909-70b0-85e7-984c56605aff","cwd":"/Users/u/repo"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1"}}
        {"type":"response_item","payload":{"type":"message","id":"r1","role":"assistant","content":[{"type":"output_text","text":"All green."}]}}
        {"type":"response_item","payload":{"type":"reasoning","id":"r2","summary":[{"text":"private"}]}}

        """.utf8).write(to: rollout)
        let outside = root.appendingPathComponent("secret.jsonl")
        try Data("{}\n".utf8).write(to: outside)
        let tree: @Sendable () -> [AGTProcess] = {
            [AGTProcess(pid: 10, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
             AGTProcess(pid: 11, ppid: 10, name: "claude", path: "/x/claude", args: ["claude"], cwd: "/Users/u/app", startedAt: 0, cpuSeconds: 1),
             AGTProcess(pid: 12, ppid: 10, name: "codex", path: "/x/codex", args: ["codex"], cwd: "/Users/u/repo", startedAt: 5, cpuSeconds: 2,
                        openFiles: [rollout.path, outside.path])]
        }
        let scanner = BackendAGTDeviceScanner(home: root.path, snapshot: tree)
        let first = await scanner.scan(now: 1_000)
        #expect(first.agents.count == 2)
        let claude = try #require(first.agents.first { $0.ai == "claude" })
        #expect(claude.sessionID == session && claude.title == "Fix login" && claude.lastLine == "Fixed and tested." && claude.state == .idle)
        #expect(claude.cpuPercent == nil) // one sample is not a measurement
        let codex = try #require(first.agents.first { $0.ai == "codex" })
        #expect(codex.project == "/Users/u/repo" && codex.model == "gpt-6.1" && codex.lastLine == "All green.")
        // CPU is measured between two passes.
        let second = await scanner.scan(now: 1_002)
        #expect(second.agents.first { $0.ai == "claude" }?.cpuPercent == 0)
        // Watch reads the end of the conversation; Codex reasoning stays private.
        let read = try await scanner.conversation(claude.id)
        #expect(read.entries.map(\.text) == ["Fix the login", "Fixed and tested."])
        let codexRead = try await scanner.conversation(codex.id)
        #expect(codexRead.entries.map(\.text) == ["All green."])
        // Never reads outside the agents' own folders.
        #expect(BackendAGTDeviceScanner.readable(outside.path, home: root.path) == nil)
        #expect(BackendAGTDeviceScanner.readable(root.path + "/.codex/sessions/../../secret.jsonl", home: root.path) == nil)
        // Filters and owner-only last lines.
        let other = BackendAGTDeviceTools.listValue(second, source: "other", includeText: false)
        #expect(other["agents"].elements?.count == 2)
        #expect(other["agents"].elements?.allSatisfy { $0["lastLine"].isNullish } == true)
        #expect(BackendAGTDeviceTools.listValue(second, source: "terminal-deck", includeText: true)["agents"].elements?.isEmpty == true)
    }

    @Test func realProcessTableIsReadCheaply() async {
        // Read-only: this Mac's own process table, as the app would read it.
        let scanner = BackendAGTDeviceScanner()
        _ = await scanner.scan()
        try? await Task.sleep(for: .seconds(1))
        let scan = await scanner.scan()
        #expect(scan.processes > 10)
        #expect(scan.wallMS < 2_000)
        print("AGT real scan: \(scan.processes) processes, \(scan.agents.count) agents, \(String(format: "%.1f", scan.wallMS)) ms wall, \(String(format: "%.1f", scan.cpuMS)) ms CPU")
        for agent in scan.agents {
            print("AGT agent: \(agent.ai) in \(agent.app.name) td=\(agent.app.isTerminalDeck) state=\(agent.state.rawValue) session=\(agent.sessionID != nil) readable=\(agent.transcriptPath != nil) model=\(agent.model ?? "-") cpu=\(agent.cpuPercent.map { String(format: "%.1f", $0) } ?? "-")")
        }
    }
}
