import Foundation
import AppKit
import CryptoKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// The CRM task link (CRM-LINK-SPEC.md), on top of the crm_task contract (BackendTaskAPI):
// the owner pin, the roster, every CRM field landing in the task, tasks with no agent
// ("From CRM", Option A), Hoot without a project, a comment that @mentions an agent, the
// `update` op, and a record of every arrival in the Receiver's Tasks source.
// Linked projects only: the CRM reaches Hoot and the agents of the projects its connection lists.

public enum BackendCrmLink {
    public static let fromCRM = "From CRM"
    public static let maxAvatarBytes = 64 * 1024

    /// The projects the connection lists (U33): none listed reaches Hoot only; no project is built in.
    public static func projects(_ connection: NativeRPCValue) -> [String] {
        connection["projects"].elements?.compactMap(\.string).filter { !$0.isEmpty } ?? []
    }
    /// The one CRM profile allowed to give work (`user:<uuid>`), pinned at setup; never taken from a message.
    public static func owner(_ connection: NativeRPCValue) -> String? { connection["ownerProfile"].string.flatMap { $0.isEmpty ? nil : $0 } }
    public static func hootIdentity(_ connection: NativeRPCValue) -> String { connection["hootIdentity"].string ?? "agent:hoot" }
    static func isHoot(_ identity: String?, _ connection: NativeRPCValue) -> Bool {
        guard let identity else { return false }
        return identity == hootIdentity(connection) || identity == "agent:hoot" || identity == "hoot"
    }

    /// Who an op is from.
    static func actor(_ operation: String, _ input: NativeRPCValue) -> String? {
        switch operation {
        case "comment": input["author"].string
        case "status": input["changedBy"].string
        default: input["requestedBy"].string ?? input["changedBy"].string
        }
    }

    /// The owner pin: nil when the op may go on. Reads never need it; an agent's own hand-off inside
    /// a task tree (a create with a parent) is checked by the task API's tree rule instead.
    public static func ownerRefusal(_ operation: String, input: NativeRPCValue, connection: NativeRPCValue) -> String? {
        guard let owner = owner(connection), !["get", "result", "roster"].contains(operation) else { return nil }
        if operation == "create", input["parentExternalTaskId"].string != nil { return nil }
        // Other people's comments on a task given to the owner arrive flagged context-only: kept as notes, never acted on.
        if operation == "comment", input["contextOnly"].bool == true { return nil }
        let who = actor(operation, input)
        guard who == owner else { return "Only the CRM owner’s profile can give Terminal Deck work; \(who.map { "“\(String($0.prefix(80)))”" } ?? "an unnamed sender") is not it." }
        return nil
    }

    // MARK: Agents the CRM can reach

    struct Reachable: Sendable { let id: String, name: String, project: String, kind: String, team: String?, icon: String?, available: Bool }

    /// Hoot is cross-project; the rest are the linked projects' agents, never the Terminal Deck team.
    static func reachable(_ connection: NativeRPCValue, config: BackendTaskConfiguration) async -> [Reachable] {
        let linked = projects(connection)
        let registry = (try? await BackendPROJRegistry.installed?.projects()) ?? []
        return ((try? await config.allAgents()) ?? []).compactMap { agent in
            guard let id = agent["id"].string, let project = agent["projectId"].string, linked.contains(project) else { return nil }
            let status = agent["status"].string ?? "active"
            guard ["active", "paused"].contains(status) else { return nil }
            let lead = registry.contains { $0.id == project && $0.lead == "agent:" + id }
            return Reachable(id: id, name: agent["name"].string ?? id, project: project, kind: lead ? "lead" : "agent",
                             team: agent["team"].string ?? agent["role"].string, icon: agent["icon"].string, available: status == "active")
        }
    }

    /// The identity a roster agent goes by: a hand-made identity when the connection has one, else `agent:<id>`.
    public static func identity(ofAgent id: String, connection: NativeRPCValue) -> String {
        connection["identities"].fields?.first { $0.value.string == id }?.key ?? "agent:" + id
    }

