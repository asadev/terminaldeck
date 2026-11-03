import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// The chat's icon strip (Asad, 20 Oct 2026): the 29-entry ⋯ menu became ⓘ Session, ⌨ Command output, ± Changes and a
/// short ⋯ More, the same on Hoot's page, in the island and in every chat session.
@MainActor final class ChatMenuTests: XCTestCase {
    func testFourIconsAndAShortMoreMenu() {
        XCTAssertEqual(NativeChatStripIcon.allCases, [.session, .commandOutput, .changes, .more])
        XCTAssertEqual(NativeChatStripIcon.allCases.map(\.title), ["Session", "Command output", "Changes", "More"])
        XCTAssertTrue(NativeChatStripIcon.allCases.allSatisfy { !$0.symbol.isEmpty && !$0.help.isEmpty })
        XCTAssertEqual(NativeChatMenuEntry.allCases.map(\.title), ["Past chats", "Export chat", "Pin or archive", "Problems"])
        XCTAssertEqual(NativeChatMenuEntry.allCases.filter(\.menuOwned), [.pastChats, .export])
        let shown = Set(NativeChatStripIcon.allCases.map(\.title) + NativeChatMenuEntry.allCases.map(\.title) + NativeChatSessionList.allCases.map(\.title))
        for removed in ["Find a past prompt", "Side question", "Long prompt editor", "Schedule as routine", "Voice", "Keyboard shortcuts",
                        "Goals", "Chat settings", "Usage & account", "Provider features", "Slash commands", "Child agents", "Model switch",
                        "Notifications", "Permission policy", "Context used", "Warnings & errors", "Event log", "Hook notices"] {
            XCTAssertFalse(shown.contains(removed), removed)
        }
    }

    func testSessionPanelHasThreeCollapsibleSections() {
        XCTAssertEqual(NativeChatSessionSection.allCases.map(\.title), ["Environment", "Context", "Connections"])
        XCTAssertEqual(NativeChatSession.defaultOpen, "environment,context,connections")
        XCTAssertEqual(NativeChatSessionList.allCases.filter { $0.section == .context }, [.sources, .excerpt, .mentions])
        XCTAssertEqual(NativeChatSessionList.allCases.filter { $0.section == .connections }, [.servers, .skills])
        let servers = NativeRPCValue.array(["connected", "failed", "needs-auth", "pending"].map { .object([.init("name", .string($0)), .init("status", .string($0))]) })
        XCTAssertEqual(NativeChatSession.reconnect(servers), 2, "failed and needs-auth are to reconnect")
        XCTAssertEqual(NativeChatSession.reconnect(.null), 0)
        let model = NativeHootChatModel(fixture: .object([]), source: .session("menu-session", provider: "claude"))
        XCTAssertEqual(NativeChatSession.mode(model), "Chat")
        XCTAssertEqual(NativeChatSession.mode(NativeHootChatModel(fixture: .object([]))), "Hoot, your assistant")
        XCTAssertEqual(NativeChatSession.providerName("codex"), "Codex")
    }

