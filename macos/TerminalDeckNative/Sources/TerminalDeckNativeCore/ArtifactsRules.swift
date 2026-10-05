import Foundation

/// The Artifacts page's rules, ported one for one from the web page
/// (src/renderer/components/ArtifactsPanel.tsx, relative-time.ts) so the two
/// surfaces cannot disagree about what an artifact is, what a row says, or what
/// the counts and empty states read.
///
/// The meaning that has to hold (the web header carries the whole argument):
/// **an artifact is a prototype, a picture or a recording** — a page, an image,
/// a PDF, a video or a sound. Markdown, prose, source and data are files, and
/// Files is the page for them. The rule runs once, on the answer, before any
/// count is taken (`onlyArtifacts`).
public enum ArtifactRules {

    // MARK: What it is

    /// Same vocabulary as the web's `KIND_BY_EXTENSION`.
    static let kindByExtension: [String: String] = {
        var map: [String: String] = [:]
        func add(_ kind: String, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = kind }
        }
        add("Document", "md markdown txt rtf pdf doc docx")
        add("Web page", "html htm xhtml")
        add("Style sheet", "css scss sass less")
        add("Image", "png jpg jpeg gif webp svg avif ico bmp heic heif")
        add("Video", "mp4 m4v mov webm")
        add("Sound", "mp3 m4a wav aac flac ogg")
        add("Data", "csv tsv json jsonl ndjson xml yaml yml toml sql geojson parquet")
        add("Code", "ts tsx js jsx mjs cjs py rb go rs java kt swift c h cpp hpp cs php sh bash zsh ps1 lua vue svelte")
        add("Notebook", "ipynb")
        return map
    }()

    /// The extensions that make a row — `ARTIFACT_EXTENSIONS` on the web,
    /// `PAGE_/IMAGE_/MEDIA_EXTENSIONS` on the phone. Change all three together.
    public static let artifactExtensions: Set<String> = [
        "html", "htm", "xhtml",
        "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "heic", "heif", "svg",
        "pdf", "mp4", "m4v", "mov", "webm", "mp3", "m4a", "wav", "aac", "flac", "ogg",
    ]

    public static func lastComponent(_ relPath: String) -> String {
        guard let slash = relPath.lastIndex(of: "/") else { return relPath }
        return String(relPath[relPath.index(after: slash)...])
    }

    /// The folder part of a project-relative path ("" for the project root).
    public static func directoryOf(_ relPath: String) -> String {
        guard let slash = relPath.lastIndex(of: "/") else { return "" }
        return String(relPath[..<slash])
    }

    /// Lower-cased, without the dot. A dotfile with no second dot has none.
    public static func extensionOf(_ relPath: String) -> String {
        let name = lastComponent(relPath)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// What kind of thing this is, in one word a person already knows.
    public static func kindOf(_ relPath: String) -> String {
        let name = lastComponent(relPath)
        if name.hasPrefix("."), !name.dropFirst().contains(".") { return "Setting" }
        let ext = extensionOf(relPath)
        if ext.isEmpty { return "File" }
        return kindByExtension[ext] ?? "File"
    }

    /// Whether this belongs on the page at all — decided from the path, so a
    /// deleted prototype stays and a deleted plan stays out.
    public static func isArtifact(_ relPath: String) -> Bool {
        artifactExtensions.contains(extensionOf(relPath))
    }

    /// A file the agent produced whole at least once.
    public static func wasMade(_ artifact: Artifact) -> Bool { artifact.writes > 0 }

    /// The scan, less everything that is not an artifact. Session file counts are
    /// recounted off what survived, and a session left with none leaves the chips.
    public static func onlyArtifacts(_ list: ArtifactList) -> (list: ArtifactList, hidden: Int) {
        let artifacts = list.artifacts.filter { isArtifact($0.relPath) }
        if artifacts.count == list.artifacts.count { return (list, 0) }
        var files: [String: Int] = [:]
        for artifact in artifacts {
            for id in artifact.sessionIds { files[id, default: 0] += 1 }
        }
        var narrowed = list
        narrowed.artifacts = artifacts
        narrowed.sessions = list.sessions.compactMap { entry in
            guard let count = files[entry.sessionId] else { return nil }
            return ArtifactSession(sessionId: entry.sessionId, at: entry.at, files: count)
        }
        return (narrowed, list.artifacts.count - artifacts.count)
    }

    /// How the preview should treat a path — `previewKindOf` on the web.
    public enum PreviewKind: String, Equatable, Sendable {
        case document, text, image, page, none
    }

    public static func previewKindOf(_ relPath: String) -> PreviewKind {
        switch kindOf(relPath) {
        case "Web page": return .page
        case "Document":
            let lower = relPath.lowercased()
            return lower.hasSuffix(".md") || lower.hasSuffix(".markdown") ? .document : .text
        case "Image": return .image
        case "File", "Notebook", "Video", "Sound": return .none
        default: return .text
        }
    }

    /// What the Open button says, which is what the thing is.
    public static func openLabel(_ kind: PreviewKind) -> String {
        switch kind {
        case .page: return "Run it in your browser"
        case .image: return "Open the picture"
        default: return "Open it on this machine"
        }
    }

    // MARK: The list on screen

    /// The rows for the chips and filter as set: made/changed, one session, a name filter.
    public static func visible(_ artifacts: [Artifact], kind: ArtifactScopeKind, session: String?, filter: String) -> [Artifact] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return artifacts.filter { artifact in
            if wasMade(artifact) != (kind == .made) { return false }
            if let session, !artifact.sessionIds.contains(session) { return false }
            if needle.isEmpty { return true }
            return artifact.relPath.lowercased().contains(needle)
        }
    }

    /// How many rows each chip draws, off the narrowed list.
    public static func counts(_ artifacts: [Artifact]) -> (made: Int, changed: Int) {
        let made = artifacts.filter(wasMade).count
        return (made, artifacts.count - made)
    }

    /// Keep a session filter only while its chip is drawn (the row shows with more than one session).
    public static func keptSession(_ session: String?, sessions: [ArtifactSession]) -> String? {
        guard let session else { return nil }
        return sessions.count > 1 && sessions.contains(where: { $0.sessionId == session }) ? session : nil
    }

    /// The page opens on content: keep a selection that is still visible, else the newest row.
    public static func selection(current: String?, visible: [Artifact]) -> String? {
        guard let first = visible.first else { return nil }
        if let current, visible.contains(where: { $0.relPath == current }) { return current }
        return first.relPath
    }

    /// A session chip: its name where the window knows it, else when it ran — and the file count.
    public static func sessionChipLabel(_ session: ArtifactSession, names: [String: String], now: Double,
                                        locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let who = names[session.sessionId] ?? relativeTime(session.at, now: now, locale: locale, timeZone: timeZone)
        return "\(who) · \(session.files) file\(session.files == 1 ? "" : "s")"
    }

    // MARK: Sentences

    /// The empty page when nothing was written — every fact the scan has, in one line.
    ///
    /// It names which sessions were read, from the scope the answer itself
    /// carries, so the sentence always agrees with the selected scope: "40
    /// sessions read" under *Every session* read like this folder's own forty.
    public static func nothingFound(_ list: ArtifactList) -> String {
        let every = list.scope == .all
        if list.sessionsScanned == 0 {
            return every
                ? "Nothing written or edited in \(list.root) — no sessions have been recorded on this Mac yet."
                : "Nothing written or edited in \(list.root) — no sessions have been recorded for it yet."
        }
        let place = "Nothing written or edited in \(list.root) by \(every ? "any session" : "its own sessions")"
        let read = every ? "\(list.sessionsScanned) read across every project" : "\(list.sessionsScanned) read"
        let elsewhere = list.outsideProject > 0
            ? ", \(list.outsideProject) change\(list.outsideProject == 1 ? "" : "s") to files outside it"
            : ""
        return "\(place) — \(read)\(elsewhere)."
    }

    /// The empty page when the rule took every row.
    public static func nothingButFiles(_ list: ArtifactList, hidden: Int) -> String {
        "No prototypes in \(list.root) — \(hidden) file\(hidden == 1 ? "" : "s") of prose or source, which is what Files is for."
    }

    /// The one-line summary under the controls. `list` is the narrowed one.
    public static func summarize(_ list: ArtifactList, shown: Int, kind: ArtifactScopeKind, hidden: Int = 0) -> String {
        if list.artifacts.isEmpty {
            return hidden > 0 ? nothingButFiles(list, hidden: hidden) : nothingFound(list)
        }
        let total = list.artifacts.filter { wasMade($0) == (kind == .made) }.count
        let noun = kind == .made ? "made here" : "changed"
        var parts: [String] = []
        parts.append(shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)")
        parts.append("\(list.sessions.count) session\(list.sessions.count == 1 ? "" : "s")")
        if list.truncated { parts.append("older work not read") }
        return parts.joined(separator: " · ")
    }

    /// "2 writes · 5 edits", with the halves that are zero left out.
    public static func changeSummary(_ artifact: Artifact) -> String {
        var parts: [String] = []
        if artifact.writes > 0 { parts.append("\(artifact.writes) write\(artifact.writes == 1 ? "" : "s")") }
        if artifact.edits > 0 { parts.append("\(artifact.edits) edit\(artifact.edits == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The detail heading's meta line: kind · folder · when · size.
    public static func detailMeta(_ artifact: Artifact, now: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let folder = directoryOf(artifact.relPath)
        let parts = [
            kindOf(artifact.relPath),
            folder.isEmpty ? "in the project root" : folder,
            "last \(relativeTime(artifact.lastAt, now: now, locale: locale, timeZone: timeZone))",
            artifact.onDisk.map { formatBytes($0.bytes) } ?? "no longer on disk",
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The note in the list when the chips leave no rows.
    public static func noRowsNote(filter: String, session: String?, kind: ArtifactScopeKind) -> String {
        if !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session != nil {
            return "Nothing matches that filter."
        }
        return kind == .made
            ? "No agent has made an artifact here yet. What it edited is under Changed."
            : "Every artifact here was made by an agent rather than edited into."
    }

    public static let cancelledMessage = "That scan was stopped before it finished. Read it again?"

    /// The engine's error sentence without Electron's wrapper.
    public static func readFailure(_ message: String) -> String {
        guard message.hasPrefix("Error invoking remote method '"),
              let close = message.range(of: "':", range: message.index(message.startIndex, offsetBy: 30)..<message.endIndex)
        else { return message }
        return message[close.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// "Reading this project’s history did not answer within 20 seconds."
    public static func overdue(_ what: String, seconds: Double) -> String {
        let rounded = seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return "\(what) did not answer within \(rounded) second\(rounded == "1" ? "" : "s")."
    }

    // MARK: Time and size, in the one spelling the whole window uses

    /// "just now", "5m ago", "3h ago", "4d ago", then a date. `at`/`now` in ms.
    public static func relativeTime(_ at: Double, now: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        if at == 0 { return "" }
        let delta = now - at
        let minute = 60_000.0, hour = 60 * minute, day = 24 * hour
        if delta < minute { return "just now" }
        if delta < hour { return "\(Int((delta / minute).rounded()))m ago" }
        if delta < day { return "\(Int((delta / hour).rounded()))h ago" }
        if delta < 30 * day { return "\(Int((delta / day).rounded()))d ago" }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        style.timeZone = timeZone
        return Date(timeIntervalSince1970: at / 1000).formatted(style)
    }

    /// Bytes as a person reads them, 1024-based.
    public static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: Where it is

    /// The artifact's file, or nil when the path would leave the project folder.
    public static func fileURL(root: String, relPath: String) -> URL? {
        guard root.hasPrefix("/"), !relPath.isEmpty, !relPath.hasPrefix("/") else { return nil }
        let base = URL(fileURLWithPath: root).standardizedFileURL
        let file = base.appendingPathComponent(relPath).standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard file.path.hasPrefix(basePath), file.path.count > basePath.count else { return nil }
        return file
    }

    // MARK: Which project

    /// Whether a sidebar heading id is a folder (the rest — `other`, `hoot-started`,
    /// `app:…`, `machine:…`, `server:…` — are runs that are not projects).
    public static func isFolder(_ id: String) -> Bool { id.hasPrefix("/") || id.hasPrefix("~/") }

    /// The project the page's Artifacts view is about.
    ///
    /// The page says it: its `sidebar` message carries `project`, the same
    /// `activeProjectPath` (App.tsx) the web Artifacts panel is handed. Only
    /// when that is missing — a page too old to send it, or no project at all —
    /// does the first open project stand in, as the page itself would choose.
    public static func currentProject(pageProject: String?, projects: [SidebarProject]) -> String? {
        if let project = pageProject?.nonEmpty { return project }
        return projects.first(where: { isFolder($0.id) })?.id
    }

    /// The `project` the page put in its `sidebar` state, read off the decoded
    /// `SidebarState` by name. The page sends it (native-sidebar.ts); reading it
    /// by name lets this build before and after that field is declared there.
    /// Swap for `state.project` once it is.
    public static func pageProject(in state: Any?) -> String? {
        guard let state else { return nil }
        return (Mirror(reflecting: state).descendant("project") as? String)?.nonEmpty
    }

    // MARK: Reading the file (fs:read)

    public enum ReadState: Equatable, Sendable {
        case text(String)
        case note(String)
        case error(String)
    }

    /// `fs:read`'s reply as something to show — `describeRead` on the web.
    public static func describeRead(_ reply: Any, bytes: Int?) -> ReadState {
        guard let dict = reply as? [String: Any] else { return .error("That file could not be read.") }
        let kind = dict["kind"] as? String
        if kind == "text", let text = dict["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .note("This file is empty.") : .text(text)
        }
        if kind == "too-large" {
            let limit = (dict["limit"] as? NSNumber).map { formatBytes($0.intValue) } ?? "the preview limit"
            return .note("Too big to preview here — over \(limit). Open it in Files.")
        }
        if kind == "binary" {
            let size = bytes.map { " (\(formatBytes($0)))" } ?? ""
            return .note("Not text\(size), so there is nothing to show inline.")
        }
        return .error("That file could not be read.")
    }
}

/// What the page found last time, so coming back is instant — the web's
/// `panel-cache` with the Artifacts page's two-minute freshness.
public struct ArtifactsCache<Value> {
    public static var freshFor: Double { 120 }
    public static var maxEntries: Int { 64 }

    private var entries: [String: (value: Value, at: Double)] = [:]
    private var order: [String] = []

    public init() {}

    public static func key(root: String, scope: ArtifactScope) -> String { "artifacts:list:\(root)|\(scope.rawValue)" }

    public mutating func remember(_ key: String, _ value: Value, at now: Double) {
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = (value, now)
        while order.count > Self.maxEntries { entries[order.removeFirst()] = nil }
    }

    /// The held value and whether it is fresh enough to skip a re-read. `now` in seconds.
    public func recall(_ key: String, now: Double, freshFor: Double = Self.freshFor) -> (value: Value, fresh: Bool)? {
        guard let entry = entries[key] else { return nil }
        let age = max(0, now - entry.at)
        return (entry.value, freshFor > 0 && age <= freshFor)
    }
}
