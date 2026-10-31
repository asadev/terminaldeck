import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ports src/main/fs-tree.test.ts. Skipped: countLines/looksBinary/createsLoop/safeJoin
/// have no standalone Swift symbol (covered through read/list/resolve below);
/// "no dates and nothing named -> null" (Swift list always stats under withStats).
final class BackendFoundationTestsS6C3FsTreeTests: XCTestCase {
    private func matcher(_ lines: String...) -> BackendFilesystemIgnore { BackendFilesystemIgnore(texts: [lines.joined(separator: "\n")]) }
    private func names(_ listing: NativeRPCValue) -> [String] { (listing["entries"].elements ?? []).compactMap { $0["name"].string } }
    private func rig(_ name: String = "s6c3fs") throws -> (fx: BackendFoundationTestsBFixture, service: BackendFilesystemService) {
        let fx = try BackendFoundationTestsBFixture(name)
        return (fx, BackendFilesystemService(authority: fx.authority))
    }
    private func errorCode(_ work: () async throws -> Any) async -> String? {
        do { _ = try await work(); return nil } catch let error as NativeRPCError { return error.code } catch { return "other" }
    }

    // MARK: compileIgnorePattern
    func testDropsBlanksAndComments() {
        XCTAssertNil(BackendFilesystemIgnore.compile(""))
        XCTAssertNil(BackendFilesystemIgnore.compile("   "))
        XCTAssertNil(BackendFilesystemIgnore.compile("# a comment"))
    }
    func testRecordsNegationAndDirectoryOnlyFlags() {
        XCTAssertEqual(BackendFilesystemIgnore.compile("!keep.txt")?.negated, true)
        XCTAssertEqual(BackendFilesystemIgnore.compile("build/")?.directoryOnly, true)
        XCTAssertEqual(BackendFilesystemIgnore.compile("build")?.directoryOnly, false)
    }
    func testLeadingEscapeIsLiteral() {
        let rule = BackendFilesystemIgnore.compile("\\#notes.md")
        XCTAssertEqual(rule?.negated, false)
        XCTAssertEqual(rule?.matches("#notes.md", directory: false), true)
    }
    func testUnescapedTrailingWhitespaceIgnored() {
        XCTAssertEqual(BackendFilesystemIgnore.compile("dist   ")?.matches("dist", directory: false), true)
    }

    // MARK: ignore matcher
    func testBareNameMatchesAtAnyDepth() {
        let ignores = matcher("dist")
        XCTAssertTrue(ignores.ignored("dist", directory: true))
        XCTAssertTrue(ignores.ignored("src/dist", directory: true))
        XCTAssertTrue(ignores.ignored("src/dist/bundle.js", directory: false))
        XCTAssertFalse(ignores.ignored("mydist", directory: true))
        XCTAssertFalse(ignores.ignored("src/distant.ts", directory: false))
    }
    func testSlashPatternIsAnchored() {
        let ignores = matcher("/build")
        XCTAssertTrue(ignores.ignored("build", directory: true))
        XCTAssertFalse(ignores.ignored("src/build", directory: true))
    }
    func testDirectoryOnlyRulesOnlyHitDirectories() {
        let ignores = matcher("cache/")
        XCTAssertTrue(ignores.ignored("cache", directory: true))
        XCTAssertFalse(ignores.ignored("cache", directory: false))
    }
    func testLastMatchingRuleWins() {
        let ignores = matcher("*.log", "!keep.log")
        XCTAssertTrue(ignores.ignored("debug.log", directory: false))
        XCTAssertFalse(ignores.ignored("keep.log", directory: false))
    }
    func testCannotReincludeInsideIgnoredDirectory() {
        XCTAssertTrue(matcher("secrets/", "!secrets/public.txt").ignored("secrets/public.txt", directory: false))
    }
    func testSingleStarStaysInSegmentAndGlobstarCrosses() {
        XCTAssertFalse(matcher("src/*.ts").ignored("src/a/b.ts", directory: false))
        XCTAssertTrue(matcher("src/**/*.ts").ignored("src/a/b.ts", directory: false))
        XCTAssertTrue(matcher("a/**/b").ignored("a/b", directory: false))
    }
    func testQuestionMarkAndClassesDoNotCrossSeparators() {
        XCTAssertTrue(matcher("log?.txt").ignored("log1.txt", directory: false))
        XCTAssertFalse(matcher("log?.txt").ignored("log12.txt", directory: false))
        XCTAssertTrue(matcher("[abc].md").ignored("b.md", directory: false))
        XCTAssertFalse(matcher("[!abc].md").ignored("b.md", directory: false))
        XCTAssertTrue(matcher("[!abc].md").ignored("z.md", directory: false))
    }
    func testNodeModulesAndGitAlwaysHidden() {
        let ignores = matcher("!node_modules", "!.git")
        XCTAssertTrue(ignores.ignored("node_modules", directory: true))
        XCTAssertTrue(ignores.ignored("packages/app/node_modules/react/index.js", directory: false))
        XCTAssertTrue(ignores.ignored(".git/HEAD", directory: false))
    }
    func testNoRulesIgnoreNothing() {
        let ignores = BackendFilesystemIgnore(texts: [""])
        XCTAssertFalse(ignores.ignored("src/index.ts", directory: false))
        XCTAssertFalse(ignores.ignored("", directory: false))
    }

