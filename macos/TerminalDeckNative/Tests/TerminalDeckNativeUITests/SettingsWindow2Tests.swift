import AppKit
import CryptoKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Owner, 15 Nov (REQUIREMENTS items 24, 25, 28, 31-64; DESIGN.md sections 1-4): the Settings window like macOS System
/// Settings. Made-up people only; pictures drawn offscreen into night/codex/settings-window-evidence, never in a window.
@MainActor
final class SettingsWindow2Tests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ name: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + name), encoding: .utf8)
    }
    typealias N = NativeSettingsNavigation

    // MARK: The list

    func testListIsProfileThenThreeGroupsWithSpaceNeverLines() throws {
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        XCTAssertEqual(N.items.map(\.id), ["profile", "general", "appearance", "notifications", "island",
                                           "agents", "agent-defaults", "tasks", "ai-apps", "privacy", "advanced", "help"])
        XCTAssertEqual(N.item("ai-apps")?.title, "AI apps")
        let entries = N.entries(N.items)
        XCTAssertEqual(entries.filter { if case .gap = $0 { return true } else { return false } }.count, 3)
        let window = try source("SettingsWindow.swift")
        XCTAssertFalse(window.contains("Divider()"), "groups apart by space, never by a line")
        XCTAssertTrue(window.contains("DeckSettingsLook.listGroupGap"))
        XCTAssertTrue(window.contains("NativeSettingsSidebarList.profileSecondLine") || window.contains("Self.profileSecondLine"))
        XCTAssertEqual(NativeSettingsSidebarList.profileSecondLine, "Terminal Deck account")
        XCTAssertEqual(DeckSettingsLook.profileRowPicture, 2 * 18, "about twice a row's picture")
    }

    func testRemovedPagesLeaveTheWindowAndOldLinksStillLandSomewhere() {
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        for gone in ["shortcuts", "features", "plugins", "browser", "devices", "cloud"] {
            XCTAssertFalse(N.items.contains { $0.id == gone }, gone)
        }
        XCTAssertEqual(N.canonical("shortcuts"), "general")
        XCTAssertEqual(N.canonical("features"), "general")
        XCTAssertEqual(N.canonical("plugins"), "general")
        XCTAssertEqual(N.canonical("devices"), "profile", "Devices is Profile's group")
        XCTAssertEqual(N.canonical("cloud"), "cloud", "Cloud is a page inside Profile")
        XCTAssertTrue(NativeBrowserSettingsWindow.handles("browser"))
        XCTAssertTrue(NativeBrowserSettingsWindow.handles("scraping"))
        XCTAssertEqual(N.title("browser"), "Browser", "the Browser's own window keeps its name")
        // Search finds the pages inside Profile.
        XCTAssertTrue(N.matching("cloud").map(\.id).contains("cloud"))
        XCTAssertTrue(N.matching("sign").map(\.id).contains("profile.sign-in"))
    }

    func testEveryPageInsideProfileLightsTheProfileRowAndSurvivesThePageReport() {
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        for page in [N.personalID, N.signInID, N.cloudID, N.olderDevicesID, N.devicePage("account:abc")] {
            XCTAssertEqual(N.listRow(page), "profile", page)
            let next = N.afterPageReport(wanted: nil, current: page, selected: "general", pageIDs: ["general"])
            XCTAssertEqual(next.selection, page, page)
        }
        XCTAssertEqual(N.listRow("general"), "general")
        XCTAssertEqual(N.deviceRow(N.devicePage("old:device:o1")), "old:device:o1")
    }

    func testBackAndForwardWalkWhatWasOpened() {
        let history = DeckSettingsHistory()
        history.moved(to: "general")
        history.moved(to: "profile")
        history.moved(to: "cloud")
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.back(), "profile")
        history.moved(to: "profile") // the window arrives where Back went: not a new step
        XCTAssertEqual(history.back(), "general")
        history.moved(to: "general")
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.forward(), "profile")
        history.moved(to: "profile")
        history.moved(to: "appearance") // a new page clears forward
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.backStack, ["general", "profile"])
    }

    // MARK: Devices: which device is listed where (item 24)

    func testDevicesRule() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let day: Int64 = 86_400_000
        let account: [DevicesPage.AccountDevice] = [
            .init(name: "Sam's Mac mini", kind: .mac, isThisMac: true, addedAtMs: nil, lastSeenAtMs: ms, deviceId: "mini"),
            .init(name: "Sam's MacBook Pro", kind: .mac, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 60_000, deviceId: "mbp"),
            .init(name: "iPhone 13 Pro Max", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - day, deviceId: "ip1"),
            .init(name: "iPhone 13 Pro Max", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 3 * day, deviceId: "ip2"),
            .init(name: "Chrome on Mac", kind: .browser, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - day, deviceId: "chrome"),
            .init(name: "Pixel 8", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 40 * day, deviceId: "pixel"),
            .init(name: "Android emulator", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 2 * day, deviceId: "emu"),
            .init(name: "New iPad", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: nil, deviceId: "ipad"),
        ]
        let old = [DevicesPage.OldDevice(ref: "device:o1", source: .device, name: "Old phone", lastSeenAtMs: nil, connected: false),
                   DevicesPage.OldDevice(ref: "machine:m1", source: .machine, name: "Studio", lastSeenAtMs: nil, connected: true)]
        let rows = NativeDevicesSettings.rows(account: account, old: old, now: now)
        let groups = NativeDevicesSettings.groups(rows, now: now)
        XCTAssertEqual(groups.main.map(\.name), ["Sam's Mac mini", "Studio", "Sam's MacBook Pro", "iPhone 13 Pro Max", "New iPad"])
        XCTAssertEqual(Set(groups.older.map(\.name)), ["iPhone 13 Pro Max", "Chrome on Mac", "Pixel 8", "Android emulator", "Old phone"])
        XCTAssertEqual(groups.main.count + groups.older.count, rows.count, "nothing is dropped, nothing signed out")
        XCTAssertEqual(NativeDevicesSettings.olderTitle(groups.older.count), "Older and browser sign-ins (5)")
        XCTAssertEqual(NativeDevicesSettings.secondLine(groups.main[0]), "This Mac")
        XCTAssertEqual(NativeDevicesSettings.secondLine(groups.main[2], now: now), "MacBook Pro · Active now")
        XCTAssertEqual(NativeDevicesSettings.kindWord(groups.main[0]), "Mac mini")
        XCTAssertEqual(NativeDevicesSettings.glyph(groups.main[0]), "macmini")
        XCTAssertEqual(NativeDevicesSettings.kindWord(rows.first { $0.name == "Pixel 8" }!), "Android phone")
        XCTAssertEqual(NativeDevicesSettings.signOutAllTitle, "Sign out all of these")
    }

    // MARK: Cloud (items 25, 28-30)

    func testCloudPageIsCalm() throws {
        let page = try source("NativeCloudSettings.swift")
        let start = try XCTUnwrap(page.range(of: "var body: some View {\n        DeckSettingsScaffold(title: \"Cloud\")"))
        let end = try XCTUnwrap(page.range(of: "struct NativeCloudDevicePlainRow"))
        let body = String(page[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("Button(\"Pause\")") || body.contains("\"Pause\""), "one button: Sync now (Resume while paused)")
        XCTAssertTrue(body.contains("NativeCloudSettings.manageFiles") || body.contains("Self.manageFiles"))
        XCTAssertFalse(body.contains("Toggle(Self.trustSwitchTitle"), "trust moved to This Mac's page")
        XCTAssertTrue(try source("NativeDevicesSettings.swift").contains("NativeCloudSettings.trustSwitchTitle"))
        let secrets = try source("NativeCloudSecrets.swift")
        XCTAssertFalse(secrets.contains("ForEach(page.notSaved"), "the grey paragraphs are in the info button")
        XCTAssertTrue(secrets.contains("savedPasswordsInfo(page)"))
        let counts = BackendCloudPageCounts(here: [.notes: 3176, .tasks: 1])
        XCTAssertEqual(NativeCloudSyncChoicesSection.count(.memory, counts), "3,176 notes")
        XCTAssertEqual(NativeCloudSyncChoicesSection.count(.tasks, counts), "1 task")
        XCTAssertNil(NativeCloudSyncChoicesSection.count(.agents, counts), "not known yet: nothing, never 0")
        let space = BackendCloudSpace(parts: [.init(kind: .memory, title: "Memory", bytes: 60_900_000)], bytesLeft: 5_000_000_000)
        XCTAssertFalse(NativeCloudSettings.spaceTotal(space).contains("of"), "never \"of 5.37 GB\"")
        XCTAssertTrue(NativeCloudSettings.spaceBreakdown(space).hasPrefix("Memory: "))
    }

    func testNoSentenceUnderATitleOnThePagesOfThisLane() throws {
        for file in ["NativeGeneralSettings.swift", "NativeAppearanceSettings.swift", "NativeNotificationsSettings.swift",
                     "NativePrivacySettings.swift", "NativeAdvancedSettings.swift", "NativeProfileSettings.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("NativeSettingsProse("), file)
            XCTAssertFalse(text.contains(".font(.callout).foregroundStyle(.secondary)"), file)
        }
        let appearance = try source("NativeAppearanceSettings.swift")
        for gone in ["NativeTerminalColours()", "Paste a scheme", "pickerStyle(.segmented)"] { XCTAssertFalse(appearance.contains(gone), gone) }
        XCTAssertEqual(NativeAppearanceSettings.choices.map(\.title), ["Match Mac", "Light", "Dark"])
    }

    /// DESIGN-FIXES SW-1, SW-4, SW-5 (15 Nov): the rules that need no picture.
    func testOneLineForNewDevicesAndTheSmallFixes() throws {
        func line(_ id: String) -> BackendCloudOverview.Waiting { .init(id: id, text: "\u{201C}X\u{201D} is a new device that cannot be trusted right now. Look at it under Devices.") }
        XCTAssertTrue(NativeCloudOverviewSection.isDeviceLine(line("device:1")))
        XCTAssertFalse(NativeCloudOverviewSection.isDeviceLine(.init(id: "folder:crm", text: "Choose a folder")))
        let waiting = BackendCloudStatusLine(kind: .needsYou, text: "Something needs you: a new device to allow", needs: ["a new device to allow"], canSyncNow: true)
        let one = NativeCloudSettings.statusLine(waiting, devices: "4 new devices need a look")
        XCTAssertEqual(one.text, "4 new devices need a look")
        XCTAssertEqual(one.kind, .needsYou)
        XCTAssertEqual(NativeCloudSettings.statusLine(waiting, devices: nil), waiting)
        XCTAssertEqual(NativeCloudSettings.review, "Review")
        let page = try source("NativeCloudSettings.swift")
        XCTAssertTrue(page.contains("Button(Self.review) { openSettings(Self.devicesListID) }"))
        let overview = try source("NativeCloudOverview.swift")
        XCTAssertTrue(overview.contains("ForEach(Self.shownWaiting(overview))"), "a new device's sentences are never written out")
        // SW-4: the badge sits on the picture; the second line keeps its width.
        XCTAssertEqual(NativeSettingsSidebarList.badgeSize, 8)
        XCTAssertTrue(try source("SettingsWindow.swift").contains("Text(Self.profileSecondLine).font(DeckSettingsLook.rowSecond).lineLimit(1).fixedSize(horizontal: true, vertical: false)"))
        // SW-5: the row says what it is, its button what it does.
        XCTAssertEqual(SettingsNotifications.testTitle, "Test notification")
        XCTAssertEqual(SettingsNotifications.testLabel, "Send")
        // SW-3: an action he can press is never dimmed for a picture.
        XCTAssertFalse(try source("NativeDevicesSettings.swift").contains(".disabled(feed.isFixture || feed.busy)"))
        XCTAssertFalse(try source("NativeTasksSettings.swift").contains("DeckSettingsButtonRow(title: \"Delete\", role: .destructive, info: \"Removed from all devices, in the Bin for 30 days.\") {\n                Task { await remove(agent.id) }\n            }\n            .disabled(busy || fixture != nil)"))
    }

    // MARK: Pictures

    static let size = CGSize(width: 1240, height: 832)

    func testPicturesBothThemes() async throws {
        NativeSettingsValues.shared.beginOffscreenFixture()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/settings-window-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = NativeCloudAccount.shared
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day: Int64 = 86_400_000
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                                 y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        let gate = CloudGate(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, revision: CloudSequence(1), expiresAt: now + 300_000)
        func device(_ n: Int, _ label: String, _ platform: CloudPlatform, seen: Int64) -> CloudDevice {
            .init(deviceId: String(format: "10000000-0000-4000-8000-%012d", n), label: label, platform: platform, appVersion: "fixture", status: .active,
                  secretsApproved: false, lastSeenAt: seen, signPublicJwk: key, wrapPublicJwk: key, registeredAt: now - 30 * day)
        }
        let devices = [device(1, "Sam's Mac mini", .macos, seen: now), device(2, "Sam's MacBook Pro", .macos, seen: now - 60_000),
                       device(3, "Sam's iPhone", .ios, seen: now - 3_600_000), device(4, "Chrome on Mac", .web, seen: now - day),
                       device(5, "Pixel 8", .android, seen: now - 45 * day)]
        let trust = BackendCloudTrustRows.build(devices: devices, list: nil, thisDeviceId: devices[0].deviceId)
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: gate, displayName: "Sam Rivera", devices: devices,
                                            coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 3, bytes: 20, blockedReasons: [])],
                                            trust: trust)
        let power = try XCTUnwrap(LidAwakeState.decode(["supported": true, "known": true, "on": true, "idleBlocked": true, "battery": ["present": false]]))
        let reach = DevicesPage.Reach(available: true, on: true, entitled: true, door: .ready)
        defer { model.fixture(.signedOut); model.fixtureUser(nil); model.fixtureProfile(nil); NativeCloudDisplayGate.shared.offer(false)
                NativeCloudPageCounts.shared.fixture(nil) }
        // SW-2: the counts each kind's row shows right after its title.
        NativeCloudPageCounts.shared.fixture(BackendCloudPageCounts(here: [.notes: 3176, .projects: 12, .agents: 9, .instructionFiles: 41,
                                                                          .tasks: 87, .appSettings: 64, .cloudFolder: 230, .artifacts: 18]))
        NativeCloudDisplayGate.shared.offer(true)
        model.fixture(snapshot)
        model.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", email: "sam@example.com", provider: "github"))
        model.fixtureProfile(.init(name: "Sam Rivera", username: "sam", email: "sam@example.com", picture: nil,
                                   ways: [.init(provider: "google", providerName: "Google", account: "sam@example.com"),
                                          .init(provider: "github", providerName: "GitHub", account: "@sam"),
                                          .init(provider: "apple", providerName: "Apple", account: "sam@example.com")], addable: []))
        let fixture = NativeDevicesFixture(reach: reach, old: [])
        let rows = NativeDevicesSettings.rows(account: DevicesPage.accountDevices(snapshot), old: [])
        let groups = NativeDevicesSettings.groups(rows)
        let thisMac = try XCTUnwrap(groups.main.first)
        let phone = try XCTUnwrap(groups.main.first { $0.name == "Sam's iPhone" })
        XCTAssertEqual(groups.older.map(\.name).sorted(), ["Chrome on Mac", "Pixel 8"])
        for dark in [false, true] {
            try render(shell("profile") { NativeProfileSettings(model: model, devicesFixture: fixture) }, "profile", dark, output)
            try render(shell(N.personalID) { NativeProfilePersonalPage(model: model) }, "personal-information", dark, output)
            try render(shell(N.signInID) { NativeProfileSignInPage(model: model) }, "sign-in", dark, output)
            try render(shell(N.cloudID) {
                // The (i) beside Saved passwords, as its popover shows (an offscreen picture cannot open a popover).
                NativeCloudSettings(model: model).overlay(alignment: .top) {
                    DeckSettingsInfoPopoverContent(text: "API keys, keys in your own SSH folder, connected-task tokens and Receiver secrets travel with saved passwords.")
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                        .padding(.top, 420)
                }
            }, "cloud-info-open", dark, output)
            try render(shell(N.devicePage(thisMac.id)) { NativeDevicePage(rowID: thisMac.id, account: model, fixture: fixture) }, "device-this-mac", dark, output)
            try render(shell(N.devicePage(phone.id)) { NativeDevicePage(rowID: phone.id, account: model, fixture: fixture) }, "device-phone", dark, output)
            try render(shell(N.olderDevicesID) { NativeOlderDevicesPage(account: model, fixture: fixture) }, "older-devices", dark, output)
            try render(shell("general") { NativeGeneralSettings(fixtureState: power) }, "general", dark, output)
            try render(shell("appearance") { NativeAppearanceSettings(fixtureTheme: "system") }, "appearance", dark, output)
            try render(shell("notifications") { NativeNotificationsSettings() }, "notifications", dark, output)
            try render(shell("privacy") { NativePrivacySettings() }, "privacy", dark, output)
            try render(shell("advanced") { NativeAdvancedSettings() }, "advanced", dark, output)
            try render(VStack(spacing: 0) {
                Color.clear.frame(height: 28)
                NativeSettingsSidebarList(selection: .constant("profile"), search: .constant(""), appearsActive: true)
            }
            .background(DeckSidebarMaterial()), "list", dark, output, size: CGSize(width: DeckSettingsLook.listWidth, height: 832))
        }
        await NativeSettingsValues.shared.endOffscreenFixture()
    }

    /// The window's own title-bar band (28 pt, traffic lights) above the shell, as the real window draws it.
    private func shell<V: View>(_ id: String, @ViewBuilder _ page: @escaping () -> V) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)
            NativeSettingsShell(selection: .constant(id)) { _ in page() }
        }
        .background(DeckTokens.page)
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize = SettingsWindow2Tests.size) throws {
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
            .write(to: output.appendingPathComponent("settings2-\(name)-\(dark ? "dark" : "light").png"))
    }
}
