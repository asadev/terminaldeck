import Foundation

// Memory, as the page reads it: src/renderer/memory/bridge.ts (types and readers),
// the words of MemoryPage.tsx, and graph-layout.ts — ported one for one.

public enum MemorySpaceKind: String, Equatable, Sendable, CaseIterable {
    case claudeProject = "claude-project", codex, hoot, knowledge
}

public struct MemorySpace: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: MemorySpaceKind
    public var label: String
    public var root: String
    public var project: String?
    public var sharedWith: [String]
    public var accounts: [String]
    public init(id: String, kind: MemorySpaceKind, label: String, root: String = "", project: String? = nil,
                sharedWith: [String] = [], accounts: [String] = []) {
        self.id = id; self.kind = kind; self.label = label; self.root = root
        self.project = project; self.sharedWith = sharedWith; self.accounts = accounts
    }
}

public struct MemoryLabel: Equatable, Sendable {
    public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

public struct MemoryNoteRow: Equatable, Sendable, Identifiable {
    public var path: String
    public var title: String
    public var description: String?
    public var type: String?
    public var labels: [MemoryLabel]
    public var modifiedAt: Double
    public var links: [String]
    public var id: String { path }
    public init(path: String, title: String, description: String? = nil, type: String? = nil,
                labels: [MemoryLabel] = [], modifiedAt: Double = 0, links: [String] = []) {
        self.path = path; self.title = title; self.description = description; self.type = type
        self.labels = labels; self.modifiedAt = modifiedAt; self.links = links
    }
}

public struct MemoryEdge: Equatable, Sendable, Hashable {
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

public struct MemoryDangling: Equatable, Sendable {
    public var from: String
    public var target: String
    public init(from: String, target: String) { self.from = from; self.target = target }
}

public struct MemoryGraph: Equatable, Sendable {
    public var nodes: [String]
    public var edges: [MemoryEdge]
    public var dangling: [MemoryDangling]
    public init(nodes: [String], edges: [MemoryEdge], dangling: [MemoryDangling]) {
        self.nodes = nodes; self.edges = edges; self.dangling = dangling
    }
}

public struct MemoryNotes: Equatable, Sendable {
    public var notes: [MemoryNoteRow]
    public var graph: MemoryGraph
}

public struct MemoryVersion: Equatable, Sendable {
    public var modifiedAt: Double
    public var bytes: Double
    /// As the engine wants it back with a save.
    public var wire: [String: Any] { ["modifiedAt": modifiedAt, "bytes": bytes] }
}

public struct MemoryLink: Equatable, Sendable {
    public var target: String
    public var to: String?
}

public struct MemoryRead: Equatable, Sendable {
    public var spaceId: String
    public var path: String
    public var text: String
    public var truncated: Bool
    public var version: MemoryVersion
    public var note: MemoryNoteRow
    public var links: [MemoryLink]
    public var backlinks: [String]
    public var indexed: Bool
}

public struct MemoryHit: Equatable, Sendable {
    public var spaceId: String
    public var path: String
    public var title: String
    public var snippet: String
    public init(spaceId: String, path: String, title: String, snippet: String) {
        self.spaceId = spaceId; self.path = path; self.title = title; self.snippet = snippet
    }
}

public struct MemoryWrite: Equatable, Sendable {
    public var conversationId: String
    public var folder: String
    public var at: Double
    public var tool: String
    public var edit: Bool
}

public struct MemoryProvenance: Equatable, Sendable {
    public var writes: [MemoryWrite]
    public var conversationsRead: Int
    public var truncated: Bool
}

public struct MemoryChange: Equatable, Sendable {
    public var version: MemoryVersion?
    public var indexLineRemoved: Bool
}

/// `Answer<T>`: the value, or the engine's sentence.
public enum MemoryAnswer<T: Equatable & Sendable>: Equatable, Sendable {
    case ok(T)
    case failed(String)
    public var value: T? { if case .ok(let v) = self { return v }; return nil }
}

private func obj(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func arr(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
private func str(_ value: Any?, _ fallback: String = "") -> String { value as? String ?? fallback }
private func strOrNil(_ value: Any?) -> String? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return s
}
private func num(_ value: Any?) -> Double {
    guard let n = value as? NSNumber, !(value is Bool), n.doubleValue.isFinite else { return 0 }
    return n.doubleValue
}
private func strings(_ value: Any?) -> [String] { arr(value).compactMap { $0 as? String }.filter { !$0.isEmpty } }
private func isOk(_ value: Any?) -> Bool { (obj(value)["ok"] as? Bool) == true }
private func failure(_ value: Any?, _ fallback: String) -> String { str(obj(value)["error"], fallback) }

public enum MemoryWire {
    public static let spaces = "memory:spaces"
    public static let notes = "memory:notes"
    public static let read = "memory:read"
    public static let search = "memory:search"
    public static let save = "memory:save"
    public static let delete = "memory:delete"
    public static let provenance = "memory:provenance"
    /// Event: `(spaceId)` when a memory's notes changed on disk.
    public static let changed = "memory:changed"

    public static func spaces(_ value: Any?) -> [MemorySpace] {
        arr(obj(value)["spaces"]).map(obj).map { space in
            MemorySpace(id: str(space["id"]),
                        kind: MemorySpaceKind(rawValue: str(space["kind"])) ?? .claudeProject,
                        label: str(space["label"], str(space["id"])),
                        root: str(space["root"]),
                        project: strOrNil(space["project"]),
                        sharedWith: strings(space["sharedWith"]),
                        accounts: strings(space["accounts"]))
        }.filter { !$0.id.isEmpty }
    }

    public static func noteRow(_ value: Any?) -> MemoryNoteRow {
        let note = obj(value)
        return MemoryNoteRow(
            path: str(note["path"]),
            title: str(note["title"], str(note["path"])),
            description: strOrNil(note["description"]),
            type: strOrNil(note["type"]),
            labels: arr(note["labels"]).map(obj).map { MemoryLabel(key: str($0["key"]), value: str($0["value"])) }
                .filter { !$0.key.isEmpty && !$0.value.isEmpty },
            modifiedAt: num(note["modifiedAt"]),
            links: strings(note["links"]))
    }

    public static func notes(_ value: Any?) -> MemoryAnswer<MemoryNotes> {
        guard isOk(value) else { return .failed(failure(value, "This memory could not be read.")) }
        let v = obj(value)
        let graph = obj(v["graph"])
        return .ok(MemoryNotes(
            notes: arr(v["notes"]).map(noteRow).filter { !$0.path.isEmpty },
            graph: MemoryGraph(
                nodes: arr(graph["nodes"]).map { str(obj($0)["path"]) }.filter { !$0.isEmpty },
                edges: arr(graph["edges"]).map(obj).map { MemoryEdge(from: str($0["from"]), to: str($0["to"])) }
                    .filter { !$0.from.isEmpty && !$0.to.isEmpty },
                dangling: arr(graph["dangling"]).map(obj).map { MemoryDangling(from: str($0["from"]), target: str($0["target"])) }
                    .filter { !$0.from.isEmpty && !$0.target.isEmpty })))
    }

    public static func read(_ value: Any?) -> MemoryAnswer<MemoryRead> {
        guard isOk(value) else { return .failed(failure(value, "This note could not be read.")) }
        let v = obj(value)
        let version = obj(v["version"])
        return .ok(MemoryRead(
            spaceId: str(v["spaceId"]),
            path: str(v["path"]),
            text: str(v["text"]),
            truncated: (v["truncated"] as? Bool) == true,
            version: MemoryVersion(modifiedAt: num(version["modifiedAt"]), bytes: num(version["bytes"])),
            note: noteRow(v["note"]),
            links: arr(v["links"]).map(obj).map { MemoryLink(target: str($0["target"]), to: strOrNil($0["to"])) }
                .filter { !$0.target.isEmpty },
            backlinks: strings(v["backlinks"]),
            indexed: (v["indexed"] as? Bool) == true))
    }

    public static func hits(_ value: Any?) -> [MemoryHit] {
        arr(obj(value)["hits"]).map(obj).map {
            MemoryHit(spaceId: str($0["spaceId"]), path: str($0["path"]), title: str($0["title"], str($0["path"])), snippet: str($0["snippet"]))
        }.filter { !$0.spaceId.isEmpty && !$0.path.isEmpty }
    }

    public static func change(_ value: Any?) -> MemoryAnswer<MemoryChange> {
        guard isOk(value) else { return .failed(failure(value, "Nothing was changed.")) }
        let v = obj(value)
        let version = obj(v["version"])
        return .ok(MemoryChange(
            version: version.isEmpty ? nil : MemoryVersion(modifiedAt: num(version["modifiedAt"]), bytes: num(version["bytes"])),
            indexLineRemoved: (v["indexLineRemoved"] as? Bool) == true))
    }

    public static func provenance(_ value: Any?) -> MemoryAnswer<MemoryProvenance> {
        guard isOk(value) else { return .failed(failure(value, "This could not be worked out.")) }
        let v = obj(value)
        return .ok(MemoryProvenance(
            writes: arr(v["writes"]).map(obj).map {
                MemoryWrite(conversationId: str($0["conversationId"]), folder: str($0["folder"]), at: num($0["at"]),
                            tool: str($0["tool"]), edit: str($0["action"]) == "edit")
            }.filter { !$0.conversationId.isEmpty },
            conversationsRead: Int(num(v["conversationsRead"])),
            truncated: (v["truncated"] as? Bool) == true))
    }
}

// MARK: - Words (MemoryPage.tsx)

public enum MemoryRules {
    public static let searchDelay: Duration = .milliseconds(200)
    public static let kindOrder: [MemorySpaceKind] = [.hoot, .claudeProject, .codex, .knowledge]

    public static func kindTitle(_ kind: MemorySpaceKind) -> String {
        switch kind {
        case .hoot: return "Hoot"
        case .claudeProject: return "Claude Code"
        case .codex: return "Codex"
        case .knowledge: return "Project knowledge"
        }
    }

    public static func saveEffect(_ kind: MemorySpaceKind) -> String {
        switch kind {
        case .hoot: return "Saves the note on disk. Hoot reads it the next time it starts."
        case .claudeProject: return "Saves the note on disk. Claude Code reads it at the start of the next conversation in this folder."
        case .codex: return "Saves the note on disk. Codex reads it at the start of its next conversation."
        case .knowledge: return "Saves the record on disk. It is used in the next brief or plan for this project."
        }
    }

    public static func sharedLine(_ space: MemorySpace) -> String? {
        let count = space.sharedWith.count
        if count == 0 { return nil }
        return "Shared with \(count) folder\(count == 1 ? "" : "s")"
    }

    /// The second line of a memory's row.
    public static func place(_ space: MemorySpace) -> String? {
        switch space.kind {
        case .claudeProject: return space.project ?? "Folder name as Claude Code stores it"
        case .knowledge: return space.project
        case .codex: return space.accounts.isEmpty ? nil : space.accounts.joined(separator: ", ")
        case .hoot: return nil
        }
    }

    /// The memories in the list's order: one group per kind that has any.
    public static func groups(_ spaces: [MemorySpace]) -> [(kind: MemorySpaceKind, spaces: [MemorySpace])] {
        kindOrder.compactMap { kind in
            let ofKind = spaces.filter { $0.kind == kind }
            return ofKind.isEmpty ? nil : (kind, ofKind)
        }
    }

    /// The page opens on the open project's own memory, else Hoot's, else the first.
    public static func firstSpace(_ spaces: [MemorySpace], projectPath: String?) -> MemorySpace? {
        if let projectPath {
            if let own = spaces.first(where: { $0.kind == .claudeProject && $0.project == projectPath })
                ?? spaces.first(where: { $0.kind == .claudeProject && $0.sharedWith.contains(projectPath) })
                ?? spaces.first(where: { $0.kind == .knowledge && $0.project == projectPath }) {
                return own
            }
        }
        return spaces.first(where: { $0.kind == .hoot }) ?? spaces.first
    }

    /// The labels a note shows: its own, else its type.
    public static func labels(_ note: MemoryNoteRow) -> [MemoryLabel] {
        if !note.labels.isEmpty { return note.labels }
        if let type = note.type { return [MemoryLabel(key: "type", value: type)] }
        return []
    }

    public static func labelText(_ label: MemoryLabel) -> String {
        label.key == "verified" ? "verified \(label.value)" : label.value
    }

    /// "16 Jul 2026" in the person's own order; "" for no date.
    public static func dateOf(_ ms: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        if ms <= 0 { return "" }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        style.timeZone = timeZone
        return Date(timeIntervalSince1970: ms / 1000).formatted(style)
    }

    public static func danglingLine(_ count: Int) -> String {
        "\(count) link\(count == 1 ? "" : "s") reach\(count == 1 ? "es" : "") no note."
    }

    /// "Claude Code · alpha", the memory a search hit came from.
    public static func hitSource(_ hit: MemoryHit, spaces: [MemorySpace]) -> String {
        guard let space = spaces.first(where: { $0.id == hit.spaceId }) else { return "" }
        return "\(kindTitle(space.kind)) · \(space.label)"
    }

    public static func deletedMessage(indexLineRemoved: Bool) -> String {
        indexLineRemoved ? "Moved to the Trash, and its line taken out of MEMORY.md." : "Moved to the Trash."
    }

    public static func writeLine(_ write: MemoryWrite) -> String {
        "\(write.edit ? "Edited" : "Written") in conversation \(String(write.conversationId.prefix(8)))"
    }

    public static func readLine(_ provenance: MemoryProvenance) -> String {
        let n = provenance.conversationsRead
        return "\(n) recent conversation\(n == 1 ? "" : "s") read\(provenance.truncated ? "; older ones were not." : ".")"
    }

    /// The save button's reason not to, as `FileEditor` works it out.
    public static func saveBecause(truncated: Bool, dirty: Bool) -> String? {
        if truncated { return "This note is larger than the page can show, so saving it here would cut it short." }
        return dirty ? nil : "Nothing has changed."
    }

    // MARK: Graph

    public static let graphWidth = 800.0
    public static let graphHeight = 480.0
    /// Past this many notes the dots are not labelled.
    public static let labelLimit = 40

    public static func degrees(_ graph: MemoryGraph) -> [String: Int] {
        var degree: [String: Int] = [:]
        for edge in graph.edges {
            degree[edge.from, default: 0] += 1
            degree[edge.to, default: 0] += 1
        }
        return degree
    }

    public static func radius(degree: Int) -> Double { 4 + min(6, Double(degree).squareRoot() * 1.6) }

    private static func rounds(for count: Int) -> Int {
        if count <= 80 { return 300 }
        if count <= 250 { return 150 }
        if count <= 600 { return 60 }
        return 25
    }

    /// `layoutGraph`: a force-directed picture that is the same every time for the same notes.
    public static func layout(nodes: [String], edges: [MemoryEdge], width: Double, height: Double,
                              margin: Double = 24, iterations: Int? = nil) -> [String: (x: Double, y: Double)] {
        let count = nodes.count
        var out: [String: (x: Double, y: Double)] = [:]
        if count == 0 { return out }
        let cx = width / 2, cy = height / 2
        if count == 1 { out[nodes[0]] = (cx, cy); return out }

        var index: [String: Int] = [:]
        for (at, node) in nodes.enumerated() where index[node] == nil { index[node] = at }
        var x = [Double](repeating: 0, count: count)
        var y = [Double](repeating: 0, count: count)
        let radius = min(width, height) / 2 - margin
        for i in 0..<count {
            let angle = 2 * Double.pi * Double(i) / Double(count)
            x[i] = cx + radius * cos(angle)
            y[i] = cy + radius * sin(angle)
        }
        let links: [(Int, Int)] = edges.compactMap { edge in
            guard let a = index[edge.from], let b = index[edge.to], a != b else { return nil }
            return (a, b)
        }
        let area = (width - 2 * margin) * (height - 2 * margin)
        let k = (area / Double(count)).squareRoot()
        let rounds = iterations ?? rounds(for: count)
        var temperature = min(width, height) / 8
        let cooling = temperature / Double(rounds + 1)
        var dx = [Double](repeating: 0, count: count)
        var dy = [Double](repeating: 0, count: count)

        for _ in 0..<rounds {
            for i in 0..<count { dx[i] = 0; dy[i] = 0 }
            for i in 0..<count {
                for j in (i + 1)..<count where j < count {
                    var ex = x[i] - x[j]
                    var ey = y[i] - y[j]
                    var distance = (ex * ex + ey * ey).squareRoot()
                    if distance < 0.01 {
                        let a = (i % 7) - 3, b = (j % 5) - 2
                        ex = 0.01 * Double(a == 0 ? 1 : a)
                        ey = 0.01 * Double(b == 0 ? 1 : b)
                        distance = (ex * ex + ey * ey).squareRoot()
                    }
                    let push = (k * k) / distance
                    dx[i] += (ex / distance) * push
                    dy[i] += (ey / distance) * push
                    dx[j] -= (ex / distance) * push
                    dy[j] -= (ey / distance) * push
                }
            }
            for (a, b) in links {
                let ex = x[a] - x[b]
                let ey = y[a] - y[b]
                let distance = max((ex * ex + ey * ey).squareRoot(), 0.01)
                let pull = (distance * distance) / k
                dx[a] -= (ex / distance) * pull
                dy[a] -= (ey / distance) * pull
                dx[b] += (ex / distance) * pull
                dy[b] += (ey / distance) * pull
            }
            for i in 0..<count {
                dx[i] += (cx - x[i]) * 0.02 * k * 0.1
                dy[i] += (cy - y[i]) * 0.02 * k * 0.1
                let length = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
                if length > 0 {
                    let step = min(length, temperature)
                    x[i] += (dx[i] / length) * step
                    y[i] += (dy[i] / length) * step
                }
                x[i] = min(width - margin, max(margin, x[i]))
                y[i] = min(height - margin, max(margin, y[i]))
            }
            temperature = max(temperature - cooling, 0.5)
        }
        for i in 0..<count where out[nodes[i]] == nil { out[nodes[i]] = (x[i], y[i]) }
        return out
    }
}
