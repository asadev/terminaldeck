import AppKit
import Foundation
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// One editor owner shared by the profile and its settings window.
/// The profile facade reads metadata; the original combined task writer saves it.
@MainActor @Observable
final class AGOPTProfileModel {
    private static var owners: [String: AGOPTProfileModel] = [:]
    static func owner(_ id: String) -> AGOPTProfileModel {
        if let existing = owners[id] { return existing }
        let model = AGOPTProfileModel(id: id); owners[id] = model; return model
    }
    let id: String
    let isFixture: Bool
    var snapshot: NativeRPCValue = .object([])
    var draft = AgentDraft(nil)
    var ags = NativeAGSSettingsModel()
    var sourceBody = ""
    var savedSourceBody = ""
    var sourceRevision: String?
    var sourceChanged = false
    var settingsChangedElsewhere = false
    var loaded = false
    var loading = false
    var saving = false
    var sourceSaving = false
    var sourceLoading = false
    var problem: String?
    var saveStatus = ""
    /// The engine's plain answer to an action ("Nothing queued for MT Builder…"), shown under the header.
    var notice: String?
    var original: AgentProfile?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var activeOwners = 0
    @ObservationIgnored private var changeGeneration = 0
    @ObservationIgnored private var savedGeneration = 0
    @ObservationIgnored private var baselineDraft = AgentDraft(nil)
    @ObservationIgnored private var pinnedAGSRevision: UInt64?
    @ObservationIgnored private var reloadAfterSave = false
    @ObservationIgnored private let fixtureWriter: (@MainActor (NativeRPCValue) async throws -> Void)?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init(id: String, fixture: NativeRPCValue? = nil, settings: AGSAgentSettings? = nil,
         fixtureWriter: (@MainActor (NativeRPCValue) async throws -> Void)? = nil) {
        self.id = id; isFixture = fixture != nil; self.fixtureWriter = fixtureWriter
        if let fixture { accept(fixture, replacingDraft: true); loaded = true }
        if let settings { ags = .rendered(settings) }
    }
    var agent: AGTAgent? { AGTAgentsStore.shared.agent(id) }
    var profile: AgentProfile? { original ?? AGTAgentsStore.shared.profiles.first { $0.id == id } }
    var busy: Bool { loading || saving || ags.busy }
    var hasDraft: Bool { changeGeneration != savedGeneration }
    var runtime: NativeRPCValue { snapshot["runtime"] }
    var stats: NativeRPCValue {
        let value = snapshot["stats"]
        guard !isFixture, id != AGTDirectory.hootID else { return value }
        let since = Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970 * 1000
        let extra = runs.filter { ($0["id"].string ?? "").hasPrefix("team:") && ($0["startedAt"].number ?? 0) >= since }.count
        return value.setting("runs14d", .number((value["runs14d"].number ?? 0) + Double(extra)))
    }
    var budget: NativeRPCValue { snapshot["budget"] }
    var runs: [NativeRPCValue] {
        let saved = snapshot["runs"].elements ?? []
        guard !isFixture, id != AGTDirectory.hootID else { return saved }
        let team = AGTTeamChatHistory.shared.sessions(of: id).compactMap { row -> NativeRPCValue? in
            guard let session = row["session"]["id"].string,
                  !saved.contains(where: { $0["sessionID"].string == session }) else { return nil }
            let started = row["session"]["createdAt"].number ?? 0
            let finished = row["finishedAt"].number.map { Date(timeIntervalSinceReferenceDate: $0).timeIntervalSince1970 * 1000 }
            return .object([.init("id", .string("team:" + session)), .init("sessionID", .string(session)),
                .init("title", row["job"]["title"]), .init("startedAt", .number(started)),
                .init("durationMs", finished.map { .number(max(0, $0 - started)) } ?? .null),
                .init("finishedAt", finished.map(NativeRPCValue.number) ?? .null),
                .init("result", .string(finished == nil ? "running" : row["failed"].bool == true ? "failed" : "completed")),
                .init("sessionName", row["session"]["title"])])
        }
        return saved + team
    }
    var skills: [NativeRPCValue] { snapshot["skills"].elements ?? [] }
    var recentTasks: [NativeRPCValue] { snapshot["tasks"].elements ?? [] }
    var isAPI: Bool { stats["isAPIAccount"].bool == true }
    var isPlan: Bool { stats["isAPIAccount"].bool == false }
    var separateExtraInstructions: Bool { snapshot["source"]["separateExtraInstructions"].bool ?? snapshot["separateExtraInstructions"].bool ?? false }
    var filePath: String? { snapshot["source"]["path"].string ?? profile?.sourceFile ?? profile?.instructionsFile }
    var canWriteSource: Bool { snapshot["source"]["can_save"].bool == true && sourceRevision != nil }
    var sourceHasChanges: Bool { sourceBody != savedSourceBody }
    var stopWhenDone: Binding<Bool> {
        Binding(get: { AGSStopWhenDone.isOn(keepAliveUntilClose: self.draft.keepAliveUntilClose, keepAliveMinutes: Double(Int(self.draft.keepAliveMinutes) ?? -1)) }, set: { stop in
            // The AI tools' stop_when_done writes exactly the same (AGSStopWhenDone).
            let keep = AGSStopWhenDone.keepAlive(stop)
            self.draft.keepAliveUntilClose = keep.untilClose
            self.draft.keepAliveMinutes = String(keep.minutes)
            AGSStopWhenDone.apply(stop, to: &self.ags.settings)
            self.changed()
        })
    }
    var monthlyLimit: Binding<Double?> {
        Binding(get: {
            let raw = self.isAPI ? self.ags.settings.efficiency?.monthlyBudgetUSD : self.ags.settings.efficiency?.agentTokenBudget.map(Double.init)
            let effective = raw ?? self.budget["limit"].number
            return effective == 0 ? nil : effective
        }, set: { value in
            var controls = self.ags.settings.efficiency ?? .init()
            if self.isAPI { controls.monthlyBudgetUSD = value ?? 0 }
            else {
                let tokens = value ?? 0
                guard tokens.isFinite, tokens.rounded() == tokens, (0...1_000_000_000).contains(tokens) else {
                    self.problem = "Enter a whole token count from 0 to 1,000,000,000."; return
                }
                controls.agentTokenBudget = Int(tokens)
            }
            self.ags.settings.efficiency = controls
            self.changed()
        })
    }
    var warningPercent: Binding<Int> {
        Binding(get: { self.ags.settings.efficiency?.warningPercent ?? self.budget["warningPercent"].number.map(Int.init) ?? 80 }, set: {
            var controls = self.ags.settings.efficiency ?? .init(); controls.warningPercent = $0
            self.ags.settings.efficiency = controls; self.changed()
        })
    }
    var exhaustionAction: Binding<String> {
        Binding(get: { self.ags.settings.efficiency?.onExhaustion ?? self.budget["onExhaustion"].string ?? "warn" }, set: {
            var controls = self.ags.settings.efficiency ?? .init(); controls.onExhaustion = $0
            self.ags.settings.efficiency = controls; self.changed()
        })
    }
    var perTaskTokens: Binding<Int?> {
        Binding(get: {
            let value = self.ags.settings.efficiency?.taskTokenBudget ?? self.budget["perTaskTokens"].number.map(Int.init)
            return value == 0 ? nil : value
        }, set: {
            var controls = self.ags.settings.efficiency ?? .init(); controls.taskTokenBudget = $0 ?? 0
            self.ags.settings.efficiency = controls; self.changed()
        })
    }