    /// An `agent:<id>` the CRM may assign or mention (a linked project's agent), as a task assignment.
    static func assignment(_ identity: String, connection: NativeRPCValue, config: BackendTaskConfiguration) async -> NativeRPCValue? {
        if isHoot(identity, connection) { return BackendTaskLocalService.assignment("hoot", kind: "hoot").setting("identity", .string(hootIdentity(connection))) }
        let id = connection["identities"][identity].string ?? (identity.hasPrefix("agent:") ? String(identity.dropFirst(6)) : nil)
        guard let id, await reachable(connection, config: config).contains(where: { $0.id == id }) else { return nil }
        return BackendTaskLocalService.assignment(id, kind: "agent").setting("identity", .string(identity))
    }

    /// `roster`: Hoot plus the linked projects' agents, with stable handles and small inline avatars.
    public static func roster(_ connection: NativeRPCValue, config: BackendTaskConfiguration) async -> NativeRPCValue {
        let agents = await reachable(connection, config: config).sorted(by: { ($0.project, $0.name) < ($1.project, $1.name) })
        return await MainActor.run {
        var rows: [NativeRPCValue] = [entry(handle: "hoot", identity: hootIdentity(connection), name: "Hoot", kind: "hoot", team: nil, project: nil, available: true)]
        for agent in agents {
            rows.append(entry(handle: agent.id, identity: identity(ofAgent: agent.id, connection: connection), name: agent.name, kind: agent.kind,
                              team: agent.team, project: agent.project, available: agent.available, icon: agent.icon))
        }
        return BackendTaskValues.object([("agents", .array(rows)), ("projects", .array(projects(connection).map(NativeRPCValue.string)))])
        }
    }

    @MainActor static func entry(handle: String, identity: String, name: String, kind: String, team: String?, project: String?, available: Bool, icon: String? = nil) -> NativeRPCValue {
        BackendTaskValues.object([("handle", .string(handle)), ("identity", .string(identity)), ("displayName", .string(name)), ("kind", .string(kind)),
                                  ("team", team.map(NativeRPCValue.string) ?? .null), ("project", project.map(NativeRPCValue.string) ?? .null),
                                  ("available", .bool(available)), ("avatar", avatar(name: name, seed: handle, icon: icon))])
    }

    /// A 64 × 64 PNG: the agent's initials on its colour (the same palette the task lists use). Under 64 KB.
    @MainActor static func avatar(name: String, seed: String, icon: String? = nil) -> NativeRPCValue {
        let size = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .null }
        let hues: [(CGFloat, CGFloat, CGFloat)] = [(0.23, 0.51, 0.96), (0.55, 0.36, 0.97), (0.20, 0.66, 0.33), (0.94, 0.54, 0.14), (0.91, 0.31, 0.54), (0.10, 0.65, 0.72), (0.85, 0.70, 0.00)]
        let (r, g, b) = hues[BackendCrmPeople.hashStringToIndex(seed, hues.count)]
        context.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let parsed = AGTIcon.parse(icon)
        var glyph = BackendCrmPeople.deriveInitials(name)
        var symbolImage: CGImage?
        if case .symbol(let symbol) = parsed,
           let picture = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 38, weight: .regular)) {
            var rect = CGRect(x: 0, y: 0, width: 40, height: 40)
            symbolImage = picture.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        } else if case .emoji(let emoji) = parsed { glyph = emoji }
        if let symbolImage {
            let scale = min(40 / CGFloat(symbolImage.width), 40 / CGFloat(symbolImage.height))
            let width = CGFloat(symbolImage.width) * scale, height = CGFloat(symbolImage.height) * scale
            context.saveGState()
            context.clip(to: CGRect(x: (64 - width) / 2, y: (64 - height) / 2, width: width, height: height), mask: symbolImage)
            context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.restoreGState()
        } else {
        let font = CTFontCreateWithName((parsed == nil ? "Helvetica-Bold" : "AppleColorEmoji") as CFString, parsed == nil ? 26 : 36, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(colorSpace: space, components: [1, 1, 1, 1])!]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: (CGFloat(size) - bounds.width) / 2 - bounds.minX, y: (CGFloat(size) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { return .null }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return .null }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= maxAvatarBytes else { return .null }
        let bytes = data as Data
        return BackendTaskValues.object([("png", .string(bytes.base64EncodedString())), ("sha256", .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())),
                                         ("bytes", .number(Double(bytes.count)))])
    }

    // MARK: Fields

    /// Every CRM field of an op, read through the CRM tasks mapping (the Receiver's Tasks source reads it the same way).
    public static func fields(_ input: NativeRPCValue) -> RCVTaskFields {
        guard let body = try? input.encodedJSON() else { return RCVTaskFields() }
        return RCVTaskMapping.fields(payload: body)
    }

    /// A task value with the op's fields landed: the task's own keys, `crmFields` (merged by label), and on a new task the
    /// "Details from the CRM" block in its instructions, so the agent or Hoot sees due date, links, files and custom fields.
    public static func withFields(_ task: NativeRPCValue, input: NativeRPCValue, newTask: Bool) -> NativeRPCValue {
        let fields = fields(input)
        var value = task
        for field in BackendTaskFieldLanding.patch(fields).fields ?? [] where field.key != "crmStatus" { value = value.setting(field.key, field.value) }
        var rows = value["crmFields"].elements ?? []
        for custom in fields.custom {
            let row = BackendTaskValues.object([("label", .string(custom.label)), ("value", .string(custom.value)), ("kind", .string(custom.kind))])
            if let index = rows.firstIndex(where: { $0["label"].string?.lowercased() == custom.label.lowercased() }) { rows[index] = row } else { rows.append(row) }
        }
        value = value.setting("crmFields", .array(Array(rows.prefix(80))))
        let lines = fields.lines().filter { !$0.hasPrefix("Comment: ") }
        if newTask, !lines.isEmpty {
            let block = "\n\n## Details from the CRM\n\n" + lines.map { "- " + $0.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n")
            value = value.setting("instructions", .string(String(((value["instructions"].string ?? "") + block).prefix(20_000))))
        }
        return value
    }

    /// The folder a task for this assignment works in: a folder the CRM named, else the named project's
    /// folder, else the agent's own default project.
    static func folder(_ named: String?, assignment: NativeRPCValue, config: BackendTaskConfiguration) async -> String? {
        if let named, named.hasPrefix("/") { return named }
        let registry = (try? await BackendPROJRegistry.installed?.projects()) ?? []
        if let named, let project = registry.first(where: { $0.id == named }), let first = project.folders.first { return first }
        guard assignment["kind"].string == "agent", let id = assignment["agentId"].string else { return nil }
        return try? await config.agent(id)?["defaultProject"].string
    }

    static func projectID(_ assignment: NativeRPCValue, config: BackendTaskConfiguration) async -> String? {
        guard assignment["kind"].string == "agent", let id = assignment["agentId"].string else { return nil }
        return try? await config.agent(id)?["projectId"].string
    }
}