    /// Each icon opens through its tool's flag, and every tool whose panel lost its entry still opens it from the strip.
    func testEveryEntryOpensThroughTheFlagItsToolUses() async throws {
        func fresh() -> NativeHootChatModel { NativeHootChatModel(fixture: .object([]), source: .session("menu-session", provider: "claude")) }
        var model = fresh()
        NativeChatStripIcon.session.open(in: model); XCTAssertTrue(model.chatContextVisible); XCTAssertTrue(NativeChatStripIcon.session.shown(in: model))
        model.closeChatSession(); XCTAssertFalse(model.chatSessionShown)
        NativeChatStripIcon.commandOutput.open(in: model); XCTAssertTrue(model.chatFeaturePanels.contains("terminal-context"))
        NativeChatStripIcon.changes.open(in: model); XCTAssertTrue(model.chatFeaturePanels.contains("diffs")); XCTAssertTrue(model.chatChangesShown)
        NativeChatMenuEntry.problems.open(in: model); XCTAssertTrue(model.chatDiagnosticsVisible); XCTAssertTrue(model.chatProblemsShown)

        // The chat feature tools themselves.
        model = fresh(); _ = try await model.featureTool("terminal-context", action: "open", args: .object([])); XCTAssertTrue(NativeChatStripIcon.commandOutput.shown(in: model))
        model = fresh(); _ = try await model.featureTool("diffs", action: "open", args: .object([])); XCTAssertTrue(model.chatChangesShown)
        model = fresh(); _ = try model.reviewTool("open", request: nil, text: nil); XCTAssertTrue(model.chatChangesShown)
        model = fresh(); _ = try await model.featureTool("mentions", action: "open", args: .object([])); XCTAssertTrue(model.chatSessionShown); XCTAssertTrue(NativeChatSessionList.mentions.asked(in: model))
        model = fresh(); _ = try await model.featureTool("mcp", action: "open", args: .object([])); XCTAssertTrue(model.chatSessionShown); XCTAssertTrue(NativeChatSessionList.servers.asked(in: model))
        model = fresh(); _ = try await model.featureTool("hooks", action: "open", args: .object([])); XCTAssertTrue(model.chatProblemsShown)
        model = fresh(); _ = try model.detailTool("open"); XCTAssertTrue(model.chatProblemsShown)
        // The panels that are now lists of ⓘ Session.
        let lists: [(NativeChatSessionList, (NativeHootChatModel) -> Void)] = [
            (.sources, { $0.chatSourcesVisible = true }), (.sources, { $0.chatArtifactsVisible = true }), (.excerpt, { $0.chatEditorContextVisible = true }),
            (.servers, { $0.chatConnectionsVisible = true }), (.skills, { $0.chatSkillsVisible = true })]
        for (list, open) in lists {
            model = fresh(); open(model)
            XCTAssertTrue(model.chatSessionShown, list.rawValue); XCTAssertTrue(list.asked(in: model), list.rawValue)
            model.closeChatSession(); XCTAssertFalse(model.chatSessionShown, list.rawValue)
        }
        model = fresh(); model.chatContextVisible = true; model.chatFeaturePanels.formUnion(["mentions", "mcp"]); model.closeChatSession()
        XCTAssertTrue(model.chatFeaturePanels.isEmpty)
        // Feature panels without an entry still hang off the strip.
        XCTAssertEqual(NativeChatMenu.toolOnlyFeatures.map(\.0), ["agents", "model-timing", "notifications", "policy"])
        model = fresh(); _ = try await model.featureTool("policy", action: "open", args: .object([])); XCTAssertTrue(model.chatFeaturePanels.contains("policy"))
        let menu = try Self.source("NativeChatMenu.swift")
        for popover in ["NativeChatSideQuestionPopover", "NativeChatLongDraftPopover", "NativeChatRoutinesPopover", "NativeChatVoicePopover",
                        "NativeChatShortcutsPopover", "NativeChatGoalsPopover", "NativeChatControlsPopover", "NativeChatAccountPopover",
                        "NativeChatCommandsPopover", "NativeChatMemorySheet"] {
            XCTAssertTrue(menu.contains(popover + "(model: model)"), popover)
        }
    }

    /// Every chat surface draws NativeHootChat, so the one strip is in all of them.
    func testEveryChatSurfaceSharesTheOneStrip() throws {
        let chat = try Self.source("NativeHootChat.swift")
        XCTAssertEqual(chat.components(separatedBy: "NativeChatMenu(model: model)").count, 2)
        XCTAssertFalse(chat.contains("ScrollView(.horizontal)"))
        for surface in ["NativeHootScreen.swift", "NativeIslandContent.swift", "NativeTerminalScreen.swift"] {
            XCTAssertTrue(try Self.source(surface).contains("NativeHootChat("), surface)
        }
    }

    /// Hoot's page, the island and a chat session, light and dark, hosted in a never-shown window; the Session
    /// panel too, every section open.
    func testStripRendersInEveryChatLightAndDark() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = ProcessInfo.processInfo.environment["HOOTSIM_RENDER_OUTPUT"].flatMap { $0.hasSuffix(".noindex") ? $0 : nil }
        for dark in [false, true] {
            for surface in ["hoot", "island", "session", "session-panel"] {
                let model = surface.hasPrefix("session")
                    ? NativeHootChatModel(fixture: .object([.init("ready", .bool(true))]), source: .session("menu-session", provider: "claude"))
                    : NativeHootChatModel(fixture: .object([.init("ready", .bool(true))]))
                let size = surface == "island" ? CGSize(width: 480, height: 420) : surface == "session-panel" ? CGSize(width: 660, height: 680) : CGSize(width: 1000, height: 640)
                let content: AnyView = surface == "session-panel" ? AnyView(NativeChatSessionPanel(model: model)) : AnyView(NativeHootChat(model: model, compact: surface == "island"))
                let host = NSHostingView(rootView: content
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.agkitOffscreenSolid, true)
                    .frame(width: size.width, height: size.height)
                    // The ground each surface really has: the session's paper, Hoot's page, the island's panel.
                    .background(surface == "session" ? DeckTokens.chatPage : surface == "hoot" ? DeckTokens.page : dark ? Color.black : Color.white))
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                for _ in 0..<6 { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                XCTAssertFalse(window.isVisible)
                XCTAssertGreaterThan(host.fittingSize.width, 0, surface)
                guard let output else { continue }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("chat-strip-\(surface)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private static func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative")
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }
}
