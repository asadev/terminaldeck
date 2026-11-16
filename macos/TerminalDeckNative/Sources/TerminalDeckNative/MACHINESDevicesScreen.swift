import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The Devices window (owner, 13 Nov: "we don't have pairing thing at all completely. We just see all of our devices
/// when we just log in. Not behind link, not behind any code, nowhere."). What it shows is decided by `DevicesPage`
/// (Core): the one switch, the account's devices, and, only when any exist, the devices connected before accounts with
/// Remove. Nothing here makes a code, shows a picture to scan, opens a sheet or asks which folder.
struct MACHINESDevicesScreen: View {
    @State private var model: RemoteSectionModel
    @State private var machines: MachinesHalfModel
    /// Other Macs this one already reaches the old way (their screens; Mac to Mac, 31 Oct).
    @State private var otherMacs: OtherMacsModel
    @State private var macScreenAllowed = NativeMacScreenSetting.allowed
    var account = NativeCloudAccount.shared
    var reach = NativeReachAccount.shared
    let fixture: Bool
    /// A render or test may hand the whole page in.
    let fixturePage: DevicesPage?
    /// The old device whose Details are open (its own per-device content: folders, sessions, sign-ins, browser windows).
    @State private var details: RemoteDevice?

    init(model: RemoteSectionModel? = nil, machines: MachinesHalfModel? = nil, otherMacs: OtherMacsModel? = nil,
         fixture: Bool = false, fixturePage: DevicesPage? = nil) {
        _model = State(initialValue: model ?? RemoteSectionModel())
        _machines = State(initialValue: machines ?? MachinesHalfModel())
        _otherMacs = State(initialValue: otherMacs ?? OtherMacsModel())
        self.fixture = fixture
        self.fixturePage = fixturePage
    }

    /// Signed in for this window: an account is on this Mac (Cloud open, paused, or not open for the account yet).
    nonisolated static func signedIn(_ phase: CloudAccountSnapshot.Phase) -> Bool { [.signedIn, .paused, .dormant].contains(phase) }

    /// The page for what this Mac holds now. Reading it changes nothing: no record of the old way is written.
    var page: DevicesPage {
        if let fixturePage { return fixturePage }
        let snapshot = account.snapshot
        let old = DevicesPage.oldDevices(devices: model.state?.devices ?? [], connected: Set(model.state?.connections.map(\.deviceId) ?? []),
                                         machines: machines.view.machines,
                                         online: Set(machines.view.links.filter { $0.phase == .online }.map(\.id)))
        let signedIn = !fixture && Self.signedIn(snapshot.phase)
        return DevicesPage(signedIn: signedIn, account: signedIn ? DevicesPage.accountDevices(snapshot) : [],
                           reach: fixture ? .unknown : reach.devicesReach, old: old)
    }

    var body: some View {
        let page = self.page
        MACHINESPage(title: DevicesPage.title, subtitle: DevicesPage.subtitle, switcher: { EmptyView() }, actions: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 16) {
                if page.showsSetting { setting(page) }
                else if let note = page.featureNote { Text(note).font(.callout).foregroundStyle(.secondary) }
                if page.signedIn { accountCard(page) } else { signIn }
                if page.showsOld { oldGroup(page) }
                if let notice = model.notice, !notice.ok { Text(notice.text).font(.callout).foregroundStyle(.secondary) }
                if let error = machines.actionError { Text(error).font(.callout).foregroundStyle(.secondary) }
                if !otherMacs.macs.isEmpty { MACHINESCard { NativeOtherMacsCard(model: otherMacs) } }
                thisMac(page)
            }
        }
        .sheet(item: $details) { device in
            DevicesOldDetails(device: device, kinds: model.kinds) { details = nil }
        }
        .task {
            guard !fixture else { return }
            async let remote: Void = model.start()
            async let links: Void = machines.start()
            async let switchState: Void = reach.reload()
            _ = await (remote, links, switchState)
        }
        .onDisappear { if !fixture { model.stop(); machines.stop() } }
        .onChange(of: machines.view, initial: true) { _, view in if !fixture { otherMacs.update(view) } }
    }

    // MARK: The one setting

    private func setting(_ page: DevicesPage) -> some View {
        MACHINESCard {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(DevicesPage.settingTitle, isOn: Binding(get: { page.settingOn }, set: { turn($0) }))
                    .toggleStyle(.switch).disabled(fixture || reach.busy)
                    .accessibilityIdentifier("devices.setting")
                HStack(spacing: 6) {
                    if let door = page.door {
                        Circle().fill(door == .ready ? Color.green : door == .connecting ? Color.secondary : Color.orange)
                            .frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    Text(page.settingDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("devices.setting.state")
                if let note = page.featureNote { Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("devices.setting.note") }
                if let problem = reach.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// On also makes sure this Mac serves: the reach model starts remote access itself whenever the switch is on and it
    /// is not running (A1). Off only closes the account way; remote access stays for devices connected before accounts.
    private func turn(_ on: Bool) {
        reach.setEnabled(on)
    }

    // MARK: The account's devices

    private var signIn: some View {
        let stage = account.signInStage
        let content = NativeCloudSignInPage.content(stage)
        return MACHINESCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(DevicesPage.signedOutLine).font(.callout)
                Button(content.button) {
                    if case .reaching = stage { account.pressCheckAgain() } else { account.pressSignIn() }
                }
                .buttonStyle(.borderedProminent).disabled(fixture || !content.enabled || account.busy)
                .accessibilityIdentifier("devices.signIn")
                if let notice = account.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accountCard(_ page: DevicesPage) -> some View {
        MACHINESCard {
            VStack(spacing: 0) {
                ForEach(page.accountRows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: Self.symbol(row.kind)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).background(MACHINESTokens.selection, in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(row.name)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if row.canRemove, let ref = row.ref {
                            Button(DevicesPage.removeTitle) { removeAccount(ref) }
                                .buttonStyle(.bordered).controlSize(.small).disabled(fixture || reach.busy || account.busy)
                                .accessibilityLabel("Remove \(row.name)")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 4)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("devices.\(row.id)")
                    if row.id != page.accountRows.last?.id { Divider() }
                }
                if page.accountRows.allSatisfy(\.isThisMac) {
                    Text(DevicesPage.noOtherDevice).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
            }
        }
    }

    /// The account device's Remove (A3), at once and with no sheet: Reach's Remove when reach is assembled here (it
    /// can no longer reach this Mac, this Mac stops taking its changes, the account is told), else the Cloud page's own
    /// Remove (this Mac stops taking its changes).
    private func removeAccount(_ deviceId: String) {
        if reach.coordinator != nil { reach.remove(deviceId) } else { account.removeJoined(deviceId) }
    }

    static func symbol(_ kind: DevicesPage.Kind) -> String {
        switch kind {
        case .mac: "laptopcomputer"
        case .pc: "pc"
        case .phone: "iphone.gen3"
        case .browser: "globe"
        }
    }

    // MARK: Connected before accounts

    private func oldGroup(_ page: DevicesPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DevicesPage.oldTitle).font(.system(size: 15, weight: .semibold))
            Text(DevicesPage.oldLine).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !page.oldRecent.isEmpty {
                MACHINESCard { oldRows(page.oldRecent) }
            }
            if !page.oldQuiet.isEmpty {
                MACHINESCard {
                    DisclosureGroup {
                        oldRows(page.oldQuiet)
                    } label: {
                        HStack {
                            Text(DevicesPage.quietTitle(page.oldQuiet.count)).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(DevicesPage.removeAllTitle) { for row in page.oldQuiet { remove(row) } }
                                .buttonStyle(.borderless).disabled(fixture || busy)
                                .accessibilityIdentifier("devices.old.removeAll")
                        }
                    }
                }
            }
        }
    }

    private func oldRows(_ rows: [DevicesPage.OldRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(row.name)
                        Text(row.seen).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.source == .device {
                        Button(DevicesPage.detailsTitle) { openDetails(row) }.buttonStyle(.borderless).controlSize(.small)
                            .disabled(fixture).accessibilityLabel("Details for \(row.name)")
                    }
                    Button(DevicesPage.removeTitle) { remove(row) }.buttonStyle(.bordered).controlSize(.small).disabled(fixture || busy)
                        .accessibilityLabel("Remove \(row.name)")
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                if row.id != rows.last?.id { Divider() }
            }
        }
    }

    private var busy: Bool { model.busy != nil || machines.busy }

    private func openDetails(_ row: DevicesPage.OldRow) {
        let id = String(row.ref.split(separator: ":", maxSplits: 1).last ?? "")
        details = model.state?.devices.first { $0.id == id }
    }

    /// The row's own Remove: what the old Revoke (a device) or Forget (a computer) did, with no question after it.
    private func remove(_ row: DevicesPage.OldRow) {
        let id = String(row.ref.split(separator: ":", maxSplits: 1).last ?? "")
        switch row.source {
        case .device: if let device = model.state?.devices.first(where: { $0.id == id }) { model.remove(device) }
        case .machine: if let machine = machines.view.machines.first(where: { $0.id == id }) { machines.forget(machine) }
        }
    }

    // MARK: This Mac

    /// This Mac's own screen settings (they used to sit behind a separate window), and who opened it lately.
    private func thisMac(_ page: DevicesPage) -> some View {
        MACHINESCard {
            Form {
                Section("This Mac") {
                    Toggle(NativeMacScreenSetting.title, isOn: Binding(get: { macScreenAllowed }, set: { on in
                        macScreenAllowed = on
                        NativeMacScreenSetting.set(on)
                    }))
                    .toggleStyle(.switch).disabled(fixture)
                    .accessibilityIdentifier("devices.access.macScreen")
                    Text(NativeMacScreenSetting.detail).font(.callout).foregroundStyle(.secondary)
                }
                if !page.lastConnections.isEmpty {
                    Section(DevicesPage.lastConnectionsTitle) {
                        ForEach(Array(page.lastConnections.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(line)
                        }
                    }.accessibilityIdentifier("devices.lastConnections")
                }
                NativeMacReachSettings(fixture: fixture)
            }.formStyle(.grouped).scrollDisabled(true)
            // The card is the frame: the form draws no second background, border or margin inside it.
            .scrollContentBackground(.hidden).contentMargins(0, for: .scrollContent)
        }
    }
}

/// "Details" on a device connected before accounts (A6b): the content the old Device access window had for it (which
/// folders, sessions, sign-ins and browser windows it gets), for that one device. No access level, no code, nothing
/// that adds a device.
struct DevicesOldDetails: View {
    let device: RemoteDevice
    let kinds: [String: RemoteDeviceKind]?
    let done: () -> Void
    @State private var tab = "Folders"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(device.name).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            MACHINESDevicesSettingsTabs(selection: $tab, items: MACHINESDevicesSettingsTabs.perDevice)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let one = [device]
                    switch tab {
                    case "Folders": RemoteFoldersView(devices: RemoteRules.grantable(one, kinds: kinds))
                    case "Sessions": RemoteSessionsView(devices: RemoteRules.sessionDevices(one))
                    case "Sign-ins": RemoteLoginsView(devices: RemoteRules.sessionDevices(one))
                    default: RemoteWindowsView(devices: RemoteRules.sessionDevices(one))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20).frame(width: 620, height: 520)
    }
}

/// Content for the separate remembered glass window; one shared alias adopts SHELL-CORE.
struct MACHINESDevicesAccessContent: View {
    @State private var model: RemoteSectionModel
    let fixture: Bool
    @State private var tab = "General"
    @State private var macScreenAllowed = NativeMacScreenSetting.allowed
    init(model: RemoteSectionModel? = nil, fixture: Bool = false) {
        _model = State(initialValue: model ?? RemoteSectionModel())
        self.fixture = fixture
    }
    var body: some View {
        MACHINESSettingsFrame(title: "Device access", switcher: {
            MACHINESDevicesSettingsTabs(selection: $tab)
        }, actions: { EmptyView() }) {
            if tab == "General" {
                Form {
                    if let state = model.state {
                        Section {
                            Toggle("Let approved devices in", isOn: Binding(get: { state.running }, set: { model.enable($0) }))
                                .toggleStyle(.switch).disabled(model.busy != nil || fixture)
                            Text("Devices connected before accounts can connect while this is on.").font(.callout).foregroundStyle(.secondary)
                        }
                        macScreenSection
                        Section("Relay") {
                            HStack {
                                Text("Status")
                                Spacer()
                                Circle().fill(state.relay?.connected == true ? Color.green : Color.orange).frame(width: 6, height: 6)
                                Text(state.relay?.connected == true ? "Connected" : "Not connected").foregroundStyle(.secondary)
                            }
                            if let reason = state.relay?.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                        }
                    } else if model.problem == nil {
                        Section {
                            LabeledContent("Let approved devices in") {
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width: 40, height: 20)
                            }
                            LabeledContent("Relay") {
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width: 90, height: 12)
                            }
                        }.accessibilityLabel("Loading device access")
                        macScreenSection
                    } else {
                        macScreenSection
                    }
                    if let problem = model.problem {
                        Section {
                            Text(problem).font(.callout).foregroundStyle(.secondary)
                            DeckRetryButton("Try Again", autoRetry: true) { Task { await model.refresh() } }.buttonStyle(.bordered) // autoRetry: re-reads the device list
                        }
                    }
                    if let notice = model.notice, !notice.ok {
                        Section { Text(notice.text).font(.callout).foregroundStyle(.secondary) }
                    }
                }.formStyle(.grouped).frame(minHeight: 0, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let state = model.state {
                            if fixture {
                                MACHINESCard { Text("No shared \(tab.lowercased()) selected.").foregroundStyle(.secondary) }
                            } else {
                                switch tab {
                                case "Folders": RemoteFoldersView(devices: RemoteRules.grantable(state.devices, kinds: model.kinds))
                                case "Sessions": RemoteSessionsView(devices: RemoteRules.sessionDevices(state.devices))
                                case "Sign-ins": RemoteLoginsView(devices: RemoteRules.sessionDevices(state.devices))
                                default: RemoteWindowsView(devices: RemoteRules.sessionDevices(state.devices))
                                }
                            }
                        }
                        if let problem = model.problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                        if let notice = model.notice, !notice.ok { Text(notice.text).font(.callout).foregroundStyle(.secondary) }
                    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.frame(minHeight: 0, maxHeight: .infinity)
            }
        }
        .task { if !fixture { await model.start() } }
        .onDisappear { if !fixture { model.stop() } }
    }

    /// The one place for whether phones may view and control this Mac's screen (round 3, #24); it works on its own,
    /// whatever the device list is doing.
    private var macScreenSection: some View {
        Group {
        Section {
            Toggle(NativeMacScreenSetting.title, isOn: Binding(get: { macScreenAllowed }, set: { on in
                macScreenAllowed = on
                NativeMacScreenSetting.set(on)
            }))
            .toggleStyle(.switch).disabled(fixture)
            .accessibilityIdentifier("devices.access.macScreen")
            Text(NativeMacScreenSetting.detail).font(.callout).foregroundStyle(.secondary)
        }
        NativeMacReachSettings(fixture: fixture)
        }
    }
}

struct MACHINESDevicesSettingsTabs: View {
    @Binding var selection: String
    static let all = [("General", "gearshape"), ("Folders", "folder"), ("Sessions", "terminal"), ("Sign-ins", "key"), ("Browser", "globe")]
    static let perDevice = Array(all.dropFirst())
    var items = Self.all
    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(items, id: \.0) { item in
                    NativeSessionButton { withAnimation(.smooth) { selection = item.0 } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.1).font(.system(size: 15))
                            Text(item.0).font(.system(size: 11))
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                        .background(selection == item.0 ? MACHINESTokens.card : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).foregroundStyle(selection == item.0 ? Color.accentColor : Color.secondary)
                        .help(item.0 + " settings")
                        .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
                }
            }.padding(4).frame(maxWidth: 450)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}