extension BackendTaskAPI {
    /// The link's own handling, before the original contract's. Nil: the original contract handles it.
    func linkPerform(_ operation: String, keyID: String, connection: NativeRPCValue, input: NativeRPCValue) async throws -> NativeRPCValue? {
        func text(_ key: String, _ max: Int) -> String? {
            guard let value = input[key].string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return String(value.prefix(max))
        }
        let external = text("externalTaskId", 200)
        switch operation {
        case "create":
            // v1.1: a create for a task the CRM cancelled before reopens the same task and thread here.
            if let external, let existing = try await store.byID(keyID + ":" + external), existing.value["stopped"].bool == true || !existing.value["archivedAt"].isNullish {
                return try await linkReopen(existing, connection: connection, input: input)
            }
            guard let external, try await store.byID(keyID + ":" + external) == nil, input["parentExternalTaskId"].isNullish else { return nil }
            let assignee = text("assignee", 200)
            if assignee == nil || assignee!.hasPrefix("user:") {
                // Option A: a task someone gave the owner in the CRM. Mirrored, held by nobody, in "From CRM"; wakes nobody.
                return try await linkCreate(keyID: keyID, external: external, connection: connection, input: input,
                                            assignment: BackendTaskLocalService.assignment("none", kind: "none"), folder: "", projectID: "independent", waiting: true)
            }
            if BackendCrmLink.isHoot(assignee, connection), text("project", 1_024) == nil {
                // Hoot is cross-project: no project from the CRM; Hoot decides which linked project.
                return try await linkCreate(keyID: keyID, external: external, connection: connection, input: input,
                                            assignment: BackendCrmLink.assignment(assignee!, connection: connection, config: config)!, folder: "", projectID: "independent", waiting: false)
            }
            if let assignee, let assignment = await BackendCrmLink.assignment(assignee, connection: connection, config: config), assignment["kind"].string == "agent" {
                // A linked project's agent: its project decides (CRM-LINK-SPEC §Project).
                guard let folder = await BackendCrmLink.folder(text("project", 1_024), assignment: assignment, config: config) else { return nil }
                guard Self.folderAllowed(connection, path: folder) else { return nil }
                let project = await BackendCrmLink.projectID(assignment, config: config) ?? "independent"
                return try await linkCreate(keyID: keyID, external: external, connection: connection, input: input, assignment: assignment, folder: folder,
                                            projectID: project, waiting: false)
            }
            return nil
        case "comment":
            guard let external, let body = text("body", 20_000) else { return nil }
            if input["contextOnly"].bool == true {
                // Someone else's comment on a task given to the owner: context only. It wakes nobody and its mentions are never read.
                guard let task = try await store.byID(keyID + ":" + external) else { return BackendTaskValues.object([("outcome", .string("ignored_not_ours"))]) }
                try await store.note(task.id, by: text("authorName", 120) ?? "someone in the CRM", kind: "comment", text: body)
                return BackendTaskValues.object([("outcome", .string("kept_as_context")), ("task", try await snapshot(task))])
            }
            let mentions = (input["mentions"].elements ?? []).compactMap(\.string)
            // Only the owner's profile gives work: their CRM name, else this Mac's owner (U33).
            let commenter = text("authorName", 120) ?? DeckOwner.name
            var target: NativeRPCValue?
            for mention in mentions { if let found = await BackendCrmLink.assignment(mention, connection: connection, config: config) { target = found; break } }
            if let task = try await store.byID(keyID + ":" + external) {
                guard task.assigneeKind == "none" || task.assigneeKind == "human" else { return nil }
                guard let target else {
                    // A comment on a task nobody here holds: context only, it wakes nobody.
                    try await store.note(task.id, by: text("author", 200) ?? "crm", kind: "comment", text: body)
                    return BackendTaskValues.object([("outcome", .string("kept_as_context")), ("task", try await snapshot(task))])
                }
                let folder = await BackendCrmLink.folder(task.project.isEmpty ? nil : task.project, assignment: target, config: config) ?? task.project
                var patch = BackendTaskValues.object([("instructions", .string(String(((task.value["instructions"].string ?? "") + "\n\n## " + commenter + "’s comment\n\n" + body).prefix(20_000)))),
                                                      ("project", .string(folder)), ("mainAssignee", target["identity"])])
                if let project = await BackendCrmLink.projectID(target, config: config) { patch = patch.setting("projectId", .string(project)) }
                _ = try await store.update(task.id, patch: patch)
                try await engine.reassign(task.id, assignee: target)
                return BackendTaskValues.object([("outcome", .string("accepted")), ("task", try await snapshot(try await store.byID(task.id) ?? task))])
            }
            // Not linked yet: the mention gives it (create + assign), the comment is its first message.
            guard let target else { return BackendTaskValues.object([("outcome", .string("ignored_not_ours"))]) }
            let title = text("title", 300) ?? String(body.split(separator: "\n").first.map(String.init)?.prefix(300) ?? "Task from the CRM")
            var created = input.setting("title", .string(title)).setting("instructions", .string((text("instructions", 18_000).map { $0 + "\n\n" } ?? "") + commenter + "’s comment: " + body))
                .setting("requestedBy", input["author"]).setting("assignee", target["identity"])
            created = created.removing("body")
            let isHoot = target["kind"].string == "hoot"
            var folder = "", project = "independent"
            if !isHoot {
                folder = await BackendCrmLink.folder(text("project", 1_024), assignment: target, config: config) ?? ""
                project = await BackendCrmLink.projectID(target, config: config) ?? "independent"
                guard Self.folderAllowed(connection, path: folder) else { return BackendTaskValues.object([("outcome", .string("ignored_not_ours"))]) }
            }
            return try await linkCreate(keyID: keyID, external: external, connection: connection, input: created, assignment: target, folder: folder,
                                        projectID: project, waiting: false)
        case "update":
            guard let external, let task = try await store.byID(keyID + ":" + external) else { throw NativeRPCError.invalidArguments("There is no task \(external ?? "") here.") }
            var patch = BackendCrmLink.withFields(BackendTaskValues.object([("crmFields", task.value["crmFields"])]), input: input, newTask: false)
            if let title = text("title", 300) { patch = patch.setting("title", .string(title)) }
            let allowed = connection["statuses"]["statuses"].elements?.compactMap(\.string) ?? [], status = BackendCrmLink.fields(input).status
            if let status, allowed.contains(status) { patch = patch.setting("crmStatus", .string(status)) }
            _ = try await store.update(task.id, patch: patch)
            return BackendTaskValues.object([("outcome", .string("recorded")), ("task", try await snapshot(try await store.byID(task.id) ?? task))])
        default: return nil
        }
    }

