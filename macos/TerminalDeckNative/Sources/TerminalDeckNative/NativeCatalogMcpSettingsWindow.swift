import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One settings window for each folder/server pair, through the shared object windows (READY L1-CORE).
/// A window keeps the id it opened with; `opened` files it under the server's current name, so a renamed
/// server reopens its own window. A removed server or a closed window lets its model go, secrets included.
@MainActor
enum NativeCatalogMcpSettingsWindow {
    /// Window id → its settings model.
    private static var shared: [String: NativeCatalogMcpSettingsModel] = [:]
    /// The server's current folder/server key → its window id.
    private static var opened: [String: String] = [:]

    static func open(server: McpServerStatus, projectPath: String?, model: McpPageModel) {
        if !ObjectWindows.hasProvider(for: ObjectRef(kind: "mcp", id: "probe")) {
            ObjectWindows.register(kind: "mcp", title: { ref in shared[ref.id]?.server.name ?? "MCP server" }, content: { ref in
                guard let settings = shared[ref.id] else {
                    return AnyView(ContentUnavailableView("Server removed", systemImage: "puzzlepiece.extension",
                        description: Text("Open it again from MCP servers.")))
                }
                return AnyView(NativeCatalogMcpSettingsView(model: settings).onDisappear { forget(ref.id) })
            })
        }
        let windowID = held(server: server, projectPath: projectPath) { model.refresh() }.windowID
        _ = ObjectWindows.open(ObjectRef(kind: "mcp", id: windowID))
    }

    /// The model and window id for this server: the open one (also after a rename), else a new one.
    static func held(server: McpServerStatus, projectPath: String?,
                     refresh: @escaping @MainActor () -> Void) -> (windowID: String, settings: NativeCatalogMcpSettingsModel) {
        let key = key(projectPath, server.id)
        if let windowID = opened[key], let settings = shared[windowID] { return (windowID, settings) }
        // A renamed server's window may still hold this id; a new server of the old name gets its own.
        let windowID = shared[key] == nil ? key : key + "\n" + UUID().uuidString
        let settings = NativeCatalogMcpSettingsModel(server: server, projectPath: projectPath)
        settings.onSaved = refresh
        settings.onRemoved = { refresh(); forget(windowID); _ = ObjectWindows.close(ObjectRef(kind: "mcp", id: windowID)) }
        settings.onIdentityChanged = { newID in
            opened = opened.filter { $0.value != windowID }
            opened[Self.key(projectPath, newID)] = windowID
        }
        shared[windowID] = settings; opened[key] = windowID
        return (windowID, settings)
    }
    static func forget(_ windowID: String) {
        shared[windowID] = nil
        opened = opened.filter { $0.value != windowID }
    }
    private static func key(_ projectPath: String?, _ serverID: String) -> String { (projectPath ?? "") + "\n" + serverID }
}

enum NativeCatalogMcpTab: String, CaseIterable, Identifiable {
    case general = "General", tools = "Tools", access = "Access", secrets = "Secrets", log = "Log"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .tools: "puzzlepiece.extension"
        case .access: "checkmark.shield"
        case .secrets: "key"
        case .log: "doc.text"
        }
    }
}

/// Debounced edits are serialized: the writer replaces a whole definition.
@MainActor @Observable
final class NativeCatalogMcpSettingsModel {
    struct AgentAccess: Identifiable {
        let id: String
        let name: String
        var enabled: Bool
    }
    var server: McpServerStatus
    var draft: McpAddDraft
    var tab = NativeCatalogMcpTab.general
    var projectPath: String?
    var saving = false
    var testing = false
    var error: String?
    var outcome: String?
    var inventory: McpInventory?
    var toolOverrides: [String: Bool] = [:]
    var access: [String: Bool] = [:]
    var configurationVerified = false
    var policyVerified = false
    var policyError: String?
    var policyRevision: Int?
    var agents: [AgentAccess] = []
    var agentAccessKnown = false
    var preservedKeys: [String] = []
    var secretKey = ""
    var secretValue = ""
    var removing = false
    @ObservationIgnored var invoke: @MainActor (String, [Any?]) async throws -> OrderedJSON = { channel, arguments in
        try await mcpInvoke(channel, arguments, what: "Updating the MCP server", seconds: channel == "mcp:call" ? 24 * 3600 : 10)
    }
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var hasPendingEdit = false
    @ObservationIgnored private var savedDraft: McpAddDraft
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var secretValues: [String] = []
    @ObservationIgnored private var savedIdentities = Set<String>()
    @ObservationIgnored private var policyWriteSerial = 0
    @ObservationIgnored var onSaved: @MainActor () -> Void = {}
    @ObservationIgnored var onRemoved: @MainActor () -> Void = {}
    @ObservationIgnored var onIdentityChanged: @MainActor (String) -> Void = { _ in }

