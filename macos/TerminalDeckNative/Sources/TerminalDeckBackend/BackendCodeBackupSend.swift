import Foundation
import Darwin
import TerminalDeckNativeCore

/// Git for the Code page's ACTIONS (L5 slice 2). Like `BackendGitRunner`, plus settings this caller sets itself
/// (a separate staging-area file, the sign-in's `GIT_CONFIG_*`). Every command: no hooks, no automatic clean-up, no
/// signing prompts, no pager, no file-system monitor, `GIT_OPTIONAL_LOCKS=0`, and Git never climbs into the home folder.
public protocol BackendCodeBackupGitRunning: Sendable {
    func run(cwd: String, arguments: [String], environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome
}

public struct BackendCodeBackupGitWriter: BackendCodeBackupGitRunning {
    private let inherited: [String: String]
    private let loginPath: @Sendable () async throws -> String
    private let home: String
    private let executor = BackendGitPipeExecutor()

    public init(inheritedEnvironment: [String: String], home: String, loginPath: @escaping @Sendable () async throws -> String) {
        inherited = inheritedEnvironment; self.home = home; self.loginPath = loginPath
    }

    static let flags = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false",
                        "-c", "core.untrackedCache=false", "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false", "-c", "push.gpgSign=false",
                        "-c", "fetch.prune=false", "-c", "fetch.pruneTags=false", "-c", "fetch.recurseSubmodules=false",
                        "-c", "push.recurseSubmodules=no", "-c", "push.followTags=false", "-c", "push.default=nothing",
                        "-c", "submodule.recurse=false", "-c", "advice.detachedHead=false"]

    public func run(cwd: String, arguments: [String], environment extra: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        try Task.checkCancellation()
        let path = try await loginPath()
        guard let executable = BackendNativeProviders.lookup("git", path: path) else {
            return BackendGitOutcome(ok: false, stdout: "", stderr: "git is not installed", missing: true, exitCode: 127, timedOut: false)
        }
        var environment = BackendSessionEnvironment.stripInherited(inherited)
        for name in BackendGitRunner.repositoryVariables { environment[name] = nil }
        for key in environment.keys where key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_") || key == "GIT_CONFIG_COUNT" { environment[key] = nil }
        environment["PATH"] = path; environment["LC_ALL"] = "C"; environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"; environment["PAGER"] = "cat"; environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_CEILING_DIRECTORIES"] = home
        for (key, value) in extra { environment[key] = value }
        let plan = BackendGitExecutionPlan(command: executable, arguments: ["--no-pager"] + Self.flags + arguments, environment: environment, cwd: cwd)
        return try await executor.run(plan, timeout: min(max(timeoutMilliseconds, 1), 600_000), maximum: min(max(maximumBytes, 1), 32 * 1024 * 1024))
    }

    /// Settings passed to Git through its environment (`GIT_CONFIG_COUNT`), never through arguments.
    public static func settings(_ pairs: [(String, String)], extra: [String: String] = [:]) -> [String: String] {
        var environment = extra
        environment["GIT_CONFIG_COUNT"] = String(pairs.count)
        for (index, pair) in pairs.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = pair.0
            environment["GIT_CONFIG_VALUE_\(index)"] = pair.1
        }
        return environment
    }
}

/// The "adds only" rule, in one place and tested on its own. What may be sent to GitHub is a list of
/// `<commit>:<full reference>` pairs: never a `+` (a forced update), never an empty source (a deletion), never a
/// pattern. Git itself then refuses anything that is not a fast-forward and any existing tag.
///
/// Correction 14 Nov (lead): a push to a real branch or tag is not a neutral backup on his repositories: deploys,
/// release workflows, preview builds and CI hang on them. So there are two kinds of home:
/// - a home Terminal Deck did NOT make (every repository he already had): the backup writes ONLY under
///   `refs/terminal-deck-backup/<Mac>/…`, which is neither a branch nor a tag (`privateOnly`);
/// - a home Terminal Deck made itself and on which nothing reacts to a push yet: his branches and tags go under their
///   real names (so "Get the code" is an ordinary clone), and uncommitted work still goes under the private references.
public enum BackendCodeBackupPlan {
    public struct Step: Sendable, Equatable {
        public let commit: String
        public let reference: String
        public init(commit: String, reference: String) { self.commit = commit; self.reference = reference }
        public var refspec: String { commit + ":" + reference }
    }

