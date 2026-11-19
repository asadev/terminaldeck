import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Settings → Devices (owner, 14 Nov: "Just keep what actually matters, what we need to manage right now"). The ONE
/// place his devices are listed: every device that can reach this Mac, the account's and the ones connected before
/// accounts alike, as ordinary rows (icon, name, one state). Two switches above. The row's action sits behind its
/// small menu; a device that waits for his OK has a Trust button on the row. The connection history stays with the
/// `devices.page` tool. Owner, 14 Nov: Remove has ONE meaning, it signs that device out; signing in on it again brings
/// it back by itself. The row's action waits 5 seconds behind "Signing out… Undo" before it acts (no sheet).
struct NativeDevicesSettings: View {
    var account: NativeCloudAccount = .shared
    var reach: NativeReachAccount = .shared
    /// Pictures and tests: no service is touched, the reach switch and the old devices show as given.
    var fixture = false
    var fixtureReach: DevicesPage.Reach?
    var fixtureOld: [DevicesPage.OldDevice] = []
    @State private var feed: NativeDevicesFeed

    init(account: NativeCloudAccount = .shared, reach: NativeReachAccount = .shared, fixture: Bool = false,
         fixtureReach: DevicesPage.Reach? = nil, fixtureOld: [DevicesPage.OldDevice] = []) {
        self.account = account; self.reach = reach; self.fixture = fixture
        self.fixtureReach = fixtureReach; self.fixtureOld = fixtureOld
        _feed = State(initialValue: NativeDevicesFeed(account: account, reach: reach,
                                                      fixture: fixture ? NativeDevicesFixture(reach: fixtureReach, old: fixtureOld) : nil))
    }

    static let activeWindowMs: Int64 = 5 * 60_000
    /// An account device (phone, browser, another Mac): the Cloud ends its sign-in and it leaves every device's list;
    /// reach's removal ends its live connections to this Mac at once. Signing in on it again brings it back.
    static let signOutTitle = "Sign out this device"
    /// A device connected before accounts: revoked (a phone or browser) or forgotten (a computer this Mac reached).
    static let removeTitle = "Remove this device"
    static let waitingState = "Waiting for you"
    /// The icon column (fits the widest device symbol) and the menu column at the row's end: fixed, so every row's name
    /// starts at one left edge and every state ends at one right edge.
    static let iconColumn: CGFloat = 28
    static let menuColumn: CGFloat = 24

    /// One row of the list, keyed by the device itself (never by its place, which changes as "last seen" moves).
    struct Row: Identifiable, Equatable {
        enum Source: Equatable { case account(deviceId: String?), old(ref: String, source: DevicesPage.OldDevice.Source) }
        let id: String
        let name: String
        let symbol: String
        let isThisMac: Bool
        let lastSeenMs: Int64?
        let connectedNow: Bool
        let source: Source
        /// What kind of device the account says it is (nil for one connected before accounts).
        var kind: DevicesPage.Kind? = nil
        /// When the account says it was added.
        var addedMs: Int64? = nil
        /// Signed out by another device: its name and when (both or neither; small fixes item 3).
        var signedOutBy: String? = nil
        var signedOutAtMs: Int64? = nil
        /// The model the device reports about itself ("mac-mini", "MacBook Pro", "iPhone15,2" …); nil = it reports none.
        var reportedModel: String? = nil
        var canDisconnect: Bool {
            switch source {
            case .account(let id): return !isThisMac && id != nil
            case .old: return true
            }
        }
        /// The one action's true name: "Sign out this device" for an account device, "Remove this device" for an old one.
        var actionTitle: String {
            if case .old = source { return NativeDevicesSettings.removeTitle }
            return NativeDevicesSettings.signOutTitle
        }
    }

