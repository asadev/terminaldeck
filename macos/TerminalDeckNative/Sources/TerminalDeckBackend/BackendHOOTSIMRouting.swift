import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// A bounded coordinator projection. The existing Hoot chat persists each row;
/// the existing task engine owns tasks, scheduling, starts, sends and results.
public actor BackendHOOTSIMRouting {
    public struct Dependencies: Sendable {
        public var require: @Sendable (BackendMCPCallContext) async throws -> Void
        public var conversationID: @Sendable () async throws -> String
        public var load: @Sendable () async throws -> [NativeRPCValue]
        public var append: @Sendable (NativeRPCValue) async throws -> Void
        public var resolve: @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> NativeRPCValue
        public var authorize: @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> Void
        public var dispatch: @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> NativeRPCValue
        /// How cards are routed (fixed by the app: ask, or notify in checks), read for every card and before an automatic send.
        public var policy: @Sendable () async -> HootPolicySnapshot
        /// "Do it and tell me": the send that runs after the Undo window, on the person's
        /// standing permission (no card answer). Nil means every card asks.
        public var autoDispatch: (@Sendable (NativeRPCValue) async throws -> NativeRPCValue)?
        /// Waits out the Undo window. Tests pass a fake clock.
        public var sleep: @Sendable (Double) async throws -> Void
        public var undoSeconds: Double
        public init(require: @escaping @Sendable (BackendMCPCallContext) async throws -> Void,
                    conversationID: @escaping @Sendable () async throws -> String,
                    load: @escaping @Sendable () async throws -> [NativeRPCValue],
                    append: @escaping @Sendable (NativeRPCValue) async throws -> Void,
                    resolve: @escaping @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> NativeRPCValue,
                    authorize: @escaping @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> Void,
                    dispatch: @escaping @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> NativeRPCValue,
                    policy: @escaping @Sendable () async -> HootPolicySnapshot = { HootPolicySnapshot() },
                    autoDispatch: (@Sendable (NativeRPCValue) async throws -> NativeRPCValue)? = nil,
                    sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .milliseconds(Int64($0 * 1000))) },
                    undoSeconds: Double = 10) {
            self.require = require; self.conversationID = conversationID; self.load = load; self.append = append; self.resolve = resolve
            self.authorize = authorize; self.dispatch = dispatch
            self.policy = policy; self.autoDispatch = autoDispatch; self.sleep = sleep; self.undoSeconds = undoSeconds
        }
    }
    public static let maximumRows = 32
    private let dependencies: Dependencies
    private var rows: [String: NativeRPCValue] = [:]
    private var order: [String] = []
    private var initialized = false
    private var chatID: String?
    private var loadGeneration = UUID()
    private var loading: Task<[NativeRPCValue], Error>?
    private var stopped = false
    /// One Undo window per automatic card; cancelled by Undo, stop or a chat change.
    private var timers: [String: Task<Void, Never>] = [:]
    public init(_ dependencies: Dependencies) { self.dependencies = dependencies }

    /// "Do it and tell me" sends by itself to an agent, a session or a task. Hoot may always run sessions and work
    /// in any folder (Asad, 12 Oct: the "What Hoot may do" switches are gone), so nothing else narrows it.
    public static func sendsWithoutAsking(_ target: NativeRPCValue, policy: HootPolicySnapshot) -> Bool {
        guard policy.routingMode == "notify" else { return false }
        return ["agent", "session", "task"].contains(target["kind"].string ?? "")
    }
    private static func failure(_ text: String, code: String = "routing-stale") -> NativeRPCError { .init(code: code, message: text) }
    private func require(_ caller: BackendMCPCallContext) async throws {
        guard !stopped, !caller.cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
        try await dependencies.require(caller)
        let current = try await dependencies.conversationID()
        guard !current.isEmpty else { throw Self.failure("Hoot's conversation is unavailable.") }
        if chatID != current {
            chatID = current; loadGeneration = UUID(); initialized = false; loading?.cancel(); loading = nil
            for timer in timers.values { timer.cancel() }; timers.removeAll()
            rows.removeAll(); order.removeAll()
        }
        guard !stopped, !caller.cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
    }
    private func initialize() async throws {
        if initialized { return }
        let expectedChatID = chatID, expectedGeneration = loadGeneration
        if loading == nil { loading = Task { [dependencies] in try await dependencies.load() } }
        let loader = loading!
        let values: [NativeRPCValue]
        do { values = try await loader.value }
        catch {
            // One failed chat read is not kept: the next routing call reads the chat again.
            if loading == loader { loading = nil }
            throw error
        }
        let currentChatID = try await dependencies.conversationID()
        guard !stopped, chatID == expectedChatID, currentChatID == expectedChatID,
              loadGeneration == expectedGeneration else { throw CancellationError() }
        guard !initialized else { return }
        for value in values {
            guard let id = value["id"].string, let revision = value["revision"].string,
                  UUID(uuidString: id) != nil, UUID(uuidString: revision) != nil else { continue }
            guard value["conversationId"].string == chatID else { continue }
            if rows[id] == nil { order.append(id) }
            var row = value
            // A crash can have happened after any mutation. Never replay it.
            if row["state"].string == "dispatching" { row = Self.state("uncertain", row) }
            if ["approving", "retargeting", "saving", "scheduled"].contains(row["state"].string ?? "") { row = Self.state("pending", row).removing("autoAt") }
            rows[id] = row
        }
        while order.count > Self.maximumRows {
            let settled = order.firstIndex { !["pending", "approving", "dispatching", "scheduled"].contains(rows[$0]?["state"].string ?? "") }
            rows[order.remove(at: settled ?? 0)] = nil
        }
        initialized = true; loading = nil
    }
    private static func state(_ state: String, _ row: NativeRPCValue) -> NativeRPCValue {
        row.setting("state", .string(state)).setting("status", .string(state))
    }
    private func room() throws {
        while order.count >= Self.maximumRows {
            guard let index = order.firstIndex(where: { !["saving", "retargeting", "pending", "approving", "dispatching", "scheduled"].contains(rows[$0]?["state"].string ?? "") }) else {
                throw Self.failure("There are 32 waiting routing cards. Dismiss one before making another.", code: "routing-full")
            }
            rows[order.remove(at: index)] = nil
        }
    }
    public func read(_ caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await require(caller); try await initialize(); try await require(caller)
        return .object([.init("proposals", .array(order.compactMap { rows[$0] }))])
    }
    public func propose(_ request: NativeRPCValue, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await require(caller); try await initialize()
        let problem = try request["problem"].requireString("problem", nonempty: true)
        guard problem.utf8.count <= 8000, request["source"].fields != nil,
              (request["candidates"].elements?.count ?? 0) <= 16,
              (request["attachments"].elements?.count ?? 0) <= 4,
              try request.encodedJSON().count <= 16_384 else {
            throw NativeRPCError.invalidArguments("Keep the problem and source short. Use references to up to four existing attachments.")
        }
        for attachment in request["attachments"].elements ?? [] {
            guard attachment.fields != nil, attachment["data"].isNullish, attachment["source"]["data"].isNullish else {
                throw NativeRPCError.invalidArguments("Routing reuses the chat's attachments. Do not copy image data into a routing card.")
            }
        }
        let resolved = try await dependencies.resolve(caller, request)
        try await require(caller); try room()
        let policy = await dependencies.policy()
        let automatic = dependencies.autoDispatch != nil && Self.sendsWithoutAsking(resolved["target"], policy: policy)
        var row = NativeRPCValue.object([.init("id", .string(UUID().uuidString.lowercased())),
            .init("revision", .string(UUID().uuidString.lowercased())), .init("state", .string("pending")), .init("status", .string("pending")),
            .init("conversationId", chatID.map(NativeRPCValue.string) ?? .null), .init("problem", .string(problem)),
            .init("request", request), .init("target", resolved["target"]), .init("reason", resolved["reason"]),
            .init("evidence", resolved["evidence"]), .init("source", resolved["source"]),
            .init("createdAt", .number(Date().timeIntervalSince1970)), .init("result", .null)])
        if automatic {
            row = Self.state("scheduled", row).setting("autoAt", .number(Date().timeIntervalSince1970 + dependencies.undoSeconds))
                .setting("undoSeconds", .number(dependencies.undoSeconds))
        }
        let id = row["id"].string!
        // Reserve capacity before the chat write's await. Failed writes remove
        // the reservation; no caller can dispatch an unpersisted row.
        rows[id] = row.setting("state", .string("saving")); order.append(id)
        do {
            try await dependencies.append(row); try await require(caller)
            guard rows[id] != nil else { throw Self.failure("Hoot's conversation changed while the card was saved.") }
            rows[id] = row
        } catch { rows[id] = nil; order.removeAll { $0 == id }; throw error }
        if automatic, let revision = row["revision"].string {
            timers[id] = Task { [weak self] in await self?.sendAfterUndoWindow(id, revision: revision) }
        }
        return row
    }
    /// The Undo window ran out: send on the person's standing permission, but
    /// only if the card is still waiting, the chat is the same and the switches
    /// still allow it. Otherwise the card falls back to asking.
    private func sendAfterUndoWindow(_ id: String, revision: String) async {
        do { try await dependencies.sleep(dependencies.undoSeconds) } catch { return }
        timers[id] = nil
        guard !stopped, !Task.isCancelled, let scheduled = rows[id], scheduled["revision"].string == revision,
              scheduled["state"].string == "scheduled", let send = dependencies.autoDispatch else { return }
        let sameChat = (try? await dependencies.conversationID()) == chatID
        let policy = await dependencies.policy()
        guard rows[id] == scheduled else { return } // Undone while the switches were read.
        guard sameChat, Self.sendsWithoutAsking(scheduled["target"], policy: policy) else {
            let asking = Self.state("pending", scheduled).removing("autoAt"); rows[id] = asking
            try? await dependencies.append(asking); return
        }
        let sending = Self.state("dispatching", scheduled); rows[id] = sending
        do { try await dependencies.append(sending) } catch {
            // Nothing was sent and the timer is gone: the card asks instead of waiting at "0 s" for ever.
            guard rows[id] == sending else { return }
            let asking = Self.state("pending", scheduled).removing("autoAt"); rows[id] = asking
            try? await dependencies.append(asking); return
        }
        guard rows[id] == sending, !stopped else { return }
        do {
            let result = try await send(scheduled)
            let sent = Self.state("sent", scheduled).setting("result", result).setting("taskId", result["taskId"]).setting("automatic", .bool(true))
            rows[id] = sent; try? await dependencies.append(sent)
        } catch {
            // After the send began, an error is an unknown outcome: never retry it.
            let next = Self.state("uncertain", scheduled).setting("error", .string(error.localizedDescription))
            rows[id] = next; try? await dependencies.append(next)
        }
    }
    public func retarget(_ id: String, revision: String, target: NativeRPCValue, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await require(caller); try await initialize()
        guard let row = rows[id], row["revision"].string == revision, row["state"].string == "pending" else {
            throw Self.failure("This routing card changed. Read it again before choosing someone else.")
        }
        let reservation = Self.state("retargeting", row); rows[id] = reservation
        do {
            let request = row["request"].setting("target", target)
            let resolved = try await dependencies.resolve(caller, request)
            try await require(caller)
            guard rows[id] == reservation else { throw Self.failure("The old card changed while its replacement was prepared.") }
            let next = Self.state("pending", row).setting("revision", .string(UUID().uuidString.lowercased()))
                .setting("request", request).setting("target", resolved["target"]).setting("source", resolved["source"])
                .setting("reason", resolved["reason"]).setting("evidence", resolved["evidence"])
            try await dependencies.append(next); try await require(caller)
            guard rows[id] == reservation else { throw Self.failure("The card changed while its replacement was saved.") }
            rows[id] = next
            return next
        } catch { if rows[id] == reservation { rows[id] = row }; throw error }
    }
    public func dismiss(_ id: String, revision: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await require(caller); try await initialize()
        guard let row = rows[id], row["revision"].string == revision,
              ["pending", "approving", "scheduled"].contains(row["state"].string ?? "") else { throw Self.failure("This card is already settled or sending.") }
        // Undo: the automatic send has not started, so nothing is sent.
        if row["state"].string == "scheduled" { timers[id]?.cancel(); timers[id] = nil }
        var next = Self.state("dismissed", row)
        if row["state"].string == "scheduled" { next = next.setting("undone", .bool(true)).removing("autoAt") }
        rows[id] = next
        do { try await dependencies.append(next) } catch { rows[id] = row; throw error }
        return next
    }
    public func dispatch(_ id: String, revision: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await require(caller); try await initialize()
        guard let before = rows[id], before["revision"].string == revision else { throw Self.failure("Read the current routing card before sending it.") }
        // Double clicks, duplicate MCP requests and restart replay never send twice.
        guard before["state"].string == "pending" else { return before }
        let approving = Self.state("approving", before); rows[id] = approving
        do {
            try await dependencies.append(approving)
            try await dependencies.authorize(caller, before)
            try await require(caller)
            guard rows[id] == approving else { throw Self.failure("This card was dismissed or replaced while approval was waiting.") }
            let current = try await dependencies.resolve(caller, before["request"])
            try await require(caller)
            guard current["target"] == before["target"], current["source"] == before["source"],
                  current["evidence"] == before["evidence"], current["reason"] == before["reason"], rows[id] == approving else {
                throw Self.failure("The target, project or ownership changed. Ask Hoot for a new routing card.")
            }
            let sending = Self.state("dispatching", before); rows[id] = sending
            try await dependencies.append(sending)
            try await require(caller)
            guard rows[id] == sending else { throw Self.failure("The routing card changed before sending.") }
            let result = try await dependencies.dispatch(caller, before)
            let sent = Self.state("sent", before).setting("result", result).setting("taskId", result["taskId"])
            rows[id] = sent
            // It was delivered: a failed chat note never reports it as failed or "uncertain" (that invites a second send).
            // The card stays "sent" here; after a restart an unsaved one reads "uncertain", never as unsent.
            try? await dependencies.append(sent)
            return sent
        } catch {
            guard let row = rows[id], row["revision"].string == revision else { throw error }
            let wasSending = row["state"].string == "dispatching"
            if row["state"].string == "approving" || wasSending {
                // After dispatch begins, an error is an unknown outcome: do not retry.
                let next = Self.state(wasSending ? "uncertain" : "pending", before)
                    .setting("error", .string(error.localizedDescription))
                rows[id] = next; try? await dependencies.append(next)
            }
            throw error
        }
    }
    /// Called only after the existing tasks:changed reader returns current
    /// owner-visible rows. New Hoot-requested tasks keep the engine's own report
    /// path. Reused tasks get a bounded projection, never a second scheduler.
    public func observeTaskOutcomes(_ tasks: [NativeRPCValue], conversationID: String) async throws {
        guard !stopped, initialized, chatID == conversationID,
              try await dependencies.conversationID() == conversationID else { return }
        for id in order {
            guard let row = rows[id], row["state"].string == "sent", let taskID = row["result"]["taskId"].string,
                  let task = tasks.first(where: { $0["id"].string == taskID }), task["requestedBy"].string != "hoot",
                  let at = task["result"]["at"].number, at.isFinite,
                  at >= (task["runStartedAt"].number ?? 0), let turn = task["lastTurn"].string, !turn.isEmpty,
                  let answer = task["result"]["answer"].string, !answer.isEmpty else { continue }
            let outcome = NativeRPCValue.object([.init("taskId", .string(taskID)), .init("turn", .string(turn)), .init("result", task["result"])])
            let revision = SHA256.hash(data: try outcome.encodedJSON()).map { String(format: "%02x", $0) }.joined()
            guard row["reportedOutcome"].string != revision else { continue }
            let verified = task["result"]["verified"].bool == true && task["verified"].bool == true
            let title = task["title"].string ?? taskID
            let text = (verified ? "Finished and verified: " : "Finished; needs review: ") + title + ". " + String(answer.prefix(1200))
            let report = NativeRPCValue.object([.init("taskId", .string(taskID)), .init("outcomeRevision", .string(revision)),
                .init("verified", .bool(verified)), .init("text", .string(text))])
            let next = row.setting("report", report).setting("reportedOutcome", .string(revision))
            rows[id] = next // Reserve the dedupe token across the chat-write await.
            do { try await dependencies.append(next) }
            catch { if rows[id] == next { rows[id] = row }; throw error }
        }
    }
    public func stop() {
        stopped = true; loading?.cancel(); loading = nil
        for timer in timers.values { timer.cancel() }; timers.removeAll()
    }
}

