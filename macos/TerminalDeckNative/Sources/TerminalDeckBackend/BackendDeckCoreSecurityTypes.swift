import Foundation
import TerminalDeckNativeCore

/// Explicit identity resolved from the credential, never from tool arguments.
public struct BackendDeckCoreSecurityCaller: Sendable {
    public enum Kind: String, Sendable { case local, remote, session, key }
    public let kind: Kind
    public let tiers: Set<BackendMCPTier>
    public let deviceID: String?
    public let keyID: String?
    public let keyName: String?
    public let askFirst: Bool?
    public let tasks: Bool
    public let folders: [String]?
    public let sessionID: String?
    public let machineID: String?
    /// Native session capability provenance, supplied by the existing lease
    /// grant only. This is never read from wire metadata or tool arguments.
    public let projectRoot: String?
    public init(kind: Kind, tiers: Set<BackendMCPTier>, deviceID: String? = nil,
                keyID: String? = nil, keyName: String? = nil, askFirst: Bool? = nil,
                tasks: Bool = false, folders: [String]? = nil, sessionID: String? = nil, machineID: String? = nil,
                projectRoot: String? = nil) {
        self.kind = kind; self.tiers = tiers; self.deviceID = deviceID; self.keyID = keyID
        self.keyName = keyName; self.askFirst = askFirst; self.tasks = tasks; self.folders = folders
        self.sessionID = sessionID; self.machineID = machineID; self.projectRoot = projectRoot
    }
    public static let local = Self(kind: .local, tiers: [.read, .act, .alter])
    public var actsAsOwner: Bool { kind == .local || kind == .key }
    public var starter: String { kind == .key && keyID != nil ? "key:\(keyID!)" : "copilot" }
    public var sessionOrigin: NativeRPCValue {
        kind == .key ? .object([.init("origin", .string("app")), .init("originApp", .string(keyName ?? "An AI app"))]) : .object([.init("origin", .string("copilot"))])
    }
    public var consentSurface: String {
        if kind == .remote, let deviceID { return "device:" + deviceID }
        if kind == .key, let keyID { return "key:" + keyID }
        return "window"
    }
    public var wireValue: NativeRPCValue {
        .object([.init("kind", .string(kind.rawValue)), .init("deviceId", deviceID.map(NativeRPCValue.string) ?? .missing),
                 .init("keyId", keyID.map(NativeRPCValue.string) ?? .missing), .init("keyName", keyName.map(NativeRPCValue.string) ?? .missing)])
    }
}

public enum BackendDeckCoreSecurityRefusalReason: String, Sendable {
    case noApprover = "no-approver", declined, timeout, approverGone = "approver-gone"
    case shuttingDown = "shutting-down", callerGone = "caller-gone", tooManyPending = "too-many-pending"
    case rateLimited = "rate-limited", notPermitted = "not-permitted", notGranted = "not-granted"
    case unattended = "not-permitted-unattended", whileDriving = "not-permitted-while-driving"
}
public struct BackendDeckCoreSecurityRefusal: Error, LocalizedError, Sendable {
    public let reason: BackendDeckCoreSecurityRefusalReason
    public let message: String
    public init(_ reason: BackendDeckCoreSecurityRefusalReason, _ message: String) { self.reason = reason; self.message = message }
    public var errorDescription: String? { message }
}

public struct BackendDeckCoreSecurityCallContext: Sendable {
    public let native: BackendMCPCallContext
    public let caller: BackendDeckCoreSecurityCaller
    public let callID: String
    public let attended: Bool
    public let granted: Set<String>?
    public let sessionLimits: NativeRPCValue
    public let now: @Sendable () -> Double
    public let startedByCopilot: @Sendable (String) -> Bool
    public let noteStarted: @Sendable (String) -> Void
    public var cancellation: BackendMCPCancellation { native.cancellation }
}
/// Accepted entry into one running deck-control call (`prepareEffect`). It
/// binds the call ID, tool, arguments and effective tier and expires with that
/// call's cancellation. It is not a credential and grants nothing elsewhere.
public struct BackendDeckCoreSecurityEffectProof: Sendable {
    public let id: UUID
    public let callID: String
    public let tool: String
    public let tier: BackendMCPTier
    public let arguments: NativeRPCValue
    let lease: BackendDeckCoreSecurityEffectLease
    /// True once the call's request is cancelled or the call has finished.
    public var isExpired: Bool { lease.isExpired }
}
/// The lifetime of one running call: its cancellation, or the call's end.
final class BackendDeckCoreSecurityEffectLease: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    let cancellation: BackendMCPCancellation
    init(cancellation: BackendMCPCancellation) { self.cancellation = cancellation }
    func end() { lock.withLock { ended = true } }
    var isExpired: Bool { lock.withLock { ended } || cancellation.isCancelled }
}
public struct BackendDeckCoreSecurityToolOutput: Sendable {
    public let value: NativeRPCValue
    public let summary: NativeRPCValue?
    public init(value: NativeRPCValue, summary: NativeRPCValue? = nil) { self.value = value; self.summary = summary }
}

