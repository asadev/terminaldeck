import Foundation
import TerminalDeckNativeCore

/// Where the Receiver hands events, and how replies leave. One seam, so the
/// routing service is tested with a fake and production uses the real task,
/// session and GitHub services (`BackendRCVProductionDispatch`).
public protocol BackendRCVDispatching: Sendable {
    /// A new task for a task agent id, or for "hoot". Returns the task id.
    func createTask(assignee: String, title: String, instructions: String, project: String) async throws -> String
    /// Stable ownership is separate from the folder used to run the task.
    func createTask(assignee: String, title: String, instructions: String, project: String, projectId: String?) async throws -> String
    /// A follow-up message into an ongoing task. Throws when no agent is waiting on it any more.
    func continueTask(_ taskID: String, text: String) async throws
    /// Type into a running AI session. Implementations refuse anything that is not an AI session.
    func typeIntoSession(_ sessionID: String, text: String) async throws
    /// A short status for the flow ("Working", "Done: …"), or nil when unknown.
    func taskOutcome(_ taskID: String) async -> String?
    func agents() async -> [RCVChoice]
    func sessions() async -> [RCVChoice]
    /// Comment on an issue or pull request with the owner's existing GitHub sign-in.
    func githubComment(repository: String, number: Int, body: String) async throws
    /// Send one reply request. Returns the status code.
    func send(_ request: URLRequest) async throws -> Int
    // Requirements (with defaults below) so the production dispatch's own versions are the ones called.
    func createTask(assignee: String, title: String, instructions: String, project: String, projectId: String?, fields: RCVTaskFields) async throws -> String
    func updateTaskFields(_ taskID: String, fields: RCVTaskFields, source: String) async
    func taskSnapshot(_ taskID: String) async -> RCVTaskSnapshot?
}

/// Older dispatch fakes/implementations keep their existing task entry point.
public extension BackendRCVDispatching {
    func createTask(assignee: String, title: String, instructions: String, project: String, projectId: String?) async throws -> String {
        try await createTask(assignee: assignee, title: title, instructions: instructions, project: project)
    }
    /// A new task carrying the event's task fields (status, priority, dates, tags …) and its named
    /// custom fields. Implementations without fields make the plain task.
    func createTask(assignee: String, title: String, instructions: String, project: String, projectId: String?, fields: RCVTaskFields) async throws -> String {
        try await createTask(assignee: assignee, title: title, instructions: instructions, project: project, projectId: projectId)
    }
    /// A later event of the same conversation: its task fields follow. Best effort; never fails a delivery.
    func updateTaskFields(_ taskID: String, fields: RCVTaskFields, source: String) async {}
    /// What a task holds now, for "Check connection". Nil when it is gone or unknown.
    func taskSnapshot(_ taskID: String) async -> RCVTaskSnapshot? { nil }
}

/// The production seam, assembled by the app's composition (see RCV.md "For INT2").
public struct BackendRCVProductionDispatch: BackendRCVDispatching {
    public let tasks: BackendTaskLocalService
    public let configuration: BackendTaskConfiguration
    /// Folder used for Hoot's tasks when a rule names none.
    public let defaultProject: @Sendable () async -> String
    /// Running sessions that are AI agents (never plain shells), id and display name.
    public let aiSessions: @Sendable () async -> [RCVChoice]
    /// Write text into a session's input (the lifecycle's `write(sessionID:data:)`).
    public let write: @Sendable (String, String) async throws -> Void
    /// Resolved per reply: the GitHub workspace is assembled after the Receiver starts.
    public let github: @Sendable () async -> (any BackendGHWorkspaceServing)?
    /// The person's registered projects: a task made with no project named is filed by its folder among these.
    public let projects: @Sendable () async -> [PROJProject]

    public init(tasks: BackendTaskLocalService, configuration: BackendTaskConfiguration, defaultProject: @escaping @Sendable () async -> String,
                aiSessions: @escaping @Sendable () async -> [RCVChoice], write: @escaping @Sendable (String, String) async throws -> Void,
                github: @escaping @Sendable () async -> (any BackendGHWorkspaceServing)?,
                projects: @escaping @Sendable () async -> [PROJProject] = { [] }) {
        self.tasks = tasks; self.configuration = configuration; self.defaultProject = defaultProject
        self.aiSessions = aiSessions; self.write = write; self.github = github; self.projects = projects
    }

