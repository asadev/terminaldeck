import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsRootPortProjectTests: XCTestCase {
    static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    actor Runtime: BackendDeckToolsFilesRuntime {
        let known: Set<String>
        var tiers: [BackendMCPTier] = []
        init(_ known: Set<String>) { self.known = known }
        func rpc(_ caller: BackendMCPCallContext) async throws -> NativeRPCContext { .init(caller: .nativeApp, ownerID: "fixture") }
        func knownFolder(_ path: String, caller: BackendMCPCallContext) async throws -> String { guard known.contains(path) else { throw NativeRPCError(code: "not-permitted", message: "\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }; return path }
        func requireSession(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("unused fixture session") }
        func startedByCopilot(_ id: String, caller: BackendMCPCallContext) async throws -> Bool { false }
        func boundary(_ id: String) async throws -> BackendDeviceBoundary? { nil }
        func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue) async throws { tiers.append(tier) }
        func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws {}
        func lastTier() -> BackendMCPTier? { tiers.last }
    }
    actor Git: BackendGitExecuting {
        var repos: Set<String>, initialized: [String] = []
        init(repos: Set<String>) { self.repos = repos }
        func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
            if arguments.first == "init" { repos.insert(cwd); initialized.append(cwd); return .init(ok: true, stdout: "", stderr: "", missing: false, exitCode: 0, timedOut: false) }
            if arguments.first == "rev-parse" && !repos.contains(cwd) { return .init(ok: false, stdout: "", stderr: "fatal: not a git repository", missing: false, exitCode: 128, timedOut: false) }
            return .init(ok: true, stdout: arguments.first == "rev-parse" ? cwd + "\n" : arguments.first == "status" ? "# branch.head main\0" : "", stderr: "", missing: false, exitCode: 0, timedOut: false)
        }
        func initCalls() -> [String] { initialized }
    }
    actor Dev: BackendDeckToolsProjectDevAccess {
        let folder: String
        var starts: [String] = []
        init(_ folder: String) { self.folder = folder }
        func list(context: NativeRPCContext) async throws -> [NativeRPCValue] { [BackendDeckToolsRootPortProjectTests.o([("folder", .string(folder)), ("status", .string("idle"))])] }
        func start(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue { starts.append(folder); return BackendDeckToolsRootPortProjectTests.o([("folder", .string(folder)), ("status", .string("starting"))]) }
        func ports(force: Bool, context: NativeRPCContext) async throws -> NativeRPCValue { .array([BackendDeckToolsRootPortProjectTests.o([("port", .number(5173)), ("process", .string("node"))])]) }
        func calls() -> [String] { starts }
    }
    struct NoSessionProcess: BackendDevSessionAccess {
        func openShell(folder: String, context: NativeRPCContext) async throws -> String { throw BackendDeckToolsSupport.unavailable("a real process is forbidden in this test") }
        func type(sessionID: String, text: String, context: NativeRPCContext) async throws { throw BackendDeckToolsSupport.unavailable("a real process is forbidden in this test") }
        func output(sessionID: String, context: NativeRPCContext) async throws -> String { throw BackendDeckToolsSupport.unavailable("a real process is forbidden in this test") }
        func alive(sessionID: String) async -> Bool { false }
    }
    struct NoTranscripts: BackendArtifactsTranscriptSource {
        func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile] { [] }
        func authorizedPath(_ file: NativeTranscriptFile, project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> String { throw BackendDeckToolsSupport.unavailable("unused transcript") }
    }
    struct Rig {
        let root: URL, api: URL, web: URL, state: URL, store: NativeStateStore, runtime: Runtime, git: Git, dev: Dev
        let definitions: [BackendDeckToolsDefinition]
        func call(_ id: String, _ args: NativeRPCValue) async throws -> BackendMCPToolReply {
            let definition = definitions.first { $0.spec.id == id }!
            let context = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true, allowedTools: Set(definitions.map { $0.spec.id }), allowedTiers: [.read, .act, .alter], cancellation: .init())
            return await BackendDeckToolsSupport.reply { try BackendDeckCoreCatalogueSchema.check(tool: definition.spec, arguments: args); return try await definition.handler(context, args) }
        }
        func dispose() { try? FileManager.default.removeItem(at: root) }
    }
    private func rig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsRootPortProject-" + UUID().uuidString).resolvingSymlinksInPath()
        let api = root.appendingPathComponent("api"), web = root.appendingPathComponent("web"), state = root.appendingPathComponent("state")
        for folder in [api, web, state, root.appendingPathComponent(".config"), api.appendingPathComponent(".git")] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "notes".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let store = NativeStateStore(clock: { 1000 }); _ = try await store.addProject(api.path); _ = try await store.addProject(web.path)
        let sessionValue = Self.o([("id", .string("s1")), ("cwd", .string(api.path)), ("title", .string("api")), ("provider", .string("shell")), ("exitCode", .null), ("createdAt", .number(1000)), ("resumed", .bool(false))])
        let session = try JSONDecoder().decode(BackendSessionMeta.self, from: sessionValue.encodedJSON())
        let authority = BackendFilesystemAuthority { _ in .init(readRoots: [root], writeRoots: [root]) }, files = BackendFilesystemService(authority: authority)
        let projects = try BackendProjectService(store: store, files: files, home: root.path, appDataRoot: state, liveSessions: { [session] }, showInWindow: { _ in false })
        let runtime = Runtime([api.path, web.path]), git = Git(repos: [api.path]), dev = Dev(api.path)
        let ports = try BackendDevPortDiscovery(runner: BackendCommandRunner(), inheritedEnvironment: [:], cwd: root.path, ownPorts: BackendDevOwnPorts())
        let services = BackendDeckToolsProjectServices(projects: projects, git: .init(authority: authority, runner: git), dev: .init(files: files, sessions: NoSessionProcess(), ports: ports), ports: ports,
            dashboards: try .init(userData: state, ownership: .memory), artifacts: .init(source: NoTranscripts(), authority: authority), devAccess: dev)
        return Rig(root: root, api: api, web: web, state: state, store: store, runtime: runtime, git: git, dev: dev, definitions: try BackendDeckToolsProjects.definitions(services: services, runtime: runtime))
    }
    func testBrowseFoldersOnlyHiddenOptInAndRepositoryMarker() async throws {
        let r = try await rig(); defer { r.dispose() }
        let plain = try await r.call("projects.browse", .object([])), rows = plain.structuredContent!["folders"].elements!
        XCTAssertEqual(plain.structuredContent!["path"], .string(r.root.path)); XCTAssertFalse(rows.contains { $0["name"].string == "notes.txt" || $0["name"].string == ".config" }); XCTAssertEqual(rows.first { $0["name"].string == "api" }?["repo"], .bool(true))
        let hidden = try await r.call("projects.browse", Self.o([("showHidden", .bool(true))])); XCTAssertTrue(hidden.structuredContent!["folders"].elements!.contains { $0["name"].string == ".config" })
    }
    func testBrowseRelativePathNeverGuesses() async throws { let r = try await rig(); defer { r.dispose() }; let reply = try await r.call("projects.browse", Self.o([("path", .string("Projects"))])); XCTAssertTrue(reply.isError); XCTAssertTrue(reply.content.first?["text"].string?.contains("absolute") == true) }
    func testProjectAddRemoveRequireAlter() throws {
        let entries = try BackendDeckToolsCatalogue.entries(); for id in ["projects.add", "projects.remove"] { XCTAssertEqual(entries.first { $0.spec.id == id }?.spec.tier, .alter) }
    }
    func testAppStorageCannotBecomeProjectBeforeConsent() async throws {
        let r = try await rig(); defer { r.dispose() }
        for path in [r.state.path, r.state.path + "/copilot"] { let reply = try await r.call("projects.add", Self.o([("path", .string(path))])); XCTAssertTrue(reply.isError) }
        let tier = await r.runtime.lastTier(); XCTAssertNil(tier)
        XCTAssertNoThrow(try BackendDeckToolsProjects.refuseStorage(r.state.path + "-two", root: r.state.path))
    }
    func testOpenProjectSaysWhetherWindowTookIt() async throws {
        let r = try await rig(); defer { r.dispose() }; let reply = try await r.call("projects.add", Self.o([("path", .string(r.api.path))]))
        XCTAssertEqual(reply.structuredContent!["inWindow"], .bool(false)); XCTAssertTrue(reply.structuredContent!["note"].string!.contains("once a session starts there"))
        let opened = await r.store.getProjects(); XCTAssertTrue(opened.contains { $0["path"].string == r.api.path })
    }
    func testRemoveKeepsRunningSessionsAndReportsIDs() async throws {
        let r = try await rig(); defer { r.dispose() }; let reply = try await r.call("projects.remove", Self.o([("path", .string(r.api.path))]))
        XCTAssertEqual(reply.structuredContent!["stillRunning"], .array([.string("s1")]))
        let projects = await r.store.getProjects(); XCTAssertFalse(projects.contains { $0["path"].string == r.api.path })
    }
    func testGitInitOnlyWhereNoRepositoryExists() async throws {
        let r = try await rig(); defer { r.dispose() }
        let existing = try await r.call("git.init", Self.o([("cwd", .string(r.api.path))])), created = try await r.call("git.init", Self.o([("cwd", .string(r.web.path))]))
        XCTAssertEqual(existing.structuredContent!["created"], .bool(false)); XCTAssertEqual(created.structuredContent!["created"], .bool(true))
        let calls = await r.git.initCalls(); XCTAssertEqual(calls, [r.web.path])
    }
    func testDevStartOnlyOpenProjectAndListingIsRead() async throws {
        let r = try await rig(); defer { r.dispose() }
        let bad = try await r.call("dev.servers", Self.o([("action", .string("start")), ("cwd", .string("/tmp"))])); XCTAssertTrue(bad.isError)
        _ = try await r.call("dev.servers", Self.o([("action", .string("list"))])); let read = await r.runtime.lastTier(); XCTAssertEqual(read, .read)
        let started = try await r.call("dev.servers", Self.o([("action", .string("start")), ("cwd", .string(r.api.path))])); XCTAssertEqual(started.structuredContent!["server"]["status"], .string("starting"))
        let act = await r.runtime.lastTier(), calls = await r.dev.calls(); XCTAssertEqual(act, .act); XCTAssertEqual(calls, [r.api.path])
    }
    func testDashboardWritesAndResetRequireAlter() async throws {
        let r = try await rig(); defer { r.dispose() }
        let args = Self.o([("action", .string("save")), ("cwd", .string(r.api.path))]); let missing = try await r.call("dashboard.layout", args); XCTAssertTrue(missing.isError)
        _ = try await r.call("dashboard.layout", args.setting("layout", .object([]))); let save = await r.runtime.lastTier(); XCTAssertEqual(save, .alter)
        let reset = try await r.call("dashboard.layout", args.setting("action", .string("reset"))); XCTAssertEqual(reset.structuredContent?["reset"], .bool(true))
        let tier = await r.runtime.lastTier(); XCTAssertEqual(tier, .alter)
    }
    func testArtifactHistoryOnlyRelativeNoTraversal() async throws {
        let r = try await rig(); defer { r.dispose() }
        for path in ["../outside.ts", "/outside.ts"] { let reply = try await r.call("artifacts.list", Self.o([("cwd", .string(r.api.path)), ("path", .string(path))])); XCTAssertTrue(reply.isError) }
        let reply = try await r.call("artifacts.list", Self.o([("cwd", .string(r.api.path)), ("path", .string("src/a.ts"))])); XCTAssertEqual(reply.structuredContent?["relPath"], .string("src/a.ts"))
    }
}
