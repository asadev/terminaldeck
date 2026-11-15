import Foundation
import TerminalDeckNativeCore

/// "See what is in your Cloud" (owner, 13 Nov): the page's model in plain words. Three parts:
/// - Devices: each device by name, when it last sent and received, and one plain state;
/// - Everything in your Cloud: every item by kind, with who changed it last, when, and on which devices it is;
/// - Activity: what moved, newest first, in sentences.
/// Built only from the sync store's local read (`CloudSyncContents`), the account snapshot the Cloud page already
/// holds and names this Mac already knows. Owner's rule: a device is only ever its name and dates; no code, id,
/// key or fingerprint reaches this model (`BackendCloudContentsWords.plain` guards every name).
public struct BackendCloudContents: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        /// Lane L3 slice 1: `cloudFolder`, the files in his Cloud folder (`~/Terminal Deck Cloud`).
        /// Lane L3 slice 2: `artifacts`, his artifacts that travel between his Macs (`BackendCloudArtifacts`).
        /// Sessions in the Cloud (15 Nov): `sessions`, every session's and earlier chat's copy in the Cloud
        /// (`BackendCloudChatsContents`), listed while the Cloud holds any.
        case memory, projects, agents, instructionFiles, tasks, settings, artifacts, cloudFolder, passwords, sessions, other
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .memory: return "Memory"
            case .projects: return "Projects"
            case .agents: return "Agents"
            case .instructionFiles: return "Instruction files"
            case .tasks: return "Tasks"
            case .settings: return "Settings"
            case .passwords: return "Saved passwords"
            case .cloudFolder: return "Cloud folder"
            case .artifacts: return "Artifacts"
            case .sessions: return "Sessions and chats"
            case .other: return "Other"
            }
        }
        public var symbol: String {
            switch self {
            case .memory: return "brain"
            case .projects: return "folder"
            case .agents: return "person.2"
            case .instructionFiles: return "doc.text"
            case .tasks: return "checklist"
            case .settings: return "gearshape"
            case .passwords: return "key"
            case .cloudFolder: return "icloud"
            case .artifacts: return "doc.richtext"
            case .sessions: return "bubble.left.and.bubble.right"
            case .other: return "tray"
            }
        }
    }
    public struct Device: Sendable, Equatable, Identifiable {
        /// The device's place in the list ("device-1"): stable for one page, never an account id.
        public let id: String
        public let name: String
        public let isThisMac: Bool
        public let lastSent: Int64?
        public let lastReceived: Int64?
        /// For another device, when it last checked in with Cloud (it fetches then).
        public let lastSeen: Int64?
        /// "Up to date", "Sending 3 items", "Receiving 12 items", "Waiting: …", "Not seen since …".
        public let state: String
        /// Something is moving right now (sending or receiving).
        public let moving: Bool
        public let needsLook: Bool
    }
    public struct Change: Sendable, Equatable {
        public let device: String
        public let at: Int64
    }
    public struct Item: Sendable, Equatable, Identifiable {
        /// Plain composite ("instructionFiles|Terminal Deck|CLAUDE.md"): stable across refreshes, no id inside.
        public let id: String
        public let kind: Kind
        /// CLOUD-FILES-4: `var` so the one pass that keeps every row apart can add what tells two apart.
        public var name: String
        /// Where it belongs: a project or agent name, or a settings folder.
        public var place: String?
        public let changedBy: String
        public let changedAt: Int64
        /// "On this Mac", "On MacBook Pro", "Waiting on MacBook Pro", "Sending from this Mac" …
        public let presence: [String]
        /// Device names it is on (for the device filter).
        public let onDevices: [String]
        /// Newest first.
        public let history: [Change]
        public let bytes: Int64?
        /// Entries of a grouped memory table ("58 entries"); nil for one item.
        public let entries: Int?
        /// One plain line when the item does not stand settled ("Waiting: …", "Could not send: …").
        public let note: String?
        /// A text file that may be shown read-only (never a saved password).
        public let isText: Bool
        /// Owner, 14 Nov (item 5c): a note the memory set aside when a newer note replaced it (`archive/…`). It is a record
        /// of its own in your Cloud (its own file, its own id), so it stays listed, and its row says it was replaced.
        /// Lane L4 (file manager): never true any more on a row: a replaced copy is one of `versions` of the note.
        public var replaced: Bool = false
        /// Lane L4: in use, put away, or in the Bin.
        public var state: BackendCloudNoteIdentity.State = .live
        /// Lane L4: its earlier versions kept on this Mac, newest first (memory notes; instruction files are read from
        /// their keeper when the item is opened).
        public var versions: [Version] = []
        /// Lane L4: "Remove" is offered (only where a removal is safe: memory notes in this slice).
        public var canRemove: Bool = false
        /// Routing only. The row draws names, never these identities.
        public var deleteItems: [CloudDeleteItem] = []
        public var localMark: CloudLocalMark? = nil
        /// Delete rule (L2): the owner's one line for this row after a press it could not do as asked (`rowErrors()`).
        public var deleteLine: String? = nil
        /// Lane L4: "Put back" is offered (an item in the Bin this Mac holds).
        public var canPutBack: Bool = false
        /// Lane L4: its content can be shown when opened.
        public var canOpen: Bool = false
        /// CLOUD-FILES-2: a note in use here that another Mac removed, replaced or put away ("Removed on MacBook Pro").
        public var elsewhere: String? = nil
        /// CLOUD-FILES-4: an instruction file's own file name, said small in its details (never on the row).
        public var fileName: String? = nil
        /// CLOUD-FILES-6: for a grouped row (the diary), one plain line saying what it is, shown when it is opened.
        public var about: String? = nil
        /// Mac shelf (15 Nov): how its newest version stands (in your Cloud, waiting here, still sending, not sent), so
        /// the shelf the phones read lists only what is really in the Cloud. Never shown.
        public var standing: CloudSyncContents.Standing = .inCloud
        /// Cloud file manager (15 Nov, owner: "I need folders shape ... go inside the folder"): the folders it sits in
        /// inside its kind, by name ("Terminal Deck", "Decker", "Notes"); empty = at the top of its kind. Set once by the
        /// builder (`BackendCloudManagerTree.folder`); never a path or an id.
        public var folder: [String] = []
        /// Cloud file manager: a setting's value in plain words ("On", "Dark"); nil for every other kind.
        public var value: String? = nil
    }
    /// Lane L4 (contracts §1): one earlier version of an item. Names and dates only; what it is on disk stays in the
    /// handle (`BackendCloudContentsHandle.versions`).
    public struct Version: Sendable, Equatable, Identifiable {
        /// Plain "<item id>|<at>|<n>": stable across refreshes, never shown.
        public let id: String
        public let at: Int64
        /// The Mac that made it, by name.
        public let device: String
        public let bytes: Int64?
        /// When it goes for good (30 days after it was replaced).
        public let keptUntil: Int64
        /// "Use this version" can make it the newest here.
        public var canUse: Bool = true
        /// CLOUD-FILES-2: another Mac's text that is NOT older than the note in use ("Different text from …").
        public var different: Bool = false
        /// CLOUD-FILES-2: Clean up may delete it (an older copy the store's guard allows; never different text).
        public var deletable: Bool = true
        /// CLOUD-FILES-4: its own title, only when it differs from the note in use (a note that replaced another may
        /// carry a new title). `at` is when its text was written, never the time it was replaced.
        public var title: String? = nil
        public init(id: String, at: Int64, device: String, bytes: Int64?, keptUntil: Int64, canUse: Bool = true, different: Bool = false, deletable: Bool = true,
                    title: String? = nil) {
            self.id = id; self.at = at; self.device = device; self.bytes = bytes; self.keptUntil = keptUntil; self.canUse = canUse
            self.different = different; self.deletable = deletable; self.title = title
        }
    }
    public struct Activity: Sendable, Equatable, Identifiable {
        public let id: String
        public let at: Int64
        public let text: String
        public let problem: Bool
    }
    public let devices: [Device]
    public var counts: [Kind: Int]
    public var items: [Item]
    public let activity: [Activity]
    /// Page-names lane: said ONCE near the top, which devices are still catching up (instead of "waiting on 1 other
    /// device" on every row). nil when every device is level.
    public var catchingUp: String? = nil
    /// Page-names lane: one line above a kind's list, in the same units and from the same source as Settings → Cloud
    /// ("On this Mac: 3,523 notes, 39,851 diary entries and 120 topics").
    public var kindLines: [Kind: String] = [:]
    /// Page-names lane: what has arrived but is not in this Mac's memory yet ("Arriving: 20,480 diary entries …").
    public var arriving: String? = nil
    /// Kinds shown in the sidebar: the six named ones always, "Other" only when it holds something.
    public var kinds: [Kind] { Kind.allCases.filter { ($0 != .other && $0 != .sessions) || (counts[$0] ?? 0) > 0 } }
    /// Lane L4: what is in the Bin, newest removal first. Memory's Bin only: the Cloud folder's Bin items are listed
    /// under "Cloud folder" (review 14 Nov, point 4).
    public var bin: [Item] { items.filter { BackendCloudNoteIdentity.isBin($0.state) } }
    /// Kinds whose Bin rows are listed under the kind itself, not in memory's Bin (lane L3: the Cloud folder, artifacts).
    public static let ownBin: Set<Kind> = []
    /// Review 14 Nov (point 4): "<Mac>'s newer <file> is in use; this Mac's version is kept until <date>", each with Show.
    public struct FolderReplaced: Sendable, Equatable, Identifiable {
        /// The file's path inside the Cloud folder. Never shown.
        public let id: String
        public let text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }
    public var folderReplaced: [FolderReplaced] = []
    /// Review 14 Nov (points 3 and 8): one plain line for each thing that holds Cloud folder files back or keeps them apart.
    public var folderLines: [String] = []
    /// Review 14 Nov (point 5): the questions exactly as shown, so one press answers what he saw and nothing else.
    public var memoryAnswer: DeckMemoryAnswer? = nil
    public var folderAnswer: CloudFolderAnswer? = nil
    /// Lane L3 slice 2: the artifacts' plain lines and their question, as the Cloud folder's.
    public var artifactsLines: [String] = []
    public var artifactsAnswer: CloudFolderAnswer? = nil
    /// Lane L4: every earlier version Clean up may delete (the button says this number; exactly what it deletes).
    public var versionsToClean: Int { memoryKeptCount ?? items.reduce(0) { $0 + $1.versions.filter(\.deletable).count } }
    /// One rule phase 2: the store's own count of kept texts (what "Clean up" removes), when changes are offered.
    public var memoryKeptCount: Int? = nil
    /// One rule phase 2: "Many notes are missing on this Mac. Nothing was removed from your other devices."
    public var missingLine: String? = nil
    /// Review round 2: the one question waiting for his answer ("62 notes were removed on MacBook Pro. Remove them here
    /// too?"), with "They are gone" and "Keep them". Shown even while `memoryChanges` is off; nil = nothing waits.
    public var answerLine: String? = nil
    /// CLOUD-FILES-2: changes to memory notes are offered (`BackendCloudFilesSwitch`); off = read only.
    public var memoryChanges: Bool = true
    public func items(_ kind: Kind, device: String? = nil, search: String = "") -> [Item] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            item.kind == kind && !BackendCloudNoteIdentity.isBin(item.state)
                && (device == nil || item.onDevices.contains(device!) || item.history.contains { $0.device == device! })
                && (words.isEmpty || item.name.lowercased().contains(words) || (item.place?.lowercased().contains(words) ?? false))
        }
    }
    /// Every string of the model, for the guard test and the tool.
    public var allText: [String] {
        var text: [String] = []
        for device in devices { text += [device.id, device.name, device.state] }
        for item in items {
            text += [item.id, item.name, item.place ?? "", item.changedBy, item.note ?? ""]
            text += item.presence
            text += item.onDevices
            text += item.history.map(\.device)
            text += item.versions.map(\.device)
            text += item.versions.compactMap(\.title)
        }
        for line in activity { text += [line.id, line.text] }
        text += [catchingUp ?? "", arriving ?? ""] + kindLines.values
        return text
    }
    /// `cloud.contents`: the same lists as plain data. Names, kinds, device names and times only.
    public func wireValue(itemLimit: Int = 500) -> NativeRPCValue {
        func time(_ at: Int64?) -> NativeRPCValue { at.map { .string(BackendCloudContentsWords.iso($0)) } ?? .null }
        let deviceWire: [NativeRPCValue] = devices.map {
            .object([.init("name", .string($0.name)), .init("thisMac", .bool($0.isThisMac)), .init("lastSent", time($0.lastSent)),
                     .init("lastReceived", time($0.lastReceived)), .init("lastSeen", time($0.lastSeen)), .init("state", .string($0.state))])
        }
        // Page-names lane: the same numbers and lines the window shows (a kind without one number carries its line).
        let kindWire: [NativeRPCValue] = kinds.map { kind in
            .object([.init("kind", .string(kind.title)), .init("count", counts[kind].map { .number(Double($0)) } ?? (kindLines[kind] == nil ? .number(0) : .null)),
                     .init("line", kindLines[kind].map(NativeRPCValue.string) ?? .null)])
        }
        let visibleItems = items.filter { !BackendCloudNoteIdentity.isBin($0.state) }
        let itemWire: [NativeRPCValue] = visibleItems.prefix(itemLimit).map { item in
            .object([.init("kind", .string(item.kind.title)), .init("name", .string(item.name)), .init("place", item.place.map(NativeRPCValue.string) ?? .null),
                     .init("changedBy", .string(item.changedBy)), .init("changedAt", time(item.changedAt)),
                     .init("on", .array(item.presence.map(NativeRPCValue.string))),
                     .init("history", .array(item.history.prefix(20).map { .object([.init("device", .string($0.device)), .init("at", time($0.at))]) })),
                     .init("note", item.note.map(NativeRPCValue.string) ?? .null),
                     // Lane L4: its one state and how many earlier versions are kept.
                     .init("state", .string(BackendCloudFilesWords.state(item.state) ?? "In use")), .init("versionCount", .number(Double(item.versions.count)))])
        }
        let activityWire: [NativeRPCValue] = activity.prefix(200).map { .object([.init("at", time($0.at)), .init("text", .string($0.text))]) }
        return .object([.init("devices", .array(deviceWire)), .init("kinds", .array(kindWire)), .init("items", .array(itemWire)),
                        .init("itemsShown", .number(Double(min(visibleItems.count, itemLimit)))), .init("itemsTotal", .number(Double(visibleItems.count))),
                        .init("activity", .array(activityWire)),
                        .init("catchingUp", catchingUp.map(NativeRPCValue.string) ?? .null), .init("arriving", arriving.map(NativeRPCValue.string) ?? .null)])
    }
}

