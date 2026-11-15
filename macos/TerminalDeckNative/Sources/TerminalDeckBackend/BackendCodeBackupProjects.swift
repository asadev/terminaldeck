import Foundation
import Darwin
import TerminalDeckNativeCore

/// Runs work with a time limit that holds even when the work blocks a thread (a stuck network drive): the caller gets
/// nil after `seconds` and the work is cancelled (a Git child is killed) or, if it is stuck in the system, left behind.
enum BackendCodeBackupLimit {
    final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var done = false
        func attach(_ continuation: CheckedContinuation<T?, Never>) { lock.withLock { self.continuation = continuation } }
        @discardableResult func finish(_ value: T?) -> Bool {
            let waiting: CheckedContinuation<T?, Never>? = lock.withLock {
                guard !done else { return nil }
                done = true; defer { continuation = nil }; return continuation
            }
            waiting?.resume(returning: value)
            return waiting != nil
        }
    }

    static func first<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = Once<T>()
        return await withCheckedContinuation { continuation in
            once.attach(continuation)
            let task = Task.detached { once.finish(await work()) }
            Task.detached {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if once.finish(nil) { task.cancel() }
            }
        }
    }
}

/// Blocking file-system work (is this a folder, the cache's stat marks, file sizes) runs on its own dispatch queue,
/// never on Swift's shared worker threads, so a frozen network drive cannot stall the app. A folder that did not answer
/// is remembered for five minutes and not touched again in that time.
enum BackendCodeBackupFileSystem {
    static let queue = DispatchQueue(label: "terminaldeck.code-backup.file-system", qos: .utility, attributes: .concurrent)
    static let forgetAfter: TimeInterval = 300
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hung: [String: Date] = [:]

    static func recentlyHung(_ path: String) -> Bool {
        lock.withLock { hung[path].map { Date().timeIntervalSince($0) < forgetAfter } ?? false }
    }
    static func noteHung(_ paths: [String]) { lock.withLock { for path in paths { hung[path] = Date() } } }

    /// The work's answer, or nil when it took longer than `seconds` (it is then left on this queue).
    static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        let once = BackendCodeBackupLimit.Once<T>()
        return await withCheckedContinuation { continuation in
            once.attach(continuation)
            queue.async { _ = once.finish(work()) }
            queue.asyncAfter(deadline: .now() + seconds) { _ = once.finish(nil) }
        }
    }

    /// The paths that are folders, each checked on its own; nil when any of them did not answer now or recently.
    static func folders(_ paths: [String], seconds: Double, isDirectory: @escaping @Sendable (String) -> Bool) async -> [String]? {
        guard !paths.contains(where: recentlyHung) else { return nil }
        var answers: [String: Bool] = [:], silent: [String] = []
        await withTaskGroup(of: (String, Bool?).self) { group in
            for path in paths { group.addTask { (path, await run(seconds) { isDirectory(path) }) } }
            for await (path, answer) in group { if let answer { answers[path] = answer } else { silent.append(path) } }
        }
        guard silent.isEmpty else { noteHung(silent); return nil }
        return paths.filter { answers[$0] == true }
    }
}

/// Reads a project's code folders with Git, READ-ONLY. Every command runs through `BackendGitRunner` with
/// `writing: false` (GIT_OPTIONAL_LOCKS=0: `status` never rewrites the index), `core.fsmonitor=false` (set by the
/// runner), the untracked cache off, hooks pointed nowhere, automatic clean-up off, a time limit and an output cap, and
/// the whole project within one overall limit. Nothing here fetches, stages, checks out, commits or touches a branch or
/// a stash. A repository whose own settings run programs (`filter.*`) is not read at all. Ignored folders are never
/// walked: `status` and `ls-files --exclude-standard` skip a directory the .gitignore excludes.
public struct BackendCodeBackupGitReader: Sendable {
    public typealias IsDirectory = @Sendable (String) -> Bool
    let runner: any BackendGitExecuting
    let context: NativeRPCContext
    /// GitHub's host for this Mac's sign-in ("github.com" unless GH_HOST says otherwise).
    let githubHost: String
    let timeoutMilliseconds: Int
    let projectSeconds: Double
    let folderSeconds: Double
    let isDirectory: IsDirectory
    /// Which repository is a project folder's code (`BackendProjectCode`); nil: this Mac's, asked at each read.
    let bounds: BackendProjectCode.Bounds?
    /// Slice 2: what the last backup of uncommitted work covered, by Git folder (`BackendCodeBackupLedger`).
    let coverage: (@Sendable (String) -> BackendCodeBackupCoverage?)?

