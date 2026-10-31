import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// INT2 enables this only after registration, compile, routing and visual gates pass.
enum NativeUIGSessionSimulatorRelease { static let enabled = true }

@MainActor @Observable final class NativeUIGSessionSimulatorStore {
    static let shared = NativeUIGSessionSimulatorStore()
    private var entries: [String: NativeUIGSessionSimulatorController] = [:]
    @ObservationIgnored private var windows: [String: NativeUIGSessionSimulatorWindow] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let lifecycleEnabled: Bool
    init(defaults: UserDefaults = .standard, lifecycleEnabled: Bool = true) { self.defaults = defaults; self.lifecycleEnabled = lifecycleEnabled }
    static func owner(_ id: String) -> any NativeUIGSimulatorOwner {
        if id == "hoot" { return NativeHootSimulatorOwner.shared }
        return NativeTerminalSessions.shared.session(for: id)
    }
    /// A session's device panel: its first (slot 0) or its second (slot 1). Two at most.
    func entry(_ session: any NativeUIGSimulatorOwner, slot: Int = 0) -> NativeUIGSessionSimulatorController {
        let key = NativePaneArrangement.panelKey(session.sessionId, slot: slot)
        if let entry = entries[key], entry.session === session { return entry }
        let entry = NativeUIGSessionSimulatorController(session: session, slot: slot, defaults: defaults, lifecycleEnabled: lifecycleEnabled)
        // U143 (#195): panels of sessions that ended or were removed, and are not on screen, are let go
        // (with their device view, recorder and tools); a panel shown again starts from its saved layout.
        entries = entries.filter { $0.value.showing || !($0.value.session.ended || $0.value.session.removed) }
        entries[key] = entry; return entry
    }
    /// The panels showing now, first slot first. Reads only: a panel is made when the person opens one (toggle,
    /// addSecond) or the session's host shows it, never by a button drawing itself (21 Oct: with a hundred finished
    /// chats on the bar, every redraw built two video renderers per chat and froze the app).
    func openEntries(_ session: any NativeUIGSimulatorOwner) -> [NativeUIGSessionSimulatorController] {
        [0, 1].compactMap { slot -> NativeUIGSessionSimulatorController? in
            guard let entry = entries[NativePaneArrangement.panelKey(session.sessionId, slot: slot)], entry.session === session else { return nil }
            return entry
        }.filter { $0.layout.isOpen }
    }
    func toggle(_ session: any NativeUIGSimulatorOwner) {
        let entry = entry(session)
        if entry.inOwnWindow {
            NativeFront.onlyForPerson("session simulator window") { windows[entry.key]?.window?.makeKeyAndOrderFront(nil) }
            return
        }
        entry.setOpen(!entry.layout.isOpen)
    }
    /// "Add another device": the second panel (the limit is two).
    func addSecond(_ session: any NativeUIGSimulatorOwner) {
        let first = entry(session), second = entry(session, slot: 1)
        if !first.layout.isOpen { first.setOpen(true) } else if !second.layout.isOpen { second.setOpen(true) }
    }
    func closeAll(_ session: any NativeUIGSimulatorOwner) { for entry in openEntries(session) { close(entry) } }
    func popOut(_ entry: NativeUIGSessionSimulatorController) {
        guard windows[entry.key] == nil else {
            NativeFront.onlyForPerson("session simulator window") { windows[entry.key]?.window?.makeKeyAndOrderFront(nil) }
            return
        }
        entry.inOwnWindow = true; entry.setOpen(true)
        let window = NativeUIGSessionSimulatorWindow(entry: entry) { [weak self] in self?.windows[entry.key] = nil }
        windows[entry.key] = window
        NativeFront.onlyForPerson("session simulator window") { window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil) }
    }
    func moveBack(_ entry: NativeUIGSessionSimulatorController) {
        windows[entry.key]?.returning = true
        entry.inOwnWindow = false; entry.setOpen(true)
        windows[entry.key]?.close(); windows[entry.key] = nil
    }
    func close(_ entry: NativeUIGSessionSimulatorController) {
        entry.setOpen(false); windows[entry.key]?.close(); windows[entry.key] = nil
    }
}

