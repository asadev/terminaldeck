import Foundation
import TerminalDeckNativeCore

public struct BackendCopilotRemoteOutcome: Equatable, Sendable {
    public let ok: Bool
    public let code: String?
    public let message: String?
    public static let success = Self(ok: true, code: nil, message: nil)
    public static func unavailable(_ message: String) -> Self { .init(ok: false, code: "unavailable", message: message) }
    public static func unauthorized(_ message: String) -> Self { .init(ok: false, code: "unauthorized", message: message) }
}
public struct BackendCopilotRemoteFileText: Equatable, Sendable {
    public let text: String
    public let error: String?
    public init(text: String, error: String?) { self.text = error == nil ? text : ""; self.error = error }
}
public struct BackendCopilotRemoteFileWrite: Equatable, Sendable {
    public let ok: Bool
    public let error: String?
    public init(ok: Bool, error: String?) { self.ok = ok; self.error = error }
}
/// remote/copilot-files.ts. Providers own all path lookup, whole-file size checks,
/// write validation, memory-name checks and paired-device audit attribution.
public protocol BackendCopilotFilesProviding: Sendable {
    func list() async throws -> [NativeRPCValue]
    func read(_ target: BackendRemoteProtocol.CopilotFileTarget) async throws -> BackendCopilotRemoteFileText
    func write(_ target: BackendRemoteProtocol.CopilotFileTarget, text: String) async throws -> BackendCopilotRemoteFileWrite
    func reset() async throws -> BackendCopilotRemoteFileWrite
    func forget(_ name: String) async throws -> BackendCopilotRemoteFileWrite
}
public struct BackendCopilotRemoteDesk: Sendable {
    public let status: String
    public let profile: String?
    public let signedIn: Bool?
    public let available: Bool
    public let reason: String?
    public let interactive: Bool
    public init(status: String, profile: String?, signedIn: Bool?, available: Bool, reason: String?, interactive: Bool) {
        self.status = status; self.profile = profile; self.signedIn = signedIn
        self.available = available; self.reason = reason; self.interactive = interactive
    }
}
public struct BackendCopilotRemoteChatUpdate: Sendable {
    public let messages: [NativeRPCValue]
    public let reset: Bool
    public init(messages: [NativeRPCValue], reset: Bool) { self.messages = messages; self.reset = reset }
}
public struct BackendCopilotRemoteSpawnRequest: Sendable {
    public let cwd: String
    public let mcpConfig: String
    public let deviceID: String
    public init(cwd: String, mcpConfig: String, deviceID: String) { self.cwd = cwd; self.mcpConfig = mcpConfig; self.deviceID = deviceID }
}
/// Serving caller-table operations, not a second credential verifier. register
/// must establish the entry before the process starts. revoke cancels live calls.
public protocol BackendCopilotRemoteCallerRegistry: Sendable {
    func register(token: String, endpointURL: URL, attended: Bool, caller: @escaping @Sendable () async -> BackendDeckCoreSecurityCaller,
                  cancellation: BackendMCPCancellation) async throws -> BackendMCPRegistration
    func revoke(_ registration: BackendMCPRegistration) async
}
public struct BackendCopilotRemoteRunDependencies: Sendable {
    public let access: BackendCopilotRemoteAccess
    public let consent: @Sendable () async -> BackendDeckCoreSecurityConsentBroker?
    public let callers: any BackendCopilotRemoteCallerRegistry
    public let endpoint: @Sendable () async throws -> BackendMCPEndpointDescription?
    public let root: @Sendable () async throws -> String
    public let spawn: @Sendable (BackendCopilotRemoteSpawnRequest) async throws -> String
    public let isAlive: @Sendable (String) async -> Bool
    public let stop: @Sendable (String) async throws -> Void
    public let say: @Sendable (String, String) async throws -> Void
    public let interrupt: @Sendable (String) async throws -> Void
    public let desk: @Sendable () async throws -> BackendCopilotRemoteDesk
    public let cost: @Sendable () async throws -> (tools: Int, turnTokens: Int)
    public let setInteractive: @Sendable (Bool) async throws -> Void
    public let sessions: @Sendable () async throws -> [NativeRPCValue]
    public let log: @Sendable (Int, String?) async throws -> (rows: [NativeRPCValue], more: Bool)
    public let chat: @Sendable (String, @escaping @Sendable (BackendCopilotRemoteChatUpdate) async -> Void) async throws -> (@Sendable () -> Void)
    public let now: @Sendable () -> Double
    public let graceMilliseconds: Double
    public let hidden: BackendRemoteServeSessionHidden
    public init(access: BackendCopilotRemoteAccess, consent: @escaping @Sendable () async -> BackendDeckCoreSecurityConsentBroker?,
                callers: any BackendCopilotRemoteCallerRegistry,
                endpoint: @escaping @Sendable () async throws -> BackendMCPEndpointDescription?,
                root: @escaping @Sendable () async throws -> String,
                spawn: @escaping @Sendable (BackendCopilotRemoteSpawnRequest) async throws -> String,
                isAlive: @escaping @Sendable (String) async -> Bool, stop: @escaping @Sendable (String) async throws -> Void,
                say: @escaping @Sendable (String, String) async throws -> Void, interrupt: @escaping @Sendable (String) async throws -> Void,
                desk: @escaping @Sendable () async throws -> BackendCopilotRemoteDesk,
                cost: @escaping @Sendable () async throws -> (tools: Int, turnTokens: Int),
                setInteractive: @escaping @Sendable (Bool) async throws -> Void,
                sessions: @escaping @Sendable () async throws -> [NativeRPCValue],
                log: @escaping @Sendable (Int, String?) async throws -> (rows: [NativeRPCValue], more: Bool),
                chat: @escaping @Sendable (String, @escaping @Sendable (BackendCopilotRemoteChatUpdate) async -> Void) async throws -> (@Sendable () -> Void),
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                graceMilliseconds: Double = BackendCopilotRemoteSurface.graceMilliseconds,
                hidden: BackendRemoteServeSessionHidden = .shared) {
        self.access = access; self.consent = consent; self.callers = callers; self.endpoint = endpoint; self.root = root
        self.spawn = spawn; self.isAlive = isAlive; self.stop = stop; self.say = say; self.interrupt = interrupt
        self.desk = desk; self.cost = cost; self.setInteractive = setInteractive; self.sessions = sessions; self.log = log; self.chat = chat
        self.now = now; self.graceMilliseconds = graceMilliseconds.isFinite ? max(0, graceMilliseconds.rounded(.towardZero)) : BackendCopilotRemoteSurface.graceMilliseconds
        self.hidden = hidden
    }
}
