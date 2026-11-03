import Foundation
import TerminalDeckNativeCore

// Connected task systems: a task system that lives somewhere else (a CRM, a project
// tracker) and offers its tasks through an MCP server over HTTP. This file is the
// wire: JSON-RPC over POST (Streamable HTTP), answers as JSON or as a server-sent
// event stream, a bearer token, and the tool result read back as data. Nothing here
// knows any one product; what a system can do is discovered from its tool list.

/// One HTTP exchange. Tests answer it with a contract fake; the app uses URLSession.
public protocol BackendConnectedTasksTransport: Sendable {
    func send(_ request: BackendConnectedTasksHTTPRequest) async throws -> BackendConnectedTasksHTTPResponse
}

public struct BackendConnectedTasksHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data
    public init(method: String, url: URL, headers: [String: String], body: Data = Data()) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}

public struct BackendConnectedTasksHTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status; self.body = body
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }
}

/// The app's transport: no cookies, no cache, no redirect to another host, bounded answers.
public struct BackendConnectedTasksURLSessionTransport: BackendConnectedTasksTransport {
    public static let maximumBytes = 8 * 1024 * 1024
    private let session: URLSession
    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
    }

    public func send(_ request: BackendConnectedTasksHTTPRequest) async throws -> BackendConnectedTasksHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        if !request.body.isEmpty { urlRequest.httpBody = request.body }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw NativeRPCError(code: "unreachable", message: "The task system did not answer over HTTP.")
        }
        guard data.count <= Self.maximumBytes else {
            throw NativeRPCError(code: "malformed", message: "The task system's answer was too large to read.")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return BackendConnectedTasksHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    /// A redirect may stay on the same host and scheme; the token never goes anywhere else.
    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let from = task.originalRequest?.url
            guard let to = request.url, from?.host == to.host, from?.scheme == to.scheme else { return completionHandler(nil) }
            completionHandler(request)
        }
    }
}

/// One tool the system offers, as its `tools/list` describes it.
public struct BackendConnectedTasksRemoteTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: NativeRPCValue
    public var readOnly: Bool
    public init(name: String, description: String = "", inputSchema: NativeRPCValue = .object([]), readOnly: Bool = false) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly
    }
    /// The argument names its schema accepts.
    public var properties: [String] { inputSchema["properties"].fields?.map(\.key) ?? [] }
    public func property(_ name: String) -> NativeRPCValue { inputSchema["properties"][name] }
}

/// What a tool call answered: the system's own sentence and the data after it.
public struct BackendConnectedTasksAnswer: Sendable, Equatable {
    public var summary: String
    public var data: NativeRPCValue
}

