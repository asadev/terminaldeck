import CryptoKit
import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// L5 slice 2: the Code page's actions on SCRATCH repositories only. Local bare repositories stand in for GitHub (the
/// fake account hands Git their folder as the address), the GitHub API is a fake, and no request ever leaves the Mac.
/// Every repository the tests make has its origin set to a github.com address that nothing ever contacts.
final class BackendCodeBackupActionsTests: XCTestCase {
    var root: URL!
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    static let path = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
    let t1: Int64 = 1_794_000_000, t2: Int64 = 1_794_000_600, t3: Int64 = 1_794_001_200

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("code-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("gitconfig"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Scratch helpers

    var environment: [String: String] {
        ["HOME": home.path, "XDG_CONFIG_HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path]
    }

    @discardableResult
    func git(_ cwd: URL, _ args: [String], at seconds: Int64? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "init.defaultBranch=main",
                             "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"] + args
        var env = environment; env["PATH"] = Self.path
        if let seconds { env["GIT_AUTHOR_DATE"] = "@\(seconds) +0000"; env["GIT_COMMITTER_DATE"] = "@\(seconds) +0000" }
        process.environment = env
        process.currentDirectoryURL = cwd
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")]) }
        return text
    }

    func write(_ folder: URL, _ name: String, _ text: String) throws {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func read(_ folder: URL, _ name: String) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    func commit(_ repo: URL, _ file: String, _ message: String, at seconds: Int64) throws {
        try write(repo, file, message + "\n")
        try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", message], at: seconds)
    }

    /// A repository whose origin reads as github.com/fixture-owner/<name>; its "GitHub" is a bare folder made by the fake.
    func homedRepo(_ name: String, github: FakeGitHub, isPrivate: Bool = true) throws -> URL {
        let bare = try github.add("fixture-owner/" + name, isPrivate: isPrivate)
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-q"])
        try git(repo, ["remote", "add", "origin", "https://github.com/fixture-owner/\(name).git"])
        try commit(repo, "README.md", "first", at: t1)
        try git(repo, ["push", "-q", bare.path, "main:refs/heads/main"])
        try git(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        return repo
    }

    func refs(_ repo: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for line in try git(repo, ["for-each-ref", "--format=%(refname) %(objectname)"]).split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    /// Every file under a folder: its bytes' hash (links and folders marked).
    func snapshot(_ folder: URL, skipping: Set<String> = []) throws -> [String: String] {
        var result: [String: String] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        // The walker may hand back the real path (/private/var/…) of a folder named through a link (/var/…): keys are
        // relative to whichever form the path starts with, so skipping works and keys stay comparable.
        let bases = [folder.resolvingSymlinksInPath().path, folder.path]
        for case let url as URL in walker {
            let key = bases.first { url.path.hasPrefix($0 + "/") }.map { String(url.path.dropFirst($0.count)) } ?? url.path
            if skipping.contains(where: { key.hasPrefix($0) }) { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { result[key] = "link"; continue }
            guard values.isRegularFile == true else { result[key] = "dir"; continue }
            result[key] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    /// His side of a repository that a backup must never change (the lane's promise, review 14 Nov): his WHOLE folder
    /// byte for byte, his `.git` included (objects, references and remote-tracking branches, config, hooks,
    /// `info/exclude`, the staging area), plus every reference and his stash as Git lists them.
    func hisSide(_ repo: URL) throws -> [String: String] {
        var side = try snapshot(repo)
        for (name, value) in try refs(repo) { side["ref " + name] = value }
        side["stash"] = (try? git(repo, ["stash", "list", "--format=%H"])) ?? ""
        return side
    }

    func bounds(made: Set<String> = []) -> BackendProjectCode.Bounds {
        let resolved = Set(made.map { BackendProjectCode.resolved($0) })
        return BackendProjectCode.Bounds(homes: [home.path], base: home.appendingPathComponent("Terminal Deck").path,
                                         madeByApp: { resolved.contains(BackendProjectCode.resolved($0)) })
    }

    struct Clock: @unchecked Sendable {
        final class Box: @unchecked Sendable { var at = Date(timeIntervalSince1970: 1_794_003_000) }
        let box = Box()
        func advance(_ seconds: TimeInterval) { box.at = box.at.addingTimeInterval(seconds) }
    }

    struct Rig {
        let actions: BackendCodeBackupActions
        let projects: BackendCodeBackupProjects
        let ledger: BackendCodeBackupLedger
    }

    func rig(_ list: [PROJProject], github: FakeGitHub, made: Set<String> = [], clock: Clock = Clock(), network: Bool = true,
             git: (any BackendCodeBackupGitRunning)? = nil) -> Rig {
        let ledger = BackendCodeBackupLedger(file: nil)
        let fence = self.bounds(made: made)
        let env = BackendCodeBackupGitReader.environment(environment, home: home.path)
        let reader = BackendCodeBackupGitReader(runner: BackendGitRunner(inheritedEnvironment: env, loginPath: { Self.path }),
                                                context: .init(caller: .nativeApp, ownerID: "code-actions-fixture"), bounds: fence,
                                                coverage: { ledger.coverage($0) })
        let projects = BackendCodeBackupProjects(projects: { list }, reader: reader, github: NoGitHub())
        let runner = git ?? self.writer()
        let box = clock.box
        let actions = BackendCodeBackupActions(projects: projects, ledger: ledger, account: github, git: runner, host: "github.com", mac: "Test-Mac",
                                               bounds: { fence }, network: { network }, now: { box.at }, workArea: root.appendingPathComponent("app-data", isDirectory: true))
        return Rig(actions: actions, projects: projects, ledger: ledger)
    }
    func writer() -> BackendCodeBackupGitWriter {
        BackendCodeBackupGitWriter(inheritedEnvironment: environment, home: home.path, loginPath: { Self.path })
    }

    // MARK: Back up now adds only

    func testBackUpAddsOnlyAndNeverChangesHisSide() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("site", github: github)
        let bare = github.bare("fixture-owner/site")
        // GitHub already has: a tag, a branch he does not have, and a branch with other work than his.
        try git(repo, ["tag", "v1"]); try git(repo, ["push", "-q", bare.path, "refs/tags/v1:refs/tags/v1"])
        try git(repo, ["checkout", "-q", "-b", "diverged"]); try commit(repo, "d.txt", "his diverged", at: t2)
        try git(repo, ["checkout", "-q", "-b", "elsewhere", "main"]); try commit(repo, "e.txt", "theirs", at: t2)
        try git(repo, ["push", "-q", bare.path, "elsewhere:refs/heads/diverged", "elsewhere:refs/heads/only-there"])
        try git(repo, ["checkout", "-q", "main"]); try git(repo, ["branch", "-q", "-D", "elsewhere"])
        // His work: a commit ahead, a new branch, a staged change, an edit, a new file, a secret file, a stash.
        try commit(repo, "a.txt", "second", at: t2)
        try git(repo, ["checkout", "-q", "-b", "feature"]); try commit(repo, "f.txt", "feature work", at: t3); try git(repo, ["checkout", "-q", "main"])
        try write(repo, "a.txt", "stashed\n"); try git(repo, ["stash", "-q"])
        try write(repo, "README.md", "staged\n"); try git(repo, ["add", "README.md"])
        try write(repo, "README.md", "edited after staging\n")
        try write(repo, "notes/new.txt", "new\n"); try write(repo, ".env", "TOKEN=fixture\n")
        let remoteBefore = try refs(bare), sideBefore = try hisSide(repo)
        let objectsBefore = Set(try snapshot(bare.appendingPathComponent("objects")).keys)

        let rig = self.rig([PROJProject(id: "site", name: "Site", folders: [repo.path])], github: github)
        let outcome = await rig.actions.backUp(projectID: "site")
        XCTAssertTrue(outcome.ok, outcome.line)
        XCTAssertTrue(outcome.line.hasPrefix("Backed up to github.com/fixture-owner/site"), outcome.line)
        XCTAssertTrue(outcome.line.contains("1 file left out (secret files)"), outcome.line)

        // A home he already had: every branch and tag on GitHub is byte for byte as it was; everything new is under the
        // private references (neither a branch nor a tag, so nothing that hangs on a push starts).
        let remoteAfter = try refs(bare)
        let real = { (all: [String: String]) in all.filter { $0.key.hasPrefix("refs/heads/") || $0.key.hasPrefix("refs/tags/") } }
        XCTAssertEqual(real(remoteAfter), real(remoteBefore), "no branch or tag created, moved or removed")
        for (name, before) in remoteBefore { XCTAssertEqual(remoteAfter[name], before, "\(name) changed") }
        for name in Set(remoteAfter.keys).subtracting(remoteBefore.keys) {
            XCTAssertTrue(name.hasPrefix("refs/terminal-deck-backup/Test-Mac/"), "\(name) is outside the private references")
        }
        XCTAssertTrue(objectsBefore.isSubset(of: Set(try snapshot(bare.appendingPathComponent("objects")).keys)), "no object file removed")
        // Each of his branches, exactly as it is, is the first parent of its keeper (even the one GitHub has other work on).
        for branch in ["main", "feature", "diverged"] {
            let keeper = try XCTUnwrap(remoteAfter["refs/terminal-deck-backup/Test-Mac/heads/" + branch], branch)
            XCTAssertEqual(try git(bare, ["rev-parse", keeper + "^1"]), try git(repo, ["rev-parse", branch]))
        }
        let work = try XCTUnwrap(remoteAfter["refs/terminal-deck-backup/Test-Mac/work/main"])
        XCTAssertNotNil(remoteAfter["refs/terminal-deck-backup/Test-Mac/set-aside"])
        // The copy of his uncommitted work: the edit as it is in the folder, the new file, never the secret file.
        XCTAssertEqual(try git(bare, ["show", work + ":README.md"]), "edited after staging\n")
        XCTAssertEqual(try git(bare, ["show", work + ":notes/new.txt"]), "new\n")
        XCTAssertThrowsError(try git(bare, ["show", work + ":.env"]), "a secret file never goes to GitHub")

        // His side: his whole folder, `.git` included, byte for byte as it was. The work happened in the app's own
        // repository, which borrows his objects and keeps its own record of GitHub's branches.
        XCTAssertEqual(try hisSide(repo), sideBefore)
        XCTAssertEqual(try git(repo, ["diff", "--cached", "--name-only"]).trimmingCharacters(in: .whitespacesAndNewlines), "README.md", "his staging area is his")
    }

    func testTheRuleItselfCannotForceOrDelete() {
        let sha = String(repeating: "a", count: 40)
        XCTAssertTrue(BackendCodeBackupPlan.addsOnly(sha + ":refs/heads/main"))
        XCTAssertTrue(BackendCodeBackupPlan.addsOnly(sha + ":refs/tags/v1"))
        for refused in ["+" + sha + ":refs/heads/main", ":refs/heads/main", sha + ":refs/remotes/origin/main", "main:refs/heads/main",
                        sha + ":refs/heads/*", "refs/heads/*:refs/heads/*", sha + ":refs/heads/a..b", sha + ":refs/heads/x.lock", "^" + sha + ":refs/heads/main",
                        sha + ":refs/heads/main:refs/heads/x", sha + ":HEAD"] {
            XCTAssertFalse(BackendCodeBackupPlan.addsOnly(refused), refused)
        }
        XCTAssertTrue(BackendCodeBackupPlan.addsOnly(sha + ":refs/terminal-deck-backup/Mac/heads/main"))
        XCTAssertFalse(BackendCodeBackupPlan.addsOnly("+" + sha + ":refs/terminal-deck-backup/Mac/heads/main"))
        // A home he already had: only the private references, never a branch or tag.
        XCTAssertTrue(BackendCodeBackupPlan.privateOnly([.init(commit: sha, reference: "refs/terminal-deck-backup/Mac/heads/main"),
                                                         .init(commit: sha, reference: "refs/terminal-deck-backup/Mac/tags/v1")]))
        XCTAssertFalse(BackendCodeBackupPlan.privateOnly([.init(commit: sha, reference: "refs/terminal-deck-backup/Mac/heads/main"),
                                                          .init(commit: sha, reference: "refs/heads/main")]))
        XCTAssertFalse(BackendCodeBackupPlan.privateOnly([.init(commit: sha, reference: "refs/tags/v1")]))
        // A home Terminal Deck made: real names, fast-forward only, existing tags never moved.
        let plan = BackendCodeBackupPlan.make(branches: ["main": sha, "new": sha, "behind": sha], tags: ["v1": sha, "v2": sha],
                                              remote: ["refs/heads/main": "b" + sha.dropFirst(), "refs/heads/behind": "c" + sha.dropFirst(), "refs/tags/v1": "d" + sha.dropFirst()]) { theirs, _ in theirs.hasPrefix("b") }
        XCTAssertEqual(plan.send.map(\.reference).sorted(), ["refs/heads/main", "refs/heads/new", "refs/tags/v2"], "an existing tag is never moved")
        XCTAssertEqual(plan.skipped, ["behind: GitHub has other work on this branch"])
        XCTAssertEqual(BackendCodeBackupPlan.accepted("To x\n*\tabc:refs/heads/new\t[new branch]\n+\tabc:refs/heads/f\tforced\n!\tabc:refs/heads/r\t[rejected]\n \tabc:refs/heads/main\ta..b\nDone\n"),
                       ["refs/heads/new", "refs/heads/main"])
    }

    func testUncommittedWorkIsBackedUpAndThePageSaysSo() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("notes", github: github)
        try write(repo, "README.md", "changed\n"); try write(repo, "draft.md", "draft\n")
        try write(repo, "x.txt", "set aside\n"); try git(repo, ["add", "x.txt"]); try git(repo, ["stash", "-q"])
        let sideBefore = try hisSide(repo)
        let rig = self.rig([PROJProject(id: "notes", name: "Notes", folders: [repo.path])], github: github)
        var row = try unwrapNow(await rig.projects.report(refresh: true).projects.first)
        XCTAssertEqual(row.state, .filesChanged)
        let outcome = await rig.actions.backUp(projectID: "notes")
        XCTAssertTrue(outcome.ok, outcome.line)
        XCTAssertEqual(try hisSide(repo), sideBefore)
        row = try unwrapNow(await rig.projects.report(refresh: true).projects.first)
        XCTAssertEqual(row.state, .backedUp)
        XCTAssertNotNil(row.changesCoveredAt); XCTAssertTrue(row.setAsideCovered)
        let then = Clock().box.at.addingTimeInterval(60)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: then), "Backed up")
        XCTAssertTrue(BackendCodeBackupWords.lastBackedUp(row, now: then).hasPrefix("Last backed up Today"), "the backup's own time, not the last commit's")
        // A new edit after the backup is not backed up, and says so.
        try write(repo, "draft.md", "draft, longer now\n")
        row = try unwrapNow(await rig.projects.report(refresh: true).projects.first)
        XCTAssertEqual(row.state, .filesChanged)
        // A second backup moves its own branch forward only.
        let before = try refs(github.bare("fixture-owner/notes"))["refs/terminal-deck-backup/Test-Mac/work/main"]
        let again = await rig.actions.backUp(projectID: "notes")
        XCTAssertTrue(again.ok, again.line)
        let after = try XCTUnwrap(try refs(github.bare("fixture-owner/notes"))["refs/terminal-deck-backup/Test-Mac/work/main"])
        XCTAssertNoThrow(try git(github.bare("fixture-owner/notes"), ["merge-base", "--is-ancestor", try XCTUnwrap(before), after]))
    }

    func testABranchWithASecretFileInItsCommitsStaysHere() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("keys", github: github)
        // A .pem holding a private key holds its branch back; a .pem certificate does not.
        try git(repo, ["checkout", "-q", "-b", "leaky"])
        try write(repo, "config/server.pem", "-----BEGIN PRIVATE KEY-----\nMIIfixture\n-----END PRIVATE KEY-----\n")
        try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", "oops"], at: t2)
        try git(repo, ["checkout", "-q", "-b", "certs", "main"])
        try write(repo, "config/ca.pem", "-----BEGIN CERTIFICATE-----\nMIIfixture\n-----END CERTIFICATE-----\n")
        try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", "ca"], at: t2)
        try git(repo, ["checkout", "-q", "main"])
        let rig = self.rig([PROJProject(id: "keys", name: "Keys", folders: [repo.path])], github: github)
        let outcome = await rig.actions.backUp(projectID: "keys")
        XCTAssertTrue(outcome.line.contains("leaky: not sent: server.pem is in its commits"), outcome.line)
        XCTAssertNotNil(try refs(github.bare("fixture-owner/keys"))["refs/terminal-deck-backup/Test-Mac/heads/certs"], "a certificate is not a secret")
        XCTAssertNil(try refs(github.bare("fixture-owner/keys"))["refs/heads/leaky"])
        XCTAssertNil(try refs(github.bare("fixture-owner/keys"))["refs/terminal-deck-backup/Test-Mac/heads/leaky"])
    }

    // MARK: A private home, only on his click

    func testAPrivateHomeIsMadeOnlyByTheClick() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        _ = try github.add("fixture-owner/my-app", isPrivate: true, description: "someone else's")
        let repo = root.appendingPathComponent("my app", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-q"]); try commit(repo, "main.swift", "start", at: t1)
        let clock = Clock()
        let rig = self.rig([PROJProject(id: "app", name: "My App", folders: [repo.path])], github: github, clock: clock)
        // Looking at the page and the automatic looks never make anything.
        _ = await rig.actions.decorate(await rig.projects.report(refresh: true))
        for _ in 0..<4 { await rig.actions.look(); clock.advance(600) }
        XCTAssertEqual(github.created, [])
        let target = await rig.actions.target(projectID: "app")
        XCTAssertEqual(target?.newHome, true); XCTAssertEqual(target?.address, "github.com/fixture-owner/my-app")
        let outcome = await rig.actions.backUp(projectID: "app")
        XCTAssertTrue(outcome.ok, outcome.line)
        XCTAssertEqual(github.created, ["fixture-owner/my-app-2"], "a plain second name when the first is taken")
        XCTAssertEqual(github.repository(named: "fixture-owner/my-app-2")?.isPrivate, true)
        XCTAssertEqual(try git(repo, ["config", "--get", "remote.origin.url"]).trimmingCharacters(in: .whitespacesAndNewlines), "https://github.com/fixture-owner/my-app-2.git")
        // Review 14 Nov: a home Terminal Deck made also gets only the private references in this release.
        XCTAssertNil(try refs(github.bare("fixture-owner/my-app-2"))["refs/heads/main"])
        XCTAssertNotNil(try refs(github.bare("fixture-owner/my-app-2"))["refs/terminal-deck-backup/Test-Mac/heads/main"])
        XCTAssertEqual(rig.ledger.home("app"), "fixture-owner/my-app-2")
    }

    func testSomeoneElsesHomeIsWrittenOnlyWithPushAccess() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("shared", github: github)
        try git(repo, ["remote", "set-url", "origin", "https://github.com/some-org/shared.git"])
        try github.alias("some-org/shared", to: "fixture-owner/shared", canPush: false)
        try commit(repo, "b.txt", "mine", at: t2)
        let rig = self.rig([PROJProject(id: "shared", name: "Shared", folders: [repo.path])], github: github)
        let before = try refs(github.bare("fixture-owner/shared"))
        let outcome = await rig.actions.backUp(projectID: "shared")
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.line.contains("no permission to send to github.com/some-org/shared"), outcome.line)
        XCTAssertEqual(try refs(github.bare("fixture-owner/shared")), before)
    }

