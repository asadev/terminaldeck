import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The phone's Changes (31 Oct 2026): what an agent changed, the change of one file, Commit and Push — read only inside
/// the device's folders, writes only at Full control, against a real repository and a real (bare) remote.
final class PHONEChangesTests: XCTestCase {
    private func parse(_ json: String) -> BackendRemoteClientMessage? {
        if case .message(let message) = BackendRemoteProtocol.parseClientMessage(json) { return message }
        return nil
    }

    private static func host(level: BackendINT2PhoneAccessLevel?, folders: [String], unrestricted: Bool = false) -> BackendRemoteHostContext {
        .init(connectionID: UUID(), deviceID: "phone-1", kind: .mine, address: "relay", peerPublicKey: nil, claimedCapabilities: [],
              reach: .init(kind: .mine, unrestricted: unrestricted, folders: folders, accounts: nil, drivesWindows: false), phoneAccess: level)
    }

    @discardableResult
    private func sh(_ cwd: URL, _ args: String...) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = Array(args)
        process.currentDirectoryURL = cwd
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": cwd.path, "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// A repository with one commit, a bare remote it tracks, one changed and one new file.
    private func repository() throws -> (repo: URL, remote: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("phone-changes-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        let repo = base.appendingPathComponent("repo"), remote = base.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        try sh(remote, "init", "--bare", "-q")
        try sh(repo, "init", "-q", "-b", "main")
        try sh(repo, "config", "user.name", "T"); try sh(repo, "config", "user.email", "t@example.com")
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try sh(repo, "add", "-A"); try sh(repo, "commit", "-q", "-m", "first")
        try sh(repo, "remote", "add", "origin", remote.path)
        try "one\nTWO\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        return (repo, remote)
    }

    private func changes() -> BackendPhoneChanges {
        let authority = BackendFilesystemAuthority(scope: { _ in .local })
        let runner = BackendGitRunner(inheritedEnvironment: ["HOME": NSHomeDirectory()], loginPath: { "/usr/bin:/bin" })
        let git = BackendGitService(authority: authority, runner: runner)
        return BackendPhoneChanges(git: git, context: { NativeRPCContext(caller: .nativeApp, ownerID: "test", capabilities: ["filesystem.read", "filesystem.write", "git.read", "git.write"]) })
    }

    func testFramesParseAndOnlyFullControlWrites() {
        XCTAssertEqual(parse(#"{"t":"git.diff","path":"/a","file":"b.txt","untracked":true}"#)?["untracked"].bool, true)
        XCTAssertEqual(parse(#"{"t":"git.commit","path":"/a","message":"Fix it"}"#)?["message"].string, "Fix it")
        XCTAssertNil(parse(#"{"t":"git.commit","path":"/a"}"#), "a commit without its message is refused")
        XCTAssertNotNil(parse(#"{"t":"git.push","path":"/a"}"#))
        XCTAssertTrue(BackendINT2PhoneAccessLevel.look.permits("git.status") && BackendINT2PhoneAccessLevel.look.permits("git.diff"))
        XCTAssertFalse(BackendINT2PhoneAccessLevel.work.permits("git.commit") || BackendINT2PhoneAccessLevel.work.permits("git.push"))
        XCTAssertTrue(BackendINT2PhoneAccessLevel.full.permits("git.commit") && BackendINT2PhoneAccessLevel.full.permits("git.push"))
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains("git.write"))
        XCTAssertEqual(Set(changes().features().map(\.capability)), ["git", "git.write"])
    }

    func testStatusAndDiffInsideTheDevicesFolders() async throws {
        let (repo, _) = try repository(), changes = changes()
        let state = try await changes.read(XCTUnwrap(parse(#"{"t":"git.status","path":"\#(repo.path)"}"#)), host: Self.host(level: .look, folders: [repo.path]))
        XCTAssertEqual(state.kind, .gitState)
        XCTAssertEqual(state.value["status"]["unstaged"].elements?.first?["path"].string, "a.txt")
        XCTAssertEqual(state.value["status"]["untracked"].elements?.first?["path"].string, "b.txt")
        let patch = try await changes.read(XCTUnwrap(parse(#"{"t":"git.diff","path":"\#(repo.path)","file":"a.txt"}"#)), host: Self.host(level: .look, folders: [repo.path]))
        XCTAssertTrue(patch.value["patch"].string?.contains("+TWO") == true)
        let fresh = try await changes.read(XCTUnwrap(parse(#"{"t":"git.diff","path":"\#(repo.path)","file":"b.txt","untracked":true}"#)), host: Self.host(level: .look, folders: [repo.path]))
        XCTAssertTrue(fresh.value["patch"].string?.contains("+new") == true)
        do {
            _ = try await changes.read(XCTUnwrap(parse(#"{"t":"git.status","path":"\#(repo.path)"}"#)), host: Self.host(level: .full, folders: ["/somewhere/else"]))
            XCTFail("a folder the device does not reach is refused")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unauthorized") }
    }

    func testCommitThenPushSetsTheUpstream() async throws {
        let (repo, remote) = try repository(), changes = changes(), host = Self.host(level: .full, folders: [repo.path])
        let refused = try await changes.write(XCTUnwrap(parse(#"{"t":"git.commit","path":"\#(repo.path)","message":"x"}"#)), host: Self.host(level: .work, folders: [repo.path]))
        XCTAssertEqual(refused.kind, .error, "below Full control nothing is written")
        let commit = try await changes.write(XCTUnwrap(parse(#"{"t":"git.commit","path":"\#(repo.path)","message":"Phone commit"}"#)), host: host)
        XCTAssertEqual(commit.kind, .gitDone); XCTAssertEqual(commit.value["ok"].bool, true, commit.value["message"].string ?? "")
        XCTAssertEqual(commit.value["status"]["clean"].bool, true)
        XCTAssertTrue(try sh(repo, "log", "-1", "--format=%s").contains("Phone commit"))
        let push = try await changes.write(XCTUnwrap(parse(#"{"t":"git.push","path":"\#(repo.path)"}"#)), host: host)
        XCTAssertEqual(push.value["ok"].bool, true, push.value["message"].string ?? "")
        XCTAssertEqual(push.value["status"]["branch"]["upstream"].string, "origin/main")
        XCTAssertEqual(push.value["status"]["branch"]["ahead"].number, 0)
        XCTAssertTrue(try sh(remote, "log", "-1", "--format=%s", "main").contains("Phone commit"))
        let nothing = try await changes.write(XCTUnwrap(parse(#"{"t":"git.commit","path":"\#(repo.path)","message":"again"}"#)), host: host)
        XCTAssertEqual(nothing.value["ok"].bool, false); XCTAssertTrue(nothing.value["message"].string?.contains("Nothing to commit") == true)
    }

    func testALongPatchIsCutAtALineAndSaysSo() {
        let long = (0..<5000).map { "+line \($0) with some text" }.joined(separator: "\n")
        let cut = BackendPhoneChanges.cut(long)
        XCTAssertLessThan(cut.utf8.count, BackendPhoneChanges.maxPatchBytes + 200)
        XCTAssertTrue(cut.hasSuffix("Open it on the Mac to see all of it.\n"))
    }
}
