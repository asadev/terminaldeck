import Foundation
import TerminalDeckNativeCore

/// L5 slice 1 (owner, 14 Nov: "a place where we can see when last update happened to this specific project and code and
/// is it completely updated or not"). One project as the Code page and `code.projects` show it: names, dates and plain
/// words only. Never a token, an id on screen or a raw path (a folder is its name alone).
///
/// A project with several code folders keeps each one in `parts`; the project's own fields are then its WORST folder's,
/// so "Backed up" shows only when every folder is.
public struct BackendCodeBackupProject: Sendable, Equatable, Identifiable {
    public enum Visibility: String, Sendable, Equatable {
        case isPrivate = "private", isPublic = "public", notChecked = "not checked"
        public var word: String { switch self { case .isPrivate: "Private"; case .isPublic: "Public"; case .notChecked: "" } }
    }
    /// The one headline per project, most urgent first.
    public enum State: String, Sendable, Equatable {
        case commitsNotOnGitHub = "commits not on GitHub", filesChanged = "files changed", setAside = "set-aside changes not on GitHub",
             noHome = "no GitHub home yet", couldNotCheck = "could not check", secretsInCommits = "secret files in your commits",
             backedUp = "backed up", noFolder = "no code folder on this Mac",
             /// Project folders (14 Nov): the app made the project's folder for a project that came from the Cloud and
             /// its code has not been fetched here yet (only "Get the code", his click, fetches it).
             codeNotHere = "code not on this Mac yet",
             /// Slice 2: he set this project's backup to Off.
             backupOff = "backup off"
    }
    public struct Commit: Sendable, Equatable {
        public let subject: String
        public let at: Int64
        public init(subject: String, at: Int64) { self.subject = subject; self.at = at }
    }
    /// A file that is NOT on GitHub and cannot go there as it is.
    public struct Held: Sendable, Equatable {
        public enum Reason: String, Sendable, Equatable { case tooLarge = "too large", looksSecret = "secret file" }
        public let name: String
        public let reason: Reason
        public init(name: String, reason: Reason) { self.name = name; self.reason = reason }
    }

    /// The project's id: the row's identity only, never shown or returned to an AI. A part's id is its folder's name.
    public var id: String
    public var name: String
    /// The code folder's own name (its last part), never the path.
    public var folderName: String?
    public var hasFolder = false
    /// The folder is one the app made for a project that came from the Cloud and holds only what the Cloud put there
    /// (instruction files, the AI tools' folders): no code yet. Any other file there keeps the ordinary states.
    public var waitingForCode = false
    public var isRepository = false
    /// "owner/name" when the code's home is on GitHub.
    public var home: String?
    /// The remote's host when the code goes somewhere other than GitHub (then "on GitHub" reads "pushed").
    public var otherHost: String?
    public var visibility: Visibility = .notChecked
    /// The branch he is on; nil when a past version is checked out (no branch) or there is no repository.
    public var branch: String?
    /// The newest commit's time (ms), what "changed since" counts from.
    public var lastCommitAt: Int64?
    /// The newest commit of his that is on the home remote (ms): "last backed up".
    public var lastBackedUpAt: Int64?
    /// Files changed since the last commit (submodules included, .gitignore respected): the count and up to `listLimit` names.
    public var changedCount = 0
    public var changedFiles: [String] = []
    /// Commits on his branches that the home remote does not have: the count, and up to `listLimit`, newest first.
    public var commitCount = 0
    public var commits: [Commit] = []
    /// Work he set aside (git stash): it lives only on this Mac.
    public var setAsideCount = 0
    /// Files not on GitHub that cannot go as they are (over 50 MB, or a secret file never committed).
    public var held: [Held] = []
    /// Secret files that ARE in his last commit, so they go (or went) to GitHub with it.
    public var secretsInCommits: [String] = []
    /// Why it could not be checked, in plain words.
    public var problem: String?
    /// One entry per code folder when the project has more than one.
    public var parts: [BackendCodeBackupProject] = []
    /// Slice 2: the changed files are in the last backup of uncommitted work (taken at this time, ms); nil when the
    /// folder changed since or there was none.
    public var changesCoveredAt: Int64?
    /// Slice 2: every set-aside change is in the last backup.
    public var setAsideCovered = false
    /// Correction 14 Nov: his commits that are safe in the private backup references but NOT on his real GitHub
    /// branches (a backup never pushes his branches on a home he already had), and the branches they are on.
    public var privateCommitCount = 0
    public var privateBranches: [String] = []
    /// Slice 2: Automatic / Manual / Off for this project (the stored choice, else the default rule).
    public var mode: BackendCodeBackupMode = .manual
    /// Slice 2: for "Code not on this Mac yet", the GitHub home "Get the code" would use ("owner/name"); nil when none
    /// was found.
    public var getFrom: String?
    /// Slice 2: a "Get the code" started here and has not finished (it continues where it stopped).
    public var getting = false
    /// Slice 2: the last action's one line ("Backed up to …", "Not backed up: …").
    public var note: String?
    /// Review 14 Nov: the home is on an organisation's (or another person's) account: Back up now only, never Automatic.
    public var organisation: String?
    /// Review 14 Nov: Terminal Deck made this home; it holds only private references, so GitHub's page looks empty.
    public var madeHome = false
    /// Project secret files (14 Nov): held-back secret files of this project that travel with his saved passwords, by
    /// name, each with its one plain word ("travels with your saved passwords", "different on <Mac>, yours kept").
    public var secretsTravel: [String: String] = [:]
    /// Mac tidy (15 Nov, "from which Mac"): when THIS Mac last sent a backup of the project (ms) and this Mac's name as
    /// System Settings shows it. nil when this Mac never sent one; another Mac's backups are not read here yet.
    public var sentAt: Int64?
    public var sentFrom: String?
    /// Mac tidy: the GitHub page of the project's home ("https://github.com/owner/name"), for the row's link.
    public var homeLink: String?

