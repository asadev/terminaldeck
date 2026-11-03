import Foundation
import TerminalDeckNativeCore

/// Native Stays Fixed worker supplies the page's single service/run registry.
/// check joins an existing run; bounded waits never cancel that domain run.
public protocol BackendDeckToolsAppFixedService: Sendable {
    func status(_ project: String) async throws -> NativeRPCValue
    func readiness(_ project: String, refresh: Bool) async throws -> NativeRPCValue
    func setup(_ project: String) async throws -> NativeRPCValue
    func check(_ project: String, by: String) async throws -> NativeRPCValue
    func progress(_ project: String) async throws -> NativeRPCValue?
    func stop(_ project: String) async throws -> Bool
    func waitFor(_ project: String, milliseconds: Int) async throws -> NativeRPCValue?
    func results(_ project: String, full: Bool) async throws -> NativeRPCValue?
    func markGood(_ project: String, anyway: Bool) async throws -> NativeRPCValue
    func setAgents(_ project: String, on: Bool) async throws -> NativeRPCValue
}
public enum BackendDeckToolsAppFixed {
    private typealias K = BackendDeckToolsAppKit
    public static let defaultCheckWaitSeconds = 45, maxCheckWaitSeconds = 120
    public static func askedBy(_ caller: BackendDeckToolsAppCaller) -> String {
        switch caller.kind { case .key: return caller.keyName ?? "an AI app"; case .remote: return "a paired device"; case .session: return "an agent session"; default: return "Hoot" }
    }
    public static func resultsForModel(_ results: NativeRPCValue?, full: Bool = false) -> NativeRPCValue {
        guard let results else { return K.object([("ran", .bool(false)), ("note", .string("No check has run in this project yet. Call fixed.check."))]) }
        let differences = (results["differences"].elements ?? []).map { difference in
            var value = K.object([("id", difference["id"]), ("title", difference["title"]), ("needsPerson", difference["needsPerson"]), ("places", difference["count"]), ("changes", difference["changes"]), ("picturesKept", K.n(results["pictures"][difference["id"].string ?? ""].elements?.count ?? 0))])
            if difference["needsPerson"].bool == true { value = value.setting("needsPersonWhy", difference["needsPersonWhy"]) }
            if (difference["more"].number ?? 0) > 0 { value = value.setting("moreChanges", difference["more"]) }
            return value
        }
        var value = K.object([("ran", .bool(true)), ("verdict", results["verdict"]), ("headline", results["headline"]), ("at", results["at"]), ("durationMs", results["durationMs"]), ("comparedAgainst", results["against"]), ("checked", results["checked"]), ("differences", .array(differences)), ("unchanged", results["unchanged"]), ("notChecked", results["notChecked"]), ("newlyUnsteady", results["unsteady"])])
        if full { value = value.setting("engineSummary", results["detail"]).setting("notLookedAt", results["gaps"]) }
        return value
    }
    private static func projectFor(_ args: NativeRPCValue, _ context: BackendMCPCallContext, _ access: BackendDeckToolsAppAccess) async throws -> String {
        let known = try await access.knownFolder(context, K.str(args, "project"))
        // The supplied callback applies exact key-folder and paired-device
        // project grants, after the open-folder check above.
        return try await access.runnableProject(context, known)
    }
    public static func definitions(service: any BackendDeckToolsAppFixedService, access: BackendDeckToolsAppAccess, clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock()) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "fixed-tools", access: access, precheck: { id, _, args in
            if id == "fixed.agents", args["on"].bool == nil { throw BackendDeckToolsArgs.bad("on is required and must be true or false") }
        }, consent: { id, _, args in
            let project = args["project"].string ?? "a project", sentence: String
            switch id {
            case "fixed.status": sentence = "Look at Stays Fixed in \(project)"
            case "fixed.setup": sentence = "Set up Stays Fixed in \(project) (writes a settings file there)"
            case "fixed.check": sentence = "Run a Stays Fixed check in \(project)"
            case "fixed.results": sentence = "Read the last Stays Fixed check in \(project)"
            case "fixed.stop": sentence = "Stop the Stays Fixed check in \(project)"
            case "fixed.mark_good": sentence = try BackendDeckToolsArgs.optBool(args, "anyway", false) ? "Mark the last-checked build in \(project) as good, accepting the differences its check found" : "Mark the last-checked build in \(project) as good"
            default: sentence = "\(args["on"].bool == true ? "Give" : "Stop giving") agent sessions in \(project) the Stays Fixed tools"
            }
            let tier: BackendMCPTier = ["fixed.setup", "fixed.mark_good", "fixed.agents"].contains(id) ? .alter : ["fixed.check", "fixed.stop"].contains(id) ? .act : .read
            return (tier, sentence, id == "fixed.mark_good")
        }, run: { id, context, args in
            let project = try await projectFor(args, context, access)
            switch id {
            case "fixed.status":
                let status = try await service.status(project), machine = try BackendDeckToolsArgs.optBool(args, "machine", false)
                var value = K.object([("project", status["projectPath"]), ("available", status["available"]), ("setUp", status["setUp"]), ("settingsFile", status["configFile"]), ("gitRepository", status["git"]), ("agentsGetIt", status["agents"]), ("guards", .array((status["guards"].elements ?? []).map { K.object([("name", $0["name"]), ("because", $0["because"])]) })), ("markedGood", status["reference"].isNullish ? .null : K.object([("build", status["reference"]["name"]), ("at", status["reference"]["setAt"]), ("forced", status["reference"]["forced"])])), ("lastCheck", status["last"].isNullish ? .null : K.object([("verdict", status["last"]["verdict"]), ("headline", status["last"]["headline"]), ("at", status["last"]["at"]), ("differences", K.n(status["last"]["differences"].elements?.count ?? 0))])), ("running", status["running"]), ("next", .string(status["setUp"].bool != true ? "fixed.setup" : status["reference"].isNullish ? "fixed.check, then ask the owner to mark the build as good (fixed.mark_good)" : "fixed.check"))])
                for key in ["unavailable", "guardProblem"] where !(status[key].string ?? "").isEmpty { value = value.setting(key, status[key]) }
                if machine && status["available"].bool == true {
                    let readiness: NativeRPCValue
                    do { readiness = try await service.readiness(project, refresh: false) }
                    catch { readiness = K.object([("error", .string(error.localizedDescription))]) }
                    value = value.setting("machine", readiness)
                }
                return .init(value, K.object([("setUp", status["setUp"]), ("guards", K.n(status["guards"].elements?.count ?? 0)), ("running", .bool(!status["running"].isNullish))]))
            case "fixed.setup": let result = try await service.setup(project); return .init(result, K.object([("ok", result["ok"]), ("wrote", K.n(result["wrote"].elements?.count ?? 0))]))
            case "fixed.check":
                let wait = try BackendDeckToolsArgs.optInt(args, "wait", defaultCheckWaitSeconds, 0, maxCheckWaitSeconds), by = askedBy(try await access.caller(context))
                let result = try await BackendDeckToolsAppWait.bounded(milliseconds: wait * 1000, clock: clock) { try await service.check(project, by: by) }
                guard let result else { return .init(K.object([("running", .bool(true)), ("progress", try await service.progress(project) ?? .null), ("next", .string("Still running. Call fixed.results with project and wait (up to \(maxCheckWaitSeconds)) to get the answer when it finishes."))]), K.object([("running", .bool(true))])) }
                return .init(resultsForModel(result), K.object([("verdict", result["verdict"]), ("differences", K.n(result["differences"].elements?.count ?? 0))]))
            case "fixed.results":
                let wait = try BackendDeckToolsArgs.optInt(args, "wait", 0, 0, maxCheckWaitSeconds), full = try BackendDeckToolsArgs.optBool(args, "full", false)
                if wait > 0 { _ = try await service.waitFor(project, milliseconds: wait * 1000) }
                let progress = try await service.progress(project), result = try await service.results(project, full: full)
                var value = resultsForModel(result, full: full); if let progress { value = value.setting("runningNow", progress) }
                return .init(value, K.object([("verdict", result?["verdict"] ?? .null), ("running", .bool(progress != nil))]))
            case "fixed.stop":
                let stopped = try await service.stop(project), value = K.object([("stopped", .bool(stopped))])
                return .init(stopped ? value : value.setting("note", .string("No check was running there.")), K.object([("stopped", .bool(stopped))]))
            case "fixed.mark_good":
                let result = try await service.markGood(project, anyway: BackendDeckToolsArgs.optBool(args, "anyway", false))
                return .init(result, K.object([("marked", result["marked"]), ("refusedFor", result["refusedFor"])]))
            default:
                let status = try await service.setAgents(project, on: args["on"].bool == true)
                return .init(K.object([("agentsGetIt", status["agents"]), ("setUp", status["setUp"])]), K.object([("on", status["agents"])]))
            }
        })
    }
}
