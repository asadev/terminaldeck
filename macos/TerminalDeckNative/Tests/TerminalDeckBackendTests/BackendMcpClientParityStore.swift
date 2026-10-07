import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private func parityStoreCatalogue() throws -> [NativeRPCValue] {
    let plain = try mcpParityJSON(#"{"id":"plain","name":"plain","summary":"Does a thing.","homepage":"https://example.com/plain","category":"utility","tags":["plain"],"licence":"MIT","version":"1.0.0","registry":"https://www.npmjs.com/package/plain","runtime":"node","command":"npx -y plain-server","token":"plain-server","inputs":[],"origin":"third-party","cost":"free","costNote":"","caveat":null}"#)
    let path = try mcpParityJSON(#"{"key":"ROOT","label":"Directory","hint":"Absolute.","kind":"path","into":"arg","required":true}"#)
    let token = try mcpParityJSON(#"{"key":"API_TOKEN","label":"API token","hint":"From them.","kind":"secret","into":"env","required":true}"#)
    return [plain,
        plain.merging(try mcpParityJSON(#"{"id":"rooted","name":"rooted","command":"npx -y rooted-server ${ROOT}","token":"rooted-server"}"#)).setting("inputs", .array([path])),
        plain.merging(try mcpParityJSON(#"{"id":"guarded","name":"guarded","command":"npx -y guarded-server","token":"guarded-server"}"#)).setting("inputs", .array([token])),
        plain.merging(try mcpParityJSON(#"{"id":"boxed","name":"boxed","runtime":"docker","command":"docker run -i --rm boxed/server","token":"boxed/server"}"#))]
}
private func parityStoreFacts(writer: Bool = true) throws -> NativeRPCValue {
    try mcpParityJSON(#"{"runtimes":[{"id":"node","binary":"npx","found":true,"path":"/usr/bin/npx","needs":"Node.js"},{"id":"docker","binary":"docker","found":false,"path":"","needs":"Docker"}],"writer":{"found":\#(writer ? "true" : "false"),"path":"\#(writer ? "/usr/local/bin/claude" : "")"},"environmentSource":"login-shell"}"#)
}
private func parityStoreRows(configured: [BackendMcpClientConfigured] = [], environment: Set<String> = [], writer: Bool = true) throws -> [NativeRPCValue] {
    BackendMcpClientStoreRules.view(catalogue: try parityStoreCatalogue(), configured: configured, facts: try parityStoreFacts(writer: writer), environment: environment, project: nil, binaries: [])["rows"].elements!
}
@Test func mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource() throws {
    let rows = try parityStoreRows(), plain = rows[0], docker = rows[3]
    #expect(plain["state"].string == "available" && plain["blocked"].string == "")
    #expect(docker["state"].string == "unavailable" && docker["blocked"].string == "docker is not on this machine. It needs Docker, and it has to be running, not only installed.")
    let installed = try parityStoreRows(configured: [.init(name: "plain", scope: "user", command: "npx -y plain-server")])[0]
    #expect(installed["state"].string == "installed" && installed["scope"].string == "user")
    let rooted = try parityStoreRows(configured: [.init(name: "rooted", scope: "user", command: "npx -y rooted-server /Users/me/code")])[1]
    #expect(rooted["command"].string == "npx -y rooted-server /Users/me/code")
    #expect(rows[1]["command"].string == "npx -y rooted-server ${ROOT}")
    let taken = try parityStoreRows(configured: [.init(name: "plain", scope: "local", command: "node /home/me/my-own-server.js")])[0]
    #expect(taken["state"].string == "taken" && taken["taken"].string == "node /home/me/my-own-server.js")
    #expect(taken["blocked"].string == "A server called plain is already configured and it is not this one. Remove it, or add this under another name from “Add your own”.")
    let noWriter = try parityStoreRows(writer: false)[0]
    #expect(noWriter["state"].string == "available" && noWriter["blocked"].string == "Claude Code’s command line tool is what writes this configuration, and it was not found on this machine.")
    #expect(rows[2]["inputs"].elements![0]["inEnvironment"].bool == false)
    let inherited = try parityStoreRows(environment: ["API_TOKEN", "ROOT"])
    #expect(inherited[2]["inputs"].elements![0]["inEnvironment"].bool == true)
    #expect(inherited[1]["inputs"].elements![0]["inEnvironment"].bool == false)
}
@Test func mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput() throws {
    let catalogue = try parityStoreCatalogue(), rooted = catalogue[1], guarded = catalogue[2]
    let path = try BackendMcpClientStoreRules.buildInstall(rooted, values: .object([.init("ROOT", .string("/Users/me/My Folder"))]), available: [])
    #expect(path.command == "npx -y rooted-server \"/Users/me/My Folder\"" && path.extras == [])
    for value in [NativeRPCValue.object([]), .object([.init("ROOT", .string("  "))])] {
        mcpParityFailure("rooted needs directory.") { _ = try BackendMcpClientStoreRules.buildInstall(rooted, values: value, available: []) }
    }
    mcpParityFailure("Directory cannot contain a double quote.") { _ = try BackendMcpClientStoreRules.buildInstall(rooted, values: .object([.init("ROOT", .string("/a/\"b"))]), available: []) }
    let typed = try BackendMcpClientStoreRules.buildInstall(guarded, values: .object([.init("API_TOKEN", .string("sk-live-1"))]), available: [])
    #expect(typed.extras == ["API_TOKEN=sk-live-1"] && typed.inherited == [])
    let inherited = try BackendMcpClientStoreRules.buildInstall(guarded, values: .object([]), available: ["API_TOKEN"])
    #expect(inherited.extras == [] && inherited.inherited == ["API_TOKEN"])
    let preferred = try BackendMcpClientStoreRules.buildInstall(guarded, values: .object([.init("API_TOKEN", .string("typed"))]), available: ["API_TOKEN"])
    #expect(preferred.extras == ["API_TOKEN=typed"] && preferred.inherited == [])
    mcpParityFailure("guarded needs api token.") { _ = try BackendMcpClientStoreRules.buildInstall(guarded, values: .object([]), available: []) }
    mcpParityFailure("API token cannot contain a line break.") { _ = try BackendMcpClientStoreRules.buildInstall(guarded, values: .object([.init("API_TOKEN", .string("a\nb"))]), available: []) }
}
@Test func mcpParityResolveInstallNarrowsValuesScopeAndEmptyRequests() throws {
    let resolved = try BackendMcpClientStoreRules.resolveInstall(mcpParityJSON(#"{"id":"plain","scope":"user","values":{"A":" x ","B":7}}"#))
    #expect(resolved["values"] == .object([.init("A", .string("x"))]))
    #expect(try BackendMcpClientStoreRules.resolveInstall(mcpParityJSON(#"{"id":"plain","scope":"nonsense"}"#))["scope"].string == "user")
    for value in [NativeRPCValue.null, .object([])] { mcpParityFailure("Nothing to install.") { _ = try BackendMcpClientStoreRules.resolveInstall(value) } }
}
@Test func mcpParityCatalogueInstallationWritesExactRequestAndReprobesRuntime() async throws {
    let fixture = try McpParityFixture(); defer { fixture.dispose() }
    let runs = McpParityRuns(), store = BackendMcpClientStore(writer: fixture.writer(runs))
    let written = await store.install(try mcpParityJSON(#"{"id":"filesystem","scope":"user","values":{"ROOT":"/Users/me/code"}}"#))
    #expect(written["ok"].bool == true && written["message"].string == "Added filesystem.")
    let calls = await runs.snapshot(), add = try #require(calls.first { $0.command == "claude" })
    #expect(add.args == ["mcp", "add", "--scope", "user", "filesystem", "--", "npx", "-y", "@modelcontextprotocol/server-filesystem", "/Users/me/code"])
    #expect(calls.first?.command == "which" && calls.first?.args == ["npx"] && calls.first?.timeout == 5_000)
    let absent = McpParityRuns(found: ["npx", "claude"]), missingStore = BackendMcpClientStore(writer: fixture.writer(absent))
    let missing = await missingStore.install(try mcpParityJSON(#"{"id":"github","scope":"user","values":{"GITHUB_PERSONAL_ACCESS_TOKEN":"ghp_x"}}"#))
    #expect(missing["ok"].bool == false && missing["message"].string == "docker is not on this machine, so this server could not start. It needs Docker, and it has to be running, not only installed.")
    #expect((await absent.snapshot()).allSatisfy { $0.command != "claude" })
}
@Test func mcpParityInstallConflictsRequiredTokensAndUnknownRowsNeverWrite() async throws {
    let fixture = try McpParityFixture(claude: mcpParityJSON(#"{"mcpServers":{"memory":{"command":"node","args":["/home/me/memory.js"]}}}"#)); defer { fixture.dispose() }
    let runs = McpParityRuns(), store = BackendMcpClientStore(writer: fixture.writer(runs))
    let conflict = await store.install(try mcpParityJSON(#"{"id":"memory","scope":"user","values":{}}"#))
    #expect(conflict["ok"].bool == false && conflict["message"].string == "A server called memory is already configured and it is not this one. Nothing was changed.")
    #expect((await runs.snapshot()).isEmpty)
    let missing = await store.install(try mcpParityJSON(#"{"id":"tavily","scope":"user","values":{}}"#))
    #expect(missing["ok"].bool == false && missing["message"].string == "tavily needs api key.")
    #expect((await runs.snapshot()).allSatisfy { $0.command != "claude" })
    let unknown = await store.install(try mcpParityJSON(#"{"id":"not-a-row"}"#))
    #expect(unknown == BackendMcpClientValue.result(false, "This build has no such server."))
}
@Test func mcpParityInstallMessagesSayExactlyWhereTokensWereKept() async throws {
    let fixture = try McpParityFixture(); defer { fixture.dispose() }
    let writtenRuns = McpParityRuns(), writtenStore = BackendMcpClientStore(writer: fixture.writer(writtenRuns))
    let written = await writtenStore.install(try mcpParityJSON(#"{"id":"tavily","scope":"user","values":{"TAVILY_API_KEY":"tvly-1"}}"#))
    #expect(written["ok"].bool == true && written["message"].string == "Added tavily. TAVILY_API_KEY was written into your user configuration in plain text.")
    #expect((await writtenRuns.snapshot()).first { $0.command == "claude" }?.args.contains("TAVILY_API_KEY=tvly-1") == true)
    let inheritedRuns = McpParityRuns(names: ["PATH", "TAVILY_API_KEY"]), inheritedStore = BackendMcpClientStore(writer: fixture.writer(inheritedRuns))
    let inherited = await inheritedStore.install(try mcpParityJSON(#"{"id":"tavily","scope":"user","values":{}}"#))
    #expect(inherited["ok"].bool == true && inherited["message"].string == "Added tavily. TAVILY_API_KEY was left to your login shell, so nothing was written down for it.")
    #expect((await inheritedRuns.snapshot()).first { $0.command == "claude" }?.args == ["mcp", "add", "--scope", "user", "tavily", "--", "npx", "-y", "tavily-mcp"])
}
@Test func mcpParityFactsRefreshAndEnvironmentNamesUseFakesOnly() async throws {
    let fixture = try McpParityFixture(); defer { fixture.dispose() }
    let runs = McpParityRuns(names: ["HOME", "WANTED", "SECRET_OF_THEIRS"]), store = BackendMcpClientStore(writer: fixture.writer(runs))
    let (facts, _) = await store.facts()
    #expect(facts["runtimes"].elements!.compactMap { $0["id"].string } == ["node", "python", "docker"])
    #expect(facts["writer"]["found"].bool == true)
    #expect((await runs.snapshot()).filter { $0.command != "which" }.count == 1)
    _ = await store.facts()
    #expect((await runs.snapshot()).filter { $0.command != "which" }.count == 2)
    let (names, source) = await store.environmentNames(keys: ["WANTED"])
    #expect(names == ["WANTED"] && source == "login-shell")
    let failedRuns = McpParityRuns(failShell: true), failedStore = BackendMcpClientStore(writer: fixture.writer(failedRuns))
    let (unknown, unavailable) = await failedStore.environmentNames(keys: ["A"])
    #expect(unknown.isEmpty && unavailable == "unavailable")
}
