import Foundation
import TerminalDeckNativeCore

/// Web version round 1 (31 Oct 2026): two read-only pages for the browser app, on the same remote
/// panel protocol the phones use (`panel.read`): the Receiver (events, sources and rules; needs Work)
/// and Projects (home folder, settings summary, counts; readable at Look). Every read goes through
/// the existing tools and the same access door as the phone pages (`BackendINT2PhonePanelScope`),
/// and no action is offered in v1. Both are machine pages: an owner-approved device only.
public struct BackendWEBPanelPort: Sendable {
    public typealias Call = BackendIOS2PanelPort.Call
    public let call: Call
    public let level: @Sendable (NativeRPCContext, String) async throws -> BackendINT2PhoneAccessLevel
    /// The calling device's authorized open projects (its folder grants applied).
    public let projects: @Sendable (NativeRPCContext, String) async throws -> [NativeRPCValue]
    public init(call: @escaping Call,
                level: @escaping @Sendable (NativeRPCContext, String) async throws -> BackendINT2PhoneAccessLevel,
                projects: @escaping @Sendable (NativeRPCContext, String) async throws -> [NativeRPCValue]) {
        self.call = call; self.level = level; self.projects = projects
    }
    public init(scope: BackendINT2PhonePanelScope) {
        call = { tool, arguments, rpc, domain, tier in try await scope.call(tool, arguments: arguments, rpc: rpc, domain: domain, tier: tier) }
        level = { rpc, domain in try await scope.level(rpc, domain: domain) }
        projects = { rpc, domain in try await scope.projects(rpc, domain: domain) }
    }
}

public enum BackendWEBPanels {
    typealias V = NativeRPCValue
    typealias P = BackendIOS2PhonePanels
    static let readOnlyNote = "Read only in the browser. Changes are made on the Mac."

    // MARK: - Receiver (read only; Work)

    static let receiverTabs: [(id: String, label: String)] = [("events", "Events"), ("sources", "Sources"), ("rules", "Rules")]
    static func statusTint(_ status: String?) -> V? {
        switch status {
        case "delivered": .string("ok")
        case "failed", "rejected": .string("bad")
        case "unrouted", "held": .string("warn")
        default: nil
        }
    }
    static func targetWords(_ target: V, names: [String: String]) -> String? {
        guard let kind = target["kind"].string else { return nil }
        let id = target["id"].string ?? ""
        switch kind {
        case "hoot": return "Hoot"
        case "newTask": return "A new task"
        case "agent": return "Agent " + (names[id] ?? id)
        case "session": return "Session " + id
        default: return kind + (id.isEmpty ? "" : " " + id)
        }
    }
    static func count(_ number: Int, _ word: String) -> String { "\(number) " + word + (number == 1 ? "" : "s") }

