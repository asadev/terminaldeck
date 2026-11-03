import Foundation
import TerminalDeckNativeCore

public struct Routines21Connection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var chatId: String?
    public var hasSecret: Bool
    public var chats: [String]
    public init(id: String, kind: String, label: String, chatId: String? = nil, hasSecret: Bool = false, chats: [String] = []) {
        self.id = id; self.kind = kind; self.label = label; self.chatId = chatId; self.hasSecret = hasSecret; self.chats = chats
    }
    public var wire: NativeRPCValue {
        .object([.init("id", .string(id)), .init("kind", .string(kind)), .init("label", .string(label)),
                 .init("chatId", chatId.map(NativeRPCValue.string) ?? .null), .init("hasSecret", .bool(hasSecret)),
                 .init("chats", .array(chats.map { .object([.init("id", .string($0)), .init("name", .string($0))]) }))])
    }
}

/// Only names and chat IDs are saved here. Tokens use the app's secret store;
/// no token, last-four value, or secret-bearing URL is ever returned.
public actor BackendRoutines21Connections {
    public static let fileName = "routines21-connections.json"
    private let directory: URL?
    private let secrets: any BackendConnectedTasksSecrets
    private var records: [Routines21Connection] = []
    private var started = false
    public init(directory: URL? = nil, secrets: any BackendConnectedTasksSecrets) { self.directory = directory; self.secrets = secrets }

    private func start() throws {
        guard !started else { return }
        if let directory, let wire = try BackendTaskPersistence(directory: directory, ownership: .exclusive).read(Self.fileName, maximumBytes: 512_000) {
            guard wire["version"].number == 1 else { throw NativeRPCError.malformed("The saved Telegram connections could not be read.") }
            records = try JSONDecoder().decode([Routines21Connection].self, from: wire["connections"].encodedJSON())
        }
        started = true
    }
    private func persist(_ next: [Routines21Connection]) throws {
        guard let directory else { return }
        let bytes = try JSONEncoder().encode(next)
        try BackendTaskPersistence(directory: directory, ownership: .exclusive).write(Self.fileName,
            value: .object([.init("version", .number(1)), .init("connections", try NativeRPCValue.parseJSON(bytes))]))
    }
    public func list() throws -> [Routines21Connection] {
        try start()
        return try records.map { value in
            var masked = value; masked.hasSecret = try secrets.read(Self.telegramKey(value.id))?.isEmpty == false
            return masked
        }
    }
    public func connection(_ id: String) throws -> Routines21Connection? { try list().first { $0.id == id } }
    public func telegramToken(_ id: String) throws -> String? { try secrets.read(Self.telegramKey(id)) }

    public func saveTelegram(id: String, label: String, chatId: String, botToken: String?) throws -> Routines21Connection {
        try start()
        guard id.range(of: #"\A[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil,
              !label.isEmpty, label.utf8.count <= 160, !Routines21Destination.hasControl(label),
              chatId.range(of: #"\A(-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Give the Telegram connection a name and its numeric chat ID or @channel name.")
        }
        let key = Self.telegramKey(id), oldToken = try secrets.read(key)
        if let botToken, !botToken.isEmpty, botToken != "••••••••" {
            guard botToken.range(of: #"\A[0-9]{5,16}:[A-Za-z0-9_-]{30,64}\z"#, options: .regularExpression) != nil else {
                throw NativeRPCError.invalidArguments("That Telegram bot token does not look right. Copy it from BotFather.")
            }
            try secrets.write(key, token: botToken)
        }
        guard try secrets.read(key)?.isEmpty == false else { throw NativeRPCError.invalidArguments("Paste the bot token from BotFather to add this Telegram connection.") }
        let connection = Routines21Connection(id: id, kind: "telegram", label: label, chatId: chatId, hasSecret: true)
        var next = records.filter { $0.id != id }; next.append(connection)
        do { try persist(next) } catch {
            if let oldToken { try? secrets.write(key, token: oldToken) } else { try? secrets.remove(key) }
            throw error
        }
        records = next
        return connection
    }
    public func saveDestinationSecret(routineID: String, id: String, value: String?) throws {
        guard let value else { return }
        let key = Self.destinationKey(routineID, id)
        if value == "••••••••" { return }
        guard value.utf8.count <= 2_000, !Routines21Destination.hasControl(value) else {
            throw NativeRPCError.invalidArguments("Use a secret header value on one line.")
        }
        if value.isEmpty { try secrets.remove(key) } else { try secrets.write(key, token: value) }
    }
    public func destinationSecret(routineID: String, id: String) throws -> String? { try secrets.read(Self.destinationKey(routineID, id)) }
    private static func telegramKey(_ id: String) -> String { "routines21-telegram-" + id }
    private static func destinationKey(_ routine: String, _ id: String) -> String {
        // Length-prefixing keeps two routine/destination pairs from sharing a key.
        "routines21-webhook-\(routine.utf8.count)-\(routine)-\(id)"
    }
}

/// Existing server Telegram channels remain on their server. This adapter uses
/// the server alert helper's curl-config sender and td_curlq quoting; it never
/// downloads bot tokens to the Mac, or invokes the all-channel test sender.
public struct BackendRoutines21ServerTelegram: Sendable {
    private let runtime: BackendAppsRuntime
    private let layout: BackendAppsServerLayout
    public init(runtime: BackendAppsRuntime, fsRoot: String = "") throws {
        self.runtime = runtime; layout = try .init(runtime: runtime, fsRoot: fsRoot)
    }
    public func list(serverIDs: [String]) async -> [Routines21Connection] {
        guard let service = try? BackendAppsServerService(runtime: runtime, fsRoot: layout.fsRoot) else { return [] }
        var result: [Routines21Connection] = []
        for server in serverIDs {
            guard let settings = try? await service.alertsRead(serverID: server) else { continue }
            for channel in settings["channels"].elements ?? [] where channel["kind"].string == "telegram" && channel["enabled"].bool != false {
                guard let id = channel["id"].string else { continue }
                result.append(.init(id: "server:\(server):\(id)", kind: "telegram", label: channel["name"].string ?? "Telegram · \(server)",
                                    chatId: channel["chatId"].string, hasSecret: channel["hasBotToken"].bool ?? false))
            }
        }
        return result
    }
    public func send(connectionID: String, chatID: String?, text: String) async throws -> Int {
        let pieces = connectionID.split(separator: ":", maxSplits: 2).map(String.init)
        guard pieces.count == 3, pieces[0] == "server", !pieces[1].isEmpty,
              pieces[2].range(of: #"\A[A-Za-z0-9_-]{1,48}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Choose a saved server Telegram connection.")
        }
        let input: NativeRPCValue = .object([.init("channelId", .string(pieces[2])), .init("chatId", chatID.map(NativeRPCValue.string) ?? .null), .init("text", .string(text))])
        let result = try await runtime.run(pieces[1], script, stdin: input.encodedJSON(), timeoutMS: 30_000, maximumBytes: 1_024)
        guard result.code == 0, !result.truncated else { return 0 }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    public var script: String {
        "set -eu\numask 077\n. \(BackendAppsRuntime.quote(layout.bin + "/td-lib.sh"))\n" + #"""
        w=$(td_tmpdir) || exit 1
        trap 'rm -rf "$w"' EXIT
        cat > "$w/input.json"
        id=$("$JQ" -r '.channelId' "$w/input.json")
        "$JQ" --arg id "$id" '[.channels[]? | select(.id == $id and .kind == "telegram" and .enabled != false)][0] // null' "$TD_ETC/alerts.json" > "$w/c.json"
        [ "$("$JQ" -r '.botToken // ""' "$w/c.json" | wc -c)" -gt 1 ] || { printf '401\n'; exit 0; }
        chat=$("$JQ" -r '.chatId // ""' "$w/input.json")
        [ -n "$chat" ] || chat=$("$JQ" -r '.chatId // ""' "$w/c.json")
        text=$("$JQ" -r '.text' "$w/input.json")
        { printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(td_curlq "$("$JQ" -r '.botToken' "$w/c.json")")"
          printf 'data-urlencode = "chat_id=%s"\n' "$(td_curlq "$chat")"
          printf 'data-urlencode = "text=%s"\n' "$(td_curlq "$text")"
        } | curl -sS --max-time 20 --proto =https -o "$w/response.json" -w '%{http_code}' -K - 2>/dev/null > "$w/code" || { printf '0\n'; exit 0; }
        code=$(cat "$w/code")
        if [ "$code" = 200 ] && [ "$("$JQ" -r '.ok // false' "$w/response.json" 2>/dev/null)" != true ]; then
          "$JQ" -r '.error_code // 400' "$w/response.json" 2>/dev/null || printf '400\n'
        else printf '%s\n' "$code"; fi

        """#
    }
}
