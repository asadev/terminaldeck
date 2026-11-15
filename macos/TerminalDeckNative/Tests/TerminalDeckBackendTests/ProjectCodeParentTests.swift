import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// CODE-PARENT (14 Nov): a repository ABOVE a project folder (a Mac whose whole home folder is a Git repository) is never
/// that project's code: not on the Code page, not on the project page, never committed or pushed. A project folder that
/// is a sub-folder of his own checkout keeps using that checkout. SCRATCH folders only; Git never climbs past `root`
/// (no ceiling on purpose for the project-page service, so the rule itself is what is proven).
final class ProjectCodeParentTests: XCTestCase {
    var root: URL!
    /// The same scratch folder as Finder and FileManager name it (/var/…, not /private/var/…).
    var unresolved: URL!
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var deck: URL { home.appendingPathComponent("Terminal Deck/Projects/Deck", isDirectory: true) }
    let context = NativeRPCContext(caller: .nativeApp, ownerID: "code-parent-fixture")

    override func setUpWithError() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("code-parent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Git names folders with every link resolved (/private/var…); so do the expectations.
        root = URL(fileURLWithPath: BackendProjectCode.resolved(scratch.path), isDirectory: true)
        unresolved = scratch
        BackendProjectCode.forgetAnswers()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("gitconfig"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var environment: [String: String] {
        let config = root.appendingPathComponent("gitconfig").path
        return ["HOME": home.path, "XDG_CONFIG_HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": config,
                "GIT_CEILING_DIRECTORIES": root.deletingLastPathComponent().path]
    }
    static let path = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

    @discardableResult
    func git(_ cwd: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "init.defaultBranch=main",
                             "-c", "commit.gpgsign=false"] + args
        var env = environment; env["PATH"] = Self.path
        process.environment = env
        process.currentDirectoryURL = cwd
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")]) }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    func write(_ folder: URL, _ name: String, _ text: String) throws {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func committedRepo(_ folder: URL, remote: String? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try git(folder, ["init", "-q"])
        try write(folder, "README.md", "hello\n")
        try git(folder, ["add", "-A"]); try git(folder, ["commit", "-q", "-m", "first"])
        if let remote { try git(folder, ["remote", "add", "origin", remote]) }
    }
    /// The home repository's own Git folder, byte for byte (what a commit, a push setting or a remote would change).
    func gitSnapshot(_ repo: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let git = repo.appendingPathComponent(".git")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: git, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result[String(url.path.dropFirst(git.path.count))] = try Data(contentsOf: url)
        }
        return result
    }

