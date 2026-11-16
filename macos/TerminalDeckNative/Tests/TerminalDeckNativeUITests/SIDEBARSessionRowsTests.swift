import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

/// The row itself changed on 15 Nov (testASessionRowIsItsTypeIconAndItsName): type icon and name only.
/// Asad, 29 Oct (the phone's side panel beside the Mac's): "this way profiles and titles look good … do the same for
/// the Mac app too, they are too separate". A Mac session row is the phone's: one picture (who works in it, the
/// project's badge on its corner), the session's own name (what the phones are sent, never "Session 2"), and
/// "Agent · AI" under it; a session with no agent shows only its AI. Fixture data only; nothing starts.
final class SIDEBARSessionRowsTests: XCTestCase {
    func testTheTitleIsTheSessionsOwnNameAsThePhonesGetIt() {
        // The page writes "Session 2" for a session still named after its folder; the phones get its own name.
        XCTAssertEqual(SIDEBARSessionLine.title(given: nil, own: "ClaudeCRM", rail: "Session 2", folder: "/work/ClaudeCRM"), "ClaudeCRM")
        // A name given here (or announced) wins at once, before the list is read again.
        XCTAssertEqual(SIDEBARSessionLine.title(given: "Fix login", own: "ClaudeCRM", rail: "Session 2", folder: nil), "Fix login")
        // A session the list does not hold (another Mac, a server) keeps the rail's name.
        XCTAssertEqual(SIDEBARSessionLine.title(given: nil, own: nil, rail: "Remote work", folder: nil), "Remote work")
        // Before session:list arrives, a generated rail label must not leak into the row.
        XCTAssertEqual(SIDEBARSessionLine.title(given: nil, own: nil, rail: "Session 2", folder: "/work/ClaudeCRM"), "ClaudeCRM")
        XCTAssertEqual(SIDEBARSessionLine.title(given: nil, own: nil, rail: "Session 1", folder: nil), "Untitled session")
        // Account switching can retain a generated page label; it must not replace the phone's title.
        XCTAssertEqual(SIDEBARSessionLine.title(given: nil, own: "ClaudeCRM", rail: "Session 2", folder: nil, retained: "Session 2"), "ClaudeCRM")
        XCTAssertEqual(SIDEBARSessionLine.title(given: nil, own: "ClaudeCRM", rail: "Session 2", folder: nil, retained: "Fix login"), "Fix login")
        // A deliberate name stays exactly as the person entered it.
        XCTAssertEqual(SIDEBARSessionLine.title(given: "Session 2", own: nil, rail: "", folder: nil), "Session 2")
        // Nothing named: the folder's name, as on the phone.
        XCTAssertEqual(SIDEBARSessionLine.title(given: " ", own: "", rail: "", folder: "/work/Deck Dev"), "Deck Dev")
    }

    func testTheLineUnderItSaysAgentThenAI() {
        XCTAssertEqual(SIDEBARSessionLine.subtitle(agent: "Decker", ai: SIDEBARSessionLine.aiName("claude")), "Decker · Claude Code")
        XCTAssertEqual(SIDEBARSessionLine.subtitle(agent: nil, ai: SIDEBARSessionLine.aiName("codex")), "Codex", "no agent: just its AI")
        XCTAssertEqual(SIDEBARSessionLine.subtitle(agent: "Alex", ai: nil), "Alex")
        XCTAssertEqual(SIDEBARSessionLine.subtitle(agent: "Claude", ai: "Claude"), "Claude")
        XCTAssertNil(SIDEBARSessionLine.subtitle(agent: " ", ai: nil))
        XCTAssertEqual(SIDEBARSessionLine.aiName("gemini"), "Gemini")
        XCTAssertEqual(SIDEBARSessionLine.aiName("shell"), "Shell")
        XCTAssertNil(SIDEBARSessionLine.aiName(""))
    }