@MainActor private final class NativeUIGSessionSimulatorWindow: NSWindowController, NSWindowDelegate {
    let entry: NativeUIGSessionSimulatorController
    let closed: () -> Void
    var returning = false
    init(entry: NativeUIGSessionSimulatorController, closed: @escaping () -> Void) {
        self.entry = entry; self.closed = closed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: entry.layout.width, height: 740),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = entry.title; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 120, height: 120)
        // Like every phone window: the phone frame alone and its strip (NativeDeviceFloatingWindow);
        // the panel (device picker) only while no device is on show.
        window.contentView = NSHostingView(rootView: NativeUIGSessionSimulatorFloating(entry: entry))
        window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) {
        entry.inOwnWindow = false
        if !returning { entry.setOpen(false) }
        closed()
    }
    func windowDidResize(_ notification: Notification) {
        // The floating phone's width is not the docked panel's width.
        guard window?.isOpaque == true else { return }
        if let width = window?.contentView?.bounds.width { entry.resize(width) }
    }
}

struct NativeUIGSessionSimulatorButton: View {
    let session: any NativeUIGSimulatorOwner
    var panels: [NativeUIGSessionSimulatorController]? = nil
    @State private var store = NativeUIGSessionSimulatorStore.shared
    var body: some View {
        if NativeUIGSessionSimulatorRelease.enabled, !session.isRemote {
            let open = panels?.filter { $0.layout.isOpen } ?? store.openEntries(session)
            let icon = Image(systemName: "iphone").font(.system(size: 13)).padding(5).nativeUIGSelection(!open.isEmpty, capsule: false)
            Group {
                if open.isEmpty {
                    Button { store.toggle(session) } label: { icon }
                        .buttonStyle(.plain)
                        .help("Show a device for this session")
                } else {
                    // Open: the same button offers a second device (two at most) or hides them.
                    Menu {
                        Button("Add another device") { store.addSecond(session) }.disabled(open.count >= 2)
                        Divider()
                        Button(open.count > 1 ? "Hide both devices" : "Hide the device") { store.closeAll(session) }
                    } label: { icon }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(open.count >= 2 ? "Two devices open" : "Add another device, or hide")
                }
            }
            .nativeUIGGreyControl()
            .disabled(session.ended || session.removed)
            .accessibilityLabel("Session devices")
        }
    }
}

/// Wrap ONLY the existing terminal host/overlays, beneath its existing header.
struct NativeUIGSessionSimulatorHost<Content: View>: View {
    let session: any NativeUIGSimulatorOwner
    @ViewBuilder var content: () -> Content
    var panels: [NativeUIGSessionSimulatorController]? = nil
    @State private var store = NativeUIGSessionSimulatorStore.shared
    var body: some View {
        if NativeUIGSessionSimulatorRelease.enabled, !session.isRemote {
            let entries = panels ?? [0, 1].map { store.entry(session, slot: $0) }
            let docks = entries.map { entry -> NativeUIGSessionSimulatorSplit<Content>.Dock in
                return .init(slot: entry.slot, state: Binding(get: { entry.layout }, set: { entry.layout = $0; entry.saveLayout() }),
                             detached: entry.inOwnWindow, title: entry.title, view: AnyView(NativeUIGSessionSimulatorPanel(entry: entry)))
            }
            NativeUIGSessionSimulatorSplit(docks: docks, sessionId: panels == nil ? session.sessionId : nil, content: content)
                .onChange(of: entries.map { $0.selected?.id }, initial: true) { _, _ in
                    guard panels == nil else { return }
                    let selected = entries.compactMap(\.selected)
                    if session.sessionId == "hoot" { NativeHootChatModel.shared.attachPhones(selected) }
                    else if let chat = session as? NativeTerminalSession, chat.isChat { chat.chatModel().attachPhones(selected) }
                }
        } else { content() }
    }
}

/// A session's device in its own window: the phone frame alone with the attached strip, as a device
/// opened from the Simulators page; the panel with its device picker until a device is on show.
struct NativeUIGSessionSimulatorFloating: View {
    @Bindable var entry: NativeUIGSessionSimulatorController
    var body: some View {
        Group {
            if let id = entry.model.device?.id, id == entry.ticket?.deviceID {
                DeviceOpenView(model: entry.model, showsDeviceBack: false, floating: true)
                    .background(NativeDeviceFloatingWindow(model: entry.model,
                                                           moveBack: { NativeUIGSessionSimulatorStore.shared.moveBack(entry) }))
            } else {
                NativeUIGSessionSimulatorPanel(entry: entry)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .ignoresSafeArea()
        .onAppear { entry.appear() }.onDisappear { entry.disappear() }
    }
}
