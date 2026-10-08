import Foundation
import TerminalDeckNativeCore

/// Where the Receiver hands events, and how replies leave. One seam, so the
/// routing service is tested with a fake and production uses the real task,
/// session and GitHub services (`BackendRCVProductionDispatch`).
public protocol BackendRCVDispatching: Sendable {
    /// A new task for a task agent id, or for "hoot". Returns the task id.
    func createTask(assignee: String, title: String, instructions: String, project: String) async throws -> String
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

    public init(tasks: BackendTaskLocalService, configuration: BackendTaskConfiguration, defaultProject: @escaping @Sendable () async -> String,
                aiSessions: @escaping @Sendable () async -> [RCVChoice], write: @escaping @Sendable (String, String) async throws -> Void,
                github: @escaping @Sendable () async -> (any BackendGHWorkspaceServing)?) {
        self.tasks = tasks; self.configuration = configuration; self.defaultProject = defaultProject
        self.aiSessions = aiSessions; self.write = write; self.github = github
    }

    public func createTask(assignee: String, title: String, instructions: String, project: String) async throws -> String {
        var folder = project
        if folder.isEmpty, assignee == "hoot" { folder = await defaultProject() }
        let input = NativeRPCValue.object([.init("title", .string(String(title.prefix(300)))), .init("instructions", .string(instructions)),
                                           .init("assignee", .string(assignee)), .init("project", folder.isEmpty ? .null : .string(folder))])
        return try await tasks.create(input, by: "receiver").id
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
    public static func request(for channel: RCVReplyChannel, event: RCVEvent, text: String, credential: String?) throws -> URLRequest {
        guard channel.via == .http else { throw NativeRPCError.invalidArguments("This reply goes through GitHub, not an address.") }
        let context = RCVEngine.Context.of(event, extra: ["reply": text, "secret.reply": credential ?? ""])
        let fixedHost = channel.url.dropFirst("https://".count).prefix { $0 != "/" }
        let rendered = try RCVEngine.render(channel.url, in: context, limit: 2_000) { value in
            value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
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
