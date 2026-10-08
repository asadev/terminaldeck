import Foundation
import SwiftUI
import TerminalDeckNativeCore

/// Device Hub's two columns, using the existing simulator model, live screen,
/// hardware toolbar and inspector. NativeSimulatorScreen keeps their lifecycle.
struct NativeUIGSimulatorScreen: View {
    let model: NativeSimulatorModel
    @State private var selectedID: String?
    @State private var startingEntry: DeviceEntry?
    @State private var pendingSelection: DeviceEntry?
    @State private var pendingOpen = false
    @State private var actionTask: Task<Void, Never>?
    @State private var pendingActionID: String?
    @State private var actionGeneration = 0
    @State private var refreshing = false

    private var entries: [DeviceEntry] { UIGSimulatorPresentation.entries(model.list, open: model.device) }
    private var selected: DeviceEntry? {
        entries.first(where: { $0.id == selectedID })
            ?? (startingEntry?.id == selectedID ? startingEntry : nil)
    }
    private var showingLiveScreen: Bool {
        guard let device = model.device else { return false }
        return device.id == selectedID || (startingEntry != nil && startingEntry?.id == selectedID)
    }

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                if !showingLiveScreen && (!model.problem.isEmpty || !model.said.isEmpty) {
                    NativeUIGSimulatorStatus(problem: model.problem, said: model.said)
                }
                main
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.list, initial: true) { _, _ in reconcileSelection() }
        .onAppear { if selectedID == nil, model.device != nil { model.back() } }
        .onChange(of: model.device?.id) { _, id in
            if let id, let startingEntry, startingEntry.id == selectedID {
                selectedID = id
                self.startingEntry = nil
            }
        }
        .onDisappear { cancelAction(); selectedID = nil; model.back() }
        .alert("Switch device?", isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })) {
            Button("Keep this screen", role: .cancel) { pendingSelection = nil }
            Button("Discard markers and switch", role: .destructive) {
                if let entry = pendingSelection {
                    choose(entry)
                    if pendingOpen && !UIGSimulatorPresentation.opensOnSelection(entry) { perform(entry) }
                }
                pendingSelection = nil
            }
        } message: {
            Text("The \(model.markers.count) marked element\(model.markers.count == 1 ? "" : "s") on this screen \(model.markers.count == 1 ? "has" : "have") not been sent.")
        }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Devices").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: refresh) {
                    Label("Refresh devices", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(refreshing)
                .help("Refresh devices")
                .accessibilityLabel("Refresh devices")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.list == nil && entries.isEmpty && model.problem.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in NativeUIGSimulatorRailSkeleton() }
                    } else {
                        ForEach(entries) { entry in
                            NativeUIGSimulatorRailRow(entry: entry, selected: selectedID == entry.id,
                                                      working: working(entry), openAction: {
                                requestSelection(entry, open: true)
                            }) {
                                requestSelection(entry)
                            }
                            .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .onChange(of: selectedID) { _, id in
                if let id { reader.scrollTo(id, anchor: .center) }
            }
            }
        }
        .background(.quaternary.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Phones and simulators")
    }

    @ViewBuilder private var main: some View {
        if showingLiveScreen {
            DeviceOpenView(model: model, showsDeviceBack: false)
        } else if let selected {
            NativeUIGSimulatorStoppedDevice(entry: selected, working: working(selected)) { perform(selected) }
        } else if model.list == nil {
            if model.problem.isEmpty {
                NativePageNote("Loading devices…", busy: true)
            } else {
                NativePageEmpty(symbol: "iphone", title: "Devices could not be read",
                                action: PageEmptyAction(label: "Try again", busy: refreshing, perform: refresh)) {
                    Text("Try again when the app is connected.")
                }
            }
        } else if let list = model.list, !list.available {
            NativePageEmpty(symbol: "iphone", title: "Simulators are not available here",
                            action: PageEmptyAction(label: "Try again", busy: refreshing, perform: refresh)) {
                Text(list.reason)
            }
        } else if !entries.isEmpty {
            NativePageEmpty(symbol: "iphone", title: "Choose a device") {
                Text("Pick a phone or simulator from the list, or use its Start or Open button.")
            }
        } else {
            NativePageEmpty(symbol: "iphone", title: "No simulators or phones yet",
                            action: PageEmptyAction(label: "Refresh", busy: refreshing, perform: refresh)) {
                Text("Create a simulator in Xcode or an emulator in Android Studio, or connect a supported phone.")
            }
        }
    }

    private func working(_ entry: DeviceEntry) -> String {
        model.busy[entry.id]
            ?? (model.opening == entry.id ? "Opening…"
                : pendingActionID == entry.id ? (startingEntry?.id == entry.id ? "Starting…" : "Opening…") : "")
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await model.refresh()
            refreshing = false
        }
    }

    private func reconcileSelection() {
        // Android's off-device id can change when it starts. Keep the selected
        // placeholder until start() supplies the actual running id.
        if let startingEntry, startingEntry.id == selectedID { return }
        let id = UIGSimulatorPresentation.selectedID(in: entries, selected: selectedID,
                                                     open: model.device?.id,
                                                     remembered: nil)
        guard id != selectedID else { return }
        if let entry = entries.first(where: { $0.id == id }) {
            choose(entry)
        } else {
            cancelAction()
            selectedID = nil
            model.back()
        }
    }

    private func requestSelection(_ entry: DeviceEntry, open: Bool = false) {
        guard entry.id != selectedID else {
            if open { perform(entry) }
            return
        }
        if model.inspecting && !model.markers.isEmpty {
            pendingSelection = entry
            pendingOpen = open
        } else {
            choose(entry)
            if open && !UIGSimulatorPresentation.opensOnSelection(entry) { perform(entry) }
        }
    }

    private func choose(_ entry: DeviceEntry) {
        cancelAction()
        selectedID = entry.id
        // back() closes the previous stream and invalidates any pending reply.
        // A stopped device is never booted by selecting its row.
        model.back()
        if UIGSimulatorPresentation.opensOnSelection(entry) { perform(entry) }
    }

    private func cancelAction() {
        actionGeneration += 1
        actionTask?.cancel()
        actionTask = nil
        pendingActionID = nil
        startingEntry = nil
    }

    private func perform(_ entry: DeviceEntry) {
        guard UIGSimulatorPresentation.canPerformAction(entry), working(entry).isEmpty else { return }
        cancelAction()
        let generation = actionGeneration
        if UIGSimulatorPresentation.action(entry) == .start { startingEntry = entry }
        pendingActionID = entry.id
        actionTask = Task {
            if UIGSimulatorPresentation.action(entry) == .start {
                await model.start(entry)
            } else {
                await model.open(entry.id)
            }
            guard !Task.isCancelled, generation == actionGeneration else { return }
            if let device = model.device {
                selectedID = device.id
            }
            startingEntry = nil
            pendingActionID = nil
            actionTask = nil
        }
    }
}

private struct NativeUIGSimulatorRailSkeleton: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone").frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("iPhone Simulator").font(.callout.weight(.medium))
                Text("Simulator        27.0").font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .foregroundStyle(.secondary)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

private struct NativeUIGSimulatorStatus: View {
    let problem: String
    let said: String
    var body: some View {
        Text(problem.isEmpty ? said : problem)
            .font(.callout)
            .foregroundStyle(problem.isEmpty ? Color.secondary : Color.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }
}
