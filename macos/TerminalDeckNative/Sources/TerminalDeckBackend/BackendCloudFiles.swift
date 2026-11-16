import Foundation
import TerminalDeckNativeCore

/// "Your Cloud" as a file manager (owner, 14 Nov: "a proper file manager"; lane L4 slice 1). One row per thing: a memory
/// note is ONE item however many replaced copies of it exist; the copies are its earlier versions, shown only inside it.
///
/// What a memory note's records are, decided from the note's OWN identity, never from its title:
/// - `archive/versions/<path>.<stamp>.md` and `archive/cloud-conflicts/<store>/<hash>/<path>`: earlier copies of `<path>`;
/// - `<name>-cloud-<16 hex>.md`: the copy another Mac's differing text was placed as beside `<name>.md`
///   (`DeckMemoryStoreCloudImport.cloudProjectFile`);
/// - an archived note replaced by a newer one (`archive_reason` superseded/merged/history and `superseded_by` = the
///   newer note's id): a version of the note at the end of that chain;
/// - an archived note's former place (`origin_path`): the same note. A move into `archive/` never sends a removal of the
///   old place (`DeckMemoryStoreCloudSource.cloudForgetRemovedFiles`: "never a cloud deletion"), so the Cloud and other
///   Macs still list the old place. Whichever of the two changed last is what the note is now (the one rule);
/// - an archived note removed by the person (`archive_reason` = removed): the note, in the Bin.
public struct BackendCloudNoteFacts: Sendable, Equatable {
    public let path: String
    public let id: String
    /// When it was archived (ms); nil for a note in use.
    public let archivedAt: Int64?
    public let reason: String?
    /// The id of the note that replaced it.
    public let supersededBy: String?
    /// Where it was before it was archived.
    public let origin: String?
    /// The file's own change time (ms).
    public let changedAt: Int64
    /// CLOUD-FILES-4: when its text was written (the note's own `date`, ms). An archived copy's file time is the time it
    /// was replaced, so an earlier version is dated by this instead. nil = not known.
    public var writtenAt: Int64?
    public init(path: String, id: String, archivedAt: Int64? = nil, reason: String? = nil, supersededBy: String? = nil, origin: String? = nil, changedAt: Int64,
                writtenAt: Int64? = nil) {
        self.path = path; self.id = id; self.archivedAt = archivedAt; self.reason = reason
        self.supersededBy = supersededBy; self.origin = origin; self.changedAt = changedAt; self.writtenAt = writtenAt
    }
}

public enum BackendCloudNoteIdentity {
    /// What one record is on the page: the item itself; an earlier version of it (older text, kept on this Mac);
    /// different text another Mac sent that is NOT older than the note in use (shown inside it, never deleted by Clean
    /// up); or only an earlier place of it (history: no row, no text of its own here).
    public enum Role: String, Sendable, Equatable { case item, version, different, history }
    public enum State: Sendable, Equatable, Hashable {
        case live
        /// Put away by hand, not replaced and not removed.
        case archived
        /// Removed by the person (`removedAt`).
        case inBin(removedAt: Int64)
    }
    public struct Placement: Sendable, Equatable {
        /// The item's own path (its group).
        public let key: String
        public let role: Role
        public let state: State
        /// For a note in use at its own place: the newer archived copy of it on another device (it was removed, replaced
        /// or put away there, and that removal has not travelled), so its row can say so ("Removed on MacBook Pro").
        public var elsewhere: String? = nil
    }
    public static let replacedReasons: Set<String> = ["superseded", "merged", "history"]
    /// CLOUD-FILES-4: the memory's own flow writes the reason WITH its why ("superseded: Note 13 corrects note 12",
    /// "done: <what answered it>", `DeckMemoryFlowPrompts.swift:261/268`), so only the word before ":" says what it was.
    public static func reasonWord(_ reason: String?) -> String? {
        guard let reason else { return nil }
        return reason.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
    /// CLOUD-FILES-4 (owner: "Memory index" rows): the memory's own index files are not his notes. `MEMORY.md` is the
    /// index of another AI's memory brought in by the import (a list of the other notes); it and the copies kept beside
    /// it are never a row and never counted.
    public static func isInternal(_ path: String) -> Bool {
        let base = conflictBase(path) ?? BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: path) ?? path
        return (base as NSString).lastPathComponent == "MEMORY.md"
    }
    /// The archive reason a Remove writes (`DeckMemoryStore.cloudFileRemove`).
    public static let removedReason = "removed"
    public static let keptFor: Int64 = 30 * 86_400_000