    // MARK: Automatic

    func testAutomaticWaitsForWorkToSettleAndNeverDuringAGitOperation() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("auto", github: github)
        let bare = github.bare("fixture-owner/auto")
        let clock = Clock()
        let project = PROJProject(id: "auto", name: "Auto", folders: [repo.path])
        // Offline (or Low Data): nothing at all.
        let offline = self.rig([project], github: github, clock: clock, network: false)
        try commit(repo, "a.txt", "work", at: t2)
        for _ in 0..<3 { await offline.actions.look(); clock.advance(400) }
        let keeper = "refs/terminal-deck-backup/Test-Mac/heads/main", realMain = try refs(bare)["refs/heads/main"]
        XCTAssertNil(try refs(bare)[keeper])

        let rig = self.rig([project], github: github, clock: clock)
        var mode = await rig.actions.decorate(await rig.projects.report(refresh: true)).projects.first?.mode
        XCTAssertEqual(mode, .manual, "Manual until a Back up now has finished on this Mac")
        rig.ledger.setFirstBackupDone()
        mode = await rig.actions.decorate(await rig.projects.report(refresh: true)).projects.first?.mode
        XCTAssertEqual(mode, .automatic, "then a private home on his own account defaults to Automatic")
        await rig.actions.look()                       // first look: work seen
        clock.advance(120); await rig.actions.look()   // 2 minutes: not settled
        XCTAssertNil(try refs(bare)[keeper])
        try write(repo, "b.txt", "still typing\n")     // a change starts the wait again
        clock.advance(240); await rig.actions.look()
        clock.advance(240); await rig.actions.look()
        XCTAssertNil(try refs(bare)[keeper])
        // A session in the middle of a merge: no backup however long it settles.
        try Data().write(to: repo.appendingPathComponent(".git/MERGE_HEAD"))
        for _ in 0..<3 { clock.advance(400); await rig.actions.look() }
        XCTAssertNil(try refs(bare)[keeper])
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/MERGE_HEAD"))
        await rig.actions.look()
        clock.advance(301); await rig.actions.look()   // unchanged for 5 minutes: backed up
        XCTAssertEqual(try git(bare, ["rev-parse", try XCTUnwrap(try refs(bare)[keeper]) + "^1"]), try git(repo, ["rev-parse", "main"]))
        XCTAssertNotNil(try refs(bare)["refs/terminal-deck-backup/Test-Mac/work/main"])
        XCTAssertEqual(try refs(bare)["refs/heads/main"], realMain, "Automatic never moves his real branch")
        // Off: never again.
        await rig.actions.setMode(projectID: "auto", .off)
        let kept = try refs(bare)
        try commit(repo, "c.txt", "more", at: t3)
        for _ in 0..<4 { clock.advance(1_000); await rig.actions.look() }
        XCTAssertEqual(try refs(bare), kept)
    }

    // MARK: Correction 14 Nov: a backup never writes his real branches or tags on a home he already had

    func testCommitsKeptPrivatelyCountAsBackedUpAndSaySoHonestly() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("api", github: github)
        let bare = github.bare("fixture-owner/api")
        try commit(repo, "a.txt", "second", at: t2); try commit(repo, "b.txt", "third", at: t3)
        let before = try refs(bare)
        let rig = self.rig([PROJProject(id: "api", name: "API", folders: [repo.path])], github: github)
        var row = try unwrapNow(await rig.projects.report(refresh: true).projects.first)
        XCTAssertEqual(row.state, .commitsNotOnGitHub)
        let outcome = await rig.actions.backUp(projectID: "api")
        XCTAssertTrue(outcome.ok, outcome.line)
        XCTAssertEqual(try refs(bare).filter { !$0.key.hasPrefix("refs/terminal-deck-backup/") }, before, "his GitHub branches and tags are untouched")
        row = try unwrapNow(await rig.projects.report(refresh: true).projects.first)
        XCTAssertEqual(row.state, .backedUp)
        XCTAssertEqual(row.commitCount, 0); XCTAssertEqual(row.privateCommitCount, 2); XCTAssertEqual(row.privateBranches, ["main"])
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: Date()), "Backed up · 2 commits not pushed to main: backed up privately")
        XCTAssertFalse(row.offersBackUp, "no button pushes his branches for him")
        // After he rebases, the next backup still only adds: a new keeper on top of the old one.
        let oldKeeper = try XCTUnwrap(try refs(bare)["refs/terminal-deck-backup/Test-Mac/heads/main"])
        try git(repo, ["commit", "-q", "--amend", "-m", "third, reworded"], at: t3)
        let again = await rig.actions.backUp(projectID: "api")
        XCTAssertTrue(again.ok, again.line)
        let newKeeper = try XCTUnwrap(try refs(bare)["refs/terminal-deck-backup/Test-Mac/heads/main"])
        XCTAssertNotEqual(newKeeper, oldKeeper)
        XCTAssertNoThrow(try git(bare, ["merge-base", "--is-ancestor", oldKeeper, newKeeper]))
        XCTAssertEqual(try git(bare, ["rev-parse", newKeeper + "^1"]), try git(repo, ["rev-parse", "main"]))
    }

    func testAHomeTerminalDeckMadeAlsoGetsOnlyPrivateReferences() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = root.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-q"]); try commit(repo, "index.html", "hello", at: t1); try git(repo, ["tag", "v1"])
        let rig = self.rig([PROJProject(id: "site", name: "Site", folders: [repo.path])], github: github)
        let first = await rig.actions.backUp(projectID: "site")
        XCTAssertTrue(first.ok, first.line)
        let bare = github.bare("fixture-owner/site")
        XCTAssertFalse(BackendCodeBackupPlan.realNamesAllowed)
        XCTAssertTrue(try refs(bare).keys.allSatisfy { $0.hasPrefix("refs/terminal-deck-backup/Test-Mac/") }, "no branch or tag, even on a home the app made")
        XCTAssertNotNil(try refs(bare)["refs/terminal-deck-backup/Test-Mac/heads/main"])
        XCTAssertNotNil(try refs(bare)["refs/terminal-deck-backup/Test-Mac/tags/v1"])
        try git(repo, ["checkout", "-q", "-b", "feature"]); try commit(repo, "f.html", "feature", at: t3)
        let second = await rig.actions.backUp(projectID: "site")
        XCTAssertTrue(second.ok, second.line)
        XCTAssertTrue(try refs(bare).keys.allSatisfy { $0.hasPrefix("refs/terminal-deck-backup/Test-Mac/") })
        XCTAssertNotNil(try refs(bare)["refs/terminal-deck-backup/Test-Mac/heads/feature"])
        // Get the code from a home holding only private references, on another device.
        let hooked = try FakeGitHub(root: root.appendingPathComponent("second"), git: { try self.git($0, $1) })
        hooked.quietHomes = false
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try git(plain, ["init", "-q"]); try commit(plain, "a.txt", "a", at: t1)
        let rig2 = self.rig([PROJProject(id: "plain", name: "Plain", folders: [plain.path])], github: hooked)
        let made = await rig2.actions.backUp(projectID: "plain")
        XCTAssertTrue(made.ok, made.line)
        XCTAssertNil(try refs(hooked.bare("fixture-owner/plain"))["refs/heads/main"])
        XCTAssertNotNil(try refs(hooked.bare("fixture-owner/plain"))["refs/terminal-deck-backup/Test-Mac/heads/main"])
        // Get the code from such a home on another device: his branch, from the backup, as a plain local branch.
        let folder = home.appendingPathComponent("Terminal Deck/Projects/Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder, "CLAUDE.md", "rules\n")
        let other2 = self.rig([PROJProject(id: "plain", name: "Plain", folders: [folder.path])], github: hooked, made: [folder.path])
        let got = await other2.actions.getCode(projectID: "plain")
        XCTAssertTrue(got.ok, got.line)
        XCTAssertEqual(read(folder, "a.txt"), "a\n")
        XCTAssertEqual(try git(folder, ["rev-parse", "main"]), try git(plain, ["rev-parse", "main"]))
    }

    func testAPublicHomeGetsNothing() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("open", github: github, isPrivate: false)
        try commit(repo, "a.txt", "work", at: t2); try write(repo, "draft.md", "draft\n")
        let before = try refs(github.bare("fixture-owner/open"))
        let rig = self.rig([PROJProject(id: "open", name: "Open", folders: [repo.path])], github: github)
        let outcome = await rig.actions.backUp(projectID: "open")
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.line.contains("is public; backups go only to a private home"), outcome.line)
        XCTAssertEqual(try refs(github.bare("fixture-owner/open")), before)
    }

    // MARK: Get the code

    func testGetTheCodeKeepsInstructionFilesResumesAndNeverOverwrites() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let source = try homedRepo("shop", github: github)
        try write(source, "CLAUDE.md", "from GitHub\n"); try write(source, "AGENTS.md", "same\n"); try write(source, "src/a.txt", "code\n")
        try git(source, ["add", "-A"]); try git(source, ["commit", "-q", "-m", "code"], at: t2)
        try git(source, ["push", "-q", github.bare("fixture-owner/shop").path, "main:refs/heads/main"])
        let projects = home.appendingPathComponent("Terminal Deck/Projects", isDirectory: true)
        let folder = projects.appendingPathComponent("Shop", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder, "CLAUDE.md", "mine, different\n"); try write(folder, "AGENTS.md", "same\n")
        let project = PROJProject(id: "shop", name: "Shop", folders: [folder.path])

        // Cut off while opening the files.
        let failing = FailingOnce(real: writer(), word: "checkout")
        let first = self.rig([project], github: github, made: [folder.path], git: failing)
        var row = try unwrapNow(await first.actions.decorate(await first.projects.report(refresh: true)).projects.first)
        XCTAssertEqual(row.state, .codeNotHere); XCTAssertEqual(row.getFrom, "fixture-owner/shop")
        let stopped = await first.actions.getCode(projectID: "shop")
        XCTAssertFalse(stopped.ok)
        XCTAssertNotNil(first.ledger.getting("shop"))
        XCTAssertEqual(read(folder, "CLAUDE.md"), "mine, different\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path))
        row = try unwrapNow(await first.actions.decorate(await first.projects.report(refresh: true)).projects.first)
        XCTAssertTrue(row.getting); XCTAssertEqual(row.state, .codeNotHere)

        // Again: it continues and finishes.
        let done = await first.actions.getCode(projectID: "shop")
        XCTAssertTrue(done.ok, done.line)
        XCTAssertTrue(done.line.contains("kept your CLAUDE.md (it differs from GitHub's)"), done.line)
        XCTAssertEqual(read(folder, "CLAUDE.md"), "mine, different\n", "never overwritten")
        XCTAssertEqual(read(folder, "AGENTS.md"), "same\n")
        XCTAssertEqual(read(folder, "src/a.txt"), "code\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: GetCodePaths.temporary(folder.path)), "the download folder is gone")
        XCTAssertNil(first.ledger.getting("shop"))
        row = try unwrapNow(await first.actions.decorate(await first.projects.report(refresh: true)).projects.first)
        XCTAssertTrue(row.isRepository); XCTAssertEqual(row.branch, "main"); XCTAssertEqual(row.home, "fixture-owner/shop")
        XCTAssertEqual(row.changedFiles, ["CLAUDE.md"], "his own CLAUDE.md shows as changed, nothing lost")
    }

    func testGetTheCodeThenThePageSaysBackedUp() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let source = try homedRepo("blog", github: github)
        try write(source, "CLAUDE.md", "rules\n"); try git(source, ["add", "-A"]); try git(source, ["commit", "-q", "-m", "rules"], at: t2)
        try git(source, ["push", "-q", github.bare("fixture-owner/blog").path, "main:refs/heads/main"])
        let folder = home.appendingPathComponent("Terminal Deck/Projects/Blog", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder, "CLAUDE.md", "rules\n")
        let rig = self.rig([PROJProject(id: "blog", name: "Blog", folders: [folder.path])], github: github, made: [folder.path])
        let done = await rig.actions.getCode(projectID: "blog")
        XCTAssertTrue(done.ok, done.line); XCTAssertEqual(done.line, "Code is here · branch main")
        let row = try unwrapNow(await rig.projects.report(refresh: true).projects.first)
        XCTAssertEqual(row.state, .backedUp); XCTAssertEqual(row.branch, "main")
    }

    // MARK: The repository above a project folder is never touched

    func testARepositoryAboveTheFolderIsNeverTouched() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        // His home folder is itself a repository, and it tracks a file inside one of the folders.
        try git(home, ["init", "-q"]); try commit(home, ".zshrc", "home", at: t1)
        try write(home, "Documents/Tracked/notes.txt", "tracked by home\n"); try git(home, ["add", "-A"]); try git(home, ["commit", "-q", "-m", "docs"], at: t2)
        let homeGit = try snapshot(home.appendingPathComponent(".git"))
        let waiting = home.appendingPathComponent("Terminal Deck/Projects/Site", isDirectory: true)
        try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
        try write(waiting, "CLAUDE.md", "rules\n")
        let tracked = home.appendingPathComponent("Documents/Tracked", isDirectory: true)
        let plain = home.appendingPathComponent("Documents/Plain", isDirectory: true)
        try write(plain, "idea.txt", "his own folder\n")
        let siteBare = try github.add("fixture-owner/site", isPrivate: true)
        let siteSource = root.appendingPathComponent("site-source", isDirectory: true)
        try FileManager.default.createDirectory(at: siteSource, withIntermediateDirectories: true)
        try git(siteSource, ["init", "-q"]); try commit(siteSource, "index.html", "site", at: t1)
        try git(siteSource, ["push", "-q", siteBare.path, "main:refs/heads/main"])
        let rig = self.rig([PROJProject(id: "site", name: "Site", folders: [waiting.path]), PROJProject(id: "tracked", name: "Tracked", folders: [tracked.path]),
                       PROJProject(id: "home", name: "Home", folders: [home.path]), PROJProject(id: "plain", name: "Plain", folders: [plain.path])],
                      github: github, made: [waiting.path])
        let notHere = await rig.actions.backUp(projectID: "site")
        XCTAssertFalse(notHere.ok); XCTAssertEqual(notHere.line, "Code not on this Mac yet")
        let keptAbove = await rig.actions.backUp(projectID: "tracked")
        XCTAssertFalse(keptAbove.ok, keptAbove.line)
        let homeItself = await rig.actions.backUp(projectID: "home")
        XCTAssertFalse(homeItself.ok, homeItself.line)
        for _ in 0..<3 { await rig.actions.look() }
        XCTAssertEqual(try snapshot(home.appendingPathComponent(".git")), homeGit, "the home folder's repository is byte for byte as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracked.appendingPathComponent(".git").path))
        // His own plain folder becomes its own repository with its own private home; the home repository stays as it was.
        let plainBackup = await rig.actions.backUp(projectID: "plain")
        XCTAssertTrue(plainBackup.ok, plainBackup.line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.appendingPathComponent(".git").path))
        // Get the code into the folder inside the home repository: its own repository, the home one unchanged.
        let got = await rig.actions.getCode(projectID: "site")
        XCTAssertTrue(got.ok, got.line)
        XCTAssertEqual(try snapshot(home.appendingPathComponent(".git")), homeGit)
        XCTAssertEqual(github.created, ["fixture-owner/plain"])
    }

    // MARK: Review 14 Nov

    func testATagAndASetAsideChangeCarryingASecretAreHeldBackAndNamed() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let tagged = try homedRepo("tagged", github: github)
        try git(tagged, ["checkout", "-q", "-b", "tmp"]); try commit(tagged, ".env", "TOKEN=fixture", at: t2)
        try git(tagged, ["tag", "leak"]); try git(tagged, ["checkout", "-q", "main"]); try git(tagged, ["branch", "-q", "-D", "tmp"])
        let stashed = try homedRepo("stashed", github: github)
        try write(stashed, "README.md", "clean change\n"); try git(stashed, ["stash", "-q"])
        let clean = try git(stashed, ["rev-parse", "refs/stash"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try write(stashed, "config/.ENV", "TOKEN=fixture\n"); try git(stashed, ["stash", "push", "-u", "-q"])
        let secret = try git(stashed, ["rev-parse", "refs/stash"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rig = self.rig([PROJProject(id: "tagged", name: "Tagged", folders: [tagged.path]),
                            PROJProject(id: "stashed", name: "Stashed", folders: [stashed.path])], github: github)
        let tagOutcome = await rig.actions.backUp(projectID: "tagged")
        XCTAssertTrue(tagOutcome.line.contains("tag leak: not sent: .env is in its commits"), tagOutcome.line)
        XCTAssertNil(try refs(github.bare("fixture-owner/tagged"))["refs/terminal-deck-backup/Test-Mac/tags/leak"])
        let stashOutcome = await rig.actions.backUp(projectID: "stashed")
        XCTAssertTrue(stashOutcome.line.contains("not sent: .ENV is in it"), stashOutcome.line)
        let setAside = try XCTUnwrap(try refs(github.bare("fixture-owner/stashed"))["refs/terminal-deck-backup/Test-Mac/set-aside"])
        let parents = try git(github.bare("fixture-owner/stashed"), ["rev-list", "--parents", "-n", "1", setAside])
        XCTAssertTrue(parents.contains(clean), "the clean set-aside change goes")
        XCTAssertFalse(parents.contains(secret), "the one with a secret file stays on this Mac")
        XCTAssertThrowsError(try git(github.bare("fixture-owner/stashed"), ["cat-file", "-e", secret + "^{commit}"]))
    }

    func testTheSecretKindsMatchInAnyCase() {
        typealias R = BackendCodeBackupGitReader
        // A: real credentials, left out of the copy AND holding back what carries them.
        for name in [".env", "a/.env.local", ".env.development.local", "release.keystore", "keys/AuthKey_ABC123.p8", "ID_ECDSA", "deploy/credentials",
                     "infra/terraform.tfstate", "vault.kdbx", ".git-credentials", "service-account-prod.json", ".dev.vars", "home/.ssh/config"] {
            XCTAssertEqual(R.secretKind(name), .credential, name)
            XCTAssertTrue(R.isSecret(name), name); XCTAssertTrue(R.holdsBack(name), name)
        }
        // C: left out of the uncommitted copy only, never holding anything back.
        for name in ["ios/GoogleService-Info.plist", "android/app/google-services.json", ".env.production", ".env.example", "app/DEBUG.KEYSTORE",
                     ".npmrc", ".yarnrc.yml", ".envrc", "infra/prod.tfvars", "certs/Dist.MobileProvision"] {
            XCTAssertEqual(R.secretKind(name), .leaveOut, name)
            XCTAssertTrue(R.isSecret(name), name); XCTAssertFalse(R.holdsBack(name), name)
        }
        // B: by content.
        for name in ["x/server.PEM", "talk.key", "KEYS.asc"] { XCTAssertEqual(R.secretKind(name), .maybeKey, name) }
        XCTAssertTrue(R.privateKey(Data("-----BEGIN RSA PRIVATE KEY-----\nMII\n".utf8)))
        XCTAssertTrue(R.privateKey(Data("-----BEGIN PGP PRIVATE KEY BLOCK-----\n".utf8)))
        XCTAssertFalse(R.privateKey(Data("-----BEGIN CERTIFICATE-----\nMII\n".utf8)))
        XCTAssertFalse(R.privateKey(Data("-----BEGIN PGP PUBLIC KEY BLOCK-----\n".utf8)))
        for name in ["README.md", "id_rsa.pub", "src/credentials.swift", "keystore.md", "Config/Release.xcconfig"] {
            XCTAssertEqual(R.secretKind(name), .none, name)
        }
    }

    func testOnlyRealCredentialsHoldBackABranch() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("mobile", github: github)
        let base = try git(repo, ["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(repo, ["checkout", "-q", "-b", "firebase"]); try commit(repo, "ios/GoogleService-Info.plist", "plist", at: t2)
        try commit(repo, "android/debug.keystore", "debug", at: t2)
        try git(repo, ["checkout", "-q", "-b", "release", base]); try commit(repo, "android/release.keystore", "release", at: t2)
        try git(repo, ["checkout", "-q", "main"])
        try write(repo, ".env.production", "PUBLIC_URL=x\n"); try write(repo, "draft.md", "draft\n")
        let rig = self.rig([PROJProject(id: "mobile", name: "Mobile", folders: [repo.path])], github: github)
        let outcome = await rig.actions.backUp(projectID: "mobile")
        XCTAssertTrue(outcome.ok, outcome.line)
        let bare = github.bare("fixture-owner/mobile")
        XCTAssertNotNil(try refs(bare)["refs/terminal-deck-backup/Test-Mac/heads/firebase"], "Firebase files and debug.keystore never hold a branch back")
        XCTAssertNil(try refs(bare)["refs/terminal-deck-backup/Test-Mac/heads/release"])
        XCTAssertTrue(outcome.line.contains("release: not sent: release.keystore is in its commits"), outcome.line)
        XCTAssertTrue(outcome.line.contains("1 file left out"), outcome.line)
        let work = try XCTUnwrap(try refs(bare)["refs/terminal-deck-backup/Test-Mac/work/main"])
        XCTAssertEqual(try git(bare, ["show", work + ":draft.md"]), "draft\n")
        XCTAssertThrowsError(try git(bare, ["show", work + ":.env.production"]), "his uncommitted .env.production is left out of the copy")
    }

    func testTheLeaveOutListIsWrittenOnlyInsideAGitTheAppMade() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try write(plain, "a.txt", "mine\n"); try write(plain, ".env", "TOKEN=fixture\n"); try write(plain, "node_modules/x/index.js", "big\n")
        let his = try homedRepo("his", github: github)
        let hisExclude = read(his, ".git/info/exclude")
        let rig = self.rig([PROJProject(id: "plain", name: "Plain", folders: [plain.path]), PROJProject(id: "his", name: "His", folders: [his.path])], github: github)
        let made = await rig.actions.backUp(projectID: "plain")
        XCTAssertTrue(made.ok, made.line)
        XCTAssertTrue(made.line.contains("1 file left out (secret files)"), made.line)
        XCTAssertTrue(read(plain, ".git/info/exclude")?.hasPrefix(BackendCodeBackupGitReader.excludeMarker) == true)
        XCTAssertNil(read(plain, ".gitignore"), "none of his files is touched")
        let work = try XCTUnwrap(try refs(github.bare("fixture-owner/plain"))["refs/terminal-deck-backup/Test-Mac/work/main"])
        let files = try git(github.bare("fixture-owner/plain"), ["ls-tree", "-r", "--name-only", work])
        XCTAssertEqual(files.trimmingCharacters(in: .whitespacesAndNewlines), "a.txt", "no secret file, no node_modules")
        let again = await rig.actions.backUp(projectID: "his")
        XCTAssertTrue(again.ok, again.line)
        XCTAssertEqual(read(his, ".git/info/exclude"), hisExclude, "a repository he already had is never given the list")
    }

    func testANestedOrganisationRepositoryGetsNothing() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("app", github: github)
        try write(repo, ".gitignore", "lib/\n"); try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", "ignore"], at: t2)
        let orgBare = try github.add("some-org/lib", isPrivate: true)
        let lib = repo.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try git(lib, ["init", "-q"]); try commit(lib, "lib.txt", "org code", at: t1)
        try git(lib, ["remote", "add", "origin", "https://github.com/some-org/lib.git"])
        try write(lib, "wip.txt", "his uncommitted work\n")
        let before = try refs(orgBare)
        let rig = self.rig([PROJProject(id: "app", name: "App", folders: [repo.path])], github: github)
        let outcome = await rig.actions.backUp(projectID: "app")
        XCTAssertTrue(outcome.ok, outcome.line)
        XCTAssertTrue(outcome.line.contains("github.com/some-org/lib is not on your account; not backed up"), outcome.line)
        XCTAssertEqual(try refs(orgBare), before, "the organisation's repository gets nothing")
    }

    func testGetTheCodeFromOnlyUncommittedBackupsPlacesTheFilesAndFromNothingFailsHonestly() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let draft = root.appendingPathComponent("draft", isDirectory: true)
        try write(draft, "notes.txt", "never committed\n")
        let first = self.rig([PROJProject(id: "draft", name: "Draft", folders: [draft.path])], github: github)
        let backedUp = await first.actions.backUp(projectID: "draft")
        XCTAssertTrue(backedUp.ok, backedUp.line)
        XCTAssertTrue(try refs(github.bare("fixture-owner/draft")).keys.allSatisfy { $0.contains("/work/") }, "only uncommitted work is on GitHub")
        // The second Mac.
        let folder = home.appendingPathComponent("Terminal Deck/Projects/Draft", isDirectory: true)
        try write(folder, "CLAUDE.md", "rules\n")
        let second = self.rig([PROJProject(id: "draft", name: "Draft", folders: [folder.path])], github: github, made: [folder.path])
        let got = await second.actions.getCode(projectID: "draft")
        XCTAssertTrue(got.ok, got.line)
        XCTAssertEqual(read(folder, "notes.txt"), "never committed\n")
        XCTAssertEqual(read(folder, "CLAUDE.md"), "rules\n")
        // A home with nothing at all: an honest line, nothing placed, no download left open.
        _ = try github.add("fixture-owner/empty", isPrivate: true)
        let emptyFolder = home.appendingPathComponent("Terminal Deck/Projects/Empty", isDirectory: true)
        try write(emptyFolder, "CLAUDE.md", "rules\n")
        let third = self.rig([PROJProject(id: "empty", name: "Empty", folders: [emptyFolder.path])], github: github, made: [emptyFolder.path])
        let nothing = await third.actions.getCode(projectID: "empty")
        XCTAssertFalse(nothing.ok)
        XCTAssertEqual(nothing.line, "Code not got: GitHub has no code for this project yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyFolder.appendingPathComponent(".git").path))
        XCTAssertNil(third.ledger.getting("empty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: GetCodePaths.temporary(emptyFolder.path)))
    }

    func testManualUntilTheFirstBackUpNowThenAutomaticButNeverOverHisChoice() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let eligible = try homedRepo("eligible", github: github)
        let pinned = try homedRepo("pinned", github: github)
        let clock = Clock()
        let rig = self.rig([PROJProject(id: "eligible", name: "Eligible", folders: [eligible.path]),
                            PROJProject(id: "pinned", name: "Pinned", folders: [pinned.path])], github: github, clock: clock)
        var report = await rig.actions.decorate(await rig.projects.report(refresh: true))
        XCTAssertTrue(report.automaticWaits)
        XCTAssertEqual(Set(report.projects.map(\.mode)), [.manual])
        try commit(eligible, "a.txt", "work", at: t2)
        for _ in 0..<4 { await rig.actions.look(); clock.advance(400) }
        XCTAssertTrue(try refs(github.bare("fixture-owner/eligible")).keys.allSatisfy { !$0.hasPrefix("refs/terminal-deck-backup/") }, "nothing automatic before the first Back up now")
        await rig.actions.setMode(projectID: "pinned", .manual)
        let first = await rig.actions.backUp(projectID: "pinned", byHand: true)
        XCTAssertTrue(first.ok, first.line)
        XCTAssertTrue(rig.ledger.firstBackupDone)
        report = await rig.actions.decorate(await rig.projects.report(refresh: true))
        XCTAssertFalse(report.automaticWaits)
        XCTAssertEqual(report.projects.first { $0.id == "eligible" }?.mode, .automatic)
        XCTAssertEqual(report.projects.first { $0.id == "pinned" }?.mode, .manual, "his own choice stays")
    }

    func testTwoMacsWithTheSameNameDoNotShareABackupArea() {
        let a = BackendCodeBackupActions.macPart(name: "Studio", hardware: BackendCodeBackupActions.deviceID("11111111-AAAA-4AAA-8AAA-111111111111"))
        let b = BackendCodeBackupActions.macPart(name: "Studio", hardware: BackendCodeBackupActions.deviceID("22222222-BBBB-4BBB-8BBB-222222222222"))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("Studio-") && b.hasPrefix("Studio-"), "the readable name stays")
        XCTAssertFalse(a.contains("11111111"), "the hardware id itself never appears")
        XCTAssertEqual(BackendCodeBackupPlan.part(a), a, "one reference part")
        XCTAssertEqual(a, BackendCodeBackupActions.macPart(name: "Studio", hardware: BackendCodeBackupActions.deviceID("11111111-aaaa-4aaa-8aaa-111111111111")), "stable")
    }

    // MARK: Last review fixes, 14 Nov

    func testABackUpThroughAToolNeverSwitchesOnAutomatic() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("tooled", github: github)
        try commit(repo, "a.txt", "work", at: t2)
        let rig = self.rig([PROJProject(id: "tooled", name: "Tooled", folders: [repo.path])], github: github)
        let viaTool = await rig.actions.backUp(projectID: "tooled")
        XCTAssertTrue(viaTool.ok, viaTool.line)
        XCTAssertFalse(rig.ledger.firstBackupDone, "only his own click on the page counts")
        await rig.actions.setMode(projectID: "tooled", .automatic)
        XCTAssertFalse(rig.ledger.firstBackupDone, "a tool's mode change is for that project only")
        XCTAssertEqual(rig.ledger.mode("tooled"), .automatic)
        let byHand = await rig.actions.backUp(projectID: "tooled", byHand: true)
        XCTAssertTrue(byHand.ok, byHand.line)
        XCTAssertTrue(rig.ledger.firstBackupDone)
    }

    func testAMergeThatAddsASecretIsHeldBack() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("merged", github: github)
        try git(repo, ["checkout", "-q", "-b", "side"]); try commit(repo, "side.txt", "side", at: t2); try git(repo, ["checkout", "-q", "main"])
        try commit(repo, "main.txt", "main", at: t2)
        try git(repo, ["merge", "--no-ff", "--no-commit", "-q", "side"])
        try write(repo, ".env", "TOKEN=fixture\n"); try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", "merge"], at: t3)
        try git(repo, ["branch", "-q", "-D", "side"])
        let rig = self.rig([PROJProject(id: "merged", name: "Merged", folders: [repo.path])], github: github)
        let outcome = await rig.actions.backUp(projectID: "merged")
        XCTAssertTrue(outcome.line.contains("main: not sent: .env is in its commits"), outcome.line)
        XCTAssertNil(try refs(github.bare("fixture-owner/merged"))["refs/terminal-deck-backup/Test-Mac/heads/main"])
    }

    func testAnOrganisationHomeIsBackUpNowOnly() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let repo = try homedRepo("team", github: github)
        try git(repo, ["remote", "set-url", "origin", "https://github.com/some-org/team.git"])
        try github.alias("some-org/team", to: "fixture-owner/team", canPush: true)
        try commit(repo, "a.txt", "work", at: t2)
        let bare = github.bare("fixture-owner/team")
        let clock = Clock()
        let rig = self.rig([PROJProject(id: "team", name: "Team", folders: [repo.path])], github: github, clock: clock)
        rig.ledger.setFirstBackupDone(); rig.ledger.setMode("team", .automatic)   // set earlier, however
        let before = try refs(bare)
        for _ in 0..<4 { await rig.actions.look(); clock.advance(400) }
        XCTAssertEqual(try refs(bare), before, "Automatic never runs on an organisation's home")
        let row = try unwrapNow(await rig.actions.decorate(await rig.projects.report(refresh: true)).projects.first)
        XCTAssertEqual(row.mode, .manual)
        XCTAssertEqual(row.modeChoices, [.manual, .off], "the control offers no Automatic")
        XCTAssertEqual(BackendCodeBackupWords.homeLine(row), "Home: some-org/team (organisation): Back up now only; everyone in some-org can see backups")
        await rig.actions.setMode(projectID: "team", .automatic)
        XCTAssertEqual(rig.ledger.mode("team"), .manual, "not even by a setting")
        let target = await rig.actions.target(projectID: "team")
        XCTAssertEqual(target?.organisation, "some-org")
        let manual = await rig.actions.backUp(projectID: "team", byHand: true)
        XCTAssertTrue(manual.ok, manual.line)
        XCTAssertNotNil(try refs(bare)["refs/terminal-deck-backup/Test-Mac/heads/main"], "Back up now still works")
    }

    func testHisOwnExcludeIsLeftAloneWhenGitAppearsBeforeTheAppsInit() async throws {
        let github = try FakeGitHub(root: root, git: { try self.git($0, $1) })
        let folder = root.appendingPathComponent("racing", isDirectory: true)
        try write(folder, "a.txt", "mine\n")
        let his = "# his own\n*.log\n"
        // His own `git init` (and his own exclude rule) lands between the app's look and its `init`.
        let runner = BeforeInit(real: writer()) { [self] cwd in
            guard cwd == folder.path, !FileManager.default.fileExists(atPath: folder.path + "/.git") else { return }
            try? self.git(folder, ["init", "-q"])
            try? self.write(folder, ".git/info/exclude", his)
        }
        let rig = self.rig([PROJProject(id: "racing", name: "Racing", folders: [folder.path])], github: github, git: runner)
        _ = await rig.actions.backUp(projectID: "racing")
        XCTAssertEqual(read(folder, ".git/info/exclude"), his, "his own exclude file is never overwritten")
        // Git's untouched template is replaced; anything with a rule of his is not.
        let fresh = root.appendingPathComponent("fresh/.git", isDirectory: true)
        try write(fresh, "info/exclude", "# git ls-files --others --exclude-from=.git/info/exclude\n# *~\n")
        XCTAssertTrue(BackendCodeBackupActions.writeExclude(gitDir: fresh.path))
        XCTAssertTrue(read(fresh, "info/exclude")?.hasPrefix(BackendCodeBackupGitReader.excludeMarker) == true)
    }

    func testMatchingAHomeForGetTheCode() {
        let repos = [BackendCodeBackupRepo(nameWithOwner: "org/my-site", isPrivate: true, canPush: true),
                     BackendCodeBackupRepo(nameWithOwner: "me/my-site", isPrivate: true, canPush: true),
                     BackendCodeBackupRepo(nameWithOwner: "org/tools", isPrivate: false, canPush: false)]
        XCTAssertEqual(BackendCodeBackupActions.match(name: "My Site", repositories: repos, login: "me"), "me/my-site")
        XCTAssertEqual(BackendCodeBackupActions.match(name: "Tools", repositories: repos, login: "me"), "org/tools")
        XCTAssertNil(BackendCodeBackupActions.match(name: "Nope", repositories: repos, login: "me"))
        XCTAssertEqual(BackendCodeBackupNames.repository("Deck Dev / Mac (new)!"), "deck-dev-mac-new")
        XCTAssertEqual(BackendCodeBackupNames.repository("🙂"), "project")
        XCTAssertEqual(BackendCodeBackupPlan.part("lane/code page"), "lane--code-page")
    }
}