    /// A mirrored CRM task the link makes itself (no agent, Hoot without a project, a mention).
    private func linkCreate(keyID: String, external: String, connection: NativeRPCValue, input: NativeRPCValue, assignment: NativeRPCValue,
                            folder: String, projectID: String, waiting: Bool) async throws -> NativeRPCValue {
        let title = String((input["title"].string ?? "Task from the CRM").prefix(300))
        let allowed = connection["statuses"]["statuses"].elements?.compactMap(\.string) ?? [], wanted = input["status"].string
        let now = BackendTaskValues.time()
        var instructions = String((input["instructions"].string ?? "").prefix(18_000))
        if assignment["kind"].string == "hoot", folder.isEmpty {
            let linked = BackendCrmLink.projects(connection)
            instructions += "\n\nNo project came with this task. Decide which project it belongs to" + (linked.isEmpty ? "" : " (linked: " + linked.joined(separator: ", ") + ")")
                + " and hand it to an agent of that project with tasks_delegate; the project goes back to the CRM."
        }
        var task = BackendTaskValues.object([("id", .string(keyID + ":" + external)), ("keyId", .string(keyID)), ("externalTaskId", .string(external)),
            ("originExternalTaskId", .string(external)), ("externalThreadId", input["externalThreadId"].string.map(NativeRPCValue.string) ?? .null), ("parentExternalTaskId", .null), ("parentTaskId", .null),
            ("notificationKeyId", .string(keyID)), ("title", .string(title)), ("instructions", .string(instructions)), ("project", .string(folder)), ("projectId", .string(projectID)),
            ("assignee", assignment), ("mainAssignee", waiting ? (input["assignee"].string.map(NativeRPCValue.string) ?? input["requestedBy"]) : assignment["identity"]),
            ("creator", input["creator"].string.map(NativeRPCValue.string) ?? input["requestedBy"]), ("requestedBy", input["requestedBy"]),
            ("crmStatus", wanted.flatMap { allowed.contains($0) ? NativeRPCValue.string($0) : nil } ?? connection["statuses"]["initial"]),
            ("process", .string(waiting ? "idle" : "queued")), ("sessionId", .null), ("conversationId", .null), ("runStartedAt", .null), ("keepOpenUntil", .null), ("hops", .number(0)),
            ("result", .null), ("questionOpen", .bool(false)), ("lastTurn", .null), ("childrenTold", .null), ("stopped", .bool(false)), ("seq", .number(0)),
            ("createdAt", .number(now)), ("updatedAt", .number(now))])
        task = BackendCrmLink.withFields(task, input: input, newTask: !waiting)
        if waiting {
            var labels = task["labels"].elements?.compactMap(\.string) ?? []
            if !labels.contains(BackendCrmLink.fromCRM) { labels.insert(BackendCrmLink.fromCRM, at: 0) }
            task = task.setting("board", .string(BackendCrmLink.fromCRM)).setting("labels", .array(labels.prefix(20).map(NativeRPCValue.string)))
        }
        let saved = try await store.put(task)
        // A task held by nobody is not started: accept() leaves it idle. Hoot and agents start as usual.
        try await engine.accept(saved.id)
        return BackendTaskValues.object([("outcome", .string("accepted")), ("task", try await snapshot(try await store.byID(saved.id) ?? saved))])
    }

