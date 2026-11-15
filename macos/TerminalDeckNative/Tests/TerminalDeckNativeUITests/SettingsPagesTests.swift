import AppKit
import CryptoKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Owner, 15 Nov (REQUIREMENTS items 49, 52, 54, 59, 61, 64; DESIGN.md section 6): Coding AIs, Agents and Tasks made
/// calm. Installed AIs only, a signed-out login said once, no path or id on Tasks, every old setting still reachable,
/// and the device rename call's shape. Made-up data only.
@MainActor
final class SettingsPagesTests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ name: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + name), encoding: .utf8)
    }
    typealias N = NativeSettingsNavigation

    // MARK: Installed AIs only

    func testOnlyInstalledAIsGetAGroupOrASegment() throws {
        let claude = CodingAITool(id: "claude", label: "Claude Code", state: .ready, version: "2.1")
        let codex = CodingAITool(id: "codex", label: "Codex", state: .ready)
        XCTAssertEqual(NativeCodingAIThisMachine.installed([claude], focus: nil).map(\.id), ["claude"])
        XCTAssertEqual(NativeCodingAIThisMachine.installed([claude, codex], focus: "codex").map(\.id), ["codex"])
        XCTAssertEqual(NativeAGSAppDefaults.installed([codex]), ["codex"], "Agents offers installed AIs only")
        XCTAssertEqual(NativeAGSAppDefaults.installed([claude, codex]), ["claude", "codex"])
        XCTAssertEqual(NativeAGSAppDefaults.installed(nil), ["claude", "codex", "gemini"], "until the installed list is read")
        let page = try source("NativeCodingAISettings.swift")
        XCTAssertFalse(page.contains("Section(\"More coding AIs\")"), "no group for an AI that is not installed")
        XCTAssertTrue(page.contains("NativeCodingAIThisMachine.installAnotherTitle") || page.contains("Self.installAnotherTitle"))
    }

    // MARK: A signed-out login is said once

    func testASignedOutLoginIsSaidOnceOnItsOwnRow() throws {
        var mac = CodingAIAccount(id: "system", name: "Default", provider: "claude"); mac.system = true
        let snapshot = CodingAIAccountsSnapshot(accounts: [mac], defaultId: nil)
        let out = CodingAISignIn(state: .signedOut, remembered: "sam@example.com")
        let model = CodingAIAccountRowModel.make(account: mac, snapshot: snapshot, signIn: ["system": out], history: [:], providerRows: [],
                                                 sessionTitles: nil, canStartSessions: true, canSignOut: true)
        let facts = NativeCodingAIAccountFacts.make(account: mac, signIn: out, model: model)
        XCTAssertEqual(facts.dot, .needsAction)
        XCTAssertEqual(facts.state, NativeCodingAIAccountFacts.needsSignIn)
        XCTAssertFalse(facts.name.contains("@"), "the row shows a name, the address only in the popover")
        XCTAssertTrue(facts.info.contains("sam@example.com"))
        // Signed in: green dot, the plan as the secondary word, no orange state.
        var work = CodingAIAccount(id: "work", name: "Work", provider: "claude"); work.system = false
        let signedIn = CodingAISignIn(state: .signedIn, account: "work@example.com", plan: "Max")
        let workModel = CodingAIAccountRowModel.make(account: work, snapshot: CodingAIAccountsSnapshot(accounts: [work], defaultId: nil),
                                                     signIn: ["work": signedIn], history: [:], providerRows: [], sessionTitles: nil,
                                                     canStartSessions: true, canSignOut: true)
        let workFacts = NativeCodingAIAccountFacts.make(account: work, signIn: signedIn, model: workModel)
        XCTAssertEqual(workFacts.name, "Work")
        XCTAssertEqual(workFacts.plan, "Max")
        XCTAssertNil(workFacts.state)
        XCTAssertEqual(workFacts.dot, .ready)
        // The "which account" page never repeats it under each agent, and the old repeats are gone.
        let levels = try source("NativeAccountLevels.swift")
        for gone in ["is signed out. Sign in again", "Same as above", "NativeSessionButton(\"Switch now\")", "Who uses what\")"] {
            XCTAssertFalse(levels.contains(gone), gone)
        }
        XCTAssertEqual(NativeAccountLevelsSection.inheritedWord("Work"), "Default (Work)")
        let coding = try source("NativeCodingAISettings.swift")
        XCTAssertFalse(coding.contains("NativeAccountLevelsSection("), "the long list is one row deeper")
        XCTAssertTrue(coding.contains("NativeSettingsNavigation.whichAccountID"))
    }

    // MARK: Tasks: no path, no id, no Show source

    func testTasksPageShowsNoPathOrId() throws {
        let path = "/Users/sam/.claude/agents/critic.md"
        let agent = AgentProfile(id: "agent-7f3a", name: "Critic", role: "Reviews every change\nand says what to fix", provider: "claude",
                                 model: "opus", maxConcurrent: 1, sourceFile: path, syncedAt: 1_763_168_580_000, syncStatus: "synced")
        XCTAssertEqual(NativeTaskAgentRow.oneLine(agent.role), "Reviews every change and says what to fix")
        let info = NativeTaskAgentPage.syncInfo(status: agent.syncStatus, syncedAt: agent.syncedAt)
        XCTAssertFalse(info.contains("/"), info)
        XCTAssertFalse(info.contains(".md"))
        XCTAssertTrue(info.contains("Last synced"))
        let facts = NativeTaskAgentPage.facts(agent)
        for word in [facts.model, facts.limits, facts.limitsInfo, facts.tools] {
            XCTAssertFalse(word.contains("/") || word.contains(agent.id), word)
        }
        let tasks = try source("NativeTasksSettings.swift")
        for gone in ["Show source", "Text(source", "Text(agent.sourceFile", "Text(agent.id", "NativeTAGSourceStatus", "Outside AI apps"] {
            XCTAssertFalse(tasks.contains(gone), gone)
        }
        XCTAssertTrue(tasks.contains("Show in Finder"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("Sources/TerminalDeckNative/NativeTAGProfileSettings.swift").path))
        let words = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNativeCore/TasksSettingsText.swift"), encoding: .utf8)
        XCTAssertFalse(words.contains("Outside AI apps"))
        // The list: working agents first, archived last.
        var old = AgentProfile(id: "b", name: "Old", role: "x"); old.status = .archived
        let new = AgentProfile(id: "a", name: "New", role: "y")
        XCTAssertEqual(NativeTasksPageBody.listed([old, new]).map(\.name), ["New", "Old"])
    }

    // MARK: Nothing is lost

    /// Every setting the three pages offered before 15 Nov, and where it is now (at most one click deeper).
    func testEveryOldSettingIsStillReachable() throws {
        let places: [(old: String, file: String, needle: String)] = [
            // Coding AIs
            ("Accounts / Add account", "NativeCodingAISettings.swift", "\"+ Add account\""),
            ("Sign in (no accounts)", "NativeCodingAISettings.swift", "store.signInInstall(tool.id)"),
            ("Account: Sign in again", "NativeCodingAIAccounts.swift", "\"Sign in again\""),
            ("Account: Sign out", "NativeCodingAIAccounts.swift", "Button(\"Sign out\")"),
            ("Account: Rename", "NativeCodingAIAccounts.swift", "Button(\"Rename\")"),
            ("Account: Remove", "NativeCodingAIAccounts.swift", "Button(\"Remove\", role: .destructive)"),
            ("Account: Remove copy", "NativeCodingAIAccounts.swift", "store.removeCopy(copy)"),
            ("Account: Check key", "NativeCodingAIAccounts.swift", "NativeAPIAccounts.shared.check(account.id)"),
            ("Account: Edit API key", "NativeCodingAIAccounts.swift", "NativeAPIAccountEditor(account: account)"),
            ("Account: Install missing AI", "NativeCodingAIAccounts.swift", "NativeAIToolInstallModel.shared.install"),
            ("Account: usage line", "NativeCodingAIAccounts.swift", "NativeAccountLevelsModel.shared.usage[account.id]"),
            ("Live status switch", "NativeCodingAISettings.swift", "NativeLiveStatusRow(providerId: tool.id"),
            ("Live status: Fix it", "NativeCodingAISettings.swift", "Button(\"Fix it\")"),
            ("Live status: Set up again / Refresh", "NativeCodingAISettings.swift", "Button(\"Set up again\")"),
            ("Default model", "NativeCodingAISettings.swift", "title: \"Default model\""),
            ("Default effort", "NativeCodingAISettings.swift", "title: \"Default effort\""),
            ("More coding AIs (install)", "NativeCodingAISettings.swift", "NativeAIToolInstallModel.continueToSignIn(agent.id)"),
            ("Updates: Upgrade it / Dismiss / Show again", "NativeCodingAISettings.swift", "store.bringBackDismissed()"),
            ("Allow login store", "NativeCodingAISettings.swift", "NativeAccountVaultRecovery(store: store)"),
            ("Who uses what: row pop-up", "NativeAccountLevels.swift", "Picker(\"Account for"),
            ("Who uses what: Switch now", "NativeAccountLevels.swift", "Button(\"Switch running sessions now\")"),
            ("Who uses what: Switch everything now", "NativeAccountLevels.swift", "Button(\"Switch all now\")"),
            ("Who uses what: AI chooser", "NativeAccountLevels.swift", "Picker(\"AI\", selection: $model.provider)"),
            ("Who uses what: find", "NativeAccountLevels.swift", "Find a project or role"),
            // Agents
            ("Model", "NativeAGSDefaultsEditor.swift", "DeckSettingsRow(\"Model\""),
            ("Thinking level", "NativeAGSDefaultsEditor.swift", "DeckSettingsRow(\"Thinking\""),
            ("Permission mode", "NativeAGSDefaultsEditor.swift", "DeckSettingsRow(\"Permission\""),
            ("Monthly token budget", "NativeAGSDefaultsEditor.swift", "\\.agentTokenBudget"),
            ("Monthly API budget", "NativeAGSDefaultsEditor.swift", "\\.monthlyBudgetUSD"),
            ("When the budget runs out", "NativeAGSDefaultsEditor.swift", "\\.onExhaustion"),
            ("Task token budget", "NativeAGSDefaultsEditor.swift", "\\.taskTokenBudget"),
            ("Warn at", "NativeAGSDefaultsEditor.swift", "\\.warningPercent"),
            ("Reuse conversation", "NativeAGSDefaultsEditor.swift", "\\.reuseContext"),
            ("When keep-open is off", "NativeAGSDefaultsEditor.swift", "\\.completion"),
            ("Extra add-ons", "NativeAGSDefaultsEditor.swift", "\\.addonsOff"),
            ("One heavy job at a time", "NativeAGSDefaultsEditor.swift", "\\.serializeHeavyJobs"),
            ("Terminal Deck hooks: add / change / test / remove / on", "NativeAGSDefaultsEditor.swift", "NativeAGSAppHookEditor(hook: hook"),
            ("Save / Discard / Reload", "NativeAGSSettingsSections.swift", "model.discardChanges()"),
            // Tasks
            ("Project workflows", "NativePCProjectWorkflows.swift", "PCProjectWorkflowEditor(project: folder"),
            ("Agent: Settings…", "NativeTasksSettings.swift", "AGTAgentSettingsWindow.open(agent.id)"),
            ("Agent: Pause / Resume", "NativeTasksSettings.swift", ".pause : .resume"),
            ("Agent: Archive / Restore", "NativeTasksSettings.swift", "lifecycle(agent.id, .restore)"),
            ("Agent: Delete", "NativeTasksSettings.swift", "\"tasks:agent-remove\""),
            ("Agent: source file", "NativeTasksSettings.swift", "activateFileViewerSelecting"),
            ("Add agent", "NativeTasksSettings.swift", "\"+ Add agent\""),
            ("Import from .claude/agents", "NativeTasksSettings.swift", "AGFRAMEImportModel()"),
            ("CRM connections", "NativeTasksSettings.swift", "CrmConnectionsGroup(state: state"),
            ("Connected task systems", "NativeTasksSettings.swift", "ConnectedTaskSystemsGroup()"),
        ]
        for place in places {
            XCTAssertTrue(try source(place.file).contains(place.needle), "\(place.old) is no longer in \(place.file)")
        }
        // The pages one click deeper are routed and light their parent's row.
        let window = try source("SettingsWindow.swift")
        for page in ["NativeWhichAccountPage()", "NativeAGSHooksPage()", "NativeTaskConnectionsPage()", "NativeTaskAgentPage(agentID:", "NativeProjectWorkflowPage(projectID:"] {
            XCTAssertTrue(window.contains(page), page)
        }
        XCTAssertEqual(N.listRow(N.whichAccountID), "agents")
        XCTAssertEqual(N.listRow(N.agentHooksID), "agent-defaults")
        XCTAssertEqual(N.listRow(N.taskConnectionsID), "tasks")
        XCTAssertEqual(N.listRow(N.taskAgentPage("critic")), "tasks")
        XCTAssertEqual(N.listRow(N.taskWorkflowPage("p1")), "tasks")
        XCTAssertEqual(N.taskAgent(N.taskAgentPage("critic")), "critic")
        XCTAssertTrue(N.nativeOnly(N.taskWorkflowPage("p1")), "kept on show when the web page re-reports its list")
    }

    func testAgentsPageWordsAndNoSentenceUnderATitle() throws {
        XCTAssertEqual(NativeAGSDefaultsEditor.defaultWord, "Default")
        let editor = try source("NativeAGSDefaultsEditor.swift")
        for gone in ["\"App default\"", "\"Agent default\"", "Section(", ".font(.callout).foregroundStyle(.secondary)"] {
            XCTAssertFalse(editor.contains(gone), gone)
        }
        for group in ["DeckSettingsGroup(\"Defaults\")", "DeckSettingsGroup(\"Budgets\")", "DeckSettingsGroup(\"Behaviour\")"] {
            XCTAssertTrue(editor.contains(group), group)
        }
        for file in ["NativeCodingAISettings.swift", "NativeAccountLevels.swift", "NativeAGSSettingsSections.swift", "NativeTasksSettings.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("NativeSettingsPage(sectionId:"), file)
        }
    }

    // MARK: Device rename

    func testDeviceRenameCallShape() throws {
        XCTAssertEqual(CloudDeviceRename.path, "/devices/rename", "under the service's /v1 base: POST /v1/devices/rename")
        let body = try CloudDeviceRename.body(deviceId: "10000000-0000-4000-8000-000000000002", name: "  Studio Mac  ")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["device_id": "10000000-0000-4000-8000-000000000002", "name": "Studio Mac"])
        XCTAssertThrowsError(try CloudDeviceRename.body(deviceId: "d", name: "   "))
        XCTAssertThrowsError(try CloudDeviceRename.body(deviceId: "", name: "Mac"))
        XCTAssertTrue(CloudDeviceRename.accepted(Data(#"{"ok":true}"#.utf8)))
        XCTAssertFalse(CloudDeviceRename.accepted(Data(#"{"ok":false}"#.utf8)))
        XCTAssertFalse(CloudDeviceRename.accepted(Data("{}".utf8)))
        XCTAssertFalse(CloudDeviceRename.accepted(Data("not json".utf8)))
        XCTAssertEqual(NativeDevicePage.renameFailed, "Could not rename")
        // Account devices rename; an old pairing (no Cloud name) does not.
        let row = NativeDevicesSettings.Row(id: "account:x", name: "iPhone", symbol: "iphone", isThisMac: false, lastSeenMs: nil,
                                            connectedNow: false, source: .account(deviceId: "x"))
        XCTAssertEqual(NativeDevicePage.renameTarget(row), "x")
        // Written beside the sign-out call, with the same sign-in headers (account: true, the device proof).
        let transport = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNativeCore/CloudSyncTransport.swift"), encoding: .utf8)
        let start = try XCTUnwrap(transport.range(of: "public func renameDevice(deviceId: String, name: String)"))
        let call = String(transport[start.lowerBound...].prefix(900))
        XCTAssertTrue(call.contains("send(\"POST\", CloudDeviceRename.path"))
        XCTAssertTrue(call.contains("account: true, ownRefusals: true"))
    }

    func testSignInMarksAreTheRealVectors() {
        XCTAssertTrue(NativeSignInMarks.googleSVG.contains("#4285F4") && NativeSignInMarks.googleSVG.contains("#EA4335"))
        XCTAssertTrue(NativeSignInMarks.githubSVG.contains("M8 0C3.58 0 0 3.58 0 8"))
        XCTAssertGreaterThan(NativeSignInMarks.google.size.width, 0)
        XCTAssertTrue(NativeSignInMarks.github.isTemplate)
    }
}

// review-fixes 5: Tasks > Connections: the connected-task-systems explainer is behind the group's info button.
extension SettingsPagesTests {
    func testConnectedTaskSystemsExplainerIsBehindTheInfoButton() throws {
        let group = try source("NativeConnectedTasksSettings.swift")
        XCTAssertTrue(group.contains("DeckSettingsInfoButton(label: \"Connected task systems\", text: Self.about)"))
        XCTAssertFalse(group.contains("Text(\"See and work on tasks"), "no sentence on the page")
        XCTAssertTrue(ConnectedTaskSystemsGroup.about.hasPrefix("See and work on tasks"))
        XCTAssertFalse(ConnectedTaskSystemsGroup.about.contains("stays in your Mac"), "everything travels; never 'stays on this Mac'")
    }
}
