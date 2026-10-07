import Foundation
import TerminalDeckNativeCore

/// Authenticated deck caller metadata. The central door supplies this; tool arguments never do.
public struct BackendDeckToolsMachinesContext: Sendable {
    public enum Kind: String, Sendable { case local, key, session, remote, unknown }
    public let kind: Kind
    public let attended: Bool
    public let sessionID: String?
    public let machineID: String
    public let keyID: String?
    public let deviceID: String?
    public let folders: [String]?
    public let rpc: NativeRPCContext
    public let startedByCopilot: @Sendable (String) async -> Bool
    public let noteStarted: @Sendable (String) async -> Void
    public init(kind: Kind, attended: Bool, sessionID: String? = nil, machineID: String = "", keyID: String? = nil,
                deviceID: String? = nil, folders: [String]? = nil, rpc: NativeRPCContext,
                startedByCopilot: @escaping @Sendable (String) async -> Bool,
                noteStarted: @escaping @Sendable (String) async -> Void) {
        self.kind = kind; self.attended = attended; self.sessionID = sessionID; self.machineID = machineID
        self.keyID = keyID; self.deviceID = deviceID; self.folders = folders; self.rpc = rpc
        self.startedByCopilot = startedByCopilot; self.noteStarted = noteStarted
    }
    public var actsAsOwner: Bool { kind == .local || kind == .key }
    public var holder: String {
        if kind == .session, let sessionID { return "session:\(machineID):\(sessionID)" }
        if kind == .key, let keyID { return "key:\(keyID)" }
        return "copilot"
    }
}

