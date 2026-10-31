import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private func mcpClientJSON(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }

@Test func backendMcpClientArgvRoundTrips() throws {
    for args in [["npx", "-y", "pkg", "/Users/me/My Folder"], ["serve", "it's", "fine"], ["a", "b\"c", "d\\e"], ["--flag", ""], ["/Users/me/My Tools/serve", "--port", "3000"]] {
        #expect(try BackendMcpClientCommands.tokenize(BackendMcpClientCommands.quoteArgv(args)) == args)
    }
    #expect(try BackendMcpClientCommands.tokenize("serve --flag \"\" /My\\ Folder 'literal\\n'") == ["serve", "--flag", "", "/My Folder", "literal\\n"])
    #expect(throws: NativeRPCError.self) { try BackendMcpClientCommands.tokenize("serve 'unclosed") }
}

@Test func backendMcpClientCLIPositionalsCannotBeEatenByVariadicFlags() throws {
    let request = try BackendMcpClientCommands.validateAdd(mcpClientJSON(#"{"name":"files","scope":"local","projectPath":"/work/app","transport":"stdio","command":"npx -y pkg '/My Folder'","extras":["API_KEY=value"]}"#))
    #expect(try BackendMcpClientCommands.addArguments(request) == ["mcp", "add", "--scope", "local", "files", "-e", "API_KEY=value", "--", "npx", "-y", "pkg", "/My Folder"])
    let http = try BackendMcpClientCommands.validateAdd(mcpClientJSON(#"{"name":"files","scope":"user","transport":"http","url":"https://x/mcp","extras":["A: b"]}"#))
    #expect(try BackendMcpClientCommands.addArguments(http) == ["mcp", "add", "--scope", "user", "--transport", "http", "files", "https://x/mcp", "-H", "A: b"])
}

@Test func backendMcpClientScopeAndNameRefusals() throws {
    let base = try mcpClientJSON(#"{"name":"files","scope":"user","transport":"stdio","command":"npx pkg"}"#)
    for bad in [base.setting("name", .string("--scope")), base.setting("scope", .string("local")), base.setting("transport", .string("grpc")), base.setting("extras", .array([.string("KEY")]))] {
        #expect(throws: NativeRPCError.self) { try BackendMcpClientCommands.validateAdd(bad) }
    }
    #expect(throws: NativeRPCError.self) { try BackendMcpClientCommands.validateRemove(base.setting("name", .string("--scope"))) }
    #expect(throws: NativeRPCError.self) { try BackendMcpClientConfiguration.projectPath(.string("../../etc")) }
}

@Test func backendMcpClientSavedEnvironmentIsKeptOnlyWhenRequested() throws {
    let saved = try mcpClientJSON(#"{"API_KEY":"secret-value","REGION":"eu"}"#)
    #expect(try BackendMcpClientCommands.mergeEnvironment(["API_KEY=", "DSN=postgres://u:p@h/db?x=1"], saved: saved) == ["API_KEY=secret-value", "DSN=postgres://u:p@h/db?x=1"])
    #expect(try BackendMcpClientCommands.mergeEnvironment([], saved: saved) == [])
    #expect(try BackendMcpClientCommands.mergeEnvironment(["API_KEY=new"], saved: saved) == ["API_KEY=new"])
    #expect(throws: NativeRPCError.self) { try BackendMcpClientCommands.mergeEnvironment(["NEW="], saved: saved) }
}

@Test func backendMcpClientDiscoveryExpandsButKeepsMissingRefs() throws {
    let raw = try mcpClientJSON(#"{"command":"${BIN}","args":["${DIR:-/tmp}",3000,false],"env":{"KEY":"${SECRET}","BOOL":true,"NO":null},"cwd":"${DIR:-/tmp}"}"#)
    let server = try #require(BackendMcpClientConfiguration.parse(name: "mine", raw: raw, scope: "user", source: "/cfg/.claude.json", environment: ["BIN": "node", "SECRET": "value"]))
    #expect(server["command"].string == "node")
    #expect(server["args"].elements == [.string("/tmp"), .string("3000")])
    #expect(server["env"]["BOOL"].string == "true" && server["env"]["NO"] == .missing)
    #expect(BackendMcpClientConfiguration.expand("${MISSING}/${EMPTY:-fallback}", environment: ["EMPTY": ""]) == "${MISSING}/fallback")
}

@Test func backendMcpClientConfigPathsMatchClaudeOverrides() {
    let plain = BackendMcpClientConfiguration(home: "/Users/test", environment: [:])
    #expect(plain.claudeJSONPath == "/Users/test/.claude.json" && plain.claudeSettingsDirectory == "/Users/test/.claude")
    let overridden = BackendMcpClientConfiguration(home: "/Users/test", environment: ["CLAUDE_CONFIG_DIR": " /tmp/profile "])
    #expect(overridden.claudeJSONPath == "/tmp/profile/.claude.json" && overridden.claudeSettingsDirectory == "/tmp/profile")
}

@Test func backendMcpClientPrecedenceGatesAndProjectIsolation() throws {
    let claude = try mcpClientJSON(#"{"mcpServers":{"db":{"command":"user"}},"projects":{"/work/app":{"mcpServers":{"db":{"command":"local"}},"disabledMcpjsonServers":["shared"]},"/work/other":{"mcpServers":{"other":{"command":"x"}}}}}"#)
    let project = try mcpClientJSON(#"{"mcpServers":{"db":{"command":"project"},"shared":{"command":"serve"},"pending":{"command":"serve"}}}"#)
    let settings = try mcpClientJSON(#"{"enabledMcpjsonServers":["shared"]}"#)
    let servers = BackendMcpClientConfiguration.collect(claude: claude, settings: settings, projectJSON: project, projectPath: "/work/app/", claudePath: "/cfg/.claude.json", projectFile: "/work/app/.mcp.json", environment: [:])
    #expect(servers.map { $0["name"].string! } == ["db", "pending", "shared"])
    #expect(servers[0]["scope"].string == "local")
    #expect(servers[1]["disabledReason"].string == "Not approved for this project yet.")
    #expect(servers[2]["disabledReason"].string == "Rejected for this project in Claude Code.")
}

@Test func backendMcpClientMalformedDiscoveryKeepsGoodEntriesAndUnsupportedURL() throws {
    let project = try mcpClientJSON(#"{"mcpServers":{"good":{"command":"node"},"broken":42,"remote":{"url":"https://x/mcp"}}}"#)
    let list = BackendMcpClientConfiguration.collect(claude: project, settings: .null, projectJSON: .null, projectPath: nil, claudePath: "/cfg", projectFile: nil, environment: [:])
    #expect(list.count == 2)
    #expect(list.last?["unsupported"].string == "Claude Code dials HTTP servers itself, so this panel cannot inspect it.")
}

@Test func backendMcpClientFileReaderRejectsDirectoriesAndTruncatedJSON() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendMcpClient-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    #expect(BackendMcpClientConfiguration.readJSON(root.path) == .null)
    let file = root.appendingPathComponent("half.json"); try Data("{\"mcpServers\":".utf8).write(to: file)
    #expect(BackendMcpClientConfiguration.readJSON(file.path) == .null)
    try Data(#"{"mcpServers":{}}"#.utf8).write(to: file)
    #expect(BackendMcpClientConfiguration.readJSON(file.path)["mcpServers"] == .object([]))
}

@Test func backendMcpClientShareNamesOnlyAndExactFormat() throws {
    let server = BackendMcpClientConfigured(name: "my-notes", scope: "user", command: "npx -y @me/notes", envKeys: ["API_KEY", "REGION"])
    let text = try BackendMcpClientShare.fileText(server), read = BackendMcpClientShare.read(text)
    #expect(text.hasSuffix("\n") && text.contains("\n  \"terminalDeckTool\": 1,"))
    #expect(read["draft"]["env"].elements == [.string("API_KEY"), .string("REGION")])
    #expect(!text.contains("API_KEY="))
    #expect(BackendMcpClientShare.fileName("a/b:c*d") == "a-b-c-d.mcpserver.json")
    #expect(BackendMcpClientShare.fileName("///") == "mcp-server.mcpserver.json")
    let imported = BackendMcpClientShare.read(#"{"kind":"mcp-server","name":"a","command":"npx a","env":["API_KEY=secret-value",42]}"#)
    #expect(imported["draft"]["env"].elements == [.string("API_KEY")])
    #expect(!imported.compact.contains("secret-value"))
}

@Test func backendMcpClientImportNarrowsFieldsAndLimitsNames() throws {
    #expect(BackendMcpClientShare.read("no JSON")["why"].string == "that file is not JSON this app can read")
    #expect(BackendMcpClientShare.read(#"{"kind":"mcp-server","name":"a","transport":"http"}"#)["why"].string == "that definition has no URL in it")
    let raw = try mcpClientJSON(#"{"kind":"mcp-server","name":"a","command":"npx a","transport":42}"#).setting("env", .array((0..<40).map { .string("KEY\($0)=drop-me") }))
    let read = BackendMcpClientShare.read(raw.compact)
    #expect(read["draft"]["transport"].string == "stdio" && read["draft"]["env"].elements?.count == 32)
}

@Test func backendMcpClientCatalogueIsStaticCompleteAndChromeRowsRetired() throws {
    let entries = BackendMcpClientCatalogue.entries
    #expect(entries.count == 37)
    #expect(Set(entries.compactMap { $0["id"].string }).count == entries.count)
    #expect(Set(entries.compactMap { $0["name"].string }).count == entries.count)
    for entry in entries {
        #expect(BackendMcpClientCommands.validName(entry["name"].string!))
        #expect(entry["command"].string!.contains(entry["token"].string!))
        #expect(entry["homepage"].string!.hasPrefix("https://"))
        #expect(entry["cost"].string == "free" || (entry["costNote"].string?.count ?? 0) > 20)
        for field in entry["inputs"].elements ?? [] where field["into"].string == "arg" { #expect(entry["command"].string!.contains("${" + field["key"].string! + "}")) }
    }
    #expect(BackendMcpClientCatalogue.requiredRuntimes() == ["node", "python", "docker"])
    #expect(BackendMcpClientCatalogue.entry("chrome-devtools") == nil && BackendMcpClientCatalogue.entry("puppeteer") == nil)
    #expect(!BackendMcpClientCatalogue.environmentKeys().contains("ROOT"))
}

@Test func backendMcpClientInstallRejectsUnfilledArgumentsAndSecrets() throws {
    let filesystem = try #require(BackendMcpClientCatalogue.entry("filesystem"))
    let built = try BackendMcpClientStoreRules.buildInstall(filesystem, values: .object([.init("ROOT", .string("/My Folder"))]), available: [])
    #expect(try BackendMcpClientCommands.tokenize(built.command).last == "/My Folder")
    #expect(throws: NativeRPCError.self) { try BackendMcpClientStoreRules.buildInstall(filesystem, values: .object([]), available: ["ROOT"]) }
    let tavily = try #require(BackendMcpClientCatalogue.entry("tavily"))
    #expect(throws: NativeRPCError.self) { try BackendMcpClientStoreRules.buildInstall(tavily, values: .object([]), available: []) }
    #expect(try BackendMcpClientStoreRules.buildInstall(tavily, values: .object([]), available: ["TAVILY_API_KEY"]).inherited == ["TAVILY_API_KEY"])
    #expect(throws: NativeRPCError.self) { try BackendMcpClientStoreRules.buildInstall(tavily, values: .object([.init("TAVILY_API_KEY", .string("a\nb"))]), available: []) }
}

@Test func backendMcpClientCustomRowsRetainControlsWithoutMakingUpMetadata() {
    let mine = BackendMcpClientConfigured(name: "github", scope: "local", command: "docker run my/server", envKeys: ["TOKEN"])
    let row = BackendMcpClientStoreRules.customRow(mine, binaries: [.object([.init("binary", .string("docker")), .init("found", .bool(false)), .init("path", .string(""))])])
    #expect(row["state"].string == "installed" && row["blocked"].string == "")
    #expect(row["runtimeMissing"].bool == true && row["cost"].string == "unknown")
    #expect(row["homepage"].string == "" && row["version"].string == "" && row["logo"].string == "")
    #expect(row["id"].string == "own:local:github" && row["envKeys"].elements == [.string("TOKEN")])
    #expect(BackendMcpClientStoreRules.customRuntime("/usr/bin/python3") == "python")
    #expect(BackendMcpClientStoreRules.customBinary(.init(name: "url", scope: "user", command: "https://x", transport: .http)) == "")
}

@Test func backendMcpClientStoreUsesFingerprintsAndAddsUnclaimedRows() throws {
    let entry = try #require(BackendMcpClientCatalogue.entry("filesystem"))
    let facts = try mcpClientJSON(#"{"runtimes":[{"id":"node","found":true}],"writer":{"found":true},"environmentSource":"login-shell"}"#)
    let configured = [BackendMcpClientConfigured(name: "filesystem", scope: "user", command: "node other.js")]
    let view = BackendMcpClientStoreRules.view(catalogue: [entry], configured: configured, facts: facts, environment: ["ROOT"], project: nil, binaries: [])
    #expect(view["rows"].elements?.count == 2)
    #expect(view["rows"].elements?.first?["state"].string == "taken")
    #expect(view["rows"].elements?.first?["inputs"].elements?.first?["inEnvironment"].bool == false)
    #expect(view["rows"].elements?.last?["custom"].bool == true)
}
