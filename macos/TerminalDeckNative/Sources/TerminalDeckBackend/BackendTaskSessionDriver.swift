import Foundation
import TerminalDeckNativeCore

public struct BackendTaskSessionAccess: Sendable {
    public let readiness: BackendLaunchReadiness
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
                              tellHoot: @escaping @Sendable (String) async throws -> Void) -> BackendTaskSessionAccess {
        let executor = BackendDevProcessExecutor()
        let deliver: @Sendable (String, String) async throws -> Void = { id, raw in
            var line = raw.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.utf16.count > 4_000 {
                guard specs.ownership == .exclusive, let session = manager.list().first(where: { $0.id == id }) else { throw BackendSessionFailure.missingCapability("the actual task reply/spec owner") }
                let name = "\(Int(BackendTaskValues.time()))-reply-\(UUID().uuidString.lowercased()).md"
                try specs.writeBytes(name, data: Data(("# Reply\n\nrepo: \(session.cwd)\n\n---\n\n\(raw)\n").utf8), replace: false)
                line = "A long reply came in on the task; read \(try specs.file(name).path)."
            }
            guard !line.isEmpty, line.utf16.count <= 4_000 else { throw NativeRPCError.invalidArguments("A delivery must be one printable line of at most 4000 characters") }
            try await authorize("sessions.send", BackendTaskValues.object([("sessionId", .string(id)), ("text", .string(line))]))
            try await BackendTaskBriefDelivery.deliver(id, line: line, manager: manager, write: { text in try await lifecycle.write(sessionID: id, data: text) })
            await noteTurn(id)
        }
        return BackendTaskSessionAccess(readiness: .ready, sessions: { manager.list() }, start: { task, agent, cwd, brief, resume in
            guard specs.ownership == .exclusive else { throw BackendSessionFailure.missingCapability("exclusive on-disk task brief storage") }
            guard (40...8_000).contains(brief.utf16.count) else { throw NativeRPCError.invalidArguments("A task worker's brief must be 40 to 8000 characters. The task record was kept; scope its instructions before starting it.") }
            try await authorize("sessions.start", BackendTaskValues.object([("cwd", .string(cwd)), ("provider", agent["provider"]), ("account", agent["account"]), ("brief", .string(brief)), ("task", .string(task.id))]))
            var input = BackendCreateSessionInput(cwd: cwd, provider: agent["provider"].string)
            input.profileId = agent["account"].string; input.resume = resume != nil; input.resumeConversationId = resume
            input.deniedTools = agent["blockedTools"].elements?.compactMap(\.string); input.noSkills = agent["skillsOff"].bool
            if ["claude", "codex"].contains(input.provider ?? ""), agent["instructionsFile"].string != nil { input.agentInstructions = agent["id"].string }
            input.origin = .copilot
            let filename = "\(Int(BackendTaskValues.time()))-\(UUID().uuidString.lowercased()).md"
            let body = "# \(task.value["title"].string ?? "Task")\n\nrepo: \(cwd)\nagent: \(input.provider ?? "the default")\nfrom-turn: \(task.id)\n\n---\n\n\(brief)\n"
            try specs.writeBytes(filename, data: Data(body.utf8), replace: false)
            let path = try specs.file(filename).path
            let session = try await lifecycle.create(input, holdOnFailure: false)
            if let id = task.value["externalTaskId"].string { try manager.rename(session.id, title: "crm-" + id) }
            do { try await deliver(session.id, "Read \(path) and do exactly what it says. That file is your whole brief — nothing else has been said to you, and nobody is going to add to it. Read it before you start.") }
            catch {
                // This driver owns only this newly created launch. A failed
                // delivery cannot leave an unclaimed task worker spending.
                try? await lifecycle.close(sessionID: session.id)
                throw NativeRPCError(code: "brief-not-delivered", message: "The new session was stopped because its brief was not delivered: \(error.localizedDescription). Its saved spec is at \(path).")
            }
            return manager.list().first { $0.id == session.id } ?? session
        }, send: deliver, stop: { id in
            try await authorize("sessions.stop", BackendTaskValues.object([("sessionId", .string(id))])); try await lifecycle.close(sessionID: id)
        }, setControl: { id, control, value in
            try await authorize("agents.set_control", BackendTaskValues.object([("sessionId", .string(id)), ("control", .string(control)), ("value", .string(value))])); try await setControl(id, control, value)
        }, check: { command, cwd in
            try await authorize("tasks.check", BackendTaskValues.object([("command", .string(command)), ("cwd", .string(cwd))]))
            let env = try await environment()
            let result = try await executor.run(command: "/bin/sh", arguments: ["-c", command], environment: env, cwd: cwd, timeoutMilliseconds: 600_000, maximumBytes: 4 * 1024 * 1024)
            return (result.ok, String((result.stdout + "\n" + result.stderr).suffix(1_500)))
        }, tellHoot: tellHoot)
    }
}

/// Exact Claude composer guards from agent-controls.ts and the brief's
/// text→observed echo→separate return protocol. Other providers remain unknown.
public enum BackendTaskBriefDelivery {
    public enum Composer: Sendable { case ready, typing(String), working, choosing(String), unknown }
    public static func composer(_ screen: String) -> Composer {
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let choice = lines.first(where: { $0.range(of: #"^[❯>]\s*\d+\.\s+\S"#, options: .regularExpression) != nil }) { return .choosing(choice) }
        let working = [#"esc to interrupt"#, #"\(\s*\d+s\s*·\s*[↑↓][^)]*\)"#, #"^(?![⏺⎿❯>│╭╰])\S\s+[A-Za-z][A-Za-z-]*…"#]
        if lines.contains(where: { line in working.contains { line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } }) { return .working }
        if let line = lines.reversed().first(where: { $0.hasPrefix("❯") || $0.hasPrefix(">") }) {
            let text = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines); return text.isEmpty ? .ready : .typing(text)
        }; return .unknown
    }
    public static func deliver(_ id: String, line: String, manager: BackendPTYManager, write: @escaping @Sendable (String) async throws -> Void) async throws {
        let surface = BackendTaskBriefSurface(manager: manager, write: write)
        let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: id, line: line,
            clock: BackendDeckCoreBriefClock(now: { BackendTaskValues.time() }, sleep: { try await BackendTaskClockContext.sleep(milliseconds: $0) }))
        guard result["delivered"].bool == true else { throw NativeRPCError(code: "brief-not-delivered", message: result["reason"].string ?? "Nothing was delivered.") }
    }
}

private struct BackendTaskBriefSurface: BackendDeckCoreBriefSurface, Sendable {
    let manager: BackendPTYManager
    let write: @Sendable (String) async throws -> Void
    func listSessions() -> [NativeRPCValue] { manager.list().compactMap { try? NativeRPCValue.parseJSON(JSONEncoder().encode($0)) } }
    func sessionScreen(id: String) async throws -> String? { manager.screen(id) }
    func writeToSession(id: String, data: String) async throws { try await write(data) }
}