    public static func receiver(port: BackendWEBPanelPort) -> BackendRemotePanelProvider {
        let domain = "receiver"
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let scope = request.scope ?? ""
            let tab = scope.hasPrefix("tab:") ? String(scope.dropFirst("tab:".count)) : "events"
            guard receiverTabs.contains(where: { $0.id == tab }) else { throw NativeRPCError.invalidArguments("Choose one of the offered Receiver lists.") }
            let sources = try await port.call("receiver.sources", .object([]), rpc, domain, .read)["sources"].elements ?? []
            var sourceNames: [String: String] = [:]
            for view in sources { if let id = view["source"]["id"].string ?? view["id"].string { sourceNames[id] = view["source"]["name"].string } }
            var rows: [V] = []
            var notes = [readOnlyNote]
            switch tab {
            case "sources":
                for view in sources {
                    let source = view["source"]
                    guard let id = source["id"].string ?? view["id"].string, let name = source["name"].string else { continue }
                    let enabled = source["enabled"].bool != false
                    let state = !enabled ? "Paused" : view["active"].bool == true ? "Active" : "Waiting for the relay"
                    let events = Int(view["eventCount"].number ?? 0), rejected = Int(view["rejectedCount"].number ?? 0)
                    rows.append(P.object([("id", .string(id)), ("title", .string(name)), ("detail", P.text(view["address"].string ?? source["type"].string)),
                        ("value", .string(state)), ("status", !enabled ? .string("warn") : view["active"].bool == true ? .string("ok") : nil),
                        ("badge", P.text(source["type"].string ?? source["preset"].string)),
                        ("facts", P.facts([("Address", view["address"].string), ("Started from", source["preset"].string),
                                           ("Projects", source["projectScope"].string == "all" ? "Every project" : "One project"),
                                           ("Senders prove themselves by", source["auth"]["scheme"].string),
                                           ("Events", count(events, "event") + (rejected > 0 ? ", \(rejected) rejected" : "")),
                                           ("Today", view["todayCount"].number.map { "\(Int($0))" }),
                                           ("Last event", P.day(view["lastEventAt"].number)),
                                           ("Replies", source["reply"].isNullish ? "Off" : view["hasReplyCredential"].bool == true ? "On, with a stored key" : "On")]))]))
                }
                if rows.isEmpty { notes.append("No sources yet. Add one on the Mac: Integrations → Receiver.") }
            case "rules":
                let rules = try await port.call("receiver.rules", .object([]), rpc, domain, .read)["rules"].elements ?? []
                for (index, rule) in rules.enumerated() {
                    guard let id = rule["id"].string, let name = rule["name"].string else { continue }
                    let enabled = rule["enabled"].bool != false
                    let ruleSources = (rule["sourceIds"].elements ?? []).compactMap(\.string)
                    let conditions = rule["conditions"].elements?.count ?? 0
                    rows.append(P.object([("id", .string(id)), ("title", .string("\(index + 1). " + name)),
                        ("detail", P.text(targetWords(rule["target"], names: [:]))), ("value", .string(enabled ? "On" : "Off")),
                        ("status", enabled ? .string("ok") : nil),
                        ("facts", P.facts([("Sources", ruleSources.isEmpty ? "Any source" : ruleSources.map { sourceNames[$0] ?? $0 }.joined(separator: ", ")),
                                           ("Conditions", conditions == 0 ? "Every event" : count(conditions, "condition")),
                                           ("Sends to", targetWords(rule["target"], names: [:])),
                                           ("Instruction", P.clip(rule["instruction"].string, 300)),
                                           ("Works in", P.text(rule["project"].string)?.string),
                                           ("Limit", rule["perMinute"].number.map { "\(Int($0)) a minute" }),
                                           ("Repeats", (rule["dedupeMinutes"].number ?? 0) > 0 ? "Same instruction within \(Int(rule["dedupeMinutes"].number ?? 0)) min is a repeat" : nil),
                                           ("Replies", rule["autoApproveReplies"].bool == true ? "Sent without asking" : "Ask first")]))]))
                }
                if rows.isEmpty { notes.append("No rules yet. Add one on the Mac: Integrations → Receiver.") }
            default:
                let value = try await port.call("receiver.events", P.object([("limit", .number(200))]), rpc, domain, .read)
                for event in value["events"].elements ?? [] {
                    guard let id = event["id"].string, let title = event["title"].string else { continue }
                    let severity = event["severity"].string ?? "info"
                    rows.append(P.object([("id", .string(id)), ("title", .string(title)), ("detail", P.text(P.clip(event["text"].string, 240))),
                        ("value", P.text(event["status"].string)), ("status", statusTint(event["status"].string)),
                        ("badge", ["warning", "error", "critical"].contains(severity) ? .string(severity.capitalized) : nil),
                        ("group", P.text(sourceNames[event["source"].string ?? ""] ?? event["source"].string)),
                        ("facts", P.facts([("Source", sourceNames[event["source"].string ?? ""] ?? event["source"].string),
                                           ("Received", P.day(event["receivedAt"].number)), ("Kind", event["kind"].string),
                                           ("Rule", event["rule"].string), ("Sent to", targetWords(event["target"], names: [:])),
                                           ("Outcome", event["outcome"].string), ("Task", event["taskId"].string),
                                           ("Replies", event["replies"].number.flatMap { $0 > 0 ? "\(Int($0))" : nil })]))]))
                }
                if let note = value["note"].string { notes.append(note) }
                if rows.isEmpty { notes.append("Nothing has come in yet.") }
            }
            return P.payload(request, rows: rows, extra: [("title", .string("Receiver")),
                ("scopes", P.scopes(receiverTabs.map { (id: "tab:" + $0.id, label: $0.label) }, current: "tab:" + tab)),
                ("note", .string(notes.joined(separator: " ")))])
        }
        return .init(scope: .machine, read: read)
    }

    // MARK: - Projects (read only; Look)

    static func projectName(_ row: V) -> String {
        row["title"].string ?? row["name"].string ?? URL(fileURLWithPath: row["path"].string ?? "").lastPathComponent
    }
    /// Scalar settings only, in the order the tool gave them; nested blocks and secrets stay on the Mac.
    static func settingsSummary(_ settings: V) -> [(String, String?)] {
        (settings.fields ?? []).compactMap { field -> (String, String?)? in
            let key = field.key.lowercased()
            guard !["secret", "password", "token", "apikey", "credential"].contains(where: key.contains) else { return nil }
            switch field.value {
            case .string(let text): return text.isEmpty ? nil : (field.key, text)
            case .number(let number): return (field.key, number == number.rounded() ? "\(Int(number))" : "\(number)")
            case .bool(let flag): return (field.key, flag ? "On" : "Off")
            default: return nil
            }
        }
    }

    public static func projects(port: BackendWEBPanelPort) -> BackendRemotePanelProvider {
        let domain = "projects"
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let projects = try await port.projects(rpc, domain)
            let sessions = (try? await port.call("sessions.list", .object([]), rpc, domain, .read))?["sessions"].elements ?? []
            let scope = request.scope ?? ""
            let chosen: [V]
            if scope == "project" || scope.hasPrefix("project:") {
                let path = scope == "project" ? request.path : String(scope.dropFirst("project:".count))
                guard let row = projects.first(where: { $0["path"].string == path }) else {
                    throw NativeRPCError(code: "access-denied", message: "Choose one of this device's currently authorized open projects.")
                }
                chosen = [row]
            } else { chosen = projects }
            var rows: [V] = []
            for row in chosen {
                guard let path = row["path"].string, !path.isEmpty else { continue }
                let name = projectName(row)
                let tasks = (try? await port.call("tasks.local", P.object([("do", .string("list")), ("project", .string(path)), ("limit", .number(200))]), rpc, domain, .read))?["tasks"].elements ?? []
                let open = tasks.filter { $0["status"].string != "done" }.count
                let running = sessions.filter { session in
                    guard let cwd = session["cwd"].string else { return false }
                    return BackendRemoteTrustStore.within(path, cwd)
                }.count
                var facts: [(String, String?)] = [("Home folder", path), ("Running sessions", "\(running)"),
                    ("Tasks", tasks.isEmpty ? "None" : "\(open) open of \(tasks.count)"),
                    ("Lead", P.text(row["leadName"].string ?? row["lead"].string)?.string),
                    ("Last opened", P.day(row["lastOpenedAt"].number))]
                var detail = path
                if chosen.count == 1, let projectID = row["id"].string ?? row["projectId"].string,
                   let settings = try? await port.call("project_settings.get", P.object([("projectId", .string(projectID))]), rpc, domain, .read) {
                    let summary = settingsSummary(settings["values"].fields != nil ? settings["values"] : settings["settings"])
                    facts += summary.isEmpty ? [("Settings", "Default for every project")] : summary.prefix(12).map { ("Setting · " + $0.0, $0.1) }
                    detail = (summary.isEmpty ? "Default settings" : count(summary.count, "own setting")) + " · " + path
                }
                rows.append(P.object([("id", .string(path)), ("title", .string(name)), ("detail", .string(detail)),
                    ("value", .string(running > 0 ? count(running, "session") : open > 0 ? count(open, "open task") : "Quiet")),
                    ("status", running > 0 ? .string("ok") : nil), ("icon", P.text(row["icon"].string)),
                    ("facts", P.facts(facts)), ("open", chosen.count == 1 ? nil : P.open("project:" + path))]))
            }
            let note = projects.isEmpty ? "No open projects are shared with this device. Open one on the Mac, or widen the device's folders there." : readOnlyNote
            return P.payload(request, rows: rows, extra: [("title", .string(chosen.count == 1 ? projectName(chosen[0]) : "Projects")), ("note", .string(note))])
        }
        return .init(scope: .machine, read: read)
    }
}