    /// Over 50 MB a file is listed as too large (GitHub refuses 100 MB; the contracts keep 50 MB).
    public static let largeBytes: Int64 = 50 * 1024 * 1024
    /// Secret files, in three kinds (lead, 14 Nov). Matched case-insensitively by the file's own name.
    /// A, `credentialPatterns`: real credentials. In commits GitHub does not have, they HOLD BACK the branch, tag or
    /// set-aside change; their uncommitted version is left out of the copy. Kept from the app's own never-send rule
    /// (`BackendFilesystemIgnore.credentialPath`): `.pgpass`, `_netrc`, `.htpasswd`, `.credentials.json`, `.vault-token`,
    /// `*.ppk`, `*.tfstate.backup`, `secret(s).json/yaml/yml/toml/env`, `*.secret(s).json/yaml/yml/toml`, and anything
    /// inside `.ssh/`, `.aws/`, `.gnupg/`, `.kube/`.
    public static let credentialPatterns = [".env", ".env.local", ".env.*.local", ".dev.vars", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
                                            "id_rsa_sk", "id_ecdsa_sk", "id_ed25519_sk", "*.p8", "*.p12", "*.pfx", "*.jks", "*.keystore", ".netrc", "_netrc",
                                            ".git-credentials", ".pypirc", "credentials", "credentials*.json", ".credentials.json", "service-account*.json",
                                            "*.tfstate", "*.tfstate.backup", "*.kdbx", ".pgpass", ".htpasswd", ".vault-token", "*.ppk",
                                            "secret.json", "secrets.json", "secret.yaml", "secrets.yaml", "secret.yml", "secrets.yml", "secret.toml",
                                            "secrets.toml", "secret.env", "secrets.env", "*.secret.json", "*.secrets.json", "*.secret.yaml",
                                            "*.secrets.yaml", "*.secret.yml", "*.secrets.yml", "*.secret.toml", "*.secrets.toml"]
    static let credentialFolders: Set<String> = [".ssh", ".aws", ".gnupg", ".kube"]
    /// B, `keyPatterns`: decided by CONTENT. A line with "PRIVATE KEY" (PEM or PGP private block) makes it kind A;
    /// otherwise (a certificate, a public key, a Keynote file, a signature) it is not secret at all.
    public static let keyPatterns = ["*.pem", "*.key", "*.asc"]
    /// C, `leaveOutPatterns`: left out of the uncommitted-work copy only; never holds anything back (a committed one
    /// travels with his commits like any file). Also anything inside `.docker/` or `.azure/` (from the never-send rule).
    public static let leaveOutPatterns = ["GoogleService-Info.plist", "google-services.json", ".env.*", "debug.keystore", ".npmrc", ".yarnrc.yml",
                                          ".envrc", "*.tfvars", "*.tfvars.json", "*.mobileprovision"]
    static let leaveOutFolders: Set<String> = [".docker", ".azure"]
    /// Every name of the three kinds (the readiness list stays inside it: a source test).
    public static var secretPatterns: [String] { credentialPatterns + keyPatterns + leaveOutPatterns }
    /// Written to `.git/info/exclude` right after the app's own `git init` on a plain folder (that file lives inside the
    /// `.git` the app just made; none of his files is touched): heavy folders, kinds A and C.
    public static let excludeMarker = "# Terminal Deck: left out of backups"
    public static var excludeText: String {
        let heavy = ["node_modules/", ".venv/", "venv/", "build/", "dist/", "DerivedData/", ".gradle/", "Pods/", ".next/", "target/", ".DS_Store"]
        let folders = (credentialFolders.sorted() + leaveOutFolders.sorted()).map { $0 + "/" }
        return excludeMarker + "\n" + (heavy + credentialPatterns + folders + leaveOutPatterns).joined(separator: "\n") + "\n"
    }

    public enum SecretKind: Sendable, Equatable { case none, credential, maybeKey, leaveOut }

    /// The kind of a path by its name alone.
    public static func secretKind(_ path: String) -> SecretKind {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        guard let name = parts.last else { return .none }
        let folders = parts.dropLast()
        func matches(_ patterns: [String]) -> Bool { patterns.contains { fnmatch($0.lowercased(), name, 0) == 0 } }
        if folders.contains(where: credentialFolders.contains) { return .credential }
        if name == "debug.keystore" { return .leaveOut }
        if matches(credentialPatterns) { return .credential }
        if matches(keyPatterns) { return .maybeKey }
        if matches(leaveOutPatterns) || folders.contains(where: leaveOutFolders.contains) { return .leaveOut }
        return .none
    }

    /// Up to this many bytes of a `.pem`/`.key`/`.asc` file are read; a bigger one is not a key file.
    public static let keyBytes = 256 * 1024
    public static func privateKey(_ data: Data) -> Bool {
        String(decoding: data.prefix(keyBytes), as: UTF8.self).contains("PRIVATE KEY")
    }
    static func privateKeyOnDisk(_ file: String) -> Bool {
        var info = stat()
        guard lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        guard Int(info.st_size) <= keyBytes else { return false }
        return FileManager.default.contents(atPath: file).map(privateKey) ?? false
    }

    static let readOnlyFlags = ["-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false"]
    static let runsPrograms = "this folder's Git settings run programs"
    static let slow = "the folder took too long to read"
    static let silent = "the folder did not answer"

    public init(runner: any BackendGitExecuting, context: NativeRPCContext, githubHost: String = "github.com", timeoutMilliseconds: Int = 15_000,
                projectSeconds: Double = 30, folderSeconds: Double = 5, isDirectory: @escaping IsDirectory = { BackendCodeBackupGitReader.directory($0) },
                bounds: BackendProjectCode.Bounds? = nil, coverage: (@Sendable (String) -> BackendCodeBackupCoverage?)? = nil) {
        self.runner = runner; self.context = context; self.githubHost = githubHost.lowercased(); self.timeoutMilliseconds = timeoutMilliseconds
        self.projectSeconds = projectSeconds; self.folderSeconds = folderSeconds; self.isDirectory = isDirectory; self.bounds = bounds
        self.coverage = coverage
    }

