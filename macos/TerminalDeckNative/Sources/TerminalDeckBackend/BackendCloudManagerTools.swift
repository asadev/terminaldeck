import Foundation
import TerminalDeckNativeCore

/// Lane L4 (CLOUD-CONTRACTS-1114 §6), reworked by the delete rule's lane L6 (15 Nov): what an AI can do with the
/// person's Cloud. Reads run freely. Deleting, bringing back and using an earlier version ask NO question (Asad, 14 Nov:
/// "if AI is doing this ... It should be everywhere", "in all cases it should go to thirty days ... even if AI is
/// deleting", "runaway protection ... not needed"): every delete is everywhere by default, always into the Bin for 30
/// days, recorded as made by an AI with the calling session's and agent's names, one group per call.
/// The Bin is the person's, by hand only ("we can keep bin away from AI access"): no tool here lists, counts, reads,
/// restores or empties anything in a Bin, a Trash, a safety copy or the sealed Bin. Retired for good (never registered):
/// `retiredIDs`. One family, supplied whole or not at all (`BackendDeckToolsRegistration.expectedIDs`).
public enum BackendCloudManagerTools {
    public static let itemsID = "cloud.items"
    public static let openID = "cloud.item_open"
    public static let versionsID = "cloud.item_versions"
    /// What is left of the old `cloud.restore`: an earlier version of an item IN USE becomes the newest. Never the Bin.
    public static let useVersionID = "cloud.use_version"
    public static let deleteID = "cloud.delete"
    public static let notHereID = "cloud.not_here"
    public static let bringBackID = "cloud.bring_back"
    public static let pageIDs: Set<String> = [itemsID, openID, versionsID, useVersionID, deleteID, notHereID, bringBackID]
    /// Every id the family has (kept under its old name for the start-up check and the tests).
    public static let allIDs: Set<String> = pageIDs
    /// Gone with the delete rule: never registered, in no catalogue (the start-up check refuses them as "Extra").
    public static let retiredIDs: Set<String> = ["cloud.remove", "cloud.restore", "cloud.bin", "cloud.empty_bin", "cloud.cleanup_versions",
                                                 "cloud.artifacts_remove", "cloud.artifacts_put_back"]

    /// An item as an AI names it: its kind, its name and (when two share a name) its place.
    public struct Ref: Sendable, Equatable {
        public let kind: String?
        public let name: String
        public let place: String?
        public init(kind: String?, name: String, place: String?) { self.kind = kind; self.name = name; self.place = place }
    }
    /// The page's own changes. The tools send only `.restore(_, at: <a date>)` (Use this version). The other cases are
    /// the person's page buttons (Remove, Empty Bin, Clean up, Put back) and are never sent by any tool.
    public enum Change: Sendable, Equatable {
        case remove(Ref, path: String)
        /// `at` nil: out of the Bin (page only); else the earlier version of that date becomes the newest.
        case restore(Ref, at: String?)
        case emptyBin(count: Int)
        case cleanUp(count: Int)
    }
    /// One read of the page: its lists and what each item is on this Mac (never shown, never in an answer).
    public struct Snapshot: Sendable {
        public let contents: BackendCloudContents
        public let handles: [String: BackendCloudContentsHandle]
        public init(contents: BackendCloudContents, handles: [String: BackendCloudContentsHandle]) { self.contents = contents; self.handles = handles }
    }
    public struct Opened: Sendable, Equatable {
        public let item: BackendCloudContents.Item
        public let versions: [BackendCloudContents.Version]
        public let text: String?
        public init(item: BackendCloudContents.Item, versions: [BackendCloudContents.Version], text: String?) {
            self.item = item; self.versions = versions; self.text = text
        }
    }
    /// What the app gives the reading tools and Use this version: the page's lists, reading one item, the page's change.
    public struct Actions: Sendable {
        public var contents: @Sendable () async -> Snapshot?
        public var read: @Sendable (Ref, _ version: String?) async throws -> Opened
        public var change: @Sendable (Change) async throws -> String
        /// CLOUD-FILES-5: the folder the instruction-file sync uses for a project on this Mac (nil = none), so an AI app
        /// whose key reaches only some folders never reads another project's instruction files.
        public var folder: @Sendable (_ projectId: String) async -> String?
        public init(contents: @escaping @Sendable () async -> Snapshot?,
                    read: @escaping @Sendable (Ref, String?) async throws -> Opened,
                    change: @escaping @Sendable (Change) async throws -> String,
                    folder: @escaping @Sendable (String) async -> String? = { _ in nil }) {
            self.contents = contents; self.read = read; self.change = change; self.folder = folder
        }
        /// Before the app installs its own: nothing is known yet.
        public static let none = Actions(contents: { nil }, read: { _, _ in throw signedOut }, change: { _ in throw signedOut })
    }

    public static let signedOut = NativeRPCError(code: "unavailable", message: "Your Cloud is not open on this Mac (signed out, or still starting).")
    public static func notFound(_ ref: Ref) -> NativeRPCError {
        .init(code: "not-found", message: "No single item is called “\(ref.name)”" + (ref.kind.map { " among \($0)" } ?? "")
              + ". cloud_items lists names; add kind or place when two share a name.")
    }
    public static func cannot(_ line: String) -> NativeRPCError { .init(code: "not-done", message: line) }
    /// The earlier version an AI names by its date (as `cloud_item_versions` gives it). nil when no date is given.
    public static func version(_ versions: [BackendCloudContents.Version], at: String?) throws -> BackendCloudContents.Version? {
        guard let at = at?.trimmingCharacters(in: .whitespaces), !at.isEmpty else { return nil }
        let parsed = ISO8601DateFormatter().date(from: at).map { Int64($0.timeIntervalSince1970 * 1000) }
        guard let found = versions.first(where: { candidate in
            BackendCloudContentsWords.iso(candidate.at) == at || (parsed.map { abs($0 - candidate.at) < 1_000 } ?? false)
        }) else {
            throw NativeRPCError(code: "not-found", message: "No earlier version of that date is kept. cloud_item_versions lists them.")
        }
        return found
    }