    /// The switch's one live line: Ready / Connecting… / Not reachable right now; nil while off.
    static func doorWord(_ reach: DevicesPage.Reach) -> String? {
        guard reach.on else { return nil }
        if reach.entitled == false { return "Not on for your account yet" }
        switch reach.entitled == nil ? .connecting : reach.door ?? .connecting {
        case .ready: return "Ready"
        case .connecting: return "Connecting…"
        case .notReachable: return "Not reachable right now"
        }
    }
    /// One state per row, in full: "This Mac", "Waiting for you", "Active now" (seen in the last five minutes, or
    /// connected now) or "Last seen <day, time>". A device's own page says it this way.
    static func state(_ row: Row, waiting: Bool = false, now: Date = Date()) -> String {
        if row.isThisMac { return "This Mac" }
        if waiting { return waitingState }
        if row.connectedNow { return "Active now" }
        guard let seen = row.lastSeenMs else { return "Not seen yet" }
        if Int64(now.timeIntervalSince1970 * 1000) - seen < activeWindowMs { return "Active now" }
        return BackendCloudPageWords.lastSeen(seen, now: now)
    }
    static func state(_ device: DevicesPage.AccountDevice, now: Date = Date()) -> String {
        state(row(device), now: now)
    }
    /// The list's short form (18 Nov, DESIGN-settings 2): a day, never a clock time: "Last seen today", "Last seen
    /// yesterday", "Last seen 14 Nov" (the year only when it is not this year).
    static func shortState(_ row: Row, waiting: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> String {
        if row.isThisMac { return "This Mac" }
        if waiting { return waitingState }
        if row.connectedNow { return "Active now" }
        guard let seen = row.lastSeenMs else { return "Not seen yet" }
        if Int64(now.timeIntervalSince1970 * 1000) - seen < activeWindowMs { return "Active now" }
        return "Last seen " + day(seen, now: now, calendar: calendar)
    }
    static func day(_ milliseconds: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        let style = Date.FormatStyle(timeZone: calendar.timeZone).day().month(.abbreviated)
        return date.formatted(calendar.isDate(date, equalTo: now, toGranularity: .year) ? style : style.year())
    }
    static func symbol(_ kind: DevicesPage.Kind) -> String {
        switch kind {
        case .mac: "laptopcomputer"
        case .pc: "pc"
        case .phone: "iphone.gen3"
        case .browser: "globe"
        }
    }
    static func name(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A device" : trimmed
    }
    /// SEAM (notes/review-20261118/LOGIC-HANDOFF.md, "device model"): the model a device reports about itself. No client
    /// sends one today and the Cloud's device list carries none, so this answers nil and the picture falls back to
    /// what the device's name and platform say. The logic job adds the field to the account's device and returns it here.
    static var reportedModel: @MainActor (DevicesPage.AccountDevice) -> String? = { _ in nil }
    static func row(_ device: DevicesPage.AccountDevice) -> Row {
        Row(id: "account:" + (device.deviceId ?? (device.isThisMac ? "this-mac" : name(device.name))), name: name(device.name),
            symbol: symbol(device.kind), isThisMac: device.isThisMac, lastSeenMs: device.lastSeenAtMs, connectedNow: false,
            source: .account(deviceId: device.deviceId), kind: device.kind, addedMs: device.addedAtMs,
            signedOutBy: device.signedOutBy, signedOutAtMs: device.signedOutAtMs, reportedModel: reportedModel(device))
    }
    static func row(_ device: DevicesPage.OldDevice) -> Row {
        Row(id: "old:" + device.ref, name: name(device.name), symbol: device.source == .machine ? "desktopcomputer" : "iphone.gen3",
            isThisMac: false, lastSeenMs: device.lastSeenAtMs.map { Int64($0) }, connectedNow: device.connected,
            source: .old(ref: device.ref, source: device.source))
    }
    /// Every device in one list: this Mac first, then the most recently seen (connected now counts as now).
    static func rows(account: [DevicesPage.AccountDevice], old: [DevicesPage.OldDevice], now: Date = Date()) -> [Row] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let all = account.map(row) + old.map(row)
        return all.enumerated().sorted { a, b in
            if a.element.isThisMac != b.element.isThisMac { return a.element.isThisMac }
            let sa = a.element.connectedNow ? nowMs : a.element.lastSeenMs ?? 0
            let sb = b.element.connectedNow ? nowMs : b.element.lastSeenMs ?? 0
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }
    static func rows(_ snapshot: CloudAccountSnapshot) -> [DevicesPage.AccountDevice] {
        DevicesPage.accountDevices(snapshot)
    }
    /// The row an action acts on, found again by its own id in the list as it is NOW (review 14 Nov, item 2): a list
    /// that re-sorted between drawing the menu and the press can never hand the action another device.
    static func target(_ id: String, in rows: [Row]) -> Row? { rows.first { $0.id == id } }
    /// "Ask me for each new device" only: a new device that can be trusted waits for him.
    static func waiting(_ row: Row, trust: [CloudDeviceTrustRow], askMode: Bool) -> CloudDeviceTrustRow? {
        guard askMode, case .account(let id?) = row.source,
              let found = trust.first(where: { $0.deviceId == id }), found.standing == .new, found.canBeTrusted, !found.removed else { return nil }
        return found
    }
    /// The Settings list's dot on Devices: some device waits for his OK.
    @MainActor static func somethingWaits(_ account: NativeCloudAccount = .shared) -> Bool {
        guard account.trustMode == .ask else { return false }
        return rows(account: DevicesPage.accountDevices(account.snapshot), old: []).contains {
            waiting($0, trust: account.snapshot.trust, askMode: true) != nil
        }
    }

    // MARK: ONE list (owner, 18 Nov, item 24: "we don't need this older one ... We need everything at one place. Older,
    // newer, how do you know what are older and what are newer? Just all here.")

    /// How many rows the list shows before "Show N more" (the rest opens in place).
    static let firstRows = 8
    static func moreTitle(_ count: Int) -> String { "Show \(count) more" }
    static let fewerTitle = "Show fewer"
    /// The list's ONE quiet action at its end (Decker, 18 Nov: he has many stale browser sign-ins): every other device
    /// and browser is signed out in one press, 5 seconds behind one Undo. This Mac stays signed in.
    static let signOutOthersTitle = "Sign out of all the others"
    static func signingOutOthers(_ count: Int) -> String { count == 1 ? "Signing out 1 other…" : "Signing out \(count) others…" }
    /// The rows that press acts on: everything but this Mac that can be signed out (or, connected before accounts, removed).
    static func others(_ rows: [Row]) -> [Row] { rows.filter { !$0.isThisMac && $0.canDisconnect } }
    /// Offered from two others on: one other device has its own "…".
    static func offersSignOutOthers(_ rows: [Row]) -> Bool { others(rows).count > 1 }
    /// The rows on show: all of them when open or when the list is short, else the first eight.
    static func shown(_ rows: [Row], open: Bool) -> [Row] {
        open || rows.count <= firstRows ? rows : Array(rows.prefix(firstRows))
    }
    static func isBrowser(_ row: Row) -> Bool {
        if row.kind == .browser { return true }
        let name = row.name.lowercased()
        return ["chrome on ", "safari on ", "firefox on ", "edge on ", "arc on ", "brave on ", "browser on "].contains { name.hasPrefix($0) }
    }

    /// What the device's NAME says it is ("Mac mini", "MacBook Pro", "iPhone", "Android phone"); nil = the name says nothing.
    static func nameKind(_ name: String) -> String? {
        let name = name.lowercased()
        let named: [(String, String)] = [("mac mini", "Mac mini"), ("macbook air", "MacBook Air"), ("macbook pro", "MacBook Pro"),
                                         ("macbook", "MacBook"), ("imac", "iMac"), ("mac studio", "Mac Studio"), ("mac pro", "Mac Pro"),
                                         ("iphone", "iPhone"), ("ipad", "iPad"), ("pixel", "Android phone"), ("android", "Android phone"),
                                         ("galaxy", "Android phone")]
        return named.first(where: { name.contains($0.0) })?.1
    }
    /// The kind as a person says it ("Mac mini", "MacBook Pro", "iPhone", "Android phone", "PC", "Browser"): what the
    /// device reports (the seam) wins over its name; a name that agrees with the report keeps its finer word
    /// ("MacBook Pro" for a reported MacBook).
    static func kindWord(_ row: Row) -> String {
        if isBrowser(row) { return "Browser" }
        let named = nameKind(row.name)
        if let model = NativeDeviceModel.from(reported: row.reportedModel) {
            if let named, NativeDeviceModel.from(reported: named) == model { return named }
            return model.word
        }
        if let named { return named }
        switch row.kind {
        case .mac: return "Mac"
        case .pc: return "PC"
        case .phone: return "Phone"
        case .browser: return "Browser"
        case nil:
            if case .old(_, let source) = row.source { return source == .machine ? "Computer" : "Phone" }
            return "Device"
        }
    }
    /// The name already says the kind ("iPhone 13 Pro Max" needs no "iPhone" under it).
    static func nameSays(_ kind: String, _ name: String) -> Bool { name.localizedCaseInsensitiveContains(kind) }
    /// The row's second line: "This Mac", "Active now", "Last seen 14 Nov"; the kind in front only when the name does not
    /// say it ("Android phone · Last seen 14 Nov" for "ASAD Pixel8").
    static func secondLine(_ row: Row, waiting: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> String {
        if row.isThisMac { return "This Mac" }
        if !waiting, let line = signedOutLine(row) { return line }
        let state = shortState(row, waiting: waiting, now: now, calendar: calendar)
        if waiting { return state }
        let kind = kindWord(row)
        return nameSays(kind, row.name) ? state : kind + " · " + state
    }
    /// Small fixes item 3: a device another device signed out says so on its second line, "Signed out from <device> on
    /// <date>", only when the Cloud gives both who and when; otherwise the row is as before.
    static func signedOutLine(_ row: Row) -> String? {
        guard let by = row.signedOutBy, !by.isEmpty, let at = row.signedOutAtMs, at > 0 else { return nil }
        return "Signed out from \(by) on \(NativeCloudTrustWords.day(at))"
    }

    // MARK: The Devices page (only where this copy has no Profile: Cloud cannot be used here)

    var body: some View {
        Group {
            if NativeCloudOffers.shows(.devices) {
        DeckSettingsScaffold(title: "Devices") {
            NativeThisMacSwitches(feed: feed)
            if !feed.rows.isEmpty {
                NativeDevicesGroup(feed: feed, title: "Your devices")
            }
            if !feed.signedIn, NativeCloudDisplayGate.shared.shows, case .signedOut(waiting: false) = account.signInStage {
                DeckSettingsGroup {
                    DeckSettingsRow("Sign in to see all your devices here.") {
                        Button("Sign in") { account.pressSignIn() }.disabled(fixture || account.busy)
                    }
                }
            }
            if let line = feed.notice { DeckSettingsGroup { DeckSettingsProblem(text: line, warn: false) } }
        }
        .task { await feed.start() }
        .onDisappear { feed.stop() }
    }
        }
    }
}

/// Pictures and tests: the reach switch and the devices connected before accounts as given; no service is touched.
struct NativeDevicesFixture {
    var reach: DevicesPage.Reach?
    var old: [DevicesPage.OldDevice] = []
}

/// What every page that lists devices reads (Profile's Devices group, a device's page, the Devices page):
/// the account's devices, the devices connected before accounts, the reach switch and the screen switch.
@MainActor @Observable
final class NativeDevicesFeed {
    let account: NativeCloudAccount
    let reach: NativeReachAccount
    let fixture: NativeDevicesFixture?
    let remote = RemoteSectionModel()
    let machines = MachinesHalfModel()
    var macScreenAllowed = NativeMacScreenSetting.allowed
    @ObservationIgnored private var started = false
    @ObservationIgnored private var watch: Task<Void, Never>?

    init(account: NativeCloudAccount = .shared, reach: NativeReachAccount = .shared, fixture: NativeDevicesFixture? = nil) {
        self.account = account; self.reach = reach; self.fixture = fixture
    }

    var isFixture: Bool { fixture != nil }
    var signedIn: Bool { MACHINESDevicesScreen.signedIn(account.snapshot.phase) }
    var reachNow: DevicesPage.Reach { fixture?.reach ?? reach.devicesReach }
    var oldDevices: [DevicesPage.OldDevice] {
        if let fixture { return fixture.old }
        return DevicesPage.oldDevices(devices: remote.state?.devices ?? [], connected: Set(remote.state?.connections.map(\.deviceId) ?? []),
                                      machines: machines.view.machines,
                                      online: Set(machines.view.links.filter { $0.phase == .online }.map(\.id)))
    }
    var rows: [NativeDevicesSettings.Row] {
        NativeDevicesSettings.rows(account: signedIn ? DevicesPage.accountDevices(account.snapshot) : [], old: oldDevices)
    }
    var busy: Bool { reach.busy || account.busy || remote.busy != nil || machines.busy }
    /// One plain line when something did not work (no codes).
    var notice: String? {
        guard !isFixture else { return nil }
        if let notice = remote.notice, !notice.ok { return notice.text }
        return machines.actionError ?? reach.problem
    }
    func waiting(_ row: NativeDevicesSettings.Row) -> CloudDeviceTrustRow? {
        NativeDevicesSettings.waiting(row, trust: account.snapshot.trust, askMode: account.trustMode == .ask)
    }

    func start() async {
        guard !isFixture, !started else { return }
        started = true
        account.refreshDevices()
        // A change made elsewhere (a tool, a phone's request, another window) shows while the page is open.
        watch = Task { [weak self] in
            while !Task.isCancelled {
                let now = NativeMacScreenSetting.allowed
                if let self, now != self.macScreenAllowed { self.macScreenAllowed = now }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        async let remoteStart: Void = remote.start()
        async let links: Void = machines.start()
        async let switchState: Void = reach.reload()
        _ = await (remoteStart, links, switchState)
    }
    func stop() {
        watch?.cancel(); watch = nil
        guard !isFixture, started else { return }
        started = false
        remote.stop(); machines.stop()
    }
    func setMacScreen(_ on: Bool) {
        macScreenAllowed = on
        if !isFixture { NativeMacScreenSetting.set(on) }
    }

    /// The row's one action for the device found again by its id, after 5 seconds behind "Signing out… Undo" (owner,
    /// 14 Nov). Account device: the Cloud ends its sign-in, then reach's removal cuts its live connections here. Device
    /// connected before accounts: revoked (a phone or browser) or forgotten (a computer this Mac reached), as before.
    func choose(_ id: String, with signOut: NativeDeviceSignOut) {
        guard !isFixture, let row = NativeDevicesSettings.target(id, in: rows), row.canDisconnect else { return }
        signOut.actions = .live(account: account, reach: reach)
        signOut.choose(row) { [remote, machines] in
            guard case .old(let ref, let source) = row.source else { return }
            let key = String(ref.split(separator: ":", maxSplits: 1).last ?? "")
            switch source {
            case .device: if let device = remote.state?.devices.first(where: { $0.id == key }) { remote.remove(device) }
            case .machine: if let machine = machines.view.machines.first(where: { $0.id == key }) { machines.forget(machine) }
            }
        }
    }
    /// One click, no sheet (review 14 Nov, item 5): the row as drawn now is trusted, through the page-press guard.
    func trust(_ id: String) {
        guard !isFixture, let row = NativeDevicesSettings.target(id, in: rows), let waiting = waiting(row) else { return }
        NativeCloudTrustSheets.trustNow(waiting, model: account)
    }
}

/// A device row's rename, in place (owner, 18 Nov, item 26: "We need to be able to edit, sign out or disconnect").
/// The name becomes a field in its row; Enter saves, Escape cancels; a small check shows for a moment when the Cloud
/// took the name, "Could not rename" as the row's second line when it did not.
@MainActor @Observable
final class NativeDeviceRowEdits {
    /// The row whose name is a field now, and its text.
    var renaming: String?
    var draft = ""
    private(set) var saving: String?
    /// The row that shows its small check (saved just now).
    private(set) var saved: String?
    private(set) var problems: [String: String] = [:]
    /// The name the Cloud took, until the list says it too.
    private(set) var names: [String: String] = [:]
    /// The Cloud's rename (device id, name). The live group hands in the account's; pictures and tests their own.
    @ObservationIgnored var send: @MainActor (String, String) async throws -> Void = { _, _ in }
    @ObservationIgnored private var checkTimer: Task<Void, Never>?
    @ObservationIgnored private var sends: [Task<Void, Never>] = []
    nonisolated static let checkShows: Duration = .milliseconds(1600)

    func name(_ row: NativeDevicesSettings.Row) -> String { names[row.id] ?? row.name }
    func begin(_ row: NativeDevicesSettings.Row) {
        guard NativeDevicePage.renameTarget(row) != nil else { return }
        renaming = row.id; draft = name(row); problems[row.id] = nil
    }
    func cancel() { renaming = nil; draft = "" }
    /// Enter, or the field losing the keyboard: the typed name goes to the Cloud; an empty or unchanged one changes nothing.
    func commit(_ row: NativeDevicesSettings.Row) {
        guard renaming == row.id else { return }
        renaming = nil
        guard let target = NativeDevicePage.renameTarget(row), let typed = CloudDeviceRename.cleaned(draft), typed != name(row) else { return }
        saving = row.id
        let id = row.id, send = send
        sends.append(Task { [weak self] in
            var failed = false
            do { try await send(target, typed) } catch { failed = true }
            guard let self else { return }
            self.saving = nil
            if failed { self.problems[id] = NativeDevicePage.renameFailed } else { self.names[id] = typed; self.showCheck(id) }
        })
    }
    /// Tests: every rename sent has answered.
    func settle() async { for task in sends { await task.value } }
    private func showCheck(_ id: String) {
        saved = id
        checkTimer?.cancel()
        checkTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.checkShows)
            guard !Task.isCancelled else { return }
            self?.saved = nil
        }
    }
    /// Pictures: a row drawn while it is being renamed, or right after its name was saved.
    func fixture(renaming id: String? = nil, draft: String = "", saved: String? = nil) {
        renaming = id; self.draft = draft; self.saved = saved
    }
}

/// One device as a row (18 Nov, DESIGN-settings 2): the 28 pt picture of its REAL kind, its name, one short line
/// ("This Mac", "Active now", "Last seen 14 Nov") and ONE quiet "…" where the row is managed in place: Rename, Sign out
/// (this Mac: Rename only). A click on the row itself opens the device's page, as before.
struct NativeDeviceRow: View {
    let row: NativeDevicesSettings.Row
    let feed: NativeDevicesFeed
    let signOut: NativeDeviceSignOut
    @Bindable var edits: NativeDeviceRowEdits
    @Environment(\.deckSettingsOpen) private var open
    @FocusState private var fieldFocused: Bool
    @State private var menuOpen = false
    static let height: CGFloat = 52
    static let moreBox: CGFloat = 26
    /// Where the row's text starts: the side padding, the picture and the gap after it. The group's hairlines start here.
    static let textInset: CGFloat = DeckSettingsLook.rowPadding + DeckSettingsLook.deviceGlyph + DeckTokens.Spacing.s8 + 2
    /// The name line keeps one height as text and as a field, so the row never moves when Rename is chosen.
    static let nameLine: CGFloat = 20
    static let renameTitle = "Rename"
    static let trustTitle = "Trust"
    /// The action's true name without "this device" ("Sign out", and for a device connected before accounts the other
    /// word): in a row's own menu the row is the device.
    static func short(_ title: String) -> String { title.replacingOccurrences(of: " this device", with: "") }

    /// The row's "…" items, in order.
    enum Action: Hashable { case trust, rename, signOut, remove }
    static func actions(_ row: NativeDevicesSettings.Row, waiting: Bool) -> [Action] {
        var made: [Action] = []
        if waiting { made.append(.trust) }
        if NativeDevicePage.renameTarget(row) != nil { made.append(.rename) }
        if row.canDisconnect {
            if case .old = row.source { made.append(.remove) } else { made.append(.signOut) }
        }
        return made
    }
    static func title(_ action: Action) -> String {
        switch action {
        case .trust: trustTitle
        case .rename: renameTitle
        case .signOut: short(NativeDevicesSettings.signOutTitle)
        case .remove: short(NativeDevicesSettings.removeTitle)
        }
    }

    static func symbol(_ action: Action) -> String {
        switch action {
        case .trust: "checkmark.shield"
        case .rename: "pencil"
        case .signOut: "rectangle.portrait.and.arrow.right"
        case .remove: "minus.circle"
        }
    }

    var body: some View {
        let waiting = feed.waiting(row) != nil
        let pending = signOut.pending.contains(row.id)
        let editing = edits.renaming == row.id
        HStack(spacing: 0) {
            if editing {
                label(waiting: waiting, pending: pending, editing: true)
            } else {
                Button { open(NativeSettingsNavigation.devicePage(row.id)) } label: {
                    label(waiting: waiting, pending: pending, editing: false).contentShape(.rect)
                }
                .buttonStyle(DeckSettingsPressStyle())
                .accessibilityLabel(edits.name(row) + ", " + NativeDevicesSettings.secondLine(row, waiting: waiting))
            }
            trailing(waiting: waiting, pending: pending, editing: editing)
                .padding(.leading, DeckTokens.Spacing.s4)
                .padding(.trailing, DeckSettingsLook.rowPadding - 3)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        // Clicking away from the field saves what was typed, as Enter does.
        .onChange(of: fieldFocused) { _, focused in if !focused, edits.renaming == row.id { edits.commit(row) } }
    }

    private func label(waiting: Bool, pending: Bool, editing: Bool) -> some View {
        HStack(spacing: DeckTokens.Spacing.s8 + 2) {
            NativeDeviceGlyph(model: NativeDeviceModel.of(row), size: DeckSettingsLook.deviceGlyph)
            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    NativeSessionTextField("Name", text: Binding(get: { edits.draft }, set: { edits.draft = String($0.prefix(CloudDeviceRename.maxName)) }))
                        .textFieldStyle(.plain)
                        .sessionFocused($fieldFocused)
                        .onSubmit { edits.commit(row) }
                        .onExitCommand { edits.cancel() }
                        .font(DeckSettingsLook.rowTitle)
                        .frame(height: NativeProfileQuietField.line)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: 260, minHeight: Self.nameLine, maxHeight: Self.nameLine, alignment: .leading)
                        .background(DeckSettingsQuietField.fill, in: RoundedRectangle(cornerRadius: DeckSettingsQuietField.radius))
                        // The fill grows around the text: the name itself stays where it was.
                        .padding(.leading, -5)
                        .onAppear { fieldFocused = true }
                        .accessibilityLabel("Device name")
                } else {
                    HStack(spacing: 6) {
                        Text(edits.name(row)).font(DeckSettingsLook.rowTitle).lineLimit(1).truncationMode(.tail)
                        if edits.saving == row.id {
                            ProgressView().controlSize(.mini)
                        } else if edits.saved == row.id {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DeckTokens.good)
                                .accessibilityLabel("Saved")
                        }
                    }
                    .frame(height: Self.nameLine)
                }
                second(waiting: waiting, pending: pending)
            }
            Spacer(minLength: DeckTokens.Spacing.s8)
        }
        .padding(.leading, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
    }

