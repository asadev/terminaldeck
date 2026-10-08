import Foundation
import TerminalDeckNativeCore

public struct BackendTaskAPIAnswer: Sendable {
    public let ok: Bool, code: String?, message: String?, value: NativeRPCValue
    public var wireValue: NativeRPCValue { ok ? BackendTaskValues.object([("ok", .bool(true)), ("value", value)]) : BackendTaskValues.object([("ok", .bool(false)), ("code", code.map(NativeRPCValue.string) ?? .null), ("message", message.map(NativeRPCValue.string) ?? .null)]) }
    static func success(_ value: NativeRPCValue) -> Self { Self(ok: true, code: nil, message: nil, value: value) }
    static func failure(_ code: String, _ message: String) -> Self { Self(ok: false, code: code, message: message, value: .missing) }
}

/// The task-api.ts operations; shared CRM transport/authentication is supplied
/// by its owner. keyID is backend authentication output, never body input.
public actor BackendTaskAPI {
    private let store: BackendTaskStore, config: BackendTaskConfiguration, engine: any BackendTaskExecuting
    private var busy = false, waiters: [CheckedContinuation<Void, Never>] = []
    public init(store: BackendTaskStore, configuration: BackendTaskConfiguration, engine: any BackendTaskExecuting) { self.store = store; config = configuration; self.engine = engine }
    public func call(_ operation: String, keyID: String, input: NativeRPCValue) async throws -> BackendTaskAPIAnswer {
        await enter(); defer { leave() }; try Task.checkCancellation()
        do {
            guard input.fields != nil else { throw Failure("bad_request", "The request has to be a JSON object.") }
            guard let connection = try await config.connection(keyID), connection["enabled"].bool == true else { throw Failure("disabled", "Tasks are switched off for this connection in Terminal Deck.") }
            guard ["create", "assign", "get", "result", "cancel", "comment", "status"].contains(operation) else { throw Failure("bad_request", "That is not a task operation.") }
            var event: String?
            if operation != "get" && operation != "result" {
                let id = try required(input, "eventId", maximum: 200); event = id
                let before = try await store.answered(keyID: keyID, eventID: id)
                if before != .missing { return .success(before.setting("duplicate", .bool(true))) }
            }
            let value = try await perform(operation, keyID: keyID, connection: connection, input: input)
            if let event { try await store.remember(keyID: keyID, eventID: event, answer: value) }
            return .success(value)
        } catch let error as Failure { return .failure(error.code, error.message) }
        catch let error as NativeRPCError where error.code == "invalid-arguments" { return .failure("bad_request", error.message) }
    }
    private func perform(_ operation: String, keyID: String, connection: NativeRPCValue, input: NativeRPCValue) async throws -> NativeRPCValue {
        switch operation {
        case "create":
            let external = try required(input, "externalTaskId", maximum: 200), who = try required(input, "requestedBy", maximum: 200)
            let assignment = try await assignee(connection, identity: required(input, "assignee", maximum: 200))
            let parentID = try optional(input, "parentExternalTaskId", maximum: 200), parent: BackendTaskRecord?
            if let parentID { parent = try await store.byID(keyID + ":" + parentID); guard parent != nil else { throw Failure("not_found", "There is no task \(parentID) here to be a parent.") } } else { parent = nil }
            try await sender(connection, who: who, parent: parent)
            if let existing = try await store.byID(keyID + ":" + external) {
                if existing.value["assignee"]["identity"] != assignment["identity"] { try await engine.reassign(existing.id, assignee: assignment) }
                return try await outcome("accepted", task: record(existing.id))
            }
            let hops = parent == nil ? 0 : Int(parent!.value["hops"].number ?? 0) + 1, maxHops = Int(connection["maxHops"].number ?? 3)
            guard hops <= maxHops else { throw Failure("too_many_hops", "This task tree has reached its limit of \(maxHops) hand-offs.") }
            guard let project = try optional(input, "project", maximum: 1_024) ?? parent?.project else { throw Failure("bad_request", "project is required.") }
            guard Self.folderAllowed(connection, path: project) else { throw Failure("folder_not_allowed", "\(project) is not a folder this connection allows work in.") }
            let status = try optional(input, "status", maximum: 60), allowed = connection["statuses"]["statuses"].elements?.compactMap(\.string) ?? []
            let now = BackendTaskValues.time(), task = BackendTaskValues.object([("id", .string(keyID + ":" + external)), ("keyId", .string(keyID)), ("externalTaskId", .string(external)),
                ("originExternalTaskId", parent?.value["originExternalTaskId"] ?? .string(external)), ("externalThreadId", try optional(input, "externalThreadId", maximum: 200).map(NativeRPCValue.string) ?? parent?.value["externalThreadId"] ?? .null), ("parentExternalTaskId", parentID.map(NativeRPCValue.string) ?? .null), ("parentTaskId", parent.map { .string($0.id) } ?? .null), ("notificationKeyId", .string(keyID)),
                ("title", .string(try required(input, "title", maximum: 300))), ("instructions", .string(try optional(input, "instructions", maximum: 20_000) ?? "")), ("project", .string(project)), ("assignee", assignment),
                ("mainAssignee", try optional(input, "mainAssignee", maximum: 200).map(NativeRPCValue.string) ?? assignment["identity"]), ("creator", try optional(input, "creator", maximum: 200).map(NativeRPCValue.string) ?? .null), ("requestedBy", .string(who)),
                ("crmStatus", status.map { allowed.contains($0) ? .string($0) : connection["statuses"]["initial"] } ?? connection["statuses"]["initial"]), ("process", .string("queued")), ("sessionId", .null), ("conversationId", .null), ("runStartedAt", .null), ("keepOpenUntil", .null), ("hops", .number(Double(hops))),
                ("result", .null), ("questionOpen", .bool(false)), ("lastTurn", .null), ("childrenTold", .null), ("stopped", .bool(false)), ("seq", .number(0)), ("createdAt", .number(now)), ("updatedAt", .number(now))])
            let saved = try await store.put(task); try await engine.accept(saved.id); return try await outcome("accepted", task: record(saved.id))
        case "comment":
            let author = try required(input, "author", maximum: 200), commentID = try optional(input, "externalCommentId", maximum: 200), body = try required(input, "body", maximum: 20_000)
            let ours = try await commentID.asyncMap { try await self.store.isOurs(keyID: keyID, eventID: $0) } ?? false
            if ownIdentity(connection, identity: author) || ours { return fields([("outcome", .string("ignored_own_agent"))]) }
            if let commentID { let before = try await store.answered(keyID: keyID, eventID: "comment:" + commentID); if before != .missing { return before } }
            guard (connection["allowedSenders"].elements ?? []).contains(.string(author)) else { return fields([("outcome", .string("ignored_not_allowed"))]) }
            let external = try required(input, "externalTaskId", maximum: 200)
            guard let task = try await store.byID(keyID + ":" + external) else { return fields([("outcome", .string("ignored_not_ours"))]) }
            let mentions = input["mentions"].isNullish ? [] : try input["mentions"].requireArray("mentions").compactMap(\.string).filter { !$0.isEmpty && $0.utf16.count <= 200 }
            let replyTo = try optional(input, "inReplyTo", maximum: 200), replyOurs = try await replyTo.asyncMap { try await self.store.isOurs(keyID: keyID, eventID: $0) } ?? false
            guard task.value["stopped"].bool != true, mentions.contains(task.value["assignee"]["identity"].string ?? "") || replyOurs || task.value["questionOpen"].bool == true else { return fields([("outcome", .string("ignored_not_addressed"))]) }
            try await engine.reply(task.id, text: body); let answer = try await outcome("answered", task: record(task.id))
            if let commentID { try await store.remember(keyID: keyID, eventID: "comment:" + commentID, answer: answer) }; return answer
        default:
            let external = try required(input, "externalTaskId", maximum: 200), task = try await record(keyID + ":" + external)
            switch operation {
            case "get": return fields([("task", try await snapshot(task))])
            case "result": return fields([("externalTaskId", .string(external)), ("finished", .bool(!task.value["result"].isNullish)), ("verified", task.value["result"]["verified"].isNullish ? .null : task.value["result"]["verified"]), ("answer", task.value["result"]["answer"].isNullish ? .null : task.value["result"]["answer"]), ("check", task.value["result"]["check"].isNullish ? .null : task.value["result"]["check"]), ("crmStatus", task.value["crmStatus"])])
            case "assign":
                try await sender(connection, who: required(input, "requestedBy", maximum: 200), parent: nil)
                let assignment = try await tryAssignee(connection, identity: required(input, "assignee", maximum: 200))
                if let assignment { if assignment["identity"] != task.value["assignee"]["identity"] || task.value["stopped"].bool == true { try await engine.reassign(task.id, assignee: assignment) }; return try await outcome("accepted", task: record(task.id)) }
                if task.value["stopped"].bool != true { try await engine.cancel(task.id, reason: "it was assigned to somebody else in the CRM.") }; return try await outcome("released", task: record(task.id))
            case "cancel":
                try await sender(connection, who: required(input, "requestedBy", maximum: 200), parent: nil)
                if task.value["stopped"].bool != true { try await engine.cancel(task.id, reason: optional(input, "reason", maximum: 500).map { "cancelled in the CRM: " + $0 } ?? "cancelled in the CRM.") }
                return try await outcome("cancelled", task: record(task.id))
            case "status":
                let status = try required(input, "status", maximum: 60)
                if let who = try optional(input, "changedBy", maximum: 200), ownIdentity(connection, identity: who) { return fields([("outcome", .string("ignored_own_agent"))]) }
                guard (connection["statuses"]["statuses"].elements ?? []).contains(.string(status)) else { throw Failure("bad_request", "\(status) is not one of this connection's statuses.") }
                _ = try await store.update(task.id, patch: fields([("crmStatus", .string(status))])); return try await outcome("recorded", task: record(task.id))
            default: throw Failure("bad_request", "Unknown task operation")
            }
        }
    }
    public func snapshot(_ task: BackendTaskRecord) async throws -> NativeRPCValue {
        let agent = try await config.agent(task.agentID)
        return fields([("externalTaskId", task.value["externalTaskId"]), ("originExternalTaskId", task.value["originExternalTaskId"]), ("parentTaskId", task.value["parentTaskId"].isNullish ? .null : task.value["parentTaskId"]), ("assignee", task.value["assignee"]["identity"]), ("agent", task.assigneeKind == "hoot" ? .string("Hoot") : agent?["name"] ?? .string(task.agentID)), ("crmStatus", task.value["crmStatus"]), ("process", task.value["process"]), ("keptOpenUntil", task.value["keepOpenUntil"].number.map { .string(BackendTaskOutbox.iso($0)) } ?? .null), ("keepAliveUntilClose", .bool(task.value["keepAliveUntilClose"].bool == true)), ("finished", .bool(!task.value["result"].isNullish)), ("verified", task.value["result"].isNullish ? .null : task.value["result"]["verified"]), ("updatedAt", .string(BackendTaskOutbox.iso(task.value["updatedAt"].number ?? 0)))])
    }
    private func sender(_ connection: NativeRPCValue, who: String, parent: BackendTaskRecord?) async throws {
        let allowed = connection["allowedSenders"].elements?.compactMap(\.string) ?? []
        if allowed.contains(who) { return }
        if let parent, parent.value["stopped"].bool != true,
           (parent.assigneeKind == "hoot" && who == connection["hootIdentity"].string || parent.assigneeKind == "agent" && who == parent.value["assignee"]["identity"].string && connection["identities"][who].string == parent.agentID) {
            var at: BackendTaskRecord? = parent
            for _ in 0..<(Int(connection["maxHops"].number ?? 3) + 2) {
                guard let task = at else { break }
                if let parent = task.value["parentExternalTaskId"].string { at = try await store.byID((task.value["keyId"].string ?? "") + ":" + parent) }
                else if allowed.contains(task.value["requestedBy"].string ?? "") { return } else { break }
            }
        }; throw Failure("not_allowed", "That CRM user is not allowed to give these agents work.")
    }
    private func tryAssignee(_ connection: NativeRPCValue, identity: String) async throws -> NativeRPCValue? {
        if identity == connection["hootIdentity"].string { return BackendTaskLocalService.assignment("hoot", kind: "hoot").setting("identity", .string(identity)) }
        if let id = connection["identities"][identity].string, try await config.agent(id) != nil { return BackendTaskLocalService.assignment(id, kind: "agent").setting("identity", .string(identity)) }; return nil
    }
    private func assignee(_ connection: NativeRPCValue, identity: String) async throws -> NativeRPCValue {
        guard let value = try await tryAssignee(connection, identity: identity) else { throw Failure("not_mine", "That assignee is not Hoot or one of the agents on this Terminal Deck.") }; return value
    }
    private func ownIdentity(_ connection: NativeRPCValue, identity: String) -> Bool { connection["hootIdentity"].string == identity || connection["identities"].has(identity) }
    public nonisolated static func folderAllowed(_ connection: NativeRPCValue, path: String) -> Bool {
        // task-config.ts folderAllowed: resolved first (so `allowed/../elsewhere` is judged where it really goes);
        // the folder itself or anything inside it, never a sibling that shares a prefix.
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let wanted = resolve(path)
        return (connection["folders"].elements?.compactMap(\.string) ?? []).contains { let base = resolve($0); return wanted == base || wanted.hasPrefix(base + "/") }
    }
    /// node:path resolve: lexical only (no symlinks), against the working folder when relative.
    private nonisolated static func resolve(_ path: String) -> String {
        var out: [Substring] = []
        for part in (path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path).split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }; if part == ".." { if !out.isEmpty { out.removeLast() }; continue }; out.append(part)
        }
        return "/" + out.joined(separator: "/")
    }
    private func record(_ id: String) async throws -> BackendTaskRecord { guard let task = try await store.byID(id) else { throw Failure("not_found", "There is no task \(id.split(separator: ":").dropFirst().joined(separator: ":")) here.") }; return task }
    private func outcome(_ name: String, task: BackendTaskRecord) async throws -> NativeRPCValue { fields([("outcome", .string(name)), ("task", try await snapshot(task))]) }
    private func required(_ input: NativeRPCValue, _ key: String, maximum: Int) throws -> String { try BackendTaskValues.text(input[key], key, max: maximum, required: true)! }
    private func optional(_ input: NativeRPCValue, _ key: String, maximum: Int) throws -> String? { if input[key].string == "" { return nil }; return try BackendTaskValues.text(input[key], key, max: maximum) }
    private func fields(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendTaskValues.object(pairs) }
    private struct Failure: Error { let code: String, message: String; init(_ code: String, _ message: String) { self.code = code; self.message = message } }
    private func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { waiters.append($0) } }
    private func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
}