// MARK: Fakes

enum GetCodePaths {
    static func temporary(_ folder: String) -> String { BackendCodeBackupGetCode.temporary(for: folder) }
}

/// GitHub's API as a fake: repositories are bare folders under the scratch root. Never reaches the network.
final class FakeGitHub: BackendCodeBackupAccount, @unchecked Sendable {
    let root: URL
    let run: (URL, [String]) throws -> String
    private let lock = NSLock()
    private var repos: [String: (repo: BackendCodeBackupRepo, folder: URL)] = [:]
    private(set) var created: [String] = []
    var account = "fixture-owner"
    /// What GitHub says about webhooks, deploy keys, Pages and all-repository apps on a home.
    var quietHomes = true

    init(root: URL, git: @escaping (URL, [String]) throws -> String) throws {
        self.root = root; self.run = git
    }

    @discardableResult
    func add(_ home: String, isPrivate: Bool, description: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent("github/" + home + ".git", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try run(folder, ["init", "-q", "--bare"])
        lock.withLock { repos[home.lowercased()] = (BackendCodeBackupRepo(nameWithOwner: home, isPrivate: isPrivate, canPush: true, description: description), folder) }
        return folder
    }
    func alias(_ home: String, to existing: String, canPush: Bool) throws {
        lock.withLock {
            if let found = repos[existing.lowercased()] {
                repos[home.lowercased()] = (BackendCodeBackupRepo(nameWithOwner: home, isPrivate: true, canPush: canPush), found.folder)
            }
        }
    }
    func bare(_ home: String) -> URL { lock.withLock { repos[home.lowercased()]?.folder } ?? root.appendingPathComponent("missing") }
    func repository(named home: String) -> BackendCodeBackupRepo? { lock.withLock { repos[home.lowercased()]?.repo } }

    func login() async -> String? { account }
    func repositories() async -> [BackendCodeBackupRepo] { lock.withLock { repos.values.map(\.repo).sorted { $0.nameWithOwner < $1.nameWithOwner } } }
    func repository(_ home: String) async -> BackendCodeBackupRepo? { repository(named: home) }
    func create(name: String, description: String) async -> BackendCodeBackupCreated {
        let home = account + "/" + name
        if repository(named: home) != nil { return .taken }
        guard (try? add(home, isPrivate: true, description: description)) != nil else { return .refused("fixture") }
        lock.withLock { created.append(home) }
        return .made(BackendCodeBackupRepo(nameWithOwner: home, isPrivate: true, canPush: true, description: description))
    }
    func quiet(_ home: String) async -> Bool { quietHomes }
    func transport(_ home: String) async -> BackendCodeBackupTransport? {
        guard repository(named: home) != nil else { return nil }
        return BackendCodeBackupTransport(url: bare(home).path, environment: BackendCodeBackupGitWriter.settings([("protocol.file.allow", "always")]))
    }
}

struct NoGitHub: BackendCodeBackupGitHubReading {
    func visibility(of homes: Set<String>) async -> BackendCodeBackupGitHubAnswer { .init(signedIn: true, found: [:]) }
}

/// The real Git, with something happening in the folder right before the app's `git init` runs.
final class BeforeInit: BackendCodeBackupGitRunning, @unchecked Sendable {
    let real: BackendCodeBackupGitWriter
    let before: (String) -> Void
    init(real: BackendCodeBackupGitWriter, before: @escaping (String) -> Void) { self.real = real; self.before = before }
    func run(cwd: String, arguments: [String], environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        if arguments.first == "init" { before(cwd) }
        return try await real.run(cwd: cwd, arguments: arguments, environment: environment, timeoutMilliseconds: timeoutMilliseconds, maximumBytes: maximumBytes)
    }
}

/// The real Git, except that the first command containing `word` fails as if the Mac had been interrupted.
final class FailingOnce: BackendCodeBackupGitRunning, @unchecked Sendable {
    let real: BackendCodeBackupGitWriter
    let word: String
    private let lock = NSLock()
    private var failed = false
    init(real: BackendCodeBackupGitWriter, word: String) { self.real = real; self.word = word }
    func run(cwd: String, arguments: [String], environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        let fail = lock.withLock { () -> Bool in
            guard !failed, arguments.contains(word) else { return false }
            failed = true; return true
        }
        if fail { return BackendGitOutcome(ok: false, stdout: "", stderr: "interrupted", missing: false, exitCode: 143, timedOut: true) }
        return try await real.run(cwd: cwd, arguments: arguments, environment: environment, timeoutMilliseconds: timeoutMilliseconds, maximumBytes: maximumBytes)
    }
}

/// INT2 (Swift 6): XCTUnwrap's argument is an autoclosure, so it cannot hold an `await`; this plain parameter can.
private func unwrapNow<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
