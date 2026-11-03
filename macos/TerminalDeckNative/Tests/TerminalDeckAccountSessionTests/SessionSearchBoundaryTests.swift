import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U177: search real fixture transcripts through the production project/scope services.
final class SessionSearchBoundaryTests: XCTestCase, @unchecked Sendable {
    private func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private struct Fixture: Sendable {
        let root: URL, project: URL
        let state: NativeStateStore
        let cost: BackendCostService
        let search: BackendSessionSearchService
        var context: NativeRPCContext { .init(caller: .nativeApp, ownerID: "fixture-search") }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-boundary-" + UUID().uuidString).resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("app"), config = root.appendingPathComponent("login")
        let directory = config.appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(project.path))
        for path in [project, directory] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let rows = [("user", "Deploy green cache", false), ("assistant", "Deploy green cache private", false),
                    ("user", "deploy blue cache", false), ("user", "Deploy green cache metadata", true)]
        let lines = rows.map { role, text, meta in
            object([("type", .string(role)), ("cwd", .string(project.path)), ("isMeta", .bool(meta)),
                ("message", object([("content", .array([object([("type", .string("text")), ("text", .string(text))])]))]))]).compact
        }
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("fixture-conversation.jsonl"), atomically: true, encoding: .utf8)
        let state = NativeStateStore(initialState: NativeStateStore.defaults)
        _ = try await state.addProject(project.path)
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [root], writeRoots: [root]) })
        let projects = try BackendProjectService(store: state, files: files, home: root.path, appDataRoot: root.appendingPathComponent("data"), liveSessions: { [] })
        let cost = BackendCostService(projects: projects, scopeProvider: { _, _ in .init(configDirectory: config.path, projectFolders: [project.path]) }, push: { _, _, _ in })
        let search = BackendSessionSearchService(cost: cost, projects: projects)
        addTeardownBlock { await search.stop(); await cost.stop(); await state.close() }
        return .init(root: root, project: project, state: state, cost: cost, search: search)
    }
    func testRequestRejectsInvalidLimitsAndKeepsOnlyKnownRoles() throws {
        let base = object([("cwd", .string("/scratch")), ("query", .string("deploy"))])
        for number in [0.0, 1001, 1.5, .infinity, .nan] {
            XCTAssertThrowsError(try BackendSessionSearchRequest.parse(base.setting("maxHits", .number(number))))
        }
        for number in [0.0, 601, 2.5] { XCTAssertThrowsError(try BackendSessionSearchRequest.parse(base.setting("maxSessions", .number(number)))) }
        let parsed = try BackendSessionSearchRequest.parse(base.setting("roles", .array([.string("tool"), .string("unknown")])))
        XCTAssertEqual(parsed.roles, [.tool])
        let defaults = try BackendSessionSearchRequest.parse(base.setting("roles", .array([.string("unknown")])))
        XCTAssertEqual(defaults.roles, [.user, .assistant])
    }
    func testMalformedAndUnsafeQueriesReturnErrorsWithoutReadingTranscripts() async throws {
        let f = try await fixture()
        for (query, regex, code) in [("x", false, "query-too-short"), ("-private", false, "query-too-short"),
                                    ("[a", true, "invalid-regex"), ("(a+)+", true, "unsafe-regex"), ("(?=ab)ab", true, "unsafe-regex")] {
            var request = BackendSessionSearchRequest(cwd: f.project.path, query: query); request.regex = regex
            let result = try await f.search.search(request, context: f.context)
            XCTAssertEqual(result["ok"].bool, false); XCTAssertEqual(result["error"].string, code, query)
        }
    }
    func testPhraseExclusionAndMetadataFilteringReturnOnlyTheMatchingUserText() async throws {
        let f = try await fixture()
        let result = try await f.search.search(.init(cwd: f.project.path, query: "\"green cache\" -private"), context: f.context)
        XCTAssertEqual(result["ok"].bool, true)
        let hits = try XCTUnwrap(result["hits"].elements)
        XCTAssertEqual(hits.count, 1); XCTAssertEqual(hits.first?["role"].string, "user")
        XCTAssertEqual(hits.first?["snippet"]["text"].string, "Deploy green cache")
        XCTAssertFalse(hits.first?["snippet"]["ranges"].elements?.isEmpty ?? true)
    }
    func testRoleAndCaseFiltersAreAppliedToTheTranscript() async throws {
        let f = try await fixture()
        var request = BackendSessionSearchRequest(cwd: f.project.path, query: "Deploy")
        request.roles = [.user]; request.caseSensitive = true
        let exact = try await f.search.search(request, context: f.context)
        XCTAssertEqual(exact["hits"].elements?.count, 1)
        request.caseSensitive = false
        let folded = try await f.search.search(request, context: f.context)
        XCTAssertEqual(folded["hits"].elements?.count, 2)
        request.roles = [.assistant]
        let assistant = try await f.search.search(request, context: f.context)
        XCTAssertEqual(assistant["hits"].elements?.count, 1); XCTAssertEqual(assistant["hits"].elements?.first?["role"].string, "assistant")
    }
    func testHitLimitAndCancellationReturnBoundedHonestResults() async throws {
        let f = try await fixture()
        var request = BackendSessionSearchRequest(cwd: f.project.path, query: "deploy"); request.maxHits = 1
        let limited = try await f.search.search(request, context: f.context)
        XCTAssertEqual(limited["hits"].elements?.count, 1); XCTAssertEqual(limited["truncated"].bool, true)
        let cancellation = BackendMCPCancellation(); cancellation.cancel()
        let cancelled = try await f.search.search(request, context: f.context, cancellation: cancellation)
        XCTAssertEqual(cancelled["cancelled"].bool, true); XCTAssertTrue(cancelled["hits"].elements?.isEmpty == true)
    }
    func testProjectBoundCallersCannotSearchEveryProjectOrAnUnopenedFolder() async throws {
        let f = try await fixture()
        var request = BackendSessionSearchRequest(cwd: f.project.path, query: "deploy"); request.allProjects = true
        do { _ = try await f.search.search(request, context: f.context, restrictedToProject: f.project.path); XCTFail("Project scope was widened") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        request = .init(cwd: f.root.appendingPathComponent("unopened").path, query: "deploy")
        do { _ = try await f.search.search(request, context: f.context); XCTFail("An unopened project was searched") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        let invalid = try await f.search.search(.init(cwd: "/", query: "deploy"), context: f.context)
        XCTAssertEqual(invalid["error"].string, "invalid-project")
    }
    func testSearchRPCRunsAndCancelsAndRejectsUnknownChannels() async throws {
        let f = try await fixture()
        let cancelled = try await f.search.invoke("session-search:cancel", args: [], ownerID: "other-owner", context: f.context)
        XCTAssertEqual(cancelled, .null)
        do { _ = try await f.search.invoke("session-search:unknown", args: [], ownerID: f.context.ownerID, context: f.context); XCTFail("Unknown channel accepted") } catch {}
        let result = try await f.search.invoke("session-search:run", args: [object([("cwd", .string(f.project.path)), ("query", .string("deploy"))])], ownerID: f.context.ownerID, context: f.context)
        XCTAssertEqual(result["ok"].bool, true); XCTAssertEqual(result["hits"].elements?.count, 3)
    }
}