    /// v1.1: a cancelled task given again. Same task, same thread, same project; the new words and fields are added.
    private func linkReopen(_ task: BackendTaskRecord, connection: NativeRPCValue, input: NativeRPCValue) async throws -> NativeRPCValue {
        let assignee = input["assignee"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let assignment: NativeRPCValue
        if assignee.isEmpty || assignee.hasPrefix("user:") { assignment = BackendTaskLocalService.assignment("none", kind: "none") }
        else if let found = await BackendCrmLink.assignment(assignee, connection: connection, config: config) { assignment = found }
        else { throw NativeRPCError.invalidArguments("That assignee is not Hoot or one of the linked projects' agents.") }
        var patch = BackendCrmLink.withFields(BackendTaskValues.object([("crmFields", task.value["crmFields"])]), input: input, newTask: false)
            .setting("stopped", .bool(false)).setting("archivedAt", .null).setting("result", .null).setting("questionOpen", .bool(false))
        if let words = input["instructions"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
            patch = patch.setting("instructions", .string(String(((task.value["instructions"].string ?? "") + "\n\n## Given again in the CRM\n\n" + words).prefix(20_000))))
        }
        _ = try await store.update(task.id, patch: patch)
        let who = input["createdByName"].string ?? input["changedByName"].string
        try await store.note(task.id, by: input["requestedBy"].string ?? "crm", kind: "edited", text: "Reopened in the CRM" + (who.map { " by \($0)" } ?? "") + ".")
        if assignment["kind"].string == "none" {
            _ = try await store.update(task.id, patch: BackendTaskValues.object([("assignee", assignment), ("process", .string("idle"))]))
        } else { try await engine.reassign(task.id, assignee: assignment) }
        return BackendTaskValues.object([("outcome", .string("accepted")), ("reopened", .bool(true)), ("task", try await snapshot(try await store.byID(task.id) ?? task))])
    }

    /// v1.1: `createdByName` / `changedByName` are context only: one line in the task's history, nothing more.
    func linkContext(_ operation: String, keyID: String, input: NativeRPCValue) async {
        guard let name = (input["changedByName"].string ?? input["createdByName"].string)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              operation != "create" || input["createdByName"].string != nil, let external = input["externalTaskId"].string,
              let task = try? await store.byID(keyID + ":" + external) else { return }
        let what: String
        switch operation {
        case "create": what = "created it"
        case "status": what = "set its status to \(input["status"].string ?? "?")"
        case "assign": what = "gave it to \(input["assignee"].string ?? "someone")"
        case "cancel": what = "cancelled it"
        case "update": what = "changed its details"
        case "comment": what = "commented"
        default: return
        }
        try? await store.note(task.id, by: "crm", kind: "edited", text: "\(String(name.prefix(80))) \(what) in the CRM.")
    }

    /// Every op the CRM sent, shown in the Receiver's Tasks source (CRM-LINK-SPEC §Visible in Terminal Deck).
    func linkRecord(_ operation: String, keyID: String, connection: NativeRPCValue, input: NativeRPCValue, answer: BackendTaskAPIAnswer) async {
        guard !["get", "result", "roster"].contains(operation), answer.value["duplicate"].bool != true else { return }
        let kind = ["create": "task.created", "assign": "task.assigned", "comment": "task.comment", "status": "task.changed", "update": "task.changed", "cancel": "task.cancelled"][operation] ?? "task." + operation
        let id = input["externalTaskId"].string.map { keyID + ":" + $0 }
        let task = id == nil ? nil : try? await store.byID(id!)
        let outcome: String
        if !answer.ok { outcome = "Refused: " + (answer.message ?? answer.code ?? "no reason") }
        else { outcome = "Answered “\(answer.value["outcome"].string ?? "done")”" + (task.map { " for the task “\($0.value["title"].string ?? "")”." } ?? ".") }
        let changed = answer.ok && ["accepted", "answered", "recorded", "cancelled", "released", "kept_as_context"].contains(answer.value["outcome"].string ?? "")
        await BackendRCVFeed.shared.recordTaskArrival(.init(kind: kind, from: connection["name"].string ?? "the CRM", title: task?.value["title"].string ?? input["title"].string,
            payload: input, upstreamId: input["eventId"].string, taskId: changed ? task?.id : nil, outcome: outcome, projectId: task?.value["projectId"].string))
    }
}

extension BackendCrmLink {
    /// The actor an outgoing event carries: an agent or CRM user identity as it is; Hoot as `agent:hoot`; a task a person
    /// here holds ("me", nobody) speaks as the CRM profile that gave it (`user:<uuid>` exactly as the CRM sent it).
    public static func outgoingActor(_ said: String?, task: BackendTaskRecord) -> String {
        if let said, said.hasPrefix("agent:") || said.hasPrefix("user:") { return said }
        if let said, said.lowercased() == "hoot" { return "agent:hoot" }
        if let giver = task.value["requestedBy"].string, giver.hasPrefix("user:") { return giver }
        return said ?? "agent:hoot"
    }
}

extension BackendCrmLink {
    /// "Sync chat to CRM" (on by default): read it, or set it on one CRM task.
    public static func sync(_ task: BackendTaskRecord, on: Bool?, store: BackendTaskStore, outbox: BackendTaskOutbox? = nil) async throws -> NativeRPCValue {
        guard !task.isLocal else { throw NativeRPCError.invalidArguments("That is a task of this Mac; only CRM tasks sync to the CRM.") }
        if let on, on != (task.value["crmSync"].bool != false) {
            _ = try await store.update(task.id, patch: BackendTaskValues.object([("crmSync", .bool(on))]))
            // One signed sync.paused / sync.resumed for the task, so the CRM can show it (sent even while off).
            if let outbox { try? await BackendTaskOutbox.outgoing(store: store, outbox: outbox)(task, BackendTaskValues.object([("type", .string(on ? "sync.resumed" : "sync.paused")), ("actor", .null)])) }
            try await store.note(task.id, by: "me", kind: "edited", text: on ? "Sync chat to CRM: on." : "Sync chat to CRM: off. Nothing about this task goes to the CRM until it is on again.")
        }
        let current = try await store.byID(task.id) ?? task
        return BackendTaskValues.object([("task", .string(task.id)), ("syncToCRM", .bool(current.value["crmSync"].bool != false))])
    }

