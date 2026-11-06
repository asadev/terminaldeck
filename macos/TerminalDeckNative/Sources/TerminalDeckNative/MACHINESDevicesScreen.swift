import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Devices is its own page. The same live model remains mounted while its pairing sheet is open.
struct MACHINESDevicesScreen: View {
    @State private var model: RemoteSectionModel
    @State private var machines = MachinesHalfModel()
    /// Other Macs this one can see and use (Mac to Mac, 31 Oct).
    @State private var otherMacs: OtherMacsModel
    @State private var pairingShown = false
    @State private var revoke: RemoteDevice?
    @State private var rename: RemoteDevice?
    @State private var newName = ""
    let fixture: Bool
    let fixtureAccess: [String: String]
    let onAccess: (() -> Void)?

    init(model: RemoteSectionModel? = nil, machines: MachinesHalfModel? = nil, otherMacs: OtherMacsModel? = nil, fixture: Bool = false, pairOnOpen: Bool = false, fixtureAccess: [String: String] = [:], onAccess: (() -> Void)? = nil) {
        _otherMacs = State(initialValue: otherMacs ?? OtherMacsModel())
        let model = model ?? RemoteSectionModel()
        if fixture { model.setRenderAccess(fixtureAccess) }
        _model = State(initialValue: model)
        _pairingShown = State(initialValue: pairOnOpen)
        _machines = State(initialValue: machines ?? MachinesHalfModel())
        self.fixture = fixture
        self.fixtureAccess = fixtureAccess
        self.onAccess = onAccess
    }