/// What the page's actions need for one item. Kept apart from the model (it carries ids) and never shown.
public struct BackendCloudContentsHandle: Sendable, Equatable {
    public let domain: String
    public let projectId: String?
    /// The item's path relative to its place, for a file (instruction files, memory files).
    public let relative: String?
    /// The settings folder an instruction file belongs to (`claude`, `codex` …), nil for a project's folder.
    public let home: CloudBootFilesPlaceKind?
    /// Lane L4: each earlier version's place in the memory folder, by the version's page id.
    public var versions: [String: String] = [:]
    public var sourceId: String? = nil
    public var recordId: String? = nil
}

/// Names this Mac already knows, handed in by the app: projects and agents by their id, saved passwords by their
/// record (names only, never a value).
public struct BackendCloudContentsNames: Sendable, Equatable {
    public var projects: [String: String]
    public var agents: [String: String]
    public var passwords: [String: String]
    /// Page-names lane: a note's or hand-off's own title by its place in the memory folder (never shown as a path).
    public var notes: [String: String]
    public var tasks: [String: String] = [:]
    /// Lane L4: this Mac's memory index, by a note's place in the memory folder: what each note is (in use, replaced by
    /// which note, removed). Empty = not known (then every earlier copy is listed as a version).
    public var noteFacts: [String: BackendCloudNoteFacts] = [:]
    /// Lane L4: the dated earlier copies this Mac keeps in its memory folder (`archive/versions/…`).
    public var keptCopies: Set<String> = []
    /// CLOUD-FILES-2: places this Mac deleted by Clean up / Empty Bin, and their former places (history from now on).
    public var deletedHere: Set<String> = []
    /// CLOUD-FILES-6: a project folder's own name → the registered project's name ("ClaudeCRM" → "CRM"), as the side
    /// panel names it (`NativeProjectNames`), so a job's desk named after its folder reads as the project.
    public var projectFolders: [String: String] = [:]
    /// One rule phase 2 (Memory seat): the ONE Bin and the kept earlier texts, from the memory store's keeper. Used
    /// while changes to memory notes are offered (`memoryChanges`); the page's actions call the store's functions.
    public var memoryBin: [DeckMemoryBinItem] = []
    public var memoryKept: [String: [DeckMemoryKeptVersion]] = [:]
    /// Exactly how many kept texts "Clean up" removes (`memoryCleanUpCount`); nil = not known.
    public var memoryKeptCount: Int? = nil
    /// The one line while many notes are missing on this Mac and nothing was sent.
    public var memoryMissingLine: String? = nil
    /// Review round 2: what waits for his answer (the page names the other Mac).
    public var memoryAnswer: DeckMemoryAnswer? = nil
    /// Lane L3 slice 1: what waits for his answer about the Cloud folder (the same two answers as memory).
    public var folderAnswer: CloudFolderAnswer? = nil
    /// Review 14 Nov (point 4): the Cloud folder's Bin on this Mac, its "newer one is in use" lines, and its page lines.
    public var folderBin: [CloudFolderKept] = []
    public var folderReplaced: [CloudVersionReplacedLine] = []
    public var folderLines: [String] = []
    /// Lane L3 slice 2: the artifacts' question, their Bin on this Mac and their page lines.
    public var artifactsAnswer: CloudFolderAnswer? = nil
    public var artifactsBin: [CloudFolderKept] = []
    public var artifactsLines: [String] = []
    /// Cloud file manager: each travelling setting's value in plain words, by its record (`setting:<key>` …), read from
    /// this Mac's own settings. Never a secret (sign-ins and keys never travel as settings).
    public var settingValues: [String: String] = [:]
    public init(projects: [String: String] = [:], agents: [String: String] = [:], passwords: [String: String] = [:], notes: [String: String] = [:]) {
        self.projects = projects; self.agents = agents; self.passwords = passwords; self.notes = notes
    }
}

