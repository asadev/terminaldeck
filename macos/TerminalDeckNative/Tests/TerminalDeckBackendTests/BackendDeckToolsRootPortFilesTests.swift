import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Uses actual native filesystem/staging owners in a temporary fixture. Network,
/// process and UI services are not started. The Git listing and caller gate are
/// fakes; each assertion reaches the real source tool handler.
final class BackendDeckToolsRootPortFilesTests: XCTestCase {
    static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    actor Runtime: BackendDeckToolsFilesRuntime {
        let root: String
        var held: BackendDeviceBoundary?
        var authorization: [(String, BackendMCPTier, NativeRPCValue)] = []
        init(root: String) { self.root = root }
        func rpc(_ caller: BackendMCPCallContext) async throws -> NativeRPCContext { .init(caller: .nativeApp, ownerID: "fixture") }
        func knownFolder(_ path: String, caller: BackendMCPCallContext) async throws -> String {
            guard path == root else { throw NativeRPCError(code: "not-permitted", message: "\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }; return path
        }
        func requireSession(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
            guard id == "s1" else { throw BackendDeckToolsArgs.bad("this app is not holding a session with id \(id)") }
            return .object([.init("id", .string(id)), .init("cwd", .string(root))])
        }
        func startedByCopilot(_ id: String, caller: BackendMCPCallContext) async throws -> Bool { id == "s1" && caller.sessionID == "owner" }
        func boundary(_ id: String) async throws -> BackendDeviceBoundary? { held }
        func setBoundary(_ value: BackendDeviceBoundary?) { held = value }
        func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue) async throws { authorization.append((tool, tier, arguments)) }
        func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws {}
        func last() -> (String, BackendMCPTier, NativeRPCValue)? { authorization.last }
    }
    final class Listing: @unchecked Sendable {
        let lock = NSLock(); private var reads = 0
        func list() -> [String] { lock.withLock { reads += 1; return ["src/login/form.ts", "src/app.ts", "docs/login.md", "test/login-form.test.ts"] } }
        var count: Int { lock.withLock { reads } }
    }
    struct Rig {
        let directory: URL, project: URL, runtime: Runtime, listing: Listing
        let definitions: [BackendDeckToolsDefinition]
        func call(_ id: String, _ args: NativeRPCValue, owner: String = "owner") async throws -> BackendMCPToolReply {
            let definition = definitions.first { $0.spec.id == id }!
            let context = BackendMCPCallContext(sessionID: owner, machineID: "", projectRoot: nil, attended: true,
                allowedTools: Set(definitions.map { $0.spec.id }), allowedTiers: [.read, .act, .alter], cancellation: .init())
            return await BackendDeckToolsSupport.reply {
                try BackendDeckCoreCatalogueSchema.check(tool: definition.spec, arguments: args)
                return try await definition.handler(context, args)
            }
        }
        func args(_ extra: [(String, NativeRPCValue)]) -> NativeRPCValue { SelfArgs(extra) }
        private func SelfArgs(_ extra: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsRootPortFilesTests.o([("cwd", .string(project.path))] + extra) }
        func dispose() { try? FileManager.default.removeItem(at: directory) }
    }
    private func rig() throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsRootPortFiles-" + UUID().uuidString)
        let project = directory.appendingPathComponent("project"), src = project.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try (1...10).map { "line \($0)" }.joined(separator: "\n").write(to: src.appendingPathComponent("app.ts"), atomically: true, encoding: .utf8)
        let runtime = Runtime(root: project.path), listing = Listing()
        let authority = BackendFilesystemAuthority { _ in .init(readRoots: [directory], writeRoots: [directory]) }
        let files = BackendFilesystemService(authority: authority, gitFiles: { _, _ in listing.list() })
        let transfers = BackendFilesystemTransfers(authority: authority, uploadsDirectory: { directory.appendingPathComponent("uploads") })
        return Rig(directory: directory, project: project, runtime: runtime, listing: listing,
            definitions: try BackendDeckToolsFiles.definitions(service: .init(files: files, transfers: transfers), runtime: runtime))
    }
    func testCredentialShapesAtAnyDepth() {
        for (path, expected) in [(".env", "dotenv"), ("config/.env.production", "dotenv"), ("deploy/key.pem", "private-key-file"), (".npmrc", "registry-auth")] {
            XCTAssertEqual(BackendDeckToolsFiles.secretShape(path)?.name, expected)
        }
        XCTAssertNotNil(BackendDeckToolsFiles.secretShape("/Users/me/.ssh/id_ed25519"))
    }
    func testTemplatesStayReadable() {
        XCTAssertNil(BackendDeckToolsFiles.secretShape(".env.example")); XCTAssertNil(BackendDeckToolsFiles.secretShape("src/.env.d.ts")); XCTAssertNil(BackendDeckToolsFiles.secretShape("src/environment.ts"))
    }
    func testSecretRefusedBeforeFileOrConsentIsOpened() async throws {
        let r = try rig(); defer { r.dispose() }
        let reply = try await r.call("files.read", r.args([("path", .string("server/.env"))]))
        XCTAssertTrue(reply.isError); XCTAssertTrue(reply.content.first?["text"].string?.contains("credential file") == true)
        let logged = await r.runtime.last(); XCTAssertNil(logged)
    }
    func testReadPagesByLines() async throws {
        let r = try rig(); defer { r.dispose() }
        let reply = try await r.call("files.read", r.args([("path", .string("src/app.ts")), ("fromLine", .number(4)), ("lines", .number(3))]))
        let value = reply.structuredContent!
        XCTAssertEqual(value["fromLine"], .number(4)); XCTAssertEqual(value["toLine"], .number(6)); XCTAssertEqual(value["more"], .bool(true)); XCTAssertEqual(value["text"], .string("line 4\nline 5\nline 6"))
    }
    func testReadCannotEscapeOrNameUnopenedFolder() async throws {
        let r = try rig(); defer { r.dispose() }
        for (args, sentence) in [(r.args([("path", .string("../web/x.ts"))]), "inside the project"), (r.args([("path", .string("/etc/passwd"))]), "relative"), (Self.o([("cwd", .string("/etc")), ("path", .string("passwd"))]), "not a folder this app has open")] {
            let reply = try await r.call("files.read", args); XCTAssertTrue(reply.isError); XCTAssertTrue(reply.content.first?["text"].string?.contains(sentence) == true)
        }
    }
    func testListingHasNoStatisticsUnlessAsked() async throws {
        let r = try rig(); defer { r.dispose() }
        let reply = try await r.call("files.list", r.args([]))
        XCTAssertEqual(reply.structuredContent!["entries"].elements!.first?["name"], .string("src"))
        XCTAssertEqual(reply.structuredContent!["entries"].elements!.first?["bytes"], .missing)
    }
    func testEveryQueryWordFilenameRankingAndRefresh() async throws {
        XCTAssertEqual(BackendDeckToolsFiles.rankMatches(["src/login/form.ts", "test/login-form.test.ts", "docs/login.md"], words: ["login", "form"]), ["test/login-form.test.ts", "src/login/form.ts"])
        let r = try rig(); defer { r.dispose() }
        _ = try await r.call("files.find", r.args([("query", .string("login"))]))
        _ = try await r.call("files.find", r.args([("query", .string("login")), ("refresh", .bool(true))]))
        XCTAssertEqual(r.listing.count, 2)
    }
    func testRefreshIgnoreRulesBeforeFiltering() async throws {
        let r = try rig(); defer { r.dispose() }
        try "dist/\n".write(to: r.project.appendingPathComponent(".deckignore"), atomically: true, encoding: .utf8)
        let reply = try await r.call("files.ignored", r.args([("action", .string("filter")), ("paths", .array([.string("dist/a.js"), .string("src/a.ts")])), ("refresh", .bool(true))]))
        XCTAssertEqual(reply.structuredContent!["kept"], .array([.string("src/a.ts")]))
        XCTAssertEqual(reply.structuredContent!["hidden"], .array([.string("dist/a.js")]))
    }
    func testUploadStagesExactBytesAndMention() async throws {
        let r = try rig(); defer { r.dispose() }
        let bytes = Data("png bytes".utf8)
        let reply = try await r.call("files.upload", Self.o([("name", .string("shot.png")), ("contentBase64", .string(bytes.base64EncodedString()))]))
        let value = reply.structuredContent!, path = value["path"].string!
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes); XCTAssertEqual(value["bytes"], .number(9)); XCTAssertEqual(value["mention"], .string("@\"\(path)\""))
    }
    func testUploadLimitAndMalformedBase64AreRefused() async throws {
        let r = try rig(); defer { r.dispose() }
        for content in [Data(repeating: 0, count: BackendDeckToolsFiles.maxUploadBytes + 1).base64EncodedString(), "not base64!"] {
            let reply = try await r.call("files.upload", Self.o([("name", .string("x")), ("contentBase64", .string(content))])); XCTAssertTrue(reply.isError)
        }
    }
    func testUploadLogKeepsOnlySize() async throws {
        let r = try rig(); defer { r.dispose() }
        _ = try await r.call("files.upload", Self.o([("name", .string("a.txt")), ("contentBase64", .string("aGVsbG8="))]))
        let row = await r.runtime.last()
        XCTAssertEqual(row?.2["name"], .string("a.txt")); XCTAssertEqual(row?.2["contentBase64"], .string("[8 base64 characters]"))
    }
    func testHeldCopiesButOrdinarySessionsUseOriginalFilesAndFolders() async throws {
        let r = try rig(); defer { r.dispose() }
        let source = r.directory.appendingPathComponent("shot.png"); try Data("png".utf8).write(to: source)
        await r.runtime.setBoundary(.init(deviceKey: "fixture", folder: r.project.path, readOnlyProjects: ["/work/web"]))
        let held = try await r.call("sessions.attach", Self.o([("sessionId", .string("s1")), ("paths", .array([.string(source.path)]))]))
        let copied = held.structuredContent!["attached"].elements![0]["path"].string!
        XCTAssertTrue(copied.hasPrefix(r.project.path + "/Terminal Deck/")); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied)), Data("png".utf8))
        XCTAssertEqual(held.structuredContent!["alsoReadable"], .array([.string("/work/web")]))
        await r.runtime.setBoundary(nil)
        let loose = try await r.call("sessions.attach", Self.o([("sessionId", .string("s1")), ("paths", .array([.string(source.path), .string(r.project.path)]))]))
        let rows = loose.structuredContent!["attached"].elements!
        XCTAssertEqual(rows[0]["path"], .string(source.path)); XCTAssertEqual(rows[1]["mention"], .string("@\"\(r.project.path)/\""))
        XCTAssertEqual(loose.structuredContent!["heldInFolder"], .null)
    }
    func testAttachmentsNeverHandOutCredentialFiles() async throws {
        let r = try rig(); defer { r.dispose() }
        let reply = try await r.call("sessions.attach", Self.o([("sessionId", .string("s1")), ("paths", .array([.string("/Users/me/.ssh/id_rsa"), .string("/Users/me/app/.env")]))]))
        XCTAssertEqual(reply.structuredContent!["attached"], .array([]))
        XCTAssertEqual(reply.structuredContent!["refused"].elements!.map { $0["why"] }, [.string("it is a credential file (ssh-private-key)"), .string("it is a credential file (dotenv)")])
    }
    func testAttachOwnershipEscalationKeepsDeclaredActFloor() async throws {
        let r = try rig(); defer { r.dispose() }
        _ = try await r.call("sessions.attach", Self.o([("sessionId", .string("s1"))]))
        let onlyAsked = await r.runtime.last(); XCTAssertEqual(onlyAsked?.1, .act) // TS control takes max(base act, escalation read).
        _ = try await r.call("sessions.attach", Self.o([("sessionId", .string("s1")), ("paths", .array([.string("/missing")]))]), owner: "other")
        let foreign = await r.runtime.last(); XCTAssertEqual(foreign?.1, .alter)
    }
}