    /// `<name>-cloud-<16 hex>.md` → `<name>.md`; nil for any other path.
    public static func siblingBase(_ path: String) -> String? {
        guard let range = path.range(of: "-cloud-[0-9a-f]{16}\\.md$", options: .regularExpression) else { return nil }
        return String(path[..<range.lowerBound]) + ".md"
    }
    /// The note a conflict copy belongs to: a `-cloud-<16 hex>.md` copy beside it, or a copy under
    /// `archive/cloud-conflicts/` (`DeckMemoryStoreCloudImport`: another Mac's differing text). nil for anything else.
    public static func conflictBase(_ path: String) -> String? {
        if let base = siblingBase(path) { return base }
        guard path.hasPrefix("archive/cloud-conflicts/") else { return nil }
        return BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: path)
    }

    /// Every path's placement. `paths`: the records the page lists (memory files); `facts`: this Mac's memory index by
    /// path; `newest`: each record's newest change time (falls back to the file's own time); `deleted`: places this Mac
    /// deleted by Clean up or Empty Bin, and their former places (their Cloud records stay until a clean-up record
    /// travels): history, never a row again.
    public static func resolve(paths: [String], facts: [String: BackendCloudNoteFacts], newest: [String: Int64] = [:],
                               deleted: Set<String> = []) -> [String: Placement] {
        var byId: [String: String] = [:]
        for fact in facts.values.sorted(by: { $0.path < $1.path }) where byId[fact.id] == nil || fact.archivedAt == nil { byId[fact.id] = fact.path }
        var archivedFrom: [String: [String]] = [:]
        for fact in facts.values where fact.archivedAt != nil {
            if let origin = fact.origin, origin != fact.path { archivedFrom[origin, default: []].append(fact.path) }
        }
        func time(_ path: String) -> Int64 { newest[path] ?? facts[path]?.changedAt ?? 0 }
        /// A note in use at its own place on this Mac.
        func inPlace(_ path: String) -> Bool { facts[path].map { $0.archivedAt == nil } ?? false }
        func known(_ path: String) -> Bool { (facts[path] != nil || newest[path] != nil) && (!deleted.contains(path) || inPlace(path)) }
        var memo: [String: Placement] = [:]
        func copy(_ role: Role, of target: Placement) -> Placement { Placement(key: target.key, role: role, state: target.state) }
        func place(_ path: String, _ depth: Int) -> Placement {
            if let done = memo[path] { return done }
            guard depth < 24 else { return Placement(key: path, role: .item, state: .live) }
            let made: Placement
            if isInternal(path) {
                // CLOUD-FILES-4: the memory's own index file: never a row, never counted.
                made = Placement(key: path, role: .history, state: .live)
            } else if deleted.contains(path), !inPlace(path) {
                made = Placement(key: path, role: .history, state: .live)
            } else if let base = conflictBase(path) {
                // Another Mac's differing text: inside its note, an earlier version only when it is older than the note.
                if known(base) {
                    let note = place(base, depth + 1)
                    made = copy(time(path) < time(note.key) ? .version : .different, of: note)
                } else {
                    made = Placement(key: path, role: .item, state: .live)
                }
            } else if let live = BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: path) {
                // A dated copy kept before the file was replaced: always older.
                made = copy(.version, of: place(live, depth + 1))
            } else if let fact = facts[path] {
                if fact.archivedAt == nil {
                    // A file in its own place is never a version, on any Mac. When another Mac moved it away (its removal
                    // does not travel), the row says so.
                    var live = Placement(key: path, role: .item, state: .live)
                    live.elsewhere = (archivedFrom[path] ?? []).filter { time($0) >= time(path) }.max { time($0) < time($1) }
                    made = live
                } else {
                    made = archived(fact, depth)
                }
            } else if let moved = (archivedFrom[path] ?? []).max(by: { time($0) < time($1) }) {
                // A record of a place this Mac has no file at, whose note was archived here: put back on another device
                // when its record is newer (then it is the item), else an earlier place of the archived note.
                made = time(path) > time(moved) ? Placement(key: path, role: .item, state: .live) : copy(.history, of: place(moved, depth + 1))
            } else if path.hasPrefix("archive/") {
                // An archived copy this Mac has no index row for: it belongs to the place it was archived from.
                var origin = String(path.dropFirst("archive/".count))
                if !known(origin), let counter = origin.range(of: "-[0-9]{1,3}\\.md$", options: .regularExpression),
                   known(String(origin[..<counter.lowerBound]) + ".md") { origin = String(origin[..<counter.lowerBound]) + ".md" }
                // CLOUD-FILES-4: nothing replaced it and it is not in use: not a row (never "On this Mac").
                made = known(origin) ? copy(.history, of: place(origin, depth + 1)) : Placement(key: path, role: .history, state: .archived)
            } else {
                made = Placement(key: path, role: .item, state: .live)
            }
            memo[path] = made
            return made
        }
        func archived(_ fact: BackendCloudNoteFacts, _ depth: Int) -> Placement {
            let reason = reasonWord(fact.reason) ?? "archived"
            // CLOUD-FILES-4 (Mac mini, 14 Nov: a replaced note was its own row "Put away" because its reason was
            // "superseded: <why>"): any note archived with the note that replaced it named (`superseded_by`), whatever
            // the reason's words, is an earlier version of that note. Only a removal is not.
            if reason != removedReason, let next = fact.supersededBy.flatMap({ byId[$0] }), next != fact.path, known(next) {
                let target = place(next, depth + 1)
                return target.role == .history ? Placement(key: fact.path, role: .history, state: .archived) : copy(.version, of: target)
            }
            if let origin = fact.origin, origin != fact.path, known(origin), facts[origin]?.archivedAt == nil {
                // Its former place still holds the note in use on this Mac: that row is the item (it says where it was
                // moved away). This copy is its older text when the note changed since, else only where it went.
                if inPlace(origin) { return copy(time(origin) > time(fact.path) ? .version : .history, of: place(origin, depth + 1)) }
                // Put back on another device: its former place is in use again there, and newer.
                if time(origin) > time(fact.path) { return copy(.version, of: place(origin, depth + 1)) }
            }
            if reason == removedReason { return Placement(key: fact.path, role: .item, state: .inBin(removedAt: fact.archivedAt ?? fact.changedAt)) }
            // CLOUD-FILES-4: put away with nothing that replaced it: not a note in use, so not a row and not counted. In
            // this read-only slice it shows nowhere on the page (it stays in the memory's archive folder).
            return Placement(key: fact.path, role: .history, state: .archived)
        }
        var all: [String: Placement] = [:]
        for path in Set(paths).union(facts.keys) { all[path] = place(path, 0) }
        return all
    }

    /// THE definition of "N notes" (both pages): notes that are items, in use or put away, never a replaced copy, a
    /// conflict copy, a note in the Bin or a place this Mac deleted.
    public static func itemCount(_ facts: [String: BackendCloudNoteFacts], deleted: Set<String> = []) -> Int {
        resolve(paths: [], facts: facts, deleted: deleted).filter { facts[$0.key] != nil && $0.value.role == .item && !isBin($0.value.state) }.count
    }
    public static func isBin(_ state: State) -> Bool { if case .inBin = state { return true }; return false }
}

