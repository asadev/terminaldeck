import Foundation
import TerminalDeckNativeCore

/// L8 (11 Oct): ONE place that says which of Terminal Deck's own tools a session gets and what it is spared
/// being asked about, the same for every signed-in AI. Asad: "AI model difference should not choose who gets
/// what kind of authority … the app control should be open for any signed in model."
///
/// What a session may DO is never decided here or by the AI it runs: it is the session's tool lease (its own
/// token, its grant from the seat / role / task and the person's settings: BackendTAGToolPolicy.sessionNames,
/// the agent's allowed and blocked tools), checked by the app on every call. This file only describes that
/// lease, and a small ADAPTER per CLI translates the description into that CLI's own config:
/// - Claude Code: the lease's private `--mcp-config` file; the allowance in its private `--settings`.
/// - Codex: `-c mcp_servers.deck-control.*` on its command line (this process only, never ~/.codex); the token
///   in one environment variable of its own (Codex keeps variables named *TOKEN* out of the commands it runs);
///   the allowance as per-tool `approval_mode="approve"`.
/// - Gemini: a private settings file of this launch (owner-only, in the lease's folder, gone with the lease),
///   `httpUrl` + `headers`; the allowance as `trust` on this one server (Gemini has no per-tool list for it).
/// Another MCP-capable CLI is added by one more adapter (and its name in `adapters`). A CLI without MCP gets
/// no app tools; the brief then tells it to answer in its reply instead (BackendTaskBriefComposition).
public enum BackendSessionAppTools {
    public static let server = "deck-control"
    public static let tokenVariable = "TERMINALDECK_DECK_CONTROL_TOKEN"
    public static let toolTimeoutSeconds = 900

    /// Every CLI that has an adapter. The launch prepares the app's tool lease for exactly these.
    public static let adapters: Set<String> = ["claude", "codex", "gemini"]
    public static func handedTo(provider: String?) -> Bool { provider.map(adapters.contains) ?? false }

    public struct Endpoint: Equatable, Sendable { public let url: String; public let token: String }

    /// The description: where the session's own tool server is, and what it is spared the CLI's own question for.
    public struct Description: Equatable, Sendable {
        public let endpoint: Endpoint
        /// A TASK session answers through the task tools in an unwatched session: these are not asked about by
        /// the CLI (the app still checks every call and asks itself where it would ask anyone).
        public let allowance: [String]
    }
    public static func describe(leaseArguments: [String], taskSession: Bool) -> Description? {
        endpoint(leaseArguments: leaseArguments).map { Description(endpoint: $0, allowance: taskSession ? taskAllowance() : []) }
    }
    /// The task-session allowance, by tool wire name: the tools the owner's "yes" to the task covers
    /// (BackendTaskAssignmentConsent) plus the index and the runner they are reached through.
    public static func taskAllowance() -> [String] {
        BackendTaskAssignmentConsent.tools.sorted().map { $0.replacingOccurrences(of: ".", with: "_") } + ["tools_run", "tools_describe"]
    }

    /// The url and token of one Claude-style server entry ({type: http, url, headers: {Authorization: Bearer …}}).
    public static func endpoint(_ entry: NativeRPCValue) -> Endpoint? {
        guard entry["type"].string == nil || entry["type"].string == "http", let url = entry["url"].string,
              url.hasPrefix("http://127.0.0.1:") || url.hasPrefix("http://localhost:") || url.hasPrefix("http://[::1]:"),
              let header = entry["headers"]["Authorization"].string, header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        guard !token.isEmpty, !token.contains("\0"), !url.contains("\0") else { return nil }
        return Endpoint(url: url, token: token)
    }
    /// The deck-control entry of the `--mcp-config` file a tool lease handed over (its arguments), read once.
    public static func endpoint(leaseArguments: [String]) -> Endpoint? {
        guard let index = leaseArguments.firstIndex(of: "--mcp-config"), index + 1 < leaseArguments.count,
              let bytes = try? BackendAccountFiles.boundedRead(URL(fileURLWithPath: leaseArguments[index + 1]), maximum: 256 * 1024),
              let value = try? NativeRPCValue.parseJSON(bytes) else { return nil }
        return endpoint(value["mcpServers"][server])
    }

    // MARK: Adapters