    public static let listLimit = 200

    public init(id: String, name: String) { self.id = id; self.name = name }

    public var hasRemote: Bool { home != nil || otherHost != nil }
    /// The backup choices the row offers: an organisation's home has no Automatic.
    public var modeChoices: [BackendCodeBackupMode] { organisation == nil ? BackendCodeBackupMode.allCases : [.manual, .off] }

    public var state: State {
        if problem != nil { return .couldNotCheck }
        if !hasFolder { return .noFolder }
        if getting || (!isRepository && waitingForCode) { return .codeNotHere }
        if mode == .off { return .backupOff }
        if !isRepository || !hasRemote { return .noHome }
        if commitCount > 0 { return .commitsNotOnGitHub }
        if changedCount > 0 && changesCoveredAt == nil { return .filesChanged }
        if setAsideCount > 0 && !setAsideCovered { return .setAside }
        if !secretsInCommits.isEmpty { return .secretsInCommits }
        return .backedUp
    }

    /// Sorting: what needs him first.
    public var rank: Int {
        switch state {
        case .commitsNotOnGitHub: 0
        case .filesChanged: 1
        case .setAside: 2
        case .noHome: 3
        case .couldNotCheck: 4
        case .secretsInCommits: 5
        case .backedUp: held.isEmpty ? 7 : 6
        case .backupOff: 7
        case .codeNotHere: 8
        case .noFolder: 9
        }
    }
    public var needsAttention: Bool { rank <= 6 }

    /// Back up now shows only when something here is safe nowhere on GitHub yet (or there is no home yet) and backup is
    /// not Off. Commits already kept privately are "backed up": no button pushes his real branches for him.
    public var offersBackUp: Bool {
        guard mode != .off, otherHost == nil || parts.count > 1 else { return false }
        switch state {
        case .commitsNotOnGitHub, .filesChanged, .setAside, .noHome: return true
        default: return false
        }
    }

    /// A project from its folders: one folder is the project; several keep their own rows and the project shows the
    /// worst of them (ties: the first), with the OLDEST last backup (nil when any folder has none).
    static func combine(id: String, name: String, parts: [BackendCodeBackupProject]) -> BackendCodeBackupProject {
        guard let worst = parts.min(by: { $0.rank < $1.rank }) else { return BackendCodeBackupProject(id: id, name: name) }
        var row = worst
        row.id = id; row.name = name
        guard parts.count > 1 else { return row }
        let backed = parts.map(\.backedUpAt)
        row.lastBackedUpAt = backed.contains(where: { $0 == nil }) ? nil : backed.compactMap { $0 }.min()
        row.parts = parts
        return row
    }

