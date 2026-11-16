import Foundation
import Darwin

/// "Get the code" (L5 slice 2, owner 14 Nov: only by his click, into the project's folder). The project's folder may
/// already hold instruction files from his Cloud, and Git will not download into a folder that holds files, so:
/// 1. the code is downloaded into a hidden folder BESIDE the project's folder (`.<folder>.terminal-deck-download`),
///    a little history at a time (`--depth`, then `--deepen`), so a download cut off continues where it stopped;
/// 2. the branch is checked out there;
/// 3. every file is MOVED into the project's folder where nothing is in the way; a file already there with the same
///    bytes stays as it is; a file already there with DIFFERENT bytes is KEPT (his) and GitHub's copy is not placed,
///    so Git then shows that file as changed and nothing of his is lost;
/// 4. Git's own folder moves in LAST, so the folder never looks like a repository with files missing.
/// Every Git command runs inside the hidden folder (its own repository from the first step), never in a folder
/// above it.
struct BackendCodeBackupGetCode: Sendable {
    struct Failure: Error {
        let plain: String
        /// True when trying again cannot help (GitHub holds no code): the half-made download is dropped.
        var final = false
    }
    let git: any BackendCodeBackupGitRunning
    let transport: BackendCodeBackupTransport
    /// The address written as the code's home ("https://github.com/owner/name.git"); never holds the sign-in.
    let homeURL: String
    let folder: String
    let temporary: String
    let progress: @Sendable (String) -> Void

    static let suffix = ".terminal-deck-download"
    static func temporary(for folder: String) -> String {
        let parent = (folder as NSString).deletingLastPathComponent, name = (folder as NSString).lastPathComponent
        return (parent as NSString).appendingPathComponent("." + name + suffix)
    }

    private func run(_ arguments: [String], network: Bool = false, timeout: Int = 120_000, extra: [String: String] = [:]) async throws -> BackendGitOutcome {
        let outcome = try await git.run(cwd: temporary, arguments: arguments, environment: (network ? transport.environment : [:]).merging(extra) { _, mine in mine },
                                        timeoutMilliseconds: timeout, maximumBytes: 8 * 1024 * 1024)
        if outcome.missing { throw Failure(plain: "Git is not installed on this Mac") }
        return outcome
    }
    private func line(_ outcome: BackendGitOutcome) -> String {
        String((transport.scrub(outcome.stderr).split(separator: "\n").last.map(String.init) ?? "").prefix(160))
    }

    /// Git LFS is never run: its large files stay as Git's small pointer files, and the line says so (review 14 Nov),
    /// instead of a download that fails half-way.
    static let noLFS = ["GIT_LFS_SKIP_SMUDGE": "1"]

