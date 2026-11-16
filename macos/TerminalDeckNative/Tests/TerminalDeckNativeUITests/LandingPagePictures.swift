import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckNative
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Owner, 14 Nov: the New session page must look exactly like the chat window. So every scene is drawn twice by the
/// same capture, side by side: an open chat with nothing said yet (its bar, `NativeHootChat` on a fixture) and the New
/// session page, light and dark, at the normal width and narrow; plus the bar's lists open.
/// Written to macos/design-2026-10-10/built.noindex/LANDING-<scene>-<chat|page>-<width>-<light|dark>.png.
/// Scratch defaults only; no AppModel.shared, no engine, no microphone lookup.
@MainActor
final class LandingPagePictures: XCTestCase {
    private var savedOutbox: UserDefaults!
    private var outboxSuite = ""
    override func setUp() async throws {
        outboxSuite = "td-landing-pictures-outbox-" + UUID().uuidString
        savedOutbox = NativeChatOutbox.defaults
        NativeChatOutbox.defaults = try XCTUnwrap(UserDefaults(suiteName: outboxSuite))
    }
    override func tearDown() async throws {
        NativeChatOutbox.defaults.removePersistentDomain(forName: outboxSuite)
        NativeChatOutbox.defaults = savedOutbox
    }

    private func page(prefilled: Bool) -> NativeLandingModel {
        let suite = "td-landing-pictures-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if prefilled {
            NativeLandingMemory.remember(NativeLastStart(folder: "/work/imatch", projectID: "imatch", projectName: "iMatch", provider: "claude",
                providerName: "Claude", account: "c-home", accountName: "Home", model: "opus", modelName: "Opus", effort: "high",
                chat: true, agentID: nil, agentName: nil), defaults)
        }
        var effects = NativeLandingModel.Effects()
        effects.defaults = defaults
        effects.projects = { [LandingNewSessionTests.work, LandingNewSessionTests.site, PROJProjects.independent] }
        effects.exists = { $0.hasPrefix("/work/") }
        let model = NativeLandingModel(effects: effects)
        if prefilled { model.apply(LandingNewSessionTests.lists(), detected: LandingNewSessionTests.detected, added: .null, pickLead: false) }
        return model
    }

    /// An agent chosen. `own`: its settings bring Opus and High (the line under the box says so, not a choice);
    /// otherwise it leaves them open: the normal choices in Chat, the "Fable 5.2 · Extra" line in Terminal.
    private func agentPage(own: Bool, chat: Bool, name: String = "Decker") -> NativeLandingModel {
        let suite = "td-landing-pictures-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var agent = NativeRPCValue.object([.init("id", .string("decker")), .init("name", .string(name)),
                                           .init("provider", .string("claude")), .init("lead", .bool(true))])
        if own { agent = agent.setting("model", .string("opus")).setting("effort", .string("high")) }
        var lists = LandingNewSessionTests.lists().setting("agents", .array([agent]))
        lists = lists.setting("providers", .array((lists["providers"].elements ?? []).map { row in
            row["id"].string == "claude" ? row.setting("defaultModel", .string("claude-fable-5-2")).setting("defaultEffort", .string("xhigh")) : row }))
        var effects = NativeLandingModel.Effects()
        effects.defaults = defaults
        effects.projects = { [LandingNewSessionTests.work, LandingNewSessionTests.site, PROJProjects.independent] }
        effects.exists = { $0.hasPrefix("/work/") }
        let model = NativeLandingModel(effects: effects)
        model.apply(lists, detected: LandingNewSessionTests.detected, added: .null, pickLead: false)
        model.chooseProject(LandingNewSessionTests.work) // picks the project's lead
        model.chooseAgent("decker")
        model.chooseChat(chat)
        return model
    }

    /// The open chat the scene compares with: an empty conversation of that AI, its bar as an open session draws it
    /// (the same bar frame and title, the folder, the account chip's label).
    private func openChat(provider: String, account: String) -> some View {
        let snapshot = NativeRPCValue.object([.init("conversationId", .string("landing-pictures")), .init("alive", .bool(true)), .init("busy", .bool(false))])
        let chat = NativeHootChatModel(fixture: snapshot, source: .session("landing-pictures", provider: provider))
        chat.composerDraft.permissionMode = .bypass
        return VStack(spacing: 0) {
            NativeSessionBarFrame {
                EmptyView()
            } title: {
                NativeSessionTitle(title: "Session 1", rename: { _ in })
            } place: {
                NativeFolderChip(path: "/work/imatch")
                ChipSeparator()
                AccountChipLabel {
                    NativeCodingAIProviderMark(provider: provider, size: 13)
                    Text(account).foregroundStyle(.primary)
                }
            } trailing: {
                EmptyView()
            }
            NativeHootChat(model: chat).frame(maxWidth: .infinity, maxHeight: .infinity).background(DeckTokens.chatBody)
        }
        .background(DeckTokens.chatPage)
    }

    private var out: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("design-2026-10-10/built.noindex")
    }

    /// The chat pictures' own capture (ChatControlsScratchTests): a hidden passive panel, the solid box fallback.
    private func capture<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) throws {
        for dark in [false, true] {
            let root = view.environment(\.agkitOffscreenSolid, true).environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: width, height: height).background(DeckTokens.chatPage)
            let host = NSHostingView(rootView: root)
            let panel = NativePassiveChatPanel(contentRect: .init(x: -30000, y: -30000, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.prepareForPassiveCapture()
            panel.identifier = .init("dev.terminaldeck.landing-pictures.scratch")
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.contentView = host
            defer { panel.contentView = nil; panel.close() }
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("LANDING-\(name)-\(dark ? "dark" : "light").png"), options: .atomic)
            XCTAssertEqual(bitmap.pixelsWide, Int(width))
            XCTAssertFalse(panel.isVisible)
        }
    }

    /// One scene: the open chat and the New session page, normal (1000 x 780: the window less its side panel) and narrow.
    private func scene(_ name: String, _ model: NativeLandingModel, provider: String = "claude", account: String = "Home") throws {
        for (width, height) in [(CGFloat(1000), CGFloat(780)), (520, 700)] {
            try capture(openChat(provider: provider, account: account), "\(name)-chat-\(Int(width))", width: width, height: height)
            try capture(NativeLandingPage(model: model, focus: NativeLandingFocus(), fixture: true), "\(name)-page-\(Int(width))", width: width, height: height)
        }
    }

    func testPictures() throws {
        let filled = page(prefilled: true)
        filled.text = ""
        // The line under the box is the open chat's: Bypass, then the model and the effort as he last started.
        XCTAssertEqual(filled.composerDraft.permissionMode, .bypass)
        XCTAssertEqual(filled.composerDraft.modelID, "claude:opus")
        XCTAssertEqual(filled.composerDraft.effort, "high")
        XCTAssertEqual(filled.composerCatalogue.featured.map(\.id).first, "claude:", "the AI's own default first when the list does not name it")
        XCTAssertTrue(filled.composerCatalogue.featured.contains { $0.id == "claude:opus" })
        XCTAssertEqual(filled.composerCatalogue.efforts, ["low", "high", "xhigh"])
        filled.chooseComposerModel("claude:sonnet"); XCTAssertEqual(filled.model, "sonnet")
        filled.chooseComposerModel("claude:"); XCTAssertNil(filled.model)
        filled.chooseComposerModel("claude:opus")
        try scene("prefilled", filled)

        try scene("first-run", page(prefilled: false))
        let typed = page(prefilled: true)
        typed.text = "Fix the sign-in page so the error shows under the field"
        try scene("typed", typed)

        // The bar's lists, open: the AI and account list (the chip's own popover content) and the project menu's rows
        // (a system menu: drawn here as its rows).
        try capture(NativeLandingAccountList(model: filled).background(DeckTokens.card, in: .rect(cornerRadius: 10)).padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), "menu-account", width: 520, height: 420)
        try capture(LandingPlaceMenuRows(model: agentPage(own: true, chat: true)), "menu-place", width: 520, height: 420)
    }

    // 15 Nov review item 8: the mark and its line are gone (the page is calm and empty above the box), so the check that
    // they sat where an open chat's do (testTheMarkSitsWhereTheChatsDoes) went with them.

    func testAgentPictures() throws {
        let scenes: [(String, NativeLandingModel, String)] = [
            ("agent-own", agentPage(own: true, chat: false), "Opus \u{00B7} High"),
            ("agent-open-chat", agentPage(own: false, chat: true), ""),
            ("agent-open-terminal", agentPage(own: false, chat: false), "Fable 5.2 \u{00B7} Extra")]
        for (name, model, line) in scenes {
            XCTAssertEqual(model.agentRuns ?? "", line, name)
            XCTAssertEqual(model.agentRunsHelp, line.isEmpty ? nil : name == "agent-own" ? "Set by Decker" : "Claude's default for this session", name)
            XCTAssertEqual(model.showsModel, line.isEmpty, name)
            // The model and effort menus give way to that line; the permission menu stays.
            XCTAssertEqual(model.composerCatalogue.sections.isEmpty, !line.isEmpty, name)
            try scene(name, model)
        }
        try scene("agent-long-name", agentPage(own: true, chat: false, name: "Release and TestFlight Coordinator for the Phones"))
    }
}

/// The project menu's rows as the menu lists them, for review (15 Nov review: projects, Choose folder…, Choose agent).
struct LandingPlaceMenuRows: View {
    let model: NativeLandingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.registeredProjects) { project in
                NewSessionMenuRow(title: project.name, chosen: model.folder != nil && model.projectID == project.id) {}
            }
            Divider().padding(.vertical, 4)
            NewSessionMenuRow(title: "Choose folder\u{2026}", chosen: false) {}
            if !model.agents.isEmpty {
                NewSessionMenuRow(title: "Choose agent", chosen: false, symbol: "chevron.right") {}
                NewSessionMenuTitle(text: "Choose agent")
                ForEach(model.agents) { agent in
                    NewSessionMenuRow(title: agent.lead ? agent.name + " (lead)" : agent.name, chosen: model.agentID == agent.id) {}
                }
            }
        }
        .padding(6)
        .frame(width: 260, alignment: .leading)
        .background(DeckTokens.card, in: .rect(cornerRadius: 10))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
