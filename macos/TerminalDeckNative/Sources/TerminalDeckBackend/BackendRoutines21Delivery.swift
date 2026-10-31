import Foundation
import TerminalDeckNativeCore

/// Saved choices contain no credentials. The optional header is its name only.
public struct Routines21Destination: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var url: String?
    public var connectionId: String?
    public var chatId: String?
    public var secretHeader: String?
    public var hasSecret: Bool

    public init(id: String, kind: String, label: String, url: String? = nil, connectionId: String? = nil,
                chatId: String? = nil, secretHeader: String? = nil, hasSecret: Bool = false) {
        self.id = id; self.kind = kind; self.label = label; self.url = url; self.connectionId = connectionId
        self.chatId = chatId; self.secretHeader = secretHeader; self.hasSecret = hasSecret
    }

    public init(wire: NativeRPCValue) throws {
        guard let fields = wire.fields, Set(fields.map(\.key)).count == fields.count,
              fields.allSatisfy({ ["id", "kind", "label", "url", "connectionId", "chatId", "secretHeader", "hasSecret"].contains($0.key) }) else {
            throw NativeRPCError.invalidArguments("Choose where this routine should send its reports.")
        }
        self.init(id: try wire["id"].requireString("destination id", nonempty: true),
                  kind: try wire["kind"].requireString("destination kind", nonempty: true),
                  label: wire["label"].string ?? "", url: wire["url"].string,
                  connectionId: wire["connectionId"].string, chatId: wire["chatId"].string,
                  secretHeader: wire["secretHeader"].string, hasSecret: wire["hasSecret"].bool ?? false)
        try validate()
    }

    public func validate() throws {
        guard id.range(of: #"\A[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil,
              ["webhook", "whatsapp", "telegram", "hoot"].contains(kind),
              label.utf8.count <= 160, !Self.hasControl(label),
              [connectionId, chatId].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !Self.hasControl($0) }) else {
            throw NativeRPCError.invalidArguments("Use a short name and choose a report destination.")
        }
        if kind == "webhook" {
            guard let raw = url, raw.utf8.count <= 2_000, !Self.hasControl(raw), let u = URL(string: raw),
                  ["https", "http"].contains(u.scheme?.lowercased() ?? ""), u.host?.isEmpty == false,
                  u.user == nil, u.password == nil, u.fragment == nil else {
                throw NativeRPCError.invalidArguments("Use a full http:// or https:// webhook address without a password.")
            }
            if let secretHeader {
                guard secretHeader.range(of: #"\A[A-Za-z][A-Za-z0-9-]{0,63}\z"#, options: .regularExpression) != nil,
                      !["host", "content-length", "content-type", "connection", "transfer-encoding"].contains(secretHeader.lowercased()) else {
                    throw NativeRPCError.invalidArguments("Use a header name such as Authorization or X-Report-Secret.")
                }
            }
        }
        if kind == "whatsapp", connectionId == nil || chatId == nil {
            throw NativeRPCError.invalidArguments("Choose a WhatsApp connection and enter the chat or group ID.")
        }
        if kind == "telegram", connectionId == nil {
            throw NativeRPCError.invalidArguments("Choose a Telegram connection or add a bot token and chat ID.")
        }
        if kind == "telegram", let chatId,
           chatId.range(of: #"\A(-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})\z"#, options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("Use the numeric Telegram chat ID or @channel name.")
        }
    }

    static func hasControl(_ value: String) -> Bool { value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    public var wire: NativeRPCValue {
        .object([.init("id", .string(id)), .init("kind", .string(kind)), .init("label", .string(label)),
                 .init("url", url.map(NativeRPCValue.string) ?? .null), .init("connectionId", connectionId.map(NativeRPCValue.string) ?? .null),
                 .init("chatId", chatId.map(NativeRPCValue.string) ?? .null), .init("secretHeader", secretHeader.map(NativeRPCValue.string) ?? .null),
                 .init("hasSecret", .bool(hasSecret))])
    }
}

public struct Routines21DeliveryReceipt: Codable, Equatable, Sendable {
    public var destinationId: String
    public var label: String
    public var status: String
    public var message: String
    public var attempts: Int
    public var wire: NativeRPCValue {
        .object([.init("destinationId", .string(destinationId)), .init("label", .string(label)), .init("status", .string(status)),
                 .init("message", .string(message)), .init("attempts", .number(Double(attempts)))])
    }
}

