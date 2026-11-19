import AppKit
import CryptoKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Owner's review of 18 Nov 2026, area "settings" (items 24-30 and the Settings part of 14;
/// notes/review-20261118/DESIGN-settings.md): ONE devices list with real device pictures, the photo that says it can be
/// changed, Personal information typed in place, sign-in ways that can be acted on, a calm Cloud page, and the file
/// manager's visible faults. Made-up people only; pictures are drawn offscreen into night/codex/ui-settings-evidence
/// (UI_SETTINGS_PICTURES overrides the folder), never in a window on screen.
@MainActor
final class UISettingsReviewTests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ name: String, backend: Bool = false) throws -> String {
        try String(contentsOf: package.appendingPathComponent("Sources/" + (backend ? "TerminalDeckBackend/" : "TerminalDeckNative/") + name), encoding: .utf8)
    }
    typealias N = NativeSettingsNavigation
    typealias D = NativeDevicesSettings
    static let day: Int64 = 86_400_000

    // MARK: Devices (items 24, 25)

    private func accountDevices(now ms: Int64) -> [DevicesPage.AccountDevice] {
        let day = Self.day
        return [
            .init(name: "Sam's Mac mini", kind: .mac, isThisMac: true, addedAtMs: nil, lastSeenAtMs: ms, deviceId: "mini"),
            .init(name: "Sam's MacBook Pro", kind: .mac, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 60_000, deviceId: "mbp"),
            .init(name: "iPhone 13 Pro Max", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - day, deviceId: "ip1"),
            .init(name: "SAM Pixel8", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 4 * day, deviceId: "pixel"),
            .init(name: "Office PC", kind: .pc, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 5 * day, deviceId: "pc"),
            .init(name: "Chrome on Mac", kind: .browser, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 15 * day, deviceId: "chrome1"),
            .init(name: "Chrome on Mac", kind: .browser, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 16 * day, deviceId: "chrome2"),
            .init(name: "TD Hoot Edition", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 20 * day, deviceId: "hoot"),
            .init(name: "Android emulator", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 45 * day, deviceId: "emu"),
            .init(name: "Old phone", kind: .phone, isThisMac: false, addedAtMs: nil, lastSeenAtMs: ms - 400 * day, deviceId: "old"),
        ]
    }

    func testEverySignInIsInTheOneListMostRecentFirst() throws {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let old = [DevicesPage.OldDevice(ref: "device:o1", source: .device, name: "Paired phone", lastSeenAtMs: nil, connected: false)]
        let rows = D.rows(account: accountDevices(now: ms), old: old, now: now)
        // Nothing is moved to another page: browsers, the emulator, the device not seen for a year and the old pairing are all here.
        XCTAssertEqual(rows.map(\.name), ["Sam's Mac mini", "Sam's MacBook Pro", "iPhone 13 Pro Max", "SAM Pixel8", "Office PC", "Chrome on Mac",
                                          "Chrome on Mac", "TD Hoot Edition", "Android emulator", "Old phone", "Paired phone"])
        XCTAssertEqual(D.firstRows, 8)
        XCTAssertEqual(D.shown(rows, open: false).count, 8, "a long list shows its first eight")
        XCTAssertEqual(D.shown(rows, open: true).count, rows.count, "and opens the rest in place")
        XCTAssertEqual(D.shown(Array(rows.prefix(8)), open: false).count, 8, "eight rows need no \"more\" row")
        XCTAssertEqual(D.moreTitle(rows.count - D.firstRows), "Show 3 more")
        XCTAssertEqual(D.fewerTitle, "Show fewer")
        // The old page is gone; its id still opens the list.
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        XCTAssertEqual(N.canonical(N.olderDevicesID), N.profileID)
        XCTAssertFalse(N.profilePages.contains { $0.title.contains("Older") })
        let devices = try source("NativeDevicesSettings.swift")
        for gone in ["NativeOlderDevicesPage", "Older and browser sign-ins", "Sign out all of these", "olderAfterMs"] {
            XCTAssertFalse(devices.contains(gone), gone)
        }
        XCTAssertFalse(try source("SettingsWindow.swift").contains("NativeOlderDevicesPage"))
    }

    func testARowSaysOneShortStateAndTheKindOnlyWhenTheNameDoesNot() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_794_052_800) // 2026-11-07 12:00 UTC
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let rows = D.rows(account: accountDevices(now: ms), old: [], now: now)
        func line(_ name: String) -> String { D.secondLine(rows.first { $0.name == name }!, now: now, calendar: calendar) }
        XCTAssertEqual(line("Sam's Mac mini"), "This Mac")
        XCTAssertEqual(line("Sam's MacBook Pro"), "Active now", "the name says MacBook Pro already")
        XCTAssertEqual(line("iPhone 13 Pro Max"), "Last seen yesterday")
        XCTAssertEqual(line("SAM Pixel8"), "Android phone · Last seen " + D.day(ms - 4 * Self.day, now: now, calendar: calendar))
        XCTAssertEqual(line("Office PC"), "Last seen " + D.day(ms - 5 * Self.day, now: now, calendar: calendar), "\"Office PC\" says PC")
        XCTAssertTrue(line("Chrome on Mac").hasPrefix("Browser · Last seen "))
        XCTAssertTrue(line("TD Hoot Edition").hasPrefix("Phone · Last seen "))
        // A day, never a clock time; the year only when it is not this year.
        XCTAssertEqual(D.day(ms - 3_600_000, now: now, calendar: calendar), "today")
        XCTAssertFalse(D.day(ms - 4 * Self.day, now: now, calendar: calendar).contains(":"))
        XCTAssertFalse(D.day(ms - 4 * Self.day, now: now, calendar: calendar).contains("2026"))
        XCTAssertTrue(D.day(ms - 400 * Self.day, now: now, calendar: calendar).contains("2025"))
        // Waiting for his OK is the one orange line of a row.
        XCTAssertEqual(D.secondLine(rows[2], waiting: true, now: now, calendar: calendar), D.waitingState)
    }

    func testThePictureIsTheDevicesRealKindReportedFirstThenItsName() {
        func row(_ name: String, _ kind: DevicesPage.Kind?, model: String? = nil) -> D.Row {
            D.Row(id: name, name: name, symbol: "", isThisMac: false, lastSeenMs: nil, connectedNow: false, source: .account(deviceId: name),
                  kind: kind, reportedModel: model)
        }
        // Today: the name and the platform.
        XCTAssertEqual(NativeDeviceModel.of(row("Sam's Mac mini", .mac)), .macMini)
        XCTAssertEqual(NativeDeviceModel.of(row("Sam's MacBook Pro", .mac)), .macBook)
        XCTAssertEqual(NativeDeviceModel.of(row("Studio iMac", .mac)), .iMac)
        XCTAssertEqual(NativeDeviceModel.of(row("iPhone 13 Pro Max", .phone)), .iPhone)
        XCTAssertEqual(NativeDeviceModel.of(row("Sam's iPad", .phone)), .iPad)
        XCTAssertEqual(NativeDeviceModel.of(row("SAM Pixel8", .phone)), .androidPhone)
        XCTAssertEqual(NativeDeviceModel.of(row("TD Hoot Edition", .phone)), .phone, "a phone of unknown make is a plain phone")
        XCTAssertEqual(NativeDeviceModel.of(row("Office PC", .pc)), .windowsPC)
        XCTAssertEqual(NativeDeviceModel.of(row("Chrome on Mac", .browser)), .browser)
        // The seam: what the device reports wins over a name that says nothing (or something else).
        XCTAssertEqual(NativeDeviceModel.of(row("Front desk", .mac, model: "mac-mini")), .macMini)
        XCTAssertEqual(NativeDeviceModel.of(row("Front desk", .mac, model: "Mac Studio")), .macStudio)
        XCTAssertEqual(NativeDeviceModel.of(row("Work", .pc, model: "windows-laptop")), .laptop)
        XCTAssertEqual(NativeDeviceModel.of(row("Tab", .phone, model: "android-tablet")), .androidTablet)
        XCTAssertEqual(NativeDeviceModel.of(row("My phone", .phone, model: "iPhone15,2")), .iPhone)
        XCTAssertEqual(NativeDeviceModel.of(row("My phone", .phone, model: "MacBookPro18,3")), .macBook)
        XCTAssertNil(NativeDeviceModel.from(reported: "Mac16,10"), "an identifier that names no family says nothing")
        XCTAssertEqual(D.kindWord(row("Front desk", .mac, model: "mac-mini")), "Mac mini")
        XCTAssertEqual(D.kindWord(row("Sam's MacBook Pro", .mac, model: "macbook")), "MacBook Pro", "the name's finer word stays")
        // No client reports a model yet: the seam answers nil.
        XCTAssertNil(D.reportedModel(.init(name: "x", kind: .mac, isThisMac: false, addedAtMs: nil, lastSeenAtMs: nil, deviceId: "x")))
        // One family: every kind has a drawing (never an SF Symbol).
        XCTAssertEqual(NativeDeviceGlyph.box, 28)
        for model in NativeDeviceModel.allCases {
            XCTAssertFalse(NativeDeviceGlyphLines(model: model).path(in: CGRect(x: 0, y: 0, width: 28, height: 28)).isEmpty, model.rawValue)
            XCTAssertFalse(model.word.isEmpty)
        }
    }

    func testARowIsManagedWhereItIs() async throws {
        func row(_ id: String, thisMac: Bool = false, source: D.Row.Source? = nil) -> D.Row {
            D.Row(id: id, name: id, symbol: "", isThisMac: thisMac, lastSeenMs: nil, connectedNow: false, source: source ?? .account(deviceId: id))
        }
        typealias R = NativeDeviceRow
        XCTAssertEqual(R.actions(row("this", thisMac: true), waiting: false), [.rename], "this Mac: Rename only")
        XCTAssertEqual(R.actions(row("phone"), waiting: false), [.rename, .signOut])
        XCTAssertEqual(R.actions(row("phone"), waiting: true), [.trust, .rename, .signOut])
        XCTAssertEqual(R.actions(row("old", source: .old(ref: "device:o1", source: .device)), waiting: false), [.remove], "an old pairing has no name in the Cloud")
        XCTAssertEqual([R.Action.trust, .rename, .signOut, .remove].map(R.title), ["Trust", "Rename", "Sign out", "Remove"])
        // Rename in place: Enter sends the typed name once; Escape sends nothing; a refusal is said on the row.
        let edits = NativeDeviceRowEdits()
        let sent = Box<(String, String)>()
        edits.send = { id, name in sent.all.append((id, name)) }
        let phone = row("phone")
        edits.begin(phone)
        XCTAssertEqual(edits.renaming, "phone")
        XCTAssertEqual(edits.draft, "phone")
        edits.draft = "  Sam's phone  "
        edits.commit(phone)
        await edits.settle()
        XCTAssertEqual(sent.all.map(\.1), ["Sam's phone"])
        XCTAssertEqual(edits.name(phone), "Sam's phone")
        XCTAssertEqual(edits.saved, "phone", "the small check")
        XCTAssertNil(edits.renaming)
        edits.begin(phone); edits.draft = "Other"; edits.cancel(); edits.commit(phone)
        await edits.settle()
        XCTAssertEqual(sent.all.count, 1, "Escape sends nothing")
        struct Refused: Error {}
        edits.send = { _, _ in throw Refused() }
        edits.begin(phone); edits.draft = "Third"; edits.commit(phone)
        await edits.settle()
        XCTAssertEqual(edits.problems["phone"], NativeDevicePage.renameFailed)
        XCTAssertEqual(edits.name(phone), "Sam's phone", "the name it had")
        // The row has no chevron and no SF Symbol picture; its menu is the settings "…".
        let devices = try source("NativeDevicesSettings.swift")
        let rowSource = try XCTUnwrap(devices.components(separatedBy: "struct NativeDeviceRow: View").last?.components(separatedBy: "struct NativeDevicesGroup").first)
        XCTAssertTrue(rowSource.contains(".deckMenu(isPresented: $menuOpen, alignment: .trailing)"), "the app's own menu")
        XCTAssertFalse(rowSource.contains("Menu {"), "never the system's drop-down")
        XCTAssertTrue(rowSource.contains("NativeDeviceGlyph(model: NativeDeviceModel.of(row)"))
        XCTAssertFalse(rowSource.contains("chevron.right"))
        XCTAssertFalse(devices.contains("Image(systemName: NativeDevicesSettings.glyph"))
    }

    func testSignOutOfAllTheOthersIsOneQuietActionAtTheEndOfTheList() throws {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let old = [DevicesPage.OldDevice(ref: "device:o1", source: .device, name: "Paired phone", lastSeenAtMs: nil, connected: false)]
        let rows = D.rows(account: accountDevices(now: ms), old: old, now: now)
        let others = D.others(rows)
        XCTAssertEqual(others.count, rows.count - 1, "every other device and browser")
        XCTAssertFalse(others.contains { $0.isThisMac }, "this Mac stays signed in")
        XCTAssertTrue(D.offersSignOutOthers(rows))
        XCTAssertFalse(D.offersSignOutOthers(Array(rows.prefix(2))), "one other device has its own \"…\"")
        XCTAssertFalse(D.offersSignOutOthers(Array(rows.prefix(1))))
        XCTAssertEqual(D.signOutOthersTitle, "Sign out of all the others")
        XCTAssertEqual(D.signingOutOthers(12), "Signing out 12 others…")
        // One press, every other row behind the same 5-second Undo; one Undo takes them all back.
        let model = NativeDeviceSignOut(wait: { _ in try await Task.sleep(for: .seconds(60)) })
        for row in others { model.choose(row) }
        XCTAssertEqual(model.pending.count, others.count)
        model.cancelAll()
        XCTAssertTrue(model.pending.isEmpty)
        let devices = try source("NativeDevicesSettings.swift")
        let row = try XCTUnwrap(devices.components(separatedBy: "struct NativeDevicesSignOutOthersRow").last?.components(separatedBy: "struct NativeDevicesMoreRow").first)
        XCTAssertFalse(row.contains("systemRed") || row.contains(".destructive") || row.contains("borderedProminent"), "quiet: no red, no weight")
        XCTAssertTrue(devices.contains("} undo: { signOut.cancelAll() }"))
    }

    // MARK: Terminal Deck Cloud (PAYMENTS-DESIGN, "Apps": the Mac)

    func testTheTerminalDeckCloudRowDoesNotExistUntilChargingStarts() throws {
        typealias W = NativeCloudPlanWords
        let oldSeam = NativeCloudPlanSeam.current
        let oldSnapshot = NativeCloudAccount.shared.snapshot
        // Charging off: no row and no page.
        XCTAssertNil(NativeCloudPlanSeam.current())
        XCTAssertNil(NativeCloudPlanSeam.shown())
        defer { NativeCloudPlanSeam.current = oldSeam; NativeCloudAccount.shared.fixture(oldSnapshot) }
        NativeCloudPlanSeam.current = { NativeCloudPlanFacts(shows: false, state: .none) }
        XCTAssertNil(NativeCloudPlanSeam.shown(), "the paywall is off: nothing, whatever the state says")
        NativeCloudPlanSeam.current = { NativeCloudPlanFacts(shows: true, state: .none) }
        XCTAssertNotNil(NativeCloudPlanSeam.shown())
        // The row is drawn only through the seam, and the Cloud row hides (not greyed) while not entitled.
        let profile = try source("NativeProfileSettings.swift")
        XCTAssertTrue(profile.contains("let plan = NativeCloudPlanSeam.shown()"))
        XCTAssertTrue(profile.contains("if model.snapshot.subscription.offers(.settingsCloud) {"))
        XCTAssertTrue(profile.contains("if let plan { NativeCloudPlanRow(facts: plan)"))
        XCTAssertTrue(try source("SettingsWindow.swift").contains("if let plan = NativeCloudPlanSeam.shown() { NativeCloudPlanPage(facts: plan) } else { NativeProfileSettings() }"))
        // Charging off: no plan destination or search result.
        NativeCloudDisplayGate.shared.offer(true)
        defer { NativeCloudDisplayGate.shared.offer(false) }
        XCTAssertFalse(N.items.contains { $0.id == N.planID })
        XCTAssertFalse(N.matching("cloud").contains { $0.id == N.planID })
        XCTAssertFalse(N.matching("Terminal Deck").contains { $0.id == N.planID })
        XCTAssertEqual(N.listRow(N.planID), "general")
        XCTAssertEqual(N.title(N.planID), "Terminal Deck Cloud")

        // The production seam follows subscription changes without a new view or account.
        NativeCloudPlanSeam.current = { NativeCloudPlanSeam.liveFacts() }
        var snapshot = oldSnapshot
        snapshot.subscription.received(.init(paywall: .on, state: .none))
        NativeCloudAccount.shared.fixture(snapshot)
        XCTAssertEqual(NativeCloudPlanSeam.shown()?.state, NativeCloudPlanFacts.State.none)
        XCTAssertFalse(try XCTUnwrap(NativeCloudPlanSeam.shown()).entitled)
        XCTAssertEqual(N.canonical(CloudSubscriptionPage.id), N.planID)
        XCTAssertTrue(N.matching("cloud").contains { $0.id == N.planID })
        snapshot.subscription.received(.init(paywall: .on, state: .gift, plan: .yearly, paidUntil: 1_825_588_800_000,
                                            source: .gift, includedGb: 100, extraGb: 200))
        NativeCloudAccount.shared.fixture(snapshot)
        let live = try XCTUnwrap(NativeCloudPlanSeam.shown())
        XCTAssertEqual(live.state, .gift)
        XCTAssertEqual(live.plan, .yearly)
        XCTAssertEqual(live.paidUntil?.timeIntervalSince1970, 1_825_588_800)
        XCTAssertEqual(live.extraGb, 200)
        // 19 Nov: a gift shows its plan with the paywall off too; any other state shows nothing while it is off.
        snapshot.subscription.received(.init(paywall: .off, state: .gift, source: .gift, tier: .paid, canBuyStorage: true))
        NativeCloudAccount.shared.fixture(snapshot)
        XCTAssertEqual(NativeCloudPlanSeam.shown()?.state, NativeCloudPlanFacts.State.gift)
        XCTAssertTrue(N.items.contains { $0.id == N.planID } || N.profilePages.contains { $0.id == N.planID })
        for state in [CloudSubscription.State.none, .lapsed, .paid] {
            snapshot.subscription.received(.init(paywall: .off, state: state))
            NativeCloudAccount.shared.fixture(snapshot)
            XCTAssertNil(NativeCloudPlanSeam.shown(), "\(state)")
        }

        // The words: names and dates, no ids, nothing about later.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let until = Date(timeIntervalSince1970: 1_825_588_800) // 2027-11-07
        let day = W.day(until, calendar: calendar)
        XCTAssertTrue(day.contains("2027"))
        let none = NativeCloudPlanFacts(shows: true, state: .none)
        XCTAssertNil(W.rowValue(none))
        XCTAssertEqual(W.price(none), "$8.00 a month, or $67.00 a year")
        XCTAssertEqual(W.gives(none), "Browser, simulators and screen sharing, Cloud sync and tasks on every device, and 100 GB of Cloud storage.")
        XCTAssertEqual(W.subscribe, "Subscribe in the Terminal Deck app on your phone")
        let yearly = NativeCloudPlanFacts(shows: true, state: .paid, plan: .yearly, paidUntil: until, source: .apple, extraGb: 200)
        XCTAssertTrue(yearly.entitled)
        XCTAssertEqual(W.rowValue(yearly, calendar: calendar), "Yearly · paid until " + day)
        XCTAssertEqual(W.source(.apple), "Apple")
        XCTAssertEqual(W.source(.google), "Google Play")
        XCTAssertEqual(W.storage(yearly), "300 GB")
        XCTAssertEqual(W.storageInfo(yearly), "100 GB with the plan and 200 GB of extra storage.")
        XCTAssertEqual(W.manage(yearly), "Change or cancel it in the Terminal Deck app on your iPhone.")
        let gift = NativeCloudPlanFacts(shows: true, state: .gift, source: .gift)
        XCTAssertTrue(gift.entitled)
        XCTAssertEqual(W.rowValue(gift), "Gift · no charge")
        XCTAssertEqual(W.title + " · " + (W.rowValue(gift) ?? ""), "Terminal Deck Cloud · Gift · no charge")
        XCTAssertNil(W.manage(gift))
        XCTAssertNil(W.storageInfo(gift))
        let lapsed = NativeCloudPlanFacts(shows: true, state: .lapsed, plan: .monthly, paidUntil: until, dataKeptUntil: until.addingTimeInterval(90 * 86_400))
        XCTAssertFalse(lapsed.entitled)
        XCTAssertEqual(W.rowValue(lapsed, calendar: calendar), "Ended " + day)
        XCTAssertEqual(W.ended(lapsed, calendar: calendar), "Your plan ended on " + day + ". Your Cloud data is kept until "
            + W.day(until.addingTimeInterval(90 * 86_400), calendar: calendar) + ".")
        XCTAssertNil(W.ended(yearly))
        // This Mac sells nothing: the page has no button.
        let page = try source("NativeCloudPlanSettings.swift")
        XCTAssertFalse(page.contains("Button("))
        for banned in ["coming", "soon", "later", "trial"] {
            XCTAssertFalse((W.subscribe + W.gives(none) + W.price(none) + W.gift).lowercased().contains(banned), banned)
        }
    }

    // MARK: Profile (items 27, 28, 26, 14)

    func testThePhotoSaysItCanBeChangedAndPersonalInformationStaysInTheApp() throws {
        let profile = try source("NativeProfileSettings.swift")
        XCTAssertEqual(NativeProfilePictureVeil.title, "Change")
        XCTAssertTrue(profile.contains("NativeProfilePictureVeil(size: size)"))
        XCTAssertTrue(profile.contains(".onHover { hovering = $0 }"))
        XCTAssertTrue(profile.contains("\"camera.fill\""))
        for gone in ["More on the website", "Edit profile on the website", "openAccountPage", "terminaldeck.dev/account\")"] {
            XCTAssertFalse(profile.contains(gone), gone)
        }
        // The fields look like fields without a hover.
        XCTAssertEqual(NativeProfileQuietField.width, 220)
        XCTAssertEqual(NativeProfileQuietField.height, 24)
        // Username: "@" is the field's own first letter; what goes to the account has none.
        XCTAssertEqual(NativeProfileUsernameField.shown("sam"), "@sam")
        XCTAssertEqual(NativeProfileUsernameField.shown("@@sam "), "@sam")
        XCTAssertEqual(NativeProfileUsernameField.cleaned(" @Sam-Dev "), "Sam-Dev")
        XCTAssertEqual(NativeProfileUsernameField.cleaned(String(repeating: "a", count: 60)).count, 40)
        // The username is a field when the account's profile answered and lets it change; otherwise plain text.
        var facts = NativeProfileFacts(name: "Sam", username: "sam")
        XCTAssertFalse(NativeProfilePersonalPage.usernameIsField(facts), "no profile read: nothing is typed here")
        facts.editable = true
        XCTAssertTrue(NativeProfilePersonalPage.usernameIsField(facts))
        facts.usernameCanChange = false
        XCTAssertFalse(NativeProfilePersonalPage.usernameIsField(facts), "it is in the address of his Store listings")
        XCTAssertTrue(profile.contains("save: { await model.saveProfileUsername($0) }"))
        XCTAssertTrue(profile.contains("DeckSettingsRow(\"Username\", state: \"@\" + username)"))
    }

    // MARK: The account's calls for the username and the ways to sign in (items 28, 26)

    private final class Wire {
        var requests: [URLRequest] = []
        var answers: [(Data, Int)?] = []
    }
    private static func profileJSON(username: String = "sam", canChange: Bool = true, ways: [[String: Any]]? = nil) -> Data {
        let object: [String: Any] = ["name": "Sam Rivera", "username": username, "usernameCanChange": canChange, "email": "sam@example.com",
                                     "waysToSignIn": ways ?? [["id": "w1", "provider": "google", "providerName": "Google", "account": "sam@example.com", "canRemove": true],
                                                              ["id": "w2", "provider": "github", "providerName": "GitHub", "account": "@sam", "canRemove": true]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }
    private func makeModel(_ wire: Wire) throws -> NativeCloudAccount {
        let model = NativeCloudAccount()
        model.fixtureSnapshot(.init(phase: .signedIn, gate: .closed, displayName: "Sam Rivera"))
        model.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", email: "sam@example.com", provider: "github"))
        var profile = try XCTUnwrap(NativeCloudAccount.parseProfile(Self.profileJSON()))
        profile.addable = ["apple"]
        model.fixtureProfile(profile)
        model.profileToken = { _ in "fixture-token" }
        model.profileSend = { request in
            wire.requests.append(request)
            return wire.answers.isEmpty ? nil : wire.answers.removeFirst()
        }
        return model
    }

    func testTheUsernameIsSavedToTheAccountInPlace() async throws {
        let wire = Wire()
        let model = try makeModel(wire)
        XCTAssertTrue(NativeProfilePersonalPage.usernameIsField(NativeProfileFacts.current(model)))
        // Typed with its "@": the account gets the bare name, and its cleaned answer is what shows.
        wire.answers = [(Self.profileJSON(username: "sam-dev"), 200)]
        let saved = await model.saveProfileUsername(" @Sam-Dev ")
        XCTAssertNil(saved)
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url, NativeCloudAccount.profileURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]), ["username": "Sam-Dev"],
                       "only the username is sent")
        XCTAssertEqual(NativeProfileFacts.current(model).username, "sam-dev")
        XCTAssertEqual(model.accountProfile?.addable, ["apple"], "what only this Mac knows is kept")
        // Unchanged: nothing is sent.
        let same = await model.saveProfileUsername("@sam-dev")
        XCTAssertNil(same)
        XCTAssertEqual(wire.requests.count, 1)
        // Refused: the account's own sentence, and the old username stays.
        wire.answers = [(Data(#"{"code":"username_taken","message":"That username is taken."}"#.utf8), 409)]
        let taken = await model.saveProfileUsername("pat")
        XCTAssertEqual(taken, "That username is taken.")
        XCTAssertEqual(NativeProfileFacts.current(model).username, "sam-dev")
        // No connection: one plain line.
        wire.answers = [nil]
        let offline = await model.saveProfileUsername("pat")
        XCTAssertEqual(offline, NativeCloudAccount.usernameUnsaved)
        // The account says it cannot change now: the page shows text, not a field.
        let locked = try XCTUnwrap(NativeCloudAccount.parseProfile(Self.profileJSON(canChange: false)))
        XCTAssertFalse(locked.usernameCanChange)
        model.fixtureProfile(locked)
        XCTAssertFalse(NativeProfilePersonalPage.usernameIsField(NativeProfileFacts.current(model)))
        XCTAssertEqual(NativeCloudAccount.cleanedUsername(String(repeating: "a", count: 60)).count, NativeCloudAccount.usernameLimit)
    }

    func testDisconnectRemovesTheWayAtTheAccount() async throws {
        typealias P = NativeProfileSignInPage
        let wire = Wire()
        let model = try makeModel(wire)
        var rows = NativeProfileFacts.current(model).signInRows
        XCTAssertEqual(rows.map(\.title), ["Google", "GitHub", "Apple"])
        XCTAssertEqual(rows.map(\.wayID), ["w1", "w2", nil], "the account's handle, never shown")
        XCTAssertEqual(rows.map { P.control($0, among: rows, pending: [], removing: []) }, [.disconnect, .disconnect, .connect])
        // After the Undo wait the way is removed at the account, and the page shows what is left.
        wire.answers = [(Self.profileJSON(ways: [["id": "w1", "provider": "google", "providerName": "Google", "account": "sam@example.com", "canRemove": false]]), 200)]
        let removal = NativeSignInWayRemoval(wait: { _ in })
        let github = rows[1]
        removal.choose(github) { row in await model.removeSignInWay(row.wayID ?? "") }
        await removal.settle()
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "https://api.terminaldeck.dev/profile/v1/me/ways/w2")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(removal.problem)
        rows = NativeProfileFacts.current(model).signInRows
        XCTAssertEqual(rows.map(\.title), ["Google", "Apple"])
        XCTAssertEqual(P.control(rows[0], among: rows, pending: [], removing: []), .connected, "the only way left cannot be removed")
        // Refused: the account's own sentence under the list; nothing changes.
        wire.answers = [(Data(#"{"code":"last_way","message":"This is your only way to sign in, so it can't be removed. Add another way first."}"#.utf8), 409)]
        let refused = await model.removeSignInWay("w1")
        XCTAssertEqual(refused, "This is your only way to sign in, so it can't be removed. Add another way first.")
        XCTAssertEqual(NativeProfileFacts.current(model).signInRows.map(\.title), ["Google", "Apple"])
        wire.answers = [nil]
        let offline = await model.removeSignInWay("w1")
        XCTAssertEqual(offline, NativeCloudAccount.wayUnremoved)
        let empty = await model.removeSignInWay("")
        XCTAssertEqual(empty, NativeCloudAccount.wayUnremoved, "no handle: nothing is sent")
        XCTAssertEqual(wire.requests.count, 3)
    }

    func testAWayToSignInCanBeActedOnInItsRow() async {
        typealias P = NativeProfileSignInPage
        typealias Way = NativeProfileFacts.SignInRow
        let google = Way(id: "linked:google:a", title: "Google", symbol: "g.circle", account: "sam@example.com", connected: true, wayID: "w1")
        let github = Way(id: "linked:github:b", title: "GitHub", symbol: "x", account: "@sam", connected: true, wayID: "w2")
        let apple = Way(id: "add:apple", title: "Apple", symbol: "apple.logo", account: nil, connected: false)
        // Disconnect while another connected way remains; never for the last one; Connect for one that is not connected.
        XCTAssertEqual(P.control(google, among: [google, github, apple], pending: [], removing: []), .disconnect)
        XCTAssertEqual(P.control(apple, among: [google, github, apple], pending: [], removing: []), .connect)
        XCTAssertEqual(P.control(google, among: [google, apple], pending: [], removing: []), .connected, "the only way cannot be removed")
        XCTAssertEqual(P.control(google, among: [google, github], pending: [google.id], removing: []), .undo)
        XCTAssertEqual(P.control(google, among: [google, github], pending: [], removing: [google.id]), .removing)
        // The account's own word wins, and a way without the account's handle (no profile read) only says "Connected".
        var held = google; held.canRemove = false
        XCTAssertEqual(P.control(held, among: [held, github], pending: [], removing: []), .connected)
        var unknown = google; unknown.wayID = nil
        XCTAssertEqual(P.control(unknown, among: [unknown, github], pending: [], removing: []), .connected)
        XCTAssertEqual([P.disconnect, P.connect, P.connected], ["Disconnect", "Connect", "Connected"])
        // Five seconds behind Undo, then once.
        let removed = Box<String>()
        let gate = Gate()
        let removal = NativeSignInWayRemoval(wait: { _ in try await gate.wait() })
        XCTAssertEqual(NativeSignInWayRemoval.undoDelay, .seconds(5))
        removal.choose(google, remove: { row in removed.all.append(row.id); return nil })
        XCTAssertEqual(removal.pending, [google.id])
        removal.undo(google.id)
        await gate.open()
        await removal.settle()
        XCTAssertTrue(removed.all.isEmpty, "Undo: nothing is removed")
        let second = Gate()
        let again = NativeSignInWayRemoval(wait: { _ in try await second.wait() })
        again.choose(github, remove: { row in removed.all.append(row.id); return "This is your only way to sign in, so it can't be removed. Add another way first." })
        await second.open()
        await again.settle()
        XCTAssertEqual(removed.all, [github.id])
        XCTAssertTrue(again.pending.isEmpty)
        XCTAssertEqual(again.problem, "This is your only way to sign in, so it can't be removed. Add another way first.", "the account's own sentence")
    }

    func testNobodySignedInIsInvitedNotNagged() throws {
        XCTAssertEqual(NativeProfileFacts().sidebarTitle, "Sign in")
        XCTAssertEqual(NativeProfileSettings.signedOutTitle, "Terminal Deck account")
        let words = NativeProfileSettings.signedOutTitle + " " + NativeProfileSettings.signedOutLine
        for banned in ["full version", "Full version", "free", "upgrade", "Upgrade", "pay", "not signed in", "limited"] {
            XCTAssertFalse(words.contains(banned), banned)
        }
        let profile = try source("NativeProfileSettings.swift")
        let page = try XCTUnwrap(profile.components(separatedBy: "@ViewBuilder private var signedOut: some View").last?.components(separatedBy: "static func line(").first)
        XCTAssertFalse(page.contains(".opacity(0.55)"), "nothing looks switched off")
        XCTAssertFalse(page.contains("DeckTokens.warn"))
        XCTAssertEqual(page.components(separatedBy: "Button(").count, 2, "one button")
    }

    // MARK: Cloud (item 29)

    func testWhatWaitsIsSaidOnceInPlainWordsAndTheRestIsFolded() throws {
        typealias C = NativeCloudCalm
        typealias W = BackendCloudStatusLineWords
        // The row's words: never "Something needs you: …", never the cause four times.
        let passwords = BackendCloudStatusLine(kind: .needsYou, text: W.needsYou([W.passwords]), needs: [W.passwords], canSyncNow: true)
        XCTAssertEqual(passwords.text, "Something needs you: saved passwords")
        XCTAssertEqual(C.headline(passwords, passwordGaps: true), "Some saved passwords are not in your Cloud yet")
        let two = BackendCloudStatusLine(kind: .needsYou, text: W.needsYou([W.passwords, W.device]), needs: [W.passwords, W.device], canSyncNow: true)
        XCTAssertEqual(C.headline(two, passwordGaps: true), "Some saved passwords are not in your Cloud yet, and 1 more")
        let request = BackendCloudStatusLine(kind: .needsYou, text: W.needsYou([W.passwordsRequest]), needs: [W.passwordsRequest], canSyncNow: true)
        XCTAssertEqual(C.headline(request, passwordGaps: false), "A device asks for saved passwords")
        let devices = BackendCloudStatusLine(kind: .needsYou, text: "4 new devices need a look", needs: ["4 new devices need a look"], canSyncNow: true)
        XCTAssertEqual(C.headline(devices, passwordGaps: false), "4 new devices need a look")
        let other = BackendCloudStatusLine(kind: .needsYou, text: W.needsYou([W.other]), needs: [W.other], canSyncNow: true)
        XCTAssertEqual(C.headline(other, passwordGaps: false), "Something is waiting for you")
        let level = BackendCloudStatusLine(kind: .level, text: W.level(nil), canSyncNow: true)
        XCTAssertEqual(C.headline(level, passwordGaps: false), level.text, "nothing waits: the line as it is")

        // His nine orange sentences are ONE sentence behind the row.
        let kinds = ["API keys", "MCP servers", "Project secret files", "Receiver secrets", "Server passwords and saved SSH keys",
                     "Server keys from your SSH settings", "Connected-task tokens", "The voice key", "WhatsApp keys"]
        var page = BackendCloudSecretsPage()
        page.standing = .protected
        page.gapKinds = kinds
        page.gaps = kinds.map { BackendCloudSecretsWords.notSavedToCloud($0, reason: nil) }
        XCTAssertEqual(C.passwordLines(page), ["Not in your Cloud yet from this Mac: API keys, MCP servers, project secret files, Receiver secrets, "
            + "server passwords and saved SSH keys, server keys from your SSH settings, connected-task tokens, the voice key and WhatsApp keys. "
            + "This Mac tries again at every sync."])
        XCTAssertEqual(C.passwordsState(page), "Not all in Cloud yet")
        XCTAssertEqual(NativeCloudSecretsSection.savedPasswordsInfo(page)?.components(separatedBy: "\n\n").prefix(9).map { $0 }, page.gaps,
                       "each kind's own sentence is in the (i)")
        page.gaps.append("An API key is too large to save in Cloud. It stays on this Mac.")
        XCTAssertEqual(C.passwordLines(page).count, 2, "a line of another kind is kept as it is")
        page.gaps = []; page.gapKinds = []
        XCTAssertEqual(C.passwordLines(page), [])
        XCTAssertEqual(C.passwordsState(page), BackendCloudSecretsWords.on)
        XCTAssertEqual(C.passwordLines(nil), [])

        // The page: no orange words, no second box, no per-kind sentences.
        let row = try source("NativeCloudStatusLine.swift")
        let settingsRow = try XCTUnwrap(row.components(separatedBy: "struct NativeCloudSettingsStatusRow").last?.components(separatedBy: "struct SidebarCloudStatus:").first)
        XCTAssertFalse(settingsRow.contains("DeckTokens.warn"), "the dot alone carries the colour")
        let secrets = try source("NativeCloudSecrets.swift")
        XCTAssertFalse(secrets.contains("ForEach(page.gaps"))
        XCTAssertTrue(secrets.contains("state: NativeCloudCalm.passwordsState(page)"))
        let cloud = try source("NativeCloudSettings.swift")
        XCTAssertEqual(cloud.components(separatedBy: "NativeCloudOverviewSection(overview:").count, 2, "the summary is drawn once, inside the details")
        XCTAssertTrue(cloud.contains("hiding: [NativeCloudCalm.passwordsGapsID]"))
        XCTAssertTrue(try source("BackendCloudOverview.swift", backend: true).contains("\"" + C.passwordsGapsID + "\""))
        XCTAssertTrue(try source("BackendCloudSecretsWiring.swift", backend: true).contains("\"" + C.notSavedPrefix))
    }

    func testTheDetailsOpenByThemselvesOnlyForSomethingHeMustPress() {
        typealias C = NativeCloudCalm
        func overview(_ waiting: [BackendCloudOverview.Waiting]) -> BackendCloudOverview {
            BackendCloudOverview(standing: .needsYou, title: "x", lines: [], waiting: waiting, rows: [])
        }
        let gaps = BackendCloudOverview.Waiting(id: C.passwordsGapsID, text: BackendCloudOverviewWords.passwordsGaps)
        let file = BackendCloudOverview.Waiting(id: "file:1", text: "A file waits", action: .acceptFile(id: "1"))
        let device = BackendCloudOverview.Waiting(id: "device:1", text: "A new device", action: .trust(deviceId: "1"))
        XCTAssertFalse(C.startsOpen(nil))
        XCTAssertFalse(C.hasSummary(nil, changes: 0))
        XCTAssertFalse(C.startsOpen(overview([gaps])), "information stays folded")
        XCTAssertFalse(C.hasSummary(overview([gaps]), changes: 0), "the saved-passwords sentence is never said twice")
        XCTAssertTrue(C.startsOpen(overview([gaps, file])), "a button he must press is shown")
        XCTAssertTrue(C.hasSummary(overview([gaps, file]), changes: 0))
        XCTAssertFalse(C.hasSummary(overview([device]), changes: 0), "a new device is the top row's own line, with Review")
        XCTAssertTrue(C.hasSummary(overview([]), changes: 2), "files another device changed here")
        XCTAssertFalse(C.startsOpen(overview([])))
    }

    // MARK: File manager (item 30)

    private func managerPage(nameless: Int) throws -> NativeCloudContentsModel {
        typealias F = BackendCloudContentsFixture
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var names = F.names
        names.tasks = ["local:launch": "Ship the Mac app", "local:phones": "Ship the phones", "local:site": "New website pictures"]
        var items: [CloudSyncContents.Item] = names.tasks.keys.sorted().enumerated().map { index, id in
            CloudManagerFixture.record(BackendCloudKindsTasks.domain, "task-list", "task:" + id, minutesAgo: Int64(10 + index * 90), now: now)
        }
        items += (0..<nameless).map { index in
            CloudManagerFixture.record(BackendCloudKindsTasks.domain, "task-list", "task:remote:\(index)", minutesAgo: Int64(4_000 + index), now: now)
        }
        items += [CloudManagerFixture.record("brain/memory/i01", "memory", "file/hoot/card.md", minutesAgo: 400, now: now),
                  CloudManagerFixture.record("brain/memory/i02", "memory", "row/diary/1", minutesAgo: 2, now: now)]
        let contents = CloudSyncContents(thisDevice: F.mac, items: items, packs: [], held: [], refused: [])
        let built = try XCTUnwrap(BackendCloudContentsBuilder.build(contents: contents, snapshot: F.snapshot(now: now), names: names, now: now))
        let account = NativeCloudAccount()
        account.fixtureSnapshot(F.snapshot(now: now))
        let model = NativeCloudContentsModel(account: account, read: { .empty }, files: CloudManagerFixture.files,
                                             deletions: NativeCloudDeleteOps(read: { _ in .init(gateOpen: true) }))
        model.deleteGateOpen = true
        model.show(built.model, handles: built.handles)
        return model
    }

    func testRowsWithNoNameOnThisMacAreOneRow() throws {
        let page = try managerPage(nameless: 9)
        page.chooseShelf(kind: .tasks)
        let files = page.listing.files
        XCTAssertEqual(files.count, 12)
        let parts = NativeCloudNameless.split(files)
        XCTAssertEqual(parts.named.map(\.name).sorted(), ["New website pictures", "Ship the Mac app", "Ship the phones"])
        XCTAssertEqual(parts.nameless.count, 9)
        XCTAssertEqual(NativeCloudNameless.title(.tasks, count: 9), "9 tasks that are not on this Mac")
        XCTAssertEqual(NativeCloudNameless.title(.agents, count: 1), "1 agent that is not on this Mac")
        XCTAssertEqual(page.rowKeys.count, 4, "three named rows and ONE row for the nine")
        // A click on the one row selects all nine, so the bar and the menu act on them.
        let group = try XCTUnwrap(page.rowKeys.last)
        page.click(group)
        XCTAssertEqual(page.selection.count, 9)
        XCTAssertEqual(page.selectedRows.count, 9)
        XCTAssertFalse(page.canOpenSelection, "nothing to read in nine nameless rows")
        page.click(group, command: true)
        XCTAssertTrue(page.selection.isEmpty, "Command-click takes all nine out again")
        XCTAssertEqual(page.menuRows(for: group).count, 9, "the right-click menu acts on the nine without a selection")
        page.selectAll()
        XCTAssertEqual(page.selection.count, 12)
        // One nameless row alone stays an ordinary row.
        let single = try managerPage(nameless: 1)
        single.chooseShelf(kind: .tasks)
        XCTAssertTrue(NativeCloudNameless.split(single.listing.files).nameless.isEmpty)
        XCTAssertEqual(single.rowKeys.count, 4)
        // The stand-in words are the contents builder's own.
        let builder = try source("BackendCloudContents.swift", backend: true)
        for kind in [BackendCloudContents.Kind.tasks, .agents, .projects] {
            XCTAssertTrue(builder.contains("\"" + (NativeCloudNameless.standIn(kind) ?? "?") + "\""), kind.title)
        }
        XCTAssertNil(NativeCloudNameless.standIn(.memory))
    }

    func testTheListIsPackedToTheLeftAndNothingIsCut() throws {
        typealias S = NativeCloudColumnsShown
        XCTAssertEqual(NativeCloudContentsBrowser.sidebarWidth, 232, "\"Sessions and chats\" with a three-digit count fits")
        XCTAssertEqual(S.nameMax, 520)
        XCTAssertEqual(S.sizeWidth, 104, "fits \"47,927 entries\"")
        XCTAssertEqual(S(width: 900, hasOn: false, hasSize: false), S(on: false, size: false), "an empty column is not drawn")
        XCTAssertEqual(S(width: 900, hasOn: true, hasSize: true), S(on: true, size: true))
        XCTAssertEqual(S(width: 500), S(on: false, size: false), "narrow: Size, then On, step aside")
        let manager = try source("NativeCloudManager.swift")
        XCTAssertFalse(manager.contains(".textFieldStyle(.roundedBorder)"), "the quiet search, not the system's bordered box")
        XCTAssertTrue(manager.contains("NativeCloudSearchField(text: $model.search)"))
        XCTAssertTrue(manager.contains("NativeCloudEmptyList(symbol:"))
        let bar = try XCTUnwrap(manager.components(separatedBy: "struct NativeCloudStatusBar").last?.components(separatedBy: "struct NativeCloudUndoLine").first)
        XCTAssertTrue(bar.contains(".buttonStyle(.plain)"), "Clean up is a quiet text button")
    }

    // MARK: Pictures

    static let size = CGSize(width: 1240, height: 832)

    func testPicturesBothThemes() async throws {
        NativeSettingsValues.shared.beginOffscreenFixture()
        let output = ProcessInfo.processInfo.environment["UI_SETTINGS_PICTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? package.deletingLastPathComponent().appendingPathComponent("night/codex/ui-settings-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = NativeCloudAccount.shared
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day = Self.day
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                                 y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        let gate = CloudGate(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, revision: CloudSequence(1), expiresAt: now + 300_000)
        func device(_ n: Int, _ label: String, _ platform: CloudPlatform, seen: Int64) -> CloudDevice {
            .init(deviceId: String(format: "10000000-0000-4000-8000-%012d", n), label: label, platform: platform, appVersion: "fixture", status: .active,
                  secretsApproved: false, lastSeenAt: seen, signPublicJwk: key, wrapPublicJwk: key, registeredAt: now - 30 * day)
        }
        // His own list of 18 Nov, with made-up names: two Macs, phones, a PC, an iPad, browsers and an emulator.
        let devices = [device(1, "Sam's Mac mini", .macos, seen: now), device(2, "Sam's MacBook Pro", .macos, seen: now - 60_000),
                       device(3, "iPhone 13 Pro Max", .ios, seen: now - day), device(4, "SAM Pixel8", .android, seen: now - 4 * day),
                       device(5, "TD iPhone", .ios, seen: now - 4 * day - 3_600_000), device(6, "Office PC", .windows, seen: now - 5 * day),
                       device(7, "Sam's iPad", .ios, seen: now - 9 * day), device(8, "iPhone Air", .ios, seen: now - 18 * day),
                       device(9, "TD Hoot Edition", .ios, seen: now - 20 * day), device(10, "Chrome on iPhone", .web, seen: now - 11 * day),
                       device(11, "Chrome on Mac", .web, seen: now - 15 * day), device(12, "Chrome on Mac", .web, seen: now - 16 * day),
                       device(13, "Android emulator", .android, seen: now - 20 * day - 7_200_000)]
        let trust = BackendCloudTrustRows.build(devices: devices, list: nil, thisDeviceId: devices[0].deviceId)
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: gate, displayName: "Sam Rivera", devices: devices,
                                            coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 3, bytes: 20, blockedReasons: [])],
                                            trust: trust)
        let reach = DevicesPage.Reach(available: true, on: true, entitled: true, door: .ready)
        defer {
            model.fixture(.signedOut); model.fixtureUser(nil); model.fixtureProfile(nil); NativeCloudDisplayGate.shared.offer(false)
            NativeCloudPageCounts.shared.fixture(nil); NativeCloudSecrets.shared.fixture(page: nil)
            NativeCloudPlanSeam.current = { nil }
        }
        NativeCloudPageCounts.shared.fixture(BackendCloudPageCounts(here: [.notes: 3228, .projects: 4, .agents: 77, .instructionFiles: 293,
                                                                          .tasks: 10, .appSettings: 33, .cloudFolder: 1, .artifacts: 38]))
        NativeCloudDisplayGate.shared.offer(true)
        model.fixture(snapshot)
        model.fixtureUser(CloudUserIdentity(id: "u1", displayName: "Sam Rivera", email: "sam@example.com", provider: "github"))
        let ways: [NativeCloudAccount.AccountProfile.Way] = [.init(provider: "google", providerName: "Google", account: "sam@example.com", id: "w1", canRemove: true),
                                                             .init(provider: "github", providerName: "GitHub", account: "@sam", id: "w2", canRemove: true)]
        let profile = NativeCloudAccount.AccountProfile(name: "Sam Rivera", username: "sam", email: "sam@example.com", picture: nil, ways: ways, addable: ["apple"])
        model.fixtureProfile(profile)
        let fixture = NativeDevicesFixture(reach: reach, old: [])
        let rows = D.rows(account: DevicesPage.accountDevices(snapshot), old: [])
        XCTAssertEqual(rows.count, 13)
        let phone = try XCTUnwrap(rows.first { $0.name == "iPhone 13 Pro Max" })
        let pixel = try XCTUnwrap(rows.first { $0.name == "SAM Pixel8" })
        let tall = CGSize(width: 1240, height: 1300)
        // The Cloud page is drawn for an account whose only device is this Mac, so the top row says the saved passwords
        // (other devices here would wait to be trusted in a fixture and the row would count them instead).
        let cloudSnapshot = CloudAccountSnapshot(phase: .signedIn, gate: gate, displayName: "Sam Rivera", devices: [devices[0]],
                                                 coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 3, bytes: 20, blockedReasons: [])],
                                                 trust: BackendCloudTrustRows.build(devices: [devices[0]], list: nil, thisDeviceId: devices[0].deviceId))

        // Saved passwords not in the Cloud, exactly as on his Mac on 18 Nov (nine kinds).
        let kinds = ["API keys", "MCP servers", "Project secret files", "Receiver secrets", "Server passwords and saved SSH keys",
                     "Server keys from your SSH settings", "Connected-task tokens", "The voice key", "WhatsApp keys"]
        var gapsPage = BackendCloudSecretsPage()
        gapsPage.standing = .protected
        gapsPage.gapKinds = kinds
        gapsPage.gaps = kinds.map { BackendCloudSecretsWords.notSavedToCloud($0, reason: nil) }
        gapsPage.askOnNewDevice = false
        gapsPage.phonesOff = false
        var fine = BackendCloudSecretsPage()
        fine.standing = .protected
        fine.askOnNewDevice = false
        fine.phonesOff = false

        let manager = try managerPage(nameless: 9)
        let empty = try managerPage(nameless: 0)

        for dark in [false, true] {
            // Profile: the one list (first eight, "Show 5 more"), then the same with the pointer on the photo, the list
            // open, a row mid-rename and a row just saved.
            try render(shell("profile") { NativeProfileSettings(model: model, devicesFixture: fixture) }, "profile", dark, output)
            let edits = NativeDeviceRowEdits()
            edits.fixture(renaming: pixel.id, draft: "Sam's Pixel 8", saved: phone.id)
            try render(shell("profile") {
                NativeProfileSettings(model: model, devicesFixture: fixture, fixtureHover: true, fixtureDevicesOpen: true, fixtureEdits: edits)
            }, "profile-hover-open-rename", dark, output, size: tall)
            // "Sign out of all the others" pressed: the last row counts them, with the one Undo.
            try render(shell("profile") {
                NativeProfileSettings(model: model, devicesFixture: fixture, fixtureDevicesOpen: true, fixtureSigningOut: 12)
            }, "profile-signing-out-others", dark, output, size: tall)
            // The menus (an offscreen picture cannot open a panel: the menu's own surface, drawn as it opens).
            try render(HStack(alignment: .top, spacing: 32) {
                DeckMenuSurface { NativeDeviceRowMenu(actions: NativeDeviceRow.actions(phone, waiting: false)) { _ in } }
                DeckMenuSurface { NativeDeviceRowMenu(actions: NativeDeviceRow.actions(rows[0], waiting: false)) { _ in } }
                DeckMenuSurface { NativeProfilePictureMenu(model: model) }
            }
            .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(DeckTokens.page), "menus", dark, output, size: CGSize(width: 900, height: 200))
            try render(deviceFamily(), "device-pictures", dark, output, size: CGSize(width: 1240, height: 250))

            // Personal information: Name and Username typed in place (Name just saved), and a username the account
            // does not let change (plain text).
            try render(shell(N.personalID) { NativeProfilePersonalPage(model: model, fixtureSaved: .name) }, "personal-information", dark, output)
            var locked = profile
            locked.usernameCanChange = false
            model.fixtureProfile(locked)
            try render(shell(N.personalID) { NativeProfilePersonalPage(model: model) }, "personal-information-username-fixed", dark, output)
            model.fixtureProfile(profile)

            // Sign-in: Disconnect on the two connected ways, Connect on the one that is not; one row behind Undo; and
            // one way only (it cannot be removed).
            try render(shell(N.signInID) { NativeProfileSignInPage(model: model) }, "sign-in", dark, output)
            let removal = NativeSignInWayRemoval()
            removal.fixture(pending: ["linked:github:@sam"])
            try render(shell(N.signInID) { NativeProfileSignInPage(model: model, fixtureRemoval: removal) }, "sign-in-undo", dark, output)
            var single = profile
            single.ways = [ways[0]]; single.addable = []
            model.fixtureProfile(single)
            try render(shell(N.signInID) { NativeProfileSignInPage(model: model) }, "sign-in-one-way", dark, output)
            model.fixtureProfile(profile)

            // Terminal Deck Cloud (invisible today: drawn here with the paywall's states handed in).
            let until = Date().addingTimeInterval(200 * 86_400)
            let offer = NativeCloudPlanFacts(shows: true, state: .none)
            let yearly = NativeCloudPlanFacts(shows: true, state: .paid, plan: .yearly, paidUntil: until, source: .apple, extraGb: 200)
            let ended = NativeCloudPlanFacts(shows: true, state: .lapsed, plan: .monthly, paidUntil: Date().addingTimeInterval(-12 * 86_400),
                                             dataKeptUntil: Date().addingTimeInterval(78 * 86_400))
            let gift = NativeCloudPlanFacts(shows: true, state: .gift, source: .gift)
            for (name, plan) in [("offer", offer), ("paid", yearly), ("gift", gift), ("ended", ended)] {
                var planSnapshot = snapshot
                planSnapshot.subscription.received(.init(paywall: .on,
                    state: .init(rawValue: plan.state.rawValue) ?? .none,
                    plan: plan.plan.flatMap { .init(rawValue: $0.rawValue) },
                    paidUntil: plan.paidUntil.map { Int64($0.timeIntervalSince1970 * 1000) },
                    source: plan.source.flatMap { .init(rawValue: $0.rawValue) },
                    includedGb: plan.includedGb, extraGb: plan.extraGb,
                    dataKeptUntil: plan.dataKeptUntil.map { Int64($0.timeIntervalSince1970 * 1000) }))
                model.fixture(planSnapshot)
                NativeCloudPlanSeam.current = { NativeCloudPlanSeam.liveFacts() }
                try render(shell("profile") { NativeProfileSettings(model: model, devicesFixture: fixture) }, "plan-\(name)-profile", dark, output)
                try render(shell(N.planID) { NativeCloudPlanPage(facts: plan) }, "plan-\(name)-page", dark, output)
            }
            NativeCloudPlanSeam.current = { nil }

            // Cloud: nothing waits; his 18 Nov state folded (one row) and with the details open.
            model.fixture(cloudSnapshot)
            NativeCloudSecrets.shared.fixture(page: fine)
            try render(shell(N.cloudID) { NativeCloudSettings(model: model) }, "cloud-calm", dark, output)
            NativeCloudSecrets.shared.fixture(page: gapsPage)
            try render(shell(N.cloudID) { NativeCloudSettings(model: model) }, "cloud-passwords-waiting", dark, output)
            try render(shell(N.cloudID) { NativeCloudSettings(model: model, fixtureDetailsOpen: true) }, "cloud-passwords-details", dark, output, size: tall)
            NativeCloudSecrets.shared.fixture(page: nil)
            model.fixture(snapshot)

            // A device's page keeps its place (the family's picture at 64 pt).
            try render(shell(N.devicePage(phone.id)) { NativeDevicePage(rowID: phone.id, account: model, fixture: fixture) }, "device-phone", dark, output)

            // File manager: the nine nameless tasks as one row; Memory; an empty place; a search with no match.
            let wide = CGSize(width: 1640, height: 760)
            manager.chooseShelf(kind: .tasks)
            try render(NativeCloudContentsPage(model: manager, live: false).background(DeckTokens.page), "files-tasks", dark, output, size: wide)
            manager.click(try XCTUnwrap(manager.rowKeys.last))
            try render(NativeCloudContentsPage(model: manager, live: false).background(DeckTokens.page), "files-tasks-selected", dark, output, size: wide)
            manager.clearSelection()
            manager.chooseShelf(kind: .memory)
            try render(NativeCloudContentsPage(model: manager, live: false).background(DeckTokens.page), "files-memory", dark, output, size: wide)
            empty.chooseShelf(kind: .artifacts)
            try render(NativeCloudContentsPage(model: empty, live: false).background(DeckTokens.page), "files-empty", dark, output, size: wide)
            manager.chooseShelf(kind: .tasks)
            manager.search = "zebra"
            try render(NativeCloudContentsPage(model: manager, live: false).background(DeckTokens.page), "files-no-match", dark, output, size: wide)
            manager.search = ""
        }

        // Nobody signed in: the Settings list's top row and the Profile page.
        model.fixture(.signedOut); model.fixtureUser(nil); model.fixtureProfile(nil)
        NativeCloudDisplayGate.shared.offer(true)
        for dark in [false, true] {
            try render(shell("profile") { NativeProfileSettings(model: model) }, "signed-out-profile", dark, output)
        }
        await NativeSettingsValues.shared.endOffscreenFixture()
    }

    /// The whole family in one picture: each kind at 28 pt (as in the list) and at 64 pt (a device's page), with its word.
    private func deviceFamily() -> some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(NativeDeviceModel.allCases, id: \.self) { model in
                VStack(spacing: 10) {
                    NativeDeviceGlyph(model: model, size: 28)
                    NativeDeviceGlyph(model: model, size: 64)
                    Text(model.word).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 58)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeckTokens.page)
    }

    /// The window's own title-bar band (28 pt) above the shell, as the real window draws it.
    private func shell<V: View>(_ id: String, @ViewBuilder _ page: @escaping () -> V) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)
            NativeSettingsShell(selection: .constant(id)) { _ in page() }
        }
        .background(DeckTokens.page)
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize = UISettingsReviewTests.size) throws {
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

/// What a fixture closure was called with.
@MainActor private final class Box<Value> { var all: [Value] = [] }

/// A wait that ends when the test opens it (the 5-second Undo, without the 5 seconds).
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async throws {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
