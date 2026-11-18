import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// WhatsApp agents, the screens (DESIGN-WHATSAPP sections 2 and 3). Pictures of Settings > AI apps' "WhatsApp" group in
/// each state and of a session's bar with and without the chip, light and dark, drawn offscreen into
/// night/codex/whatsapp-screens-evidence (never in a window on screen). Made-up names only; the store runs on
/// `WhatsAppAgentsFixture` (no network, no key kept).
@MainActor
final class WhatsAppScreensPictures: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static let size = CGSize(width: 1240, height: 832)

    static let choices = WhatsAppReceiverChoices(
        projects: [.init(id: "CRM", name: "CRM", agents: [.init(id: "builder", name: "Builder"), .init(id: "critic", name: "Critic")])],
        sessions: [.init(id: "s-crm", name: "CRM build"), .init(id: "s-site", name: "Website copy")])

    static func agent(_ n: Int, _ name: String, _ state: WhatsAppAgentState, _ receiver: WhatsAppReceiver, sending: Bool = true) -> WhatsAppAgentProfile {
        var profile = WhatsAppAgentProfile(id: "wa-\(n)", name: name, state: state, receiver: receiver, answeringComputerName: "This Mac", answeredHere: true)
        profile.sending = sending
        return profile
    }

    static let states: [(name: String, list: [WhatsAppAgentProfile], adding: Bool)] = [
        ("none", [], false),
        ("adding", [], true),
        ("two", [agent(1, "Phone", .connected, .hoot), agent(2, "CRM on the go", .waiting, .session(id: "s-crm", name: "CRM build"))], false),
        ("refused", [agent(1, "Phone", .connected, .hoot), agent(2, "Old phone", .refused, .nowhere)], false),
        ("paused", [agent(1, "Phone", .connected, .hoot), agent(2, "CRM on the go", .connected, .session(id: "s-crm", name: "CRM build"), sending: false)], false),
        // His word 4: no limit on our side; the list simply grows and the add row stays.
        ("seven", (1...7).map { agent($0, $0 == 1 ? "WhatsApp agent" : "WhatsApp agent \($0)", .connected, $0 == 1 ? .hoot : .nowhere) }, false),
    ]

    func testSettingsGroupPicturesBothThemes() async throws {
        NativeSettingsValues.shared.beginOffscreenFixture()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/whatsapp-screens-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for state in Self.states {
            let store = try await Self.store(state.list)
            for dark in [false, true] {
                try render(shell {
                    DeckSettingsScaffold(title: "AI apps") {
                        NativeWhatsAppSettingsGroup(store: store, choices: Self.choices, startsAdding: state.adding)
                    }
                }, "settings-\(state.name)", dark, output)
            }
        }
        // The info button's popover (a picture cannot open one).
        for dark in [false, true] {
            try render(NativeWhatsAppInfoContent().background(DeckTokens.page), "info", dark, output, size: CGSize(width: 340, height: 580))
        }
        await NativeSettingsValues.shared.endOffscreenFixture()
    }

    /// The guide alone: one offscreen render, no engine, app launch, preferences or fixture state.
    func testAddGuidePopoverPicture() throws {
        let output = package.deletingLastPathComponent().appendingPathComponent("night/wa-add-guide")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(NativeWhatsAppInfoContent().background(DeckTokens.page), "add-guide", false, output,
                   size: CGSize(width: 308, height: 580))
    }

    /// A session's bar with the chip (a WhatsApp agent attached to it) and without (none attached).
    func testSessionChipPicturesBothThemes() async throws {
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/whatsapp-screens-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Switch on: chip + switch on. Switch off: the chip in secondary colour, the switch off. No chip: nothing at all.
        for (sending, label) in [(true, "chip-switch-on"), (false, "chip-switch-off")] {
            let store = try await Self.store([Self.agent(1, "Phone", .connected, .session(id: "s-crm", name: "CRM build"), sending: sending)])
            XCTAssertEqual(store.chip(for: .session(id: "s-crm", name: ""))?.name, "Phone")
            XCTAssertEqual(store.chip(for: .session(id: "s-crm", name: ""))?.sending, sending)
            XCTAssertNil(store.chip(for: .session(id: "s-site", name: "")), "no chip where none is attached")
            XCTAssertNil(store.chip(for: .hoot))
            for dark in [false, true] {
                try render(bar(id: "s-crm", store: store), "session-\(label)", dark, output, size: CGSize(width: 900, height: 64))
                if sending { try render(bar(id: "s-site", store: store), "session-no-chip", dark, output, size: CGSize(width: 900, height: 64)) }
            }
        }
    }

    private func bar(id: String, store: NativeWhatsAppAgents) -> some View {
        NativeSessionBarFrame {
            EmptyView()
        } title: {
            NativeSessionTitle(title: id == "s-crm" ? "CRM build" : "Website copy", rename: { _ in })
        } place: {
            NativeFolderChip(path: "/work/crm")
            ChipSeparator()
            AccountChipLabel {
                NativeCodingAIProviderMark(provider: "claude", size: 13)
                Text("Work").foregroundStyle(.primary)
            }
            NativeWhatsAppChip(here: .session(id: id, name: ""), store: store)
        } trailing: {
            EmptyView()
        }
        .background(DeckTokens.page)
    }

    /// A store of its own on the fixture, with the list read.
    static func store(_ list: [WhatsAppAgentProfile]) async throws -> NativeWhatsAppAgents {
        let store = NativeWhatsAppAgents()
        store.connect(WhatsAppAgentsFixture(list))
        for _ in 0..<100 where store.agents.count != list.count || (list.isEmpty && store.engine == nil) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.agents, list)
        return store
    }

    /// The Settings window's shell (title-bar band and list), as SettingsPagesPictures draws it.
    private func shell<V: View>(@ViewBuilder _ page: @escaping () -> V) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)
            NativeSettingsShell(selection: .constant("ai-apps")) { _ in page() }
        }
        .background(DeckTokens.page)
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize = WhatsAppScreensPictures.size) throws {
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
            .write(to: output.appendingPathComponent("whatsapp-\(name)-\(dark ? "dark" : "light").png"))
    }
}

