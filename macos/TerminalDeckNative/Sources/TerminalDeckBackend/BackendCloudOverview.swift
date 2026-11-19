import Foundation
import TerminalDeckNativeCore

/// The ONE place on Settings → Cloud that says where this Mac stands with the Cloud, in plain words:
/// - what this Mac has saved and what is still going up ("1200 of 5000 saved; continues by itself at 14:05");
/// - whether this Mac has everything the Cloud holds, or is catching up;
/// - which devices wait to be trusted, each with its Trust button;
/// - what else waits on this Mac for the person (a file to accept, a permission change held, a project that needs a
///   folder, saved passwords that are locked).
/// It never reads "Up to date" while anything of that waits. One row each for memory, projects and agents, boot
/// files and saved passwords; a row that is not switched on is ABSENT (no greyed row, no notice).
///
/// A pure function of what the account, the sync core and the switched-on features already report. Nothing here
/// asks the network, a Keychain item or a file, and nothing here can trust, accept or unlock anything: an action
/// only names which of this Mac's own sheets the page opens.
public struct BackendCloudOverview: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case memory, projects, bootFiles, passwords
        /// Lane L3 (14 Nov): tasks (row I12) and his settings (row I21) travel too; one row each, state and count.
        case tasks, settings
        /// Lane L3 slice 1 (merged with the status line): his Cloud folder (row I24), counted under "Space used".
        case cloudFolder
        /// Lane L3 slice 2: his artifacts (row I23), counted under "Space used".
        case artifacts
    }
    public enum Standing: String, Sendable {
        case upToDate, needsYou, paused, unreachable, savingAndCatchingUp, saving, catchingUp, notReady
        /// Review B-M4: the person answered "Not now": Cloud is not used on this Mac (nothing sent, nothing received).
        case notUsed
        /// Review B-M3: a list of this Mac is not read yet. Unknown is never "Up to date".
        case checking
    }
    /// Which of this Mac's own sheets or presses a waiting line leads to. `none`: the line says where to look.
    public enum Action: Sendable, Equatable {
        case none
        case chooseDevices
        case trust(deviceId: String)
        case checkAgain
        case acceptFile(id: String)
        case chooseFolder(projectId: String)
        /// Decker's ruling on S2: pick which of this project's folders on this Mac gets its AI instruction files.
        case chooseBootFolder(projectId: String, folders: [String])
        case reviewApproval(id: String)
        /// Automatic trust: "Remove" on the notice of a device that joined by itself.
        case removeDevice(deviceId: String)
        /// Automatic trust: the one button for a device whose reported key changed.
        case trustAgain(deviceId: String)
    }
    /// One thing that waits on this Mac for the person.
    public struct Waiting: Sendable, Equatable, Identifiable {
        public let id: String
        public let text: String
        public let action: Action
        public init(id: String, text: String, action: Action = .none) {
            self.id = id
            self.text = text
            self.action = action
        }
    }
    public struct Row: Sendable, Equatable, Identifiable {
        public let kind: Kind
        public let title: String
        /// "214 items saved", "1200 of 5000 saved; continues by itself at 14:05", "Locked on this Mac" …
        public let state: String
        /// Smaller lines under the row: what is left out on purpose, what is kept as another version.
        public let notes: [String]
        /// Nothing of this row is going up, missing or waiting.
        public let settled: Bool
        public var id: String { kind.rawValue }
        public init(kind: Kind, title: String, state: String, notes: [String] = [], settled: Bool) {
            self.kind = kind
            self.title = title
            self.state = state
            self.notes = notes
            self.settled = settled
        }
    }
    public let standing: Standing
    /// The one headline: "Up to date", "2 things need you on this Mac", "Saving to your Cloud" …
    public let title: String
    /// Plain sentences under it: this Mac → Cloud, Cloud → this Mac.
    public let lines: [String]
    public let waiting: [Waiting]
    public let rows: [Row]
    /// Review B-M4: "Not now" was chosen on this Mac. The page shows `BackendCloudOverviewWords.notUsedHere` with a
    /// button that turns Cloud on here later.
    public let notUsedHere: Bool
    /// Automatic trust: plain, non-blocking notices ("<device> joined your account and is now trusted on this Mac.")
    /// with "Remove". They never make the headline say that something needs the person.
    public let notices: [Waiting]
    /// Page-names 2 (owner, 13 Nov: "needs you" is only what blocks his work and only he can do): what he can do here
    /// WHEN HE WANTS, never a task. One quiet line, and under it (a disclosure) one row per project by name, each with
    /// its own button. Never counted in the headline.
    public struct Later: Sendable, Equatable {
        public let summary: String
        public let items: [Waiting]
        public init(summary: String, items: [Waiting]) { self.summary = summary; self.items = items }
    }
    public let later: Later?
    /// What this version does not carry, said plainly on the page and in `cloud.status` (Decker's item 8).
    public var notSavedInThisVersion: [String] { BackendCloudOverviewWords.notSavedInThisVersion }
    public init(standing: Standing, title: String, lines: [String], waiting: [Waiting], rows: [Row], notUsedHere: Bool = false,
                notices: [Waiting] = [], later: Later? = nil) {
        self.notices = notices
        self.later = later
        self.standing = standing
        self.title = title
        self.lines = lines
        self.waiting = waiting
        self.rows = rows
        self.notUsedHere = notUsedHere
    }
    /// The same summary for `cloud.status`, so an agent reads what the person sees. State only.
    public var wireValue: NativeRPCValue {
        let waitingWire: [NativeRPCValue] = waiting.map { NativeRPCValue.string($0.text) }
        let rowWire: [NativeRPCValue] = rows.map { row in
            NativeRPCValue.object([.init("kind", .string(row.kind.rawValue)), .init("title", .string(row.title)), .init("state", .string(row.state)),
                                   .init("notes", .array(row.notes.map(NativeRPCValue.string))), .init("settled", .bool(row.settled))])
        }
        return .object([.init("standing", .string(standing.rawValue)), .init("title", .string(title)),
                        .init("lines", .array(lines.map(NativeRPCValue.string))),
                        .init("waitingForYou", .array(waitingWire)), .init("rows", .array(rowWire)),
                        .init("notices", .array(notices.map { NativeRPCValue.string($0.text) })),
                        .init("later", later.map { later in .object([.init("summary", .string(later.summary)),
                                                                      .init("items", .array(later.items.map { NativeRPCValue.string($0.text) }))]) } ?? .null),
                        .init("notSavedInThisVersion", .array(notSavedInThisVersion.map(NativeRPCValue.string)))])
    }
}

