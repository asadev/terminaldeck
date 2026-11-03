import Foundation
import TerminalDeckNativeCore

// Parallel jobs of one agent (Asad, 12 Oct: "Tasks at once", safe by design).
// - A job that starts while the same agent already has a live job runs in its OWN git worktree on its own
//   branch, made from the project's current head (BackendWorkspaceService). Two jobs never write one checkout.
// - Jobs claim the files they edit (task value `claims`); siblings see the claims and the files each job has
//   really changed (tasks_claims, and their brief).
// - When a job finishes it lands: its leftovers are committed, the project's branch is merged into the job's
//   branch (siblings' work comes in), the agent's check runs in the job's copy, and the project's branch is
//   fast-forwarded to it. A conflict or a failed check never forces anything: the agent is asked once to
//   resolve (it knows its own change); after that the job stays open and its lead or Hoot is told.
// - A folder without git runs the agent's jobs one at a time (the engine waits).
// - After landing, the job's worktree is removed and its merged branch deleted.

public actor BackendParallelJobs {
    public typealias Git = @Sendable (_ cwd: String, _ arguments: [String]) async throws -> BackendGitOutcome
    public typealias Check = @Sendable (_ command: String, _ cwd: String) async throws -> (ok: Bool, output: String)
    /// The task's workspace (`path`, `branch`, `repo`, `base`, `state`), or nil.
    public typealias Workspace = @Sendable (_ taskID: String) async throws -> NativeRPCValue?
    public typealias Remove = @Sendable (_ taskID: String) async throws -> Void

    public enum Landing: Equatable, Sendable {
        /// Merged into the project's branch; one plain line saying so.
        case landed(String)
        /// Not landed yet: the agent is asked to do this (it knows its own change).
        case retry(String)
        /// Not landed, and it will not be forced: the job stays open; its lead or Hoot is told this.
        case stuck(String)
        /// Not a job with its own copy (nothing to land).
        case notParallel
    }

    private let git: Git, workspace: Workspace, remove: Remove
    private var busyRepos: Set<String> = [], waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    public init(git: @escaping Git, workspace: @escaping Workspace, remove: @escaping Remove) {
        self.git = git; self.workspace = workspace; self.remove = remove
    }

    /// The job's branch and folder while it has its own copy.
    public func copy(of taskID: String) async -> (branch: String, path: String, repo: String)? {
        guard let record = try? await workspace(taskID), record["state"].string != "removed",
              let branch = record["branch"].string, let path = record["path"].string, let repo = record["repo"].string else { return nil }
        return (branch, path, repo)
    }

    /// Files the job has changed in its copy so far (committed on its branch or not).
    public func changedFiles(_ taskID: String) async -> [String] {
        guard let record = try? await workspace(taskID), record["state"].string != "removed", let path = record["path"].string, let base = record["base"].string else { return [] }
        var files = Set<String>()
        if let diff = try? await git(path, ["diff", "--name-only", base]), diff.ok { files.formUnion(lines(diff.stdout)) }
        if let status = try? await git(path, ["status", "--porcelain"]), status.ok { files.formUnion(lines(status.stdout).map { String($0.dropFirst(3)) }) }
        return files.sorted()
    }

    /// Land one finished job (see the file's note). `attempt` 0 asks the agent to resolve; later attempts report.
    public func land(taskID: String, title: String, verifyCommand: String?, attempt: Int, check: Check) async -> Landing {
        guard let record = try? await workspace(taskID), record["state"].string != "removed",
              let path = record["path"].string, let branch = record["branch"].string, let repo = record["repo"].string else { return .notParallel }
        await lock(repo); defer { unlock(repo) }
        do {
            let identity = try await identityArguments(path)
            let status = try await git(path, ["status", "--porcelain"])
            if status.ok, !lines(status.stdout).isEmpty {
                _ = try await git(path, ["add", "-A"])
                let commit = try await git(path, identity + ["commit", "-q", "-m", String("\(title) (\(taskID))".prefix(200))])
                guard commit.ok else { return .stuck("Its changes could not be committed on \(branch), so nothing was landed: \(short(commit.stderr)) The work stays in \(path).") }
            }
            let head = try await git(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"])
            guard head.ok, let target = lines(head.stdout).first else {
                return .stuck("The project folder \(repo) is not on a branch, so the job's work was not landed. It stays on \(branch) in \(path).")
            }
            let merged = try await git(path, identity + ["merge", "--no-edit", target])
            if !merged.ok {
                let conflicted = lines((try? await git(path, ["diff", "--name-only", "--diff-filter=U"]))?.stdout ?? "")
                _ = try? await git(path, ["merge", "--abort"])
                let files = conflicted.isEmpty ? "the same lines" : conflicted.prefix(10).joined(separator: ", ")
                if attempt == 0 {
                    return .retry("Another job of yours already landed changes in \(files). Nothing was landed yet. In your folder (\(path), branch \(branch)), merge \(target) into your branch, keep both their change and yours, commit, run the check, then say you are done again.")
                }
                return .stuck("This job's branch \(branch) conflicts with work already on \(target) in \(files), and it was not resolved. Nothing was forced: the job stays open in \(path) for its lead or Hoot to decide.")
            }
            if let command = verifyCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
                let result = try await check(command, path)
                guard result.ok else {
                    let output = String(result.output.suffix(1_200))
                    if attempt == 0 { return .retry("After merging the latest \(target) into your branch, the check (\(command)) failed. Fix it in your folder (\(path)), commit, then say you are done again.\n\n\(output)") }
                    return .stuck("The check (\(command)) still fails on \(branch) after merging \(target), so nothing was landed. The job stays open in \(path).\n\n\(output)")
                }
            }
            let forward = try await git(repo, ["merge", "--ff-only", "--quiet", branch])
            guard forward.ok else {
                return .stuck("\(branch) could not be landed on \(target) in \(repo): \(short(forward.stderr)) Usually the project folder has its own unsaved changes in the same files. Nothing was forced; the job stays on \(branch).")
            }
            try? await remove(taskID)
            _ = try? await git(repo, ["branch", "-d", branch])
            return .landed("Landed: \(branch) was merged into \(target)\(verifyCommand?.isEmpty == false ? " after the check passed" : ""), and its separate copy was removed.")
        } catch {
            return .stuck("The job's work could not be landed: \(error.localizedDescription) It stays on \(branch) in \(path).")
        }
    }

    // MARK: Claims (on the task value `claims`, shared by every job of the agent)

    /// Claim (or release) files for one job. Paths are relative to the project.
    public static func claim(_ taskID: String, paths: [String], release: Bool, store: BackendTaskStore) async throws -> [String] {
        guard let task = try await store.byID(taskID) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        let clean = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.utf16.count <= 500 }
        var claims = (task.value["claims"].elements ?? []).compactMap(\.string)
        if release { claims.removeAll { clean.isEmpty || clean.contains($0) } } else { for path in clean where !claims.contains(path) { claims.append(path) } }
        claims = Array(claims.prefix(200))
        _ = try await store.update(taskID, patch: BackendTaskValues.object([("claims", .array(claims.map(NativeRPCValue.string)))]))
        return claims
    }

    /// The live jobs of one agent (or of every agent), each with its branch, folder, claims and changed files.
    public func jobs(agentID: String?, store: BackendTaskStore) async throws -> NativeRPCValue {
        let live = try await store.all().filter { task in
            task.assigneeKind == "agent" && (agentID == nil || task.agentID == agentID) && task.value["stopped"].bool != true
                && task.value["result"].isNullish && ["queued", "running"].contains(task.process)
                && (agentID != nil || task.value["parallelJob"].bool == true || !(task.value["claims"].elements ?? []).isEmpty)
        }
        var rows: [NativeRPCValue] = []
        for task in live.sorted(by: { ($0.value["createdAt"].number ?? 0) < ($1.value["createdAt"].number ?? 0) }) {
            let own = await copy(of: task.id)
            rows.append(BackendTaskValues.object([("task", .string(task.id)), ("agent", .string(task.agentID)), ("title", task.value["title"]),
                ("process", .string(task.process)), ("ownCopy", .bool(own != nil)), ("branch", own.map { .string($0.branch) } ?? .null),
                ("folder", .string(own?.path ?? task.project)), ("claims", .array((task.value["claims"].elements ?? []))),
                ("changed", .array(await changedFiles(task.id).prefix(100).map(NativeRPCValue.string)))]))
        }
        return BackendTaskValues.object([("jobs", .array(rows))])
    }

    // MARK: Helpers

    private func identityArguments(_ cwd: String) async throws -> [String] {
        let email = try await git(cwd, ["config", "user.email"])
        return email.ok && !email.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["-c", "user.name=Terminal Deck", "-c", "user.email=tasks@terminaldeck.dev"]
    }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    private func short(_ text: String) -> String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
    private func lock(_ repo: String) async {
        if !busyRepos.contains(repo) { busyRepos.insert(repo); return }
        await withCheckedContinuation { waiters[repo, default: []].append($0) }
    }
    private func unlock(_ repo: String) {
        if var queue = waiters[repo], !queue.isEmpty { let next = queue.removeFirst(); waiters[repo] = queue; next.resume() } else { waiters[repo] = nil; busyRepos.remove(repo) }
    }
}