    /// The same project with private/public filled in from GitHub's answers ("owner/name" lowercased).
    func filling(_ found: [String: Visibility]) -> BackendCodeBackupProject {
        var row = self
        row.visibility = home.flatMap { found[$0.lowercased()] } ?? .notChecked
        row.parts = parts.map { $0.filling(found) }
        return row
    }
    var homes: [String] { ([home] + parts.map(\.home)).compactMap { $0 } }

    /// The newest moment his work here is known to be on GitHub: his newest commit there, or the last backup of his
    /// uncommitted work when that still covers the folder.
    public var backedUpAt: Int64? {
        let covered = changedCount > 0 ? changesCoveredAt : nil
        switch (lastBackedUpAt, covered) {
        case let (a?, b?): return max(a, b)
        case let (a, b): return a ?? b
        }
    }
}

/// Everything the page and the tool show, read in one pass.
public struct BackendCodeBackupReport: Sendable, Equatable {
    public var projects: [BackendCodeBackupProject]
    /// nil until GitHub has answered once (the page then shows nothing about it).
    public var signedInToGitHub: Bool?
    public var checkedAt: Int64
    /// Lead, 14 Nov: no "Back up now" has finished on this Mac yet, so every project is still Manual here.
    public var automaticWaits = false
    public init(projects: [BackendCodeBackupProject], signedInToGitHub: Bool?, checkedAt: Int64) {
        self.projects = projects.sorted { $0.rank == $1.rank ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.rank < $1.rank }
        self.signedInToGitHub = signedInToGitHub; self.checkedAt = checkedAt
    }
}

/// The exact words, shared by the page and the tool. No explanatory sentences (owner, 14 Nov): a row is a name, one
/// state and at most one control.
public enum BackendCodeBackupWords {
    public static let title = "Code"
    /// Slice 2: without GitHub nothing on the page works, so this line and its one button are all it offers.
    public static let signInLine = "GitHub is not connected"
    public static let signInButton = "Connect GitHub"
    public static let refresh = "Refresh"
    public static let noProjects = "No projects yet"
    public static let changedTitle = "Changed since the last commit"
    public static let commitsTitle = "Commits not on GitHub"
    public static let setAsideTitle = "Set-aside changes"
    public static let heldTitle = "Can't go to GitHub as they are"
    public static let secretsInCommitsTitle = "Secret files in your commits"
    public static let notOnBranch = "No branch"
    public static let automaticWaits = "Automatic backup starts after your first Back up now on this Mac."
    public static let madeHomeLine = "Backed up privately. GitHub's page for this repository looks empty; that is expected."
    /// Mac tidy (15 Nov): signed in, code not here and no backup of it found on his GitHub.
    public static let notFoundOnGitHub = "Not on GitHub yet: Back up now on the Mac that has its code"
    /// The row's one line about its home, when there is something he must know.
    public static func homeLine(_ project: BackendCodeBackupProject) -> String? {
        if let organisation = project.organisation, let home = project.home {
            return "Home: \(home) (organisation): Back up now only; everyone in \(organisation) can see backups"
        }
        return project.madeHome ? madeHomeLine : nil
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }

    /// The row's one line. Headlines: "Backed up", "3 files changed since 22:14", "2 commits not on GitHub",
    /// "1 set-aside change not on GitHub", "1 secret file is in your commits", "Not on GitHub yet",
    /// "No code folder on this Mac", "Could not check (reason)"; extra facts follow after " · ". With several folders
    /// the worst folder's line is shown, led by its name ("app: 2 commits not on GitHub").
    public static func summary(_ project: BackendCodeBackupProject, now: Date, timeZone: TimeZone = .current) -> String {
        let line = own(project, now: now, timeZone: timeZone)
        guard project.parts.count > 1, let folder = project.folderName else { return line }
        return folder + ": " + line
    }

