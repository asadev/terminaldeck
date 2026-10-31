import Foundation
import TerminalDeckNativeCore

/// IOS2 (9 Oct 2026, Asad #17: "the iPhone app should be actually upgraded to this new level").
/// Three Mac pages for the owner's own phone, on the existing panel frames:
/// Agents, Connected tasks and Servers and Docker (read only).
/// Every read and change goes through the same tools and approval rules as the Mac
/// (`BackendINT2PhonePanelScope.call`). A phone without the Mac's Approvals page
/// shows Hoot's own questions as its approvals.
/// Wire contract: macos/round7/IOS2.md §2. Every field here is additive: a phone
/// that never claimed `panels.<name>` is never offered these pages.
public struct BackendIOS2PanelPort: Sendable {
    public typealias Call = @Sendable (_ tool: String, _ arguments: NativeRPCValue, _ rpc: NativeRPCContext,
                                       _ domain: String, _ tier: BackendMCPTier) async throws -> NativeRPCValue
    public let call: Call
    public let level: @Sendable (NativeRPCContext, String) async throws -> BackendINT2PhoneAccessLevel
    /// The calling device's id after the live access check (`mutation` asks for change rights).
    public let device: @Sendable (NativeRPCContext, String, Bool) async throws -> String
    public init(call: @escaping Call,
                level: @escaping @Sendable (NativeRPCContext, String) async throws -> BackendINT2PhoneAccessLevel,
                device: @escaping @Sendable (NativeRPCContext, String, Bool) async throws -> String) {
        self.call = call; self.level = level; self.device = device
    }
    public init(scope: BackendINT2PhonePanelScope) {
        call = { tool, arguments, rpc, domain, tier in try await scope.call(tool, arguments: arguments, rpc: rpc, domain: domain, tier: tier) }
        level = { rpc, domain in try await scope.level(rpc, domain: domain) }
        device = { rpc, domain, mutation in try await scope.current(rpc, domain: domain, mutation: mutation).deviceID }
    }
}

public enum BackendIOS2PhonePanels {
    typealias V = NativeRPCValue
    /// The phone's inbound frame ceiling is ~93 KB; stay well under it.
    static let byteBudget = 48_000
    static let readOnlyNote = "Read only on the phone. Changes are made on the Mac."

    // MARK: - Wire helpers

