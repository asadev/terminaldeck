import Foundation
import TerminalDeckNativeCore

/// Page-names lane (owner, 13 Nov: "every number must be true and mean the same thing wherever it appears"): the ONE
/// source of every count Settings → Cloud and the Your Cloud window show. Counted in things the person recognises
/// (notes, diary entries, topics, projects, agents, instruction files, settings), never in sync records or versions.
/// "Here" is only what is really in this Mac's own memory and lists; what has arrived from the Cloud but is not added
/// to this Mac's memory yet is "arriving", said on its own.
public struct BackendCloudPageCounts: Sendable, Equatable {
    public enum Unit: String, Sendable, CaseIterable {
        case notes, diary, topics, otherMemory, memoryFiles, projects, agents, instructionFiles, settings
        /// Lane L3: this Mac's own tasks, and his settings that travel (app settings, not memory's).
        case tasks, appSettings
        /// Lane L3 slice 1: files in his Cloud folder that travel (`BackendCloudFolder.counts`).
        case cloudFolder
        /// Lane L3 slice 2: his artifacts that travel (`BackendCloudArtifacts.counts`).
        case artifacts
    }
    /// What is really on this Mac now. A unit that is absent is not known yet (never shown as 0).
    public var here: [Unit: Int]
    /// Arrived from your Cloud and kept on this Mac, not yet added to its memory.
    public var arriving: [Unit: Int]
    /// Page-names 2 (Mac mini: "61 topics" while its memory lists 64): entries this Mac's memory still lists whose file
    /// is gone from this Mac. Not counted as here, and said in words, never silently left out.
    public var missing: [Unit: Int]
    /// Page-names 2: instruction files that are in your Cloud and are written on this Mac once their project has a
    /// folder here. Not "here" and not "arriving" (nothing is being added until a folder is chosen).
    public var waitingForFolder: Int
    /// Lane L3 slice 1: the size of the files in his Cloud folder that travel (bytes). nil = not known.
    public var cloudFolderBytes: Int64?
    /// Lane L3 slice 2: the size of his artifacts that travel (bytes). nil = not known.
    public var artifactsBytes: Int64? = nil
    /// Status-line lane (owner, 14 Nov): space used per kind, from the sizes the sync core records for each part it
    /// carries (`BackendCloudSpace.make`), with the account's limit. nil until read. Both Cloud pages and
    /// `cloud.status` show these same numbers.
    public var space: BackendCloudSpace?
    public init(here: [Unit: Int] = [:], arriving: [Unit: Int] = [:], missing: [Unit: Int] = [:], waitingForFolder: Int = 0,
                cloudFolderBytes: Int64? = nil, space: BackendCloudSpace? = nil) {
        self.cloudFolderBytes = cloudFolderBytes
        self.here = here
        self.arriving = arriving
        self.missing = missing
        self.waitingForFolder = waitingForFolder
        self.space = space
    }

    /// The units each part of the pages counts in.
    public static let memoryUnits: [Unit] = [.notes, .diary, .topics]
    public static func units(_ kind: BackendCloudOverview.Kind) -> [Unit] {
        switch kind {
        case .memory: return memoryUnits
        case .projects: return [.projects, .agents]
        case .bootFiles: return [.instructionFiles]
        case .tasks: return [.tasks]
        case .settings: return [.appSettings]
        case .cloudFolder: return [.cloudFolder]
        case .artifacts: return [.artifacts]
        case .passwords: return []
        }
    }
    public static func units(_ kind: BackendCloudContents.Kind) -> [Unit] {
        switch kind {
        case .memory: return memoryUnits
        case .projects: return [.projects]
        case .agents: return [.agents]
        case .instructionFiles: return [.instructionFiles]
        case .tasks: return [.tasks]
        case .settings: return [.appSettings, .settings]
        case .cloudFolder: return [.cloudFolder]
        case .artifacts: return [.artifacts]
        case .passwords, .sessions, .other: return []
        }
    }
    /// The memory table a grouped row of the Your Cloud window stands for.
    public static func unit(memoryTable table: String) -> Unit? {
        switch table {
        case "notes": return .notes
        case "diary": return .diary
        case "topics": return .topics
        case "settings": return .settings
        default: return nil
        }
    }