extension BackendParallelJobs {
    /// The part of a parallel job's brief that tells it how to work beside its siblings.
    public static func brief(branch: String, folder: String) -> String {
        "\n\n## Working beside your other jobs\n\nYou are running more than one job at once. This job has its own copy of the project in \(folder), on the branch \(branch), made from the project's current state. Work only there.\n"
            + "- Before you edit a file, claim it: tasks_claims with do claim and paths. Release what you no longer need.\n"
            + "- See what your other jobs claimed and changed: tasks_claims with do list. Avoid their files.\n"
            + "- When you finish, Terminal Deck commits what is left, merges the project's latest work into your branch, runs your check and lands it. If another job changed the same files, you will be asked to merge and resolve, keeping both changes.\n"
    }
}

/// The running parallel-jobs service, for the task tools (assembled with the task engine).
public actor BackendParallelJobsBox {
    public static let shared = BackendParallelJobsBox()
    private var service: BackendParallelJobs?
    public func set(_ jobs: BackendParallelJobs?) { service = jobs }
    public func jobs() -> BackendParallelJobs? { service }
}

extension BackendParallelJobs {
    /// A parallel job that got no copy of its own (the folder has no git, or no commit yet) waits while a sibling
    /// job of the same agent is live: one at a time in one checkout.
    public static func mustWait(parallelJob: Bool, folder: String, project: String, siblingsLive: Int) -> Bool {
        parallelJob && folder == project && siblingsLive > 0
    }
}
