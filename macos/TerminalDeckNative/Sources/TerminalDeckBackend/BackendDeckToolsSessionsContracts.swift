import Foundation
import TerminalDeckNativeCore

/// Source caller identity supplied by deck-core's authenticated caller table.
/// Attended is deliberately never interpreted as owner authority.
public struct BackendDeckToolsSessionsCaller: Sendable {
    public enum Kind: String, Sendable { case local, key, session, remote }
    public let kind: Kind
    public let sessionID: String?, machineID: String?, deviceID: String?, keyName: String?
    public let callID: String
    public init(kind: Kind, sessionID: String? = nil, machineID: String? = nil, deviceID: String? = nil,
                keyName: String? = nil, callID: String) {
        self.kind = kind; self.sessionID = sessionID; self.machineID = machineID; self.deviceID = deviceID; self.keyName = keyName; self.callID = callID
    }
    public var actsAsOwner: Bool { kind == .local || kind == .key }
}

/// Caller attribution, the authoritative surface view, and central consent/logging.
/// Authorize must enforce effective tier and source summary, including unattended
/// refusal, fresh caller grant, action budget and the central action log.
public protocol BackendDeckToolsSessionsRuntime: Sendable {
    func caller(_ context: BackendMCPCallContext) async throws -> BackendDeckToolsSessionsCaller
    func sessions(_ context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func knownFolders(_ context: BackendMCPCallContext) async throws -> Set<String>
    func deviceFolders(deviceID: String, context: BackendMCPCallContext) async throws -> [String]?
    func startedByCaller(sessionID: String, context: BackendMCPCallContext) async throws -> Bool
    func noteStarted(sessionID: String, context: BackendMCPCallContext) async throws
    func authorize(tool: BackendMCPTool, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue, context: BackendMCPCallContext) async throws
    func recordResult(toolID: String, summary: NativeRPCValue, context: BackendMCPCallContext) async throws
    func browserSlots(sessionID: String, machineID: String, context: BackendMCPCallContext) async throws -> [String]
}

/// One method per operation the session-more factory actually calls. The live
/// adapter below reuses lifecycle/RPC/search/insights; only signal timestamps,
/// transcript tail authority, broadcast rename and plan-limit reads need seams.
public protocol BackendDeckToolsSessionsSurface: Sendable {
    func status(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue?
    func screen(sessionID: String, context: BackendMCPCallContext) async throws -> String?
    func write(sessionID: String, data: String, context: BackendMCPCallContext) async throws
    func rename(sessionID: String, title: String, context: BackendMCPCallContext) async throws -> String?
    func held(context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func retryHeld(key: String, context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func forgetHeld(key: String, context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func account(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func limits(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func accountPlan(sessionID: String, profileID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func switchAccount(sessionID: String, profileID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func switchLater(sessionID: String, profileID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func cancelSwitch(sessionID: String, context: BackendMCPCallContext) async throws -> Bool
    func armedSwitches(context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func accounts(context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func search(request: NativeRPCValue, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func insights(transcriptPath: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func transcripts(cwd: String, context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func transcriptBytes(path: String, context: BackendMCPCallContext) async throws -> Int
    func transcriptMessages(path: String, fromByte: Int, context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func start(input: BackendCreateSessionInput, deviceID: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue
}

public protocol BackendDeckToolsSessionsAgents: Sendable {
    func detect(context: BackendMCPCallContext) async throws -> NativeRPCValue
    func added(context: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func add(draft: NativeRPCValue, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func remove(agentID: String, context: BackendMCPCallContext) async throws -> Bool
    func controls(sessionID: String, cwd: String, provider: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func models(sessionID: String, provider: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func apply(request: NativeRPCValue, context: BackendMCPCallContext) async throws -> NativeRPCValue
}

public protocol BackendDeckToolsSessionsAccounts: Sendable {
    func list(agent: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func agents(context: BackendMCPCallContext) async throws -> NativeRPCValue
    func resolve(projectPath: String?, provider: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func find(accountID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue?
    func status(accountID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func signInStatus(accountID: String, refresh: Bool, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func history(accountID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func create(name: String, provider: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func rename(accountID: String, name: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func delete(accountID: String, deleteFiles: Bool, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func setDefault(accountID: String?, projectPath: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func signOut(accountID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func shareHistory(accountID: String, share: Bool, context: BackendMCPCallContext) async throws -> NativeRPCValue
}

public protocol BackendDeckToolsSessionsWindows: Sendable {
    func view(context: BackendMCPCallContext) async throws -> NativeRPCValue
    func open(sessionID: String, displayID: Double?, context: BackendMCPCallContext) async throws -> NativeRPCValue
    func dock(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue
}

/// Must file into BackendBrowserWorkersLiftRequests' single shared inbox; never
/// move a login. The adapter must preserve the TS desk's named result/refusals.
public protocol BackendDeckToolsSessionsLiftRequests: Sendable {
    func file(askedBy: String, from: String, into: [String], reason: NativeRPCValue, context: BackendMCPCallContext) async throws -> NativeRPCValue
}

public struct BackendDeckToolsSessionsClock: Sendable {
    public let now: @Sendable () -> Double
    public let sleep: @Sendable (Int) async throws -> Void
    public init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
                sleep: @escaping @Sendable (Int) async throws -> Void = BackendDeckToolsSessionsTyping.realSleep) { self.now = now; self.sleep = sleep }
}
