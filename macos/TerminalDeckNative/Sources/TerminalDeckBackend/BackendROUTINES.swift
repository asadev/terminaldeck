import Foundation
import TerminalDeckNativeCore

/// The task owner supplies its existing scoped launch pipeline. The routine
/// engine's original request, chain, cancellation and control stay intact.
/// Without that verified join, assigned-agent execution fails clearly rather
/// than launching a broad replacement process or silently running Hoot.
public struct BackendROUTINESRunner: BackendRoutinesRunner {
    public typealias Profile = @Sendable (String) async throws -> NativeRPCValue?
    public typealias ProfileRun = @Sendable (BackendRoutinesRunRequest, NativeRPCValue) async throws -> BackendRoutinesRunOutcome
    private let hoot: any BackendRoutinesRunner
    private let profile: Profile
    private let profileRun: ProfileRun?
    public let cancellable = true
    public init(hoot: any BackendRoutinesRunner, profile: @escaping Profile, profileRun: ProfileRun? = nil) {
        self.hoot = hoot; self.profile = profile; self.profileRun = profileRun
    }
    public func run(_ request: BackendRoutinesRunRequest) async -> BackendRoutinesRunOutcome {
        let id = request.routine.routinesAgentID
        if id == "@hoot" { return await hoot.run(request) }
        do {
            guard let agent = try await profile(id), agent["id"].string == id else { return .init(ok: false, error: "The agent assigned to this routine no longer exists.") }
            guard agent["status"].string != "paused", agent["status"].string != "archived" else { return .init(ok: false, error: "\(agent["name"].string ?? "This agent") is paused or archived.") }
            guard let profileRun else { return .init(ok: false, error: "The assigned agent’s scoped routine runner is unavailable. Nothing was started.") }
            return try await profileRun(request, agent)
        } catch { return .init(ok: false, error: "The assigned agent could not start: \(error.localizedDescription)") }
    }
}
public enum BackendROUTINESHistory {
    /// Reuses the shared action log. Bounded and read-only, including one rotated
    /// file, so a restart preserves the actual history and unknown token counts.
    public static func read(paths: BackendCopilotPaths, limit: Int = 200) throws -> NativeRPCValue {
        var raw: [NativeRPCValue] = []
        for path in [paths.actions + ".1", paths.actions] where FileManager.default.fileExists(atPath: path) {
            let text = try BackendCopilotServiceFiles.readText(path)
            guard text.utf8.count <= 4 * 1_048_576 else { throw NativeRPCError(code: "log-too-large", message: "The routine log is too large to read safely.") }
            raw += text.split(separator: "\n").compactMap { try? NativeRPCValue.parseJSON(Data($0.utf8)) }
        }
        return reduce(raw, limit: limit)
    }
    public static func reduce(_ rows: [NativeRPCValue], limit: Int = 200) -> NativeRPCValue {
        var runs: [String: NativeRPCValue] = [:], order: [String] = []
        for row in rows where row["action"].string == "routine.run" {
            guard let id = row["runId"].string, row["routine"].string != nil else { continue }
            if runs[id] == nil { order.append(id); runs[id] = row }
            else {
                let started = runs[id]!["at"]
                let mergedData = runs[id]!["data"].merging(row["data"])
                runs[id] = runs[id]!.merging(row).setting("data", mergedData).setting("startedAt", started)
            }
        }
        return .array(order.suffix(min(500, max(1, limit))).reversed().compactMap { id in
            guard let run = runs[id] else { return nil }
            return run.setting("agentId", run["data"]["agentId"].isNullish ? .string("@hoot") : run["data"]["agentId"])
                .setting("projectId", run["data"]["projectId"]).setting("name", run["data"]["name"])
        })
    }
}

/// Subscribe to the existing tasks:changed stream and pass its authoritative
/// store rows. Initial capture records a baseline, never invents old events.
public actor BackendROUTINESTaskEvents {
    public typealias Fire = @Sendable (String, BackendTaskRecord) async -> Void
    private var prior: [String: Bool]?
    private let fire: Fire
    public init(fire: @escaping Fire) { self.fire = fire }
    public func accept(_ rows: [BackendTaskRecord]) async {
        let now = Dictionary(rows.map { ($0.id, !$0.value["completedAt"].isNullish || $0.value["crmStatus"].string == "Done") }, uniquingKeysWith: { _, newer in newer })
        guard let old = prior else { prior = now; return }; prior = now
        for row in rows {
            if old[row.id] == nil { await fire("task-created", row) }
            if old[row.id] != true && now[row.id] == true { await fire("task-finished", row) }
        }
    }
}