/// Everything the summary is built from. A part that is nil is not switched on: its row is absent.
public struct BackendCloudOverviewInput: Sendable {
    public struct Memory: Sendable, Equatable {
        /// The person's recorded choice to include this Mac's memory; nil = not asked yet.
        /// Review B-M4: true = Cloud is used on this Mac (both directions); false = "Not now": its memory, projects,
        /// agents and boot files are not sent, and none arrive here.
        public var included: Bool?
        public init(included: Bool?) { self.included = included }
    }
    /// What a switched-on feature of another lane (projects and agents, boot files) reports besides its coverage.
    public struct Feature: Sendable, Equatable {
        /// What waits on this Mac for the person, in that lane's own plain words.
        public var waiting: [BackendCloudOverview.Waiting]
        public var notes: [String]
        /// Review B-M3: the lane's lists are not read yet (just started). The row reads "Checking…", never settled.
        public var checking: Bool
        /// Review B-M3: the lane's lists could not be read. Said as a waiting line with Check again, never "nothing waits".
        public var couldNotCheck: Bool
        /// Proof 2 (13 Nov): how many files really wait on this Mac and why, said as the row's state when the sync core
        /// lists nothing for the row yet (never "No boot files to save" while files wait).
        public var waitingSummary: String?
        /// Page-names 2: what he can do here when he wants, never a task: a project without a folder on this Mac (by its
        /// name, with "Choose folder…"), a project whose instruction files go to the one of its folders he picks.
        public var later: [BackendCloudOverview.Waiting]
        /// Page-names 2: instruction files that are written once their project has a folder here (said once, beside the
        /// projects without a folder, never as a task and never twice).
        public var filesForFolders: Int
        /// Page-names 2: changes from another device to projects or agents that this Mac holds and does not apply.
        /// Said only under the stricter trust setting ("wait for your OK"); nothing is said when none is held.
        public var heldChanges: Int
        public init(waiting: [BackendCloudOverview.Waiting] = [], notes: [String] = [], checking: Bool = false, couldNotCheck: Bool = false,
                    waitingSummary: String? = nil, later: [BackendCloudOverview.Waiting] = [], filesForFolders: Int = 0, heldChanges: Int = 0) {
            self.waiting = waiting
            self.notes = notes
            self.checking = checking
            self.couldNotCheck = couldNotCheck
            self.waitingSummary = waitingSummary
            self.later = later
            self.filesForFolders = filesForFolders
            self.heldChanges = heldChanges
        }
        /// Just started: nothing read yet.
        public static let notReadYet = Feature(checking: true)
        /// The read failed.
        public static let unreadable = Feature(couldNotCheck: true)
    }
    public var snapshot: CloudAccountSnapshot
    /// The person has not yet answered the new-Mac sheet after signing in here.
    public var newMacPending: Bool
    public var memory: Memory?
    public var projects: Feature?
    public var bootFiles: Feature?
    /// Lane L3: tasks and settings travel (their owners are built for this account). nil = not switched on: no row.
    public var tasks: Feature?
    public var settings: Feature?
    public var passwords: BackendCloudSecretsPage?
    /// Review B-M3: saved passwords are wired but their first read has not come back (`passwords` is then nil).
    public var passwordsChecking: Bool
    /// "Automatically, with my account" (owner, 13 Nov): no Trust buttons; key changes and joins are said instead.
    public var automaticTrust: Bool = false
    /// Automatic trust: the devices whose "joined your account" notice is still shown (the composition decides).
    public var joined: [String] = []
    /// Page-names lane: the ONE source of the page's numbers, shared with the Your Cloud window. nil = not read yet:
    /// the rows then say "All saved" with no number, never a count of sync records.
    public var counts: BackendCloudPageCounts?
    /// Page-names 3 (real check 4): false while the page has not yet read this Mac's progress since it opened. The
    /// snapshot's queue, first copy, coverage and feed numbers are then from an earlier read: the summary says
    /// "Checking…" and no number of them, never "5 changes … still going up" for a queue that is long empty.
    public var progressRead: Bool = true
    public init(snapshot: CloudAccountSnapshot, newMacPending: Bool = false, memory: Memory? = nil, projects: Feature? = nil,
                bootFiles: Feature? = nil, passwords: BackendCloudSecretsPage? = nil, passwordsChecking: Bool = false) {
        self.snapshot = snapshot
        self.newMacPending = newMacPending
        self.memory = memory
        self.projects = projects
        self.bootFiles = bootFiles
        self.passwords = passwords
        self.passwordsChecking = passwordsChecking
    }
}

