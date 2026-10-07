import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Test func mcpParityArgvRoundTripsEverySourceVariantAndQuotesOnlyNecessaryTokens() throws {
    let cases = [["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"], ["npx", "-y", "pkg", "/Users/me/My Folder"], ["serve", "it's", "fine"], ["a", "b\"c", "d\\e"], ["--flag", ""], ["/Users/me/My Tools/serve", "--port", "3000"]]
    for args in cases { #expect(try BackendMcpClientCommands.tokenize(BackendMcpClientCommands.quoteArgv(args)) == args) }
    #expect(BackendMcpClientCommands.quoteArgv(["npx", "-y", "@me/thing"]) == "npx -y @me/thing")
    #expect(BackendMcpClientCommands.quoteArgv(["npx", "pkg", "/Users/me/My Folder"]) == "npx pkg '/Users/me/My Folder'")
}
@Test func mcpParityTokenizerPreservesEveryREADMECommandForm() throws {
    for (line, expected) in [
        ("npx -y server-filesystem /tmp", ["npx", "-y", "server-filesystem", "/tmp"]),
        ("npx server \"/Users/me/My Folder\"", ["npx", "server", "/Users/me/My Folder"]),
        ("npx server '/Users/me/My Folder'", ["npx", "server", "/Users/me/My Folder"]),
        (#"echo '\n not an escape'"#, ["echo", #"\n not an escape"#]),
        (#"server /Users/me/My\ Folder"#, ["server", "/Users/me/My Folder"]),
        ("server \"say \\\"hi\\\"\"", ["server", "say \"hi\""]),
        ("server --flag \"\"", ["server", "--flag", ""]), ("  npx   \t server  ", ["npx", "server"]), ("   ", [])
    ] { #expect(try BackendMcpClientCommands.tokenize(line) == expected) }
    mcpParityFailure("That command has an unclosed quote.") { _ = try BackendMcpClientCommands.tokenize("npx \"unterminated") }
}
@Test func mcpParityAddArgsScopeSeparatorsAndVariadicOrderingAreExact() throws {
    #expect(try BackendMcpClientCommands.addArguments(mcpParityAdd()) == ["mcp", "add", "--scope", "user", "files", "--", "npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
    let env = mcpParityAdd(.object([.init("extras", .array([.string("API_KEY=abc")]))]))
    let envArgs = try BackendMcpClientCommands.addArguments(env)
    #expect(envArgs == ["mcp", "add", "--scope", "user", "files", "-e", "API_KEY=abc", "--", "npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
    for transport in ["http", "sse"] {
        let request = mcpParityAdd(.object([.init("transport", .string(transport)), .init("command", .string("")), .init("url", .string("https://x/mcp")), .init("extras", .array([.string("Authorization: Bearer t")]))]))
        #expect(try BackendMcpClientCommands.addArguments(request) == ["mcp", "add", "--scope", "user", "--transport", transport, "files", "https://x/mcp", "-H", "Authorization: Bearer t"])
    }
    for scope in ["project", "local"] {
        let request = mcpParityAdd(.object([.init("scope", .string(scope)), .init("projectPath", .string("/work/app"))]))
        #expect(Array(try BackendMcpClientCommands.addArguments(request).prefix(4)) == ["mcp", "add", "--scope", scope])
    }
    let remote = mcpParityAdd(.object([.init("transport", .string("http")), .init("url", .string("https://x/mcp")), .init("extras", .array([]))]))
    #expect(try BackendMcpClientCommands.addArguments(remote) == ["mcp", "add", "--scope", "user", "--transport", "http", "files", "https://x/mcp"])
}
@Test func mcpParityAddValidationUsesExactRefusalsAndNarrowing() throws {
    let nameError = "A name may use letters, numbers, dots, dashes and underscores, and must start with a letter or number."
    for name in ["--scope", "-x"] { mcpParityFailure(nameError) { _ = try BackendMcpClientCommands.validateAdd(mcpParityAdd(.object([.init("name", .string(name))]))) } }
    mcpParityFailure("Give the server a name.") { _ = try BackendMcpClientCommands.validateAdd(mcpParityAdd(.object([.init("name", .string(""))]))) }
    for name in ["files", "my-server", "server_2", "a.b"] { #expect(try BackendMcpClientCommands.validateAdd(mcpParityAdd(.object([.init("name", .string(name))])))["name"].string == name) }
    for scope in ["local", "project"] { mcpParityFailure("Open a project first — only a user-scope server can be added without one.") { _ = try BackendMcpClientCommands.validateAdd(mcpParityAdd(.object([.init("scope", .string(scope))]))) } }
    #expect(try BackendMcpClientCommands.validateAdd(mcpParityAdd(.object([.init("scope", .string("local")), .init("projectPath", .string("/work/app"))])))["scope"].string == "local")
    for (patch, message) in [
        (NativeRPCValue.object([.init("command", .string(""))]), "Give the command that starts the server."),
        (.object([.init("transport", .string("http")), .init("url", .string(""))]), "Give the server’s URL."),
        (.object([.init("scope", .string("global"))]), "Choose where to save the server."),
        (.object([.init("transport", .string("grpc"))]), "Choose how the server is reached."),
        (.object([.init("extras", .array([.string("API_KEY")]))]), "Environment variables are written KEY=value — “API_KEY” is not."),
        (.object([.init("transport", .string("http")), .init("url", .string("https://x")), .init("extras", .array([.string("nope")]))]), "Headers are written Name: value — “nope” is not.")
    ] { mcpParityFailure(message) { _ = try BackendMcpClientCommands.validateAdd(mcpParityAdd(patch)) } }
    #expect(try BackendMcpClientCommands.validateAdd(mcpParityAdd(.object([.init("extras", .array([.string("A=1"), .string("   "), .string("")]))])))["extras"].elements == [.string("A=1")])
    for bad in [NativeRPCValue.null, .missing, .string("add it"), .number(42)] { mcpParityFailure("Nothing to add.") { _ = try BackendMcpClientCommands.validateAdd(bad) } }
}
@Test func mcpParityWriterMessagesValidationAndInheritedEnvironmentStayExact() async throws {
    let fixture = try McpParityFixture(); defer { fixture.dispose() }
    let runs = McpParityRuns(responses: [mcpParityOutcome(stdout: "Added stdio MCP server files to local config"), mcpParityOutcome(false, stderr: "A server named files already exists in user config"), mcpParityOutcome(false, missing: true), mcpParityOutcome()])
    let writer = fixture.writer(runs)
    let invalid = await writer.add(mcpParityAdd(.object([.init("name", .string(""))])))
    let noCalls = await runs.snapshot()
    #expect(invalid["ok"].bool == false && invalid["message"].string == "Give the server a name." && noCalls.isEmpty)
    let local = await writer.add(mcpParityAdd(.object([.init("scope", .string("local")), .init("projectPath", .string("/work/app"))])))
    #expect(local["ok"].bool == true && local["message"].string == "Added stdio MCP server files to local config")
    let first = try #require((await runs.snapshot()).first)
    #expect(first.cwd == "/work/app" && first.args.contains("local") && first.timeout == 30_000)
    let paths = first.env.keys.filter { $0.lowercased() == "path" }
    #expect(paths == ["PATH"] && first.env["PATH"] == "/usr/bin:/bin" && first.env.count > 1)
    let refused = await writer.add(mcpParityAdd())
    #expect(refused["ok"].bool == false && refused["message"].string == "A server named files already exists in user config")
    let missing = await writer.add(mcpParityAdd())
    #expect(missing["ok"].bool == false && missing["message"].string == "Claude Code’s command line tool could not be found, and it is what writes this configuration. Install it, then try again.")
    #expect(await writer.add(mcpParityAdd()) == BackendMcpClientValue.result(true, "Added files."))
}
@Test func mcpParityRemoveScopeAndFailureMessagesRemainSpecific() async throws {
    mcpParityFailure("That is not a server name this app wrote.") { _ = try BackendMcpClientCommands.validateRemove(.object([.init("name", .string("--scope")), .init("scope", .string("user"))])) }
    mcpParityFailure("Open the project this server belongs to first.") { _ = try BackendMcpClientCommands.validateRemove(.object([.init("name", .string("files")), .init("scope", .string("local"))])) }
    let fixture = try McpParityFixture(); defer { fixture.dispose() }
    let runs = McpParityRuns(responses: [mcpParityOutcome(stdout: "Removed MCP server \"files\" from local config"), mcpParityOutcome(false, stderr: "No MCP server found with name: files")]), writer = fixture.writer(runs)
    let removed = await writer.remove(.object([.init("name", .string("files")), .init("scope", .string("local")), .init("projectPath", .string("/work/app"))]))
    #expect(removed["ok"].bool == true && removed["message"].string == "Removed MCP server \"files\" from local config")
    let first = try #require((await runs.snapshot()).first)
    #expect(first.cwd == "/work/app" && first.args == ["mcp", "remove", "--scope", "local", "files"])
    let refused = await writer.remove(.object([.init("name", .string("files")), .init("scope", .string("user"))]))
    #expect(refused["ok"].bool == false && refused["message"].string == "No MCP server found with name: files")
    #expect((await runs.snapshot())[1].args == ["mcp", "remove", "--scope", "user", "files"])
}

private func parityEditNext(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue {
    mcpParityAdd(.object([.init("name", .string("mine")), .init("command", .string("npx -y @me/thing --verbose")), .init("extras", .array([.string("API_KEY="), .string("REGION=")]))])).merging(patch)
}
private func parityEditRequest(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue { NativeRPCValue.object([.init("name", .string("mine")), .init("scope", .string("user")), .init("next", parityEditNext())]).merging(patch) }
private func parityEditFixture() throws -> McpParityFixture { try McpParityFixture(claude: mcpParityJSON(#"{"mcpServers":{"mine":{"command":"npx","args":["-y","@me/thing"],"env":{"API_KEY":"secret-value","REGION":"eu"}}}}"#)) }

@Test func mcpParityEnvironmentMergeKeepsReplacesDropsAndRefusesExactly() throws {
    let saved = try mcpParityJSON(#"{"API_KEY":"secret-value","REGION":"eu"}"#)
    #expect(try BackendMcpClientCommands.mergeEnvironment(["API_KEY=", "REGION="], saved: saved) == ["API_KEY=secret-value", "REGION=eu"])
    #expect(try BackendMcpClientCommands.mergeEnvironment(["API_KEY=new"], saved: saved) == ["API_KEY=new"])
    #expect(try BackendMcpClientCommands.mergeEnvironment(["DSN=postgres://u:p@h/db?x=1"], saved: .object([])) == ["DSN=postgres://u:p@h/db?x=1"])
    #expect(try BackendMcpClientCommands.mergeEnvironment(["API_KEY="], saved: saved) == ["API_KEY=secret-value"])
    #expect(try BackendMcpClientCommands.mergeEnvironment([], saved: saved) == [])
    mcpParityFailure("NEW_KEY has no saved value to keep. Give it one, or delete the line to drop the variable.") { _ = try BackendMcpClientCommands.mergeEnvironment(["NEW_KEY="], saved: saved) }
}
@Test func mcpParityEditValidationAndMergeFailBeforeAnyWrite() async throws {
    let fixture = try parityEditFixture(); defer { fixture.dispose() }
    let runs = McpParityRuns(), writer = fixture.writer(runs)
    for (request, message) in [
        (parityEditRequest(.object([.init("next", parityEditNext(.object([.init("name", .string("--scope"))])))])), "A name may use letters, numbers, dots, dashes and underscores, and must start with a letter or number."),
        (parityEditRequest(.object([.init("next", parityEditNext(.object([.init("command", .string(""))])))])), "Give the command that starts the server."),
        (parityEditRequest(.object([.init("name", .string(""))])), "Name the server to change."),
        (parityEditRequest(.object([.init("scope", .string("nowhere"))])), "Say which scope the server is in."),
        (parityEditRequest(.object([.init("scope", .string("local"))])), "Open the project this server belongs to first."),
        (parityEditRequest(.object([.init("next", parityEditNext(.object([.init("extras", .array([.string("MISSING=")]))])))])), "MISSING has no saved value to keep. Give it one, or delete the line to drop the variable.")
    ] {
        let result = await writer.edit(request)
        #expect(result["ok"].bool == false && result["message"].string == message)
        #expect((await runs.snapshot()).isEmpty)
    }
}
@Test func mcpParityEditWritesInOrderKeepsValuesAndNamesTheRename() async throws {
    let fixture = try parityEditFixture(); defer { fixture.dispose() }
    let ordinaryRuns = McpParityRuns()
    let ordinary = await fixture.writer(ordinaryRuns).edit(parityEditRequest()), ordinaryCalls = await ordinaryRuns.snapshot()
    #expect(ordinary["ok"].bool == true && ordinary["message"].string == "mine was changed.")
    #expect(ordinaryCalls.map { $0.args[1] } == ["remove", "add"])
    #expect(ordinaryCalls[1].args == ["mcp", "add", "--scope", "user", "mine", "-e", "API_KEY=secret-value", "-e", "REGION=eu", "--", "npx", "-y", "@me/thing", "--verbose"])
    let runs = McpParityRuns(), writer = fixture.writer(runs)
    let result = await writer.edit(parityEditRequest(.object([.init("next", parityEditNext(.object([.init("name", .string("renamed"))])))])))
    let calls = await runs.snapshot()
    #expect(calls.map { $0.args[1] } == ["remove", "add"])
    #expect(calls[0].args == ["mcp", "remove", "--scope", "user", "mine"])
    #expect(calls[1].args == ["mcp", "add", "--scope", "user", "renamed", "-e", "API_KEY=secret-value", "-e", "REGION=eu", "--", "npx", "-y", "@me/thing", "--verbose"])
    #expect(result["ok"].bool == true && result["message"].string == "renamed was changed. It was called mine and is now renamed.")
}
@Test func mcpParityEditRemoveFailureAndMissingOriginalDoNotWriteReplacement() async throws {
    let fixture = try parityEditFixture(); defer { fixture.dispose() }
    let runs = McpParityRuns(responses: [mcpParityOutcome(false, stderr: "claude is not on this machine.")]), writer = fixture.writer(runs)
    let result = await writer.edit(parityEditRequest())
    #expect(result["ok"].bool == false && result["message"].string == "mine was not changed. claude is not on this machine.")
    #expect((await runs.snapshot()).map { $0.args[1] } == ["remove"])
    let none = try McpParityFixture(); defer { none.dispose() }; let noRuns = McpParityRuns()
    let vanished = await none.writer(noRuns).edit(parityEditRequest())
    #expect(vanished["ok"].bool == false && vanished["message"].string == "mine is not in your configuration any more. Nothing was changed.")
    #expect((await noRuns.snapshot()).isEmpty)
}
@Test func mcpParityEditRollbackRestoresExactOriginalArgvAndReportsBothOutcomes() async throws {
    let fixture = try parityEditFixture(); defer { fixture.dispose() }
    for restored in [true, false] {
        let runs = McpParityRuns(responses: [mcpParityOutcome(), mcpParityOutcome(false, stderr: "A server called mine already exists."), mcpParityOutcome(restored, stderr: restored ? "" : "It would not write.")])
        let result = await fixture.writer(runs).edit(parityEditRequest()), calls = await runs.snapshot()
        #expect(calls.map { $0.args[1] } == ["remove", "add", "add"])
        #expect(calls[2].args == ["mcp", "add", "--scope", "user", "mine", "-e", "API_KEY=secret-value", "-e", "REGION=eu", "--", "npx", "-y", "@me/thing"])
        #expect(result["ok"].bool == false)
        #expect(result["message"].string == (restored ? "mine was not saved. A server called mine already exists. mine has been put back exactly as it was." : "mine was not saved. A server called mine already exists. Putting mine back also failed — It would not write. — so it is not in your configuration right now."))
    }
}

@Test func mcpParityShareDefinitionTransportFilenameAndRoundTripAreExact() throws {
    let server = BackendMcpClientConfigured(name: "my-notes", scope: "user", command: "npx -y @me/notes /Users/me/Notes", envKeys: ["API_KEY", "REGION"])
    let text = try BackendMcpClientShare.fileText(server), parsed = try mcpParityJSON(text), read = BackendMcpClientShare.read(text)
    #expect(parsed["terminalDeckTool"].number == 1 && parsed["kind"].string == "mcp-server" && parsed["name"].string == "my-notes")
    #expect(parsed["transport"].string == "stdio" && parsed["command"].string == server.command && parsed["url"].string == "")
    #expect(parsed["env"].elements == [.string("API_KEY"), .string("REGION")])
    #expect(text.contains("\"API_KEY\"") && !text.contains("API_KEY=") && !text.contains("API_KEY:") && text.contains("It holds no secrets"))
    #expect(read == .object([.init("ok", .bool(true)), .init("draft", .object([.init("name", .string("my-notes")), .init("transport", .string("stdio")), .init("command", .string(server.command)), .init("url", .string("")), .init("env", .array([.string("API_KEY"), .string("REGION")]))]))]))
    let remote = try mcpParityJSON(BackendMcpClientShare.fileText(.init(name: "my-notes", scope: "user", command: "https://example.com/mcp", transport: .http)))
    #expect(remote["command"].string == "" && remote["url"].string == "https://example.com/mcp")
    for (name, filename) in [("my-notes", "my-notes.mcpserver.json"), ("a/b:c*d", "a-b-c-d.mcpserver.json"), ("///", "mcp-server.mcpserver.json")] { #expect(BackendMcpClientShare.fileName(name) == filename) }
}
@Test func mcpParityShareParserNamesWrongFieldAndDropsForeignSecretValues() {
    for (text, why) in [
        ("not json", "that file is not JSON this app can read"),
        (#"{"kind":"something-else"}"#, "that file is not an MCP server definition"),
        (#"{"kind":"mcp-server"}"#, "that definition has no name in it"),
        (#"{"kind":"mcp-server","name":"a"}"#, "that definition has no command in it"),
        (#"{"kind":"mcp-server","name":"a","transport":"http"}"#, "that definition has no URL in it")
    ] { #expect(BackendMcpClientShare.read(text) == .object([.init("ok", .bool(false)), .init("why", .string(why))])) }
    let read = BackendMcpClientShare.read(#"{"kind":"mcp-server","name":"a","command":"npx a","env":["API_KEY=hunter2"]}"#)
    #expect(read["ok"].bool == true && read["draft"]["env"].elements == [.string("API_KEY")] && !read.compact.contains("hunter2"))
    let narrowed = BackendMcpClientShare.read(#"{"kind":"mcp-server","name":"a","command":"npx a","transport":42,"env":"nope"}"#)
    #expect(narrowed["ok"].bool == true && narrowed["draft"]["transport"].string == "stdio" && narrowed["draft"]["env"].elements == [])
}
