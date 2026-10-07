import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// file-search.test.ts against BackendFilesystemService.projectFiles.
/// Skipped: Electron ipcMain wiring/non-string payload cases (no IPC in the Swift port),
/// the real-repo `process.cwd()` case (depends on a live checkout), parseGitFileList NUL
/// splitting (done by the git runner that supplies `gitFiles`, not by this service).
/// Blocked (no seam): maxDepth, ignoreDirs, abort-signal options; the walk's depth is fixed at 12.
final class BackendFoundationTestsS6C2FileSearch: XCTestCase {
    private final class S6C2Git: @unchecked Sendable {
        private let lock = NSLock(); private var answer: [String]?; private var calls = 0
        init(_ answer: [String]?) { self.answer = answer }
        func list() -> [String]? { lock.withLock { calls += 1; return answer } }
        var count: Int { lock.withLock { calls } }
    }
    private struct S6C2Rig {
        let base: URL; let service: BackendFilesystemService
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "s6c2")
        func dispose() { try? FileManager.default.removeItem(at: base) }
        func project(_ files: [String]) throws -> URL {
            let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for file in files { try write(root, file) }
            return root
        }
        func write(_ root: URL, _ file: String) throws {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        func search(_ root: URL, refresh: Bool = false, limit: Int = 10_000, home: String? = nil) async throws -> NativeRPCValue {
            try await service.projectFiles(root: root.path, refresh: refresh, limit: limit, context: context, home: home)
        }
    }
    private func rig(git: S6C2Git? = nil) throws -> S6C2Rig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("s6c2-search-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let authority = BackendFilesystemAuthority { _ in .init(readRoots: [base], writeRoots: [base]) }
        let listing: BackendFilesystemService.GitFileListing? = git.map { g in { @Sendable _, _ in g.list() } }
        let service = BackendFilesystemService(authority: authority, gitFiles: listing)
        return S6C2Rig(base: base, service: service)
    }
    private func files(_ value: NativeRPCValue) -> [String] { value["files"].elements?.compactMap { $0.string } ?? [] }
    private func fixture(_ r: S6C2Rig) throws -> URL {
        try r.project(["package.json", ".gitignore", "src/index.ts", "src/deep/deeper/buried.ts",
                       "node_modules/react/index.js", ".git/objects/blob"])
    }

