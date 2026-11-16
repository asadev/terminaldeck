import AppKit
import CryptoKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// A project with more than one folder on this Mac and none chosen yet for its AI instruction files.
struct NativeCloudBootChoice: Sendable, Equatable {
    let projectId: String
    let name: String
    let folders: [String]
}

/// Where boot files may be read and written on this Mac (lean scope item 8). Lane F walks only what it is given.
///
/// Decker's ruling on review S2 (the chosen folder): per project, THIS Mac keeps the ONE folder that gets the
/// project's AI instruction files. It is machine-local (a file in this identity's Cloud folder on this Mac) and never
/// travels; folder paths never arrive from the Cloud.
/// - A project with exactly ONE folder on this Mac: that folder is the chosen one; it is stored and passed with
///   `chosen: true`. This also holds on the Mac the project was made on, so changes coming back land without a click.
/// - More than one folder and nothing stored: passed with `chosen: false` (lane F lists its files as waiting,
///   `no-chosen-folder`) and the Cloud page asks "Choose which folder gets this project's AI instruction files".
/// - Once stored, adding folders never moves it (the registry sorts folders, so "the first" is never used). If the
///   stored folder is no longer one of the project's folders, the choice is dropped and the rules above apply again.
/// - A project that arrived through Cloud and has no folder here yet gets no place: its boot files wait.
/// NOT given in this version: the AI account homes (`~/.claude`, `~/.codex`, `~/.gemini`, the app's own account
/// folders). Proof P3 runs scratch copies on the person's own Mac, and a boot file must never be written into a
/// real provider home from a scratch copy; they are added once a proof can run them against homes of its own.
enum NativeCloudBootPlaces {
    struct Found: Sendable, Equatable {
        var places: [BackendCloudBootFilesPlace]
        var choices: [NativeCloudBootChoice]
        /// project id → the chosen folder, as it should be stored now.
        var stored: [String: String]
    }
    /// This Mac's own record of the chosen folders, beside this identity's other Cloud state. Never sent anywhere.
    nonisolated static func choicesFile(dataRoot: URL, subjectHash: String) -> URL {
        NativeCloudLaunch.folder(dataRoot).appendingPathComponent(subjectHash, isDirectory: true).appendingPathComponent("boot-folders.json")
    }
    nonisolated static func read(_ file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file), let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }
    /// Written only inside the account folder the signed-in assembly already created.
    nonisolated static func write(_ map: [String: String], to file: URL) {
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path), let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: file, options: .atomic)
    }
    /// The person picked `folder` for `projectId` on the Cloud page. Only one of that project's own folders is kept.
    nonisolated static func choose(projectId: String, folder: String, among folders: [String], file: URL) -> Bool {
        guard folders.contains(folder), folder.hasPrefix("/") else { return false }
        var map = read(file)
        map[projectId] = folder
        write(map, to: file)
        return true
    }
    static func current(file: URL) async -> Found {
        guard let registry = BackendPROJRegistry.installed, let projects = try? await registry.projects() else { return Found(places: [], choices: [], stored: [:]) }
        let stored = read(file)
        let found = decide(projects, stored: stored)
        if found.stored != stored { write(found.stored, to: file) }
        return found
    }
    nonisolated static func decide(_ projects: [PROJProject], stored: [String: String]) -> Found {
        var found = Found(places: [], choices: [], stored: [:])
        var seen: Set<String> = []
        for project in projects where project.id != PROJProjects.independentID && !project.id.isEmpty {
            guard seen.insert(project.id).inserted else { continue }
            let folders = project.folders.filter { $0.hasPrefix("/") }
            var chosen: String?
            if let kept = stored[project.id], folders.contains(kept) { chosen = kept }
            if chosen == nil, folders.count == 1 { chosen = folders[0] }
            if let chosen {
                found.stored[project.id] = chosen
                found.places.append(BackendCloudBootFilesPlace(kind: .project, identity: project.id, root: URL(fileURLWithPath: chosen, isDirectory: true), chosen: true))
            } else if let first = folders.first {
                // Not chosen: lane F does not use it, and its files wait (`no-chosen-folder`) until the person picks one.
                found.places.append(BackendCloudBootFilesPlace(kind: .project, identity: project.id, root: URL(fileURLWithPath: first, isDirectory: true), chosen: false))
                found.choices.append(NativeCloudBootChoice(projectId: project.id, name: project.name, folders: folders))
            }
        }
        return found
    }
}

