import Foundation
import TerminalDeckNativeCore

public struct BackendTaskSessionAccess: Sendable {
    public let readiness: BackendLaunchReadiness
    public var freshJobChats: Bool = false
    /// Trusted owners only: true means they revalidate BackendPCDecisionDelivery
    /// after their internal waits at the final start/send boundary.
    public var decisionSafeStart = false
    public var decisionSafeSend = false
    public var activate: @Sendable (String) async -> Void = { _ in }
    public let sessions: @Sendable () async -> [BackendSessionMeta]
    public let start: @Sendable (BackendTaskRecord, NativeRPCValue, String, String, String?) async throws -> BackendSessionMeta
    public let send: @Sendable (String, String) async throws -> Void
    public let stop: @Sendable (String) async throws -> Void
    public let setControl: @Sendable (String, String, String) async throws -> Void
    public let check: @Sendable (String, String) async throws -> (ok: Bool, output: String)
    public let tellHoot: @Sendable (String) async throws -> Void
    public init(readiness: BackendLaunchReadiness, sessions: @escaping @Sendable () async -> [BackendSessionMeta],
                start: @escaping @Sendable (BackendTaskRecord, NativeRPCValue, String, String, String?) async throws -> BackendSessionMeta,
                send: @escaping @Sendable (String, String) async throws -> Void, stop: @escaping @Sendable (String) async throws -> Void,
                setControl: @escaping @Sendable (String, String, String) async throws -> Void,
                check: @escaping @Sendable (String, String) async throws -> (ok: Bool, output: String), tellHoot: @escaping @Sendable (String) async throws -> Void) {
        self.readiness = readiness; self.sessions = sessions; self.start = start; self.send = send; self.stop = stop
        self.setControl = setControl; self.check = check; self.tellHoot = tellHoot
    }
}