    /// The Git environment for these reads: Git never climbs into the home folder (or above) looking for a repository,
    /// so a plain folder inside a home-folder repository is not read as the whole home. A second guard on top of
    /// `BackendProjectCode.belongs`, which every repository found is checked against.
    public static func environment(_ inherited: [String: String], home: String) -> [String: String] {
        var environment = inherited
        environment["GIT_CEILING_DIRECTORIES"] = home
        return environment
    }

    /// Where Git keeps a repository's files, for the cache's change check. Never shown.
    struct Place: Sendable, Equatable { let top: String; let gitDir: String }

    struct Failure: Error { let plain: String }

    /// The rule's one read-only question to a repository above a project folder: does it keep files in it.
    private var probe: BackendProjectCode.Probe {
        let runner = self.runner, context = self.context, timeout = timeoutMilliseconds
        return { cwd, arguments in
            guard let outcome = try? await runner.run(cwd: cwd, arguments: Self.readOnlyFlags + arguments, context: context, writing: false,
                                                      timeoutMilliseconds: timeout, maximumBytes: 64 * 1024), !outcome.missing else { return nil }
            return outcome.stdout
        }
    }

    private func git(_ cwd: String, _ arguments: [String], maximum: Int = 16 * 1024 * 1024) async throws -> BackendGitOutcome {
        try Task.checkCancellation()
        let outcome = try await runner.run(cwd: cwd, arguments: Self.readOnlyFlags + arguments, context: context, writing: false,
                                           timeoutMilliseconds: timeoutMilliseconds, maximumBytes: maximum)
        if outcome.missing { throw Failure(plain: "Git is not installed on this Mac") }
        if outcome.timedOut { throw Failure(plain: Self.slow) }
        return outcome
    }

    public static func directory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// Every code folder of the project that Git keeps, each read on its own; the project shows the worst of them.
    func read(_ project: PROJProject) async -> (BackendCodeBackupProject, [Place]) {
        var row = BackendCodeBackupProject(id: project.id, name: project.name)
        let candidates = project.folders.filter { $0.hasPrefix("/") }
        guard !candidates.isEmpty else { return (row, []) }
        guard let present = await BackendCodeBackupFileSystem.folders(candidates, seconds: folderSeconds, isDirectory: isDirectory) else {
            row.hasFolder = true; row.folderName = (candidates[0] as NSString).lastPathComponent; row.problem = Self.silent
            return (row, [])
        }
        guard !present.isEmpty else { return (row, []) }
        let reader = self
        guard let answer = await BackendCodeBackupLimit.first(projectSeconds, { await reader.readFolders(project, present) }) else {
            row.hasFolder = true; row.folderName = (present[0] as NSString).lastPathComponent; row.problem = Self.slow
            return (row, [])
        }
        return answer
    }

    /// Each folder of the project, then each checked-out submodule of a repository (two levels deep) and each Git
    /// repository already sitting in the top two levels of a project folder (even one its .gitignore hides), all as
    /// their own rows. With several folders, a folder without Git is a row too ("Not on GitHub yet").
    private func readFolders(_ project: PROJProject, _ folders: [String]) async -> (BackendCodeBackupProject, [Place]) {
        var places: [Place] = [], parts: [BackendCodeBackupProject] = []
        let bounds = self.bounds ?? .live()
        var waiting: [(path: String, depth: Int, given: Bool)] = folders.map { ($0, 0, true) }
        let several = folders.count > 1
        while !waiting.isEmpty {
            let (folder, depth, given) = waiting.removeFirst()
            var part = BackendCodeBackupProject(id: (folder as NSString).lastPathComponent, name: project.name)
            part.hasFolder = true; part.folderName = part.id
            do {
                // An app-made folder holding only what the Cloud put there has no code of its own: Git is not even asked.
                if given && BackendProjectCode.waitingForCode(folder, bounds: bounds) {
                    if several { parts.append(part) }
                    continue
                }
                let found = try await git(folder, ["rev-parse", "--show-toplevel", "--absolute-git-dir"])
                let lines = found.stdout.split(separator: "\n").map(String.init)
                guard found.ok, lines.count >= 2 else {
                    if found.stderr.localizedCaseInsensitiveContains("not a git repository") {
                        if several && given { parts.append(part) }
                        continue
                    }
                    throw Failure(plain: "Git could not read the folder")
                }
                // A repository ABOVE the folder (the home folder's, the Terminal Deck folder's) is not this project's
                // code: the folder reads as a plain folder, and nothing here or in a backup touches that repository.
                guard await BackendProjectCode.owns(top: lines[0], folder: folder, bounds: bounds, probe: probe) else {
                    if several && given { parts.append(part) }
                    continue
                }
                let place = Place(top: lines[0], gitDir: lines[1])
                guard !places.contains(place) else { continue }
                places.append(place)
                part.id = (place.top as NSString).lastPathComponent; part.folderName = part.id; part.isRepository = true
                try await fill(&part, top: place.top, gitDir: place.gitDir)
                if depth < 2 { for sub in try await submodules(place.top) { waiting.append((sub, depth + 1, false)) } }
                if depth == 0 { for nested in await nestedRepositories(place.top) { waiting.append((nested, 1, false)) } }
            } catch let failure as Failure {
                part.problem = failure.plain
            } catch is CancellationError {
                part.problem = Self.slow
            } catch {
                part.problem = "Git could not be started"
            }
            if part.isRepository || part.problem != nil { parts.append(part) }
        }
        guard !parts.isEmpty else {
            // Folders here, none kept by Git: no GitHub home yet.
            var row = BackendCodeBackupProject(id: project.id, name: project.name)
            row.hasFolder = true; row.folderName = (folders[0] as NSString).lastPathComponent
            // Project folders (14 Nov): a folder the app made for a project from the Cloud has no code until he gets it,
            // judged by what is IN it: only what the Cloud puts there. Anything else (work written there by him or a
            // session) is his work and keeps the flagged "Not on GitHub yet".
            row.waitingForCode = !several && BackendProjectCode.waitingForCode(folders[0], bounds: bounds)
            return (row, places)
        }
        return (BackendCodeBackupProject.combine(id: project.id, name: project.name, parts: parts), places)
    }

