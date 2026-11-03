import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// PARALLEL-JOBS with real git worktrees in temp folders: separate copies per job, claims every sibling sees,
/// a conflicting landing that is never forced, and one-at-a-time in a folder without git.
final class ParallelJobsTests: XCTestCase {
    private struct Rig { let temp: S6C3WSTemp; let git: BackendGitService; let workspaces: BackendWorkspaceService; let jobs: BackendParallelJobs }
    private func rig() throws -> Rig {
        try XCTSkipUnless(S6C3WS.hasGit, "git not installed")
        let temp = try S6C3WSTemp("parallel"), git = S6C3WS.git()
        let workspaces = try BackendWorkspaceService(userData: temp.sub("data"), git: git, ownership: .exclusive)
        let jobs = BackendParallelJobs(git: { cwd, arguments in try await git.workspaceCommand(cwd: cwd, arguments: arguments, context: S6C3WS.context) },
            workspace: { id in let view = try await workspaces.view(taskID: id, context: S6C3WS.context)["workspace"]; return view.isNullish ? nil : view },
            remove: { id in _ = try await workspaces.remove(taskID: id, liveFolders: [], context: S6C3WS.context) })
        return Rig(temp: temp, git: git, workspaces: workspaces, jobs: jobs)
    }
    private func copy(_ r: Rig, _ id: String, _ repo: String) async throws -> String {
        let found = try await r.workspaces.folderFor(taskID: id, project: repo, useWorkspace: true, title: id, context: S6C3WS.context)
        return try XCTUnwrap(found)
    }
    private let noCheck: BackendParallelJobs.Check = { _, _ in (true, "") }

    func testTwoJobsOfOneAgentGetSeparateWorktrees() async throws {
        let r = try rig(); let repo = try await S6C3WS.repository(r.git, at: r.temp.sub("repo"))
        let one = try await copy(r, "local:job-1", repo), two = try await copy(r, "local:job-2", repo)
        XCTAssertNotEqual(one, two); XCTAssertNotEqual(one, repo); XCTAssertNotEqual(two, repo)
        let b1 = try await S6C3WS.sh(r.git, one, "symbolic-ref", "--short", "HEAD"), b2 = try await S6C3WS.sh(r.git, two, "symbolic-ref", "--short", "HEAD")
        XCTAssertNotEqual(b1, b2)
        let c1 = await r.jobs.copy(of: "local:job-1"), c2 = await r.jobs.copy(of: "local:job-2")
        XCTAssertEqual(c1?.branch, b1); XCTAssertEqual(c2?.branch, b2)
        let own = try await S6C3WS.sh(r.git, repo, "symbolic-ref", "--short", "HEAD")
        XCTAssertEqual(own, "main", "the project's own checkout is left alone")
    }

    func testClaimsAreVisibleToSiblingJobs() async throws {
        let core = try await BackendRoutinesTaskStoreParityRig.make()
        let r = try rig()
        var ids: [String] = []
        for title in ["First job", "Second job"] {
            let made = try await core.local.create(routinesTaskObject([("title", .string(title)), ("assignee", .string("builder")), ("project", .string("/work"))]))
            _ = try await core.store.update(made.id, patch: routinesTaskObject([("process", .string("running"))])); ids.append(made.id)
        }
        _ = try await BackendParallelJobs.claim(ids[0], paths: ["app/main.ts", "a.txt"], release: false, store: core.store)
        let listed = try await r.jobs.jobs(agentID: "builder", store: core.store)["jobs"].elements ?? []
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.first { $0["task"].string == ids[0] }?["claims"].elements?.compactMap(\.string), ["app/main.ts", "a.txt"])
        let left = try await BackendParallelJobs.claim(ids[0], paths: ["a.txt"], release: true, store: core.store)
        XCTAssertEqual(left, ["app/main.ts"])
    }

    func testAConflictingLandingIsNotForcedAndIsReported() async throws {
        let r = try rig(); let repo = try await S6C3WS.repository(r.git, at: r.temp.sub("repo"))
        let one = try await copy(r, "local:job-1", repo), two = try await copy(r, "local:job-2", repo)
        try S6C3WS.write(one + "/a.txt", "from job one\n"); try S6C3WS.write(two + "/a.txt", "from job two\n")
        let first = await r.jobs.land(taskID: "local:job-1", title: "Job one", verifyCommand: nil, attempt: 0, check: noCheck)
        guard case .landed = first else { return XCTFail("the first job should land: \(first)") }
        XCTAssertEqual(try S6C3WS.read(repo + "/a.txt"), "from job one\n")
        XCTAssertFalse(S6C3WS.exists(one), "a landed job's copy is removed")
        let asked = await r.jobs.land(taskID: "local:job-2", title: "Job two", verifyCommand: nil, attempt: 0, check: noCheck)
        guard case .retry(let words) = asked else { return XCTFail("a conflict first asks the agent to resolve: \(asked)") }
        XCTAssertTrue(words.contains("a.txt"))
        let reported = await r.jobs.land(taskID: "local:job-2", title: "Job two", verifyCommand: nil, attempt: 1, check: noCheck)
        guard case .stuck(let why) = reported else { return XCTFail("an unresolved conflict is reported: \(reported)") }
        XCTAssertTrue(why.contains("Nothing was forced"))
        XCTAssertEqual(try S6C3WS.read(repo + "/a.txt"), "from job one\n", "nothing was forced onto the project")
        XCTAssertTrue(S6C3WS.exists(two), "the unresolved job stays open in its own copy")
    }

    func testAFailedCheckDoesNotLand() async throws {
        let r = try rig(); let repo = try await S6C3WS.repository(r.git, at: r.temp.sub("repo"))
        let one = try await copy(r, "local:job-1", repo)
        try S6C3WS.write(one + "/b.txt", "new\n")
        let result = await r.jobs.land(taskID: "local:job-1", title: "Job", verifyCommand: "make test", attempt: 1, check: { _, _ in (false, "1 test failed") })
        guard case .stuck(let why) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(why.contains("1 test failed")); XCTAssertFalse(S6C3WS.exists(repo + "/b.txt"))
    }

    func testAFolderWithoutGitRunsJobsOneAtATime() async throws {
        let r = try rig()
        let plain = r.temp.sub("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let folder = try await r.workspaces.folderFor(taskID: "local:job-2", project: plain, useWorkspace: true, title: "x", context: S6C3WS.context)
        XCTAssertNil(folder, "no git: no copy of its own")
        XCTAssertTrue(BackendParallelJobs.mustWait(parallelJob: true, folder: folder ?? plain, project: plain, siblingsLive: 1))
        XCTAssertFalse(BackendParallelJobs.mustWait(parallelJob: true, folder: folder ?? plain, project: plain, siblingsLive: 0), "it starts once the sibling is done")
        XCTAssertFalse(BackendParallelJobs.mustWait(parallelJob: true, folder: "/elsewhere/copy", project: plain, siblingsLive: 1), "a job with its own copy never waits")
    }
}