    public static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
    /// "1 note", "3,523 notes", "39,851 diary entries".
    public static func noun(_ unit: Unit, _ value: Int) -> String {
        let (one, many): (String, String)
        switch unit {
        case .notes: (one, many) = ("note", "notes")
        case .diary: (one, many) = ("diary entry", "diary entries")
        case .topics: (one, many) = ("topic", "topics")
        case .otherMemory: (one, many) = ("other memory entry", "other memory entries")
        case .memoryFiles: (one, many) = ("memory file", "memory files")
        case .projects: (one, many) = ("project", "projects")
        case .agents: (one, many) = ("agent", "agents")
        case .instructionFiles: (one, many) = ("instruction file", "instruction files")
        case .settings: (one, many) = ("setting", "settings")
        case .tasks: (one, many) = ("task", "tasks")
        case .appSettings: (one, many) = ("setting", "settings")
        case .cloudFolder: (one, many) = ("file in your Cloud folder", "files in your Cloud folder")
        case .artifacts: (one, many) = ("artifact", "artifacts")
        }
        return number(value) + " " + (value == 1 ? one : many)
    }
    /// "3,523 notes, 39,851 diary entries and 120 topics": only the units that are known. nil when none is.
    public func line(_ units: [Unit]) -> String? {
        let parts = units.compactMap { unit in here[unit].map { Self.noun(unit, $0) } }
        return parts.isEmpty ? nil : BackendCloudContentsWords.list(parts)
    }
    /// The Settings → Cloud row of a part that is wholly in your Cloud. Page-names 2: never "All saved" while something
    /// of that part is still being added here (`addingLine` is said instead) or waits for a project folder.
    public func savedLine(_ kind: BackendCloudOverview.Kind) -> String {
        if let adding = addingLine(kind) { return adding }
        if kind == .bootFiles, waitingForFolder > 0 { return folderLine }
        if kind == .settings { return settingsCount.map { "All saved: " + Self.noun(.appSettings, $0) } ?? BackendCloudPageWords.allSaved }
        return line(Self.units(kind)).map { "All saved: " + $0 } ?? BackendCloudPageWords.allSaved
    }
    /// What arrives on this Mac for each part of Settings → Cloud, in that part's own units.
    public static func arrivingUnits(_ kind: BackendCloudOverview.Kind) -> [Unit] {
        switch kind {
        case .memory: return [.notes, .diary, .topics, .otherMemory, .memoryFiles, .settings]
        case .projects: return [.projects, .agents]
        case .bootFiles, .passwords, .tasks, .settings, .cloudFolder, .artifacts: return []
        }
    }
    /// "Adding 3,228 notes and 33,255 diary entries from your Cloud". nil when nothing of that part is arriving.
    public func addingLine(_ kind: BackendCloudOverview.Kind) -> String? {
        let parts = Self.arrivingUnits(kind).compactMap { unit in arriving[unit].flatMap { $0 > 0 ? Self.noun(unit, $0) : nil } }
        return parts.isEmpty ? nil : "Adding " + BackendCloudContentsWords.list(parts) + " from your Cloud"
    }
    /// The boot files row while files wait for their project's folder. Project folders (14 Nov): folders are made by
    /// themselves, so those files are simply arriving; nothing about folders or choosing one is said.
    public var folderLine: String {
        guard let here = here[.instructionFiles], here > 0 else { return "Adding " + Self.noun(.instructionFiles, waitingForFolder) + " from your Cloud" }
        return Self.noun(.instructionFiles, here) + " on this Mac"
    }
    /// "3 more topics are listed in your memory, but their files are gone from this Mac." nil when none is missing.
    public var missingLine: String? {
        let parts = Self.memoryUnits.compactMap { unit in missing[unit].flatMap { $0 > 0 ? Self.noun(unit, $0) : nil } }
        guard !parts.isEmpty else { return nil }
        let total = Self.memoryUnits.reduce(0) { $0 + (missing[$1] ?? 0) }
        return BackendCloudContentsWords.list(parts) + (total == 1 ? " is" : " are") + " also listed in your memory, but "
            + (total == 1 ? "its file is" : "their files are") + " gone from this Mac, so " + (total == 1 ? "it is" : "they are") + " not counted."
    }
    /// The same numbers in the Your Cloud window, said once above the list of that kind.
    public func onThisMacLine(_ kind: BackendCloudContents.Kind) -> String? {
        if kind == .settings { return count(.settings).map { "On this Mac: " + Self.noun(.settings, $0) } }
        if kind == .cloudFolder { return cloudFolderLine }
        if kind == .artifacts { return artifactsLine }
        guard var said = line(Self.units(kind)).map({ "On this Mac: " + $0 }) else { return nil }
        let adding = Self.units(kind).compactMap { unit in arriving[unit].flatMap { $0 > 0 ? Self.noun(unit, $0) : nil } }
        if kind != .memory, !adding.isEmpty { said += ". Adding " + BackendCloudContentsWords.list(adding) + " from your Cloud" }
        if kind == .instructionFiles, waitingForFolder > 0 {
            said += ". Adding " + Self.noun(.instructionFiles, waitingForFolder) + " from your Cloud"
        }
        if kind == .memory, let missingLine { said += ". " + String(missingLine.dropLast()) }
        return said
    }
    /// The one number beside a kind in the Your Cloud window's sidebar: only for a kind counted in ONE unit. Memory is
    /// counted in three units and has no single number (its line above the list says them). Page-names 2 (owner: count
    /// what he would count): projects and agents are those of the account, the ones here plus the ones still arriving.
    public func count(_ kind: BackendCloudContents.Kind) -> Int? {
        // Owner, 14 Nov (item 5d): every kind shows one number. Memory: its notes (diary entries and topics are counted on
        // their own rows of the list). Settings: his settings that travel and the shared memory settings together.
        if kind == .memory { return here[.notes] }
        if kind == .settings { return settingsCount }
        let units = Self.units(kind)
        guard units.count == 1, let number = here[units[0]] else { return nil }
        return number + (kind == .projects || kind == .agents ? (arriving[units[0]] ?? 0) : 0)
    }
    /// Kinds-state (14 Nov: the side-panel Cloud page said "Settings 86" while Settings → Cloud said "10 settings" on the
    /// same Mac): the ONE definition of "how many settings", used by both pages. It is what the Your Cloud window lists
    /// under Settings, as the owner decided (item 5d): his app settings that travel AND the shared memory settings. nil
    /// while neither is known.
    public var settingsCount: Int? {
        let known = [Unit.appSettings, .settings].compactMap { here[$0] }
        return known.isEmpty ? nil : known.reduce(0, +)
    }
    /// Lane L3 slice 1: "Cloud folder: 12 files, 3.4 MB". nil while the folder is not counted yet.
    public var cloudFolderLine: String? {
        guard let files = here[.cloudFolder] else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: cloudFolderBytes ?? 0, countStyle: .file)
        return "Cloud folder: " + Self.number(files) + (files == 1 ? " file, " : " files, ") + size
    }
    /// Lane L3 slice 2: "Artifacts: 12, 3.4 MB". nil while artifacts are not counted yet.
    public var artifactsLine: String? {
        guard let artifacts = here[.artifacts] else { return nil }
        return "Artifacts: " + Self.number(artifacts) + ", " + ByteCountFormatter.string(fromByteCount: artifactsBytes ?? 0, countStyle: .file)
    }
    /// "Arriving: 20,480 diary entries are being added to this Mac." nil when nothing waits to be added.
    public var arrivingLine: String? { Self.arriving(arriving) }
    public static func arriving(_ counts: [Unit: Int]) -> String? {
        let parts = Unit.allCases.compactMap { unit in counts[unit].flatMap { $0 > 0 ? noun(unit, $0) : nil } }
        guard !parts.isEmpty else { return nil }
        let total = counts.values.reduce(0, +)
        return "Arriving: " + BackendCloudContentsWords.list(parts) + (total == 1 ? " is" : " are") + " being added to this Mac."
    }
    /// Instruction files on this Mac, from boot files' own coverage (files in the chosen folders). Files that wait to
    /// be placed here are not on this Mac and are not counted. nil while boot files report nothing.
    public static func instructionFilesHere(_ snapshot: CloudAccountSnapshot) -> Int? {
        let all = snapshot.coverage.filter { $0.inventoryRow == CloudBootFilesFormat.inventoryRow }
        let rows = all.filter { !isWaitingForFolder($0) }
        // Page-names 2: only files that wait for a folder: none is here (0, a true number, never a blank).
        if rows.isEmpty { return all.isEmpty ? nil : 0 }
        return rows.reduce(0) { $0 + $1.items }
    }
    /// Instruction files that are in your Cloud and wait for their project's folder on this Mac.
    public static func instructionFilesWaitingForFolder(_ snapshot: CloudAccountSnapshot) -> Int {
        snapshot.coverage.filter { $0.inventoryRow == CloudBootFilesFormat.inventoryRow && isWaitingForFolder($0) }.reduce(0) { $0 + $1.items }
    }
    /// The boot files coverage line for files whose project has no folder here (it is never something going up).
    public static func isWaitingForFolder(_ coverage: CloudCoverage) -> Bool { coverage.sourceId.hasSuffix("not-on-this-mac") }
}