    /// The second line: the sign-out that is waiting or did not happen, a rename that did not happen, else the state.
    @ViewBuilder private func second(waiting: Bool, pending: Bool) -> some View {
        let problem = signOut.notes[row.id] ?? edits.problems[row.id]
        Text(pending ? NativeDeviceSignOut.pendingWord(row) : problem ?? NativeDevicesSettings.secondLine(row, waiting: waiting))
            .font(DeckSettingsLook.rowSecond)
            .foregroundStyle(!pending && (problem != nil || waiting) ? DeckTokens.warn : Color.secondary)
            .lineLimit(problem != nil && !pending ? 2 : 1).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func trailing(waiting: Bool, pending: Bool, editing: Bool) -> some View {
        if pending {
            Button("Undo") { signOut.undo(row.id) }.controlSize(.small).accessibilityIdentifier("devices.undo")
        } else if !editing {
            let actions = Self.actions(row, waiting: waiting)
            if !actions.isEmpty {
                // The plain three dots of the Settings pages (13 pt, secondary); the menu is the app's own DeckMenu.
                Button { menuOpen.toggle() } label: {
                    Image(systemName: NativeSettingsMoreGlyph.glyph).font(.system(size: NativeSettingsMoreGlyph.size)).foregroundStyle(.secondary)
                        .frame(width: Self.moreBox, height: Self.moreBox).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More for \(edits.name(row))")
                .deckMenu(isPresented: $menuOpen, alignment: .trailing) {
                    NativeDeviceRowMenu(actions: actions) { perform($0) }
                }
            }
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .trust: feed.trust(row.id)
        case .rename: edits.begin(row)
        case .signOut, .remove: feed.choose(row.id, with: signOut)
        }
    }
}

/// What a device row's "…" opens, in the app's shared menu (`DeckMenu`): Trust (only while it waits), Rename, then the
/// one red row (Sign out; for a device connected before accounts, Remove).
struct NativeDeviceRowMenu: View {
    let actions: [NativeDeviceRow.Action]
    let perform: (NativeDeviceRow.Action) -> Void
    var body: some View {
        ForEach(actions, id: \.self) { action in
            DeckMenuRow(NativeDeviceRow.title(action), symbol: NativeDeviceRow.symbol(action),
                        role: action == .signOut || action == .remove ? .destructive : .normal) { perform(action) }
        }
    }
}

/// The "Devices" group: ONE list of everything signed in, this Mac first, then most recently seen first. A long list
/// shows its first eight rows and opens the rest in place ("Show 5 more" / "Show fewer").
struct NativeDevicesGroup: View {
    let feed: NativeDevicesFeed
    var title: String = "Devices"
    /// Pictures: the rest of a long list drawn open, and a row drawn mid-rename or just saved.
    var fixtureOpen = false
    var fixtureEdits: NativeDeviceRowEdits? = nil
    /// Pictures: the last row drawn while that many sign-outs wait behind Undo.
    var fixtureSigningOut: Int? = nil
    @State private var open = false
    @State private var signOut = NativeDeviceSignOut()
    @State private var edits = NativeDeviceRowEdits()

    var body: some View {
        Group {
            if NativeCloudOffers.shows(.devices) {
        let rows = feed.rows
        let isOpen = open || fixtureOpen
        let rowEdits = fixtureEdits ?? self.edits
        DeckSettingsGroup(title, separatorInset: NativeDeviceRow.textInset) {
            ForEach(NativeDevicesSettings.shown(rows, open: isOpen)) { row in
                NativeDeviceRow(row: row, feed: feed, signOut: signOut, edits: rowEdits)
            }
            if rows.count > NativeDevicesSettings.firstRows {
                NativeDevicesMoreRow(count: rows.count - NativeDevicesSettings.firstRows, open: isOpen) { open.toggle() }
            }
            if NativeDevicesSettings.offersSignOutOthers(rows) {
                NativeDevicesSignOutOthersRow(waiting: fixtureSigningOut ?? signOut.pending.count) {
                    for row in NativeDevicesSettings.others(rows) { feed.choose(row.id, with: signOut) }
                } undo: { signOut.cancelAll() }
            }
            if let done = signOut.doneLine { DeckSettingsProblem(text: done, warn: false) }
        }
        .onAppear {
            guard !feed.isFixture else { return }
            let account = feed.account
            rowEdits.send = { try await account.renameDevice($0, name: $1) }
        }
        // Leaving the page cancels a sign-out still waiting behind its Undo: it never fires later by itself.
        .onDisappear { signOut.cancelAll() }
        }
    }
    }
}

/// The list's last row: "Sign out of all the others", quiet (secondary ink, no red, no border). Pressed, it says how many
/// are being signed out, with ONE Undo for all of them, for 5 seconds.
struct NativeDevicesSignOutOthersRow: View {
    /// How many sign-outs wait behind Undo right now (two or more: this row shows them).
    let waiting: Int
    let action: () -> Void
    let undo: () -> Void
    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s8) {
            if waiting > 1 {
                Text(NativeDevicesSettings.signingOutOthers(waiting)).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                Spacer(minLength: DeckTokens.Spacing.s8)
                Button("Undo", action: undo).controlSize(.small).accessibilityIdentifier("devices.undo-all")
            } else {
                Button(action: action) {
                    Text(NativeDevicesSettings.signOutOthersTitle).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: NativeDevicesMoreRow.height, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, NativeDeviceRow.textInset).padding(.trailing, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: NativeDevicesMoreRow.height, alignment: .leading)
    }
}

/// The list's last row while it is long: "Show 5 more" (the rest opens in place), then "Show fewer".
struct NativeDevicesMoreRow: View {
    let count: Int
    let open: Bool
    let action: () -> Void
    static let height: CGFloat = 40
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(open ? NativeDevicesSettings.fewerTitle : NativeDevicesSettings.moreTitle(count))
                    .font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor)).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .padding(.leading, NativeDeviceRow.textInset).padding(.trailing, DeckSettingsLook.rowPadding)
            .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(DeckSettingsPressStyle())
    }
}

