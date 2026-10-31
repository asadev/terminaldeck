import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Night S3: cases of the clients test inventory that had no Swift counterpart.
/// src/main/staysfixed/agents.test.ts (agentLaunch / serverSpec / tomlTable, Claude, Codex, Gemini),
/// src/main/memory/text-index.test.ts parseNote, src/main/knowledge/knowledge.test.ts parseRecord.
private struct S3ProjectSource: BackendProjectMCPSource {
    let readiness: BackendLaunchReadiness = .ready
    var environment: [String: String] = ["ELECTRON_RUN_AS_NODE": "1", "TD_SF_EXEC_PATH": "/u/staysfixed/bin/node", "PATH": "/opt/homebrew/bin:/usr/bin:/u/staysfixed/bin"]
    func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? {
        guard ["claude", "codex", "gemini"].contains(provider) else { return nil }
        let spec = try BackendProjectMCPServerSpec(name: "staysfixed", command: "/bin/sh", arguments: ["--import", "file:///preload.mjs", "bin/staysfixed.js", "mcp", "--cwd", cwd], environment: environment, implementation: .suppliedSourceBridge)
        return .stdio(root: cwd, server: spec)
    }
}

@MainActor final class BackendClientsS3Tests: XCTestCase {
    private let path = "/usr/bin:/bin"
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-clients-s3-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("userData"), withIntermediateDirectories: true)
        return try BackendFilesystemAuthority.canonical(url)
    }
    private func composition(_ root: URL, env: [String: String] = [:], source: S3ProjectSource = S3ProjectSource()) throws -> BackendProjectToolComposition {
        try BackendProjectToolComposition(source: source, userData: root.appendingPathComponent("userData"),
            inheritedEnvironment: env.isEmpty ? ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": root.appendingPathComponent("no-such-defaults.json").path] : env)
    }
    private func json(_ file: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
    }

    // agents.test.ts L58 "reaches every agent this app runs — never only one" (+ shell/custom give nothing)
    func testStaysFixedReachesEveryAgentAndNothingForShellOrCustom() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = try composition(root)
        for provider in ["claude", "codex", "gemini"] {
            let launch = try await tools.prepare(provider: provider, cwd: "/work/shop", loginPath: path)
            XCTAssertNotNil(launch, provider); if let launch { await tools.abandon(launch.id) }
        }
        for provider in ["shell", "custom:my-agent"] {
            let launch = try await tools.prepare(provider: provider, cwd: "/work/shop", loginPath: path)
            XCTAssertNil(launch, provider)
        }
        await tools.stop()
    }

    // L68 one --mcp-config file in the app's own folder, never --strict-mcp-config; L81 one file per project
    func testClaudeGetsOneMcpConfigInOwnFolderAndOneFilePerProject() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = try composition(root)
        let aResult = try await tools.prepare(provider: "claude", cwd: "/work/a", loginPath: path)
        let a = try XCTUnwrap(aResult)
        let bResult = try await tools.prepare(provider: "claude", cwd: "/work/b", loginPath: path)
        let b = try XCTUnwrap(bResult)
        XCTAssertEqual(a.arguments.count, 2); XCTAssertEqual(a.arguments[0], "--mcp-config")
        XCTAssertFalse(a.arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(a.arguments[1].hasPrefix(root.appendingPathComponent("userData/staysfixed/agents").path))
        XCTAssertNotEqual(a.arguments[1], b.arguments[1])
        let config = try json(a.arguments[1]), servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["staysfixed"])
        let server = try XCTUnwrap(servers["staysfixed"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "stdio")
        XCTAssertTrue((server["args"] as? [String] ?? []).contains("/work/a"))
        XCTAssertEqual(a.environment, [:])
        await tools.abandon(a.id); await tools.abandon(b.id); await tools.stop()
    }

    // L89 Codex gets four -c overrides with the long timeout; L100 TOML quotes what needs quoting
    func testCodexGetsFourOverridesWithNinetyHundredSecondTimeoutAndQuotedToml() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let source = S3ProjectSource(environment: ["PATH": "/x", "odd key": "y"])
        let tools = try composition(root, source: source)
        let launchResult = try await tools.prepare(provider: "codex", cwd: "/work/shop", loginPath: path)
        let launch = try XCTUnwrap(launchResult)
        let flags = stride(from: 0, to: launch.arguments.count, by: 2).map { launch.arguments[$0] }
        let values = stride(from: 1, to: launch.arguments.count, by: 2).map { launch.arguments[$0] }
        XCTAssertEqual(flags, ["-c", "-c", "-c", "-c"])
        XCTAssertEqual(values[0], "mcp_servers.staysfixed.command=\"/bin/sh\"")
        XCTAssertEqual(values[1], "mcp_servers.staysfixed.args=[\"--import\",\"file:///preload.mjs\",\"bin/staysfixed.js\",\"mcp\",\"--cwd\",\"/work/shop\"]")
        XCTAssertEqual(values[2], "mcp_servers.staysfixed.env={PATH=\"/x\",\"odd key\"=\"y\"}")
        XCTAssertEqual(values[3], "mcp_servers.staysfixed.tool_timeout_sec=900")
        XCTAssertEqual(launch.environment, [:])
        XCTAssertEqual(BackendNativeInstructions.tomlString("c\"d"), "\"c\\\"d\"")
        XCTAssertEqual(BackendNativeInstructions.tomlString("a b"), "\"a b\"")
        await tools.abandon(launch.id); await tools.stop()
    }

    // L107 Gemini gets the server through the system-defaults variable, nothing else added
    func testGeminiGetsServerThroughSystemDefaultsVariableOnly() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = try composition(root)
        let launchResult = try await tools.prepare(provider: "gemini", cwd: "/work/shop", loginPath: path)
        let launch = try XCTUnwrap(launchResult)
        XCTAssertEqual(launch.arguments, [])
        let file = try XCTUnwrap(launch.environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"])
        let servers = try XCTUnwrap(json(file)["mcpServers"] as? [String: Any]), server = try XCTUnwrap(servers["staysfixed"] as? [String: Any])
        XCTAssertEqual((server["timeout"] as? NSNumber)?.intValue, 900_000)
        XCTAssertEqual(Set(launch.environment.keys), ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"])
        await tools.abandon(launch.id); await tools.stop()
    }

    // L115 an existing system-defaults file is carried into the new one and never written; L135 found where Gemini looks
    func testGeminiCarriesExistingDefaultsForwardWithoutWritingThem() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let theirs = root.appendingPathComponent("their-defaults.json")
        let original = #"{"ui":{"theme":"GitHub"},"mcpServers":{"company":{"command":"company-mcp"}}}"#
        try Data(original.utf8).write(to: theirs)
        let tools = try composition(root, env: ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": theirs.path])
        let launchResult = try await tools.prepare(provider: "gemini", cwd: "/work/shop", loginPath: path)
        let launch = try XCTUnwrap(launchResult)
        let ours = try XCTUnwrap(launch.environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"]); XCTAssertNotEqual(ours, theirs.path)
        let config = try json(ours)
        XCTAssertEqual((config["ui"] as? [String: Any])?["theme"] as? String, "GitHub")
        XCTAssertEqual(Set((config["mcpServers"] as? [String: Any] ?? [:]).keys), ["company", "staysfixed"])
        XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), original)
        await tools.abandon(launch.id)
        // Derived location: GEMINI_CLI_SYSTEM_SETTINGS_PATH's folder + system-defaults.json
        let folder = root.appendingPathComponent("custom"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"general":{"vimMode":true}}"#.utf8).write(to: folder.appendingPathComponent("system-defaults.json"))
        let derived = try composition(root, env: ["GEMINI_CLI_SYSTEM_SETTINGS_PATH": folder.appendingPathComponent("settings.json").path])
        let secondResult = try await derived.prepare(provider: "gemini", cwd: "/work/shop", loginPath: path)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual((try json(try XCTUnwrap(second.environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"]))["general"] as? [String: Any])?["vimMode"] as? Bool, true)
        await derived.abandon(second.id); await derived.stop(); await tools.stop()
    }

    // text-index.test.ts L65/L73: parseNote name, title, links once each, body start, heading then file-name fallback
    func testMemoryNoteTakesNameBodyAndLinksOnceEachWithTitleFallbacks() {
        let text = ["---", "name: relay-is-the-network", "description: never Tailscale", "metadata:", "  type: feedback", "---", "",
                    "See [[servers]] and [[vault|the vault]] and [[servers#ports]] again."].joined(separator: "\n")
        let note = BackendMemoryParsing.parseNote(text, file: "/m/feedback_relay.md")
        XCTAssertEqual(note.name, "relay-is-the-network"); XCTAssertEqual(note.title, "relay-is-the-network")
        XCTAssertEqual(note.links, ["servers", "vault"]); XCTAssertTrue(note.body.hasPrefix("\nSee"))
        XCTAssertEqual(BackendMemoryParsing.parseNote("# Heading here\ntext", file: "/m/a.md").title, "Heading here")
        XCTAssertEqual(BackendMemoryParsing.parseNote("just text", file: "/m/plain-note.md").title, "plain-note")
        XCTAssertEqual(BackendMemoryParsing.wikiLinks("[[ ]] [[a]]"), ["a"])
    }

    // knowledge.test.ts L118: a file that is not a record is left out rather than guessed at
    func testKnowledgeLeavesOutAFileThatIsNotARecord() {
        XCTAssertNil(BackendKnowledgeFormat.parse("---\nkind: decision\n---\nno status, no source", file: "kx.md", project: "/work/api"))
        XCTAssertNil(BackendKnowledgeFormat.parse("just text", file: "ky.md", project: "/work/api"))
    }
}
