import Foundation
import TerminalDeckNativeCore

/// Backend-owned flags/config only. It neither writes account settings nor
/// accepts paths, environment, tool widening or permission mode from chat RPCs.
public struct BackendHootChatLaunchPlan: Sendable {
    public let arguments: [String]
    public let setup: BackendHootChatSetup?
    /// `pageServers`: the MCP page's servers Hoot gets (BackendMcpPolicy.hootServers). Their secrets never go on a
    /// command line: Claude reads them from a private file, Codex and Gemini get them over the conversation's own pipe.
    public init(provider: HootChatProvider, cwd: String, sessionID: String?, extra: [String], expectedTools: Set<String> = [],
                pageServers: [BackendMcpPolicy.HootServer] = [], privateDirectory: URL? = BackendMcpPolicy.launchDirectory(), sessionTools: Bool = false) throws {
        if provider == .claude {
            arguments = try BackendHootChatCLI.claudeArguments(sessionID: sessionID,
                extra: Self.withPageServers(try Self.richClaudeArguments(extra), pageServers, privateDirectory: privateDirectory))
            setup = nil; return
        }
        var cli = provider == .codex ? ["app-server", "--stdio"] : ["--acp"]
        var session = NativeRPCValue.object([]), config = NativeRPCValue.object([])
        var mcp = NativeRPCValue.object([]), instructions = "", index = 0
        var profileInstructions = ""
        let geminiFlags: Set<String> = ["--model", "-m", "--approval-mode", "--policy", "--admin-policy", "--allowed-tools", "--allowed-mcp-server-names"]
        while index < extra.count {
            let flag = extra[index]
            if flag == "--strict-mcp-config" { index += 1; continue }
            if provider == .gemini && ["--sandbox", "-s", "--yolo", "-y"].contains(flag) { cli.append(flag); index += 1; continue }
            guard index + 1 < extra.count else { throw NativeRPCError.invalidArguments("Missing value for Hoot's \(flag) setting.") }
            let value = extra[index + 1]; index += 2
            switch flag {
            case "--mcp-config":
                let bytes = try Data(contentsOf: URL(fileURLWithPath: value), options: .mappedIfSafe)
                mcp = try NativeRPCValue.parseJSON(bytes, maximumBytes: 1_048_576)["mcpServers"].requireObject("Hoot MCP servers")
            case "--append-system-prompt-file":
                let bytes = try Data(contentsOf: URL(fileURLWithPath: value), options: .mappedIfSafe)
                guard bytes.count <= 131_072, let text = String(data: bytes, encoding: .utf8) else { throw NativeRPCError.invalidArguments("Hoot instructions require valid UTF-8, at most 128 KiB.") }
                instructions += text
            case "--append-system-prompt": instructions += value
            case "--model", "-m":
                if provider == .codex { session = session.setting("model", .string(value)) }
                else { cli += [flag, value] }
            case "--sandbox", "-s":
                guard provider == .codex else { throw NativeRPCError.invalidArguments("Invalid Hoot sandbox setting.") }
                let values = ["read-only": "read-only", "workspace-write": "workspace-write", "danger-full-access": "danger-full-access"]
                guard let sandbox = values[value] else { throw NativeRPCError.invalidArguments("Unsupported Hoot Codex sandbox mode.") }
                session = session.setting("sandbox", .string(sandbox))
            case "--ask-for-approval", "-a":
                // SETTINGS-TRUTH line 70: every choice except Asks first adds `--sandbox X --ask-for-approval on-request`
                // (BackendAGSLaunch). The app server takes it as the thread's approval policy, so every choice starts.
                guard provider == .codex else { throw NativeRPCError.invalidArguments("Invalid Hoot approval setting.") }
                guard ["untrusted", "on-failure", "on-request", "never"].contains(value) else {
                    throw NativeRPCError.invalidArguments("Unsupported Hoot Codex approval policy.")
                }
                session = session.setting("approvalPolicy", .string(value))
            case "--config", "-c":
                // Preserve the same resolver's TOML setting on this app-server
                // invocation, never by editing the person's config.toml.
                guard !value.hasPrefix("mcp_servers") || (sessionTools && provider == .codex) else { throw NativeRPCError.invalidArguments("Hoot's MCP lease is supplied separately from profile configuration.") }
                if value.hasPrefix("developer_instructions=") {
                    let literal = String(value.dropFirst("developer_instructions=".count))
                    profileInstructions = try NativeRPCValue.parseJSON(Data(literal.utf8)).requireString("profile instructions")
                } else {
                    guard provider == .codex else { throw NativeRPCError.invalidArguments("This Gemini profile setting has no verified ACP equivalent.") }
                    cli += [flag, value]
                }
            default:
                guard provider == .gemini, geminiFlags.contains(flag) else {
                    throw NativeRPCError(code: "unsupported-policy", message: "Hoot cannot preserve \(flag) for \(provider.rawValue); no CLI was started.")
                }
                cli += [flag, value]
            }
        }
        var required: [String: Set<String>] = [:], codexServers: [NativeRPCValue.Field] = [], geminiServers: [NativeRPCValue] = []
        for field in mcp.fields ?? [] {
            let server = field.value
            guard let url = server["url"].string, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme),
                  parsed.user == nil, parsed.password == nil, !field.key.isEmpty else { throw NativeRPCError.invalidArguments("Hoot's MCP lease requires a valid HTTP server.") }
            let headers = server["headers"].isNullish ? NativeRPCValue.object([]) : try server["headers"].requireObject("MCP headers")
            guard headers.fields?.allSatisfy({ $0.value.string != nil }) == true else { throw NativeRPCError.invalidArguments("Invalid Hoot MCP headers.") }
            required[field.key] = Set(expectedTools.map { name in
                let prefix = "mcp__" + field.key + "__"
                return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
            })
            codexServers.append(.init(field.key, .object([.init("url", .string(url)), .init("http_headers", headers), .init("required", .bool(true))])))
            geminiServers.append(.object([.init("name", .string(field.key)), .init("type", .string("http")), .init("url", .string(url)),
                .init("headers", .array((headers.fields ?? []).map { .object([.init("name", .string($0.key)), .init("value", $0.value)]) }))]))
        }
        if !expectedTools.isEmpty && required.isEmpty { throw NativeRPCError(code: "unavailable", message: "Hoot's tool catalogue has no attached MCP lease.") }
        // FINAL-HOOT: the MCP page's servers, as every other session gets them (never required, never over the lease).
        for page in pageServers where required[page.name] == nil {
            let server = page.server, off = NativeRPCValue.array(page.toolsOff.map(NativeRPCValue.string))
            if server["transport"].string == "stdio", let command = server["command"].string {
                let args = server["args"].isNullish ? NativeRPCValue.array([]) : server["args"]
                let env = server["env"].fields ?? []
                var codex: [NativeRPCValue.Field] = [.init("command", .string(command)), .init("args", args), .init("required", .bool(false))]
                if !env.isEmpty { codex.append(.init("env", .object(env))) }
                if let folder = server["cwd"].string { codex.append(.init("cwd", .string(folder))) }
                if !page.toolsOff.isEmpty { codex.append(.init("disabled_tools", off)) }
                codexServers.append(.init(page.name, .object(codex)))
                geminiServers.append(.object([.init("name", .string(page.name)), .init("command", .string(command)), .init("args", args),
                    .init("env", .array(env.compactMap { field in field.value.string.map { .object([.init("name", .string(field.key)), .init("value", .string($0))]) } }))]))
            } else if ["http", "sse"].contains(server["transport"].string ?? ""), let url = server["url"].string {
                var codex: [NativeRPCValue.Field] = [.init("url", .string(url)), .init("required", .bool(false))]
                if !page.toolsOff.isEmpty { codex.append(.init("disabled_tools", off)) }
                codexServers.append(.init(page.name, .object(codex)))
                geminiServers.append(.object([.init("name", .string(page.name)), .init("type", .string(server["transport"].string ?? "http")),
                    .init("url", .string(url)), .init("headers", .array([]))]))
            }
        }
        // SETTINGS-TRUTH line 76: the folder's own instructions are saved as CLAUDE.md in Hoot's folder, which only
        // Claude Code reads by itself. On Codex and Gemini they are folded into the instructions here; nothing
        // (no AGENTS.md, no GEMINI.md) is ever written into the folder.
        if let folder = Self.folderInstructions(cwd: cwd) {
            instructions += (instructions.isEmpty ? "" : "\n\n") + folder
        }
        if provider == .codex {
            // An empty thread override would erase the worker's CLI lease and account restrictions.
            if !sessionTools || !codexServers.isEmpty { config = config.setting("mcp_servers", .object(codexServers)) }
            // Ask is an explicit app choice, not an invitation to inherit a user's `never` default.
            if !session.has("approvalPolicy") { session = session.setting("approvalPolicy", .string("on-request")) }
            session = BackendCodexApprovalPolicy.session(session.setting("config", config))
            let composed = [profileInstructions, instructions, ChatMarkdown.instruction].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !composed.isEmpty { session = session.setting("developerInstructions", .string(composed)) }
        } else {
            session = session.setting("mcpServers", .array(geminiServers))
        }
        // Last override wins over profile extras; this invocation must never wait on an update menu.
        if provider == .codex { cli += BackendAgentStartup.codexArguments }
        arguments = cli
        // The rich-chat drawing instruction goes to every AI, but on Gemini as an optional extra: a CLI that cannot take
        // prompt context still starts, without it (6 Nov). Codex has it in its developer instructions above.
        // APPMGMT (8 Nov): Gemini's form of the session note's browser line (Claude and Codex carry it in their note).
        setup = .init(cwd: cwd, session: session, expectedTools: required,
            instructions: provider == .gemini ? [profileInstructions, instructions].filter { !$0.isEmpty }.joined(separator: "\n\n") : "",
            optionalInstructions: provider == .gemini ? ChatMarkdown.instruction + "\n\n" + BackendANDROIDSessionPhoneNote.browserLine : "")
    }
}