/// This Mac's own switches (they say what this Mac allows): they sit at the top of This Mac's page, and on the Devices
/// page where this copy has no Profile.
struct NativeThisMacSwitches: View {
    let feed: NativeDevicesFeed
    var withTrust = false
    var body: some View {
        let reachNow = feed.reachNow
        DeckSettingsGroup {
            // The switch that lets his devices open this Mac stays with a free account (19 Nov free plan).
            if NativeCloudOffers.shows(.devices), feed.signedIn, feed.fixture?.reach != nil || feed.reach.devicesReach.available {
                DeckSettingsRow(DevicesPage.settingTitle, info: DevicesPage.settingOnDetail + "\n\n" + DevicesPage.settingOffDetail,
                                state: NativeDevicesSettings.doorWord(reachNow),
                                stateColor: reachNow.door == .notReachable ? DeckTokens.warn : .secondary) {
                    Toggle(DevicesPage.settingTitle, isOn: Binding(get: { reachNow.on }, set: { on in if !feed.isFixture { feed.reach.setEnabled(on) } }))
                        .toggleStyle(.switch).controlSize(.small).disabled(feed.reach.busy)
                        .accessibilityIdentifier("devices.setting")
                }
            }
            DeckSettingsToggleRow(NativeMacScreenSetting.title, info: NativeMacScreenSetting.detail,
                                  isOn: Binding(get: { feed.macScreenAllowed }, set: { feed.setMacScreen($0) }))
                .accessibilityIdentifier("devices.access.macScreen")
            if withTrust {
                // Owner, 14 Nov: trust is one switch (on = automatically with my account, off = ask for each device).
                let model = feed.account
                DeckSettingsToggleRow(NativeCloudSettings.trustSwitchTitle,
                                      info: NativeCloudSettings.trustModeNote(model.trustMode),
                                      isOn: Binding(get: { NativeCloudSettings.trustSwitchOn(model.trustMode) }, set: { on in
                                          guard !feed.isFixture else { return }
                                          NativeCloudSheetGuard.shared.pagePress(model: model) { model.changeTrustMode(NativeCloudSettings.trustMode(switchOn: on)) }
                                      }))
            }
        }
    }
}

