import Foundation
import TerminalDeckNativeCore

/// Cloud file manager (owner, 15 Nov, items 26, 27, 30: "I need a proper file manager where I can go inside and see things
/// ... I need folders shape ... go inside the folder, read ... file versus folder"). Every kind of the Cloud page as real
/// folders and files. A row's folders (`Item.folder`) are decided here once, from what the record really is; the page,
/// its counts and the `cloud.items` tool all list from `listing(_:kind:path:)`, so a number beside a place always equals
/// what that place holds (owner: a count that did not match its page).
///
/// The tree per kind (names only, never a path or an id):
/// - Memory › project › seat (or "Lead") › Notes / Topics / Hand-offs; an agent's own memory › agent; Hoot › …;
///   Templates › Leads / Agents / Hoot; the diary and other grouped entries at the top.
/// - Projects: one row per project. Agents › project › agents (agents of no project at the top).
/// - Instruction files › project (or "Claude settings folder" …) › the folders inside it (".claude" reads "Claude").
/// - Tasks › project › tasks (tasks of no project at the top).
/// - Settings › the Settings page a setting belongs to › one row per setting with its value; Projects › project › its
///   own settings; Memory › the memory's shared settings.
/// - Artifacts › project › its folders › files. Cloud folder › his own folders › files.
/// - Sessions and chats › project › sessions, and "Earlier chats" inside the project.
/// - Saved passwords › what they are for ("API keys", "Server logins" …) › one row per saved password, by name.
public enum BackendCloudManagerTree {
    public typealias Item = BackendCloudContents.Item
    public typealias Kind = BackendCloudContents.Kind

    /// One folder as a row: its name, where it is, how many items are inside it (at any depth) and its newest change.
    public struct Folder: Sendable, Equatable, Identifiable {
        public let name: String
        public let path: [String]
        public let count: Int
        public let changedAt: Int64
        public var id: String { BackendCloudManagerTree.folderId(path) }
        public init(name: String, path: [String], count: Int, changedAt: Int64) {
            self.name = name; self.path = path; self.count = count; self.changedAt = changedAt
        }
    }
    /// What one place shows: its folders first (by name), then its files (newest first, as the rows always were).
    public struct Listing: Sendable, Equatable {
        public let folders: [Folder]
        public let files: [Item]
        public var count: Int { folders.count + files.count }
        public init(folders: [Folder], files: [Item]) { self.folders = folders; self.files = files }
    }

    public static let folderPrefix = "folder|"
    /// A folder's selection key (never shown). The unit separator never occurs in a folder's name.
    public static func folderId(_ path: [String]) -> String { folderPrefix + path.joined(separator: "\u{1F}") }
    public static func path(ofFolderId id: String) -> [String]? {
        guard id.hasPrefix(folderPrefix) else { return nil }
        let rest = String(id.dropFirst(folderPrefix.count))
        return rest.isEmpty ? [] : rest.components(separatedBy: "\u{1F}")
    }
    public static let unknownProject = "A project not on this Mac"
    public static let noProject = "No project"
    public static let earlierChats = "Earlier chats"

