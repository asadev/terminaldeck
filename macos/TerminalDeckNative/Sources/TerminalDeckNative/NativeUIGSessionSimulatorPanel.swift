import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Thin frame only. Everything below its picker is the Simulators page's view.
struct NativeUIGSessionSimulatorPanel: View {
    @Bindable var entry: NativeUIGSessionSimulatorController
    @State private var switching: DeviceEntry?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(entry.title).font(.callout.weight(.semibold)); Spacer(minLength: 4)
                Button {
                    if entry.inOwnWindow { NativeUIGSessionSimulatorStore.shared.moveBack(entry) }
                    else { NativeUIGSessionSimulatorStore.shared.popOut(entry) }
                } label: { Image(systemName: entry.inOwnWindow ? "arrow.down.left.square" : "arrow.up.forward.square") }
                .help(entry.inOwnWindow ? "Move back to this session" : "Open in its own window")
                Button { NativeUIGSessionSimulatorStore.shared.close(entry) } label: { Image(systemName: "xmark") }
                    .help("Close simulator panel")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(12)
            picker.padding(.horizontal, 12).padding(.bottom, 8)
            if !entry.problem.isEmpty {
                Text(entry.problem).font(.callout).textSelection(.enabled).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            NativeUIGSimulatorDeviceArea(model: entry.model, selected: entry.selected,
                showingLiveScreen: entry.model.device?.id != nil && entry.model.device?.id == entry.ticket?.deviceID,
                working: entry.busy ? "Opening…" : "", refreshing: entry.busy,
                perform: { if let selected = entry.selected { Task { await entry.select(selected) } } },
                refresh: { Task { await entry.model.refresh() } },
                choose: { entry.pickerShown = true })
        }
        // The framed phone floats on the session's own page colour: no card, no lines.
        .modifier(NativeDevicePanelBackground()).nativeUIGGreyControl()
        .overlay(alignment: .topLeading) {
            if entry.inOwnWindow {
                // Match the docked title grip; both right-hand buttons stay outside its hit area.
                HStack(spacing: 0) {
                    Color.clear.frame(height: 40)
                        .contentShape(.rect)
                        .nativePopoutDragBack(perform: { NativeUIGSessionSimulatorStore.shared.moveBack(entry) })
                        .help("Drag back over the main window to return this device")
                    Color.clear.frame(width: 76, height: 40).allowsHitTesting(false)
                }
            }
        }
        .onAppear { entry.appear() }.onDisappear { entry.disappear() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in entry.model.appBecameActive() }
        .alert("Switch device?", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } })) {
            Button("Keep this device", role: .cancel) { switching = nil }
            Button("Discard markers and switch", role: .destructive) {
                if let device = switching { Task { await entry.select(device) } }; switching = nil
            }
        } message: { Text("The marked elements have not been sent to this session.") }
    }
    /// The scrollable device list with Start and ⋯ per row (NativeUIGDevicePicker).
    private var picker: some View {
        NativeUIGDevicePicker(entry: entry, confirmSwitch: { switching = $0 })
    }
}