/// Page-names lane: the words both Cloud views share for things that used to show codes, key names or record counts.
public enum BackendCloudPageWords {
    public static let allSaved = "All saved"
    public static let stillGoingUp = "Still going up"
    /// Devices, said once near the top of Your Cloud instead of on every row.
    public static let level = "Up to date"
    /// Page-names 2: this Mac is level with your Cloud and is still adding what arrived to its memory.
    public static let addingHere = "Adding what arrived from your Cloud"
    public static func catchingUp(_ count: Int?) -> String {
        guard let count, count > 0 else { return "Catching up" }
        return count == 1 ? "Catching up: 1 change still to fetch" : "Catching up: " + BackendCloudPageCounts.number(count) + " changes still to fetch"
    }
    public static func sending(_ count: Int) -> String {
        count == 1 ? "Sending 1 change" : "Sending " + BackendCloudPageCounts.number(count) + " changes"
    }
    public static func lastSeen(_ at: Int64, now: Date = Date()) -> String { "Last seen " + BackendCloudContentsWords.time(at, now: now) }
    public static func lastSent(_ at: Int64, now: Date = Date()) -> String { "Last sent " + BackendCloudContentsWords.time(at, now: now) }
    /// The one line near the top of Your Cloud that names the devices still catching up.
    public static func stillCatchingUp(_ devices: [(name: String, count: Int?)]) -> String? {
        guard !devices.isEmpty else { return nil }
        let parts = devices.map { device in
            device.count.map { $0 > 0 ? device.name + " (" + BackendCloudPageCounts.number($0) + ($0 == 1 ? " change" : " changes") + " still to fetch)" : device.name } ?? device.name
        }
        let who = BackendCloudContentsWords.list(parts)
        return (devices.count == 1 ? who + " is still catching up." : who + " are still catching up.")
            + " Everything listed below reaches " + (devices.count == 1 ? "it" : "them") + " by itself."
    }
    /// Settings that belong to one Mac only, as ONE count (never their key names). Nothing to do about them.
    public static func keptHere(settings: Int) -> String {
        settings == 1 ? "1 memory setting belongs to this Mac only and stays here." : BackendCloudPageCounts.number(settings) + " memory settings belong to this Mac only and stay here."
    }