    public func createTask(assignee: String, title: String, instructions: String, project: String) async throws -> String {
        try await createTask(assignee: assignee, title: title, instructions: instructions, project: project, projectId: nil)
    }

    public func createTask(assignee: String, title: String, instructions: String, project: String, projectId: String?) async throws -> String {
        try await createTask(assignee: assignee, title: title, instructions: instructions, project: project, projectId: projectId, fields: RCVTaskFields())
    }

    public func createTask(assignee: String, title: String, instructions: String, project: String, projectId: String?, fields: RCVTaskFields) async throws -> String {
        let taskService = tasks
        let extra = BackendTaskFieldLanding.input(fields)
        let id = try await Self.createTask(assignee: assignee, title: title, instructions: instructions, project: project,
            projectId: projectId, projects: await projects(), defaultProject: defaultProject, create: { input in
                // The task's own fields ride on the create. A value the task service still refuses never costs the task:
                // it is made without them, and they are kept as custom fields below.
                guard !extra.isEmpty else { return try await taskService.create(input, by: "receiver").id }
                var full = input
                for (key, value) in extra { full = full.setting(key, value) }
                do { return try await taskService.create(full, by: "receiver").id }
                catch let error as NativeRPCError where error.code == "invalid-arguments" { return try await taskService.create(input, by: "receiver").id }
            })
        await Self.setCustomFields(id, fields: fields, keepTaskFields: (try? await tasks.task(id)).map { record in extra.contains { record.value[$0.0 == "status" ? "crmStatus" : $0.0].isNullish } } ?? false,
                                   note: "The Receiver filled in its fields from the event.")
        return id
    }

    public func updateTaskFields(_ taskID: String, fields: RCVTaskFields, source: String) async {
        let extra = BackendTaskFieldLanding.input(fields)
        if !extra.isEmpty { _ = try? await tasks.update(taskID, input: BackendTaskValues.object(extra), by: "receiver") }
        await Self.setCustomFields(taskID, fields: fields, keepTaskFields: false, note: nil)
    }

    public func taskSnapshot(_ taskID: String) async -> RCVTaskSnapshot? {
        guard let record = try? await tasks.store.byID(taskID) else { return nil }
        return BackendTaskFieldLanding.snapshot(record)
    }

    /// Custom fields through the task popup's field service (one save). `keepTaskFields`: the task
    /// refused its own fields, so they are kept as custom fields too.
    static func setCustomFields(_ taskID: String, fields: RCVTaskFields, keepTaskFields: Bool, note: String?) async {
        var items = fields.custom
        if keepTaskFields {
            items = fields.keys.map { RCVTaskCustomField(name: $0, label: RCVTaskMapping.taskLabel($0), kind: "text", value: fields.text($0)!) } + items
        }
        guard !items.isEmpty, let detail = await BackendTaskFieldsBox.shared.detail() else { return }
        _ = try? await detail.setNamedFields(taskID, items, by: "receiver", note: note)
    }