public enum BackendCloudOverviewWords {
    public static let upToDate = "Up to date"
    public static let paused = "Paused"
    public static let pausedLine = "Nothing is sent or fetched while Cloud is paused. Choose Resume to go on."
    public static let unreachable = "Can't reach Cloud right now"
    public static let saving = "Saving to your Cloud"
    public static let catchingUp = "Catching up with your Cloud"
    public static let savingAndCatchingUp = "Saving to your Cloud and catching up"
    public static let notReady = "Not ready yet"
    public static let checking = "Checking…"
    /// Decker's item 8: the list of what is not saved in this version, in plain words.
    public static let notSavedTitle = "Not saved in this version"
    public static let notSavedInThisVersion = [
        "Boot files travel only from each project's chosen folder.",
        "Your account-wide instruction files, skills and agents (the ones outside your projects) do not travel yet.",
        "API keys do not travel yet.",
    ]
    /// Review B-M3: a lane's list that could not be read on this Mac.
    public static func couldNotCheck(_ kind: BackendCloudOverview.Kind) -> String {
        switch kind {
        case .projects: return "Projects and agents could not be checked on this Mac. Choose Check again."
        case .bootFiles: return "Boot files could not be checked on this Mac. Choose Check again."
        case .memory: return "Memory could not be checked on this Mac. Choose Check again."
        case .tasks: return "Tasks could not be checked on this Mac. Choose Check again."
        case .settings: return "Settings could not be checked on this Mac. Choose Check again."
        case .cloudFolder: return "Your Cloud folder could not be checked on this Mac. Choose Check again."
        case .artifacts: return "Artifacts could not be checked on this Mac. Choose Check again."
        case .passwords: return passwordsUnchecked
        }
    }
    public static func needsYou(_ count: Int) -> String {
        count == 1 ? "1 thing needs you on this Mac" : "\(count) things need you on this Mac"
    }
    public static let allSaved = "Everything on this Mac is saved to your Cloud."
    public static let notAllSaved = "Some things on this Mac are not in your Cloud yet. They are listed below."
    public static let heldUp = "Sending is held up right now. It is tried again by itself; Sync now tries at once."
    public static func goingUp(_ count: Int) -> String {
        count == 1 ? "1 change on this Mac is still going up." : "\(count) changes on this Mac are still going up."
    }
    public static let level = "This Mac has everything your Cloud holds."
    public static let levelExceptUntrusted = "This Mac has everything your Cloud holds, except the changes that wait for a device you have not trusted."
    public static func behind(_ count: Int?) -> String {
        guard let count, count > 0 else { return "This Mac is catching up with your Cloud." }
        return count == 1 ? "This Mac is catching up with your Cloud: 1 change still to fetch."
                          : "This Mac is catching up with your Cloud: " + BackendCloudPageCounts.number(count) + " changes still to fetch."
    }
    public static let levelUnknown = "Not checked yet whether this Mac has everything your Cloud holds."
    public static func signedIn(_ name: String) -> String { "“" + name + "” signed in to your account." }
    public static func joined(_ name: String) -> String { "“" + name + "” joined your account and is now trusted on this Mac." }
    public static func keyChanged(_ name: String, waiting: Int) -> String {
        let what = waiting == 1 ? "1 change from it waits" : (waiting > 1 ? "\(waiting) changes from it wait" : "Its changes wait")
        return "“" + name + "” now signs its changes differently than when it joined. " + what + " on this Mac until you trust it again."
    }
    public static let chooseDevices = "Choose which of your devices this Mac trusts. Until you do, nothing of this Mac's own memory is sent."
    public static func device(name: String, waiting: Int, canBeTrusted: Bool) -> String {
        let who = "“" + name + "”"
        guard canBeTrusted else { return who + " is a new device that cannot be trusted right now. Look at it under Devices." }
        if waiting == 0 { return who + " is a new device. Its changes will wait until you trust it." }
        let count = waiting == 1 ? "1 change from it waits" : "\(waiting) changes from it wait"
        return who + " is a new device. " + count + " until you trust it."
    }
    public static func unlisted(_ count: Int) -> String {
        count == 1 ? "1 change from a device that is not on your device list waits on this Mac. It is not used."
                   : "\(count) changes from a device that is not on your device list wait on this Mac. They are not used."
    }
    /// The one line for packs this Mac could not check (design 3.3).
    public static func refused(_ count: Int) -> String {
        count == 1 ? "1 change from Cloud could not be checked and was not used."
                   : "\(count) changes from Cloud could not be checked and were not used."
    }
    public static func title(_ kind: BackendCloudOverview.Kind) -> String {
        switch kind {
        case .memory: return "Memory"
        case .projects: return "Projects and agents"
        case .bootFiles: return "Boot files"
        case .tasks: return "Tasks"
        case .settings: return "Settings"
        case .cloudFolder: return "Cloud folder"
        case .artifacts: return "Artifacts"
        case .passwords: return "Saved passwords"
        }
    }
    public static func saved(_ items: Int) -> String { items == 1 ? "1 item saved" : "\(items) items saved" }
    public static func savedSoFar(_ items: Int) -> String { items == 1 ? "1 item so far; still going up" : "\(items) items so far; still going up" }
    public static let starting = "Starting"
    /// 13 Nov leftover: the boot files lane is running and lists nothing at all: no chosen folder holds a boot file and
    /// none waits. That is the true state, not "Starting".
    public static let noBootFiles = "No boot files to save"
    public static let notComplete = "Not complete"
    /// Review B-M4: the ONE line for "Not now", both directions in words.
    public static let notUsedHere = "Cloud is not used on this Mac yet: its memory, projects, agents and boot files are not sent, and none arrive here."
    public static let notUsed = "Not used on this Mac"
    public static let memoryNotAsked = "Not started yet"
    public static let memoryAfterDevices = "Starts once you have chosen which devices this Mac trusts."
    public static let memoryAfterQuestion = "Starts once you have answered whether to use your Cloud on this Mac."
    /// Page-names lane (owner, 13 Nov): an optional feature is an offer, never a task. Said as a notice, never counted in
    /// "needs you", and true about what it does today (API keys do not travel yet).
    public static let passwordsNotSetUp = "Saved passwords are optional and off on this Mac. Turned on, your server, SSH and tool logins reach your other devices too. API keys do not travel yet."
    public static let passwordsOff = "Off on this Mac"
    /// Page-names 2: a failed check of saved passwords is not a task: one calm line with Check again.
    public static let passwordsNotChecked = "Saved passwords could not be checked on this Mac just now."
    /// Page-names 2: a list that could not be read is not a task either.
    public static func notChecked(_ kind: BackendCloudOverview.Kind) -> String {
        switch kind {
        case .projects: return "Projects and agents could not be checked on this Mac just now."
        case .bootFiles: return "Boot files could not be checked on this Mac just now."
        case .memory: return "Memory could not be checked on this Mac just now."
        case .tasks: return "Tasks could not be checked on this Mac just now."
        case .settings: return "Settings could not be checked on this Mac just now."
        case .cloudFolder: return "Your Cloud folder could not be checked on this Mac just now."
        case .artifacts: return "Artifacts could not be checked on this Mac just now."
        case .passwords: return passwordsNotChecked
        }
    }
    /// Page-names 2: projects from your Cloud without a folder on this Mac, said once and quietly.
    public static func projectsWithoutFolder(_ count: Int, files: Int) -> String {
        var line = count == 1 ? "1 project from your Cloud has no folder on this Mac yet. Choose a folder when you want to work on it here."
                              : BackendCloudPageCounts.number(count) + " projects from your Cloud have no folder on this Mac yet. Choose a folder when you want to work on one here."
        if files > 0 { line += " " + (count == 1 ? "Its " : "Their ") + filesWritten(files) }
        return line
    }
    /// "Their 293 instruction files are written when you choose a folder."
    static func filesWritten(_ files: Int) -> String {
        BackendCloudPageCounts.number(files) + (files == 1 ? " instruction file is" : " instruction files are") + " written when you choose a folder."
    }
    /// Page-names 2: instruction files that wait for a folder while no project here lacks one (another place of it).
    public static func filesWaitForFolder(_ files: Int) -> String {
        BackendCloudPageCounts.number(files) + (files == 1 ? " instruction file from your Cloud is" : " instruction files from your Cloud are")
            + " written on this Mac once their project has a folder here."
    }
    /// Page-names 2: a project with several folders here and none chosen for its instruction files: not a question.
    public static func severalFolders(_ count: Int) -> String {
        count == 1 ? "1 project has more than one folder on this Mac. Its instruction files are written in the folder you pick."
                   : BackendCloudPageCounts.number(count) + " projects have more than one folder on this Mac. Their instruction files are written in the folder you pick."
    }
    /// Page-names 2: under the stricter trust setting only, changes to projects and agents held for his OK.
    public static func heldForOK(_ count: Int) -> String {
        count == 1 ? "1 change to your projects or agents waits for your OK on this Mac."
                   : BackendCloudPageCounts.number(count) + " changes to your projects and agents wait for your OK on this Mac."
    }
    public static let passwordsLocked = "Saved passwords are locked on this Mac. Unlock them under Saved passwords."
    public static let passwordsGaps = "Some saved passwords on this Mac are not in your Cloud. They are listed under Saved passwords."
    /// Review B-M2: a failed or unreadable check of saved passwords is said as it is, never "ready".
    public static let passwordsUnchecked = "Saved passwords could not be checked on this Mac. Choose Check again."
    public static func passwordsServers(_ count: Int) -> String {
        count == 1 ? "1 MCP server from your other devices waits to be added under Saved passwords."
                   : "\(count) MCP servers from your other devices wait to be added under Saved passwords."
    }
    /// Mac-next 2: while the first copy is built on this Mac, nothing is held up: it says what it is doing.
    /// Page-names lane: once every change is prepared (n = m) it is not "Preparing" any more; it says what happens next.
    public static func preparing(_ progress: CloudBaselineProgress) -> String {
        let count = BackendCloudPageCounts.number
        guard preparingNow(progress) else { return BackendCloudPageWords.sending(progress.total) }
        return "Preparing the first copy: \(count(progress.sent)) of \(count(progress.total)) changes"
    }
    /// Preparation is really running: the first copy is marked as being prepared and not every change of it is ready.
    /// Sync now is disabled only then (both Cloud views ask this one question).
    public static func preparingNow(_ progress: CloudBaselineProgress?) -> Bool {
        guard let progress, progress.preparing == true else { return false }
        return progress.total <= 0 || progress.sent < progress.total
    }
    /// Proof 3 (13 Nov): "Sync now" while this Mac prepares its first copy: disabled, and this is its tooltip. Also
    /// what a press says when this Mac's sync is busy with another step of its own (not a failure).
    public static let busyHere = "This Mac is still busy with another Cloud step. It continues by itself."
    public static func syncNowWhilePreparing(_ progress: CloudBaselineProgress?) -> String {
        guard let progress, preparingNow(progress) else { return busyHere }
        return preparing(progress) + ". Sending starts by itself when it is ready."
    }
    static func day(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(date: .abbreviated, time: .omitted)
    }
    /// This Mac's first save, honestly: how far it is and, when it is paused, when it goes on by itself.
    public static func baseline(_ progress: CloudBaselineProgress, now: Date = Date(), calendar: Calendar = .current) -> String {
        if progress.preparing == true { return preparing(progress) }
        let count = BackendCloudPageCounts.number
        var line = "\(count(progress.sent)) of \(count(progress.total)) changes saved"
        if progress.filesWaiting > 0 { line += progress.filesWaiting == 1 ? ", 1 file still to send" : ", \(progress.filesWaiting) files still to send" }
        if let until = progress.waitingUntil {
            let resume = Date(timeIntervalSince1970: Double(until) / 1000)
            // 14 Nov: waits are short (minutes), never "tomorrow": the time it goes on by itself, or "in a moment".
            if resume <= now { line += "; continues in a moment" }
            else { line += "; continues by itself at " + resume.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)) }
        }
        if let reason = progress.reason, !reason.isEmpty { line += ". " + reason }
        return line
    }
}

