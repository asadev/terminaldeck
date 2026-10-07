import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct McpClientRecordedRun: Sendable { let command: String; let arguments: [String]; let environment: [String: String]; let cwd: String; let timeout: Int }
private actor McpClientRunRecorder {
    var calls: [McpClientRecordedRun] = []
    var answers: [BackendGitOutcome]
    init(_ answers: [BackendGitOutcome] = []) { self.answers = answers }
    func run(_ command: String, _ args: [String], _ env: [String: String], _ cwd: String, _ timeout: Int) -> BackendGitOutcome {
        calls.append(.init(command: command, arguments: args, environment: env, cwd: cwd, timeout: timeout))
        return answers.isEmpty ? mcpClientOutcome(true) : answers.removeFirst()
    }
    func snapshot() -> [McpClientRecordedRun] { calls }
}
private func mcpClientOutcome(_ ok: Bool, stdout: String = "", stderr: String = "", missing: Bool = false) -> BackendGitOutcome {
    .init(ok: ok, stdout: stdout, stderr: stderr, missing: missing, exitCode: ok ? 0 : 1, timedOut: false)
}
private func mcpWriterRequest() -> NativeRPCValue {
    .object([.init("name", .string("mine")), .init("scope", .string("user")), .init("transport", .string("stdio")), .init("command", .string("npx -y new-package")), .init("extras", .array([.string("API_KEY="), .string("REGION=")]))])
}
private func mcpWriterFixture(_ recorder: McpClientRunRecorder, root: URL) -> BackendMcpClientWriter {
    .init(configuration: .init(home: root.path, environment: ["HOME": root.path, "PATH": "/old"]), loginPath: { "/usr/bin:/bin" }, run: { command, args, env, cwd, timeout in await recorder.run(command, args, env, cwd, timeout) })
}
private func mcpWriterRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendMcpClient-writer-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(#"{"untouched":{"state":"keep"},"mcpServers":{"mine":{"command":"npx","args":["-y","original-package"],"env":{"API_KEY":"secret-value","REGION":"eu"}}}}"#.utf8).write(to: root.appendingPathComponent(".claude.json"))
    return root
}

@Test func backendMcpClientProductionAdapterResolvesAbsoluteExecutablesBeforeRun() throws {
    let plan = try #require(BackendMcpClientWriter.executionPlan(command: "echo", arguments: ["literal"], environment: ["PATH": "/bin:/usr/bin"], cwd: "/tmp"))
    #expect(plan.command.hasPrefix("/") && plan.command.hasSuffix("/echo"))
    #expect(plan.arguments == ["literal"] && plan.environment["PATH"] == "/bin:/usr/bin" && plan.cwd == "/tmp")
    #expect(BackendMcpClientWriter.executionPlan(command: "BackendMcpClient-no-such-command", arguments: [], environment: ["PATH": "/bin:/usr/bin"], cwd: "/tmp") == nil)
}

@Test func backendMcpClientWriterUsesOwnerCLIAndExplicitCwd() async throws {
    let recorder = McpClientRunRecorder([mcpClientOutcome(true, stdout: "Added to local config\n")]), root = try mcpWriterRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = mcpWriterFixture(recorder, root: root)
    let result = await writer.add(mcpWriterRequest().setting("scope", .string("local")).setting("projectPath", .string("/work/app")).setting("extras", .array([.string("API_KEY=typed")])))
    #expect(result["ok"].bool == true && result["message"].string == "Added to local config")
    let calls = await recorder.snapshot(), call = try #require(calls.first)
    #expect(call.command == "claude" && call.cwd == "/work/app" && call.timeout == 30_000)
    #expect(call.environment["PATH"] == "/usr/bin:/bin" && call.environment["HOME"] == root.path)
    #expect(call.arguments == ["mcp", "add", "--scope", "local", "mine", "-e", "API_KEY=typed", "--", "npx", "-y", "new-package"])
}

@Test func backendMcpClientWriterReportsActualCLIFailureAndMissingBinary() async throws {
    let recorder = McpClientRunRecorder([mcpClientOutcome(false, stderr: "A server named mine already exists"), mcpClientOutcome(false, missing: true)]), root = try mcpWriterRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = mcpWriterFixture(recorder, root: root)
    let refusal = await writer.add(mcpWriterRequest()), missing = await writer.remove(.object([.init("name", .string("mine")), .init("scope", .string("user"))]))
    #expect(refusal["ok"].bool == false && refusal["message"].string == "A server named mine already exists")
    #expect(missing["message"].string?.contains("command line tool could not be found") == true)
}

