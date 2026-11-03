import Foundation
import TerminalDeckNativeCore

/// Only caller-owned window slots and host names. Never cookies or transfer operations.
public protocol BackendDeckToolsMachinesWorkerMetadata: Sendable {
    func windowsByWorker(context: BackendDeckToolsMachinesContext) async throws -> [String: String]
    func signedInHosts(profileID: String, context: BackendDeckToolsMachinesContext) async throws -> [String]
}
public protocol BackendDeckToolsMachinesWorkerPool: Sendable {
    func view(context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue
    func take(profileID: String?, holdMS: NativeRPCValue, context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue
    func release(profileID: String, renew: Bool, holdMS: NativeRPCValue, context: BackendDeckToolsMachinesContext) async throws -> Bool
}
/// Uses Safari's actual shared lease actor. No second cookie jar, pool or scheduler.
public struct BackendDeckToolsMachinesSafariPool: BackendDeckToolsMachinesWorkerPool, Sendable {
    public let workers: BackendBrowserWorkers
    public init(workers: BackendBrowserWorkers) { self.workers = workers }
    private func caller(_ context: BackendDeckToolsMachinesContext) -> BackendBrowserScrapingCaller {
        return .init(ownerID: context.holder, sessionID: context.kind == .session ? context.sessionID : nil,
                     machineID: context.kind == .session ? context.machineID : nil,
                     attended: context.attended, remote: context.kind == .remote, rpc: context.rpc)
    }
    public func view(context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        let principal = caller(context), value = try await workers.view(principal)
        let rows = (value["workers"].elements ?? []).map { row in row.setting("holder", .string(row["holder"].string == principal.holder ? context.holder : "")) }
        return value.setting("workers", .array(rows))
    }
    public func take(profileID: String?, holdMS: NativeRPCValue, context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        do { return try await workers.take(worker: profileID, holdMS: holdMS, caller: caller(context)) }
        catch let error as NativeRPCError { return BackendDeckToolsMachinesShared.object(["ok": .bool(false), "reason": .string(error.message)]) }
    }
    public func release(profileID: String, renew: Bool, holdMS: NativeRPCValue, context: BackendDeckToolsMachinesContext) async throws -> Bool {
        do { _ = try await workers.release(worker: profileID, renew: renew, holdMS: holdMS, caller: caller(context)); return true }
        catch let error as NativeRPCError where error.code == "access-denied" { return false }
    }
}
public struct BackendDeckToolsMachinesWorkers: Sendable {
    public typealias V = NativeRPCValue
    typealias S = BackendDeckToolsMachinesShared
    public static let ids = ["browser.workers", "browser.worker"]
    public let pool: any BackendDeckToolsMachinesWorkerPool
    public let metadata: any BackendDeckToolsMachinesWorkerMetadata
    public init(pool: any BackendDeckToolsMachinesWorkerPool, metadata: any BackendDeckToolsMachinesWorkerMetadata) { self.pool = pool; self.metadata = metadata }
    public static func mayUse(_ context: BackendDeckToolsMachinesContext, tool: String) throws {
        if !(context.kind == .session && context.sessionID != nil) && !context.actsAsOwner { throw S.refused("\(tool) only works for the person at this machine. Driving a browser from a paired device is not something this app does. Say what you would have done and let them do it.", "not-granted") }
        if !context.attended { throw S.refused("\(tool) takes a browser profile that holds the person's logins, and there is nobody at the machine to watch it. Do not retry and do not look for another way. Say in your report what you would have run.", "not-permitted-unattended") }
    }
    public static func noWindow(_ context: BackendDeckToolsMachinesContext, one: Bool) -> String {
        if context.kind != .session || context.sessionID == nil { return one ? "The hold is yours, but a worker profile is driven from a session’s own browser window and Hoot’s tab is not one. Ask a session to drive it, or say what you would have done." : "None of these can be driven from here: a worker profile is driven from a session’s own browser window, and Hoot’s tab is not one." }
        return one ? "This worker has no window of yours showing a page in it, so you cannot drive it yet. Ask the person to open a page in it and attach that window; the hold is yours in the meantime." : "None of these has a window attached to you, so none can be driven yet. Ask the person to open a page in a worker and attach that window."
    }
    public static func action(_ args: V) throws -> String { guard let action = args["action"].string, ["take", "release", "renew"].contains(action) else { throw S.refused("action must be one of: take, release, renew") }; return action }
    private static func name(_ args: V) throws -> String? { if args["worker"].isNullish || args["worker"].string == "" { return nil }; guard let name = args["worker"].string else { throw S.refused("worker must be a string") }; return name }
    public func definitions(environment: any BackendDeckToolsMachinesEnvironment, liftRequest: [BackendDeckToolsDefinition]) throws -> [BackendDeckToolsDefinition] {
        let definitions = try BackendDeckToolsMachinesFactory.definitions(ids: Self.ids, environment: environment, prepare: { [self] in try await self.policy($0, $1, $2) }, run: { [self] in try await self.run($0, $1, $2) })
        // The request desk belongs to the sessions lane. Never register a transfer primitive.
        guard liftRequest.count == 1 && liftRequest[0].spec.id == "browser.lift_request" else { throw BackendDeckToolsSupport.unavailable("the browser.lift_request definition") }
        return definitions + liftRequest
    }
    public func policy(_ spec: BackendMCPTool, _ args: V, _ context: BackendDeckToolsMachinesContext) throws -> BackendDeckToolsMachinesPolicy {
        try Self.mayUse(context, tool: spec.id)
        let sentence: String
        if spec.id == "browser.workers" { sentence = "List the browser’s worker profiles" }
        else { let action = try Self.action(args), name = try Self.name(args); if action != "take" && name == nil { throw S.refused("\(action) needs the worker it is about") }; sentence = action == "take" ? "Take \(name ?? "a free") browser worker" : "\(action == "release" ? "Release" : "Renew") browser worker \(name ?? "?")" }
        return .init(tool: spec, arguments: args, loggedArguments: args, tier: spec.tier, sentence: sentence)
    }
    public func run(_ tool: String, _ args: V, _ context: BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesOutput {
        try Self.mayUse(context, tool: tool)
        let view = try await pool.view(context: context), workers = view["workers"].elements ?? [], slots: [String: String]
        if context.kind == .session && context.sessionID != nil { slots = try await metadata.windowsByWorker(context: context) } else { slots = [:] }
        if tool == "browser.workers" {
            var rows: [V] = []
            for worker in workers { let id = worker["profileId"].string ?? "", signedIn = try await metadata.signedInHosts(profileID: id, context: context); rows.append(S.object(["name": worker["name"], "busy": worker["busy"], "yours": .bool(worker["busy"].bool == true && worker["holder"].string == context.holder), "window": slots[id].map(V.string) ?? .null, "readyInMs": worker["readyInMs"], "signedInFor": .array(signedIn.map(V.string))])) }
            let drivable = rows.filter { !$0["window"].isNullish }.count, pace = view["pace"]
            let note = rows.isEmpty ? "There are no worker profiles yet. The person adds them in the browser’s profile menu, under Workers." : drivable == 0 ? Self.noWindow(context, one: false) : "\(drivable) of \(rows.count) can be driven from your windows."
            return .init(S.empty(S.object(["workers": .array(rows), "drivable": .number(Double(drivable)), "maxConcurrent": pace["maxConcurrent"], "minDelayMs": pace["minDelayMs"], "jitterMs": pace["jitterMs"], "note": .string(note)]), count: rows.count, reason: "there is no worker profile to list. A worker is a browser profile with its own cookie jar and a person makes them, in the browser’s profile menu, under Workers — nothing on this surface can create one."), S.emptySummary(rows.count).setting("workers", .number(Double(rows.count))).setting("drivable", .number(Double(drivable))))
        }
        let action = try Self.action(args), name = try Self.name(args), named = name.flatMap { wanted in workers.first { $0["name"].string?.lowercased() == wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? workers.first { $0["profileId"].string == wanted } }, hold = args["holdMs"].number == nil ? V.missing : args["holdMs"]
        if action != "take" && name == nil { throw S.refused("\(action) needs the worker it is about") }
        if name != nil && named == nil { throw S.refused("there is no worker by that name. browser.workers lists them.") }
        if action == "take" {
            let answer = try await pool.take(profileID: named?["profileId"].string, holdMS: hold, context: context)
            guard answer["ok"].bool == true else { throw S.refused(answer["reason"].string ?? "The worker could not be taken.") }
            let profile = answer["profileId"].string ?? "", freshSlots: [String: String]
            if context.kind == .session && context.sessionID != nil { freshSlots = try await metadata.windowsByWorker(context: context) } else { freshSlots = [:] }
            let window = freshSlots[profile], signedIn = try await metadata.signedInHosts(profileID: profile, context: context)
            var summary = S.emptySummary(1).setting("worker", answer["name"]).setting("pacedMs", answer["pacedMs"]); if let window { summary = summary.setting("window", .string(window)) }
            return .init(S.empty(S.object(["worker": answer["name"], "window": window.map(V.string) ?? .null, "pacedMs": answer["pacedMs"], "expiresAt": answer["expiresAt"], "signedInFor": .array(signedIn.map(V.string)), "note": .string(window.map { "Drive \($0). Release the worker when the page is done." } ?? Self.noWindow(context, one: true))]), count: 1, reason: ""), summary)
        }
        guard let named, let id = named["profileId"].string else { throw S.refused("there is no worker by that name. browser.workers lists them.") }
        let ok = try await pool.release(profileID: id, renew: action == "renew", holdMS: hold, context: context)
        if !ok { throw S.refused("\(named["name"].string ?? id) is not held by you. It may have lapsed while you were away — take it again.") }
        return .init(S.empty(S.object(["worker": named["name"], action == "release" ? "released" : "renewed": .bool(true)]), count: 1, reason: ""), S.emptySummary(1).setting("worker", named["name"]))
    }
}

/// Source machine-area composition. Server tools are absent if the server room was not built;
/// GitHub definitions come from deck-tools' GitHub worker, and devices/workers stay separate.
public enum BackendDeckToolsMachinesComposition {
    public static func area(machines: BackendDeckToolsMachinesArea, remote: BackendDeckToolsMachinesRemote,
                            servers: BackendDeckToolsMachinesServers?, github: [BackendDeckToolsDefinition],
                            environment: any BackendDeckToolsMachinesEnvironment) async throws -> BackendDeckCoreToolArea {
        var definitions = try await machines.definitions(environment: environment)
        if let servers { definitions += try await servers.definitions(environment: environment) }
        definitions += try await remote.definitions(environment: environment)
        definitions += github
        return try BackendDeckToolsSupport.area(id: "machines", definitions: definitions)
    }
}
