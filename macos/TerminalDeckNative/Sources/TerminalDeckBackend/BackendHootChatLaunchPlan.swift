import Foundation
import TerminalDeckNativeCore

/// Backend-owned flags/config only. It neither writes account settings nor
/// accepts paths, environment, tool widening or permission mode from chat RPCs.
public struct BackendHootChatLaunchPlan: Sendable {
    public let arguments: [String]
    public let setup: BackendHootChatSetup?
    public init(provider: HootChatProvider, cwd: String, sessionID: String?, extra: [String], expectedTools: Set<String> = []) throws {
        if provider == .claude {
            arguments = try BackendHootChatCLI.claudeArguments(sessionID: sessionID, extra: extra)
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
            case "--config", "-c":
                // Preserve the same resolver's TOML setting on this app-server
                // invocation, never by editing the person's config.toml.
                guard !value.hasPrefix("mcp_servers") else { throw NativeRPCError.invalidArguments("Hoot's MCP lease is supplied separately from profile configuration.") }
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
        if provider == .codex {
            config = config.setting("mcp_servers", .object(codexServers))
            session = session.setting("config", config)
            let composed = [profileInstructions, instructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !composed.isEmpty { session = session.setting("developerInstructions", .string(composed)) }
        } else {
            session = session.setting("mcpServers", .array(geminiServers))
        }
        arguments = cli
        setup = .init(cwd: cwd, session: session, expectedTools: required,
            instructions: provider == .gemini ? [profileInstructions, instructions].filter { !$0.isEmpty }.joined(separator: "\n\n") : "")
    }
}

public protocol BackendHootChatToolRequirementsReceiving: Sendable {
    func toolRequirements(_ tools: BackendCopilotSessionTools?) async
}
