import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Status-line lane (owner, 14 Nov): the one Cloud line sits in the side panel's bottom bar (above his profile and the
/// gear), on every page, with one Sync now. Pictures of the bar before and with the line in each state, light and dark,
/// drawn offscreen (never in a window) into `night/codex/status-line-evidence/`, in the Settings window pictures' style.
@MainActor
final class CloudStatusLineUITests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ name: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + name), encoding: .utf8)
    }
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    static let size = CGSize(width: 264, height: 104)

    /// Every state the line can be in, with its exact words (the pictures' names are the keys).
    static func states(now: Date) -> [(String, BackendCloudStatusLine, Bool)] {
        typealias W = BackendCloudStatusLineWords
        return [
            ("level", .init(kind: .level, text: W.level(now, now: now), canSyncNow: true, levelAt: now), false),
            ("sending", .init(kind: .sending, text: W.sending(12), canSyncNow: true), false),
            ("getting", .init(kind: .getting, text: W.getting(3), canSyncNow: true), false),
            ("sync-now-running", .init(kind: .checking, text: W.checkingNow, canSyncNow: true), true),
            ("offline", .init(kind: .offline, text: W.offline), false),
            ("signed-out", .init(kind: .signedOut, text: W.signedOut), false),
            ("needs-you-memory", .init(kind: .needsYou, text: W.needsYou(["2 notes removed on MacBook Pro"]), needs: ["2 notes removed on MacBook Pro"], canSyncNow: true), false),
            ("needs-you-device", .init(kind: .needsYou, text: W.needsYou([W.device]), needs: [W.device], canSyncNow: true), false),
            ("problem", .init(kind: .problem, text: W.unreachable, canSyncNow: true), false),
            ("paused", .init(kind: .paused, text: W.paused), false),
        ]
    }

    func testTheLineSitsAtTheTopOfSettingsCloudNotInTheSidePanel() throws {
        let sidebar = try source("SidebarView.swift")
        // Owner, 15 Nov: the line and its Sync now left the side panel; what keeps it current still runs there, unseen.
        XCTAssertFalse(sidebar.contains("SidebarCloudStatus(open:"))
        XCTAssertTrue(sidebar.contains("if cloudLine { NativeCloudStatusWatch() }"))
        XCTAssertTrue(sidebar.contains("cloudLine: true"))
        // SW-1 (DESIGN-FIXES, 15 Nov): the row shows the line, or the one "N new devices need a look" line in its place.
        XCTAssertTrue(try source("NativeCloudSettings.swift").contains("NativeCloudSettingsStatusRow(line: Self.statusLine(line, devices: devices)"))
        XCTAssertTrue(sidebar.contains("footer().frame(height: 44)"), "the profile and gear row keeps its height")
        let line = try source("NativeCloudStatusLine.swift")
        XCTAssertTrue(line.contains("DeckSidebarRowStyle()"), "the bar's own row style")
        XCTAssertTrue(line.contains("DeckSidebarIconStyle()"), "the gear's own icon style for Sync now")
    }

    func testSyncNowIsOneControlAndOnlyWhereItCanRun() {
        for (_, line, _) in Self.states(now: Date()) {
            switch line.kind {
            case .signedOut, .offline, .paused, .off, .signingIn: XCTAssertFalse(line.canSyncNow, line.text)
            default: XCTAssertTrue(line.canSyncNow, line.text)
            }
        }
        // Without a signed-in account, a press starts nothing (and never a second pass while one runs).
        let account = NativeCloudAccount()
        account.syncNow()
        XCTAssertFalse(account.syncingNow)
    }

    func testTheModelReadsTheEngineAndTheToolSaysTheSame() throws {
        let account = NativeCloudAccount()
        let model = NativeCloudStatusLineModel(account: account)
        XCTAssertEqual(model.current().text, "Signed out")
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Fixture person",
                                            coverage: [.init(sourceId: "m", inventoryRow: "I01", complete: true, items: 3, bytes: 120_000_000, blockedReasons: [])],
                                            waitingRecords: 5, cloudHead: CloudSequence(4), fetched: CloudSequence(4))
        account.fixtureSnapshot(snapshot, memoryIncluded: true)
        XCTAssertEqual(model.current().text, "Sending 5 changes…")
        // Delete rule L5 (15 Nov, a1d0f1918: "no delete questions"): a note removed on another Mac is no longer a
        // question for him, so it never turns the line into "Something needs you"; the line keeps saying what moves.
        model.fixture(memoryAnswer: DeckMemoryAnswer(missing: 0, held: 1, heldFrom: "Mac mini"), levelAt: nil)
        XCTAssertEqual(model.current().text, "Sending 5 changes…")
        XCTAssertNotEqual(model.current().kind, .needsYou)
        // `cloud.status`: the same line and the same space numbers (one source).
        let wire = model.wire()
        XCTAssertEqual(wire["statusLine"]["line"], .string(model.current().text))
        XCTAssertEqual(wire["statusLine"]["line"], .string("Sending 5 changes…"))
        XCTAssertEqual(wire["space"], BackendCloudSpace.make(snapshot, bytesLeft: nil).wireValue)
        model.fixture(memoryAnswer: nil, levelAt: nil)
    }

    func testANewChangeIsSeenWithinTenSecondsWhileLevel_fix2() {
        let second: UInt64 = 1_000_000_000
        let quiet = CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, cloudHead: CloudSequence(4), fetched: CloudSequence(4))
        // The line says "Everything is…": its queue is re-read every 10 seconds.
        XCTAssertTrue(NativeCloudAccount.progressCheckDue(snapshot: quiet, pageOpen: false, lineShown: true, lineLevel: true, sinceLast: 10 * second))
        // Any other quiet state: every 30 seconds.
        XCTAssertFalse(NativeCloudAccount.progressCheckDue(snapshot: quiet, pageOpen: false, lineShown: true, lineLevel: false, sinceLast: 10 * second))
        XCTAssertTrue(NativeCloudAccount.progressCheckDue(snapshot: quiet, pageOpen: false, lineShown: true, lineLevel: false, sinceLast: 30 * second))
        // The model tells the account when the line is level.
        let account = NativeCloudAccount()
        let model = NativeCloudStatusLineModel(account: account)
        model.noted(.level)
        XCTAssertTrue(account.lineLevel)
        model.noted(.sending)
        XCTAssertFalse(account.lineLevel)
    }

    func testMemoryQuestionIsReadBeforeTheFirstEverything_fix3() throws {
        let account = NativeCloudAccount()
        let model = NativeCloudStatusLineModel(account: account)
        XCTAssertFalse(model.memoryChecked, "nothing read at start-up yet")
        let level = CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Fixture person",
                                         coverage: [.init(sourceId: "m", inventoryRow: "I01", complete: true, items: 3, bytes: 10, blockedReasons: [])],
                                         cloudHead: CloudSequence(4), fetched: CloudSequence(4))
        account.fixtureSnapshot(level, memoryIncluded: true)
        XCTAssertNotEqual(model.current().kind, .level)
        let source = try source("NativeCloudStatusLine.swift")
        XCTAssertTrue(source.contains("made.memoryChecked = memoryChecked"))
    }

    func testTwoWindowsKeepTheReReadsOnUntilBothClose_fix4() {
        let account = NativeCloudAccount()
        account.lineShown(true)   // window 1
        account.lineShown(true)   // window 2
        account.lineShown(false)  // window 2 closes
        XCTAssertTrue(account.lineOpen)
        account.lineShown(false)  // window 1 closes
        XCTAssertFalse(account.lineOpen)
        account.lineShown(false)  // never below zero
        XCTAssertFalse(account.lineOpen)
        account.lineShown(true)
        XCTAssertTrue(account.lineOpen)
    }

    func testPanelHiddenShowsTheShortFormPanelShownOnlyTheBarsLine() throws {
        // Hidden: the collapse button (detail only), or a narrow window that collapsed the panel (page at the left edge).
        XCTAssertTrue(NativeCloudStatusShort.panelHidden(.detailOnly, detailMinX: 0))
        XCTAssertTrue(NativeCloudStatusShort.panelHidden(.automatic, detailMinX: 0))
        // Shown: the bar's line only, no short form in the toolbar.
        XCTAssertFalse(NativeCloudStatusShort.panelHidden(.automatic, detailMinX: 264))
        XCTAssertFalse(NativeCloudStatusShort.panelHidden(.all, detailMinX: 240))
        let content = try source("ContentView.swift")
        XCTAssertTrue(content.contains("if NativeCloudStatusShort.panelHidden(columnVisibility, detailMinX: detailMinX) {"))
        XCTAssertTrue(content.contains("NativeCloudStatusShortLive(open: { model.select(Sidebar21Pages.cloudID) })"))
        // The short words: the plain mark when level, a word or two otherwise.
        XCTAssertNil(BackendCloudStatusLineWords.short(.level))
        XCTAssertEqual(BackendCloudStatusLineWords.short(.sending), "Sending…")
        XCTAssertEqual(BackendCloudStatusLineWords.short(.offline), "Offline")
        XCTAssertEqual(BackendCloudStatusLineWords.short(.needsYou), "Needs you")
    }

    // MARK: Pictures

    func testPicturesBeforeAndInEveryStateBothThemes() throws {
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/status-line-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let account = NativeCloudAccount.shared
        defer { account.fixture(.signedOut); account.fixtureUser(nil) }
        account.fixture(CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Sam Rivera"))
        account.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", provider: "github"))
        let now = Date()
        for dark in [false, true] {
            try render(StatusBarFixture(line: nil, syncing: false), "before", dark, output)
            for (name, line, syncing) in Self.states(now: now) {
                try render(StatusBarFixture(line: line, syncing: syncing), name, dark, output)
            }
        }
        // Panel hidden: the short form in the toolbar, level (plain mark) and needs you.
        for dark in [false, true] {
            let level = Self.states(now: now)[0].1, needs = Self.states(now: now)[6].1
            try render(HStack(spacing: 8) { Spacer(); NativeCloudStatusShort(line: level, open: {}); NativeCloudStatusShort(line: needs, open: {}) }
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity).background(DeckTokens.frame),
                       "toolbar-short", dark, output, size: CGSize(width: 264, height: 52))
        }
        // Space per kind under the kinds of the side panel's Cloud page.
        let space = BackendCloudSpace(parts: [.init(kind: .memory, title: "Memory", bytes: 120_000_000),
                                              .init(kind: .bootFiles, title: "Instruction files", bytes: 2_000_000),
                                              .init(kind: .settings, title: "Settings", bytes: 40_000)], bytesLeft: 9_877_960_000)
        for dark in [false, true] {
            try render(NativeCloudSpaceList(space: space).frame(width: 190).background(DeckTokens.textPrimary.opacity(0.03)),
                       "space-per-kind", dark, output, size: CGSize(width: 190, height: 110))
        }
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize = CloudStatusLineUITests.size) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("status-line-\(name)-\(dark ? "dark" : "light").png"))
    }
}

/// The side panel's bottom bar as the panel draws it (divider, the line, then profile + gear at 44 pt), without an
/// app model. `line == nil` is the bar before this lane.
private struct StatusBarFixture: View {
    let line: BackendCloudStatusLine?
    let syncing: Bool
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                if let line { SidebarCloudStatusLine(line: line, syncing: syncing, open: {}, syncNow: {}).padding(.top, 4) }
                HStack(spacing: 8) {
                    SidebarProfileButton(enabled: true) {}
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }
                .foregroundStyle(.secondary)
                .frame(height: 44)
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeckSidebarMaterial())
    }
}