/// A client for one system's MCP endpoint. Opens the conversation once (initialize),
/// then calls tools. Holds the token only in memory.
public actor BackendConnectedTasksClient {
    public struct Server: Sendable, Equatable {
        public var name: String
        public var title: String?
        public var version: String?
        public var instructions: String?
    }

    public let endpoint: URL
    private let token: String
    private let transport: any BackendConnectedTasksTransport
    private var sessionID: String?
    private var protocolVersion: String?
    private var server: Server?
    private var nextID = 1

    public static let protocolVersions = ["2025-06-18", "2025-03-26"]

    public init(endpoint: URL, token: String, transport: any BackendConnectedTasksTransport) throws {
        try Self.checkEndpoint(endpoint)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096, !trimmed.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7e }) else {
            throw NativeRPCError.invalidArguments("Paste the access token exactly as the system showed it.")
        }
        self.endpoint = endpoint; self.token = trimmed; self.transport = transport
    }

    /// HTTPS only, except a loopback address (a system running on this Mac).
    public static func checkEndpoint(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else {
            throw NativeRPCError.invalidArguments("Give the full address of the system's MCP server, starting with https://.")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || scheme == "http" && loopback else {
            throw NativeRPCError.invalidArguments("The address has to start with https:// (plain http is allowed only for this Mac).")
        }
    }

    /// Opens the conversation (once) and says who answered.
    @discardableResult
    public func open() async throws -> Server {
        if let server { return server }
        let params = NativeRPCValue.object([
            .init("protocolVersion", .string(Self.protocolVersions[0])),
            .init("capabilities", .object([])),
            .init("clientInfo", .object([.init("name", .string("terminal-deck-connected-tasks")), .init("version", .string("1"))])),
        ])
        let result = try await request("initialize", params: params, opening: true)
        let info = result["serverInfo"]
        let opened = Server(name: info["name"].string ?? "task system", title: info["title"].string,
                            version: info["version"].string, instructions: result["instructions"].string)
        protocolVersion = result["protocolVersion"].string ?? Self.protocolVersions[0]
        server = opened
        try await notify("notifications/initialized")
        return opened
    }

    public func tools() async throws -> [BackendConnectedTasksRemoteTool] {
        try await open()
        var all: [BackendConnectedTasksRemoteTool] = [], cursor: String?
        for _ in 0..<20 {
            let params: NativeRPCValue = cursor.map { .object([.init("cursor", .string($0))]) } ?? .object([])
            let result = try await request("tools/list", params: params)
            for tool in result["tools"].elements ?? [] {
                guard let name = tool["name"].string, !name.isEmpty else { continue }
                all.append(.init(name: name, description: tool["description"].string ?? "",
                                 inputSchema: tool["inputSchema"].fields == nil ? .object([]) : tool["inputSchema"],
                                 readOnly: tool["annotations"]["readOnlyHint"].bool == true))
            }
            guard let next = result["nextCursor"].string, !next.isEmpty else { break }
            cursor = next
        }
        return all
    }

    /// Calls one tool; a refusal comes back as the system's own sentence (code `refused`).
    public func call(_ tool: String, _ arguments: NativeRPCValue) async throws -> BackendConnectedTasksAnswer {
        try await open()
        let result = try await request("tools/call", params: .object([.init("name", .string(tool)), .init("arguments", arguments)]))
        return try Self.answer(result)
    }

    /// A tool result → (sentence, data). Data is `structuredContent` when there is one,
    /// else JSON found in the text (the whole text, or what follows its first line).
    public static func answer(_ result: NativeRPCValue) throws -> BackendConnectedTasksAnswer {
        let text = (result["content"].elements ?? []).compactMap { $0["type"].string == "text" ? $0["text"].string : nil }.joined(separator: "\n")
        if result["isError"].bool == true {
            let sentence = text.components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NativeRPCError(code: "refused", message: sentence.isEmpty ? "The task system refused that." : String(sentence.prefix(600)))
        }
        if result["structuredContent"].fields != nil {
            let summary = text.components(separatedBy: "\n\n").first ?? ""
            return .init(summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), data: result["structuredContent"])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whole = json(trimmed) { return .init(summary: "", data: whole) }
        var summary = trimmed, data = NativeRPCValue.missing
        if let start = trimmed.range(of: "\n\n") {
            let rest = String(trimmed[start.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = json(rest) { summary = String(trimmed[..<start.lowerBound]); data = parsed }
        }
        if data == .missing, let brace = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }), let parsed = json(String(trimmed[brace...])) {
            summary = String(trimmed[..<brace]); data = parsed
        }
        return .init(summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), data: data)
    }

    private static func json(_ text: String) -> NativeRPCValue? {
        guard let first = text.first, first == "{" || first == "[" else { return nil }
        return try? NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: 8 * 1024 * 1024)
    }

    // MARK: JSON-RPC

    private func headers() -> [String: String] {
        var headers = ["Authorization": "Bearer " + token, "Content-Type": "application/json",
                       "Accept": "application/json, text/event-stream"]
        if let sessionID { headers["Mcp-Session-Id"] = sessionID }
        if let protocolVersion { headers["MCP-Protocol-Version"] = protocolVersion }
        return headers
    }

    private func notify(_ method: String) async throws {
        let body = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("method", .string(method))]).encodedJSON()
        let response = try await exchange(body)
        guard (200..<300).contains(response.status) else { throw Self.failure(response) }
    }

    private func request(_ method: String, params: NativeRPCValue, opening: Bool = false) async throws -> NativeRPCValue {
        let id = nextID; nextID += 1
        let body = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(Double(id))),
                                              .init("method", .string(method)), .init("params", params)]).encodedJSON()
        var response = try await exchange(body)
        if response.status == 404, sessionID != nil, !opening {
            // The server forgot the session: open again once, then repeat.
            sessionID = nil; server = nil; protocolVersion = nil
            try await open()
            response = try await exchange(body)
        }
        guard (200..<300).contains(response.status) else { throw Self.failure(response) }
        if opening, let session = response.headers["mcp-session-id"], !session.isEmpty { sessionID = session }
        let message = try Self.message(response, id: id)
        if message["error"].fields != nil {
            let text = message["error"]["message"].string ?? "The task system refused the request."
            throw NativeRPCError(code: "refused", message: String(text.prefix(600)))
        }
        return message["result"]
    }

    private func exchange(_ body: Data) async throws -> BackendConnectedTasksHTTPResponse {
        do {
            return try await transport.send(.init(method: "POST", url: endpoint, headers: headers(), body: body))
        } catch let error as NativeRPCError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeRPCError(code: "unreachable", message: "Could not reach the task system: " + error.localizedDescription)
        }
    }

    /// The JSON-RPC answer with this id, from a JSON body or an event stream.
    static func message(_ response: BackendConnectedTasksHTTPResponse, id: Int) throws -> NativeRPCValue {
        let type = response.headers["content-type"]?.lowercased() ?? ""
        var candidates: [NativeRPCValue] = []
        if type.contains("text/event-stream") {
            for payload in events(String(decoding: response.body, as: UTF8.self)) {
                if let value = try? NativeRPCValue.parseJSON(Data(payload.utf8)) { candidates.append(value) }
            }
        } else if let value = try? NativeRPCValue.parseJSON(response.body) {
            candidates = value.elements ?? [value]
        }
        guard let match = candidates.first(where: { $0["id"].number == Double(id) }) ?? candidates.first(where: { $0.has("result") || $0.has("error") }) else {
            throw NativeRPCError(code: "malformed", message: "The task system's answer could not be read.")
        }
        return match
    }

    /// The `data:` payloads of a server-sent event stream, one per event.
    static func events(_ text: String) -> [String] {
        var out: [String] = [], data: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.isEmpty { if !data.isEmpty { out.append(data.joined(separator: "\n")); data = [] }; continue }
            if raw.hasPrefix("data:") { data.append(String(raw.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " "))) }
        }
        if !data.isEmpty { out.append(data.joined(separator: "\n")) }
        return out
    }

    static func failure(_ response: BackendConnectedTasksHTTPResponse) -> NativeRPCError {
        switch response.status {
        case 401, 403:
            return NativeRPCError(code: "unauthorized", message: "The task system did not accept the access token. Make a new one there and paste it again.")
        case 404:
            return NativeRPCError(code: "unreachable", message: "Nothing answers at that address. Check it is the system's MCP address.")
        case 429:
            let wait = response.headers["retry-after"].map { " Wait \($0) seconds and try again." } ?? " Wait a minute and try again."
            return NativeRPCError(code: "rate-limited", message: "The task system says too many requests." + wait)
        default:
            return NativeRPCError(code: "unreachable", message: "The task system answered with an error (HTTP \(response.status)). Try again in a moment.")
        }
    }
}
