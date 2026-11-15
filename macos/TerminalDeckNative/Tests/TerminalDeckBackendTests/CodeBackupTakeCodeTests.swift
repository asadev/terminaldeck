import Foundation
import XCTest
@testable import TerminalDeckBackend

/// "Switch to this Mac", the code half, on SCRATCH repositories only: a local bare repository stands in for GitHub
/// (its folder is the transport's address), the old Mac's backup references are written there as its Code backup
/// writes them (a keeper whose first parent is his branch commit, a work copy whose first parent is the commit he was
/// on). Nothing is pushed anywhere else; no repository of his is read or changed.
final class CodeBackupTakeCodeTests: XCTestCase {
    var root: URL!
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var bare: URL { root.appendingPathComponent("github.git", isDirectory: true) }
    var air: URL { root.appendingPathComponent("air", isDirectory: true) }
    static let path = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
    static let area = "refs/terminal-deck-backup/MacBook-Air-abcd1234/"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("take-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("gitconfig"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var environment: [String: String] {
        ["HOME": home.path, "XDG_CONFIG_HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path]
    }
    @discardableResult
    func git(_ cwd: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "init.defaultBranch=main",
                             "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"] + args
        var env = environment; env["PATH"] = Self.path
        process.environment = env
        process.currentDirectoryURL = cwd
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func write(_ folder: URL, _ name: String, _ text: String) throws {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func read(_ folder: URL, _ name: String) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// GitHub has `main` at c1. The old Mac committed c2 on top (backed up as a keeper, not on GitHub's branch) and has
    /// uncommitted work (backed up as a work copy). Answers (keeper, work, c2).
    func oldMacBackedUp(tracked extraTracked: String? = nil, unsaved extraUnsaved: String? = nil) throws -> (keeper: String, work: String, tip: String) {
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try git(bare, ["init", "-q", "--bare"])
        try FileManager.default.createDirectory(at: air, withIntermediateDirectories: true)
        try git(air, ["init", "-q"])
        try write(air, "a.txt", "one\n"); try git(air, ["add", "-A"]); try git(air, ["commit", "-q", "-m", "c1"])
        try git(air, ["push", "-q", bare.path, "main:refs/heads/main"])
        try write(air, "c.txt", "two\n")
        if let extraTracked { try write(air, extraTracked, "the old Mac's \(extraTracked)\n") }
        try git(air, ["add", "-A"]); try git(air, ["commit", "-q", "-m", "c2"])
        let tip = try git(air, ["rev-parse", "HEAD"])
        let keeper = try git(air, ["commit-tree", tip + "^{tree}", "-p", tip, "-m", "Branch main on MacBook-Air (Terminal Deck backup)"])
        try write(air, "c.txt", "two, and more not saved yet\n")
        // A new file in the old Mac's unsaved work (staged so the work copy holds it, as Code backup's copy does).
        if let extraUnsaved { try write(air, extraUnsaved, "the old Mac's \(extraUnsaved)\n"); try git(air, ["add", "--", extraUnsaved]) }
        let work = try git(air, ["stash", "create"])
        if extraUnsaved != nil { try git(air, ["reset", "-q"]) }
        try git(air, ["push", "-q", bare.path, keeper + ":" + Self.area + "heads/main", work + ":" + Self.area + "work/main"])
        return (keeper, work, tip)
    }
    func clone(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try git(root, ["clone", "-q", bare.path, folder.path])
        // The project's home as his folder names it (Git fetches from the scratch "GitHub" through the transport).
        try git(folder, ["remote", "set-url", "origin", "https://github.com/fixture-owner/site.git"])
        return folder
    }
    static let now = Date(timeIntervalSince1970: 1_794_700_000)
    actor Journal {
        var records: [BackendCodeBackupTakeCode.Pending?] = []
        func note(_ value: BackendCodeBackupTakeCode.Pending?) { records.append(value) }
    }
    func take(_ folder: URL, _ named: BackendCodeBackupTakeCode.Named, pending: BackendCodeBackupTakeCode.Pending? = nil,
              journal: Journal? = nil) async -> BackendCodeBackupTakeCode.Result {
        let writer = BackendCodeBackupGitWriter(inheritedEnvironment: environment, home: home.path, loginPath: { Self.path })
        let transport = BackendCodeBackupTransport(url: bare.path, environment: BackendCodeBackupGitWriter.settings([("protocol.file.allow", "always")]))
        return await BackendCodeBackupTakeCode(git: writer, transport: transport, homeURL: "https://github.com/fixture-owner/site.git",
                                               folder: folder.path, home: "fixture-owner/site", now: Self.now, pending: pending,
                                               record: { value in await journal?.note(value) }).perform(named)
    }
    /// Git as the switch runs it, with one file written into the folder during the switch (an editor's autosave or an
    /// AI session writing while it checks out and merges): just before the first step after its stash and its check.
    final class WritesDuringSwitch: BackendCodeBackupGitRunning, @unchecked Sendable {
        let inner: BackendCodeBackupGitWriter
        let file: URL
        private let lock = NSLock()
        private var stashed = false, written = false
        init(inner: BackendCodeBackupGitWriter, file: URL) { self.inner = inner; self.file = file }
        func run(cwd: String, arguments: [String], environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
            let now = lock.withLock { () -> Bool in
                guard stashed, !written, let first = arguments.first, !["status", "stash"].contains(first) else { return false }
                written = true; return true
            }
            if now { try Data("written by an editor during the switch\n".utf8).write(to: file) }
            let outcome = try await inner.run(cwd: cwd, arguments: arguments, environment: environment, timeoutMilliseconds: timeoutMilliseconds, maximumBytes: maximumBytes)
            if arguments.starts(with: ["stash", "push"]), arguments.contains(where: { $0.hasPrefix("Terminal Deck: kept before switch") }) {
                lock.withLock { stashed = true }
            }
            return outcome
        }
    }
    func named(_ old: (keeper: String, work: String, tip: String)) -> BackendCodeBackupTakeCode.Named {
        .init(branch: "main", headSha: old.keeper, workSha: old.work, fromMac: "MacBook Air", codeAt: 1)
    }
    func ignore(_ folder: URL, _ name: String) throws {
        try write(folder, ".git/info/exclude", name + "\n")
    }

    /// His own unsaved change here is put aside in Git first and comes back with `git stash apply`; his branch moves
    /// forward to the old Mac's commit and its unsaved work is laid over the files.
    func testOwnChangesArePutAsideAndRecoverable() async throws {
        let old = try oldMacBackedUp()
        let mini = try clone("mini")
        try write(mini, "a.txt", "mine, not saved\n")
        try write(mini, "notes.txt", "only here\n")
        let result = await take(mini, .init(branch: "main", headSha: old.keeper, workSha: old.work, fromMac: "MacBook Air", codeAt: 1))
        XCTAssertEqual(result.kind, .fastForward)
        XCTAssertEqual(try git(mini, ["rev-parse", "HEAD"]), old.tip)
        XCTAssertEqual(try git(mini, ["symbolic-ref", "--short", "HEAD"]), "main")
        XCTAssertEqual(read(mini, "c.txt"), "two, and more not saved yet\n", "the old Mac's unsaved work is here")
        XCTAssertEqual(read(mini, "a.txt"), "one\n")
        let kept = try XCTUnwrap(result.keptAside)
        XCTAssertTrue(kept.hasPrefix("Terminal Deck: kept before switch "))
        XCTAssertTrue(try git(mini, ["stash", "list"]).contains(kept))
        // Got back.
        try git(mini, ["checkout", "-q", "--", "."])
        try git(mini, ["stash", "apply", "-q"])
        XCTAssertEqual(read(mini, "a.txt"), "mine, not saved\n")
        XCTAssertEqual(read(mini, "notes.txt"), "only here\n")
    }

    /// Split histories: this Mac's branch has its own commit; the old Mac's code goes on a branch of its own and his
    /// branch stays exactly where it was.
    func testSplitHistoriesKeepBoth() async throws {
        let old = try oldMacBackedUp()
        let mini = try clone("mini")
        try write(mini, "m.txt", "this Mac's own work\n"); try git(mini, ["add", "-A"]); try git(mini, ["commit", "-q", "-m", "mine"])
        let mine = try git(mini, ["rev-parse", "HEAD"])
        let result = await take(mini, .init(branch: "main", headSha: old.keeper, workSha: old.work, fromMac: "MacBook Air", codeAt: 1))
        XCTAssertEqual(result.kind, .ownBranch("main-MacBook-Air"))
        XCTAssertEqual(try git(mini, ["rev-parse", "refs/heads/main"]), mine, "his branch is untouched")
        XCTAssertEqual(try git(mini, ["rev-parse", "refs/heads/main-MacBook-Air"]), old.tip)
        XCTAssertEqual(try git(mini, ["symbolic-ref", "--short", "HEAD"]), "main-MacBook-Air")
        XCTAssertEqual(read(mini, "c.txt"), "two, and more not saved yet\n")
        XCTAssertNil(result.keptAside, "nothing of his was unsaved")
    }

    /// No project folder on this Mac: it is made, the code comes down (Get the code), then the old Mac's exact code.
    func testMissingFolderIsMadeAndGetsTheCode() async throws {
        let old = try oldMacBackedUp()
        let folder = root.appendingPathComponent("Projects/site", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let result = await take(folder, .init(branch: "main", headSha: old.keeper, workSha: old.work, fromMac: "MacBook Air", codeAt: 1))
        XCTAssertEqual(result.kind, .gotCode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path))
        XCTAssertEqual(try git(folder, ["rev-parse", "HEAD"]), old.tip)
        XCTAssertEqual(read(folder, "c.txt"), "two, and more not saved yet\n")
    }

    /// Taken while the old Mac was off (nothing named): its newest backup is used, and its time is the code's time.
    func testTakenWithoutHandOverUsesTheNewestBackup() async throws {
        let old = try oldMacBackedUp()
        let mini = try clone("mini")
        let result = await take(mini, .init(branch: nil, headSha: nil, workSha: nil, fromMac: "MacBook Air", codeAt: nil))
        XCTAssertEqual(result.kind, .fastForward)
        XCTAssertEqual(try git(mini, ["rev-parse", "HEAD"]), old.tip)
        XCTAssertNotNil(result.codeAt)
    }

    // MARK: Review fixes (15 Nov)

    /// A file Git ignores here that the old Mac's unsaved work would write over is copied first and named.
    func testIgnoredFileThatWouldBeWrittenOverIsKeptAndNamed() async throws {
        let old = try oldMacBackedUp(unsaved: ".env.local")
        let mini = try clone("mini")
        try ignore(mini, ".env.local")
        try write(mini, ".env.local", "this Mac's own secret\n")
        let result = await take(mini, named(old))
        XCTAssertEqual(result.kind, .fastForward)
        XCTAssertEqual(result.keptIgnored, [".env.local"])
        let folder = try XCTUnwrap(result.keptIgnoredFolder)
        XCTAssertTrue(folder.contains("/terminal-deck-switch/kept-"), folder)
        XCTAssertEqual(read(URL(fileURLWithPath: folder), ".env.local"), "this Mac's own secret\n", "his copy is kept before anything is written")
        XCTAssertEqual(read(mini, ".env.local"), "the old Mac's .env.local\n")
        XCTAssertNil(result.keptAside, "an ignored file is never stashed; it is copied")
    }

    /// A failure after his changes were put aside (here: the branch cannot move forward over a file Git ignores here)
    /// puts them back exactly: his commit, his changes, nothing left in the stash, the ignored file untouched.
    func testFailureAfterTheStashPutsHisChangesBack() async throws {
        let old = try oldMacBackedUp(tracked: "build.cfg")
        let mini = try clone("mini")
        let before = try git(mini, ["rev-parse", "HEAD"])
        try ignore(mini, "build.cfg")
        try write(mini, "build.cfg", "this Mac's own build settings\n")
        try write(mini, "a.txt", "mine, not saved\n")
        let journal = Journal()
        let result = await take(mini, named(old), journal: journal)
        guard case .failed(let why) = result.kind else { return XCTFail("expected a failure, got \(result.kind)") }
        XCTAssertTrue(why.contains("Your unsaved changes here are back as they were."), why)
        XCTAssertEqual(read(mini, "a.txt"), "mine, not saved\n")
        XCTAssertEqual(read(mini, "build.cfg"), "this Mac's own build settings\n")
        XCTAssertEqual(try git(mini, ["rev-parse", "HEAD"]), before)
        XCTAssertEqual(try git(mini, ["stash", "list"]), "")
        XCTAssertNil(result.keptAside)
        let records = await journal.records
        XCTAssertNotNil(records.first ?? nil, "the stash name and his commit were in the journal before the stash")
        XCTAssertNil(records.last ?? nil, "and cleared once he had them back")
    }

    /// A LIVE switch that fails after its stash (Reviewer, 15 Nov): a file written in the folder meanwhile is put aside
    /// in its own stash before the undo resets and cleans, so it is kept, and the failure says where; his own unsaved
    /// changes come back as before.
    func testFileWrittenDuringAFailingLiveSwitchIsKept() async throws {
        let old = try oldMacBackedUp(tracked: "build.cfg")
        let mini = try clone("mini")
        try ignore(mini, "build.cfg")
        try write(mini, "build.cfg", "this Mac's own build settings\n")
        try write(mini, "a.txt", "mine, not saved\n")
        let writer = BackendCodeBackupGitWriter(inheritedEnvironment: environment, home: home.path, loginPath: { Self.path })
        let transport = BackendCodeBackupTransport(url: bare.path, environment: BackendCodeBackupGitWriter.settings([("protocol.file.allow", "always")]))
        let runner = WritesDuringSwitch(inner: writer, file: mini.appendingPathComponent("autosave.txt"))
        let result = await BackendCodeBackupTakeCode(git: runner, transport: transport, homeURL: "https://github.com/fixture-owner/site.git",
                                                     folder: mini.path, home: "fixture-owner/site", now: Self.now, pending: nil,
                                                     record: { _ in }).perform(named(old))
        guard case .failed(let why) = result.kind else { return XCTFail("expected a failure, got \(result.kind)") }
        XCTAssertTrue(why.contains("Your unsaved changes here are back as they were."), why)
        XCTAssertTrue(why.contains("Files changed here during the switch are kept as 'Terminal Deck: your edits made during a stopped switch, "), why)
        XCTAssertEqual(read(mini, "a.txt"), "mine, not saved\n")
        XCTAssertEqual(read(mini, "build.cfg"), "this Mac's own build settings\n")
        // The file written during the switch: never removed without a copy; it comes back from its own stash.
        let ref = try XCTUnwrap(try stashRef(mini, "Terminal Deck: your edits made during a stopped switch, " + BackendCodeBackupTakeCode.stamp(Self.now)))
        try git(mini, ["checkout", "-q", "--", "."])
        try git(mini, ["stash", "apply", "-q", ref])
        XCTAssertEqual(read(mini, "autosave.txt"), "written by an editor during the switch\n")
    }

    /// A switch stopped half-way (his changes in the stash, the journal's record left): the next start undoes it,
    /// puts his changes back, says so, then switches.
    func testInterruptedAfterTheStashIsUndoneAndReported() async throws {
        let old = try oldMacBackedUp()
        let mini = try clone("mini")
        let head = try git(mini, ["rev-parse", "HEAD"])
        try write(mini, "a.txt", "mine, not saved\n")
        let message = "Terminal Deck: kept before switch earlier"
        try git(mini, ["stash", "push", "--include-untracked", "-m", message])
        let pending = BackendCodeBackupTakeCode.Pending(stash: message, head: head, branch: "main", at: 1_794_699_000_000)
        let result = await take(mini, named(old), pending: pending)
        XCTAssertEqual(result.kind, .fastForward)
        XCTAssertTrue(result.resumed?.contains("stopped half-way") == true, result.resumed ?? "nil")
        XCTAssertFalse(try git(mini, ["stash", "list"]).contains(message), "the old stash was given back")
        // His changes went back, then aside again for this switch, under this switch's name.
        let kept = try XCTUnwrap(result.keptAside)
        XCTAssertTrue(try git(mini, ["stash", "list"]).contains(kept))
        try git(mini, ["checkout", "-q", "--", "."])
        try git(mini, ["stash", "apply", "-q"])
        XCTAssertEqual(read(mini, "a.txt"), "mine, not saved\n")
    }

    /// A folder whose remotes do not name the project's home is another project's: refused, nothing touched.
    func testFolderOfAnotherProjectIsRefused() async throws {
        let old = try oldMacBackedUp()
        let mini = try clone("mini")
        try git(mini, ["remote", "set-url", "origin", "https://github.com/someone/other.git"])
        try write(mini, "a.txt", "mine, not saved\n")
        let before = try git(mini, ["rev-parse", "HEAD"])
        let result = await take(mini, named(old))
        XCTAssertEqual(result.kind, .otherProject)
        XCTAssertEqual(BackendCodeBackupTakeCode.refusedOtherProject, "This folder belongs to another project, so the code was not changed.")
        XCTAssertEqual(read(mini, "a.txt"), "mine, not saved\n")
        XCTAssertEqual(try git(mini, ["rev-parse", "HEAD"]), before)
        XCTAssertEqual(try git(mini, ["stash", "list"]), "")
    }

    /// A lock file left by a stopped Git is named in plain words; nothing is changed and the lock is not removed.
    func testStaleLockIsNamed() async throws {
        let old = try oldMacBackedUp()
        let mini = try clone("mini")
        let lock = mini.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        try FileManager.default.setAttributes([.modificationDate: Self.now.addingTimeInterval(-3_600)], ofItemAtPath: lock.path)
        let result = await take(mini, named(old))
        guard case .failed(let why) = result.kind else { return XCTFail("expected a failure, got \(result.kind)") }
        XCTAssertTrue(why.hasPrefix("Git left a lock file behind in this project (.git/index.lock, from "), why)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func stashRef(_ folder: URL, _ message: String) throws -> String? {
        try git(folder, ["stash", "list", "--format=%gd%x09%gs"]).split(separator: "\n").first { $0.hasSuffix(message) }
            .map { String($0.split(separator: "\t").first ?? "") }
    }

    /// Stopped after the stash; then he edits a tracked file and adds a new one in the half-switched folder; the next
    /// start keeps those edits in a stash of their own BEFORE undoing, puts his original changes back, says so, and
    /// both his original changes and the later edits can be got back. Nothing is removed without a copy.
    func testEditsMadeDuringAStoppedSwitchAreKeptBeforeTheUndo() async throws {
        let old = try oldMacBackedUp()
        let mini = try clone("mini")
        let head = try git(mini, ["rev-parse", "HEAD"])
        try write(mini, "a.txt", "mine, not saved\n")
        let message = "Terminal Deck: kept before switch earlier"
        try git(mini, ["stash", "push", "--include-untracked", "-m", message])
        // While the switch was stopped:
        try write(mini, "a.txt", "edited while it was stopped\n")
        try write(mini, "new.txt", "added while it was stopped\n")
        let pending = BackendCodeBackupTakeCode.Pending(stash: message, head: head, branch: "main", at: 1_794_699_000_000)
        let result = await take(mini, named(old), pending: pending)
        XCTAssertEqual(result.kind, .fastForward)
        let resumed = try XCTUnwrap(result.resumed)
        XCTAssertTrue(resumed.contains("You changed files here while the switch was stopped; those changes are kept as 'Terminal Deck: your edits made during a stopped switch, "), resumed)
        // His original changes: in this switch's stash now (put back, then aside again).
        let kept = try XCTUnwrap(result.keptAside)
        let keptRef = try XCTUnwrap(try stashRef(mini, kept))
        try git(mini, ["checkout", "-q", "--", "."])
        try git(mini, ["stash", "apply", "-q", keptRef])
        XCTAssertEqual(read(mini, "a.txt"), "mine, not saved\n")
        // The later edits: in their own stash, the new file included.
        try git(mini, ["checkout", "-q", "--", "."])
        let editsRef = try XCTUnwrap(try stashRef(mini, "Terminal Deck: your edits made during a stopped switch, " + BackendCodeBackupTakeCode.stamp(Self.now)))
        try git(mini, ["stash", "apply", "-q", editsRef])
        XCTAssertEqual(read(mini, "a.txt"), "edited while it was stopped\n")
        XCTAssertEqual(read(mini, "new.txt"), "added while it was stopped\n")
        XCTAssertNil(try stashRef(mini, message), "the stopped switch's own stash was given back, not dropped unseen")
    }
}
