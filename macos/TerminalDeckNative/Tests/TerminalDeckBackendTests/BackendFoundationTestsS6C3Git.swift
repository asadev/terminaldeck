import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ports src/main/git.test.ts.
/// Skipped: backslash-as-separator repoRelative case (Windows-only);
/// dubiousOwnershipMessage "names the folder in the command" (Swift deliberately
/// never writes global safe.directory and words the fix without the path);
/// activeGitWatchCount/stopAllGitWatches/registerGitIpc channel plumbing is
/// covered through BackendFileWatchService.count.
/// Deviation noted: a relative cwd throws invalid-arguments in Swift where TS
/// returned { repo: false, reason: "no-such-folder" }.
private final class S6C3GitFake: BackendGitExecuting, @unchecked Sendable {
    private let lock = NSLock(); private var seen: [[String]] = []
    private let handler: @Sendable ([String]) -> BackendGitOutcome
    init(_ handler: @escaping @Sendable ([String]) -> BackendGitOutcome) { self.handler = handler }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return seen }
    func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        lock.withLock { seen.append(arguments) }
        return handler(arguments)
    }
}
private func S6C3GitOutcome(_ stdout: String = "", stderr: String = "", ok: Bool = true, code: Int = 0) -> BackendGitOutcome {
    BackendGitOutcome(ok: ok, stdout: stdout, stderr: stderr, missing: false, exitCode: code, timedOut: false)
}
/// Join records the way `-z` does: every record NUL-terminated.
private func S6C3GitZ(_ records: String...) -> String { records.map { $0 + "\0" }.joined() }
private let S6C3GitHeaders = ["# branch.oid 1a2b3c4d5e6f7a8b", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1"]

final class BackendFoundationTestsS6C3GitTests: XCTestCase {
    private func parse(_ extra: [String], headers: [String] = S6C3GitHeaders) -> BackendGitService.Parsed {
        BackendGitService.parsePorcelain((headers + extra).map { $0 + "\0" }.joined())
    }
    private func paths(_ files: [NativeRPCValue]) -> [String?] { files.map { $0["path"].string } }

    // MARK: parsePorcelainV2 branch header
    func testBranchHeaderReadsNameOidUpstreamAheadBehind() {
        let b = BackendGitService.parsePorcelain(S6C3GitZ(S6C3GitHeaders[0], S6C3GitHeaders[1], S6C3GitHeaders[2], S6C3GitHeaders[3])).branch
        XCTAssertEqual(b["name"].string, "main"); XCTAssertEqual(b["detached"].bool, false); XCTAssertEqual(b["oid"].string, "1a2b3c4d5e6f7a8b")
        XCTAssertEqual(b["upstream"].string, "origin/main"); XCTAssertEqual(b["ahead"].number, 2); XCTAssertEqual(b["behind"].number, 1)
    }
    func testDetachedHeadHasNoBranchName() {
        let b = BackendGitService.parsePorcelain(S6C3GitZ("# branch.oid 1a2b3c4d", "# branch.head (detached)")).branch
        XCTAssertEqual(b["detached"].bool, true); XCTAssertEqual(b["name"], .null)
    }
    func testUnbornBranchHasNoCommit() {
        let b = BackendGitService.parsePorcelain(S6C3GitZ("# branch.oid (initial)", "# branch.head main")).branch
        XCTAssertEqual(b["oid"], .null); XCTAssertEqual(b["name"].string, "main")
    }
    func testNoUpstreamLeavesAheadBehindZero() {
        let b = BackendGitService.parsePorcelain(S6C3GitZ("# branch.oid abc123", "# branch.head main")).branch
        XCTAssertEqual(b["upstream"], .null); XCTAssertEqual(b["ahead"].number, 0); XCTAssertEqual(b["behind"].number, 0)
    }

    // MARK: parsePorcelainV2 entries
    func testSplitsStagedAddFromUnstagedDelete() {
        let p = parse(["1 A. N... 000000 100644 100644 0000000000 aaaaaaaaaa src/new.ts", "1 .D N... 100644 100644 000000 bbbbbbbbbb bbbbbbbbbb src/gone.ts"])
        XCTAssertEqual(paths(p.staged), ["src/new.ts"]); XCTAssertEqual(p.staged[0]["code"].string, "A"); XCTAssertEqual(p.staged[0]["kind"].string, "added")
        XCTAssertEqual(paths(p.unstaged), ["src/gone.ts"]); XCTAssertEqual(p.unstaged[0]["code"].string, "D"); XCTAssertEqual(p.unstaged[0]["kind"].string, "deleted")
    }
    func testStagedAndDirtyFileAppearsInBothGroups() {
        let p = parse(["1 MM N... 100644 100644 100644 cccccccccc dddddddddd src/app.ts"])
        XCTAssertEqual(p.staged.count, 1); XCTAssertEqual(p.unstaged.count, 1)
        XCTAssertEqual(p.staged[0]["path"].string, "src/app.ts"); XCTAssertEqual(p.unstaged[0]["path"].string, "src/app.ts")
        XCTAssertEqual(p.staged[0]["group"].string, "staged"); XCTAssertEqual(p.unstaged[0]["group"].string, "unstaged")
    }
    func testRenameKeepsScoreAndOriginalPath() {
        let p = parse(["2 R. N... 100644 100644 100644 eeeeeeeeee eeeeeeeeee R100 src/new-name.ts", "src/old-name.ts"])
        XCTAssertEqual(p.staged.count, 1); XCTAssertEqual(p.unstaged.count, 0)
        let f = p.staged[0]
        XCTAssertEqual(f["path"].string, "src/new-name.ts"); XCTAssertEqual(f["origPath"].string, "src/old-name.ts")
        XCTAssertEqual(f["code"].string, "R"); XCTAssertEqual(f["kind"].string, "renamed"); XCTAssertEqual(f["score"].number, 100)
    }
    func testRenameOriginalPathDoesNotLeakIntoNextEntry() {
        let p = parse(["2 R. N... 100644 100644 100644 eeeeeeeeee eeeeeeeeee R98 b.ts", "a.ts", "? untracked.md"])
        XCTAssertEqual(p.staged.count, 1); XCTAssertEqual(paths(p.untracked), ["untracked.md"])
    }
    func testWorkingTreeHalfOfRenameIsPlainModification() {
        let p = parse(["2 RM N... 100644 100644 100644 ffffffffff ffffffffff R87 lib/b.ts", "lib/a.ts"])
        XCTAssertEqual(p.staged[0]["code"].string, "R"); XCTAssertEqual(p.staged[0]["origPath"].string, "lib/a.ts"); XCTAssertEqual(p.staged[0]["score"].number, 87)
        XCTAssertEqual(p.unstaged[0]["code"].string, "M"); XCTAssertEqual(p.unstaged[0]["kind"].string, "modified"); XCTAssertEqual(p.unstaged[0]["origPath"], .null)
    }
    func testCopyIsItsOwnKind() {
        let p = parse(["2 C. N... 100644 100644 100644 aaaa bbbb C75 dup.ts", "orig.ts"])
        XCTAssertEqual(p.staged[0]["kind"].string, "copied"); XCTAssertEqual(p.staged[0]["score"].number, 75); XCTAssertEqual(p.staged[0]["origPath"].string, "orig.ts")
    }
    func testUntrackedCollectedIgnoredSkipped() {
        let p = parse(["? notes.md", "? build/", "! dist/"])
        XCTAssertEqual(paths(p.untracked), ["notes.md", "build/"])
        XCTAssertEqual(p.untracked[0]["code"].string, "?"); XCTAssertEqual(p.untracked[0]["kind"].string, "untracked"); XCTAssertEqual(p.untracked[0]["group"].string, "untracked")
    }
    func testUnmergedKeepsBothLetters() {
        let p = parse(["u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/conflict.ts", "u DU N... 100644 100644 100644 100644 aaaa bbbb cccc src/theirs.ts"])
        XCTAssertEqual(paths(p.conflicted), ["src/conflict.ts", "src/theirs.ts"])
        XCTAssertEqual(p.conflicted.map { $0["code"].string }, ["UU", "DU"]); XCTAssertEqual(p.conflicted[0]["kind"].string, "conflicted")
        XCTAssertEqual(p.staged.count, 0); XCTAssertEqual(p.unstaged.count, 0)
    }
    func testSpacesInPathsStayIntact() {
        let p = parse(["1 .M N... 100644 100644 100644 aaaa bbbb docs/my notes.md"])
        XCTAssertEqual(p.unstaged[0]["path"].string, "docs/my notes.md")
    }
    func testCleanRepoHasEmptyGroups() {
        let p = parse([])
        XCTAssertTrue(p.staged.isEmpty && p.unstaged.isEmpty && p.untracked.isEmpty && p.conflicted.isEmpty)
    }
    func testEmptyOutputSurvives() {
        let p = BackendGitService.parsePorcelain("")
        XCTAssertEqual(p.branch["name"], .null); XCTAssertTrue(p.staged.isEmpty)
    }

    // MARK: parseNumstat (Swift returns a dictionary keyed by the new path)
    func testNumstatReadsCounts() {
        let r = BackendGitService.parseNumstat(S6C3GitZ("12\t3\tsrc/app.ts", "0\t9\tsrc/old.ts"))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r["src/app.ts"]?["insertions"].number, 12); XCTAssertEqual(r["src/app.ts"]?["deletions"].number, 3); XCTAssertEqual(r["src/app.ts"]?["binary"].bool, false); XCTAssertEqual(r["src/app.ts"]?["origPath"], .null)
        XCTAssertEqual(r["src/old.ts"]?["insertions"].number, 0); XCTAssertEqual(r["src/old.ts"]?["deletions"].number, 9)
    }
    func testNumstatRenamePathsArriveAsTwoExtraRecords() {
        let r = BackendGitService.parseNumstat(S6C3GitZ("4\t2\t", "src/old.ts", "src/new.ts", "1\t1\tother.ts"))
        XCTAssertEqual(Set(r.keys), ["src/new.ts", "other.ts"])
        XCTAssertEqual(r["src/new.ts"]?["origPath"].string, "src/old.ts"); XCTAssertEqual(r["src/new.ts"]?["insertions"].number, 4); XCTAssertEqual(r["src/new.ts"]?["deletions"].number, 2)
        XCTAssertEqual(r["other.ts"]?["origPath"], .null)
    }
    func testNumstatFlagsBinary() {
        let r = BackendGitService.parseNumstat(S6C3GitZ("-\t-\tassets/logo.png"))
        XCTAssertEqual(r["assets/logo.png"]?["binary"].bool, true); XCTAssertEqual(r["assets/logo.png"]?["insertions"].number, 0); XCTAssertEqual(r["assets/logo.png"]?["deletions"].number, 0)
    }
    func testNumstatEmptyOutput() { XCTAssertTrue(BackendGitService.parseNumstat("").isEmpty) }

    // MARK: applyStats, through status() with a fake runner
    private func statusRig(porcelain: String, work: String = "", cached: String = "") throws -> (BackendFoundationTestsBFixture, BackendGitService) {
        let fx = try BackendFoundationTestsBFixture("s6c3status"); let root = fx.root.resolvingSymlinksInPath().path
        let fake = S6C3GitFake { args in
            if args.first == "rev-parse" { return S6C3GitOutcome(root + "\n") }
            if args.first == "status" { return S6C3GitOutcome(porcelain) }
            if args.contains("--cached") { return S6C3GitOutcome(cached) }
            return S6C3GitOutcome(work)
        }
        return (fx, BackendGitService(authority: fx.authority, runner: fake))
    }
    func testApplyStatsFoldsCountsOntoMatchingEntriesOnly() async throws {
        let porcelain = S6C3GitZ(S6C3GitHeaders[0], S6C3GitHeaders[1], "1 .M N... 100644 100644 100644 aaaa bbbb src/app.ts", "1 .M N... 100644 100644 100644 cccc dddd src/untouched.ts")
        let (fx, service) = try statusRig(porcelain: porcelain, work: S6C3GitZ("12\t3\tsrc/app.ts"))
        let result = try await service.status(cwd: fx.root.path, context: fx.context)
        let rows = result["unstaged"].elements ?? []
        XCTAssertEqual(rows[0]["insertions"].number, 12); XCTAssertEqual(rows[0]["deletions"].number, 3); XCTAssertEqual(rows[0]["binary"].bool, false)
        XCTAssertEqual(rows[1]["insertions"], .null); XCTAssertEqual(rows[1]["deletions"], .null)
    }
    func testApplyStatsMatchesRenameOnNewPath() async throws {
        let porcelain = S6C3GitZ(S6C3GitHeaders[0], "2 R. N... 100644 100644 100644 aaaa bbbb R100 src/new.ts", "src/old.ts")
        let (fx, service) = try statusRig(porcelain: porcelain, cached: S6C3GitZ("4\t2\t", "src/old.ts", "src/new.ts"))
        let result = try await service.status(cwd: fx.root.path, context: fx.context)
        let row = (result["staged"].elements ?? [])[0]
        XCTAssertEqual(row["insertions"].number, 4); XCTAssertEqual(row["deletions"].number, 2)
        XCTAssertEqual(result["clean"].bool, false)
    }

    // MARK: failure wording (fake runner)
    func testDubiousOwnershipDoesNotTellYouToInit() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3dubious")
        let fake = S6C3GitFake { _ in S6C3GitOutcome(stderr: "fatal: detected dubious ownership in repository at '/x'", ok: false, code: 128) }
        let result = try await BackendGitService(authority: fx.authority, runner: fake).status(cwd: fx.root.path, context: fx.context)
        XCTAssertEqual(result["repo"].bool, false); XCTAssertEqual(result["reason"].string, "not-a-repo")
        let message = result["message"].string ?? ""
        XCTAssertFalse(message.contains("git init")); XCTAssertNotEqual(message, "This folder is not a git repository. Source control can create one.")
        XCTAssertFalse(result.has("canInit"))
    }
    func testNotARepoSaysItInASentenceNotGitStderr() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3notrepo")
        let fake = S6C3GitFake { _ in S6C3GitOutcome(stderr: "fatal: not a git repository (or any of the parent directories): .git", ok: false, code: 128) }
        let result = try await BackendGitService(authority: fx.authority, runner: fake).status(cwd: fx.root.path, context: fx.context)
        let message = result["message"].string ?? ""
        XCTAssertEqual(message, "This folder is not a git repository. Source control can create one.")
        XCTAssertFalse(message.contains("fatal:")); XCTAssertFalse(message.contains(".git")); XCTAssertTrue(message.contains("Source control")); XCTAssertTrue(message.hasSuffix("."))
        XCTAssertEqual(result["canInit"].bool, true)
    }
    func testMissingGitReportsGitMissing() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3missing")
        let fake = S6C3GitFake { _ in BackendGitOutcome(ok: false, stdout: "", stderr: "x", missing: true, exitCode: 127, timedOut: false) }
        let result = try await BackendGitService(authority: fx.authority, runner: fake).status(cwd: fx.root.path, context: fx.context)
        XCTAssertEqual(result["reason"].string, "git-missing"); XCTAssertEqual(result["message"].string, "git is not installed, or not on the login PATH")
    }
    func testNonexistentFolderReportsNoSuchFolder() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3nofolder")
        let result = try await BackendGitService(authority: fx.authority, runner: S6C3GitFake { _ in S6C3GitOutcome() })
            .status(cwd: fx.root.path + "/terminaldeck-does-not-exist-9f3a", context: fx.context)
        XCTAssertEqual(result["repo"].bool, false); XCTAssertEqual(result["reason"].string, "no-such-folder")
    }
    func testRelativePathIsRefusedNotResolvedAgainstCwd() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3relative")
        let service = BackendGitService(authority: fx.authority, runner: S6C3GitFake { _ in S6C3GitOutcome() })
        do {
            let result = try await service.status(cwd: "src", context: fx.context)
            XCTAssertEqual(result["repo"].bool, false); XCTAssertEqual(result["reason"].string, "no-such-folder")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
    }

    // MARK: repoRelative, through diff() argument confinement
    private func diffRig() throws -> (BackendFoundationTestsBFixture, S6C3GitFake, BackendGitService) {
        let fx = try BackendFoundationTestsBFixture("s6c3diff"); let root = fx.root.resolvingSymlinksInPath().path
        let fake = S6C3GitFake { args in args.first == "rev-parse" ? S6C3GitOutcome(root + "\n") : S6C3GitOutcome("DIFF") }
        return (fx, fake, BackendGitService(authority: fx.authority, runner: fake))
    }
    func testDiffPassesThroughGitReportedPathsAndNormalisesInnerWalks() async throws {
        let (fx, fake, service) = try diffRig()
        for (input, expected) in [("src/app.ts", "src/app.ts"), ("docs/my notes.md", "docs/my notes.md"), ("src/../lib/x.ts", "lib/x.ts")] {
            let out = try await service.diff(cwd: fx.root.path, path: input, context: fx.context)
            XCTAssertEqual(out, "DIFF"); XCTAssertEqual(Array(fake.calls.last?.suffix(2) ?? []), ["--", expected], input)
        }
    }
    func testDiffRefusesEscapingAbsoluteEmptyNulAndRootPaths() async throws {
        let (fx, fake, service) = try diffRig(); let root = fx.root.resolvingSymlinksInPath().path
        for bad in ["../secret.txt", "../../../../../../etc/passwd", "src/../../etc/passwd", "..", "/etc/passwd", root + "/src/app.ts", "", "a\0b", "."] {
            let out = try await service.diff(cwd: fx.root.path, path: bad, context: fx.context)
            XCTAssertEqual(out, "", bad)
        }
        XCTAssertFalse(fake.calls.contains { $0.first == "diff" })
    }

    // MARK: real git
    private func realService(_ fx: BackendFoundationTestsBFixture) throws -> BackendGitService {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git") || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git"), "git not installed")
        let runner = BackendGitRunner(inheritedEnvironment: ["HOME": fx.root.path], loginPath: { "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" })
        return BackendGitService(authority: fx.authority, runner: runner)
    }
    private func makeRepo(_ fx: BackendFoundationTestsBFixture, _ service: BackendGitService) async throws {
        try fx.write("tracked.txt", "one\n")
        for args in [["init", "-q", "-b", "main", "."], ["add", "-A"], ["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "init"]] {
            let r = try await service.workspaceCommand(cwd: fx.root.path, arguments: args, context: fx.context)
            XCTAssertTrue(r.ok, r.stderr)
        }
    }
    func testRealNonRepoFolderSaysNotARepoInASentence() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3realnone"); let service = try realService(fx)
        let result = try await service.status(cwd: fx.root.path, context: fx.context)
        XCTAssertEqual(result["repo"].bool, false)
        XCTAssertEqual(result["reason"].string, "not-a-repo"); XCTAssertEqual(result["message"].string, "This folder is not a git repository. Source control can create one.")
        XCTAssertEqual(result["canInit"].bool, true)
    }
    func testDiffRefusesPathsEscapingTheRepositoryAgainstRealGit() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3realescape"); let service = try realService(fx); try await makeRepo(fx, service)
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("terminaldeck-secret-\(UUID().uuidString).txt")
        try Data("BEGIN OPENSSH PRIVATE KEY\n".utf8).write(to: secret); defer { try? FileManager.default.removeItem(at: secret) }
        let escape = "../" + secret.lastPathComponent
        let attempts: [(String, BackendGitService.DiffOptions)] = [(escape, .init(untracked: true)), (secret.path, .init(untracked: true)), (escape, .init()), (escape, .init(staged: true))]
        for (path, options) in attempts {
            let out = try await service.diff(cwd: fx.root.path, path: path, options: options, context: fx.context)
            XCTAssertEqual(out, ""); XCTAssertFalse(out.contains("OPENSSH"))
        }
    }
    func testDiffStillWorksForUntrackedUnstagedAndStagedInsideTheRepo() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3realdiff"); let service = try realService(fx); try await makeRepo(fx, service)
        try fx.write("fresh.txt", "brand new\n")
        let untracked = try await service.diff(cwd: fx.root.path, path: "fresh.txt", options: .init(untracked: true), context: fx.context)
        XCTAssertTrue(untracked.contains("brand new"))
        try fx.write("tracked.txt", "one\ntwo\n")
        let work = try await service.diff(cwd: fx.root.path, path: "tracked.txt", context: fx.context)
        XCTAssertTrue(work.contains("+two"))
        _ = try await service.workspaceCommand(cwd: fx.root.path, arguments: ["add", "tracked.txt"], context: fx.context)
        let staged = try await service.diff(cwd: fx.root.path, path: "tracked.txt", options: .init(staged: true), context: fx.context)
        XCTAssertTrue(staged.contains("+two"))
    }

    // MARK: git init
    func testInitCreatesRepositoryAndAnswersWithStatus() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3init"); let service = try realService(fx)
        let before = try await service.status(cwd: fx.root.path, context: fx.context)
        XCTAssertEqual(before["repo"].bool, false)
        let after = try await service.initialize(cwd: fx.root.path, context: fx.context)
        XCTAssertEqual(after["repo"].bool, true); XCTAssertEqual(after["clean"].bool, true)
        XCTAssertEqual(after["staged"].elements?.count, 0); XCTAssertEqual(after["untracked"].elements?.count, 0)
    }
    func testInitRefusesExistingRepositoryRatherThanNesting() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3inittwice"); let service = try realService(fx)
        let first = try await service.initialize(cwd: fx.root.path, context: fx.context)
        XCTAssertEqual(first["repo"].bool, true)
        try fx.write("a.txt", "hello\n")
        let second = try await service.initialize(cwd: fx.root.path, context: fx.context)
        XCTAssertEqual(second["repo"].bool, true)
        XCTAssertTrue((second["untracked"].elements ?? []).contains { $0["path"].string == "a.txt" })
    }
    func testInitSaysNoSuchFolderForMissingFolder() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3initnone")
        let result = try await BackendGitService(authority: fx.authority, runner: S6C3GitFake { _ in S6C3GitOutcome() })
            .initialize(cwd: fx.root.path + "/terminaldeck-not-here-at-all", context: fx.context)
        XCTAssertEqual(result["repo"].bool, false); XCTAssertEqual(result["reason"].string, "no-such-folder")
    }

    // MARK: git watches (ref-counted)
    private func watcher(_ fx: BackendFoundationTestsBFixture) -> BackendFileWatchService {
        let git = BackendGitService(authority: fx.authority, runner: S6C3GitFake { _ in S6C3GitOutcome(stderr: "fatal: not a git repository", ok: false, code: 128) })
        return BackendFileWatchService(files: BackendFilesystemService(authority: fx.authority), git: git, registry: NativeChannelRegistry())
    }
    func testWatchKeepsPollingUntilEveryPanelHasUnwatched() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3watch"); let service = watcher(fx); let owner = fx.context.ownerID
        var count = await service.count; XCTAssertEqual(count, 0)
        _ = try await service.watchGit(cwd: fx.root.path, context: fx.context)
        _ = try await service.watchGit(cwd: fx.root.path, context: fx.context)
        count = await service.count; XCTAssertEqual(count, 1)
        await service.unwatch(cwd: fx.root.path, ownerID: owner)
        count = await service.count; XCTAssertEqual(count, 1)
        await service.unwatch(cwd: fx.root.path, ownerID: owner)
        count = await service.count; XCTAssertEqual(count, 0)
        await service.unwatch(cwd: fx.root.path, ownerID: owner)
        count = await service.count; XCTAssertEqual(count, 0)
        await service.stop()
    }
    func testWatchIgnoresRelativePath() async throws {
        let fx = try BackendFoundationTestsBFixture("s6c3watchrel"); let service = watcher(fx)
        do { let r = try await service.watchGit(cwd: "relative/path", context: fx.context); XCTAssertEqual(r["repo"].bool, false) } catch {}
        let count = await service.count; XCTAssertEqual(count, 0)
        await service.unwatch(cwd: "relative/path", ownerID: fx.context.ownerID)
        await service.stop()
    }
}