    func testTheRowsReadTheSameNamesAndPicturesAsThePhones() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let side = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(side.contains("SIDEBARSessionLine.title(session, store: store)"))
        // The phones' own pictures (their session lists) still name who works in each session.
        let phones = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCompositionPhonePictures.swift"), encoding: .utf8)
        XCTAssertTrue(phones.contains("if let agent = agent(id, agents: agents) { result[id] = face(agent) }"))
    }

    /// Asad, 15 Nov (DESIGN-SESSION-ROWS SR-1 to SR-8): a side-panel session row is its type icon and its name, nothing
    /// else. The outline chat bubble or terminal; no agent or project picture, no AI, no machine, no simulator or browser
    /// mark, no second line, no state dot; only the orange dot while it needs him. Projects keep their pictures.
    func testASessionRowIsItsTypeIconAndItsName() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/" + name), encoding: .utf8)
        }
        XCTAssertEqual(SIDEBARSessionTypeIcon.symbol(chat: true), "bubble.left")
        XCTAssertEqual(SIDEBARSessionTypeIcon.symbol(chat: false), "terminal")
        XCTAssertNotNil(NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: "terminal", accessibilityDescription: nil))
        XCTAssertEqual(SIDEBARSessionTypeIcon.size, 14)
        XCTAssertTrue(SIDEBARNeedsYouDot.needsYou(status: "input"))
        for status in [nil, "working", "idle", "completed", "exited", "failed"] {
            XCTAssertFalse(SIDEBARNeedsYouDot.needsYou(status: status), status ?? "nil")
        }
        let side = try source("SidebarView.swift")
        let start = try XCTUnwrap(side.range(of: "private struct SIDEBARSessionRow<MenuItems: View>: View {"))
        let end = try XCTUnwrap(side.range(of: "/// Which agent works in each session"))
        let row = String(side[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(row.contains("SIDEBARSessionTypeIcon(chat: chat"))
        for gone in ["SIDEBARSessionPicture", "subtitle", "agent", "machine", "provider", "project", "SessionStatusDot",
                     "SIDEBARToolsAtWorkMarks"] {
            XCTAssertFalse(row.contains(gone), "the session row draws no \(gone)")
        }
        XCTAssertFalse(side.contains("NativeUIGSessionSimulatorStore"), "no simulator mark in the side panel")
        XCTAssertFalse(side.contains("NativeBackgroundToolsPolicy.marks("), "no simulator or browser mark on a row")
        let cloud = try source("NativeCloudChatsViews.swift")
        let cloudStart = try XCTUnwrap(cloud.range(of: "struct SIDEBARCloudSessionRow"))
        let cloudEnd = try XCTUnwrap(cloud.range(of: "struct SIDEBAREarlierChatsRow"))
        let cloudRow = String(cloud[cloudStart.lowerBound..<cloudEnd.lowerBound])
        XCTAssertTrue(cloudRow.contains("SIDEBARSessionTypeIcon(chat: chat"))
        XCTAssertFalse(cloudRow.contains("SIDEBARSessionPicture"))
        XCTAssertFalse(cloudRow.contains("machineLine"), "no machine line on another Mac's row")
        let archived = try source("NativeChatOrganization.swift")
        XCTAssertTrue(archived.contains("SIDEBARSessionTypeIcon(chat: true)"))
        XCTAssertFalse(archived.contains("identity.picture"), "an archived chat's row has no picture")
        // Projects keep their pictures: the project rows are not touched.
        XCTAssertTrue(side.contains("private func projectRow"))
    }

    /// The side panel with a mixed list under the Projects section (TD_SIDEBAR_ROWS_FRAMES=<folder>): two chats, an AI
    /// in a terminal, a shell, one on another Mac, one holding a simulator, one holding a browser, and one that needs
    /// him (the only one with a mark: the orange dot). Light and dark: session-rows-mixed-{light,dark}.png.
    @MainActor func testRenderTheMixedListUnderProjectsLightAndDark() throws {
        guard let destination = ProcessInfo.processInfo.environment["TD_SIDEBAR_ROWS_FRAMES"] else {
            throw XCTSkip("Set TD_SIDEBAR_ROWS_FRAMES to a folder to draw the rows.")
        }
        try SessionPictureFixture.prepare()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = AGTAgentsStore.shared, chats = AGTTeamChatHistory.shared
        let saved = (store.fixture, store.live, store.liveLoaded, chats.explicitOwners)
        defer { store.fixture = saved.0; store.live = saved.1; store.liveLoaded = saved.2; chats.explicitOwners = saved.3 }
        // An agent works in two of them: its picture must NOT appear on their rows.
        store.fixture = TasksState(agents: [
            AgentProfile(id: "decker", name: "Decker", provider: "claude", icon: "sf:chart.bar.fill@green", projectID: "deckdev"),
        ])
        store.live = []; store.liveLoaded = true
        let ids = ["a1111111-1111-4111-8111-111111111111", "a2222222-2222-4222-8222-222222222222",
                   "a3333333-3333-4333-8333-333333333333", "a4444444-4444-4444-8444-444444444444",
                   "machine m1 a5555555-5555-4555-8555-555555555555", "a6666666-6666-4666-8666-666666666666",
                   "a7777777-7777-4777-8777-777777777777", "a8888888-8888-4888-8888-888888888888"]
        chats.explicitOwners = [ids[0]: "decker", ids[2]: "decker"]
        let rows = [
            SidebarItem(id: ids[0], title: "Fix login", kind: .session, status: "working"),
            SidebarItem(id: ids[1], title: "Invoice totals", kind: .session, status: "idle"),
            SidebarItem(id: ids[2], title: "Deck Dev", kind: .session, status: "working"),
            SidebarItem(id: ids[3], title: "zsh", kind: .session, status: "idle"),
            SidebarItem(id: ids[4], title: "Backups on Mac mini", kind: .session, status: "idle"),
            SidebarItem(id: ids[5], title: "iPhone build", kind: .session, status: "working"),
            SidebarItem(id: ids[6], title: "Site check in browser", kind: .session, status: "idle"),
            SidebarItem(id: ids[7], title: "Needs your approval", kind: .session, status: "input"),
        ]
        let projectsName = "sidebar-mixed-" + UUID().uuidString
        let projectsDefaults = UserDefaults(suiteName: projectsName)!
        defer { projectsDefaults.removePersistentDomain(forName: projectsName) }
        let projects = SIDEBARProjectStore(defaults: projectsDefaults)
        projects.projects = [.init(id: "deckdev", name: "Deck Dev", folders: ["/work/Deck Dev"]),
                             .init(id: "crm", name: "ClaudeCRM", folders: ["/work/ClaudeCRM"])]
        projects.liveIDs = Set(ids)
        projects.started = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Double(100 - $0)) })
        projects.sessionProjects = [ids[0]: (nil, "/work/ClaudeCRM"), ids[1]: (nil, "/work/ClaudeCRM"), ids[2]: (nil, "/work/Deck Dev"),
                                    ids[3]: (nil, "/work/Deck Dev"), ids[5]: (nil, "/work/Deck Dev"), ids[6]: (nil, "/work/ClaudeCRM"),
                                    ids[7]: (nil, "/work/ClaudeCRM")]
        projects.sessionTitles = Dictionary(uniqueKeysWithValues: zip(ids, rows.map(\.title)))
        projects.sessionProviders = [ids[0]: "claude", ids[1]: "codex", ids[2]: "claude", ids[3]: "shell", ids[4]: "claude",
                                     ids[5]: "claude", ids[6]: "codex", ids[7]: "claude"]
        projects.sessionChats = [ids[0], ids[1], ids[4], ids[7]]
        let state = SidebarState(groups: [.init(id: "sessions", title: nil, items: rows)], projects: [], selectedId: ids[1])
        let pinsName = "sidebar-mixed-pins-" + UUID().uuidString, pinsDefaults = UserDefaults(suiteName: pinsName)!
        defer { pinsDefaults.removePersistentDomain(forName: pinsName) }
        let pins = Sidebar21Store(defaults: pinsDefaults)
        pins.initialize(existingUser: false, pages: Sidebar21Pages.standard)
        pins.setPinned(Sidebar21Pages.projectsID, pinned: true, pages: Sidebar21Pages.standard)
        let width = DeckTokens.Metrics.sidebarIdeal
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let panel = SIDEBARPanel(state: state, selected: state.selectedId, store: projects,
                choose: { _ in }, openProject: {}, newSession: { _ in }, closeProject: { _ in },
                openWindow: { _ in }, rename: { _ in }, close: { _ in }, stop: { _ in }, pagePins: pins) {
                    EmptyView()
                } hostFailure: { EmptyView() }
                .environment(\.appearsActive, true)
                .frame(width: width, height: 760)
            try render(AnyView(panel), size: .init(width: width, height: 760), scheme: scheme,
                       to: output.appendingPathComponent("session-rows-mixed-\(name).png"))
        }
    }

    // MARK: Pictures (TD_SIDEBAR_ROWS_FRAMES=<folder>): light and dark, narrow and wide, the blue selected row and
    // the grey one of a window behind.

    @MainActor func testRenderTheRowsLightDarkNarrowAndWide() throws {
        guard let destination = ProcessInfo.processInfo.environment["TD_SIDEBAR_ROWS_FRAMES"] else {
            throw XCTSkip("Set TD_SIDEBAR_ROWS_FRAMES to a folder to draw the rows.")
        }
        try SessionPictureFixture.prepare()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = AGTAgentsStore.shared, chats = AGTTeamChatHistory.shared
        let saved = (store.fixture, store.live, store.liveLoaded, chats.explicitOwners)
        defer { store.fixture = saved.0; store.live = saved.1; store.liveLoaded = saved.2; chats.explicitOwners = saved.3 }
        store.fixture = TasksState(agents: [
            AgentProfile(id: "decker", name: "Decker", provider: "claude", icon: "sf:chart.bar.fill@green", projectID: "deckdev"),
            AgentProfile(id: "alex", name: "Alex", provider: "claude", icon: "sf:tablecells@red", projectID: "crm"),
            AgentProfile(id: "commander", name: "Commander", provider: "claude", icon: "sf:crown@orange", projectID: "imatch"),
        ])
        store.live = []; store.liveLoaded = true
        let ids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
                   "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444",
                   "55555555-5555-4555-8555-555555555555"]
        chats.explicitOwners = [ids[0]: "decker", ids[1]: "alex", ids[2]: "commander", ids[4]: "decker"]
        let rows = [
            SidebarItem(id: ids[0], title: "Session 1", kind: .session, status: "working"),
            SidebarItem(id: ids[1], title: "Session 2", kind: .session, status: "idle"),
            SidebarItem(id: ids[2], title: "iMatch Backend", kind: .session, status: "input"),
            SidebarItem(id: ids[3], title: "Session 3", kind: .session, status: "idle"),
            SidebarItem(id: ids[4], title: "Independent agent", kind: .session, status: "idle"),
        ]
        let projectsName = "sidebar-rows-" + UUID().uuidString
        let projectsDefaults = UserDefaults(suiteName: projectsName)!
        defer { projectsDefaults.removePersistentDomain(forName: projectsName) }
        let projects = SIDEBARProjectStore(defaults: projectsDefaults)
        projects.projects = [.init(id: "deckdev", name: "Deck Dev", folders: ["/work/Deck Dev"]),
                             .init(id: "crm", name: "ClaudeCRM", folders: ["/work/ClaudeCRM"]),
                             .init(id: "imatch", name: "iMatch", folders: ["/work/iMatch"])]
        projects.liveIDs = Set(ids)
        projects.started = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Double(100 - $0)) })
        projects.sessionProjects = [ids[0]: (nil, "/work/Deck Dev"), ids[1]: (nil, "/work/ClaudeCRM"), ids[2]: (nil, "/work/iMatch"),
                                    ids[3]: (nil, "/work/ClaudeCRM"), ids[4]: (nil, "/scratch/notes")]
        projects.sessionTitles = [ids[0]: "Deck Dev", ids[1]: "ClaudeCRM", ids[2]: "iMatch Backend", ids[3]: "ClaudeCRM"]
        projects.sessionProviders = [ids[0]: "claude", ids[1]: "codex", ids[2]: "claude", ids[3]: "powershell", ids[4]: "codex"]
        projects.sessionChats = [ids[0], ids[1], ids[2], ids[4]]
        let state = SidebarState(groups: [.init(id: "sessions", title: nil, items: rows)], projects: [], selectedId: ids[0])
        let pinsName = "sidebar-rows-pins-" + UUID().uuidString, pinsDefaults = UserDefaults(suiteName: pinsName)!
        defer { pinsDefaults.removePersistentDomain(forName: pinsName) }
        let pins = Sidebar21Store(defaults: pinsDefaults)
        pins.initialize(existingUser: false, pages: Sidebar21Pages.standard)
        func panel(_ width: CGFloat, active: Bool) -> some View {
            SIDEBARPanel(state: state, selected: state.selectedId, store: projects,
                choose: { _ in }, openProject: {}, newSession: { _ in }, closeProject: { _ in },
                openWindow: { _ in }, rename: { _ in }, close: { _ in }, stop: { _ in }, pagePins: pins) {
                    HStack { Label("Settings", systemImage: "gearshape"); Spacer(); Image(systemName: "laptopcomputer.and.iphone") }
                        .foregroundStyle(.secondary).font(.system(size: 13))
                } hostFailure: { EmptyView() }
                .environment(\.appearsActive, active)
                .frame(width: width, height: 760)
        }
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            for width in [DeckTokens.Metrics.sidebarMin, DeckTokens.Metrics.sidebarMax] {
                for active in [true, false] {
                    try render(AnyView(panel(width, active: active)), size: .init(width: width, height: 760), scheme: scheme,
                               to: output.appendingPathComponent("sidebar-rows-\(name)-\(Int(width))\(active ? "" : "-behind").png"))
                }
            }
        }
        XCTAssertFalse(NSApp.isActive)
    }

    @MainActor private func render(_ view: AnyView, size: CGSize, scheme: ColorScheme, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).background(DeckTokens.frame))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 1000)
    }
}