    func acquire() async {
        guard !isFixture else { return }
        activeOwners += 1
        let reopened = activeOwners == 1
        if reopened {
            for event in ["tasks:changed", "ags:changed", "agents-profile:changed", "agents-watch:changed"] {
                subscriptions.append(EngineBridge.shared.on(event) { [weak self] _ in
                    Task { @MainActor in await self?.reload(replacingDraft: false) }
                })
            }
        }
        await AGTTeamChatHistory.shared.start()
        // Reopening a cached profile restarts its settings listener (release stopped it) and re-reads both,
        // so a model, effort or tools change made while it was closed is shown, never saved back over.
        if !loaded || reopened {
            if id != AGTDirectory.hootID { await ags.start(profile: id == "new" ? nil : id, provider: profile?.provider ?? "claude") }
            await reload(replacingDraft: true)
        }
    }
    func release() {
        guard !isFixture else { return }
        activeOwners = max(0, activeOwners - 1)
        guard activeOwners == 0 else { return }
        subscriptions.forEach { $0.cancel() }; subscriptions.removeAll()
        debounce?.cancel(); debounce = nil
        Task { [weak self] in
            guard let self else { return }
            await self.saveOwner()
            guard self.activeOwners == 0 else { return }
            self.ags.stop()
            // U143 (#512): a closed profile with nothing left to save is let go; one whose save did not
            // go through stays, so its edits are still there when it is opened again.
            if !self.hasDraft, Self.owners[self.id] === self { Self.owners[self.id] = nil }
        }
    }
    func reload(replacingDraft: Bool = false) async {
        guard !isFixture, !gone else { return }
        // This editor's own save raises these events: read them once it has finished, so its new
        // revision is never taken for a change made elsewhere.
        if saving { reloadAfterSave = true; return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let raw = try await EngineBridge.shared.invoke("agopt:profile", [id], timeout: 10)
            var value = try NativeRPCValue.fromFoundation(raw)
            if value["gone"].bool == true { closeGone(); return }
            if id != AGTDirectory.hootID {
                let editor = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("agopt:settings-get", [id], timeout: 10))
                value = value.setting("profile", editor["profile"]).setting("choices", editor["choices"])
                // The profile service has no Skills reader. Resolve its assigned names
                // through the same owner UI catalogue as the Skills page.
                let catalogue = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("skills:list", [["installed": true]], timeout: 10))
                let installed = catalogue["skills"].elements ?? []
                let assigned = (editor["profile"]["skills"].elements ?? []).compactMap(\.string)
                value = value.setting("skills", .array(assigned.map { name in
                    let row = installed.first { $0["name"].string == name || $0["id"].string == name }
                        ?? .object([.init("name", .string(name)), .init("source", .string("Assigned skill; not found in installed catalogue"))])
                    return row.setting("id", .string(name))
                }))
            }
            if saving { reloadAfterSave = true; return }
            accept(value, replacingDraft: replacingDraft && !hasDraft)
            loaded = true
            if !settingsChangedElsewhere { problem = nil }
        } catch { problem = error.localizedDescription }
    }
    /// L4-AGENTS: the agent was deleted. Stop listening, drop the cached model, close its page and its
    /// settings window. Nothing is shown as a problem and nothing is asked of the engine again.
    private(set) var gone = false
    func closeGone() {
        guard !gone else { return }
        gone = true; problem = nil
        subscriptions.forEach { $0.cancel() }; subscriptions.removeAll()
        debounce?.cancel(); debounce = nil
        Self.owners[id] = nil
        if AGTAgentsStore.shared.openProfile == id { AGTAgentsStore.shared.openProfile = nil }
        _ = ObjectWindows.close(ObjectRef(kind: "agent", id: id))
    }
    func accept(_ value: NativeRPCValue, replacingDraft: Bool) {
        var value = AGOPTProfileDTO.normalized(value)
        let incomingRevision = value["ags"]["revision"].number.flatMap { number -> UInt64? in
            guard number.isFinite, number >= 0, number.rounded() == number, number <= Double(Int32.max) else { return nil }
            return UInt64(number)
        }
        // While this editor saves, a newer revision is its own write (the save re-pins it), not a change elsewhere.
        if hasDraft, !saving, pinnedAGSRevision != incomingRevision {
            settingsChangedElsewhere = true
            problem = "This agent changed elsewhere. Keep your draft, or discard and reload."
        } else if replacingDraft || !hasDraft {
            pinnedAGSRevision = incomingRevision
            settingsChangedElsewhere = false
        }
        if !value["source"].has("body"), value["source"]["path"] == snapshot["source"]["path"] {
            value = value.setting("source", snapshot["source"].merging(value["source"]))
        }
        if value["source"].has("body") {
            let changedRevision = value["source"]["revision"].string
            if sourceHasChanges, let sourceRevision, changedRevision != sourceRevision { sourceChanged = true }
            else {
                sourceBody = value["source"]["body"].string ?? ""
                savedSourceBody = sourceBody; sourceRevision = changedRevision; sourceChanged = false
            }
        }
        snapshot = value
        if let decoded = TasksDecode.state(["agents": [value["profile"].foundation ?? NSNull()], "connections": []])?.agents.first {
            // With no unsaved edits, a rename or change made elsewhere replaces what the page shows; the echo of
            // this editor's own save (the same saved profile) leaves the fields exactly as typed.
            let changedElsewhere = !hasDraft && original.map { AgentDraft($0) } != AgentDraft(decoded)
            original = decoded
            if replacingDraft || changedElsewhere { draft = AgentDraft(decoded); baselineDraft = draft }
        }
    }
    func changed() {
        guard loaded, draft != baselineDraft || ags.settings != ags.savedSettings else { return }
        changeGeneration += 1; saveStatus = "Saving…"
        if isFixture { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await self?.saveOwner()
        }
    }
    /// A second edit queues behind an in-flight save; it never cancels an accepted write.
    func saveOwner() async {
        guard loaded, !saving, !sourceSaving, !settingsChangedElsewhere, hasDraft else { return }
        saving = true
        let generation = changeGeneration
        let capturedDraft = draft
        var submitted = draft
        var settings = ags.settings
        settings.keepOpen = draft.keepAliveUntilClose
        submitted.provider = settings.provider; submitted.model = settings.model ?? ""; submitted.effort = settings.effort ?? ""
        submitted.permissionMode = settings.permissionMode ?? ""; submitted.allowedTools = settings.allowedTools
        submitted.blockedTools = settings.deniedTools; submitted.defaultProject = settings.workingFolder ?? submitted.defaultProject
        submitted.agsSettings = settings; submitted.agsRevision = pinnedAGSRevision
        let knownProfiles = isFixture ? original.map { [$0] } ?? [] : AGTAgentsStore.shared.profiles
        switch AgentForm.payload(submitted, agents: knownProfiles) {
        case .failure(let refusal): problem = refusal.message; saveStatus = "Not saved"
        case .success(let profile):
            do {
                var payload = profile.wire
                if let revision = pinnedAGSRevision {
                    payload["ags"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
                    payload["agsRevision"] = Double(revision)
                }
                if let fixtureWriter {
                    try await fixtureWriter(try NativeRPCValue.fromFoundation(payload))
                } else if !isFixture {
                    let result = await TasksStore.shared.call("tasks:agent-save", [payload])
                    guard result.ok else { throw NativeRPCError(code: "agent-save-refused", message: result.message ?? "The changes were not saved.") }
                    TasksStore.shared.adopt(result)
                    // Re-read the successful revision without replacing newer local edits.
                    let currentSettings = ags.settings
                    await ags.load(profile: profile.id, provider: settings.provider, discardDraft: true)
                    pinnedAGSRevision = ags.revision
                    if changeGeneration != generation { ags.settings = currentSettings }
                }
                original = profile; baselineDraft = capturedDraft; savedGeneration = generation; problem = nil; saveStatus = "Saved"
                if id == "new", !isFixture { AGTAgentsStore.shared.openProfile = profile.id }
            } catch { problem = error.localizedDescription; saveStatus = "Not saved" }
        }
        saving = false
        if reloadAfterSave { reloadAfterSave = false; await reload() }
        if savedGeneration == generation && hasDraft { await saveOwner() }
    }
    func loadInstructions() async {
        guard !isFixture, !sourceLoading, id != AGTDirectory.hootID else { return }
        sourceLoading = true
        defer { sourceLoading = false }
        do {
            let source = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("agopt:instructions-read", [id], timeout: 10))
            accept(snapshot.setting("source", snapshot["source"].merging(source)), replacingDraft: false)
        } catch { problem = error.localizedDescription }
    }
    func discardAndReload() async {
        guard !saving, !sourceSaving else { return }
        draft = baselineDraft; ags.discardChanges(); savedGeneration = changeGeneration
        settingsChangedElsewhere = false
        await ags.load(profile: id, provider: profile?.provider ?? "claude", discardDraft: true)
        await reload(replacingDraft: true)
    }
    func saveSource() async {
        guard canWriteSource, sourceHasChanges, !sourceSaving, let sourceRevision else { return }
        sourceSaving = true
        let submittedBody = sourceBody
        do {
            if !isFixture {
                _ = try await EngineBridge.shared.invoke("agopt:instructions-save", [["id": id, "body": submittedBody, "revision": sourceRevision]])
            }
            savedSourceBody = submittedBody; sourceChanged = false
            await reload(replacingDraft: !hasDraft); await loadInstructions()
        } catch { problem = error.localizedDescription }
        sourceSaving = false
        if hasDraft { await saveOwner() }
    }
    func useFileVersion() async { sourceBody = savedSourceBody; await loadInstructions() }
    /// The change a run made, for "Show the change" ("Open the run" opens its task).
    func changePath(ofRun id: String) -> String? { runs.first { $0["id"].string == id }?["changePath"].string }
    func showChange(ofRun id: String) {
        guard !isFixture, let path = changePath(ofRun: id) else { return }
        NativeFront.onlyForPerson("show the change in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    func showFile() {
        guard !isFixture, let filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
    }
    func openFile() {
        guard !isFixture, let filePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
    }
    func perform(_ action: String, target: String? = nil) async {
        guard !isFixture else { saveStatus = "Fixture action: " + action; return }
        do {
            var input: [String: Any] = ["id": id, "action": action]
            if let target { input["target"] = target }
            let answer = CodingAIJSON(try await EngineBridge.shared.invoke("agopt:profile-action", [input]))
            // A refusal from an earlier press must not stay on screen once an action has gone through.
            problem = nil; await reload()
            // The engine's own sentence ("Nothing queued for MT Builder…") is shown, never silence.
            notice = (answer["message"].string ?? answer["result"]["message"].string).flatMap { $0.isEmpty ? nil : $0 }
        } catch { problem = error.localizedDescription }
    }
}