    var body: some View {
        MACHINESPage(title: "Devices", subtitle: "Phones, browsers and computers that can drive this Mac", switcher: { EmptyView() }, actions: {
            Button(model.busy == "web" ? "Opening…" : "Open web version", systemImage: "globe") { model.openWebVersion() }
                .buttonStyle(.bordered).disabled(fixture || model.busy != nil)
                .help(webTurnsAccessOn ? Self.webAccessNote : "Open the web version in this Mac’s browser")
                .accessibilityIdentifier("devices.openWebVersion")
            Button("Device access", systemImage: "lock") { openAccess() }.buttonStyle(.bordered)
            Button("Pair a device", systemImage: "qrcode") { pairingShown = true }.buttonStyle(.borderedProminent)
        }) {
            VStack(alignment: .leading, spacing: 16) {
                if webTurnsAccessOn {
                    // The web version is served by device access, so its button turns that on (review install-24 S1).
                    // Said under the header's buttons only while access is off: then the click changes it.
                    Text(Self.webAccessNote).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, -8)
                        .accessibilityIdentifier("devices.openWebVersion.note")
                }
                HStack {
                    Text("Paired").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if model.state != nil { Text("\(approved.count) devices").font(.caption).foregroundStyle(.secondary) }
                }
                if model.state == nil && model.problem == nil {
                    MACHINESCard {
                        ForEach(0..<3) { _ in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)).frame(width: 32, height: 32)
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width: 180, height: 12)
                                Spacer()
                            }.padding(.vertical, 8)
                        }
                    }.accessibilityLabel("Loading devices")
                } else if model.state == nil, let problem = model.problem {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.orange)
                        Text("Couldn’t read devices").font(.headline)
                        Text(problem).font(.callout).foregroundStyle(.secondary)
                        DeckRetryButton("Try Again", autoRetry: true) { Task { await model.refresh() } }.buttonStyle(.bordered) // autoRetry: re-reads the device list
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                } else if approved.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text("No devices yet").font(.headline)
                        Text("Pair a phone or computer to drive this Mac.").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    MACHINESCard {
                        VStack(spacing: 0) {
                            ForEach(approved) { device in
                                deviceRow(device)
                                if device.id != approved.last?.id { Divider() }
                            }
                        }
                    }
                    .task(id: approved.map(\.id)) { await model.readAccess() }
                }
                if let pending = model.state?.devices.first(where: { $0.state == .pending }) {
                    Button { pairingShown = true } label: {
                        HStack {
                            Image(systemName: "iphone.gen3").foregroundStyle(.secondary)
                            Text("\(pending.name) wants to connect")
                            Spacer()
                            Text("Review").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.frame(maxWidth: .infinity, minHeight: 36).contentShape(.rect)
                    }.buttonStyle(MACHINESRowStyle())
                }
                if model.state != nil, let problem = model.problem {
                    HStack {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        DeckRetryButton("Try Again", autoRetry: true) { Task { await model.refresh() } }.buttonStyle(.bordered) // autoRetry: re-reads the device list
                    }
                }
                if let notice = model.notice, !notice.ok { Text(notice.text).font(.callout).foregroundStyle(.secondary) }
                if !machines.view.machines.isEmpty || machines.error != nil {
                    MACHINESCard { NativeMachineLinksView(half: machines) }
                }
                MACHINESCard { NativeOtherMacsCard(model: otherMacs) }
            }
        }
        .task {
            guard !fixture else { return }
            async let remote: Void = model.start()
            async let reach: Void = machines.start()
            _ = await (remote, reach)
        }
        .onDisappear { if !fixture { model.stop(); machines.stop() } }
        .onChange(of: machines.view, initial: true) { _, view in if !fixture { otherMacs.update(view) } }
        .sheet(isPresented: $pairingShown) {
            MACHINESDevicesPairSheet(model: model, machines: machines, fixture: fixture) { pairingShown = false }
        }
        .alert("Revoke \(revoke?.name ?? "device")?", isPresented: Binding(get: { revoke != nil }, set: { if !$0 { revoke = nil } })) {
            Button("Cancel", role: .cancel) { revoke = nil }
            Button("Revoke", role: .destructive) { if let device = revoke { model.revoke(device) }; revoke = nil }
        } message: { Text("It will be disconnected immediately and must pair again.") }
        .alert("Rename device", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { rename = nil }
            Button("Rename") { if let device = rename { model.rename(device, to: newName) }; rename = nil }
                .disabled(!validRename)
        } message: { Text("Use a name from 1 to 128 characters.") }
    }

    private func openAccess() {
        if let onAccess { onAccess() }
        else { MACHINESObjectWindows.openDevices() }
    }

    private var validRename: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 128
    }

    private var approved: [RemoteDevice] { (model.state?.devices ?? []).filter { $0.state == .approved } }
    /// Open web version starts device access (relay included) and remembers it on, as the Device access switch does.
    static let webAccessNote = "Open web version also turns on device access for this Mac."
    private var webTurnsAccessOn: Bool { model.state?.running == false }

    private func deviceRow(_ device: RemoteDevice) -> some View {
        let connected = model.state?.connections.contains { $0.deviceId == device.id } == true
        return HStack(spacing: 12) {
            Button { openAccess() } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol(device)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32).background(MACHINESTokens.selection, in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(device.name)
                        Text((device.platform == "web" ? "Web browser · " : "") + pairedNote(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(connected ? "Connected" : seenNote(device)).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
            }.buttonStyle(MACHINESRowStyle())
            NativeINT2PhoneAccessControl(deviceID: device.id, level: fixture ? (model.access?[device.id] ?? "full") : model.accessLevel(device.id),
                                         problem: model.accessProblem) { try await model.setAccess(device.id, to: $0) }
                .frame(width: 140)
            Menu {
                Button("Device access…") { openAccess() }
                Button("Rename…") { newName = device.name; rename = device }
                Button("Revoke…", role: .destructive) { revoke = device }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(.rect) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Device actions").accessibilityLabel("Actions for \(device.name)")
        }
        .padding(.vertical, 6)
        .background(model.highlightedDeviceID == device.id ? MACHINESTokens.selection : Color.clear, in: .rect(cornerRadius: 8))
        .contextMenu {
            Button("Device access…") { openAccess() }
            Button("Rename…") { newName = device.name; rename = device }
            Button("Revoke…", role: .destructive) { revoke = device }
        }
    }

    private func symbol(_ device: RemoteDevice) -> String {
        RemoteRules.deviceSymbol(platform: device.platform ?? model.state?.connections.first { $0.deviceId == device.id }?.platform)
    }
    private func pairedNote(_ device: RemoteDevice) -> String {
        guard let at = device.addedAt else { return "Paired device" }
        return "Paired " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: at / 1000), relativeTo: Date(timeIntervalSince1970: model.now / 1000))
    }
    private func seenNote(_ device: RemoteDevice) -> String {
        guard let at = device.lastSeenAt else { return "Not connected" }
        return "Last seen " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: at / 1000), relativeTo: Date(timeIntervalSince1970: model.now / 1000))
    }
}