public struct BackendDeckToolsMachinesOutput: Sendable {
    public let value: NativeRPCValue
    public let summary: NativeRPCValue
    public init(_ value: NativeRPCValue, _ summary: NativeRPCValue = .object([])) { self.value = value; self.summary = summary }
}
public struct BackendDeckToolsMachinesPolicy: Sendable {
    public let tool: BackendMCPTool
    public let arguments: NativeRPCValue
    public let loggedArguments: NativeRPCValue
    public let tier: BackendMCPTier
    public let ownerMustAnswer: Bool
    public let spends: String
    public let sentence: String
    public init(tool: BackendMCPTool, arguments: NativeRPCValue, loggedArguments: NativeRPCValue,
                tier: BackendMCPTier, ownerMustAnswer: Bool = false, spends: String = "changes", sentence: String) {
        self.tool = tool; self.arguments = arguments; self.loggedArguments = loggedArguments; self.tier = tier
        self.ownerMustAnswer = ownerMustAnswer; self.spends = spends; self.sentence = sentence
    }
}
/// Owns schema validation, tier/consent/budget and unconditional success/failure logging.
/// execute MUST gate before invoking the supplied operation and log only loggedArguments + output.summary.
public protocol BackendDeckToolsMachinesEnvironment: Sendable {
    func context(for call: BackendMCPCallContext) async throws -> BackendDeckToolsMachinesContext
    func validate(arguments: NativeRPCValue, schema: NativeRPCValue) async throws
    func execute(context: BackendDeckToolsMachinesContext, policy: BackendDeckToolsMachinesPolicy,
                 operation: @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply
    /// Records setup/schema/precheck failures too. Only loggedArguments are safe to persist.
    /// execute returns already-logged failures; a thrown failure is recorded here exactly once.
    func failed(call: BackendMCPCallContext, tool: BackendMCPTool, policy: BackendDeckToolsMachinesPolicy?,
                loggedArguments: NativeRPCValue, error: any Error) async -> BackendMCPToolReply
}

/// A bounded channel slice, implemented by the actual machine/server/remote channel owners.
public protocol BackendDeckToolsMachinesChannels: Sendable {
    func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue
}
/// Registry adapter shares BackendMachineChannels/BackendMachineMCP's real handlers.
/// It translates the already-written Swift channel projection to the original area shape.
public struct BackendDeckToolsMachinesRegistry: BackendDeckToolsMachinesChannels, Sendable {
    public let registry: NativeChannelRegistry
    private let localPairingAvailable: @Sendable () async -> Bool
    public init(registry: NativeChannelRegistry, localPairingAvailable: @escaping @Sendable () async -> Bool = { false }) {
        self.registry = registry; self.localPairingAvailable = localPairingAvailable
    }
    public func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        guard Self.allowed.contains(channel) else { throw BackendDeckToolsSupport.unavailable(channel) }
        if ["machines:code", "machines:code:cancel"].contains(channel), !(await localPairingAvailable()) {
            throw BackendDeckToolsSupport.unavailable("the native local machine pairing host")
        }
        guard await registry.has(channel) else { throw BackendDeckToolsSupport.unavailable(channel) }
        // A separate request ID per round trip permits the independent reads the source makes together.
        let original = context.rpc
        let rpc = NativeRPCContext(caller: original.caller, ownerID: original.ownerID, origin: original.origin, capabilities: original.capabilities)
        let answer = try await registry.invoke(channel, context: rpc, arguments: arguments)
        if ["machines:connect", "machines:disconnect", "machines:rename", "machines:forget", "machines:drive-windows"].contains(channel), answer.fields == nil {
            return try await registry.invoke("machines:list", context: rpc, arguments: [])
        }
        if channel == "machines:pair", answer["offer"].isNullish, !answer["machine"].isNullish {
            return answer.setting("offer", answer["machine"])
        }
        return answer
    }
    public static let allowed: Set<String> = [
        "machines:list",
        "machines:host:read",
        "machines:logins:read",
        "machines:github:read",
        "machines:controls:read",
        "machines:account:read",
        "machines:usage:read",
        "machines:create",
        "machines:send",
        "machines:close",
        "machines:session:rename",
        "machines:attach",
        "machines:controls:apply",
        "machines:account:switch",
        "machines:copilot:attach",
        "machines:copilot:start",
        "machines:copilot:refresh",
        "machines:copilot:say",
        "machines:ports",
        "machines:reach",
        "machines:reach:close",
        "machines:open",
        "machines:upload",
        "machines:upload:cancel",
        "machines:code",
        "machines:code:cancel",
        "machines:pair",
        "machines:forget",
        "machines:connect",
        "machines:disconnect",
        "machines:rename",
        "machines:drive-windows",
        "machines:host:restart",
        "machines:host:stop",
        "machines:logins:signin",
        "machines:logins:signout",
        "machines:github:connect",
        "machines:github:cancel",
        "machines:github:disconnect",
        "servers:list",
        "servers:preview",
        "servers:setup:look",
        "servers:setup:state",
        "servers:host:look",
        "servers:host:state",
        "servers:ports",
        "servers:folder",
        "servers:start-in",
        "servers:grant-state",
        "servers:keys",
        "servers:key-read",
        "servers:key-pick",
        "servers:controls:read",
        "servers:controls:apply",
        "servers:shell:account",
        "servers:shell:open",
        "servers:shell:write",
        "servers:shell:close",
        "servers:reach",
        "servers:reach:close",
        "servers:close",
        "servers:setup:cancel",
        "servers:host:cancel",
        "servers:add",
        "servers:rename",
        "servers:forget",
        "servers:revoke",
        "servers:start-in:set",
        "servers:drive-windows",
        "servers:upload",
        "servers:setup:install",
        "servers:setup:signin",
        "servers:setup:signout",
        "servers:setup:remove",
        "servers:host:install",
        "servers:host:pair",
        "servers:host:link",
        "servers:host:remove",
        "remote:status",
        "remote:devices",
        "remote:kinds",
        "remote:folders",
        "remote:accounts",
        "remote:sessions",
        "remote:sessions:running",
        "remote:windows",
        "power:lid-awake:get",
        "confine:state",
        "tailnet:status",
        "remote:start",
        "remote:stop",
        "remote:pair",
        "remote:pair:cancel",
        "remote:device:approve",
        "remote:device:revoke",
        "remote:folders:set",
        "remote:accounts:set",
        "remote:sessions:set",
        "remote:windows:set",
        "remote:connection:disconnect",
        "remote:tunnel:stop",
        "power:lid-awake:set",
    ]
}