    /// Every row a place holds (never a Bin row).
    public static func rows(_ contents: BackendCloudContents, kind: Kind, device: String? = nil) -> [Item] {
        contents.items(kind, device: device)
    }
    /// The number beside a place: exactly the rows it lists, at any depth.
    public static func count(_ contents: BackendCloudContents, kind: Kind) -> Int { rows(contents, kind: kind).count }
    /// Every row inside a folder, at any depth (a folder's removal acts on all of them as one removal).
    public static func items(under path: [String], kind: Kind, in contents: BackendCloudContents, device: String? = nil) -> [Item] {
        rows(contents, kind: kind, device: device).filter { $0.folder.starts(with: path) }
    }
    /// One place: the folders and files directly inside `path`. With search words: every file inside `path` (at any
    /// depth) whose name, place or value has them, and no folders (as Finder searches).
    public static func listing(_ contents: BackendCloudContents, kind: Kind, path: [String], device: String? = nil, search: String = "") -> Listing {
        let words = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inside = items(under: path, kind: kind, in: contents, device: device)
        if !words.isEmpty {
            return Listing(folders: [], files: inside.filter { item in
                item.name.lowercased().contains(words) || (item.place?.lowercased().contains(words) ?? false)
                    || (item.value?.lowercased().contains(words) ?? false) || item.folder.contains { $0.lowercased().contains(words) }
            })
        }
        var files: [Item] = []
        var below: [String: (count: Int, at: Int64)] = [:]
        for item in inside {
            guard item.folder.count > path.count else { files.append(item); continue }
            let name = item.folder[path.count]
            let was = below[name] ?? (0, 0)
            below[name] = (was.count + 1, max(was.at, item.changedAt))
        }
        let folders = below.map { Folder(name: $0.key, path: path + [$0.key], count: $0.value.count, changedAt: $0.value.at) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Listing(folders: folders, files: files)
    }
    /// The folder `path` still exists in this kind (after a refresh or a removal it may be gone).
    public static func exists(_ path: [String], kind: Kind, in contents: BackendCloudContents) -> Bool {
        path.isEmpty || rows(contents, kind: kind).contains { $0.folder.starts(with: path) }
    }

    // MARK: Where each row sits

    public static func folder(of item: Item, handle: BackendCloudContentsHandle?, names: BackendCloudContentsNames) -> [String] {
        switch item.kind {
        case .memory:
            guard let path = handle?.relative, !path.isEmpty else { return [] }
            return memoryFolders(path, names: names)
        case .settings:
            if let record = handle?.recordId, handle?.domain == BackendCloudKindsSettings.domain {
                return BackendCloudManagerSettings.folder(recordId: record, names: names)
            }
            // The memory's own shared settings (one grouped row of its settings table).
            return [BackendCloudManagerSettings.memoryPage]
        case .instructionFiles:
            let top = handle?.home.flatMap { BackendCloudContentsBuilder.homeNames[$0] } ?? projectName(handle?.projectId, names: names)
            return [top ?? unknownProject] + directories(handle?.relative)
        case .cloudFolder:
            return directories(handle?.relative)
        case .artifacts:
            // The store path is `<project id>/<path inside the project>`.
            var parts = (handle?.relative ?? "").split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return [projectName(handle?.projectId, names: names) ?? unknownProject] }
            let first = parts.removeFirst()
            parts.removeLast()
            let project = BackendCloudContentsWords.plain(names.projects[first]) ?? projectName(handle?.projectId, names: names)
                ?? folderWord(first) ?? unknownProject
            return [project] + parts.compactMap(folderWord)
        case .tasks, .agents:
            return projectName(handle?.projectId, names: names).map { [$0] } ?? []
        case .passwords:
            return [passwordsFolder(handle?.domain)]
        case .sessions:
            return item.folder
        case .projects, .other:
            return []
        }
    }
    static func projectName(_ id: String?, names: BackendCloudContentsNames) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return BackendCloudContentsWords.plain(names.projects[id]) ?? unknownProject
    }
    /// What saved passwords are for, as the folder they sit in: "API keys", "Server logins" …
    public static func passwordsFolder(_ domain: String?) -> String {
        let noun = BackendCloudContentsBuilder.passwordNoun(domain ?? "")
        return noun == "Saved password" ? "Other saved passwords" : noun + "s"
    }
    /// The folders of a file's place, each a plain name; pieces that are not plain are passed over (never shown).
    static func directories(_ relative: String?) -> [String] {
        var parts = (relative ?? "").split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }
        parts.removeLast()
        return parts.compactMap(folderWord)
    }
    static let dotFolders: [String: String] = [".claude": "Claude", ".codex": "Codex", ".gemini": "Gemini", ".agents": "Agents",
                                               ".cursor": "Cursor", ".github": "GitHub", ".vscode": "VS Code"]
    static let memoryWords: [String: String] = ["notes": "Notes", "topics": "Topics", "handoffs": "Hand-offs", "diary": "Diary",
                                                "journal": "Journal", "lead": "Lead", "leads": "Leads", "agents": "Agents",
                                                "playbooks": "Playbooks", "files": "Files"]
    /// One folder's name as he reads it: his own name for a folder, a known word for the app's own folders, nothing for
    /// a piece that looks like an id or a code.
    static func folderWord(_ piece: String) -> String? {
        if let known = dotFolders[piece.lowercased()] { return known }
        let bare = piece.hasPrefix(".") ? String(piece.dropFirst()) : piece
        guard !bare.isEmpty, bare.count <= 80, !bare.contains("\n"),
              bare.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) }),
              let said = BackendCloudContentsWords.plain(bare) else { return nil }
        return said
    }
    static func memoryFolders(_ path: String, names: BackendCloudContentsNames) -> [String] {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        parts.removeLast()
        if parts.first == "archive" {
            parts.removeFirst()
            if parts.first == "versions" || parts.first == "cloud-conflicts" { return ["Earlier copies"] }
        }
        func agent(_ id: String) -> String {
            BackendCloudContentsWords.plain(names.agents[id]) ?? BackendCloudContentsWords.seatWords(id) ?? "An agent"
        }
        func word(_ piece: String) -> String? {
            if let known = memoryWords[piece.lowercased()] { return known }
            guard BackendCloudContentsBuilder.safePiece(piece), !piece.hasPrefix("."), !BackendCloudContentsWords.looksLikeCode(piece) else { return nil }
            return BackendCloudContentsWords.seatWords(piece)
        }
        var out: [String] = []
        var rest = parts[...]
        switch parts.first ?? "" {
        case "projects" where parts.count >= 2:
            out.append(BackendCloudContentsWords.plain(names.projects[parts[1]]) ?? names.projectFolders[parts[1]] ?? unknownProject)
            rest = parts.dropFirst(2)
            if rest.first == "roles", rest.count >= 2 {
                out.append(agent(rest[rest.index(after: rest.startIndex)]))
                rest = rest.dropFirst(2)
            }
        case "roles" where parts.count >= 2:
            out.append(agent(parts[1]))
            rest = parts.dropFirst(2)
        case "hoot":
            out.append(BackendCloudContentsWords.plain(names.agents["hoot"]) ?? "Hoot")
            rest = parts.dropFirst()
        case "templates":
            out.append("Templates")
            rest = parts.dropFirst()
            if let category = rest.first {
                switch DeckMemoryCategory(rawValue: category) {
                case .orchestrator: out.append(BackendCloudContentsWords.plain(names.agents["hoot"]) ?? "Hoot")
                case .lead: out.append("Leads")
                case .agent: out.append("Agents")
                case nil: if let said = word(category) { out.append(said) }
                }
                rest = rest.dropFirst()
            }
        default:
            break
        }
        for piece in rest { if let said = word(piece) { out.append(said) } }
        return out
    }
}

