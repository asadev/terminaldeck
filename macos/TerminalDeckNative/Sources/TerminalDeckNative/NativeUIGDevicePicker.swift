import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The phone panel's "Choose a device" list (ANDROID lane, 10 Oct). Asad: "lets give start button and three
/// dots every with all with scrollable list to see all list". A popover with every device (running first,
/// green dot), a search field past eight, a real Start (or Open) button per row, and the Simulators page's
/// own ⋯ menu (NativeFIXESDeviceContextMenu with the picker's sections). Used by every phone panel.
struct NativeUIGDevicePicker: View {
    @Bindable var entry: NativeUIGSessionSimulatorController
    /// Markers not yet sent: switching asks first (the panel's alert).
    var confirmSwitch: (DeviceEntry) -> Void
    var body: some View {
        NativeSessionButton { entry.pickerShown.toggle() } label: {
            HStack(spacing: 3) {
                Text(entry.selected.map { Self.label($0) } ?? "Choose a device").lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .buttonStyle(.borderless).font(.caption).help(entry.selected?.name ?? "Choose a device on this Mac")
        .popover(isPresented: $entry.pickerShown, arrowEdge: .bottom) {
            NativeUIGDeviceList(entry: entry, confirmSwitch: confirmSwitch, chosen: { entry.pickerShown = false }).frame(width: 340)
        }
    }

    static func ordered(_ devices: [DeviceEntry]) -> [DeviceEntry] { NativeUIGDeviceList.ordered(devices) }
    static func os(_ device: DeviceEntry) -> String { NativeUIGDeviceList.os(device) }
    static func label(_ device: DeviceEntry) -> String { NativeUIGDeviceList.label(device) }
}

/// The device list itself: in the picker's popover, and filling the panel while no device is chosen.
struct NativeUIGDeviceList: View {
    @Bindable var entry: NativeUIGSessionSimulatorController
    var confirmSwitch: (DeviceEntry) -> Void
    /// The popover closes; nil in the panel body.
    var chosen: (() -> Void)? = nil
    /// The panel body fills its height; the popover stops at 360 pt.
    var fills = false
    @State private var search = ""

    var body: some View {
        let all = Self.ordered(entry.entries)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = query.isEmpty ? all : all.filter { ($0.name + " " + $0.runtime).lowercased().contains(query) }
        return VStack(spacing: 0) {
            if all.count > 8 {
                // Same side insets as the rows (6 + 6), never wider than the panel.
                NativeSessionTextField("Search devices", text: $search).textFieldStyle(.roundedBorder)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            }
            if entry.ticket?.deviceID != nil {
                NativeSessionButton { Task { await entry.detach() }; chosen?() } label: { Label("Detach device", systemImage: "eject") }
                    .buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { device in row(device) }
                    if rows.isEmpty {
                        Text(all.isEmpty ? "No devices on this Mac" : "No device matches").font(.callout).foregroundStyle(.secondary).padding(16)
                    }
                }.padding(6)
            }
            .frame(maxHeight: fills ? .infinity : 360)
            Divider()
            NativeSessionButton { Task { await entry.model.refresh() } } label: { Label("Refresh devices", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: !fills)
    }

    private func row(_ device: DeviceEntry) -> some View {
        let current = device.id == entry.selected?.id
        let working = entry.busy || entry.model.busy[device.id] != nil
        return HStack(spacing: 8) {
            Circle().fill(device.available ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                .accessibilityLabel(device.available ? "Running" : "Off")
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.callout.weight(current ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                let os = Self.os(device)
                if !os.isEmpty { Text(os).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if current {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            } else {
                NativeSessionButton(device.available ? "Open" : "Start") { choose(device) }
                    .controlSize(.small)
                    .disabled(working || (!device.available && !device.canBoot))
                    .help(device.available ? "Show \(device.name) in this panel" : "Start \(device.name) and show it in this panel")
            }
            Color.clear.frame(width: 26, height: 24) // the ⋯ button sits here (the shared row menu's overlay)
        }
        .padding(.leading, 8).padding(.vertical, 5)
        .background(current ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(.rect)
        .modifier(NativeFIXESDeviceContextMenu(entry: device, model: entry.model, start: { choose(device) },
                                               selected: current, forceEllipsis: true,
                                               sections: FIXESDeviceContextAction.pickerSections(for: device)))
    }

    private func choose(_ device: DeviceEntry) {
        chosen?()
        if !entry.model.markers.isEmpty { confirmSwitch(device) } else { Task { await entry.select(device) } }
    }

    /// Running first, then iOS before Android, then by name.
    static func ordered(_ devices: [DeviceEntry]) -> [DeviceEntry] {
        devices.sorted {
            if $0.available != $1.available { return $0.available }
            if $0.platform != $1.platform { return $0.platform == "ios" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    /// "iOS 27.0", "Android 16 (API 36)", or "Android" when the emulator has not said; never an empty field.
    static func os(_ device: DeviceEntry) -> String {
        let runtime = device.runtime.trimmingCharacters(in: .whitespaces)
        if !runtime.isEmpty { return runtime }
        return device.platform == "ios" ? "iOS" : device.platform == "android" ? "Android" : ""
    }
    static func label(_ device: DeviceEntry) -> String {
        let os = os(device)
        return os.isEmpty ? device.name : device.name + " · " + os
    }
}

/// The one way in to the phone panel (the Simulators page is retired, 10 Oct): the given session's panel, or
/// Hoot's when there is no session; with a device chosen (started if it is off) or the dropdown open.
@MainActor enum NativeUIGPhonePanel {
    @discardableResult
    /// `ownWindow`: the panel goes in its own phone window (opened with no session and not on Hoot's page).
    static func open(session: NativeTerminalSession?, deviceID: String? = nil, slot: Int? = nil, ownWindow: Bool = false) -> NativeUIGSessionSimulatorController {
        let owner: any NativeUIGSimulatorOwner
        if let session { owner = session } else { owner = NativeUIGSessionSimulatorStore.owner("hoot") }
        let store = NativeUIGSessionSimulatorStore.shared
        let panels = [0, 1].map { store.entry(owner, slot: $0) }
        let selectedSlot = slot.flatMap { [0, 1].contains($0) ? $0 : nil }
            ?? deviceID.flatMap { id in panels.first { $0.ticket?.deviceID == id }?.slot }
            ?? (deviceID == nil ? panels.first(where: { $0.layout.isOpen })?.slot : panels.first(where: { !$0.layout.isOpen || $0.ticket?.deviceID == nil })?.slot)
            ?? 0
        let entry = panels[selectedSlot]
        if owner.isRemote { entry.problem = "Device panels belong to local sessions."; return entry }
        if let deviceID, slot == nil, panels.allSatisfy({ $0.layout.isOpen && $0.ticket?.deviceID != nil }), !panels.contains(where: { $0.ticket?.deviceID == deviceID }) {
            entry.problem = "Two devices are already open. Pick a device in one panel to replace it."; return entry
        }
        if let deviceID, !entry.model.markers.isEmpty, entry.ticket?.deviceID != deviceID {
            entry.setOpen(true); entry.pickerShown = true; entry.problem = "Keep or discard this panel's markers before changing device."; return entry
        }
        if entry.inOwnWindow || ownWindow { store.popOut(entry) }
        else if !entry.layout.isOpen { entry.setOpen(true) }
        Task { @MainActor in
            _ = await entry.model.refresh()
            if let deviceID, let device = entry.entries.first(where: { $0.id == deviceID }) {
                if entry.ticket?.deviceID != deviceID { await entry.select(device) }
            } else if entry.ticket?.deviceID == nil {
                entry.pickerShown = true
            }
        }
        return entry
    }
}
