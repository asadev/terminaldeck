import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ports the "git's environment for workspaces" tests of task-workspaces.test.ts
/// (workspace-git.ts has no test file of its own). The environment is observed through
/// the device-planner seam, which receives the exact plan the runner would spawn.
/// Deviation: Swift also sets GIT_PAGER/PAGER (and GIT_OPTIONAL_LOCKS for reads), so the
/// exact-equality assertion becomes "no repo-pointing variable survives + required keys".
final class BackendFoundationTestsS6C3WorkspaceGitTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock(); private var plans: [BackendGitExecutionPlan] = []
        func add(_ plan: BackendGitExecutionPlan) { lock.lock(); plans.append(plan); lock.unlock() }
        var all: [BackendGitExecutionPlan] { lock.lock(); defer { lock.unlock() }; return plans }
    }

    func testDropsEveryVariableThatWouldPointGitAtAnotherRepositoryOrIndex() async throws {
        try XCTSkipUnless(S6C3WS.hasGit, "git not installed")
        let temp = try S6C3WSTemp("gitenv"), capture = Capture()
        let runner = BackendGitRunner(
            inheritedEnvironment: ["GIT_DIR": "/x/.git", "GIT_INDEX_FILE": "/x/index", "GIT_WORK_TREE": "/x", "GIT_COMMON_DIR": "/x", "GIT_OBJECT_DIRECTORY": "/x/o",
                                   "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/x/a", "GIT_NAMESPACE": "n", "GIT_PREFIX": "p", "KEEP_ME": "1"],
            loginPath: { S6C3WS.loginPath },
            devicePlanner: { _, plan in capture.add(plan); return plan })
        let device = NativeRPCContext(caller: .pairedDevice, ownerID: "s6c3-device")
        _ = try await runner.run(cwd: temp.path, arguments: ["--version"], context: device, writing: false, timeoutMilliseconds: 8_000, maximumBytes: 1_048_576)
        let plan = try XCTUnwrap(capture.all.first)
        for name in BackendGitRunner.repositoryVariables { XCTAssertNil(plan.environment[name], name) }
        XCTAssertEqual(Set(BackendGitRunner.repositoryVariables), ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX"])
        XCTAssertEqual(plan.environment["LC_ALL"], "C"); XCTAssertEqual(plan.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(plan.environment["PATH"], S6C3WS.loginPath); XCTAssertEqual(plan.environment["KEEP_ME"], "1")
        XCTAssertEqual(plan.environment["GIT_OPTIONAL_LOCKS"], "0")
    }
    func testWritingCallsDoNotDisableOptionalLocks() async throws {
        try XCTSkipUnless(S6C3WS.hasGit, "git not installed")
        let temp = try S6C3WSTemp("gitenvw"), capture = Capture()
        let runner = BackendGitRunner(inheritedEnvironment: [:], loginPath: { S6C3WS.loginPath }, devicePlanner: { _, plan in capture.add(plan); return plan })
        _ = try await runner.run(cwd: temp.path, arguments: ["--version"], context: NativeRPCContext(caller: .pairedDevice, ownerID: "s6c3-device"), writing: true,
                                 timeoutMilliseconds: 8_000, maximumBytes: 1_048_576)
        XCTAssertNil(capture.all.first?.environment["GIT_OPTIONAL_LOCKS"])
    }
    func testRemoteCallerWithoutAGuestPlannerIsRefused() async throws {
        try XCTSkipUnless(S6C3WS.hasGit, "git not installed")
        let temp = try S6C3WSTemp("gitenvr")
        let runner = BackendGitRunner(inheritedEnvironment: [:], loginPath: { S6C3WS.loginPath })
        do {
            _ = try await runner.run(cwd: temp.path, arguments: ["--version"], context: NativeRPCContext(caller: .page, ownerID: "tab"), writing: false, timeoutMilliseconds: 8_000, maximumBytes: 1_048_576)
            XCTFail("a page caller ran git on the owner's environment")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "missing-capability") }
    }
    func testInheritedIndexFileCannotReachThePersonsIndex() async throws {
        try XCTSkipUnless(S6C3WS.hasGit, "git not installed")
        let temp = try S6C3WSTemp("stray"), clean = S6C3WS.git()
        let repo = try await S6C3WS.repository(clean, at: temp.sub("repo"))
        try await S6C3WS.workInProgress(clean, repo)
        let before = try await S6C3WS.checkout(clean, repo)
        let stray = S6C3WS.git(extra: ["GIT_INDEX_FILE": repo + "/.git/index", "GIT_DIR": repo + "/.git"])
        let workspaces = try BackendWorkspaceService(userData: temp.sub("data"), git: stray, ownership: .exclusive)
        let folder = try await workspaces.folderFor(taskID: "local:6f1c2d", project: repo, useWorkspace: true, title: "Stray", context: S6C3WS.context)
        XCTAssertNotNil(folder)
        let after = try await S6C3WS.checkout(clean, repo); XCTAssertEqual(after, before)
    }
}