    // MARK: The rule, in the words every AI reads (point 5)

    /// Said in `cloud_delete`'s description and repeated where an AI deletes something else (tasks, agents, Cloud folder).
    public static let ruleWords = "To delete anything the person keeps in Terminal Deck (memory notes, team cards and playbooks, instruction files, Cloud folder files, artifacts, tasks, agents, projects), use cloud_delete: it is removed from every one of the person's devices at once and kept in the Bin for 30 days. A file you remove with a plain shell command (rm, mv, trash) inside a Terminal Deck session is also removed everywhere when Terminal Deck can see the command; files removed by git, a build tool or a script, and anything Terminal Deck cannot see, are removed on this Mac only and stay in the Cloud and on the other devices. Files that do not belong to Terminal Deck (project code, the person's own files) are never removed anywhere else. The Bin belongs to the person: no tool lists it, puts anything back from it or empties it; only the person does that, by hand, on the Your Cloud page."
    /// The answer's last words after a delete.
    public static let binLine = "They are in the Bin for 30 days; only the person can put them back, by hand, from the Bin on the Your Cloud page."

    // MARK: Plain answers (names, kinds, device names and dates only)

    static func iso(_ ms: Int64) -> NativeRPCValue { .string(BackendCloudContentsWords.iso(ms)) }
    public static func itemWire(_ item: BackendCloudContents.Item) -> NativeRPCValue {
        BackendDeckToolsSupport.object([
            ("kind", .string(item.kind.title)), ("name", .string(item.name)), ("place", item.place.map(NativeRPCValue.string) ?? .null),
            ("changedBy", .string(item.changedBy)), ("changedAt", iso(item.changedAt)),
            ("state", .string(BackendCloudFilesWords.state(item.state) ?? "In use")), ("versionCount", .number(Double(item.versions.count))),
            ("bytes", item.bytes.map { .number(Double($0)) } ?? .null),
            // Cloud file manager: the folders it sits in, as the page's crumbs name them; a setting's value in words.
            ("folder", .array(item.folder.map(NativeRPCValue.string))),
            ("value", item.value.map(NativeRPCValue.string) ?? .null),
        ])
    }
    public static func folderWire(_ folder: BackendCloudManagerTree.Folder) -> NativeRPCValue {
        BackendDeckToolsSupport.object([("isFolder", .bool(true)), ("name", .string(folder.name)), ("items", .number(Double(folder.count))),
                                        ("changedAt", iso(folder.changedAt))])
    }
    /// `folder` as the page's crumbs: a list of names, or one text with "›" (or "/") between them. nil = not asked.
    static func folderPath(_ args: NativeRPCValue) -> [String]? {
        if let list = args["folder"].elements { return list.compactMap { $0.string?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        guard let text = args["folder"].string else { return nil }
        return text.components(separatedBy: CharacterSet(charactersIn: "›/")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    public static func versionWire(_ version: BackendCloudContents.Version) -> NativeRPCValue {
        BackendDeckToolsSupport.object([("at", iso(version.at)), ("device", .string(version.device)), ("bytes", version.bytes.map { .number(Double($0)) } ?? .null),
                                        ("keptUntil", iso(version.keptUntil)), ("canUse", .bool(version.canUse))])
    }
    /// The files lane's provenance sidecars (`about/<group>`, an artifact's description file) are never an item.
    public static func isSidecar(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return path.hasPrefix("about/") || CloudArtifactsFormat.isAbout(path)
    }
    /// A row the AI may see: never a Bin row, never a sidecar.
    static func listable(_ item: BackendCloudContents.Item, _ handles: [String: BackendCloudContentsHandle]) -> Bool {
        !BackendCloudNoteIdentity.isBin(item.state) && !isSidecar(handles[item.id]?.relative)
    }

    // MARK: The definitions

    static let refSchema = #"{"type":"object","properties":{"kind":{"type":"string"},"name":{"type":"string"},"place":{"type":"string"}},"required":["name"],"additionalProperties":false}"#
    static let itemsListSchema = #"{"type":"array","minItems":1,"items":{"type":"object","properties":{"kind":{"type":"string"},"name":{"type":"string"},"place":{"type":"string"}},"required":["name"],"additionalProperties":false}}"#
    static let specs: [(id: String, tier: BackendMCPTier, title: String, description: String, schema: String)] = [
        (itemsID, .read, "List what is in your Cloud",
         "The items of the Cloud page, one per thing: kind (Memory, Projects, Agents, Instruction files, Tasks, Settings, Artifacts, Cloud folder, Sessions and chats, Saved passwords), name, place (project or agent), the folders it sits in (folder), a setting's value in words, who changed it last and when, its state (In use, Put away) and how many earlier versions are kept. kind and search narrow the list. With kind and folder (the folders' names as the page's crumbs show them, a list or one text like \"Terminal Deck › Decker › Notes\"; [] or \"\" for the top), it lists that folder as the page does: its folders first (isFolder, name, items inside, newest change), then its items, all in rows; search then finds items at any depth inside it. offset and limit page through a long list (next gives the next offset). Names and dates only: never an id, a path or a saved password's value. Nothing in the Bin is listed: the Bin is the person's.",
         #"{"type":"object","properties":{"kind":{"type":"string"},"folder":{"anyOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]},"search":{"type":"string"},"offset":{"type":"number"},"limit":{"type":"number"}},"additionalProperties":false}"#),
        (openID, .read, "Open one item of your Cloud",
         "Read one item in use as the page shows it when opened: a memory note's or instruction file's text (at most 256 KB), or for other kinds its facts. version (a date from cloud_item_versions) reads that earlier version instead. Never a saved password's value and never anything in the Bin.",
         #"{"type":"object","properties":{"kind":{"type":"string"},"name":{"type":"string"},"place":{"type":"string"},"version":{"type":"string"}},"required":["name"],"additionalProperties":false}"#),
        (versionsID, .read, "See an item's earlier versions",
         "An item's earlier versions kept for 30 days, newest first: when, which device made it, its size, until when it is kept, and whether it can be used again (cloud_use_version).",
         refSchema),
        (useVersionID, .act, "Use an earlier version",
         "For an item in use: the earlier version of that date (version, from cloud_item_versions) becomes the newest on all the person's devices; the version it replaces is kept for 30 days. Only for items in use, never for anything in the Bin.",
         #"{"type":"object","properties":{"kind":{"type":"string"},"name":{"type":"string"},"place":{"type":"string"},"version":{"type":"string"}},"required":["name","version"],"additionalProperties":false}"#),
        (deleteID, .act, "Delete from all devices",
         "Deletes items (each by kind, name and, when two share a name, place, as cloud_items, tasks_local and tasks_agents name them) from all the person's devices in one go, with no question: everything goes to the Bin for 30 days. scope everywhere (the default) removes it from the Cloud and every device; scope cloud (only when the person asked for it) removes the Cloud copy and every device keeps its own, shown as Only on this Mac. Tasks and agents are always removed everywhere. Only items inside the projects this caller may reach. " + ruleWords,
         #"{"type":"object","properties":{"items":"# + itemsListSchema + #","scope":{"type":"string","enum":["everywhere","cloud"]}},"required":["items"],"additionalProperties":false}"#),
        (notHereID, .read, "What is missing on this Mac",
         "What is Not on this Mac (removed here by hand: the Cloud and the other devices keep it) and what is Only on this Mac (its Cloud copy was deleted with scope cloud: this device keeps its own), each with kind, name and since when. cloud_bring_back undoes either. Never anything in the Bin.",
         #"{"type":"object","properties":{},"additionalProperties":false}"#),
        (bringBackID, .act, "Bring back to this Mac, or put in Cloud again",
         "For items cloud_not_here lists, with no question. to this-mac (Bring back) places the Cloud's newest copy here again; to cloud (Put in Cloud again) sends this Mac's copy to the Cloud and every device again. Without to, each item gets the one that fits it. Nothing in the Bin can be brought back here: that is the person's, by hand.",
         #"{"type":"object","properties":{"items":"# + itemsListSchema + #","to":{"type":"string","enum":["this-mac","cloud"]}},"required":["items"],"additionalProperties":false}"#),
    ]

    public static func definitions(access: BackendDeckToolsAppAccess, actions: Actions,
                                   door: BackendCloudDeleteDoor = .none) throws -> [BackendDeckToolsDefinition] {
        try specs.map { entry in
            let spec = try BackendMCPTool(id: entry.id, wireName: entry.id.replacingOccurrences(of: ".", with: "_"), description: entry.description,
                                          inputSchema: NativeRPCValue.parseJSON(Data(entry.schema.utf8)), tier: entry.tier)
            return BackendDeckToolsDefinition(spec: spec, title: entry.title, index: entry.title + " (the Cloud page in the side panel).") { context, args in
                try await BackendDeckToolsSupport.reply {
                    guard context.allowedTools.contains(spec.id) || context.allowedTools.contains(spec.wireName), context.allowedTiers.contains(entry.tier) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use the Cloud page.")
                    }
                    let caller = try await access.caller(context)
                    try BackendCloudDeleteDoor.thisMacOnly(caller, entry.title)
                    return .value(try await run(spec.id, args, caller: caller, access: access, context: context, actions: actions, door: door))
                }
            }
        }
    }

    static func text(_ args: NativeRPCValue, _ key: String) -> String? {
        args[key].string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    static func ref(_ args: NativeRPCValue) throws -> Ref {
        guard let name = text(args, "name") else { throw NativeRPCError.invalidArguments("Give name, as cloud_items lists it.") }
        return Ref(kind: text(args, "kind"), name: name, place: text(args, "place"))
    }
    /// `items: [{kind, name, place?}]`, at least one, no upper limit (no limit on what an AI may delete).
    static func refs(_ args: NativeRPCValue) throws -> [Ref] {
        guard let rows = args["items"].elements, !rows.isEmpty else {
            throw NativeRPCError.invalidArguments("Give items: a list of {kind, name, place}, as cloud_items names them.")
        }
        return try rows.map(ref)
    }
    static func find(_ contents: BackendCloudContents, _ ref: Ref) throws -> BackendCloudContents.Item {
        let matches = contents.items.filter { item in
            !BackendCloudNoteIdentity.isBin(item.state)
                && item.name.caseInsensitiveCompare(ref.name) == .orderedSame
                && (ref.kind == nil || item.kind.title.caseInsensitiveCompare(ref.kind!) == .orderedSame || item.kind.rawValue == ref.kind)
                && (ref.place == nil || item.place?.caseInsensitiveCompare(ref.place!) == .orderedSame)
        }
        guard matches.count == 1 else { throw notFound(ref) }
        return matches[0]
    }

    /// CLOUD-FILES-5: the caller may read inside this item's project folder: the person at this Mac always; anyone else
    /// only when the tool door's own folder rule (`knownFolder`, which narrows a key to its granted folders) admits it.
    static func reaches(_ item: BackendCloudContents.Item, handles: [String: BackendCloudContentsHandle], access: BackendDeckToolsAppAccess,
                        context: BackendMCPCallContext, actions: Actions) async -> Bool {
        guard let caller = try? await access.caller(context) else { return false }
        if caller.kind == .local { return true }
        guard let projectId = handles[item.id]?.projectId, let folder = await actions.folder(projectId) else { return false }
        return (try? await access.knownFolder(context, folder)) != nil
    }

    static func run(_ id: String, _ args: NativeRPCValue, caller: BackendDeckToolsAppCaller, access: BackendDeckToolsAppAccess,
                    context: BackendMCPCallContext, actions: Actions, door: BackendCloudDeleteDoor) async throws -> NativeRPCValue {
        func done(_ value: NativeRPCValue) async throws -> NativeRPCValue {
            try await access.record(context, id, args, value)
            return value
        }
        switch id {
        case deleteID:
            return try await done(try await BackendCloudDeleteDoor.delete(args, caller: caller, access: access, context: context, door: door))
        case notHereID:
            try await access.authorize(context, id, args, .read, "See what is not on this Mac", false)
            return try await BackendCloudDeleteDoor.notHere(caller: caller, access: access, context: context, door: door)
        case bringBackID:
            return try await done(try await BackendCloudDeleteDoor.bringBack(args, caller: caller, access: access, context: context, door: door))
        default:
            break
        }
        if [itemsID, openID, versionsID].contains(id) {
            try await access.authorize(context, id, args, .read, "Read the Cloud page", false)
        }
        guard let snapshot = await actions.contents() else { throw signedOut }
        let contents = snapshot.contents
        switch id {
        case itemsID:
            let kind = text(args, "kind")
            let words = (args["search"].string ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let limit = max(1, min(Int(args["limit"].number ?? 500), 2_000))
            let offset = max(0, Int(args["offset"].number ?? 0))
            func page(_ count: Int) -> [(String, NativeRPCValue)] {
                [("offset", .number(Double(offset))), ("shown", .number(Double(max(0, min(count - offset, limit))))), ("total", .number(Double(count))),
                 ("next", offset + limit < count ? .number(Double(offset + limit)) : .null)]
            }
            // Cloud file manager: one folder as the page lists it (folders first, then items), in one paged read.
            if let path = folderPath(args) {
                guard let wanted = kind.flatMap({ want in BackendCloudContents.Kind.allCases.first { $0.title.caseInsensitiveCompare(want) == .orderedSame || $0.rawValue == want } }) else {
                    throw NativeRPCError.invalidArguments("Give kind with folder: Memory, Projects, Agents, Instruction files, Tasks, Settings, Artifacts, Cloud folder, Sessions and chats or Saved passwords.")
                }
                var shown = contents
                shown.items = contents.items.filter { listable($0, snapshot.handles) }
                let listing = BackendCloudManagerTree.listing(shown, kind: wanted, path: path, search: words)
                let rows: [NativeRPCValue] = listing.folders.map(folderWire) + listing.files.map(itemWire)
                let window = Array(rows.dropFirst(offset).prefix(limit))
                return BackendDeckToolsSupport.object([("kind", .string(wanted.title)), ("folder", .array(path.map(NativeRPCValue.string))),
                                                       ("folders", .number(Double(listing.folders.count))), ("rows", .array(window))] + page(rows.count))
            }
            let rows = contents.items.filter { listable($0, snapshot.handles) }.filter { item in
                (kind == nil || item.kind.title.caseInsensitiveCompare(kind!) == .orderedSame || item.kind.rawValue == kind)
                    && (words.isEmpty || item.name.lowercased().contains(words) || (item.place?.lowercased().contains(words) ?? false))
            }
            return BackendDeckToolsSupport.object([("items", .array(rows.dropFirst(offset).prefix(limit).map(itemWire)))] + page(rows.count))
        case versionsID:
            let opened = try await actions.read(try ref(args), nil)
            guard !BackendCloudNoteIdentity.isBin(opened.item.state) else { throw notFound(try ref(args)) }
            return BackendDeckToolsSupport.object([("item", itemWire(opened.item)), ("versions", .array(opened.versions.map(versionWire)))])
        case openID:
            let opened = try await actions.read(try ref(args), text(args, "version"))
            guard !BackendCloudNoteIdentity.isBin(opened.item.state) else { throw notFound(try ref(args)) }
            if opened.item.kind == .passwords { return BackendDeckToolsSupport.object([("item", itemWire(opened.item)), ("text", .null)]) }
            // CLOUD-FILES-5: an instruction file's text only for a caller whose reach includes that project's folder (the
            // person here always; an AI app's key only for the folders it was given). Otherwise no text (as a saved password).
            if opened.item.kind == .instructionFiles, opened.text != nil,
               !(await reaches(opened.item, handles: snapshot.handles, access: access, context: context, actions: actions)) {
                return BackendDeckToolsSupport.object([("item", itemWire(opened.item)), ("text", .null)])
            }
            return BackendDeckToolsSupport.object([("item", itemWire(opened.item)), ("text", opened.text.map(NativeRPCValue.string) ?? .null)])
        case useVersionID:
            let wanted = try ref(args)
            guard let at = text(args, "version") else {
                throw NativeRPCError.invalidArguments("Give version: the date of an earlier version from cloud_item_versions.")
            }
            let opened = try await actions.read(wanted, nil)
            guard !BackendCloudNoteIdentity.isBin(opened.item.state) else { throw notFound(wanted) }
            guard let chosen = try Self.version(opened.versions, at: at), chosen.canUse else {
                throw cannot("That earlier version cannot be made the newest from here.")
            }
            // No question (section G): the replaced version is kept for 30 days.
            try await access.authorize(context, id, args, .act,
                                       "Use the version of “\(opened.item.name)” from \(BackendCloudContentsWords.time(chosen.at)) on all your devices", false)
            guard !context.cancellation.isCancelled else { throw CancellationError() }
            return try await done(BackendDeckToolsSupport.object([("done", .string(try await actions.change(.restore(wanted, at: at))))]))
        default:
            throw NativeRPCError.invalidArguments("Unknown Cloud page tool.")
        }
    }
}

// MARK: - The delete rule's door for AI tools (lane L6)

/// What the app gives `cloud_delete`, `cloud_not_here` and `cloud_bring_back`: the items an AI may name, each kind's
/// owner (`CloudDeleteOwning`, from the kinds' lanes), this Mac, the gate and the clock. The tools never delete anything
/// themselves: every delete, bring back and put in Cloud again is the owner's. Bin methods (`binGroups`,
/// `putBackGroup`, `deleteForGood`) are never called here: they are the person's page only.
public struct BackendCloudDeleteDoor: Sendable {
    /// One item an AI may delete: how its owner routes it (`item`), the words an AI names it by, and the project folder it
    /// belongs to (nil = in no project: the Cloud folder, account-wide memory, an AI account's settings folder).
    public struct Target: Sendable, Equatable {
        public let item: CloudDeleteItem
        public let kindTitle: String
        public let placeName: String?
        public let folder: String?
        public init(item: CloudDeleteItem, kindTitle: String? = nil, placeName: String? = nil, folder: String? = nil) {
            self.item = item; self.kindTitle = kindTitle ?? BackendCloudDeleteDoor.title(ofKind: item.kind)
            self.placeName = placeName; self.folder = folder
        }
    }
    /// The calling session's and agent's NAMES at the moment of the delete (never ids).
    public struct CallerNames: Sendable, Equatable {
        public let session: String?
        public let agent: String?
        public init(session: String?, agent: String?) { self.session = session; self.agent = agent }
    }
    public struct Mac: Sendable, Equatable {
        /// Routing identity (the Cloud device id); never shown.
        public let id: String
        /// The Mac's own name, from the device list.
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// Every live item of every kind an AI may delete (never a Bin row, never a sidecar).
    public var targets: @Sendable () async throws -> [Target]
    /// Every owner by its route, one entry per owner (the pages lane's `NativeCloudDeleteOwners.all()`): memory,
    /// cloudFolder, artifacts, boot, task, agent, project, project-secret-files, secrets|<source>.
    public var owners: @Sendable () async -> [String: any CloudDeleteOwning]
    /// The route of one item (the pages lane's `BackendCloudDeletePage.route`); by default its kind.
    public var route: @Sendable (CloudDeleteItem) -> String
    /// The project folder a not-here item belongs to (nil = in no project), for the caller's scope.
    public var folderOf: @Sendable (CloudDeleteItem) async -> String?
    public var thisMac: @Sendable () async -> Mac?
    /// `DeckMemoryStore.cloudDeleteRuleIsOpen()`: false while an older Mac exists (scope cloud refused).
    public var gateOpen: @Sendable () async -> Bool
    /// Service milliseconds.
    public var now: @Sendable () async -> Int64
    /// Better names than the tool door knows (a task agent's session, Hoot); nil = the door's own.
    public var names: @Sendable (BackendMCPCallContext) async -> CallerNames?

    public init(targets: @escaping @Sendable () async throws -> [Target],
                owners: @escaping @Sendable () async -> [String: any CloudDeleteOwning],
                route: @escaping @Sendable (CloudDeleteItem) -> String = { $0.kind },
                folderOf: @escaping @Sendable (CloudDeleteItem) async -> String? = { _ in nil },
                thisMac: @escaping @Sendable () async -> Mac?,
                gateOpen: @escaping @Sendable () async -> Bool,
                now: @escaping @Sendable () async -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                names: @escaping @Sendable (BackendMCPCallContext) async -> CallerNames? = { _ in nil }) {
        self.targets = targets; self.owners = owners; self.route = route; self.folderOf = folderOf
        self.thisMac = thisMac; self.gateOpen = gateOpen; self.now = now; self.names = names
    }
    /// Before the app installs its own: the Cloud is not open.
    public static let none = BackendCloudDeleteDoor(targets: { throw BackendCloudManagerTools.signedOut }, owners: { [:] },
                                                    thisMac: { nil }, gateOpen: { false })

    /// "for few cases it should be always everywhere, which includes tasks and agents" (Asad, 14 Nov).
    public static let alwaysEverywhere: Set<String> = ["task", "agent"]
    public static func title(ofKind kind: String) -> String {
        switch kind {
        case "memory": return "Memory"
        case "boot": return "Instruction files"
        case "cloudFolder": return "Cloud folder"
        case "artifacts": return "Artifacts"
        case "task": return "Tasks"
        case "agent": return "Agents"
        case "project": return "Projects"
        case "project-secret-files": return "Project secret files"
        case "saved-passwords": return "Saved passwords"
        case "mcp-servers": return "MCP servers"
        case BackendCloudChatsDeleteOwner.kind: return "Sessions and chats"
        default: return kind
        }
    }

    // MARK: Who may use these tools, and what each caller reaches

    /// The person here, Hoot, AI sessions on this Mac and AI apps with a key. A paired device cannot (it shows tasks and
    /// agents and deletes them through this Mac's own page path, as the person).
    public static func thisMacOnly(_ caller: BackendDeckToolsAppCaller, _ what: String) throws {
        guard caller.kind == .local || caller.kind == .key || caller.kind == .session else {
            throw NativeRPCError(code: "not-granted", message: "\(what) works only on this Mac (the person, Hoot, an AI session here, or an AI app with an access key). A paired device cannot do it from here.")
        }
    }
    /// The caller's project scope: the person and Hoot reach everything; any other caller reaches an item of a project
    /// only when the tool door admits that project's folder; an item in no project is reached by AI sessions on this Mac,
    /// never by a key narrowed to some folders.
    public static func reaches(folder: String?, caller: BackendDeckToolsAppCaller, access: BackendDeckToolsAppAccess,
                               context: BackendMCPCallContext) async -> Bool {
        if caller.kind == .local { return true }
        guard let folder, !folder.isEmpty else { return caller.kind == .session }
        return (try? await access.knownFolder(context, folder)) != nil
    }

    // MARK: Who is deleting (names, not ids)

    /// The session's own name and its agent's name, from the tool door's session row (`title`, `profileName`).
    public static func callerNames(_ context: BackendMCPCallContext, caller: BackendDeckToolsAppCaller,
                                   access: BackendDeckToolsAppAccess) async -> CallerNames {
        let sessionID = caller.sessionID ?? context.sessionID
        if !sessionID.isEmpty, let row = try? await access.session(context, sessionID), row.fields != nil {
            return .init(session: plain(row["title"].string), agent: plain(row["profileName"].string))
        }
        switch caller.kind {
        case .key: return .init(session: nil, agent: plain(caller.keyName) ?? "An AI app")
        case .local: return .init(session: nil, agent: "Hoot")
        default: return .init(session: nil, agent: "An AI")
        }
    }
    static func plain(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return BackendCloudContentsWords.looksLikeCode(text) ? nil : text
    }
    /// One actor for one tool call: by an AI, this Mac, the names, the service time and ONE new group.
    public static func aiActor(names: CallerNames, door: BackendCloudDeleteDoor) async throws -> CloudDeleteActor {
        guard let mac = await door.thisMac() else { throw BackendCloudManagerTools.signedOut }
        return CloudDeleteActor(by: .ai, mac: mac.id, macName: mac.name, session: names.session, agent: names.agent,
                                at: await door.now(), group: UUID().uuidString.lowercased())
    }
    /// The same for a caller the deck-tools door resolved.
    public static func aiActor(_ context: BackendMCPCallContext, caller: BackendDeckToolsAppCaller, access: BackendDeckToolsAppAccess,
                               door: BackendCloudDeleteDoor) async throws -> CloudDeleteActor {
        let names: CallerNames
        if let better = await door.names(context) { names = better } else { names = await callerNames(context, caller: caller, access: access) }
        return try await aiActor(names: names, door: door)
    }

    // MARK: Finding what the AI named

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
    static func kindMatches(_ words: String, kind: String, title: String) -> Bool {
        let singular = title.hasSuffix("s") ? String(title.dropLast()) : title
        return same(words, kind) || same(words, title) || same(words, singular) || same(words + "s", kind) || same(words, kind + "s")
    }
    static func pick(_ targets: [Target], _ ref: BackendCloudManagerTools.Ref) throws -> Target {
        let ofKind = targets.filter { target in ref.kind.map { kindMatches($0, kind: target.item.kind, title: target.kindTitle) } ?? true }
        let named = ofKind.filter { same($0.item.name, ref.name) || same($0.item.place, ref.name) }
        let placed = ref.place.map { place in named.filter { same($0.placeName, place) || same($0.item.place, place) || $0.item.id == place } } ?? named
        if placed.count == 1 { return placed[0] }
        if placed.count > 1 {
            let places = Set(placed.compactMap(\.placeName)).sorted()
            throw NativeRPCError(code: "not-found", message: "More than one item is called “\(ref.name)”. Add kind or place"
                                 + (places.isEmpty ? "." : " (one of: " + places.joined(separator: ", ") + ")."))
        }
        throw BackendCloudManagerTools.notFound(ref)
    }
    static func why(_ error: Error) -> String { (error as? NativeRPCError)?.message ?? error.localizedDescription }
    static func quoted(_ items: [String]) -> String {
        let quoted = items.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        return items.count > 3 ? quoted + " and \(items.count - 3) more" : quoted
    }

    // MARK: cloud_delete

    static func delete(_ args: NativeRPCValue, caller: BackendDeckToolsAppCaller, access: BackendDeckToolsAppAccess,
                       context: BackendMCPCallContext, door: BackendCloudDeleteDoor) async throws -> NativeRPCValue {
        let wanted = try BackendCloudManagerTools.refs(args)
        let scope: CloudDeleteScope
        if let raw = BackendCloudManagerTools.text(args, "scope") {
            guard let chosen = CloudDeleteScope(rawValue: raw.lowercased()) else { throw NativeRPCError.invalidArguments("scope is everywhere (the default) or cloud.") }
            scope = chosen
        } else { scope = .everywhere }
        let targets = try await door.targets().filter { !BackendCloudManagerTools.isSidecar($0.item.place) && !BackendCloudManagerTools.isSidecar($0.item.id) }
        var chosen: [Target] = []
        for ref in wanted {
            let target = try pick(targets, ref)
            if !chosen.contains(target) { chosen.append(target) }
        }
        // Only what the caller's project scope allows; one item outside it and nothing is deleted.
        for target in chosen {
            if !(await reaches(folder: target.folder, caller: caller, access: access, context: context)) {
                throw NativeRPCError(code: "not-granted", message: "“\(target.item.name)” belongs to a project this caller cannot reach. Nothing was deleted.")
            }
        }
        // Mixed versions (spec D): while an older Mac exists, scope cloud is refused (tasks and agents ignore the scope).
        if scope == .cloud, chosen.contains(where: { !alwaysEverywhere.contains($0.item.kind) }), !(await door.gateOpen()) {
            throw BackendCloudManagerTools.cannot(CloudDeleteWords.cloudNeedsUpdatedMacs)
        }
        let actor = try await aiActor(context, caller: caller, access: access, door: door)
        // No question (Asad's decision, newer than "a change asks first"): one line in the action log.
        let place = scope == .cloud ? "from the Cloud" : "everywhere"
        try await access.authorize(context, BackendCloudManagerTools.deleteID, args, .act,
                                   "Delete " + quoted(chosen.map(\.item.name)) + " " + place + " (in the Bin for 30 days)", false)
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        // One call per owner (route), all with the same actor and group.
        var routesInOrder: [String] = []
        var byRoute: [String: [CloudDeleteItem]] = [:]
        var titles: [String: String] = [:]
        for target in chosen {
            let route = door.route(target.item)
            if byRoute[route] == nil { routesInOrder.append(route) }
            byRoute[route, default: []].append(target.item)
            titles[target.item.kind] = target.kindTitle
        }
        let owners = await door.owners()
        var removed: [(kind: String, item: CloudDeleteItem)] = []
        var notDone: [NativeRPCValue] = []
        for route in routesInOrder {
            let items = byRoute[route] ?? []
            let kind = items.first?.kind ?? route
            let kindTitle = titles[kind] ?? title(ofKind: kind)
            guard let owner = owners[route] else {
                for item in items { notDone.append(BackendDeckToolsSupport.object([("kind", .string(kindTitle)), ("name", .string(item.name)),
                                                                                   ("why", .string("\(kindTitle) cannot be deleted on this Mac right now."))])) }
                continue
            }
            let kindScope: CloudDeleteScope = alwaysEverywhere.contains(kind) ? .everywhere : scope
            do {
                let group = try await owner.deleteItems(items, scope: kindScope, by: actor)
                removed += group.items.map { (kind: kind, item: $0) }
            } catch {
                for item in items { notDone.append(BackendDeckToolsSupport.object([("kind", .string(kindTitle)), ("name", .string(item.name)), ("why", .string(why(error)))])) }
            }
        }
        if removed.isEmpty, let first = notDone.first { throw BackendCloudManagerTools.cannot(first["why"].string ?? "Nothing was deleted.") }
        let group = CloudBinGroup(id: actor.group, by: .ai, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at,
                                  items: removed.map(\.item))
        let count = removed.count == 1 ? "1 item" : "\(removed.count) items"
        var line = scope == .cloud
            ? "Deleted from the Cloud: \(count). Each device keeps its own copy, shown as Only on this Mac."
            : "Deleted from all the person's devices: \(count)."
        if scope == .cloud, removed.contains(where: { alwaysEverywhere.contains($0.kind) }) { line += " Tasks and agents are always deleted everywhere." }
        line += " " + BackendCloudManagerTools.binLine
        return BackendDeckToolsSupport.object([
            ("deleted", .array(removed.map { BackendDeckToolsSupport.object([("kind", .string(titles[$0.kind] ?? title(ofKind: $0.kind))), ("name", .string($0.item.name))]) })),
            ("notDeleted", .array(notDone)),
            ("where", .string(scope == .cloud ? CloudDeleteWords.cloud : CloudDeleteWords.everywhere)),
            ("group", .string(group.title)),
            ("line", .string(line)),
        ])
    }

    // MARK: cloud_not_here and cloud_bring_back

    /// Every Not-on-this-Mac / Only-on-this-Mac item this caller reaches, with its kind. Never a Bin row: `notHere()` is
    /// the owners' local marks only.
    static func marked(caller: BackendDeckToolsAppCaller, access: BackendDeckToolsAppAccess, context: BackendMCPCallContext,
                       door: BackendCloudDeleteDoor) async -> [(kind: String, entry: CloudNotHereItem)] {
        var rows: [(kind: String, entry: CloudNotHereItem)] = []
        let owners = await door.owners()
        for route in owners.keys.sorted() {
            guard let owner = owners[route], let list = try? await owner.notHere() else { continue }
            for entry in list where !BackendCloudManagerTools.isSidecar(entry.item.place) && !BackendCloudManagerTools.isSidecar(entry.item.id) {
                guard await reaches(folder: await door.folderOf(entry.item), caller: caller, access: access, context: context) else { continue }
                rows.append((entry.item.kind, entry))
            }
        }
        return rows.sorted { $0.entry.at > $1.entry.at }
    }
    static func notHere(caller: BackendDeckToolsAppCaller, access: BackendDeckToolsAppAccess, context: BackendMCPCallContext,
                        door: BackendCloudDeleteDoor) async throws -> NativeRPCValue {
        guard await door.thisMac() != nil else { throw BackendCloudManagerTools.signedOut }
        let rows = await marked(caller: caller, access: access, context: context, door: door)
        return BackendDeckToolsSupport.object([("items", .array(rows.map { row in
            BackendDeckToolsSupport.object([
                ("kind", .string(title(ofKind: row.kind))), ("name", .string(row.entry.item.name)),
                ("state", .string(row.entry.mark == .notOnThisMac ? CloudDeleteWords.notOnThisMac : CloudDeleteWords.onlyOnThisMac)),
                ("since", BackendCloudManagerTools.iso(row.entry.at)),
                ("action", .string(row.entry.mark == .notOnThisMac ? CloudDeleteWords.bringBack : CloudDeleteWords.putInCloudAgain)),
            ])
        }))])
    }
    static func bringBack(_ args: NativeRPCValue, caller: BackendDeckToolsAppCaller, access: BackendDeckToolsAppAccess,
                          context: BackendMCPCallContext, door: BackendCloudDeleteDoor) async throws -> NativeRPCValue {
        let wanted = try BackendCloudManagerTools.refs(args)
        var asked: CloudBringBackDestination?
        if let raw = BackendCloudManagerTools.text(args, "to") {
            guard let to = CloudBringBackDestination(rawValue: raw.lowercased()) else { throw NativeRPCError.invalidArguments("to is this-mac (the default) or cloud.") }
            asked = to
        }
        guard await door.thisMac() != nil else { throw BackendCloudManagerTools.signedOut }
        let rows = await marked(caller: caller, access: access, context: context, door: door)
        let targets = rows.map { Target(item: $0.entry.item, kindTitle: title(ofKind: $0.kind)) }
        var chosen: [(kind: String, entry: CloudNotHereItem)] = []
        for ref in wanted {
            let target = try pick(targets, ref)
            guard let row = rows.first(where: { $0.entry.item == target.item }) else { throw BackendCloudManagerTools.notFound(ref) }
            if !chosen.contains(where: { $0.entry.item == row.entry.item }) { chosen.append(row) }
        }
        try await access.authorize(context, BackendCloudManagerTools.bringBackID, args, .act,
                                   "Bring back " + quoted(chosen.map(\.entry.item.name)), false)
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        var done: [NativeRPCValue] = []
        var notDone: [NativeRPCValue] = []
        // One call per kind and destination; each item gets the one that fits it unless `to` was given.
        var batches: [(route: String, to: CloudBringBackDestination, items: [CloudDeleteItem])] = []
        for row in chosen {
            let fits: CloudBringBackDestination = row.entry.mark == .notOnThisMac ? .thisMac : .cloud
            let to = asked ?? fits
            guard to == fits else {
                let line = row.entry.mark == .notOnThisMac
                    ? "“\(row.entry.item.name)” is not on this Mac: to this-mac brings it back."
                    : "“\(row.entry.item.name)” is already on this Mac: to cloud puts it in the Cloud again."
                notDone.append(BackendDeckToolsSupport.object([("kind", .string(title(ofKind: row.kind))), ("name", .string(row.entry.item.name)), ("why", .string(line))]))
                continue
            }
            let route = door.route(row.entry.item)
            if let index = batches.firstIndex(where: { $0.route == route && $0.to == to }) { batches[index].items.append(row.entry.item) }
            else { batches.append((route: route, to: to, items: [row.entry.item])) }
        }
        let owners = await door.owners()
        for batch in batches {
            let kindTitle = title(ofKind: batch.items.first?.kind ?? batch.route)
            guard let owner = owners[batch.route] else {
                for item in batch.items { notDone.append(BackendDeckToolsSupport.object([("kind", .string(kindTitle)), ("name", .string(item.name)), ("why", .string("\(kindTitle) cannot be brought back on this Mac right now."))])) }
                continue
            }
            do {
                for item in try await owner.bringBack(batch.items, to: batch.to) {
                    done.append(BackendDeckToolsSupport.object([("kind", .string(kindTitle)), ("name", .string(item.name)),
                                                                ("done", .string(batch.to == .thisMac ? CloudDeleteWords.bringBack : CloudDeleteWords.putInCloudAgain))]))
                }
            } catch {
                for item in batch.items { notDone.append(BackendDeckToolsSupport.object([("kind", .string(kindTitle)), ("name", .string(item.name)), ("why", .string(why(error)))])) }
            }
        }
        if done.isEmpty, let first = notDone.first { throw BackendCloudManagerTools.cannot(first["why"].string ?? "Nothing was brought back.") }
        return BackendDeckToolsSupport.object([("broughtBack", .array(done)), ("notDone", .array(notDone))])
    }

    // MARK: Building the targets (for the app's composition)

    /// Memory notes, team cards, playbooks and topics from one read of the Your Cloud page (L1 routing:
    /// `kind = "memory"`, `id = "memory:" + relativePath`, `place = relativePath`). Grouped rows and Bin rows are skipped.
    public static func memoryTargets(_ snapshot: BackendCloudManagerTools.Snapshot,
                                     folder: @Sendable (_ projectId: String) async -> String?) async -> [Target] {
        var made: [Target] = []
        for item in snapshot.contents.items where item.kind == .memory && !BackendCloudNoteIdentity.isBin(item.state) {
            guard let handle = snapshot.handles[item.id], let path = handle.relative, !path.isEmpty,
                  !BackendCloudManagerTools.isSidecar(path), !BackendCloudNoteIdentity.isInternal(path) else { continue }
            let projectFolder: String?
            if let projectId = handle.projectId { projectFolder = await folder(projectId) } else { projectFolder = nil }
            made.append(.init(item: .init(id: "memory:" + path, kind: "memory", name: item.name, place: path),
                              placeName: item.place, folder: projectFolder))
        }
        return made
    }
    /// An instruction file (L2 routing: `kind = "boot"`, `id = sourceId + "\n" + relative`).
    public static func bootTarget(sourceId: String, relative: String, name: String, placeName: String?, folder: String?) -> Target {
        .init(item: .init(id: sourceId + "\n" + relative, kind: "boot", name: name, place: sourceId + "\n" + relative), placeName: placeName, folder: folder)
    }
    /// A Cloud folder file (L2 routing: the path relative to the Cloud folder). Its name is that path.
    public static func cloudFolderTarget(relative: String) -> Target? {
        guard !relative.isEmpty, !BackendCloudManagerTools.isSidecar(relative) else { return nil }
        return .init(item: .init(id: relative, kind: "cloudFolder", name: relative, place: relative))
    }
    /// An artifact (L2 routing: its store path `<project>/<relative>`, as `cloud_artifacts` gives it as id).
    public static func artifactTarget(_ artifact: CloudArtifactItem, folder: String?) -> Target? {
        guard !BackendCloudManagerTools.isSidecar(artifact.path), !BackendCloudManagerTools.isSidecar(artifact.relPath) else { return nil }
        return .init(item: .init(id: artifact.path, kind: "artifacts", name: artifact.name, place: artifact.path), placeName: artifact.project, folder: folder)
    }
    /// A task, an agent or a project (L4 routing: the record's own id; kinds `task`, `agent`, `project`).
    public static func recordTarget(kind: String, id: String, name: String, placeName: String?, folder: String?) -> Target {
        .init(item: .init(id: id, kind: kind, name: name, place: id), placeName: placeName, folder: folder)
    }
}
