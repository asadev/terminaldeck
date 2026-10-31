import SwiftUI
import TerminalDeckNativeCore

/// Content-only bridge to the existing Apps capability. The server dashboard
/// remains the route; one inspector retains deploy history, rollback and backups.
struct NativeMACHINESManagedApps: View {
    let server: CodingAIServer
    let live: Bool
    var fixtureApps: [NativeAppsSummary] = []
    var onRows: ([NativeAppsSummary]) -> Void = { _ in }
    @Binding var filter: String
    @State private var model: NativeAppsModel
    @State private var hovering: String?
    @State private var removing: NativeAppsSummary?
    @State private var confirmationName = ""

    init(server: CodingAIServer, filter: Binding<String>, live: Bool = true,
         fixtureApps: [NativeAppsSummary] = [], onRows: @escaping ([NativeAppsSummary]) -> Void = { _ in }) {
        self.server = server; _filter = filter; self.live = live; self.fixtureApps = fixtureApps; self.onRows = onRows
        _model = State(initialValue: NativeAppsModel(serverID: server.id))
    }
    @State private var shownApps: MACHINESShownAppsModel?
    /// Show only these apps: a hidden app is not listed here either.
    private var rows: [NativeAppsSummary] {
        (live ? model.apps : fixtureApps).filter { app in shownApps.map { $0.isOn(app.name) } ?? true }
    }
    private var visible: [NativeAppsSummary] {
        rows.filter { filter == "All" || (filter == "Running" ? NativeAppsRules.friendlyStatus($0.status) == "Running" : NativeAppsRules.friendlyStatus($0.status) == "Stopped") }
    }
    private var inspector: Binding<Bool> {
        Binding(get: { live && model.selectedID != nil }, set: { if !$0 { model.backToList() } })
    }

    var body: some View {
        content.task(id: server.id) {
            guard live else { return }
            let filter = MACHINESShownAppsModel(serverID: server.id)
            await filter.load(); shownApps = filter
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !rows.isEmpty {
                Text("Deployed apps").font(.system(size: 15, weight: .semibold))
                MACHINESCard {
                    VStack(spacing: 0) {
                        ForEach(visible) { app in
                            managedRow(app)
                            if app.id != visible.last?.id { Divider() }
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button { if live { model.newApp() } } label: { Label("New app", systemImage: "plus") }
                    .buttonStyle(.bordered)
                    .disabled(live && (model.busy != nil || !model.canChange))
                    .help("Deploy a repository, use a template, or add a database.")
                if let progress = live ? model.busy : nil {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                } else if let problem = live ? model.displayProblem : nil {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    DeckRetryButton("Try again", autoRetry: true) { model.refresh() } // autoRetry: re-reads the app list
                } else if live, let reason = model.writesUnavailableReason, !model.checkingCapabilities {
                    Text(reason).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(reason)
                    Button("Check again") { model.refreshCapabilities() }
                }
                Spacer(minLength: 0)
            }
        }
        .alert("Remove \(removing?.name ?? "this app")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            TextField("Type the app’s name", text: $confirmationName)
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove app", role: .destructive) {
                if live, let app = removing { model.removeApp(app, confirmationName: confirmationName) }
                removing = nil
            }.disabled(confirmationName != removing?.name)
        } message: { Text("Type the name to remove this app and its saved data.") }
        .onChange(of: model.apps) { _, next in onRows(next) }
        .onAppear { if live { model.start() } else { onRows(fixtureApps) } }
        .onDisappear { if live { model.stop() } }
        .inspector(isPresented: inspector) {
            if let app = model.selectedApp, live {
                NativeAppsDetailView(model: model, app: app, onBack: model.backToList)
                    .inspectorColumnWidth(min: 520, ideal: 560, max: 680)
            }
        }
        .sheet(isPresented: $model.showingNewApp, onDismiss: { if live { model.cancelCatalog() } }) {
            if live {
                NativeAppsNewAppView(repositories: model.repositories, templates: model.templates,
                    catalogLoading: model.catalogLoading, catalogProblem: model.catalogProblem,
                    busy: model.busy != nil, problem: model.displayProblem,
                    canChange: model.canChange, writesUnavailableReason: model.writesUnavailableReason,
                    onReloadCatalog: model.loadCatalog,
                    onCancel: { model.cancelCatalog(); model.showingNewApp = false }, onCreate: model.create)
                    .interactiveDismissDisabled(model.busy != nil)
            }
        }
    }

    private func managedRow(_ app: NativeAppsSummary) -> some View {
        HStack(spacing: 8) {
            Button { open(app) } label: {
                HStack(spacing: 12) {
                    Image(systemName: app.kind == "app" ? "cube" : "externaldrive").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 13, weight: .semibold))
                        Text(app.address ?? (app.kind == "app" ? "No address yet" : "Database"))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(statusColor(app.status)).frame(width: 6, height: 6)
                        Text(NativeAppsRules.friendlyStatus(app.status)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(.rect)
            }.buttonStyle(MACHINESRowStyle())
            HStack(spacing: 6) {
                if hovering == app.id {
                    Button("Logs") { open(app, tab: .logs) }.buttonStyle(.bordered)
                    Button("Restart") { if live { model.restartApp(app) } }
                        .buttonStyle(.bordered).disabled(live && (model.busy != nil || !model.canChange))
                }
            }.frame(minWidth: 110)
            Menu { managedActions(app) } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(.rect) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).help("Actions for \(app.name)")
        }.padding(.vertical, 8)
        .onHover { hovering = $0 ? app.id : nil }
        .contextMenu { managedActions(app) }
    }

    @ViewBuilder private func managedActions(_ app: NativeAppsSummary) -> some View {
        Button("Open app") { open(app) }
        Button("Logs") { open(app, tab: .logs) }
        Button("Restart") { if live { model.restartApp(app) } }.disabled(live && !model.canChange)
        Button("Deploy") { if live { model.deployApp(app) } }.disabled(live && !model.canChange)
        Button("Deploy history") { open(app, tab: .deploys) }
        Button("Settings") { open(app, tab: .settings) }
        if app.kind != "app" { Button("Backups") { open(app, tab: .backups) } }
        if let url = NativeAppsRules.safeAddress(app.address) { Link("Open address", destination: url) }
        Button("Remove…", role: .destructive) { if live { confirmationName = ""; removing = app } }.disabled(live && !model.canChange)
    }

    private func statusColor(_ status: String) -> Color {
        switch NativeAppsRules.friendlyStatus(status) {
        case "Running": .green
        case "Stopped": .red
        case "Needs attention", "Starting", "Deploying", "Building", "Waiting": .orange
        default: .secondary
        }
    }

    private func open(_ app: NativeAppsSummary, tab: NativeAppsTab = .overview) {
        guard live else { return }
        model.select(app)
        if tab != .overview { model.showTab(tab) }
    }
}