    /// The private references: not a branch, not a tag. Per Mac: `<Mac>/heads/<branch>`, `<Mac>/tags/<tag>`,
    /// `<Mac>/work/<branch>`, `<Mac>/set-aside`.
    public static let namespace = "refs/terminal-deck-backup/"
    /// Review 14 Nov (lead): in this release EVERY home, a home Terminal Deck made included, gets only the private
    /// references. A workflow file committed later, or an app linked to that one repository, would not be noticed
    /// before a branch push started it. The "quiet home" code (`make`, `BackendCodeBackupAccount.quiet`) stays, but is
    /// unreachable while this is false; "Get the code" opens homes that hold only private references.
    public static let realNamesAllowed = false
    /// Slice-2 first draft used branches with this prefix; never sent any more, still skipped when seen.
    public static let prefix = "terminal-deck-backup/"

    public static func mine(_ mac: String) -> String { namespace + part(mac) + "/" }

    public static func addsOnly(_ refspec: String) -> Bool {
        guard !refspec.hasPrefix("+"), !refspec.hasPrefix(":"), !refspec.hasPrefix("^"), !refspec.contains("*"),
              let colon = refspec.firstIndex(of: ":"), refspec[refspec.index(after: colon)...].firstIndex(of: ":") == nil else { return false }
        let source = refspec[..<colon], destination = String(refspec[refspec.index(after: colon)...])
        guard source.count >= 40, source.allSatisfy(\.isHexDigit) else { return false }
        guard destination.hasPrefix("refs/heads/") || destination.hasPrefix("refs/tags/") || destination.hasPrefix(namespace) else { return false }
        let odd: Set<Character> = ["~", "^", "?", "[", "\\", ":"]
        return !destination.contains("..") && !destination.contains("@{") && !destination.contains("//") && !destination.hasSuffix("/")
            && !destination.hasSuffix(".lock") && !destination.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7f }
            && !destination.contains(where: odd.contains)
    }

    /// Every step stays in the private references: nothing under `refs/heads/` or `refs/tags/` (a home he already had).
    public static func privateOnly(_ steps: [Step]) -> Bool {
        steps.allSatisfy { $0.reference.hasPrefix(namespace) && addsOnly($0.refspec) }
    }

    /// A home Terminal Deck made: his branches and tags under their real names. A branch goes when the home lacks it,
    /// or when what the home has is already inside his branch (a fast-forward); a branch with other work there is left
    /// alone and named; an existing tag is never moved.
    public static func make(branches: [String: String], tags: [String: String], remote: [String: String],
                            contains: (_ remoteCommit: String, _ localCommit: String) -> Bool?) -> (send: [Step], skipped: [String]) {
        var send: [Step] = [], skipped: [String] = []
        for (name, commit) in branches.sorted(by: { $0.key < $1.key }) where !name.hasPrefix(prefix) {
            let reference = "refs/heads/" + name
            if let theirs = remote[reference] {
                if theirs == commit { continue }
                if contains(theirs, commit) == true { send.append(.init(commit: commit, reference: reference)) }
                else { skipped.append(name + ": GitHub has other work on this branch") }
            } else {
                send.append(.init(commit: commit, reference: reference))
            }
        }
        for (name, commit) in tags.sorted(by: { $0.key < $1.key }) where remote["refs/tags/" + name] == nil {
            send.append(.init(commit: commit, reference: "refs/tags/" + name))
        }
        return (send.filter { addsOnly($0.refspec) }, skipped)
    }

    /// `push --porcelain`: the references GitHub took ("*" new, " " moved forward, "=" already there). A "+" or "-"
    /// line would be a forced update or a deletion; they cannot come from the steps above and are never counted.
    public static func accepted(_ porcelain: String) -> Set<String> {
        var taken = Set<String>()
        for line in porcelain.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2, let flag = parts[0].first, flag == "*" || flag == " " || flag == "=" else { continue }
            if let colon = parts[1].lastIndex(of: ":") { taken.insert(String(parts[1][parts[1].index(after: colon)...])) }
        }
        return taken
    }

    /// A branch or Mac name as one part of a reference: letters, digits, '.', '_' and '-' only ("/" becomes "--").
    public static func part(_ name: String) -> String {
        var out = ""
        for scalar in name.replacingOccurrences(of: "/", with: "--").unicodeScalars {
            out.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "." || scalar == "_" || scalar == "-" ? scalar : "-")
        }
        while out.contains("..") { out = out.replacingOccurrences(of: "..", with: ".-") }
        while out.hasPrefix(".") || out.hasPrefix("-") { out.removeFirst() }
        if out.hasSuffix(".lock") || out.hasSuffix(".") { out += "-" }
        return out.isEmpty ? "x" : String(out.prefix(80))
    }
}

