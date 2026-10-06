import Foundation

/// Handing what was pointed at to a session — the Swift reading of
/// `src/shared/annotate.ts`, `DeviceShotPopup.tsx`'s one line, and the send
/// rules in `browser/agent-target.ts` and `chat/attach/mentions.ts`.
///
/// One message, worded exactly as the web page words it, so an agent reading a
/// round from the native inspector reads the same sentence it would from the
/// page's Annotate — and `annotate:save` keeps the same round for
/// `devices.annotations`.

/// Where a round was made.
public struct AnnotateWhere: Equatable, Sendable {
    public var kind: String
    /// "iOS Simulator", "Android emulator", "Android phone".
    public var place: String
    public var name: String
    public var deviceId: String?
    public var app: String?
    public var screen: String?

    public init(kind: String = "device", place: String, name: String, deviceId: String? = nil,
                app: String? = nil, screen: String? = nil) {
        self.kind = kind
        self.place = place
        self.name = name
        self.deviceId = deviceId
        self.app = app
        self.screen = screen
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            guard let value = row[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        kind = text("kind") ?? "device"
        place = text("place") ?? ""
        name = text("name") ?? ""
        deviceId = text("deviceId")
        app = text("app")
        screen = text("screen")
    }

    public var json: [String: Any] {
        var out: [String: Any] = ["kind": kind, "place": place, "name": name]
        if let deviceId { out["deviceId"] = deviceId }
        if let app { out["app"] = app }
        if let screen { out["screen"] = screen }
        return out
    }

    /// The short name of where this is, for the head of the panel.
    public var short: String {
        if let app { return "\(name) · \(app)" }
        return name
    }
}

/// What finds an element again — in words for a person and in handles for code.
public struct AnnotatedElement: Equatable, Hashable, Sendable {
    public var role: String?
    public var name: String?
    public var identifier: String?
    public var component: String?
    public var source: SourceLocation?

    public init(role: String? = nil, name: String? = nil, identifier: String? = nil,
                component: String? = nil, source: SourceLocation? = nil) {
        self.role = role
        self.name = name
        self.identifier = identifier
        self.component = component
        self.source = source
    }

    /// What a tree node is, as Annotate records it (`elementOf` in `DevicesPage.tsx`).
    public init(node: DeviceNode) {
        let name = DeviceTreeQuery.nodeName(node)
        let identifier = [node.identifier, node.testID].compactMap { $0 }.first { !$0.isEmpty }
        let role = DeviceTreeQuery.plainRole(node.role)
        self.role = role.isEmpty ? nil : role
        self.name = !name.isEmpty && name != identifier ? name : nil
        self.identifier = identifier
        self.component = node.component
        self.source = node.sourceLocation
    }

    public var json: [String: Any] {
        var out: [String: Any] = [:]
        if let role { out["role"] = role }
        if let name { out["name"] = name }
        if let identifier { out["identifier"] = identifier }
        if let component { out["component"] = component }
        if let source {
            var place: [String: Any] = ["file": source.file]
            if let line = source.line { place["line"] = line }
            if let column = source.column { place["column"] = column }
            out["source"] = place
        }
        return out
    }
}

/// One numbered marker.
public struct Annotation: Equatable, Sendable, Identifiable {
    public var id: String
    /// The number on the marker, from 1. Renumbered when one is removed.
    public var n: Int
    public var rect: NormRect
    /// Null for a point on blank space.
    public var element: AnnotatedElement?
    /// The tree node it was made from, when it was made from one. Native only — never sent.
    public var nodeRef: String?

    public init(id: String, n: Int, rect: NormRect, element: AnnotatedElement?, nodeRef: String? = nil) {
        self.id = id
        self.n = n
        self.rect = rect
        self.element = element
        self.nodeRef = nodeRef
    }

    /// Add one, numbered after the last.
    public static func adding(_ list: [Annotation], id: String, rect: NormRect,
                              element: AnnotatedElement?, nodeRef: String? = nil) -> [Annotation] {
        list + [Annotation(id: id, n: list.count + 1, rect: rect, element: element, nodeRef: nodeRef)]
    }

    /// Remove one and close the gap, so the numbers match the markers drawn.
    public static func removing(_ list: [Annotation], id: String) -> [Annotation] {
        list.filter { $0.id != id }.enumerated().map { index, entry in
            var copy = entry
            copy.n = index + 1
            return copy
        }
    }
}

/// One frozen picture and everything pointed at on it.
public struct AnnotationRound: Equatable, Sendable {
    public var id: String
    /// Milliseconds since 1970, as the page's `Date.now()`.
    public var createdAt: Double
    public var where_: AnnotateWhere
    public var frameWidth: Int
    public var frameHeight: Int
    public var annotations: [Annotation]
    public var note: String

