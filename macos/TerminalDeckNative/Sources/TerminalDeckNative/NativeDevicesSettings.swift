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
    /// One state per row: "This Mac", "Waiting for you", "Active now" (seen in the last five minutes, or connected
    /// now) or "Last seen <when>".
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
    static func row(_ device: DevicesPage.AccountDevice) -> Row {
        Row(id: "account:" + (device.deviceId ?? (device.isThisMac ? "this-mac" : name(device.name))), name: name(device.name),
            symbol: symbol(device.kind), isThisMac: device.isThisMac, lastSeenMs: device.lastSeenAtMs, connectedNow: false,
            source: .account(deviceId: device.deviceId), kind: device.kind, addedMs: device.addedAtMs,
            signedOutBy: device.signedOutBy, signedOutAtMs: device.signedOutAtMs)
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

    // MARK: Which devices are listed where (owner, 15 Nov, item 24)

    /// A device not seen for longer than this is not in the main list (it moves behind "Older and browser sign-ins").
    static let olderAfterMs: Int64 = 30 * 86_400_000
    /// The two lists: the devices that matter, and the quiet "Older and browser sign-ins". Nothing is signed out by this.
    struct Groups: Equatable {
        let main: [Row]
        let older: [Row]
    }
    /// THE RULE, in order:
    /// 1. This Mac: always in the main list.
    /// 2. A browser sign-in (the account says "Browser", or its name reads "Chrome / Safari / Firefox / Edge / Arc / Brave
    ///    on …"): older list.
    /// 3. A simulator or emulator (its name says so): older list.
    /// 4. Not connected now and last seen more than 30 days ago: older list. A device connected before accounts that was
    ///    never seen at all: older list. An account device not seen yet (just signed in): main list.
    /// 5. The same device twice (same name, same kind, case and spaces ignored): the most recently seen stays, the
    ///    others go to the older list.
    /// Everything else (this Mac, his other computers, his phones): main list, once each, most recently seen first.
    static func groups(_ rows: [Row], now: Date = Date()) -> Groups {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var main: [Row] = []
        var older: [Row] = []
        var seen = Set<String>()
        for row in rows { // `rows` is already this Mac first, then most recently seen first
            if row.isThisMac { main.append(row); seen.insert(sameKey(row)); continue }
            if isBrowser(row) || isTestDevice(row) { older.append(row); continue }
            let at = row.connectedNow ? nowMs : row.lastSeenMs
            if let at, nowMs - at > olderAfterMs { older.append(row); continue }
            if at == nil, case .old = row.source { older.append(row); continue }
            let key = sameKey(row)
            if seen.contains(key) { older.append(row); continue }
            seen.insert(key)
            main.append(row)
        }
        return Groups(main: main, older: older)
    }
    static func isBrowser(_ row: Row) -> Bool {
        if row.kind == .browser { return true }
        let name = row.name.lowercased()
        return ["chrome on ", "safari on ", "firefox on ", "edge on ", "arc on ", "brave on ", "browser on "].contains { name.hasPrefix($0) }
    }
    static func isTestDevice(_ row: Row) -> Bool {
        let name = row.name.lowercased()
        return name.contains("emulator") || name.contains("simulator")
    }
    private static func sameKey(_ row: Row) -> String {
        row.name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") + "|" + kindWord(row)
    }

    /// The kind as a person says it ("Mac mini", "MacBook Pro", "iPhone", "Android phone", "PC", "Browser").
    static func kindWord(_ row: Row) -> String {
        let name = row.name.lowercased()
        if isBrowser(row) { return "Browser" }
        let named: [(String, String)] = [("mac mini", "Mac mini"), ("macbook air", "MacBook Air"), ("macbook pro", "MacBook Pro"),
                                         ("macbook", "MacBook"), ("imac", "iMac"), ("mac studio", "Mac Studio"), ("mac pro", "Mac Pro"),
                                         ("iphone", "iPhone"), ("ipad", "iPad"), ("pixel", "Android phone"), ("android", "Android phone"),
                                         ("galaxy", "Android phone")]
        if let hit = named.first(where: { name.contains($0.0) }) { return hit.1 }
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
    /// The 28 pt picture of its kind.
    static func glyph(_ row: Row) -> String {
        switch kindWord(row) {
        case "Mac mini": return "macmini"
        case "Mac Studio": return "macstudio"
        case "Mac Pro": return "macpro.gen3"
        case "iMac": return "desktopcomputer"
        case "MacBook", "MacBook Air", "MacBook Pro", "Mac": return "laptopcomputer"
        case "iPhone": return "iphone"
        case "iPad": return "ipad"
        case "Android phone": return "smartphone"
        case "Phone": return "iphone.gen3"
        case "PC": return "pc"
        case "Browser": return "globe"
        default: return row.symbol
        }
    }
    /// The row's second line: "This Mac", "MacBook Pro · Active now", "iPhone · Last seen Today, 2:23 AM".
    static func secondLine(_ row: Row, waiting: Bool = false, now: Date = Date()) -> String {
        if row.isThisMac { return "This Mac" }
        if !waiting, let line = signedOutLine(row) { return line }
        return kindWord(row) + " · " + state(row, waiting: waiting, now: now)
    }
    /// Small fixes item 3: a device another device signed out says so on its second line, "Signed out from <device> on
    /// <date>", only when the Cloud gives both who and when; otherwise the row is as before.
    static func signedOutLine(_ row: Row) -> String? {
        guard let by = row.signedOutBy, !by.isEmpty, let at = row.signedOutAtMs, at > 0 else { return nil }
        return "Signed out from \(by) on \(NativeCloudTrustWords.day(at))"
    }
    static func olderTitle(_ count: Int) -> String { "Older and browser sign-ins (\(count))" }
    static let signOutAllTitle = "Sign out all of these"

    // MARK: The Devices page (only where this copy has no Profile: Cloud cannot be used here)

    var body: some View {
        let groups = feed.groups
        DeckSettingsScaffold(title: "Devices") {
            NativeThisMacSwitches(feed: feed)
            if !groups.main.isEmpty || !groups.older.isEmpty {
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

/// Pictures and tests: the reach switch and the devices connected before accounts as given; no service is touched.
struct NativeDevicesFixture {
    var reach: DevicesPage.Reach?
    var old: [DevicesPage.OldDevice] = []
}

/// What every page that lists devices reads (Profile's Devices group, a device's page, the older list, the Devices page):
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
    var groups: NativeDevicesSettings.Groups { NativeDevicesSettings.groups(rows) }
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

/// One device as a row (Apple's device list): the 28 pt picture of its kind, its name, "This Mac" or its kind and when
/// it was seen, and a chevron; the row opens the device's page.
struct NativeDeviceRow: View {
    let row: NativeDevicesSettings.Row
    var waiting = false
    @Environment(\.deckSettingsOpen) private var open
    var body: some View {
        DeckSettingsLinkRow(title: row.name, subtitle: NativeDevicesSettings.secondLine(row, waiting: waiting),
                            leading: AnyView(Image(systemName: NativeDevicesSettings.glyph(row))
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(.primary)
                                .frame(width: DeckSettingsLook.deviceGlyph, height: DeckSettingsLook.deviceGlyph)),
                            value: waiting ? NativeDevicesSettings.waitingState : nil, valueColor: DeckTokens.warn,
                            minHeight: 52) {
            open(NativeSettingsNavigation.devicePage(row.id))
        }
    }
}

/// The "Devices" group: one row per device that matters, then the one quiet row "Older and browser sign-ins (7) ›".
struct NativeDevicesGroup: View {
    let feed: NativeDevicesFeed
    var title: String = "Devices"
    @Environment(\.deckSettingsOpen) private var open
    var body: some View {
        let groups = feed.groups
        DeckSettingsGroup(title) {
            ForEach(groups.main) { row in NativeDeviceRow(row: row, waiting: feed.waiting(row) != nil) }
            if !groups.older.isEmpty {
                DeckSettingsLinkRow(title: NativeDevicesSettings.olderTitle(groups.older.count), symbol: "clock.arrow.circlepath", tint: .gray) {
                    open(NativeSettingsNavigation.olderDevicesID)
                }
            }
        }
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
            if feed.signedIn, feed.fixture?.reach != nil || feed.reach.devicesReach.available {
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
        let listed = NativeDevicesSettings.target(rowID, in: feed.rows)
        let row = listed.map { NativeDevicesSettings.Row(id: $0.id, name: renamed ?? $0.name, symbol: $0.symbol, isThisMac: $0.isThisMac,
                                                         lastSeenMs: $0.lastSeenMs, connectedNow: $0.connectedNow, source: $0.source,
                                                         kind: $0.kind, addedMs: $0.addedMs) }
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
            Image(systemName: NativeDevicesSettings.glyph(row)).font(.system(size: 56, weight: .ultraLight))
                .frame(height: 72).accessibilityHidden(true)
            Text(row.name).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(row.isThisMac ? "This Mac" : NativeDevicesSettings.kindWord(row)).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// "Older and browser sign-ins": browsers, test devices, devices not seen for 30 days and second copies of a device.
/// Each can be signed out; "Sign out all of these" does it in one click (5 seconds behind one Undo). Nothing here was
/// signed out by itself.
struct NativeOlderDevicesPage: View {
    var account: NativeCloudAccount = .shared
    var fixture: NativeDevicesFixture?
    @State private var feed: NativeDevicesFeed
    @State private var signOut = NativeDeviceSignOut()

    init(account: NativeCloudAccount = .shared, fixture: NativeDevicesFixture? = nil) {
        self.account = account; self.fixture = fixture
        _feed = State(initialValue: NativeDevicesFeed(account: account, fixture: fixture))
    }

    var body: some View {
        let older = feed.groups.older
        DeckSettingsScaffold(title: "Older and browser sign-ins") {
            if older.isEmpty {
                DeckSettingsGroup { DeckSettingsProblem(text: "Nothing here.", warn: false) }
            } else {
                DeckSettingsGroup(info: "Browsers you signed in with, test devices, devices not seen for 30 days and second copies of a device. They stay signed in until you sign them out here.") {
                    ForEach(older) { row in
                        DeckSettingsRow(row.name, subtitle: NativeDevicesSettings.secondLine(row)) {
                            if signOut.pending.contains(row.id) {
                                Button("Undo") { signOut.undo(row.id) }
                            } else if row.canDisconnect {
                                Button("Sign out") { feed.choose(row.id, with: signOut) }.disabled(feed.busy)
                            }
                        }
                        if let note = signOut.notes[row.id] { DeckSettingsProblem(text: note) }
                    }
                }
                let open = older.filter { $0.canDisconnect && !signOut.pending.contains($0.id) }
                if !open.isEmpty {
                    DeckSettingsGroup {
                        DeckSettingsButtonRow(title: NativeDevicesSettings.signOutAllTitle, role: .destructive) {
                            for row in open { feed.choose(row.id, with: signOut) }
                        }
                        .disabled(feed.busy)
                    }
                }
            }
        }
        .task { await feed.start() }
        .onDisappear { signOut.cancelAll(); feed.stop() }
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