    init(server: McpServerStatus, projectPath: String?) {
        self.server = server; self.projectPath = projectPath
        let draft = Self.draft(server)
        self.draft = draft; savedDraft = draft
    }
    private static func draft(_ server: McpServerStatus) -> McpAddDraft {
        var draft = McpAddDraft()
        draft.name = server.name
        draft.scope = McpAddScope(rawValue: server.scope) ?? .user
        draft.transport = McpAddTransport(rawValue: server.transport) ?? .stdio
        draft.command = server.transport == "stdio" ? BackendMcpClientCommands.quoteArgv([server.command ?? ""] + server.args) : ""
        draft.url = server.url ?? ""
        return draft
    }

    var status: String {
        if !server.enabled { return "Off" }
        if server.scope == "local" || server.unsupported != nil { return "Unavailable" }
        switch server.state {
        case .ready: return "Connected"
        case .connecting: return "Connecting"
        case .failed: return server.error?.localizedCaseInsensitiveContains("sign") == true ? "Needs sign-in" : "Not running"
        case .closed, .idle: return "Not running"
        }
    }

    func start() {
        guard EngineBridge.shared.isReady, subscription == nil else { return }
        subscription = EngineBridge.shared.on("mcp:state") { [weak self] args in
            guard let self, let raw = args.first else { return }
            let value = OrderedJSON(foundation: raw)
            guard value["id"]?.string == self.server.id else { return }
            guard value["source"]?.string == self.server.source else { return }
            self.server = self.server.merging(value)
        }
        Task { await readSaved(); await readPolicy() }
    }
    /// On open the fields show the saved definition, not the copy held when the list was read.
    func readSaved() async {
        guard await readConfiguration(), !hasPendingEdit, !saving, draft == savedDraft else { return }
        let fresh = Self.draft(server)
        savedDraft = fresh; draft = fresh
    }
    func stop() {
        debounce?.cancel(); subscription?.cancel(); subscription = nil
        // Closing the window must not discard the last debounced field edit.
        if hasPendingEdit { Task { await savePending() } }
    }

