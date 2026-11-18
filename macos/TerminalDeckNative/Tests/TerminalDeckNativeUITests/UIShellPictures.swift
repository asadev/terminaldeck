import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckNative
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Review of 18 Nov 2026, area "shell" (DESIGN-shell.md): the changed looks drawn offscreen, light and dark, into
/// ~/Deck Dev/notes/review-20261118/after-shell/<scene>-<light|dark>.png, to be LOOKED at beside the recordings'
/// frames. Plain values only: no AppModel.shared, no engine, no session, no account.
/// Run: tools/lane-build.sh <worktree> plain test --filter UIShellPictures
@MainActor
final class UIShellPictures: XCTestCase {
    private var out: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/review-20261118/after-shell")
    }

    /// The landing pictures' own capture: a hidden passive panel, the solid fallback for glass.
    private func capture<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat, ground: Color = DeckTokens.frame) throws {
        for dark in [false, true] {
            let root = view.environment(\.agkitOffscreenSolid, true).environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: width, height: height).background(ground)
            let host = NSHostingView(rootView: root)
            let panel = NativePassiveChatPanel(contentRect: .init(x: -30000, y: -30000, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.prepareForPassiveCapture()
            panel.identifier = .init("dev.terminaldeck.ui-shell-pictures.scratch")
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.contentView = host
            defer { panel.contentView = nil; panel.close() }
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"), options: .atomic)
            XCTAssertFalse(panel.isVisible)
        }
    }

    // MARK: DeckMenu

    private var accountGroups: [NewSessionAccountGroup] {
        [NewSessionAccountGroup(provider: "claude", name: "Claude", accounts: [
            NativeLandingModel.Account(id: "a1", name: "Asad Iqbal", provider: "claude", state: .signIn),
            NativeLandingModel.Account(id: "a2", name: "Imza Premium API", provider: "claude", state: .ready),
            NativeLandingModel.Account(id: "a3", name: "asadiqbalonline@gmail.com", provider: "claude", state: .ready),
            NativeLandingModel.Account(id: "a4", name: "Imza", provider: "claude", state: .ready),
        ]),
         NewSessionAccountGroup(provider: "codex", name: "Codex", accounts: [
            NativeLandingModel.Account(id: "c1", name: "ChatGPT", provider: "codex", state: .ready),
         ])]
    }

    func testMenusOnTheAppsOwnSurface() throws {
        let groups = accountGroups
        let menus = HStack(alignment: .top, spacing: 28) {
            // The account menu: names only (an address shows its part before the @), a check, a dot where one needs him.
            DeckMenuSurface {
                SessionAccountDeckMenu(groups: groups, chosenProvider: "claude", chosenAccount: "a3", pick: { _, _ in }, addAccount: {})
            }
            // A control's menu: a section, a hint, the chosen row, a switch row at the foot.
            DeckMenuSurface {
                DeckMenuRow("Default", detail: "your account’s default", action: {})
                DeckMenuRow("Opus 5.5", checked: true, action: {})
                DeckMenuRow("Fable 5.2", action: {})
                DeckMenuSection("Earlier models")
                DeckMenuRow("Sonnet 5.5", action: {})
                DeckMenuDivider()
                DeckMenuToggleRow(title: "Fast mode", detail: "off if you switch model", isOn: .constant(true))
            }
            // The WhatsApp button's menu.
            DeckMenuSurface {
                DeckMenuToggleRow(title: "Send to WhatsApp", isOn: .constant(true))
                DeckMenuDivider()
                DeckMenuSection("Agent")
                DeckMenuRow("Decker", checked: true, action: {})
                DeckMenuRow("Hoot", action: {})
                DeckMenuDivider()
                DeckMenuRow("Off", symbol: "xmark.circle", action: {})
            }
        }
        .padding(40)
        try capture(menus, "menus", width: 900, height: 420)
    }

    func testUsageRingAndPanel() throws {
        let now = Date().timeIntervalSince1970 * 1000
        let readouts = [
            UsageReadout.of(UsageWindowReading(id: "five", window: .fiveHour, label: "Current session", used: 0.42,
                                               resets: .at(now + 3 * 3_600_000 + 12 * 60_000), reportedAt: now), now: now),
            UsageReadout.of(UsageWindowReading(id: "week", window: .weekly, label: "Weekly limit", used: 0.86,
                                               resets: .at(now + 2 * 86_400_000 + 5 * 3_600_000), reportedAt: now), now: now),
            UsageReadout.of(UsageWindowReading(id: "fable", window: .weekly, label: "Current week (Fable)", used: nil,
                                               resets: .notReported, reportedAt: now), now: now),
        ]
        let panels = HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                // The ring: no number, a healthy number, a warning, fetching.
                HStack(spacing: 18) {
                    DeckUsageRing(percent: nil, level: .ok, reading: false)
                    DeckUsageRing(percent: 42, level: .ok, reading: false)
                    DeckUsageRing(percent: 86, level: .warning, reading: false)
                    DeckUsageRing(percent: 97, level: .critical, reading: false)
                }
            }
            DeckMenuSurface(width: 280) {
                NativeUsagePlanPanel(provider: "claude", agent: "Claude Code", account: DeckAccountWords.shown("asadiqbalonline@gmail.com"),
                                     readouts: readouts, now: now)
            }
            // Nothing read yet.
            DeckMenuSurface(width: 280) {
                NativeUsagePlanPanel(provider: "claude", agent: "Claude Code", account: "Asad Iqbal", readouts: [], now: now, checking: true)
            }
        }
        .padding(40)
        try capture(panels, "usage", width: 900, height: 380)
    }

    // MARK: Side panel

    func testSessionRowGlyphs() throws {
        func row(_ title: String, chat: Bool, working: Bool = false, selected: Bool = false, quiet: Bool = false) -> some View {
            HStack(spacing: 8) {
                SIDEBARSessionTypeIcon(chat: chat, onAccent: selected, working: working).opacity(quiet ? 0.55 : 1)
                Text(title).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(selected ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 8))
        }
        let rows = VStack(alignment: .leading, spacing: 0) {
            Text("Running").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 28)
            row("iPresent", chat: false)
            row("iMatch", chat: false, working: true)
            row("Deck Dev", chat: false, selected: true)
            row("Deck Dev", chat: true)
            row("CRM", chat: true, working: true)
            Text("Not reopened").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 28)
                .padding(.top, 12)
            row("Deck Dev · Claude Code", chat: false, quiet: true)
            Spacer(minLength: 12)
            // The bottom bar with nobody signed in: only the gear with its word (the bar's own layout, drawn by hand:
            // `SidebarSettingsLine` needs the app's model).
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 18)
                Text("Settings").font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 44)
        }
        .padding(.horizontal, 12).padding(.top, 12)
        try capture(rows, "side-panel-rows", width: 264, height: 360)
    }

    // MARK: Session header

    private func bar<Extra: View>(title: String, path: String, account: String, whatsApp: Bool?, @ViewBuilder extra: () -> Extra) -> some View {
        let extraView = extra()
        return NativeSessionBarFrame {
            EmptyView()
        } title: {
            NativeSessionTitle(title: title, rename: { _ in })
        } place: {
            NativeSessionWhere(path: path)
            ChipSeparator()
            AccountChipLabel {
                NativeCodingAIProviderMark(provider: "claude", size: 13)
                Text(account).foregroundStyle(.primary)
            }
            if let whatsApp {
                ChipSeparator()
                DeckWhatsAppMark(on: whatsApp)
            }
            extraView
        } trailing: {
            DeckUsageRing(percent: 42, level: .ok, reading: false).frame(width: 26, height: 26)
            DeckPillLabel {
                Text("Opus 5.5")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
            }
            DeckPillLabel {
                Text("Effort").foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    func testSessionHeaderLocalAndOtherDevice() throws {
        let home = NSHomeDirectory()
        let bars = VStack(spacing: 18) {
            // On this Mac: where it runs, the account's name, WhatsApp on.
            bar(title: "Deck Dev", path: home + "/Deck Dev", account: DeckAccountWords.shown("asadiqbalonline@gmail.com"), whatsApp: true) { EmptyView() }
            // WhatsApp attached but not sending.
            bar(title: "CRM build", path: home + "/Projects/crm", account: "Asad Iqbal", whatsApp: false) { EmptyView() }
            // On another device: the same bar, plus its glyph and name.
            bar(title: "Deck Dev", path: home + "/Deck Dev", account: "Asad Iqbal", whatsApp: nil) {
                ChipSeparator()
                NativeDeviceMark(name: "Asad’s MacBook Pro", kind: DeckDeviceKind.resolve(reported: nil, name: "Asad’s MacBook Pro"))
                NativeCloudMoveLine(state: .plain("", canSwitch: true), inBar: true)
            }
            // Moving here.
            bar(title: "Deck Dev", path: home + "/Deck Dev", account: "Asad Iqbal", whatsApp: nil) {
                ChipSeparator()
                NativeDeviceMark(name: "Asad’s MacBook Pro", kind: .laptop)
                NativeCloudMoveLine(state: .moving("Moving from Asad’s MacBook Pro…"), inBar: true)
            }
            .overlay(alignment: .bottom) { DeckMovingLine() }
        }
        .padding(.vertical, 16)
        try capture(bars, "session-header", width: 1100, height: 320, ground: DeckTokens.chatPage)
    }

    // MARK: Ended session

    func testEndedSessionCard() throws {
        func page(_ end: SessionEnd) -> some View {
            ZStack {
                // A stand-in for the last screen.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<16, id: \.self) { line in
                        Text(line % 4 == 0 ? "❯ swift build" : "Compiling TerminalDeckNative … done").font(.system(size: 12, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                NativeSessionEndedPage(end: end, ground: DeckTokens.chatPage, act: { _ in }, close: {})
            }
        }
        try capture(page(.exited(code: 0)), "ended-finished", width: 900, height: 520, ground: DeckTokens.chatPage)
        try capture(page(.exited(code: 1)), "ended-error", width: 900, height: 520, ground: DeckTokens.chatPage)
    }

    // MARK: Words (the parts a picture cannot prove)

    func testWordsOfTheNewLooks() {
        XCTAssertEqual(DeckAccountWords.shown("asadiqbalonline@gmail.com"), "asadiqbalonline")
        XCTAssertEqual(DeckAccountWords.shown("Asad Iqbal"), "Asad Iqbal")
        XCTAssertEqual(DeckAccountWords.shown("Sherzod’s API"), "Sherzod’s API")
        let now = 1_000_000_000.0
        func resets(_ ms: Double) -> String? {
            DeckUsageWords.resets(UsageReadout.of(UsageWindowReading(id: "w", window: .weekly, used: 0.5, resets: .at(now + ms), reportedAt: now), now: now), now: now)
        }
        XCTAssertEqual(resets(12 * 60_000), "Resets in 12 min")
        XCTAssertEqual(resets(3 * 3_600_000 + 12 * 60_000), "Resets in 3 h 12 min")
        XCTAssertEqual(resets(2 * 86_400_000 + 5 * 3_600_000), "Resets in 2 d 5 h")
        XCTAssertEqual(NativeSessionEndedLook.words(.exited(code: 1), notice: SessionEnd.exited(code: 1).notice).title, "This session stopped with an error")
        XCTAssertEqual(NativeSessionEndedLook.words(.exited(code: 0), notice: SessionEnd.exited(code: 0).notice).action, "Start again here")
        XCTAssertEqual(DeckDeviceKind.resolve(reported: nil, name: "Asad’s MacBook Pro"), .laptop)
        XCTAssertEqual(DeckDeviceKind.resolve(reported: "mac-mini", name: "Asad’s MacBook Pro"), .macMini, "the reported type wins")
        XCTAssertEqual(DeckDeviceKind.resolve(reported: nil, name: "Office"), .computer)
        XCTAssertEqual(NativeSessionWhere.shownPath(NSHomeDirectory() + "/Deck Dev"), "~/Deck Dev")
    }
}
