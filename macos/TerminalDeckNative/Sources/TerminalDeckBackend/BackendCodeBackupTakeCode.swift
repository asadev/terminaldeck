import Foundation

/// "Switch to this Mac", the code half (owner, 15 Nov 2026; plan `switch-to-this-mac-plan.md` section 2.5 and R4):
/// the old Mac's code, exactly as its hand-over backup named it, laid into this Mac's project folder. Never loses work:
/// - this Mac's own folder was backed up just before (the caller), and its own unsaved changes are put aside in Git
///   (`git stash push -u -m "Terminal Deck: kept before switch <time>"`, got back with `git stash apply`) BEFORE any
///   file changes; when they cannot be put aside, nothing changes at all;
/// - his branch is moved only forward (a fast-forward to the old Mac's commit); with split histories the old Mac's
///   commit goes on a branch of its own (`<branch>-<Mac>`) and his branch stays exactly where it was;
/// - the old Mac's uncommitted work (the backup's `work` copy) is laid over the files without removing any (a file
///   that is only here stays); files Git ignores here are never overwritten by a checkout;
/// - no project folder or no code yet: the existing Get the code first (it keeps any file already there).
/// Only references under `refs/terminal-deck-switch/` are added for the fetched commits; nothing is pushed anywhere.
public struct BackendCodeBackupTakeCode: Sendable {
    /// What the old Mac named (`release`), or for a take without one only its name (its newest backup is used).
    public struct Named: Sendable, Equatable {
        public var branch: String?
        /// The backed-up branch commit: a backup keeper (its first parent is his branch) or his branch's commit itself.
        public var headSha: String?
        /// The copy of his uncommitted work (its first parent is the commit he was on).
        public var workSha: String?
        public var fromMac: String
        public var codeAt: Int64?
        public init(branch: String?, headSha: String?, workSha: String?, fromMac: String, codeAt: Int64?) {
            self.branch = branch; self.headSha = headSha; self.workSha = workSha; self.fromMac = fromMac; self.codeAt = codeAt
        }
    }
    public struct Result: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// His branch moved forward to the old Mac's commit (or was made, or was already there).
            case fastForward
            /// Split histories: the old Mac's code is on this branch; his branch untouched.
            case ownBranch(String)
            /// The folder had no code: it came down from GitHub, then the old Mac's exact code was laid in.
            case gotCode
            /// GitHub is not connected on this Mac: the code stays as it is here (the old Mac's backup is kept).
            case notConnected
            /// The old Mac never backed this project up: the code here is this Mac's own.
            case nothingBackedUp
            /// The folder's repository is not the project's GitHub home: nothing was changed.
            case otherProject
            case failed(String)
        }
        public var kind: Kind
        public var branch: String?
        /// The message of the stash his own changes are in now (nil: none, or they were put back).
        public var keptAside: String?
        /// The command that brings them back, when they are still in the stash after a failure.
        public var bringBack: String?
        /// Files Git ignores here that the old Mac's work would have written over: copied first into this folder.
        public var keptIgnoredFolder: String?
        public var keptIgnored: [String] = []
        /// A switch stopped half-way earlier was found and undone (his changes put back) before this one.
        public var resumed: String?
        /// When the laid-in code was backed up on the old Mac.
        public var codeAt: Int64?
        public init(kind: Kind, branch: String? = nil, keptAside: String? = nil, codeAt: Int64? = nil) {
            self.kind = kind; self.branch = branch; self.keptAside = keptAside; self.codeAt = codeAt
        }
        public var isFailure: Bool { if case .failed = kind { return true }; return false }
    }
    /// Written into the move's journal BEFORE his changes are put aside, cleared when the switch is over: a switch
    /// stopped half-way (quit, sleep, a killed Git) is found by the next start, reported and undone cleanly.
    public struct Pending: Codable, Sendable, Equatable {
        public var stash: String
        /// The commit and branch his folder was on before anything changed.
        public var head: String
        public var branch: String?
        /// The branch this switch may have moved forward (only ever from `head`).
        public var moved: String?
        /// The old Mac's work copy, once this switch started laying it over the files: the state the switch itself
        /// leaves is the commit it is on plus this. Anything else found later is his.
        public var laid: String?
        public var at: Int64
        public init(stash: String, head: String, branch: String?, moved: String? = nil, at: Int64) {
            self.stash = stash; self.head = head; self.branch = branch; self.moved = moved; self.at = at
        }
    }
    struct Failure: Error {
        let plain: String
        var keptAside: String?
        var bringBack: String?
        /// Files were already being written when it failed.
        var laidIn = false
        init(plain: String, keptAside: String? = nil, bringBack: String? = nil, laidIn: Bool = false) {
            self.plain = plain; self.keptAside = keptAside; self.bringBack = bringBack; self.laidIn = laidIn
        }
    }
    public static let refusedOtherProject = "This folder belongs to another project, so the code was not changed."

    let git: any BackendCodeBackupGitRunning
    let transport: BackendCodeBackupTransport
    /// "https://github.com/owner/name.git" (never holds the sign-in), for Get the code.
    let homeURL: String
    let folder: String
    /// The project's GitHub home ("owner/name") and host: a folder whose own remotes do not name it is refused.
    let home: String
    let host: String
    let now: Date
    /// The switch stopped half-way earlier, from the move's journal.
    let pending: Pending?
    /// Writes (or clears, nil) the journal's record; awaited before the stash.
    let record: @Sendable (Pending?) async -> Void
    let progress: @Sendable (String) -> Void

    public static let localNamespace = "refs/terminal-deck-switch/"
    public init(git: any BackendCodeBackupGitRunning, transport: BackendCodeBackupTransport, homeURL: String, folder: String,
                home: String, host: String = "github.com", now: Date = Date(), pending: Pending? = nil,
                record: @escaping @Sendable (Pending?) async -> Void = { _ in },
                progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.git = git; self.transport = transport; self.homeURL = homeURL; self.folder = folder; self.home = home; self.host = host
        self.now = now; self.pending = pending; self.record = record; self.progress = progress
    }

    private func run(_ arguments: [String], network: Bool = false, timeout: Int = 120_000, extra: [String: String] = [:]) async throws -> BackendGitOutcome {
        let base = network ? transport.environment : BackendCodeBackupGetCode.noLFS
        let outcome = try await git.run(cwd: folder, arguments: arguments, environment: base.merging(extra) { _, mine in mine },
                                        timeoutMilliseconds: timeout, maximumBytes: 16 * 1024 * 1024)
        if outcome.missing { throw Failure(plain: "Git is not installed on this Mac") }
        return outcome
    }
    private func text(_ outcome: BackendGitOutcome) -> String { outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func line(_ outcome: BackendGitOutcome) -> String {
        String((transport.scrub(outcome.stderr).split(separator: "\n").last.map(String.init) ?? "").prefix(160))
    }

    public func perform(_ named: Named) async -> Result {
        do { return try await body(named) }
        catch let failure as Failure {
            var result = Result(kind: .failed(failure.plain)); result.keptAside = failure.keptAside; result.bringBack = failure.bringBack
            return result
        }
        catch { return Result(kind: .failed("Git could not be started")) }
    }

    private func body(_ named: Named) async throws -> Result {
        let manager = FileManager.default
        var got = false
        // 0. No folder, or no code in it: made, then the existing Get the code (which keeps every file already there).
        if !manager.fileExists(atPath: folder) {
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        if !manager.fileExists(atPath: folder + "/.git") {
            progress("Getting the code")
            do {
                _ = try await BackendCodeBackupGetCode(git: git, transport: transport, homeURL: homeURL, folder: folder,
                                                       temporary: BackendCodeBackupGetCode.temporary(for: folder), progress: progress).perform()
                got = true
            } catch let failure as BackendCodeBackupGetCode.Failure {
                if failure.final { return Result(kind: .nothingBackedUp) }
                throw Failure(plain: failure.plain)
            }
        }
        // 0b. Only the project's own repository: one of its remotes must name the GitHub home (a name match is not enough).
        if !got {
            let remotes = try await run(["config", "--get-regexp", #"^remote\..*\.url$"#])
            let homes = BackendCodeBackupGitReader.remotes(remotes.stdout).compactMap { BackendCodeBackupGitReader.githubHome($0.url, host: host)?.lowercased() }
            guard homes.contains(home.lowercased()) else { return Result(kind: .otherProject) }
        }
        let gitDir = try await gitDirectory()
        if let busy = BackendCodeBackupSend.gitBusy(gitDir) {
            // A lock file left by a Git that was stopped (an app quit, a timeout): named in plain words, never removed here.
            if busy == "a Git command", let info = try? manager.attributesOfItem(atPath: gitDir + "/index.lock"),
               let since = info[.modificationDate] as? Date, now.timeIntervalSince(since) > 120 {
                throw Failure(plain: "Git left a lock file behind in this project (.git/index.lock, from \(Self.stamp(since))) and nothing was changed. "
                              + "Close any Git app using this folder, delete that file, then switch again")
            }
            throw Failure(plain: "Git is in the middle of \(busy) here")
        }
        // 0c. A switch stopped half-way before: undone cleanly first (his changes put back exactly), then this one runs.
        var resumed: String?
        if let pending { resumed = try await undoInterrupted(pending) }

        // 1. What GitHub holds: the refs the hand-over named, or (taken while the old Mac was off) its newest backup.
        let listing = try await run(["ls-remote", "--", transport.url], network: true)
        guard listing.ok else { throw Failure(plain: "GitHub did not answer (\(line(listing)))") }
        var remote: [(sha: String, ref: String)] = []
        for row in listing.stdout.split(separator: "\n") {
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[1].hasSuffix("^{}") { remote.append((parts[0], parts[1])) }
        }
        var head: (sha: String, ref: String)?, work: (sha: String, ref: String)?
        if let sha = named.headSha { head = remote.first { $0.sha == sha && $0.ref.hasPrefix(BackendCodeBackupPlan.namespace) } ?? remote.first { $0.sha == sha } }
        if let sha = named.workSha { work = remote.first { $0.sha == sha && $0.ref.hasPrefix(BackendCodeBackupPlan.namespace) } }
        let forced = named.headSha == nil && named.workSha == nil
        // The old Mac's own backup area: `<name>-<id>` (its name as System Settings shows it, as the rows carry it).
        let macPrefix = BackendCodeBackupPlan.namespace + BackendCodeBackupPlan.part(String(BackendCodeBackupPlan.part(named.fromMac).prefix(60))) + "-"
        let candidates = forced ? remote.filter { $0.ref.hasPrefix(macPrefix) && ($0.ref.contains("/heads/") || $0.ref.contains("/work/")) } : []
        let wanted = (forced ? candidates : [head, work].compactMap { $0 })
        guard !wanted.isEmpty || (!forced && named.headSha != nil) else { return Result(kind: got ? .gotCode : .nothingBackedUp) }

        // 2. Their commits into this repository under its own private names (nothing of his is moved by a fetch).
        var local: [String: String] = [:]
        if !wanted.isEmpty {
            progress("Getting the code from \(named.fromMac)")
            var specs: [String] = []
            for (index, item) in wanted.enumerated() {
                let name = Self.localNamespace + "\(index)"
                specs.append("+" + item.ref + ":" + name); local[item.ref] = name
            }
            let fetched = try await run(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--", transport.url] + specs,
                                        network: true, timeout: 600_000)
            guard fetched.ok else { throw Failure(plain: "The code could not be downloaded (\(line(fetched)))") }
        }
        if !forced, head == nil, let sha = named.headSha {
            // His branch's own commit, already on one of GitHub's branches: fetched with them.
            let fetched = try await run(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", transport.url,
                                         "+refs/heads/*:" + Self.localNamespace + "heads/*"], network: true, timeout: 600_000)
            guard fetched.ok, try await run(["cat-file", "-e", sha + "^{commit}"]).ok else { throw Failure(plain: "The code \(named.fromMac) backed up is not on GitHub") }
        }

        // 3. Which commit his branch should be at, and the work copy on top of it.
        var tip: String?, workCommit: String?, branch = named.branch, codeAt = named.codeAt
        func parent(_ commit: String) async throws -> String? {
            let read = try await run(["rev-parse", "--verify", "--quiet", commit + "^1"])
            return read.ok ? text(read) : nil
        }
        if forced {
            var newest: (sha: String, ref: String, at: Int64)?
            for item in candidates {
                let time = try await run(["log", "-1", "--format=%ct", item.sha])
                let at = Int64(text(time)) ?? 0
                if newest == nil || at > newest!.at { newest = (item.sha, item.ref, at) }
            }
            guard let newest else { return Result(kind: got ? .gotCode : .nothingBackedUp) }
            if codeAt == nil { codeAt = newest.at * 1000 }
            if newest.ref.contains("/work/") { workCommit = newest.sha; tip = try await parent(newest.sha) }
            else { tip = try await parent(newest.sha) }
            if branch == nil, let range = newest.ref.range(of: newest.ref.contains("/work/") ? "/work/" : "/heads/") {
                let part = String(newest.ref[range.upperBound...])
                branch = part == "no-branch" ? nil : part.replacingOccurrences(of: "--", with: "/")
            }
        } else {
            if let head, let sha = named.headSha {
                tip = head.ref.hasPrefix(BackendCodeBackupPlan.namespace) && head.ref.contains("/heads/") ? try await parent(sha) : sha
            } else if let sha = named.headSha { tip = sha }
            if work != nil, let sha = named.workSha {
                workCommit = sha
                if tip == nil { tip = try await parent(sha) }
            }
        }

        // 4. His own unsaved changes here are put aside in Git first. The journal knows the stash's name and his commit
        //    BEFORE it is made; from then on every way out either puts them back exactly or names where they are.
        var kept: String?
        let status = try await run(["status", "--porcelain=v1", "--untracked-files=all"])
        guard status.ok else { throw Failure(plain: "Git could not read the folder") }
        let startRead = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
        let currentRead = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        var plan = Pending(stash: "Terminal Deck: kept before switch " + Self.stamp(now), head: text(startRead),
                           branch: currentRead.ok ? text(currentRead) : nil, at: Int64(now.timeIntervalSince1970 * 1000))
        if !text(status).isEmpty {
            await record(plan)
            // A Mac with no Git name set still gets its changes put aside (Git needs a name to make the stash).
            let stashed = try await run(["stash", "push", "--include-untracked", "-m", plan.stash], extra: try await identity())
            guard try await stashRef(plan.stash) != nil else {
                await record(nil)
                throw Failure(plain: "your unsaved changes here could not be put aside (\(line(stashed))), so nothing was changed")
            }
            kept = plan.stash
            let after = try await run(["status", "--porcelain=v1", "--untracked-files=all"])
            if !after.ok || !text(after).isEmpty {
                // Git could not take everything (a nested Git folder, a file it cannot remove): put back at once.
                throw try await failAfterStash(Failure(plain: "Git could not put all of your unsaved changes here aside, so the code was not changed"), plan, partly: true)
            }
        }
        do {
            var result = try await layIn(named: named, tip: tip, workCommit: workCommit, branch: branch, got: got, plan: &plan, stashed: kept != nil)
            await record(nil)
            result.keptAside = kept; result.codeAt = codeAt; result.resumed = resumed
            return result
        } catch let failure as Failure where kept != nil {
            throw try await failAfterStash(failure, plan)
        } catch where kept != nil {
            // Stopped or Git could not start: the same rule (the journal still holds it if this, too, is cut off).
            throw try await failAfterStash(Failure(plain: "the switch was stopped"), plan)
        }
    }

    /// Steps 5 and 6, after the stash.
    private func layIn(named: Named, tip: String?, workCommit: String?, branch: String?, got: Bool, plan: inout Pending, stashed: Bool) async throws -> Result {
        func parent(_ commit: String) async throws -> String? {
            let read = try await run(["rev-parse", "--verify", "--quiet", commit + "^1"])
            return read.ok ? text(read) : nil
        }
        // 5. The branch: forward only; split histories on a branch of its own.
        var kind: Result.Kind = got ? .gotCode : .fastForward
        var target: String?
        if let tip {
            let current = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"])
            let name = branch ?? (current.ok ? text(current) : "main")
            let mine = try await run(["rev-parse", "--verify", "--quiet", "refs/heads/" + name])
            if !mine.ok {
                guard try await run(["branch", "--no-track", name, tip]).ok else { throw Failure(plain: "the branch \(name) could not be made") }
                target = name
            } else if text(mine) == tip {
                target = name
            } else if try await run(["merge-base", "--is-ancestor", text(mine), tip]).exitCode == 0 {
                target = name
            } else {
                // His branch has commits the old Mac's does not: it stays exactly as it is.
                var own = name + "-" + BackendCodeBackupPlan.part(named.fromMac)
                var index = 2
                while true {
                    let there = try await run(["rev-parse", "--verify", "--quiet", "refs/heads/" + own])
                    if !there.ok { guard try await run(["branch", "--no-track", own, tip]).ok else { throw Failure(plain: "a branch could not be made") }; break }
                    if text(there) == tip { break }
                    own = name + "-" + BackendCodeBackupPlan.part(named.fromMac) + "-\(index)"; index += 1
                }
                target = own
                kind = .ownBranch(own)
            }
            if let target {
                let checkout = try await run(["checkout", "-q", "--no-overwrite-ignore", target], timeout: 600_000)
                guard checkout.ok else { throw Failure(plain: "the branch \(target) could not be opened (\(line(checkout)))") }
                if kind != .ownBranch(target) {
                    if stashed { plan.moved = target; await record(plan) }
                    let forward = try await run(["merge", "--ff-only", "--no-overwrite-ignore", "-q", tip], timeout: 600_000)
                    guard forward.ok else { throw Failure(plain: "the branch \(target) could not be moved forward (\(line(forward)))") }
                }
            }
        }

        // 6. The old Mac's uncommitted work over the files (adds and changes only; nothing removed). A file it would write
        //    over that is on disk but not tracked here can only be one Git ignores here (his own changes are in the
        //    stash): copied first to `.git/terminal-deck-switch/kept-<time>/`, same relative path, and named.
        var result = Result(kind: kind, branch: target)
        if let workCommit, let tip, let base = try await parent(workCommit), base == tip {
            let changed = try await run(["diff", "--name-only", "-z", "--no-renames", tip, workCommit])
            guard changed.ok else { throw Failure(plain: "its unsaved work could not be read (\(line(changed)))") }
            let paths = changed.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
            let tracked = Set(try await run(["ls-files", "-z"]).stdout.split(separator: "\0").map(String.init))
            let manager = FileManager.default
            let onDisk = paths.filter { path in
                var info = stat()
                return !tracked.contains(path) && lstat(folder + "/" + path, &info) == 0
            }
            if !onDisk.isEmpty {
                let keep = try await gitDirectory() + "/terminal-deck-switch/kept-" + Self.fileStamp(now)
                for path in onDisk {
                    let destination = keep + "/" + path
                    do {
                        try manager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                        if !manager.fileExists(atPath: destination) { try manager.copyItem(atPath: folder + "/" + path, toPath: destination) }
                    } catch { throw Failure(plain: "\(path) (a file Git ignores here) could not be kept first, so the unsaved work was not laid in") }
                }
                result.keptIgnoredFolder = keep; result.keptIgnored = onDisk.sorted()
            }
            if stashed { plan.laid = workCommit; await record(plan) }
            let laid = try await run(["restore", "--source=" + workCommit, "--worktree", "--overlay", "--", "."], timeout: 600_000)
            guard laid.ok else { throw Failure(plain: "its unsaved work could not be laid in (\(line(laid)))", laidIn: true) }
        }
        return result
    }

    // MARK: Never losing his changes after the stash

    private func gitDirectory() async throws -> String {
        let read = try await run(["rev-parse", "--absolute-git-dir"])
        guard read.ok, !text(read).isEmpty else { throw Failure(plain: "Git could not read the folder") }
        return text(read)
    }
    /// A Mac with no Git name set still gets its changes put aside and back (Git needs a name to make a stash).
    private func identity() async throws -> [String: String] {
        if try await run(["config", "--get", "user.email"]).ok { return [:] }
        return ["GIT_AUTHOR_NAME": "Terminal Deck", "GIT_AUTHOR_EMAIL": "terminal-deck@localhost",
                "GIT_COMMITTER_NAME": "Terminal Deck", "GIT_COMMITTER_EMAIL": "terminal-deck@localhost"]
    }
    /// `stash@{n}` of the stash with exactly this message (nil: there is none).
    private func stashRef(_ message: String) async throws -> String? {
        let list = try await run(["stash", "list", "--format=%gd%x09%gs"])
        for row in list.stdout.split(separator: "\n") {
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[1] == message || parts[1].hasSuffix(": " + message) { return parts[0] }
        }
        return nil
    }
    /// Back exactly where he was: his branch at his commit (a branch this switch moved forward goes back to his
    /// commit), what the switch laid in taken away (tracked files reset, untracked ones removed; files Git ignores are
    /// never touched), then his stash applied with its staged part. Only called while his changes are all in the stash.
    /// `partly`: Git could not take everything, so some of his changes are still on disk: then nothing is reset or
    /// removed, the stash is only applied back over them.
    private func putBack(_ plan: Pending, partly: Bool = false) async throws -> (back: Bool, line: String) {
        guard let ref = try await stashRef(plan.stash) else { return (true, "") }
        var ok = true
        if !partly {
            ok = try await run(["checkout", "-q", "-f", plan.branch ?? plan.head]).ok
            if ok, let moved = plan.moved, moved == plan.branch, !plan.head.isEmpty { ok = try await run(["reset", "-q", "--hard", plan.head]).ok }
            if ok { ok = try await run(["clean", "-q", "-f", "-d"]).ok }
        }
        if ok { ok = try await run(["stash", "pop", "--index", "-q", ref], extra: try await identity()).ok }
        if ok, try await stashRef(plan.stash) == nil { return (true, "Your unsaved changes here are back as they were.") }
        let now = try await stashRef(plan.stash) ?? ref
        return (false, "Your unsaved changes here are kept in Git as \"\(plan.stash)\"; to bring them back, in the project folder: git stash apply \(now)")
    }
    /// Every way out after a stash: nothing laid in yet = put back exactly; otherwise the failure names the stash and
    /// the one command that brings his changes back. Never "nothing was changed" once a stash ran and stayed.
    private func failAfterStash(_ failure: Failure, _ plan: Pending, partly: Bool = false) async throws -> Failure {
        if !failure.laidIn {
            // A live switch can fail after minutes of checkout or merge: anything written here meanwhile (an editor's
            // autosave, an AI session, a new file) is put aside first, as for a stopped switch (Reviewer, 15 Nov). If
            // that fails, nothing is reset or removed. `partly`: nothing is reset anyway, so nothing to put aside.
            var later = ""
            if !partly {
                let edits = try await setAsideLaterEdits(plan)
                switch edits {
                case .failed:
                    let ref = try await stashRef(plan.stash) ?? "stash@{0}"
                    await record(nil)
                    return Failure(plain: failure.plain + ". The files changed here during the switch could not be put aside, so nothing was undone: "
                                   + "your unsaved changes from before it are kept in Git as \"\(plan.stash)\"; to bring them back, in the project folder: git stash apply \(ref)",
                                   keptAside: plan.stash, bringBack: "git stash apply " + ref)
                case .stashed(let name): later = " Files changed here during the switch are kept as '\(name)'."
                case .copied(let folder): later = " Files changed here during the switch are kept as copies in '\(folder)'."
                case .none: break
                }
            }
            let back = try await putBack(plan, partly: partly)
            await record(nil)
            if back.back { return Failure(plain: failure.plain + ". " + back.line + later) }
            return Failure(plain: failure.plain + ". " + back.line + later, keptAside: plan.stash, bringBack: Self.command(back.line))
        }
        let ref = try await stashRef(plan.stash) ?? "stash@{0}"
        await record(nil)
        return Failure(plain: failure.plain + ". Your unsaved changes here are kept in Git as \"\(plan.stash)\"; to bring them back, in the project folder: git stash apply \(ref)",
                       keptAside: plan.stash, bringBack: "git stash apply " + ref)
    }
    /// A switch stopped half-way earlier: undone, his changes put back; the sentence for the result.
    private func undoInterrupted(_ plan: Pending) async throws -> String? {
        let when = Self.stamp(Date(timeIntervalSince1970: TimeInterval(plan.at) / 1000))
        guard let original = try await stashRef(plan.stash) else { await record(nil); return nil }
        // Before anything is reset or removed: what he changed here AFTER the switch stopped is put aside (a second
        // stash, untracked files included; else copies). If that fails, nothing is undone and the folder stays as it is.
        let edits = try await setAsideLaterEdits(plan)
        if case .failed = edits {
            throw Failure(plain: "A switch here was stopped half-way at \(when) and the files you changed since could not be put aside, so nothing was undone: "
                          + "your changes from before it are in Git as \"\(plan.stash)\" (git stash apply \(original)); save your work, then switch again",
                          keptAside: plan.stash, bringBack: "git stash apply " + original)
        }
        let back = try await putBack(plan)
        await record(nil)
        var later = ""
        switch edits {
        case .stashed(let name): later = " You changed files here while the switch was stopped; those changes are kept as '\(name)'."
        case .copied(let folder): later = " You changed files here while the switch was stopped; those changes are kept as copies in '\(folder)'."
        default: break
        }
        guard back.back else {
            throw Failure(plain: "A switch here was stopped half-way at \(when). " + back.line + later, keptAside: plan.stash, bringBack: Self.command(back.line))
        }
        return "A switch here was stopped half-way at \(when); it was undone and your unsaved changes were put back first." + later
    }

    enum LaterEdits: Equatable { case none, stashed(String), copied(String), failed }
    /// Compares the folder with what the stopped switch itself left (its commit, plus the old Mac's work copy when it
    /// had started laying it in). Changed tracked files and new untracked files that differ from that are his: put
    /// aside in a stash of their own (untracked included), else copied to `.git/terminal-deck-switch/kept-<time>/`.
    /// Files Git ignores are not looked at and never touched.
    private func setAsideLaterEdits(_ plan: Pending) async throws -> LaterEdits {
        let status = try await run(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"])
        guard status.ok else { return .failed }
        let paths = status.stdout.split(separator: "\0").compactMap { entry -> String? in
            let text = String(entry)
            return text.count > 3 ? String(text.dropFirst(3)) : nil
        }
        guard !paths.isEmpty else { return .none }
        var his: [String] = []
        for path in paths {
            var info = stat()
            let exists = lstat(folder + "/" + path, &info) == 0
            if let laid = plan.laid, exists {
                let blob = try await run(["rev-parse", "--verify", "--quiet", laid + ":" + path])
                let file = try await run(["hash-object", "--no-filters", "--", path])
                if blob.ok, file.ok, text(blob) == text(file) { continue }   // what the switch laid in, unchanged
            }
            his.append(path)
        }
        guard !his.isEmpty else { return .none }
        let name = "Terminal Deck: your edits made during a stopped switch, " + Self.stamp(now)
        _ = try await run(["stash", "push", "--include-untracked", "-m", name], extra: try await identity())
        let after = try await run(["status", "--porcelain=v1", "--untracked-files=all"])
        if try await stashRef(name) != nil, after.ok, text(after).isEmpty { return .stashed(name) }
        // A stash could not take them all: copies of whatever is still changed (and, if the stash took some, both).
        let rest = try await run(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"])
        let left = rest.stdout.split(separator: "\0").compactMap { entry -> String? in
            let text = String(entry)
            return text.count > 3 ? String(text.dropFirst(3)) : nil
        }
        let keep = try await gitDirectory() + "/terminal-deck-switch/kept-" + Self.fileStamp(now) + "-edits"
        let manager = FileManager.default
        for path in left {
            var info = stat()
            guard lstat(folder + "/" + path, &info) == 0 else { continue }
            do {
                try manager.createDirectory(atPath: ((keep + "/" + path) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if !manager.fileExists(atPath: keep + "/" + path) { try manager.copyItem(atPath: folder + "/" + path, toPath: keep + "/" + path) }
            } catch { return .failed }
        }
        return try await stashRef(name) != nil ? .stashed(name + "' and copies in '" + keep) : .copied(keep)
    }
    static func command(_ line: String) -> String? {
        line.range(of: "git stash apply ").map { String(line[$0.lowerBound...]) }
    }
    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: The two Macs' code steps on the Code page's one actor (so a move never runs beside another backup of the project)

extension BackendCodeBackupActions {
    /// The old Mac, after the session stopped: Back up now (not marked as his own click), then the exact names the
    /// hand-over carries: his branch, the backed-up commit for it (a keeper whose first parent is his branch commit,
    /// or his commit itself when GitHub already has it on a branch) and the copy of his uncommitted work when he has any.
    public func handOver(projectID: String?, folder: String) async -> BackendCloudSessionMove.CodeHandOver? {
        guard let projectID, let project = await projects.list().first(where: { $0.id == projectID }) else { return nil }
        let outcome = await backUp(projectID: projectID)
        let (_, places) = await projects.fresh(project)
        guard let place = places.first else { return .init(ok: outcome.ok, codeAt: nil, branch: nil, headSha: nil, workSha: nil) }
        func read(_ arguments: [String], shadow: Bool = false) async -> String? {
            let environment = shadow ? ["GIT_DIR": Self.shadow(workArea, gitDir: place.gitDir)] : [:]
            guard let outcome = try? await git.run(cwd: place.top, arguments: arguments, environment: environment, timeoutMilliseconds: 30_000, maximumBytes: 1_048_576),
                  outcome.ok else { return nil }
            let text = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let branch = await read(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let tip = await read(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
        let at = ledger.coverage(place.gitDir)?.at ?? 0
        var handOver = BackendCloudSessionMove.CodeHandOver(ok: outcome.ok, codeAt: at > 0 ? at : nil, branch: branch, headSha: tip, workSha: nil)
        guard outcome.ok, let home = ledger.home(projectID), let transport = await account.transport(home) else { return handOver }
        let area = BackendCodeBackupPlan.mine(mac), part = BackendCodeBackupPlan.part(branch ?? "no-branch")
        guard let listing = try? await git.run(cwd: place.top, arguments: ["ls-remote", "--", transport.url, area + "heads/" + part, area + "work/" + part],
                                               environment: transport.environment, timeoutMilliseconds: 120_000, maximumBytes: 1_048_576), listing.ok else { return handOver }
        var found: [String: String] = [:]
        for row in listing.stdout.split(separator: "\n") {
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { found[parts[1]] = parts[0] }
        }
        // A keeper counts only when it keeps exactly the commit he is on (an older keeper would name older code).
        if let keeper = found[area + "heads/" + part], let tip, await read(["rev-parse", "--verify", "--quiet", keeper + "^1"], shadow: true) == tip {
            handOver.headSha = keeper
        }
        // The work copy only when there IS uncommitted work now (a clean folder leaves an older copy in place).
        if let work = found[area + "work/" + part], await read(["status", "--porcelain=v1", "--untracked-files=all"]) != nil,
           await read(["rev-parse", "--verify", "--quiet", work + "^1"], shadow: true) == tip {
            handOver.workSha = work
        }
        return handOver
    }

    /// This Mac: the old Mac's code into the project's folder (see `BackendCodeBackupTakeCode`). GitHub not connected:
    /// nothing changes here and the old Mac's backup is kept.
    public func takeCode(projectID: String?, folder: String, named: BackendCodeBackupTakeCode.Named,
                         pending: BackendCodeBackupTakeCode.Pending? = nil,
                         record: @escaping @Sendable (BackendCodeBackupTakeCode.Pending?) async -> Void = { _ in },
                         progress: @escaping @Sendable (String) -> Void = { _ in }) async -> BackendCodeBackupTakeCode.Result {
        guard let login = await account.login() else { return .init(kind: .notConnected) }
        var home = projectID.flatMap { ledger.home($0) }
        let project = projectID == nil ? nil : await projects.list().first { $0.id == projectID }
        if home == nil, let project { home = await projects.fresh(project).0.home }
        if home == nil, let project { home = Self.match(name: project.name, repositories: await account.repositories(), login: login) }
        guard let home else { return .init(kind: .nothingBackedUp) }
        guard let transport = await account.transport(home) else { return .init(kind: .notConnected) }
        let result = await BackendCodeBackupTakeCode(git: git, transport: transport, homeURL: "https://\(host)/\(home).git", folder: folder,
                                                     home: home, host: host, now: now(), pending: pending, record: record,
                                                     progress: progress).perform(named)
        if let projectID {
            switch result.kind {
            case .failed, .otherProject: break
            default: ledger.setHome(projectID, home)
            }
            await projects.forget(projectID)
        }
        return result
    }

    /// When this Mac last backed the project up (the list row's `codeAt`, "the code here is from <time>" elsewhere).
    public func lastBackup(projectID: String) -> Int64? { ledger.sentAt(projectID) }
}
