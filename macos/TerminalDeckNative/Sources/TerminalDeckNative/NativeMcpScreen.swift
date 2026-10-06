import SwiftUI
import TerminalDeckNativeCore

// The MCP servers page, drawn in SwiftUI (web: components/McpInspector.tsx and
// mcp-machines.ts). Same controls, same words, same order: the store door, the
// machine switch, the folder, the header, the add form, then one row per server
// that opens onto its tools, resources and prompts, with a form to run a tool.

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
    var expanded: String?
    var section: McpSection = .tools
    var inventories: [String: InventoryState] = [:]
    var adding = false
    var removing: String?
    var removeError: [String: String] = [:]
    private(set) var machinePick: String?
    private(set) var machinesView: OrderedJSON = .object([])

    @ObservationIgnored private var listTicket = 0
    @ObservationIgnored private var inventoryTickets: [String: Int] = [:]
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var started = false
    /// `panel-cache`: the list per folder, good for `SERVERS_FRESH_MS`.
    private static var cache: [String: (servers: [McpServerStatus], at: Date)] = [:]

    /// The store wrote the configuration: the next look at this page reads it again.
    static func forgetHeld() { cache = [:] }

    /// `reportableMachines` over `useMachines`.
    var targets: [McpMachineTarget] { McpMachineTarget.reportable(machinesView) }
    var here: String { McpMachineTarget.hereName(machinesView) }
    var target: McpMachineTarget? { targets.first { $0.machineId == machinePick } }

    func start(projectPath: String?) {
        self.projectPath = projectPath
        if subscriptions.isEmpty {
            let bridge = EngineBridge.shared
            subscriptions.append(bridge.on("mcp:state") { [weak self] args in
                // `{ ...server, ...status }` for the one server the push is about.
                guard let self, let first = args.first else { return }
                let status = OrderedJSON(foundation: first)
                guard let id = status["id"]?.string else { return }
                self.servers = self.servers.map { $0.id == id ? $0.merging(status) : $0 }
            })
            subscriptions.append(bridge.on("machines:state") { [weak self] args in
                self?.adoptMachines(OrderedJSON(foundation: args.first))
            })
            subscriptions.append(bridge.on("remote:connections") { [weak self] _ in self?.readMachines() })
        }
        if !started {
            started = true
            hold(projectPath)
        }
        readMachines()
    }

    func stop() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        started = false
    }

    /// The engine came up after the page did: read again.
    func engineCameUp() {
        refresh()
        readMachines()
    }

    /// A different folder: what was open belonged to the old one.
    func projectChanged(_ next: String?) {
        guard next != projectPath else { return }
        projectPath = next
        inventories = [:]
        expanded = nil
        inventoryTickets = [:]
        hold(next)
    }

    func pick(_ machineId: String?) {
        machinePick = machineId
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

    private func readMachines() {
        Task {
            guard let raw = try? await EngineBridge.shared.invokeOrdered("machines:list") else { return }
            adoptMachines(raw)
        }
    }

    private func adoptMachines(_ view: OrderedJSON) {
        machinesView = view.isObject ? view : .object([])
        // `pickSurvives`: a machine that can no longer be read is forgotten, not waited for.
        if !McpMachineTarget.pickSurvives(machinePick, targets) { machinePick = nil }
    }

    func loadInventory(_ id: String) {
        let ticket = (inventoryTickets[id] ?? 0) + 1
        inventoryTickets[id] = ticket
        inventories[id] = InventoryState(loading: true, data: inventories[id]?.data, error: nil)
        let path = projectPath
        Task {
            do {
                let raw = try await mcpInvoke("mcp:inventory", [id, path], what: "Connecting to \(id)", seconds: McpDeadline.inventory)
                guard inventoryTickets[id] == ticket else { return }
                let data = McpInventory.from(raw)
                inventories[id] = InventoryState(loading: false, data: data, error: nil)
                servers = servers.map { $0.id == id ? $0.merging(data.status) : $0 }
            } catch {
                guard inventoryTickets[id] == ticket else { return }
                inventories[id] = InventoryState(loading: false, data: inventories[id]?.data, error: mcpMessage(error))
            }
        }
    }

    func toggle(_ server: McpServerStatus) {
        if expanded == server.id {
            expanded = nil
            return
        }
        expanded = server.id
        section = .tools
        let held = inventories[server.id]
        if held?.data == nil, held?.loading != true, server.unsupported == nil { loadInventory(server.id) }
    }

    func remove(_ server: McpServerStatus) {
        removing = nil
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
            if expanded == server.id { expanded = nil }
            removeError[server.id] = ""
            refresh()
        }
    }

    func disconnect(_ id: String) {
        inventoryTickets[id] = (inventoryTickets[id] ?? 0) + 1
        Task {
            _ = try? await EngineBridge.shared.invokeOrdered("mcp:disconnect", [id])
            inventories[id] = InventoryState()
            if expanded == id { expanded = nil }
            refresh()
        }
    }

    func callTool(_ serverId: String, _ tool: McpTool, _ args: OrderedJSON) async -> McpCallResult {
        do {
            // No deadline on the page: a tool runs as long as it runs.
            let raw = try await EngineBridge.shared.invokeOrdered("mcp:call", [serverId, tool.name, args.foundation, projectPath],
                                                                  timeout: 24 * 3600)
            return McpCallResult.from(raw)
        } catch {
            return McpCallResult.failed(mcpMessage(error))
        }
    }

    func add(_ request: [String: Any]) async throws -> McpAddResult {
        McpAddResult.from(try await EngineBridge.shared.invokeOrdered("mcp:add", [request]))
    }
}