@Test func backendMcpClientEditRollsBackAfterAddFailsAndDoesNotRewriteConfigItself() async throws {
    let root = try mcpWriterRoot(), file = root.appendingPathComponent(".claude.json"), before = try Data(contentsOf: root.appendingPathComponent(".claude.json"))
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = McpClientRunRecorder([mcpClientOutcome(true), mcpClientOutcome(false, stderr: "Rejected replacement"), mcpClientOutcome(true)])
    let writer = mcpWriterFixture(recorder, root: root)
    let result = await writer.edit(.object([.init("name", .string("mine")), .init("scope", .string("user")), .init("next", mcpWriterRequest())]))
    let calls = await recorder.snapshot()
    #expect(calls.count == 3 && calls.map { $0.arguments[1] } == ["remove", "add", "add"])
    #expect(calls[1].arguments.contains("API_KEY=secret-value") && calls[2].arguments.contains("original-package"))
    #expect(result["message"].string?.contains("has been put back exactly as it was") == true && !result.compact.contains("secret-value"))
    #expect(try Data(contentsOf: file) == before)
}

@Test func backendMcpClientEditNamesFailedRollbackAndPrevalidatesBeforeRemoval() async throws {
    let root = try mcpWriterRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = McpClientRunRecorder([mcpClientOutcome(true), mcpClientOutcome(false, stderr: "New write failed"), mcpClientOutcome(false, stderr: "Restore failed")]), writer = mcpWriterFixture(recorder, root: root)
    let base = NativeRPCValue.object([.init("name", .string("mine")), .init("scope", .string("user")), .init("next", mcpWriterRequest())])
    let invalid = await writer.edit(base.setting("next", mcpWriterRequest().setting("command", .string("npx 'unclosed"))))
    let invalidSnapshot = await recorder.snapshot()
    #expect(invalid["ok"].bool == false && invalidSnapshot.isEmpty)
    let absent = await writer.edit(base.setting("next", mcpWriterRequest().setting("extras", .array([.string("MISSING=")]))))
    let absentSnapshot = await recorder.snapshot()
    #expect(absent["message"].string?.contains("no saved value") == true && absentSnapshot.isEmpty)
    let failed = await writer.edit(base)
    #expect(failed["message"].string?.contains("is not in your configuration right now") == true)
}

@Test func backendMcpClientStoreReprobesRuntimeAndRefusesBeforeAnyWrite() async throws {
    let root = try mcpWriterRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = McpClientRunRecorder([mcpClientOutcome(false)]), store = BackendMcpClientStore(writer: mcpWriterFixture(recorder, root: root))
    let result = await store.install(.object([.init("id", .string("github")), .init("values", .object([.init("GITHUB_PERSONAL_ACCESS_TOKEN", .string("typed"))]))]))
    #expect(result["ok"].bool == false && result["message"].string?.contains("docker is not on this machine") == true)
    let calls = await recorder.snapshot()
    #expect(calls.count == 1 && calls[0].command == "which" && calls[0].arguments == ["docker"] && calls[0].timeout == 5_000)
}

@Test func backendMcpClientEnvironmentProbeReturnsNamesOnlyAndNoClaimOnFailure() async throws {
    let root = try mcpWriterRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = McpClientRunRecorder([mcpClientOutcome(true, stdout: "HOME\nTAVILY_API_KEY\nSECRET_OF_THEIRS\ninvalid=secret-value\n"), mcpClientOutcome(false)]), store = BackendMcpClientStore(writer: mcpWriterFixture(recorder, root: root))
    let (names, source) = await store.environmentNames(), (none, failed) = await store.environmentNames()
    #expect(names == ["TAVILY_API_KEY"] && source == "login-shell")
    #expect(none.isEmpty && failed == "unavailable")
    let calls = await recorder.snapshot()
    #expect(calls[0].arguments == ["-lic", #"printenv | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'"#])
    #expect(calls[0].timeout == 10_000)
}

@Test func backendMcpClientMissingFileDialogsReturnExplicitUnavailable() async throws {
    let root = try mcpWriterRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = McpClientRunRecorder(), service = BackendMcpClientService(writer: mcpWriterFixture(recorder, root: root))
    let save = try await service.export(name: .string("mine"), scope: .string("user")), open = try await service.importFile()
    #expect(save["ok"].bool == false && save["message"].string == "This build cannot save a file.")
    #expect(open["ok"].bool == false && open["message"].string == "This build cannot open a file.")
    #expect((await recorder.snapshot()).isEmpty)
}