public enum BackendCloudContentsWords {
    public static let openButton = "See what is in your Cloud"
    public static let windowTitle = "Your Cloud"
    public static let devicesTitle = "Devices"
    public static let browserTitle = "Everything in your Cloud"
    public static let activityTitle = "Activity"
    public static let thisMac = "This Mac"
    public static let upToDate = "Up to date"
    public static let paused = "Paused"
    public static let unknownDevice = "A device not on your list"
    public static let nothingYet = "Nothing of this kind is in your Cloud yet."
    public static let nothingMoved = "Nothing has moved yet."
    public static let signedOut = "Sign in to see what is in your Cloud."
    public static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
    public static func sending(_ count: Int) -> String { "Sending " + items(count) }
    public static func receiving(_ count: Int) -> String { "Receiving " + items(count) }
    public static func waiting(_ reason: String) -> String { "Waiting: " + reason }
    public static func notSeenSince(_ at: Int64) -> String { "Not seen since " + day(at) }
    public static let neverSeen = "Not seen yet"
    public static func changedBy(_ device: String) -> String { "Changed by " + device }
    public static func on(_ device: String, thisMac: Bool) -> String { thisMac ? "On this Mac" : "On " + device }
    public static let phone = "Phone"
    public static let browser = "Browser"
    public static func waitingOn(_ device: String, thisMac: Bool) -> String { thisMac ? "Waiting on this Mac" : "Waiting on " + device }
    public static let sendingFromThisMac = "Sending from this Mac"
    /// Proof 3 (13 Nov): the one short line in the list. An item this Mac holds says "On this Mac" (never "On every
    /// device"); otherwise the first line as it is. Page-names lane: which device is still catching up is said ONCE
    /// near the top of the window (`BackendCloudContents.catchingUp`), never repeated on every row; the detail panel
    /// still lists each device.
    public static func presenceLine(_ presence: [String]) -> String { presence.first ?? "" }
    public static let arrivingHere = "Arriving on this Mac"
    /// Item 5c: the one state of a note a newer note replaced.
    public static let replaced = "Replaced by a newer note"
    /// Owner, 14 Nov (item 5a: rows carried "lead", "agent", "hoot", "orchestrator"): where a memory file belongs, said
    /// as what he knows: the project's name, the agent's name, or both ("Terminal Deck · Decker"). Hoot's own memory is
    /// "Hoot". Never a folder's role word; nil when no name is known.
    public static func memoryPlace(_ path: String, names: BackendCloudContentsNames) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "archive" { parts.removeFirst() }
        guard parts.count >= 2 else { return nil }
        func named(_ value: String?) -> String? { plain(value) }
        switch parts[0] {
        case "projects":
            let project = named(names.projects[parts[1]])
            // CLOUD-FILES-4: a seat with no agent of that name on this Mac is said by its folder's words ("Shell design"),
            // so twenty seats' "Open items" are twenty rows told apart, never one name repeated.
            let agent = parts.count >= 4 && parts[2] == "roles" ? (named(names.agents[parts[3]]) ?? seatWords(parts[3])) : nil
            let said = [project, agent].compactMap { $0 }
            return said.isEmpty ? nil : said.joined(separator: " · ")
        case "roles":
            return named(names.agents[parts[1]])
        case "hoot":
            return named(names.agents["hoot"]) ?? "Hoot"
        case "templates":
            return nil
        default:
            // Another folder a person made ("team/decker/…"): the agent of that name, else the folder's own name, never a
            // role word.
            let roleWords: Set<String> = ["lead", "agent", "agents", "orchestrator", "hoot", "templates", "seat", "seats"]
            guard let folder = folderName(path), !roleWords.contains(folder.lowercased()) else { return nil }
            return named(names.agents[folder]) ?? folder
        }
    }
    /// CLOUD-FILES-4: a seat's folder name as words ("shell-design" → "Shell design"); nil when it is not plain.
    static func seatWords(_ folder: String) -> String? {
        // CLOUD-FILES-6 (owner: "Ai link", "Hr payroll"): never a re-capitalised guess; the folder's own name as it is.
        guard let text = plain(folder), BackendCloudPageWords.isPlain(text), BackendCloudContentsBuilder.safePiece(text) else { return nil }
        return text
    }
    /// CLOUD-FILES-4 (owner: rows "Imatch", "Deck dev", "Claudecrm"): a job's desk is a topic the app titles
    /// "Desk snapshot: Deck Dev (hand 1)". Said as what it is, "Desk · Deck Dev"; "(hand 1)" (which helper's desk) is
    /// left out of every title.
    public static func topicTitle(_ title: String) -> String {
        var said = title.replacingOccurrences(of: "\\s*\\(hand [0-9]+\\)$", with: "", options: .regularExpression)
        if let range = said.range(of: "^Desk snapshot:\\s*", options: .regularExpression), range.upperBound < said.endIndex {
            said = "Desk · " + String(said[range.upperBound...])
        }
        return said
    }
    /// Item 5b: a note's own title is his or an agent's words, so a web address or a dotted name in it ("onecollective.ae")
    /// does not turn it into a file name. Only what is truly code-like is refused: an id, a long run of hex, a path.
    public static func titleReads(_ text: String) -> Bool {
        let banned = ["[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}", "\\b[0-9a-fA-F]{8,}\\b", "(^|\\s)/[A-Za-z0-9._-]+/"]
        return !banned.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    /// Where a memory file belongs, as the one folder name a person gave it ("decker", "hoot"), never a path. The
    /// memory folder's own sorting folders and anything code-like are passed over. nil when nothing plain is left.
    public static func folderName(_ path: String) -> String? {
        let generic: Set<String> = ["notes", "topics", "handoffs", "projects", "roles", "leads", "team", "archive", "versions", "files", ""]
        for part in path.split(separator: "/").dropLast().reversed().map(String.init) where !generic.contains(part.lowercased()) {
            if let name = plain(part), BackendCloudPageWords.isPlain(name), !name.hasPrefix(".") { return name }
        }
        return nil
    }
    /// A note by its own title, never its file name. Without a title, the app's own file name is made readable: its
    /// date and the random ending it adds to keep names apart ("…-dtvjwi") are left out. nil when nothing plain is left.
    public static func noteName(_ path: String, titles: [String: String]) -> String? {
        if let title = plain(titles[path].map(topicTitle)), titleReads(title) {
            // Page-names 2 ("2026-11-02-app-domain-retired" was shown): a title that is itself a file name is made
            // readable the same way as a file name. A title the app cut at 60 characters is cut at a word.
            if looksLikeFileName(title) { return fileWords(title, cutAt: nil) ?? title }
            // Lane L4 (owner: "the details cut the note's own title although there is room"): the title in full; the
            // row wraps it to two lines. Only a title the app itself cut at 60 characters loses its last piece of a word.
            if title.count == appTitleLimit { return shortTitle(title, cut: true) }
            // CLOUD-FILES-4: a title longer than `plain`'s 120 characters is still his whole title (the row shows two
            // lines of it, the details all of it); only a single-line, code-free title is given in full.
            if title.hasSuffix("…"), let whole = titles[path].map(topicTitle)?.trimmingCharacters(in: .whitespacesAndNewlines),
               whole.count <= 400, !whole.contains("\n"), !looksLikeCode(whole), titleReads(whole) { return whole }
            return title
        }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return fileWords(stem, cutAt: appFileWordsLimit)
    }
    /// The app names a note's file "<date>-<at most 48 characters of its title>-<6 random letters>.md", and gives a note
    /// without a title the first 60 characters of its text as its title. Either may stop in the middle of a word.
    static let appFileWordsLimit = 48
    static let appTitleLimit = 60
    /// The longest title a row shows; a longer one is cut at a word and ends with "…".
    public static let titleLimit = 60
    /// A title for a row: at most `titleLimit` characters, cut only between words, ending with "…" when cut. `cut`: the
    /// text was already cut somewhere unknown (its last word may be a piece of a word), so that last piece is left out.
    public static func shortTitle(_ text: String, cut: Bool = false) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var shortened = cut && words.count > 1
        if shortened { words.removeLast() }
        while words.count > 1, words.joined(separator: " ").count > titleLimit - 1 { words.removeLast(); shortened = true }
        var said = words.joined(separator: " ")
        if said.count > titleLimit - 1 { said = String(said.prefix(titleLimit - 1)); shortened = true }
        guard shortened else { return said }
        while let last = said.last, ",;:-–—".contains(last) { said.removeLast() }
        return said + "…"
    }
    /// "2026-11-02-app-domain-retired": a dated, dash-joined name with no spaces.
    static func looksLikeFileName(_ text: String) -> Bool {
        !text.contains(" ") && text.range(of: "^[0-9]{4}-?[0-9]{2}-?[0-9]{2}([-_]|$)", options: .regularExpression) != nil
    }
    /// A file name's own words: its date and the random ending the app adds are left out, dashes become spaces, the
    /// first letter is a capital. `cutAt`: the length at which the app cut the words, so a name that long ends with "…".
    static func fileWords(_ name: String, cutAt: Int?) -> String? {
        var stem = name
        let dated = stem.range(of: "^[0-9]{4}-?[0-9]{2}-?[0-9]{2}", options: .regularExpression) != nil
        if dated {
            // Item 5b: a second copy's name ends "-<6 random letters>-2"; both endings are left out.
            stem = stem.replacingOccurrences(of: "-[a-z0-9]{6}(-[0-9]{1,3})?$", with: "", options: .regularExpression)
            stem = stem.replacingOccurrences(of: "^[0-9]{4}-?[0-9]{2}-?[0-9]{2}(-[0-9]{6})?-?", with: "", options: .regularExpression)
        }
        let cut = dated && cutAt.map { stem.count >= $0 - 1 } == true
        let words = stem.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard let text = plain(words), BackendCloudPageWords.isPlain(text) else { return nil }
        let short = shortTitle(text, cut: cut)
        return short.prefix(1).uppercased() + short.dropFirst()
    }
    /// Proof 3 (13 Nov): a dated earlier version of a memory file (`archive/versions/<path>.<yyyyMMdd-HHmmss>[-n].md`)
    /// or a copy kept at a conflict (`archive/cloud-conflicts/<store>/<hash>/<path>`) is history of the live file, never
    /// an item of its own. Returns the live file's path for such a copy, nil for any other path.
    public static func liveMemoryPath(ofEarlierCopy path: String) -> String? {
        let versions = "archive/versions/", conflicts = "archive/cloud-conflicts/"
        if path.hasPrefix(versions) {
            let rest = String(path.dropFirst(versions.count))
            let live = rest.replacingOccurrences(of: "\\.[0-9]{8}-[0-9]{6}(-[0-9]+)?(\\.md)$", with: "$2", options: .regularExpression)
            return live.isEmpty ? nil : live
        }
        if path.hasPrefix(conflicts) {
            let parts = path.dropFirst(conflicts.count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count > 2 else { return nil }
            return parts.dropFirst(2).joined(separator: "/")
        }
        return nil
    }
    public static func entries(_ count: Int) -> String { count == 1 ? "1 entry" : BackendCloudPageCounts.number(count) + " entries" }
    public static func held(_ count: Int) -> String {
        "Held: " + (count == 1 ? "1 item" : "\(count) items") + " from a device this Mac does not trust yet"
    }
    public static func couldNotUse(_ count: Int) -> String {
        "Could not use: " + (count == 1 ? "1 change from Cloud could not be checked" : "\(count) changes from Cloud could not be checked")
    }
    public static func couldNotSend(_ reason: String) -> String { "Could not send: " + reason }

    /// The count of one kind in a sentence: "4 memory notes", "1 instruction file".
    public static func count(_ kind: BackendCloudContents.Kind, _ number: Int) -> String {
        let (one, many): (String, String)
        switch kind {
        case .memory: (one, many) = ("memory note", "memory notes")
        case .projects: (one, many) = ("project", "projects")
        case .agents: (one, many) = ("agent", "agents")
        case .instructionFiles: (one, many) = ("instruction file", "instruction files")
        case .tasks: (one, many) = ("task", "tasks")
        case .settings: (one, many) = ("setting", "settings")
        case .passwords: (one, many) = ("saved password", "saved passwords")
        case .cloudFolder: (one, many) = ("file in your Cloud folder", "files in your Cloud folder")
        case .artifacts: (one, many) = ("artifact", "artifacts")
        case .sessions: (one, many) = ("chat", "chats")
        case .other: (one, many) = ("item", "items")
        }
        return number == 1 ? "1 " + one : "\(number) " + many
    }
    public static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return parts[0] + " and " + parts[1]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }

    /// A name only when it reads as words: no UUID, no long run of hex or code-like characters. nil otherwise.
    public static func plain(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Page-names 2: a long name is cut between words, never in the middle of one.
        if text.count > 120 {
            var cut = String(text.prefix(119))
            if let space = cut.lastIndex(where: { $0.isWhitespace }), cut.distance(from: cut.startIndex, to: space) > 60 { cut = String(cut[..<space]) }
            text = cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        return looksLikeCode(text) ? nil : text
    }
    /// True for anything that looks like an id, a key, a hash or a code.
    public static func looksLikeCode(_ text: String) -> Bool {
        let patterns = [
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            "[0-9a-fA-F]{12,}",
            "[A-Za-z0-9+=]{28,}",
            "\\b[A-Z0-9]{4}( [A-Z0-9]{4}){3,}\\b",
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    /// A reason sentence from the sync core, made plain: no bracketed codes, first clause, lower-case start.
    public static func reason(_ text: String?, fallback: String) -> String {
        guard var line = text else { return fallback }
        line = line.replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
        if let cut = line.firstIndex(where: { $0 == ";" || $0 == "." }) { line = String(line[..<cut]) }
        line = line.trimmingCharacters(in: .whitespaces)
        guard let first = line.first, let plain = plain(line), !line.contains("_") else { return fallback }
        return first.lowercased() + plain.dropFirst()
    }

    nonisolated(unsafe) private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM yyyy"); return f }()
    nonisolated(unsafe) private static let shortDayFormat: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM"); return f }()
    nonisolated(unsafe) private static let clockFormat: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    private static let lock = NSLock()
    public static func day(_ at: Int64) -> String {
        lock.withLock { dayFormat.string(from: Date(timeIntervalSince1970: Double(at) / 1000)) }
    }
    /// "Today, 14:02", "Yesterday, 09:10", "12 Nov, 14:02", "3 Feb 2025".
    public static func time(_ at: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(at) / 1000)
        return lock.withLock {
            let clock = clockFormat.string(from: date)
            if calendar.isDate(date, inSameDayAs: now) { return "Today, " + clock }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, " + clock }
            if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return shortDayFormat.string(from: date) + ", " + clock }
            return dayFormat.string(from: date)
        }
    }
    public static func iso(_ at: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(at) / 1000))
    }
    public static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