    /// A repository whose own settings (local or per-worktree, or a file they include) name clean/smudge/process
    /// programs is not read: reading its files' state would run them. Checked in its checked-out submodules too, since
    /// `status` reads inside them. His own global and system settings are his set-up and allowed.
    private func refuseProgramSettings(_ top: String, depth: Int = 0) async throws {
        let filters = try await git(top, ["config", "--show-scope", "--includes", "--get-regexp", #"^filter\..*\.(clean|smudge|process)$"#])
        if filters.ok, Self.repositoryRunsPrograms(filters.stdout) { throw Failure(plain: Self.runsPrograms) }
        guard depth < 3 else { return }
        for sub in try await submodules(top) { try await refuseProgramSettings(sub, depth: depth + 1) }
    }

    /// The repository's submodules that are checked out here (index entries of mode 160000 with a .git inside).
    private func submodules(_ top: String) async throws -> [String] {
        let entries = try await git(top, ["ls-files", "-s", "-z"], maximum: 32 * 1024 * 1024)
        guard entries.ok else { return [] }
        let paths = Self.gitlinks(entries.stdout).map { top + "/" + $0 }
        let present = await BackendCodeBackupFileSystem.run(folderSeconds) {
            paths.filter { FileManager.default.fileExists(atPath: $0 + "/.git") }
        }
        guard let present else { throw Failure(plain: Self.silent) }
        return present
    }

    /// Git repositories in the top two levels of a repository's folder that are not that repository: a nested project
    /// its .gitignore may hide. A slow folder skips this look rather than failing the row.
    private func nestedRepositories(_ top: String) async -> [String] {
        await BackendCodeBackupFileSystem.run(folderSeconds) { Self.nested(in: top) } ?? []
    }

    static func nested(in top: String) -> [String] {
        let manager = FileManager.default
        func children(_ path: String) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: path)) ?? []).filter { $0 != ".git" }.map { path + "/" + $0 }.filter {
                var info = stat(); return lstat($0, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }
        }
        var found: [String] = []
        for child in children(top) {
            if manager.fileExists(atPath: child + "/.git") { found.append(child); continue }
            for grandchild in children(child).prefix(5_000) where manager.fileExists(atPath: grandchild + "/.git") { found.append(grandchild) }
        }
        return found.sorted()
    }

    /// `ls-files -s -z`: "160000 <object> <stage>\t<path>\0" for a submodule.
    static func gitlinks(_ text: String) -> [String] {
        text.split(separator: "\0").compactMap { entry in
            guard entry.hasPrefix("160000 "), let tab = entry.firstIndex(of: "\t") else { return nil }
            return String(entry[entry.index(after: tab)...])
        }
    }

    private func fill(_ row: inout BackendCodeBackupProject, top: String, gitDir: String) async throws {
        // A repository whose own settings (or a file they include) name clean/smudge/process programs: reading its
        // files' state would run them. Not read.
        try await refuseProgramSettings(top)
        // The branch he is on (exit 1: a past version is checked out, no branch).
        let branch = try await git(top, ["symbolic-ref", "--quiet", "--short", "HEAD"])
        row.branch = branch.ok ? branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        // The newest commit (none yet in a new repository).
        let head = try await git(top, ["log", "-1", "--format=%ct%x1f%H", "HEAD"])
        let headParts = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}").map(String.init)
        if head.ok, let seconds = headParts.first.flatMap({ Int64($0) }) { row.lastCommitAt = seconds * 1000 }
        let headCommit = head.ok && headParts.count > 1 ? headParts[1] : ""
        // The code's home: origin first, else the first remote with an address. Only this remote counts as "on GitHub".
        let remotes = try await git(top, ["config", "--get-regexp", #"^remote\..*\.url$"#])
        let addresses = Self.remotes(remotes.ok ? remotes.stdout : "")
        let chosen = addresses.first(where: { $0.name == "origin" }) ?? addresses.first
        if let chosen {
            if let home = Self.githubHome(chosen.url, host: githubHost) { row.home = home } else { row.otherHost = Self.host(chosen.url) ?? "another place" }
        }
        // Files changed since the last commit (a changed or moved submodule counts), not ignored by .gitignore.
        let status = try await git(top, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none", "--no-renames"])
        guard status.ok else { throw Failure(plain: "Git could not read the folder") }
        let changed = Self.statusNames(status.stdout)
        row.changedCount = changed.count
        row.changedFiles = Array(changed.prefix(BackendCodeBackupProject.listLimit))
        // Work set aside with git stash lives only here.
        let stash = try await git(top, ["log", "--walk-reflogs", "--format=%H", "refs/stash"])
        let stashes = stash.ok ? stash.stdout.split(separator: "\n").map(String.init) : []
        row.setAsideCount = stashes.count
        // Slice 2: a backup of uncommitted work covers the changed files only while the folder is exactly as it was
        // then (same commit, same list, same sizes and times); set-aside changes, while every one of them went.
        if let covered = coverage?(gitDir) {
            let raw = status.stdout
            if changed.count > 0, let now = await BackendCodeBackupFileSystem.run(projectSeconds, { BackendCodeBackupCoverage.fingerprint(head: headCommit, status: raw, top: top) }),
               covered.fingerprint == now {
                row.changesCoveredAt = covered.at
            }
            if !stashes.isEmpty, Set(stashes).isSubset(of: Set(covered.stashes)) { row.setAsideCovered = true }
        }
        // Commits the home remote does not have, and the newest of his commits that it has. Correction 14 Nov: commits
        // kept in the private backup references (`heads` of the last backup) are safe on GitHub too.
        let kept = Array(Set((coverage?(gitDir)?.heads ?? [:]).values)).sorted()
        if let chosen, row.lastCommitAt != nil { try await pushed(&row, top: top, remote: chosen.name, kept: kept) }
        // What the next commit would carry that is not in the last one: over 50 MB, or a secret file. Secret files
        // already in the last commit are their own warning.
        let files = try await git(top, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], maximum: 32 * 1024 * 1024)
        guard files.ok else { throw Failure(plain: "Git could not list the folder's files") }
        var committed = Set<String>()
        if row.lastCommitAt != nil {
            let tree = try await git(top, ["ls-tree", "-r", "-z", "--name-only", "HEAD"], maximum: 32 * 1024 * 1024)
            guard tree.ok else { throw Failure(plain: "Git could not list the folder's files") }
            committed = Set(tree.stdout.split(separator: "\0").map(String.init))
        }
        let names = Set(files.stdout.split(separator: "\0").map(String.init)), known = committed
        guard let sorted = await BackendCodeBackupFileSystem.run(projectSeconds, { Self.held(names: names, committed: known, top: top) }) else {
            throw Failure(plain: Self.silent)
        }
        let (held, inCommits) = sorted
        row.held = held; row.secretsInCommits = inCommits
    }

    private func pushed(_ row: inout BackendCodeBackupProject, top: String, remote: String, kept: [String]) async throws {
        // Backed-up commits this repository still has (a commit gone from here cannot be named to Git).
        var present: [String] = []
        for sha in kept.prefix(200) {
            if try await git(top, ["cat-file", "-e", sha + "^{commit}"]).ok { present.append(sha) }
        }
        let known = try await git(top, ["for-each-ref", "--format=%(objectname)", "refs/remotes/" + remote])
        let heard = known.ok && !known.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard heard || !present.isEmpty else {
            // The home has never been heard from on this Mac: nothing of his is on it yet.
            let count = try await git(top, ["rev-list", "--count", "--branches", "HEAD"])
            row.commitCount = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if row.commitCount > 0 { row.commits = try await commitList(top, ["--branches", "HEAD"]) }
            return
        }
        let tips = try await git(top, ["for-each-ref", "--format=%(objectname)%1f%(committerdate:unix)%1f%(refname:strip=2)", "refs/heads"])
        let heads: [(sha: String, at: Int64, name: String)] = tips.stdout.split(separator: "\n").compactMap {
            let parts = $0.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let seconds = Int64(parts[1]) else { return nil }
            return (parts[0], seconds * 1000, parts[2])
        }
        // Commits nowhere on GitHub ('>') and the commits it has right at their edge ('-'): the newest of his there is
        // the newest edge commit, or the tip of a branch with nothing missing.
        let walk = try await git(top, ["log", "--boundary", "--branches", "HEAD", "--not", "--remotes=" + remote] + present
                                       + ["--format=%m%x1f%H%x1f%ct%x1f%s"], maximum: 32 * 1024 * 1024)
        guard walk.ok else { throw Failure(plain: "Git could not read the commits") }
        var missing: [BackendCodeBackupProject.Commit] = [], missingSHAs = Set<String>(), newest: Int64?
        for line in walk.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let seconds = Int64(parts[2]) else { continue }
            if parts[0] == "-" { newest = max(newest ?? 0, seconds * 1000) }
            else if missingSHAs.insert(parts[1]).inserted { missing.append(.init(subject: parts.count > 3 ? parts[3] : "", at: seconds * 1000)) }
        }
        for head in heads where !missingSHAs.contains(head.sha) { newest = max(newest ?? 0, head.at) }
        row.lastBackedUpAt = newest
        row.commitCount = missing.count
        row.commits = Array(missing.sorted { $0.at > $1.at }.prefix(BackendCodeBackupProject.listLimit))
        // Safe in the private backup but not on his real GitHub branches: counted and named, never pushed for him.
        guard !present.isEmpty else { return }
        let all = try await git(top, ["rev-list", "--count", "--branches", "HEAD", "--not", "--remotes=" + remote])
        row.privateCommitCount = max(0, (Int(all.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) - missing.count)
        guard row.privateCommitCount > 0 else { return }
        for head in heads where !missingSHAs.contains(head.sha) {
            let ahead = try await git(top, ["rev-list", "--count", head.sha, "--not", "--remotes=" + remote])
            if (Int(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 { row.privateBranches.append(head.name) }
        }
    }

    private func commitList(_ top: String, _ range: [String]) async throws -> [BackendCodeBackupProject.Commit] {
        let log = try await git(top, ["log"] + range + ["-n", "\(BackendCodeBackupProject.listLimit)", "--format=%ct%x1f%s"])
        guard log.ok else { return [] }
        return log.stdout.split(separator: "\n").compactMap {
            let parts = $0.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let seconds = Int64(parts[0]) else { return nil }
            return .init(subject: parts.count > 1 ? parts[1] : "", at: seconds * 1000)
        }
    }

    // MARK: Plain parsing (tested directly)

    /// `config --show-scope --get-regexp`: "<scope>\t<key> <value>" per line.
    static func repositoryRunsPrograms(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let scope = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            return scope == "local" || scope == "worktree"
        }
    }

    static func remotes(_ text: String) -> [(name: String, url: String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("remote."), parts[0].hasSuffix(".url") else { return nil }
            return (String(parts[0].dropFirst("remote.".count).dropLast(".url".count)), parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    /// "owner/name" for https://github.com/o/n(.git), git@github.com:o/n.git, ssh://git@github.com/o/n.git.
    static func githubHome(_ url: String, host: String) -> String? {
        var rest: Substring
        if let range = url.range(of: "://") {
            let afterScheme = url[range.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            let authority = afterScheme[..<slash].split(separator: "@").last.map(String.init) ?? ""
            guard (authority.split(separator: ":").first.map(String.init) ?? "").lowercased() == host else { return nil }
            rest = afterScheme[afterScheme.index(after: slash)...]
        } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            let authority = url[..<colon].split(separator: "@").last.map(String.init) ?? ""
            guard authority.lowercased() == host else { return nil }
            rest = url[url.index(after: colon)...]
        } else { return nil }
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        if rest.lowercased().hasSuffix(".git") { rest = rest.dropLast(4) }
        let parts = rest.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    static func host(_ url: String) -> String? {
        if let range = url.range(of: "://") {
            let after = url[range.upperBound...]
            let authority = after.split(separator: "/").first.map(String.init) ?? ""
            let host = authority.split(separator: "@").last.map(String.init)?.split(separator: ":").first.map(String.init)
            return url.hasPrefix("file://") ? "a folder on this Mac" : host
        }
        if url.hasPrefix("/") || url.hasPrefix(".") { return "a folder on this Mac" }
        if let colon = url.firstIndex(of: ":") { return url[..<colon].split(separator: "@").last.map(String.init) }
        return nil
    }

    /// `status --porcelain=v1 -z --no-renames`: "XY name\0" per entry.
    static func statusNames(_ text: String) -> [String] {
        text.split(separator: "\0").compactMap { entry in entry.count > 3 ? String(entry.dropFirst(3)) : nil }
    }

    /// Files not in the last commit that cannot go as they are, and secret files that are in it.
    static func held(names: Set<String>, committed: Set<String>, top: String) -> ([BackendCodeBackupProject.Held], [String]) {
        var held: [BackendCodeBackupProject.Held] = []
        for name in names.sorted() where !committed.contains(name) {
            if isSecret(name, top: top) { held.append(.init(name: name, reason: .looksSecret)); continue }
            var info = stat()
            guard lstat(top + "/" + name, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if Int64(info.st_size) > largeBytes { held.append(.init(name: name, reason: .tooLarge)) }
        }
        return (held, committed.filter { holdsBack($0, top: top) }.sorted())
    }

    /// Left out of the uncommitted-work copy: kinds A and C, and a B file whose bytes in `top` hold a private key
    /// (without `top`, every B file).
    public static func isSecret(_ path: String, top: String? = nil) -> Bool {
        switch secretKind(path) {
        case .credential, .leaveOut: return true
        case .maybeKey: return top.map { privateKeyOnDisk($0 + "/" + path) } ?? true
        case .none: return false
        }
    }

    /// Holds back what carries it: kind A, and a B file whose bytes in `top` hold a private key (without `top`, every
    /// B file). Kind C never does.
    public static func holdsBack(_ path: String, top: String? = nil) -> Bool {
        switch secretKind(path) {
        case .credential: return true
        case .maybeKey: return top.map { privateKeyOnDisk($0 + "/" + path) } ?? true
        case .none, .leaveOut: return false
        }
    }
}

/// Private or public, from GitHub, only when this Mac is signed in to it.
public protocol BackendCodeBackupGitHubReading: Sendable {
    func visibility(of homes: Set<String>) async -> BackendCodeBackupGitHubAnswer
}
public struct BackendCodeBackupGitHubAnswer: Sendable, Equatable {
    public var signedIn: Bool
    /// Keyed by "owner/name" lowercased.
    public var found: [String: BackendCodeBackupProject.Visibility]
    public init(signedIn: Bool, found: [String: BackendCodeBackupProject.Visibility]) { self.signedIn = signedIn; self.found = found }
    public static let signedOut = Self(signedIn: false, found: [:])
}

/// The live reader: the repositories the existing sign-in already lists (gh's token or the GitHub App "terminal-deck",
/// read by `BackendGitHubAuthenticator.status`), then `GET /repos/{owner}/{name}`, all at once, for homes not in that
/// list when a token this app may use is at hand. A token only ever goes in a request header; never returned or logged.
public struct BackendCodeBackupGitHub: BackendCodeBackupGitHubReading {
    public struct Account: Sendable {
        public var signedIn: Bool
        /// "owner/name" lowercased -> private.
        public var listed: [String: Bool]
        public init(signedIn: Bool, listed: [String: Bool]) { self.signedIn = signedIn; self.listed = listed }
    }
    let host: String
    let http: any BackendGitHubHTTPFetching
    let account: @Sendable () async -> Account
    let token: @Sendable () async -> String?

    public init(host: String, http: any BackendGitHubHTTPFetching, account: @escaping @Sendable () async -> Account,
                token: @escaping @Sendable () async -> String?) {
        self.host = host; self.http = http; self.account = account; self.token = token
    }

    /// Reads the authenticator's own status (cached there for a minute) and its stored credential.
    public static func live(_ auth: BackendGitHubAuthenticator, http: any BackendGitHubHTTPFetching = BackendGitHubURLSessionHTTP()) -> Self {
        Self(host: auth.host, http: http, account: {
            let status = await auth.status()
            guard status["connected"].bool == true else { return Account(signedIn: false, listed: [:]) }
            var listed: [String: Bool] = [:]
            for repo in status["access"]["repos"].elements ?? [] {
                if let full = repo["nameWithOwner"].string { listed[full.lowercased()] = repo["private"].bool == true }
            }
            return Account(signedIn: true, listed: listed)
        }, token: { await auth.gitCredential()?.password })
    }

    public func visibility(of homes: Set<String>) async -> BackendCodeBackupGitHubAnswer {
        let account = await account()
        guard account.signedIn else { return .signedOut }
        var found: [String: BackendCodeBackupProject.Visibility] = [:]
        var missing: [String] = []
        for home in Set(homes.map { $0.lowercased() }).sorted() {
            if let isPrivate = account.listed[home] { found[home] = isPrivate ? .isPrivate : .isPublic } else { missing.append(home) }
        }
        guard !missing.isEmpty, let token = await token() else { return .init(signedIn: true, found: found) }
        let http = self.http, root = BackendGitHubRepositories.apiRoot(host), headers = BackendGitHubRepositories.headers(token: token)
        await withTaskGroup(of: (String, BackendCodeBackupProject.Visibility?).self) { group in
            for home in missing.prefix(50) {
                group.addTask {
                    guard let response = try? await http.fetch(url: root + "/repos/" + home, method: "GET", headers: headers, body: nil, timeoutMilliseconds: 10_000),
                          response.ok, let raw = try? NativeRPCValue.parseJSON(Data(response.body.utf8)), let isPrivate = raw["private"].bool else { return (home, nil) }
                    return (home, isPrivate ? .isPrivate : .isPublic)
                }
            }
            for await (home, value) in group { if let value { found[home] = value } }
        }
        return .init(signedIn: true, found: found)
    }
}

/// The Code page's model: every project on this Mac, read off the main thread, at most four at a time. A project's
/// answer is kept until Refresh, a change Git records (a commit, a push, staging, a stash, a branch switch), or a
/// minute passes. GitHub's private/public answers are kept apart and never hold the Git facts back.
public actor BackendCodeBackupProjects {
    public typealias Projects = @Sendable () async throws -> [PROJProject]
    let projects: Projects
    let reader: BackendCodeBackupGitReader
    let github: any BackendCodeBackupGitHubReading
    let now: @Sendable () -> Date
    let maxAge: TimeInterval
    let githubSeconds: Double
    private struct Kept { let project: PROJProject; let row: BackendCodeBackupProject; let places: [BackendCodeBackupGitReader.Place]; let mark: [String]; let at: Date }
    private var kept: [String: Kept] = [:]
    private var running: Task<BackendCodeBackupReport, Never>?
    private var visibility: [String: BackendCodeBackupProject.Visibility] = [:]
    private var signedIn: Bool?
    private var askedGitHub: (at: Date, homes: Set<String>)?
    private var asking: Task<Void, Never>?

    public init(projects: @escaping Projects, reader: BackendCodeBackupGitReader, github: any BackendCodeBackupGitHubReading,
                now: @escaping @Sendable () -> Date = { Date() }, maxAge: TimeInterval = 60, githubSeconds: Double = 4) {
        self.projects = projects; self.reader = reader; self.github = github; self.now = now; self.maxAge = maxAge; self.githubSeconds = githubSeconds
    }

    /// The Git facts at once, with the private/public answers kept so far. Never fails: a project that cannot be read
    /// says so in its own row.
    public func report(refresh: Bool = false) async -> BackendCodeBackupReport {
        if refresh { kept = [:]; askedGitHub = nil }
        if let running { return applied(await running.value) }
        let task = Task { await self.build() }
        running = task
        let report = await task.value
        running = nil
        return applied(report)
    }

    /// The same report once GitHub has answered, waiting at most `githubSeconds` in all. Answers that arrive later are
    /// kept for the next look; offline or signed out changes nothing on the rows.
    public func withGitHub(_ report: BackendCodeBackupReport) async -> BackendCodeBackupReport {
        let homes = Set(report.projects.flatMap(\.homes).map { $0.lowercased() })
        if let asked = askedGitHub, now().timeIntervalSince(asked.at) < 300, homes.isSubset(of: asked.homes) { return applied(report) }
        let task: Task<Void, Never>
        if let asking { task = asking } else {
            let github = self.github
            task = Task { let answer = await github.visibility(of: homes); await self.keep(answer, homes: homes) }
            asking = task
        }
        _ = await BackendCodeBackupLimit.first(githubSeconds) { await task.value }
        return applied(report)
    }

    /// Slice 2: the project list as the page reads it.
    public func list() async -> [PROJProject] { (try? await projects()) ?? [] }

    /// Slice 2: one project read now, never from the kept answers (before and for an action).
    func fresh(_ project: PROJProject) async -> (BackendCodeBackupProject, [BackendCodeBackupGitReader.Place]) {
        await reader.read(project)
    }

    /// Slice 2: after an action, the next look reads the project again.
    public func forget(_ projectID: String) { kept[projectID] = nil }

    private func keep(_ answer: BackendCodeBackupGitHubAnswer, homes: Set<String>) {
        signedIn = answer.signedIn
        if answer.signedIn { visibility.merge(answer.found) { _, new in new } } else { visibility = [:] }
        askedGitHub = (now(), homes); asking = nil
    }

    private func applied(_ report: BackendCodeBackupReport) -> BackendCodeBackupReport {
        BackendCodeBackupReport(projects: report.projects.map { $0.filling(visibility) }, signedInToGitHub: signedIn, checkedAt: report.checkedAt)
    }

    private func build() async -> BackendCodeBackupReport {
        let list = (try? await projects()) ?? []
        let reader = self.reader, started = now(), maxAge = self.maxAge
        var rows: [BackendCodeBackupProject] = [], toRead: [PROJProject] = []
        for project in list {
            if let old = kept[project.id], old.project == project, started.timeIntervalSince(old.at) < maxAge,
               let mark = await Self.markOnQueue(project, old.places), mark == old.mark {
                rows.append(old.row)
            } else { toRead.append(project) }
        }
        await withTaskGroup(of: (PROJProject, BackendCodeBackupProject, [BackendCodeBackupGitReader.Place]).self) { group in
            var waiting = toRead[...]
            // At most four projects are read at once.
            for _ in 0..<min(4, waiting.count) {
                let project = waiting.removeFirst()
                group.addTask { let (row, places) = await reader.read(project); return (project, row, places) }
            }
            for await (project, row, places) in group {
                rows.append(row)
                if row.problem == nil, let mark = await Self.markOnQueue(project, places) {
                    kept[project.id] = Kept(project: project, row: row, places: places, mark: mark, at: started)
                } else { kept[project.id] = nil }
                if let following = waiting.first {
                    waiting.removeFirst()
                    group.addTask { let (row, places) = await reader.read(following); return (following, row, places) }
                }
            }
        }
        return BackendCodeBackupReport(projects: rows, signedInToGitHub: signedIn, checkedAt: Int64(started.timeIntervalSince1970 * 1000))
    }

    static func markOnQueue(_ project: PROJProject, _ places: [BackendCodeBackupGitReader.Place]) async -> [String]? {
        guard !project.folders.contains(where: BackendCodeBackupFileSystem.recentlyHung) else { return nil }
        let mark = await BackendCodeBackupFileSystem.run(3) { Self.mark(project, places) }
        if mark == nil { BackendCodeBackupFileSystem.noteHung(project.folders) }
        return mark
    }

    /// What changes when Git records something: the folders, and the modification times of HEAD, the staging area,
    /// the packed refs, the reflogs (a stash too) and the remote refs. A stat each, never a Git command.
    static func mark(_ project: PROJProject, _ places: [BackendCodeBackupGitReader.Place]) -> [String] {
        var mark = project.folders.map { $0 + (BackendCodeBackupGitReader.directory($0) ? "+" : "-") }
        func time(_ path: String) -> String {
            var info = stat()
            return lstat(path, &info) == 0 ? "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" : "-"
        }
        for place in places {
            for name in ["HEAD", "index", "packed-refs", "FETCH_HEAD", "logs/HEAD", "refs/stash"] { mark.append(time(place.gitDir + "/" + name)) }
            for folder in ["refs/heads", "refs/remotes", "logs/refs"] {
                let root = place.gitDir + "/" + folder
                mark.append(time(root))
                if let walker = FileManager.default.enumerator(atPath: root) {
                    var count = 0
                    while let item = walker.nextObject() as? String, count < 2_000 { mark.append(item + "@" + time(root + "/" + item)); count += 1 }
                }
            }
        }
        return mark
    }
}

/// The one live Code model the app installs at start, for the page and `code.projects`.
public actor BackendCodeBackupHolder {
    public static let shared = BackendCodeBackupHolder()
    public private(set) var service: BackendCodeBackupProjects?
    /// Slice 2: Back up now, Get the code, Automatic / Manual / Off.
    public private(set) var actions: BackendCodeBackupActions?
    public func install(_ service: BackendCodeBackupProjects, actions: BackendCodeBackupActions? = nil) {
        self.service = service; self.actions = actions
    }
}
