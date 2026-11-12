import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// #108 (L6-SIMMENU, built from Codex FIXES's drafts in round7/FIXES-sim-drafts):
// the Simulators page's right-click / ⋯ menu, its confirmations, device tabs and
// windows, and the presenter the simulators_open MCP tool uses. Every device
// change goes through the one device manager (devices:* channels); nothing here
// runs xcrun or adb itself.

/// Device tabs in the main window's tab strip, beside the native browser tabs.
@MainActor @Observable
final class NativeFIXESDeviceTabs {
    static let shared = NativeFIXESDeviceTabs()
    private(set) var entries: [DeviceEntry] = []
    var selectedID: String?
    /// True once the window's tab strip shows device tabs (AppModel calls installPresenter()).
    static var shellJoined = false
    static func screenID(_ deviceID: String) -> String { "simulator:" + deviceID }
    static func deviceID(_ screenID: String) -> String? {
        screenID.hasPrefix("simulator:") ? String(screenID.dropFirst("simulator:".count)) : nil
    }
    func has(_ screenID: String) -> Bool { entries.contains { Self.screenID($0.id) == screenID } }
    func open(_ entry: DeviceEntry) {
        if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
        AppModel.shared.selectTab(Self.screenID(entry.id))
    }
    func openWindow(_ entry: DeviceEntry) {
        AppModel.shared.openScreenWindow(ScreenRef(kind: .panel, id: Self.screenID(entry.id)), title: entry.name)
    }
    func close(_ screenID: String) {
        entries.removeAll { Self.screenID($0.id) == screenID }
        if selectedID == screenID { selectedID = entries.last.map { Self.screenID($0.id) } }
    }
    var tabs: [TabItem] {
        entries.map { TabItem(id: Self.screenID($0.id), title: $0.name,
            symbol: $0.platform == "ios" ? "iphone" : "smartphone", kind: "panel",
            active: Self.screenID($0.id) == selectedID, closable: true) }
    }
    /// The simulators_open tool's way into this window (tab, window, beside a session, Finder).
    static func installPresenter() {
        shellJoined = true
        BackendFIXESDevicePresenter.shared.install { row, destination, sessionID in
            try await NativeFIXESDeviceTabs.shared.present(row, destination: destination, sessionID: sessionID)
        }
        // "fix ai taps" (22 Oct 2026): AI sessions' device tools reach iOS Simulators the phone panel's way.
        DeviceDirectInputs.install()
    }
    func present(_ row: NativeRPCValue, destination: String, sessionID: String?) async throws {
        guard let entry = DeviceEntry(json: row.foundation) else {
            throw NativeRPCError(code: "device-refused", message: "That device is no longer listed.")
        }
        switch destination {
        case "tab": open(entry)
        case "window": openWindow(entry)
        case "beside":
            guard let sessionID, !sessionID.isEmpty else { throw NativeRPCError(code: "device-refused", message: "Choose the session to show it beside.") }
            try await NativeFIXESDeviceMenuServices.beside(entry, sessionID: sessionID)
        case "finder":
            let path = try await NativeFIXESDeviceMenuServices.folder(entry.id)
            NativeFront.onlyForPerson("show device in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        default: throw NativeRPCError(code: "device-refused", message: "Choose a new tab, a new window or beside a session.")
        }
    }
}

@MainActor enum NativeFIXESDeviceMenuServices {
    /// Whole screen + accessibility tree to Hoot, through Hoot's one ingress (#88/#89).
    static var sendScreenToHoot: ((String) async throws -> Void)? = { id in
        try await NativeHOOTSIMFeedback.sendScreenToHoot(deviceId: id)
    }
    static func folder(_ id: String) async throws -> String {
        let value = try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke("devices:folder", [id]))
        guard let path = value["path"].string, !path.isEmpty else {
            throw NativeRPCError(code: "device-fault", message: "The device folder is not available.")
        }
        return path
    }
    static func beside(_ entry: DeviceEntry, sessionID: String) async throws {
        let sessions = AgentSessions.read(try await EngineBridge.shared.invoke("session:list"))
        guard sessions.contains(where: { $0.id == sessionID && !$0.ended && $0.machineId.isEmpty && !$0.onServer }) else {
            throw NativeRPCError(code: "device-refused", message: "That session is no longer running on this Mac.")
        }
        let session = NativeTerminalSessions.shared.session(for: sessionID)
        let store = NativeUIGSessionSimulatorStore.shared
        let first = store.entry(session), second = store.entry(session, slot: 1)
        func reusable(_ value: NativeUIGSessionSimulatorController) -> Bool {
            value.selected?.id == entry.id || (!value.layout.isOpen && value.model.markers.isEmpty && value.model.shot == nil
                && value.model.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        let controller: NativeUIGSessionSimulatorController
        if reusable(first) { controller = first }
        else if reusable(second) { controller = second }
        else { throw NativeRPCError(code: "device-refused", message: "This session already shows two devices. Close one of its device panels first.") }
        controller.setOpen(true)
        AppModel.shared.selectTab(sessionID)
        await controller.select(entry)
        if !controller.problem.isEmpty { throw NativeRPCError(code: "device-fault", message: controller.problem) }
        if !controller.model.problem.isEmpty { throw NativeRPCError(code: "device-fault", message: controller.model.problem) }
    }
    /// Tests pass their own writer and never touch the clipboard.
    @discardableResult static func copyID(_ id: String, write: ((String) -> Bool)? = nil) -> Bool {
        let text = FIXESDeviceIdentity.copiedID(id)
        guard !text.isEmpty else { return false }
        if let write { return write(text) }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        return clipboard.setString(text, forType: .string)
    }
}

/// One pushed attachment reader shared by the visible rows, for "iOS 27.0 · Commander".
@MainActor @Observable final class NativeFIXESDeviceSessionUsage {
    static let shared = NativeFIXESDeviceSessionUsage()
    private var usage = FIXESDeviceSessionUsage()
    private var rows: [AgentSessionRow] = []
    @ObservationIgnored private var owners = Set<UUID>()
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var revisions: [String: Int] = [:]
    /// Sessions whose first read has not finished yet.
    @ObservationIgnored private var unread = Set<String>()
    @ObservationIgnored private var generation = 0
    private init() {}
    func labels(for deviceID: String) -> [String] {
        let ids = Set(usage.sessionIDs(for: deviceID))
        return rows.filter { ids.contains($0.id) }.map(\.label).sorted()
    }
    func retain(_ owner: UUID, sessions: [AgentSessionRow]) {
        owners.insert(owner)
        if subscription == nil {
            subscription = EngineBridge.shared.on("session-simulator:attachment") { [weak self] args in
                guard let self, let raw = args.first, let value = try? NativeRPCValue.fromFoundation(raw),
                      let id = value["sessionId"].string, self.rows.contains(where: { $0.id == id }),
                      let slot = value["slot"].number, slot == 0 || slot == 1 else { return }
                self.revisions[self.key(id, Int(slot)), default: 0] += 1
                _ = self.usage.accept(value)
            }
        }
        update(sessions: sessions)
    }
    func update(sessions: [AgentSessionRow]) {
        let next = Array(sessions.filter { !$0.ended && $0.machineId.isEmpty && !$0.onServer }.prefix(128))
        guard !owners.isEmpty, next != rows else { return }
        let ids = Set(next.map(\.id))
        unread = FIXESDeviceSessionUsage.unread(before: Set(rows.map(\.id)), after: ids, pending: unread)
        rows = next; usage.retain(sessions: ids)
        generation += 1; let epoch = generation
        reading?.cancel(); reading = nil
        let toRead = next.filter { unread.contains($0.id) }
        guard !toRead.isEmpty else { return }
        reading = Task { [weak self] in
            guard let self else { return }
            for row in toRead {
                defer { if self.generation == epoch { self.unread.remove(row.id) } }
                for slot in [0, 1] {
                    guard !Task.isCancelled, self.generation == epoch else { return }
                    let key = self.key(row.id, slot), revision = self.revisions[key] ?? 0
                    do {
                        let raw = try await EngineBridge.shared.invoke("session-simulator:get", [["sessionId": row.id, "slot": slot]])
                        guard !Task.isCancelled, self.generation == epoch else { return }
                        if (self.revisions[key] ?? 0) == revision { _ = self.usage.accept(try NativeRPCValue.fromFoundation(raw)) }
                    } catch {
                        guard self.generation == epoch else { return }
                        if (self.revisions[key] ?? 0) == revision {
                            _ = self.usage.accept(.object([.init("sessionId", .string(row.id)), .init("slot", .number(Double(slot))), .init("deviceId", .null)]))
                        }
                    }
                }
            }
        }
    }
    func release(_ owner: UUID) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        generation += 1; reading?.cancel(); reading = nil
        subscription?.cancel(); subscription = nil; rows = []; usage = .init(); revisions = [:]; unread = []
    }
    private func key(_ id: String, _ slot: Int) -> String { id + "#" + String(slot) }
}

/// "iOS 27.0 · Commander" under the device name.
struct NativeFIXESDeviceRowCaption: View {
    let entry: DeviceEntry
    var suppliedLabels: [String]? = nil
    private var words: String {
        let runtime = entry.runtime.trimmingCharacters(in: .whitespacesAndNewlines)
        let os = runtime.isEmpty ? (entry.platform == "ios" ? "iOS" : "Android") : runtime
        let labels = suppliedLabels ?? NativeFIXESDeviceSessionUsage.shared.labels(for: entry.id)
        return ([os] + (labels.isEmpty ? [] : [labels.joined(separator: ", ")])).joined(separator: " · ")
    }
    var body: some View {
        Text(words).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(words)
    }
}

/// The On dot + word at the right of a row (green, as the approved mockup).
struct NativeFIXESDeviceRowStatus: View {
    let entry: DeviceEntry
    private var words: String { entry.available ? "On" : entry.state == "booting" ? "Starting…" : entry.canBoot ? "Off" : "Unavailable" }
    var body: some View {
        HStack(spacing: 4) {
            if entry.available { Circle().fill(.green).frame(width: 6, height: 6) }
            Text(words).foregroundStyle(entry.available ? Color.green : .secondary)
        }
        .font(.caption2).fixedSize().help(entry.stateLine)
    }
}

/// Right-click menu + hover/selected ⋯ button + named confirmations on one device row.
struct NativeFIXESDeviceContextMenu: ViewModifier {
    let entry: DeviceEntry
    let model: NativeSimulatorModel
    /// The row's own Start/Open path (selects it and starts it if off).
    let start: () -> Void
    var selected = false
    /// Off in offscreen fixtures: no engine reads.
    var readsEnabled = true
    /// Fixtures can show the ⋯ button without a hover.
    var forceEllipsis = false
    /// Another set of actions (the phone panel's device list uses `pickerSections`); nil = the Simulators page's.
    var sections: [[FIXESDeviceContextAction]]? = nil
    @State private var interaction = FIXESDeviceMenuInteraction()
    @State private var working = false
    @State private var hovered = false
    @State private var usageOwner = UUID()
    private var pending: FIXESDeviceContextAction? { interaction.pending }

