import SwiftUI
import TerminalDeckNativeCore

/// A child of the existing Machines/server page. The parent owns Apps/Advanced.
struct NativeDockerAdvancedView: View {
    @Environment(\.nativeServerCheckConnection) private var checkConnection
    @State private var model: NativeDockerModel
    @State private var removing: NativeDockerRemoval?
    @State private var usesWideLayout = false

    init(target: NativeDockerTarget, client: NativeDockerClient) {
        _model = State(initialValue: NativeDockerModel(target: target, client: client))
    }
    init(serverID: String, serverName: String) {
        let target = NativeDockerTarget.server(id: serverID, name: serverName)
        self.init(target: target, client: .bridge(target: target))
    }
    init() { self.init(target: .thisMac, client: .bridge(target: .thisMac)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                NativeSettingsHead(title: "Docker", blurb: nil)
                Spacer(minLength: 0)
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.busy)
            }
            NativePageScope(path: nil, machine: model.target.name, detail: version)
            if let outcome = model.outcome {
                NativePageNote(outcome, busy: model.busy)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.streamCleanupPending {
                HStack(alignment: .top, spacing: 8) {
                    NativePageNote(model.streamCleanupBusy ? "Closing live stream…" : "Docker hasn’t confirmed the previous live stream closed.",
                                   busy: model.streamCleanupBusy)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry closing live stream", action: model.retryClosingLiveStream)
                        .disabled(model.streamCleanupBusy || model.busy)
                }
            }
            if let error = model.error, model.availability != nil, !usesWideLayout, model.selection != nil {
                HStack(alignment: .top, spacing: 8) {
                    NativePageNote(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Try again", action: model.refresh).disabled(model.loading || model.busy)
                }
            }
            if model.availability == .missingDocker {
                missingDocker
            } else if model.availability == .noLocalSocket {
                NativePageEmpty(symbol: "shippingbox", title: "This Mac has no running Docker",
                                action: PageEmptyAction(label: "Check again", perform: model.refresh)) {
                    Text("Start Docker Desktop, OrbStack or Colima on this Mac, then check again.")
                }
            } else if model.availability == nil, let error = model.error, !model.loading {
                let reason = unavailableReason(error)
                NativePageEmpty(symbol: "shippingbox", title: reason.title,
                                action: PageEmptyAction(label: model.target.isLocal ? "Check again" : checkConnection == nil ? "Read again" : "Check connection",
                                                       perform: { if let checkConnection, !model.target.isLocal { checkConnection() } else { model.refresh() } })) {
                    Text(reason.message)
                }
            } else {
                resourceLayout
            }
        }
        .frame(maxWidth: .infinity, minHeight: 480, alignment: .topLeading)
        .background(.background)
        .onGeometryChange(for: Bool.self, of: { $0.size.width >= 880 }) { usesWideLayout = $0 }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: model.section) { _, _ in removing = nil }
        .onChange(of: model.selection) { _, _ in removing = nil }
        .onChange(of: model.loading) { _, loading in if loading { removing = nil } }
        .onChange(of: model.detail?.confirmationName) { _, _ in removing = nil }
        .confirmationDialog(removing.map { "Remove \($0.item.name)?" } ?? "Remove this resource?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            if let request = removing {
                let item = request.item
                Button("Remove \(item.confirmationName)", role: .destructive) {
                    model.run(.remove, item: item, namedConfirmation: item.confirmationName, in: request.section); removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            }
        } message: {
            if let request = removing {
                Text("Remove \(request.section.singular) ‘\(request.item.confirmationName)’ from \(model.target.name)? This cannot be undone.")
            }
        }
        .sheet(isPresented: Binding(get: { model.installationPreview != nil }, set: { if !$0 { model.dismissInstall() } })) {
            if let preview = model.installationPreview { installSheet(preview) }
        }
    }

    private var version: String? {
        if case .available(let version) = model.availability { return "Docker \(version)" }
        return nil
    }

    private func unavailableReason(_ error: String) -> NativeDockerUnavailableReason {
        let problem: String?
        if case .server(let id, _) = model.target,
           let state = NativeServersModel.shared.states[id], state.link == .failed {
            problem = state.problem
        } else { problem = nil }
        return .connection(problem: problem, fallback: error, isLocal: model.target.isLocal)
    }

    private var missingDocker: some View {
        NativePageEmpty(symbol: "shippingbox", title: "Docker isn’t installed on this server",
                        action: model.target.isLocal ? nil : PageEmptyAction(label: "Install Docker", busy: model.busy || model.loading || model.error != nil,
                                                                            perform: model.previewInstall)) {
            Text(model.target.isLocal ? "Start Docker Desktop, OrbStack or Colima, then refresh."
                 : "Review Docker’s official installation command before installing it on \(model.target.name).")
        }
    }

    private var resourceLayout: some View {
        // AnyLayout moves the same children instead of mounting two candidates
        // or replacing the detail subtree. Logs and PTY ownership survive resize.
        let layout = usesWideLayout
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        let showsInventory = usesWideLayout || model.selection == nil
        let showsDetail = usesWideLayout || model.selection != nil
        return layout {
            Group {
                if usesWideLayout {
                    NativeDockerSectionList(section: sectionBinding, counts: model.counts)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Docker resources", selection: sectionBinding) {
                            ForEach(NativeDockerSection.allCases) { section in Text(section.title).tag(section) }
                        }.pickerStyle(.menu)
                        if model.selection != nil {
                            Button { selectionBinding.wrappedValue = nil } label: {
                                Label("Back to \(model.section.title.lowercased())", systemImage: "chevron.left")
                            }
                        }
                    }
                }
            }
            .frame(width: usesWideLayout ? 180 : nil, alignment: .leading)
            .padding(.bottom, usesWideLayout ? 0 : 16)
            Divider().frame(width: usesWideLayout ? nil : 0, height: usesWideLayout ? nil : 0)
                .opacity(usesWideLayout ? 1 : 0).accessibilityHidden(!usesWideLayout)
            inventory.frame(width: usesWideLayout ? 270 : nil)
                .frame(height: showsInventory ? nil : 0)
                .opacity(showsInventory ? 1 : 0)
                .disabled(!showsInventory)
                .allowsHitTesting(showsInventory).accessibilityHidden(!showsInventory)
            Divider().frame(width: usesWideLayout ? nil : 0, height: usesWideLayout ? nil : 0)
                .opacity(usesWideLayout ? 1 : 0).accessibilityHidden(!usesWideLayout)
            detail.frame(minWidth: usesWideLayout ? 320 : nil, maxWidth: .infinity, alignment: .topLeading)
                .frame(height: showsDetail ? nil : 0)
                .opacity(showsDetail ? 1 : 0)
                .disabled(!showsDetail)
                .allowsHitTesting(showsDetail).accessibilityHidden(!showsDetail)
        }
    }

    private var inventory: some View {
        @Bindable var model = model
        return NativeDockerInventoryList(items: model.items, selection: selectionBinding, search: $model.search,
                                         section: model.section, loading: model.loading, error: model.error,
                                         retry: model.refresh)
    }

    @ViewBuilder private var detail: some View {
        if model.selection == nil {
            NativeDockerEmptyView(symbol: model.section.symbol, title: "Choose a \(model.section.singular)",
                                  message: "Select a row to see its details.")
        } else if model.detailLoading {
            VStack(alignment: .leading, spacing: 16) {
                NativeSettingsHead(title: "Reading details", blurb: nil).redacted(reason: .placeholder)
                NativeDockerFactsView(facts: [NativeDockerFact(label: "Name", value: "Resource name"),
                                             NativeDockerFact(label: "Status", value: "Resource status")])
                    .redacted(reason: .placeholder).accessibilityHidden(true)
                NativePageNote("Reading Docker details…", busy: true).frame(maxHeight: 40)
            }
        } else if let error = model.detailError {
            NativePageEmpty(symbol: model.section.symbol, title: "Could not read these details",
                            action: PageEmptyAction(label: "Try again", perform: model.selectCurrent)) { Text(error) }
        } else if let item = model.selected {
            if model.section == .containers {
                VStack(alignment: .leading, spacing: 16) {
                    NativeDockerContainerHeader(item: item, busy: model.busy || model.loading || model.error != nil,
                                                onStart: { model.run(.start, item: item) },
                                                onStop: { model.run(.stop, item: item) },
                                                onRestart: { model.run(.restart, item: item) },
                                                onRemove: { removing = NativeDockerRemoval(item: item, section: .containers) })
                    Picker("Container view", selection: tabBinding) {
                        ForEach(NativeDockerContainerTab.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).nativeUIGGreyControl()
                    switch model.tab {
                    case .overview:
                        if item.running == true {
                            NativeDockerUsageView(usage: model.usage, loading: model.streamConnecting, error: model.streamError)
                            if model.streamError != nil { Button("Reconnect live usage", action: model.retryStream).disabled(model.loading || model.error != nil) }
                        } else { NativePageNote("CPU and memory are available while this container runs.").frame(maxHeight: 44) }
                        NativeDockerFactsView(facts: item.facts)
                    case .logs:
                        if model.logBuffer.droppedLines > 0 {
                            NativePageNote("Showing the newest log lines; older output was trimmed.").frame(maxHeight: 40)
                        }
                        NativeDockerLogsView(lines: model.logBuffer.lines, connecting: model.streamConnecting,
                                             error: model.streamError, onRetry: model.retryStream, onClear: model.clearLogs)
                    case .terminal:
                        if let terminal = model.terminalModel {
                            NativeDockerTerminalView(model: terminal).id(ObjectIdentifier(terminal)).frame(minHeight: 300)
                        }
                        else if let error = model.streamError { NativePageNote(error) }
                        else { NativePageNote("Start this container to open its terminal.") }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 8) {
                        NativeSettingsHead(title: item.name, blurb: item.subtitle.isEmpty ? nil : item.subtitle)
                        Spacer(minLength: 0)
                        if model.section != .projects {
                            Button("Remove", role: .destructive) {
                                removing = NativeDockerRemoval(item: item, section: model.section)
                            }.disabled(model.busy || model.loading || model.error != nil)
                        }
                    }
                    NativeDockerFactsView(facts: item.facts)
                    if model.section == .projects {
                        NativeSettingsProse(text: "Manage this project through its containers. Compose projects are grouped by their Docker labels.")
                        ForEach(item.members) { member in
                            Button { model.showContainer(member.id) } label: {
                                HStack(spacing: 8) {
                                    Label(member.name, systemImage: "shippingbox")
                                    Spacer(minLength: 8)
                                    Text(member.state).font(.caption)
                                    Image(systemName: "chevron.right").font(.caption)
                                }.foregroundStyle(.secondary).contentShape(Rectangle())
                            }.buttonStyle(.plain).padding(.vertical, 5)
                                .accessibilityLabel("Open container \(member.name), \(member.state)")
                        }
                    }
                }
            }
        }
    }

    // A user choice starts its read synchronously. Routing and refresh choices
    // are handled by the model; neither relies on a later onChange callback.
    private var sectionBinding: Binding<NativeDockerSection> {
        Binding(get: { model.section }, set: { next in
            guard next != model.section else { return }
            removing = nil; model.section = next; model.changeSection()
        })
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { model.selection }, set: { next in
            guard next != model.selection else { return }
            removing = nil; model.selection = next; model.selectCurrent()
        })
    }

    private var tabBinding: Binding<NativeDockerContainerTab> {
        Binding(get: { model.tab }, set: { next in
            guard next != model.tab else { return }
            model.tab = next; model.changeTab()
        })
    }

    private func installSheet(_ preview: NativeDockerInstallation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeSettingsHead(title: "Install Docker on \(model.target.name)", blurb: nil)
            NativeSettingsProse(text: preview.explanation)
            Text(preview.command).font(.callout.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            NativeSettingsProse(text: "This needs administrator access. Terminal Deck will ask for approval through its usual permission prompt.")
            HStack {
                Button("Cancel", role: .cancel) { model.dismissInstall() }
                Spacer()
                Button("Continue to approval") { model.install() }.disabled(model.busy)
            }
        }.padding(24).frame(width: 560)
    }
}

private struct NativeDockerRemoval {
    let item: NativeDockerItem
    let section: NativeDockerSection
}
