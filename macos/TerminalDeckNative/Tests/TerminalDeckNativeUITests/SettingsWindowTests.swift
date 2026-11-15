import AppKit
import CryptoKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Owner, 14 Nov: the Settings window twice as large, opening on General, no pop-out, no bottom stripe, Profile at the
/// top and Cloud holding only Cloud things. In-memory fixtures; pictures are drawn offscreen, never in a window.
@MainActor
final class SettingsWindowTests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ name: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + name), encoding: .utf8)
    }

    // MARK: Size

    func testDefaultSizeOnABigScreenIsCentredOnHisWindow() {
        let visible = CGRect(x: 0, y: 70, width: 1728, height: 1009) // a 16-inch screen without menu bar and Dock
        let anchor = CGRect(x: 200, y: 150, width: 1300, height: 850)
        let frame = NativeSettingsWindowFrame.frame(visible: visible, anchor: anchor, saved: nil)
        XCTAssertEqual(frame.size, CGSize(width: 1240, height: 860))
        XCTAssertGreaterThanOrEqual(frame.width * frame.height, 2 * 760 * 560, "at least twice the old window")
        XCTAssertEqual(frame.midX, anchor.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, anchor.midY, accuracy: 1)
        XCTAssertTrue(visible.contains(frame))
    }

    func testSmallScreenTakesWhatFitsWithAMarginAndStaysOnScreen() {
        let visible = CGRect(x: 0, y: 80, width: 1280, height: 695) // 1280 x 800 with menu bar and Dock
        let frame = NativeSettingsWindowFrame.frame(visible: visible, anchor: CGRect(x: 900, y: 500, width: 600, height: 400), saved: nil)
        XCTAssertEqual(frame.size, CGSize(width: 1200, height: 615))
        XCTAssertTrue(visible.insetBy(dx: NativeSettingsWindowFrame.margin, dy: NativeSettingsWindowFrame.margin).contains(frame))
        // A screen smaller than the window's minimum: never off screen.
        let tiny = CGRect(x: 0, y: 0, width: 700, height: 460)
        XCTAssertTrue(tiny.contains(NativeSettingsWindowFrame.frame(visible: tiny, anchor: nil, saved: nil)))
    }

    func testRemembersTheSizeHeChose() throws {
        let name = "settings-window-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(NativeSettingsWindowFrame.savedSize(defaults))
        NativeSettingsWindowFrame.remember(CGSize(width: 1500, height: 980), in: defaults)
        let saved = NativeSettingsWindowFrame.savedSize(defaults)
        XCTAssertEqual(saved, CGSize(width: 1500, height: 980))
        let big = CGRect(x: 0, y: 0, width: 2560, height: 1410)
        XCTAssertEqual(NativeSettingsWindowFrame.frame(visible: big, anchor: nil, saved: saved).size, CGSize(width: 1500, height: 980))
        // On a smaller screen his size is cut to the screen, never past it.
        let small = CGRect(x: 0, y: 80, width: 1280, height: 695)
        XCTAssertEqual(NativeSettingsWindowFrame.frame(visible: small, anchor: nil, saved: saved).size, CGSize(width: 1280, height: 695))
        // A size below the minimum is not remembered.
        NativeSettingsWindowFrame.remember(CGSize(width: 300, height: 200), in: defaults)
        XCTAssertEqual(NativeSettingsWindowFrame.savedSize(defaults), CGSize(width: 1500, height: 980))
    }

    // MARK: Opening page

    func testOpensOnGeneralAfterBeingClosedOnAnotherPage() {
        XCTAssertEqual(NativeSettingsNavigation.opened(naming: nil), "general")
        XCTAssertEqual(NativeSettingsNavigation.shown(nil), "general")
        // Closed on Cloud; the web page remembered Cloud: the opening still shows General and tells the page.
        let pages = ["general", "appearance", "notifications", "agents"]
        let next = NativeSettingsNavigation.afterPageReport(wanted: NativeSettingsNavigation.opened(naming: nil), current: "general",
                                                            selected: "appearance", pageIDs: pages)
        XCTAssertEqual(next.selection, "general")
        XCTAssertEqual(next.tellPage, "general")
        // With the gate open, Profile is listed first, and General is still what opens.
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        XCTAssertEqual(NativeSettingsNavigation.items.first?.id, "profile")
        XCTAssertEqual(NativeSettingsNavigation.shown(nil), "general")
        XCTAssertEqual(NativeSettingsNavigation.opened(naming: "hoot"), "general")
    }

    func testDeepLinkStillOpensTheNamedPage() {
        XCTAssertEqual(NativeSettingsNavigation.opened(naming: "notifications"), "notifications")
        let next = NativeSettingsNavigation.afterPageReport(wanted: "notifications", current: "notifications",
                                                            selected: "general", pageIDs: ["general", "notifications"])
        XCTAssertEqual(next.selection, "notifications")
        XCTAssertEqual(next.tellPage, "notifications")
        // A page drawn only here stays on show when the web page re-reports its list later.
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        let later = NativeSettingsNavigation.afterPageReport(wanted: nil, current: "profile", selected: "general", pageIDs: ["general"])
        XCTAssertEqual(later.selection, "profile")
        XCTAssertNil(later.tellPage)
    }

    // MARK: Pop-out, stripe, Shortcuts

    func testNoPopOutAndNoStripe() throws {
        let window = try source("SettingsWindow.swift")
        XCTAssertFalse(window.contains("NativePagePopoutButton"), "Settings has no Move to new window button")
        XCTAssertFalse(window.contains("NativeSettingsFoot"), "no stripe at the foot")
        XCTAssertFalse(try source("NativeSettingsKit.swift").contains("Changes save as you make them."))
        let tools = try source("NativeCompositionWindowTools.swift")
        XCTAssertFalse(tools.contains("settings:<section>"), "no tool splits Settings into windows")
        XCTAssertTrue(tools.contains("Settings is one window and cannot be split."))
        XCTAssertTrue(tools.contains("\"Settings → Devices\""), "move_page devices says what really happened")
    }

    /// Owner, 15 Nov: Shortcuts left Settings ("This one needs to completely go"); the shortcuts still work and show in
    /// the menus. An old link to it opens General.
    func testShortcutsLeftSettings() throws {
        XCTAssertFalse(NativeSettingsNavigation.items.contains { $0.id == "shortcuts" })
        XCTAssertEqual(NativeSettingsNavigation.canonical("shortcuts"), "general")
        let host = NSHostingView(rootView: NativeShortcutsSettings(fixtureHidden: []).frame(width: 880, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 880, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(Keymap.live(hidden: []).isEmpty)
    }

    // MARK: Profile and Cloud

    func testProfileFactsShowOnlyWhatTheAppHas() {
        let model = NativeCloudAccount()
        XCTAssertFalse(NativeProfileFacts.current(model).signedIn)
        model.fixtureSnapshot(.init(phase: .signedIn, gate: .closed, displayName: "Sam Rivera"))
        var facts = NativeProfileFacts.current(model)
        XCTAssertEqual(facts.name, "Sam Rivera")
        XCTAssertNil(facts.email)
        XCTAssertTrue(facts.signInRows.isEmpty, "the way he signed in is not known yet: no rows rather than wrong ones")
        // Without the profile API: only the way this Mac's sign-in was made, and never an "Add".
        model.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", email: "sam@example.com", provider: "github"))
        facts = NativeProfileFacts.current(model)
        XCTAssertEqual(facts.email, "sam@example.com")
        XCTAssertEqual(facts.signInRows.map(\.title), ["GitHub"])
        XCTAssertEqual(facts.signInRows.map(\.connected), [true])
        XCTAssertTrue(facts.details.isEmpty)
        XCTAssertEqual(NativeProfileFacts.initials("Sam Rivera"), "SR")
        XCTAssertEqual(NativeProfileFacts.initials("person@example.com"), "P")
        model.fixtureSnapshot(.init(phase: .signedIn, gate: .closed, displayName: "sam@example.com"))
        XCTAssertNil(NativeProfileFacts.current(model).email)
        XCTAssertEqual(NativeProfileFacts.SignIn.from("magic-link"), .email)
        XCTAssertNil(NativeProfileFacts.SignIn.from(nil))
        // Waiting to be checked again: "Sign in again" in Profile and in the bottom bar.
        model.fixtureSnapshot(.init(phase: .needsSignIn, gate: .closed, displayName: "Sam Rivera"))
        XCTAssertTrue(NativeProfileFacts.current(model).needsSignInAgain)
        XCTAssertEqual(SidebarProfileButton.text(NativeProfileFacts.current(model)), "Sign in again")
        XCTAssertEqual(SidebarProfileButton.text(NativeProfileFacts()), "Sign in")
    }

    /// Review 14 Nov, item 3: the profile API's answer decides the ways; "Add" only for a way the site can add now.
    func testWaysToSignInAreTrue() throws {
        let me = Data(#"{"name":"Sam Rivera","username":"sam","email":"sam@example.com","picture":"https://api.terminaldeck.dev/profile/v1/picture/u1?v=2","waysToSignIn":[{"id":"w1","provider":"github","providerName":"GitHub","account":"@sam","canRemove":false}]}"#.utf8)
        var profile = try XCTUnwrap(NativeCloudAccount.parseProfile(me))
        XCTAssertEqual(profile.username, "sam")
        XCTAssertEqual(profile.picture?.host, "api.terminaldeck.dev")
        let settings = Data(#"{"external":{"github":true,"google":true,"apple":false,"email":true}}"#.utf8)
        profile.addable = NativeCloudAccount.switchedOnWays(settings)
        XCTAssertEqual(profile.addable, ["github", "google"])
        let rows = NativeProfileFacts.rows(profile: profile, signedInWith: .github)
        XCTAssertEqual(rows.map(\.title), ["GitHub", "Google"], "Apple is off on the site: no Add that leads nowhere")
        XCTAssertEqual(rows.map(\.connected), [true, false])
        XCTAssertEqual(rows.first?.account, "@sam")
        XCTAssertEqual(NativeProfileSettings.addWayPage.absoluteString, "https://terminaldeck.dev/account#ways")
        // A picture from anywhere else is never loaded.
        let foreign = Data(#"{"name":"X","picture":"https://example.com/p.png","waysToSignIn":[]}"#.utf8)
        XCTAssertNil(try XCTUnwrap(NativeCloudAccount.parseProfile(foreign)).picture)
        XCTAssertEqual(NativeCloudAccount.switchedOnWays(Data("nope".utf8)), [])
        let model = NativeCloudAccount()
        model.fixtureSnapshot(.init(phase: .signedIn, gate: .closed, displayName: "Saved name"))
        model.fixtureProfile(profile)
        let facts = NativeProfileFacts.current(model)
        XCTAssertEqual(facts.name, "Sam Rivera")
        XCTAssertEqual(facts.username, "sam")
        XCTAssertNotNil(facts.picture)
    }

    func testCloudPageHasNoAccountRows() throws {
        let text = try source("NativeCloudSettings.swift")
        let start = try XCTUnwrap(text.range(of: "struct NativeCloudSettings: View"))
        let end = try XCTUnwrap(text.range(of: "struct NativeCloudDevicePlainRow"))
        let body = String(text[start.upperBound..<end.lowerBound])
        for gone in ["LabeledContent(\"Signed in\"", "\"Sign out\"", "NativeCloudDevicePlainRow(row:", "Section(\"Devices\")",
                     "Picker(Self.trustModeTitle", "displayName", "NativeCloudContentsWindow.show()", "useCloudState("] {
            XCTAssertFalse(body.contains(gone), gone)
        }
        // 15 Nov: one button (Sync now; Resume while paused); trust moved to This Mac's page.
        for kept in ["\"Sync now\"", "NativeCloudOverviewSection", "NativeCloudSecretsSection", "useCloudToggle"] {
            XCTAssertTrue(body.contains(kept), kept)
        }
        XCTAssertTrue(try source("NativeProfileSettings.swift").contains("\"Sign out\""))
        // A joined device is not said again on the Cloud page; key changes and other waiting items still are.
        XCTAssertFalse(NativeCloudOverviewSection.shownHere(.removeDevice(deviceId: "d1")))
        XCTAssertFalse(NativeCloudOverviewSection.shownHere(.trust(deviceId: "d1")), "a waiting device is Devices' business")
        XCTAssertTrue(NativeCloudOverviewSection.shownHere(.trustAgain(deviceId: "d1")))
        XCTAssertEqual(NativeCloudOverviewSection.rowState("All saved: 293 boot files"), "All saved · 293 instruction files")
        XCTAssertEqual(NativeCloudOverviewSection.words("Boot files"), "Instruction files")
    }

    func testTrustSwitchMapsToTheTwoExistingValues() {
        XCTAssertTrue(NativeCloudSettings.trustSwitchOn(.account))
        XCTAssertFalse(NativeCloudSettings.trustSwitchOn(.ask))
        XCTAssertEqual(NativeCloudSettings.trustMode(switchOn: true), .account)
        XCTAssertEqual(NativeCloudSettings.trustMode(switchOn: false), .ask)
        XCTAssertEqual(NativeCloudSettings.trustSwitchTitle, "Trust my signed-in devices automatically")
    }

    // MARK: Pages fix (14 Nov, the owner's look on both Macs)

    /// Item 1: an entry that is not shown takes no space; a divider only between two groups that both show a row.
    func testSettingsListHasNoEmptyPlace() {
        typealias N = NativeSettingsNavigation
        let all = N.items
        let entries = N.entries(all)
        XCTAssertEqual(entries.compactMap { if case .row(let id) = $0 { return id } else { return nil } }, all.map(\.id))
        XCTAssertEqual(entries.filter { if case .gap = $0 { return true } else { return false } }.count, N.groups(all).count - 1)
        // Without Dynamic Island: Notifications is followed directly by the space before the next group, nothing else.
        let without = N.entries(all.filter { $0.id != "island" })
        let ids = without.map(\.id)
        let notifications = try! XCTUnwrap(ids.firstIndex(of: "row:notifications"))
        XCTAssertTrue(ids[notifications + 1].hasPrefix("gap:"))
        // A group that loses every row loses its divider too; never two dividers in a row, never one at an end.
        let lone = N.entries(all.filter { $0.group != 1 })
        for (a, b) in zip(lone, lone.dropFirst()) {
            if case .gap = a, case .gap = b { XCTFail("two gaps in a row") }
        }
        if case .gap = lone.first { XCTFail("gap at the top") }
        if case .gap = lone.last { XCTFail("gap at the bottom") }
        XCTAssertTrue(N.entries([]).isEmpty)
        XCTAssertFalse(try source("SettingsWindow.swift").contains("ForEach(groups"), "the list is one flat run")
    }

    /// Item 2: Settings → Cloud has a Tasks row and a Settings row in the same form as the others (state · count).
    func testCloudPageListsTasksAndSettings() throws {
        let coverage = [("I01", 3), ("I12", 10), ("I21", 12)].map { row, items in
            CloudCoverage(sourceId: "s-" + row, inventoryRow: row, complete: true, items: items, bytes: 1, blockedReasons: [], exclusions: [])
        }
        var input = BackendCloudOverviewInput(snapshot: CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true),
                                                                             coverage: coverage), memory: .init(included: true))
        input.counts = BackendCloudPageCounts(here: [.notes: 3, .tasks: 10, .appSettings: 12])
        XCTAssertNil(BackendCloudOverviewBuilder.build(input)?.rows.first { $0.kind == .tasks }, "no row while tasks do not travel")
        input.tasks = .init()
        input.settings = .init()
        let overview = try XCTUnwrap(BackendCloudOverviewBuilder.build(input))
        let rows = overview.rows.map { NativeCloudOverviewSection.words($0.title) + " · " + NativeCloudOverviewSection.rowState($0.state) }
        XCTAssertTrue(rows.contains("Tasks · All saved · 10 tasks"), "\(rows)")
        XCTAssertTrue(rows.contains("Settings · All saved · 12 settings"), "\(rows)")
    }

    /// Item 6: one left edge for every device row's name and one right edge for every state.
    /// 15 Nov: every device row is the kit's link row (one 28 pt picture column, one chevron column).
    func testDeviceRowsShareTheirEdges() throws {
        let page = try source("NativeDevicesSettings.swift")
        XCTAssertTrue(page.contains(".frame(width: DeckSettingsLook.deviceGlyph, height: DeckSettingsLook.deviceGlyph)"))
        XCTAssertTrue(page.contains("DeckSettingsLinkRow(title: row.name"))
    }

    // MARK: Devices: one place

    func testDevicesAreListedInExactlyOnePlace() throws {
        XCTAssertEqual(NativeSettingsNavigation.items.first?.id, "devices", "gate closed: Devices is the top row")
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        XCTAssertEqual(NativeSettingsNavigation.items.prefix(2).map(\.id), ["profile", "general"], "Devices is Profile's group")
        XCTAssertFalse(try source("AppScenes.swift").contains("Window(\"Devices\""), "no Devices window")
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("Sources/TerminalDeckNative/DevicesWindow.swift").path))
        let profile = try source("NativeProfileSettings.swift")
        XCTAssertFalse(profile.contains("NativeCloudDevicePlainRow(row:"))
        XCTAssertFalse(profile.contains("trustModeTitle"))
        let cloudPage = try source("NativeCloudContents.swift")
        let pageStart = try XCTUnwrap(cloudPage.range(of: "struct NativeCloudContentsPage"))
        let pageEnd = try XCTUnwrap(cloudPage.range(of: "// MARK: Devices"))
        let page = String(cloudPage[pageStart.upperBound..<pageEnd.lowerBound])
        XCTAssertFalse(page.contains("NativeCloudContentsDevices"), "the Cloud page draws no device cards")
        XCTAssertFalse(page.contains("NativeCloudContentsActivity"), "no history list")
        let devices = try source("NativeDevicesSettings.swift")
        let start = try XCTUnwrap(devices.range(of: "var body: some View {"))
        let body = String(devices[start.lowerBound...])
        for gone in ["oldTitle", "oldLine", "oldRecent", "oldQuiet", "lastConnections", "NativeMacReachSettings", "addedAtMs", "DevicesPage.subtitle",
                     "\"Remove\"", "detailsTitle", "Section(\"Connected"] {
            XCTAssertFalse(body.contains(gone), gone)
        }
        XCTAssertTrue(body.contains("row.actionTitle"))
        XCTAssertEqual(NativeDevicesSettings.signOutTitle, "Sign out this device")
        XCTAssertEqual(NativeDevicesSettings.removeTitle, "Remove this device")
        // Access after lock or restart: one row in Advanced opening the existing content.
        let advanced = try source("NativeAdvancedSettings.swift")
        XCTAssertTrue(advanced.contains("NativeMacReachSettings(fixture: false)"))
        XCTAssertEqual(NativeAdvancedSettings.accessTitle, "Access after lock or restart")
        // Every way that opened the Devices window opens Settings → Devices.
        for file in ["SHELLRoutes.swift", "NativeJoinRemoteDialog.swift", "NativeWidgetNavigation.swift", "AppModel.swift", "SidebarView.swift", "ContentView.swift"] {
            XCTAssertFalse(try source(file).contains("requestDevicesWindow"), file)
        }
        XCTAssertTrue(try source("SHELLRoutes.swift").contains("AppModel.shared.openDevices()"))
    }

    func testDeviceRowsSayOneState() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(NativeDevicesSettings.state(.init(name: "Mac", kind: .mac, isThisMac: true, addedAtMs: nil, lastSeenAtMs: ms), now: now), "This Mac")
        XCTAssertEqual(NativeDevicesSettings.state(.init(name: "iPhone", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 60_000), now: now), "Active now")
        XCTAssertTrue(NativeDevicesSettings.state(.init(name: "Pixel", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 3_600_000), now: now).hasPrefix("Last seen "))
        XCTAssertEqual(NativeDevicesSettings.doorWord(.init(available: true, on: true, entitled: true, door: .ready)), "Ready")
        XCTAssertEqual(NativeDevicesSettings.doorWord(.init(available: true, on: true, entitled: true, door: .connecting)), "Connecting…")
        XCTAssertEqual(NativeDevicesSettings.doorWord(.init(available: true, on: true, entitled: true, door: .notReachable)), "Not reachable right now")
        XCTAssertNil(NativeDevicesSettings.doorWord(.init(available: true, on: false, entitled: true)))
    }

    /// Review 14 Nov, item 1: devices connected before accounts are ordinary rows of the one list.
    func testOldDevicesAreOrdinaryRows() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let ms = now.timeIntervalSince1970 * 1000
        let account = [DevicesPage.AccountDevice(name: "MacBook Pro", kind: .mac, isThisMac: true, addedAtMs: nil, lastSeenAtMs: nil, deviceId: "a1"),
                       DevicesPage.AccountDevice(name: "Pixel", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: Int64(ms) - 7_200_000, deviceId: "a2")]
        let old = [DevicesPage.OldDevice(ref: "device:o1", source: .device, name: "Old iPhone", lastSeenAtMs: ms - 3_600_000, connected: false),
                   DevicesPage.OldDevice(ref: "machine:m1", source: .machine, name: "Studio", lastSeenAtMs: nil, connected: true)]
        let rows = NativeDevicesSettings.rows(account: account, old: old, now: now)
        XCTAssertEqual(rows.map(\.name), ["MacBook Pro", "Studio", "Old iPhone", "Pixel"])
        XCTAssertEqual(NativeDevicesSettings.state(rows[1], now: now), "Active now")
        XCTAssertTrue(NativeDevicesSettings.state(rows[2], now: now).hasPrefix("Last seen "))
        XCTAssertTrue(rows[1].canDisconnect && rows[2].canDisconnect && !rows[0].canDisconnect)
    }

    /// Review 14 Nov, item 2: the action finds its device by the device's own id, so a list that re-sorts between the
    /// menu and the press can never hand it another device.
    func testDisconnectHitsTheSameDeviceAfterAReSort() throws {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        func devices(_ pixelSeen: Int64, _ ipadSeen: Int64) -> [DevicesPage.AccountDevice] {
            [.init(name: "Pixel", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: pixelSeen, deviceId: "pixel"),
             .init(name: "iPad", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ipadSeen, deviceId: "ipad")]
        }
        let before = NativeDevicesSettings.rows(account: devices(ms - 1_000, ms - 9_000), old: [], now: now)
        let held = before[0] // the menu drawn on the first row: Pixel
        XCTAssertEqual(held.name, "Pixel")
        let after = NativeDevicesSettings.rows(account: devices(ms - 9_000, ms - 1_000), old: [], now: now)
        XCTAssertEqual(after[0].name, "iPad", "the list re-sorted under the open menu")
        let target = try XCTUnwrap(NativeDevicesSettings.target(held.id, in: after))
        XCTAssertEqual(target.source, .account(deviceId: "pixel"))
        XCTAssertEqual(Set(after.map(\.id)).count, after.count, "every row has its own id")
        let source = try source("NativeDevicesSettings.swift")
        XCTAssertFalse(source.contains("id: \\.offset"), "rows are never keyed by place")
    }

    /// Review 14 Nov, item 5: a new device that waits says so on its row, with Trust on the row.
    func testWaitingDeviceSaysSoOnItsRow() {
        let row = NativeDevicesSettings.row(DevicesPage.AccountDevice(name: "Mac mini", kind: .mac, isThisMac: false, addedAtMs: nil, lastSeenAtMs: 1, deviceId: "m"))
        XCTAssertEqual(NativeDevicesSettings.state(row, waiting: true), "Waiting for you")
        XCTAssertNil(NativeDevicesSettings.waiting(row, trust: [], askMode: true))
        XCTAssertTrue(try source("NativeDevicesSettings.swift").contains("Button(\"Trust\")"))
        XCTAssertTrue(try source("SettingsWindow.swift").contains("NativeDevicesSettings.somethingWaits()"))
    }

    // MARK: Side panel

    func testBottomBarIsProfileAndGear() throws {
        let bar = try source("SidebarView.swift")
        let start = try XCTUnwrap(bar.range(of: "struct SidebarSettingsLine: View {"))
        let end = try XCTUnwrap(bar.range(of: "struct SidebarRow: View {"))
        let body = String(bar[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("SidebarProfileButton("))
        XCTAssertTrue(body.contains("Image(systemName: \"gearshape\")"))
        XCTAssertFalse(body.contains("Label(\"Settings\", systemImage"), "no word Settings")
        XCTAssertFalse(body.contains("Text(\"Settings\")"), "no word Settings")
        XCTAssertFalse(body.contains("laptopcomputer.and.iphone"), "no devices icon")
        XCTAssertTrue(body.contains("NativeSettingsNavigation.profileID"))
        XCTAssertTrue(body.contains("\"Sign in\""))
        XCTAssertEqual(SidebarProfileButton.label(name: "Asad", plan: "Ultra"), "Asad · Ultra")
        XCTAssertEqual(SidebarProfileButton.label(name: "Asad", plan: nil), "Asad")
    }

    func testSidePanelCloudOpensInTheMainWindow() {
        XCTAssertTrue(Sidebar21Pages.standard.contains { $0.id == Sidebar21Pages.cloudID && $0.title == "Cloud" })
        XCTAssertFalse(Sidebar21Pages.defaults.contains(Sidebar21Pages.cloudID), "pinned only where Cloud can be used")
        XCTAssertFalse(Sidebar21Pages.catalogue(nil, cloud: false).contains { $0.id == Sidebar21Pages.cloudID })
        XCTAssertTrue(SHELLRoutes.owns(Sidebar21Pages.cloudID), "a main-window place, kept as the selection")
        XCTAssertTrue(AppModel.nativeOnly(Sidebar21Pages.cloudID))
        XCTAssertNotNil(SHELLRoutes.detail(kind: "panel", id: Sidebar21Pages.cloudID))
        XCTAssertEqual(Sidebar21Store.addingCloud(["agents-all", "tasks", "servers"]), ["agents-all", "tasks", "cloud-page", "servers"])
        XCTAssertEqual(Sidebar21Store.addingCloud(["cloud-page"]), ["cloud-page"])
    }

    // MARK: Pictures

    static let size = CGSize(width: 1240, height: 832) // 860 minus the title bar

    func testPicturesAtTheNewSizeBothThemes() throws {
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/settings-window-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = NativeCloudAccount.shared
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                                 y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        let gate = CloudGate(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, revision: CloudSequence(1), expiresAt: now + 300_000)
        let devices: [CloudDevice] = [
            .init(deviceId: "10000000-0000-4000-8000-00000000000a", label: "MacBook Pro", platform: .macos, appVersion: "fixture", status: .active,
                  secretsApproved: false, lastSeenAt: now - 60_000, signPublicJwk: key, wrapPublicJwk: key, registeredAt: now - 86_400_000 * 3),
            .init(deviceId: "10000000-0000-4000-8000-00000000000b", label: "Mac mini", platform: .macos, appVersion: "fixture", status: .active,
                  secretsApproved: false, lastSeenAt: now - 3_600_000, signPublicJwk: key, wrapPublicJwk: key, registeredAt: now - 86_400_000)
        ]
        let trust = BackendCloudTrustRows.build(devices: devices, list: nil, thisDeviceId: devices[0].deviceId)
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: gate, displayName: "Sam Rivera", devices: devices,
                                            coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 3, bytes: 20, blockedReasons: [])],
                                            trust: trust)
        let power = try XCTUnwrap(LidAwakeState.decode(["supported": true, "known": true, "on": true, "idleBlocked": true, "battery": ["present": false]]))
        defer { model.fixture(.signedOut); model.fixtureUser(nil); model.fixtureProfile(nil); NativeCloudDisplayGate.shared.offer(false) }

        model.fixture(snapshot)
        model.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", email: "sam@example.com", provider: "github"))
        model.fixtureProfile(.init(name: "Sam Rivera", username: "sam", email: "sam@example.com", picture: nil,
                                   ways: [.init(provider: "github", providerName: "GitHub", account: "@sam")], addable: ["google"]))
        let contents = NativeCloudContentsModel(account: model, read: { nil })
        if let built = BackendCloudContentsBuilder.build(contents: BackendCloudContentsFixture.contents(now: now), snapshot: BackendCloudContentsFixture.snapshot(now: now),
                                                         names: BackendCloudContentsFixture.names, now: now) {
            contents.show(built.model, handles: built.handles)
        }
        XCTAssertEqual(NativeSettingsNavigation.items.prefix(2).map(\.id), ["profile", "general"])
        for dark in [false, true] {
            try render(shell("general") { NativeGeneralSettings(fixtureState: power) }, "general", dark, output)
            try render(shell("profile") { NativeProfileSettings(model: model) }, "profile-signed-in", dark, output)
            try render(shell("cloud") { NativeCloudSettings(model: model) }, "cloud", dark, output)
            try render(shell("devices") {
                NativeDevicesSettings(account: model, fixture: true,
                                      fixtureReach: .init(available: true, on: true, entitled: true, door: .ready),
                                      fixtureOld: [.init(ref: "device:o1", source: .device, name: "Old iPhone", lastSeenAtMs: Double(now - 7_200_000), connected: false)])
            }, "devices", dark, output)
            try render(VStack(spacing: 0) { Color.clear.frame(height: 28); NativeCloudContentsPage(model: contents, live: false) }
                .background(DeckTokens.page), "side-panel-cloud", dark, output)
            try render(SidebarSettingsLineFixture(), "bottom-bar", dark, output, size: CGSize(width: 264, height: 44))
        }
        model.fixture(.signedOut)
        model.fixtureUser(nil)
        model.fixtureProfile(nil)
        NativeCloudDisplayGate.shared.offer(true)
        for dark in [false, true] {
            try render(shell("profile") { NativeProfileSettings(model: model) }, "profile-signed-out", dark, output)
            try render(SidebarSettingsLineFixture(), "bottom-bar-signed-out", dark, output, size: CGSize(width: 264, height: 44))
        }
    }

    /// The window's own title-bar band (28 pt, traffic lights) above the shell, as the real window draws it.
    private func shell<V: View>(_ id: String, @ViewBuilder _ page: @escaping () -> V) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)
            NativeSettingsShell(selection: .constant(id)) { _ in page() }
        }
        .background(DeckTokens.page)
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize = SettingsWindowTests.size) throws {
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
            .write(to: output.appendingPathComponent("settings-\(name)-\(dark ? "dark" : "light").png"))
    }
}

/// The side panel's bottom bar as drawn, without an app model (the gear is the same image the bar uses).
private struct SidebarSettingsLineFixture: View {
    var body: some View {
        HStack(spacing: 8) {
            SidebarProfileButton(enabled: true) {}
            Spacer(minLength: 0)
            Image(systemName: "gearshape").frame(width: 28, height: 28)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeckSidebarMaterial())
    }
}