    /// The Mac's rule with the scratch home and its Terminal Deck folder; `made` folders were made by the app.
    func bounds(made: [URL] = []) -> BackendProjectCode.Bounds {
        let made = Set(made.map(\.path))
        return .init(homes: [home.path], base: home.appendingPathComponent("Terminal Deck").path, madeByApp: { made.contains($0) })
    }
    /// The Code page's reader WITHOUT the home ceiling, so only the rule keeps the home repository out.
    func reader(_ bounds: BackendProjectCode.Bounds) -> BackendCodeBackupGitReader {
        BackendCodeBackupGitReader(runner: BackendGitRunner(inheritedEnvironment: environment, loginPath: { Self.path }), context: context, bounds: bounds)
    }
    /// The project page's service (header, Code card, Code tab, phone Changes, git.* tools).
    func service(_ bounds: BackendProjectCode.Bounds) -> BackendGitService {
        let roots = [root!, unresolved!]
        return BackendGitService(authority: BackendFilesystemAuthority { _ in .init(readRoots: roots, writeRoots: roots) },
                                 runner: BackendGitRunner(inheritedEnvironment: environment, loginPath: { Self.path }), bounds: bounds)
    }
    func gitAvailable() throws {
        try XCTSkipUnless(["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].contains { FileManager.default.isExecutableFile(atPath: $0) }, "git not installed")
    }

    // MARK: The rule

    func testTheRule() {
        let b = bounds(made: [deck])
        let mono = root.appendingPathComponent("code/mono").path
        XCTAssertTrue(BackendProjectCode.belongs(top: mono, folder: mono, bounds: b), "its own repository")
        XCTAssertTrue(BackendProjectCode.belongs(top: mono + "/apps/web", folder: mono, bounds: b), "a repository inside the folder")
        XCTAssertTrue(BackendProjectCode.belongs(top: mono, folder: mono + "/apps/web", bounds: b), "a sub-folder of his own checkout")
        XCTAssertTrue(BackendProjectCode.belongs(top: home.path + "/code/mono", folder: home.path + "/code/mono/web", bounds: b), "a checkout in his home")
        XCTAssertFalse(BackendProjectCode.belongs(top: home.path, folder: home.path + "/code/plain", bounds: b), "the home folder's repository")
        XCTAssertFalse(BackendProjectCode.belongs(top: root.path, folder: home.path + "/code/plain", bounds: b), "a repository above the home folder")
        XCTAssertFalse(BackendProjectCode.belongs(top: "/", folder: home.path + "/code/plain", bounds: b), "a repository at /")
        XCTAssertFalse(BackendProjectCode.belongs(top: home.path + "/Terminal Deck", folder: deck.path, bounds: bounds()), "the Terminal Deck folder's repository")
        XCTAssertFalse(BackendProjectCode.belongs(top: home.path + "/Terminal Deck/Projects", folder: deck.path, bounds: b), "above a folder the app made")
        XCTAssertTrue(BackendProjectCode.belongs(top: home.path, folder: home.path, bounds: b), "a project whose folder IS the home repository")
        XCTAssertFalse(BackendProjectCode.belongs(top: root.path + "/elsewhere", folder: mono, bounds: b), "a top that does not hold the folder")
        // A session in a sub-folder of an app-made folder never reaches a repository above that app-made folder.
        let made = bounds(made: [URL(fileURLWithPath: mono + "/Deck")])
        XCTAssertFalse(BackendProjectCode.belongs(top: mono, folder: mono + "/Deck/src", bounds: made), "an app-made folder in between")
        XCTAssertTrue(BackendProjectCode.belongs(top: mono + "/Deck", folder: mono + "/Deck/src", bounds: made), "the app-made folder's own repository")
    }

    // MARK: The MacBook: home folder is a repository, the app made Terminal Deck/Projects/Deck with only instruction files

    func testAHomeRepositoryIsNeverTheCodeOfACloudOnlyProjectFolder() async throws {
        try gitAvailable()
        try committedRepo(home, remote: "https://github.com/fixture-owner/home.git")
        try write(deck, "CLAUDE.md", "# Deck\n"); try write(deck, "AGENTS.md", "# Deck\n"); try write(deck, ".claude/settings.json", "{}\n")
        let b = bounds(made: [deck]), before = try gitSnapshot(home)

        // Code page: "Code not on this Mac yet", no branch, no GitHub home, nothing to back up.
        let row = await reader(b).read(PROJProject(id: "deck", name: "Deck", folders: [deck.path])).0
        XCTAssertFalse(row.isRepository); XCTAssertNil(row.branch); XCTAssertNil(row.home); XCTAssertEqual(row.changedCount, 0)
        XCTAssertEqual(row.state, .codeNotHere)

        // Project page header and Code card: no branch, no "0 changed".
        let git = service(b)
        let status = try await git.status(cwd: deck.path, context: context)
        XCTAssertEqual(status["repo"].bool, false); XCTAssertEqual(status["reason"].string, "code-not-here")
        XCTAssertFalse(status.has("branch")); XCTAssertFalse(status.has("canInit"))
        let widget = GitWidgetRules.status(status.foundation)
        XCTAssertNil(widget.branchName); XCTAssertEqual(GitWidgetRules.notRepoTitle(widget.reason), "Code not on this Mac yet")
        XCTAssertEqual(GitRules.unavailable(GitStatusResult(json: status.foundation)).title, "Code not on this Mac yet")

        // Nothing acts on the home repository: no commit, no push, no diff, no Git folder to watch, no init.
        let commit = try await git.commitAll(cwd: deck.path, message: "should never happen", context: context)
        XCTAssertFalse(commit.ok)
        let push = try await git.push(cwd: deck.path, context: context)
        XCTAssertFalse(push.ok)
        let diff = try await git.diff(cwd: deck.path, path: "CLAUDE.md", options: .init(untracked: true), context: context)
        XCTAssertEqual(diff, "")
        let gitDir = try await git.gitDirectory(cwd: deck.path, context: context)
        XCTAssertNil(gitDir)
        let watched = try await git.metadataDirectories(cwd: deck.path, context: context)
        XCTAssertEqual(watched, [])
        let initialised = try await git.initialize(cwd: deck.path, context: context)
        XCTAssertEqual(initialised["repo"].bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deck.appendingPathComponent(".git").path))
        XCTAssertEqual(try gitSnapshot(home), before, "the home repository was changed")
    }

    func testCodeWrittenThereWithoutItsOwnRepositoryIsAPlainFolderNotTheHome() async throws {
        try gitAvailable()
        try committedRepo(home)
        try write(deck, "CLAUDE.md", "# Deck\n"); try write(deck, "main.swift", "print(1)\n")
        let b = bounds(made: [deck]), before = try gitSnapshot(home)
        let row = await reader(b).read(PROJProject(id: "deck", name: "Deck", folders: [deck.path])).0
        XCTAssertFalse(row.isRepository); XCTAssertNil(row.branch); XCTAssertEqual(row.state, .noHome)
        let git = service(b)
        let status = try await git.status(cwd: deck.path, context: context)
        XCTAssertEqual(status["repo"].bool, false); XCTAssertEqual(status["reason"].string, "not-a-repo"); XCTAssertEqual(status["canInit"].bool, true)
        let commit = try await git.commitAll(cwd: deck.path, message: "should never happen", context: context)
        XCTAssertFalse(commit.ok)
        XCTAssertEqual(try gitSnapshot(home), before, "the home repository was changed")
    }

    func testAPlainFolderOfHisInsideAHomeRepositoryIsNotTheHome() async throws {
        try gitAvailable()
        try committedRepo(home)
        let plain = home.appendingPathComponent("Work/notes", isDirectory: true)
        try write(plain, "notes.md", "hi\n")
        let row = await reader(bounds()).read(PROJProject(id: "notes", name: "Notes", folders: [plain.path])).0
        XCTAssertFalse(row.isRepository); XCTAssertEqual(row.state, .noHome)
        let status = try await service(bounds()).status(cwd: plain.path, context: context)
        XCTAssertEqual(status["repo"].bool, false); XCTAssertEqual(status["reason"].string, "not-a-repo")
    }

    func testOnceTheCodeIsThereWithItsOwnRepositoryThatRepositoryIsUsed() async throws {
        try gitAvailable()
        try committedRepo(home)
        try write(deck, "CLAUDE.md", "# Deck\n")
        try write(deck, "main.swift", "print(1)\n")
        try git(deck, ["init", "-q"]); try git(deck, ["add", "-A"]); try git(deck, ["commit", "-q", "-m", "code"])
        try write(deck, "main.swift", "print(2)\n")
        let b = bounds(made: [deck])
        let row = await reader(b).read(PROJProject(id: "deck", name: "Deck", folders: [deck.path])).0
        XCTAssertTrue(row.isRepository); XCTAssertEqual(row.branch, "main"); XCTAssertEqual(row.changedCount, 1)
        let status = try await service(b).status(cwd: deck.path, context: context)
        XCTAssertEqual(status["repo"].bool, true)
        XCTAssertEqual(status["root"].string, deck.path)
        XCTAssertEqual(status["branch"]["name"].string, "main")
        XCTAssertEqual((status["unstaged"].elements ?? []).count, 1)
    }

    // MARK: Task workspaces (and the Chat worktrees and parallel jobs built on them)

    func workspaces(_ b: BackendProjectCode.Bounds) throws -> BackendWorkspaceService {
        try BackendWorkspaceService(userData: root.appendingPathComponent("data"), git: service(b), ownership: .memory)
    }

    func testATaskGetsNoWorkspaceFromTheHomeRepository() async throws {
        try gitAvailable()
        try committedRepo(home)
        try write(deck, "CLAUDE.md", "# Deck\n"); try write(deck, ".claude/settings.json", "{}\n")
        let b = bounds(made: [deck]), before = try gitSnapshot(home)
        let service = try workspaces(b)
        let none = try await service.folderFor(taskID: "task-1", project: deck.path, useWorkspace: true, title: "Fix it", context: context)
        XCTAssertNil(none)
        let refusal = try await service.view(taskID: "task-1", context: context)["refusal"].string
        XCTAssertEqual(refusal, "This project's code is not on this Mac yet, so the task runs in its project folder.")
        // Code written there, still no repository of its own: still none, and still nothing in the home repository.
        try write(deck, "main.swift", "print(1)\n")
        let still = try await service.folderFor(taskID: "task-2", project: deck.path, useWorkspace: true, title: "Fix it", context: context)
        XCTAssertNil(still)
        let second = try await service.view(taskID: "task-2", context: context)["refusal"].string
        XCTAssertEqual(second, "This folder has no Git repository of its own, so the task runs in its project folder.")
        XCTAssertEqual(try gitSnapshot(home), before, "the home repository was changed")
        XCTAssertEqual(try git(home, ["branch", "--list"]).split(separator: "\n").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/workspaces").path))
    }

    func testOtherOwnersSeeNoRepositoryAboveTheFolder() async throws {
        try gitAvailable()
        try committedRepo(home)
        try write(deck, "CLAUDE.md", "# Deck\n")
        let b = bounds(made: [deck])
        XCTAssertEqual(BackendProjectCode.nearestTop(deck.path), home.path)
        let gitService = service(b)
        let refusedDeck = await gitService.refuses(deck.path, context: context)
        XCTAssertTrue(refusedDeck)
        let files = try await service(b).listFiles(cwd: deck.path, context: context)
        XCTAssertNil(files, "the file list walks the folder itself, not the home repository's index")
        let mono = root.appendingPathComponent("code/mono", isDirectory: true)
        try committedRepo(mono)
        try write(mono, "apps/web/index.html", "hi\n"); try git(mono, ["add", "-A"]); try git(mono, ["commit", "-q", "-m", "web"])
        let apps = await gitService.refuses(mono.appendingPathComponent("apps").path, context: context)
        XCTAssertFalse(apps, "a sub-folder of his own checkout that it keeps files in")
        let empty = root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let loose = await gitService.refuses(empty.path, context: context)
        XCTAssertFalse(loose, "no repository at all is not refused")
    }

    // MARK: The legitimate case: a project folder that is a sub-folder of his own checkout

    func testASubFolderOfHisOwnCheckoutStillUsesTheCheckout() async throws {
        try gitAvailable()
        let mono = root.appendingPathComponent("code/mono", isDirectory: true)
        try committedRepo(mono, remote: "https://github.com/fixture-owner/mono.git")
        let web = mono.appendingPathComponent("apps/web", isDirectory: true)
        try write(web, "index.html", "<p>hi</p>\n")
        try git(mono, ["add", "-A"]); try git(mono, ["commit", "-q", "-m", "web"])
        try write(web, "index.html", "<p>hello</p>\n")
        let row = await reader(bounds()).read(PROJProject(id: "web", name: "Web", folders: [web.path])).0
        XCTAssertTrue(row.isRepository); XCTAssertEqual(row.branch, "main"); XCTAssertEqual(row.home, "fixture-owner/mono")
        let status = try await service(bounds()).status(cwd: web.path, context: context)
        XCTAssertEqual(status["repo"].bool, true); XCTAssertEqual(status["root"].string, mono.path)
        XCTAssertEqual(status["branch"]["name"].string, "main")
        XCTAssertEqual((status["unstaged"].elements ?? []).count, 1)
    }

    func testANewEmptySubFolderOfAMonorepoIsAPlainFolderUntilSomethingInItIsCommitted() async throws {
        try gitAvailable()
        let mono = root.appendingPathComponent("code/mono", isDirectory: true)
        try committedRepo(mono)
        let fresh = mono.appendingPathComponent("apps/new", isDirectory: true)
        try write(fresh, "draft.txt", "draft\n")
        let git = service(bounds())
        let before = try await git.status(cwd: fresh.path, context: context)
        XCTAssertEqual(before["repo"].bool, false); XCTAssertEqual(before["reason"].string, "not-a-repo")
        try self.git(mono, ["add", "-A"]); try self.git(mono, ["commit", "-q", "-m", "new app"])
        let after = try await git.status(cwd: fresh.path, context: context)
        XCTAssertEqual(after["repo"].bool, true); XCTAssertEqual(after["root"].string, mono.path)
    }

    // MARK: A big unrelated repository one level down (~/Documents), push to a real remote, unresolved paths, worktrees

    func testARepositoryAtDocumentsIsNotTheCodeOfAProjectInsideIt() async throws {
        try gitAvailable()
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        try committedRepo(documents)
        try write(documents, "taxes/2025.txt", "private\n"); try git(documents, ["add", "-A"]); try git(documents, ["commit", "-q", "-m", "taxes"])
        let foo = documents.appendingPathComponent("Foo", isDirectory: true)
        try write(foo, "main.swift", "print(1)\n")
        let before = try gitSnapshot(documents)
        let row = await reader(bounds()).read(PROJProject(id: "foo", name: "Foo", folders: [foo.path])).0
        XCTAssertFalse(row.isRepository); XCTAssertNil(row.branch); XCTAssertEqual(row.state, .noHome)
        let git = service(bounds())
        let status = try await git.status(cwd: foo.path, context: context)
        XCTAssertEqual(status["repo"].bool, false); XCTAssertFalse(status.has("branch"))
        let commit = try await git.commitAll(cwd: foo.path, message: "should never happen", context: context)
        XCTAssertFalse(commit.ok)
        let task = try await workspaces(bounds()).folderFor(taskID: "foo-task", project: foo.path, useWorkspace: true, title: "x", context: context)
        XCTAssertNil(task)
        XCTAssertEqual(try gitSnapshot(documents), before, "the Documents repository was changed")
    }

    func testPushNeverReachesTheHomeRepositorysRealRemote() async throws {
        try gitAvailable()
        let bare = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try git(bare, ["init", "-q", "--bare"])
        try committedRepo(home, remote: bare.path)
        try git(home, ["push", "-q", "-u", "origin", "main"])
        try write(home, "diary.txt", "not for GitHub\n")
        try write(deck, "CLAUDE.md", "# Deck\n")
        let b = bounds(made: [deck]), homeBefore = try gitSnapshot(home), remoteBefore = try bareSnapshot(bare)
        let git = service(b)
        for folder in [deck.path, unresolvedPath(deck)] {
            let push = try await git.push(cwd: folder, context: context)
            XCTAssertFalse(push.ok, folder)
            let commit = try await git.commitAll(cwd: folder, message: "should never happen", context: context)
            XCTAssertFalse(commit.ok, folder)
        }
        // Code written there: still a plain folder (no repository of its own), still nothing pushed.
        try write(deck, "main.swift", "print(1)\n")
        let push = try await git.push(cwd: deck.path, context: context)
        XCTAssertFalse(push.ok)
        XCTAssertEqual(try gitSnapshot(home), homeBefore, "the home repository was changed")
        XCTAssertEqual(try bareSnapshot(bare), remoteBefore, "the home repository's remote was changed")
    }

    func testAnUnresolvedVarPathReadsTheSameAsTheResolvedOne() async throws {
        try gitAvailable()
        try committedRepo(home)
        try write(deck, "CLAUDE.md", "# Deck\n")
        let b = bounds(made: [deck]), path = unresolvedPath(deck)
        XCTAssertNotEqual(path, deck.path)
        let row = await reader(b).read(PROJProject(id: "deck", name: "Deck", folders: [path])).0
        XCTAssertEqual(row.state, .codeNotHere)
        let unresolvedService = service(b)
        let status = try await unresolvedService.status(cwd: path, context: context)
        XCTAssertEqual(status["reason"].string, "code-not-here")
        try write(deck, "main.swift", "print(1)\n")
        let plain = try await unresolvedService.status(cwd: path, context: context)
        XCTAssertEqual(plain["repo"].bool, false); XCTAssertEqual(plain["reason"].string, "not-a-repo")
    }

    func testAProjectWhoseFolderIsAGitWorktreeUsesThatWorktree() async throws {
        try gitAvailable()
        let mono = root.appendingPathComponent("code/mono", isDirectory: true)
        try committedRepo(mono)
        let tree = root.appendingPathComponent("code/mono-feature", isDirectory: true)
        try git(mono, ["worktree", "add", "-q", "-b", "feature", tree.path])
        try write(tree, "README.md", "changed\n")
        let row = await reader(bounds()).read(PROJProject(id: "tree", name: "Tree", folders: [tree.path])).0
        XCTAssertTrue(row.isRepository); XCTAssertEqual(row.branch, "feature"); XCTAssertEqual(row.changedCount, 1)
        let status = try await service(bounds()).status(cwd: tree.path, context: context)
        XCTAssertEqual(status["repo"].bool, true); XCTAssertEqual(status["root"].string, tree.path)
        XCTAssertEqual(status["branch"]["name"].string, "feature")
    }

    func unresolvedPath(_ url: URL) -> String { unresolved.path + String(url.path.dropFirst(root.path.count)) }
    func bareSnapshot(_ bare: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: bare, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result[String(url.path.dropFirst(bare.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
}