/// Backs up ONE repository whose top folder the caller has already proved is the project's code
/// (`BackendProjectCode.owns`), to a PRIVATE home. What it changes, all of it additions:
/// - on GitHub, a home he already had: only references under `refs/terminal-deck-backup/<Mac>/` (never a branch or a
///   tag). Each of his branches is kept as a "keeper" commit whose FIRST parent is his branch exactly as it is and
///   whose second parent is the previous keeper, so the reference only ever moves forward, even after he rebases;
/// - on GitHub, a home Terminal Deck made (and on which nothing reacts to a push): his branches and tags under their
///   real names, fast-forward only, plus the same private references for uncommitted work;
/// - in his repository: NOTHING (review 14 Nov). Fetched objects, the copies and every reference this needs live in
///   the app's own repository for the project (`shadow`), which reads his objects through `alternates`.
/// Never touched: his `.git` (objects, references, remote-tracking branches, config, hooks, `info/exclude`), his working
/// files, his staging area. Uncommitted work is copied through a temporary index into the app's own repository.
struct BackendCodeBackupSend: Sendable {
    struct Result: Sendable, Equatable {
        var sent = 0
        var skipped: [String] = []
        var leftOut: [BackendCodeBackupCoverage.LeftOut] = []
        var failure: String?
        /// The made home showed a workflow file: from now on it is treated like a home he already had.
        var becameLoud = false
    }
    struct Failure: Error { let plain: String }

    let git: any BackendCodeBackupGitRunning
    let top: String
    let gitDir: String
    let remoteName: String
    let transport: BackendCodeBackupTransport
    /// True only for a home Terminal Deck made on which nothing reacts to a push (checked before, and again here).
    let realNames: Bool
    let mac: String
    let ledger: BackendCodeBackupLedger
    let now: Date
    /// Review 14 Nov (the promise: a backup changes NOTHING in his repository): every write happens in this Mac's
    /// OWN bare repository for this project, under the app's data folder. Its object store borrows his through Git's
    /// `alternates` (nothing is copied), it keeps its own record of GitHub's branches (`refs/remotes/home/*`), and the
    /// copy of his working folder is staged in a temporary index. His `.git` is only ever read.
    let shadow: String
    static let homeRemote = "home"

