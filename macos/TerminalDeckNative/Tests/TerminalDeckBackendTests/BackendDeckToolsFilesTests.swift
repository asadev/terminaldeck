import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsFilesTests: XCTestCase {
    private func args(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    func testCredentialFilesAndExplicitTemplates() {
        XCTAssertEqual(BackendDeckToolsFiles.secretShape("config/.env.production")?.name, "dotenv")
        XCTAssertEqual(BackendDeckToolsFiles.secretShape("/Users/me/.ssh/id_ed25519")?.name, "ssh-private-key")
        XCTAssertEqual(BackendDeckToolsFiles.secretShape("deploy/key.pem")?.name, "private-key-file")
        XCTAssertNil(BackendDeckToolsFiles.secretShape(".env.example"))
        XCTAssertNil(BackendDeckToolsFiles.secretShape("src/.env.d.ts"))
    }
    func testRelativePathsStayInProjectAndDoNotGuessAbsolute() throws {
        XCTAssertEqual(try BackendDeckToolsFiles.relative("src/../test\\a.swift"), "test/a.swift")
        XCTAssertEqual(try BackendDeckToolsFiles.relative("\\foo\\bar"), "/foo/bar")
        XCTAssertThrowsError(try BackendDeckToolsFiles.relative("../sibling/a.swift")) { XCTAssertEqual(($0 as? NativeRPCError)?.message, "path must stay inside the project folder") }
        XCTAssertThrowsError(try BackendDeckToolsFiles.relative("/etc/passwd"))
    }
    func testUploadBytesAndTransportCeiling() throws {
        XCTAssertEqual(try BackendDeckToolsFiles.decodeUpload(args([("name", .string("x.txt")), ("contentBase64", .string("aGVsbG8"))])), Data("hello".utf8))
        let over = Data(repeating: 0, count: BackendDeckToolsFiles.maxUploadBytes + 1).base64EncodedString()
        XCTAssertThrowsError(try BackendDeckToolsFiles.decodeUpload(args([("name", .string("x")), ("contentBase64", .string(over))])))
        XCTAssertThrowsError(try BackendDeckToolsFiles.decodeUpload(args([("name", .string("x")), ("contentBase64", .string("not base64!"))])))
    }
    func testEveryQueryWordAndFilenameRanking() {
        XCTAssertEqual(BackendDeckToolsFiles.rankMatches(["src/login/form.ts", "test/login-form.test.ts", "docs/login.md"], words: ["login", "form"]), ["test/login-form.test.ts", "src/login/form.ts"])
    }
    func testAttachPathsCapAndOriginalMentionSpelling() throws {
        XCTAssertThrowsError(try BackendDeckToolsFiles.attachPaths(args([("paths", .array(Array(repeating: .string("/a"), count: 11)))])))
        XCTAssertThrowsError(try BackendDeckToolsFiles.attachPaths(args([("paths", .array([.string("relative")]))])))
        XCTAssertEqual(BackendDeckToolsFiles.mention("/a/folder", directory: true), "@\"/a/folder/\"")
    }
    func testProjectStorageBoundaryAndSibling() throws {
        XCTAssertThrowsError(try BackendDeckToolsProjects.refuseStorage("/state/copilot", root: "/state"))
        XCTAssertNoThrow(try BackendDeckToolsProjects.refuseStorage("/state-two", root: "/state"))
        XCTAssertThrowsError(try BackendDeckToolsProjects.folder("Projects"))
    }
    func testSourceMetadataHasExactAttachmentTierAndActionEnums() throws {
        let entries = try BackendDeckToolsCatalogue.entries()
        XCTAssertEqual(entries.count, 19)
        XCTAssertEqual(entries.first { $0.spec.id == "sessions.attach" }?.spec.tier, .act)
        XCTAssertEqual(entries.first { $0.spec.id == "files.ignored" }?.spec.inputSchema["properties"]["action"]["enum"], .array([.string("overview"), .string("explain"), .string("filter")]))
    }
    struct Runtime: BackendDeckToolsFilesRuntime {
        func rpc(_ caller: BackendMCPCallContext) async throws -> NativeRPCContext { .init(caller: .nativeApp, ownerID: "test") }
        func knownFolder(_ path: String, caller: BackendMCPCallContext) async throws -> String { throw BackendDeckToolsSupport.unavailable("unused test folder") }
        func requireSession(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { .object([.init("id", .string(id))]) }
        func startedByCopilot(_ id: String, caller: BackendMCPCallContext) async throws -> Bool { caller.sessionID == "callerA" }
        func boundary(_ id: String) async throws -> BackendDeviceBoundary? { nil }
        func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue) async throws {}
        func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws {}
    }
    func testAttachmentTierFloorAndPerCallerOwnershipBeforeAnyDiskRead() async throws {
        let authority = BackendFilesystemAuthority { _ in .init(readRoots: []) }
        let files = BackendFilesystemService(authority: authority)
        let transfers = BackendFilesystemTransfers(authority: authority, uploadsDirectory: { throw BackendDeckToolsSupport.unavailable("unused test upload") })
        let definitions = try BackendDeckToolsFiles.definitions(service: .init(files: files, transfers: transfers), runtime: Runtime())
        let attach = definitions.first { $0.spec.id == "sessions.attach" }!
        let reader = BackendMCPCallContext(sessionID: "callerA", machineID: "", projectRoot: nil, attended: true, allowedTools: ["sessions.attach"], allowedTiers: [.read], cancellation: .init())
        let readOnly = try await attach.handler(reader, args([("sessionId", .string("s"))]))
        XCTAssertTrue(readOnly.isError)
        let other = BackendMCPCallContext(sessionID: "callerB", machineID: "", projectRoot: nil, attended: true, allowedTools: ["sessions.attach"], allowedTiers: [.act], cancellation: .init())
        let foreign = try await attach.handler(other, args([("sessionId", .string("s")), ("paths", .array([.string("/unused-file")]))]))
        XCTAssertTrue(foreign.isError)
    }
}