// MARK: - Settings as rows

/// Cloud file manager (owner, item 30: Settings showed as ONE row): each travelling setting is its own row, named in
/// plain words, its value in plain words, under the Settings page it belongs to.
public enum BackendCloudManagerSettings {
    public static let memoryPage = "Memory"
    public static let projectsPage = "Projects"

    static func parse(_ recordId: String) -> (source: CloudBrainSettings.Source, key: String)? { BackendCloudKindsSettings.parse(recordId) }

    /// The Settings page a setting is changed on (the Settings window's own list where there is one).
    public static func page(_ source: CloudBrainSettings.Source, _ key: String) -> String {
        let first = key.split(separator: ".").first.map(String.init) ?? key
        switch source {
        case .project:
            return projectsPage
        case .preference:
            switch key {
            case "theme": return "Appearance"
            case "notifyOnComplete": return "Notifications"
            case "defaultProvider": return "Coding AIs"
            default: return "General"
            }
        case .app:
            if key.hasPrefix("copilot.island") || key == "copilot.menuBar" { return "Dynamic Island" }
            if ["general.notifyOnAttention", "general.showInsightAlerts", "general.soundOnFinish"].contains(key) { return "Notifications" }
            if key == "general.defaultProvider" || key == "agents.defaultProvider" { return "Coding AIs" }
            switch first {
            case "appearance": return "Appearance"
            case "general", "browser": return "General"
            case "notifications", "sounds": return "Notifications"
            case "hoot", "copilot": return "Hoot"
            case "agents", "routines": return "Agents"
            case "tasks": return "Tasks"
            default: return "Advanced"
            }
        case .choice:
            if key.hasPrefix("td.tasks.") || key.hasPrefix("page.tasks.") { return "Tasks" }
            if key.hasPrefix("page.hoot.") { return "Hoot" }
            switch first {
            case "sidebar", "chat", "deploy", "catalog", "machines", "page": return "Side panel"
            case "AGFRAME", "agt": return "Agents"
            case "phone": return "Voice"
            case "session-controls", "landing": return "New session"
            case "hoot": return "Hoot"
            default: return "Advanced"
            }
        }
    }
    static let knownNames: [String: String] = [
        "preference|theme": "Window theme", "preference|restoreSessions": "Reopen sessions when the app starts",
        "preference|newSessionMode": "How a new session opens", "preference|notifyOnComplete": "Notify when a session finishes",
        "preference|defaultProvider": "Default AI for new sessions",
        "app|appearance.theme": "Theme", "app|appearance.terminalScheme": "Terminal colours", "app|appearance.terminalFontSize": "Terminal text size",
        "app|appearance.terminalFontFamily": "Terminal font", "app|appearance.fontSize": "Text size", "app|appearance.reduceMotion": "Reduce motion",
        "app|general.autoNameSessions": "Name sessions by themselves", "app|general.confirmCloseWorking": "Ask before closing a working session",
        "app|general.copyOnSelect": "Copy when text is selected", "app|notifications.onComplete": "When a session finishes",
        "app|notifications.onNeedsInput": "When a session needs you", "app|notifications.onFinishSound": "Sound when a session finishes",
        "app|notifications.soundName": "Sound", "app|notifications.sound": "Sounds", "app|notifications.onlyWhenUnfocused": "Only when the app is in the background",
        "app|notifications.showInsightAlerts": "Insight alerts", "app|general.notifyOnAttention": "When something needs attention",
        "app|general.showInsightAlerts": "Show insight alerts", "app|general.soundOnFinish": "Sound on finish", "app|sounds.enabled": "Sounds on",
        "app|browser.startUrl": "Browser start page", "app|copilot.islandLook": "Island look", "app|copilot.islandQuiet": "Quiet times",
        "app|copilot.islandWidthPreset": "Island width", "app|copilot.menuBar": "Show in the menu bar",
        "app|general.defaultProvider": "Default AI", "app|agents.defaultProvider": "Default AI for agents", "app|hoot.provider": "Hoot's AI",
        "app|hoot.interactive": "Hoot acts without asking", "app|copilot.interactive": "Island acts without asking",
        "app|routines.maxRunsPerHour": "Routine runs per hour at most",
        "project|setup.hootLeads": "Hoot leads this project",
        "choice|sidebar.pagePins.v1": "Side panel pages and their order", "choice|sidebar.pinnedTabs.v2": "Pinned sessions",
        "choice|chat.archivedSessions.v1": "Archived chats", "choice|chat.sessionPanel.open": "Session panel open",
        "choice|deploy.hootPanel.collapsed": "Hoot panel folded", "choice|page.tasks.section21": "Tasks page view",
        "choice|page.hoot.machine21": "Hoot's computer", "choice|AGFRAME.view": "Agents page view", "choice|AGFRAME.project": "Agents page project",
        "choice|AGFRAME.filter21": "Agents page filter", "choice|AGFRAME.search21": "Agents page search", "choice|agt.layout": "Agents layout",
        "choice|agt.grouping": "Agents grouping", "choice|td.tasks.viewState.v1": "Tasks view", "choice|td.tasks.savedViews.v1": "Saved task views",
        "choice|td.tasks.activeView.v1": "Task view in use", "choice|td.tasks.favorites.v1": "Favourite task views",
        "choice|td.tasks.projectScope": "Tasks of which projects", "choice|td.tasks.selectedProjectID": "Tasks project",
        "choice|catalog.artifacts.project": "Artifacts project", "choice|machines.servers.project": "Servers project",
        "choice|phone.record.talk": "Talk to send", "choice|phone.record.words": "Voice words", "choice|phone.record.language": "Voice language",
        "choice|session-controls.effort.v1": "Remembered effort", "choice|features.v2": "Feature switches",
        "choice|readiness.dismissed.v1": "Notices you closed", "choice|hoot.setup.dismissed.v1": "Hoot set-up closed",
        "choice|td.sessionSimulator.annotateFullPanel": "Phone preview notes", "choice|devices.directScreen": "Phone screen direct",
        "choice|landing.draft.v1": "Unsent text of New session",
    ]
    /// A setting's name in plain words ("Theme", "Terminal text size"); never its key.
    public static func name(recordId: String, names: BackendCloudContentsNames = .init()) -> String {
        guard let parsed = parse(recordId) else { return "A setting" }
        let source = parsed.source, key = parsed.key
        let own = source == .project ? (CloudBrainSettings.projectParts(key)?.key ?? key) : key
        if let known = knownNames[source.rawValue + "|" + own] { return known }
        if source == .app, own.hasPrefix("appearance.terminalScheme.custom.") { return "Your colour scheme" + piece(String(own.dropFirst("appearance.terminalScheme.custom.".count))) }
        if source == .app, own.hasPrefix("hoot.permission.") { return "Hoot may" + piece(String(own.dropFirst("hoot.permission.".count))) }
        if source == .app, own.hasPrefix("hoot.policy.") { return "Hoot's rule" + piece(String(own.dropFirst("hoot.policy.".count))) }
        if source == .choice, own.hasPrefix("agt.declaredLead.notNow.") { return "Lead suggestion put off" }
        return words(own) ?? "A setting"
    }
    /// " · <words>" for the end of a family key, or nothing when it is not plain.
    static func piece(_ text: String) -> String { words(text).map { " · " + $0 } ?? "" }
    /// "appearance.terminalFontSize" → "Terminal font size": the last dotted piece, its version ending left out, its
    /// words split. nil when nothing plain is left.
    public static func words(_ key: String) -> String? {
        var last = key.split(separator: ".").map(String.init).last { !$0.isEmpty && $0.range(of: "^v[0-9]+$", options: .regularExpression) == nil } ?? key
        last = last.replacingOccurrences(of: "[0-9]+$", with: "", options: .regularExpression)
        var spaced = ""
        for character in last {
            if character.isUppercase, let previous = spaced.last, previous.isLowercase { spaced.append(" ") }
            spaced.append(character == "_" || character == "-" ? " " : character)
        }
        let lowered = spaced.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty, let said = BackendCloudContentsWords.plain(lowered), BackendCloudPageWords.isPlain(said) else { return nil }
        return said.prefix(1).uppercased() + said.dropFirst()
    }
    /// The folders a setting sits in: its Settings page; a project's own setting under Projects › the project.
    public static func folder(recordId: String, names: BackendCloudContentsNames) -> [String] {
        guard let parsed = parse(recordId) else { return ["Advanced"] }
        let source = parsed.source, key = parsed.key
        if source == .project {
            let project = CloudBrainSettings.projectParts(key).map { $0.project }
            return [projectsPage, BackendCloudManagerTree.projectName(project, names: names) ?? BackendCloudManagerTree.unknownProject]
        }
        return [page(source, key)]
    }
    static let choiceWords: [String: String] = ["dark": "Dark", "light": "Light", "system": "Same as the Mac", "claude": "Claude", "codex": "Codex",
                                                "gemini": "Gemini", "shell": "Terminal", "chime": "Chime", "blip": "Blip", "knock": "Knock"]
    /// A setting's value in plain words: "On", "Off", "Dark", "14", "3 chosen"; "Set" for anything long or code-like.
    /// Never a long text he typed (the unsent text of New session is only "Saved text").
    public static func value(recordId: String, _ value: NativeRPCValue) -> String {
        if let parsed = parse(recordId), parsed.source == .choice, parsed.key.hasPrefix("landing.draft") {
            if case .string(let text) = value, text.isEmpty { return "Empty" }
            return "Saved text"
        }
        return words(value: value)
    }
    public static func words(value: NativeRPCValue) -> String {
        switch value {
        case .bool(let on): return on ? "On" : "Off"
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e12 ? BackendCloudPageCounts.number(Int(number)) : String(format: "%.2f", number)
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Empty" }
            if let known = choiceWords[trimmed.lowercased()] { return known }
            guard trimmed.count <= 40, !trimmed.contains("\n"), let said = BackendCloudContentsWords.plain(trimmed), BackendCloudPageWords.isPlain(said),
                  !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return "Set" }
            return said.prefix(1).uppercased() + said.dropFirst()
        case .array(let list): return list.isEmpty ? "None" : (list.count == 1 ? "1 chosen" : "\(list.count) chosen")
        case .null, .missing: return "Not set"
        default: return "Set"
        }
    }
}