/// A device's own page: its picture, name and kind, when it was seen and added, and "Sign out this device" (5 seconds
/// behind Undo). This Mac's page holds this Mac's switches instead. A device waiting for his OK has Trust here.
struct NativeDevicePage: View {
    let rowID: String
    var account: NativeCloudAccount = .shared
    var fixture: NativeDevicesFixture?
    @State private var feed: NativeDevicesFeed
    @State private var signOut = NativeDeviceSignOut()
    /// The Name row's text while he edits it; the name the Cloud took (until the list says it too); its one error.
    @State private var nameDraft: String?
    @State private var renamed: String?
    @State private var renameProblem: String?
    @State private var renaming = false

    init(rowID: String, account: NativeCloudAccount = .shared, fixture: NativeDevicesFixture? = nil) {
        self.rowID = rowID; self.account = account; self.fixture = fixture
        _feed = State(initialValue: NativeDevicesFeed(account: account, fixture: fixture))
    }

    static let renameFailed = "Could not rename"
    /// The Cloud id a row is renamed by: account devices only (an old pairing has no name in the Cloud).
    static func renameTarget(_ row: NativeDevicesSettings.Row) -> String? {
        if case .account(let id) = row.source, let id, !id.isEmpty { return id }
        return nil
    }

    var body: some View {
        Group {
            if NativeCloudOffers.shows(.devices) {
        let listed = NativeDevicesSettings.target(rowID, in: feed.rows)
        let row = listed.map { NativeDevicesSettings.Row(id: $0.id, name: renamed ?? $0.name, symbol: $0.symbol, isThisMac: $0.isThisMac,
                                                         lastSeenMs: $0.lastSeenMs, connectedNow: $0.connectedNow, source: $0.source,
                                                         kind: $0.kind, addedMs: $0.addedMs, reportedModel: $0.reportedModel) }
        DeckSettingsScaffold(title: row?.name ?? "Device") {
            if let row {
                header(row)
                let waiting = feed.waiting(row)
                DeckSettingsGroup {
                    if let target = Self.renameTarget(row) {
                        DeckSettingsRow("Name", state: renaming ? "Saving…" : nil) {
                            NativeSessionTextField("Name", text: Binding(get: { nameDraft ?? row.name }, set: { nameDraft = String($0.prefix(CloudDeviceRename.maxName)) }))
                                .textFieldStyle(.plain)
                                .onSubmit { rename(target, from: row.name) }
                                .multilineTextAlignment(.trailing).frame(width: 220)
                                .foregroundStyle(.secondary)
                                .disabled(feed.isFixture || renaming)
                                .accessibilityLabel("Device name")
                        }
                        if let renameProblem { DeckSettingsProblem(text: renameProblem) }
                    }
                    DeckSettingsRow("Kind", state: NativeDevicesSettings.kindWord(row))
                    if !row.isThisMac {
                        DeckSettingsRow("Seen", state: NativeDevicesSettings.state(row, waiting: false),
                                        stateColor: .secondary)
                    }
                    if let added = row.addedMs, added > 0 {
                        DeckSettingsRow("Added", state: NativeCloudTrustWords.day(added))
                    }
                    if waiting != nil {
                        DeckSettingsRow(NativeDevicesSettings.waitingState, stateColor: DeckTokens.warn) {
                            Button("Trust") { feed.trust(row.id) }.disabled(feed.isFixture || feed.account.busy)
                        }
                    }
                }
                if row.isThisMac {
                    NativeThisMacSwitches(feed: feed, withTrust: feed.signedIn && NativeCloudDisplayGate.shared.shows)
                    let ask = feed.account.trustMode == .ask
                    if ask, let code = feed.account.snapshot.trust.first(where: { $0.standing == .thisMac && !$0.stale })?.code {
                        DeckSettingsGroup {
                            DeckSettingsButtonRow(title: "Show this Mac's code…") { NativeCloudTrustSheets.showOwnCode(code) }
                        }
                    }
                }
                if row.canDisconnect {
                    DeckSettingsGroup {
                        if signOut.pending.contains(row.id) {
                            DeckSettingsRow(NativeDeviceSignOut.pendingWord(row)) {
                                Button("Undo") { signOut.undo(row.id) }.accessibilityIdentifier("devices.undo")
                            }
                        } else {
                            // SW-3: an action he can press is full-strength red; a picture's fixture makes the press inert
                            // (`choose` does nothing there), never a dimmed control.
                            DeckSettingsButtonRow(title: row.actionTitle, role: .destructive) { feed.choose(row.id, with: signOut) }
                                .disabled(feed.busy)
                        }
                        if let note = signOut.notes[row.id] { DeckSettingsProblem(text: note) }
                    }
                }
            } else {
                DeckSettingsGroup { DeckSettingsProblem(text: signOut.doneLine ?? "This device is no longer listed.", warn: false) }
            }
        }
        .task { await feed.start() }
        // Leaving the page cancels a sign-out still waiting behind its Undo: it never fires later by itself.
        .onDisappear { signOut.cancelAll(); feed.stop() }
            }
        }
    }

