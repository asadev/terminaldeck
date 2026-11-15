import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

/// Mac tidy (Owner, 15 Nov): no Overview page anywhere; "When Terminal Deck opens" is New session / Hoot chat / Where I
/// left off; code backup is managed from the Cloud page too ("Code" in its list, the Code page's own content).
/// Pictures are drawn offscreen into `night/codex/mac-tidy-evidence` (or TD_MAC_TIDY_FRAMES), never in a window.
@MainActor
final class MacTidyPicturesTests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func output() throws -> URL {
        let out = ProcessInfo.processInfo.environment["TD_MAC_TIDY_FRAMES"].map { URL(fileURLWithPath: $0) }
            ?? package.deletingLastPathComponent().appendingPathComponent("night/codex/mac-tidy-evidence")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    // MARK: 1. The side panel without Overview

    func testTheSidePanelHasNoOverview() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        XCTAssertFalse(Sidebar21Pages.standard.contains { $0.id == "overview" || $0.title == "Overview" })
        XCTAssertFalse(AppCommandCatalog.all.contains { $0.title.contains("Overview") }, "no Overview in the menus")
        XCTAssertEqual(Sidebar21Pages.unique(["overview", "tasks"], pages: Sidebar21Pages.standard), ["tasks"], "an old pin is dropped")
        XCTAssertEqual(SHELLRoutes.overviewStandIn(current: nil), NativeLanding.pageID)
        let out = try output()
        let name = "mac-tidy-sidebar-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pins = Sidebar21Store(defaults: defaults)
        pins.initialize(existingUser: true, pages: Sidebar21Pages.standard)
        let session = SidebarItem(id: "fixture-session", title: "Review the sidebar", kind: .session, status: "working")
        let state = SidebarState(groups: [.init(id: "sessions", title: nil, items: [session])], projects: [
            .init(id: "/scratch/project", title: "Example project", expanded: false, sessions: [session])], selectedId: NativeLanding.pageID)
        let projects = SIDEBARProjectStore()
        projects.projects = [.init(id: "example", name: "Example project", folders: ["/scratch/project"])]
        projects.liveIDs = [session.id]
        let panel = SIDEBARPanel(state: state, selected: state.selectedId, store: projects,
            choose: { _ in }, openProject: {}, newSession: { _ in }, closeProject: { _ in },
            openWindow: { _ in }, rename: { _ in }, close: { _ in }, stop: { _ in }, pagePins: pins) {
                HStack { Label("Settings", systemImage: "gearshape"); Spacer() }.foregroundStyle(.secondary).font(.system(size: 13))
            } hostFailure: { EmptyView() }.frame(width: 264, height: 820)
        for dark in [false, true] {
            let expanded = HStack(alignment: .top, spacing: 12) {
                panel
                Sidebar21More(pages: Sidebar21Pages.standard, pins: pins, choose: { _ in }, dismiss: {})
                    .padding(.top, 84).padding(.trailing, 12)
            }.background(DeckTokens.frame)
            try render(expanded, size: CGSize(width: 264 + 272, height: 820), dark: dark,
                       to: out.appendingPathComponent("mac-tidy-side-panel-\(dark ? "dark" : "light").png"))
        }
    }

    // MARK: 2. General: When Terminal Deck opens

    func testWhenTerminalDeckOpensHasThreeChoices() throws {
        let setting = try XCTUnwrap(SettingsSchema.setting(NativeLandingOpensOn.settingID))
        XCTAssertEqual(setting.options.map(\.label), ["New session", "Hoot chat", "Where I left off"])
        XCTAssertEqual(setting.options.map(\.value), NativeLandingOpensOn.allCases.map(\.rawValue), "the page's choices are the app's")
        XCTAssertEqual(SettingsSchema.merge([:])[setting.id]?.string, "new-session", "untouched: New session")
        XCTAssertEqual(SettingsSchema.merge([setting.id: .string("overview")])[setting.id]?.string, "new-session", "old Overview: New session")
        let out = try output()
        let power = try XCTUnwrap(LidAwakeState.decode(["supported": true, "known": true, "on": true, "idleBlocked": true, "battery": ["present": false]]))
        for dark in [false, true] {
            let page = VStack(spacing: 0) {
                Color.clear.frame(height: 28)
                NativeSettingsShell(selection: .constant("general")) { _ in NativeGeneralSettings(fixtureState: power) }
            }.background(DeckTokens.page)
            try render(page, size: SettingsWindowTests.size, dark: dark,
                       to: out.appendingPathComponent("mac-tidy-general-\(dark ? "dark" : "light").png"))
            // The setting's menu, as its rows read when it is open (the schema's own options, in order).
            let menu = Form {
                Picker(setting.label, selection: .constant(setting.defaultValue.string ?? "")) {
                    ForEach(setting.options) { Text($0.label).tag($0.value) }
                }.pickerStyle(.inline)
            }.formStyle(.grouped).frame(width: 420, height: 200).background(DeckTokens.page)
            try render(menu, size: CGSize(width: 420, height: 200), dark: dark,
                       to: out.appendingPathComponent("mac-tidy-general-choices-\(dark ? "dark" : "light").png"))
        }
    }

    // MARK: 3. The Cloud page with "Code" chosen

    static func codeFixture() -> BackendCodeBackupReport {
        let base = CodeBackupPageTests.fixture()
        // This Mac's send is the newest backup known (the base fixture's last backup of Hoot Notes is 10 minutes ago):
        // only then does the row say which Mac it came from (`BackendCodeBackupWords.lastBackedUp`).
        let sentAt = CodeBackupPageTests.ago(5)
        let rows = base.projects.map { row -> BackendCodeBackupProject in
            var row = row
            row.homeLink = BackendCodeBackupActions.link(host: "github.com", home: row.home)
            if row.name == "Hoot Notes" { row.sentAt = sentAt; row.sentFrom = "Mac mini" }
            return row
        }
        var report = BackendCodeBackupReport(projects: rows, signedInToGitHub: true, checkedAt: base.checkedAt)
        report.automaticWaits = false
        return report
    }

    func testTheCloudPageShowsCodeFromTheCodePage() throws {
        let code = NativeCodeBackupPageModel(fixture: Self.codeFixture(), opened: ["p1"], now: CodeBackupPageTests.now)
        let contents = NativeCloudContentsModel(account: .shared, read: { nil }, code: code)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let built = try XCTUnwrap(BackendCloudContentsBuilder.build(contents: BackendCloudContentsFixture.contents(now: now),
            snapshot: BackendCloudContentsFixture.snapshot(now: now), names: BackendCloudContentsFixture.names, now: now))
        contents.show(built.model, handles: built.handles)
        contents.chooseCode()
        XCTAssertTrue(contents.showingCode)
        XCTAssertTrue(contents.shownItems.isEmpty, "no Cloud items under Code")
        XCTAssertTrue(contents.code === code, "one model: the Code page's own")
        XCTAssertTrue(NativeCloudContentsModel(read: { nil }).code === NativeCodeBackupPageModel.shared, "the live page uses the Code page's model")
        let hoot = try XCTUnwrap(code.report?.projects.first { $0.name == "Hoot Notes" })
        XCTAssertEqual(hoot.homeLink, "https://github.com/fixture-owner/hoot-notes")
        XCTAssertTrue(BackendCodeBackupWords.lastBackedUp(hoot, now: CodeBackupPageTests.now).hasSuffix(" from Mac mini"))
        contents.chooseShelf(kind: .memory)
        XCTAssertFalse(contents.showingCode, "another kind leaves Code")
        contents.chooseCode()
        // The Code page itself stays where it is (side panel, beside Projects).
        XCTAssertNotNil(SHELLRoutes.detail(kind: "panel", id: Sidebar21Pages.codeID))
        let out = try output()
        for dark in [false, true] {
            let page = VStack(spacing: 0) { Color.clear.frame(height: 28); NativeCloudContentsPage(model: contents, live: false) }
                .background(DeckTokens.page)
            try render(page, size: CGSize(width: 1240, height: 900), dark: dark,
                       to: out.appendingPathComponent("mac-tidy-cloud-code-\(dark ? "dark" : "light").png"))
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 1000)
    }
}