enum BackendDeckToolsMachinesShared {
    typealias V = NativeRPCValue
    static func object(_ fields: [String: V]) -> V { .object(fields.sorted { $0.key < $1.key }.map { .init($0.key, $0.value) }) }
    static func refused(_ message: String, _ code: String = "not-permitted") -> BackendDeckCoreSecurityRefusal { .init(BackendDeckCoreSecurityRefusalReason(rawValue: code) ?? .notPermitted, message) }
    static func hereOnly(_ context: BackendDeckToolsMachinesContext, _ what: String) throws {
        guard context.actsAsOwner else { throw refused("\(what) only works for the person at this computer, Hoot (the assistant they talk to here), and AI apps they gave an access key to. A paired device cannot do it from here. Say what you would have done and let them do it.", "not-granted") }
    }
    static func ok(_ answer: V, fallback: String = "That did not change.", key: String = "message") throws -> V {
        guard answer["ok"].bool == true else { throw refused(answer[key].string ?? fallback) }; return answer
    }
    static func empty(_ value: V, count: Int, reason: String) -> V {
        value.setting("empty", .bool(count == 0)).setting("emptyReason", .string(count == 0 ? reason : ""))
    }
    static func emptySummary(_ count: Int) -> V { object(["empty": .bool(count == 0)]) }
    static func sendable(_ path: String, dataRoot: URL, home: URL) throws -> String {
        guard path.hasPrefix("/") else { throw BackendDeckToolsArgs.bad("path must be an absolute path to a file on this computer") }
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        let denied = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config/gh", "Library/Keychains"].map { home.appendingPathComponent($0).path } + [dataRoot.standardizedFileURL.path]
        for folder in denied where clean == folder || clean.hasPrefix(folder + "/") {
            throw refused("\(clean) is inside \(folder), where sign-in keys and credentials are kept. Files there are never sent from this computer by a tool.")
        }
        return clean
    }
}

/// Closure adapter for the central deck gate. There is deliberately no allow-all executor.
public struct BackendDeckToolsMachinesEnvironmentAdapter: BackendDeckToolsMachinesEnvironment, Sendable {
    public typealias Resolve = @Sendable (BackendMCPCallContext) async throws -> BackendDeckToolsMachinesContext
    public typealias Execute = @Sendable (BackendDeckToolsMachinesContext, BackendDeckToolsMachinesPolicy,
        @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply
    public typealias Failure = @Sendable (BackendMCPCallContext, BackendMCPTool, BackendDeckToolsMachinesPolicy?, NativeRPCValue, any Error) async -> BackendMCPToolReply
    private let resolve: Resolve
    private let perform: Execute
    private let failure: Failure
    public init(resolve: @escaping Resolve, execute: @escaping Execute, failed: @escaping Failure) {
        self.resolve = resolve; perform = execute; failure = failed
    }
    public func context(for call: BackendMCPCallContext) async throws -> BackendDeckToolsMachinesContext { try await resolve(call) }
    public func validate(arguments: NativeRPCValue, schema: NativeRPCValue) throws {
        try BackendDeckCoreCatalogueSchema.check(schema: schema, arguments: arguments)
    }
    public func execute(context: BackendDeckToolsMachinesContext, policy: BackendDeckToolsMachinesPolicy,
        operation: @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply {
        try await perform(context, policy, operation)
    }
    public func failed(call: BackendMCPCallContext, tool: BackendMCPTool, policy: BackendDeckToolsMachinesPolicy?,
        loggedArguments: NativeRPCValue, error: any Error) async -> BackendMCPToolReply {
        await failure(call, tool, policy, loggedArguments, error)
    }
}
