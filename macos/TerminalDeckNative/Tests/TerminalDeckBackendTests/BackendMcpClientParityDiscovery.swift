import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Test func mcpParityClaudeConfigPathsKeepDefaultOverrideAndEmptyOverrideRules() {
    let normal = BackendMcpClientConfiguration(home: "/Users/fixture", environment: [:])
    #expect(normal.claudeJSONPath == "/Users/fixture/.claude.json" && normal.claudeSettingsDirectory == "/Users/fixture/.claude")
    let moved = BackendMcpClientConfiguration(home: "/Users/fixture", environment: ["CLAUDE_CONFIG_DIR": "/tmp/work-profile"])
    #expect(moved.claudeJSONPath == "/tmp/work-profile/.claude.json" && moved.claudeSettingsDirectory == "/tmp/work-profile")
    let blank = BackendMcpClientConfiguration(home: "/Users/fixture", environment: ["CLAUDE_CONFIG_DIR": "   "])
    #expect(blank.claudeJSONPath == normal.claudeJSONPath && blank.claudeSettingsDirectory == normal.claudeSettingsDirectory)
}
@Test func mcpParityJSONReaderIsolatedTemporaryFilesMatchEveryFailureShape() throws {
    let fixture = try McpParityFixture(); defer { fixture.dispose() }
    #expect(BackendMcpClientConfiguration.readJSON(fixture.root.appendingPathComponent("nope.json").path) == .null)
    #expect(BackendMcpClientConfiguration.readJSON(fixture.root.path) == .null)
    let file = fixture.root.appendingPathComponent("half.json")
    try Data(#"{"mcpServers":{"a":{"command":"node""#.utf8).write(to: file)
    #expect(BackendMcpClientConfiguration.readJSON(file.path) == .null)
    try Data(#"{"mcpServers":{}}"#.utf8).write(to: file)
    #expect(BackendMcpClientConfiguration.readJSON(file.path) == .object([.init("mcpServers", .object([]))]))
}
@Test func mcpParityEnvironmentExpansionEveryFallbackAndMissingRule() {
    #expect(BackendMcpClientConfiguration.expand("Bearer ${TOKEN}", environment: ["TOKEN": "abc"]) == "Bearer abc")
    #expect(BackendMcpClientConfiguration.expand("${PORT:-8080}", environment: [:]) == "8080")
    #expect(BackendMcpClientConfiguration.expand("${MISSING}", environment: [:]) == "${MISSING}")
    #expect(BackendMcpClientConfiguration.expand("${TOKEN:-fallback}", environment: ["TOKEN": ""]) == "fallback")
}
@Test func mcpParityServerEntryNarrowsTransportMalformedRowsAndNumericValues() throws {
    let stdio = try #require(BackendMcpClientConfiguration.parse(name: "files", raw: mcpParityJSON(#"{"command":"npx","args":["-y","server-filesystem","/tmp"],"env":{"DEBUG":"1"}}"#), scope: "user", source: "/cfg/.claude.json", environment: [:]))
    #expect(stdio["id"].string == "user:files" && stdio["name"].string == "files" && stdio["transport"].string == "stdio")
    #expect(stdio["command"].string == "npx" && stdio["args"].elements == [.string("-y"), .string("server-filesystem"), .string("/tmp")])
    #expect(stdio["env"] == .object([.init("DEBUG", .string("1"))]) && stdio["unsupported"] == .null)
    let http = try #require(BackendMcpClientConfiguration.parse(name: "higgsfield", raw: mcpParityJSON(#"{"type":"http","url":"https://mcp.example.ai/mcp"}"#), scope: "user", source: "s", environment: [:]))
    #expect(http["transport"].string == "http" && http["url"].string == "https://mcp.example.ai/mcp" && http["command"] == .null)
    #expect(http["unsupported"].string == "Claude Code dials HTTP servers itself, so this panel cannot inspect it.")
    let mixed = BackendMcpClientConfiguration.parse(name: "mixed", raw: try mcpParityJSON(#"{"type":"sse","url":"https://x/sse","command":"node"}"#), scope: "user", source: "s", environment: [:])
    #expect(mixed?["transport"].string == "sse")
    for raw in [try mcpParityJSON(#"{"args":["x"]}"#), NativeRPCValue.string("npx server"), .null] { #expect(BackendMcpClientConfiguration.parse(name: "bad", raw: raw, scope: "user", source: "s", environment: [:]) == nil) }
    #expect(BackendMcpClientConfiguration.parse(name: "", raw: stdio, scope: "user", source: "s", environment: [:]) == nil)
    let numbers = BackendMcpClientConfiguration.parse(name: "n", raw: try mcpParityJSON(#"{"command":"node","args":["--port",3000],"env":{"PORT":3000}}"#), scope: "user", source: "s", environment: [:])
    #expect(numbers?["args"].elements == [.string("--port"), .string("3000")] && numbers?["env"]["PORT"].string == "3000")
    let expanded = BackendMcpClientConfiguration.parse(name: "e", raw: try mcpParityJSON(#"{"command":"${BIN}","args":["${DIR:-/tmp}"],"env":{"KEY":"${SECRET}"}}"#), scope: "user", source: "s", environment: ["BIN": "/usr/local/bin/node", "SECRET": "s3cret"])
    #expect(expanded?["command"].string == "/usr/local/bin/node" && expanded?["args"].elements == [.string("/tmp")] && expanded?["env"]["KEY"].string == "s3cret")
}
@Test func mcpParityServerMapKeepsSourceOrderAndGoodNeighbors() throws {
    let raw = try mcpParityJSON(#"{"good":{"command":"node"},"broken":42,"alsoGood":{"url":"https://x"}}"#)
    #expect(BackendMcpClientConfiguration.parseMap(raw, scope: "user", source: "s", environment: [:]).map { $0["name"].string! } == ["good", "alsoGood"])
    #expect(BackendMcpClientConfiguration.parseMap(.missing, scope: "user", source: "s", environment: [:]) == [])
    #expect(BackendMcpClientConfiguration.parseMap(.array([]), scope: "user", source: "s", environment: [:]) == [])
}
@Test func mcpParityProjectGatesPreservePendingExplicitApprovalAndRejectionPrecedence() throws {
    let project = BackendMcpClientConfiguration.parseMap(try mcpParityJSON(#"{"shared":{"command":"node"}}"#), scope: "project", source: "/p/.mcp.json", environment: [:])
    let pending = BackendMcpClientConfiguration.applyProjectGates(project, gates: try mcpParityJSON(#"{"enabled":[],"disabled":[],"enableAll":false}"#))[0]
    #expect(pending["enabled"].bool == false && pending["disabledReason"].string == "Not approved for this project yet.")
    let approved = BackendMcpClientConfiguration.applyProjectGates(project, gates: try mcpParityJSON(#"{"enabled":["shared"],"disabled":[],"enableAll":false}"#))[0]
    #expect(approved["enabled"].bool == true && approved["disabledReason"] == .null)
    let rejected = BackendMcpClientConfiguration.applyProjectGates(project, gates: try mcpParityJSON(#"{"enabled":["shared"],"disabled":["shared"],"enableAll":true}"#))[0]
    #expect(rejected["enabled"].bool == false && rejected["disabledReason"].string == "Rejected for this project in Claude Code.")
    for scope in ["user", "local"] {
        let row = BackendMcpClientConfiguration.parseMap(try mcpParityJSON(#"{"u":{"command":"node"}}"#), scope: scope, source: "s", environment: [:])
        #expect(BackendMcpClientConfiguration.applyProjectGates(row, gates: .object([]))[0]["enabled"].bool == true)
    }
    let gates = BackendMcpClientConfiguration.projectGates(claude: try mcpParityJSON(#"{"projects":{"/work/app":{"enabledMcpjsonServers":["a"],"disabledMcpjsonServers":["b"]}}}"#), settings: try mcpParityJSON(#"{"enableAllProjectMcpServers":true}"#), projectPath: "/work/app/")
    #expect(gates == .object([.init("enabled", .array([.string("a")])), .init("disabled", .array([.string("b")])), .init("enableAll", .bool(true))]))
}
@Test func mcpParityScopeMergeLocalProjectUserPriorityAndNameSorting() throws {
    let groups = try [("user", "user-cmd", "u"), ("project", "project-cmd", "p"), ("local", "local-cmd", "l")].map { scope, command, source in BackendMcpClientConfiguration.parseMap(try mcpParityJSON(#"{"db":{"command":"\#(command)"}}"#), scope: scope, source: source, environment: [:]) }
    let merged = BackendMcpClientConfiguration.mergeByPrecedence(groups)
    #expect(merged.count == 1 && merged[0]["command"].string == "local-cmd" && merged[0]["scope"].string == "local")
    let unordered = BackendMcpClientConfiguration.parseMap(try mcpParityJSON(#"{"zeta":{"command":"z"},"alpha":{"command":"a"}}"#), scope: "user", source: "u", environment: [:])
    #expect(BackendMcpClientConfiguration.mergeByPrecedence([unordered]).map { $0["name"].string! } == ["alpha", "zeta"])
}
@Test func mcpParityDiscoveryMergesOnlyTheOpenProjectsSourcesAndSurvivesMissingJSON() throws {
    let claude = try mcpParityJSON(#"{"mcpServers":{"higgsfield":{"type":"http","url":"https://mcp.example.ai/mcp"}},"projects":{"/work/app":{"mcpServers":{"scratch":{"command":"node","args":["local.js"]}},"enabledMcpjsonServers":["shared"],"disabledMcpjsonServers":[]},"/work/other":{"mcpServers":{"elsewhere":{"command":"node"}}}}}"#)
    func collect(_ config: NativeRPCValue, _ project: String?, _ file: NativeRPCValue) -> [NativeRPCValue] {
        BackendMcpClientConfiguration.collect(claude: config, settings: .object([]), projectJSON: file, projectPath: project, claudePath: "/home/u/.claude.json", projectFile: project.map { $0 + "/.mcp.json" }, environment: [:])
    }
    let rows = collect(claude, "/work/app", try mcpParityJSON(#"{"mcpServers":{"shared":{"command":"uvx","args":["thing"]}}}"#))
    #expect(rows.map { $0["scope"].string! + ":" + $0["name"].string! } == ["user:higgsfield", "local:scratch", "project:shared"])
    #expect(rows.first { $0["name"].string == "shared" }?["enabled"].bool == true)
    #expect(rows.first { $0["name"].string == "shared" }?["source"].string == "/work/app/.mcp.json")
    #expect(!collect(claude, "/work/app", .null).contains { $0["name"].string == "elsewhere" })
    #expect(collect(claude, nil, .null).map { $0["name"].string! } == ["higgsfield"])
    #expect(collect(.null, "/work/app", .null) == [])
}
