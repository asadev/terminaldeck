import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 15 Nov (Asad: "api accounts are not coming dropdown for coding ai"): the account menu in an open session's heading
/// is the New session page's menu fed by the New session page's lists: every account (API-key accounts included), by
/// name only, the session's AI first, a pick switches the session. Pictures (light and dark) go to
/// macos/night/codex/session-account-menu-evidence/.
@MainActor final class SessionAccountMenuTests: XCTestCase {
    static var evidence: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("night/codex/session-account-menu-evidence", isDirectory: true)
    }
    static var source: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative/NativeSessionAccountChip.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Made-up accounts: two subscription logins, one API-key account, one Codex login that needs sign-in.
    static var lists: NativeRPCValue {
        .object([
            .init("providers", .array([
                .object([.init("id", .string("claude")), .init("name", .string("Claude Code"))]),
                .object([.init("id", .string("codex")), .init("name", .string("Codex"))]),
                .object([.init("id", .string("gemini")), .init("name", .string("Gemini"))]),
                .object([.init("id", .string("shell")), .init("name", .string("Shell"))])])),
            .init("accounts", .array([
                .object([.init("id", .string("p-work")), .init("name", .string("Work")), .init("provider", .string("claude")),
                         .init("email", .string("work@example.com")), .init("state", .string("ready"))]),
                .object([.init("id", .string("p-home")), .init("name", .string("Home")), .init("provider", .string("claude")),
                         .init("email", .string("home@example.com")), .init("state", .string("ready"))]),
                .object([.init("id", .string("p-api")), .init("name", .string("Studio API")), .init("provider", .string("claude"))]),
                .object([.init("id", .string("p-codex")), .init("name", .string("ChatGPT")), .init("provider", .string("codex")),
                         .init("state", .string("signIn"))])]))])
    }

    func testTheHeadingMenuListsAPIKeyAccountsBesideSubscriptionsSessionAIFirst() {
        let all = HootSharedLists(fixture: Self.lists).menuGroups
        let groups = SessionAccountMenu.groups(all, sessionAgent: "codex")
        XCTAssertEqual(groups.map(\.provider), ["codex", "claude"], "the session's AI first; an AI with no account is left out")
        let claude = SessionAccountMenu.groups(all, sessionAgent: "claude")
        XCTAssertEqual(claude.first?.accounts.map(\.id), ["p-work", "p-home", "p-api"], "the API-key account sits beside the subscriptions")
        XCTAssertEqual(claude.flatMap(\.accounts).map(\.name), ["Work", "Home", "Studio API", "ChatGPT"], "names only")
        XCTAssertEqual(claude.flatMap(\.accounts).filter(\.needsHim).map(\.id), ["p-codex"], "one dot only where it needs him")
    }

    func testChoosingAnyAccountSwitchesTheSession() {
        XCTAssertEqual(SessionAccountMenu.action("p-api", currentId: "p-work", switching: true, blocked: nil), .switchHere)
        XCTAssertEqual(SessionAccountMenu.action("p-home", currentId: "p-work", switching: true, blocked: nil), .switchHere)
        XCTAssertEqual(SessionAccountMenu.action("p-work", currentId: "p-work", switching: true, blocked: nil), .none)
        XCTAssertEqual(SessionAccountMenu.action("p-api", currentId: nil, switching: false, blocked: nil), .newSession)
        XCTAssertEqual(SessionAccountMenu.action("p-api", currentId: nil, switching: false, blocked: "one login"), .none)
        // The switch is the app's own, as before.
        let source = Self.source
        XCTAssertTrue(source.contains("NativeAccountSwitcher.shared.ask(sessionId: id, accountId: account.id"))
        XCTAssertTrue(source.contains("SessionAccountMenu.groups(lists.menuGroups, sessionAgent: sessionAgent)"))
    }

    func testNoOldRowsAreLeft() {
        let source = Self.source
        XCTAssertFalse(source.contains("AccountRowLine"), "the old rows (dot, mark and e-mail on every row) are gone")
        XCTAssertFalse(source.contains("readyRows("), "never only the logins that read as signed in")
        XCTAssertFalse(source.contains("Text(email)"), "no e-mail line under each row")
        XCTAssertEqual(source.components(separatedBy: "NewSessionAccountMenu(").count - 1, 2, "the session's and a paired machine's menu")
    }

    func testThePairedMachineMenuIsNamesOnlyByAI() {
        let accounts = [MachineAccount.decode(["id": "m1", "name": "Office", "provider": "claude"]),
                        MachineAccount.decode(["id": "m2", "name": "Spare", "provider": "codex"])].compactMap { $0 }
        let groups = SessionAccountMenu.machineGroups(accounts)
        XCTAssertEqual(groups.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(groups.flatMap(\.accounts).map(\.name), ["Office", "Spare"])
    }

    func testTheHeadingMenuPictures() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let groups = SessionAccountMenu.groups(HootSharedLists(fixture: Self.lists).menuGroups, sessionAgent: "claude")
        try FileManager.default.createDirectory(at: Self.evidence, withIntermediateDirectories: true)
        for dark in [false, true] {
            let size = CGSize(width: 300, height: 300)
            let view = NewSessionAccountMenu(groups: groups, chosenProvider: "claude", chosenAccount: "p-work",
                                             pick: { _, _ in }, addAccount: {})
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            XCTAssertFalse(window.isVisible)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 1000)
            try data.write(to: Self.evidence.appendingPathComponent("session-account-menu-\(dark ? "dark" : "light").png"))
        }
    }
}