/// One rule phase 2 (Memory seat): ONE Bin and ONE delete path. Nothing on the page works out file paths to delete any
/// more: Empty Bin and Clean up call the memory store (`memoryEmptyBin`, `memoryCleanUpVersions`), which decides by the
/// Cloud's revision order and never by a file date. A kept text's handle on the page is its keeper id.
public enum BackendCloudFilesPlan {
    public static let keptPrefix = "kept:"
    /// The keeper id of a version handle ("kept:<sha256>"); nil for a copy in the memory folder (read-only history).
    public static func keptId(_ handle: String?) -> String? {
        guard let handle, handle.hasPrefix(keptPrefix) else { return nil }
        let id = String(handle.dropFirst(keptPrefix.count))
        return id.utf8.count == 64 && id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) ? id : nil
    }
}

/// The page's words for the file manager. Names, dates and one state; nothing technical.
public enum BackendCloudFilesWords {
    /// The one rule, said once at the top of the page.
    public static let oneRule = "The newest version is used on all your devices. Earlier ones are kept for 30 days."
    public static func cleanUp(_ count: Int) -> String {
        count == 1 ? "Clean up 1 earlier version" : "Clean up " + BackendCloudPageCounts.number(count) + " earlier versions"
    }
    public static let nothingToClean = "No earlier versions"
    public static let bin = "Bin"
    public static let binSymbol = "trash"
    public static let earlierVersions = "Earlier versions"
    public static let useThisVersion = "Use this version"
    public static let remove = "Remove"
    public static let putBack = "Put back"
    public static let emptyBin = "Empty Bin"
    public static let undo = "Undo"
    public static let removing = "Removing…"
    public static let emptying = "Emptying the Bin…"
    public static let cleaning = "Cleaning up…"
    public static let binEmpty = "The Bin is empty."
    public static let current = "In use now"
    public static let notReadable = "Nothing to read here."
    /// One state per row, in plain words.
    public static func state(_ state: BackendCloudNoteIdentity.State) -> String? {
        switch state {
        case .live: return nil
        case .archived: return "Put away"
        case .inBin: return "In the Bin"
        }
    }
    /// A Bin row's date. Once removals travel (the switch): "Leaves your devices on 14 Dec" (the Cloud keeps every
    /// version, so nothing is ever said to be deleted). Until then only the true date is said: "Removed 14 Nov".
    public static func goesOn(_ removedAt: Int64, travels: Bool = true, timeZone: TimeZone = .current) -> String {
        travels ? "Leaves your devices on " + CloudVersionReplacedLine.day(removedAt + BackendCloudNoteIdentity.keptFor, timeZone: timeZone)
                : "Removed " + CloudVersionReplacedLine.day(removedAt, timeZone: timeZone)
    }
    /// Who removed a Bin item: "Removed on Mac mini", or "Removed by an AI on Mac mini" (never shown as his own).
    public static func removedBy(device: String, byAI: Bool) -> String {
        (byAI ? "Removed by an AI on " : "Removed on ") + device
    }
    /// A version row: "Today, 3:00 AM · MacBook Pro"; another Mac's text that is not older than the note in use:
    /// "Different text from MacBook Pro · Today, 3:00 AM".
    public static func version(_ version: BackendCloudContents.Version, now: Date = Date()) -> String {
        version.different ? "Different text from " + version.device + " · " + BackendCloudContentsWords.time(version.at, now: now)
                          : BackendCloudContentsWords.time(version.at, now: now) + " · " + version.device
    }
    /// CLOUD-FILES-4: an earlier version whose title differs from the note in use says its own title above its date
    /// ("Earlier: … phone sheets have a flat bottom"), so it never reads as a different note mixed in.
    public static func versionTitle(_ version: BackendCloudContents.Version) -> String? {
        version.title.map { "Earlier: " + $0 }
    }
    /// CLOUD-FILES-6: the details' header line while an earlier version is chosen: its own Mac and time.
    public static func chosenVersion(_ version: BackendCloudContents.Version, now: Date = Date()) -> String {
        version.different ? "Different text from " + version.device + " · " + BackendCloudContentsWords.time(version.at, now: now)
                          : "Earlier version from " + version.device + " · " + BackendCloudContentsWords.time(version.at, now: now)
    }
    /// A note in use here that another Mac removed, replaced or put away (that change has not reached this Mac's memory).
    public static func elsewhere(reason: String?, device: String) -> String {
        switch BackendCloudNoteIdentity.reasonWord(reason) {
        case BackendCloudNoteIdentity.removedReason: return "Removed on " + device
        case let reason? where BackendCloudNoteIdentity.replacedReasons.contains(reason): return "Replaced on " + device
        default: return "Put away on " + device
        }
    }
    /// What an item is called in a sentence: "the memory note “Plan” (Terminal Deck)".
    public static func named(_ item: BackendCloudContents.Item) -> String {
        let noun: String
        switch item.kind {
        case .memory: noun = "memory note"
        case .instructionFiles: noun = "instruction file"
        case .projects: noun = "project"
        case .agents: noun = "agent"
        case .tasks: noun = "task"
        case .settings: noun = "setting"
        case .passwords: noun = "saved password"
        case .cloudFolder: noun = "file in your Cloud folder"
        case .artifacts: noun = "artifact"
        case .sessions: noun = "chat"
        case .other: noun = "item"
        }
        return "the " + noun + " “" + item.name + "”" + (item.place.map { " (" + $0 + ")" } ?? "")
    }
    // The approval lines of the tools: exactly what changes, by name and kind, never an id.
    /// Once removals travel (the switch): removed from your devices, in the Bin for 30 days. Until then: this Mac only.
    public static func approveRemove(_ item: BackendCloudContents.Item, travels: Bool = true) -> String {
        travels ? "Remove " + named(item) + " from your devices: it goes to the Bin and can be put back for 30 days"
                : "Remove " + named(item) + " from this Mac's memory: it goes to this Mac's Bin; your other devices follow later"
    }
    /// `cloud.remove`'s description, true for the switch it is registered under.
    public static func removeToolDescription(travels: Bool) -> String {
        (travels ? "Removes a memory note from your devices: it goes to the Bin and can be put back for 30 days"
                 : "Moves a memory note to this Mac's Bin (your other devices follow later)")
            + " and put back with cloud_restore. Only memory notes in use can be removed for now; saved passwords, devices and the account are never removed here. Asks the person first."
    }
    public static func approvePutBack(_ item: BackendCloudContents.Item) -> String { "Put back " + named(item) + " from the Bin" }
    public static func approveUseVersion(_ item: BackendCloudContents.Item, _ version: BackendCloudContents.Version) -> String {
        "Use the version of " + named(item) + " from " + BackendCloudContentsWords.time(version.at) + " (" + version.device
            + "): it becomes the newest on all your devices; the version it replaces is kept for 30 days"
    }
    /// The owner's own answer, every time: the line states exactly how many items go.
    public static func approveEmptyBin(_ items: [BackendCloudContents.Item]) -> String {
        let names = items.prefix(5).map { "“" + $0.name + "”" }
        let more = items.count > 5 ? " and \(items.count - 5) more" : ""
        return "Empty the Bin: " + (items.count == 1 ? "1 item, " : "\(items.count) items, ") + BackendCloudContentsWords.list(names) + more
            + ", removed from your devices now. They can no longer be put back"
    }
    /// The owner's own answer, every time: the line states exactly how many kept texts go.
    public static func approveCleanUp(_ count: Int) -> String {
        "Remove " + (count == 1 ? "1 earlier version" : BackendCloudPageCounts.number(count) + " earlier versions")
            + " from your devices now instead of after 30 days. Nothing in use is touched"
    }
    public static func emptied(_ count: Int) -> String {
        count == 1 ? "The Bin was emptied: 1 item removed from your devices." : "The Bin was emptied: \(count) items removed from your devices."
    }
    public static func cleaned(_ count: Int) -> String {
        count == 1 ? "1 earlier version was removed from your devices." : "\(count) earlier versions were removed from your devices."
    }
}

