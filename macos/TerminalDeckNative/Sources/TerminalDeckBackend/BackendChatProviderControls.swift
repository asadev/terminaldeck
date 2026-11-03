import Foundation
import TerminalDeckNativeCore

/// Narrow provider actions backed by the installed Codex app-server experimental schema.
/// Schema presence means the transport is supported; the provider decides account/model availability.
public enum BackendChatProviderControls {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(fields.map { .init($0.0, $0.1) })
    }
    public static func capabilities(provider: HootChatProvider) -> NativeRPCValue {
        let supported = provider == .codex
        return object([
            ("provider", .string(provider.rawValue)), ("transportSupported", .bool(supported)),
            ("availability", .string(supported ? "provider-check-required" : "unavailable")),
            ("reason", .string(supported ? "Experimental provider API; account, model and configuration gates are checked by each request." : "This provider's structured Chat protocol does not expose goals, native app management or conversational voice.")),
            ("operations", .array((supported ? operations : []).map(NativeRPCValue.string))),
            ("voiceTransport", supported ? .string("websocket-via-app-server") : .null),
            ("voiceAudioFormat", supported ? .string("PCM16 base64 with sampleRate and numChannels") : .null),
        ])
    }
    public static let operations = [
        "goals/read", "goals/set", "goals/edit", "goals/pause", "goals/resume", "goals/clear",
        "connections/plugins", "connections/installedPlugins", "connections/apps", "connections/installedApps",
        "connections/plugin", "connections/app", "connections/auth", "connections/installPlugin", "connections/uninstallPlugin", "connections/enablePlugin", "connections/enableApp",
        "voice/voices", "voice/start", "voice/audio", "voice/text", "voice/stop",
    ]
    public static func invoke(operation: String, arguments: NativeRPCValue, provider: HootChatProvider,
                              conversation: String?, cwd: String, request: Request) async throws -> NativeRPCValue {
        if operation == "capabilities" { return capabilities(provider: provider) }
        guard operations.contains(operation) else { throw invalid("Unknown provider operation.") }
        guard provider == .codex else { return capabilities(provider: provider) }
        var params = NativeRPCValue.object([])
        if operation.hasPrefix("goals/") || operation.hasPrefix("voice/") && operation != "voice/voices" {
            guard let conversation, !conversation.isEmpty else { throw invalid("The provider conversation is not ready.") }
            params = params.setting("threadId", .string(conversation))
        }
        let method: String
        switch operation {
        case "goals/read": method = "thread/goal/get"
        case "goals/clear": method = "thread/goal/clear"
        case "goals/pause", "goals/resume":
            method = "thread/goal/set"
            params = params.setting("status", .string(operation == "goals/pause" ? "paused" : "active"))
        case "goals/set", "goals/edit":
            method = "thread/goal/set"
            if arguments.has("objective") { params = params.setting("objective", .string(try text(arguments, "objective", maximum: 32_768))) }
            if arguments.has("tokenBudget") {
                let budget = arguments["tokenBudget"]
                guard budget == .null || budget.number.map({ $0 > 0 && $0.rounded() == $0 && $0 <= 9_007_199_254_740_991 }) == true else {
                    throw invalid("Goal token budget must be a positive whole number, or null to remove it.")
                }
                params = params.setting("tokenBudget", budget)
            }
            if operation == "goals/set" { _ = try text(arguments, "objective", maximum: 32_768) }
            guard params.has("objective") || params.has("tokenBudget") else { throw invalid("Provide the goal objective or budget to edit.") }
        case "connections/plugins", "connections/installedPlugins":
            method = operation == "connections/plugins" ? "plugin/list" : "plugin/installed"
            params = object([("cwds", .array([.string(cwd)]))])
            if operation == "connections/plugins" { params = params.setting("forceRefetch", .bool(arguments["refresh"].bool == true)) }
        case "connections/apps":
            method = "app/list"
            params = object([("forceRefetch", .bool(arguments["refresh"].bool == true)), ("limit", .number(100))])
            if let conversation { params = params.setting("threadId", .string(conversation)) }
            if arguments.has("cursor") { params = params.setting("cursor", .string(try text(arguments, "cursor", maximum: 4096))) }
        case "connections/installedApps":
            method = "app/installed"
            params = object([("forceRefresh", .bool(arguments["refresh"].bool == true))])
            if let conversation { params = params.setting("threadId", .string(conversation)) }
        case "connections/installPlugin":
            method = "plugin/install"; params = try pluginReference(arguments)
        case "connections/uninstallPlugin":
            method = "plugin/uninstall"; params = object([("pluginId", .string(try text(arguments, "id", maximum: 256)))])
        case "connections/plugin":
            method = "plugin/read"; params = try pluginReference(arguments)
        case "connections/app":
            method = "app/read"
            params = object([("appIds", .array([.string(try text(arguments, "id", maximum: 256))])), ("includeTools", .bool(true))])
            if let conversation { params = params.setting("threadId", .string(conversation)) }
        case "connections/auth":
            // Returns the provider's login URL. Opening it and completing consent remain explicit UI actions.
            method = "mcpServer/oauth/login"
            params = object([("name", .string(try text(arguments, "name", maximum: 256)))])
            if let conversation { params = params.setting("threadId", .string(conversation)) }
        case "connections/enablePlugin", "connections/enableApp":
            return try await enable(operation: operation, arguments: arguments, conversation: conversation, cwd: cwd, request: request)
        case "voice/voices": method = "thread/realtime/listVoices"
        case "voice/start":
            method = "thread/realtime/start"
            params = params.setting("transport", object([("type", .string("websocket"))])).setting("outputModality", .string("audio"))
            if arguments.has("voice") {
                let voice = try text(arguments, "voice", maximum: 64)
                let voices = ["alloy", "arbor", "ash", "ballad", "breeze", "cedar", "coral", "cove", "echo", "ember", "juniper", "maple", "marin", "sage", "shimmer", "sol", "spruce", "vale", "verse"]
                guard voices.contains(voice) else { throw invalid("Choose a voice returned by the provider.") }
                params = params.setting("voice", .string(voice))
            }
        case "voice/audio":
            method = "thread/realtime/appendAudio"
            params = params.setting("audio", try audio(arguments["audio"]))
        case "voice/text":
            method = "thread/realtime/appendText"
            params = params.setting("text", .string(try text(arguments, "text", maximum: 32_768)))
                .setting("role", .string("user"))
        case "voice/stop": method = "thread/realtime/stop"
        default: throw invalid("Unknown provider operation.")
        }
        return sanitized(try await request(method, params))
    }
    private static func enable(operation: String, arguments: NativeRPCValue, conversation: String?, cwd: String, request: Request) async throws -> NativeRPCValue {
        let id = try text(arguments, "id", maximum: 256)
        guard !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw invalid("Choose a valid provider inventory ID.")
        }
        guard let enabled = arguments["enabled"].bool else { throw invalid("Provide enabled as true or false.") }
        let plugin = operation == "connections/enablePlugin"
        let inventory: NativeRPCValue
        if plugin {
            inventory = try await request("plugin/installed", object([("cwds", .array([.string(cwd)]))]))
            let installed = (inventory["marketplaces"].elements ?? []).flatMap { $0["plugins"].elements ?? [] }
            guard installed.contains(where: { $0["id"].string == id && $0["installed"].bool == true }) else {
                throw invalid("Choose an installed plugin from the current provider inventory.")
            }
        } else {
            var read = object([("appIds", .array([.string(id)])), ("includeTools", .bool(false))])
            if let conversation { read = read.setting("threadId", .string(conversation)) }
            inventory = try await request("app/read", read)
            guard (inventory["apps"].elements ?? []).contains(where: { $0["id"].string == id }) else {
                throw invalid("Choose an app from the current provider inventory.")
            }
        }
        // A single quoted TOML key segment prevents dots, quotes or slashes escaping into another setting.
        let quotedID = "\"" + id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let result = try await request("config/value/write", object([
            ("keyPath", .string((plugin ? "plugins." : "apps.") + quotedID + ".enabled")),
            ("value", .bool(enabled)), ("mergeStrategy", .string("upsert")),
        ]))
        // Write success is a saved preference, not proof that this loaded thread has new tools.
        return object([("saved", .bool(true)), ("id", .string(id)), ("enabled", .bool(enabled)),
                       ("effectiveOnNextConversation", .bool(true)), ("providerResult", sanitized(result))])
    }
    private static func pluginReference(_ arguments: NativeRPCValue) throws -> NativeRPCValue {
        var value = object([("pluginName", .string(try text(arguments, "pluginName", maximum: 256)))])
        if arguments.has("remoteMarketplaceName") { value = value.setting("remoteMarketplaceName", .string(try text(arguments, "remoteMarketplaceName", maximum: 256))) }
        if arguments.has("marketplacePath") {
            let path = try text(arguments, "marketplacePath", maximum: 4096)
            guard path.hasPrefix("/") else { throw invalid("Marketplace path must be absolute.") }
            value = value.setting("marketplacePath", .string(path))
        }
        return value
    }
    private static func text(_ value: NativeRPCValue, _ key: String, maximum: Int) throws -> String {
        guard let result = value[key].string, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.utf8.count <= maximum, !result.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else {
            throw invalid("Provide a valid \(key).")
        }
        return result
    }
    private static func audio(_ value: NativeRPCValue) throws -> NativeRPCValue {
        let encoded = try text(value, "data", maximum: 524_288)
        guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
              let rate = value["sampleRate"].number, rate.rounded() == rate, (8_000...192_000).contains(rate),
              let channels = value["numChannels"].number, channels.rounded() == channels, (1...2).contains(channels),
              bytes.count % (2 * Int(channels)) == 0 else { throw invalid("Provide valid base64 PCM16 audio and its sample rate/channels.") }
        return object([("data", .string(encoded)), ("sampleRate", .number(rate)), ("numChannels", .number(channels)),
                       ("samplesPerChannel", .number(Double(bytes.count / (2 * Int(channels)))))])
    }
    private static func invalid(_ message: String) -> NativeRPCError { .invalidArguments(message) }

    /// A transient event for the active provider thread. Audio must never enter the durable chat journal.
    /// Consumers must display closed/error events and release microphone/playback resources immediately.
    public static func notification(_ row: NativeRPCValue, conversation: String?) -> NativeRPCValue? {
        guard let method = row["method"].string else { return nil }
        let params = row["params"]
        let threadScoped = method.hasPrefix("thread/goal/") || method.hasPrefix("thread/realtime/")
        if threadScoped { guard let conversation, params["threadId"].string == conversation else { return nil } }
        let keys: [String]
        switch method {
        case "thread/goal/updated": keys = ["goal", "threadId", "turnId"]
        case "thread/goal/cleared": keys = ["threadId"]
        case "thread/realtime/started": keys = ["threadId", "version", "realtimeSessionId"]
        case "thread/realtime/closed": keys = ["threadId", "reason"]
        case "thread/realtime/error": keys = ["threadId", "message"]
        case "thread/realtime/transcript/delta": keys = ["threadId", "role", "delta"]
        case "thread/realtime/transcript/done": keys = ["threadId", "role", "text"]
        case "thread/realtime/item/transcript/delta": keys = ["threadId", "itemId", "delta"]
        case "thread/realtime/item/started", "thread/realtime/item/completed", "thread/realtime/itemAdded": keys = ["threadId", "item"]
        case "thread/realtime/outputAudio/delta":
            guard let chunk = try? audio(params["audio"]) else { return nil }
            return object([("method", .string(method)), ("params", object([("threadId", params["threadId"]), ("audio", chunk)])), ("ephemeralAudio", .bool(true))])
        case "mcpServer/oauthLogin/completed": keys = ["name", "success", "error"]
        case "app/list/updated": return object([("method", .string(method)), ("params", .object([]))])
        default: return nil
        }
        var clean = NativeRPCValue.object([])
        for key in keys where params.has(key) {
            let value: NativeRPCValue
            if key == "goal" {
                let allowed = ["threadId", "objective", "status", "tokenBudget", "tokensUsed", "timeUsedSeconds", "createdAt", "updatedAt"]
                value = .object((params[key].fields ?? []).filter { allowed.contains($0.key) }.map { .init($0.key, bounded($0.value)) })
            } else if key == "item" {
                let allowed = ["id", "realtimeSessionId", "type", "role", "text", "item_id", "turn_id", "outcome"]
                value = .object((params[key].fields ?? []).filter { allowed.contains($0.key) }.map { .init($0.key, bounded($0.value)) })
            } else { value = bounded(params[key]) }
            clean = clean.setting(key, value)
        }
        return object([("method", .string(method)), ("params", clean)])
    }
    /// Provider catalogs may contain private server configuration. Keep secrets out of tool/UI results.
    public static func sanitized(_ value: NativeRPCValue, depth: Int = 0) -> NativeRPCValue {
        guard depth < 16 else { return .null }
        if let fields = value.fields {
            let secretKeys = Set(["apikey", "api_key", "accesstoken", "access_token", "refreshtoken", "refresh_token", "clientsecret", "client_secret", "password", "credentials", "env", "environment", "headers", "http_headers", "authorization", "bearertoken", "bearer_token", "token", "secret", "secrets", "config"])
            return .object(fields.prefix(512).filter { !secretKeys.contains($0.key.lowercased()) }.map {
                .init($0.key, sanitized($0.value, depth: depth + 1))
            })
        }
        if let elements = value.elements { return .array(elements.prefix(1024).map { sanitized($0, depth: depth + 1) }) }
        return bounded(value)
    }
    private static func bounded(_ value: NativeRPCValue) -> NativeRPCValue {
        if let string = value.string { return .string(String(string.prefix(32_768))) }
        if value.fields != nil || value.elements != nil { return .null }
        return value
    }
}
