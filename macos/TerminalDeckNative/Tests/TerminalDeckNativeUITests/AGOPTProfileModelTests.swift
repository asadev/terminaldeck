import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
private func AGOPTModelFixture(api: Bool?, writer: (@MainActor (NativeRPCValue) async throws -> Void)? = nil) throws -> AGOPTProfileModel {
    let profile = AgentProfile(id: "fixture-reviewer", name: "Fixture reviewer", role: "Checks the app", provider: "claude",
        instructions: "Check the current change", keepAliveMinutes: 120, keepAliveUntilClose: false)
    let settings = AGSAgentSettings(provider: "claude", efficiency: .init(agentTokenBudget: 200_000, taskTokenBudget: 50_000,
        warningPercent: 80, monthlyBudgetUSD: api == true ? 150 : nil, onExhaustion: "warn"))
    let snapshot: NativeRPCValue = .object([
        .init("profile", try .fromFoundation(profile.wire)),
        .init("ags", .object([.init("revision", .number(0))])),
        .init("stats", .object([.init("isAPIAccount", api.map(NativeRPCValue.bool) ?? .null)])),
        .init("budget", .object([.init("unit", .string(api == true ? "usd" : api == false ? "tokens" : "unknown")),
            .init("limit", .number(api == true ? 150 : 200_000)), .init("warningPercent", .number(80)), .init("onExhaustion", .string("warn"))])),
        .init("source", .object([.init("separateExtraInstructions", .bool(false))]))
    ])
    return AGOPTProfileModel(id: profile.id, fixture: snapshot, settings: settings, fixtureWriter: writer)
}

@MainActor @Test
func AGOPTStopToggleEditsCanonicalRetentionOnce() throws {
    let model = try AGOPTModelFixture(api: false)
    #expect(model.stopWhenDone.wrappedValue == false)
    model.stopWhenDone.wrappedValue = true
    #expect(model.draft.keepAliveMinutes == "0")
    #expect(model.draft.keepAliveUntilClose == false)
    #expect(model.ags.settings.keepOpen == false)
    #expect(model.ags.settings.efficiency?.completion == "park")
    model.stopWhenDone.wrappedValue = false
    #expect(model.draft.keepAliveUntilClose == true)
    #expect(model.ags.settings.keepOpen == true)
}

@MainActor @Test
func AGOPTMonthlyAndTaskBudgetsUseExistingAGSRecord() throws {
    let model = try AGOPTModelFixture(api: false)
    model.monthlyLimit.wrappedValue = 300_000
    model.perTaskTokens.wrappedValue = 40_000
    model.warningPercent.wrappedValue = 90
    model.exhaustionAction.wrappedValue = "pause"
    #expect(model.ags.settings.efficiency?.agentTokenBudget == 300_000)
    #expect(model.ags.settings.efficiency?.taskTokenBudget == 40_000)
    #expect(model.ags.settings.efficiency?.warningPercent == 90)
    #expect(model.ags.settings.efficiency?.onExhaustion == "pause")
    #expect(model.ags.settings.efficiency?.monthlyBudgetUSD == nil)
    model.monthlyLimit.wrappedValue = nil
    #expect(model.ags.settings.efficiency?.agentTokenBudget == 0)
}

@MainActor @Test
func AGOPTAPIAndUnknownAccountsNeverPretendToBePlanAccounts() throws {
    let api = try AGOPTModelFixture(api: true)
    api.monthlyLimit.wrappedValue = 200
    #expect(api.ags.settings.efficiency?.monthlyBudgetUSD == 200)
    #expect(api.ags.settings.efficiency?.agentTokenBudget == 200_000)
    #expect(api.isAPI && !api.isPlan)
    let unknown = try AGOPTModelFixture(api: nil)
    #expect(!unknown.isAPI && !unknown.isPlan)
    #expect(unknown.separateExtraInstructions == false)
}

@MainActor @Test
func AGOPTSaveOwnerSerializesSameRetentionAndBudgetPayload() async throws {
    var captured: NativeRPCValue?
    let model = try AGOPTModelFixture(api: false) { captured = $0 }
    model.stopWhenDone.wrappedValue = false
    model.perTaskTokens.wrappedValue = 20_000
    await model.saveOwner()
    let saved = try #require(captured)
    #expect(saved["keepAliveUntilClose"].bool == true)
    #expect(saved["ags"]["keepOpen"].bool == true)
    #expect(saved["ags"]["efficiency"]["taskTokenBudget"].number == 20_000)
    #expect(saved["agsRevision"].number == 0)
    #expect(model.saveStatus == "Saved")
}

/// U114 (#190): the settings window is the one editor, so what only the old Settings form held saves through it.
@MainActor @Test
func AGOPTOneEditorSavesAvoidedToolsAndAllowList() async throws {
    var captured: NativeRPCValue?
    let model = try AGOPTModelFixture(api: false) { captured = $0 }
    model.draft.toolsAvoided = ["WebFetch"]
    model.ags.settings.allowedTools = ["Read", "mcp__github__get_issue"]
    model.changed()
    await model.saveOwner()
    let saved = try #require(captured)
    #expect(saved["toolsAvoided"].elements?.compactMap(\.string) == ["WebFetch"])
    #expect(saved["allowedTools"].elements?.compactMap(\.string) == ["Read", "mcp__github__get_issue"])
    #expect(saved["ags"]["allowedTools"].elements?.compactMap(\.string) == ["Read", "mcp__github__get_issue"])
    #expect(model.saveStatus == "Saved")
}