public enum BackendCloudOverviewBuilder {
    /// Which inventory rows belong to which row of the summary.
    public static func inventory(_ kind: BackendCloudOverview.Kind) -> Set<String> {
        switch kind {
        case .memory: return Set(CloudBrainMemoryFormat.inventoryRows)
        case .projects: return ["I10", "I11"]
        case .bootFiles: return [CloudBootFilesFormat.inventoryRow, CloudProjectFoldersRules.inventoryRow]
        case .tasks: return [BackendCloudKinds.tasksRow]
        case .settings: return [BackendCloudKinds.settingsRow]
        case .cloudFolder: return [CloudFolderFormat.inventoryRow]
        case .artifacts: return [CloudArtifactsFormat.inventoryRow]
        case .passwords: return []
        }
    }
    private static func unique(_ lines: [String]) -> [String] {
        var seen: Set<String> = [], kept: [String] = []
        for line in lines where !line.isEmpty && seen.insert(line).inserted { kept.append(line) }
        return kept
    }
    /// 13 Nov blocker: "not finished" / "waiting" lines say what they wait for (the newest sync failure, in plain words).
    static func explainWaiting(_ line: String) -> String {
        let finished = "The first saved copy is not finished.", verified = "Waiting for a verified snapshot."
        guard line == finished || line == verified else { return line }
        let failure = CloudSyncDiagnostics.shared.lastReason
        if line == finished {
            return "The first saved copy is not finished. " + (failure ?? "It is still being made on this Mac and sent to your Cloud; this can take a few minutes.")
        }
        // A part that has no setup of its own (boot files) also carries this gap: say it plainly, and why only on a failure.
        return "Waiting for your Cloud to confirm this part." + (failure.map { " " + $0 } ?? "")
    }
    /// One row whose state comes from the sync core's coverage of its inventory rows.
    private static func coverageRow(_ kind: BackendCloudOverview.Kind, snapshot: CloudAccountSnapshot, sending: Bool, firstSave: String?,
                                    extraNotes: [String], extraWaiting: Bool, waitingSummary: String? = nil,
                                    counts: BackendCloudPageCounts? = nil) -> (row: BackendCloudOverview.Row, reasons: [String], complete: Bool) {
        let wanted = inventory(kind)
        let all = snapshot.coverage.filter { wanted.contains($0.inventoryRow) }
        // Page-names 2: boot files that wait for their project's folder here are in your Cloud already; nothing of
        // this Mac is missing from it. They are said once, beside the projects without a folder, never as "Not complete".
        let coverage = all.filter { !BackendCloudPageCounts.isWaitingForFolder($0) }
        let folderFiles = all.filter(BackendCloudPageCounts.isWaitingForFolder).reduce(0) { $0 + $1.items }
        var counts = counts
        if kind == .bootFiles, folderFiles > 0 {
            var known = counts ?? BackendCloudPageCounts()
            known.waitingForFolder = folderFiles
            counts = known
        }
        // Boot files list nothing while no chosen folder holds one and none waits: nothing to save is complete.
        let nothingHere = coverage.isEmpty && kind == .bootFiles
        let complete = nothingHere || (!coverage.isEmpty && coverage.allSatisfy { $0.complete })
        let reasons = unique(coverage.flatMap { $0.blockedReasons })
        // Left out on purpose (reported by the sync core and by the memory store): said, never counted as missing.
        let leftOut: [String] = coverage.flatMap { $0.exclusions }
        let named: [String] = coverage.compactMap { BackendCloudBrainMemoryExclusions.note($0.inventoryRow) }
        // Page-names lane: key names, file names and paths never reach the page; settings kept here are one count.
        var notes = BackendCloudPageWords.plainNotes(unique(extraNotes + leftOut + named))
        // Page-names 2: never a smaller number than the memory itself without a word why.
        if kind == .memory, let missing = counts?.missingLine { notes.append(missing) }
        let state: String
        var settled = false
        if nothingHere, let waitingSummary { state = waitingSummary }
        else if nothingHere, folderFiles > 0, let counts { state = counts.folderLine; settled = !extraWaiting }
        else if nothingHere { state = BackendCloudOverviewWords.noBootFiles; settled = !extraWaiting }
        else if coverage.isEmpty { state = BackendCloudOverviewWords.starting }
        // Page-names lane: counted in the person's own units from the one shared source, never in sync records.
        // Page-names 2: "All saved" only when nothing of this part is still arriving; otherwise what is happening.
        else if complete, let adding = counts?.addingLine(kind) { state = adding }
        else if complete { state = counts?.savedLine(kind) ?? BackendCloudPageWords.allSaved; settled = !extraWaiting }
        else if sending { state = firstSave ?? BackendCloudPageWords.stillGoingUp }
        else { state = BackendCloudOverviewWords.notComplete }
        // What keeps it from being complete is said only when it is not simply "still going up".
        let said = (complete || sending) ? [] : reasons.map(explainWaiting).map(BackendCloudPageWords.plainWords)
        return (BackendCloudOverview.Row(kind: kind, title: BackendCloudOverviewWords.title(kind), state: state, notes: notes, settled: settled), said, complete)
    }