    // MARK: git check-ignore table
    func testAgreesWithGitCheckIgnore() {
        let rules = ["dist", "/build", "cache/", "*.log", "!keep.log", "secrets/", "!secrets/public.txt", "src/*.ts", "src/**/*.tsx",
                     "a/**/b", "log?.txt", "[abc].md", "**/tmp", "docs/frotz", "foo/", "\\#hash.md", "sp ace.txt", "*.o", "!vital.o", "deep/**", "x/y/**/z"].joined(separator: "\n")
        let cases: [(String, Bool, Bool)] = [
            ("dist/x.js", false, true), ("src/dist/x.js", false, true), ("mydist/x.js", false, false), ("build/x.js", false, true),
            ("src/build/x.js", false, false), ("cache", true, true), ("nested/cache/f.js", false, true), ("debug.log", false, true),
            ("keep.log", false, false), ("sub/keep.log", false, false), ("secrets/public.txt", false, true), ("secrets/other.txt", false, true),
            ("src/a.ts", false, true), ("src/x/b.ts", false, false), ("src/x/b.tsx", false, true), ("a/b", false, true), ("a/x/y/b", false, true),
            ("log1.txt", false, true), ("log12.txt", false, false), ("b.md", false, true), ("z.md", false, false), ("tmp/f", false, true),
            ("q/tmp/f", false, true), ("docs/frotz/f", false, true), ("q/docs/frotz/f", false, false), ("foo/f", false, true), ("q/foo/f", false, true),
            ("#hash.md", false, true), ("sp ace.txt", false, true), ("o1.o", false, true), ("vital.o", false, false), ("deep/a/b/c", false, true),
            ("x/y/p/q/z", false, true), ("x/y/z", false, true)]
        let ignores = BackendFilesystemIgnore(texts: [rules])
        for (path, directory, expected) in cases {
            XCTAssertEqual(ignores.ignored(path, directory: directory), expected, "\(path) isDir=\(directory)")
        }
    }

