import SwiftUI
import TerminalDeckNativeCore

// MCP servers open their shared settings window. Its Tools tab lists access switches
// and the argument form used to try each tool through mcp:call.

// MARK: - The page's state

@MainActor @Observable
final class McpPageModel {
    struct InventoryState {
        var loading = false
        var data: McpInventory?
        var error: String?
    }

    private(set) var projectPath: String?
    var servers: [McpServerStatus] = []
    var loading = true
    var listError: String?
    var inventories: [String: InventoryState] = [:]
    var adding = false
    var addStart: McpFormStart?
    var removeError: [String: String] = [:]

    @ObservationIgnored private var listTicket = 0
    @ObservationIgnored private var inventoryTickets: [String: Int] = [:]
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var started = false
    /// `panel-cache`: the list per folder, good for `SERVERS_FRESH_MS`.
    private static var cache: [String: (servers: [McpServerStatus], at: Date)] = [:]

    init() {}

    init(projectPath: String?, servers: [McpServerStatus] = [],
         inventories: [String: InventoryState] = [:], loading: Bool = true) {
        self.projectPath = projectPath
        self.servers = servers
        self.inventories = inventories
        self.loading = loading
    }

    /// The store wrote the configuration: the next look at this page reads it again.
    static func forgetHeld() { cache = [:] }

    func start(projectPath: String?) {
        self.projectPath = projectPath
        if subscriptions.isEmpty {
            let bridge = EngineBridge.shared
            subscriptions.append(bridge.on("mcp:state") { [weak self] args in
                // `{ ...server, ...status }` for the one server the push is about.
                guard let self, let first = args.first else { return }
                let status = OrderedJSON(foundation: first)
                guard let id = status["id"]?.string else { return }
                self.servers = self.servers.map { server in
                    guard server.id == id, status["source"]?.string == server.source else { return server }
                    return server.merging(status)
                }
            })

        }
        if !started {
            started = true
            hold(projectPath)
        }
    }

