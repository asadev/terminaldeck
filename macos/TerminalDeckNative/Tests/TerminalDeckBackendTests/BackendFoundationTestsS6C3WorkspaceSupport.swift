import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Shared helpers for the S6/C3 workspace tests (task-workspaces, names, store, ipc, git env).
final class S6C3WSTemp {
    let url: URL
    var path: String { url.path }
    init(_ name: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("td-ws-\(name)-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func sub(_ name: String) -> URL { url.appendingPathComponent(name) }
    func mkdir(_ name: String) throws -> URL { let u = sub(name); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }
    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

/// Deterministic stand-in for git: worktree add/remove only touch folders.
final class S6C3WSFakeGit: BackendGitExecuting, @unchecked Sendable {
    let repo: String
    private let lock = NSLock()
    private var taken: Set<String>
    private var seen: [[String]] = []
    init(repo: String, taken: Set<String> = []) { self.repo = repo; self.taken = taken }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return seen }
    func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        let taken = lock.withLock { seen.append(arguments); return self.taken }
        func ok(_ text: String = "") -> BackendGitOutcome { BackendGitOutcome(ok: true, stdout: text, stderr: "", missing: false, exitCode: 0, timedOut: false) }
        if arguments.starts(with: ["rev-parse", "--show-toplevel"]) { return ok(repo + "\n") }
        if arguments.first == "rev-parse" { return ok("abc123abc123\n") }
        if arguments.first == "show-ref", let ref = arguments.last {
            return taken.contains(String(ref.dropFirst("refs/heads/".count))) ? ok() : BackendGitOutcome(ok: false, stdout: "", stderr: "", missing: false, exitCode: 1, timedOut: false)
        }
        if arguments.starts(with: ["worktree", "add"]), arguments.count >= 7 {
            try? FileManager.default.createDirectory(atPath: arguments[5], withIntermediateDirectories: true); return ok()
        }
        if arguments.starts(with: ["worktree", "remove"]), let path = arguments.last { try? FileManager.default.removeItem(atPath: path); return ok() }
        return ok()
    }
}

enum S6C3WS {
    static let context = NativeRPCContext(caller: .nativeApp, ownerID: "s6c3-workspaces")
    static var authority: BackendFilesystemAuthority { BackendFilesystemAuthority { _ in .local } }
    static var hasGit: Bool { ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].contains { FileManager.default.isExecutableFile(atPath: $0) } }
    static let loginPath = "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"

    /// The machine's own git config is left out so hooks/templates cannot change what is seen.
    static func runner(extra: [String: String] = [:]) -> BackendGitRunner {
        var environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "HOME": NSTemporaryDirectory()]
        for (key, value) in extra { environment[key] = value }
        return BackendGitRunner(inheritedEnvironment: environment, loginPath: { loginPath })
    }
    static func git(extra: [String: String] = [:]) -> BackendGitService { BackendGitService(authority: authority, runner: runner(extra: extra)) }
    static func fakeGit(_ fake: S6C3WSFakeGit) -> BackendGitService { BackendGitService(authority: authority, runner: fake) }

    @discardableResult
    static func sh(_ git: BackendGitService, _ cwd: String, _ args: String...) async throws -> String {
        let outcome = try await git.workspaceCommand(cwd: cwd, arguments: args, context: context)
        guard outcome.ok else { throw NativeRPCError(code: "git", message: "git \(args.joined(separator: " ")) failed: \(outcome.stderr)") }
        return outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    static func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// A repository with two commits, a subfolder and its own identity.
    static func repository(_ git: BackendGitService, at root: URL) async throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.resolvingSymlinksInPath().path
        try await sh(git, repo, "init", "-q", "-b", "main")
        try await sh(git, repo, "config", "user.name", "Test")
        try await sh(git, repo, "config", "user.email", "test@example.com")
        try write(repo + "/a.txt", "one\n"); try write(repo + "/app/main.ts", "export {}\n")
        try await sh(git, repo, "add", ".")
        try await sh(git, repo, "commit", "-q", "-m", "first")
        try write(repo + "/a.txt", "two\n")
        try await sh(git, repo, "commit", "-q", "-am", "second")
        return repo
    }
    /// A stash, a staged file, an edit and an untracked file.
    static func workInProgress(_ git: BackendGitService, _ repo: String) async throws {
        try write(repo + "/a.txt", "stashed\n"); try await sh(git, repo, "stash", "-q")
        try write(repo + "/staged.txt", "staged\n"); try await sh(git, repo, "add", "staged.txt")
        try write(repo + "/a.txt", "edited, not staged\n"); try write(repo + "/loose.txt", "untracked\n")
    }
    /// Everything about the person's checkout that a workspace must not change.
    static func checkout(_ git: BackendGitService, _ repo: String) async throws -> [String: String] {
        let index = try Data(contentsOf: URL(fileURLWithPath: repo + "/.git/index"))
        return [
            "index": SHA256.hash(data: index).map { String(format: "%02x", $0) }.joined(),
            "head": try await sh(git, repo, "rev-parse", "HEAD"),
            "branch": try await sh(git, repo, "symbolic-ref", "--short", "HEAD"),
            "status": try await sh(git, repo, "--no-optional-locks", "status", "--porcelain"),
            "stash": try await sh(git, repo, "stash", "list"),
            "a": try read(repo + "/a.txt"), "loose": try read(repo + "/loose.txt"),
        ]
    }
    static func worktrees(_ git: BackendGitService, _ repo: String) async throws -> [String] {
        try await sh(git, repo, "worktree", "list", "--porcelain").components(separatedBy: "\n")
            .filter { $0.hasPrefix("worktree ") }.map { URL(fileURLWithPath: String($0.dropFirst("worktree ".count))).resolvingSymlinksInPath().path }
    }
    static func branchExists(_ git: BackendGitService, _ repo: String, _ branch: String) async throws -> Bool {
        try await git.workspaceCommand(cwd: repo, arguments: ["show-ref", "--verify", "--quiet", "refs/heads/" + branch], context: context, writing: false).ok
    }
    static func digest(_ value: String, _ count: Int) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(count))
    }
    static func shortID(_ taskID: String) -> String { digest(taskID, 8) }
    static func repoKey(_ repo: String) -> String { digest(repo, 16) }
}