    func changed() {
        guard draft != savedDraft else { return }
        hasPendingEdit = true
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            self?.debounce = nil
            await self?.savePending()
        }
    }

    func savePending() async {
        guard !saving, hasPendingEdit else { return }
        saving = true
        defer { saving = false }
        while hasPendingEdit {
            hasPendingEdit = false
            let next = draft
            guard next.missing == nil else { error = next.missing; return }
            // The existing web writer cannot preserve hidden authorization headers.
            // Refuse that edit until the backend offers its safe replacement contract.
            guard server.transport == "stdio", next.transport == .stdio else {
                error = "Couldn't safely save this web server's settings. Your saved settings were kept."
                return
            }
            guard next.scope.rawValue == server.scope else {
                error = "Couldn't safely move this server to another project. Your saved settings were kept."
                return
            }
            do {
                guard await readConfiguration(), configurationVerified else { return }
                let nextIdentity = next.scope.rawValue + ":" + next.name
                guard nextIdentity == server.id || !savedIdentities.contains(nextIdentity) else {
                    error = "A server with that name already exists. Choose another name."; return
                }
                var safeNext = next
                let typed = next.extras.split(separator: "\n").map(String.init)
                let editedKeys = Set(typed.map { $0.components(separatedBy: "=")[0] })
                safeNext.extras = (preservedKeys.filter { !editedKeys.contains($0) }.map { $0 + "=" } + typed).joined(separator: "\n")
                let result = McpAddResult.from(try await invoke("mcp:edit", [["name": server.name,
                    "scope": server.scope, "projectPath": projectPath as Any? ?? NSNull(),
                    "next": safeNext.request(projectPath: projectPath)]]))
                guard result.ok else { error = masked(result.message); return }
                server = server.merging(.object([.init("name", .string(next.name)), .init("scope", .string(next.scope.rawValue)),
                    .init("id", .string(next.scope.rawValue + ":" + next.name))]))
                onIdentityChanged(server.id)
                savedDraft = next
                error = nil; outcome = "Saved"
                McpPageModel.forgetHeld()
                _ = await readConfiguration()
                onSaved()
                if draft != next { hasPendingEdit = true }
            } catch { self.error = masked(mcpMessage(error)); return }
        }
    }

    @discardableResult func readConfiguration() async -> Bool {
        do {
            let rows = try await invoke("mcp:list", [projectPath])
            savedIdentities = Set((rows.array ?? []).compactMap { $0["id"]?.string })
            guard let raw = rows.array?.first(where: { $0["id"]?.string == server.id && $0["source"]?.string == server.source }),
                  let fresh = McpServerStatus.from(raw), let env = raw["env"]?.fields else {
                configurationVerified = false; error = "Couldn't read this server's saved settings."; return false
            }
            guard raw["cwd"]?.string == nil else {
                configurationVerified = false; error = "This server's folder settings could not be safely changed."; return false
            }
            preservedKeys = env.map(\.key)
            secretValues = env.compactMap { $0.value.string }.filter { !$0.isEmpty }
            server = fresh
            configurationVerified = true
            return true
        } catch { configurationVerified = false; self.error = masked(mcpMessage(error)); return false }
    }
    func masked(_ text: String) -> String {
        let values = (secretValues + (secretValue.isEmpty ? [] : [secretValue])).sorted { $0.count > $1.count }
        return values.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••••") }
    }
    var safeLog: String? {
        guard configurationVerified else { return nil }
        return masked([server.error ?? "", server.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
    func readPolicy() async {
        let identity = server.id
        let serial = policyWriteSerial
        do {
            let answer = try await invoke("mcp:policy", [["serverId": identity,
                "projectPath": projectPath as Any? ?? NSNull()]])
            guard identity == server.id, serial == policyWriteSerial else { return }
            guard answer["ok"]?.bool == true, let enabled = answer["enabled"]?.bool,
                  let tools = answer["tools"]?.fields, let clients = answer["access"]?.fields,
                  let revision = answer["revision"]?.number, revision.isFinite, revision >= 0,
                  revision < Double(Int.max), revision.rounded(.towardZero) == revision,
                  tools.allSatisfy({ $0.value.bool != nil }), clients.allSatisfy({ $0.value.bool != nil }) else {
                invalidatePolicy(); return
            }
            if let current = policyRevision, Int(revision) < current { return }
            server = server.merging(.object([.init("enabled", .bool(enabled))]))
            toolOverrides = Dictionary(uniqueKeysWithValues: tools.map { ($0.key, $0.value.bool!) })
            access = Dictionary(uniqueKeysWithValues: clients.map { ($0.key, $0.value.bool!) })
            if let rows = answer["agents"]?.array {
                let parsed = rows.compactMap { row -> AgentAccess? in
                    guard let id = row["id"]?.string, !id.isEmpty, let name = row["name"]?.string, !name.isEmpty,
                          let enabled = row["enabled"]?.bool else { return nil }
                    return AgentAccess(id: id, name: name, enabled: enabled)
                }
                if parsed.count == rows.count && Set(parsed.map(\.id)).count == parsed.count {
                    agents = parsed; agentAccessKnown = true
                } else { agents = []; agentAccessKnown = false }
            } else { agents = []; agentAccessKnown = false }
            policyRevision = Int(revision); policyVerified = true; policyError = nil
        } catch { if serial == policyWriteSerial && identity == server.id { invalidatePolicy() } }
    }
    private func invalidatePolicy() {
        policyVerified = false; policyError = "Couldn't read this server's access settings."
        toolOverrides = [:]; access = [:]; agents = []; agentAccessKnown = false; policyRevision = nil
    }

    func test() async {
        guard !testing else { return }
        guard server.scope != "local", server.unsupported == nil else {
            inventory = nil
            error = server.unsupported ?? "This server's project connection couldn't be checked safely."
            return
        }
        testing = true; error = nil
        defer { testing = false }
        do {
            let answer = try await invoke("mcp:inventory", [server.id, projectPath])
            inventory = McpInventory.from(answer)
            guard inventory?.status["source"]?.string == server.source else {
                inventory = nil; error = "A different project's server answered. No tools were opened."; return
            }
            server = server.merging(inventory!.status)
            guard server.state == .ready else {
                error = masked(server.error ?? "Couldn't connect to this server.")
                inventory = nil; outcome = nil; return
            }
            outcome = status == "Connected" ? "Connected · \(inventory!.tools.count) tools" : status
        } catch { self.error = masked(mcpMessage(error)) }
    }

    func callTool(_ tool: McpTool, _ args: OrderedJSON) async -> McpCallResult {
        guard server.enabled, server.state == .ready, toolOverrides[tool.name] != false else {
            return .failed("Switch on this server and tool, then connect before running it.")
        }
        do {
            let raw = try await invoke("mcp:call", [server.id, tool.name, args.foundation, projectPath])
            return McpCallResult.from(raw)
        } catch { return .failed(masked(mcpMessage(error))) }
    }

    func setEnabled(_ enabled: Bool) async {
        await policy("mcp:enabled", ["enabled": enabled], success: "Server \(enabled ? "on" : "off")") {
            self.server = self.server.merging(.object([.init("enabled", .bool(enabled))]))
        }
    }
    func setTool(_ name: String, enabled: Bool) async {
        await policy("mcp:tools:set", ["tool": name, "enabled": enabled], success: "Tool updated") {
            self.toolOverrides[name] = enabled
        }
    }
    func setAccess(_ name: String, enabled: Bool) async {
        await policy("mcp:access:set", ["client": name, "enabled": enabled], success: "Access updated") {
            self.access[name] = enabled
        }
    }
    func setAgentAccess(_ id: String, enabled: Bool) async {
        await policy("mcp:access:set", ["agentId": id, "enabled": enabled], success: "Agent access updated") {
            if let index = self.agents.firstIndex(where: { $0.id == id }) { self.agents[index].enabled = enabled }
        }
    }
    private func policy(_ channel: String, _ values: [String: Any], success: String, commit: () -> Void) async {
        guard !saving else { return }
        guard policyVerified, policyRevision != nil else {
            error = "Read this server's access settings before changing them."; return
        }
        saving = true
        defer {
            saving = false
            if hasPendingEdit { Task { await savePending() } }
        }
        var request = values
        request["serverId"] = server.id; request["projectPath"] = projectPath as Any? ?? NSNull()
        if let policyRevision { request["revision"] = policyRevision }
        do {
            let answer = try await invoke(channel, [request])
            guard answer["ok"]?.bool == true else { error = masked(answer["message"]?.string ?? "This server could not save that setting."); return }
            policyWriteSerial += 1
            commit(); error = nil; outcome = success
            if let revision = answer["revision"]?.number { policyRevision = Int(revision) }
        } catch { self.error = masked(mcpMessage(error)) }
    }
    func saveSecret() async {
        guard !secretKey.isEmpty, !secretValue.isEmpty, !saving else { return }
        guard draft.transport == .stdio else { error = "Web server secrets need a server that supports saved headers."; return }
        let key = secretKey
        let previous = draft.extras
        draft.extras = (previous.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(key + "=") }
            + [key + "=" + secretValue]).joined(separator: "\n")
        hasPendingEdit = true
        await savePending()
        guard error == nil else { draft.extras = previous; return }
        draft.extras = ""; savedDraft.extras = ""
        secretValue = ""
    }
    func remove() async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            let result = McpAddResult.from(try await invoke("mcp:remove", [["name": server.name,
                "scope": server.scope, "projectPath": projectPath as Any? ?? NSNull()]]))
            guard result.ok else { error = masked(result.message); return false }
            McpPageModel.forgetHeld(); onRemoved(); return true
        } catch { self.error = masked(mcpMessage(error)); return false }
    }
}