/// Actual native start/write/close operations reuse the sole lifecycle owner.
/// Authorization is required before each operation; that callback belongs to
/// the real consent/action-log dispatcher, never an always-allow fallback.
public enum BackendTaskSessionDriver {
    public typealias Gate = @Sendable (String, NativeRPCValue) async throws -> Void
    public static func access(lifecycle: BackendSessionLifecycleCoordinator, manager: BackendPTYManager, specs: BackendTaskPersistence,
                              authorize: @escaping Gate, environment: @escaping @Sendable () async throws -> [String: String],
                              setControl: @escaping @Sendable (String, String, String) async throws -> Void,
                              noteTurn: @escaping @Sendable (String) async -> Void,
                              tellHoot: @escaping @Sendable (String) async throws -> Void,
                              bindTaskSession: (@Sendable (BackendTaskRecord, BackendSessionMeta) async throws -> Void)? = nil,
                              usageBaseline: (@Sendable (BackendTaskRecord, BackendSessionMeta) async throws -> Void)? = nil,
                              chats: BackendSessionChats? = nil,
                              sender: @escaping @Sendable (BackendTaskRecord) async -> BackendTeamChatSender = { BackendTeamChatSender.request($0.value["requestedBy"].string ?? "hoot") }) -> BackendTaskSessionAccess {
        let executor = BackendDevProcessExecutor()
        let deliver: @Sendable (String, String) async throws -> Void = { id, raw in
            if let chats, manager.isChat(id) {
                try await authorize("sessions.send", BackendTaskValues.object([("sessionId", .string(id)), ("text", .string(raw))]))
                try await BackendPCDecisionDelivery.verify()
                _ = try await chats.say(id, text: raw)
                await noteTurn(id)
                return
            }
            var line = raw.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            // FORK-TASKS (11 Oct, real app): long text is never typed into a CLI's prompt. A brief of a few thousand
            // characters typed into a reused session arrived as its tail only, and the agent answered its previous
            // task again. Anything longer than one short line goes whole into a file and one line points at it,
            // the way a new worker has always been given its brief.
            if line.utf16.count > BackendTaskTypedBriefs.inlineLimit {
                guard specs.ownership == .exclusive, let session = manager.list().first(where: { $0.id == id }) else { throw BackendSessionFailure.missingCapability("the actual task reply/spec owner") }
                let name = "\(Int(BackendTaskValues.time()))-reply-\(UUID().uuidString.lowercased()).md"
                try specs.writeBytes(name, data: Data(("# New text on your task\n\nrepo: \(session.cwd)\n\n---\n\n\(raw)\n").utf8), replace: false)
                line = BackendTaskTypedBriefs.pointerLine(try specs.file(name).path)
            }
            guard !line.isEmpty, line.utf16.count <= 4_000 else { throw NativeRPCError.invalidArguments("A delivery must be one printable line of at most 4000 characters") }
            try await authorize("sessions.send", BackendTaskValues.object([("sessionId", .string(id)), ("text", .string(line))]))
            try await BackendPCDecisionDelivery.verify()
            try await BackendTaskBriefDelivery.deliver(id, line: line, manager: manager, write: { text in try await lifecycle.write(sessionID: id, data: text) })
            await noteTurn(id)
        }
        var access = BackendTaskSessionAccess(readiness: .ready, sessions: { manager.list() }, start: { task, agent, cwd, brief, resume in
            try await BackendPCDecisionDelivery.verify(required: PCDecisions.requires(task.value))
            guard specs.ownership == .exclusive else { throw BackendSessionFailure.missingCapability("exclusive on-disk task brief storage") }
            guard (40...8_000).contains(brief.utf16.count) else { throw NativeRPCError.invalidArguments("A task worker's brief must be 40 to 8000 characters. The task record was kept; scope its instructions before starting it.") }
            try await authorize("sessions.start", BackendTaskValues.object([("cwd", .string(cwd)), ("provider", agent["provider"]), ("account", agent["account"]), ("brief", .string(brief)), ("task", .string(task.id))]))
            var input = chats != nil
                ? try BackendAgentSessionInput.make(agent: agent, folder: cwd, projectID: task.value["projectId"].string, chat: true)
                : BackendCreateSessionInput(cwd: cwd, provider: agent["provider"].string)
            input.model = task.value["model"].string ?? agent["model"].string
            if !agent["agoptSettings"].isNullish {
                input.agentSettings = try BackendAGSCodec.decode(AGSAgentSettings.self, agent["agoptSettings"])
            }
            input.profileId = agent["account"].string; input.resume = resume != nil; input.resumeConversationId = resume
            input.deniedTools = agent["blockedTools"].elements?.compactMap(\.string); input.noSkills = (input.agentSettings?.provider ?? input.provider) == "claude" ? (input.agentSettings?.efficiency?.addonsOff == true ? true : agent["skillsOff"].bool) : nil
            input.claudeAgent = agent["claudeAgent"].string
            input.allowedTools = agent["allowedTools"].elements?.compactMap(\.string)
            input.permissionMode = agent["permissionMode"].string
            input.taskID = task.id
            input.taskProject = task.project.isEmpty ? nil : task.project
            input.projectId = task.value["projectId"].string ?? agent["projectId"].string
            input.agentDefinitionsFile = try BackendTAGAgentDefinitionLaunch.prepare(agent: agent, specs: specs)
            if input.claudeAgent != nil { input.provider = "claude" }
            if input.claudeAgent == nil, ["claude", "codex"].contains(input.provider ?? ""), agent["instructionsFile"].string != nil { input.agentInstructions = agent["id"].string }
            input.origin = .copilot
            if chats != nil {
                input.chat = true
                input.resume = false; input.resumeConversationId = nil
                input.agentProfileID = agent["id"].string
                let from = await sender(task)
                input.teamJob = BackendTeamChatJob(fromID: from.id, fromName: from.name, agentID: agent["id"].string ?? task.agentID,
                    agentName: agent["name"].string ?? task.agentID, title: task.value["title"].string ?? "Task", taskID: task.id)
            }
            let filename = "\(Int(BackendTaskValues.time()))-\(UUID().uuidString.lowercased()).md"
            let body = BackendTaskTypedBriefs.fileBody(title: task.value["title"].string, folder: cwd, provider: input.provider, taskID: task.id, brief: brief)
            try specs.writeBytes(filename, data: Data(body.utf8), replace: false)
            let path = try specs.file(filename).path
            try await BackendPCDecisionDelivery.verify(required: PCDecisions.requires(task.value))
            let session = try await lifecycle.create(input, holdOnFailure: false)
            do {
                // Root's store owner binds the exact original assignment before
                // the first brief can make a worker call its task tools.
                try await bindTaskSession?(task, session)
                try await usageBaseline?(task, manager.list().first { $0.id == session.id } ?? session)
                if chats != nil { try await deliver(session.id, brief) }
                else {
                if let id = task.value["externalTaskId"].string { try manager.rename(session.id, title: "crm-" + id) }
                try await deliver(session.id, "Read \(path) and do exactly what it says. That file is your whole brief — nothing else has been said to you, and nobody is going to add to it. Read it before you start.")
                }
            }
            catch {
                if let chats {
                    try? await chats.finishJob(session.id, result: "The brief could not be delivered: " + error.localizedDescription, failed: true)
                    try? await lifecycle.close(sessionID: session.id)
                    _ = try? await chats.openJobHistory(session.id)
                    throw error
                }
                // FORK-TASKS (c): Claude Code's own setup screen is not a failed delivery. The session stays, bound to
                // its task; the engine types this brief's line itself once the prompt is there.
                if let setup = error as? NativeRPCError, setup.code == "setup-needed" {
                    throw NativeRPCError(code: "setup-needed", message: setup.message, details: .object([.init("briefFile", .string(path)), .init("sessionId", .string(session.id))]))
                }
                // L8 (10 Oct): never kill the worker over a delivery doubt. It stays open (idle, it was told
                // nothing) so the person or Hoot can see it and send the brief; the reason goes on the task.
                // (The reason already ends its own sentence: it used to be followed by a second full stop.)
                let why = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NativeRPCError(code: "brief-not-delivered", message: "The brief was not delivered: \(why.hasSuffix(".") ? String(why.dropLast()) : why). The session was left open so you can see it; send it \"Read \(path) and do exactly what it says.\" to start it, or close it.")
            }
            return manager.list().first { $0.id == session.id } ?? session
        }, send: deliver, stop: { id in
            try await authorize("sessions.stop", BackendTaskValues.object([("sessionId", .string(id))]))
            if let chats, manager.isChat(id) { try await chats.finishJob(id, result: "Task closed", failed: true) }
            try await lifecycle.close(sessionID: id)
            if let chats { _ = try? await chats.openJobHistory(id) }
        }, setControl: { id, control, value in
            try await authorize("agents.set_control", BackendTaskValues.object([("sessionId", .string(id)), ("control", .string(control)), ("value", .string(value))])); try await setControl(id, control, value)
        }, check: { command, cwd in
            try await authorize("tasks.check", BackendTaskValues.object([("command", .string(command)), ("cwd", .string(cwd))]))
            let env = try await environment()
            let result = try await executor.run(command: "/bin/sh", arguments: ["-c", command], environment: env, cwd: cwd, timeoutMilliseconds: 600_000, maximumBytes: 4 * 1024 * 1024)
            return (result.ok, String((result.stdout + "\n" + result.stderr).suffix(1_500)))
        }, tellHoot: tellHoot)
        access.freshJobChats = chats != nil
        access.activate = { id in await chats?.activateTaskJob(id) }
        return access
    }
}