/// The submenu and the chip's list, the receiver pop-up's choices, and what must NOT change (session rows, the New
/// session page, the engine's files).
@MainActor
final class WhatsAppScreensRulesTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative")
    }
    private func source(_ file: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8) }

    func testSubmenuListsAgentsByNameWithTheCheckAndOff() {
        let here = WhatsAppReceiver.session(id: "s-crm", name: "CRM build")
        let agents = [WhatsAppScreensPictures.agent(1, "Phone", .connected, .hoot),
                      WhatsAppScreensPictures.agent(2, "CRM on the go", .waiting, .session(id: "s-crm", name: "old name"))]
        let items = WhatsAppMenu.items(agents, here: here)
        XCTAssertEqual(items.map(\.name), ["Phone", "CRM on the go"], "his WhatsApp agents by name, in his order")
        XCTAssertEqual(items.map(\.checked), [false, true], "a check on the one attached here (by id, not by name)")
        XCTAssertEqual(WhatsAppWords.off, "Off")
        XCTAssertEqual(WhatsAppWords.submenuTitle, "WhatsApp")
        XCTAssertEqual(WhatsAppMenu.items(agents, here: .hoot).map(\.checked), [true, false])
    }

    func testChoosingAttachesHereAndOffSendsItNowhere() async throws {
        let here = WhatsAppReceiver.session(id: "s-crm", name: "CRM build")
        let fixture = WhatsAppAgentsFixture([WhatsAppScreensPictures.agent(1, "Phone", .connected, .hoot),
                                             WhatsAppScreensPictures.agent(2, "Spare", .waiting, .nowhere)])
        let store = NativeWhatsAppAgents()
        store.connect(fixture)
        let attached = await WhatsAppMenu.perform(.agent("wa-1"), here: here, store: store)
        XCTAssertTrue(attached)
        var list = await fixture.agents()
        XCTAssertTrue(list[0].receiver.sameTarget(here), "choosing a WhatsApp agent attaches it HERE (taken from Hoot)")
        XCTAssertEqual(store.chip(for: here)?.name, "Phone")
        let offed = await WhatsAppMenu.perform(.off, here: here, store: store)
        XCTAssertTrue(offed)
        list = await fixture.agents()
        XCTAssertEqual(list[0].receiver, .nowhere, "Off sets it to Nowhere")
        XCTAssertNil(store.chip(for: here), "no chip once none is attached")
        XCTAssertNil(store.problem)
    }

    /// THE SWITCH (his word 4): "Send to WhatsApp" is a checked item in the submenu and the switch after the chip; it
    /// changes only the sending of the agent attached here, which stays attached.
    func testSendToWhatsAppTurnsSendingOffAndOnAndKeepsTheAgentAttached() async throws {
        XCTAssertEqual(WhatsAppWords.send, "Send to WhatsApp")
        let here = WhatsAppReceiver.session(id: "s-crm", name: "CRM build")
        let fixture = WhatsAppAgentsFixture([WhatsAppScreensPictures.agent(1, "Phone", .connected, here)])
        let store = NativeWhatsAppAgents()
        store.connect(fixture)
        // The store reads the list in the background after connect; the switch acts on the agent attached HERE, so the
        // list must be in first (on screen the switch only exists once the chip, i.e. the list, is there).
        for _ in 0..<100 where store.agents.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.chip(for: here)?.name, "Phone")
        let paused = await WhatsAppMenu.perform(.sending(false), here: here, store: store)
        XCTAssertTrue(paused)
        var list = await fixture.agents()
        XCTAssertFalse(list[0].sending, "switch off: nothing is sent")
        XCTAssertTrue(list[0].receiver.sameTarget(here), "the agent stays attached")
        XCTAssertEqual(store.chip(for: here)?.sending, false)
        let resumed = await WhatsAppMenu.perform(.sending(true), here: here, store: store)
        XCTAssertTrue(resumed)
        list = await fixture.agents()
        XCTAssertTrue(list[0].sending)
        let nothingHere = await WhatsAppMenu.perform(.sending(false), here: .hoot, store: store)
        XCTAssertFalse(nothingHere, "no switch where nothing is attached")
        let screens = try source("NativeWhatsAppScreens.swift")
        XCTAssertTrue(screens.contains("Toggle(WhatsAppWords.send"), "the submenu's checked item and the heading switch")
        // 18 Nov (Asad, review item 16: "this WhatsApp button is too bigger"): the heading keeps ONE small button; its
        // switch is the first row of the button's own menu, no longer a second control in the bar.
        XCTAssertTrue(screens.contains("DeckMenuToggleRow(title: WhatsAppWords.send"), "the switch is in the button's menu")
        XCTAssertFalse(screens.contains(".controlSize(.mini).labelsHidden()"), "no separate switch in the bar")
        XCTAssertTrue(screens.contains("agent.sending ? WhatsAppWords.pause : WhatsAppWords.resume"), "Pause / Resume first in the row's menu")
        XCTAssertFalse(screens.contains("canAdd"), "no limit on our side: the add row always stays")
    }

    func testReceiverPopUpTagsKeepTheChoiceByID() {
        let choices = WhatsAppScreensPictures.choices
        XCTAssertEqual(WhatsAppReceiverChoices.tag(.session(id: "s-crm", name: "x")), "session:s-crm")
        XCTAssertEqual(choices.receiver(for: "hoot", current: .nowhere), .hoot)
        XCTAssertEqual(choices.receiver(for: "agent:critic", current: .nowhere), .agent(id: "critic", name: "Critic"))
        XCTAssertEqual(choices.receiver(for: "session:s-site", current: .hoot), .session(id: "s-site", name: "Website copy"))
        XCTAssertEqual(choices.receiver(for: "nowhere", current: .hoot), .nowhere)
        XCTAssertTrue(choices.lacks(.session(id: "gone", name: "Ended one")), "a receiver no longer listed is still shown by its name")
        XCTAssertFalse(choices.lacks(.hoot))
    }

    func testTheGlyphIsThePlainOutlineNeverTheBrand() throws {
        XCTAssertEqual(WhatsAppGlyph.symbol, "phone.bubble")
        XCTAssertEqual(WhatsAppGlyph.size, 13)
        XCTAssertNotNil(NSImage(systemSymbolName: WhatsAppGlyph.symbol, accessibilityDescription: nil))
        let screens = try source("NativeWhatsAppScreens.swift")
        XCTAssertEqual(screens.components(separatedBy: "Color.green").count - 1, 1, "green only for the connected dot")
    }

    /// Session rows get nothing; only their right-click (and ⋯) menu gains the submenu. The New session page gets nothing.
    func testSessionRowsAndTheNewSessionPageShowNothingNew() throws {
        let sidebar = try source("SidebarView.swift")
        let row = try XCTUnwrap(sidebar.components(separatedBy: "private struct SIDEBARSessionRow").dropFirst().first)
        let rowBody = try XCTUnwrap(row.components(separatedBy: "\n}\n").first)
        XCTAssertFalse(rowBody.contains("WhatsApp"), "a session row is an icon and a name; nothing is added to it")
        XCTAssertFalse(try source("SIDEBARSessionLine.swift").contains("WhatsApp"))
        let menu = try XCTUnwrap(sidebar.components(separatedBy: "@ViewBuilder private func sessionMenu").dropFirst().first)
        let menuBody = try XCTUnwrap(menu.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(menuBody.contains("NativeWhatsAppSubmenu("), "the row's right-click menu has the WhatsApp submenu")
        XCTAssertFalse(try source("NativeNewSessionDialog.swift").contains("WhatsApp"), "the New session page gets no new control")
        // The page's menus and headings.
        XCTAssertTrue(try source("AgentMenu.swift").contains("NativeWhatsAppSubmenu(here: here)"), "an agent's and Hoot's ⋯ menu")
        XCTAssertTrue(try source("NativeSessionHeader.swift").contains("NativeWhatsAppChip("), "the session heading's chip")
        XCTAssertTrue(try source("NativeHootScreen.swift").contains("NativeWhatsAppChip(here: .hoot)"), "Hoot's heading chip")
        XCTAssertTrue(try source("AGTProfileView.swift").contains("NativeWhatsAppChip("), "an agent's heading chip")
        // Settings > AI apps: the group is the LAST one.
        let aiApps = try source("NativeAiAppsSettings.swift")
        let page = try XCTUnwrap(aiApps.components(separatedBy: "struct AiAppsPageGroups").first)
        XCTAssertTrue(page.contains("NativeWhatsAppSettingsGroup()"))
    }
}