public struct Routines21HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data = Data()) { self.status = status; self.body = body }
}

/// Sending never throws to the routine runner. Each selected destination gets
/// at most two attempts, and every error shown to the person is written here.
public actor BackendRoutines21Delivery {
    public typealias Transport = @Sendable (URLRequest) async throws -> Routines21HTTPResponse
    public typealias Receiver = @Sendable () async throws -> BackendRCVState?
    public typealias Hoot = @Sendable (_ routine: String, _ runTime: Double, _ status: String, _ report: String) async throws -> Void
    public typealias ServerConnections = @Sendable () async throws -> [Routines21Connection]
    public typealias ServerTelegram = @Sendable (_ connectionID: String, _ chatID: String?, _ text: String) async throws -> Int

    private let connectionsStore: BackendRoutines21Connections
    private let receiver: Receiver
    private let serverConnections: ServerConnections
    private let serverTelegram: ServerTelegram
    private let transport: Transport
    private let hoot: Hoot

    public init(connections: BackendRoutines21Connections, receiver: @escaping Receiver = { nil },
                serverConnections: @escaping ServerConnections = { [] },
                serverTelegram: @escaping ServerTelegram = { _, _, _ in throw NativeRPCError(code: "unavailable", message: "Telegram is not connected.") },
                transport: @escaping Transport = BackendRoutines21Delivery.http,
                hoot: @escaping Hoot = { _, _, _, _ in throw NativeRPCError(code: "unavailable", message: "Hoot is not available.") }) {
        connectionsStore = connections; self.receiver = receiver; self.serverConnections = serverConnections
        self.serverTelegram = serverTelegram; self.transport = transport; self.hoot = hoot
    }

    public init(directory: URL? = nil, secrets: any BackendConnectedTasksSecrets, receiver: @escaping Receiver = { nil },
                existingTelegram: @escaping ServerConnections = { [] },
                sendExistingTelegram: @escaping ServerTelegram = { _, _, _ in throw NativeRPCError(code: "unavailable", message: "Telegram is not connected.") },
                transport: @escaping Transport = BackendRoutines21Delivery.http,
                hoot: @escaping Hoot = { _, _, _, _ in throw NativeRPCError(code: "unavailable", message: "Hoot is not available.") }) {
        connectionsStore = .init(directory: directory, secrets: secrets); self.receiver = receiver
        serverConnections = existingTelegram; serverTelegram = sendExistingTelegram; self.transport = transport; self.hoot = hoot
    }

    public func connections() async throws -> [Routines21Connection] {
        var result = try await connectionsStore.list()
        if let state = try await receiver() { result += Self.receiverConnections(state) }
        result += (try? await serverConnections()) ?? []
        return result
    }

    public func saveTelegram(id: String, label: String, chatId: String, botToken: String?) async throws -> Routines21Connection {
        try await connectionsStore.saveTelegram(id: id, label: label, chatId: chatId, botToken: botToken)
    }
    public func addConnection(_ wire: NativeRPCValue) async throws -> Routines21Connection {
        guard let fields = wire.fields, Set(fields.map(\.key)).count == fields.count,
              fields.allSatisfy({ ["id", "kind", "label", "chatId", "botToken"].contains($0.key) }),
              wire["kind"].string == nil || wire["kind"].string == "telegram" else {
            throw NativeRPCError.invalidArguments("Add a Telegram connection with its name, bot token and chat ID.")
        }
        return try await saveTelegram(id: wire["id"].string ?? UUID().uuidString.lowercased(),
                                      label: try wire["label"].requireString("connection name", nonempty: true),
                                      chatId: try wire["chatId"].requireString("chat ID", nonempty: true), botToken: wire["botToken"].string)
    }
    public func saveDestinationSecret(routineID: String, id: String, value: String?) async throws {
        try await connectionsStore.saveDestinationSecret(routineID: routineID, id: id, value: value)
    }
    public func prepareDestinations(routineID: String, raw: [NativeRPCValue], previous: [Routines21Destination]) async throws -> [Routines21Destination] {
        guard raw.count <= 20 else { throw NativeRPCError.invalidArguments("Choose up to 20 report destinations.") }
        var parsed: [(Routines21Destination, String?)] = []
        for item in raw {
            guard let fields = item.fields, Set(fields.map(\.key)).count == fields.count else {
                throw NativeRPCError.invalidArguments("Each report destination must have one value for each setting.")
            }
            let safe = item.removing("secret")
            var destination = try Routines21Destination(wire: safe)
            if destination.secretHeader == nil { destination.secretHeader = previous.first { $0.id == destination.id }?.secretHeader }
            let secret = item["secret"].string
            if item.has("secret"), secret == nil { throw NativeRPCError.invalidArguments("Use a secret header value on one line.") }
            if secret != nil, destination.kind != "webhook" { throw NativeRPCError.invalidArguments("Only webhook destinations use a secret header. Other tokens belong to their connection.") }
            if secret?.isEmpty == false, destination.secretHeader == nil { throw NativeRPCError.invalidArguments("Choose a header name for the webhook secret.") }
            if destination.kind == "webhook" {
                if secret == "" { destination.hasSecret = false }
                else if previous.first(where: { $0.id == destination.id })?.hasSecret == true { destination.hasSecret = true }
                else if secret == nil, !previous.contains(where: { $0.id == destination.id }) { destination.hasSecret = false }
            }
            try destination.validate()
            parsed.append((destination, secret))
        }
        guard Set(parsed.map { $0.0.id }).count == parsed.count else { throw NativeRPCError.invalidArguments("Each report destination needs its own ID.") }
        for (destination, secret) in parsed {
            // #358: a webhook new to this list starts without a secret, whatever an old one with its id left behind.
            let fresh = destination.kind == "webhook" && !previous.contains { $0.id == destination.id }
            try await saveDestinationSecret(routineID: routineID, id: destination.id, value: secret ?? (fresh ? "" : nil))
        }
        return try await masked(parsed.map { $0.0 }, routineID: routineID)
    }
    public func masked(_ destinations: [Routines21Destination], routineID: String) async throws -> [Routines21Destination] {
        var result: [Routines21Destination] = []
        for var item in destinations {
            try item.validate()
            if item.kind == "webhook" {
                let saved = try await connectionsStore.destinationSecret(routineID: routineID, id: item.id) != nil
                item.hasSecret = item.hasSecret || saved
            }
            else { item.hasSecret = false }
            result.append(item)
        }
        return result
    }

    public func send(_ destinations: [Routines21Destination], routineID: String, routine: String, runTime: Double, status: String, report: String) async -> [Routines21DeliveryReceipt] {
        var receipts: [Routines21DeliveryReceipt] = []
        for destination in destinations {
            var final = "The connection could not be reached. Check it and try again."
            var attempts = 0
            for attempt in 1...2 {
                attempts = attempt
                do {
                    try Task.checkCancellation()
                    try destination.validate()
                    let response = try await sendOnce(destination, routineID: routineID, routine: routine, runTime: runTime, status: status, report: report)
                    if (200..<300).contains(response) {
                        receipts.append(.init(destinationId: destination.id, label: Self.label(destination), status: "sent", message: "Sent.", attempts: attempt))
                        final = ""; break
                    }
                    final = Self.failure(kind: destination.kind, code: response)
                } catch is CancellationError {
                    final = "Sending was stopped."; break
                } catch let error as DeliveryError {
                    final = error.message
                } catch {
                    // Never expose URLSession/server errors: they can include a token or URL.
                    final = "The connection could not be reached. Check it and try again."
                }
            }
            if !final.isEmpty {
                receipts.append(.init(destinationId: destination.id, label: Self.label(destination), status: "failed", message: final, attempts: attempts))
            }
        }
        return receipts
    }

    private func sendOnce(_ destination: Routines21Destination, routineID: String, routine: String, runTime: Double, status: String, report: String) async throws -> Int {
        let text = "\(routine) · \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: runTime / 1000))) · \(status)\n\(report)"
        if destination.kind == "hoot" { try await hoot(routine, runTime, status, report); return 200 }
        if destination.kind == "telegram", let connection = destination.connectionId, connection.hasPrefix("server:") {
            return try await serverTelegram(connection, destination.chatId, text)
        }
        var request: URLRequest
        switch destination.kind {
        case "webhook":
            request = URLRequest(url: URL(string: destination.url!)!, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try NativeRPCValue.object([.init("routine", .string(routine)), .init("runTime", .number(runTime)),
                .init("status", .string(status)), .init("report", .string(report))]).encodedJSON()
            let secret = try await connectionsStore.destinationSecret(routineID: routineID, id: destination.id)
            if destination.hasSecret, secret?.isEmpty != false {
                throw DeliveryError("The saved webhook secret is missing. Add it again before sending.")
            }
            if let secret {
                guard let header = destination.secretHeader else { throw DeliveryError("Choose a header name for the saved webhook secret.") }
                request.setValue(secret, forHTTPHeaderField: header)
            }
        case "whatsapp":
            guard let state = try await receiver(),
                  let source = state.sources.first(where: { $0.id == destination.connectionId && $0.preset == RCVPresets.whapi.id && $0.enabled }),
                  let credential = state.secrets[source.id]?.reply, !credential.isEmpty,
                  let channel = RCVPresets.whapi.reply else { throw DeliveryError("The WhatsApp connection has no saved channel token. Add it in Receiver.") }
            let event = RCVEvent(sourceId: source.id, receivedAt: runTime, kind: "routine-report", fields: ["chat": destination.chatId!])
            request = try BackendRCVReplySender.request(for: channel, event: event, text: text, credential: credential)
        case "telegram":
            guard let id = destination.connectionId, let connection = try await connectionsStore.connection(id),
                  let credential = try await connectionsStore.telegramToken(id) else { throw DeliveryError("The Telegram connection has no saved bot token. Add one below.") }
            let chat = destination.chatId ?? connection.chatId
            guard let chat, !chat.isEmpty else { throw DeliveryError("Enter the Telegram chat ID.") }
            guard let url = URL(string: "https://api.telegram.org/bot\(credential)/sendMessage") else {
                throw DeliveryError("The saved bot token could not be used. Add it again.")
            }
            request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try NativeRPCValue.object([.init("chat_id", .string(chat)), .init("text", .string(text))]).encodedJSON()
        default: throw DeliveryError("Choose a report destination.")
        }
        let response = try await transport(request)
        if destination.kind == "telegram", (200..<300).contains(response.status), !response.body.isEmpty,
           let value = try? NativeRPCValue.parseJSON(response.body), value["ok"].bool == false {
            return Int(value["error_code"].number ?? 400)
        }
        return response.status
    }

    public static func receiverConnections(_ state: BackendRCVState) -> [Routines21Connection] {
        state.sources.filter { $0.preset == RCVPresets.whapi.id && $0.enabled }.map { source in
            let seen = state.events.filter { $0.sourceId == source.id }.compactMap { $0.fields["chat"] }
            return Routines21Connection(id: source.id, kind: "whatsapp", label: source.name,
                hasSecret: state.secrets[source.id]?.reply?.isEmpty == false, chats: Array(Set(seen)).sorted())
        }
    }

    private static func label(_ destination: Routines21Destination) -> String {
        if !destination.label.isEmpty { return destination.label }
        switch destination.kind { case "whatsapp": return "WhatsApp"; case "telegram": return "Telegram"; case "hoot": return "Hoot"; default: return "Webhook" }
    }
    private static func failure(kind: String, code: Int) -> String {
        if code == 401 || code == 403 {
            return kind == "telegram" ? "The bot token was refused." : "The saved secret or channel token was refused."
        }
        if code == 404 { return "The destination could not be found. Check the address or chat ID." }
        if code == 429 { return "The service asked us to slow down. The report was not sent." }
        if (300..<400).contains(code) { return "The address moved. Update it before sending again." }
        return "The service refused the message (code \(code))."
    }
    private struct DeliveryError: Error { let message: String; init(_ message: String) { self.message = message } }

    /// Same cookie-free, credential-free, no-redirect policy as Receiver replies.
    public static func http(_ request: URLRequest) async throws -> Routines21HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: BackendRCVNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return .init(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
