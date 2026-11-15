import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Asad's recorded review of 15 Nov, Hoot items 14 to 23, drawn in a real but never-shown window, light and dark:
/// his message with a screenshot (the real picture, the page's name, no marker, no path), a normal answer, a stopped
/// turn ("Stopped"), a failed turn (one sentence and Try again, never the raw "[ede_diagnostic]" line), the box with
/// the New session page's row under it, the account chip in the bar, and hover equal to no hover. No app, engine,
/// device or AI. Pictures go to macos/night/codex/hoot-review-evidence/.
@MainActor final class HootReviewPictures: XCTestCase {
    private static let conversation = "hoot-review"
    private static let diagnostic = "[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"
    private static let browserText = "show me all inquiries and listings on this map [browser screenshot of http://localhost:3010/preview/home: /Users/someone/Library/Application Support/terminaldeck/browser-screenshots/marked-E855A177.png (1640 x 896)]"
    private static let simulatorText = "[iOS Simulator screenshot of \"TD iPhone\": /Users/someone/Pictures/Terminal Deck/TD-iPhone-20261113-063350-annotated.png (1206 x 2622)]"

    static var evidence: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("night/codex/hoot-review-evidence", isDirectory: true)
    }

    static var samplePNG: String {
        let image = NSImage(size: NSSize(width: 328, height: 180), flipped: false) { rect in
            NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.97, alpha: 1).setFill(); rect.fill()
            NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 1).setFill()
            for index in 0..<6 { NSBezierPath(ovalIn: NSRect(x: 30 + index * 46, y: 40 + (index % 3) * 34, width: 18, height: 18)).fill() }
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return "" }
        return data.base64EncodedString()
    }

    private static func event(_ turn: String, _ sequence: Int, _ record: HootChatRecord) -> HootChatEvent {
        HootChatEvent(conversationID: conversation, turnID: turn, sequence: sequence, provider: .claude, record: record,
                      at: 1_794_681_030_000 + Double(sequence) * 60_000)
    }

    static var chat: NativeRPCValue {
        let browserSource = NativeRPCValue.object([.init("kind", .string("browser")), .init("title", .string("iMatch home (local preview)")),
                                                    .init("url", .string("http://localhost:3010/preview/home"))])
        let deviceSource = NativeRPCValue.object([.init("kind", .string("device")), .init("title", .string("TD iPhone")),
                                                   .init("deviceId", .string("ios:6CFFF3FD-E66E-49B0-AA11-42A134B993FF"))])
        let events = [
            event("t1", 1, .init(.user, id: "u1", value: .object([.init("text", .string(browserText)), .init("attachmentCount", .number(1)),
                .init("context", .object([.init("source", browserSource)]))]))),
            event("t1", 2, .text(.message, id: "m1", "The pins now **spread out** before you zoom in:\n\n1. Nearby listings form a small group.\n2. A group opens as you zoom.\n\n`MapPins.swift` has the change.")),
            event("t1", 3, .init(.completed)),
            event("t2", 4, .init(.user, id: "u2", value: .object([.init("text", .string(simulatorText)), .init("attachmentCount", .number(1)),
                .init("context", .object([.init("source", deviceSource)]))]))),
            event("t2", 5, .init(.interrupted, value: .object([.init("by", .string("person"))]))),
            event("t3", 6, .text(.user, id: "u3", "why does the poster open twice?")),
            event("t3", 7, .init(.error, value: .object([.init("text", .string(diagnostic))]))),
        ]
        return .object([.init("conversationId", .string(conversation)), .init("sequence", .number(7)),
            .init("events", .array(events.map(\.wireValue))), .init("ready", .bool(true)), .init("alive", .bool(true)),
            .init("busy", .bool(false)), .init("pending", .array([])),
            .init("options", .object([.init("permissionMode", .string("bypass")), .init("model", .string("claude:claude-fable-5-2")),
                .init("effort", .string("xhigh")), .init("efforts", .array(["low", "medium", "high", "xhigh", "max"].map(NativeRPCValue.string))),
                .init("ready", .bool(true))])),
            .init("images", .object([.init("t1:u1", .string(samplePNG)), .init("t2:u2", .string(samplePNG))]))])
    }

    static var lists: NativeRPCValue {
        .object([
            .init("providers", .array([
                .object([.init("id", .string("claude")), .init("name", .string("Claude Code")), .init("models", .array([
                    .object([.init("id", .string("claude-fable-5-2")), .init("name", .string("Fable 5.2"))]),
                    .object([.init("id", .string("claude-opus-5-5")), .init("name", .string("Opus 5.5"))]),
                    .object([.init("id", .string("claude-sonnet-5")), .init("name", .string("Sonnet 5"))])]))]),
                .object([.init("id", .string("codex")), .init("name", .string("Codex"))]),
                .object([.init("id", .string("shell")), .init("name", .string("Shell"))])])),
            .init("accounts", .array([
                .object([.init("id", .string("p-own")), .init("name", .string("Your own Claude Code install")), .init("provider", .string("claude"))]),
                .object([.init("id", .string("p-imza")), .init("name", .string("Imza Premium API")), .init("provider", .string("claude"))]),
                .object([.init("id", .string("p-main")), .init("name", .string("Main account")), .init("provider", .string("claude"))]),
                .object([.init("id", .string("p-codex")), .init("name", .string("ChatGPT")), .init("provider", .string("codex")),
                         .init("state", .string("signIn"))])]))])
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, hover: NSPoint? = nil) throws -> Data {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.agkitOffscreenSolid, true).frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
        if let hover, let moved = NSEvent.mouseEvent(with: .mouseMoved, location: hover, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            window.sendEvent(moved)
            for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
        }
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    private func save(_ data: Data, _ name: String, dark: Bool) throws {
        try FileManager.default.createDirectory(at: Self.evidence, withIntermediateDirectories: true)
        try data.write(to: Self.evidence.appendingPathComponent("hoot-review-\(name)-\(dark ? "dark" : "light").png"))
    }

    /// Items 15, 21, 22: what the chat draws for each message (no rendering).
    func testWhatTheChatShowsInPlaceOfInternalText() {
        XCTAssertEqual(HootMessageDisplay.shown(Self.browserText), "show me all inquiries and listings on this map")
        XCTAssertEqual(HootMessageDisplay.shown(Self.simulatorText), "")
        XCTAssertEqual(HootMessageDisplay.shown("Screen from TD iPhone\nAccessibility tree:\n{\"a\":1}"), "")
        XCTAssertEqual(HootMessageDisplay.shown("plain words stay"), "plain words stay")
        XCTAssertEqual(HootMessageDisplay.picturePath(text: Self.browserText, source: .object([])),
                       "/Users/someone/Library/Application Support/terminaldeck/browser-screenshots/marked-E855A177.png")
        XCTAssertEqual(HootMessageDisplay.cardDetail(text: Self.simulatorText, source: .object([.init("deviceId", .string("ios:6CFFF3FD-E66E"))])), "iOS Simulator")
        XCTAssertNil(HootMessageDisplay.cardTitle(.object([.init("title", .string("ios:6CFFF3FD-E66E-49B0-AA11-42A134B993FF"))])))
        XCTAssertEqual(HootMessageDisplay.cardTitle(.object([.init("title", .string("TD iPhone"))])), "TD iPhone")

        XCTAssertTrue(HootTurnEnd.isDiagnostic(Self.diagnostic))
        XCTAssertTrue(HootTurnEnd.isDiagnostic("[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"))
        XCTAssertEqual(HootTurnEnd.of(kind: .error, text: Self.diagnostic, stoppedByPerson: false), .failed(HootTurnEnd.failedSentence))
        XCTAssertEqual(HootTurnEnd.of(kind: .error, text: Self.diagnostic, stoppedByPerson: true), .stopped)
        XCTAssertEqual(HootTurnEnd.of(kind: .interrupted, text: "", stoppedByPerson: false), .stopped)
        XCTAssertTrue(BackendHootChatStore.isProviderDiagnostic(Self.diagnostic))
        XCTAssertFalse(BackendHootChatStore.isProviderDiagnostic("The pins now spread out."))

        // Pictures load only from the app's own picture folders.
        let root = URL(fileURLWithPath: "/tmp/hoot-review-root")
        let folders = HootSavedPicture.allowedFolders(dataRoot: root)
        XCTAssertFalse(HootSavedPicture.isAllowed("/etc/passwd.png", folders: folders))
        XCTAssertFalse(HootSavedPicture.isAllowed(root.path + "/browser-screenshots/../secret.png", folders: folders))
        XCTAssertFalse(HootSavedPicture.isAllowed(root.path + "/browser-screenshots/a.txt", folders: folders))

        // Item 23: a model is named, never its raw id.
        XCTAssertEqual(ROUTINESHootBrainModel.readableModel("claude-fable-5-2"), "Fable 5.2")
        XCTAssertEqual(ROUTINESHootBrainModel.readableModel("opus[1m]"), "Opus")
    }

    /// Items 18, 19: Hoot's lists are the New session page's lists (every account, API keys included; every model by name).
    func testHootUsesTheNewSessionPagesLists() {
        let lists = HootSharedLists(fixture: Self.lists)
        XCTAssertEqual(lists.ais.map(\.id), ["claude", "codex"])
        XCTAssertEqual(lists.accounts("claude").map(\.id), ["p-own", "p-imza", "p-main"])
        let catalogue = lists.catalogue(base: HootComposerCatalogue(), modelID: "claude:claude-fable-5-2")
        XCTAssertEqual(catalogue.featured.map(\.name), ["Fable 5.2", "Opus 5.5", "Sonnet 5"])
        XCTAssertEqual(catalogue.featured.first?.id, "claude:claude-fable-5-2")
    }

    /// DESIGN-FIXES H-1, H-2, H-5 (15 Nov): his bubble hugs its text (at most 70 % of the 720 pt column); the account
    /// list is the New session page's menu with names only.
    func testTheBubbleFollowsItsTextAndTheAccountRowsAreNamesOnly() {
        func width(_ text: String, available: CGFloat = 648) -> CGFloat {
            let bubble = Text(text).font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 10)
                .modifier(HootBubbleWidth.Fit())
            return NSHostingController(rootView: bubble).sizeThatFits(in: CGSize(width: available, height: 2_000)).width
        }
        let short = width("why does the poster open twice?")
        let long = width(String(repeating: "a long line that has to wrap inside the bubble ", count: 12))
        XCTAssertLessThan(short, 300, "a short line makes a short bubble")
        XCTAssertGreaterThan(long, short)
        XCTAssertLessThanOrEqual(long, NativeHootChat.columnWidth * 0.7 + 0.5, "never wider than 70 % of the column")
        XCTAssertEqual(HootBubbleWidth.limit(available: 1_000, compact: false), 504, accuracy: 0.001)
        XCTAssertEqual(HootBubbleWidth.limit(available: 400, compact: true), 280, accuracy: 0.001)

        let groups = HootSharedLists(fixture: Self.lists).menuGroups
        XCTAssertEqual(groups.map(\.provider), ["claude", "codex"])
        let names = groups.flatMap(\.accounts).map(\.name)
        XCTAssertEqual(names, ["Your own Claude Code install", "Imza Premium API", "Main account", "ChatGPT"])
        XCTAssertFalse(names.contains { $0.contains(" · ") || $0.contains("signed in with") }, "names only")
        XCTAssertEqual(groups.flatMap(\.accounts).filter(\.needsHim).map(\.id), ["p-codex"], "a dot only where it needs him")
    }

    /// Item 62: the dropped-down Hoot closes when another of the app's titled windows comes forward, not for its own popovers.
    func testIslandClosesForSettingsNotForItsOwnSheets() {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let popover = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        XCTAssertTrue(IslandController.closesIsland(window: settings, panel: panel))
        XCTAssertFalse(IslandController.closesIsland(window: panel, panel: panel))
        XCTAssertFalse(IslandController.closesIsland(window: popover, panel: panel))
    }

    /// Items 14, 15, 16, 20, 21, 22 drawn: the chat, the box with its row, the account chip; hover equals no hover.
    func testTheReviewedHootChatPictures() throws {
        XCTAssertFalse(EngineBridge.shared.isReady)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let brain = ROUTINESHootBrainModel(snapshot: CodingAIJSON(["provider": "claude", "profileId": "p-main",
            "choices": ["provider": "claude", "profileId": "p-main"],
            "accounts": [["id": "p-main", "name": "Main account", "provider": "claude", "signedIn": true]]] as [String: Any]))
        let lists = HootSharedLists(fixture: Self.lists)
        for dark in [false, true] {
            let model = NativeHootChatModel(fixture: Self.chat)
            XCTAssertTrue(model.optionsKnown)
            XCTAssertEqual(model.turnEnd(model.rows.first { $0.kind == .interrupted }!), .stopped)
            XCTAssertEqual(model.turnEnd(model.rows.first { $0.kind == .error }!), .failed(HootTurnEnd.failedSentence))
            let size = CGSize(width: 1000, height: 900)
            try save(try render(NativeHootScreen(fixture: Self.chat, brain: brain, lists: lists), size: size, dark: dark), "page", dark: dark)
            let plain = try render(NativeHootChat(model: NativeHootChatModel(fixture: Self.chat), lists: lists), size: size, dark: dark)
            // The pointer on his first message (over its words, not on an icon, whose quick tip is a tooltip).
            let hovered = try render(NativeHootChat(model: NativeHootChatModel(fixture: Self.chat), lists: lists), size: size, dark: dark,
                                     hover: NSPoint(x: 700, y: 760))
            try save(plain, "chat", dark: dark)
            try save(hovered, "chat-hover", dark: dark)
            XCTAssertEqual(plain, hovered, "Nothing may appear, move or hide on hover (item 14)")
            try save(try render(HootAccountList(brain: brain, lists: lists, live: false), size: CGSize(width: 320, height: 260), dark: dark),
                     "account-list", dark: dark)
            try save(try render(NativeHootChat(model: NativeHootChatModel(fixture: Self.chat), compact: true, lists: lists),
                                size: CGSize(width: 480, height: 620), dark: dark), "island", dark: dark)
        }
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
