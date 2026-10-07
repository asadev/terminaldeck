import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsFleetDiffTests: XCTestCase {
    private func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    struct Git: BackendGitExecuting {
        let root: String, paths: [String], diff: String
        func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool,
                 timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
            let text: String
            if arguments.first == "rev-parse" { text = root + "\n" }
            else if arguments.first == "status" { text = "# branch.head main\0" + paths.map { "1 .M N... 100644 100644 100644 aaaaaa bbbbbb \($0)\0" }.joined() }
            else if arguments.contains("--numstat") { text = paths.map { "1\t0\t\($0)\0" }.joined() }
            else { text = diff }
            return BackendGitOutcome(ok: true, stdout: text, stderr: "", missing: false, exitCode: 0, timedOut: false)
        }
    }
    private func session(_ id: String, cwd: String, at: Double) -> NativeRPCValue {
        o([("id", .string(id)), ("cwd", .string(cwd)), ("title", .string(id)), ("provider", .string("claude")), ("attention", .string("running")), ("createdAt", .number(at)), ("startedByCopilot", .bool(false))])
    }
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsFleetDiffTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }
    private func review(root: URL, paths: [String], diff: String = "+changed\n", sessions: [NativeRPCValue]) -> BackendGitReview {
        let authority = BackendFilesystemAuthority { _ in .init(readRoots: [root]) }
        return BackendGitReview(git: .init(authority: authority, runner: Git(root: root.path, paths: paths, diff: diff)), sessionViews: { sessions })
    }
    func testOnlyEarlierSessionCanOwnAFileAndNeighborCannot() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.swift"); try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: file.path)
        let sessions = [session("early", cwd: root.path + "/web", at: 1000), session("late", cwd: root.path, at: 9000), session("neighbor", cwd: root.path + "-two", at: 0)]
        let value = try await BackendDeckToolsFleetDiff.collect(review: review(root: root, paths: ["a.swift"], sessions: sessions), cwd: root.path, context: .init(caller: .nativeApp, ownerID: "test"))
        XCTAssertEqual(value["files"].elements![0]["attribution"]["candidates"], .array([.string("early")]))
        XCTAssertEqual(value["files"].elements![0]["attribution"]["sessionId"], .string("early"))
        XCTAssertTrue(value["attributionNote"].string!.hasPrefix("1 changed file:"))
    }
    func testOverlappingSessionsStayAmbiguousAndMissingFileKeepsReason() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.swift"); try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: file.path)
        let sessions = [session("one", cwd: root.path, at: 1000), session("two", cwd: root.path, at: 2000)]
        let value = try await BackendDeckToolsFleetDiff.collect(review: review(root: root, paths: ["a.swift", "missing.swift"], sessions: sessions), cwd: root.path, context: .init(caller: .nativeApp, ownerID: "test"))
        let rows = value["files"].elements!
        XCTAssertEqual(rows[0]["attribution"]["sessionId"], .null)
        XCTAssertEqual(rows[0]["attribution"]["candidates"].elements?.count, 2)
        XCTAssertEqual(rows[1]["attribution"]["modifiedAt"], .null)
        XCTAssertTrue(rows[1]["attribution"]["reason"].string!.contains("nothing can be said"))
    }
    func testListsAllFilesWhileBoundingPerFileAndTotalDiffText() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<8).map { "f\($0).swift" }
        let value = try await BackendDeckToolsFleetDiff.collect(review: review(root: root, paths: paths, diff: String(repeating: "x", count: 36_000), sessions: []), cwd: root.path, context: .init(caller: .nativeApp, ownerID: "test"))
        XCTAssertEqual(value["files"].elements?.count, 8)
        XCTAssertEqual(value["diffChars"], .number(60_000)); XCTAssertEqual(value["withDiff"], .number(5))
        XCTAssertEqual(value["files"].elements![0]["diff"].string?.utf16.count, 12_000)
        XCTAssertEqual(value["files"].elements![6]["omitted"], .string("byte-limit"))
    }
}
