import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// TRUTH-B (12 Oct, SETTINGS-TRUTH.md): settings that said one thing and did another. Each test fails on the old code.
final class TRUTHBTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("truth-b-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func write(_ value: String, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }

    // MCP page: the four channels answer, and their choices reach every AI's launch.
    func testMcpSwitchesAreAnsweredAndSaved() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), data = root.appendingPathComponent("data")
        try write(#"{"mcpServers":{"gh":{"command":"echo","args":["x"],"env":{"GH_TOKEN":"secret-1"}},"web":{"type":"http","url":"https://example.com/mcp"}}}"#,
                  home.appendingPathComponent(".claude.json"))
        BackendMcpPolicy.configure(dataDirectory: data)
        let config = BackendMcpClientConfiguration(home: home.path, environment: [:])
        let writer = BackendMcpClientWriter(configuration: config, loginPath: { "/usr/bin" }, run: { _, _, _, _, _ in throw BackendMcpClientValue.error("Unexpected process") })
        let service = BackendMcpClientService(writer: writer), registry = NativeChannelRegistry()
        await service.setAgentsSource { [("agent-1", "Builder")] }
        _ = try await BackendMcpClientChannels.register(registry: registry, ownerID: "mcp-test", service: service)
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "mcp-test")
        func call(_ channel: String, _ fields: [NativeRPCValue.Field]) async throws -> NativeRPCValue {
            try await registry.invoke(channel, context: context, arguments: [.object([.init("serverId", .string("user:gh"))] + fields)])
        }
        let first = try await call("mcp:policy", [])
        XCTAssertEqual(first["ok"].bool, true); XCTAssertEqual(first["enabled"].bool, true)
        XCTAssertEqual(first["access"]["codex"].bool, true); XCTAssertEqual(first["agents"].elements?.first?["enabled"].bool, true)
        let revision = try XCTUnwrap(first["revision"].number)
        let off = try await call("mcp:tools:set", [.init("tool", .string("delete_repo")), .init("enabled", .bool(false)), .init("revision", .number(revision))])
        XCTAssertEqual(off["ok"].bool, true)
        // A screen holding the old revision is refused, never silently overwritten.
        let stale = try await call("mcp:access:set", [.init("client", .string("gemini")), .init("enabled", .bool(false)), .init("revision", .number(revision))])
        XCTAssertEqual(stale["ok"].bool, false)
        _ = try await call("mcp:access:set", [.init("client", .string("gemini")), .init("enabled", .bool(false))])
        _ = try await call("mcp:access:set", [.init("agentId", .string("agent-1")), .init("enabled", .bool(false))])
        let now = try await call("mcp:policy", [])
        XCTAssertEqual(now["tools"]["delete_repo"].bool, false); XCTAssertEqual(now["access"]["gemini"].bool, false)
        XCTAssertEqual(now["agents"].elements?.first?["enabled"].bool, false)
        // Hoot's mcp_switch names a server by its bare name and sends no revision.
        let hoot = try await registry.invoke("mcp:enabled", context: context, arguments: [.object([.init("serverId", .string("web")), .init("enabled", .bool(false))])])
        XCTAssertEqual(hoot["ok"].bool, true)
        let listed = try await registry.invoke("mcp:list", context: context, arguments: [])
        XCTAssertEqual(listed.elements?.first { $0["name"].string == "web" }?["enabled"].bool, false, "the page shows it Off")
        do { _ = try await registry.invoke("mcp:enabled", context: context, arguments: [.object([.init("serverId", .string("user:nope")), .init("enabled", .bool(false))])]); XCTFail() } catch {}

        // Claude Code: the server that is off and the tool that is off are refused.
        let document = BackendMcpPolicy.load()
        let claude = BackendMcpPolicy.launch(provider: "claude", cwd: "", agentID: nil, agentSettings: false, home: home.path, inherited: [:], environment: [:], privateDirectory: nil, document: document)
        XCTAssertEqual(claude.arguments, ["--disallowedTools", "mcp__gh__delete_repo,mcp__web"])
        let forAgent = BackendMcpPolicy.launch(provider: "claude", cwd: "", agentID: "agent-1", agentSettings: false, home: home.path, inherited: [:], environment: [:], privateDirectory: nil, document: document)
        XCTAssertEqual(forAgent.arguments, ["--disallowedTools", "mcp__gh,mcp__web"])
        // Under agent settings: the same choices fold into the agent's server switches and blocked tools.
        var settings = AGSAgentSettings(provider: "claude")
        BackendMcpPolicy.applyToAgentSettings(&settings, accountServers: ["gh", "web"], agentID: nil, document: document)
        XCTAssertEqual(settings.mcpServers["web"], false); XCTAssertEqual(settings.deniedTools, ["mcp__gh__delete_repo"])

        // Codex: the page's server reaches it, its secret in a private file only that server reads, minus what is off.
        let launchDir = root.appendingPathComponent("launch"); try FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)
        let codex = BackendMcpPolicy.launch(provider: "codex", cwd: "", agentID: nil, agentSettings: false, home: home.path, inherited: [:], environment: [:], privateDirectory: launchDir, document: document)
        let secrets = try XCTUnwrap(codex.readableFiles.first)
        XCTAssertTrue(codex.arguments.contains(#"mcp_servers.gh.command="/bin/sh""#))
        XCTAssertTrue(codex.arguments.contains("mcp_servers.gh.args=" + BackendMcpPolicy.toml(["-c", BackendMcpPolicy.secretsLoader, secrets, "echo", "x"])))
        XCTAssertTrue(codex.arguments.contains(#"mcp_servers.gh.disabled_tools=["delete_repo"]"#))
        XCTAssertFalse(codex.arguments.contains { $0.contains("secret-1") }, "a secret never goes on a command line")
        XCTAssertFalse(codex.arguments.contains { $0.contains("mcp_servers.web") }, "a server that is off is not handed over")
        XCTAssertTrue(codex.environment.isEmpty, "a secret never goes into the session's own environment")
        XCTAssertEqual(try String(contentsOfFile: secrets, encoding: .utf8), "export GH_TOKEN='secret-1'\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: secrets)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // What Codex runs hands the value to the server it starts, and to nothing else.
        let server = Process(), out = Pipe()
        server.executableURL = URL(fileURLWithPath: "/bin/sh"); server.arguments = ["-c", BackendMcpPolicy.secretsLoader, secrets, "/usr/bin/printenv", "GH_TOKEN"]
        server.environment = ["PATH": "/usr/bin:/bin"]; server.standardOutput = out
        try server.run(); server.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "secret-1\n")
        // With no private folder the server is left out, never handed its secret some other way.
        let unfiled = BackendMcpPolicy.launch(provider: "codex", cwd: "", agentID: nil, agentSettings: false, home: home.path, inherited: [:], environment: [:], privateDirectory: nil, document: document)
        XCTAssertFalse(unfiled.arguments.contains { $0.hasPrefix("mcp_servers.gh.") }); XCTAssertTrue(unfiled.environment.isEmpty)

        // Gemini: a private settings file, and only when it is on for Gemini.
        try BackendMcpPolicy.change("gh", expected: nil) { $0.clientsOff = [] }
        let gemini = BackendMcpPolicy.launch(provider: "gemini", cwd: "", agentID: nil, agentSettings: false, home: home.path,
                                             inherited: ["GEMINI_CLI_SYSTEM_SETTINGS_PATH": root.appendingPathComponent("none/settings.json").path],
                                             environment: [:], privateDirectory: launchDir)
        let file = try XCTUnwrap(gemini.environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"])
        let saved = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: file)))
        XCTAssertEqual(saved["mcpServers"]["gh"]["command"].string, "echo")
        XCTAssertEqual(saved["mcpServers"]["gh"]["excludeTools"].elements?.first?.string, "delete_repo")
        XCTAssertEqual(saved["mcp"]["excluded"].elements?.compactMap(\.string), ["web"])
    }

    // Skills page: a skill made or installed for Claude also reaches Codex and Gemini (.agents/skills), and goes with it.
    func testSkillsReachCodexAndGemini() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let service = BackendROUTINESSkills(dependencies: .init(projects: { [] }, profiles: { [] }, catalogue: { .object([]) },
            install: { _, _ in .null }, remove: { _ in .null }),
            sharedRoots: [.init(folder: home.appendingPathComponent(".claude/skills"), source: "Every project · .claude/skills")], home: home, writable: true)
        _ = try await service.create(name: "tidy", summary: "Tidy up", category: "Code", markdown: "Do it.", projectID: nil)
        let copy = home.appendingPathComponent(".agents/skills/tidy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent(BackendSkillsMirror.marker).path))
        // A folder of the same name that is not Terminal Deck's own is never replaced or removed.
        let theirs = home.appendingPathComponent(".agents/skills/mine")
        try write("---\nname: mine\n---\n", theirs.appendingPathComponent("SKILL.md"))
        try write("---\nname: mine\ndescription: x\n---\n", home.appendingPathComponent(".claude/skills/mine/SKILL.md"))
        XCTAssertNil(BackendSkillsMirror.mirror(home.appendingPathComponent(".claude/skills/mine")))
        BackendSkillsMirror.unmirror(home.appendingPathComponent(".claude/skills/mine"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirs.path))
        _ = try await service.remove(home.appendingPathComponent(".claude/skills/tidy").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    // Updates › "Upgrade it": each AI is updated through the route that installed it.
    func testUpgradeFollowsTheRouteThatInstalledIt() {
        guard case .attempts(let brew) = BackendAIToolInstallPlan.upgradePlan("gemini", installedAt: "/opt/homebrew/bin/gemini", brew: "/opt/homebrew/bin/brew", npm: nil) else { return XCTFail() }
        XCTAssertEqual(brew.first?.argv, ["/opt/homebrew/bin/brew", "upgrade", "gemini-cli"])
        guard case .attempts(let npm) = BackendAIToolInstallPlan.upgradePlan("codex", installedAt: "/usr/local/lib/node_modules/@openai/codex/bin/codex.js", brew: nil, npm: "/usr/local/bin/npm") else { return XCTFail() }
        XCTAssertEqual(npm.first?.argv, ["/usr/local/bin/npm", "install", "-g", "@openai/codex@latest"])
        guard case .attempts(let native) = BackendAIToolInstallPlan.upgradePlan("claude", installedAt: "/Users/a/.local/bin/claude", brew: nil, npm: nil) else { return XCTFail() }
        XCTAssertEqual(native.first?.scriptURL, "https://claude.ai/install.sh")
    }
}