    /// The branch now on this Mac, the files of his that were kept because they differ from GitHub's, and whether the
    /// code keeps large files with Git LFS (not included).
    func perform() async throws -> (branch: String?, kept: [String], large: Bool) {
        let manager = FileManager.default
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue else { throw Failure(plain: "The project's folder is not on this Mac") }
        if manager.fileExists(atPath: folder + "/.git") {
            // A run that stopped right after Git's folder moved in: only the clean-up is left.
            try? manager.removeItem(atPath: temporary)
            return (nil, [], FileManager.default.contents(atPath: folder + "/.gitattributes").map { String(decoding: $0, as: UTF8.self).contains("filter=lfs") } ?? false)
        }
        if !manager.fileExists(atPath: temporary + "/.git") {
            if !manager.fileExists(atPath: temporary) {
                guard mkdir(temporary, 0o700) == 0 else { throw Failure(plain: "A folder for the download could not be made beside the project's folder") }
            }
            let made = try await run(["init", "-q"])
            guard made.ok else { throw Failure(plain: "Git could not start the download") }
            _ = try await run(["remote", "add", "origin", homeURL])
        }
        // What GitHub has, and the branch it opens with.
        progress("Getting the code · asking GitHub")
        let listing = try await run(["ls-remote", "--symref", "--", transport.url], network: true, timeout: 120_000)
        guard listing.ok else { throw Failure(plain: "GitHub did not answer (\(line(listing)))") }
        let rows = listing.stdout.split(separator: "\n").map(String.init)
        var branch = rows.compactMap { row -> String? in
            guard row.hasPrefix("ref: refs/heads/"), row.hasSuffix("\tHEAD"), let tab = row.firstIndex(of: "\t") else { return nil }
            return String(row[row.index(row.startIndex, offsetBy: "ref: refs/heads/".count)..<tab])
        }.first
        let empty = !rows.contains { $0.contains("\trefs/heads/") || $0.contains("\trefs/tags/") }
        // Branches kept only in the private backup references (a home whose real branches were never written): each
        // row "<keeper>\trefs/terminal-deck-backup/<Mac>/heads/<branch>"; the keeper's first parent is his branch.
        let keepers: [(reference: String, branch: String)] = rows.compactMap { row in
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix(BackendCodeBackupPlan.namespace), let range = parts[1].range(of: "/heads/") else { return nil }
            return (parts[1], String(parts[1][range.upperBound...]))
        }
        // Uncommitted work kept only in the private references ("<keeper>\trefs/terminal-deck-backup/<Mac>/work/<branch>"):
        // the only code a folder backed up before its first commit has (review 14 Nov).
        let work: [(reference: String, branch: String)] = rows.compactMap { row in
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix(BackendCodeBackupPlan.namespace), let range = parts[1].range(of: "/work/") else { return nil }
            return (parts[1], String(parts[1][range.upperBound...]))
        }
        let refspecs = ["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/" + BackendCodeBackupPlan.prefix + "*", "refs/tags/*:refs/tags/*"]
        // A little history first, then the rest in steps: each finished step stays when the download is cut off.
        let shallow = temporary + "/.git/shallow"
        let started = try await run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/" + (branch ?? "main")])
        if !started.ok && !empty {
            progress("Getting the code · downloading")
            let first = try await run(["fetch", "--quiet", "--depth=50", "--no-write-fetch-head", "--", transport.url] + refspecs, network: true, timeout: 600_000)
            guard first.ok else { throw Failure(plain: "The download stopped (\(line(first))). Get the code again to continue") }
        }
        var step = 0
        while manager.fileExists(atPath: shallow), step < 400 {
            step += 1
            progress("Getting the code · downloading history (\(step))")
            let more = try await run(["fetch", "--quiet", "--deepen=2000", "--no-write-fetch-head", "--", transport.url] + refspecs, network: true, timeout: 600_000)
            guard more.ok else { throw Failure(plain: "The download stopped (\(line(more))). Get the code again to continue") }
            let check = try await run(["rev-parse", "--is-shallow-repository"])
            if check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "false" { break }
            try Task.checkCancellation()
        }
        // The branch to open: GitHub's own, else main, else the first one (never a backup branch).
        let known = try await run(["for-each-ref", "--format=%(refname:strip=3)", "refs/remotes/origin"])
        let remoteBranches = known.stdout.split(separator: "\n").map(String.init).filter { $0 != "HEAD" && !$0.hasPrefix(BackendCodeBackupPlan.prefix) }
        if branch.map({ !remoteBranches.contains($0) }) ?? true {
            branch = remoteBranches.contains("main") ? "main" : remoteBranches.contains("master") ? "master" : remoteBranches.first
        }
        let opened = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]).ok
        var placedWork = false
        if branch == nil, keepers.isEmpty, !opened, !work.isEmpty {
            // No branch anywhere: the newest copy of uncommitted work, opened as files on a new branch with no commits
            // yet (as they were on the Mac that backed them up).
            progress("Getting the code · downloading the backup")
            let got = try await run(["fetch", "--quiet", "--no-write-fetch-head", "--no-tags", "--", transport.url] + work.map(\.reference), network: true, timeout: 600_000)
            guard got.ok else { throw Failure(plain: "The download stopped (\(line(got))). Get the code again to continue") }
            var newest: (sha: String, branch: String, at: Int64)?
            for entry in work {
                guard let sha = rows.first(where: { $0.hasSuffix("\t" + entry.reference) })?.split(separator: "\t").first.map(String.init) else { continue }
                let time = try await run(["log", "-1", "--format=%ct", sha])
                let at = Int64(time.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if newest == nil || at > newest!.at { newest = (sha, entry.branch, at) }
            }
            if let newest {
                let name = newest.branch == "no-branch" ? "main" : newest.branch
                progress("Getting the code · opening \(name)")
                let pointed = try await run(["symbolic-ref", "HEAD", "refs/heads/" + name])
                let read = try await run(["read-tree", "--reset", "-u", newest.sha + "^{tree}"], timeout: 600_000, extra: Self.noLFS)
                guard pointed.ok, read.ok else { throw Failure(plain: "The files could not be opened (\(line(read.ok ? pointed : read)))") }
                branch = name; placedWork = true
            }
        } else if branch == nil, !keepers.isEmpty, !opened {
            // No real branch on GitHub: open his newest backed-up branch (main first) as a plain local branch.
            progress("Getting the code · downloading the backup")
            let wanted = keepers.contains { $0.branch == "main" } ? keepers.filter { $0.branch == "main" } : keepers
            let got = try await run(["fetch", "--quiet", "--no-write-fetch-head", "--no-tags", "--", transport.url] + wanted.map(\.reference), network: true, timeout: 600_000)
            guard got.ok else { throw Failure(plain: "The download stopped (\(line(got))). Get the code again to continue") }
            var newest: (sha: String, branch: String, at: Int64)?
            for entry in wanted {
                guard let sha = rows.first(where: { $0.hasSuffix("\t" + entry.reference) })?.split(separator: "\t").first.map(String.init) else { continue }
                let time = try await run(["log", "-1", "--format=%ct", sha])
                let at = Int64(time.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if newest == nil || at > newest!.at { newest = (sha, entry.branch, at) }
            }
            if let newest {
                progress("Getting the code · opening \(newest.branch)")
                let checkout = try await run(["checkout", "-q", "-b", newest.branch, newest.sha + "^1"], timeout: 600_000, extra: Self.noLFS)
                guard checkout.ok else { throw Failure(plain: "The files could not be opened (\(line(checkout)))") }
                branch = newest.branch
            }
        } else if let branch {
            let local = try await run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch])
            if !local.ok {
                progress("Getting the code · opening \(branch)")
                let checkout = try await run(["checkout", "-q", "-b", branch, "--track", "origin/" + branch], timeout: 600_000, extra: Self.noLFS)
                guard checkout.ok else { throw Failure(plain: "The files could not be opened (\(line(checkout)))") }
            }
        }
        // Never "Code is here" with nothing placed.
        let hasCommit = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]).ok
        guard placedWork || hasCommit else {
            throw Failure(plain: "Code not got: GitHub has no code for this project yet", final: true)
        }
        let large = FileManager.default.contents(atPath: temporary + "/.gitattributes").map { String(decoding: $0, as: UTF8.self).contains("filter=lfs") } ?? false
        progress("Getting the code · placing files")
        var placedKept: [String] = []
        try Self.merge(from: temporary, into: folder, relative: "", kept: &placedKept)
        guard renamex_np(temporary + "/.git", folder + "/.git", UInt32(RENAME_EXCL)) == 0 else { throw Failure(plain: "Git's folder could not be moved into the project's folder") }
        try? manager.removeItem(atPath: temporary)
        return (branch, placedKept.sorted(), large)
    }

    /// Moves `from` into `into` without ever replacing anything there (Git's own folder is left for last).
    static func merge(from source: String, into target: String, relative: String, kept: inout [String]) throws {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: source)) ?? [] {
            if relative.isEmpty && name == ".git" { continue }
            let from = source + "/" + name, to = target + "/" + name, path = relative.isEmpty ? name : relative + "/" + name
            var mine = stat(), theirs = stat()
            guard lstat(from, &theirs) == 0 else { continue }
            if lstat(to, &mine) != 0 {
                // Exclusive (review 14 Nov): a file that appears at the same instant is never replaced; it is then his.
                if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { continue }
                guard errno == EEXIST, lstat(to, &mine) == 0 else { throw Failure(plain: "A file could not be placed (\(path))") }
            }
            let mineType = mine.st_mode & S_IFMT, theirType = theirs.st_mode & S_IFMT
            if mineType == S_IFDIR && theirType == S_IFDIR {
                try merge(from: from, into: to, relative: path, kept: &kept)
            } else if mineType == S_IFREG && theirType == S_IFREG {
                if !manager.contentsEqual(atPath: from, andPath: to) { kept.append(path) }
            } else if mineType == S_IFLNK && theirType == S_IFLNK,
                      (try? manager.destinationOfSymbolicLink(atPath: from)) == (try? manager.destinationOfSymbolicLink(atPath: to)) {
                continue
            } else {
                kept.append(path)
            }
        }
    }
}