/// What the Cloud page and the `cloud.boot_files` tool know of boot files (lane F) for the signed-in identity, and
/// the ONE way a file that can run a command is accepted: the accept sheet in this Mac's own window. Empty while
/// the row is not switched on: the summary's row, the sheet and the tool are then absent.
@MainActor
final class NativeCloudBoot {
    static let shared = NativeCloudBoot()
    static let toolOwner = "cloud-boot-files"
    static let notWritten = "The file could not be written on this Mac. Nothing was changed. It stays on the list."
    /// Security review M3: without the exact bytes there is no sheet, so nothing is ever accepted blind.
    static let notReadable = "The file could not be read on this Mac, so it cannot be accepted now. Nothing was changed."
    static let changed = "That file changed or no longer waits. The list on the Cloud page is up to date again."
    private(set) var boot: BackendCloudBootFiles?
    private var roots: [String: URL] = [:]
    /// CLOUD-FILES-5: the folder the instruction-file sync uses for a project on this Mac (the CHOSEN one), nil = none.
    func projectRoot(_ projectId: String) -> URL? { roots[projectId] }
    /// Projects with more than one folder and none chosen (Decker's ruling on S2), and where the choices are kept.
    private(set) var choices: [NativeCloudBootChoice] = []
    private var foldersFile: URL?
    /// The changed list's lines as lane F reported them, by line id (security review M4).
    private var changeRecords: [String: BackendCloudBootFilesChange] = [:]
    /// "Put the earlier version back": lane F's `putBackEarlierVersion`, called only from this page (no tool, no
    /// feature action). Kept optional so a build without it draws no button that cannot work.
    static let putBackBinding: (@Sendable (BackendCloudBootFiles, BackendCloudBootFilesChange) async throws -> BackendCloudBootFilesPutBack)? = {
        boot, change in try await boot.putBackEarlierVersion(change)
    }
    private var loading: Task<Void, Never>?
    private var sessionEnded: EngineSubscription?
    private var becameActive: NSObjectProtocol?
    init() {}