extension BackendHootChatLaunchPlan {
    // A repeated CLI string flag can replace the earlier value. Merge existing
    // appended text first; the separate private prompt file remains unchanged.
    private static func richClaudeArguments(_ extra: [String]) throws -> [String] {
        var kept: [String] = [], prompts: [String] = [], index = 0
        while index < extra.count {
            if extra[index] == "--append-system-prompt" {
                guard index + 1 < extra.count else { throw NativeRPCError.invalidArguments("The appended chat instruction is missing.") }
                prompts.append(extra[index + 1]); index += 2
            } else { kept.append(extra[index]); index += 1 }
        }
        prompts.append(ChatMarkdown.instruction)
        return kept + ["--append-system-prompt", prompts.joined(separator: "\n\n")]
    }

    /// Claude Code: Hoot's lease file plus the MCP page's servers, in one private file (the lease stays as it is), and
    /// the page's tools that are off as disallowed tools. Unchanged when there is nothing to add.
    static func withPageServers(_ extra: [String], _ page: [BackendMcpPolicy.HootServer], privateDirectory: URL?) throws -> [String] {
        guard !page.isEmpty, let directory = privateDirectory, let index = extra.firstIndex(of: "--mcp-config"), index + 1 < extra.count else { return extra }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: extra[index + 1]), options: .mappedIfSafe)
        let lease = try NativeRPCValue.parseJSON(bytes, maximumBytes: 1_048_576)
        var servers = lease["mcpServers"].fields == nil ? NativeRPCValue.object([]) : lease["mcpServers"]
        var denied: [String] = []
        for entry in page where servers[entry.name].isNullish {
            let server = entry.server
            if server["transport"].string == "stdio", let command = server["command"].string {
                var fields: [NativeRPCValue.Field] = [.init("command", .string(command)), .init("args", server["args"].isNullish ? .array([]) : server["args"])]
                if server["env"].fields?.isEmpty == false { fields.append(.init("env", server["env"])) }
                servers = servers.setting(entry.name, .object(fields))
            } else if ["http", "sse"].contains(server["transport"].string ?? ""), let url = server["url"].string {
                servers = servers.setting(entry.name, .object([.init("type", .string(server["transport"].string ?? "http")), .init("url", .string(url))]))
            } else { continue }
            denied += entry.toolsOff.map { "mcp__" + entry.name + "__" + $0 }
        }
        let file = directory.appendingPathComponent("hoot-mcp-" + UUID().uuidString.prefix(8) + ".json")
        try BackendPrivateLaunchFiles.write(try lease.setting("mcpServers", servers).encodedJSON(pretty: true), to: file)
        var next = extra
        next[index + 1] = file.path
        if !denied.isEmpty { next += ["--disallowedTools", denied.joined(separator: ",")] }
        return next
    }
    /// The folder's CLAUDE.md (Hoot profile › Instructions, "the folder's own instructions") as a section for an AI that
    /// does not read CLAUDE.md itself. nil when there is none, it is empty, or it is not readable UTF-8 within 64 KiB.
    static func folderInstructions(cwd: String) -> String? {
        let file = URL(fileURLWithPath: cwd).appendingPathComponent("CLAUDE.md")
        guard let data = try? BackendAccountFiles.boundedRead(file, maximum: 65_536), let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "# The folder's own instructions (CLAUDE.md in \(cwd))\n\nThe person wrote these for Hoot and any session in this folder. Follow them as you would your own instructions file.\n\n" + text
    }
}

public protocol BackendHootChatToolRequirementsReceiving: Sendable {
    func toolRequirements(_ tools: BackendCopilotSessionTools?) async
}
