import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ports task-workspaces.test.ts with real git worktrees in temp folders.
/// Skipped: workspaceProvider title adapter (no Swift equivalent; folderFor takes the title).
/// Wording deviations (asserted on the stable part): not-a-repo / moved-project refusal text,
/// "A session is still running in this workspace", missing project folder throws instead of refusing.
/// testDeletedFolder... may expose a gap: prune uses `worktree remove` on a missing folder (see NIGHT-REQUESTS).
final class BackendFoundationTestsS6C3TaskWorkspacesTests: XCTestCase {
    private let task = "local:6f1c2d"
    private struct Rig { let temp: S6C3WSTemp; let git: BackendGitService; let data: URL; let service: BackendWorkspaceService }
    private func rig() throws -> Rig {
        try XCTSkipUnless(S6C3WS.hasGit, "git not installed")
        let temp = try S6C3WSTemp("tasks"), git = S6C3WS.git(), data = temp.sub("data")
        return Rig(temp: temp, git: git, data: data, service: try BackendWorkspaceService(userData: data, git: git, ownership: .exclusive))
    }
    private func repo(_ r: Rig, _ name: String = "repo") async throws -> String { try await S6C3WS.repository(r.git, at: r.temp.sub(name)) }
    private func folder(_ r: Rig, _ project: String, id: String? = nil, title: String = "x", use: Bool = true, service: BackendWorkspaceService? = nil) async throws -> String? {
        try await (service ?? r.service).folderFor(taskID: id ?? task, project: project, useWorkspace: use, title: title, context: S6C3WS.context)
    }
    private func must(_ r: Rig, _ project: String, title: String = "x") async throws -> String {
        let found = try await folder(r, project, title: title)
        return try XCTUnwrap(found)
    }
    private func view(_ r: Rig, _ id: String? = nil, service: BackendWorkspaceService? = nil) async throws -> NativeRPCValue {
        try await (service ?? r.service).view(taskID: id ?? task, context: S6C3WS.context)
    }

