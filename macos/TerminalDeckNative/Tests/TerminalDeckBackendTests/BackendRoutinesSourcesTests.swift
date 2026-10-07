import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRoutinesSourceProbe: @unchecked Sendable {
    private let lock = NSLock(); private var callbacks: [String: @Sendable (String) -> Void] = [:], received: [String: [String]] = [:]
    private(set) var opens = 0, closes = 0
    func stream(_ root: String, callback: @escaping @Sendable (String) -> Void) -> @Sendable () -> Void { lock.withLock { opens += 1; callbacks[root] = callback }; return { [self] in lock.withLock { closes += 1; callbacks[root] = nil } } }
    func emit(_ root: String, _ path: String) { let callback = lock.withLock { callbacks[root] }; callback?(path) }
    func listen(_ key: String, path: String) { lock.withLock { received[key, default: []].append(path) } }
    func paths(_ key: String) -> [String] { lock.withLock { received[key] ?? [] } }
}
actor BackendRoutinesTestGit: BackendRoutinesGitWatching {
    private var observers: [UUID: @Sendable (String, NativeRPCValue) async -> Void] = [:]
    private var holders: [String: Int] = [:]
    func observeGit(_ callback: @escaping @Sendable (String, NativeRPCValue) async -> Void) -> UUID { let id = UUID(); observers[id] = callback; return id }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    func watchGit(cwd: String, context: NativeRPCContext) -> NativeRPCValue { holders[context.ownerID, default: 0] += 1; return .object([.init("repo", .bool(true))]) }
    func unwatch(cwd: String, ownerID: String) { holders[ownerID, default: 0] -= 1; if holders[ownerID] == 0 { holders[ownerID] = nil } }
    func references(_ owner: String) -> Int { holders[owner] ?? 0 }
    func emit(_ cwd: String) async { for callback in observers.values { await callback(cwd, .object([])) } }
}
final class BackendRoutinesSourcesTests: XCTestCase {
    func testOneStreamPerFolderAndLastReleaseStopsIt() throws {
        let probe = BackendRoutinesSourceProbe(), watchers = BackendRoutinesFileWatchers(stream: { probe.stream($0, callback: $1) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-routines-source-" + UUID().uuidString).path
        let first = try watchers.watch(root) { probe.listen("a", path: $0) }, second = try watchers.watch(root + "/.") { probe.listen("b", path: $0) }
        XCTAssertEqual(watchers.count, 1); XCTAssertEqual(probe.opens, 1)
        probe.emit(root, root + "/src/app.swift"); XCTAssertEqual(probe.paths("a"), ["src/app.swift"]); XCTAssertEqual(probe.paths("b"), ["src/app.swift"])
        first(); probe.emit(root, root + "/second.swift"); XCTAssertEqual(probe.paths("a").count, 1); XCTAssertEqual(probe.paths("b").count, 2)
        second(); second(); XCTAssertEqual(watchers.count, 0); XCTAssertEqual(probe.closes, 1)
        watchers.stop(); XCTAssertThrowsError(try watchers.watch(root) { _ in })
    }
    func testIgnoredTreesOutsideRootDepthAndSymlinksNeverReport() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("td-routines-source-" + UUID().uuidString), root = rootURL.path
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createSymbolicLink(atPath: root + "/outside", withDestinationPath: "/tmp")
        let probe = BackendRoutinesSourceProbe(), watchers = BackendRoutinesFileWatchers(stream: { probe.stream($0, callback: $1) }); defer { watchers.stop() }
        _ = try watchers.watch(root) { probe.listen("seen", path: $0) }
        for path in [".git/HEAD", "node_modules/a/index.js", "out/app.js", "dist/main.js", "outside/unowned.txt", "../other/file.txt", String(repeating: "a/", count: 11) + "file.txt"] { probe.emit(root, root + "/" + path) }
        probe.emit(root, root); probe.emit(root, root + "-other/file"); probe.emit(root, root + "/real.swift")
        XCTAssertEqual(probe.paths("seen"), ["real.swift"])
        // FSEvents may report /private/tmp or /private/var while the named
        // watch is the ordinary /tmp or /var alias. Preserve the listener key
        // and relative result while matching the same physical folder.
        let namedAlias = "/tmp/td-routine-alias-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: namedAlias, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: namedAlias) }
        let offAlias = try watchers.watch(namedAlias) { probe.listen("alias", path: $0) }; defer { offAlias() }
        let physical = URL(fileURLWithPath: namedAlias).resolvingSymlinksInPath().path
        probe.emit(namedAlias, physical + "/app.swift"); XCTAssertEqual(probe.paths("alias"), ["app.swift"])
    }
    func testGlobstarDotsBracesRangesNegationExtglobsAndPOSIXClasses() {
        let rows: [(String, String, Bool)] = [
            ("src/**", "src", true), ("src/**", "src/app/a.swift", true), ("**/*.swift", "app.swift", true), ("**/*.swift", ".hidden/app.swift", true),
            ("src/*.swift", "src/deep/a.swift", false), ("foo**bar", "foo/a/bar", false), ("foo**bar", "fooxbar", true),
            ("!**/*.ts", "src/app.swift", true), ("!**/*.ts", "src/app.ts", false), ("!!*.ts", "app.ts", true),
            ("*.{ts,tsx}", "app.tsx", true), ("file{1..3}.txt", "file2.txt", true), ("file{a..c}.txt", "fileb.txt", true), ("{literal}", "literal", false), ("{literal}", "{literal}", true),
            ("@(app|lib).swift", "lib.swift", true), ("!(old).swift", "new.swift", true), ("!(*.d).ts", "types.d.ts", false), ("!(*.d).ts", "types.ts", true),
            ("[[:digit:]].txt", "2.txt", true), ("[[:alpha:]].txt", "2.txt", false), ("[ab].txt", "[ab].txt", true),
            ("**", "a/../secret", false), ("*", ".", false), ("\"*.swift\"", "app.swift", false), ("\"*.swift\"", "*.swift", true)
            , ("+(*(a)|*(b))", "abba", true), ("+(a|aa)", "aaa", false), ("+(a|aa)", "+(a|aa)", true)
        ]
        for (glob, path, expected) in rows { XCTAssertEqual(BackendRoutinesGlob.matches(glob, path: path), expected, "\(glob) matching \(path)") }
    }
    func testRelativePathRejectsRootOutsideAndNormalizesDots() {
        XCTAssertEqual(BackendRoutinesFileWatchers.relative(root: "/work/api", path: "/work/api/src/./app.swift"), "src/app.swift")
        XCTAssertNil(BackendRoutinesFileWatchers.relative(root: "/work/api", path: "/work/api-two/file")); XCTAssertNil(BackendRoutinesFileWatchers.relative(root: "/work/api", path: "/work/api")); XCTAssertNil(BackendRoutinesFileWatchers.relative(root: "/work/api", path: "/work/api/../secret"))
    }
    func testGitAdapterHoldsSharedWatchWithoutPanelAndReleasesOnlyItsReference() async throws {
        let shared = BackendRoutinesTestGit(), probe = BackendRoutinesSourceProbe(), root = "/tmp/td-git-source-" + UUID().uuidString
        _ = await shared.watchGit(cwd: root, context: .init(caller: .nativeApp, ownerID: "panel"))
        let adapter = BackendRoutinesGitSources(shared: shared, context: { _ in .init(caller: .internalEngine, ownerID: "routines") }, problem: { _ in XCTFail("shared Git watch should succeed") })
        let first = adapter.watch(root) { probe.listen("a", path: "git") }, second = adapter.watch(root) { probe.listen("b", path: "git") }
        await BackendRoutinesTestRig.settle(); let held = await shared.references("routines"); XCTAssertEqual(held, 2)
        await shared.emit(root + "-other"); XCTAssertTrue(probe.paths("a").isEmpty)
        await shared.emit(root); XCTAssertEqual(probe.paths("a"), ["git"]); XCTAssertEqual(probe.paths("b"), ["git"])
        first(); await BackendRoutinesTestRig.settle(); await shared.emit(root)
        let remaining = await shared.references("routines"); XCTAssertEqual(remaining, 1); XCTAssertEqual(probe.paths("a").count, 1); XCTAssertEqual(probe.paths("b").count, 2)
        second(); second(); await BackendRoutinesTestRig.settle(); await shared.emit(root)
        let final = await shared.references("routines"), panel = await shared.references("panel"); XCTAssertEqual(final, 0); XCTAssertEqual(panel, 1); XCTAssertEqual(probe.paths("b").count, 2)
    }
    func testAlertObserverReceivesTheExactReportReturnedByItsSource() async throws {
        let rig = try await BackendRoutinesTestRig.make(unwired: true); addTeardownBlock { await rig.clean() }
        try rig.write("alerts", when: "alert critical"); await rig.engine.reload()
        let observer = BackendRoutinesSources.alertObserver(for: rig.engine), registry = NativeChannelRegistry()
        let report = NativeRPCValue.object([.init("projectPath", .string(BackendRoutinesTestRig.project)), .init("alerts", .array([.object([.init("id", .string("blocked:s")), .init("kind", .string("session-blocked")), .init("severity", .string("critical")), .init("title", .string("Needs an answer"))])])), .init("scannedAt", .number(rig.clock.now)), .init("coverage", .array([.string("exact source value")]))])
        try await registry.register("alerts:project", ownerID: "alerts-source") { _, _ in await observer(report); return report }
        let answer = try await registry.invoke("alerts:project", context: .init(caller: .nativeApp, ownerID: "person"), arguments: []); XCTAssertEqual(answer, report)
        await BackendRoutinesTestRig.settle(); let calls = await rig.runner.calls, source = await rig.engine.get("alerts")?.sources.first
        XCTAssertEqual(calls.first?.cause, .alert(alertId: "blocked:s", severity: "critical", title: "Needs an answer", sessionId: nil)); XCTAssertEqual(source?.events, 1); XCTAssertEqual(source?.lastEventAt, rig.clock.now)
    }
}