/// Translate the existing engine's record keys once, at the read boundary.
/// Explicit nulls remain unknown; they never become zero or inferred API cost.
enum AGOPTProfileDTO {
    static func aliases(_ value: NativeRPCValue, _ keys: [String: String]) -> NativeRPCValue {
        guard value.fields != nil else { return value }
        var result = value
        for (display, source) in keys where !value.has(display) && value.has(source) { result = result.setting(display, value[source]) }
        return result
    }
    static func normalized(_ value: NativeRPCValue) -> NativeRPCValue {
        var output = value
        var stats = aliases(value["stats"], ["runs14d": "runs14days", "monthTokens": "tokensThisMonth"])
        if !stats.has("successRate"), stats.has("finishedWithoutHelp") {
            stats = stats.setting("successRate", stats["finishedWithoutHelp"].number.map { .number($0 / 100) } ?? .null)
        }
        output = output.setting("stats", stats)
        var budget = aliases(value["budget"], ["used": "spent", "limit": "monthly_budget", "warningPercent": "warning_percent",
            "onExhaustion": "on_exhaustion", "paused": "paused_by_budget", "daily": "days", "costUSD": "cost_usd", "coverage": "token_coverage"])
        if budget["billing_kind"].string == "unknown" { budget = budget.setting("unit", .string("unknown")) }
        if let days = budget["daily"].elements { budget = budget.setting("daily", .array(days.map { aliases($0, ["costUSD": "cost_usd"]) })) }
        output = output.setting("budget", budget)
        let runtime = aliases(value["runtime"], ["state": "status", "taskID": "taskId", "sessionID": "sessionId", "queuedCount": "queued"])
        output = output.setting("runtime", runtime)
        if let tasks = value["tasks"].elements {
            output = output.setting("tasks", .array(tasks.map { aliases($0, ["id": "task_id", "sessionID": "session_id", "projectID": "project_id"]) }))
        }
        if let runs = value["runs"].elements {
            output = output.setting("runs", .array(runs.map { row in
                var result = aliases(row, ["startedAt": "started_at", "finishedAt": "ended_at", "taskID": "task_id",
                    "sessionID": "session_id", "sessionName": "session_name", "result": "outcome", "costUSD": "cost_usd", "projectID": "project_id"])
                if !result.has("durationMs"), let start = result["startedAt"].number, let end = result["finishedAt"].number, end >= start {
                    result = result.setting("durationMs", .number(end - start))
                }
                return result
            }))
        }
        return output
    }
}