/// `useMachineServers`: one machine's servers, read through one of its sessions.
@MainActor @Observable
final class McpMachineServersModel {
    enum Status { case loading, ready, unanswered }
    var status: Status = .loading
    var rows: [McpRow] = []
    @ObservationIgnored private var attempt = 0

    func read(_ target: McpMachineTarget) {
        attempt += 1
        let mine = attempt
        status = .loading
        rows = []
        Task {
            let answer = try? await EngineBridge.shared.invokeOrdered("machines:controls:read", [target.machineId, target.sessionId])
            guard mine == attempt else { return }
            // Nobody answering and "that folder has none" are different facts.
            if let list = McpRow.list(answer?["connectors"]) {
                rows = list
                status = .ready
            } else {
                status = .unanswered
            }
        }
    }
}

// MARK: - The page

struct NativeMcpScreen: View {
    @State private var model = McpPageModel()

    var body: some View {
        let projectPath = DeckProject.current
        Group {
            if let target = model.target {
                VStack(alignment: .leading, spacing: 14) {
                    McpMachinePills(targets: model.targets, here: model.here, pick: target.machineId, onPick: model.pick)
                    McpMachineServerList(target: target)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                local(projectPath)
            }
        }
        .onAppear { model.start(projectPath: projectPath) }
        .onDisappear { model.stop() }
        .onChange(of: projectPath) { _, next in model.projectChanged(next) }
        .onChange(of: AppModel.shared.engineIsUp) { _, up in if up { model.engineCameUp() } }
    }

    private func blank() -> Bool {
        !model.loading && model.servers.isEmpty && model.listError == nil && !model.adding
    }

    @ViewBuilder private func local(_ projectPath: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                DeckProject.show("store")
            } label: {
                HStack(spacing: 4) {
                    Text("Browse the store")
                    Image(systemName: "chevron.right").font(.caption)
                }
            }
            .buttonStyle(.link)
            McpMachinePills(targets: model.targets, here: model.here, pick: nil, onPick: model.pick)
            NativePageScope(path: projectPath)
            if blank() {
                NativePageEmpty(
                    symbol: "server.rack",
                    title: "No servers yet",
                    message: { EmptyView() },
                    action: PageEmptyAction(label: model.targets.isEmpty ? "Add a server" : "Add a server on \(model.here)",
                                            primary: true) { model.adding = true },
                    hint: { if let projectPath { McpFolderChip(path: projectPath) } },
                    extra: { reload }
                )
            } else {
                header(projectPath)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.adding {
                            McpAddFormView(projectPath: projectPath,
                                           onSubmit: { try await model.add($0) },
                                           onAdded: { _ in
                                               model.adding = false
                                               model.refresh()
                                           },
                                           onCancel: { model.adding = false })
                        }
                        if let listError = model.listError {
                            McpErrorText(listError)
                        }
                        if model.loading, model.servers.isEmpty, model.listError == nil {
                            NativePageNote("Reading your MCP configuration…", busy: true)
                                .padding(.top, 40)
                        }
                        ForEach(model.servers) { server in
                            McpServerRow(server: server, model: model)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        // The page's reading column (`.mcp`), centred in the window.
        .frame(maxWidth: 960, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var reload: some View {
        Button(model.loading ? "Reading…" : "Reload") { model.refresh() }
            .disabled(model.loading)
    }

    private func header(_ projectPath: String?) -> some View {
        HStack(spacing: 8) {
            NativeCodingAIInfo(label: "Where these come from", text: "Read from your Claude Code configuration.")
            if let projectPath { McpFolderChip(path: projectPath) }
            Spacer()
            Button(model.adding ? "Close" : model.targets.isEmpty ? "Add server" : "Add server on \(model.here)") {
                model.adding.toggle()
            }
            .buttonStyle(.borderedProminent)
            .help("Adds to the configuration on \(model.here)")
            reload
        }
    }
}

// MARK: - One server

private struct McpServerRow: View {
    let server: McpServerStatus
    @Bindable var model: McpPageModel

    private var open: Bool { model.expanded == server.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // An HTTP or SSE server cannot be opened, so its row is not a control that looks like one.
                Button { model.toggle(server) } label: {
                    HStack(spacing: 8) {
                        McpDot(state: server.state)
                        Text(server.name).font(.body.weight(.medium))
                        McpTag(text: server.scope, kind: server.scope == "user" ? .plain : .scope)
                        McpTag(text: server.transport)
                        if !server.enabled { McpTag(text: "disabled", kind: .warn) }
                        if !model.targets.isEmpty { McpTag(text: model.here, kind: .machine) }
                        Spacer(minLength: 8)
                        Text(server.state.label).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(server.unsupported != nil)
                .help(server.unsupported ?? "")
                .accessibilityValue(server.unsupported == nil ? (open ? "expanded" : "collapsed") : "")

                if server.state == .ready {
                    Button("Disconnect") { model.disconnect(server.id) }
                }
                if model.removing == server.id {
                    Button("Remove", role: .destructive) { model.remove(server) }
                    Button("Keep") { model.removing = nil }
                } else {
                    Button("Remove") { model.removing = server.id }
                        .help("Remove \(server.name) from your \(server.scope) configuration")
                }
            }

            Text(server.commandLine.isEmpty ? "—" : server.commandLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(server.source)

            if let why = server.why {
                NativeCodingAIInfo(label: server.whyLabel, text: why)
            }
            if let error = server.error { McpErrorText(error) }
            if let error = model.removeError[server.id], !error.isEmpty { McpErrorText(error) }

            if open { McpServerBody(server: server, model: model) }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, open ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(open ? 0.4 : 0)))
    }
}

private struct McpServerBody: View {
    let server: McpServerStatus
    @Bindable var model: McpPageModel

    var body: some View {
        let inventory = model.inventories[server.id]
        VStack(alignment: .leading, spacing: 8) {
            if let info = server.serverInfo {
                (Text("\(info.name) \(info.version)")
                    + Text(server.pid.map { " · pid \($0)" } ?? "").foregroundStyle(.secondary)
                    + Text(server.capabilities.isEmpty ? "" : " · \(server.capabilities.joined(separator: ", "))").foregroundStyle(.secondary))
                    .font(.callout)
            }
            if let instructions = server.instructions {
                Text(instructions).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !server.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("Server output") { McpPre(text: server.stderr) }
            }
            if inventory?.loading == true {
                Text("Starting the server…").font(.callout).foregroundStyle(.secondary)
            }
            if let error = inventory?.error { McpErrorText(error) }

            if let data = inventory?.data {
                HStack(spacing: 10) {
                    Picker("", selection: $model.section) {
                        ForEach(McpSection.allCases) { key in
                            Text("\(key.rawValue)  \(data.count(key))").tag(key)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button("Refresh") { model.loadInventory(server.id) }
                }
                // Failures that belong to no tab show on every tab.
                ForEach(data.errors(for: model.section), id: \.self) { McpErrorText($0) }

                switch model.section {
                case .tools:
                    if data.tools.isEmpty { McpNote("No tools.") }
                    ForEach(data.tools) { tool in
                        McpToolRow(tool: tool, disabled: server.state != .ready) { tool, args in
                            await model.callTool(server.id, tool, args)
                        }
                        .id("\(server.id)/\(tool.name)")
                    }
                case .resources:
                    if data.resources.isEmpty && data.resourceTemplates.isEmpty { McpNote("No resources.") }
                    ForEach(data.resources) { resource in
                        McpItem(name: resource.name, summary: resource.uri, tag: resource.mimeType, description: resource.description)
                    }
                    ForEach(data.resourceTemplates) { template in
                        McpItem(name: template.name, summary: template.uriTemplate, tag: "template", description: template.description)
                    }
                case .prompts:
                    if data.prompts.isEmpty { McpNote("No prompts.") }
                    ForEach(data.prompts) { prompt in
                        VStack(alignment: .leading, spacing: 4) {
                            McpItem(name: prompt.name, summary: prompt.description ?? "No description", tag: nil, description: nil)
                            ForEach(prompt.arguments, id: \.name) { arg in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(arg.name).font(.caption.monospaced())
                                    if arg.required { Text("*").foregroundStyle(.red) }
                                    if let description = arg.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - One tool (ToolRow)

private struct McpToolRow: View {
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

// MARK: - Another machine (MachinePills, MachineServerList)

/// `MachinePills`: this computer and each machine that can answer. Nothing when there is none.
struct McpMachinePills: View {
    let targets: [McpMachineTarget]
    let here: String
    let pick: String?
    let onPick: (String?) -> Void

    var body: some View {
        if !targets.isEmpty {
            Picker("Which machine’s servers to show", selection: Binding(
                get: { pick ?? "" },
                set: { onPick($0.isEmpty ? nil : $0) }
            )) {
                Text(here).tag("")
                ForEach(targets) { target in
                    Text(target.name).tag(target.machineId)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(pick.flatMap { id in targets.first { $0.machineId == id } }
                .map { "Read the configuration on \($0.name), for the folder \($0.sessionTitle) runs in" }
                ?? "The configuration on \(here)")
        }
    }
}

private struct McpMachineServerList: View {
    let target: McpMachineTarget
    @State private var reader = McpMachineServersModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The machine, the folder it resolved for, and the session it asked through.
            NativePageScope(path: target.cwd.isEmpty ? nil : target.cwd, machine: target.name, detail: "through \(target.sessionTitle)")
            switch reader.status {
            case .loading:
                NativePageNote("Asking \(target.name)…", busy: true)
            case .unanswered:
                NativePageEmpty(symbol: "server.rack", title: "\(target.name) did not answer",
                                action: PageEmptyAction(label: "Try again", primary: true) { reader.read(target) }) {
                    Text("The link to it is up, but nothing came back for that session.")
                }
            case .ready where reader.rows.isEmpty:
                NativePageEmpty(
                    symbol: "server.rack",
                    title: "No servers there",
                    message: { Text("Nothing is configured for that folder on \(target.name).") },
                    action: nil,
                    hint: { McpFolderChip(path: target.cwd) },
                    extra: { reload }
                )
            case .ready:
                HStack {
                    NativeCodingAIInfo(label: "Where these come from",
                                       text: "Read on \(target.name), from the configuration that applies to that session’s folder. Adding, removing and opening a server happen on the machine that runs it.")
                    Spacer()
                    reload
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(reader.rows) { row in
                            // A row, not a button: nothing here can open a server on another machine.
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    McpDot(state: .idle)
                                    Text(row.name).font(.body.weight(.medium))
                                    if let scope = row.scope { McpTag(text: scope, kind: scope == "user" ? .plain : .scope) }
                                    if let transport = row.transport { McpTag(text: transport) }
                                    if !row.enabled { McpTag(text: "disabled", kind: .warn) }
                                    McpTag(text: target.name, kind: .machine)
                                    Spacer(minLength: 0)
                                }
                                Text(row.detail.isEmpty ? "—" : row.detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(target.machineId)|\(target.sessionId)") { reader.read(target) }
    }

    private var reload: some View {
        Button(reader.status == .loading ? "Reading…" : "Reload") { reader.read(target) }
            .disabled(reader.status == .loading)
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
            .padding(.vertical, 1)
            .background {
                if kind != .machine {
                    Capsule().fill(kind == .warn ? Color.orange.opacity(0.18) : Color.secondary.opacity(kind == .scope ? 0.22 : 0.12))
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