/// Tool policy stays with the actual operation through aliases and tools.run.
public struct BackendDeckCoreSecurityToolPolicy: Sendable {
    public typealias Context = BackendDeckCoreSecurityCallContext
    public typealias Handler = @Sendable (NativeRPCValue, Context) async throws -> BackendDeckCoreSecurityToolOutput
    public let tool: BackendMCPTool
    public let aliases: [String]
    public let audience: String?
    public let keyRequiresTasks: Bool
    public let spendsDeviceInput: Bool
    public let summary: @Sendable (NativeRPCValue, Context) throws -> String
    public let precheck: (@Sendable (NativeRPCValue, Context) throws -> Void)?
    /// Actor-backed persistence/authority checks finish before consent, without
    /// blocking a native actor or weakening the original synchronous grammar.
    public let precheckAsync: (@Sendable (NativeRPCValue, Context) async throws -> Void)?
    public let escalate: (@Sendable (NativeRPCValue, Context) throws -> BackendMCPTier?)?
    public let ownerMustAnswer: (@Sendable (NativeRPCValue) throws -> Bool)?
    public let redactArgs: (@Sendable (NativeRPCValue) throws -> NativeRPCValue)?
    public let run: Handler
    public init(tool: BackendMCPTool, aliases: [String] = [], audience: String? = nil, keyRequiresTasks: Bool = false,
                spendsDeviceInput: Bool = false,
                summary: @escaping @Sendable (NativeRPCValue, Context) throws -> String,
                precheck: (@Sendable (NativeRPCValue, Context) throws -> Void)? = nil,
                precheckAsync: (@Sendable (NativeRPCValue, Context) async throws -> Void)? = nil,
                escalate: (@Sendable (NativeRPCValue, Context) throws -> BackendMCPTier?)? = nil,
                ownerMustAnswer: (@Sendable (NativeRPCValue) throws -> Bool)? = nil,
                redactArgs: (@Sendable (NativeRPCValue) throws -> NativeRPCValue)? = nil,
                run: @escaping Handler) {
        self.tool = tool; self.aliases = aliases; self.audience = audience; self.keyRequiresTasks = keyRequiresTasks
        self.spendsDeviceInput = spendsDeviceInput; self.summary = summary; self.precheck = precheck
        self.precheckAsync = precheckAsync
        self.escalate = escalate; self.ownerMustAnswer = ownerMustAnswer; self.redactArgs = redactArgs; self.run = run
    }
    public func visible(to granted: Set<String>?, caller: BackendDeckCoreSecurityCaller) -> Bool {
        (granted == nil || granted!.contains(tool.id) || granted!.contains(tool.wireName) || aliases.contains { granted!.contains($0) }) &&
        !(audience == "keys" && caller.kind != .key) && !(audience == "copilot" && caller.kind == .key) &&
        !(caller.kind == .key && keyRequiresTasks && !caller.tasks)
    }
}

public struct BackendDeckCoreSecurityCallOptions: Sendable {
    public let caller: BackendDeckCoreSecurityCaller
    public let attended: Bool
    public let granted: Set<String>?
    public let cancellation: BackendMCPCancellation
    public let sessionLimits: NativeRPCValue
    public init(caller: BackendDeckCoreSecurityCaller = .local, attended: Bool = true, granted: Set<String>? = nil,
                cancellation: BackendMCPCancellation = BackendMCPCancellation(), sessionLimits: NativeRPCValue = .missing) {
        self.caller = caller; self.attended = attended; self.granted = granted
        self.cancellation = cancellation; self.sessionLimits = sessionLimits
    }
}

public protocol BackendDeckCoreSecurityEvents: Sendable {
    func list() async throws -> NativeRPCValue
    func subscribe(keyID: String, via: String, parameters: NativeRPCValue) async throws -> NativeRPCValue
    func unsubscribe(keyID: String, parameters: NativeRPCValue) async throws -> NativeRPCValue
}
public struct BackendDeckCoreSecurityProtocolError: Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public let data: NativeRPCValue
    public init(code: Int, message: String, data: NativeRPCValue = .missing) { self.code = code; self.message = message; self.data = data }
    public var errorDescription: String? { message }
}