    // MARK: a task workspace
    func testWorkspaceIsAWorktreeOnANewTdBranchAndCheckoutIsLeftAlone() async throws {
        let r = try rig(); let repo = try await repo(r)
        try await S6C3WS.workInProgress(r.git, repo)
        let before = try await S6C3WS.checkout(r.git, repo)
        let found = try await folder(r, repo, title: "Fix the login page!")
        let path = try XCTUnwrap(found)
        XCTAssertTrue(path.hasPrefix(r.data.appendingPathComponent("workspaces").appendingPathComponent(S6C3WS.repoKey(repo)).path))
        let branch = "td/fix-the-login-page-" + S6C3WS.shortID(task)
        let headRef = try await S6C3WS.sh(r.git, path, "symbolic-ref", "--short", "HEAD"); XCTAssertEqual(headRef, branch)
        let head = try await S6C3WS.sh(r.git, path, "rev-parse", "HEAD"); XCTAssertEqual(head, before["head"])
        XCTAssertEqual(try S6C3WS.read(path + "/a.txt"), "two\n")
        XCTAssertFalse(S6C3WS.exists(path + "/staged.txt")); XCTAssertFalse(S6C3WS.exists(path + "/loose.txt"))
        let after = try await S6C3WS.checkout(r.git, repo); XCTAssertEqual(after, before)
        let ws = try await view(r)["workspace"]
        XCTAssertEqual(ws["taskId"].string, task); XCTAssertEqual(ws["repo"].string, repo); XCTAssertEqual(ws["path"].string, path); XCTAssertEqual(ws["branch"].string, branch)
        XCTAssertEqual(ws["base"].string, before["head"]); XCTAssertEqual(ws["state"].string, "active"); XCTAssertEqual(ws["folder"].string, path)
        let stored = try NativeRPCValue.parseJSON(Data(contentsOf: r.data.appendingPathComponent("workspaces.json")))
        XCTAssertEqual((stored["workspaces"].elements ?? []).map { $0["path"].string }, [path])
        let refusal = try await view(r)["refusal"]; XCTAssertEqual(refusal, .null)
    }
    func testWorkspaceIsReusedBySameTaskAndSurvivesARestart() async throws {
        let r = try rig(); let repo = try await repo(r)
        let first = try await folder(r, repo, title: "Ship it"), second = try await folder(r, repo, title: "Ship it, renamed")
        XCTAssertNotNil(first); XCTAssertEqual(second, first)
        let restarted = try BackendWorkspaceService(userData: r.data, git: r.git, ownership: .exclusive)
        let third = try await folder(r, repo, service: restarted); XCTAssertEqual(third, first)
        let trees = try await S6C3WS.worktrees(r.git, repo); XCTAssertEqual(trees.count, 2)
    }
    func testWorkspaceIsMadeOnceWhenTwoStartsAskAtTheSameMoment() async throws {
        let r = try rig(); let repo = try await repo(r)
        let service = r.service, taskID = task
        async let a = service.folderFor(taskID: taskID, project: repo, useWorkspace: true, title: "Same", context: S6C3WS.context)
        async let b = service.folderFor(taskID: taskID, project: repo, useWorkspace: true, title: "Same", context: S6C3WS.context)
        let (x, y) = try await (a, b)
        XCTAssertNotNil(x); XCTAssertEqual(x, y)
        let trees = try await S6C3WS.worktrees(r.git, repo); XCTAssertEqual(trees.count, 2)
    }
    func testSubfolderProjectRunsInTheSameSubfolderOfTheWorkspace() async throws {
        let r = try rig(); let repo = try await repo(r)
        let found = try await folder(r, repo + "/app", title: "App only")
        let ws = try await view(r)["workspace"]
        XCTAssertEqual(ws["repo"].string, repo)
        XCTAssertEqual(found, (ws["path"].string ?? "") + "/app")
        XCTAssertTrue(S6C3WS.exists((found ?? "") + "/main.ts"))
    }
    func testNotMadeForATaskThatDoesNotAskAndExistingOneStaysInUse() async throws {
        let r = try rig(); let repo = try await repo(r)
        let none = try await folder(r, repo, use: false); XCTAssertNil(none)
        let one = try await S6C3WS.worktrees(r.git, repo); XCTAssertEqual(one.count, 1)
        let made = try await folder(r, repo)
        let stillUsed = try await folder(r, repo, use: false); XCTAssertEqual(stillUsed, made)
    }
    func testSkipsPastATakenBranchNameAndLeavesThatBranchAlone() async throws {
        let r = try rig(); let repo = try await repo(r)
        let taken = "td/taken-" + S6C3WS.shortID(task)
        try await S6C3WS.sh(r.git, repo, "branch", taken, "HEAD~1")
        let was = try await S6C3WS.sh(r.git, repo, "rev-parse", taken)
        let found = try await folder(r, repo, title: "Taken")
        let ref = try await S6C3WS.sh(r.git, try XCTUnwrap(found), "symbolic-ref", "--short", "HEAD"); XCTAssertEqual(ref, taken + "-2")
        let now = try await S6C3WS.sh(r.git, repo, "rev-parse", taken); XCTAssertEqual(now, was)
    }