    /// Explicit rule ownership wins; old rule folders override only when nonempty.
    /// Otherwise the received event already carries its source/producer ownership.
    /// `projects`: the person's registered projects (an old rule's folder is matched against these only).
    public static func projectId(event: RCVEvent, rule: RCVRule?, projects: [PROJProject]) -> String {
        if let explicit = rule?.projectId { return PROJProjects.resolve(projectID: explicit, folder: nil, projects: projects) }
        if let folder = rule?.project.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            return PROJProjects.resolve(projectID: nil, folder: folder, projects: projects)
        }
        return event.projectID
    }

    /// Same task.create payload path as production, with only creation injected for tests.
    public static func createTask(assignee: String, title: String, instructions: String, project: String, projectId: String?,
                                  projects: [PROJProject], defaultProject: @Sendable () async -> String,
                                  create: @Sendable (NativeRPCValue) async throws -> String) async throws -> String {
        var folder = project
        if folder.isEmpty, assignee == "hoot" { folder = await defaultProject() }
        let ownership = PROJProjects.resolve(projectID: projectId, folder: folder, projects: projects)
        let input = NativeRPCValue.object([.init("title", .string(String(title.prefix(300)))), .init("instructions", .string(instructions)),
            .init("assignee", .string(assignee)), .init("project", folder.isEmpty ? .null : .string(folder)), .init("projectId", .string(ownership))])
        return try await create(input)
    }

    public func continueTask(_ taskID: String, text: String) async throws { _ = try await tasks.reply(taskID, text: text) }

    public func typeIntoSession(_ sessionID: String, text: String) async throws {
        guard await aiSessions().contains(where: { $0.id == sessionID }) else {
            throw NativeRPCError.invalidArguments("That session is not a running AI session, so nothing was typed into it.")
        }
        // Bracketed paste keeps the text in the prompt as one piece; control characters are removed so
        // nothing in an incoming message can act as a key press. One Enter submits it.
        try await write(sessionID, "\u{1b}[200~" + BackendRCVProductionDispatch.printable(text) + "\u{1b}[201~")
        try await write(sessionID, "\r")
    }

    /// Text with every control character (escape sequences, Enter, Ctrl keys) replaced by a space, except new lines inside paste.
    public static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar -> Unicode.Scalar in
            if scalar == "\n" { return scalar }
            return (scalar.value < 0x20 || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value)) ? " " : scalar
        }))
    }

    public func taskOutcome(_ taskID: String) async -> String? {
        guard let record = try? await tasks.task(taskID) else { return nil }
        let status = record.value["crmStatus"].string ?? "", process = record.value["process"].string ?? ""
        if let result = record.value["result"].string, !result.isEmpty { return "\(status): \(String(result.prefix(200)))" }
        return process == "idle" || process.isEmpty ? status : "\(status) (\(process))"
    }

    public func agents() async -> [RCVChoice] {
        ((try? await configuration.allAgents()) ?? []).compactMap { agent in
            guard let id = agent["id"].string else { return nil }
            return RCVChoice(id: id, name: agent["name"].string ?? id)
        }
    }

    public func sessions() async -> [RCVChoice] { await aiSessions() }

    public func githubComment(repository: String, number: Int, body: String) async throws {
        guard let github = await github() else { throw NativeRPCError(code: "unavailable", message: "GitHub is not connected, so the reply was not sent.") }
        _ = try await github.perform(operation: BackendGHOperation.issuesComment.rawValue,
                                     arguments: .object([.init("repo", .string(repository)), .init("number", .number(Double(number))), .init("body", .string(body))]))
    }

    public func send(_ request: URLRequest) async throws -> Int { try await BackendRCVReplySender.send(request) }
}

/// Builds and sends a reply. The host is the one the owner wrote; event values
/// may fill the path, query and body, never the host, and the agent supplies only the text.
public enum BackendRCVReplySender {
    /// Only the always-safe address characters stay as they are, so a filled-in
    /// value can never add a query setting ("&to=…") or a path step, and a
    /// reply holding "&" or "=" arrives whole (#388).
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    public static func request(for channel: RCVReplyChannel, event: RCVEvent, text: String, credential: String?) throws -> URLRequest {
        guard channel.via == .http else { throw NativeRPCError.invalidArguments("This reply goes through GitHub, not an address.") }
        let context = RCVEngine.Context.of(event, extra: ["reply": text, "secret.reply": credential ?? ""])
        let fixedHost = channel.url.dropFirst("https://".count).prefix { $0 != "/" }
        let rendered = try RCVEngine.render(channel.url, in: context, limit: 2_000) { value in
            value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        guard channel.url.hasPrefix("https://"), let url = URL(string: rendered), url.scheme == "https",
              let host = url.host, host.lowercased() == String(fixedHost).split(separator: ":").first.map(String.init)?.lowercased() else {
            throw NativeRPCError.invalidArguments("The reply address is not a fixed https address.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = channel.method
        var isJSON = channel.body.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        for header in channel.headers {
            let value = try RCVEngine.render(header.value, in: context, limit: 2_000)
            // By scalar: "\r\n" is one Character in Swift, so contains("\r") would miss it.
            guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { throw NativeRPCError.invalidArguments("A reply header would contain a line break.") }
            request.setValue(value, forHTTPHeaderField: header.name)
            if header.name.lowercased() == "content-type" { isJSON = value.lowercased().contains("json") }
        }
        let body = try RCVEngine.render(channel.body, in: context, limit: 64_000, escape: isJSON ? RCVEngine.jsonEscape : { $0 })
        request.httpBody = Data(body.utf8)
        return request
    }

    static func send(_ request: URLRequest) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: BackendRCVNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// A reply never follows a redirect: the owner's host is the only destination.
final class BackendRCVNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
