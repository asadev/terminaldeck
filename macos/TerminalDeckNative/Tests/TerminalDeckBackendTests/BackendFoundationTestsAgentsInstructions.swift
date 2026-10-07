import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Exact agent-launch.ts expectations. No command, CLI, app or network runs.
final class BackendFoundationTestsAgentsInstructions: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foundation-agent-launch-" + UUID().uuidString).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("agent-instructions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Work on a branch.\nSay \"done\" when \"done\".\n".utf8).write(to: directory.appendingPathComponent("builder.md"))
        return root
    }
    private func launch(_ root: URL, provider: String, id: String? = "builder", denied: [String]? = nil) async throws -> [String] {
        var input = BackendCreateSessionInput(cwd: "/project", provider: provider)
        input.agentInstructions = id; input.deniedTools = denied
        return try await BackendNativeInstructions(storageRoot: root).arguments(input,
            provider: .init(id: provider, command: "/fake/never-spawn", args: [], resumeArgs: []), context: .init())
    }
    private func errorContains(_ text: String, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected source refusal: " + text, file: file, line: line) }
        catch { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription, file: file, line: line) }
    }
    // src/main/agents/agent-launch.test.ts:24
    func testClaudeReceivesInstructionFileFlag() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let args = try await launch(root, provider: "claude")
        XCTAssertEqual(args, ["--append-system-prompt-file", root.appendingPathComponent("agent-instructions/builder.md").path])
    }
    // src/main/agents/agent-launch.test.ts:28
    func testCodexReceivesExactTOMLDeveloperInstructions() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let args = try await launch(root, provider: "codex")
        XCTAssertEqual(args, ["-c", #"developer_instructions="Work on a branch.\nSay \"done\" when \"done\".\n""#])
    }
    // Expected parity failure: native refusal wording differs from TS.
    // src/main/agents/agent-launch.test.ts:32
    func testUnsupportedProviderRefusalKeepsSourceWording() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for provider in ["gemini", "shell", "custom:aider"] {
            await errorContains("cannot be given standing instructions") { _ = try await self.launch(root, provider: provider) }
        }
    }
    // Expected parity failures: native missing/id refusal wording differs.
    // src/main/agents/agent-launch.test.ts:38 (Mac clauses; WSL is not applicable).
    func testMissingFileAndPathIDRefusalsKeepSourceWording() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await errorContains("missing or empty") { _ = try await self.launch(root, provider: "claude", id: "nobody") }
        await errorContains("not a task agent id") { _ = try await self.launch(root, provider: "claude", id: "../../etc/passwd") }
    }
    // src/main/agents/agent-launch.test.ts:45 (Mac clause; Windows limit excluded).
    func testMacAcceptsInstructionsBeyondWindowsArgumentRoom() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data((String(repeating: "x", count: 7_000) + "\n").utf8).write(to: root.appendingPathComponent("agent-instructions/builder.md"))
        let args = try await launch(root, provider: "codex")
        XCTAssertGreaterThan(try XCTUnwrap(args.last).count, 7_000)
    }
    // src/main/agents/agent-launch.test.ts:53
    func testTOMLBasicStringEscapesExactCharacters() {
        XCTAssertEqual(BackendNativeInstructions.tomlString("plain — ünïcode ✓"), "\"plain — ünïcode ✓\"")
        XCTAssertEqual(BackendNativeInstructions.tomlString("a\\b\"c"), #""a\\b\"c""#)
        XCTAssertEqual(BackendNativeInstructions.tomlString("tab\there\r\n"), #""tab\there\r\n""#)
        XCTAssertEqual(BackendNativeInstructions.tomlString("bell\u{0007} del\u{007f}"), #""bell\u0007 del\u007f""#)
    }
    // src/main/agents/agent-launch.test.ts:60. Swift repairs invalid UTF-16 at
    // the String boundary; the resolver still must preserve the resulting text.
    func testTOMLPreservesSurrogatePairsAndRepairedLoneSurrogate() {
        XCTAssertEqual(BackendNativeInstructions.tomlString("emoji 😀"), "\"emoji 😀\"")
        let units: [UInt16] = [0x6c, 0x6f, 0x6e, 0x65, 0x20, 0xd800, 0x20, 0x65, 0x6e, 0x64]
        XCTAssertEqual(BackendNativeInstructions.tomlString(String(decoding: units, as: UTF16.self)), "\"lone � end\"")
    }
    // Instruction part of host-core.agent-instructions.test.ts:102.
    // Ledger/PTY composition remains a separate integration gap.
    func testClaudeInstructionFlagCoexistsWithBlockedTools() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let args = try await launch(root, provider: "claude", denied: ["WebFetch"])
        XCTAssertEqual(args, ["--disallowedTools", "WebFetch", "--append-system-prompt-file", root.appendingPathComponent("agent-instructions/builder.md").path])
    }
    // host-core.agent-instructions.test.ts:148 instruction-only assertion.
    func testUnrequestedInstructionsAddNoFlag() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let args = try await launch(root, provider: "claude", id: nil)
        XCTAssertFalse(args.contains { $0.hasPrefix("--append-system-prompt") })
    }
}