public enum BackendCloudContentsBuilder {
    /// A device not seen for this long reads "Not seen since …".
    public static let quietAfter: Int64 = 3 * 24 * 3_600_000
    static let textExtensions: Set<String> = ["md", "markdown", "txt", "json", "jsonc", "toml", "yaml", "yml", "mdc", "rules", "xml", "csv"]
    static let tableNames: [String: String] = [
        "notes": "Notes", "diary": "Diary", "handoffs": "Handoffs",
        "rewinds": "Rewinds", "questions": "Questions for you", "topics": "Topics", "files": "Memory file list", "settings": "Shared memory settings",
    ]
    static let homeNames: [CloudBootFilesPlaceKind: String] = [
        .claude: "Claude settings folder", .codex: "Codex settings folder", .gemini: "Gemini settings folder", .agents: "Agents settings folder",
    ]
    /// Page-names 3 (lead's decision, 13 Nov): the live status board is this Mac's own state and no longer travels. Its
    /// tables (memory row I03: board cards and their history) are never listed or counted on either page.
    static let boardTables: Set<String> = ["board", "board_history"]
    /// CLOUD-FILES-4 (owner: "Notes, 3,272 entries" and "Memory file list, 106 entries" listed as notes): the memory's
    /// own index tables. Each row of them only describes a file that is already its own row (a note, a topic, a hand-off,
    /// a card): `notes` (I05), `topics` (I05), `handoffs` (I04) and `files` (I05, the list of cards, playbooks and
    /// templates). Listing them shows every note twice; they are never a row and never counted here.
    /// CLOUD-FILES-6: and `rewinds` (I05), the store's own record of a conversation rewind, kept only so that rewind
    /// can be undone exactly (`DeckMemoryDatabase.swift:371`, `DeckMemoryStoreRewind.swift:7`): bookkeeping, not his.
    static let indexTables: Set<String> = ["notes", "topics", "handoffs", "files", "rewinds"]
    /// CLOUD-FILES-6: what a grouped memory row is, in one plain line shown when it is opened (never a table dump).
    static let tableAbout: [String: String] = [
        "diary": "Every message of your sessions, kept one entry each. Your agents' memory reads it; it is not a file to open.",
        "questions": "Questions your memory asked you while tidying up what it keeps.",
        "settings": "How your memory works on every device, kept as one set of settings.",
    ]
    static let boardDomain = "brain/memory/i03"
    static func passwordNoun(_ domain: String) -> String {
        switch CloudSecretsDomain(rawValue: domain) {
        case .apiKey: return "API key"
        case .server: return "Server login"
        case .ssh: return "SSH key"
        case .mcp: return "Tool server login"
        case .taskConnection: return "Task connection"
        case .receiver: return "Receiver login"
        case .browserCookies: return "Browser sign-in"
        case .browserPassword: return "Browser password"
        case .project: return "Project password"
        case .app: return "App password"
        case .aiSubscription: return "AI account sign-in"
        case nil: return "Saved password"
        }
    }