    /// `his: true` reads his repository (never a writing command); otherwise the command runs in the app's own
    /// repository (`shadow`), with his folder as the files only when a temporary index is in use.
    private func run(_ arguments: [String], environment: [String: String] = [:], network: Bool = false, his: Bool = false, timeout: Int = 60_000,
                     maximum: Int = 16 * 1024 * 1024) async throws -> BackendGitOutcome {
        var extra = environment
        if !his {
            extra["GIT_DIR"] = shadow
            if extra["GIT_INDEX_FILE"] != nil { extra["GIT_WORK_TREE"] = top }
        }
        let outcome = try await git.run(cwd: top, arguments: arguments, environment: network ? transport.environment.merging(extra) { _, mine in mine } : extra,
                                        timeoutMilliseconds: timeout, maximumBytes: maximum)
        if outcome.missing { throw Failure(plain: "Git is not installed on this Mac") }
        return outcome
    }
    private func line(_ outcome: BackendGitOutcome) -> String {
        let text = transport.scrub(outcome.stderr).split(separator: "\n").map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return String(text.trimmingCharacters(in: .whitespaces).prefix(160))
    }
    private func trimmed(_ outcome: BackendGitOutcome) -> String { outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func gitBusy(_ gitDir: String) -> String? {
        let markers: [(String, String)] = [("MERGE_HEAD", "a merge"), ("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"),
                                          ("CHERRY_PICK_HEAD", "a cherry-pick"), ("REVERT_HEAD", "a revert"), ("BISECT_LOG", "a bisect"),
                                          ("sequencer", "a cherry-pick"), ("index.lock", "a Git command")]
        for (name, what) in markers where FileManager.default.fileExists(atPath: gitDir + "/" + name) { return what }
        return nil
    }

    func perform() async -> Result {
        var result = Result()
        do { try await body(&result) }
        catch let failure as Failure { result.failure = failure.plain }
        catch is CancellationError { result.failure = "stopped" }
        catch { result.failure = "Git could not be started" }
        return result
    }

    private func pairs(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for row in text.split(separator: "\n") {
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    private func body(_ result: inout Result) async throws {
        if let busy = Self.gitBusy(gitDir) { throw Failure(plain: "Git is in the middle of \(busy) here; tried again later") }
        let mine = BackendCodeBackupPlan.mine(mac)
        try await prepareShadow()
        // 1. What the home has now, read from GitHub itself.
        let listing = try await run(["ls-remote", "--", transport.url], network: true, timeout: 120_000)
        guard listing.ok else { throw Failure(plain: "GitHub did not answer (\(line(listing)))") }
        var remote: [String: String] = [:]
        for row in listing.stdout.split(separator: "\n") {
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].hasSuffix("^{}") else { continue }
            remote[parts[1]] = parts[0]
        }
        // 2. Its commits, so "moves forward" can be checked here. Only remote-tracking references change; this Mac's
        //    own private references are fetched without a name (their commits only).
        if !remote.isEmpty {
            var refspecs = ["+refs/heads/*:refs/remotes/\(Self.homeRemote)/*", "^refs/heads/" + BackendCodeBackupPlan.prefix + "*"]
            refspecs += remote.keys.filter { $0.hasPrefix(mine) }.sorted()
            let fetched = try await run(["fetch", "--quiet", "--prune", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--", transport.url] + refspecs,
                                        network: true, timeout: 600_000)
            guard fetched.ok else { throw Failure(plain: "GitHub's copy could not be read (\(line(fetched)))") }
        }
        // 3. A made home that now carries a workflow file is a home things hang on: private references from now on.
        var realNames = self.realNames && BackendCodeBackupPlan.realNamesAllowed
        if realNames, try await carriesWorkflow(remote) { realNames = false; result.becameLoud = true }

        // 4. His branches and tags.
        let branches = pairs(try await run(["for-each-ref", "--format=%(refname:strip=2)%09%(objectname)", "refs/heads"], his: true).stdout)
        let tags = pairs(try await run(["for-each-ref", "--format=%(refname:strip=2)%09%(objectname)", "refs/tags"], his: true).stdout)
        let currentRead = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], his: true)
        let current = currentRead.ok ? trimmed(currentRead) : nil
        let before = ledger.coverage(gitDir)
        var heads = before?.heads ?? [:]
        var steps: [BackendCodeBackupPlan.Step] = []
        var keeperFor: [String: (branch: String, tip: String)] = [:]
        let identity = try await author()
        let when = BackendCodeBackupWords.when(Int64(now.timeIntervalSince1970 * 1000), now: now)

        if realNames {
            var ancestry: [String: Bool] = [:]
            for (name, commit) in branches {
                guard let theirs = remote["refs/heads/" + name], theirs != commit else { continue }
                let check = try await run(["merge-base", "--is-ancestor", theirs, commit])
                ancestry[theirs + ":" + commit] = check.exitCode == 0 ? true : (check.exitCode == 1 ? false : nil)
            }
            let plan = BackendCodeBackupPlan.make(branches: branches, tags: tags, remote: remote) { ancestry[$0 + ":" + $1] }
            result.skipped = plan.skipped
            for step in plan.send {
                if let secret = try await secretIn(step.commit, beyond: []) {
                    let what = step.reference.hasPrefix("refs/tags/") ? "tag " + String(step.reference.dropFirst("refs/tags/".count))
                                                                       : String(step.reference.dropFirst("refs/heads/".count))
                    result.skipped.append(what + ": not sent: \(secret) is in its commits")
                    continue
                }
                steps.append(step)
            }
        } else {
            // Each branch as a keeper commit under the private references; tags under the private references, new only.
            for (name, tip) in branches.sorted(by: { $0.key < $1.key }) where !name.hasPrefix(BackendCodeBackupPlan.prefix) {
                let reference = mine + "heads/" + name
                if heads[name] == tip, remote[reference] != nil { continue }
                if let theirs = remote["refs/heads/" + name], try await run(["merge-base", "--is-ancestor", tip, theirs]).exitCode == 0 {
                    heads[name] = tip; continue   // already on his real GitHub branch
                }
                let previous = remote[reference]
                if let previous, try await run(["rev-parse", "--verify", "--quiet", previous + "^1"]).stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines) == tip { heads[name] = tip; continue }
                if let secret = try await secretIn(tip, beyond: Array(heads.values)) {
                    result.skipped.append(name + ": not sent: \(secret) is in its commits"); continue
                }
                let tree = try await run(["rev-parse", tip + "^{tree}"])
                guard tree.ok else { result.skipped.append(name + ": could not be read"); continue }
                var parents = [tip]
                if let previous, try await run(["cat-file", "-e", previous + "^{commit}"]).ok { parents.append(previous) }
                let keeper = try await run(["commit-tree", trimmed(tree), "--no-gpg-sign"] + parents.flatMap { ["-p", $0] }
                                           + ["-m", "Branch \(name) on \(mac), \(when) (Terminal Deck backup)"], environment: identity)
                guard keeper.ok else { result.skipped.append(name + ": could not be copied"); continue }
                let step = BackendCodeBackupPlan.Step(commit: trimmed(keeper), reference: reference)
                steps.append(step); keeperFor[reference] = (name, tip)
            }
            for (name, commit) in tags.sorted(by: { $0.key < $1.key }) {
                let reference = mine + "tags/" + name
                if remote["refs/tags/" + name] == commit { continue }
                if let theirs = remote[reference] { if theirs != commit { result.skipped.append("tag " + name + ": kept earlier with other content") }; continue }
                // Review 14 Nov: a tag's commits are checked for secret files like a branch's.
                if let secret = try await secretIn(commit, beyond: Array(heads.values) + keeperFor.values.map { $0.tip }) {
                    result.skipped.append("tag " + name + ": not sent: \(secret) is in its commits"); continue
                }
                steps.append(.init(commit: commit, reference: reference))
            }
        }
        // 5. Uncommitted work and set-aside changes: always under the private references.
        let safe = Array(heads.values) + keeperFor.values.map { $0.tip } + plannedTips(steps)
        let (snapshotSteps, coverage, leftOut, held) = try await snapshots(remote: remote, workReference: mine + "work/" + BackendCodeBackupPlan.part(current ?? "no-branch"),
                                                                          setAsideReference: mine + "set-aside", identity: identity, when: when, safe: safe)
        steps += snapshotSteps; result.leftOut = leftOut; result.skipped += held

        // 6. Send. Every step passed `addsOnly`; on a home he already had, every step is a private reference.
        let checked = steps.filter { BackendCodeBackupPlan.addsOnly($0.refspec) }
        if !realNames, !BackendCodeBackupPlan.privateOnly(checked) { throw Failure(plain: "a backup step would have touched a branch or tag; nothing was sent") }
        var taken = Set<String>()
        if !checked.isEmpty {
            taken = try await push(checked)
            if taken.count < checked.count {
                for step in checked where !taken.contains(step.reference) {
                    let single = try await push([step])
                    taken.formUnion(single)
                    if single.isEmpty {
                        let what = step.reference.hasPrefix(BackendCodeBackupPlan.namespace) ? String(step.reference.dropFirst(mine.count)) : String(step.reference.split(separator: "/", maxSplits: 2).last ?? "")
                        result.skipped.append(what + ": GitHub did not take it")
                    }
                }
            }
        }
        result.sent = taken.count
        if !checked.isEmpty, taken.isEmpty, checked.allSatisfy({ $0.reference.hasPrefix(BackendCodeBackupPlan.namespace) }) {
            // GitHub refusing the private references is a stop, never a reason to fall back to branches.
            throw Failure(plain: "GitHub did not accept the private backup references; nothing was sent to your branches")
        }
        // 7. His remote-tracking references follow his real GitHub branches that moved (made homes only).
        for step in checked where taken.contains(step.reference) && step.reference.hasPrefix("refs/heads/") {
            _ = try await run(["update-ref", "-m", "Terminal Deck backup", "refs/remotes/\(Self.homeRemote)/" + String(step.reference.dropFirst("refs/heads/".count)), step.commit])
        }
        for (reference, kept) in keeperFor where taken.contains(reference) { heads[kept.branch] = kept.tip }
        // 8. What is safe now: his branches in the private references, and the working state the snapshot covered.
        var record = coverage
        let needed = snapshotSteps.map(\.reference)
        if !needed.allSatisfy(taken.contains) {
            result.failure = "GitHub did not take the copy of your uncommitted work"
            record.fingerprint = before?.fingerprint ?? ""; record.stashes = before?.stashes ?? []; record.leftOut = before?.leftOut ?? []
            record.at = before?.at ?? 0
        } else {
            record.at = Int64(now.timeIntervalSince1970 * 1000)
        }
        record.heads = heads.filter { branches[$0.key] != nil }
        ledger.setCoverage(gitDir, record)
    }