    func stop() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        started = false
    }

    /// The engine came up after the page did: read again.
    func engineCameUp() {
        refresh()
    }

    /// A different folder: what was open belonged to the old one.
    func projectChanged(_ next: String?) {
        guard next != projectPath else { return }
        projectPath = next
        inventories = [:]
        inventoryTickets = [:]
        hold(next)
    }

    private func hold(_ path: String?) {
        if let held = Self.cache[path ?? ""] {
            servers = held.servers
            listError = nil
            loading = false
            if Date().timeIntervalSince(held.at) < McpDeadline.fresh { return }
            refresh(seeded: true)
        } else {
            refresh()
        }
    }

    func refresh(seeded: Bool = false) {
        listTicket += 1
        let ticket = listTicket
        if !seeded { loading = true }
        let path = projectPath
        Task {
            do {
                let raw = try await mcpInvoke("mcp:list", [path], what: "Reading your MCP configuration", seconds: McpDeadline.list)
                guard ticket == listTicket else { return }
                let next = (raw.array ?? []).compactMap(McpServerStatus.from)
                Self.cache[path ?? ""] = (next, Date())
                servers = next
                listError = nil
            } catch {
                if ticket == listTicket, !seeded { listError = mcpMessage(error) }
            }
            if ticket == listTicket { loading = false }
        }
    }

    func loadInventory(_ id: String) {
        if let server = servers.first(where: { $0.id == id }), server.scope == "local" || server.unsupported != nil {
            inventories[id] = InventoryState(error: server.unsupported ?? "This server's project connection couldn't be checked safely.")
            return
        }
        let ticket = (inventoryTickets[id] ?? 0) + 1
        inventoryTickets[id] = ticket
        inventories[id] = InventoryState(loading: true, data: inventories[id]?.data, error: nil)
        let path = projectPath
        Task {
            do {
                let raw = try await mcpInvoke("mcp:inventory", [id, path], what: "Connecting to \(id)", seconds: McpDeadline.inventory)
                guard inventoryTickets[id] == ticket else { return }
                let data = McpInventory.from(raw)
                if let expected = servers.first(where: { $0.id == id }),
                   let source = data.status["source"]?.string, source != expected.source {
                    inventories[id] = InventoryState(loading: false, data: nil,
                        error: "Another project has a connection with this server name. Disconnect it before testing this server.")
                    return
                }
                inventories[id] = InventoryState(loading: false, data: data, error: nil)
                servers = servers.map { $0.id == id ? $0.merging(data.status) : $0 }
            } catch {
                guard inventoryTickets[id] == ticket else { return }
                inventories[id] = InventoryState(loading: false, data: inventories[id]?.data, error: mcpMessage(error))
            }
        }
    }

    func remove(_ server: McpServerStatus) {
        removeError[server.id] = ""
        let path = projectPath
        Task {
            let request: [String: Any] = ["name": server.name, "scope": server.scope, "projectPath": path as Any? ?? NSNull()]
            let result: McpAddResult
            do {
                result = McpAddResult.from(try await EngineBridge.shared.invokeOrdered("mcp:remove", [request]))
            } catch {
                result = McpAddResult(ok: false, message: mcpMessage(error))
            }
            if !result.ok {
                removeError[server.id] = result.message
                return
            }
            removeError[server.id] = ""
            refresh()
        }
    }

    func setEnabled(_ server: McpServerStatus, _ enabled: Bool) {
        removeError[server.id] = ""
        Task {
            do {
                let request: [String: Any] = ["serverId": server.id, "projectPath": projectPath as Any? ?? NSNull(), "enabled": enabled]
                let raw = try await EngineBridge.shared.invokeOrdered("mcp:enabled", [request])
                guard raw["ok"]?.isTrue == true else {
                    removeError[server.id] = raw["message"]?.string ?? "This server could not save that setting."
                    return
                }
                Self.forgetHeld()
                refresh()
            } catch { removeError[server.id] = mcpMessage(error) }
        }
    }

    func add(_ request: [String: Any]) async throws -> McpAddResult {
        McpAddResult.from(try await EngineBridge.shared.invokeOrdered("mcp:add", [request]))
    }
}

// MARK: - The page

struct NativeMcpScreen: View {
    @State private var catalogue = NativeCatalogMcpGroups()
    @State private var selectedProject = "all"
    @State private var addingModel: McpPageModel?
    @State private var labels = NativePROJLabels.shared
    private let fixture: Bool
    private let fixtureProjects: [PROJProject]

    init() { self.init(catalogue: NativeCatalogMcpGroups(), fixture: false) }

    init(catalogue: NativeCatalogMcpGroups, fixture: Bool = false,
         projects: [PROJProject] = PROJProjects.defaults) {
        _catalogue = State(initialValue: catalogue)
        self.fixture = fixture
        fixtureProjects = projects
    }

    private var projects: [PROJProject] { fixture ? fixtureProjects : labels.projects }