    public struct Handover: Equatable, Sendable {
        public var arguments: [String] = []
        public var environment: [String: String] = [:]
        public var readableFiles: [String] = []
        public var problem: String?
    }
    /// The lease translated for `provider`. `leaseArguments` / `leaseFiles` are what the lease gave (Claude's form);
    /// `environment` is the launch's environment so far (a Gemini settings file already named is built upon).
    /// `inAgentSettings`: the session's agent settings merge the server themselves (Claude, Gemini), so only what
    /// they do not cover is returned here.
    public static func handover(provider: String, leaseArguments: [String], leaseFiles: [String], taskSession: Bool,
                                environment: [String: String], inAgentSettings: Bool) -> Handover {
        switch provider {
        case "claude":
            // Claude's allowance rides in its one merged --settings file (DeckMemorySessionHook.claudeArguments).
            return Handover(arguments: leaseArguments, readableFiles: [])
        case "codex":
            guard let description = describe(leaseArguments: leaseArguments, taskSession: taskSession) else {
                return Handover(problem: "Terminal Deck's own tools could not be handed to this session: their configuration could not be read.")
            }
            let codex = codex(description)
            return Handover(arguments: codex.arguments, environment: codex.environment)
        case "gemini":
            if inAgentSettings { return Handover() }   // merged into the agent settings' Gemini file (BackendAGSLaunchBinding)
            guard let description = describe(leaseArguments: leaseArguments, taskSession: taskSession),
                  let config = leaseArguments.last.map({ URL(fileURLWithPath: $0) }) else {
                return Handover(problem: "Terminal Deck's own tools could not be handed to this session: their configuration could not be read.")
            }
            guard let gemini = gemini(description, directory: config.deletingLastPathComponent(), environment: environment) else {
                return Handover(problem: "Terminal Deck's own tools could not be handed to this Gemini session: its settings file could not be read.")
            }
            return Handover(environment: gemini.environment, readableFiles: [gemini.file.path])
        default:
            return Handover(problem: "This AI has no way to be given Terminal Deck's own tools yet.")
        }
    }

    /// Claude Code: the allowance as permission rules (`mcp__<server>__<tool>`).
    public static func claudeAllowance(_ allowance: [String]) -> [String] { allowance.map { "mcp__" + server + "__" + $0 } }

    /// Codex: `-c` overrides (this process only) and the one environment variable that carries the token.
    public static func codex(_ description: Description) -> (arguments: [String], environment: [String: String]) {
        let prefix = "mcp_servers." + server
        var arguments = ["-c", prefix + ".url=" + BackendNativeInstructions.tomlString(description.endpoint.url),
                         "-c", prefix + ".bearer_token_env_var=" + BackendNativeInstructions.tomlString(tokenVariable),
                         "-c", prefix + ".tool_timeout_sec=\(toolTimeoutSeconds)"]
        for tool in description.allowance { arguments += ["-c", prefix + ".tools." + tool + ".approval_mode=\"approve\""] }
        return (arguments, [tokenVariable: description.endpoint.token])
    }

    /// Gemini's own form of the entry: `httpUrl` is its streamable-HTTP field (`url` would mean SSE).
    public static func geminiEntry(_ description: Description) -> NativeRPCValue {
        .object([.init("httpUrl", .string(description.endpoint.url)),
                 .init("headers", .object([.init("Authorization", .string("Bearer " + description.endpoint.token))])),
                 .init("timeout", .number(Double(toolTimeoutSeconds * 1000))), .init("trust", .bool(!description.allowance.isEmpty))])
    }
    /// A Claude-style server entry in Gemini's form (where agent settings merge the generated servers).
    public static func geminiForm(_ entry: NativeRPCValue, taskSession: Bool) -> NativeRPCValue {
        guard let endpoint = endpoint(entry) else { return entry.removing("type") }
        return geminiEntry(Description(endpoint: endpoint, allowance: taskSession ? taskAllowance() : []))
    }
    /// Gemini: a private system-DEFAULTS file next to the lease (the lowest settings layer, the one the project
    /// tools use too), built on top of the defaults file this launch already names, or the machine's own.
    /// Nil when an existing defaults file cannot be read: nothing is handed over (never a half-merged file).
    public static func gemini(_ description: Description, directory: URL,
                              environment: [String: String]) -> (environment: [String: String], file: URL)? {
        let key = "GEMINI_CLI_SYSTEM_DEFAULTS_PATH"
        let defaults: URL
        if let given = environment[key], !given.isEmpty { defaults = URL(fileURLWithPath: given) }
        else {
            let settings = environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] ?? "/Library/Application Support/GeminiCli/settings.json"
            defaults = URL(fileURLWithPath: settings).deletingLastPathComponent().appendingPathComponent("system-defaults.json")
        }
        var object = NativeRPCValue.object([])
        if FileManager.default.fileExists(atPath: defaults.path) {
            guard let bytes = try? BackendAccountFiles.boundedRead(defaults, maximum: 2 * 1024 * 1024),
                  let parsed = try? NativeRPCValue.parseJSON(bytes), parsed.fields != nil else { return nil }
            object = parsed
        }
        let servers = object["mcpServers"].fields == nil ? NativeRPCValue.object([]) : object["mcpServers"]
        let value = object.setting("mcpServers", servers.setting(server, geminiEntry(description)))
        let file = directory.appendingPathComponent("gemini-deck-control.json")
        do { try BackendPrivateLaunchFiles.write(try value.encodedJSON(pretty: true), to: file) } catch { return nil }
        return ([key: file.path], file)
    }
}
