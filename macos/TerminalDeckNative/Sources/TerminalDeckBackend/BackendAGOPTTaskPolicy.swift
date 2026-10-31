import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Task execution uses the resolved owner settings; private values stay in
/// memory. Only non-secret launch identity and lifecycle facts enter the task.
public enum BackendAGOPTTaskPolicy {
    public static func applying(_ task: BackendTaskRecord, to settings: AGSAgentSettings) throws -> AGSAgentSettings {
        try BackendAGOPTEfficiencyPolicy.taskChoices(settings, task: task.value)
    }

    public static func snapshot(agent: NativeRPCValue, cwd: String, settings: AGSAgentSettings, profileID: String? = nil) -> NativeRPCValue {
        .object([
            .init("agoptSettingsSignature", .string(contextSignature(settings, agent: agent))),
            .init("agoptProfileID", profileID.map(NativeRPCValue.string) ?? .null),
            .init("agoptModel", settings.model.map(NativeRPCValue.string) ?? .null),
            .init("agoptEffort", settings.effort.map(NativeRPCValue.string) ?? .null),
            .init("agoptAgentID", agent["id"]), .init("agoptProvider", .string(settings.provider)),
            .init("agoptAccount", agent["account"].isNullish ? .null : agent["account"]), .init("agoptCwd", .string(cwd)),
            .init("agoptEfficiencyApplied", .bool(true)),
            .init("agoptCompletion", retainsSession(agent) ? .null : .string(settings.efficiency?.completion ?? "park")),
            .init("agoptReuseContext", .bool(settings.efficiency?.reuseContext ?? true)),
            .init("agoptSerializeHeavyJobs", .bool(settings.efficiency?.serializeHeavyJobs ?? true))
        ])
    }
    /// Resume the exact parked conversation, never an arbitrary newest cwd
    /// transcript or another agent/account/CRM connection's session.
    public static func parkedConversation(for task: BackendTaskRecord, agent: NativeRPCValue, cwd: String,
                                          settings: AGSAgentSettings, records: [BackendTaskRecord], profileID: String? = nil) -> String? {
        guard settings.efficiency?.reuseContext != false else { return nil }
        let signature = contextSignature(settings, agent: agent)
        return records.filter { row in
            row.id != task.id && row.value["keyId"] == task.value["keyId"] && row.value["notificationKeyId"] == task.value["notificationKeyId"] && row.project == task.project && row.value["projectId"] == task.value["projectId"] &&
            row.sessionID == nil && !row.value["result"].isNullish && row.value["agoptCompletion"].string == "park" &&
            row.value["agoptReuseContext"].bool == true && row.value["agoptAgentID"] == agent["id"] &&
            row.value["agoptSettingsSignature"].string == signature &&
            row.value["agoptProfileID"] == (profileID.map(NativeRPCValue.string) ?? .null) &&
            row.value["agoptProvider"].string == settings.provider && row.value["agoptCwd"].string == cwd &&
            row.value["agoptAccount"] == (agent["account"].isNullish ? .null : agent["account"]) &&
            row.value["conversationId"].string != nil
        }.sorted {
            ($0.value["result"]["at"].number ?? 0) > ($1.value["result"]["at"].number ?? 0)
        }.first?.value["conversationId"].string
    }
    public static func liveHolder(for task: BackendTaskRecord, agent: NativeRPCValue, cwd: String,
                                  settings: AGSAgentSettings, profileID: String?, records: [BackendTaskRecord],
                                  sessions: [BackendSessionMeta], calm: Set<String>) -> (task: BackendTaskRecord, session: BackendSessionMeta)? {
        guard let profileID else { return nil }
        let signature = contextSignature(settings, agent: agent)
        for row in records where row.id != task.id && row.value["stopped"].bool != true && !row.value["result"].isNullish {
            guard let id = row.sessionID, calm.contains(id), let meta = sessions.first(where: { $0.id == id && $0.exitCode == nil }),
                  meta.cwd == cwd, meta.provider == settings.provider,
                  (meta.profileId == profileID || settings.provider == "gemini" && meta.profileId == nil && row.value["agoptProfileID"].string == profileID),
                  row.value["keyId"] == task.value["keyId"], row.value["notificationKeyId"] == task.value["notificationKeyId"], row.project == task.project, row.value["projectId"] == task.value["projectId"],
                  row.value["agoptAgentID"] == agent["id"], row.value["agoptProvider"].string == settings.provider,
                  row.value["agoptCwd"].string == cwd, row.value["agoptProfileID"].string == profileID,
                  row.value["agoptAccount"] == (agent["account"].isNullish ? .null : agent["account"]),
                  row.value["agoptSettingsSignature"].string == signature else { continue }
            return (row, meta)
        }
        return nil
    }
    public static func sameControls(_ task: BackendTaskRecord, settings: AGSAgentSettings) -> Bool {
        task.value["agoptModel"] == (settings.model.map(NativeRPCValue.string) ?? .null) &&
        task.value["agoptEffort"] == (settings.effort.map(NativeRPCValue.string) ?? .null)
    }
    public static func sameScope(_ task: BackendTaskRecord, agent: NativeRPCValue, cwd: String,
                                 settings: AGSAgentSettings, profileID: String?) -> Bool {
        let scope = snapshot(agent: agent, cwd: cwd, settings: settings, profileID: profileID)
        return ["agoptAgentID", "agoptProvider", "agoptAccount", "agoptProfileID", "agoptCwd", "agoptSettingsSignature"].allSatisfy {
            task.value[$0] == scope[$0]
        }
    }
    private static func contextSignature(_ settings: AGSAgentSettings, agent: NativeRPCValue) -> String {
        var scope = settings
        // A task's model/effort/budget choice changes execution, not whose
        // context may be reused. Security and add-on changes require fresh context.
        scope.model = nil; scope.effort = nil; scope.keepOpen = false
        scope.efficiency = .init(addonsOff: settings.efficiency?.addonsOff ?? false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let settingsBytes = try? encoder.encode(scope), let settingsValue = try? NativeRPCValue.parseJSON(settingsBytes) else { return "unavailable" }
        var material = NativeRPCValue.object([.init("settings", settingsValue),
            .init("skillsOff", .bool(agent["skillsOff"].bool == true)),
            .init("claudeAgent", agent["claudeAgent"].isNullish ? .null : agent["claudeAgent"]),
            .init("instructionsFile", agent["instructionsFile"].isNullish ? .null : agent["instructionsFile"]),
            .init("instructions", agent["instructions"].isNullish ? .null : agent["instructions"]),
            .init("extraTaskInstructions", agent["extraTaskInstructions"].isNullish ? .null : agent["extraTaskInstructions"]),
            .init("projectId", agent["projectId"].isNullish ? .null : agent["projectId"]),
            .init("sourceFile", agent["sourceFile"].isNullish ? .null : agent["sourceFile"])])
        if let source = agent["sourceFile"].string, agent["claudeAgent"].string != nil {
            if let definition = try? BackendTAGAgentImport.read(URL(fileURLWithPath: source)) {
                material = material.setting("definition", .object([.init("name", .string(definition.name)),
                    .init("description", .string(definition.description)), .init("prompt", .string(definition.prompt)),
                    .init("model", definition.model.map(NativeRPCValue.string) ?? .null),
                    .init("tools", definition.tools.map { .array($0.map(NativeRPCValue.string)) } ?? .null)]))
            } else { material = material.setting("definitionUnavailable", .bool(true)) }
        }
        guard let bytes = try? material.encodedJSON() else { return "unavailable" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    /// Existing task history owns attribution. A reassignment keeps earlier
    /// expenditure under its original agent instead of moving it to the new one.
    public static func usageByAgent(_ task: BackendTaskRecord) -> NativeRPCValue {
        var value = NativeRPCValue.object((task.value["tokenUsageByAgent"].fields ?? []).filter { field in
            guard let number = field.value.number else { return false }; return number.isFinite && number >= 0
        })
        if let old = task.value["agoptAgentID"].string {
            let allocated = (value.fields ?? []).reduce(0.0) { $0 + ($1.value.number ?? 0) }
            let missing = max(0, (task.value["tokenUsage"].number ?? 0) - allocated)
            if missing > 0 { value = value.setting(old, .number((value[old].number ?? 0) + missing)) }
        }
        return value
    }
    public static func retainsSession(_ agent: NativeRPCValue) -> Bool {
        agent["keepAliveUntilClose"].bool == true || (agent["keepAliveMinutes"].number ?? 0) > 0
    }
    public static func instructions(_ settings: AGSAgentSettings, profileID: String, retained: Bool = false) -> String {
        var text = "\n\n## Working efficiently\n\nWait for events or a reply when blocked. Do not poll. Finish with a short result; " +
            (retained ? "Terminal Deck will keep this session open according to the saved profile." : "Terminal Deck will stop the process and " +
                ((settings.efficiency?.completion ?? "park") == "park" ? "keep this conversation for the next task." : "end this conversation."))
        if settings.efficiency?.serializeHeavyJobs != false {
            let profile = NativeRPCValue.string(profileID).compact
            text += " Use profile \(profile) in each work-lock call. Before a build, test suite, simulator job or other heavy work, call agents_work_change with action acquire. If it is waiting, call agents_work_wait; this waits for the done event. Release the job with agents_work_change action release and your ticket when finished, including on failure. A granted lock is kept for 30 minutes after your last work-lock call; during a longer job, call agents_work_read between steps to keep it."
        }
        return text
    }
}

/// Internal scope for an accepted completion. It never authorizes a write;
/// the existing owner gates still run. A newer task run only cancels stale work.
enum BackendAGOPTCompletionFence {
    struct Run: Sendable { let taskID: String, runID: String }
    @TaskLocal static var current: Run?
}
