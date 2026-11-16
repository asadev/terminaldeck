import CryptoKit
import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// L5 slice 1: the Code page's model on SCRATCH repositories only (a temporary folder, a local bare remote standing in
/// for GitHub through `url.<bare>.insteadOf`, no global or system Git config), and a fake GitHub HTTP layer. Every
/// query must leave the repository byte-identical: working files, staging area, refs, stash and everything in .git.
final class BackendCodeBackupProjectsTests: XCTestCase {
    typealias P = BackendCodeBackupProject
    var root: URL!
    let t1: Int64 = 1_794_000_000, t2: Int64 = 1_794_000_600, t3: Int64 = 1_794_001_200

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("code-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("home/gitconfig"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Scratch helpers

    var environment: [String: String] {
        let home = root.appendingPathComponent("home").path
        return ["HOME": home, "XDG_CONFIG_HOME": home, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": home + "/gitconfig"]
    }
    static let path = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

    @discardableResult
    func git(_ cwd: URL, _ args: [String], at seconds: Int64? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "init.defaultBranch=main",
                             "-c", "commit.gpgsign=false"] + args
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

    func write(_ repo: URL, _ name: String, _ text: String) throws {
        let file = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func repo(_ name: String) throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-q"])
        return repo
    }

    func commit(_ repo: URL, _ file: String, _ message: String, at seconds: Int64) throws {
        try write(repo, file, message + "\n")
        try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", message], at: seconds)
    }

    /// A repository whose origin reads as github.com/fixture-owner/<name> and really pushes to a bare folder here.
    func pushedRepo(_ name: String) throws -> URL {
        let bare = root.appendingPathComponent(name + "-remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try git(bare, ["init", "-q", "--bare"])
        let repo = try repo(name)
        let home = "https://github.com/fixture-owner/\(name).git"
        try git(repo, ["remote", "add", "origin", home])
        try git(repo, ["config", "url.\(bare.path).insteadOf", home])
        try commit(repo, "README.md", "first", at: t1)
        try git(repo, ["push", "-q", "-u", "origin", "main"])
        return repo
    }

    func reader(path: String = BackendCodeBackupProjectsTests.path, runner: (any BackendGitExecuting)? = nil, projectSeconds: Double = 30,
                folderSeconds: Double = 5, isDirectory: BackendCodeBackupGitReader.IsDirectory? = nil) -> BackendCodeBackupGitReader {
        let env = BackendCodeBackupGitReader.environment(environment, home: root.appendingPathComponent("home").path)
        return BackendCodeBackupGitReader(runner: runner ?? BackendGitRunner(inheritedEnvironment: env, loginPath: { path }),
                                          context: .init(caller: .nativeApp, ownerID: "code-backup-fixture"),
                                          projectSeconds: projectSeconds, folderSeconds: folderSeconds,
                                          isDirectory: isDirectory ?? { BackendCodeBackupGitReader.directory($0) })
    }

    func read(_ folders: [String], name: String = "Fixture", reader: BackendCodeBackupGitReader? = nil) async -> P {
        await (reader ?? self.reader()).read(PROJProject(id: "fixture", name: name, folders: folders)).0
    }

    /// Every file under the repository, .git included: its bytes (or, above 1 MB, its size and modification time).
    func snapshot(_ repo: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: repo, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]))
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            let key = String(url.path.dropFirst(repo.path.count))
            if values.isSymbolicLink == true { result[key] = "link"; continue }
            guard values.isRegularFile == true else { result[key] = "dir"; continue }
            if (values.fileSize ?? 0) > 1_000_000 { result[key] = "\(values.fileSize ?? 0)@\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"; continue }
            result[key] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    func readUnchanged(_ repo: URL, _ file: StaticString = #filePath, _ line: UInt = #line) async throws -> P {
        let before = try snapshot(repo)
        let row = await read([repo.path])
        let after = try snapshot(repo)
        XCTAssertEqual(before, after, "the read changed something in the repository", file: file, line: line)
        return row
    }

    let now = Date(timeIntervalSince1970: 1_794_003_000)
    let utc = TimeZone(identifier: "UTC")!

    // MARK: Scratch repositories

    func testCleanPushedRepositoryIsBackedUp() async throws {
        let repo = try pushedRepo("clean")
        let row = try await readUnchanged(repo)
        XCTAssertNil(row.problem)
        XCTAssertTrue(row.hasFolder && row.isRepository)
        XCTAssertEqual(row.home, "fixture-owner/clean")
        XCTAssertEqual(row.branch, "main")
        XCTAssertEqual(row.lastBackedUpAt, t1 * 1000)
        XCTAssertEqual(row.changedCount, 0); XCTAssertEqual(row.commitCount, 0); XCTAssertEqual(row.held, [])
        XCTAssertEqual(row.state, .backedUp)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "Backed up")
        XCTAssertEqual(BackendCodeBackupWords.lastBackedUp(row, now: now, timeZone: utc), "Last backed up Today, 21:20")
    }

