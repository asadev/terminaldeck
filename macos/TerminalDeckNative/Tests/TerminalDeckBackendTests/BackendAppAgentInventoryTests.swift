import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppAgentInventoryTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppAgentInventory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func write(_ file: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
    private func skill(_ directory: URL, _ folder: String, _ text: String) throws {
        try write(directory.appendingPathComponent(folder + "/SKILL.md"), text)
    }
    func testClaudeToolsAppConfiguredServersAndAllSkillLocations() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), project = root.appendingPathComponent("project"), plugin = root.appendingPathComponent("plugin-install")
        try write(account.appendingPathComponent(".claude.json"), #"{"mcpServers":{"github":{"command":"gh-mcp"}}}"#)
        try write(project.appendingPathComponent(".mcp.json"), #"{"mcpServers":{"db tools":{"command":"db"}}}"#)
        try skill(account.appendingPathComponent("skills"), "review", "---\nname: code-review\ndescription: Review a diff\n---\nbody")
        try skill(account.appendingPathComponent("skills"), "plain", "no front matter")
        try FileManager.default.createDirectory(at: account.appendingPathComponent("skills/not-a-skill"), withIntermediateDirectories: true)
        try skill(project.appendingPathComponent(".claude/skills"), "deploy", "---\nname: \"ship-it\"\n---")
        try skill(plugin.appendingPathComponent("skills"), "lint", "---\nname: lint\n---")
        try write(account.appendingPathComponent("plugins/installed_plugins.json"), NativeRPCValue.object([.init("version", .number(2)),
            .init("plugins", .object([.init("tidy@market", .array([.object([.init("installPath", .string(plugin.path))])]))]))]).compact)
        let reader = BackendAppAgentInventory(systemHome: root.path)
        let found = reader.read(.init(configDirectory: account.path, system: false, projects: [project.path], environment: [:]))
        XCTAssertEqual(Array(found.tools.prefix(BackendSharedAgentTools.claude.count)).map(\.value), BackendSharedAgentTools.claude.map(\.name))
        for value in ["mcp__deck-control", "mcp__github", "mcp__db_tools"] { XCTAssertTrue(found.tools.contains { $0.value == value }) }
        XCTAssertEqual(found.skills.map(\.value), ["plain", "code-review", "ship-it", "tidy:lint"])
        XCTAssertEqual(found.skills.first { $0.value == "code-review" }?.label, "code-review — Review a diff")
        XCTAssertEqual(found.skills.last?.where, "plugin tidy")
    }
    func testDescriptionIsCutAtAWordAndMarked() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try skill(root.appendingPathComponent("skills"), "long", "---\nname: long\ndescription: " + String(repeating: "word ", count: 40) + "\n---")
        let found = BackendAppAgentInventory(systemHome: root.path).read(.init(configDirectory: root.path, system: false, projects: [], environment: [:]))
        let label = try XCTUnwrap(found.skills.first?.label)
        XCTAssertLessThanOrEqual(label.utf16.count, "long — ".utf16.count + 61); XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertEqual(BackendAppAgentInventory.shortened("short"), "short")
        XCTAssertEqual(BackendAppAgentInventory.shortened(String(repeating: "x", count: 61)), String(repeating: "x", count: 60) + "…")
    }
    func testNoConfigurationStillHasClaudeAndAppTools() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let found = BackendAppAgentInventory(systemHome: root.path).read(.init(configDirectory: root.appendingPathComponent("none").path, system: false, projects: [root.appendingPathComponent("missing").path], environment: [:]))
        XCTAssertTrue(found.skills.isEmpty)
        XCTAssertTrue(found.tools.allSatisfy { $0.where == "Claude Code" || $0.value == "mcp__deck-control" })
    }
    func testAppServerNameAndFrontMatterExactlyMatchSource() throws {
        XCTAssertEqual(BackendAppAgentInventory.appServerName, BackendDeckCoreSecurityServer.serverName)
        XCTAssertNil(try BackendAppAgentInventory.frontMatter("---\nname: x\n---", key: "description"))
        XCTAssertNil(try BackendAppAgentInventory.frontMatter("before\n---\nname: x\n---", key: "name"))
        XCTAssertEqual(try BackendAppAgentInventory.frontMatter("---\r\nname: 'x'\r\n---", key: "name"), "x")
        XCTAssertEqual(try BackendAppAgentInventory.frontMatter("---\nname: \"x'\n---", key: "name"), "x")
        XCTAssertNil(try BackendAppAgentInventory.frontMatter("---\nname: ''\n---", key: "name"))
        XCTAssertThrowsError(try BackendAppAgentInventory.frontMatter("---\nname: x\n---", key: "["))
    }
    func testCodexUsesItsOwnServersAndSkillLocations() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("codex-home"), home = root.appendingPathComponent("home"), project = root.appendingPathComponent("project")
        try write(account.appendingPathComponent("config.toml"), "model = \"x\"\n[mcp_servers.github]\ncommand = \"gh\"\n[mcp_servers.\"db tools\"]\ncommand = \"db\"\n[mcp_servers.github.env]\nA = \"1\"\n")
        try skill(account.appendingPathComponent("skills"), "alpha", "---\nname: alpha\ndescription: From the account\n---")
        try skill(account.appendingPathComponent("skills/.system"), "imagegen", "---\nname: imagegen\n---")
        try skill(home.appendingPathComponent(".agents/skills"), "delta", "---\nname: delta\n---")
        try skill(project.appendingPathComponent(".agents/skills"), "gamma", "---\nname: gamma\n---")
        try skill(project.appendingPathComponent(".claude/skills"), "claude-only", "---\nname: claude-only\n---")
        let found = BackendAppAgentInventory(systemHome: root.path).read(.init(provider: "codex", configDirectory: account.path, system: true, projects: [project.path], environment: [:], home: home.path))
        XCTAssertEqual(found.tools.map(\.value), ["mcp__github", "mcp__db_tools"])
        XCTAssertFalse(found.tools.contains { tool in BackendSharedAgentTools.claude.contains { $0.name == tool.value } })
        XCTAssertEqual(found.skills.map(\.value), ["alpha", "delta", "gamma", "imagegen"])
        XCTAssertEqual(found.skills.map(\.where), ["account", "home", "project", "built in"])
    }
    func testGeminiCustomAndShellHaveNoGuessedInventory() {
        let reader = BackendAppAgentInventory(systemHome: "/tmp/BackendAppAgentInventory-no-home", loadServers: { _, _ in XCTFail("Unsupported provider read MCP configuration"); return [] })
        for provider in ["gemini", "custom:aider", "shell"] {
            XCTAssertEqual(reader.read(.init(provider: provider, configDirectory: "/tmp/unused", system: true, projects: [], environment: [:])), .init(tools: [], skills: []))
        }
    }
    func testSystemAccountScrubsInheritedOverrideAndUsesSiblingClaudeJSON() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent(".claude"), foreign = root.appendingPathComponent("foreign")
        try write(root.appendingPathComponent(".claude.json"), #"{"mcpServers":{"system-only":{"command":"ok"}}}"#)
        try write(account.appendingPathComponent(".claude.json"), #"{"mcpServers":{"wrong-inside":{"command":"ok"}}}"#)
        try write(foreign.appendingPathComponent(".claude.json"), #"{"mcpServers":{"wrong-inherited":{"command":"ok"}}}"#)
        let found = BackendAppAgentInventory(systemHome: root.path).read(.init(configDirectory: account.path, system: true, projects: [], environment: ["CLAUDE_CONFIG_DIR": foreign.path]))
        XCTAssertTrue(found.tools.contains { $0.value == "mcp__system-only" })
        XCTAssertFalse(found.tools.contains { $0.value == "mcp__wrong-inside" || $0.value == "mcp__wrong-inherited" })
    }
    func testToolsDedupeSanitizedNamesAndOnlyUniqueRowsSpendTheCap() {
        let servers = [NativeRPCValue.object([.init("name", .string("db tools")), .init("scope", .string("user"))]),
                       .object([.init("name", .string("db_tools")), .init("scope", .string("project"))])] + (0..<310).map {
            NativeRPCValue.object([.init("name", .string(String(format: "server%03d", $0))), .init("scope", .string("user"))])
        }
        let reader = BackendAppAgentInventory(systemHome: "/tmp/unused", loadServers: { _, _ in servers })
        let found = reader.read(.init(configDirectory: "/tmp/unused-account", system: false, projects: ["/tmp/unused-project"], environment: [:]))
        XCTAssertEqual(found.tools.count, 300); XCTAssertEqual(Set(found.tools.map(\.value)).count, 300)
        XCTAssertEqual(found.tools.first { $0.value == "mcp__db_tools" }?.where, "MCP, user")
    }
    func testSkillsDedupeAccountBeforeProjectAndCapAtThreeHundred() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), project = root.appendingPathComponent("project")
        for index in 0..<301 { try skill(account.appendingPathComponent("skills"), String(format: "s%03d", index), "body") }
        try skill(project.appendingPathComponent(".claude/skills"), "s000", "---\nname: s000\ndescription: project duplicate\n---")
        let found = BackendAppAgentInventory(systemHome: root.path).read(.init(configDirectory: account.path, system: false, projects: [project.path], environment: [:]))
        XCTAssertEqual(found.skills.count, 300); XCTAssertEqual(found.skills.first?.value, "s000"); XCTAssertEqual(found.skills.last?.value, "s299")
        XCTAssertTrue(found.skills.allSatisfy { $0.where == "account" })
    }
    func testOnlyFirstPluginInstallAndValidSkillNamesAreOffered() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try skill(first.appendingPathComponent("skills"), "ok", "---\nname: ok\n---")
        try skill(second.appendingPathComponent("skills"), "ignored", "body")
        try skill(root.appendingPathComponent("skills"), "invalid", "---\nname: bad name\n---")
        let installs = NativeRPCValue.array([.object([.init("installPath", .string(first.path))]), .object([.init("installPath", .string(second.path))])])
        try write(root.appendingPathComponent("plugins/installed_plugins.json"), NativeRPCValue.object([.init("plugins", .object([.init("tidy@market", installs), .init("@bad", installs), .init("broken", .object([]))]))]).compact)
        let found = BackendAppAgentInventory(systemHome: root.path).read(.init(configDirectory: root.path, system: false, projects: [], environment: [:]))
        XCTAssertEqual(found.skills.map(\.value), ["tidy:ok"])
    }
    func testHeaderLimitIsDecodedUTF16AndFolderSortIsUTF16() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        // Closing front matter is beyond4096 bytes but inside4096 UTF-16 units.
        try skill(root.appendingPathComponent("skills"), "cjk", "---\nname: cjk\ndescription: " + String(repeating: "界", count: 2000) + "\n---")
        try skill(root.appendingPathComponent("skills"), "beyond", "---\n" + String(repeating: "#", count: 4100) + "\nname: hidden\n---")
        try skill(root.appendingPathComponent("skills"), "\u{10000}", "---\nname: supplementary\n---")
        try skill(root.appendingPathComponent("skills"), "\u{E000}", "---\nname: private-use\n---")
        let found = BackendAppAgentInventory(systemHome: root.path).read(.init(configDirectory: root.path, system: false, projects: [], environment: [:]))
        XCTAssertEqual(found.skills.map(\.value), ["beyond", "cjk", "supplementary", "private-use"])
        XCTAssertTrue(found.skills.first { $0.value == "cjk" }?.label.hasSuffix("…") == true)
    }
    func testCodexTableGrammarDuplicatesMalformedUTF8AndNestedTables() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.toml")
        var bytes = Data([0xff, 10]); bytes.append(Data(" [mcp_servers.github]\r\n[mcp_servers.\"db tools\"]\n[mcp_servers.github]\n[mcp_servers.github.env]\n[mcp_servers.bad.name]\n".utf8))
        try bytes.write(to: file)
        XCTAssertEqual(BackendAppAgentInventory.codexServers(file: file.path), ["github", "db tools"])
    }
    func testBrokenServerReaderDoesNotEraseSkillsOrOtherProjectServers() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try skill(root.appendingPathComponent("skills"), "ok", "body")
        let reader = BackendAppAgentInventory(systemHome: root.path, loadServers: { project, _ in
            guard project != nil else { throw NativeRPCError(code: "fixture", message: "unreadable") }
            return [.object([.init("name", .string("project")), .init("scope", .string("project"))])]
        })
        let found = reader.read(.init(configDirectory: root.path, system: false, projects: [root.appendingPathComponent("project").path], environment: [:]))
        XCTAssertTrue(found.tools.contains { $0.value == "mcp__project" }); XCTAssertEqual(found.skills.map(\.value), ["ok"])
    }
    func testTaskAdapterResolvesAccountNameAndRestrictsFoldersToSavedForty() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), home = root.appendingPathComponent("home"), account = data.appendingPathComponent("profiles/work")
        try write(data.appendingPathComponent("profiles.json"), NativeRPCValue.object([.init("version", .number(1)), .init("profiles", .array([
            .object([.init("id", .string("work")), .init("name", .string("Team Account")), .init("provider", .string("codex")), .init("configDir", .string(account.path))])
        ])), .init("defaultProfileId", .string("work"))]).compact)
        try write(account.appendingPathComponent("config.toml"), "[mcp_servers.account-only]\ncommand = \"ok\"\n")
        let projects: [NativeRPCValue] = (0..<41).map { index in
            .object([.init("path", .string(root.appendingPathComponent("project\(index)").path)), .init("lastOpenedAt", .number(Double(41 - index)))])
        }
        try skill(root.appendingPathComponent("project39/.agents/skills"), "included", "body")
        try skill(root.appendingPathComponent("project40/.agents/skills"), "excluded", "body")
        let store = NativeStateStore(initialState: NativeStateStore.defaults.setting("projects", .array(projects)))
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "Terminal Deck", appID: "terminaldeck", helperExecutable: root.appendingPathComponent("never-run-helper"), inheritedEnvironment: [:])
        let profiles = try BackendAccountProfileStore(configuration: configuration, stateStore: store)
        let adapter = BackendAppAgentInventoryTaskAdapter(reader: .init(systemHome: home.path), profiles: profiles, store: store, environment: [:])
        let found = try await adapter.callback(.object([.init("provider", .string(" codex ")), .init("account", .string(" TEAM ACCOUNT ")), .init("configDir", .string("/ignored-renderer-directory"))]))
        XCTAssertEqual(found["account"].string, "Team Account")
        XCTAssertEqual(found["tools"].elements?.map { $0["value"].string }, ["mcp__account-only"])
        XCTAssertEqual(found["skills"].elements?.map { $0["value"].string }, ["included"])
        let other = try await adapter.inventory(.object([.init("provider", .string("gemini")), .init("account", .string("not-found"))]))
        XCTAssertEqual(other["account"].string, "Default"); XCTAssertEqual(other["tools"], .array([])); XCTAssertEqual(other["skills"], .array([]))
    }
}