    // MARK: removing
    func testRemovesACleanOneKeepsItsBranchAndLeavesTheCheckoutAlone() async throws {
        let r = try rig(); let repo = try await repo(r)
        try await S6C3WS.workInProgress(r.git, repo)
        let path = try await must(r, repo, title: "Clean up")
        try S6C3WS.write(path + "/done.txt", "done\n")
        try await S6C3WS.sh(r.git, path, "add", "done.txt"); try await S6C3WS.sh(r.git, path, "commit", "-q", "-m", "task work")
        let tip = try await S6C3WS.sh(r.git, path, "rev-parse", "HEAD")
        let before = try await S6C3WS.checkout(r.git, repo)
        let outcome = try await r.service.remove(taskID: task, liveFolders: [], context: S6C3WS.context)
        XCTAssertEqual(outcome["ok"].bool, true)
        let branch = "td/clean-up-" + S6C3WS.shortID(task)
        XCTAssertTrue(outcome["message"].string?.contains(branch) == true)
        XCTAssertEqual(outcome["view"]["workspace"]["state"].string, "removed")
        XCTAssertFalse(S6C3WS.exists(path))
        let kept = try await S6C3WS.branchExists(r.git, repo, branch); XCTAssertTrue(kept)
        let now = try await S6C3WS.sh(r.git, repo, "rev-parse", branch); XCTAssertEqual(now, tip)
        let trees = try await S6C3WS.worktrees(r.git, repo); XCTAssertEqual(trees, [repo])
        let after = try await S6C3WS.checkout(r.git, repo); XCTAssertEqual(after, before)
        let open = try await r.service.folderToOpen(taskID: task, context: S6C3WS.context); XCTAssertNil(open)
    }
    func testKeepsOneWithUncommittedChangesWithTheReasonAndNeverForcesIt() async throws {
        let r = try rig(); let repo = try await repo(r)
        let path = try await must(r, repo, title: "Dirty")
        try S6C3WS.write(path + "/a.txt", "changed by the agent\n"); try S6C3WS.write(path + "/new.txt", "new\n")
        let outcome = try await r.service.remove(taskID: task, liveFolders: [], context: S6C3WS.context)
        XCTAssertEqual(outcome["ok"].bool, false)
        let message = outcome["message"].string ?? ""
        XCTAssertTrue(message.contains("2 uncommitted changes")); XCTAssertTrue(message.contains("a.txt")); XCTAssertTrue(message.contains("new.txt"))
        XCTAssertEqual(outcome["view"]["workspace"]["state"].string, "kept"); XCTAssertEqual(outcome["view"]["workspace"]["reason"].string, message)
        XCTAssertEqual(try S6C3WS.read(path + "/a.txt"), "changed by the agent\n")
        let trees = try await S6C3WS.worktrees(r.git, repo); XCTAssertEqual(trees.count, 2)
        // Used again, it is the task's working folder again.
        let again = try await folder(r, repo); XCTAssertEqual(again, path)
        let ws = try await view(r)["workspace"]; XCTAssertEqual(ws["state"].string, "active"); XCTAssertEqual(ws["reason"], .null)
        // Once clean, it goes.
        try await S6C3WS.sh(r.git, path, "checkout", "--", "a.txt"); try FileManager.default.removeItem(atPath: path + "/new.txt")
        let last = try await r.service.remove(taskID: task, liveFolders: [], context: S6C3WS.context)
        XCTAssertEqual(last["ok"].bool, true); XCTAssertFalse(S6C3WS.exists(path))
    }
    func testKeepsOneASessionIsStillRunningIn() async throws {
        let r = try rig(); let repo = try await repo(r)
        let path = try await must(r, repo + "/app", title: "Busy")
        let outcome = try await r.service.remove(taskID: task, liveFolders: [path], context: S6C3WS.context)
        XCTAssertEqual(outcome["ok"].bool, false)
        XCTAssertTrue(outcome["message"].string?.contains("A session is still running") == true)
        XCTAssertEqual(outcome["view"]["workspace"]["state"].string, "kept"); XCTAssertTrue(S6C3WS.exists(path))
    }
    func testSaysSoWhenTheTaskHasNone() async throws {
        let r = try rig()
        let outcome = try await r.service.remove(taskID: "local:none", liveFolders: [], context: S6C3WS.context)
        XCTAssertEqual(outcome["ok"].bool, false); XCTAssertEqual(outcome["message"].string, "This task has no workspace to remove.")
    }