/// CLI composer guards and the brief's
/// text→observed echo→separate return protocol for Claude, Codex and Gemini.
public enum BackendTaskBriefDelivery {
    public enum Composer: Sendable { case ready, typing(String), working, choosing(String), unknown }
    /// L8 (10 Oct): the real Claude Code screen leaves NUL cells where it skipped spaces and draws its input
    /// inside a box. Read it as a person would: NUL → space, box sides dropped, runs of spaces collapsed.
    public static func normalizedRows(_ screen: String) -> [String] {
        screen.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: .newlines).map { row in
            var text = row.trimmingCharacters(in: .whitespaces)
            while let first = text.first, "│┃|".contains(first) { text.removeFirst(); text = text.trimmingCharacters(in: .whitespaces) }
            while let last = text.last, "│┃|".contains(last) { text.removeLast(); text = text.trimmingCharacters(in: .whitespaces) }
            return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
    }
    static func isRule(_ row: String) -> Bool { row.range(of: #"^[─━═╭╮╰╯┌┐└┘\-]{3,}$"#, options: .regularExpression) != nil }
    static func hasPromptPrefix(_ row: String) -> Bool {
        row.hasPrefix("❯") || row.hasPrefix("›") || row.hasPrefix(">") || row == "*" || row.hasPrefix("* ")
    }
    /// The whole text in the prompt, its wrapped rows joined (Claude wraps long input onto indented rows).
    public static func promptText(_ screen: String) -> String? {
        let rows = normalizedRows(screen)
        guard let start = rows.lastIndex(where: { hasPromptPrefix($0) }) else { return nil }
        var parts = [String(rows[start].dropFirst()).trimmingCharacters(in: .whitespaces)]
        for row in rows[(start + 1)...] {
            if row.isEmpty || isRule(row) || row.hasPrefix("?") || row.hasPrefix("⏵") { break }
            parts.append(row)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func composer(_ screen: String) -> Composer {
        let lines = normalizedRows(screen).filter { !$0.isEmpty }
        if let choice = lines.first(where: { $0.range(of: #"^[❯›>]\s*\d+\.\s+\S"#, options: .regularExpression) != nil }) { return .choosing(choice) }
        let working = [#"esc to interrupt"#, #"\(\s*\d+s\s*·\s*[↑↓][^)]*\)"#, #"^(?![⏺⎿❯›>*│╭╰])\S\s+[A-Za-z][A-Za-z-]*…"#]
        if lines.contains(where: { line in working.contains { line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } }) { return .working }
        if let text = promptText(screen) {
            // Claude's dimmed example in an empty prompt is not typed text (L8, 10 Oct).
            return text.isEmpty || BackendSessionClassifier.isEmptyPromptHint(text) ? .ready : .typing(text)
        }; return .unknown
    }
    /// FORK-TASKS (11 Oct, real app): Claude Code's own screens that come before its prompt (first run,
    /// sign-in, folder trust), by the words only those screens show. A task used to fail on them after two
    /// minutes with "There is unsent text at this session's prompt (“✔ Dark mode Light mode …”) … clear the
    /// prompt and pick again", which was neither true nor useful. nil for any other screen. Asked only when
    /// the prompt is NOT empty and ready, so these words in a conversation never stop a delivery.
    public static func setupScreen(_ screen: String) -> String? {
        let text = normalizedRows(screen).joined(separator: " ").lowercased().replacingOccurrences(of: "’", with: "'")
        func shows(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if shows("choose the text style that looks best with your terminal", "to change this later, run /theme") {
            return "Claude Code is showing its first-run setup in this session. Open the session and finish it once."
        }
        if shows("select login method", "paste code here if prompted", "browser didn't open? use the url below to sign in") {
            return "Claude Code is asking to sign in in this session. Open the session and sign in."
        }
        if shows("do you trust the files in this folder", "do you trust the contents of this directory") {
            return text.contains("do you trust the files in this folder")
                ? "Claude Code is asking whether to trust this folder. Open the session and answer it."
                : "Codex is asking whether to trust this folder. Open the session and answer it."
        }
        return nil
    }
    /// Whether what the prompt shows is (the start of) `line`, compared as normalized words.
    public static func echoes(_ shown: String, line: String) -> Bool {
        let a = shown.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let b = line.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard a.count >= min(30, b.count) else { return false }
        return b.hasPrefix(a) || a.hasPrefix(b) || b.hasPrefix(String(a.prefix(60)))
    }
    /// After Return was pressed without the typed text having been seen: the CLI took the message when it
    /// is working, or when the line now stands ABOVE the prompt (it moved into the conversation).
    public static func taken(_ screen: String, line: String) -> Bool {
        if case .working = composer(screen) { return true }
        let rows = normalizedRows(screen)
        guard let prompt = rows.lastIndex(where: { hasPromptPrefix($0) }) else { return false }
        let above = rows[..<prompt].joined().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let wanted = line.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return wanted.count >= 12 && above.contains(String(wanted.prefix(30)))
    }
    /// True: the message was seen on screen (delivered). False: it was sent (Return pressed) without being
    /// seen; the session goes on, and whoever reports it says "sent", not "delivered". Throws only when
    /// nothing was sent.
    @discardableResult
    public static func deliver(_ id: String, line: String, manager: BackendPTYManager, write: @escaping @Sendable (String) async throws -> Void) async throws -> Bool {
        let surface = BackendTaskBriefSurface(manager: manager, write: write)
        let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: id, line: line,
            clock: BackendDeckCoreBriefClock(now: { BackendTaskValues.time() }, sleep: { try await BackendTaskClockContext.sleep(milliseconds: $0) }))
        if result["delivered"].bool == true { return true }
        if result["setup"].bool == true { throw NativeRPCError(code: "setup-needed", message: result["reason"].string ?? "Claude Code is showing a setup screen in this session.") }
        guard result["sent"].bool == true else { throw NativeRPCError(code: "brief-not-delivered", message: result["reason"].string ?? "Nothing was delivered.") }
        return false
    }
}

private struct BackendTaskBriefSurface: BackendDeckCoreBriefSurface, Sendable {
    let manager: BackendPTYManager
    let write: @Sendable (String) async throws -> Void
    func listSessions() -> [NativeRPCValue] { manager.list().compactMap { try? NativeRPCValue.parseJSON(JSONEncoder().encode($0)) } }
    func session(id: String) -> NativeRPCValue? { manager.list().first { $0.id == id }.flatMap { try? NativeRPCValue.parseJSON(JSONEncoder().encode($0)) } }
    func sessionScreen(id: String) async throws -> String? { manager.screen(id) }
    func writeToSession(id: String, data: String) async throws {
        try await BackendPCDecisionDelivery.verify()
        try await write(data)
    }
}