    // MARK: traversal guard
    func testWithinRootAcceptsRootAndDescendantsOnly() {
        let root = URL(fileURLWithPath: "/projects/terminaldeck")
        XCTAssertTrue(BackendFilesystemAuthority.within(root, root))
        XCTAssertTrue(BackendFilesystemAuthority.within(URL(fileURLWithPath: "/projects/terminaldeck/src/main/index.ts"), root))
        XCTAssertFalse(BackendFilesystemAuthority.within(URL(fileURLWithPath: "/projects/terminaldeck-other"), root))
        XCTAssertFalse(BackendFilesystemAuthority.within(URL(fileURLWithPath: "/projects"), root))
        XCTAssertFalse(BackendFilesystemAuthority.within(URL(fileURLWithPath: "/"), root))
    }
    func testResolveJoinsOrdinaryRelativePaths() async throws {
        let (fx, _) = try rig(); let root = fx.root.resolvingSymlinksInPath()
        try fx.write("src/App.tsx", "x"); try fx.write("src/main/index.ts", "x")
        let auth = fx.authority
        let a = try await auth.resolve(root: fx.root.path, relative: "src/main/index.ts", context: fx.context)
        XCTAssertEqual(a.path.path, root.appendingPathComponent("src/main/index.ts").path)
        let b = try await auth.resolve(root: fx.root.path, relative: "", context: fx.context)
        XCTAssertEqual(b.path.path, root.path)
        let c = try await auth.resolve(root: fx.root.path, relative: "src/../src/App.tsx", context: fx.context)
        XCTAssertEqual(c.path.path, root.appendingPathComponent("src/App.tsx").path)
    }
    func testResolveRefusesClimbingAbsoluteAndNullByte() async throws {
        let (fx, _) = try rig(); try fx.mkdir("src")
        for relative in ["../secrets.txt", "src/../../../etc/passwd", "/etc/passwd", "src/index.ts\0.png"] {
            do { _ = try await fx.authority.resolve(root: fx.root.path, relative: relative, context: fx.context); XCTFail("accepted \(relative)") } catch {}
        }
        do { _ = try await fx.authority.resolve(root: fx.root.path, relative: "../secrets.txt", context: fx.context) }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "path-escape") }
    }

    // MARK: text helpers through read
    func testReadCountsLinesLikeAnEditor() async throws {
        let (fx, service) = try rig()
        let samples: [(String, Double)] = [("", 0), ("one", 1), ("one\n", 1), ("one\ntwo", 2), ("one\ntwo\n", 2), ("\n", 1)]
        for (index, sample) in samples.enumerated() {
            try fx.write("f\(index).txt", sample.0)
            let read = try await service.read(root: fx.root.path, relative: "f\(index).txt", context: fx.context)
            XCTAssertEqual(read["lines"].number, sample.1, "sample \(index)")
        }
    }
    func testReadCallsBufferBinaryOnlyWithNul() async throws {
        let (fx, service) = try rig()
        try fx.write("plain.txt", "plain text\n")
        try Data([0x89, 0x50, 0x00, 0x4e]).write(to: fx.file("img.png"))
        let plain = try await service.read(root: fx.root.path, relative: "plain.txt", context: fx.context)
        let binary = try await service.read(root: fx.root.path, relative: "img.png", context: fx.context)
        XCTAssertEqual(plain["kind"].string, "text"); XCTAssertEqual(binary["kind"].string, "binary")
    }

    // MARK: listDirectory
    private func listingRig() throws -> (BackendFoundationTestsBFixture, BackendFilesystemService) {
        let (fx, service) = try rig("s6c3list")
        try fx.mkdir("src"); try fx.mkdir("node_modules/react"); try fx.mkdir("dist")
        try fx.write(".gitignore", "dist/\n*.log\n!keep.log\n")
        try fx.write("file10.txt", "ten\n"); try fx.write("file2.txt", "two\n"); try fx.write("debug.log", "noise\n"); try fx.write("keep.log", "wanted\n")
        try FileManager.default.createSymbolicLink(at: fx.file("self-loop"), withDestinationURL: fx.file("src"))
        try FileManager.default.createSymbolicLink(at: fx.file("escape"), withDestinationURL: FileManager.default.temporaryDirectory)
        return (fx, service)
    }
    func testSortsDirectoriesFirstAndNamesNaturally() async throws {
        let (fx, service) = try listingRig()
        let n = names(try await service.list(root: fx.root.path, context: fx.context))
        XCTAssertLessThan(n.firstIndex(of: "src")!, n.firstIndex(of: "file2.txt")!)
        XCTAssertLessThan(n.firstIndex(of: "file2.txt")!, n.firstIndex(of: "file10.txt")!)
    }
    func testHonoursGitignoreAndAlwaysHidesNodeModules() async throws {
        let (fx, service) = try listingRig()
        let n = names(try await service.list(root: fx.root.path, context: fx.context))
        for hidden in ["dist", "debug.log", "node_modules"] { XCTAssertFalse(n.contains(hidden), hidden) }
        XCTAssertTrue(n.contains("keep.log"))
    }
    func testShowIgnoredStillHidesNodeModules() async throws {
        let (fx, service) = try listingRig()
        let n = names(try await service.list(root: fx.root.path, options: .init(showIgnored: true), context: fx.context))
        XCTAssertTrue(n.contains("dist")); XCTAssertTrue(n.contains("debug.log")); XCTAssertFalse(n.contains("node_modules"))
    }
    func testBlocksEscapingSymlinksButNotSiblingTargets() async throws {
        let (fx, service) = try listingRig()
        let entries = try await service.list(root: fx.root.path, context: fx.context)["entries"].elements ?? []
        XCTAssertEqual(entries.first { $0["name"].string == "escape" }?["blocked"].bool, true)
        XCTAssertEqual(entries.first { $0["name"].string == "self-loop" }?["blocked"].bool, false)
    }
    func testRefusesDirectoryOutsideRoot() async throws {
        let (fx, service) = try listingRig()
        let code = await errorCode { try await service.list(root: fx.root.path, relative: "../..", context: fx.context) }
        XCTAssertEqual(code, "path-escape")
    }
    func testReadsFileBackWithLineCount() async throws {
        let (fx, service) = try listingRig()
        let read = try await service.read(root: fx.root.path, relative: "file2.txt", context: fx.context)
        XCTAssertEqual(read["kind"].string, "text"); XCTAssertEqual(read["text"].string, "two\n"); XCTAssertEqual(read["lines"].number, 1)
    }
    func testRefusesFileThroughEscapingSymlink() async throws {
        let (fx, service) = try listingRig()
        let code = await errorCode { try await service.read(root: fx.root.path, relative: "escape/anything", context: fx.context) }
        XCTAssertNotNil(code)
    }

    // MARK: edges
    func testEmptyDirectoryListsEmpty() async throws {
        let (fx, service) = try rig("s6c3edge"); try fx.mkdir("empty")
        let listing = try await service.list(root: fx.root.path, relative: "empty", context: fx.context)
        XCTAssertEqual(listing["relPath"].string, "empty"); XCTAssertEqual(listing["entries"].elements?.count, 0); XCTAssertEqual(listing["truncated"].bool, false)
    }
    func testMissingDirectoryRejects() async throws {
        let (fx, service) = try rig("s6c3edge")
        let code = await errorCode { try await service.list(root: fx.root.path, relative: "no-such-dir", context: fx.context) }
        XCTAssertNotNil(code)
    }
    func testDirectoryAsFileRefused() async throws {
        let (fx, service) = try rig("s6c3edge"); try fx.mkdir("adir")
        do { _ = try await service.read(root: fx.root.path, relative: "adir", context: fx.context); XCTFail("read a directory") }
        catch { XCTAssertTrue(error.localizedDescription.contains("readable file"), error.localizedDescription) }
    }
    /// The read half (never block on a FIFO) is BLOCKED: openStable opens without O_NONBLOCK. See NIGHT-REQUESTS.
    func testFifoIsListedAsBlockedFile() async throws {
        let (fx, service) = try rig("s6c3fifo")
        XCTAssertEqual(mkfifo(fx.file("pipe").path, 0o600), 0)
        let entries = try await service.list(root: fx.root.path, context: fx.context)["entries"].elements ?? []
        let pipe = entries.first { $0["name"].string == "pipe" }
        XCTAssertEqual(pipe?["kind"].string, "file"); XCTAssertEqual(pipe?["blocked"].bool, true)
    }
    func testSymlinkHopsOutOfRootAreBlocked() async throws {
        let (fx, service) = try rig("s6c3hop")
        try FileManager.default.createSymbolicLink(at: fx.file("hop1"), withDestinationURL: FileManager.default.temporaryDirectory)
        try FileManager.default.createSymbolicLink(at: fx.file("hop2"), withDestinationURL: fx.file("hop1"))
        let entries = try await service.list(root: fx.root.path, context: fx.context)["entries"].elements ?? []
        XCTAssertEqual(entries.first { $0["name"].string == "hop1" }?["blocked"].bool, true)
        XCTAssertEqual(entries.first { $0["name"].string == "hop2" }?["blocked"].bool, true)
    }
    func testTruncatesOnlyPastMaxEntries() async throws {
        let (fx, service) = try rig("s6c3big"); try fx.mkdir("big")
        for index in 0...2000 { try Data("x".utf8).write(to: fx.file("big/f" + String(format: "%05d", index) + ".txt")) }
        let over = try await service.list(root: fx.root.path, relative: "big", context: fx.context)
        XCTAssertEqual(over["truncated"].bool, true); XCTAssertEqual(over["entries"].elements?.count, 2000)
        try FileManager.default.removeItem(at: fx.file("big/f02000.txt"))
        let exact = try await service.list(root: fx.root.path, relative: "big", context: fx.context)
        XCTAssertEqual(exact["truncated"].bool, false); XCTAssertEqual(exact["entries"].elements?.count, 2000)
    }
    func testRefusesOverLimitFileButReadsExactlyAtLimit() async throws {
        let (fx, service) = try rig("s6c3limit"); let limit = 2 * 1024 * 1024
        try Data(repeating: 0x61, count: limit + 1).write(to: fx.file("over.txt"))
        let over = try await service.read(root: fx.root.path, relative: "over.txt", context: fx.context)
        XCTAssertEqual(over["kind"].string, "too-large"); XCTAssertEqual(over["bytes"].number, Double(limit + 1)); XCTAssertEqual(over["limit"].number, Double(limit))
        try Data(repeating: 0x61, count: limit).write(to: fx.file("edge.txt"))
        let edge = try await service.read(root: fx.root.path, relative: "edge.txt", context: fx.context)
        XCTAssertEqual(edge["kind"].string, "text")
    }
    func testEditedGitignoreIsNotServedStale() async throws {
        let (fx, service) = try rig("s6c3stale"); try fx.mkdir("cached/target")
        try fx.write("cached/.gitignore", "target/\n")
        // TS fs-tree.test.ts:389 lists `cached` as the root: only root-level ignore files are consulted (fs-tree.ts:321).
        let before = names(try await service.list(root: fx.file("cached").path, context: fx.context))
        XCTAssertFalse(before.contains("target"))
        try fx.write("cached/.gitignore", "# target is welcome again now\n")
        let after = names(try await service.list(root: fx.file("cached").path, context: fx.context))
        XCTAssertTrue(after.contains("target"))
    }

    // MARK: pickDefaultFile / withStats (through list defaultFile)
    private func stamped(_ fx: BackendFoundationTestsBFixture, _ name: String, _ seconds: TimeInterval) throws {
        try fx.write(name, "x")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: fx.file(name).path)
    }
    private func defaultFile(_ fx: BackendFoundationTestsBFixture, _ service: BackendFilesystemService) async throws -> NativeRPCValue {
        try await service.list(root: fx.root.path, options: .init(withStats: true), context: fx.context)["defaultFile"]
    }
    func testDefaultLeadsWithReadmeWhateverItsExtension() async throws {
        let (fx, service) = try rig("s6c3pick1")
        try stamped(fx, "zebra.ts", 9_000); try stamped(fx, "README.md", 1_000); try stamped(fx, "index.ts", 8_000)
        let picked = try await defaultFile(fx, service); XCTAssertEqual(picked.string, "README.md")
    }
    func testDefaultTakesExtensionlessReadme() async throws {
        let (fx, service) = try rig("s6c3pick2"); try stamped(fx, "src.ts", 9_000); try stamped(fx, "README", 1)
        let picked = try await defaultFile(fx, service); XCTAssertEqual(picked.string, "README")
    }
    func testDefaultIgnoresFilesThatMerelyStartWithReadme() async throws {
        let (fx, service) = try rig("s6c3pick3"); try stamped(fx, "readme-generator.js", 5_000); try stamped(fx, "index.ts", 1_000)
        let picked = try await defaultFile(fx, service); XCTAssertEqual(picked.string, "index.ts")
    }
    func testDefaultFallsBackToNewestFile() async throws {
        let (fx, service) = try rig("s6c3pick4")
        try stamped(fx, "old.txt", 1_000); try stamped(fx, "newest.txt", 9_000); try stamped(fx, "middle.txt", 5_000)
        let picked = try await defaultFile(fx, service); XCTAssertEqual(picked.string, "newest.txt")
    }
    func testDefaultNeverOpensDirectory() async throws {
        let (fx, service) = try rig("s6c3pick5"); try fx.mkdir("src"); try stamped(fx, "a.txt", 1_000)
        let picked = try await defaultFile(fx, service); XCTAssertEqual(picked.string, "a.txt")
    }
    func testDefaultNeverOpensBlockedEntry() async throws {
        let (fx, service) = try rig("s6c3pick6")
        try FileManager.default.createSymbolicLink(at: fx.file("link.txt"), withDestinationURL: FileManager.default.temporaryDirectory)
        try stamped(fx, "real.txt", 1_000)
        let picked = try await defaultFile(fx, service); XCTAssertEqual(picked.string, "real.txt")
    }
    func testDefaultNullForDirectoriesOnlyRoot() async throws {
        let (fx, service) = try rig("s6c3pick7"); try fx.mkdir("src")
        let picked = try await defaultFile(fx, service); XCTAssertEqual(picked, .null)
    }
    func testStatsAreOffByDefault() async throws {
        let (fx, service) = try rig("s6c3stats"); try fx.write("README.md", "# hello\n"); try fx.mkdir("src")
        let listing = try await service.list(root: fx.root.path, context: fx.context)
        for entry in listing["entries"].elements ?? [] {
            XCTAssertFalse(entry.has("modifiedAt")); XCTAssertFalse(entry.has("bytes"))
        }
    }
    func testStatsFilledInWhenAskedAndDefaultFileNamed() async throws {
        let (fx, service) = try rig("s6c3stats2"); try fx.write("README.md", "# hello\n"); try fx.mkdir("src")
        let listing = try await service.list(root: fx.root.path, options: .init(withStats: true), context: fx.context)
        let entries = listing["entries"].elements ?? []
        let readme = entries.first { $0["name"].string == "README.md" }, src = entries.first { $0["name"].string == "src" }
        XCTAssertEqual(readme?["bytes"].number, 8); XCTAssertGreaterThan(readme?["modifiedAt"].number ?? 0, 0); XCTAssertGreaterThan(src?["modifiedAt"].number ?? 0, 0)
        XCTAssertEqual(listing["defaultFile"].string, "README.md")
        let plain = try await service.list(root: fx.root.path, context: fx.context)
        XCTAssertFalse(plain.has("defaultFile"))
    }
}