    // MARK: a workspace whose folder was deleted
    func testDeletedFolderIsMarkedRemovedBranchKeptAndGitsNoteCleared() async throws {
        let r = try rig(); let repo = try await repo(r)
        let path = try await must(r, repo, title: "Gone")
        try FileManager.default.removeItem(atPath: path)
        let live = try await r.service.liveFolders(); XCTAssertEqual(live, [])
        let ws = try await view(r)["workspace"]
        XCTAssertEqual(ws["state"].string, "removed"); XCTAssertTrue(ws["reason"].string?.contains("deleted outside") == true)
        let trees = try await S6C3WS.worktrees(r.git, repo); XCTAssertEqual(trees, [repo])
        let branch = "td/gone-" + S6C3WS.shortID(task)
        let kept = try await S6C3WS.branchExists(r.git, repo, branch); XCTAssertTrue(kept)
        // Asked again, the task gets a new one on a fresh branch beside the kept one.
        let again = try await folder(r, repo, title: "Gone"); XCTAssertEqual(again, path)
        let ref = try await S6C3WS.sh(r.git, try XCTUnwrap(again), "symbolic-ref", "--short", "HEAD"); XCTAssertEqual(ref, branch + "-2")
        // And a sweep after a restart finds one deleted while the app was closed.
        try FileManager.default.removeItem(atPath: try XCTUnwrap(again))
        let restarted = try BackendWorkspaceService(userData: r.data, git: r.git, ownership: .exclusive)
        try await restarted.pruneVanished(context: S6C3WS.context)
        let swept = try await view(r, service: restarted)["workspace"]; XCTAssertEqual(swept["state"].string, "removed")
    }

    // MARK: no workspace, with the reason
    func testNonRepositoryFolderRunsInTheProjectFolderWithAReason() async throws {
        let r = try rig(); let plain = try r.temp.mkdir("plain").path
        let none = try await folder(r, plain); XCTAssertNil(none)
        let v = try await view(r)
        XCTAssertTrue(v["workspace"].isNullish)
        let reason = try XCTUnwrap(v["refusal"].string)
        XCTAssertTrue(reason.contains("project folder"), reason)
        XCTAssertFalse(S6C3WS.exists(r.data.appendingPathComponent("workspaces").appendingPathComponent(S6C3WS.repoKey(plain)).path))
        // A task that stops asking is no longer told why it could not have one.
        _ = try await folder(r, plain, use: false)
        let cleared = try await view(r)["refusal"]; XCTAssertEqual(cleared, .null)
    }
    func testRepositoryWithNoCommits() async throws {
        let r = try rig(); let empty = try r.temp.mkdir("empty").path
        try await S6C3WS.sh(r.git, empty, "init", "-q")
        let none = try await folder(r, empty); XCTAssertNil(none)
        let reason = try await view(r)["refusal"].string; XCTAssertTrue(reason?.contains("has no commits yet") == true)
    }
    func testProjectFolderThatDoesNotExist() async throws {
        let r = try rig()
        do {
            let none = try await folder(r, "/no/such/folder"); XCTAssertNil(none)
            let reason = try await view(r)["refusal"].string; XCTAssertTrue(reason?.contains("does not exist") == true)
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "filesystem") } // Swift throws instead of recording a refusal
    }
    func testTaskWhoseProjectMovedToAnotherRepository() async throws {
        let r = try rig(); let first = try await repo(r, "first"), second = try await repo(r, "second")
        let made = try await folder(r, first, title: "Moved")
        let none = try await folder(r, second); XCTAssertNil(none)
        let v = try await view(r)
        XCTAssertNotNil(v["refusal"].string)
        XCTAssertEqual(v["workspace"]["path"].string, made)
        let trees = try await S6C3WS.worktrees(r.git, second); XCTAssertEqual(trees.count, 1)
    }

    // MARK: folders the copilot may start a session in
    func testLiveFoldersAreTheWorkspacesTopsAndTheFoldersTasksRunIn() async throws {
        let r = try rig(); let repo = try await repo(r)
        let sub = try await must(r, repo + "/app", title: "App")
        let top = try await view(r)["workspace"]["path"].string ?? ""
        let live = try await r.service.liveFolders(); XCTAssertEqual(live.sorted(), [top, sub].sorted())
    }
}