    public init(id: String, createdAt: Double, where_: AnnotateWhere, frameWidth: Int, frameHeight: Int,
                annotations: [Annotation], note: String) {
        self.id = id
        self.createdAt = createdAt
        self.where_ = where_
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.annotations = annotations
        self.note = note
    }

    /// The round as `annotate:save` reads it (`src/main/devices/round.ts`).
    public var json: [String: Any] {
        [
            "id": id,
            "createdAt": createdAt,
            "where": where_.json,
            "frame": ["width": frameWidth, "height": frameHeight],
            "note": note,
            "annotations": annotations.map { entry -> [String: Any] in
                [
                    "id": entry.id,
                    "n": entry.n,
                    "rect": entry.rect.json,
                    "element": entry.element.map { $0.json as Any } ?? NSNull(),
                ]
            },
        ]
    }
}

// MARK: - The words

public enum Handoff {
    /// Flatten for a terminal: no controls, no line breaks, one space between words.
    public static func flat(_ value: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let control = code < 0x20 || (code >= 0x7F && code <= 0x9F) || code == 0x2028 || code == 0x2029
            out.unicodeScalars.append(control ? " " : scalar)
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static let maxQuoted = 120

    static func clip(_ value: String, _ max: Int = maxQuoted) -> String {
        let one = flat(value)
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }

    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    /// `button "Save" (id save-button, source src/Home.tsx:42)` — or just the role, or nothing.
    public static func describeElement(_ element: AnnotatedElement?) -> String {
        guard let element else { return "blank space" }
        let head = [element.role.map { clip($0, 40) } ?? "", element.name.map { "\"\(clip($0))\"" } ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var handles: [String] = []
        if let identifier = element.identifier, !identifier.isEmpty { handles.append("id \(clip(identifier))") }
        if let component = element.component, !component.isEmpty { handles.append("component \(clip(component, 80))") }
        if let source = element.source {
            var place = "source \(clip(source.file, 200))"
            if let line = source.line {
                place += ":\(line)"
                if let column = source.column { place += ":\(column)" }
            }
            handles.append(place)
        }
        let named = head.isEmpty ? "element" : head
        return handles.isEmpty ? named : "\(named) (\(handles.joined(separator: ", ")))"
    }

    /// `the iOS Simulator "iPhone 17 Pro", app com.example.Shop, screen Checkout`
    public static func describeWhere(_ where_: AnnotateWhere) -> String {
        var parts = ["the \(clip(where_.place, 40))\(where_.name.isEmpty ? "" : " \"\(clip(where_.name, 60))\"")"]
        if let app = where_.app { parts.append("app \(clip(app, 120))") }
        if let screen = where_.screen { parts.append("screen \(clip(screen, 120))") }
        return parts.joined(separator: ", ")
    }

    /// `#1 button "Save" (id save) at 4% across, 44% down, 92% x 6%`
    public static func describeMarker(_ entry: Annotation) -> String {
        let r = entry.rect
        let at = "at \(percent(r.x)) across, \(percent(r.y)) down, \(percent(r.width)) x \(percent(r.height))"
        return "#\(entry.n) \(describeElement(entry.element)) \(at)"
    }

    /// The exact message a session receives for a round — `composeHandoff`.
    public static func composeRound(_ round: AnnotationRound, picturePath: String) -> String {
        let count = "\(round.annotations.count) marked element\(round.annotations.count == 1 ? "" : "s")"
        let size = "\(round.frameWidth) x \(round.frameHeight)"
        let picture = picturePath.isEmpty
            ? "the picture could not be saved"
            : "picture with the numbered markers: \(picturePath) (\(size))"
        let head = "[Annotate: \(count) on \(describeWhere(round.where_)); \(picture)]"
        let marked = round.annotations.map(describeMarker).joined(separator: "; ")
        let note = flat(round.note)
        return [head, marked.isEmpty ? "" : "\(marked).", note.isEmpty ? "" : "What should change: \(note)"]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `Look [iOS Simulator screenshot of "iPhone 17": /p/x.png (1206 x 2622)]` — `composeDeviceShot`.
    public static func composeScreenshot(path: String, width: Int, height: Int, kind: String,
                                         deviceName: String, instruction: String) -> String {
        let name = deviceName.isEmpty ? "" : " of \"\(flat(deviceName))\""
        let context = "[\(flat(kind)) screenshot\(name): \(path) (\(width) x \(height))]"
        let lead = flat(instruction)
        return lead.isEmpty ? context : "\(lead) \(context)"
    }

    /// The milliseconds between the two writes of a send. Measured in the web app:
    /// back to back they are one chunk and nothing is submitted; 30 ms apart submits.
    /// The native side waits longer because its first write is an HTTP post it cannot await.
    public static let submitGapMilliseconds = 150

    /// The writes a session must receive, in order, for one line to be sent and
    /// submitted: the text (with a trailing space when it holds an `@`, so the
    /// CLI's mention menu cannot eat the Return), then the Return on its own.
    /// Empty when there is nothing to send.
    public static func terminalWrites(_ text: String) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        return [typed.contains("@") ? "\(typed) " : typed, "\r"]
    }
}

// MARK: - The sessions a send can go to

/// One session a send can reach, as the picker shows it. Mirrors `AgentSession`
/// for this Mac's sessions and the ones on paired machines.
public struct AgentSessionRow: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var cwd: String
    public var provider: String
    public var ended: Bool
    /// `folder · Session 2`, or the name the session was given; `PC · …` on another machine.
    public var label: String
    /// The paired machine it runs on, or empty for this Mac — which route a send takes.
    public var machineId: String
    /// The paired machine's name, or the server's for a terminal on one.
    public var machineName: String
    /// A terminal on a server this window opened: `id` is its tab id.
    public var onServer: Bool

    public init(id: String, cwd: String, provider: String, ended: Bool, label: String,
                machineId: String = "", machineName: String = "", onServer: Bool = false) {
        self.id = id
        self.cwd = cwd
        self.provider = provider
        self.ended = ended
        self.label = label
        self.machineId = machineId
        self.machineName = machineName
        self.onServer = onServer
    }

    /// The tab id a send is addressed by (`SessionTarget`): the pty's id here,
    /// `machine <machineId> <sessionId>` on a paired machine, the server tab's own id.
    public var tabId: String {
        if onServer { return id }
        return machineId.isEmpty ? id : "machine \(machineId) \(id)"
    }
}

public enum AgentSessions {
    static func folderName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    static func labelFor(cwd: String, index: Int, name: String) -> String {
        if !name.isEmpty { return name }
        let folder = cwd.isEmpty ? "" : folderName(cwd)
        return folder.isEmpty ? "Session \(index)" : "\(folder) · Session \(index)"
    }

