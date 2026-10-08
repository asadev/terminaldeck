import SwiftUI
import TerminalDeckNativeCore

/// The default simple view inside the existing server page. DKA owns the host
/// Apps/Advanced switch; this view never creates another server destination.
struct NativeAppsScreen: View {
    @Environment(\.nativeServerCheckConnection) private var checkConnection
    let serverID: String
    let serverName: String
    @State private var model: NativeAppsModel

    init(serverID: String, serverName: String) {
        self.serverID = serverID
        self.serverName = serverName
        _model = State(initialValue: NativeAppsModel(serverID: serverID))
    }

    var body: some View {
        Group {
            if let failure = connectionFailure {
                NativePageEmpty(symbol: "server.rack", title: failure.title,
                                action: PageEmptyAction(label: checkConnection == nil ? "Read again" : "Check connection",
                                                        perform: {
                                                            if let checkConnection { checkConnection() }
                                                            else { model.refresh() }
                                                        })) {
                    NativeSettingsProse(text: failure.message)
                }
                .onAppear { model.backToList() }
            } else if let app = model.selectedApp, model.selectedID != nil {
                NativeAppsDetailView(model: model, app: app, onBack: model.backToList)
            } else {
                appsList
            }
        }
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $model.showingNewApp, onDismiss: model.cancelCatalog) {
            NativeAppsNewAppView(repositories: model.repositories, templates: model.templates,
                                 catalogLoading: model.catalogLoading, catalogProblem: model.catalogProblem,
                                 busy: model.busy != nil, problem: model.displayProblem,
                                 canChange: model.canChange, writesUnavailableReason: model.writesUnavailableReason,
                                 onReloadCatalog: model.loadCatalog,
                                 onCancel: { model.cancelCatalog(); model.showingNewApp = false }, onCreate: model.create)
                .interactiveDismissDisabled(model.busy != nil)
        }
        .onChange(of: DeckProject.current) { _, _ in
            if model.showingNewApp { model.cancelCatalog(); model.loadCatalog() }
        }
    }

    private var connectionFailure: NativeDockerUnavailableReason? {
        guard let state = NativeServersModel.shared.states[serverID], state.link == .failed else { return nil }
        return NativeDockerUnavailableReason.connection(problem: state.problem,
                                                        fallback: "App data could not be read from this server.", isLocal: false)
    }

    private var appsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                NativeSettingsHead(title: "Apps", blurb: "Sites, tools and databases running on this server.")
                Spacer(minLength: 12)
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.busy != nil)
                Button { model.newApp() } label: { Label("New app", systemImage: "plus") }
                    .disabled(model.busy != nil || !model.canChange)
                    .help(model.writesUnavailableReason ?? "Create an app on this server.")
            }
            NativePageScope(path: nil, machine: serverName,
                            detail: model.loading ? "Loading apps…" : "\(model.apps.count) \(model.apps.count == 1 ? "app" : "apps")")
            if model.checkingCapabilities {
                NativePageNote("Checking server support…", busy: true).frame(height: 28)
            } else if let reason = model.writesUnavailableReason {
                NativeSettingsProse(text: reason).font(.callout)
                Button("Check again", action: model.refreshCapabilities)
                    .disabled(model.busy != nil)
            }
            if let problem = model.displayProblem {
                NativeCodingAINotice(tone: .error, text: problem)
                if !model.loading, problem != model.writesUnavailableReason {
                    Button("Read again", action: model.refresh).disabled(model.busy != nil)
                }
            }
            if let notice = model.notice, notice != model.displayProblem { NativeSettingsProse(text: notice).font(.callout) }
            if let busy = model.busy { NativePageNote(busy + "…", busy: true).frame(maxHeight: 28) }

            if model.loading, model.apps.isEmpty {
                NativeAppsListSkeleton()
            } else if model.apps.isEmpty, model.displayProblem == nil {
                NativePageEmpty(symbol: "square.stack.3d.up", title: "No apps yet",
                                action: model.canChange ? PageEmptyAction(label: "New app", perform: model.newApp) : nil) {
                    Text("Deploy a GitHub repository, start from a template, or create a database.")
                }
            } else if !model.apps.isEmpty {
                TextField("Search apps or addresses", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search apps or addresses")
                if model.filteredApps.isEmpty {
                    NativePageEmpty(symbol: "magnifyingglass", title: "No matching apps",
                                    action: PageEmptyAction(label: "Clear search", perform: { model.search = "" })) {
                        Text("Try another name or address.")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.filteredApps) { app in
                                NativeAppsListRow(app: app, onOpen: { model.select(app) })
                            }
                        }
                    }
                    if !model.search.isEmpty {
                        Text("\(model.filteredApps.count) of \(model.apps.count) apps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, MachinesPage.gutter)
        .padding(.vertical, 24)
        .frame(maxWidth: MachinesPage.measure, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Compact gray rows copy the existing Store rail and server-row spacing.
private struct NativeAppsListRow: View {
    let app: NativeAppsSummary
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: app.kind == "app" ? "app.dashed" : "externaldrive")
                        .font(.body).foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
                        Text(NativeAppsRules.friendlyStatus(app.status))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(app.name), \(NativeAppsRules.friendlyStatus(app.status))")

            if let url = NativeAppsRules.safeAddress(app.address) {
                Link(destination: url) {
                    Label(url.host ?? "Open app", systemImage: "arrow.up.right")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .help(url.absoluteString)
                .accessibilityLabel("Open address for \(app.name)")
            } else {
                Text(app.kind == "app" ? "No address yet" : "Database")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(action: onOpen) {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(app.name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}

/// New shared candidate: native row placeholders with the existing redacted style.
struct NativeAppsListSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            NativePageNote("Loading apps…", busy: true).frame(height: 28)
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    Image(systemName: "app.dashed").frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("App name").font(.callout.weight(.medium))
                        Text("Checking status").font(.caption)
                    }
                    Spacer()
                    Text("app.server.address").font(.callout)
                }
                .padding(.horizontal, 8).padding(.vertical, 9)
                .foregroundStyle(.secondary).redacted(reason: .placeholder)
                .accessibilityHidden(true)
            }
        }
    }
}
