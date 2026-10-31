import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// L8 (10 Oct): the REAL `claude` CLI in a real PTY through the app's own PTY manager and SwiftTerm screen,
/// typed into exactly as a task brief is. Opt-in only (L8_REAL_CLAUDE=1): it starts the person's real CLI.
/// L8_REAL_CLAUDE_SUBMIT=1 also delivers ONE tiny brief ("reply OK") through the production deliver().
final class L8RealClaudeProbeTests: XCTestCase {
    private func env(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }
    private func shown(_ text: String?) -> String {
        (text ?? "<nil>").replacingOccurrences(of: "\u{0}", with: "␀").components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func testRealClaudeEcho() async throws {
        try XCTSkipUnless(env("L8_REAL_CLAUDE") == "1", "opt-in: starts the real claude CLI")
        let out = URL(fileURLWithPath: env("L8_OUT") ?? NSTemporaryDirectory()).appendingPathComponent("l8-real-claude.txt")
        var log = ""
        func note(_ s: String) { log += s + "\n"; try? log.write(to: out, atomically: true, encoding: .utf8) }
        var inherited = ProcessInfo.processInfo.environment
        for key in inherited.keys where key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC") || key.hasPrefix("MCP_") { inherited[key] = nil }
        let manager = BackendPTYManager(inheritedEnvironment: inherited) { _ in }
        let claude = env("L8_CLAUDE") ?? "/Users/imatch/.nvm/versions/node/v24.20.0/bin/claude"
        let cwd = env("L8_CWD") ?? "/Users/imatch/ClaudeAsad"
        let path = URL(fileURLWithPath: claude).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let meta = try manager.create(BackendCreateSessionInput(cwd: cwd, cols: 120, rows: 30, provider: "claude"),
                                      spawn: .init(provider: "claude", command: claude, args: [], path: path))
        let id = meta.id
        defer { _ = try? manager.write(id, data: "\u{3}"); _ = try? manager.write(id, data: "\u{3}") }
        func screen() -> String { manager.screen(id) ?? "" }
        // 1. wait for the empty prompt (production readiness rules)
        var ready = false
        for _ in 0..<150 {
            let s = screen()
            if case .ready = BackendTaskBriefDelivery.composer(s), BackendSessionClassifier.classify(viewport: s) == .waiting { ready = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        note("READY=\(ready) composer=\(BackendTaskBriefDelivery.composer(screen())) classify=\(BackendSessionClassifier.classify(viewport: screen()))\n--- empty prompt screen\n" + shown(screen()))
        // 2. type a brief-shaped line WITHOUT submitting, watch the screen, then clear it again
        let line = BackendDeckCoreBrief.deliveryLine("/Users/imatch/Library/Application Support/terminaldeck/remote/task-briefs/1791646382023-a04b435e-fbd8-45e8-96b0-daccbda6f7d2.md")
        try manager.write(id, data: line)
        for step in 1...6 {
            try await Task.sleep(for: .milliseconds(500))
            let s = screen()
            note("--- \(step * 500) ms after typing: composer=\(BackendTaskBriefDelivery.composer(s))\n" + shown(s))
        }
        try manager.write(id, data: "\u{15}")
        try await Task.sleep(for: .milliseconds(800))
        note("--- after ctrl-U: composer=\(BackendTaskBriefDelivery.composer(screen()))\n" + shown(screen()))
        // 3. optionally: ONE real tiny brief through the production deliver()
        guard env("L8_REAL_CLAUDE_SUBMIT") == "1" else { return }
        struct Surface: BackendDeckCoreBriefSurface {
            let manager: BackendPTYManager
            func listSessions() -> [NativeRPCValue] { manager.list().compactMap { try? NativeRPCValue.parseJSON(JSONEncoder().encode($0)) } }
            func sessionScreen(id: String) async throws -> String? { manager.screen(id) }
            func writeToSession(id: String, data: String) async throws { try manager.write(id, data: data) }
        }
        let tiny = "Reply with exactly the two letters OK and nothing else. Do not use any tool, do not read or change any file."
        let result = try await BackendDeckCoreBrief.deliver(surface: Surface(manager: manager), sessionID: id, line: tiny, timeoutMs: 30_000)
        note("--- deliver(): \(result.compact)")
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            if screen().contains("⏺ OK") || screen().range(of: #"(?m)^\s*⏺\s*OK\s*$"#, options: .regularExpression) != nil { break }
        }
        note("--- after submit\n" + shown(screen()))
        XCTAssertEqual(result["delivered"], .bool(true), result["reason"].string ?? "")
    }
}
