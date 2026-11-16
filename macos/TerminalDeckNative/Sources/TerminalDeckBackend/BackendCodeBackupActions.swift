import Foundation
import Darwin
import Network
import SystemConfiguration
import CryptoKit
import TerminalDeckNativeCore

/// L5 slice 2: the Code page's actions (owner, 13-14 Nov). Back up now, a private home on GitHub for a project that has
/// none, Get the code, and Automatic / Manual / Off per project.
///
/// Rules every action keeps:
/// - WHOSE ACCOUNT: only the GitHub sign-in the app already has. Not connected: nothing runs ("Connect GitHub first").
///   A home on another person's account or an organisation is written to only when it is ALREADY the project's home
///   (its Git remote) AND GitHub says this sign-in may push there. New homes are made on his own account only.
/// - PRIVATE: a new home is always made private; an existing home's visibility is never changed. A public home is not
///   backed up at all (anything sent there could be read by anyone).
/// - NO SIDE EFFECTS ON GITHUB (correction 14 Nov): on a home he already had, a backup writes only private references
///   (`refs/terminal-deck-backup/…`), never a branch or a tag, so nothing that hangs on a push (deploys, release
///   workflows, preview builds, CI) can start. Review 14 Nov: in this release a home Terminal Deck made gets only the
///   private references too (`BackendCodeBackupPlan.realNamesAllowed` is false; the quiet-home path is unreachable).
/// - WHICH REPOSITORY: only a repository that `BackendProjectCode.owns` for one of the project's folders, checked again
///   right before any change, and never one whose top is the home folder or the Terminal Deck folder (or above).
/// - ADDS ONLY: see `BackendCodeBackupPlan` and `BackendCodeBackupSend`.
public actor BackendCodeBackupActions {
    public typealias Network = @Sendable () -> Bool
    public struct Outcome: Sendable, Equatable {
        public var ok: Bool
        public var line: String
        public init(ok: Bool, line: String) { self.ok = ok; self.line = line }
    }
    /// What an action would do, for the approval line and the page's Undo line.
    public struct Target: Sendable, Equatable {
        public var projectID: String
        public var name: String
        /// "github.com/owner/name"; for a new home, the name it will try first.
        public var address: String?
        public var newHome: Bool
        /// Review 14 Nov: the home's owner when it is not his own account (an organisation): named on every line.
        public var organisation: String?
        /// Where Get the code puts the code (the short path).
        public var folder: String?
    }

    /// Automatic: a project's work must stay the same for `settleSeconds` (seen on two looks that far apart), at most one
    /// automatic backup per project every `gapSeconds`, a normal network, Git not busy in it.
    public static let lookSeconds: TimeInterval = 300, settleSeconds: TimeInterval = 300, gapSeconds: TimeInterval = 900
    public static let automaticRule = "Automatic backs up when a project's work has not changed for 5 minutes, at most every 15 minutes, on a normal network (not Low Data, not a phone hotspot), and never while Git is busy in it. Cost: one quick read of each Automatic project every 5 minutes; the network only when there is something new."

    let projects: BackendCodeBackupProjects
    let ledger: BackendCodeBackupLedger
    let account: any BackendCodeBackupAccount
    let git: any BackendCodeBackupGitRunning
    let host: String
    let mac: String
    /// This Mac's name as System Settings shows it ("from which Mac" on the page).
    let macTitle: String
    let bounds: @Sendable () -> BackendProjectCode.Bounds
    let network: Network
    let now: @Sendable () -> Date
    /// Where the app keeps its own Git repository per project (`BackendCodeBackupSend.shadow`).
    let workArea: URL
    private var busy: Set<String> = []
    private var notes: [String: String] = [:]
    private var seen: [String: (mark: String, since: Date)] = [:]
    private var lastAutomatic: [String: Date] = [:]
    private var quietAnswers: [String: (quiet: Bool, at: Date)] = [:]
    private var loop: Task<Void, Never>?

    public init(projects: BackendCodeBackupProjects, ledger: BackendCodeBackupLedger, account: any BackendCodeBackupAccount,
                git: any BackendCodeBackupGitRunning, host: String = "github.com", mac: String? = nil, macTitle: String? = nil,
                bounds: @escaping @Sendable () -> BackendProjectCode.Bounds = { .live() }, network: @escaping Network = BackendCodeBackupNetwork.shared.normal,
                now: @escaping @Sendable () -> Date = { Date() }, workArea: URL? = nil) {
        self.projects = projects; self.ledger = ledger; self.account = account; self.git = git; self.host = host.lowercased()
        self.mac = mac ?? Self.macName(ledger: ledger)
        self.macTitle = macTitle ?? (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "this Mac"
        self.workArea = workArea ?? ledger.folder?.appendingPathComponent("code-backup-git", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("terminaldeck-code-backup-git", isDirectory: true)
        self.bounds = bounds; self.network = network; self.now = now
    }

    /// This Mac's part of the backup references: its own name from System Settings (no network lookup, unlike
    /// Host.current()) and, review 14 Nov, a short stable id so two Macs with the same name never share one backup
    /// area. The id is a hash of the hardware id (never the hardware id itself); a kept random one when it cannot be read.
    public static func macName(ledger: BackendCodeBackupLedger) -> String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        return macPart(name: name, hardware: BackendCloudMachineFacts.platformUUID().map { Self.deviceID($0) } ?? ledger.spareID())
    }
    static func deviceID(_ hardware: String) -> String {
        let digest = SHA256.hash(data: Data(("TD-CODE-BACKUP-1\n" + hardware.uppercased()).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
    /// "<readable name>-<id>", one reference part.
    public static func macPart(name: String, hardware id: String) -> String {
        BackendCodeBackupPlan.part(String(BackendCodeBackupPlan.part(name).prefix(60)) + "-" + BackendCodeBackupPlan.part(id))
    }

    // MARK: The page and the tool read through this

    /// The report with each project's mode, Get-the-code home, unfinished downloads and last action line filled in.
    public func decorate(_ report: BackendCodeBackupReport) async -> BackendCodeBackupReport {
        let login = await account.login()
        let repositories = login == nil ? [] : await account.repositories()
        let getting = ledger.allGetting
        var rows: [BackendCodeBackupProject] = []
        for var row in report.projects {
            if getting[row.id] != nil {
                row.getting = true; row.problem = nil; row.hasFolder = true; row.isRepository = false; row.parts = []
                row.getFrom = getting[row.id]?.home
            } else if row.state == .codeNotHere {
                row.getFrom = ledger.home(row.id) ?? Self.match(name: row.name, repositories: repositories, login: login)
            }
            row.mode = mode(row.id, home: row.home, repositories: repositories, login: login, visibility: row.visibility)
            row.note = notes[row.id]
            row.organisation = Self.organisation(row.home, login: login)
            row.madeHome = row.home.map { ledger.isMade($0) } ?? false
            row.homeLink = Self.link(host: host, home: row.home)
            row.parts = row.parts.map { var part = $0; part.homeLink = Self.link(host: host, home: part.home); return part }
            if let sent = ledger.sentAt(row.id) { row.sentAt = sent; row.sentFrom = macTitle }
            rows.append(row)
        }
        var out = BackendCodeBackupReport(projects: rows, signedInToGitHub: report.signedInToGitHub ?? (login != nil), checkedAt: report.checkedAt)
        out.automaticWaits = !ledger.firstBackupDone
        return out
    }

    /// The stored choice (he set it by hand). Otherwise (lead, 14 Nov): Manual on this Mac until a "Back up now" here has
    /// finished successfully; from then on Automatic for a project whose home is PRIVATE on HIS OWN account, else
    /// Manual (so nothing is made on GitHub without his click).
    func mode(_ projectID: String, home: String?, repositories: [BackendCodeBackupRepo], login: String?,
              visibility: BackendCodeBackupProject.Visibility = .notChecked) -> BackendCodeBackupMode {
        // Review 14 Nov: a home that is not on his own account is Manual only (or Off), whatever was set, by anyone.
        if Self.organisation(home, login: login) != nil { return ledger.mode(projectID) == .off ? .off : .manual }
        if let stored = ledger.mode(projectID) { return stored }
        guard ledger.firstBackupDone else { return .manual }
        guard let home, let login, home.split(separator: "/").first.map({ $0.lowercased() == login.lowercased() }) == true else { return .manual }
        if visibility == .isPrivate { return .automatic }
        return repositories.first { $0.nameWithOwner.lowercased() == home.lowercased() }?.isPrivate == true ? .automatic : .manual
    }

    /// A GitHub repository for a project whose code is not here: one named as this app names homes (his own account
    /// first), else the only repository of that name he can see.
    static func match(name: String, repositories: [BackendCodeBackupRepo], login: String?) -> String? {
        let wanted = BackendCodeBackupNames.repository(name).lowercased()
        let named = repositories.filter { $0.name.lowercased() == wanted }
        if let login, let own = named.first(where: { $0.owner.lowercased() == login.lowercased() }) { return own.nameWithOwner }
        return named.count == 1 ? named[0].nameWithOwner : nil
    }

    /// The app's own repository for one of his repositories: named by a hash of his Git folder's real path.
    static func shadow(_ area: URL, gitDir: String) -> String {
        let digest = SHA256.hash(data: Data(BackendProjectCode.resolved(gitDir).utf8)).map { String(format: "%02x", $0) }.joined()
        return area.appendingPathComponent(String(digest.prefix(24)) + ".git", isDirectory: true).path
    }

    /// The owner of a home that is not on his own account; nil for his own (or no home, or not signed in).
    static func organisation(_ home: String?, login: String?) -> String? {
        guard let home, let login, let owner = home.split(separator: "/").first.map(String.init), owner.lowercased() != login.lowercased() else { return nil }
        return owner
    }

    public func note(_ projectID: String) -> String? { notes[projectID] }
    public func signedIn() async -> Bool { await account.login() != nil }

    // MARK: What an action would do (the approval line names the project and the GitHub address)

    public func target(projectID: String) async -> Target? {
        guard let project = await projects.list().first(where: { $0.id == projectID }) else { return nil }
        return await target(project)
    }
    public func target(named name: String) async -> Target? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let project = await projects.list().first(where: { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame }) else { return nil }
        return await target(project)
    }
    private func target(_ project: PROJProject) async -> Target {
        let (row, _) = await projects.fresh(project)
        var target = Target(projectID: project.id, name: project.name, address: nil, newHome: false,
                            folder: project.folders.first.map { BackendProjectFolders.shortPath($0) })
        let login = await account.login()
        if let getting = ledger.getting(project.id) { target.address = host + "/" + getting.home; return target }
        if row.state == .codeNotHere {
            let repositories = login == nil ? [] : await account.repositories()
            let found = ledger.home(project.id) ?? Self.match(name: project.name, repositories: repositories, login: login)
            target.address = found.map { host + "/" + $0 }
        } else if let home = row.home {
            target.address = host + "/" + home
            target.organisation = Self.organisation(home, login: login)
        } else if row.otherHost == nil, let login {
            target.newHome = true
            target.address = host + "/" + login + "/" + BackendCodeBackupNames.repository(project.name)
        }
        return target
    }

    /// The home's own page on GitHub, for the row's link; nil without a home or with an unreadable name.
    static func link(host: String, home: String?) -> String? {
        guard let home, home.split(separator: "/").count == 2,
              let url = URL(string: "https://" + host + "/" + home), url.host != nil else { return nil }
        return url.absoluteString
    }

    // MARK: Automatic / Manual / Off

    /// Per project only; never the per-Mac "first Back up now" mark. Automatic is refused for a home that is not on his
    /// own account (stored as Manual).
    public func setMode(projectID: String, _ mode: BackendCodeBackupMode) async {
        var mode = mode
        if mode == .automatic, let project = await projects.list().first(where: { $0.id == projectID }) {
            let home = await projects.fresh(project).0.home
            if Self.organisation(home, login: await account.login()) != nil { mode = .manual }
        }
        ledger.setMode(projectID, mode)
        seen[projectID] = nil
        await projects.forget(projectID)
    }

    // MARK: Back up now

    /// `byHand`: his own click on the page (only the page passes true). Only that marks the first Back up now on this
    /// Mac, which lets eligible projects default to Automatic; a tool call never does.
    public func backUp(projectID: String, automatic: Bool = false, byHand: Bool = false, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        guard let project = await projects.list().first(where: { $0.id == projectID }) else { return Outcome(ok: false, line: "This project is not on this Mac") }
        guard !busy.contains(projectID) else { return Outcome(ok: false, line: "Already working on this project") }
        busy.insert(projectID)
        defer { busy.remove(projectID) }
        let outcome = await backUp(project, automatic: automatic, progress: progress)
        if byHand && !automatic && outcome.ok { ledger.setFirstBackupDone() }
        if outcome.ok { ledger.setSent(projectID, at: Int64(now().timeIntervalSince1970 * 1000)) }
        // Automatic stays quiet when it worked; a failure is the row's one line.
        if !automatic || !outcome.ok { notes[projectID] = outcome.line }
        await projects.forget(projectID)
        return outcome
    }

    private func backUp(_ project: PROJProject, automatic: Bool, progress: @escaping @Sendable (String) -> Void) async -> Outcome {
        if ledger.getting(project.id) != nil { return Outcome(ok: false, line: "Not backed up: Get the code has not finished") }
        guard let login = await account.login() else { return Outcome(ok: false, line: "Connect GitHub first") }
        let bounds = self.bounds()
        progress("Backing up · reading the folder")
        var (row, places) = await projects.fresh(project)
        if let problem = row.problem { return Outcome(ok: false, line: "Not backed up: \(problem)") }
        if row.waitingForCode || row.state == .codeNotHere { return Outcome(ok: false, line: "Code not on this Mac yet") }
        if places.isEmpty {
            // A plain folder of his (no Git yet): it becomes its own repository, so it can have a home. Never one the
            // app made that holds only Cloud files, never his home folder or the Terminal Deck folder.
            guard let folder = project.folders.first(where: { BackendCodeBackupGitReader.directory($0) }),
                  !BackendProjectCode.waitingForCode(folder, bounds: bounds), !Self.atOrAboveProtected(folder, bounds: bounds),
                  !FileManager.default.fileExists(atPath: folder + "/.git") else { return Outcome(ok: false, line: "No code folder on this Mac") }
            // A folder whose files a repository above already keeps (his home folder's, say) is that repository's
            // business: no new repository is started inside it.
            if let above = BackendProjectCode.nearestTop(folder), BackendProjectCode.resolved(above) != BackendProjectCode.resolved(folder),
               await BackendProjectCode.tracksInside(top: BackendProjectCode.resolved(above), folder: BackendProjectCode.resolved(folder), probe: probe) {
                return Outcome(ok: false, line: "Not backed up: its files are kept by the Git folder above it")
            }
            // Checked again right before `init` (review 14 Nov): a `.git` that appeared meanwhile is his; `git init` would
            // quietly re-initialise it, so it is neither initialised nor given a list.
            if !FileManager.default.fileExists(atPath: folder + "/.git") {
                let made = try? await git.run(cwd: folder, arguments: ["init", "-q", "--initial-branch=main"], environment: [:], timeoutMilliseconds: 30_000, maximumBytes: 65_536)
                guard made?.ok == true else { return Outcome(ok: false, line: "Not backed up: Git could not start in the folder") }
                // The `.git` the app just made gets a list of what never goes (heavy folders, key files). It lives inside
                // that `.git`; none of his files is touched. Without it nothing is sent.
                guard Self.writeExclude(gitDir: folder + "/.git") else { return Outcome(ok: false, line: "Not backed up: Git could not start in the folder") }
            }
            (row, places) = await projects.fresh(project)
            guard !places.isEmpty else { return Outcome(ok: false, line: "Not backed up: the folder could not be read") }
        }
        var sent = 0, skipped: [String] = [], leftOut: [BackendCodeBackupCoverage.LeftOut] = [], homes: [String] = []
        var failures: [String] = []
        var largeFiles = false
        for (index, place) in places.enumerated() {
            // Checked again right before anything changes: the repository is this project's code.
            guard await owned(place, project: project, bounds: bounds) else { failures.append("a folder above the project is not its code"); continue }
            let label = places.count > 1 ? (place.top as NSString).lastPathComponent + ": " : ""
            if let busy = BackendCodeBackupSend.gitBusy(place.gitDir) { failures.append(label + "Git is in the middle of \(busy)"); continue }
            switch await home(place, main: index == 0, project: project, login: login, automatic: automatic, progress: progress) {
            // A submodule or a nested repository of someone else's (or with no home) stays as it is, named on the line;
            // the project's own folder failing is the project failing.
            case .failure(let line): if index == 0 { failures.append(label + line) } else { skipped.append(label + line) }
            case .success(let found):
                guard let transport = await account.transport(found.home) else { failures.append("Connect GitHub first"); continue }
                progress("Backing up · sending to \(host)/\(found.home)")
                var realNames = false
                if BackendCodeBackupPlan.realNamesAllowed { realNames = await usesRealNames(found.home) }
                let result = await BackendCodeBackupSend(git: git, top: place.top, gitDir: place.gitDir, remoteName: found.remote, transport: transport,
                                                         realNames: realNames, mac: mac, ledger: ledger, now: now(),
                                                         shadow: Self.shadow(workArea, gitDir: place.gitDir)).perform()
                if result.becameLoud { ledger.markLoud(found.home) }
                if let failure = result.failure { failures.append(label + failure) }
                sent += result.sent; skipped += result.skipped.map { label + $0 }; leftOut += result.leftOut
                if index == 0 { homes.append(found.home); ledger.setHome(project.id, found.home) }
                if Self.usesLFS(place.top) { largeFiles = true }
            }
        }
        var line = failures.isEmpty ? (homes.first.map { "Backed up to \(host)/\($0)" } ?? "Backed up") : "Not backed up: " + failures[0]
        if !leftOut.isEmpty {
            let secret = leftOut.filter { $0.reason == "secret file" }.count
            let why = secret == leftOut.count ? "secret files" : secret == 0 ? "over 50 MB" : "secret files, over 50 MB"
            line += " · \(leftOut.count) \(leftOut.count == 1 ? "file" : "files") left out (\(why))"
        }
        if let first = skipped.first { line += " · " + first + (skipped.count > 1 ? " · \(skipped.count - 1) more not sent" : "") }
        if largeFiles { line += " · " + Self.lfsLine }
        if failures.isEmpty && sent == 0 && skipped.isEmpty && leftOut.isEmpty { line += " · nothing new to send" }
        return Outcome(ok: failures.isEmpty, line: line)
    }

    private struct Home { let home: String; let remote: String; let isPrivate: Bool }
    private enum Found { case success(Home), failure(String) }

    /// The repository's GitHub home and whether he may send there; for the project's own folder with no home at all, a
    /// new PRIVATE home on his account (only on his click, or with Automatic chosen by him).
    private func home(_ place: BackendCodeBackupGitReader.Place, main: Bool, project: PROJProject, login: String, automatic: Bool,
                      progress: @Sendable (String) -> Void) async -> Found {
        let remotes = (try? await git.run(cwd: place.top, arguments: ["config", "--get-regexp", #"^remote\..*\.url$"#], environment: [:],
                                          timeoutMilliseconds: 10_000, maximumBytes: 65_536))?.stdout ?? ""
        let addresses = BackendCodeBackupGitReader.remotes(remotes)
        if let chosen = addresses.first(where: { $0.name == "origin" }) ?? addresses.first {
            guard let home = BackendCodeBackupGitReader.githubHome(chosen.url, host: host) else {
                return .failure("its home is \(BackendCodeBackupGitReader.host(chosen.url) ?? "another place"), not GitHub")
            }
            if let mirror = try? await git.run(cwd: place.top, arguments: ["config", "--get", "remote.\(chosen.name).mirror"], environment: [:],
                                              timeoutMilliseconds: 10_000, maximumBytes: 4096), mirror.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                return .failure("its home is set up as a mirror; not sent")
            }
            let own = home.split(separator: "/").first.map { $0.lowercased() == login.lowercased() } == true
            guard let repository = await account.repository(home) else { return .failure("no access to \(host)/\(home)") }
            // Someone else's or an organisation's: only with push access, only because it already is the home, and only
            // for the project's own folder. Review 14 Nov: a nested clone or submodule of an organisation's repository
            // inside his project is never written to (everyone in that organisation could read its backup references).
            guard own || main else { return .failure("\(host)/\(home) is not on your account; not backed up") }
            // An organisation's home: Back up now only, never Automatic.
            guard own || !automatic else { return .failure("\(host)/\(home) is an organisation's home: Back up now only") }
            guard own || repository.canPush else { return .failure("no permission to send to \(host)/\(home)") }
            guard repository.isPrivate else { return .failure("its home \(host)/\(home) is public; backups go only to a private home") }
            return .success(Home(home: repository.nameWithOwner, remote: chosen.name, isPrivate: repository.isPrivate))
        }
        guard main else { return .failure("no GitHub home") }
        // Automatic makes a home only when he chose Automatic for this project himself.
        if automatic && ledger.mode(project.id) != .automatic { return .failure("no GitHub home yet") }
        progress("Backing up · making a private home on GitHub")
        guard let made = await makeHome(project, login: login) else { return .failure("GitHub did not make a private home") }
        switch made {
        case .failure(let line): return .failure(line)
        case .success(let repository):
            let url = "https://\(host)/\(repository.nameWithOwner).git"
            let added = try? await git.run(cwd: place.top, arguments: ["remote", "add", "origin", url], environment: [:], timeoutMilliseconds: 10_000, maximumBytes: 65_536)
            guard added?.ok == true else { return .failure("the new home could not be set in the folder") }
            ledger.setHome(project.id, repository.nameWithOwner)
            ledger.madeHome(repository.nameWithOwner)
            return .success(Home(home: repository.nameWithOwner, remote: "origin", isPrivate: repository.isPrivate))
        }
    }

    private enum Made { case success(BackendCodeBackupRepo), failure(String) }

    public static let lfsLine = "Large files (Git LFS) are not included"

    /// The repository keeps large files with Git LFS (its own `.gitattributes`); those are not copied by a backup.
    static func usesLFS(_ top: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: top + "/.gitattributes"), data.count < 1_048_576 else { return false }
        return String(decoding: data, as: UTF8.self).contains("filter=lfs")
    }

    /// `.git/info/exclude` of a `.git` the app has just made (never one of his): heavy folders and the secret names.
    /// Written only when the file is missing or still Git's untouched template (comment lines only); a file with any
    /// rule of his is left exactly as it is (and counts as written: his rules stand).
    static func writeExclude(gitDir: String) -> Bool {
        let info = gitDir + "/info"
        if let existing = FileManager.default.contents(atPath: info + "/exclude") {
            let text = String(decoding: existing, as: UTF8.self)
            if text.hasPrefix(BackendCodeBackupGitReader.excludeMarker) { return true }
            let untouched = text.split(whereSeparator: \.isNewline).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix("#") }
            if !untouched { return true }
        }
        do {
            try FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
            try Data(BackendCodeBackupGitReader.excludeText.utf8).write(to: URL(fileURLWithPath: info + "/exclude"), options: .atomic)
            return true
        } catch { return false }
    }

    /// Real branch and tag names only for a home Terminal Deck made that GitHub says nothing reacts to; the answer is
    /// kept an hour (four small API reads per home per hour at most). A "no" is recorded for good.
    private func usesRealNames(_ home: String) async -> Bool {
        guard ledger.usesRealNames(home) else { return false }
        let key = home.lowercased()
        if let kept = quietAnswers[key], now().timeIntervalSince(kept.at) < 3_600 { return kept.quiet }
        let quiet = await account.quiet(home)
        quietAnswers[key] = (quiet, now())
        if !quiet { ledger.markLoud(home) }
        return quiet
    }

    /// Named after the project ("my-site", then "my-site-2" … when taken). A home this app already made for the same
    /// project on his account (same name, private, described as this project) is used again instead of a second one.
    private func makeHome(_ project: PROJProject, login: String) async -> Made? {
        let description = BackendCodeBackupNames.description(project.name)
        let base = BackendCodeBackupNames.repository(project.name)
        let existing = await account.repositories()
        if let again = existing.first(where: { $0.owner.lowercased() == login.lowercased() && $0.isPrivate && $0.description == description
                                               && ($0.name.lowercased() == base.lowercased() || $0.name.lowercased().hasPrefix(base.lowercased() + "-")) }) {
            return .success(again)
        }
        for name in BackendCodeBackupNames.candidates(base) {
            switch await account.create(name: name, description: description) {
            case .made(let repository):
                // Never published: if GitHub ever made it public, nothing is sent and it is not changed.
                guard repository.isPrivate else { return .failure("GitHub made \(host)/\(repository.nameWithOwner) public; nothing was sent") }
                return .success(repository)
            case .taken: continue
            case .refused(let reason): return .failure(reason)
            }
        }
        return .failure("every name for a new home is taken")
    }

    /// The rule's read-only question to a repository above a folder (`ls-files`), never a change.
    private var probe: BackendProjectCode.Probe {
        let git = self.git
        return { cwd, arguments in
            guard let outcome = try? await git.run(cwd: cwd, arguments: arguments, environment: [:], timeoutMilliseconds: 15_000, maximumBytes: 64 * 1024),
                  !outcome.missing else { return nil }
            return outcome.stdout
        }
    }

    private func owned(_ place: BackendCodeBackupGitReader.Place, project: PROJProject, bounds: BackendProjectCode.Bounds) async -> Bool {
        if Self.atOrAboveProtected(place.top, bounds: bounds) { return false }
        let probe = self.probe
        for folder in project.folders where folder.hasPrefix("/") {
            let top = BackendProjectCode.resolved(place.top), inside = BackendProjectCode.resolved(folder)
            // A submodule or a nested repository inside the project's folder is its own top.
            if BackendProjectCode.inside(top, inside) { return true }
            if await BackendProjectCode.owns(top: place.top, folder: folder, bounds: bounds, probe: probe) { return true }
        }
        return false
    }

    /// The home folder, the Terminal Deck folder, or a folder above either: never backed up as a project's code.
    static func atOrAboveProtected(_ path: String, bounds: BackendProjectCode.Bounds) -> Bool {
        let path = BackendProjectCode.resolved(path)
        for home in bounds.homes where !home.isEmpty && BackendProjectCode.inside(BackendProjectCode.resolved(home), path) { return true }
        if let base = bounds.base, !base.isEmpty, BackendProjectCode.inside(BackendProjectCode.resolved(base), path) { return true }
        return false
    }

    // MARK: Get the code

    public func getCode(projectID: String, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        guard let project = await projects.list().first(where: { $0.id == projectID }) else { return Outcome(ok: false, line: "This project is not on this Mac") }
        guard !busy.contains(projectID) else { return Outcome(ok: false, line: "Already working on this project") }
        busy.insert(projectID)
        defer { busy.remove(projectID) }
        let outcome = await getCode(project, progress: progress)
        notes[projectID] = outcome.line
        await projects.forget(projectID)
        return outcome
    }

    private func getCode(_ project: PROJProject, progress: @escaping @Sendable (String) -> Void) async -> Outcome {
        guard let login = await account.login() else { return Outcome(ok: false, line: "Connect GitHub first") }
        var getting = ledger.getting(project.id)
        if getting == nil {
            let (row, _) = await projects.fresh(project)
            guard row.state == .codeNotHere, let folder = project.folders.first(where: { BackendProjectCode.waitingForCode($0, bounds: bounds()) }) else {
                return Outcome(ok: false, line: row.isRepository ? "The code is already on this Mac" : "Code not got: the project's folder holds other files")
            }
            let repositories = await account.repositories()
            guard let home = ledger.home(project.id) ?? Self.match(name: project.name, repositories: repositories, login: login) else {
                return Outcome(ok: false, line: "No GitHub home found for this project")
            }
            getting = BackendCodeBackupGetting(home: home, folder: folder, temporary: BackendCodeBackupGetCode.temporary(for: folder),
                                               startedAt: Int64(now().timeIntervalSince1970 * 1000))
            ledger.setGetting(project.id, getting)
        }
        guard let getting else { return Outcome(ok: false, line: "Code not got") }
        guard let transport = await account.transport(getting.home) else { return Outcome(ok: false, line: "Connect GitHub first") }
        do {
            let (branch, kept, large) = try await BackendCodeBackupGetCode(git: git, transport: transport, homeURL: "https://\(host)/\(getting.home).git",
                                                                    folder: getting.folder, temporary: getting.temporary, progress: progress).perform()
            ledger.setGetting(project.id, nil)
            ledger.setHome(project.id, getting.home)
            ledger.setKept(project.id, kept)
            var line = "Code is here" + (branch.map { " · branch \($0)" } ?? "")
            if large { line += " · " + Self.lfsLine }
            if let first = kept.first {
                line += kept.count == 1 ? " · kept your \(first) (it differs from GitHub's)" : " · kept \(kept.count) of your files that differ from GitHub's"
            }
            return Outcome(ok: true, line: line)
        } catch let failure as BackendCodeBackupGetCode.Failure {
            if failure.final {
                // Nothing to download (or nothing this app can place): no half-open download is left behind.
                ledger.setGetting(project.id, nil)
                try? FileManager.default.removeItem(atPath: getting.temporary)
            }
            return Outcome(ok: false, line: failure.plain)
        } catch {
            return Outcome(ok: false, line: "The download stopped. Get the code again to continue")
        }
    }

    // MARK: Automatic

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.lookSeconds))
                guard let self else { return }
                await self.look()
            }
        }
    }
    public func stop() { loop?.cancel(); loop = nil }

    /// One automatic look at every project set (or defaulted) to Automatic.
    public func look() async {
        guard network() else { return }
        guard let login = await account.login() else { return }
        let repositories = await account.repositories()
        for project in await projects.list() where !busy.contains(project.id) && ledger.getting(project.id) == nil {
            // Review 14 Nov: a project that is Manual or Off (stored, or Manual because no Back up now has finished on
            // this Mac yet) is not read at all; only one that may be Automatic is.
            let stored = ledger.mode(project.id)
            if stored == .manual || stored == .off || (stored == nil && !ledger.firstBackupDone) { seen[project.id] = nil; continue }
            let (row, places) = await projects.fresh(project)
            guard mode(project.id, home: row.home, repositories: repositories, login: login) == .automatic,
                  row.problem == nil, row.hasFolder, !row.waitingForCode else { seen[project.id] = nil; continue }
            var check = row; check.mode = .automatic
            let needs: Set<BackendCodeBackupProject.State> = [.commitsNotOnGitHub, .filesChanged, .setAside, .noHome]
            guard needs.contains(check.state) else { seen[project.id] = nil; continue }
            if places.contains(where: { BackendCodeBackupSend.gitBusy($0.gitDir) != nil }) { seen[project.id] = nil; continue }
            guard let mark = await Self.settleMark(project, row: row, places: places) else { continue }
            let at = now()
            if let before = seen[project.id], before.mark == mark {
                let settled = at.timeIntervalSince(before.since) >= Self.settleSeconds - 1
                let spaced = lastAutomatic[project.id].map { at.timeIntervalSince($0) >= Self.gapSeconds } ?? true
                if settled && spaced {
                    lastAutomatic[project.id] = at; seen[project.id] = nil
                    _ = await backUp(projectID: project.id, automatic: true)
                }
            } else {
                seen[project.id] = (mark, at)
            }
        }
    }

    /// What must stay the same for work to count as settled: the row's facts, Git's own change marks, and each changed
    /// file's size and modification time. Read-only.
    static func settleMark(_ project: PROJProject, row: BackendCodeBackupProject, places: [BackendCodeBackupGitReader.Place]) async -> String? {
        let parts = row.parts.isEmpty ? [row] : row.parts
        let topFolders = places.map(\.top)
        return await BackendCodeBackupFileSystem.run(5) {
            var text = BackendCodeBackupProjects.mark(project, places).joined(separator: "|")
            for (index, part) in parts.enumerated() {
                text += "#\(part.commitCount).\(part.changedCount).\(part.setAsideCount).\(part.lastCommitAt ?? 0)"
                let top = index < topFolders.count ? topFolders[index] : nil
                for name in part.changedFiles.prefix(BackendCodeBackupProject.listLimit) {
                    var info = stat()
                    let stamp = top.map { lstat($0 + "/" + name, &info) == 0 ? "\(info.st_size).\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" : "-" } ?? "?"
                    text += "|" + name + "@" + stamp
                }
            }
            return text
        }
    }
}