    // :103 :111 :117 walk finds files relative to the root, dotfiles too, never node_modules/.git
    func testS6C2WalkFindsProjectFilesAndSkipsIgnoredDirectories() async throws {
        let r = try rig(); defer { r.dispose() }
        let list = files(try await r.search(try fixture(r)))
        XCTAssertTrue(list.contains("package.json")); XCTAssertTrue(list.contains("src/index.ts"))
        XCTAssertTrue(list.contains("src/deep/deeper/buried.ts")); XCTAssertTrue(list.contains(".gitignore"))
        XCTAssertFalse(list.contains { $0.hasPrefix("node_modules/") }); XCTAssertFalse(list.contains { $0.hasPrefix(".git/") })
    }
    // :124 :131 cap and shallow-first
    func testS6C2WalkCapsCountAndReturnsShallowFilesFirst() async throws {
        let r = try rig(); defer { r.dispose() }
        let value = try await r.search(try fixture(r), limit: 2)
        XCTAssertEqual(files(value).count, 2); XCTAssertEqual(value["truncated"].bool, true)
        XCTAssertTrue(files(value).contains("package.json")); XCTAssertFalse(files(value).contains("src/deep/deeper/buried.ts"))
    }
    // :153 symlinks are skipped
    func testS6C2WalkSkipsSymlinks() async throws {
        let r = try rig(); defer { r.dispose() }
        let root = try fixture(r)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/loop"), withDestinationURL: root)
        let awaited7 = try await r.search(root, limit: 500)
        XCTAssertFalse(files(awaited7).contains { $0.contains("loop") })
    }
    // :176 falls back to the walk when git cannot answer
    func testS6C2FallsBackToWalkWhenGitCannotAnswer() async throws {
        let git = S6C2Git(nil); let r = try rig(git: git); defer { r.dispose() }
        let root = try r.project(["a.ts"])
        let value = try await r.search(root)
        XCTAssertEqual(value["source"].string, "walk"); XCTAssertEqual(files(value), ["a.ts"])
        XCTAssertEqual(URL(fileURLWithPath: value["root"].string ?? "").resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        XCTAssertGreaterThanOrEqual(value["tookMs"].number ?? -1, 0)
        XCTAssertEqual(git.count, 1)
    }
    // :23-:35 :41-:57 git list is de-duplicated and ignored directories are dropped by whole segment
    func testS6C2GitListIsDedupedAndFilteredByWholeSegments() async throws {
        let git = S6C2Git(["a.ts", "dir/b\nc.ts", "a.ts", "b.ts", "node_modules/react/index.js", "packages/app/node_modules/x.js",
            ".git/config", "src/index.ts", "package.json", "src/node_modules_stub/x.ts", "src/distribution/x.ts", "src/build"])
        let r = try rig(git: git); defer { r.dispose() }
        let value = try await r.search(try r.project(["a.ts"]))
        XCTAssertEqual(value["source"].string, "git")
        XCTAssertEqual(files(value), ["a.ts", "dir/b\nc.ts", "b.ts", "src/index.ts", "package.json", "src/node_modules_stub/x.ts", "src/distribution/x.ts", "src/build"])
    }
    func testS6C2EmptyGitOutputGivesEmptyList() async throws {
        let r = try rig(git: S6C2Git([])); defer { r.dispose() }
        let awaited8 = try await r.search(try r.project([]))
        XCTAssertEqual(files(awaited8), [])
    }
    // :63-:75 implausible roots refused: filesystem root, home itself, relative, empty, missing
    func testS6C2RefusesImplausibleRoots() async throws {
        let r = try rig(); defer { r.dispose() }
        let root = try r.project(["a.ts"])
        do { _ = try await r.search(root, home: root.resolvingSymlinksInPath().path); XCTFail("home accepted") } catch {}
        for bad in ["/", "src", "", r.base.appendingPathComponent("terminaldeck-not-a-directory-at-all").path] {
            do { _ = try await r.service.projectFiles(root: bad, context: r.context); XCTFail("accepted \(bad)") } catch {}
        }
    }
    // :239 a root the host has not allowed
    func testS6C2RefusesRootOutsideAllowedRoots() async throws {
        let r = try rig(); defer { r.dispose() }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("s6c2-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        do { _ = try await r.search(outside); XCTFail("outside root served") } catch {}
    }
    // :258 repeat request served from cache until refresh
    func testS6C2RepeatRequestIsCachedUntilRefresh() async throws {
        let r = try rig(); defer { r.dispose() }
        let root = try r.project(["a.ts"])
        let awaited9 = try await r.search(root)
        XCTAssertEqual(files(awaited9), ["a.ts"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.ts"))
        let awaited10 = try await r.search(root)
        XCTAssertEqual(files(awaited10), ["a.ts"])
        let awaited11 = try await r.search(root, refresh: true)
        XCTAssertEqual(files(awaited11), [])
    }
    // :273 a truncated list is not served to a request that asked for more
    func testS6C2TruncatedListNotServedToLargerRequest() async throws {
        let r = try rig(); defer { r.dispose() }
        let root = try r.project(["a.ts", "b.ts", "c.ts"])
        let small = try await r.search(root, limit: 1)
        XCTAssertEqual(small["truncated"].bool, true); XCTAssertEqual(files(small).count, 1)
        let full = try await r.search(root, limit: 100)
        XCTAssertEqual(files(full).count, 3); XCTAssertEqual(full["truncated"].bool, false)
    }
    // :289 the coldest root is evicted (cap is eight roots)
    func testS6C2EvictsColdestRoot() async throws {
        let r = try rig(); defer { r.dispose() }
        let first = try r.project(["original.ts"])
        let awaited12 = try await r.search(first)
        XCTAssertEqual(files(awaited12), ["original.ts"])
        try FileManager.default.removeItem(at: first.appendingPathComponent("original.ts"))
        try r.write(first, "replaced.ts")
        let awaited13 = try await r.search(first)
        XCTAssertEqual(files(awaited13), ["original.ts"])
        for i in 0..<10 { _ = try await r.search(try r.project(["f\(i).ts"])) }
        let awaited14 = try await r.search(first)
        XCTAssertEqual(files(awaited14), ["replaced.ts"])
    }
}