// MARK: - The columns' words

public enum BackendCloudManagerWords {
    public static let name = "Name"
    public static let changed = "Changed"
    public static let on = "On"
    public static let size = "Size"
    public static let allDevices = "All devices"
    public static let open = "Open"
    public static let show = "Show"
    public static let hide = "Hide"
    public static let noValue = "This saved password's value is not on this Mac."
    public static let emptyFolder = "This folder is empty."
    public static let nothingHere = "Nothing here yet."
    public static let nothingMatches = "Nothing matches."
    /// "12 items" for a folder.
    public static func items(_ count: Int) -> String { count == 1 ? "1 item" : BackendCloudPageCounts.number(count) + " items" }
    /// The "On" column: one small state. Its mark ("Not on this Mac", "Only on this Mac"), the device's name while the
    /// device filter is used, "All devices" once every device has it, else what it waits for.
    public static func on(_ item: BackendCloudContents.Item, device: String? = nil) -> String {
        if let mark = item.localMark { return mark.title }
        if let device { return device }
        if item.kind == .sessions { return item.changedBy }
        if item.presence.first == BackendCloudContentsWords.arrivingHere { return "Arriving" }
        if item.standing == .sending { return "Sending" }
        if item.standing == .notSent { return "Not sent yet" }
        if item.standing == .waitingHere { return "Waiting on this Mac" }
        let waiting = item.presence.filter { $0.hasPrefix("Waiting on ") }.map { String($0.dropFirst("Waiting on ".count)) }
        if waiting.isEmpty { return allDevices }
        return waiting.count == 1 ? "Not yet on " + waiting[0] : "Not yet on \(waiting.count) devices"
    }
    /// 15 Nov (DESIGN-FIXES CM-2): what the list's "On" column shows. EMPTY for an item in its normal state (on every
    /// device, or still on its way); only what he must know: "Not on this Mac" or "Only on this Mac".
    public static func onColumn(_ item: BackendCloudContents.Item) -> String {
        item.localMark?.title ?? ""
    }
    /// Where an item is, written in full, for the reading pane only: its mark, else every device it still waits for by
    /// name ("Not yet on Office iMac and MacBook Pro"), else the one state ("All devices", "Arriving", "Sending").
    public static func onInFull(_ item: BackendCloudContents.Item) -> String {
        if let mark = item.localMark { return mark.title }
        return waitingInFull(item.presence) ?? on(item)
    }
    /// "Not yet on Office iMac and MacBook Pro" for two or more waiting devices (one is already said in full by `on`).
    public static func waitingInFull(_ presence: [String]) -> String? {
        let waiting = presence.filter { $0.hasPrefix("Waiting on ") }.map { String($0.dropFirst("Waiting on ".count)) }
        guard waiting.count > 1 else { return nil }
        return "Not yet on " + waiting.dropLast().joined(separator: ", ") + " and " + (waiting.last ?? "")
    }
    /// The "Size" column: a file's size, a folder's number of items; nothing when it has no size of its own.
    public static func size(_ item: BackendCloudContents.Item) -> String {
        if let entries = item.entries { return BackendCloudContentsWords.entries(entries) }
        return item.bytes.map(BackendCloudContentsWords.size) ?? ""
    }
}