    /// Notes from the memory store and coverage lines, made plain for the page: the lines that name memory settings
    /// by their key ("Memory setting kept on this Mac: desk.fill") become ONE count line; file lists and file names are
    /// said as counts; any other line that still carries a code, key name, path or internal word is dropped.
    public static func plainNotes(_ notes: [String]) -> [String] {
        var settings = 0, kept: [String] = [], seen: Set<String> = []
        func add(_ line: String) { if seen.insert(line).inserted { kept.append(line) } }
        for note in notes {
            if note.hasPrefix("Memory setting kept on this Mac: ") { settings += 1; continue }
            if note.hasPrefix("Memory settings kept on this Mac: "),
               let number = Int(note.dropFirst("Memory settings kept on this Mac: ".count).prefix { $0.isNumber }) { settings += number; continue }
            if let count = trailingCount(note, prefix: "Hidden files and folders") {
                add(count == 1 ? "1 hidden file or folder stays on this Mac." : BackendCloudPageCounts.number(count) + " hidden files and folders stay on this Mac."); continue
            }
            if let count = trailingCount(note, prefix: "Linked files and folders") {
                add(count == 1 ? "1 linked file or folder stays on this Mac." : BackendCloudPageCounts.number(count) + " linked files and folders stay on this Mac."); continue
            }
            // The app writes its own help files on each device: nothing of the person's, nothing to do.
            if note.hasPrefix("The app's own help files") { continue }
            let plain = plainWords(note)
            if isPlain(plain) { add(plain) }
        }
        if settings > 0 { kept.insert(keptHere(settings: settings), at: 0) }
        return kept
    }
    /// A store or sync sentence with its internal words said plainly.
    public static func plainWords(_ line: String) -> String {
        if let failure = plainFailure(line) { return failure }
        return line.replacingOccurrences(of: "memory records", with: "memory entries")
            .replacingOccurrences(of: "memory record", with: "memory entry")
            .replacingOccurrences(of: "Waiting for a verified snapshot.", with: "Waiting for your Cloud to confirm this part.")
    }
    /// Kinds-state 2 (lead, 14 Nov): the sync core's sentences for a real, lasting failure (CloudSyncEngine `reported`)
    /// name "records" and carry the service's own reason, so the page guard dropped them and a row said "Not complete"
    /// with no reason. Said here in plain words instead; the sync core keeps its own wording for the log and the tools.
    public static func plainFailure(_ line: String) -> String? {
        let forms: [(String, (Int) -> String)] = [
            ("^([0-9]+) records could not be applied on this Mac and are kept for retry", { n in
                (n == 1 ? "1 change" : BackendCloudPageCounts.number(n) + " changes") + " could not be saved on this Mac yet. It is tried again by itself." }),
            ("^([0-9]+) edits could not be sent and are kept here", { n in
                (n == 1 ? "1 change was" : BackendCloudPageCounts.number(n) + " changes were") + " refused by your Cloud. "
                    + (n == 1 ? "It is" : "They are") + " kept on this Mac." }),
            ("^([0-9]+) edits wait behind an earlier edit", { n in
                (n == 1 ? "1 change waits" : BackendCloudPageCounts.number(n) + " changes wait") + " behind an earlier change your Cloud refused." }),
        ]
        for (pattern, say) in forms {
            guard let range = line.range(of: pattern, options: .regularExpression),
                  let number = Int(line[range].prefix { $0.isNumber }) else { continue }
            return say(number)
        }
        return nil
    }
    /// "Hidden files and folders (such as .git or .obsidian) stay on this Mac: 3." → 3.
    static func trailingCount(_ note: String, prefix: String) -> Int? {
        guard note.hasPrefix(prefix), let colon = note.lastIndex(of: ":") else { return nil }
        return Int(note[note.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " .")))
    }
    /// The page guard (owner, 13 Nov): no UUID, run of 8+ hex characters, dotted key name, file name with an ending,
    /// path or internal sync word.
    public static func isPlain(_ text: String) -> Bool {
        let banned = [
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}",
            "\\b[0-9a-fA-F]{8,}\\b",
            "\\b[a-z][a-z0-9_-]*\\.[a-z][a-z0-9_.-]*[a-z0-9]\\b",
            "/[A-Za-z0-9._-]+/",
            "\\b(pack|packs|record|records|seq|outbox|baseline|snapshot|cursor|opId|inventory)\\b",
        ]
        return !banned.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