/// U114 (#190): a source guard. Settings › Tasks and the New agent page never grow a second agent editor again;
/// both hand the agent to its settings window.
@Test
func AGOPTSettingsAndNewAgentOpenTheOneEditor() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TerminalDeckNative")
    let tasks = try String(contentsOf: sources.appendingPathComponent("NativeTasksSettings.swift"), encoding: .utf8)
    let hire = try String(contentsOf: sources.appendingPathComponent("AGTNewAgentView.swift"), encoding: .utf8)
    #expect(!tasks.contains("AgentFormView") && !tasks.contains("\"tasks:agent-save\""))
    #expect(tasks.contains("AGTAgentSettingsWindow.open(agent.id)"))
    #expect(!hire.contains("AgentFormView") && hire.contains("AGTAgentSettingsWindow.open(profile.id)"))
}

@MainActor
private func AGOPTChangedElsewhere(_ model: AGOPTProfileModel, name: String, revision: Double) throws -> NativeRPCValue {
    let profile = AgentProfile(id: "fixture-reviewer", name: name, role: "Checks the app", provider: "claude",
        instructions: "Check the current change", keepAliveMinutes: 120, keepAliveUntilClose: false)
    return model.snapshot.setting("profile", try .fromFoundation(profile.wire))
        .setting("ags", .object([.init("revision", .number(revision))]))
}

@MainActor @Test
func AGOPTChangeElsewhereReplacesOnlyAnUntouchedDraft() async throws {
    var captured: NativeRPCValue?
    let model = try AGOPTModelFixture(api: false) { captured = $0 }
    // Renamed from an MCP tool while the page is open with nothing typed: the page shows it.
    model.accept(try AGOPTChangedElsewhere(model, name: "Renamed elsewhere", revision: 3), replacingDraft: false)
    #expect(model.draft.name == "Renamed elsewhere")
    #expect(!model.settingsChangedElsewhere)
    // A later edit saves on top of that change, with its revision, never the old values.
    model.draft.role = "Typed here"; model.changed()
    model.accept(try AGOPTChangedElsewhere(model, name: "Renamed again", revision: 3), replacingDraft: false)
    #expect(model.draft.role == "Typed here")
    #expect(model.draft.name == "Renamed elsewhere")
    await model.saveOwner()
    let saved = try #require(captured)
    #expect(saved["name"].string == "Renamed elsewhere")
    #expect(saved["agsRevision"].number == 3)
}

@MainActor @Test
func AGOPTOwnSaveIsNeverReportedAsChangedElsewhere() async throws {
    var model: AGOPTProfileModel?
    model = try AGOPTModelFixture(api: false) { _ in
        // The engine's event for this very save is read while the save is still in flight.
        guard let model else { return }
        model.accept(model.snapshot.setting("ags", .object([.init("revision", .number(1))])), replacingDraft: false)
    }
    let owner = try #require(model)
    owner.perTaskTokens.wrappedValue = 20_000
    await owner.saveOwner()
    #expect(!owner.settingsChangedElsewhere)
    #expect(owner.saveStatus == "Saved")
}

@MainActor @Test
func AGOPTActualEngineKeysPreserveReportedValuesAndUnknowns() {
    let raw: NativeRPCValue = .object([
        .init("stats", .object([.init("runs14days", .number(38)), .init("finishedWithoutHelp", .number(92)), .init("tokensThisMonth", .null)])),
        .init("budget", .object([.init("billing_kind", .string("api")), .init("unit", .string("usd")), .init("spent", .number(61)),
            .init("monthly_budget", .number(150)), .init("warning_percent", .number(80)), .init("on_exhaustion", .string("warn")),
            .init("days", .array([.object([.init("day", .string("2026-10-10")), .init("cost_usd", .number(1.25))])]))])),
        .init("runtime", .object([.init("status", .string("working")), .init("taskId", .string("task-1"))]))
    ])
    let projected = AGOPTProfileDTO.normalized(raw)
    #expect(projected["stats"]["runs14d"].number == 38)
    #expect(projected["stats"]["successRate"].number == 0.92)
    #expect(projected["stats"]["monthTokens"].isNullish)
    #expect(projected["budget"]["used"].number == 61)
    #expect(projected["budget"]["daily"].elements?.first?["costUSD"].number == 1.25)
    #expect(projected["runtime"]["state"].string == "working")
    let unknown = AGOPTProfileDTO.normalized(raw.setting("budget", .object([.init("unit", .string("tokens")), .init("billing_kind", .string("unknown"))])))
    #expect(unknown["budget"]["unit"].string == "unknown")
    #expect(unknown["budget"]["daily"].elements == nil)
}

@MainActor @Test
func AGTShowTheChangeUsesTheRunsOwnChangeNotItsTask() throws {
    let model = try AGOPTModelFixture(api: false)
    model.snapshot = model.snapshot.setting("runs", .array([
        .object([.init("id", .string("run-1")), .init("taskID", .string("task-1")), .init("changePath", .string("/work/project/changes.diff"))]),
        .object([.init("id", .string("run-2")), .init("taskID", .string("task-2"))])]))
    #expect(model.changePath(ofRun: "run-1") == "/work/project/changes.diff")
    #expect(model.changePath(ofRun: "run-2") == nil)
}

@MainActor @Test
func AGTShowTheSkillOpensThatSkillsPreview() async {
    let store = ROUTINESSkillsStore(); store.fixture = true
    store.installed = [ROUTINESSkill(id: "/fixture/skills/check", name: "check", source: "project", folder: "/fixture/skills/check"),
                       ROUTINESSkill(id: "/fixture/skills/ship", name: "ship", source: "project", folder: "/fixture/skills/ship")]
    await store.open(id: "/fixture/skills/ship")
    #expect(store.preview?["id"].string == "/fixture/skills/ship")
    store.preview = nil
    await store.open(id: "/fixture/skills/gone")
    #expect(store.preview == nil)
    #expect(store.problem != nil)
}