    /// The window's own name for a session wins; otherwise a title that has moved on from the folder.
    static func nameOf(_ id: String, cwd: String, title: String, names: [String: String]) -> String {
        if let typed = names[id], !typed.isEmpty { return typed }
        let folder = cwd.isEmpty ? "" : folderName(cwd)
        return !title.isEmpty && title != folder ? title : ""
    }

    /// The names the rail is showing for sessions, from the page's published side panel
    /// (`id`, `title`). A row the rail only numbers (`Session 2`) has no name.
    public static func railNames(_ rows: [(id: String, title: String)]) -> [String: String] {
        var names: [String: String] = [:]
        for row in rows {
            let title = row.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, title.range(of: #"^Session \d+$"#, options: .regularExpression) == nil else { continue }
            names[row.id] = title
        }
        return names
    }

    /// Every session a send can go to: this Mac's (`session:list`), then the ones on
    /// paired machines (`machines:list`), numbered per folder in list order — the rail's
    /// own numbering — with two rows that would read the same told apart.
    public static func read(_ value: Any?, names: [String: String] = [:], machines: Any? = nil,
                            servers: [(name: String, shells: [(tabId: String, title: String)])] = []) -> [AgentSessionRow] {
        distinct(here(value, names: names) + elsewhere(machines, names: names) + onServers(servers))
    }

    /// The terminals this window holds open on servers, last, by server — as the rail lists them.
    static func onServers(_ servers: [(name: String, shells: [(tabId: String, title: String)])]) -> [AgentSessionRow] {
        servers.flatMap { server in
            server.shells.filter { $0.tabId.hasPrefix("server ") }.map { shell in
                AgentSessionRow(id: shell.tabId, cwd: "", provider: "", ended: false, label: "\(server.name) · \(shell.title)",
                                machineName: server.name, onServer: true)
            }
        }
    }

    static func here(_ value: Any?, names: [String: String]) -> [AgentSessionRow] {
        guard let list = value as? [Any] else { return [] }
        var counts: [String: Int] = [:]
        var rows: [AgentSessionRow] = []
        for entry in list {
            guard let row = entry as? [String: Any], let id = row["id"] as? String, !id.isEmpty else { continue }
            let cwd = row["cwd"] as? String ?? ""
            let index = (counts[cwd] ?? 0) + 1
            counts[cwd] = index
            let name = nameOf(id, cwd: cwd, title: row["title"] as? String ?? "", names: names)
            // `exitCode` is null while the process lives and a number once it has gone.
            rows.append(AgentSessionRow(id: id, cwd: cwd, provider: row["provider"] as? String ?? "",
                                        ended: row["exitCode"] is NSNumber, label: labelFor(cwd: cwd, index: index, name: name)))
        }
        return rows
    }

    /// `PC`, `Mac`, `machine` — never guessed (`machineNoun`).
    static func machineNoun(_ platform: String) -> String {
        switch platform {
        case "darwin": "Mac"
        case "win32": "PC"
        case "linux": "machine"
        default: "desktop"
        }
    }

    /// The sessions on the machines this Mac dialled, by the name the app gives each
    /// machine (`machineChoices`). A link whose machine is not listed cannot be named, so it is left out.
    static func elsewhere(_ value: Any?, names: [String: String]) -> [AgentSessionRow] {
        guard let view = value as? [String: Any] else { return [] }
        let machines = (view["machines"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let links = (view["links"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        func linkOf(_ id: String) -> [String: Any]? { links.first { $0["id"] as? String == id } }
        var machineNames: [String: String] = [:]
        for machine in machines {
            guard let id = machine["id"] as? String, !id.isEmpty else { continue }
            let host = linkOf(id)?["hostPlatform"] as? String ?? ""
            let noun = machineNoun(host.isEmpty ? machine["platform"] as? String ?? "" : host)
            let name = machine["name"] as? String ?? ""
            machineNames[id] = name.isEmpty ? "That \(noun)" : name
        }
        var counts: [String: Int] = [:]
        var rows: [AgentSessionRow] = []
        for link in links {
            guard let machineId = link["id"] as? String, let machineName = machineNames[machineId] else { continue }
            for case let session as [String: Any] in link["sessions"] as? [Any] ?? [] {
                guard let id = session["id"] as? String, !id.isEmpty else { continue }
                let cwd = session["cwd"] as? String ?? ""
                let key = "\(machineId)\u{0}\(cwd)"
                let index = (counts[key] ?? 0) + 1
                counts[key] = index
                let name = nameOf(id, cwd: cwd, title: session["title"] as? String ?? "", names: [:])
                rows.append(AgentSessionRow(id: id, cwd: cwd, provider: session["provider"] as? String ?? "",
                                            ended: session["exitCode"] is NSNumber,
                                            label: "\(machineName) · \(labelFor(cwd: cwd, index: index, name: name))",
                                            machineId: machineId, machineName: machineName))
            }
        }
        return rows
    }

    /// Two rows that read the same get their machine, folder and number after the name.
    static func distinct(_ rows: [AgentSessionRow]) -> [AgentSessionRow] {
        var seen: [String: Int] = [:]
        for row in rows { seen[row.label, default: 0] += 1 }
        var again: [String: Int] = [:]
        return rows.map { row in
            guard (seen[row.label] ?? 0) > 1 else { return row }
            let key = "\(row.machineId)\u{0}\(row.cwd)"
            let index = (again[key] ?? 0) + 1
            again[key] = index
            var copy = row
            let place = row.machineName.isEmpty ? "" : "\(row.machineName) · "
            copy.label = "\(row.label) — \(place)\(labelFor(cwd: row.cwd, index: index, name: ""))"
            return copy
        }
    }

    /// The session a send would reach, or nil: nothing chosen, gone, or exited.
    public static func resolve(_ chosenId: String, in rows: [AgentSessionRow]) -> AgentSessionRow? {
        guard !chosenId.isEmpty, let found = rows.first(where: { $0.id == chosenId }), !found.ended else { return nil }
        return found
    }

    /// Why Send is off, in one sentence, or empty when it is on (or nothing is chosen yet).
    public static func whyDisabled(_ chosenId: String, in rows: [AgentSessionRow], available: Bool = true) -> String {
        if !available { return "This build cannot list your sessions, so there is nothing to send to." }
        if rows.isEmpty { return "No sessions are open. Start one, then choose it here." }
        if chosenId.isEmpty { return "" }
        guard let found = rows.first(where: { $0.id == chosenId }) else { return "That session is gone. Choose another one." }
        if found.ended { return "\(found.label) has exited. Choose another one." }
        return ""
    }

    /// What a paired machine answered to `machines:send`: nil when it landed, else its own words.
    public static func machineRefusal(_ answer: Any?, machineName: String) -> String? {
        guard let row = answer as? [String: Any] else { return "\(machineName) did not answer." }
        if row["ok"] as? Bool == true { return nil }
        let message = row["message"] as? String ?? ""
        return message.isEmpty ? "\(machineName) refused it." : message
    }
}