/// Resolve ids against current owners. Names and ownership prose supplied by a
/// model never become authority. A tie produces a task-only card.
public enum BackendHOOTSIMRoutingResolver {
    public static func resolve(_ request: NativeRPCValue, projects: [PROJProject], openFolders: [String], agents: [NativeRPCValue], sessions: [NativeRPCValue], tasks: [NativeRPCValue] = []) throws -> NativeRPCValue {
        let source = request["source"]
        let sourceSession = source["sessionId"].string.flatMap { wanted in
            sessions.first { $0["id"].string == wanted && $0["exitCode"] == .null && $0["status"].string != "exited" }
        }
        let folder = source["folder"].string ?? sourceSession?["cwd"].string ?? ""
        let opened = openFolders.map(PROJProjects.normalize)
        func isOpen(_ folder: String) -> Bool {
            let path = PROJProjects.normalize(folder)
            return !path.isEmpty && opened.contains { root in path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
        }
        if !folder.isEmpty && !isOpen(folder) { throw NativeRPCError(code: "routing-project-closed", message: "Open the source project before handing this problem to an agent or session.") }
        let projectID = PROJProjects.resolve(projectID: source["projectId"].string, folder: folder, projects: projects)
        guard let project = projects.first(where: { $0.id == projectID }) else { throw NativeRPCError.invalidArguments("The source project no longer exists.") }
        if !folder.isEmpty && projectID != PROJProjects.independentID,
           PROJProjects.resolve(projectID: nil, folder: folder, projects: projects) != projectID {
            throw NativeRPCError.invalidArguments("The source folder belongs to a different project.")
        }
        let currentProjectFolders = project.folders.filter(isOpen)
        let fallbackFolder = currentProjectFolders.count == 1 ? currentProjectFolders[0] : ""
        if folder.isEmpty && !project.folders.isEmpty && currentProjectFolders.isEmpty {
            throw NativeRPCError(code: "routing-project-closed", message: "Open " + project.name + " before handing this problem to an agent or session.")
        }
        let candidates = request["candidates"].elements ?? []
        func allowed(_ kind: String, _ id: String) -> Bool {
            candidates.isEmpty || candidates.contains { $0["kind"].string == kind && $0["id"].string == id }
        }
        let problem = request["problem"].string?.lowercased() ?? "", file = source["file"].string ?? ""
        if !file.isEmpty, BackendHOOTSIMOwnership.scopedFile(file, sourceFolder: folder.isEmpty ? fallbackFolder : folder) == nil {
            throw NativeRPCError.invalidArguments("Choose the exact open source folder and a file inside it before routing this problem.")
        }
        var ranked: [(Int, NativeRPCValue, String)] = []
        var fileOwners = 0, contradictoryFileScope = false
        for agent in agents {
            guard let id = agent["id"].string, allowed("agent", id), !["paused", "archived"].contains(agent["status"].string ?? ""),
                  PROJProjects.resolve(projectID: agent["projectId"].string, folder: agent["defaultProject"].string, projects: projects) == projectID else { continue }
            let configuredFolder = agent["defaultProject"].string ?? ""
            if !configuredFolder.isEmpty && !isOpen(configuredFolder) { continue }
            let executionFolder = !folder.isEmpty ? folder : !configuredFolder.isEmpty ? configuredFolder : fallbackFolder
            guard isOpen(executionFolder) else { continue }
            let role = agent["role"].string ?? agent["description"].string ?? ""
            let instructions = agent["instructions"].string ?? ""
            let ownership = file.isEmpty ? .unknown : BackendHOOTSIMOwnership.claim(instructions: instructions, file: file,
                sourceFolder: folder.isEmpty ? executionFolder : folder,
                ownerFolder: configuredFolder.isEmpty ? executionFolder : configuredFolder)
            if ownership == .contradictory { contradictoryFileScope = true; continue }
            if ownership == .excludes { continue }
            let namesFile = ownership == .owns
            if namesFile { fileOwners += 1 }
            let words = role.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 5 }
            let matches = words.filter { problem.contains($0) }.count
            let evidenceScore = namesFile ? 100 : file.isEmpty ? matches * 3 : 0
            let busy = tasks.contains { task in
                (task["assignee"].string ?? task["assignee"]["agentId"].string) == id && ["running", "working", "checking", "waiting"].contains(task["process"].string ?? "")
            }
            let score = namesFile ? 201 : evidenceScore == 0 ? 0 : evidenceScore * 2 + (busy ? 0 : 1)
            let facts = NativeRPCValue.object([.init("id", .string(id)), .init("kind", .string("agent")),
                .init("name", agent["name"]), .init("icon", agent["icon"]), .init("projectId", .string(projectID)), .init("folder", .string(executionFolder)),
                .init("role", .string(role)), .init("available", .bool(!busy)), .init("projectName", .string(project.name)), .init("revision", .string(digest(agent))), .init("provider", agent["provider"]), .init("account", agent["account"])])
            ranked.append((score, facts, namesFile ? "Its current instructions explicitly own " + file + "." : file.isEmpty && matches > 0 ? "Its current role matches this problem." : "The selected current profile belongs to " + project.name + "; file ownership is unconfirmed."))
        }
        for session in sessions {
            guard let id = session["id"].string, allowed("session", id) || id == source["sessionId"].string,
                  session["exitCode"] == .null, session["status"].string != "exited",
                  let sessionFolder = session["cwd"].string, isOpen(sessionFolder),
                  PROJProjects.resolve(projectID: session["projectId"].string, folder: session["cwd"].string, projects: projects) == projectID else { continue }
            let facts = NativeRPCValue.object([.init("id", .string(id)), .init("kind", .string("session")),
                .init("name", session["title"]), .init("role", .string("Running session")), .init("projectName", .string(project.name)), .init("projectId", .string(projectID)), .init("folder", session["cwd"]),
                .init("revision", .string(digest(.object([.init("id", .string(id)), .init("createdAt", session["createdAt"]), .init("cwd", session["cwd"]), .init("provider", session["provider"])]))))])
            let capturedHere = id == source["sessionId"].string
            ranked.append((capturedHere && file.isEmpty ? 1000 : 0, facts, capturedHere
                ? "This capture came from this exact current session in " + project.name + "."
                : "A current running session in " + project.name + "."))
        }
        let selected = request["target"]
        let chosen: (Int, NativeRPCValue, String)?
        if selected["kind"].string == "task" || (!file.isEmpty && (contradictoryFileScope || fileOwners > 1)) { chosen = nil }
        else if !selected.isNullish {
            guard let match = ranked.first(where: { $0.1["kind"] == selected["kind"] && $0.1["id"] == selected["id"] }) else {
                throw NativeRPCError(code: "routing-stale", message: "That target is no longer available in the source project.")
            }
            chosen = match
        } else {
            let best = ranked.map(\.0).max() ?? 0, matches = ranked.filter { $0.0 == best }
            chosen = best > 0 && matches.count == 1 ? matches[0] : nil
        }
        let taskOnly = NativeRPCValue.object([.init("kind", .string("task")), .init("id", .string("task")),
            .init("name", .string("Make a task only")), .init("role", .string("Waiting for assignment")), .init("projectName", .string(project.name)), .init("projectId", .string(projectID)), .init("folder", .string(folder.isEmpty ? fallbackFolder : folder)),
            .init("revision", .string(digest(project.wireValue)))])
        return .object([.init("target", chosen?.1 ?? taskOnly), .init("source", source.setting("projectId", .string(projectID))),
            .init("reason", .string(chosen?.2 ?? "No single current target fits. Make a task for you to assign.")),
            .init("evidence", .array([.string("Project: " + project.name), .string(chosen?.2 ?? "No unique current target match.")]))])
    }
    private static func digest(_ value: NativeRPCValue) -> String {
        SHA256.hash(data: (try? value.encodedJSON()) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}
