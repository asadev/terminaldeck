import AppKit
import CryptoKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Pictures of the calmer Coding AIs, Which account agents use, Agents (per AI), Tasks, a task agent's page, Sign-in
/// and a device's page, light and dark, drawn offscreen into night/codex/settings-pages-evidence (never in a window
/// on screen). Made-up people only.
@MainActor
final class SettingsPagesPictures: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    typealias N = NativeSettingsNavigation
    static let size = CGSize(width: 1240, height: 832)

    func testPicturesBothThemes() async throws {
        NativeSettingsValues.shared.beginOffscreenFixture()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/settings-pages-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // Coding AIs: two installed AIs, a signed-in account, the Mac's own login signed out (said once).
        let workRow = NativeCodingAIAccountFacts(name: "Work", plan: "Max", dot: .ready, state: nil, info: "work@example.com")
        let own = NativeCodingAIAccountFacts(name: "This Mac’s own Claude Code login", plan: nil, dot: .needsAction,
                                             state: NativeCodingAIAccountFacts.needsSignIn, info: "Last signed in here as sam@example.com")
        let codex = NativeCodingAIAccountFacts(name: "sam", plan: "ChatGPT Plus", dot: .ready, state: nil, info: "sam@example.com")

        // Which account agents use.
        var mac = CodingAIAccount(id: "system", name: "Default", provider: "claude"); mac.system = true
        let work = CodingAIAccount(id: "work", name: "Work", provider: "claude")
        let crm = PROJProject(id: "crm", name: "CRM", folders: ["/scratch/CRM"], colour: "blue")
        let rows = [
            NativeAccountLevelRow(id: "app", kind: .app, title: "Whole Terminal Deck", levels: [["kind": "app"]]),
            NativeAccountLevelRow(id: "seat:orchestrator", kind: .hoot, title: "Hoot", levels: [["kind": "seat", "key": "orchestrator"]]),
            NativeAccountLevelRow(id: "project:crm", kind: .project, title: "CRM", project: crm, levels: [["kind": "project", "path": "/scratch/CRM"]]),
            NativeAccountLevelRow(id: "seat:role:crm/builder", kind: .role, title: "Builder", project: crm, levels: [["kind": "seat", "key": "role:crm/builder"]]),
            NativeAccountLevelRow(id: "seat:role:crm/reviewer", kind: .role, title: "Reviewer", project: crm, levels: [["kind": "seat", "key": "role:crm/reviewer"]]),
        ]
        NativeAccountLevelsModel.shared.setFixture(app: ["claude": "work"], projects: [:], seats: [:], sessions: [], usage: [:], olderHelper: false)

        // Tasks.
        let critic = AgentProfile(id: "critic", name: "Critic", role: "Reviews every change and says plainly what to fix before it ships to anyone",
                                  provider: "claude", model: "opus", effort: "high", maxConcurrent: 1,
                                  sourceFile: "/scratch/agents/critic.md", syncedAt: 1_763_168_580_000, syncStatus: "synced")
        let builder = AgentProfile(id: "builder", name: "Builder", role: "Writes the code for a task", provider: "codex", maxConcurrent: 2)
        var archived = AgentProfile(id: "old", name: "Old helper", role: "Kept for later", provider: "claude"); archived.status = .archived
        let state = TasksState(agents: [critic, builder, archived])
        let projects = [crm, PROJProject(id: "site", name: "Website", folders: ["/scratch/site"], colour: "green")]

        // Sign-in and a device (the Settings window lane's fixture).
        let model = NativeCloudAccount.shared
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day: Int64 = 86_400_000
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                                 y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        let gate = CloudGate(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, revision: CloudSequence(1), expiresAt: now + 300_000)
        func device(_ n: Int, _ label: String, _ platform: CloudPlatform, seen: Int64) -> CloudDevice {
            .init(deviceId: String(format: "10000000-0000-4000-8000-%012d", n), label: label, platform: platform, appVersion: "fixture", status: .active,
                  secretsApproved: false, lastSeenAt: seen, signPublicJwk: key, wrapPublicJwk: key, registeredAt: now - 30 * day)
        }
        let devices = [device(1, "Sam's Mac mini", .macos, seen: now), device(2, "Sam's iPhone", .ios, seen: now - 3_600_000)]
        let trust = BackendCloudTrustRows.build(devices: devices, list: nil, thisDeviceId: devices[0].deviceId)
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: gate, displayName: "Sam Rivera", devices: devices,
                                            coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 3, bytes: 20, blockedReasons: [])],
                                            trust: trust)
        let reach = DevicesPage.Reach(available: true, on: true, entitled: true, door: .ready)
        defer { model.fixture(.signedOut); model.fixtureUser(nil); model.fixtureProfile(nil); NativeCloudDisplayGate.shared.offer(false) }
        NativeCloudDisplayGate.shared.offer(true)
        model.fixture(snapshot)
        model.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", email: "sam@example.com", provider: "github"))
        model.fixtureProfile(.init(name: "Sam Rivera", username: "sam", email: "sam@example.com", picture: nil,
                                   ways: [.init(provider: "google", providerName: "Google", account: "sam@example.com"),
                                          .init(provider: "github", providerName: "GitHub", account: "@sam"),
                                          .init(provider: "apple", providerName: "Apple", account: "sam@example.com")], addable: []))
        let fixture = NativeDevicesFixture(reach: reach, old: [])
        let deviceRows = NativeDevicesSettings.rows(account: DevicesPage.accountDevices(snapshot), old: [])
        let phone = try XCTUnwrap(deviceRows.first { $0.name == "Sam's iPhone" })

        for dark in [false, true] {
            try render(shell("agents") {
                DeckSettingsScaffold(title: "Coding AIs") {
                    self.codingGroup("claude", "Claude Code", [workRow, own])
                    self.codingGroup("codex", "Codex", [codex])
                    DeckSettingsGroup { DeckSettingsLinkRow(title: NativeCodingAIThisMachine.whichAccountTitle) {} }
                }
            }, "coding-ais", dark, output)
            try render(shell(N.whichAccountID) {
                NativeWhichAccountPage(fixtureAccounts: [mac, work], fixtureRows: rows)
            }, "which-account", dark, output)
            for ai in ["claude", "codex", "gemini"] {
                let choice = NativeAGSPageChoice(); choice.provider = ai
                try render(shell("agent-defaults") {
                    NativeAGSDefaultsSettingsSections(model: NativeAGSSettingsModel.rendered(AGSAgentSettings()), choice: choice,
                                                      fixtureProviders: ["claude", "codex", "gemini"])
                }, "agents-\(ai)", dark, output)
            }
            try render(shell("tasks") { NativeTasksSettings(fixtureState: state, fixtureProjects: projects) }, "tasks", dark, output)
            try render(shell(N.taskAgentPage("critic")) {
                NativeTaskAgentPage(agentID: "critic", fixture: (critic, [critic, builder, archived]))
            }, "task-agent", dark, output)
            try render(shell(N.signInID) { NativeProfileSignInPage(model: model) }, "sign-in", dark, output)
            try render(shell(N.devicePage(phone.id)) { NativeDevicePage(rowID: phone.id, account: model, fixture: fixture) }, "device-page", dark, output)
        }
        await NativeSettingsValues.shared.endOffscreenFixture()
    }

    /// SP-1, SP-2 (15 Nov): the rules that need no picture.
    func testCodingAIsNamesTheModelAndTheAgentsFieldsAreQuiet() throws {
        XCTAssertEqual(NativeCodingAIThisMachine.defaultModelWords(chosen: nil, cliDefault: "claude-fable-5-2"), "Fable 5.2")
        XCTAssertEqual(NativeCodingAIThisMachine.defaultModelWords(chosen: "claude:claude-opus-5-5", cliDefault: "claude-fable-5-2"), "Opus 5.5")
        XCTAssertEqual(NativeCodingAIThisMachine.defaultModelWords(chosen: "default", cliDefault: "opus"), "Opus")
        // Small fixes item 2: Codex and Gemini are named too, never a raw id.
        XCTAssertEqual(NativeCodingAIThisMachine.defaultModelWords(chosen: nil, cliDefault: "gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(NativeCodingAIThisMachine.defaultModelWords(chosen: "codex:gpt-5.5-codex", cliDefault: nil), "GPT-5.5 Codex")
        XCTAssertEqual(NativeCodingAIThisMachine.defaultModelWords(chosen: nil, cliDefault: "gemini-2.5-pro"), "Gemini 2.5 Pro")
        XCTAssertEqual(NativeSettingsMoreGlyph.glyph, "ellipsis")
        XCTAssertEqual(NativeSettingsMoreGlyph.size, 13)
        XCTAssertEqual(DeckSettingsQuietField.width, 120)
        XCTAssertEqual(DeckSettingsQuietField.radius, 6)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let editor = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/NativeAGSDefaultsEditor.swift"), encoding: .utf8)
        let defaults = try XCTUnwrap(editor.components(separatedBy: "private struct NativeAGSBehaviourRows").first)
        XCTAssertFalse(defaults.contains(".textFieldStyle(.roundedBorder)"), "no black-outlined boxes in Defaults and Budgets")
        XCTAssertEqual(editor.components(separatedBy: "DeckSettingsQuietField()").count - 1, 4, "Model, Monthly API money, Warn at and the number fields")
    }

    /// One AI's two groups on Coding AIs, built from the page's own parts.
    @ViewBuilder private func codingGroup(_ id: String, _ title: String, _ accounts: [NativeCodingAIAccountFacts]) -> some View {
        VStack(alignment: .leading, spacing: DeckSettingsLook.groupTitleGap) {
            NativeCodingAIGroupTitle(provider: id, title: title, info: "Version 2.1")
            DeckSettingsGroup {
                ForEach(accounts, id: \.name) { facts in
                    NativeCodingAIAccountLine(facts: facts) { NativeSettingsMoreMenu(label: facts.name) { Button("Sign out") {} } }
                }
                DeckSettingsButtonRow(title: "+ Add account") {}
            }
            Color.clear.frame(height: DeckSettingsLook.groupGap - DeckSettingsLook.groupTitleGap)
            DeckSettingsGroup {
                DeckSettingsToggleRow("Live status", info: "Lets its tabs show Working, Waiting for you or Done.", isOn: .constant(true))
                // SP-1: the real model's name, never the word "Default".
                DeckSettingsLinkRow(title: "Default model",
                                    value: NativeCodingAIThisMachine.defaultModelWords(chosen: nil, cliDefault: id == "claude" ? "claude-fable-5-2" : "gpt-5.5")) {}
                DeckSettingsLinkRow(title: "Default effort", value: "High") {}
            }
        }
    }

    /// The window's own title-bar band (28 pt) above the shell, as the real window draws it.
    private func shell<V: View>(_ id: String, @ViewBuilder _ page: @escaping () -> V) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)
            NativeSettingsShell(selection: .constant(id)) { _ in page() }
        }
        .background(DeckTokens.page)
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL) throws {
        let size = Self.size
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("settings-pages-\(name)-\(dark ? "dark" : "light").png"))
    }
}