    func body(content: Content) -> some View {
        content
        .onHover { hovered = $0 }
        .onAppear { if readsEnabled { NativeFIXESDeviceSessionUsage.shared.retain(usageOwner, sessions: model.sessions) } }
        .onChange(of: model.sessions) { _, rows in if readsEnabled { NativeFIXESDeviceSessionUsage.shared.update(sessions: rows) } }
        .onDisappear { if readsEnabled { NativeFIXESDeviceSessionUsage.shared.release(usageOwner) } }
        .contextMenu { menu }
        .overlay(alignment: .trailing) {
            let shown = hovered || selected || forceEllipsis
            Menu { menu } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 24, height: 24)
                    .background(Color(nsColor: .controlBackgroundColor), in: Circle())
            }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
            .opacity(shown ? 1 : 0).allowsHitTesting(shown)
            .accessibilityLabel("Actions for \(entry.name)")
            .padding(.trailing, 6)
        }
        .alert(alertTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { interaction.cancel() } })) {
            if pending == .rename { NativeSessionTextField("Device name", text: $interaction.name) }
            NativeSessionButton("Cancel", role: .cancel) { interaction.cancel() }
            NativeSessionButton(confirmTitle, role: pending?.destructive == true ? .destructive : nil) {
                if let command = interaction.confirm() { execute(command.action, deviceID: command.deviceID, name: command.name) }
            }
            .disabled(pending == .rename && interaction.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            if pending == .reset { Text("This clears the apps, accounts and settings on \(entry.name). It is shut down first.") }
            else if pending == .delete { Text("This removes \(entry.name) and its data from this Mac. This cannot be undone.") }
        }
    }
    private var alertTitle: String {
        switch pending {
        case .rename: "Rename \(entry.name)"
        case .reset: entry.platform == "android" ? "Wipe data on \(entry.name)?" : "Erase all content and settings on \(entry.name)?"
        default: "Delete \(entry.name)?"
        }
    }
    private var confirmTitle: String {
        switch pending {
        case .rename: "Rename"
        case .reset: entry.platform == "android" ? "Wipe data" : "Erase"
        default: "Delete"
        }
    }
    @ViewBuilder private var menu: some View {
        ForEach(Array((sections ?? FIXESDeviceContextAction.sections(for: entry)).enumerated()), id: \.offset) { section in
            if section.offset > 0 { Divider() }
            ForEach(section.element, id: \.self) { action in
                if action == .beside {
                    Menu {
                        ForEach(sessionGroups, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.rows) { row in NativeSessionButton(row.label) { showBeside(row) } }
                            }
                        }
                    } label: { Label(action.title, systemImage: action.symbol) }
                    .disabled(sessionGroups.isEmpty || !action.available(for: entry, working: busy))
                } else {
                    NativeSessionButton(role: action == .delete ? .destructive : nil) { choose(action) } label: {
                        if action == .sendToHoot, let owl = NativeFIXESDeviceContextMenu.hootImage {
                            Label { Text(action.title) } icon: { Image(nsImage: owl) } // Hoot keeps his coloured owl
                        } else {
                            Label(action.title(for: entry), systemImage: action.symbol)
                        }
                    }
                    .disabled(!action.available(for: entry, working: busy)
                        || (action == .sendToHoot && NativeFIXESDeviceMenuServices.sendScreenToHoot == nil)
                        || ((action == .newTab || action == .startAndOpen) && !NativeFIXESDeviceTabs.shellJoined))
                }
            }
        }
    }
    private var busy: Bool { working || model.busy[entry.id] != nil }
    private struct SessionGroup { let name: String; let rows: [AgentSessionRow] }
    private var sessionGroups: [SessionGroup] {
        guard readsEnabled else { return [] }
        let projects = NativePROJLabels.shared.projects
        let rows = model.sessions.filter { !$0.ended && $0.machineId.isEmpty && !$0.onServer }
        let groups = Dictionary(grouping: rows) { PROJProjects.resolve(projectID: nil, folder: $0.cwd, projects: projects) }
        return groups.keys.sorted().map { id in
            SessionGroup(name: NativePROJLabels.shared.name(for: id), rows: groups[id]!.sorted { $0.label < $1.label })
        }
    }
    private func showBeside(_ row: AgentSessionRow) {
        run { try await NativeFIXESDeviceMenuServices.beside(entry, sessionID: row.id) }
    }
    private func choose(_ action: FIXESDeviceContextAction) {
        if let command = interaction.choose(action, entry: entry) { execute(command.action, deviceID: command.deviceID, name: command.name) }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do { try await work() } catch { model.problem = error.localizedDescription }
        }
    }
    private func execute(_ action: FIXESDeviceContextAction, deviceID: String? = nil, name: String? = nil) {
        guard deviceID == nil || deviceID == entry.id else { model.problem = "That device changed. Choose it again."; return }
        switch action {
        case .start: start()
        case .newTab: NativeFIXESDeviceTabs.shared.open(entry)
        case .startAndOpen: NativeFIXESDeviceTabs.shared.open(entry)
        case .newWindow: NativeFIXESDeviceTabs.shared.openWindow(entry)
        case .copyID:
            if !NativeFIXESDeviceMenuServices.copyID(entry.id) { model.problem = "The device ID could not be copied." }
        case .beside: break // The submenu supplies the session.
        case .sendToHoot:
            run {
                guard let send = NativeFIXESDeviceMenuServices.sendScreenToHoot else {
                    throw NativeRPCError(code: "unavailable", message: "Hoot cannot receive this screen yet.")
                }
                try await send(entry.id)
            }
        case .finder:
            run {
                let path = try await NativeFIXESDeviceMenuServices.folder(entry.id)
                NativeFront.onlyForPerson("show device in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        case .shutDown, .restart, .coldStart, .rename, .reset, .delete:
            run {
                let wasShowing = model.device?.id == entry.id
                // Erase and Delete leave nothing to show; the rest close the view only once the change worked (#455).
                let closesFirst = NativeFIXESDeviceContextMenu.closesBeforeChange(action)
                if wasShowing && closesFirst { model.back() }
                let channel = NativeFIXESDeviceContextMenu.channel(for: action)
                let args: [Any?] = action == .rename ? [entry.id, name ?? ""] : action.destructive ? [entry.id, true] : [entry.id]
                let answer = try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke(channel, args))
                if answer["ok"].bool == false {
                    throw NativeRPCError(code: "device-fault", message: answer["message"].string ?? "The device change did not finish.")
                }
                if wasShowing && !closesFirst && model.device?.id == entry.id { model.back() }
                _ = await model.refresh()
                if wasShowing && (action == .restart || action == .coldStart) {
                    await model.open(answer["id"].string ?? entry.id)
                }
            }
        }
    }
    /// The coloured owl as a menu image (an NSMenu item takes an image, not a view).
    @MainActor static let hootImage: NSImage? = {
        let renderer = ImageRenderer(content: HootMark(size: 16, animated: false).frame(width: 16, height: 16))
        renderer.scale = 2
        let image = renderer.nsImage
        image?.size = NSSize(width: 16, height: 16)
        return image
    }()
    /// Erase and Delete close the open device before the change; a refused Shut down, Restart or Rename leaves it open.
    static func closesBeforeChange(_ action: FIXESDeviceContextAction) -> Bool { action == .reset || action == .delete }
    /// The one devices:* channel each change uses.
    static func channel(for action: FIXESDeviceContextAction) -> String {
        switch action {
        case .shutDown: "devices:shutdown"
        case .restart: "devices:restart"
        case .coldStart: "devices:cold-start"
        case .rename: "devices:rename"
        case .reset: "devices:reset"
        case .delete: "devices:delete"
        default: "devices:boot"
        }
    }
}