public struct BackendTaskHTTPAnswer: Sendable { public let status: Int, body: NativeRPCValue }
public struct BackendTaskHTTP: Sendable {
    private let api: BackendTaskAPI
    private let authenticate: @Sendable (String?) async throws -> String?
    /// Register only behind the actual loopback no-Origin server policy.
    public init(api: BackendTaskAPI, authenticate: @escaping @Sendable (String?) async throws -> String?) { self.api = api; self.authenticate = authenticate }
    public func handle(method: String, path: String, authorization: String?, body: Data) async throws -> BackendTaskHTTPAnswer {
        guard let key = try await authenticate(authorization) else { return refused("unauthorized", "A valid access key is required.", status: 403) }
        let encoded = path.split(separator: "/", omittingEmptySubsequences: true), parts = encoded.compactMap { String($0).removingPercentEncoding }
        guard parts.count == encoded.count, parts.first == "tasks", parts.count <= 3 else { return refused("no_route", "There is no such task route.", status: 404) }
        var input = NativeRPCValue.object([])
        if method == "POST" {
            guard body.count <= 256 * 1024, let raw = body.isEmpty ? NativeRPCValue.object([]) : try? NativeRPCValue.parseJSON(body, maximumBytes: 256 * 1024), raw.fields != nil else { return refused("bad_request", "The body has to be a JSON object.", status: 400) }; input = raw
        }
        if parts.count >= 2 { input = input.setting("externalTaskId", .string(parts[1])) }
        let route = method + " " + (parts.count == 1 ? "" : parts.count == 2 ? ":id" : ":id/" + parts[2])
        let operations = ["POST ": "create", "GET :id": "get", "GET :id/result": "result", "POST :id/assign": "assign", "POST :id/cancel": "cancel", "POST :id/comments": "comment", "POST :id/status": "status"]
        guard let operation = operations[route] else { return refused("no_route", "There is no such task route.", status: 404) }
        let answer = try await api.call(operation, keyID: key, input: input)
        if answer.ok { return BackendTaskHTTPAnswer(status: 200, body: answer.value) }
        let statuses = ["disabled": 403, "not_allowed": 403, "folder_not_allowed": 403, "not_mine": 409, "too_many_hops": 409, "not_found": 404, "bad_request": 400]
        return refused(answer.code ?? "bad_request", answer.message ?? "The task request was refused.", status: statuses[answer.code ?? ""] ?? 400)
    }
    private func refused(_ code: String, _ message: String, status: Int) -> BackendTaskHTTPAnswer { BackendTaskHTTPAnswer(status: status, body: BackendTaskValues.object([("error", BackendTaskValues.object([("code", .string(code)), ("message", .string(message))]))])) }
}