    func attach(_ made: BackendCloudBootFiles, places: [BackendCloudBootFilesPlace], choices: [NativeCloudBootChoice] = [], foldersFile: URL? = nil) {
        boot = made
        Task {
            await made.setDeleteRuleGate(NativeCloudFolder.deleteRuleIsOpen)
            await made.setDeleteRuleAnnounced(NativeCloudFolder.deleteRuleAnnounced)
            await made.setMacName { id in
                await MainActor.run {
                    NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }
                        .flatMap { BackendCloudContentsWords.plain($0.shownName) }
                }
            }
        }
        self.foldersFile = foldersFile
        self.choices = choices
        NativeCloudFeatureParts.shared.acceptFile = { [weak self] id in self?.review(id) }
        NativeCloudFeatureParts.shared.chooseBootFolder = { [weak self] projectId, folder in self?.chooseBootFolder(projectId, folder) }
        NativeCloudFeatureParts.shared.showEarlier = { [weak self] id in self?.showEarlier(id) }
        if Self.putBackBinding != nil {
            NativeCloudFeatureParts.shared.putBack = { [weak self] (id: String) in self?.putBack(id) }
        } else {
            NativeCloudFeatureParts.shared.putBack = nil
        }
        // Review B-M3: nothing is read yet, so the row says "Checking…", never "nothing waits".
        NativeCloudFeatureParts.shared.bootFiles = .notReadYet
        // Lane F has no watcher and no timer. This Mac's folders are looked at again when a session of any AI ends
        // ("stop a session on Mac 1"), when the app comes to the front, when the Cloud page opens, when a project gets
        // its first folder and (proof 2) when files from another device arrive.
        if EngineBridge.shared.isReady, sessionEnded == nil {
            sessionEnded = EngineBridge.shared.on("session:exit") { _ in Task { @MainActor in NativeCloudBrainRegistration.pageOpened() } }
        }
        if becameActive == nil {
            becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in NativeCloudBrainRegistration.pageOpened() }
            }
        }
        update(places: places)
    }
    func detach(_ made: BackendCloudBootFiles) {
        guard let current = boot, current === made else { return }
        loading?.cancel(); loading = nil
        sessionEnded?.cancel(); sessionEnded = nil
        if let becameActive { NotificationCenter.default.removeObserver(becameActive) }
        becameActive = nil
        boot = nil
        roots = [:]
        choices = []
        foldersFile = nil
        NativeCloudFeatureParts.shared.acceptFile = nil
        NativeCloudFeatureParts.shared.chooseBootFolder = nil
        NativeCloudFeatureParts.shared.showEarlier = nil
        NativeCloudFeatureParts.shared.putBack = nil
        NativeCloudFeatureParts.shared.changes = []
        changeRecords = [:]
        NativeCloudFeatureParts.shared.bootFiles = nil
    }
    /// The places lane F was last given, so a waiting file's place can be shown as a path on this Mac.
    func update(places: [BackendCloudBootFilesPlace], choices: [NativeCloudBootChoice]? = nil) {
        var next: [String: URL] = [:]
        for place in places where place.kind == .project && place.chosen { next[place.identity] = place.root }
        roots = next
        if let choices { self.choices = choices }
        refresh()
    }
    /// "Choose folder…" on a project's choice line: kept on this Mac only, then lane F is given the places again.
    private func chooseBootFolder(_ projectId: String, _ folder: String) {
        guard let file = foldersFile, let choice = choices.first(where: { $0.projectId == projectId }) else { return }
        guard NativeCloudBootPlaces.choose(projectId: projectId, folder: folder, among: choice.folders, file: file) else { return }
        choices.removeAll { $0.projectId == projectId }
        NativeCloudBrainRegistration.pageOpened()
    }
    func refresh() {
        guard let boot else { return }
        loading?.cancel()
        loading = Task { [weak self] in
            // Review B-M3: a list that cannot be read is "could not check" with Check again, never "nothing waits".
            let part: BackendCloudOverviewInput.Feature
            let choices = self?.choices ?? []
            do { part = Self.part(try await boot.items(), choices: choices) } catch { part = .unreadable }
            // Security review M4: what other devices changed here by itself, newest first.
            let changed = (try? await boot.changedFromOtherDevices(limit: 100)) ?? []
            // The one rule's line names the project, never its id.
            var projectNames: [String: String] = [:]
            if changed.contains(where: { $0.how == "newer" }), let registry = BackendPROJRegistry.installed, let projects = try? await registry.projects() {
                for project in projects { projectNames[project.id] = project.name }
            }
            guard !Task.isCancelled, let self, let current = self.boot, current === boot else { return }
            let before = NativeCloudFeatureParts.shared.bootFiles
            NativeCloudFeatureParts.shared.bootFiles = part
            // 13 Nov leftover: the Boot files row's state comes from the account's status read. When what waits here
            // changed, it is read again, so the row never keeps "Starting" or an old "wait for a folder" count.
            if before != part { NativeCloudAccount.shared.refreshDevices() }
            let names = Dictionary(NativeCloudAccount.shared.snapshot.trust.map { ($0.deviceId, $0.name) }, uniquingKeysWith: { first, _ in first })
            var records: [String: BackendCloudBootFilesChange] = [:]
            var lines: [NativeCloudChangeLine] = []
            for change in changed {
                let id = Self.changeId(change)
                guard records[id] == nil else { continue }
                records[id] = change
                let root = change.identity.flatMap { self.roots[$0] }
                if change.how == "newer", let line = Self.keptLine(change, from: names[change.originDevice], projects: projectNames, root: root) {
                    // Shown on its own while this Mac's version is still kept (30 days).
                    let kept = line.keptUntil > Int64(Date().timeIntervalSince1970 * 1000)
                    lines.append(NativeCloudChangeLine(id: id, text: line.sentence(), earlierHash: change.previousHash, keptLine: kept))
                    continue
                }
                lines.append(NativeCloudChangeLine(id: id, text: Self.changeLine(change, root: root, from: names[change.originDevice]), earlierHash: change.previousHash))
            }
            self.changeRecords = records
            NativeCloudFeatureParts.shared.changes = lines
        }
    }
    /// A path as another device wrote it, on one plain line.
    nonisolated static func shown(_ relative: String) -> String { NativeCloudFileAcceptSheet.plain(relative, limit: 120) }
    nonisolated static func count(_ number: Int, _ one: String, _ many: String) -> String { number == 1 ? "1 " + one : "\(number) " + many }
    /// The summary's part for boot files. Only what can be accepted here has a button; the rest says why it waits.
    nonisolated static func chooseFolderLine(_ name: String) -> String {
        "Choose which folder gets this project's AI instruction files: “" + BackendCloudTrustRows.plainName(name) + "”."
    }
    nonisolated static func part(_ items: [BackendCloudBootFilesItem], choices: [NativeCloudBootChoice] = []) -> BackendCloudOverviewInput.Feature {
        var waiting: [BackendCloudOverview.Waiting] = []
        var notes: [String] = []
        // Decker's ruling on S2: one line per project with several folders and none chosen, with its folders to pick.
        // Page-names 2 (owner: no "which folder" questions): not a task; listed by name under the summary's quiet line.
        var later: [BackendCloudOverview.Waiting] = []
        for choice in choices {
            later.append(.init(id: "boot-folder:" + choice.projectId, text: BackendCloudTrustRows.plainName(choice.name),
                               action: .chooseBootFolder(projectId: choice.projectId, folders: choice.folders)))
        }
        var needFolder = 0, notChosen = 0, homeFolder = 0, blocked = 0, removed = 0, replaced = 0, review = 0
        for item in items {
            switch item.kind {
            case .needsAccept:
                review += 1
                waiting.append(.init(id: "file:" + item.id, text: "A file from your Cloud can run a command or let tools run, and waits for you: " + shown(item.relative),
                                     action: .acceptFile(id: item.id)))
            case .keptVersion, .otherVersion:
                review += 1
                waiting.append(.init(id: "file:" + item.id, text: "Another version of " + shown(item.relative) + " came from another device. This Mac’s file was not changed.",
                                     action: .acceptFile(id: item.id)))
            case .waitingFolder:
                if item.reasons.contains("home-folder") { homeFolder += 1 }
                else if item.reasons.contains("no-chosen-folder") { notChosen += 1 }
                else { needFolder += 1 }
            case .blocked: blocked += 1
            case .removedElsewhere: removed += 1
            case .replacedLocal: replaced += 1
            }
        }
        // Page-names 2: files that wait for their project's folder are said ONCE, beside the projects without a folder
        // ("Their 293 instruction files are written when you choose a folder"), never as a task and never twice.
        if homeFolder > 0 {
            waiting.append(.init(id: "files:home", text: count(homeFolder, "boot file is", "boot files are")
                + " not written: its project's folder is your home folder or holds an AI account's settings."))
        }
        if blocked > 0 {
            waiting.append(.init(id: "files:blocked", text: count(blocked, "boot file was", "boot files were")
                + " not written: a link, a folder or a name that differs only in letter case is in the way. This clears by itself."))
        }
        if removed > 0 {
            notes.append(removed == 1 ? "1 file was removed on another device. It is still on this Mac."
                                      : "\(removed) files were removed on another device. They are still on this Mac.")
        }
        if replaced > 0 {
            notes.append(replaced == 1 ? "1 earlier version of a file on this Mac is kept." : "\(replaced) earlier versions of files on this Mac are kept.")
        }
        return BackendCloudOverviewInput.Feature(waiting: waiting, notes: notes,
            waitingSummary: waitingSummary(needFolder: 0, notChosen: 0, homeFolder: homeFolder, blocked: blocked, review: review),
            later: later, filesForFolders: needFolder + notChosen)
    }
    /// Proof 2 (13 Nov): the Boot files row's own words while files really wait here: how many, and why.
    nonisolated static func waitingSummary(needFolder: Int, notChosen: Int, homeFolder: Int, blocked: Int, review: Int) -> String? {
        let total = needFolder + notChosen + homeFolder + blocked + review
        guard total > 0 else { return nil }
        var why: [String] = []
        if needFolder > 0 { why.append("for a project folder on this Mac") }
        if notChosen > 0 { why.append("until you choose a project's folder") }
        if homeFolder > 0 { why.append("because a project's folder is your home folder") }
        if blocked > 0 { why.append("because something is in the way") }
        if review > 0 { why.append("for you to look at them") }
        return count(total, "boot file waits ", "boot files wait ") + why.joined(separator: " or ")
    }
    nonisolated static func changeId(_ change: BackendCloudBootFilesChange) -> String {
        [change.place.rawValue, change.identity ?? "", change.relative, change.hash, String(change.at)].joined(separator: "|")
    }
    /// One line of "Changed from your other devices": what changed, where on this Mac, from which device, which day.
    nonisolated static func changeLine(_ change: BackendCloudBootFilesChange, root: URL?, from: String?) -> String {
        let what: String
        switch change.how {
        case "created": what = "Added"
        case "accepted": what = "Accepted by you"
        default: what = "Changed"
        }
        let place = root.map { shown($0.appendingPathComponent(change.relative).path) } ?? shown(change.relative)
        let device = from.map { "“" + BackendCloudTrustRows.plainName($0) + "”" } ?? "another device"
        let day = Date(timeIntervalSince1970: Double(change.at) / 1000).formatted(date: .abbreviated, time: .omitted)
        return what + " " + place + " · from " + device + " · " + day
    }
    /// The one rule's line for a change that replaced this Mac's own version: names and dates only.
    /// A project no longer listed here is named by its folder on this Mac, or as "a project not on this Mac".
    nonisolated static let projectNotHere = "a project not on this Mac"
    nonisolated static func keptLine(_ change: BackendCloudBootFilesChange, from: String?, projects: [String: String], root: URL? = nil) -> CloudVersionReplacedLine? {
        guard change.how == "newer", change.previousHash != nil else { return nil }
        let device = from.map(BackendCloudTrustRows.plainName) ?? "Another device"
        var project: String?
        if change.place == .project {
            project = (change.identity.flatMap { projects[$0] } ?? root.map { $0.lastPathComponent }).map(BackendCloudTrustRows.plainName) ?? projectNotHere
        }
        return CloudVersionReplacedLine(device: device, name: BackendCloudTrustRows.plainName(CloudVersionReplacedLine.fileName(change.relative)), project: project,
                                        keptUntil: change.at + CloudBootFilesRules.keptFor, itemId: changeId(change))
    }
    static let keptTitle = "This Mac's version"
    static let keptLead = "A newer version from another device is in use. This is the version this Mac had; it is kept for 30 days. Restore makes it the newest version again, on every device."
    static let earlierGone = "That earlier version is no longer kept on this Mac."
    static let earlierUnreadable = "The earlier version could not be read on this Mac. Nothing was changed."
    static let putBackTitle = "Put the earlier version back?"
    static let putBackLead = "This Mac's file is replaced by the version it held before the change from your other device. The current version is kept as another version. Read it in the box below first."
    static let putBackAccept = NSApplication.ModalResponse.alertSecondButtonReturn
    static let putBackFailed = "The earlier version could not be put back. Nothing was changed."
    static let putBackGone = "The earlier version is no longer kept on this Mac."
    static let putBackChangedSince = "This file was changed on this Mac since then, so it was left as it is."
    /// Lane F's answer as one plain line; nil when it was put back.
    static func putBackLine(_ result: BackendCloudBootFilesPutBack?) -> String? {
        switch result {
        case .putBack: return nil
        case .earlierVersionGone: return putBackGone
        case .changedSince: return putBackChangedSince
        case .notPossible, nil: return putBackFailed
        }
    }
    /// The bytes of an earlier version as numbered plain lines for a box (never the sheet's own words).
    nonisolated static func earlierText(_ data: Data, path: String) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var lines = ["Earlier version of:", "  " + NativeCloudFileAcceptSheet.plain(path), "", "\(min(all.count, 400)) of \(all.count) lines:"]
        for (index, line) in all.prefix(400).enumerated() {
            let number = String(index + 1)
            lines.append(String(repeating: " ", count: max(0, 5 - number.count)) + number + " │ " + NativeCloudFileAcceptSheet.plain(String(line), limit: 500))
        }
        return lines.joined(separator: "\n")
    }
    /// "Show earlier version": read-only, in a fixed-width box. Reached through a guarded page press.
    private func showEarlier(_ id: String) {
        guard let boot, let change = changeRecords[id], let hash = change.previousHash else { return }
        let model = NativeCloudAccount.shared
        Task {
            let data: Data?
            do { data = try await boot.earlierVersion(hash: hash) } catch { model.say(Self.earlierUnreadable); return }
            guard let data else { model.say(Self.earlierGone); return }
            let alert = NSAlert()
            alert.messageText = "Earlier version"
            alert.informativeText = "This is what this Mac's file held before the change from your other device. Nothing is changed by reading it."
            alert.accessoryView = NativeCloudFileAcceptSheet.box(Self.earlierText(data, path: change.relative))
            alert.addButton(withTitle: "Close").keyEquivalent = "\r"
            NativeCloudSheetGuard.shared.notice(alert)
        }
    }
    /// "Put the earlier version back": a guarded page press, then a guarded sheet with the bytes; only a taken click
    /// on "Put it back" calls lane F.
    private func putBack(_ id: String) {
        guard let boot, let change = changeRecords[id], let hash = change.previousHash, let binding = Self.putBackBinding else { return }
        let model = NativeCloudAccount.shared
        Task { [weak self] in
            let data: Data?
            do { data = try await boot.earlierVersion(hash: hash) } catch { model.say(Self.earlierUnreadable); return }
            guard let data else { model.say(Self.earlierGone); return }
            NativeFront.onlyForPerson("Cloud: put the earlier version back") { NSApp?.activate() } // person-ok: his own Put back click
            guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
            let alert = NSAlert()
            // The one rule's "Show": the kept text, with Restore (the same safe put-back: only over the bytes that change wrote).
            let kept = change.how == "newer"
            alert.alertStyle = kept ? .informational : .warning
            alert.messageText = kept ? Self.keptTitle : Self.putBackTitle
            alert.informativeText = kept ? Self.keptLead : Self.putBackLead
            alert.accessoryView = NativeCloudFileAcceptSheet.box(Self.earlierText(data, path: kept ? CloudVersionReplacedLine.fileName(change.relative) : change.relative))
            alert.addButton(withTitle: kept ? "Close" : "Not now").keyEquivalent = "\r"
            alert.addButton(withTitle: kept ? "Restore" : "Put it back")
            let answer = await NativeCloudSheetGuard.shared.present(alert, on: window, accept: Self.putBackAccept)
            if answer.chose, !answer.taken { model.say(NativeCloudSheetGuard.pressRefused) }
            guard answer.taken else { return }
            let result = try? await binding(boot, change)
            if let line = Self.putBackLine(result) { model.say(line) }
            self?.refresh()
        }
    }
    // MARK: Lane L4: an instruction file's versions on the Your Cloud page

    /// The versions this Mac keeps of one instruction file (lane L1's 30-day keeper), newest first.
    func keptVersions(home: CloudBootFilesPlaceKind?, projectId: String?, relative: String) async -> [BackendCloudBootFilesKept] {
        guard let boot else { return [] }
        let place = home ?? .project
        guard let identity = projectId ?? changeRecords.values.first(where: { $0.place == place && $0.relative == relative })?.identity else { return [] }
        return (try? await boot.keptVersions(place: place, identity: identity, relative: relative)) ?? []
    }
    /// The text of one kept version.
    func keptText(_ hash: String) async -> Data? {
        guard let boot else { return nil }
        return try? await boot.keptLocal(hash: hash)
    }
    /// The change a kept version can be put back through (the one rule's Restore): the newest change of that file that
    /// replaced exactly that version. nil = this version cannot be made the newest from here.
    func restorable(relative: String, hash: String) -> BackendCloudBootFilesChange? {
        changeRecords.values.filter { $0.relative == relative && $0.previousHash == hash }.max { $0.at < $1.at }
    }
    /// "Use this version" on the Your Cloud page, with no sheet (owner, 14 Nov: no confirm sheets; the person read the
    /// version on the page): lane F's same safe put-back, only over exactly the bytes that change wrote. Returns the one
    /// plain line to say when it could not be done.
    func useKept(relative: String, hash: String) async -> String? {
        guard let boot, let change = restorable(relative: relative, hash: hash), let binding = Self.putBackBinding else { return Self.putBackFailed }
        let result = try? await binding(boot, change)
        refresh()
        return Self.putBackLine(result)
    }

    /// Lane F's short reason, as one plain line for the accept sheet.
    nonisolated static func runLine(_ reason: String) -> String {
        if reason == "header:unclear" { return "Its header is written in a way this Mac cannot read plainly, so it waits for you." }
        if reason.hasPrefix("import:") {
            return "It pulls in a file from outside the project when it loads: " + shown(String(reason.dropFirst(7)))
        }
        if reason.hasPrefix("header:") {
            let key = String(reason.dropFirst(7))
            if key.hasPrefix("allowed") { return "Its header lets tools run without asking (" + key + ")." }
            if key.hasPrefix("mcp") { return "Its header names MCP servers (" + key + ")." }
            if key == "hooks" { return "Its header holds hooks, which run commands." }
            if key.contains("tools") || key.hasPrefix("permission") { return "Its header changes what an agent may do (" + key + ")." }
            if key == "command" || key.hasPrefix("run") || key.hasPrefix("exec") { return "Its header names a command or its settings (" + key + ")." }
            return "Its header changes how the AI tool uses it (" + key + ")."
        }
        switch reason {
        case "script": return "It is a script (it begins with #!)."
        case "script-or-settings": return "It is not a plain note: it may be a script or a settings file."
        case "inline-command": return "It holds a command the AI tool runs while it loads the file."
        case "local-differs": return "This Mac has a different file at that place."
        case "removed-here": return "This Mac’s file at that place was removed."
        case "not-text": return "It is not plain text."
        case "newer-version": return "A newer version of it came from another device."
        case "changed": return "This Mac’s file changed since it was last saved."
        case "no-folder": return "Waiting for a folder on this Mac."
        case "no-chosen-folder": return "Choose which folder of this project gets its AI instruction files on this Mac."
        case "home-folder": return "This project's folder is your home folder (or holds an AI account's settings), so its files are not written there."
        default: return reason
        }
    }
    /// What the accept sheet shows for one waiting file: where it would be written on this Mac, what in it can run
    /// and (security review M3) the file itself from lane F's `review`: the exact bytes `accept` writes.
    nonisolated static func request(_ item: BackendCloudBootFilesItem, root: URL?, from: String?,
                                    review: BackendCloudBootFilesReview? = nil) -> NativeCloudFileAcceptRequest {
        let path = root.map { $0.appendingPathComponent(item.relative).path } ?? (item.place.rawValue + ": " + item.relative)
        let replaces = item.kind != .needsAccept || item.reasons.contains("local-differs")
        // The reasons lane F found in those very bytes first, then this Mac's own (another version, removed here …).
        var reasons: [String] = review?.reasons ?? []
        for reason in item.reasons where !reasons.contains(reason) { reasons.append(reason) }
        // S12: a version whose only reason is that this Mac's file differs does not run anything.
        let canRun = item.kind == .needsAccept || reasons.contains { $0 != "local-differs" && $0 != "newer-version" && $0 != "changed" && $0 != "removed-here" }
        return NativeCloudFileAcceptRequest(id: item.id, path: path, runs: reasons.map(runLine), from: from, replaces: replaces,
                                            shown: review?.lines ?? [], totalLines: review?.totalLines ?? 0, canRun: canRun)
    }
    /// Security review M3: the review is shown only when it is about THIS line's exact bytes.
    nonisolated static func matches(_ review: BackendCloudBootFilesReview, _ item: BackendCloudBootFilesItem) -> Bool {
        let digest = SHA256.hash(data: review.bytes).map { String(format: "%02x", $0) }.joined()
        let sameLine = review.id == item.id && review.hash == item.hash
        return sameLine && digest == item.hash
    }
    /// "Review…" on the Cloud page. The sheet is the only way in: `accept` and `dismiss` are never tools.
    private func review(_ id: String) {
        guard let boot else { return }
        let model = NativeCloudAccount.shared
        Task { [weak self] in
            guard let self, let item = try? await boot.items().first(where: { $0.id == id }), item.canAccept else { self?.refresh(); return }
            // Security review M3: the sheet shows the exact bytes `accept` writes, or it does not open at all.
            let reviewed: BackendCloudBootFilesReview?
            do { reviewed = try await boot.review(id) } catch { model.say(Self.notReadable); self.refresh(); return }
            guard let reviewed else { model.say(Self.changed); self.refresh(); return }
            guard Self.matches(reviewed, item) else { model.say(Self.notReadable); self.refresh(); return }
            let from = model.snapshot.trust.first { $0.deviceId == item.originDevice }?.name
            let request = Self.request(item, root: item.identity.flatMap { self.roots[$0] }, from: from, review: reviewed)
            switch await NativeCloudFileAcceptSheet.ask(request, model: model) {
            case .accept:
                let written = (try? await boot.accept([id])) ?? []
                if !written.contains(id) { model.say(Self.notWritten) }
            case .keepMine:
                try? await boot.dismiss([id])
            case .notNow:
                break
            }
            self.refresh()
        }
    }
    /// Lane F's one read-only tool (`cloud.boot_files`: paths, sizes and reasons, never a file's text), registered
    /// beside the account's tools only while the row is built.
    func toolEntries(visible: @escaping @Sendable () async -> Bool) async throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        guard let boot, await visible(), let definition = BackendCloudBootFilesFeature.contribution.tools.first else { return [] }
        let spec = try BackendMCPTool(id: definition.id, wireName: definition.id.replacingOccurrences(of: ".", with: "_"),
                                      description: definition.description, inputSchema: definition.inputSchema.raw, tier: .read)
        return [(spec, { _, arguments in
            guard await visible() else { throw CloudFailure.gateClosed }
            let answer = try await boot.tool(arguments: CloudValue(arguments))
            return .value(answer.raw)
        })]
    }
}