    static func own(_ project: BackendCodeBackupProject, now: Date, timeZone: TimeZone) -> String {
        switch project.state {
        case .couldNotCheck: return "Could not check (\(project.problem ?? "unknown reason"))"
        case .noFolder: return "No code folder on this Mac"
        case .codeNotHere: return project.getting ? "Getting the code stopped · continues where it stopped" : "Code not on this Mac yet"
        case .noHome: return "Not on GitHub yet"
        default: break
        }
        let backupOff = project.state == .backupOff
        var parts: [String] = []
        if project.commitCount > 0 {
            parts.append(plural(project.commitCount, "commit", "commits") + (project.home != nil ? " not on GitHub" : " not pushed"))
        }
        if project.changedCount > 0 && project.changesCoveredAt == nil {
            let files = plural(project.changedCount, "file", "files")
            parts.append(project.lastCommitAt.map { files + " changed since " + short($0, now: now, timeZone: timeZone) } ?? files + " not committed yet")
        }
        if project.setAsideCount > 0 && !project.setAsideCovered {
            parts.append(plural(project.setAsideCount, "set-aside change", "set-aside changes") + (project.home != nil ? " not on GitHub" : " not pushed"))
        }
        let committed = project.secretsInCommits.count
        if committed > 0 { parts.append(committed == 1 ? "1 secret file is in your commits" : "\(committed) secret files are in your commits") }
        if backupOff { parts.insert("Backup off", at: 0) }
        else if parts.isEmpty { parts.append(project.isRepository && project.hasRemote ? "Backed up" : "Not on GitHub yet") }
        // Correction 14 Nov: honest about his real GitHub branches; no button pushes them for him.
        if project.privateCommitCount > 0 {
            let commits = plural(project.privateCommitCount, "commit", "commits")
            let target = project.privateBranches.count == 1 ? project.privateBranches[0] : "your GitHub branches"
            parts.append(commits + " not pushed to " + target + ": backed up privately")
        }
        let large = project.held.filter { $0.reason == .tooLarge }.count
        let travelling = project.held.filter { $0.reason == .looksSecret && project.secretsTravel[$0.name].map(BackendProjectSecretFilesWords.travelling) == true }.count
        let secret = project.held.count - large - travelling
        if large > 0 { parts.append(plural(large, "file", "files") + " too large") }
        if secret > 0 { parts.append(plural(secret, "secret file", "secret files") + " not sent to GitHub") }
        // Project secret files: the held-back line becomes where they DO go.
        if travelling > 0 { parts.append(plural(travelling, "secret file", "secret files") + (travelling == 1 ? " travels" : " travel") + " with your saved passwords") }
        return parts.joined(separator: " · ")
    }

    /// "Last backed up Today, 22:14" / "Last backed up 13 Nov, 22:14" / "Never backed up"; empty without code here.
    public static func lastBackedUp(_ project: BackendCodeBackupProject, now: Date, timeZone: TimeZone = .current) -> String {
        guard project.hasFolder, project.problem == nil, project.isRepository, !project.getting else { return "" }
        // Mac tidy (15 Nov): "from which Mac", when the newest backup known here is the one this Mac sent.
        if let sent = project.sentAt, let mac = project.sentFrom, !mac.isEmpty, sent >= (project.backedUpAt ?? 0) {
            return "Last backed up " + when(sent, now: now, timeZone: timeZone) + " from " + mac
        }
        guard let at = project.backedUpAt else { return "Never backed up" }
        return "Last backed up " + when(at, now: now, timeZone: timeZone)
    }

    /// "Today, 22:14", "Yesterday, 09:05", "13 Nov, 22:14", "3 Mar 2025".
    public static func when(_ ms: Int64, now: Date, timeZone: TimeZone = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let time = format("HH:mm", date, timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, " + time }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return format("d MMM", date, timeZone) + ", " + time }
        return format("d MMM yyyy", date, timeZone)
    }

    /// "22:14" today, "13 Nov" earlier (the contracts' status-line style).
    public static func short(_ ms: Int64, now: Date, timeZone: TimeZone = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return format("HH:mm", date, timeZone) }
        return format(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "d MMM" : "d MMM yyyy", date, timeZone)
    }

    static func format(_ pattern: String, _ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB"); formatter.timeZone = timeZone; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    public static func reason(_ reason: BackendCodeBackupProject.Held.Reason) -> String {
        switch reason { case .tooLarge: "over 50 MB"; case .looksSecret: "secret file" }
    }
}