    /// nil when there is nothing to say: no row is switched on and nothing waits.
    public static func build(_ input: BackendCloudOverviewInput, now: Date = Date(), calendar: Calendar = .current) -> BackendCloudOverview? {
        let snapshot = input.snapshot
        var waiting: [BackendCloudOverview.Waiting] = []
        var rows: [BackendCloudOverview.Row] = []

        // 1. Devices that wait to be trusted, each with its Trust button.
        if input.newMacPending {
            waiting.append(.init(id: "choose-devices", text: BackendCloudOverviewWords.chooseDevices, action: .chooseDevices))
        }
        var listed = 0
        var notices: [BackendCloudOverview.Waiting] = []
        for device in snapshot.trust where device.standing == .new {
            listed += device.waiting
            // 13 Nov leftover: an earlier entry of a device that signed in again (this Mac's own included) is neither
            // shown nor trusted, in either trust mode. Its waiting changes are counted here so no other line names them.
            guard !device.stale else { continue }
            // A device Cloud reports as removed is named only while something from it still waits here.
            guard device.waiting > 0 || !device.removed else { continue }
            // Automatic trust: a device still new here could not be trusted by itself; there is no Trust button.
            let offer = device.canBeTrusted && !input.automaticTrust
            waiting.append(.init(id: "device:" + device.deviceId,
                                 text: BackendCloudOverviewWords.device(name: device.name, waiting: device.waiting, canBeTrusted: offer),
                                 action: offer ? .trust(deviceId: device.deviceId) : .none))
        }
        if input.automaticTrust {
            for device in snapshot.trust where device.standing == .trusted && device.keyChanged {
                listed += device.waiting
                guard !device.stale else { continue }
                waiting.append(.init(id: "key:" + device.deviceId, text: BackendCloudOverviewWords.keyChanged(device.name, waiting: device.waiting),
                                     action: device.removed || device.sameKey || device.sameCode ? .none : .trustAgain(deviceId: device.deviceId)))
            }
            for device in snapshot.trust where device.standing == .trusted && device.byAccount && !device.keyChanged && !device.stale && input.joined.contains(device.deviceId) {
                // MAC-NEXT-11: a phone or a browser only reads; under automatic trust its notice is one calm line.
                let viewer = snapshot.devices.first { $0.deviceId == device.deviceId }?.isViewer == true
                notices.append(.init(id: "joined:" + device.deviceId, text: viewer ? BackendCloudOverviewWords.signedIn(device.name) : BackendCloudOverviewWords.joined(device.name),
                                     action: .removeDevice(deviceId: device.deviceId)))
            }
        }
        if snapshot.heldChanges > listed {
            // MAC-NEXT-7 (7): only the stricter trust setting makes this something he must do. Under automatic trust
            // it is a plain notice, never counted in "n things need you".
            let line = BackendCloudOverview.Waiting(id: "held-unlisted", text: BackendCloudOverviewWords.unlisted(snapshot.heldChanges - listed))
            if input.automaticTrust { notices.append(line) } else { waiting.append(line) }
        }
        if let notice = snapshot.trustNotice { waiting.append(.init(id: "trust-notice", text: notice)) }
        if snapshot.refusedPacks > 0 {
            waiting.append(.init(id: "refused", text: BackendCloudOverviewWords.refused(snapshot.refusedPacks), action: .checkAgain))
        }

        // 2. The rows. `sending`: something of this Mac is on its way up right now.
        // Page-names 3: before the page's first read of this Mac's progress none of these numbers is current.
        let progressRead = input.progressRead
        let sending = progressRead && (snapshot.baseline != nil || snapshot.waitingRecords > 0)
        let firstSave = progressRead ? snapshot.baseline.map { BackendCloudOverviewWords.baseline($0, now: now, calendar: calendar) } : nil
        // Review B-M1: true when ANY row of this Mac travels through the sync core: memory, projects and agents,
        // boot files AND saved passwords (protected). Only then do "still going up" and "still to fetch" count, so
        // a saved password on its way up or still to fetch never reads as "Up to date".
        var sendsAnything = false
        // Of the rows that travel: is every one of them wholly in Cloud, and is any of them short of it for a
        // reason other than "still going up"?
        var everyRowComplete = true, someRowShort = false
        var notUsedHere = false
        // Review B-M3: a list not read yet is unknown, and unknown is never "Up to date".
        var checking = false
        if let memory = input.memory {
            let title = BackendCloudOverviewWords.title(.memory)
            if memory.included == true {
                sendsAnything = true
                let made = coverageRow(.memory, snapshot: snapshot, sending: sending, firstSave: firstSave, extraNotes: [], extraWaiting: false,
                                       counts: input.counts)
                if progressRead {
                    rows.append(made.row)
                    if !made.complete { everyRowComplete = false }
                    if made.row.state == BackendCloudOverviewWords.notComplete { someRowShort = true }
                    for (index, reason) in made.reasons.enumerated() { waiting.append(.init(id: "memory:\(index)", text: reason)) }
                } else {
                    checking = true
                    rows.append(.init(kind: .memory, title: title, state: BackendCloudOverviewWords.checking, settled: false))
                }
            } else if memory.included == false {
                // Review B-M4: "Not now" stops BOTH directions. No memory row: one line says so, with a button.
                notUsedHere = true
            } else {
                let note = input.newMacPending ? BackendCloudOverviewWords.memoryAfterDevices : BackendCloudOverviewWords.memoryAfterQuestion
                rows.append(.init(kind: .memory, title: title, state: BackendCloudOverviewWords.memoryNotAsked, notes: [note], settled: false))
            }
        }
        let features: [(BackendCloudOverview.Kind, BackendCloudOverviewInput.Feature?)] = [(.projects, input.projects), (.bootFiles, input.bootFiles)]
        var laterItems: [BackendCloudOverview.Waiting] = []
        var filesForFolders = 0
        for (kind, feature) in features {
            guard let feature else { continue }
            sendsAnything = true
            let unsure = feature.checking || feature.couldNotCheck
            let made = coverageRow(kind, snapshot: snapshot, sending: sending, firstSave: nil, extraNotes: feature.notes,
                                   extraWaiting: !feature.waiting.isEmpty || unsure || feature.waitingSummary != nil,
                                   waitingSummary: feature.waitingSummary, counts: input.counts)
            if feature.checking || !progressRead {
                checking = true
                rows.append(.init(kind: kind, title: made.row.title, state: BackendCloudOverviewWords.checking, notes: made.row.notes, settled: false))
            } else {
                rows.append(made.row)
            }
            if !made.complete { everyRowComplete = false }
            if made.row.state == BackendCloudOverviewWords.notComplete { someRowShort = true }
            // Page-names 2: a list that could not be read is not a task: one calm line with Check again.
            if feature.couldNotCheck {
                notices.append(.init(id: kind.rawValue + ":unchecked", text: BackendCloudOverviewWords.notChecked(kind), action: .checkAgain))
            }
            waiting += feature.waiting
            laterItems += feature.later
            filesForFolders += feature.filesForFolders
            // Under the stricter trust setting only; with automatic trust his own devices' changes are applied by
            // themselves and nothing is said (and nothing at all when none is held).
            if feature.heldChanges > 0, !input.automaticTrust {
                waiting.append(.init(id: kind.rawValue + ":held", text: BackendCloudOverviewWords.heldForOK(feature.heldChanges)))
            }
            if progressRead {
                for (index, reason) in made.reasons.enumerated() { waiting.append(.init(id: kind.rawValue + ":\(index)", text: reason)) }
            }
        }
        // Project folders (owner, 14 Nov): a project from the Cloud gets its folder by itself, so the Cloud page says
        // nothing about folders: no paragraph, no "choose a folder", no list of projects without one, whether they are
        // waiting for the first pass or have just got their folders. The only folder words anywhere are the calm
        // one-line states on the project itself ("Folder not on this Mac", the drive or full-disk line). The lanes'
        // facts stay data (`feature.later`, `filesForFolders`) for agents; the page never shows them.
        _ = (laterItems, filesForFolders)
        let later: BackendCloudOverview.Later? = nil
        // Lane L3 (owner, 14 Nov: Settings → Cloud had no Tasks and no Settings row while both travel): one row each, in
        // the same form as the others (state · count). What keeps either from being complete is said on its row, never
        // as something that needs him. Kinds-state (14 Nov, Mac mini: "Not ready yet" over "Everything on this Mac is
        // saved"): these rows are part of the SAME facts as every other row, so the sentences and the headline are made
        // from one set of facts and can never say opposite things. A value that stays different on two Macs, or stays on
        // one Mac by rule, is not a gap (the owner lists it as kept, never as missing), so it never makes a row short.
        let travelling: [(BackendCloudOverview.Kind, BackendCloudOverviewInput.Feature?)] = [(.tasks, input.tasks), (.settings, input.settings)]
        for (kind, feature) in travelling {
            guard let feature else { continue }
            sendsAnything = true
            let made = coverageRow(kind, snapshot: snapshot, sending: sending, firstSave: nil, extraNotes: feature.notes,
                                   extraWaiting: false, counts: input.counts)
            if feature.checking || !progressRead {
                checking = true
                rows.append(.init(kind: kind, title: made.row.title, state: BackendCloudOverviewWords.checking, settled: false))
                continue
            }
            // A real, lasting failure (the service refusing a record, this Mac unable to write) is said under its row in
            // plain words, never as a task; "Not complete" is the row's one state for it.
            let why = made.reasons.filter(BackendCloudPageWords.isPlain)
            rows.append(why.isEmpty ? made.row : .init(kind: kind, title: made.row.title, state: made.row.state,
                                                       notes: made.row.notes + why, settled: made.row.settled))
            if !made.complete { everyRowComplete = false }
            if made.row.state == BackendCloudOverviewWords.notComplete { someRowShort = true }
        }
        if input.passwords == nil, input.passwordsChecking {
            checking = true
            rows.append(.init(kind: .passwords, title: BackendCloudOverviewWords.title(.passwords), state: BackendCloudOverviewWords.checking, settled: false))
        }
        if let page = input.passwords {
            var settled = false
            switch page.standing {
            // Page-names 2: a failed check is not a task: one calm line with Check again, never counted.
            case .unknown, .cannotCheck:
                notices.append(.init(id: "passwords:unchecked", text: BackendCloudOverviewWords.passwordsNotChecked, action: .checkAgain))
            // Page-names 2 (Mac mini: "Off on this Mac" and, lower, "Not set up yet"): one state, said by the row; the
            // one sentence about it is said once, in the Saved passwords part below (`BackendCloudSecretsWords.advice`).
            case .notSetUp: break
            // On by default (owner, 14 Nov; his page rule): "Opening…" and the dead-state line are the row's one state,
            // never a second line or a task.
            case .locked:
                if !page.opensBySelf && !page.cannotOpen { waiting.append(.init(id: "passwords:locked", text: BackendCloudOverviewWords.passwordsLocked)) }
            case .waitingForCloud: waiting.append(.init(id: "passwords:waiting", text: CloudSecretsProtection.waitingAdvice))
            case .startedAnew(let text), .keyBlocked(let text), .loginStoreBlocked(let text), .keyLost(let text):
                waiting.append(.init(id: "passwords:blocked", text: text))
            case .protected:
                // Saved passwords travel through the same sync core, in both directions (review B-M1).
                sendsAnything = true
                if !page.gaps.isEmpty { waiting.append(.init(id: "passwords:gaps", text: BackendCloudOverviewWords.passwordsGaps)) }
                for approval in page.approvals {
                    waiting.append(.init(id: "passwords:approval:" + approval.id, text: BackendCloudSecretsWords.approval, action: .reviewApproval(id: approval.id)))
                }
                let servers = page.waiting.filter { !$0.removed }.count
                if servers > 0 { waiting.append(.init(id: "passwords:servers", text: BackendCloudOverviewWords.passwordsServers(servers))) }
                if page.couldNotCheck {
                    notices.append(.init(id: "passwords:unchecked", text: BackendCloudOverviewWords.passwordsNotChecked, action: .checkAgain))
                }
                settled = page.gaps.isEmpty && page.approvals.isEmpty && servers == 0 && !page.couldNotCheck
            }
            // Page-names 3 (real check 4: "Saved passwords / Off on this Mac" still sat above the one sentence): while
            // saved passwords are not set up the summary has NO row for them. Their own section says it, once: one
            // sentence and "Turn on".
            if case .notSetUp = page.standing {} else {
                rows.append(.init(kind: .passwords, title: BackendCloudOverviewWords.title(.passwords), state: BackendCloudSecretsWords.state(page), settled: settled))
            }
        }
        guard !rows.isEmpty || !waiting.isEmpty || notUsedHere || !notices.isEmpty || later != nil else { return nil }

        // 3. The two directions, in plain sentences. Only when something of this Mac travels at all.
        var lines: [String] = []
        if notUsedHere { lines.append(BackendCloudOverviewWords.notUsedHere) }
        let heldUp = progressRead && sendsAnything && snapshot.blockedRecords > 0 && snapshot.baseline == nil
        if snapshot.phase == .paused { lines.append(BackendCloudOverviewWords.pausedLine) }
        if let problem = snapshot.problem { lines.append(problem) }
        let preparingCopy = sendsAnything && progressRead && snapshot.baseline?.preparing == true ? firstSave : nil
        // Page-names lane: what has arrived but is not in this Mac's memory yet is its own state, never "on this Mac".
        let arriving = sendsAnything && progressRead ? input.counts?.arrivingLine : nil
        if sendsAnything && progressRead {
            if let preparingCopy { lines.append(preparingCopy) }
            else if let firstSave { lines.append("This Mac's first save: " + firstSave + (firstSave.hasSuffix(".") ? "" : ".")) }
            else if snapshot.waitingRecords > 0 { lines.append(BackendCloudOverviewWords.goingUp(snapshot.waitingRecords)) }
            else if everyRowComplete { lines.append(BackendCloudOverviewWords.allSaved) }
            else if someRowShort { lines.append(BackendCloudOverviewWords.notAllSaved) }
            if heldUp { lines.append(BackendCloudOverviewWords.heldUp) }
            switch snapshot.catchingUp {
            case .some(true): lines.append(BackendCloudOverviewWords.behind(snapshot.behindBy))
            case .some(false) where arriving != nil: break
            case .some(false): lines.append(snapshot.heldChanges > 0 ? BackendCloudOverviewWords.levelExceptUntrusted : BackendCloudOverviewWords.level)
            case .none: lines.append(BackendCloudOverviewWords.levelUnknown)
            }
            if let arriving { lines.append(arriving) }
        }

        // 4. The headline. "Up to date" only when nothing is going up, nothing is to fetch, nothing waits and
        // every row is settled.
        let goingUp = sendsAnything && (sending || heldUp)
        let behind = sendsAnything && progressRead && (snapshot.catchingUp == true || arriving != nil)
        let standing: BackendCloudOverview.Standing
        if snapshot.phase == .paused { standing = .paused }
        else if !waiting.isEmpty { standing = .needsYou }
        else if snapshot.problem != nil { standing = .unreachable }
        else if goingUp && behind { standing = .savingAndCatchingUp }
        else if goingUp { standing = .saving }
        else if behind { standing = .catchingUp }
        else if checking { standing = .checking }
        else if notUsedHere && rows.isEmpty { standing = .notUsed }
        // One source (kinds-state, 14 Nov): every row that travels is in `everyRowComplete`, which also decides "Everything
        // on this Mac is saved", so "Not ready yet" never stands over that sentence because of a row it did not count.
        else if rows.contains(where: { !$0.settled }) || (sendsAnything && (!everyRowComplete || snapshot.catchingUp == nil)) { standing = .notReady }
        else { standing = .upToDate }
        var title: String
        switch standing {
        case .upToDate: title = BackendCloudOverviewWords.upToDate
        case .needsYou: title = BackendCloudOverviewWords.needsYou(waiting.count)
        case .paused: title = BackendCloudOverviewWords.paused
        case .unreachable: title = BackendCloudOverviewWords.unreachable
        case .savingAndCatchingUp: title = BackendCloudOverviewWords.savingAndCatchingUp
        case .saving: title = BackendCloudOverviewWords.saving
        case .catchingUp: title = BackendCloudOverviewWords.catchingUp
        case .notReady: title = BackendCloudOverviewWords.notReady
        case .checking: title = BackendCloudOverviewWords.checking
        case .notUsed: title = BackendCloudOverviewWords.notUsed
        }
        // Proof 3 (13 Nov): while this Mac prepares its first copy, that IS the headline: "Preparing the first copy:
        // 31,400 of 56,500", with no "held up" line and no count of things that need the person for it.
        if let preparingCopy, [.saving, .savingAndCatchingUp].contains(standing) {
            title = preparingCopy
            lines.removeAll { $0 == preparingCopy }
        }
        return BackendCloudOverview(standing: standing, title: title, lines: lines, waiting: waiting, rows: rows, notUsedHere: notUsedHere, notices: notices,
                                    later: later)
    }
}