    var body: some View {
        NativeCatalogPage(title: "MCP servers", subtitle: "Extra tools your coding AIs can use") {
            NativeCatalogProjectPicker(selection: Binding(get: { selectedProject == "all" ? nil : selectedProject },
                set: { selectedProject = $0 ?? "all" }), projects: projects)
            Button("Browse Store", systemImage: "bag") { NativeMcpStoreDepartment.browse() }
                .buttonStyle(.bordered)
            Button("Add server", systemImage: "plus") {
                guard !fixture else { return }
                let project = projects.first { $0.id == selectedProject }
                let model = catalogue.model(for: project?.folders.first)
                model.addStart = nil
                addingModel = model
            }
            .buttonStyle(.borderedProminent)
        } content: {
            VStack(alignment: .leading, spacing: 28) {
                if !fixture && catalogue.groups.isEmpty {
                    NativeCatalogMcpSkeleton()
                } else if visibleGroups.allSatisfy({ group in
                    !group.model.loading && group.model.listError == nil &&
                    group.model.servers.filter { group.projectID == nil ? $0.scope == "user" : $0.scope != "user" }.isEmpty
                }) {
                    VStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text("No MCP servers yet").font(.system(size: 15, weight: .semibold))
                        Text("Add a server to give your coding AIs extra tools.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 120)
                } else {
                    ForEach(visibleGroups) { group in groupView(group) }
                }
            }
        }
        .onAppear {
            if !fixture {
                selectedProject = UserDefaults.standard.string(forKey: "catalog.mcp.project") ?? "all"
                labels.start(); catalogue.start(projects: projects)
            }
        }
        .onChange(of: selectedProject) { _, project in
            if !fixture { UserDefaults.standard.set(project, forKey: "catalog.mcp.project") }
        }
        .onDisappear { if !fixture { catalogue.stop() } }
        .onChange(of: projects) { _, projects in if !fixture { catalogue.start(projects: projects) } }
        .onChange(of: fixture ? false : AppModel.shared.engineIsUp) { _, up in
            if up && !fixture { labels.start(); catalogue.start(projects: projects, refresh: true) }
        }
        .sheet(isPresented: Binding(get: { addingModel != nil }, set: { if !$0 { addingModel = nil } })) {
            if let addingModel {
                McpAddFormView(projectPath: addingModel.projectPath, start: addingModel.addStart,
                    onSubmit: { try await addingModel.add($0) },
                    onAdded: { _ in self.addingModel = nil; catalogue.refresh() },
                    onCancel: { self.addingModel = nil })
            }
        }
    }

    private var visibleGroups: [NativeCatalogMcpGroups.Group] {
        catalogue.groups.filter { selectedProject == "all" || $0.projectID == selectedProject || $0.projectID == nil }
    }

    @ViewBuilder private func groupView(_ group: NativeCatalogMcpGroups.Group) -> some View {
        let servers = group.model.servers.filter { group.projectID == nil ? $0.scope == "user" : $0.scope != "user" }
        if !servers.isEmpty || group.model.loading || group.model.listError != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if group.projectID != nil { Circle().fill(projectColour(group.colour)).frame(width: 8, height: 8) }
                    Text(group.name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(servers.count)").font(.caption).foregroundStyle(.secondary)
                }
                if let error = group.model.listError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        DeckRetryButton("Try Again") { group.model.refresh() }
                    }
                } else if group.model.loading && servers.isEmpty {
                    NativeCatalogMcpSkeleton()
                } else {
                    VStack(spacing: 0) {
                        ForEach(servers) { server in
                            NativeCatalogMcpRow(server: server, model: group.model) { duplicate in
                                group.model.addStart = duplicate
                                addingModel = group.model
                            }
                            if let error = group.model.removeError[server.id], !error.isEmpty {
                                McpErrorText(error).padding(.horizontal, 12).padding(.bottom, 8)
                            }
                            if server.id != servers.last?.id { Divider().padding(.leading, 60) }
                        }
                    }
                    .background(NativeCatalogTokens.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeCatalogTokens.hairline, lineWidth: 1))
                }
            }
        }
    }
    private func projectColour(_ colour: String) -> Color {
        NativeCatalogProjectColour.value(colour)
    }
}

@MainActor @Observable
final class NativeCatalogMcpGroups {
    struct Group: Identifiable {
        var id: String
        var projectID: String?
        var name: String
        var colour: String
        var model: McpPageModel
    }
    var groups: [Group] = []
    private var models: [String: McpPageModel] = [:]

    init(groups: [Group] = []) {
        self.groups = groups
        for group in groups { models[group.model.projectPath ?? ""] = group.model }
    }

