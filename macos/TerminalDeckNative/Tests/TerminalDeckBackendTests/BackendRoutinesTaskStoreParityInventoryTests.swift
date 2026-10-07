import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendRoutinesTaskStoreParityInventoryBindings {
    static let appServerName: (@Sendable () -> String)? = { BackendAppAgentInventory.appServerName }
    static let frontMatter: (@Sendable (String, String) -> String?)? = { head, key in (try? BackendAppAgentInventory.frontMatter(head, key: key)) ?? nil }
}
@Suite("Exact agent-inventory.test.ts parity — missing native discovery must fail visibly")
struct BackendRoutinesTaskStoreParityInventory {
    private let claude = BackendSharedAgentTools.claude.map(\.name)  // CLAUDE_TOOLS names
    private func write(_ text: String, at file: URL) throws { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: file) }
    private func skill(_ root: URL, _ folder: String, _ head: String) throws { try write(head, at: root.appendingPathComponent(folder).appendingPathComponent("SKILL.md")) }
    /// agent-inventory.test.ts calls `agentInventory(input)` directly: configDir, system, projects, env {}, provider, home.
    /// The scratch folder stands in for the machine's home so nothing outside it is read.
    private func inventory(_ root: URL, _ config: URL, projects: [URL], system: Bool = false, provider: String? = nil, home: URL? = nil) -> NativeRPCValue {
        BackendAppAgentInventory(systemHome: root.path).read(.init(provider: provider, configDirectory: config.path, system: system, projects: projects.map(\.path), environment: [:], home: home?.path)).wire
    }
    @Test func claudeInventoryReadsToolsServersAndSkillsOnlyFromDisk() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let account = r.root.appendingPathComponent("account"), project = r.root.appendingPathComponent("project"), plugin = r.root.appendingPathComponent("plugin-install")
        try write(#"{"mcpServers":{"github":{"command":"gh-mcp"}}}"#, at: account.appendingPathComponent(".claude.json"))
        try write(#"{"mcpServers":{"db tools":{"command":"db"}}}"#, at: project.appendingPathComponent(".mcp.json"))
        try skill(account.appendingPathComponent("skills"), "review", "---\nname: code-review\ndescription: Review a diff\n---\nbody")
        try skill(account.appendingPathComponent("skills"), "plain", "no front matter")
        try FileManager.default.createDirectory(at: account.appendingPathComponent("skills/not-a-skill"), withIntermediateDirectories: true)
        try skill(project.appendingPathComponent(".claude/skills"), "deploy", "---\nname: \"ship-it\"\n---")
        try skill(plugin.appendingPathComponent("skills"), "lint", "---\nname: lint\n---")
        try write(routinesTaskObject([("version", .number(2)), ("plugins", routinesTaskObject([("tidy@market", .array([routinesTaskObject([("installPath", .string(plugin.path))])]))]))]).compact, at: account.appendingPathComponent("plugins/installed_plugins.json"))
        let found = inventory(r.root, account, projects: [project])
        let tools = found["tools"].elements?.compactMap { $0["value"].string } ?? []
        #expect(Array(tools.prefix(claude.count)) == claude); #expect(tools.contains("mcp__deck-control")); #expect(tools.contains("mcp__github")); #expect(tools.contains("mcp__db_tools"))
        #expect(found["skills"].elements?.compactMap { $0["value"].string } == ["plain", "code-review", "ship-it", "tidy:lint"])
        #expect(found["skills"].elements?.first { $0["value"].string == "code-review" }?["label"].string == "code-review — Review a diff")
        try skill(account.appendingPathComponent("skills"), "long", "---\nname: long\ndescription: " + String(repeating: "word ", count: 40) + "\n---")
        let again = inventory(r.root, account, projects: []), long = try #require(again["skills"].elements?.first { $0["value"].string == "long" }?["label"].string)
        #expect(long.utf16.count <= "long — ".utf16.count + 61); #expect(long.hasSuffix("…"))
        }
    }
    @Test func absentConfigurationOffersClaudeToolsAndAppOnly() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let found = inventory(r.root, r.root.appendingPathComponent("none"), projects: [r.root.appendingPathComponent("missing")])
        #expect(found["skills"] == .array([])); #expect(found["tools"].elements?.allSatisfy { $0["where"].string == "Claude Code" || $0["value"].string == "mcp__deck-control" } == true)
        }
    }
    @Test func appServerNameMatchesAndAbsentFrontMatterIsNil() throws {
        let name = try #require(BackendRoutinesTaskStoreParityInventoryBindings.appServerName)
        #expect(name() == "deck-control")
        let frontMatter = try #require(BackendRoutinesTaskStoreParityInventoryBindings.frontMatter)
        #expect(frontMatter("---\nname: x\n---", "description") == nil)
    }
    @Test func codexUsesOwnServersAndAccountHomeProjectSystemSkillOrder() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let codex = r.root.appendingPathComponent("codex-home"), home = r.root.appendingPathComponent("home"), project = r.root.appendingPathComponent("project")
        try write("model = \"x\"\n[mcp_servers.github]\ncommand = \"gh\"\n[mcp_servers.\"db tools\"]\ncommand = \"db\"\n[mcp_servers.github.env]\nA = \"1\"\n", at: codex.appendingPathComponent("config.toml"))
        try skill(codex.appendingPathComponent("skills"), "alpha", "---\nname: alpha\ndescription: From the account\n---")
        try skill(codex.appendingPathComponent("skills/.system"), "imagegen", "---\nname: imagegen\n---")
        try skill(home.appendingPathComponent(".agents/skills"), "delta", "---\nname: delta\n---")
        try skill(project.appendingPathComponent(".agents/skills"), "gamma", "---\nname: gamma\n---")
        try skill(project.appendingPathComponent(".claude/skills"), "claude-only", "---\nname: claude-only\n---")
        let found = inventory(r.root, codex, projects: [project], system: true, provider: "codex", home: home)
        let tools = found["tools"].elements?.compactMap { $0["value"].string } ?? []; #expect(tools == ["mcp__github", "mcp__db_tools"]); #expect(!tools.contains { claude.contains($0) })
        #expect(found["skills"].elements?.map { [$0["value"].string!, $0["where"].string!] } == [["alpha", "account"], ["delta", "home"], ["gamma", "project"], ["imagegen", "built in"]])
        }
    }
    @Test func unsupportedProviderHasNoInventedInventory() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        for provider in ["gemini", "custom:aider"] { #expect(inventory(r.root, r.root.appendingPathComponent("x"), projects: [], system: true, provider: provider) == routinesTaskObject([("tools", .array([])), ("skills", .array([]))])) }
        }
    }
}