    func testAheadOfTheRemoteAndDirtyWithAStash() async throws {
        let repo = try pushedRepo("ahead")
        try commit(repo, "a.txt", "second", at: t2)
        try commit(repo, "b.txt", "third", at: t3)
        try write(repo, "a.txt", "stashed\n"); try git(repo, ["stash", "-q"])
        try write(repo, "README.md", "edited\n"); try write(repo, "notes/new.txt", "new\n")
        try git(repo, ["add", "README.md"]) // staged change: the staging area must stay exactly as it is
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.lastBackedUpAt, t1 * 1000, "the newest commit of his that is on the remote")
        XCTAssertEqual(row.commitCount, 2)
        XCTAssertEqual(row.commits.map(\.subject), ["third", "second"])
        XCTAssertEqual(row.changedCount, 2)
        XCTAssertEqual(Set(row.changedFiles), ["README.md", "notes/new.txt"])
        XCTAssertEqual(row.lastCommitAt, t3 * 1000)
        XCTAssertEqual(row.state, .commitsNotOnGitHub)
        XCTAssertEqual(row.setAsideCount, 1)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "2 commits not on GitHub · 2 files changed since 21:40 · 1 set-aside change not on GitHub")
        XCTAssertEqual(try git(repo, ["stash", "list"]).split(separator: "\n").count, 1, "the stash is still there")
    }

    func testABranchPushedLaterCountsAsBackedUp() async throws {
        let repo = try pushedRepo("branches")
        try git(repo, ["checkout", "-q", "-b", "feature"])
        try commit(repo, "f.txt", "feature work", at: t2)
        try git(repo, ["push", "-q", "origin", "feature"])
        try git(repo, ["checkout", "-q", "main"])
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.lastBackedUpAt, t2 * 1000, "any of his branches")
        XCTAssertEqual(row.state, .backedUp)
    }

    func testNoRemoteMeansNoGitHubHome() async throws {
        let repo = try repo("local")
        try commit(repo, "a.txt", "only here", at: t1)
        let row = try await readUnchanged(repo)
        XCTAssertNil(row.home); XCTAssertNil(row.lastBackedUpAt)
        XCTAssertEqual(row.state, .noHome)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "Not on GitHub yet")
        XCTAssertEqual(BackendCodeBackupWords.lastBackedUp(row, now: now, timeZone: utc), "Never backed up")
    }

    func testARemoteNeverPushedHasEveryCommitWaiting() async throws {
        let repo = try repo("never")
        try git(repo, ["remote", "add", "origin", "git@github.com:fixture-owner/never.git"])
        try commit(repo, "a.txt", "one", at: t1); try commit(repo, "b.txt", "two", at: t2)
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.home, "fixture-owner/never")
        XCTAssertEqual(row.commitCount, 2); XCTAssertNil(row.lastBackedUpAt)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "2 commits not on GitHub")
    }

    func testDetachedHead() async throws {
        let repo = try pushedRepo("detached")
        try commit(repo, "a.txt", "second", at: t2)
        try git(repo, ["checkout", "-q", "--detach", "HEAD~1"])
        let row = try await readUnchanged(repo)
        XCTAssertNil(row.branch)
        XCTAssertEqual(row.commitCount, 1, "main's unpushed commit")
        XCTAssertEqual(BackendCodeBackupTools.wire(.init(projects: [row], signedInToGitHub: false, checkedAt: 0), now: now, timeZone: utc)["projects"].elements?.first?["branch"].string,
                       BackendCodeBackupWords.notOnBranch)
    }

    func testHugeIgnoredFolderLargeFileAndSecretFile() async throws {
        let repo = try pushedRepo("heavy")
        try write(repo, ".gitignore", "build/\n")
        try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", "ignore build"], at: t2)
        try git(repo, ["push", "-q"])
        for folder in 0..<20 { for file in 0..<150 { try write(repo, "build/f\(folder)/o\(file).o", "x") } }
        let big = repo.appendingPathComponent("media/big.mov")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: 60 * 1024 * 1024); try handle.close() // sparse: no disk used
        try write(repo, ".env", "KEY=fixture\n"); try write(repo, ".env.example", "KEY=\n"); try write(repo, "config/server.pem", "fixture\n")
        let started = Date()
        let row = try await readUnchanged(repo)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the ignored folder is never walked")
        XCTAssertEqual(row.changedCount, 4, "big.mov, .env, .env.example, server.pem; nothing under build/")
        XCTAssertFalse(row.changedFiles.contains { $0.hasPrefix("build/") })
        // Lead's three kinds (14 Nov): .env.example is left out of the uncommitted copy; a .pem with no private key in it
        // is not secret at all.
        XCTAssertEqual(row.held, [.init(name: ".env", reason: .looksSecret), .init(name: ".env.example", reason: .looksSecret),
                                  .init(name: "media/big.mov", reason: .tooLarge)])
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc),
                       "4 files changed since 21:30 · 1 file too large · 2 secret files not sent to GitHub")
    }

    func testPlainFolderAndNoFolder() async throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let row = await read([plain.path])
        XCTAssertTrue(row.hasFolder); XCTAssertFalse(row.isRepository); XCTAssertNil(row.problem)
        XCTAssertEqual(row.folderName, "plain")
        XCTAssertEqual(row.state, .noHome)
        let none = await read([])
        XCTAssertEqual(none.state, .noFolder)
        XCTAssertEqual(BackendCodeBackupWords.summary(none, now: now), "No code folder on this Mac")
        XCTAssertEqual(BackendCodeBackupWords.lastBackedUp(none, now: now), "")
        let gone = await read([root.appendingPathComponent("gone").path])
        XCTAssertEqual(gone.state, .noFolder)
    }

    func testGitMissingCouldNotCheck() async throws {
        let repo = try pushedRepo("nogit")
        let row = await read([repo.path], reader: reader(path: root.appendingPathComponent("no-bin").path))
        XCTAssertEqual(row.state, .couldNotCheck)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now), "Could not check (Git is not installed on this Mac)")
    }

    // MARK: The model: GitHub, cache, order

    final class FakeHTTP: BackendGitHubHTTPFetching, @unchecked Sendable {
        let lock = NSLock(); var asked: [(url: String, headers: [String: String])] = []
        func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse {
            lock.withLock { asked.append((url, headers)) }
            if url.hasSuffix("/repos/fixture-owner/clean") { return .init(status: 200, body: #"{"full_name":"fixture-owner/clean","private":true}"#) }
            return .init(status: 404, body: #"{"message":"Not Found"}"#)
        }
    }

    final class CountingRunner: BackendGitExecuting, @unchecked Sendable {
        let inner: BackendGitRunner; let lock = NSLock(); var calls = 0
        init(_ inner: BackendGitRunner) { self.inner = inner }
        func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
            XCTAssertFalse(writing, "the Code page never asks Git to write")
            lock.withLock { calls += 1 }
            return try await inner.run(cwd: cwd, arguments: arguments, context: context, writing: writing, timeoutMilliseconds: timeoutMilliseconds, maximumBytes: maximumBytes)
        }
    }

    func testPrivatePublicFromGitHubAndTheCache() async throws {
        let clean = try pushedRepo("clean"), site = try pushedRepo("site")
        let env = environment
        let counting = CountingRunner(BackendGitRunner(inheritedEnvironment: env, loginPath: { Self.path }))
        let http = FakeHTTP()
        let github = BackendCodeBackupGitHub(host: "github.com", http: http,
            account: { .init(signedIn: true, listed: ["fixture-owner/site": false]) }, token: { "fixture-token-not-real" })
        let projects = [PROJProject(id: "a", name: "Clean", folders: [clean.path]), PROJProject(id: "b", name: "Site", folders: [site.path]),
                        PROJProject(id: "c", name: "Notes")]
        let model = BackendCodeBackupProjects(projects: { projects }, reader: reader(runner: counting), github: github)
        let facts = await model.report()
        XCTAssertNil(facts.signedInToGitHub, "the Git facts come first, before GitHub has answered")
        XCTAssertEqual(facts.projects.first?.visibility, .notChecked)
        let report = await model.withGitHub(facts)
        XCTAssertEqual(report.signedInToGitHub, true)
        XCTAssertEqual(report.projects.map(\.name), ["Clean", "Site", "Notes"])
        XCTAssertEqual(report.projects.first { $0.name == "Clean" }?.visibility, .isPrivate)
        XCTAssertEqual(report.projects.first { $0.name == "Site" }?.visibility, .isPublic, "from the sign-in's own list, no request")
        XCTAssertEqual(http.asked.map(\.url), ["https://api.github.com/repos/fixture-owner/clean"])
        XCTAssertEqual(http.asked.first?.headers["Authorization"], "Bearer fixture-token-not-real")
        let wire = String(decoding: try BackendCodeBackupTools.wire(report, now: now).encodedJSON(), as: UTF8.self)
        XCTAssertFalse(wire.contains("fixture-token"), "a token never leaves in a result")
        XCTAssertFalse(wire.contains(root.path), "names, never paths")
        XCTAssertFalse(wire.contains("\"a\""), "no project ids")
        // Kept until something changes: a second look runs no Git at all.
        let calls = counting.calls
        _ = await model.report()
        XCTAssertEqual(counting.calls, calls)
        // GitHub's answers are kept: asked again within five minutes, nothing is fetched.
        let kept = await model.withGitHub(await model.report())
        XCTAssertEqual(http.asked.count, 1)
        XCTAssertEqual(kept.projects.first { $0.name == "Clean" }?.visibility, .isPrivate)
        // A commit changes HEAD: that project alone is read again.
        try commit(site, "x.txt", "later", at: t3)
        let after = await model.report()
        XCTAssertGreaterThan(counting.calls, calls)
        XCTAssertEqual(after.projects.first?.name, "Site", "what needs him comes first")
        XCTAssertEqual(after.projects.first?.commitCount, 1)
        // Refresh reads everything again.
        let beforeRefresh = counting.calls
        _ = await model.report(refresh: true)
        XCTAssertGreaterThan(counting.calls, beforeRefresh)
    }

    func testSignedOutShowsNotChecked() async throws {
        let clean = try pushedRepo("clean")
        let http = FakeHTTP()
        let github = BackendCodeBackupGitHub(host: "github.com", http: http, account: { .init(signedIn: false, listed: [:]) }, token: { nil })
        let model = BackendCodeBackupProjects(projects: { [PROJProject(id: "a", name: "Clean", folders: [clean.path])] }, reader: reader(), github: github)
        let report = await model.withGitHub(await model.report())
        XCTAssertEqual(report.signedInToGitHub, false)
        XCTAssertEqual(report.projects.first?.visibility, .notChecked)
        XCTAssertEqual(report.projects.first?.state, .backedUp, "everything git can tell locally still shows")
        XCTAssertTrue(http.asked.isEmpty)
        XCTAssertEqual(BackendCodeBackupTools.wire(report, now: now)["note"].string, "GitHub is not connected")
    }

    // MARK: Review fixes (cf73a463): never "Backed up" while work exists only here

    func testAChangedSubmoduleCountsAsAChangedFile() async throws {
        let sub = try pushedRepo("library")
        let repo = try pushedRepo("withsub")
        try git(repo, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.path, "library"])
        try git(repo, ["commit", "-q", "-m", "add library"], at: t2); try git(repo, ["push", "-q"])
        try write(repo, "library/README.md", "changed inside the submodule\n")
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.changedFiles, ["library"])
        XCTAssertEqual(row.state, .filesChanged)
    }

    func testAnUnpushedCommitInsideASubmoduleIsNotBackedUp() async throws {
        let sub = try pushedRepo("widgets")
        let repo = try pushedRepo("outer")
        try git(repo, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.path, "widgets"])
        try git(repo, ["commit", "-q", "-m", "add widgets"], at: t2); try git(repo, ["push", "-q"])
        let inside = repo.appendingPathComponent("widgets")
        try commit(inside, "w.txt", "made inside the submodule", at: t3)
        try git(repo, ["add", "widgets"]); try git(repo, ["commit", "-q", "-m", "move widgets"], at: t3); try git(repo, ["push", "-q"])
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.parts.map { $0.folderName ?? "" }, ["outer", "widgets"])
        XCTAssertEqual(row.parts.first?.state, .backedUp, "the outer project itself is clean and pushed")
        XCTAssertEqual(row.parts.last?.commitCount, 1)
        XCTAssertNotEqual(row.state, .backedUp)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "widgets: 1 commit not pushed")
    }

    func testAPlainFolderBesideAPushedRepositoryIsNotBackedUp() async throws {
        let repo = try pushedRepo("pushed")
        let plain = root.appendingPathComponent("designs", isDirectory: true)
        try write(plain, "logo.sketch", "only here\n")
        let row = await read([repo.path, plain.path])
        XCTAssertEqual(row.parts.map(\.state), [.backedUp, .noHome])
        XCTAssertEqual(row.state, .noHome)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "designs: Not on GitHub yet")
    }

    func testANestedRepositoryTheGitignoreHidesIsItsOwnRow() async throws {
        let repo = try pushedRepo("host")
        try write(repo, ".gitignore", "vendor/\n")
        try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", "ignore vendor"], at: t2); try git(repo, ["push", "-q"])
        let nested = repo.appendingPathComponent("vendor/tool", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try git(nested, ["init", "-q"]); try commit(nested, "t.txt", "only here", at: t3)
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.parts.map { $0.folderName ?? "" }, ["host", "tool"])
        XCTAssertEqual(row.state, .noHome)
        XCTAssertEqual(BackendCodeBackupGitReader.nested(in: repo.path), [nested.path])
    }

    func testOnlyAStashIsNotBackedUp() async throws {
        let repo = try pushedRepo("stashonly")
        try write(repo, "README.md", "set aside\n"); try git(repo, ["stash", "-q"])
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.changedCount, 0); XCTAssertEqual(row.commitCount, 0); XCTAssertEqual(row.setAsideCount, 1)
        XCTAssertEqual(row.state, .setAside)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "1 set-aside change not on GitHub")
    }

    func testACommitOnlyOnAnotherRemoteIsNotOnGitHub() async throws {
        let repo = try pushedRepo("tworemotes")
        let other = root.appendingPathComponent("elsewhere.git", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try git(other, ["init", "-q", "--bare"])
        try git(repo, ["remote", "add", "backup", other.path])
        try commit(repo, "a.txt", "only on backup", at: t2)
        try git(repo, ["push", "-q", "backup", "main"])
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.home, "fixture-owner/tworemotes")
        XCTAssertEqual(row.commitCount, 1)
        XCTAssertEqual(row.lastBackedUpAt, t1 * 1000)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "1 commit not on GitHub")
    }

    func testEveryCodeFolderIsReadAndTheWorstShows() async throws {
        let clean = try pushedRepo("api"), dirty = try pushedRepo("app")
        try write(dirty, "new.txt", "new\n")
        let plain = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let before = (try snapshot(clean), try snapshot(dirty))
        let row = await read([clean.path, plain.path, dirty.path, dirty.appendingPathComponent(".git").deletingLastPathComponent().path])
        XCTAssertEqual(before.0, try snapshot(clean)); XCTAssertEqual(before.1, try snapshot(dirty))
        XCTAssertEqual(row.parts.map { $0.folderName ?? "" }, ["api", "docs", "app"], "each repository once; the plain folder is its own row")
        XCTAssertEqual(row.parts[1].state, .noHome)
        XCTAssertEqual(row.state, .filesChanged)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "app: 1 file changed since 21:20")
        XCTAssertEqual(row.parts.first?.state, .backedUp)
        var broken = row.parts[0]; broken.problem = "the folder took too long to read"
        XCTAssertNotEqual(P.combine(id: "x", name: "X", parts: [row.parts[0], broken]).state, .backedUp, "never Backed up when a folder was not read")
    }

    func testSecretFilesInCommitsAndNotSent() async throws {
        let repo = try pushedRepo("secrets")
        try write(repo, ".env", "KEY=committed\n")
        try git(repo, ["add", "-A"]); try git(repo, ["commit", "-q", "-m", "oops"], at: t2); try git(repo, ["push", "-q"])
        var row = try await readUnchanged(repo)
        XCTAssertEqual(row.secretsInCommits, [".env"]); XCTAssertEqual(row.held, [])
        XCTAssertEqual(row.state, .secretsInCommits)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc), "1 secret file is in your commits")
        try write(repo, ".gitignore", "local.pem\n"); try write(repo, "id_rsa", "k\n"); try write(repo, "local.pem", "ignored\n")
        try git(repo, ["add", ".gitignore"]); try git(repo, ["commit", "-q", "-m", "ignore"], at: t3); try git(repo, ["push", "-q"])
        row = try await readUnchanged(repo)
        XCTAssertEqual(row.held, [.init(name: "id_rsa", reason: .looksSecret)], "an ignored secret file is not listed; a committed one is not 'held'")
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now, timeZone: utc),
                       "1 file changed since 21:40 · 1 secret file is in your commits · 1 secret file not sent to GitHub")
    }

    func testARepositoryWhoseSettingsRunProgramsIsNotRead() async throws {
        let marker = root.appendingPathComponent("ran")
        let repo = try pushedRepo("filtered")
        try write(repo, ".gitattributes", "* filter=evil\n")
        try git(repo, ["config", "filter.evil.clean", "touch \(marker.path)"])
        let row = try await readUnchanged(repo)
        XCTAssertEqual(BackendCodeBackupWords.summary(row, now: now), "Could not check (this folder's Git settings run programs)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        // The same through a file the repository's settings include.
        let included = try pushedRepo("included")
        try write(root, "extra.gitconfig", "[filter \"inc\"]\n\tsmudge = touch \(marker.path)\n")
        try git(included, ["config", "include.path", root.appendingPathComponent("extra.gitconfig").path])
        let second = try await readUnchanged(included)
        XCTAssertEqual(second.problem, "this folder's Git settings run programs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAFilterInThePerWorktreeSettingsIsRefused() async throws {
        let marker = root.appendingPathComponent("ran-worktree")
        let repo = try pushedRepo("worktreecfg")
        try write(repo, ".gitattributes", "* filter=wt\n")
        try git(repo, ["config", "core.repositoryformatversion", "1"])
        try git(repo, ["config", "extensions.worktreeConfig", "true"])
        try git(repo, ["config", "--worktree", "filter.wt.clean", "touch \(marker.path)"])
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.problem, "this folder's Git settings run programs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(BackendCodeBackupGitReader.repositoryRunsPrograms("worktree\tfilter.wt.clean touch x\n"))
        XCTAssertTrue(BackendCodeBackupGitReader.repositoryRunsPrograms("local\tfilter.a.smudge x\n"))
        XCTAssertFalse(BackendCodeBackupGitReader.repositoryRunsPrograms("global\tfilter.lfs.process git-lfs filter-process\nsystem\tfilter.x.clean y\n"),
                       "his own global and system set-up is allowed")
    }

    func testASubmodulesOwnFilterStopsTheOuterRead() async throws {
        let marker = root.appendingPathComponent("ran-submodule")
        let sub = try pushedRepo("parts")
        let repo = try pushedRepo("assembly")
        try git(repo, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.path, "parts"])
        try git(repo, ["commit", "-q", "-m", "add parts"], at: t2)
        let inside = repo.appendingPathComponent("parts")
        try write(inside, ".gitattributes", "* filter=sub\n")
        try git(inside, ["config", "filter.sub.clean", "touch \(marker.path)"])
        let row = try await readUnchanged(repo)
        XCTAssertEqual(row.state, .couldNotCheck)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "status never ran inside the submodule")
    }

    func testAPlainFolderInsideAHomeRepositoryIsNotTheHome() async throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try git(home, ["init", "-q"])
        let plain = home.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let row = await read([plain.path])
        XCTAssertFalse(row.isRepository)
        XCTAssertEqual(row.state, .noHome)
    }

    final class HangingRunner: BackendGitExecuting, @unchecked Sendable {
        func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
            try await Task.sleep(for: .seconds(60)); throw CancellationError()
        }
    }

    func testOneTimeLimitPerProjectAndForTheFolderCheck() async throws {
        let repo = try pushedRepo("slow")
        var started = Date()
        let slow = await read([repo.path], reader: reader(runner: HangingRunner(), projectSeconds: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(BackendCodeBackupWords.summary(slow, now: now), "Could not check (the folder took too long to read)")
        started = Date()
        let silent = await read([repo.path], reader: reader(folderSeconds: 0.3, isDirectory: { _ in Thread.sleep(forTimeInterval: 3); return true }))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(BackendCodeBackupWords.summary(silent, now: now), "Could not check (the folder did not answer)")
        // The folder that hung is remembered: not touched again for a while, even by a check that would answer.
        let remembered = await read([repo.path])
        XCTAssertEqual(remembered.problem, "the folder did not answer")
        XCTAssertEqual(BackendCodeBackupGitReader.gitlinks("100644 abc 0\tREADME.md\0" + "160000 def 0\tlib/widgets\0"), ["lib/widgets"])
    }

    final class SlowHTTP: BackendGitHubHTTPFetching, @unchecked Sendable {
        let delay: Double
        init(delay: Double) { self.delay = delay }
        func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse {
            try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            return .init(status: 200, body: #"{"private":false}"#)
        }
    }

    func testGitHubLookupsRunTogetherWithinOneLimit() async throws {
        let homes: Set<String> = ["o/a", "o/b", "o/c", "o/d", "o/e"]
        let github = BackendCodeBackupGitHub(host: "github.com", http: SlowHTTP(delay: 0.6),
            account: { .init(signedIn: true, listed: [:]) }, token: { "fixture-token-not-real" })
        var started = Date()
        let answer = await github.visibility(of: homes)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "five lookups at once, not one after another")
        XCTAssertEqual(answer.found.count, 5)
        // A GitHub that does not answer never holds the page: the Git facts come back within the one limit.
        let clean = try pushedRepo("offline")
        let stuck = BackendCodeBackupGitHub(host: "github.com", http: SlowHTTP(delay: 30),
            account: { .init(signedIn: true, listed: [:]) }, token: { "fixture-token-not-real" })
        let model = BackendCodeBackupProjects(projects: { [PROJProject(id: "a", name: "Offline", folders: [clean.path])] }, reader: reader(),
                                              github: stuck, githubSeconds: 0.5)
        started = Date()
        let report = await model.withGitHub(await model.report())
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(report.projects.first?.visibility, .notChecked)
        XCTAssertEqual(report.projects.first?.state, .backedUp)
    }

    // MARK: Plain rules

    func testGitHubHomesAndHosts() {
        typealias R = BackendCodeBackupGitReader
        for url in ["https://github.com/o/n.git", "https://github.com/o/n", "git@github.com:o/n.git", "ssh://git@github.com/o/n.git",
                    "https://user@github.com/o/n.git/", "ssh://git@github.com:22/o/n.git"] {
            XCTAssertEqual(R.githubHome(url, host: "github.com"), "o/n", url)
        }
        XCTAssertNil(R.githubHome("https://gitlab.com/o/n.git", host: "github.com"))
        XCTAssertNil(R.githubHome("/tmp/bare.git", host: "github.com"))
        XCTAssertEqual(R.host("https://gitlab.com/o/n.git"), "gitlab.com")
        XCTAssertEqual(R.host("/srv/bare.git"), "a folder on this Mac")
        XCTAssertEqual(R.statusNames(" M a.txt\0?? b c.txt\0"), ["a.txt", "b c.txt"])
    }

    func testSecretPatternsKeepTheReadinessList() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckBackend/BackendReadinessService.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains("private static let secretPatterns") })
        let listed = line.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        XCTAssertFalse(listed.isEmpty)
        for pattern in listed where !pattern.hasPrefix("!") { XCTAssertTrue(BackendCodeBackupGitReader.secretPatterns.contains(pattern), pattern) }
        for yes in [".env", "a/.env.local", "id_rsa", "x/server.pem", "k.key", "credentials-prod.json", ".netrc"] { XCTAssertTrue(BackendCodeBackupGitReader.isSecret(yes), yes) }
        for no in ["environment.ts", "README.md", "keys.txt"] { XCTAssertFalse(BackendCodeBackupGitReader.isSecret(no), no) }
    }

    func testOrderAndWords() {
        var backed = P(id: "1", name: "Backed"); backed.hasFolder = true; backed.isRepository = true; backed.home = "o/b"; backed.lastBackedUpAt = 1_794_000_000_000
        var changed = P(id: "2", name: "Changed"); changed.hasFolder = true; changed.isRepository = true; changed.home = "o/c"; changed.changedCount = 1; changed.lastCommitAt = 1_700_000_000_000
        let none = P(id: "3", name: "Absent")
        var broken = P(id: "4", name: "Broken"); broken.hasFolder = true; broken.problem = "the folder took too long to read"
        let report = BackendCodeBackupReport(projects: [none, backed, broken, changed], signedInToGitHub: true, checkedAt: 0)
        XCTAssertEqual(report.projects.map(\.name), ["Changed", "Broken", "Backed", "Absent"])
        XCTAssertEqual(BackendCodeBackupWords.summary(changed, now: now, timeZone: utc), "1 file changed since 14 Nov 2023")
        XCTAssertEqual(BackendCodeBackupWords.summary(broken, now: now), "Could not check (the folder took too long to read)")
        XCTAssertEqual(BackendCodeBackupWords.when(1_793_900_000_000, now: now, timeZone: utc), "Yesterday, 17:33")
        XCTAssertEqual(BackendCodeBackupWords.when(1_790_000_000_000, now: now, timeZone: utc), "21 Sep, 14:13")
    }
}
