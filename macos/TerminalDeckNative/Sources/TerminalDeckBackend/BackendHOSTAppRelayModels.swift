import Foundation
import TerminalDeckNativeCore

/// The host authenticated the original MCP caller; the app must apply its
/// current real authority again before executing any tool or showing consent.
public struct BackendHOSTAppRelayCall: Sendable {
    public let id: UUID
    public let toolID: String
    public let wireName: String
    public let tier: BackendMCPTier
    public let context: BackendMCPCallContext
    public let taskProject: String?
    public let arguments: NativeRPCValue
}

public struct BackendHOSTAppRelayProjection: Codable, Sendable {
    public var attached: Bool
    public var appPID: Int32?
    public var pendingCalls: Int
    public var hostInstance: UUID
}

/// Private helper management calls, never advertised as MCP tools and never
/// attributed to an invented session caller. The app applies its real joins.
public struct BackendHOSTAppRelayControl: Sendable {
    public enum Operation: String, Codable, Sendable {
        case verifyClaims = "claims.verify", hookContext = "hooks.context", hookOpen = "hooks.open"
        case accountAuthorize = "account.authorize"
        case decisionValidate = "decision.validate"
    }
    public let id: UUID
    public let operation: Operation
    public let arguments: NativeRPCValue
    public let cancellation: BackendMCPCancellation
}

enum BackendHOSTAppRelayProtocol {
    static let version = 1
    // Native HTTP replies allow 16 MiB. Data's JSON/base64 envelope needs
    // headroom; preserving that existing limit must not shrink large replies.
    static let maximumFrame = 24 * 1024 * 1024
    static let maximumHandshake = 4_096
    static let maximumArguments = 256 * 1024
    static let maximumCalls = 128
    struct Control: Codable, Sendable {
        var operation: BackendHOSTAppRelayControl.Operation
        var argumentsJSON: Data
        init(operation: BackendHOSTAppRelayControl.Operation, arguments: NativeRPCValue) throws {
            self.operation = operation; argumentsJSON = try arguments.encodedJSON()
            guard argumentsJSON.count <= BackendHOSTAppRelayProtocol.maximumArguments else { throw BackendHOSTFailure.invalid("The private host control exceeds its limit.") }
        }
        func decode(id: UUID, cancellation: BackendMCPCancellation) throws -> BackendHOSTAppRelayControl {
            .init(id: id, operation: operation, arguments: try NativeRPCValue.parseJSON(argumentsJSON, maximumBytes: BackendHOSTAppRelayProtocol.maximumArguments), cancellation: cancellation)
        }
    }
    struct Call: Codable, Sendable {
        var toolID: String
        var wireName: String
        var tier: String
        var sessionID: String
        var machineID: String
        var projectRoot: String?
        var taskProject: String?
        var attended: Bool
        var allowedTools: [String]
        var allowedTiers: [String]
        var argumentsJSON: Data
        init(tool: BackendMCPTool, context: BackendMCPCallContext, taskProject: String?, arguments: NativeRPCValue) throws {
            toolID = tool.id; wireName = tool.wireName; tier = tool.tier.rawValue
            sessionID = context.sessionID; machineID = context.machineID; projectRoot = context.projectRoot
            self.taskProject = taskProject; attended = context.attended
            allowedTools = context.allowedTools.sorted(); allowedTiers = context.allowedTiers.map(\.rawValue).sorted()
            argumentsJSON = try arguments.encodedJSON()
        }
        func decode(id: UUID, cancellation: BackendMCPCancellation) throws -> BackendHOSTAppRelayCall {
            let tiers = allowedTiers.compactMap(BackendMCPTier.init(rawValue:))
            guard !sessionID.isEmpty, let tier = BackendMCPTier(rawValue: tier), tiers.count == allowedTiers.count,
                  Set(tiers).contains(tier), BackendMCPToolNames.permits(toolID, granted: Set(allowedTools)) || BackendMCPToolNames.permits(wireName, granted: Set(allowedTools)) else {
                throw BackendHOSTFailure.invalid("Invalid original MCP relay scope.")
            }
            let context = BackendMCPCallContext(sessionID: sessionID, machineID: machineID, projectRoot: projectRoot,
                attended: attended, allowedTools: Set(allowedTools), allowedTiers: Set(tiers), cancellation: cancellation)
            let arguments = try NativeRPCValue.parseJSON(argumentsJSON, maximumBytes: BackendHOSTAppRelayProtocol.maximumArguments)
            return .init(id: id, toolID: toolID, wireName: wireName, tier: tier, context: context, taskProject: taskProject, arguments: arguments)
        }
    }
    struct Reply: Codable, Sendable {
        var json: Data
        init(_ reply: BackendMCPToolReply) throws { json = try reply.wireValue.encodedJSON() }
        func decode() throws -> BackendMCPToolReply {
            let value = try NativeRPCValue.parseJSON(json, maximumBytes: 16 * 1024 * 1024)
            guard let content = value["content"].elements, let isError = value["isError"].bool else { throw BackendHOSTFailure.invalid("Invalid original MCP reply.") }
            return .init(content: content, structuredContent: value["structuredContent"] == .missing ? nil : value["structuredContent"], isError: isError)
        }
    }
    struct Frame: Codable, Sendable {
        enum Operation: String, Codable, Sendable { case attach, attached, call, control, reply, cancel, detach }
        var version = BackendHOSTAppRelayProtocol.version
        var operation: Operation
        var instance: UUID
        var attachment: UUID?
        var id: UUID?
        var secret: String?
        var pid: Int32?
        var call: Call?
        var control: Control?
        var reply: Reply?
        var error: String?
        init(_ operation: Operation, instance: UUID, attachment: UUID? = nil, id: UUID? = nil) {
            self.operation = operation; self.instance = instance; self.attachment = attachment; self.id = id
        }
    }
    static let unavailable = "Terminal Deck's app is disconnected. This app-dependent tool is unavailable until the app reattaches; the session and its grant were kept."
    /// 18 Oct (#109, #162): a full call table is a busy app, not a gone one; only that call is refused.
    static let busy = "Terminal Deck's app is busy with too many tool calls at once. Try this tool again in a moment; the session and its grant were kept."
}