/// Presentation and routing shared by the existing rows and the manual Bin. No file operations live here.
public enum BackendCloudDeletePage {
    public static func kind(_ item: CloudDeleteItem) -> BackendCloudContents.Kind {
        switch item.kind {
        case "memory": .memory
        case "cloudFolder": .cloudFolder
        case "artifacts": .artifacts
        case "boot": .instructionFiles
        case "task": .tasks
        case "agent": .agents
        case "project": .projects
        case "saved-passwords", "mcp-servers", "project-secret-files": .passwords
        case BackendCloudChatsDeleteOwner.kind: .sessions
        default: .other
        }
    }
    /// The kinds of the secrets lane (L3): saved passwords and MCP servers are owned per source, so they route by
    /// kind and source; every other kind has one owner.
    public static let secretKinds: Set<String> = ["saved-passwords", "mcp-servers"]
    /// The bin buttons a row (or a selection) offers, in order. They follow the delete gate: "Cloud" only while it is
    /// open and never for tasks and agents (always removed everywhere); saved passwords offer none while it is closed
    /// (their removal would not travel then). An owner that cannot delete right now is left out by the page.
    public static func scopes(for kinds: [BackendCloudContents.Kind], gateOpen: Bool) -> [CloudDeleteScope] {
        if !gateOpen, kinds.contains(.passwords) { return [] }
        // Chats: "Everywhere" only. No device keeps a copy of a chat (phones and other Macs read it from the Cloud), so
        // "Cloud, your devices keep their copies" would mean nothing; the AI's own history file stays untouched.
        return gateOpen && !kinds.contains { $0 == .tasks || $0 == .agents || $0 == .sessions } ? [.cloud, .everywhere] : [.everywhere]
    }
    public static func route(_ item: CloudDeleteItem) -> String {
        secretKinds.contains(item.kind) ? "secrets|" + (item.place ?? "") : item.kind
    }
    public static func targets(kind: BackendCloudContents.Kind, name: String, handle: BackendCloudContentsHandle, grouped: Bool = false) -> [CloudDeleteItem] {
        guard !grouped, kind != .settings, let record = handle.recordId else { return [] }
        let id: String, ownerKind: String
        switch kind {
        case .memory:
            guard let path = handle.relative else { return [] }
            id = "memory:" + path; ownerKind = "memory"
        case .cloudFolder, .artifacts:
            guard let path = handle.relative else { return [] }
            id = path; ownerKind = kind.rawValue
        case .instructionFiles:
            guard let path = handle.relative else { return [] }
            // Boot's owner uses the place encoded in the record, not the inventory source's outer prefix.
            let pathPrefix = "file/"
            guard record.hasPrefix(pathPrefix), record.hasSuffix("/" + path) else { return [] }
            let source = String(record.dropFirst(pathPrefix.count).dropLast(path.count + 1))
            id = source + "\n" + path; ownerKind = "boot"
        case .projects: id = record.hasPrefix("project:") ? record : "project:" + record; ownerKind = "project"
        case .agents:
            let own = record.hasPrefix("instruction:") ? String(record.dropFirst("instruction:".count)).replacingOccurrences(of: ".md", with: "")
                : record.hasPrefix("agent:") ? String(record.dropFirst("agent:".count)) : record
            id = "agent:" + own; ownerKind = "agent"
        case .tasks: id = record; ownerKind = "task"
        case .passwords:
            // L3 owner routing: the record id, kind by domain, the source as place (`deleteOwner(sourceId:)`).
            guard let source = handle.sourceId else { return [] }
            return [.init(id: record, kind: handle.domain == CloudSecretsDomain.mcp.rawValue ? "mcp-servers" : "saved-passwords",
                          name: name, place: source)]
        case .settings, .sessions, .other: return []
        }
        return [.init(id: id, kind: ownerKind, name: name, place: handle.relative)]
    }
    public static func key(_ item: CloudDeleteItem) -> String { item.kind + "|" + item.id }
    /// A Bin row gets its own "Put back" when its owner can put back exactly that one item: memory, the Cloud folder,
    /// artifacts and tasks always; instruction files, agents, projects and the sealed Bin put back by whole removal, so only when the
    /// row is that owner's whole part of it. "Put back all" is always offered.
    public static func canPutBackAlone(_ item: CloudDeleteItem, in group: CloudBinGroup) -> Bool {
        if ["memory", "cloudFolder", "artifacts", "task", BackendCloudChatsDeleteOwner.kind].contains(item.kind) { return true }
        guard ["boot", "agent", "project", "project-secret-files"].contains(item.kind) || secretKinds.contains(item.kind) else { return false }
        return group.items.filter { route($0) == route(item) }.count == 1
    }
    public static func merge(_ groups: [CloudBinGroup]) -> [CloudBinGroup] {
        var result: [String: CloudBinGroup] = [:]
        for group in groups where !group.items.isEmpty {
            let previous = result[group.id]
            var seen: Set<String> = []
            let items = ((previous?.items ?? []) + group.items).filter { seen.insert(key($0)).inserted }
            result[group.id] = .init(id: group.id, by: group.by, macName: group.macName, session: group.session, agent: group.agent,
                                     at: max(previous?.at ?? 0, group.at), items: items, era: group.era)
        }
        return result.values.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
    }
    public static func groupLine(_ group: CloudBinGroup, now: Date = Date()) -> String {
        let mac = BackendCloudContentsWords.plain(group.macName) ?? "another device"
        let title: String
        switch group.era {
        case .beforeNewRule: title = CloudDeleteWords.beforeNewRule
        case .olderVersion: title = CloudDeleteWords.removedOlderVersion(on: mac)
        case .current: title = group.by == .ai ? CloudDeleteWords.removedByAI(on: mac) : CloudDeleteWords.removed(on: mac)
        }
        let names = [group.session, group.agent].compactMap { BackendCloudContentsWords.plain($0) }
        var seen: Set<String> = []
        return ([title] + names.filter { seen.insert($0).inserted }
            + [BackendCloudContentsWords.time(group.at, now: now), group.count == 1 ? "1 item" : "\(group.count) items"]).joined(separator: " · ")
    }
    /// Marks can outlive a local row. Add its named row so Bring back is still reachable after a restart.
    public static func applying(_ marks: [CloudNotHereItem], groups: [CloudBinGroup], to model: BackendCloudContents,
                                rowErrors: [String: String] = [:]) -> BackendCloudContents {
        var made = model
        let marked = Dictionary(marks.map { (key($0.item), $0) }, uniquingKeysWith: { _, last in last })
        let binned = Set(groups.flatMap(\.items).map(key))
        var found: Set<String> = []
        made.items = model.items.compactMap { item in
            // The owners supply the one Bin. Legacy page copies must not become a second list.
            guard !BackendCloudNoteIdentity.isBin(item.state) else { return nil }
            var row = item
            for target in row.deleteItems {
                let identity = key(target)
                found.insert(identity)
                if let line = rowErrors[identity] { row.deleteLine = line }
                if let state = marked[identity] { row.localMark = state.mark; row.elsewhere = nil }
                else if binned.contains(identity) { return nil }
            }
            return row
        }
        for mark in marks where !found.contains(key(mark.item)) {
            let kind = kind(mark.item)
            var row = BackendCloudContents.Item(id: "marked|" + key(mark.item), kind: kind,
                name: BackendCloudContentsWords.plain(mark.item.name) ?? kind.title, place: nil, changedBy: "This Mac", changedAt: mark.at,
                presence: [], onDevices: [], history: [], bytes: nil, entries: nil, note: nil, isText: false)
            row.localMark = mark.mark; row.deleteItems = [mark.item]; row.canRemove = true
            made.items.append(row)
        }
        for kind in BackendCloudContents.Kind.allCases where kind != .settings {
            // Grouped memory database rows keep their actual entry counts.
            made.counts[kind] = made.items.filter { $0.kind == kind }.reduce(0) { $0 + ($1.entries ?? 1) }
        }
        return made
    }
}