    /// What one record key is on the page: its kind, name and place, its grouping key and its action handle.
    /// nil = not shown (where a project lives on each device: this Mac's own bookkeeping).
    struct Shape {
        let kind: BackendCloudContents.Kind; let name: String; let place: String?; let group: String; let handle: BackendCloudContentsHandle; let isText: Bool; let grouped: Bool
        /// Proof 3: an earlier version of the live item in `group`; it adds to that item's history only.
        var earlier = false
        /// Page-names lane: the unit a grouped memory table is counted in on the pages (diary → diary entries).
        var unit: BackendCloudPageCounts.Unit?
        /// Lane L4: an earlier PLACE of the item only (its record, no text of its own here): history, never a version.
        var history = false
        /// Lane L4: the item's state (in use, put away, in the Bin).
        var state: BackendCloudNoteIdentity.State = .live
        /// CLOUD-FILES-2: another Mac's text not older than the note (shown inside it, never deleted).
        var different = false
        /// CLOUD-FILES-2: the newer archived copy of a note in use here (removed or replaced on another device).
        var elsewhere: String?
        /// CLOUD-FILES-6: a grouped row's plain line.
        var about: String?
    }
    static func shape(_ key: CloudSyncContents.Key, names: BackendCloudContentsNames, placements: [String: BackendCloudNoteIdentity.Placement] = [:]) -> Shape? {
        if key.recordId.hasPrefix("about/"),
           [CloudFolderFormat.domain, CloudArtifactsFormat.domain, CloudBootFilesFormat.domain].contains(key.domain) { return nil }
        let project = key.projectId.flatMap { names.projects[$0] }.flatMap(BackendCloudContentsWords.plain)
        func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }
        func isText(_ path: String) -> Bool { textExtensions.contains((path as NSString).pathExtension.lowercased()) }
        func handle(relative: String? = nil, home: CloudBootFilesPlaceKind? = nil) -> BackendCloudContentsHandle {
            var made = BackendCloudContentsHandle(domain: key.domain, projectId: key.projectId, relative: relative, home: home)
            made.sourceId = key.sourceId
            made.recordId = key.recordId
            return made
        }
        let domain = key.domain
        if domain == "machines/paths" { return nil }
        if domain == boardDomain { return nil }
        if domain.hasPrefix("brain/memory/") {
            if key.recordId.hasPrefix("row/") {
                let table = key.recordId.split(separator: "/").dropFirst().first.map(String.init) ?? ""
                if boardTables.contains(table) || indexTables.contains(table) { return nil }
                let name = tableNames[table] ?? "Memory entries"
                let kind: BackendCloudContents.Kind = table == "settings" ? .settings : .memory
                var made = Shape(kind: kind, name: name, place: nil, group: kind.rawValue + "|table|" + name, handle: handle(), isText: false, grouped: true)
                made.unit = BackendCloudPageCounts.unit(memoryTable: table)
                made.about = tableAbout[table]
                return made
            }
            let stored = key.recordId.hasPrefix("file/") ? String(key.recordId.dropFirst(5)) : key.recordId
            return memoryFile(stored, project: project, titles: names.notes, names: names, placement: placements[stored], handle: handle)
        }
        if domain.hasPrefix("brain/files/") {
            var path = key.recordId.hasPrefix("file/") ? String(key.recordId.dropFirst(5)) : key.recordId
            let row = domain.dropFirst("brain/files/".count).uppercased()
            let name = BackendCloudContentsWords.plain(fileName(path)) ?? "File"
            if row == CloudBootFilesFormat.inventoryRow {
                // "files/I09/home/claude/<token>" is an AI account's settings folder; otherwise the project's folder.
                let fields = key.sourceId.split(separator: "/").map(String.init)
                let home = fields.count >= 4 && fields[2] == "home" ? CloudBootFilesPlaceKind(rawValue: fields[3]) : nil
                let place = home.flatMap { homeNames[$0] } ?? project
                // CLOUD-FILES-4 (owner: an instruction file opened with no text): the record's key is
                // `file/<place>/<path inside the place>` (`BackendCloudBootFiles.sourceId`: "project/<token>" or
                // "home/<ai>/<token>"), so the path kept here began "project/<token>/" and the file was looked for at
                // "<project folder>/project/<token>/CLAUDE.md", which never exists. The path inside the place only.
                path = bootRelative(path)
                return Shape(kind: .instructionFiles, name: instructionName(path, home: home, agents: names.agents), place: place, group: "boot|" + (place ?? "") + "|" + path,
                             handle: handle(relative: path, home: home), isText: isText(path), grouped: false)
            }
            if row == "I08" { return memoryFile(path, project: project, titles: names.notes, names: names, placement: placements[path], handle: handle) }
            let kind: BackendCloudContents.Kind = .other
            return Shape(kind: kind, name: name, place: project, group: kind.rawValue + "|" + (project ?? "") + "|" + path, handle: handle(relative: path), isText: isText(path), grouped: false)
        }
        if domain == "projects" {
            // Proof 2 (13 Nov): the record is "project:<id>" (lane A2's record kind); the bare id is the older form.
            let id = recordOwnId(key.recordId, prefix: "project:")
            let name = BackendCloudContentsWords.plain(names.projects[id]) ?? project ?? "A project not on this Mac"
            return Shape(kind: .projects, name: name, place: nil, group: "projects|" + id, handle: handle(), isText: false, grouped: false)
        }
        if domain == "agents" {
            // "agent:<id>" and its instruction text "instruction:<id>.md" are ONE agent on the page.
            let id = recordOwnId(recordOwnId(key.recordId, prefix: "agent:"), prefix: "instruction:", suffix: ".md")
            let name = BackendCloudContentsWords.plain(names.agents[id]) ?? "An agent not on this Mac"
            return Shape(kind: .agents, name: name, place: project, group: "agents|" + id, handle: handle(), isText: false, grouped: false)
        }
        if domain == CloudFolderFormat.domain || domain == CloudArtifactsFormat.domain {
            let kind: BackendCloudContents.Kind = domain == CloudFolderFormat.domain ? .cloudFolder : .artifacts
            let prefix = "file/" + (kind == .cloudFolder ? CloudFileKind.cloudFolder.sourceId : CloudFileKind.artifacts.sourceId) + "/"
            let path = key.recordId.hasPrefix(prefix) ? String(key.recordId.dropFirst(prefix.count)) : key.recordId
            guard !path.hasPrefix("about/"), !path.hasSuffix(".tdabout") else { return nil }
            return Shape(kind: kind, name: BackendCloudContentsWords.plain(fileName(path)) ?? "File", place: project,
                         group: kind.rawValue + "|" + path, handle: handle(relative: path), isText: isText(path), grouped: false)
        }
        if domain == BackendCloudKindsTasks.domain {
            let id = recordOwnId(key.recordId, prefix: "task:")
            let name = BackendCloudContentsWords.plain(names.tasks[id]) ?? "A task not on this Mac"
            return Shape(kind: .tasks, name: name, place: project, group: "tasks|" + id, handle: handle(), isText: false, grouped: false)
        }
        if domain == BackendCloudKindsSettings.domain {
            // Cloud file manager (owner: "Settings ... show as ONE row"): one row per setting, named in plain words and
            // filed under the Settings page it belongs to (`BackendCloudManagerSettings`).
            let said = BackendCloudManagerSettings.name(recordId: key.recordId, names: names)
            return Shape(kind: .settings, name: said, place: nil, group: "settings|" + key.recordId, handle: handle(), isText: false, grouped: false)
        }
        if CloudSecretsDomain(rawValue: domain) != nil {
            // Names only: a saved password's value is never read here.
            let name = BackendCloudContentsWords.plain(names.passwords[key.recordId]) ?? passwordNoun(domain)
            return Shape(kind: .passwords, name: name, place: project, group: "passwords|" + key.recordId, handle: handle(), isText: false, grouped: false)
        }
        return Shape(kind: .other, name: "Item", place: project, group: "other|" + domain + "|" + key.recordId, handle: handle(), isText: false, grouped: false)
    }

    /// One memory file. Proof 3 (13 Nov): an earlier copy joins its live file's group (history only), and a file is
    /// keyed by its whole path, with its folder as the place when no project names it, so two files of the same name
    /// in different folders are two plainly different lines and one file is never listed twice.
    static func memoryFile(_ stored: String, project: String?, titles: [String: String] = [:], names: BackendCloudContentsNames = .init(),
                           placement: BackendCloudNoteIdentity.Placement? = nil,
                           handle: (String?, CloudBootFilesPlaceKind?) -> BackendCloudContentsHandle) -> Shape {
        // Lane L4: the note's own identity decides which item a record belongs to (`BackendCloudNoteIdentity`); without
        // it, only the dated and conflict copies are folded in, as before.
        let live = placement.map { $0.role == .item ? nil : $0.key } ?? BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: stored)
        let path = live ?? stored
        // Page-names lane: the note's own title, never its file name or folder path; "A note in <project>" otherwise.
        let agentFile = agentFileName(path, names: names)
        var name = agentFile ?? BackendCloudContentsWords.noteName(path, titles: titles) ?? (project.map { "A note in " + $0 } ?? "A note")
        // CLOUD-FILES-6: "Desk · ClaudeCRM" → "Desk · CRM": a desk named after a project's folder reads as the project.
        let desk = "Desk · "
        if name.hasPrefix(desk), let real = names.projectFolders[String(name.dropFirst(desk.count))].flatMap(BackendCloudContentsWords.plain) {
            name = desk + real
        }
        // Item 5a: the project's or agent's name, never a folder's role word ("lead", "agent", "hoot").
        var place = project ?? (agentFile != nil ? projectOnly(path, names: names) : BackendCloudContentsWords.memoryPlace(path, names: names))
        if let said = place, name.hasSuffix(" · " + said) { place = nil }
        var shape = Shape(kind: .memory, name: name, place: place, group: "memory|" + path, handle: handle(path, nil),
                          isText: textExtensions.contains((path as NSString).pathExtension.lowercased()), grouped: false)
        shape.earlier = live != nil
        shape.history = placement?.role == .history
        shape.different = placement?.role == .different
        shape.elsewhere = placement?.elsewhere
        shape.state = placement?.state ?? (live == nil && path.hasPrefix("archive/") ? .archived : .live)
        return shape
    }
    /// Lane L4 (owner: three rows named "Card", three "Checklist"): an agent's own file says whose it is: "Card · Decker",
    /// "Checklist · All Leads", "Card · Hoot". nil for a note (its title names it).
    static func agentFileName(_ path: String, names: BackendCloudContentsNames) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last, !parts.contains("notes"), !parts.contains("topics"), !parts.contains("handoffs") else { return nil }
        let word: String
        switch last.lowercased() {
        case "card.md": word = "Card"
        case "checklist.md": word = "Checklist"
        case "playbook.md": word = "Playbook"
        case "settings.md": word = "Settings"
        default: return nil
        }
        func titled(_ folder: String) -> String? {
            guard let plain = BackendCloudContentsWords.plain(folder), BackendCloudPageWords.isPlain(plain) else { return nil }
            return plain.prefix(1).uppercased() + plain.dropFirst()
        }
        let owner: String?
        if parts.first == "templates", parts.count == 3 {
            switch DeckMemoryCategory(rawValue: parts[1]) {
            // CLOUD-FILES-4 (owner: "Card · Hoot" twice): the orchestrator's template is the card every new Hoot starts
            // from, not Hoot's own card (`hoot/card.md`): "Default card · Hoot".
            case .orchestrator: return "Default " + word.lowercased() + " · " + (BackendCloudContentsWords.plain(names.agents["hoot"]) ?? "Hoot")
            case .lead: owner = "All Leads"
            case .agent: owner = "All Agents"
            case nil: owner = titled(parts[1])
            }
        } else if parts.first == "hoot" {
            owner = BackendCloudContentsWords.plain(names.agents["hoot"]) ?? "Hoot"
        } else if let roles = parts.firstIndex(of: "roles"), roles + 1 < parts.count - 1 {
            owner = BackendCloudContentsWords.plain(names.agents[parts[roles + 1]]) ?? titled(parts[roles + 1])
        } else if parts.first == "projects", parts.count >= 3, parts[2] == "lead" {
            owner = "Lead"
        } else if parts.first == "projects", parts.count == 3 {
            owner = BackendCloudContentsWords.plain(names.projects[parts[1]])
        } else {
            // Another folder a person made ("team/decker/checklist.md"): the agent of that name, else the folder's name.
            owner = BackendCloudContentsWords.folderName(path).flatMap { BackendCloudContentsWords.plain(names.agents[$0]) ?? titled($0) }
        }
        return owner.map { word + " · " + $0 } ?? word
    }
    /// The project an agent's file belongs to, by name (its agent is already in the file's name).
    static func projectOnly(_ path: String, names: BackendCloudContentsNames) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "projects", parts.count >= 3 else { return nil }
        return BackendCloudContentsWords.plain(names.projects[parts[1]])
    }
    /// CLOUD-FILES-4 (owner: "Never two identical rows"): two rows of one kind that would read the same (name and place)
    /// are told apart by where each one is inside its place: the folder words that differ ("Open items · Terminal Deck"
    /// → "Open items · Terminal Deck · Release"). Ids and file endings are never used.
    static func keepApart(_ items: inout [BackendCloudContents.Item], handles: [String: BackendCloudContentsHandle]) {
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where !BackendCloudNoteIdentity.isBin(item.state) {
            groups[item.kind.rawValue + "|" + item.name + "|" + (item.place ?? ""), default: []].append(index)
        }
        for indexes in groups.values where indexes.count > 1 {
            let folders = indexes.map { index -> [String] in
                let relative = handles[items[index].id]?.relative ?? ""
                return relative.split(separator: "/").dropLast().map(String.init).filter { !BackendCloudContentsWords.looksLikeCode($0) && safePiece($0) }
            }
            for (position, index) in indexes.enumerated() {
                // The first folder (from the end) in which this one differs from every other of the group.
                let mine = folders[position]
                let others = folders.enumerated().filter { $0.offset != position }.map(\.element)
                let differing = mine.reversed().first { part in others.allSatisfy { !$0.contains(part) } }
                let said = differing.flatMap { BackendCloudContentsWords.seatWords($0) ?? BackendCloudContentsWords.plain($0) }
                    ?? (items[index].changedAt > 0 ? BackendCloudContentsWords.time(items[index].changedAt) : nil)
                if let said { items[index].place = [items[index].place, said].compactMap { $0 }.joined(separator: " · ") }
            }
        }
    }
    /// A record kind's own id inside its record key (`project:<id>`, `instruction:<id>.md`); the key itself otherwise.
    static func recordOwnId(_ recordId: String, prefix: String, suffix: String = "") -> String {
        guard recordId.hasPrefix(prefix), recordId.hasSuffix(suffix), recordId.count > prefix.count + suffix.count else { return recordId }
        return String(recordId.dropFirst(prefix.count).dropLast(suffix.count))
    }
    /// CLOUD-FILES-4: an instruction file record's path inside its place: "project/<token>/x" → "x",
    /// "home/<ai>/<token>/x" → "x". A path without that start (older records, fixtures) is kept as it is.
    static func bootRelative(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2, BackendCloudBootFiles.parse(sourceId: parts[0] + "/" + parts[1])?.kind == .project { return parts.dropFirst(2).joined(separator: "/") }
        if parts.count > 3, let place = BackendCloudBootFiles.parse(sourceId: parts[0...2].joined(separator: "/")), place.kind != .project {
            return parts.dropFirst(3).joined(separator: "/")
        }
        return path
    }
    /// CLOUD-FILES-4 (owner: "SKILL.md" 17 times, "journal.md" 10 times): an instruction file named by what it is, from
    /// its place inside the project (or the AI's settings folder): "ui-ux-pro-max · Skill", "Decker · Agent",
    /// "Decker · Journal", "Instructions for Claude". Where no rule fits: its short path inside the project.
    static func instructionName(_ relative: String, home: CloudBootFilesPlaceKind? = nil, agents: [String: String] = [:]) -> String {
        // CLOUD-FILES-5 (Security blocker 3): a name comes from a Cloud record any signed-in device can write, and it
        // reaches the AI tools' output and the approval sentence the person answers. Every piece of the path must be a
        // short run of letters, digits, ".", "_" and "-" (no line break, no control or invisible character, no space
        // trick); the words made from a piece pass `plain` and the page's `isPlain`; the whole name passes `plain`.
        // Anything else is "File".
        let fallback = "File"
        guard let named = unsafeInstructionName(relative, home: home, agents: agents), let said = BackendCloudContentsWords.plain(named),
              said.count <= instructionNameLimit, !said.contains("…") else { return fallback }
        return said
    }
    static let instructionNameLimit = 120
    /// One piece of an instruction file's path that may become part of a name.
    static func safePiece(_ piece: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !piece.isEmpty && piece.count <= 64 && piece.unicodeScalars.allSatisfy { allowed.contains($0) && $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) }
    }
    /// A piece used as words (a skill, an agent, a seat): also plain and free of code-like runs.
    static func wordPiece(_ piece: String) -> String? {
        guard safePiece(piece), let plain = BackendCloudContentsWords.plain(piece), BackendCloudPageWords.isPlain(plain) else { return nil }
        return plain
    }
    static func unsafeInstructionName(_ relative: String, home: CloudBootFilesPlaceKind?, agents: [String: String] = [:]) -> String? {
        // A settings folder's files are the same kinds as a project's ".claude/…", ".codex/…" files.
        var path = relative
        switch home {
        case .claude?: path = ".claude/" + relative
        case .codex?: path = ".codex/" + relative
        case .gemini?: path = ".gemini/" + relative
        case .agents?: path = ".agents/" + relative
        case .project?, nil: break
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let file = parts.last, parts.allSatisfy(safePiece) else { return nil }
        // CLOUD-FILES-6 (owner: "Ai link", "Hr payroll"): an agent by its real name from this Mac's agent list when the
        // file belongs to a known agent ("0-decker" → "Decker"); otherwise the file's own name unchanged ("ai-link").
        func words(_ stem: String) -> String? {
            guard let piece = wordPiece(stem) else { return nil }
            let bare = piece.replacingOccurrences(of: "^[0-9]+[-_]", with: "", options: .regularExpression)
            for key in [piece, bare, bare.lowercased()] {
                if let known = agents[key].flatMap(BackendCloudContentsWords.plain), BackendCloudPageWords.isPlain(known),
                   !known.contains(where: { $0.isNewline }) { return known }
            }
            return piece
        }
        func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }
        /// A file's own name without its ending, as one more piece of the name.
        func own(_ name: String) -> String { let bare = stem(name); return bare.isEmpty ? name : bare }
        // Where no rule fits: the short path inside the project (each piece already checked), if it is short.
        let short = parts.joined(separator: "/")
        let shortOrNil: String? = short.count <= instructionNameLimit ? short : nil
        // The project's (or AI's) own instruction files, at the top or in a folder of the project.
        let main: [String: String] = ["CLAUDE.md": "Instructions for Claude", "AGENTS.md": "Instructions for Codex",
                                      "GEMINI.md": "Instructions for Gemini", "CLAUDE.local.md": "Your own instructions for Claude"]
        if let said = main[file] {
            let folder = parts.dropLast().filter { ![".claude", ".codex", ".gemini", ".agents"].contains($0) }
            return folder.isEmpty ? said : said + " · " + folder.joined(separator: "/")
        }
        // Skills: "<ai folder>/skills/<skill>/SKILL.md", and the skill's other files.
        if let at = parts.firstIndex(of: "skills"), at + 2 < parts.count, let skill = wordPiece(parts[at + 1]) {
            let ai = at > 0 ? parts[at - 1] : ""
            let whose = ai == ".agents" ? "Codex skill" : ai == ".gemini" ? "Gemini skill" : "Skill"
            if parts.count == at + 3, file == "SKILL.md" { return skill + " · " + whose }
            // CLOUD-FILES-6: "meta-ground-rules · Skill · autonomy" (the skill, then the file's own name).
            return skill + " · " + whose + " · " + own(file)
        }
        // Commands: "<ai folder>/commands/<name>.md".
        if let at = parts.firstIndex(of: "commands"), at + 2 == parts.count, let command = wordPiece(stem(file)) { return command + " · Command" }
        // Agents: "<ai folder>/agents/<name>.md" is the agent; "<ai folder>/agents/<name>/journal.md" its journal.
        if let at = parts.firstIndex(of: "agents"), at + 1 < parts.count, at == 0 || parts[at - 1].hasPrefix(".") {
            let rest = Array(parts[(at + 1)...])
            if rest.count == 1 { return words(stem(file)).map { $0 + " · Agent" } ?? shortOrNil }
            let owner = rest[0]
            if owner == "_retired" {
                guard rest.count >= 2, let who = words(rest.count == 2 ? stem(file) : rest[1]) else { return shortOrNil }
                return rest.count == 2 ? who + " · Retired agent" : who + " · Retired agent · " + own(file)
            }
            guard !owner.hasPrefix("_"), let who = words(owner) else { return shortOrNil }
            if rest.count == 2 {
                switch file.lowercased() {
                case "journal.md": return who + " · Journal"
                case "boot.md": return who + " · Start-up notes"
                case "card.md": return who + " · Card"
                case "lessons.md": return who + " · Lessons"
                default: return who + " · " + own(file)
                }
            }
            return who + " · " + own(file)
        }
        // A seat's folder: "team/<seat>/journal.md".
        if parts.count == 3, parts[0] == "team", let seat = words(parts[1]) {
            switch file.lowercased() {
            case "journal.md": return seat + " · Journal"
            case "card.md": return seat + " · Card"
            default: return seat + " · " + own(file)
            }
        }
        return shortOrNil
    }
    static func kindOf(domain: String) -> BackendCloudContents.Kind {
        if domain.hasPrefix("brain/memory/") || domain == "brain/files/i08" { return .memory }
        if domain == CloudBootFilesFormat.domain { return .instructionFiles }
        if domain == "projects" { return .projects }
        if domain == "agents" { return .agents }
        // Lane L3: tasks (I12) and his settings (I21; `native-state` is the older settings domain).
        if domain == BackendCloudKindsTasks.domain { return .tasks }
        if domain == BackendCloudKindsSettings.domain || domain == "native-state" { return .settings }
        if domain == CloudFolderFormat.domain { return .cloudFolder }
        if domain == CloudArtifactsFormat.domain { return .artifacts }
        if CloudSecretsDomain(rawValue: domain) != nil { return .passwords }
        return .other
    }

    /// nil while Cloud is not open for this Mac: then nothing is built and nothing was asked.
    /// `counts`: the ONE source of numbers shared with Settings → Cloud (page-names lane). Given, every number the window
    /// shows comes from it; nil (older callers) keeps the window's own grouping counts.
    public static func build(contents: CloudSyncContents, snapshot: CloudAccountSnapshot, names: BackendCloudContentsNames = .init(),
                             counts pageCounts: BackendCloudPageCounts? = nil,
                             positionMovedAt: [String: Int64]? = nil,
                             memoryChanges: Bool = true,
                             now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> (model: BackendCloudContents, handles: [String: BackendCloudContentsHandle])? {
        guard snapshot.visible(at: now) else { return nil }
        // Devices by name. This Mac is the row the account marks as this Mac.
        // 13 Nov leftover: a stale earlier entry of a device that signed in again is not one of the devices shown.
        let stale = Set(snapshot.trust.filter(\.stale).map(\.deviceId))
        let rows = snapshot.trust.filter { !$0.stale }
        let thisRow = rows.first { $0.standing == .thisMac }
        // Page-names lane (MacBook, 13 Nov: its own card was missing): this Mac is the sync core's own device first.
        let thisId = contents.thisDevice.isEmpty ? (thisRow?.deviceId ?? "") : contents.thisDevice
        // Page-names 2 (each Mac showed one card): every entry that IS this Mac (the sync core's device and the row the
        // account marks as this Mac, when the two differ) is ONE card, this Mac's, never a second card under another
        // name and never a card that hides the other device.
        let alsoThis: Set<String> = Set([thisRow?.deviceId].compactMap { $0 }.filter { $0 != thisId && !$0.isEmpty })
        // Owner, 14 Nov ("Changed by Asad s Mac mini"): a trust row's name went through the trust list's own filter
        // (`BackendCloudTrustRows.plainName`), which keeps only a straight apostrophe, so the Mac's own "’" became a
        // space. The device's real name, as Settings → Devices shows it, comes first; the trust row's name only for a
        // device the service no longer lists.
        var deviceName: [String: String] = [:]
        for device in snapshot.devices {
            if let shown = BackendCloudContentsWords.plain(device.shownName) { deviceName[device.deviceId] = shown }
        }
        for row in rows where deviceName[row.deviceId] == nil { deviceName[row.deviceId] = BackendCloudContentsWords.plain(row.name) ?? "A device" }
        for device in snapshot.devices where deviceName[device.deviceId] == nil { deviceName[device.deviceId] = "A device" }
        let thisName = deviceName[thisId] ?? alsoThis.compactMap { deviceName[$0] }.first ?? BackendCloudContentsWords.thisMac
        deviceName[thisId] = thisName
        for id in alsoThis { deviceName[id] = thisName }
        func name(_ id: String) -> String { deviceName[id] ?? BackendCloudContentsWords.unknownDevice }
        let lastSeen = Dictionary(snapshot.devices.map { ($0.deviceId, $0.lastSeenAt) }, uniquingKeysWith: max)
        // Proof 2 (13 Nov): how far each device has read the feed, as the service reports it. The service's "last seen"
        // moves only once an hour, so it alone left items "Waiting on" a device that had them long ago.
        let pulled = Dictionary(snapshot.devices.compactMap { device in device.lastPulledSeq.map { (device.deviceId, $0) } }, uniquingKeysWith: max)
        let heldIds = Set(contents.held.map(\.deviceId))
        // MAC-NEXT-11: a phone or a browser is a viewer: it holds no copy and reports no position. Its card says what it
        // is and when it was last seen, and it never counts as catching up or as a device an item waits on.
        let viewerKind: [String: String] = Dictionary(snapshot.devices.filter(\.isViewer).map {
            ($0.deviceId, $0.platform == .web ? BackendCloudContentsWords.browser : BackendCloudContentsWords.phone)
        }, uniquingKeysWith: { first, _ in first })
        var orderedSeen: Set<String> = []
        let ordered: [String] = ([thisId] + rows.map(\.deviceId).filter { $0 != thisId && !alsoThis.contains($0) }
            + snapshot.devices.map(\.deviceId).filter { id in id != thisId && !alsoThis.contains(id) && !stale.contains(id) && !rows.contains { $0.deviceId == id } })
            .filter { orderedSeen.insert($0).inserted }

        // Items, grouped as the page shows them.
        // Lane L4: memory files by the note's own identity: one item, its replaced copies as versions.
        var memoryNewest: [String: Int64] = [:]
        for item in contents.items where item.key.domain.hasPrefix("brain/memory/") || item.key.domain == "brain/files/i08" {
            guard !item.key.recordId.hasPrefix("row/") else { continue }
            let path = item.key.recordId.hasPrefix("file/") ? String(item.key.recordId.dropFirst(5)) : item.key.recordId
            memoryNewest[path] = max(memoryNewest[path] ?? 0, item.changes.map(\.at).max() ?? 0)
        }
        let placements = BackendCloudNoteIdentity.resolve(paths: Array(memoryNewest.keys), facts: names.noteFacts, newest: memoryNewest, deleted: names.deletedHere)
        // CLOUD-FILES-2: who made each memory record's newest change (for "Removed on <Mac>").
        var memoryAuthor: [String: String] = [:]
        for item in contents.items where !item.key.recordId.hasPrefix("row/") {
            let path = item.key.recordId.hasPrefix("file/") ? String(item.key.recordId.dropFirst(5)) : item.key.recordId
            if let newest = item.changes.max(by: { $0.at < $1.at }), newest.at >= (memoryNewest[path] ?? 0) { memoryAuthor[path] = newest.deviceId }
        }
        // Without this Mac's memory index (fixtures, older callers) every earlier copy counts as one kept here.
        let knowsFiles = !names.noteFacts.isEmpty || !names.keptCopies.isEmpty
        struct Building {
            var shape: Shape; var changes: [CloudSyncContents.Change] = []; var entries = 0; var standing = CloudSyncContents.Standing.inCloud; var reason: String?; var bytes: Int64?; var seq: CloudSequence?
            /// Proof 3: changes of earlier copies (history only), and whether the live item itself is here.
            var earlier: [CloudSyncContents.Change] = []
            var live = false
            /// Lane L4: earlier versions whose text this Mac holds: (place in the memory folder, newest change, size).
            var versions: [(path: String, change: CloudSyncContents.Change, bytes: Int64?, different: Bool)] = []
        }
        var groups: [String: Building] = [:]
        var keyGroup: [CloudSyncContents.Key: String] = [:]
        for item in contents.items {
            guard let shape = shape(item.key, names: names, placements: placements) else { continue }
            var entry = groups[shape.group] ?? Building(shape: shape)
            if shape.earlier {
                entry.earlier += item.changes
                let path = item.key.recordId.hasPrefix("file/") ? String(item.key.recordId.dropFirst(5)) : item.key.recordId
                if !shape.history, let newest = item.changes.max(by: { $0.at < $1.at }),
                   !knowsFiles || names.noteFacts[path] != nil || names.keptCopies.contains(path) {
                    entry.versions.append((path, newest, item.bytes, shape.different))
                }
                groups[shape.group] = entry
                continue
            }
            if !entry.live { entry.shape = shape; entry.live = true }
            entry.changes += item.changes
            entry.entries += 1
            if let seq = item.seq, entry.seq.map({ seq > $0 }) ?? true { entry.seq = seq }
            if entry.bytes == nil { entry.bytes = item.bytes } else if shape.grouped, let more = item.bytes { entry.bytes! += more }
            // The least settled entry decides the group's line.
            let rank: [CloudSyncContents.Standing: Int] = [.inCloud: 0, .sending: 1, .notSent: 2, .waitingHere: 3]
            if rank[item.standing]! > rank[entry.standing]! { entry.standing = item.standing; entry.reason = item.reason }
            groups[shape.group] = entry
            keyGroup[item.key] = shape.group
        }
        var items: [BackendCloudContents.Item] = []
        var handles: [String: BackendCloudContentsHandle] = [:]
        var counts: [BackendCloudContents.Kind: Int] = [:]
        var usedIds: Set<String> = []
        var pendingFor: [String: Int] = [:]
        for (_, entry) in groups.sorted(by: { $0.key < $1.key }) where entry.live {
            var seen: Set<String> = []
            let history = (entry.changes + entry.earlier).sorted { $0.at > $1.at }
                .filter { seen.insert($0.deviceId + "|" + String($0.at)).inserted }
                .prefix(entry.shape.grouped ? 50 : 200)
                .map { BackendCloudContents.Change(device: name($0.deviceId), at: $0.at) }
            guard let newest = entry.changes.max(by: { $0.at < $1.at }) else { continue }
            // Where it is: this Mac from its own standing; the author has it; another device has it once it checked
            // in after the change (it fetches then), else the change waits for it.
            var presence: [String] = [], on: [String] = []
            // Page-names lane: a table whose entries have arrived but are not in this Mac's memory yet is "Arriving",
            // never "On this Mac"; its number is what is really here, from the one shared source.
            let unit = entry.shape.unit
            let arrivingHere = unit.flatMap { pageCounts?.arriving[$0] } ?? 0
            if arrivingHere > 0 { presence.append(BackendCloudContentsWords.arrivingHere) }
            else { switch entry.standing {
            case .sending: presence.append(BackendCloudContentsWords.sendingFromThisMac); on.append(thisName)
            case .waitingHere: presence.append(BackendCloudContentsWords.waitingOn(thisName, thisMac: true))
            case .inCloud, .notSent: presence.append(BackendCloudContentsWords.on(thisName, thisMac: true)); on.append(thisName)
            } }
            for id in ordered where id != thisId && viewerKind[id] == nil {
                let device = name(id)
                let inCloud = entry.standing != .sending && entry.standing != .notSent
                let readPast = entry.seq.flatMap { seq in pulled[id].map { $0 >= seq } } ?? false
                if id == newest.deviceId || (inCloud && (readPast || (lastSeen[id] ?? 0) >= newest.at)) { presence.append(BackendCloudContentsWords.on(device, thisMac: false)); on.append(device) }
                else {
                    presence.append(BackendCloudContentsWords.waitingOn(device, thisMac: false))
                    // Only what is already in Cloud is on its way to that device.
                    if entry.standing != .sending && entry.standing != .notSent { pendingFor[id, default: 0] += 1 }
                }
            }
            var note: String?
            switch entry.standing {
            case .inCloud, .sending: note = nil
            case .notSent: note = BackendCloudContentsWords.couldNotSend(BackendCloudContentsWords.reason(entry.reason, fallback: "Cloud did not take it; it is tried again by itself"))
            case .waitingHere: note = BackendCloudContentsWords.waiting(BackendCloudContentsWords.reason(entry.reason, fallback: "it waits for something else to arrive first"))
            }
            if arrivingHere > 0, let unit { note = BackendCloudPageCounts.arriving([unit: arrivingHere]).map { String($0.dropFirst("Arriving: ".count)) } }
            let entries = entry.shape.grouped ? (unit.flatMap { pageCounts?.here[$0] } ?? entry.entries) : nil
            // Plain and stable across refreshes (the groups are walked in a fixed order), so a selection stays.
            var plainId = [entry.shape.kind.rawValue, entry.shape.place ?? "", entry.shape.handle.relative ?? entry.shape.name].joined(separator: "|")
            if BackendCloudContentsWords.looksLikeCode(plainId) { plainId = [entry.shape.kind.rawValue, entry.shape.place ?? "", entry.shape.name].joined(separator: "|") }
            let base = plainId
            var copy = 1
            while !usedIds.insert(plainId).inserted { copy += 1; plainId = base + " (\(copy))" }
            var made = BackendCloudContents.Item(id: plainId, kind: entry.shape.kind, name: entry.shape.name, place: entry.shape.place, changedBy: name(newest.deviceId),
                                                 changedAt: newest.at, presence: presence, onDevices: on, history: Array(history), bytes: entry.bytes,
                                                 entries: entries, note: note, isText: entry.shape.isText && entry.shape.kind != .passwords)
            var handle = entry.shape.handle
            // Lane L4: the item's state, its earlier versions (newest first, one per place), and what may be done with it.
            made.state = entry.shape.state
            made.standing = entry.standing
            var versionSeen: Set<String> = []
            // CLOUD-FILES-4: the same earlier text arrived twice (one Mac's archived copy and the other Mac's "-2" copy of
            // it: same title, same writing time) is ONE earlier version.
            var sameText: Set<String> = []
            // One rule phase 2: with changes offered, a memory item's earlier versions are the keeper's kept texts only
            // (the one place "Use this version" and Clean up work on); its copies in the memory folder stay history
            // there (the archived-notes settling keeps each replaced one as a kept text).
            let recordVersions = memoryChanges && entry.shape.kind == .memory ? [] : entry.versions
            for (index, version) in recordVersions.sorted(by: { $0.change.at != $1.change.at ? $0.change.at > $1.change.at : $0.path < $1.path }).enumerated()
                where versionSeen.insert(version.path).inserted {
                let fact = names.noteFacts[version.path]
                // Its own title when it differs from the note in use, and when its text was written (never the time it
                // was replaced: that is the archived file's own time).
                let ownTitle = entry.shape.kind == .memory ? BackendCloudContentsWords.noteName(version.path, titles: names.notes) : nil
                let title = ownTitle.flatMap { $0 == entry.shape.name || names.notes[version.path] == nil ? nil : $0 }
                let written = fact?.writtenAt.flatMap { $0 > 0 && $0 <= version.change.at ? $0 : nil } ?? version.change.at
                if let stamp = fact?.writtenAt, !sameText.insert((title ?? entry.shape.name) + "|" + String(stamp)).inserted { continue }
                let id = plainId + "|" + String(version.change.at) + "|" + String(index)
                // Read only while changes to memory notes wait (`BackendCloudFilesSwitch`).
                made.versions.append(.init(id: id, at: written, device: name(version.change.deviceId), bytes: version.bytes,
                                           keptUntil: version.change.at + BackendCloudNoteIdentity.keptFor, canUse: false,
                                           different: version.different, deletable: false, title: title))
                handle.versions[id] = version.path
            }
            if memoryChanges, entry.shape.kind == .memory, !entry.shape.grouped, let path = entry.shape.handle.relative {
                for (index, kept) in (names.memoryKept[path] ?? []).enumerated() {
                    let id = plainId + "|kept|" + String(kept.at) + "|" + String(index)
                    made.versions.append(.init(id: id, at: kept.at, device: kept.device.isEmpty ? BackendCloudContentsWords.unknownDevice : name(kept.device),
                                               bytes: kept.bytes, keptUntil: kept.keptUntil, canUse: true, different: false, deletable: true))
                    handle.versions[id] = BackendCloudFilesPlan.keptPrefix + kept.id
                }
                made.versions.sort { $0.at > $1.at }
            }
            let memoryPath = entry.shape.kind == .memory && !entry.shape.grouped ? entry.shape.handle.relative : nil
            made.deleteItems = BackendCloudDeletePage.targets(kind: made.kind, name: made.name, handle: handle, grouped: entry.shape.grouped)
            made.canRemove = !made.deleteItems.isEmpty && made.state == .live
            // One rule phase 2: Put back only for the ONE Bin (the store's keeper; its rows are added below).
            made.canPutBack = false
            if let moved = entry.shape.elsewhere {
                made.elsewhere = BackendCloudFilesWords.elsewhere(reason: names.noteFacts[moved]?.reason,
                                                                  device: memoryAuthor[moved].map(name) ?? "another device")
            }
            made.canOpen = memoryPath != nil || (entry.shape.kind == .instructionFiles && entry.shape.isText)
            // CLOUD-FILES-5: the file's own name only when it is one safe piece (it comes from a Cloud record).
            made.about = entry.shape.about
            if entry.shape.kind == .instructionFiles {
                made.fileName = entry.shape.handle.relative.map { ($0 as NSString).lastPathComponent }.flatMap { safePiece($0) ? $0 : nil }
            }
            items.append(made)
            handles[plainId] = handle
            if !BackendCloudNoteIdentity.isBin(made.state) { counts[entry.shape.kind, default: 0] += entry.shape.grouped ? entry.entries : 1 }
        }
        // One rule phase 2: the ONE Bin, from the memory store's keeper (removed here or on another device). A note an
        // earlier build archived with the reason "removed" is not a second Bin: it stays in the memory's archive.
        if memoryChanges {
            items.removeAll { BackendCloudNoteIdentity.isBin($0.state) }
            for binned in names.memoryBin {
                let id = "memory|bin|" + binned.path
                guard !usedIds.contains(id) else { continue }
                usedIds.insert(id)
                let by = BackendCloudFilesWords.removedBy(device: binned.device.isEmpty ? BackendCloudContentsWords.unknownDevice : name(binned.device), byAI: binned.byAI)
                var made = BackendCloudContents.Item(id: id, kind: .memory, name: binned.name, place: binned.place.map { names.projects[$0] ?? $0 }, changedBy: by,
                                                     changedAt: binned.removedAt, presence: [], onDevices: [], history: [], bytes: binned.bytes,
                                                     entries: nil, note: nil, isText: true)
                made.state = .inBin(removedAt: binned.removedAt)
                made.canPutBack = true
                made.canOpen = true
                items.append(made)
                handles[id] = BackendCloudContentsHandle(domain: "brain/memory", projectId: binned.place, relative: binned.path, home: nil)
            }
        }
        // Review 14 Nov (point 4): the Cloud folder's Bin, listed under "Cloud folder" (name, date, which Mac) with Put
        // back. Not behind the memory switch: putting back never removes anything.
        for binned in names.folderBin {
            let id = "cloudFolder|bin|" + binned.path
            guard !usedIds.contains(id) else { continue }
            usedIds.insert(id)
            let mac = deviceName.first { $0.key.lowercased() == binned.device.lowercased() }?.value ?? BackendCloudContentsWords.unknownDevice
            let by = BackendCloudFilesWords.removedBy(device: mac, byAI: false)
            var made = BackendCloudContents.Item(id: id, kind: .cloudFolder, name: BackendCloudContentsWords.plain(binned.name) ?? "File",
                                                 place: [binned.place, by].compactMap { $0 }.joined(separator: " · "), changedBy: by,
                                                 changedAt: binned.at, presence: [], onDevices: [], history: [], bytes: binned.bytes,
                                                 entries: nil, note: nil, isText: false)
            made.state = .inBin(removedAt: binned.at)
            made.canPutBack = true
            items.append(made)
            handles[id] = BackendCloudContentsHandle(domain: CloudFolderFormat.domain, projectId: nil, relative: binned.path, home: nil)
        }
        // Lane L3 slice 2: the artifacts' Bin, listed under "Artifacts" (name, project, which Mac) with Put back, as the
        // Cloud folder's.
        for binned in names.artifactsBin {
            let id = "artifacts|bin|" + binned.path
            guard !usedIds.contains(id) else { continue }
            usedIds.insert(id)
            let mac = deviceName.first { $0.key.lowercased() == binned.device.lowercased() }?.value ?? BackendCloudContentsWords.unknownDevice
            let by = BackendCloudFilesWords.removedBy(device: mac, byAI: false)
            var made = BackendCloudContents.Item(id: id, kind: .artifacts, name: BackendCloudContentsWords.plain(binned.name) ?? "Artifact",
                                                 place: [binned.place, by].compactMap { $0 }.joined(separator: " · "), changedBy: by,
                                                 changedAt: binned.at, presence: [], onDevices: [], history: [], bytes: binned.bytes,
                                                 entries: nil, note: nil, isText: false)
            made.state = .inBin(removedAt: binned.at)
            made.canPutBack = true
            items.append(made)
            handles[id] = BackendCloudContentsHandle(domain: CloudArtifactsFormat.domain, projectId: nil, relative: binned.path, home: nil)
        }
        items.sort { $0.changedAt != $1.changedAt ? $0.changedAt > $1.changedAt : $0.name < $1.name }
        keepApart(&items, handles: handles)
        // Cloud file manager: each row's folders inside its kind, and a setting's value, from the same read as the rows.
        for index in items.indices {
            items[index].folder = BackendCloudManagerTree.folder(of: items[index], handle: handles[items[index].id], names: names)
            if items[index].kind == .settings, let record = handles[items[index].id]?.recordId { items[index].value = names.settingValues[record] }
        }

        // Devices: last sent from the packs; this Mac's received from the arrival times; others' last check-in.
        var lastSent: [String: Int64] = [:], lastReceived: Int64?
        for pack in contents.packs {
            lastSent[pack.deviceId] = max(lastSent[pack.deviceId] ?? 0, pack.at)
            if let arrived = pack.arrivedAt { lastReceived = max(lastReceived ?? 0, arrived) }
        }
        // Page-names lane: one measure of "catching up" for every card, the same as Settings → Cloud's "changes still
        // to fetch": the places in your Cloud's list of changes a device has still to read (the Cloud's newest place
        // minus how far that device has read). Never a count of the window's own grouped rows.
        let behind = snapshot.behindBy ?? 0
        let head = snapshot.cloudHead.flatMap { UInt64($0.rawValue) }
        func toFetch(_ id: String) -> Int? {
            guard let head, let read = pulled[id].flatMap({ UInt64($0.rawValue) }) else { return nil }
            return head > read ? Int(clamping: head - read) : 0
        }
        // Page-names 2 ("394 changes still to fetch" when about 130 were left): a device's number is said only while
        // its reported position is current, i.e. it was seen to move within the last 3 minutes of this window's reads.
        // Otherwise it is "Catching up" with no number. Level is level whatever the age.
        // MAC-NEXT-7 (6): the service now says WHEN it received each device's position (`lastPulledAt`). That reported
        // time replaces the guess: recent (within 3 minutes) = the number is said; older = "Catching up" with no
        // number. An older service without the field keeps the guess below (the position seen moving lately).
        let pulledAt = Dictionary(snapshot.devices.compactMap { device in device.lastPulledAt.map { (device.deviceId, $0) } }, uniquingKeysWith: max)
        func shownCount(_ id: String, _ fetch: Int?) -> Int? {
            guard let fetch, fetch > 0 else { return fetch }
            if let reported = pulledAt[id] { return now - reported <= 180_000 ? fetch : nil }
            guard let positionMovedAt else { return fetch }
            guard let moved = positionMovedAt[id], now - moved <= 180_000 else { return nil }
            return fetch
        }
        var devices: [BackendCloudContents.Device] = []
        var stillCatchingUp: [(name: String, count: Int?)] = []
        for (index, id) in ordered.enumerated() {
            let isThis = id == thisId
            var state = BackendCloudContentsWords.upToDate, moving = false, look = false
            // Last seen: the newest of the service's check-in and the newest change it sent that this Mac holds.
            // MAC-NEXT-7 (E): and the time the service received its read position (`lastPulledAt`), which moves with
            // every fetch, so an active device never shows "Last seen" an hour ago.
            let seenAt = max(lastSeen[id] ?? 0, lastSent[id] ?? 0, pulledAt[id] ?? 0)
            if isThis {
                if snapshot.phase == .paused { state = BackendCloudContentsWords.paused }
                else if snapshot.problem != nil { state = BackendCloudContentsWords.waiting("Cloud can't be reached right now"); look = true }
                // Proof 3: while the first copy is prepared, its records are queued page by page; the queue is not "sending".
                // Page-names lane: prepared in full (n = m) is "Sending n changes", never "Preparing".
                else if let baseline = snapshot.baseline, baseline.preparing == true { state = BackendCloudOverviewWords.preparing(baseline); moving = true }
                else if contents.queued > 0 { state = BackendCloudPageWords.sending(contents.queued); moving = true }
                // Page-names 2: this Mac is named as catching up only when it really is behind the Cloud's list of
                // changes. Level, with memory still being added here, it says that instead.
                else if snapshot.catchingUp == true {
                    state = BackendCloudPageWords.catchingUp(behind > 0 ? behind : nil); moving = true
                    stillCatchingUp.append((BackendCloudContentsWords.thisMac, behind > 0 ? behind : nil))
                }
                else if pageCounts?.arrivingLine != nil { state = BackendCloudPageWords.addingHere; moving = true }
                else if let first = contents.notSent.first { state = BackendCloudContentsWords.waiting(BackendCloudContentsWords.reason(first.reason, fallback: "some items could not be sent")); look = true }
            } else if let kind = viewerKind[id] {
                state = kind
            } else {
                let fetch = toFetch(id)
                // Without a reported read position: still catching up while something in Cloud waits for it.
                let pending = fetch ?? ((pendingFor[id] ?? 0) > 0 ? -1 : 0)
                if heldIds.contains(id) { state = BackendCloudContentsWords.waiting("this Mac does not trust it yet"); look = true }
                else if seenAt <= 0 { state = BackendCloudContentsWords.neverSeen }
                else if now - seenAt > quietAfter { state = BackendCloudContentsWords.notSeenSince(seenAt) }
                else if pending != 0 {
                    let said = shownCount(id, fetch)
                    state = BackendCloudPageWords.catchingUp(said); moving = now - seenAt < 120_000
                    stillCatchingUp.append((name(id), said))
                }
            }
            devices.append(.init(id: "device-" + String(index + 1), name: name(id), isThisMac: isThis, lastSent: lastSent[id],
                                 lastReceived: isThis ? lastReceived : nil, lastSeen: isThis ? nil : (seenAt > 0 ? seenAt : nil),
                                 state: state, moving: moving, needsLook: look))
        }

        // Activity, newest first.
        var activity: [BackendCloudContents.Activity] = []
        func what(_ pack: CloudSyncContents.Pack) -> String {
            if pack.count.values.reduce(0, +) == 1, let key = pack.keys.first, let shape = shape(key, names: names), !shape.grouped {
                return shape.name + (shape.place.map { " for " + $0 } ?? "")
            }
            // Page-names lane: counted in what the person recognises. A memory pack's entries are diary entries (row
            // I02) or memory entries (every other memory row), never "memory notes" for rows that are not notes.
            var byKind: [BackendCloudContents.Kind: Int] = [:]
            var diary = 0, memoryEntries = 0
            for (domain, number) in pack.count where number > 0 && domain != boardDomain {
                let kind = kindOf(domain: domain)
                if kind == .memory { if domain == "brain/memory/i02" { diary += number } else { memoryEntries += number } }
                else { byKind[kind, default: 0] += number }
            }
            var parts: [String] = []
            if diary > 0 { parts.append(BackendCloudPageCounts.noun(.diary, diary)) }
            if memoryEntries > 0 { parts.append(BackendCloudPageCounts.number(memoryEntries) + (memoryEntries == 1 ? " memory entry" : " memory entries")) }
            parts += BackendCloudContents.Kind.allCases.compactMap { kind in byKind[kind].map { BackendCloudContentsWords.count(kind, $0) } }
            return BackendCloudContentsWords.list(parts)
        }
        for (index, pack) in contents.packs.enumerated() {
            let words = what(pack)
            guard !words.isEmpty else { continue }
            activity.append(.init(id: "sent-\(index)", at: pack.at, text: name(pack.deviceId) + " sent " + words, problem: false))
            if let arrived = pack.arrivedAt, pack.deviceId != thisId {
                activity.append(.init(id: "received-\(index)", at: arrived, text: thisName + " received " + words + " from " + name(pack.deviceId), problem: false))
            }
        }
        let heldCount = contents.held.reduce(0) { $0 + $1.operations }
        if heldCount > 0, let first = contents.held.map(\.firstSeenAt).max() {
            activity.append(.init(id: "held", at: first, text: BackendCloudContentsWords.held(heldCount), problem: true))
        }
        if !contents.refused.isEmpty, let at = contents.refused.map(\.firstAt).max() {
            activity.append(.init(id: "refused", at: at, text: BackendCloudContentsWords.couldNotUse(contents.refused.count), problem: true))
        }
        for (index, line) in contents.notSent.enumerated() {
            activity.append(.init(id: "not-sent-\(index)", at: line.since, text: BackendCloudContentsWords.couldNotSend(BackendCloudContentsWords.reason(line.reason, fallback: "Cloud did not take it")), problem: true))
        }
        activity.sort { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
        var kindLines: [BackendCloudContents.Kind: String] = [:]
        if let pageCounts {
            // Page-names lane: every number of the window from the one shared source; memory has no single number.
            counts = [:]
            for kind in BackendCloudContents.Kind.allCases {
                if let line = pageCounts.onThisMacLine(kind) { kindLines[kind] = line }
                if let number = pageCounts.count(kind) { counts[kind] = number }
            }
            // Saved passwords and other items are not in this Mac's memory or lists: their rows are what the window lists.
            for kind in [BackendCloudContents.Kind.passwords, .other] { counts[kind] = items.filter { $0.kind == kind }.count }
        }
        var made = BackendCloudContents(devices: devices, counts: counts, items: items, activity: Array(activity.prefix(300)))
        made.memoryChanges = memoryChanges
        if memoryChanges {
            made.memoryKeptCount = names.memoryKeptCount
        }
        made.folderAnswer = names.folderAnswer
        made.folderReplaced = names.folderReplaced.map { .init(id: String($0.itemId.dropFirst(BackendCloudFolder.kind.count + 1)), text: $0.sentence()) }
        made.folderLines = names.folderLines
        made.artifactsAnswer = names.artifactsAnswer
        made.artifactsLines = names.artifactsLines
        made.catchingUp = BackendCloudPageWords.stillCatchingUp(stillCatchingUp)
        made.kindLines = kindLines
        made.arriving = pageCounts?.arrivingLine
        return (made, handles)
    }
}
