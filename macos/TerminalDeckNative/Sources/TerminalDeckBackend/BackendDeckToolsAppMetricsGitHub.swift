import Foundation
import TerminalDeckNativeCore

public protocol BackendDeckToolsAppUsageService: Sendable {
    func read(_ sessionID: String?, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func context(_ sessionID: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func refresh(_ sessionID: String, force: Bool, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func projectCost(_ path: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func transcripts(_ path: String, caller: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func sessionCost(_ path: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
}
public enum BackendDeckToolsAppUsage {
    private typealias K = BackendDeckToolsAppKit
    public static let maxCostSessions = 100
    public static func definitions(service: any BackendDeckToolsAppUsageService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "usage-tools", access: access, precheck: { id, context, args in
            if id == "usage.cost" { _ = try await access.knownFolder(context, K.str(args, "projectPath", trimmed: true)) }
        }, consent: { id, _, args in
            let session = try K.optStr(args, "sessionId", trimmed: true), sentence: String
            if id == "usage.read" { sentence = "Read usage\(session.map { " for session \($0)" } ?? "")" }
            else if id == "usage.refresh" { sentence = "Refresh the plan limits for session \(session ?? "?")" }
            else { sentence = try K.optStr(args, "transcriptPath", trimmed: true) == nil ? "Read the cost of \(try K.optStr(args, "projectPath", trimmed: true) ?? "?")" : "Read the cost of one session in \(try K.optStr(args, "projectPath", trimmed: true) ?? "?")" }
            return (id == "usage.refresh" ? .act : .read, sentence, false)
        }, run: { id, context, args in
            if id == "usage.read" {
                guard let id = try K.optStr(args, "sessionId", trimmed: true) else { return .init(K.object([("limits", try await service.read(nil, caller: context))]), K.object([("sessionId", .null)])) }
                let session = try await access.session(context, id), actual = session["id"].string ?? id
                async let limits = service.read(actual, caller: context)
                async let window = service.context(actual, caller: context)
                return try await .init(K.object([("sessionId", .string(actual)), ("limits", limits), ("contextWindow", window)]), K.object([("sessionId", .string(actual))]))
            }
            if id == "usage.refresh" {
                let session = try await access.session(context, K.str(args, "sessionId", trimmed: true)), actual = session["id"].string ?? ""
                return .init(try await service.refresh(actual, force: BackendDeckToolsArgs.optBool(args, "force", false), caller: context), K.object([("sessionId", .string(actual))]))
            }
            let path = try await access.knownFolder(context, K.str(args, "projectPath", trimmed: true)), transcripts = try await service.transcripts(path, caller: context), wanted = try K.optStr(args, "transcriptPath", trimmed: true)
            if let wanted {
                guard transcripts.contains(where: { $0["path"].string == wanted }) else { throw K.refused("\(wanted) is not one of \(path)’s transcripts. usage.cost without transcriptPath lists them.") }
                return .init(K.object([("session", try await service.sessionCost(wanted, caller: context))]), K.object([("projectPath", .string(path)), ("session", .bool(true))]))
            }
            let limit = try BackendDeckToolsArgs.optInt(args, "limit", 20, 1, maxCostSessions)
            return .init(K.object([("project", try await service.projectCost(path, caller: context)), ("transcripts", .array(Array(transcripts.prefix(limit)))), ("totalTranscripts", K.n(transcripts.count))]), K.object([("projectPath", .string(path)), ("transcripts", K.n(transcripts.count))]))
        })
    }
}

public protocol BackendDeckToolsAppSetupService: Sendable {
    var fixIDs: Set<String> { get }
    func setup(_ caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func scan(_ path: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func fix(_ path: String, id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
}
public enum BackendDeckToolsAppSetup {
    private typealias K = BackendDeckToolsAppKit
    public static func definitions(service: any BackendDeckToolsAppSetupService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "setup-tools", access: access, precheck: { id, context, args in
            if id == "setup.status" { return }
            _ = try await access.knownFolder(context, K.str(args, "projectPath"))
            if id == "readiness.fix" { let fix = try K.str(args, "fixId"); guard service.fixIDs.contains(fix) else { throw K.refused("\(fix) is not a fix this version can apply by id.") } }
        }, consent: { id, _, args in
            return (id == "readiness.fix" ? .alter : .read, id == "setup.status" ? "Check this computer’s setup" : id == "readiness.scan" ? "Score the readiness of \(args["projectPath"].string ?? "?")" : "Apply the readiness fix \(args["fixId"].string ?? "?") to \(args["projectPath"].string ?? "?")", false)
        }, run: { id, context, args in
            if id == "setup.status" { return .init(try await service.setup(context)) }
            let path = try await access.knownFolder(context, K.str(args, "projectPath"))
            if id == "readiness.scan" { let report = try await service.scan(path, caller: context); return .init(report, K.object([("projectPath", .string(path)), ("checks", K.n(report["checks"].elements?.count ?? 0))])) }
            let fixID = try K.str(args, "fixId")
            guard service.fixIDs.contains(fixID) else { throw K.refused("\(fixID) is not a fix this version can apply by id.") }
            let report = try await service.scan(path, caller: context)
            guard let offered = report["checks"].elements?.map({ $0["fix"] }).first(where: { $0 != .null && $0["id"].string == fixID }) else { throw K.refused("the scan of \(path) is not offering \(fixID) right now — that gap may already be closed. Run readiness.scan to see the fixes on offer.") }
            let result = try await service.fix(path, id: fixID, caller: context)
            guard result["ok"].bool == true else { throw K.refused(result["message"].string ?? "This readiness fix was refused.") }
            return .init(result.setting("applied", offered), K.object([("projectPath", .string(path)), ("fixId", .string(fixID)), ("changed", K.n(result["changed"].elements?.count ?? 0))]))
        })
    }
}

/// Reuses the native metrics/readiness services; no second cache/store/probe.
/// Register these exact-schema factories instead of BackendUsageMCPTools' five
/// overlapping usage/readiness ids, leaving its other metric tools intact.
public struct BackendDeckToolsAppNativeMetricsAdapter: BackendDeckToolsAppUsageService, BackendDeckToolsAppSetupService, Sendable {
    public let fixIDs = BackendReadinessService.fixIDs
    private let usage: BackendUsageService, cost: BackendCostService, readiness: BackendReadinessService
    private let access: BackendDeckToolsAppAccess
    private let readSetup: @Sendable (NativeRPCContext) async throws -> NativeRPCValue
    public init(usage: BackendUsageService, cost: BackendCostService, readiness: BackendReadinessService,
                access: BackendDeckToolsAppAccess, setup: @escaping @Sendable (NativeRPCContext) async throws -> NativeRPCValue) {
        self.usage = usage; self.cost = cost; self.readiness = readiness; self.access = access; readSetup = setup
    }
    public func read(_ sessionID: String?, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await usage.read(sessionID: sessionID).wireValue }
    public func context(_ sessionID: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await usage.contextWindow(sessionID: sessionID, context: access.rpc(caller)) }
    public func refresh(_ sessionID: String, force: Bool, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await usage.refresh(sessionID: sessionID, force: force, cancellation: caller.cancellation).wireValue }
    public func projectCost(_ path: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await cost.project(path, context: access.rpc(caller), cancellation: caller.cancellation) }
    public func transcripts(_ path: String, caller: BackendMCPCallContext) async throws -> [NativeRPCValue] { try await cost.files(project: path, context: access.rpc(caller)).map { try NativeRPCValue.fromFoundation($0.wireValue) } }
    public func sessionCost(_ path: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await cost.session(path: path, context: access.rpc(caller), cancellation: caller.cancellation).summary }
    public func setup(_ caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await readSetup(access.rpc(caller)) }
    public func scan(_ path: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await BackendReadinessService.wire(readiness.scan(project: path, context: access.rpc(caller))) }
    public func fix(_ path: String, id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await BackendReadinessService.wire(readiness.fix(project: path, id: id, context: access.rpc(caller), requireOffered: true)) }
}

/// Native GitHub worker provides the same nine channels; no credentials pass
/// through this protocol. awaitAuth continues when the tool's ceiling wins.
public protocol BackendDeckToolsAppGitHubService: Sendable {
    func overview(_ folder: String) async throws -> NativeRPCValue
    func refresh(_ folder: String) async throws -> NativeRPCValue
    func repo(_ folder: String) async throws -> NativeRPCValue
    func clearCache(_ folder: String) async throws
    func authStatus(_ folder: String) async throws -> NativeRPCValue
    func connect() async throws -> NativeRPCValue
    func awaitAuth(_ folder: String) async throws -> NativeRPCValue
    func cancel(_ folder: String) async throws -> NativeRPCValue
    func disconnect(_ folder: String) async throws -> NativeRPCValue
}

/// Unstructured domain operations keep running after a bounded tool wait. The
/// lock resolves exactly once, so neither a late error nor cancellation can
/// resume the tool continuation twice. Only the scheduled ceiling is cancelled.
private final class BackendDeckToolsAppRaceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, any Error>?
    private var resolved: Result<Value?, any Error>?
    private var ceiling: (clock: any BackendDeckCoreEventsClock, handle: UUID)?
    func bind(_ value: CheckedContinuation<Value?, any Error>) {
        let answer = lock.withLock { () -> Result<Value?, any Error>? in if let resolved { return resolved }; continuation = value; return nil }
        if let answer { value.resume(with: answer) }
    }
    func setCeiling(_ handle: UUID, clock: any BackendDeckCoreEventsClock) { let done = lock.withLock { () -> Bool in if resolved != nil { return true }; ceiling = (clock, handle); return false }; if done { clock.cancel(handle) } }
    func resolve(_ answer: Result<Value?, any Error>) {
        let state: (CheckedContinuation<Value?, any Error>?, (clock: any BackendDeckCoreEventsClock, handle: UUID)?) = lock.withLock {
            guard resolved == nil else { return (nil, nil) }
            resolved = answer; let state = (continuation, ceiling); continuation = nil; ceiling = nil; return state
        }
        if let deadline = state.1 { deadline.clock.cancel(deadline.handle) }; state.0?.resume(with: answer)
    }
}
public enum BackendDeckToolsAppWait {
    public static func bounded<Value: Sendable>(milliseconds: Int, clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock(), operation: @escaping @Sendable () async throws -> Value) async throws -> Value? {
        let box = BackendDeckToolsAppRaceBox<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.bind(continuation)
                Task { do { box.resolve(.success(try await operation())) } catch { box.resolve(.failure(error)) } }
                let timeout = clock.schedule(after: Double(milliseconds)) { box.resolve(.success(nil)) }
                box.setCeiling(timeout, clock: clock)
            }
        } onCancel: { box.resolve(.failure(CancellationError())) }
    }
}
public enum BackendDeckToolsAppGitHub {
    private typealias K = BackendDeckToolsAppKit
    public static let signInWaitMs = 120_000
    public static func withoutCode(_ state: NativeRPCValue) -> NativeRPCValue {
        guard state.fields != nil, state["pending"].fields != nil else { return state }
        return state.setting("pending", state["pending"].setting("userCode", .string("(shown in the app, and to the call that started it)")))
    }
    public static func definitions(service: any BackendDeckToolsAppGitHubService, access: BackendDeckToolsAppAccess, clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock()) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "github-tools", access: access, precheck: { id, context, args in
            try K.hereOnly(await access.caller(context), id == "github.look" ? "Reading GitHub" : "Signing this app in to GitHub")
            if id == "github.look" { _ = try await access.knownFolder(context, K.str(args, "folder")) }
            else { _ = try BackendDeckToolsArgs.oneOf(args, "do", ["connect", "wait", "cancel", "disconnect"]); if let folder = try K.optStr(args, "folder") { _ = try await access.knownFolder(context, folder) } }
        }, consent: { id, _, args in
            let verb = args["do"].string ?? ""
            let sentence = id == "github.look" ? "Read GitHub for \(args["folder"].string ?? "?")" : verb == "connect" ? "Start signing this app in to GitHub" : verb == "wait" ? "Wait for the GitHub sign-in to finish" : verb == "cancel" ? "Cancel the GitHub sign-in that is waiting" : "Sign this app out of GitHub"
            return (id == "github.look" ? .read : .alter, sentence, false)
        }, run: { id, context, args in
            if id == "github.look" {
                let folder = try await access.knownFolder(context, K.str(args, "folder")), refresh = try BackendDeckToolsArgs.optBool(args, "refresh", false)
                if refresh { try await service.clearCache(folder) }
                async let repo = service.repo(folder)
                async let overview = refresh ? service.refresh(folder) : service.overview(folder)
                async let signedIn = service.authStatus(folder)
                return try await .init(K.object([("folder", .string(folder)), ("repo", repo), ("overview", overview), ("signedIn", withoutCode(signedIn))]), K.object([("folder", .string(folder)), ("refresh", .bool(refresh))]))
            }
            let verb = try BackendDeckToolsArgs.oneOf(args, "do", ["connect", "wait", "cancel", "disconnect"]), folder = try K.optStr(args, "folder") ?? ""
            if verb == "connect" { return .init(K.object([("prompt", try await service.connect()), ("note", .string("Ask the person to open the address and type the code, then call this with do \"wait\"."))]), K.object([("started", .bool(true))])) }
            if verb == "wait" {
                guard let state = try await BackendDeckToolsAppWait.bounded(milliseconds: signInWaitMs, clock: clock, operation: { try await service.awaitAuth(folder) }) else { return .init(K.object([("finished", .bool(false)), ("note", .string("Not finished yet. The code is still waiting at github.com; call wait again."))]), K.object([("finished", .bool(false))])) }
                return .init(K.object([("finished", .bool(true)), ("state", state)]), K.object([("finished", .bool(true))]))
            }
            let state: NativeRPCValue
            if verb == "cancel" { state = try await service.cancel(folder) } else { state = try await service.disconnect(folder) }
            return .init(K.object([("state", state)]), K.object([("verb", .string(verb))]))
        })
    }
}