/// Names for a new GitHub home.
public enum BackendCodeBackupNames {
    /// The project's name as a GitHub repository name: letters, digits, '.', '_' and '-', lower case, at most 90.
    public static func repository(_ name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-") { out.unicodeScalars.append(scalar) }
            else if !out.hasSuffix("-") { out += "-" }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if out.isEmpty || out == "." || out == ".." { out = "project" }
        return String(out.prefix(90))
    }
    /// "name", then "name-2" … "name-9".
    public static func candidates(_ base: String) -> [String] { [base] + (2...9).map { base + "-\($0)" } }
    /// The description a new home carries, so another Mac of his finds it for "Get the code".
    public static func description(_ projectName: String) -> String { "Terminal Deck project: " + projectName }
}

/// A normal network: connected, not Low Data, not an expensive link (a phone's hotspot). Watched by the system.
public final class BackendCodeBackupNetwork: @unchecked Sendable {
    public static let shared = BackendCodeBackupNetwork()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var isNormal = false
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let normal = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            guard let self else { return }
            self.lock.withLock { self.isNormal = normal }
        }
        monitor.start(queue: DispatchQueue(label: "terminaldeck.code-backup.network", qos: .utility))
    }
    public var normal: @Sendable () -> Bool { { self.lock.withLock { self.isNormal } } }
}