/// A device in its own tab or window: the same live screen, toolbar and inspector.
struct NativeFIXESDeviceScreen: View {
    let deviceID: String
    @State private var model = NativeSimulatorModel(deviceRail: true)
    /// Set only in a window of its own: then the window is the phone and a strip (NativeDeviceFloatingWindow).
    @Environment(\.popoutReturn) private var popout
    var body: some View {
        if let popout {
            content(floating: true)
                .background(NativeDeviceFloatingWindow(model: model, moveBack: popout.moveBack))
        } else { content(floating: false) }
    }
    @ViewBuilder private func content(floating: Bool) -> some View {
        Group {
            if model.device != nil { DeviceOpenView(model: model, showsDeviceBack: false, floating: floating) }
            else if !model.problem.isEmpty {
                NativePageEmpty(symbol: "iphone", title: "The device could not open", message: { Text(model.problem) })
            } else if let entry = model.list?.devices.first(where: { $0.id == deviceID }) {
                NativeUIGSimulatorStoppedDevice(entry: entry, working: model.busy[entry.id] ?? "") {
                    Task { if entry.canBoot { await model.start(entry) } else { await model.open(entry.id) } }
                }
            } else { ProgressView("Opening device…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        // Floating and not open yet (stopped, opening, a problem): on a glass card, the window has no background.
        .background { if floating && model.device == nil { RoundedRectangle(cornerRadius: 24).fill(.regularMaterial) } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { NativeDeviceDirectRecorder.attach(to: model); model.appear() }
        .task(id: deviceID) {
            _ = await model.refresh()
            guard !Task.isCancelled else { return }
            guard let entry = model.list?.devices.first(where: { $0.id == deviceID }) else {
                model.problem = "That device is no longer listed. Refresh the device list and try again."; return
            }
            if entry.available { await model.open(entry.id) } else if entry.canBoot { await model.start(entry) }
        }
        .onDisappear { model.disappear() }
    }
}

/// The device preview toolbar's "Send to Hoot": the same handoff as the row menu's
/// "Send the screen to Hoot" (screen + accessibility tree into Hoot's chat).
struct NativeFIXESDeviceSendButton: View {
    let model: NativeSimulatorModel
    @State private var sending = false
    @State private var sent = false
    var body: some View {
        NativeSessionButton {
            guard let id = model.device?.id, let send = NativeFIXESDeviceMenuServices.sendScreenToHoot else { return }
            sending = true
            Task { @MainActor in
                do { try await send(id); sent = true }
                catch { model.problem = error.localizedDescription }
                sending = false
            }
        } label: {
            if sending { ProgressView().controlSize(.mini) }
            else if sent { Image(systemName: "checkmark").foregroundStyle(.green) }
            else { HootMark(size: 16, animated: false) }
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .disabled(sending || model.device == nil || NativeFIXESDeviceMenuServices.sendScreenToHoot == nil)
        .help("Send to Hoot — this screen and its accessibility tree")
        .accessibilityLabel(sent ? "Sent to Hoot" : "Send to Hoot")
        .task(id: sent) {
            guard sent else { return }
            try? await Task.sleep(for: .seconds(2))
            sent = false
        }
    }
}