    func model(for path: String?) -> McpPageModel {
        let key = path ?? ""
        if let model = models[key] { return model }
        let model = McpPageModel()
        models[key] = model
        model.start(projectPath: path)
        return model
    }
    func start(projects: [PROJProject], refresh: Bool = false) {
        groups = projects.flatMap { project in
            project.folders.map { folder in
                let model = model(for: folder)
                model.start(projectPath: folder)
                return Group(id: folder, projectID: project.id, name: project.name, colour: project.colour, model: model)
            }
        }
        let global = model(for: nil)
        global.start(projectPath: nil)
        groups.append(Group(id: "every", projectID: nil, name: "Every project", colour: "graphite", model: global))
        if refresh { self.refresh() }
    }
    func refresh() { models.values.forEach { $0.refresh() } }
    func stop() { models.values.forEach { $0.stop() } }
}

private struct NativeCatalogMcpSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 150, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 250, height: 9)
                    }
                    Spacer()
                }.padding(12)
            }
        }
        .background(NativeCatalogTokens.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Loading MCP servers")
    }
}

struct NativeCatalogMcpRow: View {
    let server: McpServerStatus
    @Bindable var model: McpPageModel
    var duplicate: (McpFormStart) -> Void
    @State private var confirmingRemoval = false

    private var status: String { !server.enabled ? "Off" : server.scope == "local" || server.unsupported != nil ? "Unavailable" : server.state == .ready ? "Connected" : server.state == .connecting ? "Connecting" : "Not running" }
    var body: some View {
        Button { open() } label: {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(.secondary).frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(server.name).font(.system(size: 13, weight: .semibold))
                        McpTag(text: server.transport == "stdio" ? "Command" : "Web address")
                    }
                    Text(server.commandLine).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(model.inventories[server.id]?.data.map { "\($0.tools.count) tools" } ?? "—")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text("Claude Code").font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                HStack(spacing: 6) {
                    Circle().fill(status == "Connected" ? Color.green : server.scope != "local" && server.unsupported == nil && server.state == .failed ? Color.red : Color.secondary).frame(width: 6, height: 6)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }.frame(width: 110, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(NativeCatalogRowStyle())
        .accessibilityLabel("Open \(server.name)")
        .accessibilityValue(status)
        .help("Open \(server.name) settings")
        .contextMenu {
            Button("Open", action: open)
            Button(server.enabled ? "Turn off" : "Turn on") { model.setEnabled(server, !server.enabled) }
            Button("Test connection") { model.loadInventory(server.id) }.disabled(server.unsupported != nil || server.scope == "local")
            Button("Duplicate") {
                var start = McpFormStart.edit(name: duplicateName, scope: McpAddScope(rawValue: server.scope) ?? .user,
                    transport: McpAddTransport(rawValue: server.transport) ?? .stdio, command: duplicateCommand, envKeys: [])
                start.savedKeys = []
                duplicate(start)
            }
            Divider()
            Button("Remove…", role: .destructive) { confirmingRemoval = true }
        }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove server", role: .destructive) { model.remove(server) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the server from its saved configuration.") }
    }
    private var duplicateCommand: String {
        guard server.transport == "stdio" else { return server.url ?? "" }
        return ([server.command ?? ""] + server.args).map { value in
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
    private var duplicateName: String {
        let clean = server.name.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        let base = clean.isEmpty ? "server" : clean
        let names = Set(model.servers.map(\.name))
        var candidate = base + "-copy", number = 2
        while names.contains(candidate) { candidate = base + "-copy-" + String(number); number += 1 }
        return candidate
    }
    private func open() { NativeCatalogMcpSettingsWindow.open(server: server, projectPath: model.projectPath, model: model) }
}

// MARK: - One tool (ToolRow)

struct McpToolRow: View {
    let tool: McpTool
    let disabled: Bool
    let call: (McpTool, OrderedJSON) async -> McpCallResult

    @State private var open = false
    @State private var values: OrderedJSON
    @State private var invalid: [String: String] = [:]
    @State private var running = false
    @State private var result: McpCallResult?

    init(tool: McpTool, disabled: Bool, call: @escaping (McpTool, OrderedJSON) async -> McpCallResult) {
        self.tool = tool
        self.disabled = disabled
        self.call = call
        _values = State(initialValue: McpSchema.initialValues(McpSchema.describe(tool.inputSchema).fields))
    }

    var body: some View {
        let missing = McpSchema.missingRequired(McpSchema.describe(tool.inputSchema).fields, values)
        let blocked = !missing.isEmpty || !invalid.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tool.name).font(.callout.monospaced().weight(.medium))
                    if let title = tool.title, title != tool.name { Text(title).font(.callout) }
                    // The head's one-liner is elided; the body shows the description in full.
                    if !open {
                        Text(tool.description ?? "No description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")

            if open {
                if let description = tool.description {
                    Text(description).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                McpSchemaFormView(schema: tool.inputSchema, values: $values, invalid: $invalid, disabled: disabled || running)

                HStack(spacing: 10) {
                    Button(running ? "Running…" : "Run tool", action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(disabled || running || blocked)
                    if !missing.isEmpty { hint("Needs \(missing.joined(separator: ", "))") }
                    if !invalid.isEmpty { hint("Fix the JSON in \(invalid.keys.sorted().joined(separator: ", "))") }
                    if let result, !running { hint(result.summary) }
                }

                if let result {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = result.error { McpErrorText(error) }
                        if let text = result.text { McpPre(text: text) }
                        if result.ok {
                            DisclosureGroup("Raw result\(result.truncated ? " (truncated)" : "")") {
                                McpPre(text: result.result.pretty)
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(result.ok ? Color.green.opacity(0.4) : Color.red.opacity(0.5)))
                }

                DisclosureGroup("Input schema") { McpPre(text: tool.inputSchema.pretty) }
                if let output = tool.outputSchema {
                    DisclosureGroup("Output schema") { McpPre(text: output.pretty) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(open ? 0.6 : 0.3)))
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func run() {
        running = true
        let args = McpSchema.prune(values)
        Task {
            result = await call(tool, args)
            running = false
        }
    }
}

// MARK: - Small parts

/// `.mcp-dot`, coloured by connection state.
struct McpDot: View {
    let state: McpConnectionState
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
    private var color: Color {
        switch state {
        case .idle: return Color.secondary.opacity(0.5)
        case .connecting: return .yellow
        case .ready: return .green
        case .failed: return .red
        case .closed: return .orange
        }
    }
}

/// `.mcp-tag`: scope, transport, "disabled", and whose machine.
struct McpTag: View {
    enum Kind { case plain, scope, warn, machine }
    let text: String
    var kind: Kind = .plain

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(kind == .warn ? Color.orange : kind == .scope ? Color.primary : Color.secondary)
            .padding(.horizontal, kind == .machine ? 0 : 6)
            .frame(height: 22)
            .background {
                if kind != .machine {
                    RoundedRectangle(cornerRadius: 6).fill(kind == .warn ? Color.orange.opacity(0.18) : NativeCatalogTokens.selection)
                }
            }
    }
}

/// `.mcp-folder`: the folder the list is about, by name; the path on hover.
struct McpFolderChip: View {
    let path: String
    var body: some View {
        Text(mcpFolderName(path))
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .help(path)
    }
}

/// `.mcp-pre`: monospaced, selectable, scrolling once it is long.
struct McpPre: View {
    let text: String
    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxHeight: 280)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }
    private var content: some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }
}

private struct McpItem: View {
    let name: String
    let summary: String
    let tag: String?
    let description: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.callout.monospaced().weight(.medium))
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let tag { McpTag(text: tag) }
                Spacer(minLength: 0)
            }
            if let description {
                Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.3)))
    }
}

private struct McpNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}

struct McpErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