    /// #576: `@handle` counts only as a whole name: "@sam" is not in "@samantha", nor in "me@sam".
    static func mentions(_ text: String, _ handle: String) -> Bool {
        func partOfName(_ character: Character?) -> Bool { character.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } ?? false }
        var from = text.startIndex
        while let found = text.range(of: handle, range: from..<text.endIndex) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            if !partOfName(before), !partOfName(found.upperBound == text.endIndex ? nil : text[found.upperBound]) { return true }
            from = text.index(after: found.lowerBound)
        }
        return false
    }

    /// Hoot @mentioned agents on a CRM task it holds: each mentioned agent of a linked project gets the part as its own
    /// task here, tied to that CRM task's thread (its comments go there under its own name; BackendTaskEngine.post).
    /// Returns the names asked.
    public static func relayMentions(_ task: BackendTaskRecord, text: String, local: BackendTaskLocalService, config: BackendTaskConfiguration, store: BackendTaskStore) async -> [String] {
        guard !task.isLocal, text.contains("@"), let connection = try? await config.connection(task.value["keyId"].string ?? "") else { return [] }
        let lower = text.lowercased()
        var asked: [String] = []
        for agent in await reachable(connection, config: config) where agent.available {
            let handles = ["@" + agent.id.lowercased(), "@" + agent.name.lowercased(), "@" + agent.name.lowercased().replacingOccurrences(of: " ", with: "")]
            guard handles.contains(where: { mentions(lower, $0) }) else { continue }
            let folder = (try? await config.agent(agent.id))?["defaultProject"].string ?? ""
            let title = String((task.value["title"].string ?? "a CRM task").prefix(200))
            let input = BackendTaskValues.object([("title", .string(String("Part of “\(title)”".prefix(300)))),
                ("instructions", .string("Hoot asked you this on the CRM task “\(title)”:\n\n\(BackendTaskBriefComposition.quoted(text))\n\nThe task itself:\n\n\(BackendTaskBriefComposition.quoted(String((task.value["instructions"].string ?? "").prefix(12_000))))\n\nPost your progress, questions and result with tasks_comment on THIS task: each one goes into the CRM task’s thread under your own name, and Hoot hears your result.")),
                ("assignee", .string(agent.id)), ("project", .string(folder)), ("projectId", .string(agent.project))])
            guard let made = try? await local.create(input, by: "hoot") else { continue }
            _ = try? await store.update(made.id, patch: BackendTaskValues.object([("crmThreadOf", .string(task.id))]))
            asked.append(agent.name)
        }
        return asked
    }
}

extension BackendCrmLink {
    /// The CRM link's consent (install 13: every crm_task call was raised to "Full control" and would have asked on
    /// screen). The owner said yes once, when connecting the CRM: its profile is pinned and the task API refuses any
    /// other actor itself. So a key with the task grant (a CRM-only key has it) never stops on an on-screen question
    /// for crm_task; every other tool keeps `otherwise`.
    public static func ownerMustAnswer(tool: String, caller: BackendDeckCoreSecurityCaller, otherwise: Bool) -> Bool {
        if ["crm.task", "crm_task"].contains(tool), caller.kind == .key, caller.tasks { return false }
        return otherwise
    }
}