    /// Enter in the Name row: the Cloud renames the device; anything but its ok shows the old name again and one
    /// orange line.
    private func rename(_ deviceId: String, from old: String) {
        guard let typed = nameDraft.flatMap(CloudDeviceRename.cleaned), typed != old else { nameDraft = nil; return }
        renaming = true; renameProblem = nil
        Task {
            defer { renaming = false }
            do {
                try await account.renameDevice(deviceId, name: typed)
                renamed = typed; nameDraft = nil
            } catch {
                nameDraft = nil; renamed = nil
                renameProblem = Self.renameFailed
            }
        }
    }

    private func header(_ row: NativeDevicesSettings.Row) -> some View {
        VStack(spacing: DeckTokens.Spacing.s4) {
            NativeDeviceGlyph(model: NativeDeviceModel.of(row), size: 64)
                .frame(height: 72)
            Text(row.name).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(row.isThisMac ? "This Mac" : NativeDevicesSettings.kindWord(row)).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// "Sign out this device" with its 5-second Undo (owner, 14 Nov). A choice waits `undoDelay` with "Signing out… Undo"
/// on its row, then acts once. Undo, leaving the page (`cancelAll` from `onDisappear`) and quitting (the app's
/// will-terminate notice) cancel it; nothing is saved, so it can never fire later by itself.
@MainActor @Observable
final class NativeDeviceSignOut {
    /// What the action does for an account device; tests hand in their own.
    struct Actions {
        /// The Cloud ends the device's sign-in (`POST /devices/remove`). Throws `BackendDeviceSignOutRefusal` or a failure.
        var signOut: @MainActor (String) async throws -> BackendDeviceSignOutOutcome
        /// Reach's removal: its live connections to this Mac end at once and the Cloud is told. Throws when it could
        /// not be done (reach not set up here, the Cloud not told).
        var cut: @MainActor (String) async throws -> Void
        static var none: Actions { Actions(signOut: { _ in throw BackendDeviceSignOutRefusal.notSignedIn }, cut: { _ in }) }
        static func live(account: NativeCloudAccount, reach: NativeReachAccount) -> Actions {
            Actions(signOut: { try await account.signOutDevice($0) }, cut: { try await reach.cutSignedOut($0) })
        }
        /// The whole sign-out, for the row (after its Undo) and the tool (after its approval): the Cloud first, then
        /// reach. A device the Cloud revoked is signed out whatever reach answers (its failure only logged; the Cloud's
        /// own push carries the removal to every Mac). A device the Cloud does not list (a browser's reach key,
        /// DEVICE-SIGNOUT-2) is signed out only by reach's removal reaching the Cloud: its failure is thrown.
        @discardableResult
        @MainActor func signOutBoth(_ deviceId: String) async throws -> BackendDeviceSignOutOutcome {
            let outcome = try await signOut(deviceId)
            if outcome == .notAnAccountDevice { try await cut(deviceId); return outcome }
            do { try await cut(deviceId) }
            catch { NativeCloudAccount.log("devices: signed-out device's reach removal not finished here: \(type(of: error))") }
            return outcome
        }
    }

    nonisolated static let undoDelay: Duration = .seconds(5)
    /// Lost-device design B1: the new service signs out a device that keeps the saved-passwords key at once (the key then
    /// changes by itself on his other Macs). Only a Cloud that has not been updated yet still refuses it.
    nonisolated static let holdsKeyLine = "Not signed out yet: Cloud needs its next update to sign out a device that keeps your saved-passwords key. Nothing was changed; try again later."
    nonisolated static let failedLine = "Could not sign it out. Try again."
    static func pendingWord(_ row: NativeDevicesSettings.Row) -> String {
        if case .old = row.source { return "Removing…" }
        return "Signing out…"
    }

    /// Rows showing "Signing out… Undo" now.
    private(set) var pending: Set<String> = []
    /// One plain line under a row whose sign-out did not happen (no codes).
    private(set) var notes: [String: String] = [:]
    /// The one result line after a sign-out went through (lost-device service: his browser sign-ins ended too).
    private(set) var doneLine: String?
    nonisolated static let browsersEndedLine = "Signed out. Your browser sign-ins were ended too."
    @ObservationIgnored var actions: Actions
    private let wait: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var started: [Task<Void, Never>] = []
    @ObservationIgnored private var quitWatch: (any NSObjectProtocol)?

    init(actions: Actions = .none, wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.actions = actions
        self.wait = wait
        quitWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAll() }
        }
    }
    isolated deinit { if let quitWatch { NotificationCenter.default.removeObserver(quitWatch) } }

    /// The row's action was chosen: it waits behind Undo, then acts. `removeOld` is what an old device's Remove does.
    func choose(_ row: NativeDevicesSettings.Row, removeOld: @escaping @MainActor @Sendable () -> Void = {}) {
        guard row.canDisconnect, !row.isThisMac, timers[row.id] == nil else { return }
        let id = row.id
        pending.insert(id); notes[id] = nil
        let wait = self.wait
        let timer = Task { [weak self] in
            do { try await wait(Self.undoDelay) } catch { return }
            guard !Task.isCancelled, let self, self.pending.contains(id) else { return }
            self.pending.remove(id); self.timers[id] = nil
            await self.act(row, removeOld: removeOld)
        }
        timers[id] = timer
        started.append(timer)
    }
    func undo(_ id: String) {
        timers[id]?.cancel(); timers[id] = nil
        pending.remove(id)
    }
    func cancelAll() { for id in Array(pending) + Array(timers.keys) { undo(id) } }
    /// Tests: every chosen action has finished or was cancelled.
    func settle() async { for task in started { await task.value } }

    private func act(_ row: NativeDevicesSettings.Row, removeOld: @MainActor () -> Void) async {
        switch row.source {
        case .account(let deviceId?):
            do { doneLine = try await actions.signOutBoth(deviceId) == .signedOutBrowsersEnded ? Self.browsersEndedLine : nil }
            catch BackendDeviceSignOutRefusal.holdsSavedPasswordsKey { notes[row.id] = Self.holdsKeyLine }
            catch BackendDeviceSignOutRefusal.thisMac { return }
            catch { notes[row.id] = Self.failedLine }
        case .account(nil):
            return
        case .old:
            removeOld()
        }
    }
}