    /// The commits a step of the (unreachable) real-names path sends: already checked, so safe under a snapshot.
    private func plannedTips(_ steps: [BackendCodeBackupPlan.Step]) -> [String] {
        steps.filter { $0.reference.hasPrefix("refs/heads/") }.map(\.commit)
    }

    /// The app's own repository for this project: made once (bare), its object store borrowing his (`alternates`, so
    /// his objects are read in place and nothing is copied). Only the app's data folder is written.
    private func prepareShadow() async throws {
        let common = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], his: true)
        let objects = trimmed(common) + "/objects"
        let manager = FileManager.default
        guard common.ok, manager.fileExists(atPath: objects) else { throw Failure(plain: "Git could not read the folder") }
        if !manager.fileExists(atPath: shadow + "/HEAD") {
            try manager.createDirectory(atPath: shadow, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let made = try await git.run(cwd: shadow, arguments: ["init", "--bare", "-q", "."], environment: [:], timeoutMilliseconds: 30_000, maximumBytes: 65_536)
            if made.missing { throw Failure(plain: "Git is not installed on this Mac") }
            guard made.ok else { throw Failure(plain: "Terminal Deck could not prepare its backup area") }
        }
        let alternates = shadow + "/objects/info/alternates"
        if (try? String(contentsOfFile: alternates, encoding: .utf8)) != objects + "\n" {
            try manager.createDirectory(atPath: shadow + "/objects/info", withIntermediateDirectories: true)
            try Data((objects + "\n").utf8).write(to: URL(fileURLWithPath: alternates), options: .atomic)
        }
    }

    /// A workflow file on any of the home's branches (read from the commits just fetched; no network).
    private func carriesWorkflow(_ remote: [String: String]) async throws -> Bool {
        for (reference, commit) in remote where reference.hasPrefix("refs/heads/") && !reference.hasPrefix("refs/heads/" + BackendCodeBackupPlan.prefix) {
            let listed = try await run(["ls-tree", "--name-only", commit, ".github/workflows/"])
            if listed.ok, !trimmed(listed).isEmpty { return true }
        }
        return false
    }

    /// The first file added or changed by the commits of `tip` that GitHub does not have yet (neither on the home's
    /// branches nor in commits already backed up) that holds a commit back: kind A by name, kind B by its bytes.
    /// `-m` (review 14 Nov): a merge commit lists what it changed against each parent, so a file added in a merge counts.
    private func secretIn(_ tip: String, beyond: [String]) async throws -> String? {
        let listed = try await run(["log", "--format=", "--raw", "-z", "-m", "--no-abbrev", "--no-renames", "--diff-filter=AM", tip, "--not", "--remotes=" + Self.homeRemote] + beyond,
                                   maximum: 32 * 1024 * 1024)
        guard listed.ok, !listed.timedOut else { return Self.unchecked }
        return try await firstHeld(Self.rawEntries(listed.stdout))
    }

    static let unchecked = "a file that could not be checked"

    /// `--raw -z` output (log, diff-tree): ":<mode> <mode> <old> <new> <status>\0<path>\0" per file.
    static func rawEntries(_ text: String) -> [(blob: String, path: String)] {
        var out: [(blob: String, path: String)] = [], pending: String?
        for token in text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if let blob = pending { out.append((blob, token)); pending = nil; continue }
            let meta = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard meta.hasPrefix(":") else { continue }
            let fields = meta.split(separator: " ")
            if fields.count >= 5 { pending = String(fields[3]) }
        }
        return out
    }

    /// The first entry that holds back: its file's name, or nil.
    private func firstHeld(_ entries: [(blob: String, path: String)]) async throws -> String? {
        for entry in entries {
            let name = (entry.path as NSString).lastPathComponent
            switch BackendCodeBackupGitReader.secretKind(entry.path) {
            case .credential: return name
            case .maybeKey: if try await blobHoldsPrivateKey(entry.blob) { return name }
            case .none, .leaveOut: continue
            }
        }
        return nil
    }

    /// A `.pem`/`.key`/`.asc` blob with "PRIVATE KEY" in it. One that cannot be read is treated as a key.
    private func blobHoldsPrivateKey(_ blob: String) async throws -> Bool {
        let size = try await run(["cat-file", "-s", blob])
        guard size.ok, let bytes = Int(trimmed(size)) else { return true }
        guard bytes <= BackendCodeBackupGitReader.keyBytes else { return false }
        let body = try await run(["cat-file", "blob", blob], maximum: BackendCodeBackupGitReader.keyBytes + 65_536)
        guard body.ok, !body.timedOut else { return true }
        return BackendCodeBackupGitReader.privateKey(Data(body.stdout.utf8))
    }

    private func push(_ steps: [BackendCodeBackupPlan.Step]) async throws -> Set<String> {
        let outcome = try await run(["push", "--porcelain", "--no-verify", "--no-follow-tags", "--recurse-submodules=no", "--no-signed", transport.url]
                                    + steps.map(\.refspec), network: true, timeout: 600_000)
        return BackendCodeBackupPlan.accepted(outcome.stdout)
    }

    /// Commits holding his uncommitted work (on top of the commit he is on) and his set-aside changes, each chained to
    /// the previous one of this Mac on the home so the references only move forward. His staging area is never used:
    /// a separate one is made in a temporary folder and removed afterwards.
    /// Review 14 Nov: a set-aside change carrying a secret file (in its change, its staged part, its untracked part, or
    /// in the commits under it) stays on this Mac.
    private func stashSecret(_ stash: String, safe: [String]) async throws -> String? {
        if let secret = try await secretIn(stash + "^1", beyond: safe) { return secret }
        var entries: [(blob: String, path: String)] = []
        for pair in [(stash + "^1", stash), (stash + "^1", stash + "^2")] {
            let changed = try await run(["diff-tree", "-r", "-z", "--no-abbrev", "--no-renames", "--no-commit-id", "--diff-filter=AM", pair.0, pair.1])
            guard changed.ok, !changed.timedOut else { return Self.unchecked }
            entries += Self.rawEntries(changed.stdout)
        }
        if try await run(["rev-parse", "--verify", "--quiet", stash + "^3^{commit}"]).ok {
            let untracked = try await run(["ls-tree", "-r", "-z", stash + "^3"])
            guard untracked.ok, !untracked.timedOut else { return Self.unchecked }
            // "<mode> blob <sha>\t<path>" per file.
            for row in untracked.stdout.split(separator: "\0").map(String.init) {
                guard let tab = row.firstIndex(of: "\t") else { continue }
                let fields = row[..<tab].split(separator: " ")
                if fields.count == 3 { entries.append((String(fields[2]), String(row[row.index(after: tab)...]))) }
            }
        }
        return try await firstHeld(entries)
    }

    /// Secret files a `.git/info/exclude` the app wrote (after its own `git init`) keeps out of Git's view: still
    /// counted as left out, so the row keeps saying so.
    private func excludedSecrets() async throws -> [BackendCodeBackupCoverage.LeftOut] {
        let file = gitDir + "/info/exclude"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8), text.hasPrefix(BackendCodeBackupGitReader.excludeMarker) else { return [] }
        let listed = try await run(["ls-files", "-z", "--others", "--ignored", "--directory", "--exclude-from=" + file], his: true, maximum: 4 * 1024 * 1024)
        guard listed.ok else { return [] }
        return listed.stdout.split(separator: "\0").map(String.init).filter { BackendCodeBackupGitReader.isSecret($0, top: top) }.map { .init(name: $0, reason: "secret file") }
    }

    private func snapshots(remote: [String: String], workReference: String, setAsideReference: String, identity: [String: String], when: String,
                           safe: [String]) async throws
        -> ([BackendCodeBackupPlan.Step], BackendCodeBackupCoverage, [BackendCodeBackupCoverage.LeftOut], [String]) {
        let status = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none", "--no-renames"], his: true, maximum: 32 * 1024 * 1024)
        guard status.ok, !status.timedOut else { throw Failure(plain: "Git could not read the folder") }
        let headRead = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], his: true)
        let head = headRead.ok ? trimmed(headRead) : nil
        let stashRead = try await run(["log", "--walk-reflogs", "--format=%H", "refs/stash"], his: true)
        var stashes: [String] = []
        if stashRead.ok { for sha in stashRead.stdout.split(separator: "\n").map(String.init) where !stashes.contains(sha) { stashes.append(sha) } }
        let fingerprint = BackendCodeBackupCoverage.fingerprint(head: head ?? "", status: status.stdout, top: top)
        let names = BackendCodeBackupGitReader.statusNames(status.stdout)
        var leftOut: [BackendCodeBackupCoverage.LeftOut] = []
        var include: [String] = []
        for name in names {
            if BackendCodeBackupGitReader.isSecret(name, top: top) { leftOut.append(.init(name: name, reason: "secret file")); continue }
            var info = stat()
            if lstat(top + "/" + name, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int64(info.st_size) > BackendCodeBackupGitReader.largeBytes {
                leftOut.append(.init(name: name, reason: "over 50 MB")); continue
            }
            include.append(name)
        }
        var heldBack: [String] = []
        let before = ledger.coverage(gitDir)
        var covered = BackendCodeBackupCoverage(fingerprint: fingerprint, stashes: stashes, at: before?.at ?? 0, leftOut: names.isEmpty ? [] : leftOut,
                                                heads: before?.heads)
        var steps: [BackendCodeBackupPlan.Step] = []
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("terminaldeck-code-backup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let index = ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path, "GIT_LITERAL_PATHSPECS": "1"]

        // The copy of his uncommitted work sits on his last commit, so that commit's history travels with it: a secret
        // file in commits GitHub does not have keeps the copy here (review 14 Nov).
        var underSecret: String?
        if let head, !names.isEmpty { underSecret = try await secretIn(head, beyond: safe) }
        if let underSecret {
            heldBack.append("uncommitted work: not sent: \(underSecret) is in the commits under it")
            covered.fingerprint = before?.fingerprint ?? ""
        }
        // Uncommitted work: his last commit's files, with the changed ones as they are in the folder now.
        if underSecret == nil && !names.isEmpty && (before?.fingerprint != fingerprint || remote[workReference] == nil) {
            let start = try await run(head.map { ["read-tree", $0] } ?? ["read-tree", "--empty"], environment: index)
            guard start.ok else { throw Failure(plain: "Git could not copy your uncommitted work") }
            if !include.isEmpty {
                let list = scratch.appendingPathComponent("paths")
                try Data(include.joined(separator: "\0").utf8).write(to: list)
                let added = try await run(["add", "-A", "--ignore-errors", "--pathspec-from-file=" + list.path, "--pathspec-file-nul"], environment: index, timeout: 300_000)
                guard added.ok || added.exitCode == 1 else { throw Failure(plain: "Git could not copy your uncommitted work") }
            }
            let listed = try await run(["ls-files", "-z"], environment: index, maximum: 32 * 1024 * 1024)
            // Kind A (and a B file holding a private key) never goes, even one already in his last commit; a kind C
            // file in that commit travels with his commits like any file.
            let secrets = listed.stdout.split(separator: "\0").map(String.init).filter { BackendCodeBackupGitReader.holdsBack($0, top: top) }
            if !secrets.isEmpty {
                let list = scratch.appendingPathComponent("secrets")
                try Data(secrets.joined(separator: "\0").utf8).write(to: list)
                let removed = try await run(["rm", "--cached", "-q", "--ignore-unmatch", "--pathspec-from-file=" + list.path, "--pathspec-file-nul"], environment: index)
                guard removed.ok else { throw Failure(plain: "Git could not leave a secret file out") }
            }
            let tree = try await run(["write-tree"], environment: index)
            guard tree.ok else { throw Failure(plain: "Git could not copy your uncommitted work") }
            var parents: [String] = []
            if let head { parents.append(head) }
            if let previous = remote[workReference], try await run(["cat-file", "-e", previous + "^{commit}"]).ok { parents.append(previous) }
            let made = try await run(["commit-tree", trimmed(tree), "--no-gpg-sign"]
                                     + parents.flatMap { ["-p", $0] } + ["-m", "Uncommitted work on \(mac), \(when) (Terminal Deck backup)"], environment: identity)
            guard made.ok else { throw Failure(plain: "Git could not copy your uncommitted work") }
            steps.append(.init(commit: trimmed(made), reference: workReference))
        }

        // Set-aside changes: every stash entry as a parent of one commit, so all of them travel and none is changed.
        let previousSetAside = remote[setAsideReference]
        var missing: [String] = [], clean: [String] = []
        for (position, stash) in stashes.enumerated() {
            if let previousSetAside, try await run(["merge-base", "--is-ancestor", stash, previousSetAside]).exitCode == 0 { clean.append(stash); continue }
            if let secret = try await stashSecret(stash, safe: safe) {
                heldBack.append("set-aside change \(position + 1): not sent: \(secret) is in it"); continue
            }
            clean.append(stash)
            if !(before?.stashes.contains(stash) ?? false) || previousSetAside == nil { missing.append(stash) }
        }
        // Only what actually travels counts as covered; a held-back one keeps the row honest.
        covered.stashes = clean
        if !missing.isEmpty {
            let empty = ["GIT_INDEX_FILE": scratch.appendingPathComponent("empty-index").path]
            _ = try await run(["read-tree", "--empty"], environment: empty)
            let tree = try await run(["write-tree"], environment: empty)
            guard tree.ok else { throw Failure(plain: "Git could not copy your set-aside changes") }
            var parents: [String] = []
            if let previousSetAside, try await run(["cat-file", "-e", previousSetAside + "^{commit}"]).ok { parents.append(previousSetAside) }
            parents += clean.filter { !parents.contains($0) }.prefix(60)
            let made = try await run(["commit-tree", trimmed(tree), "--no-gpg-sign"]
                                     + parents.flatMap { ["-p", $0] } + ["-m", "Set-aside changes on \(mac), \(when) (Terminal Deck backup)"], environment: identity)
            guard made.ok else { throw Failure(plain: "Git could not copy your set-aside changes") }
            steps.append(.init(commit: trimmed(made), reference: setAsideReference))
        }
        covered.leftOut = names.isEmpty ? [] : leftOut
        let excluded = try await excludedSecrets()
        return (steps, covered, leftOut + excluded, heldBack)
    }

    /// His own name and e-mail from his Git settings; a plain stand-in only when he has none (a commit needs one).
    private func author() async throws -> [String: String] {
        let email = try await run(["config", "--get", "user.email"], his: true)
        let name = try await run(["config", "--get", "user.name"], his: true)
        // Passed explicitly: the copies are made in the app's own repository, which does not see his repository's
        // own settings.
        let mail = email.ok && !trimmed(email).isEmpty ? trimmed(email) : "backup@terminaldeck.invalid"
        let who = name.ok && !trimmed(name).isEmpty ? trimmed(name) : "Terminal Deck"
        return ["GIT_AUTHOR_EMAIL": mail, "GIT_COMMITTER_EMAIL": mail, "GIT_AUTHOR_NAME": who, "GIT_COMMITTER_NAME": who]
    }
}