struct MACHINESDevicesPairSheet: View {
    @Bindable var model: RemoteSectionModel
    @Bindable var machines: MachinesHalfModel
    let fixture: Bool
    let close: () -> Void
    @State private var segment = "This Mac shows a code"
    @State private var access = "full"
    /// Whose device is waiting (#27): the person's own by default, with Full control and every login.
    @State private var whose = RemoteDeviceKind.mine
    @State private var submitting = false
    @State private var typedCode = ""

    init(model: RemoteSectionModel, machines: MachinesHalfModel, fixture: Bool,
         typeCodeOnOpen: Bool = false, whose: RemoteDeviceKind = .mine, close: @escaping () -> Void) {
        _model = Bindable(wrappedValue: model)
        _whose = State(initialValue: whose)
        _machines = Bindable(wrappedValue: machines)
        self.fixture = fixture
        self.close = close
        _segment = State(initialValue: typeCodeOnOpen ? "Type a code" : "This Mac shows a code")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pair a device").font(.system(size: 20, weight: .semibold))
                Text("On the phone, open Terminal Deck and tap Pair. Scan this, or type the code.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Picker("Pairing direction", selection: $segment) {
                Text("This Mac shows a code").tag("This Mac shows a code")
                Text("Type a code").tag("Type a code")
            }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl()
            if segment == "This Mac shows a code" {
                HStack(spacing: 24) {
                    qr
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Code").font(.callout).foregroundStyle(.secondary)
                        if let pairing = model.pairing {
                            Text(RemoteRules.codeShown(pairing.token)).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            if let seconds = model.secondsLeft, seconds > 0 {
                                Text("Works once · \(seconds / 60):\(String(format: "%02d", seconds % 60)) left").font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text("This code expired").font(.callout).foregroundStyle(.secondary)
                                Button("Make a new code") { model.pair() }.buttonStyle(.bordered)
                            }
                            Button("Copy code") { DeckProject.copy(RemoteRules.codeShown(pairing.token)) }.buttonStyle(.borderless)
                        } else if model.busy != nil { ProgressView().controlSize(.small) }
                        else { Button("Make a code") { model.pair() }.buttonStyle(.bordered) }
                    }
                    Spacer(minLength: 0)
                }.frame(height: 140)
                if let request = pending {
                    MACHINESCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: "iphone.gen3").foregroundStyle(Color.accentColor).frame(width: 32, height: 32)
                                    .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(request.name) wants to connect").font(.system(size: 13, weight: .semibold)).lineLimit(2).help(request.name)
                                    Text("Only let in the device you are holding.").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if !guestOpen { accessPicker }
                            }
                            Picker("Whose device", selection: whoseChoice(request)) {
                                Text("My device").tag(RemoteDeviceKind.mine)
                                Text("Someone else’s").tag(RemoteDeviceKind.guest)
                            }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl().disabled(submitting || model.busy != nil)
                            Text(guestOpen ? Self.guestNote : Self.mineNote)
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if guestOpen {
                        RemoteApprovalCard(approval: $model.approving, busy: model.busy != nil, problem: nil,
                                           addFolder: model.addApprovalFolder, approve: model.approve,
                                           cancel: { whose = .mine; model.approving = nil }, firstStep: .folders)
                    }
                } else {
                    Text("Waiting for the device…").font(.callout).foregroundStyle(.secondary).frame(height: 56)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Show a code on the other computer, then type it here.").font(.callout).foregroundStyle(.secondary)
                    TextField("Pairing code", text: $typedCode).textFieldStyle(.roundedBorder).font(.system(.title3, design: .monospaced))
                    if let error = machines.pairError { Text(error).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(error) }
                }.frame(height: 216, alignment: .top)
            }
            if let notice = model.notice, !notice.ok { Text(notice.text).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(notice.text) }
            HStack {
                Spacer()
                Button(pending == nil ? "Cancel" : "Not now") { cancel() }.buttonStyle(.bordered)
                if segment == "Type a code" {
                    Button(machines.busy ? "Pairing…" : "Pair a device") { machines.type(typedCode); machines.pair() }
                        .buttonStyle(.borderedProminent).disabled(machines.busy || CodeEntryRules.normalise(typedCode) == nil)
                } else if !guestOpen {
                    Button(submitting ? "Letting it in…" : "Let it in") {
                        guard let request = pending else { return }
                        submitting = true
                        Task { if await model.letIn(request, access: access) { close() }; submitting = false }
                    }.buttonStyle(.borderedProminent).disabled(pending == nil || submitting || model.busy != nil)
                }
            }
        }
        .padding(24).frame(width: 592)
        .task { if !fixture, segment == "This Mac shows a code", model.pairing == nil, pending == nil { model.pair() } }
        .onChange(of: machines.busy) { before, after in
            if before && !after && machines.pairError == nil && machines.digits.isEmpty { close() }
        }
        .onChange(of: segment) { _, after in
            if !fixture {
                if after == "Type a code" { model.closePairing() }
                else if pending == nil { model.pair() }
            }
        }
        // A guest let in through its folder and login steps: the walk-through ends, so does the sheet.
        .onChange(of: model.approving == nil) { _, ended in if ended && whose == .guest { whose = .mine; close() } }
        .onDisappear {
            if model.approving != nil { model.approving = nil }
            if !fixture, model.pairing != nil { model.closePairing() }
        }
        .onExitCommand { cancel() }
    }

    private var pending: RemoteDevice? { model.state?.devices.first { $0.state == .pending } }
    /// The guest steps are open for the device waiting now (a different device arriving shows My device again).
    private var guestOpen: Bool { whose == .guest && pending != nil && model.approving?.device.id == pending?.id }
    static let mineNote = "Your own device. At Full control it gets every login, every tool and every folder, as on this Mac."
    static let guestNote = "They get only the folders and logins you choose next, and never Hoot."
    /// Someone else's opens the guest steps (folders, logins, confirm) for this device; My device closes them.
    private func whoseChoice(_ request: RemoteDevice) -> Binding<RemoteDeviceKind> {
        Binding(get: { guestOpen ? .guest : .mine }, set: { picked in
            whose = picked
            if picked == .guest {
                var approval = RemoteApproval(device: request)
                approval.pick(.guest)
                model.approving = approval
                NativeCodingAIStore.shared.reloadAccounts()
            } else { model.approving = nil }
        })
    }
    private var accessPicker: some View {
        Picker("Access", selection: $access) {
            ForEach(BackendINT2PhoneAccessLevel.offered, id: \.self) { Text($0.title).tag($0.rawValue) }
        }.pickerStyle(.menu).fixedSize()
    }
    private var qr: some View {
        Group {
            if let url = model.pairingURL, let image = MACHINESDevicesQR.image(url) {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit().padding(8)
                    .background(Color.white, in: .rect(cornerRadius: 12)).accessibilityLabel("Scan to pair this device")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Type the code").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MACHINESTokens.card, in: .rect(cornerRadius: 12))
            }
        }.frame(width: 140, height: 140)
    }
    private func cancel() {
        if !fixture { if let request = pending { model.deny(request) }; model.closePairing() }
        close()
    }
}

@MainActor
enum MACHINESDevicesQR {
    static func image(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let bitmap = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: bitmap, size: NSSize(width: output.extent.width, height: output.extent.height))
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
                            Text("Only devices you pair and approve can connect.").font(.callout).foregroundStyle(.secondary)
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
    private let items = [("General", "gearshape"), ("Folders", "folder"), ("Sessions", "terminal"), ("Sign-ins", "key"), ("Browser", "globe")]
    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(items, id: \.0) { item in
                    Button { withAnimation(.smooth) { selection = item.0 } } label: {
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