    static func object(_ fields: [(String, V?)]) -> V {
        .object(fields.compactMap { key, value in value.map { .init(key, $0) } })
    }
    static func text(_ value: String?) -> V? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .string(value)
    }
    static func facts(_ pairs: [(String, String?)]) -> V? {
        let rows = pairs.compactMap { label, value -> V? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return object([("label", .string(label)), ("value", .string(String(value.prefix(400))))])
        }
        return rows.isEmpty ? nil : .array(rows)
    }
    static func field(_ id: String, _ label: String, value: String = "", required: Bool = false,
                      choices: [(id: String, label: String)] = [], placeholder: String? = nil) -> V {
        var row = object([("id", .string(id)), ("label", .string(label)), ("value", .string(value)), ("required", .bool(required)),
                          ("placeholder", text(placeholder))])
        if !choices.isEmpty {
            row = row.setting("choices", .array(choices.map { .string($0.id) }))
                .setting("choiceLabels", .object(choices.map { .init($0.id, .string($0.label)) }))
        }
        return row
    }
    static func action(_ id: String, _ label: String, fields: [V] = [], confirm: String? = nil, destructive: Bool = false) -> V {
        var row = object([("id", .string(id)), ("label", .string(label)), ("fields", .array(fields))])
        if let confirm { row = row.setting("confirm", .string(confirm)) }
        if destructive { row = row.setting("destructive", .bool(true)).setting("kind", .string("destructive")) }
        return row
    }
    static func scopes(_ rows: [(id: String, label: String)], current: String) -> V {
        .array(rows.map { object([("id", .string($0.id)), ("label", .string($0.label)), ("on", .bool($0.id == current))]) })
    }
    /// One panel answer: echoes `view`, trims to the phone's frame budget (the
    /// first row, the page's subject, is always kept).
    static func payload(_ request: BackendRemotePanelRequest, rows: [V], actions: [V] = [], extra: [(String, V?)] = []) -> V {
        let view = request.scope.flatMap { $0.isEmpty ? nil : $0 }
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var visible = query.isEmpty ? rows : rows.filter {
            ($0["title"].string ?? "").localizedCaseInsensitiveContains(query) || ($0["detail"].string ?? "").localizedCaseInsensitiveContains(query)
        }
        visible = Array(visible.prefix(200))
        func build(_ list: [V], shortened: Bool) -> V {
            var value = object([("path", .string(request.path)), ("rows", .array(list)), ("actions", .array(actions)), ("view", view.map(V.string))] + extra)
            if shortened {
                let note = "Shortened to fit the phone. The full page is on the Mac."
                value = value.setting("note", .string((value["note"].string.map { $0 + " " } ?? "") + note))
            }
            return value
        }
        var result = build(visible, shortened: false)
        while visible.count > 1, ((try? result.encodedJSON().count) ?? 0) > byteBudget {
            visible.removeLast(max(1, visible.count / 10))
            result = build(visible, shortened: true)
        }
        return result
    }
    static func requireFields(_ request: BackendRemotePanelActionRequest, allowed: Set<String>) throws {
        guard Set(request.fields.keys).isSubset(of: allowed) else { throw NativeRPCError.invalidArguments("This action received a field it does not offer.") }
    }
    static func clip(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        return value.count > limit ? String(value.prefix(limit)) + "…" : value
    }
    /// "in 11 h", "in 25 min", "12 min ago".
    static func span(from now: Double, to then: Double) -> String {
        let seconds = Int(abs(then - now) / 1000), future = then >= now
        let words: String
        if seconds < 60 { words = "less than a minute" }
        else if seconds < 3_600 { words = "\(seconds / 60) min" }
        else if seconds < 86_400 { words = "\(seconds / 3_600) h" + (seconds % 3_600 >= 1_800 && seconds < 36_000 ? " 30 min" : "") }
        else { words = "\(seconds / 86_400) d" }
        return future ? "in " + words : words + " ago"
    }
    static func day(_ milliseconds: Double?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "d MMM yyyy, HH:mm"; formatter.locale = Locale(identifier: "en_GB")
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds > 10_000_000_000 ? milliseconds / 1000 : milliseconds))
    }
    static func json(_ value: V) -> String? {
        guard !value.isNullish, let data = try? value.encodedJSON(pretty: true) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text == "{}" || text == "[]" ? nil : clip(text, 6_000)
    }
    static func open(_ scope: String) -> V? { scope.utf8.count <= 128 ? .string(scope) : nil }

    // MARK: - Agents

    static func providerLabel(_ provider: String) -> String {
        switch provider { case "claude", "": "Claude Code"; case "codex": "Codex"; case "gemini": "Gemini"; default: provider.capitalized }
    }
    static func kindLabel(_ agent: V) -> String {
        switch agent["kind"].string {
        case "hoot": return "Built-in assistant"
        case "session": return "Live session"
        default: return agent["sourceFile"].string?.isEmpty == false ? "Claude Code agent" : "Task agent"
        }
    }
    static func liveTint(_ agent: V) -> V? {
        switch agent["live"].string { case "working": .string("ok"); case "waiting": .string("warn"); default: nil }
    }
    static func managerName(_ agent: V, names: [String: String]) -> String {
        guard let boss = agent["reportsTo"].string, !boss.isEmpty else { return "Independent" }
        if boss == "@hoot" { return "Hoot" }
        return names[boss] ?? boss
    }
    static func doing(_ agent: V) -> String? {
        let activity = agent["activity"].string ?? ""
        guard let task = agent["taskTitle"].string, !task.isEmpty else { return text(activity)?.string }
        return activity.isEmpty ? task : activity + " · " + task
    }
    /// The agent's picture as its avatar draws it: the icon with its chosen colour (`sf:star@pink`), so the phone
    /// colours the glyph as the Mac does (no colour: the stable one from its id, the same on both).
    static func pictureIcon(_ agent: V) -> V? {
        guard let icon = text(agent["icon"].string)?.string else { return nil }
        guard !icon.contains("@"), let colour = agent["iconColour"].string, AGTIcon.colourNames.contains(colour) else { return .string(icon) }
        return .string(icon + "@" + colour)
    }
    static func agentRow(_ agent: V, group: String?, names: [String: String], level: Int? = nil) -> V? {
        guard let id = agent["id"].string, let name = agent["name"].string else { return nil }
        let role = agent["role"].string ?? ""
        let model = [providerLabel(agent["provider"].string ?? ""), agent["model"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return object([("id", .string(id)), ("title", .string(name)),
                       ("detail", text(role.isEmpty ? doing(agent) : role)),
                       ("value", text(agent["statusLabel"].string ?? agent["status"].string)), ("status", liveTint(agent)),
                       ("icon", pictureIcon(agent)), ("group", group.map(V.string)), ("badge", .string(kindLabel(agent))),
                       ("facts", facts([("Project", agent["projectName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "Every project"),
                                        ("Coding AI", agent["kind"].string == "hoot" ? nil : model),
                                        ("Reports to", agent["kind"].string == "hoot" ? nil : managerName(agent, names: names)),
                                        ("Doing now", doing(agent))])),
                       ("open", open("agent:" + id)), ("level", level.map { .number(Double($0)) })])
    }
    /// A short monoline + emoji set for the phone's picker; the Mac's full 307 stay on the Mac.
    static let iconChoices: [(id: String, label: String)] = [
        ("", "Default for its role"), ("sf:person", "Person"), ("sf:person.2", "Team"), ("sf:brain", "Thinker"),
        ("sf:hammer", "Builder"), ("sf:wrench.and.screwdriver", "Fixer"), ("sf:paintbrush", "Designer"), ("sf:paintpalette", "Palette"),
        ("sf:checkmark.seal", "Inspector"), ("sf:magnifyingglass", "Researcher"), ("sf:doc.text", "Writer"), ("sf:terminal", "Terminal"),
        ("sf:iphone", "Phone"), ("sf:desktopcomputer", "Desktop"), ("sf:server.rack", "Server"), ("sf:shield", "Security"),
        ("sf:chart.bar", "Analyst"), ("sf:megaphone", "Marketing"), ("sf:bubble.left.and.bubble.right", "Support"), ("sf:graduationcap", "Teacher"),
        ("sf:bolt", "Fast"), ("sf:leaf", "Leaf"), ("sf:star", "Star"), ("sf:flag", "Flag"),
        ("emoji:🤖", "🤖 Robot"), ("emoji:🦉", "🦉 Owl"), ("emoji:🧠", "🧠 Brain"), ("emoji:🛠️", "🛠️ Tools"), ("emoji:🎨", "🎨 Art"),
        ("emoji:🔍", "🔍 Search"), ("emoji:📱", "📱 Phone"), ("emoji:🚀", "🚀 Rocket"), ("emoji:🧪", "🧪 Test"), ("emoji:📝", "📝 Notes"),
        ("emoji:🛡️", "🛡️ Shield"), ("emoji:⚡️", "⚡️ Bolt"), ("emoji:🐞", "🐞 Bug"), ("emoji:📊", "📊 Chart"), ("emoji:🦊", "🦊 Fox"),
    ]

    public static func agents(port: BackendIOS2PanelPort) -> BackendRemotePanelProvider {
        let domain = "agents"
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let scope = request.scope ?? ""
            if scope.hasPrefix("agent:") {
                let id = String(scope.dropFirst("agent:".count))
                let value = try await port.call("agents.profile", object([("id", .string(id))]), rpc, domain, .read)
                let full = try await port.level(rpc, domain) == .full
                let directory = (try? await port.call("agents.directory", .object([]), rpc, domain, .read))?["agents"].elements ?? []
                var names: [String: String] = [:]
                for agent in directory { if let id = agent["id"].string, let name = agent["name"].string { names[id] = name } }
                let settings = value["settings"]
                let name = value["name"].string ?? id
                let model = [providerLabel(value["provider"].string ?? ""), value["model"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let tools = { (key: String) -> String? in
                    let list = (settings[key].elements ?? []).compactMap(\.string); return list.isEmpty ? nil : list.joined(separator: ", ")
                }
                var actions: [V] = []
                let isTaskAgent = value["kind"].string == "profile"
                if full, isTaskAgent, let agentID = value["id"].string {
                    let provider = value["provider"].string ?? "claude"
                    let efforts = [("", "Its default")] + AGSCapabilities.efforts(provider: provider).map { ($0, $0.capitalized) }
                    actions.append(action("edit", "Edit", fields: [
                        field("name", "Name", value: name, required: true),
                        field("role", "Role", value: value["role"].string ?? ""),
                        field("model", "Model", value: value["model"].string ?? "", placeholder: "Its default"),
                        field("effort", "Effort", value: settings["effort"].string ?? "", choices: efforts.map { (id: $0.0, label: $0.1) })]))
                    let managers: [(id: String, label: String)] = [("", "Independent"), ("@hoot", "Hoot")] + directory.compactMap { agent in
                        guard agent["kind"].string == "profile", let other = agent["id"].string, other != agentID,
                              let label = agent["name"].string else { return nil }
                        return (other, label)
                    }
                    actions.append(action("reports", "Reports to", fields: [field("reportsTo", "Reports to", value: value["reportsTo"].string ?? "", choices: managers)]))
                    var icons = iconChoices
                    if let current = value["icon"].string, !icons.contains(where: { $0.id == current }) { icons.insert((current, "Current icon"), at: 1) }
                    actions.append(action("icon", "Icon", fields: [field("icon", "Icon", value: value["icon"].string ?? "", choices: icons)]))
                }
                var header = object([("id", .string(value["id"].string ?? id)), ("title", .string(name)), ("detail", text(value["role"].string)),
                    ("value", text(value["statusLabel"].string)), ("status", liveTint(value)), ("icon", pictureIcon(value)),
                    ("badge", .string(kindLabel(value))),
                    ("facts", facts([("Project", value["projectName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "Every project"),
                                     ("Coding AI", value["kind"].string == "hoot" ? nil : model),
                                     ("Effort", settings["effort"].string), ("Permission mode", settings["permissionMode"].string),
                                     ("Reports to", value["kind"].string == "hoot" ? nil : value["reportsToName"].string ?? managerName(value, names: names)),
                                     ("Doing now", doing(value)), ("Machine", value["machine"].string),
                                     ("Claude Code agent", value["claudeAgent"].string.map { "--agent " + $0 }),
                                     ("File", value["sourceFile"].string), ("File sync", value["syncStatus"].string),
                                     ("Allowed tools", tools("allowedTools")), ("Blocked tools", tools("blockedTools")),
                                     ("Last active", day(value["lastActivity"].number))])),
                    ("actions", .array(actions))])
                if let boss = value["reportsTo"].string, !boss.isEmpty, boss != "@hoot" { header = header.setting("parent", .string(boss)) }
                var rows = [header]
                for report in value["reports"].elements ?? [] {
                    guard let rid = report["id"].string, let rname = report["name"].string else { continue }
                    rows.append(object([("id", .string(rid)), ("title", .string(rname)), ("group", .string("Direct reports")), ("open", open("agent:" + rid))]))
                }
                if let now = doing(value), value["live"].string != nil {
                    rows.append(object([("id", .string("now")), ("title", .string(now)), ("group", .string("Now")),
                                        ("value", text(value["statusLabel"].string)), ("status", liveTint(value)), ("sessionId", text(value["sessionId"].string))]))
                }
                for task in value["recentTasks"].elements ?? [] {
                    guard let tid = task["id"].string, let title = task["title"].string else { continue }
                    rows.append(object([("id", .string("task:" + tid)), ("title", .string(title)), ("group", .string("Recent tasks")),
                                        ("value", text(task["state"].string)), ("detail", text(day(task["updatedAt"].number)))]))
                }
                let notes = (value["notices"].elements ?? []).compactMap(\.string)
                return payload(request, rows: rows, extra: [("title", .string(name)), ("note", notes.isEmpty ? nil : .string(notes.joined(separator: " ")))])
            }
            if scope == "org" {
                let chart = try await port.call("agents.org_chart", .object([]), rpc, domain, .read)
                var rows: [V] = []
                func walk(_ node: V, depth: Int, group: String) {
                    guard let id = node["id"].string, let name = node["name"].string, rows.count < 200 else { return }
                    rows.append(object([("id", .string(id)), ("title", .string(name)), ("detail", text(node["role"].string)),
                                        ("value", text(node["status"].string)), ("icon", text(node["icon"].string)), ("group", .string(group)),
                                        ("level", .number(Double(depth))), ("open", open("agent:" + id))]))
                    for child in node["reports"].elements ?? [] { walk(child, depth: depth + 1, group: group) }
                }
                for tree in chart["trees"].elements ?? [] {
                    walk(tree, depth: 0, group: tree["id"].string == "@hoot" ? "Hoot's team" : "Team of " + (tree["name"].string ?? "an agent"))
                }
                for agent in chart["independent"].elements ?? [] {
                    guard let id = agent["id"].string, let name = agent["name"].string else { continue }
                    rows.append(object([("id", .string(id)), ("title", .string(name)), ("icon", text(agent["icon"].string)),
                                        ("group", .string("Independent")), ("level", .number(0)), ("open", open("agent:" + id))]))
                }
                return payload(request, rows: rows, extra: [("title", .string("Org chart"))])
            }
            let byManager = scope == "group:reportsTo"
            let value = try await port.call("agents.directory", object([("group", .string(byManager ? "reportsTo" : "project"))]), rpc, domain, .read)
            let agents = value["agents"].elements ?? []
            var byID: [String: V] = [:], names: [String: String] = [:]
            for agent in agents { if let id = agent["id"].string { byID[id] = agent; names[id] = agent["name"].string } }
            var rows: [V] = [], seen: Set<String> = []
            for group in value["groups"].elements ?? [] {
                for id in (group["agents"].elements ?? []).compactMap(\.string) where !seen.contains(id) {
                    guard let agent = byID[id], let row = agentRow(agent, group: group["title"].string, names: names) else { continue }
                    rows.append(row); seen.insert(id)
                }
            }
            for agent in agents where !seen.contains(agent["id"].string ?? "") {
                if let row = agentRow(agent, group: "Other", names: names) { rows.append(row) }
            }
            let notes = (value["notices"].elements ?? []).compactMap(\.string)
            return payload(request, rows: rows, extra: [("title", .string("Agents")), ("note", notes.isEmpty ? nil : .string(notes.joined(separator: " ")))])
        }
        return .init(scope: .machine, read: read, act: { request, rpc in
            let scope = request.panel.scope ?? ""
            guard scope.hasPrefix("agent:"), let id = request.id, id == String(scope.dropFirst("agent:".count)) else {
                throw NativeRPCError.invalidArguments("Open the agent's page first.")
            }
            let tool: String, args: V
            switch request.action {
            case "edit":
                try requireFields(request, allowed: ["name", "role", "model", "effort"])
                var changes: [(String, V?)] = []
                if let name = request.fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    guard !name.isEmpty else { throw NativeRPCError.invalidArguments("Give the agent a name.") }
                    changes.append(("name", .string(name)))
                }
                if let role = request.fields["role"] { changes.append(("role", .string(role.trimmingCharacters(in: .whitespacesAndNewlines)))) }
                for key in ["model", "effort"] {
                    if let value = request.fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines) { changes.append((key, value.isEmpty ? .null : .string(value))) }
                }
                tool = "agents.edit_profile"; args = object([("id", .string(id)), ("fields", object(changes))])
            case "reports":
                try requireFields(request, allowed: ["reportsTo"])
                let boss = request.fields["reportsTo"] ?? ""
                tool = "agents.set_reports_to"; args = object([("id", .string(id)), ("reportsTo", boss.isEmpty ? .null : .string(boss))])
            case "icon":
                try requireFields(request, allowed: ["icon"])
                let icon = request.fields["icon"] ?? ""
                tool = "agents.set_icon"; args = object([("id", .string(id)), ("icon", icon.isEmpty ? .null : .string(icon))])
            default: throw NativeRPCError.invalidArguments("This agent action is unavailable.")
            }
            _ = try await port.call(tool, args, rpc, domain, .alter)
            return try await read(request.panel, rpc).setting("notice", .string("Saved."))
        })
    }

    // MARK: - Connected tasks

    static let piles: [(id: String, label: String)] = [("all", "All"), ("assigned_to_me", "Assigned to me"),
                                                      ("raised_by_me", "Raised by me"), ("with_others", "With others")]
    static func personName(_ value: V) -> String? { value["name"].string ?? value.string }
    static func today() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    public static func connectedTasks(port: BackendIOS2PanelPort) -> BackendRemotePanelProvider {
        let domain = "connected-tasks"
        @Sendable func systems(_ rpc: NativeRPCContext) async throws -> [V] {
            try await port.call("connected_tasks.systems", .object([]), rpc, domain, .read)["systems"].elements ?? []
        }
        @Sendable func task(_ scope: String, _ systems: [V]) throws -> (system: V, task: String) {
            let rest = scope.dropFirst("task:".count)
            guard let bar = rest.firstIndex(of: "|"),
                  let systemID = String(rest[..<bar]).removingPercentEncoding,
                  let system = systems.first(where: { $0["id"].string == systemID }) else {
                throw NativeRPCError.invalidArguments("That task's system is no longer connected.")
            }
            return (system, String(rest[rest.index(after: bar)...]))
        }
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let scope = request.scope ?? ""
            let connected = try await systems(rpc)
            guard !connected.isEmpty else {
                return payload(request, rows: [], extra: [("title", .string("Connected tasks")),
                    ("note", .string("No task system is connected. Connect one on the Mac: Settings → Tasks → Connect a task system."))])
            }
            let full = try await port.level(rpc, domain) == .full
            if scope.hasPrefix("task:") {
                let (system, taskID) = try task(scope, connected)
                let systemID = system["id"].string ?? "", systemName = system["name"].string ?? "the system"
                let detail = try await port.call("connected_tasks.get", object([("system", .string(systemID)), ("task", .string(taskID))]), rpc, domain, .read)
                let changes = system["changes"].string ?? "ask", enabled = system["enabled"].bool != false
                let people = (detail["people"].elements ?? []).compactMap { person -> (id: String, label: String)? in
                    guard let id = person["id"].string, let name = person["name"].string else { return nil }; return (id, name)
                }
                var actions: [V] = []
                if full, enabled, changes != "off" {
                    let statuses = (system["statuses"].elements ?? []).compactMap(\.string)
                    actions.append(action("status", "Status", fields: [field("status", "Status", value: detail["status"].string ?? "", required: true,
                                                                             choices: statuses.map { ($0, $0) })]))
                    actions.append(action("due", "Due date", fields: [field("due_date", "Due date", value: detail["dueDate"].string ?? "",
                                                                          placeholder: "YYYY-MM-DD, or empty for none")]))
                    if !people.isEmpty {
                        actions.append(action("assignee", "Assignee", fields: [field("assignee", "Assignee", value: detail["assignee"]["id"].string ?? "",
                                                                                   required: true, choices: people)]))
                    }
                    actions.append(action("comment", "Comment", fields: [field("body", "Comment", required: true, placeholder: "Written as you, in \(systemName)")]))
                    let agents = ((try? await port.call("agents.directory", .object([]), rpc, domain, .read))?["agents"].elements ?? [])
                        .compactMap { agent -> (id: String, label: String)? in
                            guard agent["kind"].string == "profile", !["paused", "archived"].contains(agent["status"].string ?? ""),
                                  let id = agent["profileId"].string ?? agent["id"].string, let name = agent["name"].string else { return nil }
                            return (id, name)
                        }
                    if !agents.isEmpty {
                        actions.append(action("hand", "Hand to an agent", fields: [field("agent", "Agent", required: true, choices: agents),
                            field("mark_done", "When it finishes", value: "no", choices: [("no", "Post its answer"), ("yes", "Post its answer and mark done")])]))
                    }
                }
                let labels = (detail["labels"].elements ?? []).compactMap(\.string).joined(separator: ", ")
                let header = object([("id", .string(taskID)), ("title", .string(detail["title"].string ?? "Task")),
                    ("detail", text(detail["board"].string)), ("value", text(detail["status"].string)),
                    ("badge", text(detail["assignedToMe"].bool == true ? "Assigned to you" : detail["raisedByMe"].bool == true ? "Raised by you" : nil)),
                    ("facts", facts([("Status", detail["status"].string), ("Due", detail["dueDate"].string), ("Starts", detail["startDate"].string),
                                     ("Assignee", personName(detail["assignee"])), ("Priority", detail["priority"].string ?? detail["priority"].number.map { String(Int($0)) }),
                                     ("Board", detail["board"].string), ("Labels", labels), ("Type", detail["taskType"].string),
                                     ("Raised by", personName(detail["createdBy"])), ("Link", detail["url"].string)])),
                    ("body", text(clip(detail["description"].string, 6_000))), ("actions", .array(actions))])
                var rows = [header]
                for (n, sub) in (detail["subtasks"].elements ?? []).prefix(60).enumerated() {
                    guard let title = sub["title"].string else { continue }
                    rows.append(object([("id", .string("sub:\(n)")), ("title", .string(title)), ("group", .string("Subtasks")),
                        ("value", .string(sub["done"].bool == true ? "Done" : "Open")), ("status", sub["done"].bool == true ? .string("ok") : nil),
                        ("detail", text([personName(sub["assignee"]), sub["dueDate"].string.map { "Due " + $0 }].compactMap { $0 }.joined(separator: " · ")))]))
                }
                for (c, list) in (detail["checklists"].elements ?? []).prefix(10).enumerated() {
                    let group = "Checklist: " + (list["title"].string ?? "Items")
                    for (n, item) in (list["items"].elements ?? []).prefix(40).enumerated() {
                        guard let title = item["title"].string else { continue }
                        rows.append(object([("id", .string("check:\(c):\(n)")), ("title", .string(title)), ("group", .string(group)),
                            ("value", .string(item["done"].bool == true ? "Done" : "Open")), ("status", item["done"].bool == true ? .string("ok") : nil)]))
                    }
                }
                for (n, comment) in (detail["comments"].elements ?? []).suffix(30).enumerated() {
                    rows.append(object([("id", .string("comment:\(n)")), ("title", .string(comment["by"].string ?? "Someone")), ("group", .string("Comments")),
                        ("detail", text(comment["at"].string)), ("body", text(clip(comment["body"].string, 2_000)))]))
                }
                for (n, entry) in (detail["activity"].elements ?? []).suffix(20).enumerated() {
                    guard let line = entry["text"].string else { continue }
                    rows.append(object([("id", .string("activity:\(n)")), ("title", .string(line)), ("group", .string("Activity")),
                        ("detail", text([entry["by"].string, entry["at"].string].compactMap { $0 }.joined(separator: " · ")))]))
                }
                if detail["handoff"].fields != nil {
                    let handoff = detail["handoff"]
                    let state = handoff["problem"].string ?? (handoff["postedAt"].isNullish ? "Working on it" : "Answer posted")
                    rows.append(object([("id", .string("handoff")), ("title", .string(handoff["agentName"].string ?? "A task agent")),
                        ("group", .string("With an agent")), ("value", .string(state)), ("status", handoff["problem"].string == nil ? .string("ok") : .string("bad"))]))
                }
                let note: String? = !enabled ? "This connection is switched off on the Mac." :
                    changes == "off" ? "\(systemName) is connected read only. Changes are switched off on the Mac." :
                    !full ? "Changing tasks needs this phone to have full access." : nil
                return payload(request, rows: rows, extra: [("title", .string(detail["title"].string ?? "Task")), ("note", note.map(V.string))])
            }
            let pile = scope.hasPrefix("pile:") ? String(scope.dropFirst("pile:".count)) : "all"
            guard piles.contains(where: { $0.id == pile }) else { throw NativeRPCError.invalidArguments("Choose one of the offered task piles.") }
            var rows: [V] = [], notes: [String] = []
            let today = today()
            for system in connected {
                guard let systemID = system["id"].string else { continue }
                let encodedSystem = systemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "|/%"))) ?? ""
                let name = system["name"].string ?? "Connected tasks"
                if let problem = system["problem"].string, !problem.isEmpty { notes.append(name + ": " + problem) }
                var args = object([("system", .string(systemID)), ("pile", .string(pile)), ("limit", .number(200))])
                var list = try await port.call("connected_tasks.list", args, rpc, domain, .read)
                if list["readAt"].isNullish {
                    args = args.setting("refresh", .bool(true))
                    list = try await port.call("connected_tasks.list", args, rpc, domain, .read)
                }
                let done = system["doneStatus"].string
                for row in list["tasks"].elements ?? [] {
                    guard let id = row["id"].string, let title = row["title"].string else { continue }
                    let due = row["dueDate"].string
                    let overdue = due.map { $0 < today } == true && row["status"].string != done
                    rows.append(object([("id", .string("\(encodedSystem)|" + id)), ("title", .string(title)),
                        ("detail", text([row["board"].string, due.map { "Due " + $0 }, personName(row["assignee"])].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))),
                        ("value", text(row["status"].string)), ("status", overdue ? .string("warn") : nil),
                        ("badge", text(row["assignedToMe"].bool == true ? "Assigned to you" : row["raisedByMe"].bool == true ? "Raised by you" : nil)),
                        ("group", connected.count > 1 ? .string(name) : nil), ("open", open("task:\(encodedSystem)|" + id))]))
                }
            }
            let title = connected.count == 1 ? connected[0]["name"].string ?? "Connected tasks" : "Connected tasks"
            if rows.isEmpty { notes.append("No tasks in this pile.") }
            return payload(request, rows: rows, actions: [action("refresh", "Read again")],
                           extra: [("title", .string(title)), ("scopes", scopes(piles.map { (id: "pile:" + $0.id, label: $0.label) }, current: "pile:" + pile)),
                                   ("note", notes.isEmpty ? nil : .string(notes.joined(separator: " ")))])
        }
        return .init(scope: .machine, read: read, act: { request, rpc in
            let scope = request.panel.scope ?? ""
            if request.action == "refresh" {
                try requireFields(request, allowed: [])
                for system in try await systems(rpc) {
                    guard let id = system["id"].string else { continue }
                    _ = try await port.call("connected_tasks.list", object([("system", .string(id)), ("refresh", .bool(true)), ("limit", .number(1))]), rpc, domain, .read)
                }
                return try await read(request.panel, rpc).setting("notice", .string("Read again."))
            }
            guard scope.hasPrefix("task:") else { throw NativeRPCError.invalidArguments("Open the task first.") }
            let (system, taskID) = try task(scope, try await systems(rpc))
            guard request.id == taskID else { throw NativeRPCError.invalidArguments("Open the task first.") }
            var args = object([("system", system["id"]), ("task", .string(taskID))])
            let tool: String
            switch request.action {
            case "status": try requireFields(request, allowed: ["status"]); tool = "connected_tasks.update"; args = args.setting("status", .string(request.fields["status"] ?? ""))
            case "due":
                try requireFields(request, allowed: ["due_date"])
                let due = (request.fields["due_date"] ?? "").trimmingCharacters(in: .whitespaces)
                guard due.isEmpty || due.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
                    throw NativeRPCError.invalidArguments("Write the date as YYYY-MM-DD, or leave it empty for none.")
                }
                tool = "connected_tasks.update"; args = args.setting("due_date", .string(due))
            case "assignee": try requireFields(request, allowed: ["assignee"]); tool = "connected_tasks.update"; args = args.setting("assignee", .string(request.fields["assignee"] ?? ""))
            case "comment":
                try requireFields(request, allowed: ["body"])
                let body = (request.fields["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { throw NativeRPCError.invalidArguments("Write the comment first.") }
                tool = "connected_tasks.comment"; args = args.setting("body", .string(body))
            case "hand":
                try requireFields(request, allowed: ["agent", "mark_done"])
                tool = "connected_tasks.hand_to_agent"
                args = args.setting("agent", .string(request.fields["agent"] ?? "")).setting("mark_done", .bool(request.fields["mark_done"] == "yes"))
            default: throw NativeRPCError.invalidArguments("This task action is unavailable.")
            }
            let answer = try await port.call(tool, args, rpc, domain, .alter)
            let notice = answer["message"].string ?? answer["note"].string ?? "Sent to \(system["name"].string ?? "the system")."
            return try await read(request.panel, rpc).setting("notice", .string(notice))
        })
    }

    // MARK: - Servers and Docker (read only)

    static let dockerTabs: [(id: String, label: String)] = [("containers", "Containers"), ("images", "Images"), ("volumes", "Volumes"),
                                                           ("networks", "Networks"), ("compose", "Compose")]
    static func megabytes(_ bytes: Double?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return bytes >= 1_000_000_000 ? String(format: "%.1f GB", bytes / 1_000_000_000) : String(format: "%.0f MB", bytes / 1_000_000)
    }
    static func ports(_ value: V) -> String? {
        let list = (value.elements ?? []).compactMap { port -> String? in
            guard let inside = port["privatePort"].number else { return nil }
            let type = port["type"].string ?? "tcp"
            if let outside = port["publicPort"].number { return "\(Int(outside)) → \(Int(inside))/\(type)" }
            return "\(Int(inside))/\(type)"
        }
        return list.isEmpty ? nil : Array(Set(list)).sorted().joined(separator: ", ")
    }
    static func stateTint(_ state: String?) -> V? {
        switch state { case "running": .string("ok"); case "restarting", "paused", "created": .string("warn"); case "dead": .string("bad"); default: nil }
    }

    public static func docker(port: BackendIOS2PanelPort) -> BackendRemotePanelProvider {
        let domain = "docker"
        @Sendable func servers(_ rpc: NativeRPCContext) async throws -> [V] {
            try await port.call("servers.look", .object([]), rpc, domain, .read)["servers"].elements ?? []
        }
        @Sendable func name(of target: String, in list: [V]) throws -> (name: String, lookOnly: Bool) {
            if target == "local" { return ("This Mac", false) }
            guard let row = list.first(where: { $0["id"].string == target }) else { throw NativeRPCError.invalidArguments("That server is no longer saved on the Mac.") }
            return (row["name"].string ?? target, row["lookOnly"].bool == true)
        }
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let scope = request.scope ?? ""
            let saved = try await servers(rpc)
            if scope.hasPrefix("container:") {
                let rest = scope.dropFirst("container:".count)
                guard let bar = rest.firstIndex(of: "|") else { throw NativeRPCError.invalidArguments("Open the container from its server.") }
                let target = String(rest[..<bar]), id = String(rest[rest.index(after: bar)...])
                let server = try name(of: target, in: saved)
                let value = try await port.call("docker.containers.inspect", object([("target", .string(target)), ("id", .string(id))]), rpc, domain, .read)
                let mounts = (value["mounts"].elements ?? []).compactMap { $0["destination"].string }.joined(separator: ", ")
                let env = (value["environment"].elements ?? []).compactMap { $0["name"].string }
                let containerName = value["name"].string ?? id
                var rows = [object([("id", .string(value["id"].string ?? id)), ("title", .string(containerName)), ("detail", text(value["image"].string)),
                    ("value", text(value["state"].string)), ("status", stateTint(value["state"].string)), ("badge", server.lookOnly ? .string("Look only") : nil),
                    ("facts", facts([("Server", server.name), ("State", value["state"].string), ("Status", value["status"].string), ("Image", value["image"].string),
                                     ("Created", day(value["created"].number)), ("Ports", ports(value["ports"])), ("Folders", mounts),
                                     ("Settings", env.isEmpty ? nil : "\(env.count) (values hidden)")]))])]
                do {
                    let logs = try await port.call("docker.logs", object([("target", .string(target)), ("id", .string(id)), ("tail", .number(60)),
                                                                          ("limit", .number(60)), ("waitMilliseconds", .number(1500))]), rpc, domain, .read)
                    let lines = (logs["records"].elements ?? []).compactMap { record -> String? in
                        record["text"].string ?? record["record"]["text"].string ?? record["data"]["text"].string
                    }.joined().split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n")
                    rows.append(object([("id", .string("logs")), ("title", .string("Recent logs")), ("group", .string("Recent logs")),
                                        ("body", .string(lines.isEmpty ? "No recent log lines." : clip(lines, 12_000) ?? "")), ("bodyStyle", .string("code"))]))
                } catch {
                    rows.append(object([("id", .string("logs")), ("title", .string("Logs could not be read from here")), ("group", .string("Recent logs")),
                                        ("detail", .string("Open the container's logs on the Mac."))]))
                }
                return payload(request, rows: rows, extra: [("title", .string(containerName)), ("note", .string(readOnlyNote))])
            }
            if scope.hasPrefix("server:") {
                let parts = scope.dropFirst("server:".count).split(separator: ":", maxSplits: 1).map(String.init)
                guard let target = parts.first, !target.isEmpty else { throw NativeRPCError.invalidArguments("Choose a server.") }
                let tab = parts.count > 1 ? parts[1] : "containers"
                guard dockerTabs.contains(where: { $0.id == tab }) else { throw NativeRPCError.invalidArguments("Choose one of the offered Docker lists.") }
                let server = try name(of: target, in: saved)
                let args = object([("target", .string(target))])
                var rows: [V] = []
                var heading = server.name
                if let status = try? await port.call("docker.status", args, rpc, domain, .read), let version = status["version"].string ?? status["serverVersion"].string {
                    heading += " · Docker " + version
                }
                switch tab {
                case "images":
                    for image in try await port.call("docker.images.list", args, rpc, domain, .read)["images"].elements ?? [] {
                        guard let id = image["id"].string else { continue }
                        let tags = (image["tags"].elements ?? []).compactMap(\.string)
                        rows.append(object([("id", .string(id)), ("title", .string(tags.first ?? String(id.prefix(19)))),
                            ("detail", text(tags.dropFirst().joined(separator: ", "))), ("value", text(megabytes(image["size"].number))),
                            ("facts", facts([("Created", day(image["created"].number))]))]))
                    }
                case "volumes":
                    for volume in try await port.call("docker.volumes.list", args, rpc, domain, .read)["volumes"].elements ?? [] {
                        guard let name = volume["name"].string else { continue }
                        rows.append(object([("id", .string(name)), ("title", .string(name)), ("detail", text(volume["driver"].string)), ("value", text(volume["scope"].string))]))
                    }
                case "networks":
                    for network in try await port.call("docker.networks.list", args, rpc, domain, .read)["networks"].elements ?? [] {
                        guard let id = network["id"].string, let name = network["name"].string else { continue }
                        rows.append(object([("id", .string(id)), ("title", .string(name)), ("detail", text(network["driver"].string)),
                            ("value", .string(network["internal"].bool == true ? "Internal" : network["scope"].string ?? ""))]))
                    }
                case "compose":
                    for project in try await port.call("docker.compose.list", args, rpc, domain, .read)["projects"].elements ?? [] {
                        guard let name = project["name"].string else { continue }
                        let running = Int(project["running"].number ?? 0), total = Int(project["total"].number ?? 0)
                        rows.append(object([("id", .string(name)), ("title", .string(name)),
                            ("detail", text((project["services"].elements ?? []).compactMap(\.string).joined(separator: ", "))),
                            ("value", .string("\(running) of \(total) running")), ("status", running == total && total > 0 ? .string("ok") : .string("warn"))]))
                    }
                default:
                    let list = try await port.call("docker.containers.list", args.setting("all", .bool(true)), rpc, domain, .read)["containers"].elements ?? []
                    let sorted = list.sorted { a, b in
                        let pa = a["labels"]["com.docker.compose.project"].string ?? "~", pb = b["labels"]["com.docker.compose.project"].string ?? "~"
                        return pa == pb ? (a["name"].string ?? "") < (b["name"].string ?? "") : pa < pb
                    }
                    for container in sorted {
                        guard let id = container["id"].string, let name = container["name"].string else { continue }
                        rows.append(object([("id", .string(id)), ("title", .string(name)), ("detail", text(container["image"].string)),
                            ("value", text(container["status"].string)), ("status", stateTint(container["state"].string)),
                            ("group", .string(container["labels"]["com.docker.compose.project"].string ?? "Other containers")),
                            ("facts", facts([("Ports", ports(container["ports"]))])),
                            ("open", open("container:" + target + "|" + String(id.prefix(64))))]))
                    }
                }
                let empty = rows.isEmpty ? " Nothing here." : ""
                return payload(request, rows: rows, extra: [("title", .string(heading)),
                    ("scopes", scopes(dockerTabs.map { (id: "server:" + target + ($0.id == "containers" ? "" : ":" + $0.id), label: $0.label) },
                                      current: "server:" + target + (tab == "containers" ? "" : ":" + tab))),
                    ("note", .string((server.lookOnly ? "Look only server. " : "") + readOnlyNote + empty))])
            }
            var rows = saved.compactMap { server -> V? in
                guard let id = server["id"].string, let title = server["name"].string else { return nil }
                let address = [server["username"].string, server["address"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "@")
                return object([("id", .string(id)), ("title", .string(title)), ("detail", text(server["sshAlias"].string ?? address)),
                    ("badge", server["lookOnly"].bool == true ? .string("Look only") : nil), ("group", .string("Servers")), ("open", open("server:" + id))])
            }
            if let local = try? await port.call("docker.status", object([("target", .string("local"))]), rpc, domain, .read), local["available"].bool == true {
                rows.insert(object([("id", .string("local")), ("title", .string("This Mac")), ("detail", text(local["version"].string.map { "Docker " + $0 })),
                                    ("group", .string("This Mac")), ("open", .string("server:local"))]), at: 0)
            }
            let note = rows.isEmpty ? "No servers are saved on the Mac yet. Add one there: Machines → Add a server." : readOnlyNote
            return payload(request, rows: rows, extra: [("title", .string("Servers and Docker")), ("note", .string(note))])
        }
        return .init(scope: .machine, read: read)
    }
}