struct NativeCatalogMcpSettingsView: View {
    @State var model: NativeCatalogMcpSettingsModel
    private let lifecycleEnabled: Bool
    private let fixtureProjects: [PROJProject]?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glass
    init(server: McpServerStatus, projectPath: String?) {
        _model = State(initialValue: NativeCatalogMcpSettingsModel(server: server, projectPath: projectPath))
        lifecycleEnabled = true
        fixtureProjects = nil
    }
    init(model: NativeCatalogMcpSettingsModel, lifecycleEnabled: Bool = true, projects: [PROJProject]? = nil) {
        _model = State(initialValue: model)
        self.lifecycleEnabled = lifecycleEnabled
        fixtureProjects = projects
    }
    var body: some View {
        NativeCatalogSettingsFrame(title: model.server.name, switcher: { tabs }) {
          VStack(spacing: 0) {
            Form {
                switch model.tab {
                case .general: general
                case .tools: tools
                case .access: access
                case .secrets: secrets
                case .log: log
                }
                if let error = model.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                if let error = model.policyError, [.general, .tools, .access].contains(model.tab) {
                    Section {
                        HStack {
                            Text(error).foregroundStyle(.secondary)
                            Spacer()
                            DeckRetryButton("Try Again", autoRetry: true) { Task { await model.readPolicy() } }.buttonStyle(.bordered) // autoRetry: re-reads the saved policy
                        }
                    }
                }
            }.formStyle(.grouped).toggleStyle(.switch).scrollContentBackground(.hidden)
            if model.tab == .general {
                HStack {
                    Button("Remove server", role: .destructive) { model.removing = true }.buttonStyle(.bordered)
                    Spacer()
                    Text(model.saving ? "Saving…" : "Changes save as you make them.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 22).padding(.bottom, 18)
            }
          }
        }.font(.system(size: 13)).frame(minWidth: 520, minHeight: 440)
            .background(NativeCatalogTokens.page)
            .onChange(of: model.draft) { _, _ in model.changed() }
            .onChange(of: model.tab) { _, tab in
                if tab == .tools && model.inventory == nil { Task { await model.test() } }
            }
            .onAppear { if lifecycleEnabled { model.start() } }
            .onDisappear { if lifecycleEnabled { model.stop() } }
            .alert("Remove \(model.server.name)?", isPresented: $model.removing) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { Task { if await model.remove() { dismiss() } } }
            } message: { Text("Its configuration and saved keys will be removed.") }
    }
    private var tabs: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(NativeCatalogMcpTab.allCases) { tab in
                    Button { model.tab = tab } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.symbol).font(.system(size: 18))
                            Text(tab.rawValue).font(.system(size: 11, weight: model.tab == tab ? .semibold : .regular))
                        }.frame(width: 72, height: 52).contentShape(.rect)
                    }.buttonStyle(.plain).foregroundStyle(model.tab == tab ? .primary : .secondary)
                        .background(model.tab == tab ? NativeCatalogTokens.card.opacity(reduceTransparency ? 1 : 0.7) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .glassEffectID(tab.id, in: glass)
                        .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                }
            }.padding(4).glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
    // FINAL-CONNECT (SETTINGS-TRUTH rows 113/114): Kind and Project could never be saved (every change was refused),
    // and a web server's fields neither. They are plain information now; a command server's name and command still edit.
    @ViewBuilder private var general: some View {
        let command = model.server.transport == "stdio"
        Section {
            if command {
                TextField("Name", text: $model.draft.name)
                LabeledContent("Kind") { Text("Command").foregroundStyle(.secondary) }
                TextField("Command", text: $model.draft.command).font(.system(size: 12, design: .monospaced))
            } else {
                LabeledContent("Name") { Text(model.server.name).foregroundStyle(.secondary).textSelection(.enabled) }
                LabeledContent("Kind") { Text("Web address").foregroundStyle(.secondary) }
                LabeledContent("Address") { Text(model.draft.url).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            LabeledContent("Project") { Text(projectLabel).foregroundStyle(.secondary) }
        } footer: {
            Text(command ? "To change its kind or its project, remove it and add it again." : "A web server's settings are changed where it was added (its sign-in headers stay hidden). Remove it and add it again to change them here.")
        }.disabled(model.saving)
        Section {
            Toggle(isOn: Binding(get: { model.server.enabled }, set: { enabled in Task { await model.setEnabled(enabled) } })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("On")
                    Text(model.status + (model.inventory.map { " · \($0.tools.count) tools" } ?? ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.tint(NativeCatalogTokens.switchOn).disabled(model.saving || !model.policyVerified)
            LabeledContent("Test connection") {
                Button(model.testing ? "Testing…" : "Test") { Task { await model.test() } }
                    .disabled(model.testing).buttonStyle(.bordered)
            }
        }
    }
    @ViewBuilder private var tools: some View {
        if let inventory = model.inventory {
            Section {
                ForEach(inventory.tools) { tool in
                    // TRUTH-B: the policy lists only the tools switched off; every other tool is on.
                    Toggle(isOn: Binding(get: { model.toolOverrides[tool.name] ?? true },
                        set: { enabled in Task { await model.setTool(tool.name, enabled: enabled) } })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.title ?? tool.name)
                            if let description = tool.description {
                                Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).help(description)
                            }
                        }
                    }.tint(NativeCatalogTokens.switchOn).disabled(model.saving || !model.policyVerified)
                    McpToolRow(tool: tool, disabled: !model.server.enabled || model.server.state != .ready ||
                        model.toolOverrides[tool.name] == false || model.saving) { tool, args in
                        await model.callTool(tool, args)
                    }
                    .id("\(model.server.id)/\(tool.name)")
                }
                if inventory.tools.isEmpty { Text("This server offers no tools.").foregroundStyle(.secondary) }
            }
        } else {
            Section {
                Button(model.testing ? "Reading tools…" : "Read tools") { Task { await model.test() } }.disabled(model.testing)
            }
        }
    }
    @ViewBuilder private var access: some View {
        Section("Coding AIs") {
            ForEach(["claude", "codex", "gemini"], id: \.self) { client in
                Toggle(client == "claude" ? "Claude Code" : client == "codex" ? "Codex" : "Gemini", isOn: Binding(get: { model.access[client] ?? false },
                    set: { enabled in Task { await model.setAccess(client, enabled: enabled) } }))
                    .tint(NativeCatalogTokens.switchOn).disabled(model.saving || model.access[client] == nil)
            }
        }
        Section("Agents") {
            if model.agentAccessKnown {
                ForEach(model.agents) { agent in
                    Toggle(agent.name, isOn: Binding(get: { agent.enabled }, set: { enabled in
                        Task { await model.setAgentAccess(agent.id, enabled: enabled) }
                    })).tint(NativeCatalogTokens.switchOn).disabled(model.saving)
                }
                if model.agents.isEmpty { Text("No agents have been added.").foregroundStyle(.secondary) }
            } else {
                LabeledContent("Agent access", value: "Unavailable").foregroundStyle(.secondary)
            }
        }
    }
    private var projectLabel: String {
        switch model.draft.scope {
        case .user: return "Every project"
        case .local: return "This project (private)"
        default:
            guard let path = model.projectPath else { return "This project" }
            let projects = fixtureProjects ?? NativePROJLabels.shared.projects
            return PROJProjects.name(for: PROJProjects.resolve(projectID: nil, folder: path, projects: projects), projects: projects)
        }
    }
    @ViewBuilder private var secrets: some View {
        if model.server.transport != "stdio" {
            // Row 114: secrets were refused for web servers; say so instead of offering a Set value that cannot work.
            Section { Text("A web server's secrets travel in its sign-in headers, which are kept where it was added.").foregroundStyle(.secondary) }
        } else { secretsForm }
    }
    private var secretsForm: some View {
        Section {
            TextField("Name", text: $model.secretKey).font(.system(size: 12, design: .monospaced))
            SecureField("Value", text: $model.secretValue)
            LabeledContent("Environment value") {
                Button("Set value") { Task { await model.saveSecret() } }.buttonStyle(.bordered)
                    .disabled(model.secretKey.isEmpty || model.secretValue.isEmpty || model.saving)
            }
        } footer: { Text("Saved values stay hidden.") }
    }
    private var log: some View {
        Section("Last errors") {
            if let log = model.safeLog, !log.isEmpty {
                Text(log).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            } else if model.configurationVerified { Text("No errors reported.").foregroundStyle(.secondary) }
            else { Button("Read log") { Task { await model.readConfiguration() } } }
        }
    }
}
