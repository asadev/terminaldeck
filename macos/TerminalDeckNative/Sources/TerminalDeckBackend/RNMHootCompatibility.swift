import Foundation
import TerminalDeckNativeCore
#if RNM_FOCUSED_BACKEND
import TerminalDeckBackend
#endif

/// Phase A naming only. Caller identity, tiers, current grants, consent and
/// cancellation remain decisions of the existing MCP servers.
public enum RNMHootMCPCompatibility {
    private struct Names: Sendable {
        let suffix: String
        var id: String { "hoot." + suffix }
        var wire: String { "hoot_" + suffix }
        var oldID: String { "copilot." + suffix }
        var oldWire: String { "copilot_" + suffix }
        var all: Set<String> { [id, wire, oldID, oldWire] }
    }
    // These are the four aliases in BackendDeckToolsAppMetadata. A prefix
    // replacement would accidentally rename unrelated tools or invent access.
    private static let names = ["state", "run", "instructions", "memory"].map { Names(suffix: $0) }

    public static func canonicalName(_ name: String) -> String {
        guard let group = names.first(where: { $0.all.contains(name) }) else { return name }
        return name.contains("_") ? group.wire : group.id
    }

    public static func equivalentNames(_ name: String) -> Set<String> {
        names.first(where: { $0.all.contains(name) })?.all ?? [name]
    }

    /// Compare only the same operation. This does not add a tool to a grant.
    /// Resolve a real registered tool and apply its original policy afterward.
    public static func permits(_ name: String, granted: Set<String>) -> Bool {
        !equivalentNames(name).isDisjoint(with: granted)
    }

    /// Apply the existing task-profile rule grammar to every spelling of one
    /// registered operation. A denied legacy alias must also deny its new name.
    public static func profilePermits(server: String, id: String, wire: String,
                                      allowed: [String]?, denied: [String]) -> Bool {
        // Preserve TAG's exact candidate set for every unrelated operation.
        // In particular, a wire without '_' still has a full MCP name, and an
        // internal id must never be externalized as another callable wire.
        var candidates: Set<String> = [id, wire, "mcp__" + server, "mcp__" + server + "__" + wire]
        if let group = names.first(where: { $0.all.contains(id) && $0.all.contains(wire) }) {
            candidates.formUnion(group.all)
            candidates.formUnion(["mcp__" + server + "__" + group.wire,
                                  "mcp__" + server + "__" + group.oldWire])
        }
        if denied.contains(where: { rule in candidates.contains { BackendTAGToolPolicy.covers(rule, tool: $0) } }) { return false }
        return allowed.map { rules in rules.contains { rule in candidates.contains { BackendTAGToolPolicy.covers(rule, tool: $0) } } } ?? true
    }

    /// Native session MCP has no metadata alias field. Contribute one hidden
    /// spec for the legacy dot/underscore names, using the SAME gated handler.
    /// The owner should use replaceTools so collision checks are atomic.
    public static func registrations(
        _ contribution: [(BackendMCPTool, BackendNativeMCPServer.Handler)]
    ) throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        var result = contribution
        for (tool, handler) in contribution {
            guard let group = names.first(where: { $0.id == tool.id && $0.wire == tool.wireName }) else { continue }
            let alias = try BackendMCPTool(id: group.oldID, wireName: group.oldWire,
                description: tool.description, inputSchema: tool.inputSchema, tier: tool.tier,
                advertised: false, implementation: tool.implementation)
            result.append((alias, handler))
        }
        return result
    }
}

/// Normalize incoming names into the existing v1 vocabulary before the sealed
/// schema validator and authorization gates. This is not a payload migration.
public enum RNMHootWireCompatibility {
    public static let clientSuffixes: Set<String> = [
        "hello", "bye", "attach", "detach", "state", "sessions", "pending",
        "start", "cancel", "stop", "answer", "say", "log", "interactive",
        "files", "file.read", "file.write", "file.reset", "memory.delete"
    ]
    public static let serverSuffixes: Set<String> = [
        "state", "chat", "tool", "sessions", "log", "pending", "grant",
        "ask", "settled", "files.rows", "file.text"
    ]

    public static func incomingClientType(_ type: String) -> String {
        legacyType(type, allowed: clientSuffixes)
    }
    public static func incomingServerType(_ type: String) -> String {
        legacyType(type, allowed: serverSuffixes)
    }
    private static func legacyType(_ type: String, allowed: Set<String>) -> String {
        guard type.hasPrefix("hoot.") else { return type }
        let suffix = String(type.dropFirst(5))
        return allowed.contains(suffix) ? "copilot." + suffix : type
    }

    /// Only negotiated feature spellings; capabilities still confer no grant.
    public static func incomingCapability(_ capability: String) -> String {
        switch capability {
        case "hoot": return "copilot"
        case "hoot.files": return "copilot.files"
        default: return capability
        }
    }
    private static func capabilities(in value: NativeRPCValue) -> NativeRPCValue {
        guard let entries = value["capabilities"].elements else { return value }
        return value.setting("capabilities", .array(entries.map { entry in
            entry.string.map { .string(incomingCapability($0)) } ?? entry
        }))
    }
    public static func incomingClientEnvelope(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let type = value["t"].string else { return value }
        var result = value
        let legacy = incomingClientType(type)
        if legacy != type { result = result.setting("t", .string(legacy)) }
        if type == "hello" { result = capabilities(in: result) }
        return result
    }
    public static func incomingServerEnvelope(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let type = value["t"].string else { return value }
        var result = value
        let legacy = incomingServerType(type)
        if legacy != type { result = result.setting("t", .string(legacy)) }
        if type == "welcome" {
            result = capabilities(in: result)
            // Welcome's one known assistant-link field. An existing legacy
            // field remains authoritative if both spellings are supplied.
            if result["copilot"] == .missing, result["hoot"] != .missing {
                result = result.setting("copilot", result["hoot"])
            }
        }
        return result
    }
    public static func parseIncomingClient(_ value: NativeRPCValue) -> BackendRemoteClientParse {
        BackendRemoteProtocol.parseClientMessage(incomingClientEnvelope(value))
    }
}
