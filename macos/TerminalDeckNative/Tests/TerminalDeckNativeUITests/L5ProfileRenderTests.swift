import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Windowless actual-view proof. This source joins the existing UI test target
/// once the A3 views and shared frame compile. No app entry, NSApp or NSWindow.
@MainActor @Test
func L5ProfileAndSettingsFrames() throws {
    let store = AGTAgentsStore.shared
    let before = store.fixture, previousSettings = store.fixtureAgentSettings
    defer { store.fixture = before; store.fixtureAgentSettings = previousSettings }
    let profile = AgentProfile(id: "accounts-keeper", name: "accounts-keeper", role: "Sign-in and accounts", provider: "claude",
        model: "sonnet", effort: "high", instructions: "Check sign-in and report the result.",
        keepAliveMinutes: 0, keepAliveUntilClose: false, defaultProject: "/fixtures/imatch")
    store.fixture = TasksState(agents: [profile])
    let settings = AGSAgentSettings(provider: "claude", model: "sonnet", effort: "high", permissionMode: "default",
        mcpServers: ["project-tools": true, "optional-tools": false], workingFolder: "/fixtures/imatch",
        efficiency: .init(reuseContext: true, completion: "park", agentTokenBudget: 5_000_000,
            taskTokenBudget: 200_000, warningPercent: 80, serializeHeavyJobs: true, monthlyBudgetUSD: 150, onExhaustion: "warn"))
    store.fixtureAgentSettings[profile.id] = settings
    let snapshot = try L5FixtureSnapshot(profile: profile)
    let model = AGOPTProfileModel(id: profile.id, fixture: snapshot, settings: settings)
    var actionCounts: [AgentMenu.Action: Int] = [:]
    var actions = AgentMenu.Actions(name: profile.name)
    for action in AgentMenu.Action.allCases { actions.perform[action] = { actionCounts[action, default: 0] += 1 } }
    for dark in [false, true] {
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 1000, height: 700)] {
            for tab in ["dashboard", "instructions", "skills", "runs", "budget"] {
                let view = AGTProfileView(agentID: profile.id, fixtureModel: model, fixtureActions: actions, initialTab: tab)
                try L5Render(view, size: size, dark: dark, name: "profile-\(tab)-\(Int(size.width))x\(Int(size.height))")
            }
        }
        for tab in ["general", "coding", "limits", "tools", "advanced"] {
            try L5Render(AGTAgentSettingsWindow(model: model, initialTab: tab),
                size: CGSize(width: 600, height: 690), dark: dark, name: "settings-\(tab)-600x690")
        }
    }
    #expect(actionCounts.isEmpty) // drawing never wakes, pauses or assigns work
}

@MainActor
private func L5Render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    #expect(host.window == nil)
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let file = URL(fileURLWithPath: #filePath)
    let workspace = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let out = workspace.appendingPathComponent("macos/design-2026-10-10/built.noindex")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try png.write(to: out.appendingPathComponent("L5-\(name)-\(dark ? "dark" : "light").png"), options: .atomic)
}

private func L5FixtureSnapshot(profile: AgentProfile) throws -> NativeRPCValue {
    let now: Double = Date().timeIntervalSince1970 * 1000
    var tasks: [Any] = []
    for n in 1...7 {
        var row: [String: Any] = [:]
        row["id"] = "fixture-task-\(n)"
        row["title"] = n == 2 ? "Google sign-in loops on Safari" : "Review sign-in change \(n)"
        let state: String = n == 2 ? "Working" : (n == 3 ? "Waiting for you" : (n == 5 ? "Failed" : "Done"))
        row["state"] = state
        row["updatedAt"] = now - Double(n * 3_600_000)
        tasks.append(row)
    }
    var runs: [Any] = []
    for n in 1...6 {
        var row: [String: Any] = [:]
        row["id"] = "fixture-run-\(n)"; row["taskID"] = "fixture-task-\(n)"; row["title"] = "Sign-in review \(n)"
        row["startedAt"] = now - Double(n * 7_200_000); row["finishedAt"] = now - Double(n * 3_600_000)
        row["durationMs"] = 720_000.0; row["result"] = "completed"; row["tokens"] = 42_000.0; row["costUSD"] = 0.61
        row["sessionName"] = "Fixture session"; row["summary"] = "The callback now reports the correct account. Focused checks passed."
        runs.append(row)
    }
    var daily: [Any] = []
    for d in 1...30 { daily.append(["day": String(d), "tokens": Double(d * 1000), "costUSD": Double(d) / 10] as [String: Any]) }
    var source: [String: Any] = [:]
    source["path"] = "/fixtures/accounts-keeper.md"; source["body"] = "# accounts-keeper\n\nCheck the account sign-in flows."
    source["revision"] = "fixture-source-version"; source["can_save"] = true; source["separateExtraInstructions"] = false
    var runtime: [String: Any] = [:]
    runtime["state"] = "working"; runtime["title"] = "Google sign-in loops on Safari"; runtime["taskID"] = "fixture-task-2"
    runtime["detail"] = "Started 12 min ago · last step: reading the callback"
    var stats: [String: Any] = [:]
    stats["runs14d"] = 38.0; stats["tasksDone"] = 21.0; stats["successRate"] = 0.92
    stats["monthTokens"] = 4_100_000.0; stats["costUSD"] = 61.0; stats["isAPIAccount"] = true
    var budget: [String: Any] = [:]
    budget["unit"] = "usd"; budget["limit"] = 150.0; budget["used"] = 61.0; budget["warningPercent"] = 80.0
    budget["onExhaustion"] = "warn"; budget["daily"] = daily
    let skill: [String: Any] = ["id": "sign-in-flows", "name": "sign-in-flows", "source": "iMatch", "enabled": true]
    let account: [String: Any] = ["id": "fixture-account", "name": "Fixture API account", "provider": "claude"]
    let mcp: [Any] = [["name": "project-tools", "enabled": true] as [String: Any], ["name": "optional-tools", "enabled": false] as [String: Any]]
    var choices: [String: Any] = [:]
    choices["providersInstalled"] = ["claude": true, "codex": true, "gemini": false] as [String: Any]
    choices["accounts"] = [account]; choices["models"] = ["claude": ["sonnet", "opus"]] as [String: Any]; choices["mcp"] = mcp
    var root: [String: Any] = [:]
    root["profile"] = profile.wire; root["ags"] = ["revision": 0.0] as [String: Any]; root["source"] = source
    root["project"] = ["name": "iMatch", "colour": "blue"] as [String: Any]; root["runtime"] = runtime; root["stats"] = stats
    root["tasks"] = tasks; root["taskCount"] = 26.0; root["runs"] = runs; root["skills"] = [skill]; root["budget"] = budget
    root["choices"] = choices
    return try NativeRPCValue.fromFoundation(root)
}

@MainActor @Test
func L5HootQuickSettingsFrames() throws {
    let never: @MainActor (String, [Any?]) async throws -> CodingAIJSON = { channel, _ in throw NativeRPCError.invalidArguments("Fixture called " + channel) }
    let brain = ROUTINESHootBrainModel(snapshot: CodingAIJSON(["provider": "claude", "choices": ["provider": "claude", "profileId": "fixture-account",
        "model": "opus", "effort": "high", "permissionMode": "acceptEdits", "contextWindow": "1m"],
        "accounts": [["id": "fixture-account", "name": "Fixture · Max plan", "provider": "claude"]]]), invoke: never)
    for dark in [false, true] {
        try L5Render(HootQuickSettings(brain: brain, live: false), size: HootQuickSettings.size, dark: dark, name: "hoot-quick-settings")
    }
}
