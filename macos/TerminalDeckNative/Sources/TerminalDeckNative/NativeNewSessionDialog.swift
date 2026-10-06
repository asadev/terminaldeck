import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

// The New session dialog, drawn in Swift — a port of `NewSessionDialog.tsx`
// (with `AddAgentForm.tsx` for "Add a CLI"), same sections in the same order:
// the error and what the resolver changed, Where (only with other machines or
// servers), Project / Folder on <machine> / Folder on <server>, Agent (with
// Add a CLI), Login (with Make default), Remember; footer ⌘↩ to start, Cancel,
// Start session / Open a terminal.
//
// The page hands it the context (`native-new-session.ts`, `{type:'new-session'}`);
// it asks the engine for the rest on the page dialog's own channels; Start goes
// back to the page (`window.tdNewSession.run('start', …)`), which runs the same
// code the page dialog runs. It is a sheet on the main window.

/// Opens and closes the dialog for the page's `new-session` message.
@MainActor
enum NativeNewSession {
    private static var sheet: NSWindow?
    private static var model: NativeNewSessionModel?

    /// True when `body` was the dialog's message (WebBridge.receive's lane B line).
    static func accept(_ body: Any, from bridge: WebBridge) -> Bool {
        guard let context = NewSessionContext.parse(body) else { return false }
        show(context, bridge: bridge)
        return true
    }

    private static func show(_ context: NewSessionContext, bridge: WebBridge) {
        if let model, let sheet, sheet.isVisible || sheet.sheetParent != nil {
            // The same opening again (the servers arriving late) only updates it.
            if model.context.seq == context.seq {
                model.update(context)
                return
            }
            close()
        }
        guard let parent = bridge.webView.window else { return }
        let made = NativeNewSessionModel(context: context, bridge: bridge)
        let host = NSHostingController(rootView: NativeNewSessionDialog(model: made))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled]
        window.title = "New session"
        made.window = window
        model = made
        sheet = window
        parent.beginSheet(window)
        made.load()
    }

    static func close() {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        self.sheet = nil
        model = nil
    }
}

@MainActor
@Observable
final class NativeNewSessionModel {
    private(set) var context: NewSessionContext
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private weak var bridge: WebBridge?

    // Choices
    var selectedPath: String?
    var selectedMachine: String?
    var selectedServer: String?
    var serverPath: String?
    var chosenProvider: String?
    var chosenProfileId: String?
    var remember = true
    var filter = ""

    // What the engine said
    private(set) var projects: [NewSessionProject] = []
    private(set) var detected: CodingAIJSON = .null
    private(set) var snapshot = CodingAIAccountsSnapshot.empty
    private(set) var defaultProvider: String?
    private(set) var defaultProfileId: String?
    private(set) var memory = NewSessionMemory()
    private(set) var signIn: CodingAISignIn?
    private(set) var added: [NewSessionCustomAgent] = []

    var error: String?
    private(set) var starting = false
    private(set) var browsing = false
    var confirmRemove: String?

    // Add a CLI
    var addingAgent = false
    var draft = NewSessionAgentDraft()
    var problems: [String: String] = [:]
    private(set) var agentBusy = false

    @ObservationIgnored private var profileTicket = 0
    @ObservationIgnored private var signInTicket = 0

    init(context: NewSessionContext, bridge: WebBridge) {
        self.context = context
        self.bridge = bridge
        selectedPath = context.projectPath
        selectedMachine = context.machineId
        memory = NewSessionMemory.parse(context.memory)
    }

    func update(_ context: NewSessionContext) {
        self.context = context
    }

    // MARK: Derived

    var providerRows: [NewSessionProviderRow] { NewSessionProviders.rows(detected: detected, added: added) }

    var resolution: NewSessionResolution {
        NewSessionStart.resolve(
            providers: NewSessionStartProvider.from(providerRows),
            profiles: snapshot.accounts.map { NewSessionStartProfile(id: $0.id, name: $0.name, system: $0.system) },
            memory: memory, defaultProvider: defaultProvider, defaultProfileId: defaultProfileId,
            projectPath: selectedPath, provider: chosenProvider, profileId: chosenProfileId, resume: false)
    }

    var decided: NewSessionRequest? { resolution.request }
    var profileNotice: String? { NewSessionProviders.isolationNotice(decided?.provider) }

    var machine: NewSessionMachine? { selectedMachine.flatMap { id in context.machines.first { $0.id == id } } }
    var server: NewSessionServer? { selectedServer.flatMap { id in context.servers.first { $0.id == id } } }
    var here: Bool { machine == nil && server == nil }

    var shortlist: (filtering: Bool, shown: [NewSessionProject], hidden: Int) {
        if let machine {
            return (false, machine.folders.map { NewSessionProject(path: $0) }, 0)
        }
        return NewSessionProjects.shortlist(projects, filter: filter)
    }

    var activeProfile: CodingAIAccount? { snapshot.accounts.first { $0.id == decided?.profileId } }

    var loginHint: String? {
        NewSessionLogin.hint(signIn, optionLabel: activeProfile.map { NewSessionLogin.optionLabel($0, selectedId: decided?.profileId, report: signIn) })
    }

    var canMakeDefault: Bool {
        decided?.profileId != nil && profileNotice == nil && activeProfile != nil
            && !NewSessionLogin.isDefault(activeProfile, defaultId: snapshot.defaultId)
    }

    var canStart: Bool { !starting && (server != nil || decided != nil) }

    // MARK: Loading (the page dialog's effects)

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func load() {
        Task { projects = NewSessionProjects.parse((try? await call("projects:list")) ?? .null) }
        Task { detected = (try? await call("providers:detect")) ?? .null }
        Task { added = NewSessionCustomAgent.parse((try? await call("agents:list")) ?? .null) }
        Task {
            let stored = (try? await call("prefs:get")) ?? .null
            let id = stored["defaultProvider"].string
            defaultProvider = NewSessionProviders.isProviderId(id) ? id : "claude"
        }
        Task { snapshot = CodingAIAccountsParse.snapshot((try? await call("profiles:list")) ?? .null) }
        resolveDefaultProfile()
    }

    /// `profiles:resolve` for the chosen folder: which login a session there gets by default.
    func resolveDefaultProfile() {
        profileTicket += 1
        let mine = profileTicket
        let path = selectedPath
        Task {
            let answer = try? await call("profiles:resolve", [["projectPath": path as Any? ?? NSNull()]])
            guard mine == profileTicket else { return }
            defaultProfileId = answer.flatMap { CodingAIAccountsParse.account($0)?.id }
        }
    }

    /// `profiles:signin` for the decided login, unless it does not apply.
    func checkSignIn() {
        signInTicket += 1
        let mine = signInTicket
        guard let profileId = decided?.profileId, let provider = decided?.provider, profileNotice == nil else {
            signIn = nil
            return
        }
        Task {
            let answer = try? await call("profiles:signin", [profileId, ["provider": provider]])
            guard mine == signInTicket else { return }
            signIn = answer.flatMap(NewSessionLogin.signIn)
        }
    }

    // MARK: Actions

    func chooseHere() {
        selectedMachine = nil
        selectedServer = nil
        selectedPath = context.projectPath
    }

    func choose(machine: NewSessionMachine) {
        selectedMachine = machine.id
        selectedServer = nil
        selectedPath = machine.folders.first
    }

    func choose(server: NewSessionServer) {
        selectedServer = server.id
        selectedMachine = nil
        serverPath = nil
    }

    func browse() {
        browsing = true
        window?.alphaValue = 0 // the page dialog hides while the folder panel is up
        Task {
            defer {
                browsing = false
                window?.alphaValue = 1
            }
            do {
                let picked = try await call("project:pick")
                guard let path = picked.string, !path.isEmpty else { return }
                projects = NewSessionProjects.with(projects, path)
                selectedPath = path
            } catch {
                self.error = "Could not open the folder picker."
            }
        }
    }

    func remove(_ path: String) {
        confirmRemove = nil
        projects.removeAll { $0.path == path }
        if selectedPath == path { selectedPath = nil }
        // The page's store does it (ends the folder's sessions, then `projects:remove`).
        runOnPage("remove-project", argument: path)
    }

    func addAgent() {
        guard !agentBusy else { return }
        agentBusy = true
        Task {
            defer { agentBusy = false }
            do {
                switch NewSessionAddAgent.outcome(try await call("agents:add", [draft.json])) {
                case .problems(let said):
                    problems = said
                case .added(let id):
                    added = NewSessionCustomAgent.parse((try? await call("agents:list")) ?? .null)
                    detected = (try? await call("providers:detect")) ?? .null
                    chosenProvider = id
                    draft = NewSessionAgentDraft()
                    problems = [:]
                    addingAgent = false
                }
            } catch {
                problems = ["command": (error as? EngineWireError)?.description ?? "That agent could not be added."]
            }
        }
    }

    func removeAgent(_ id: String) {
        Task {
            _ = try? await call("agents:remove", [id])
            added = NewSessionCustomAgent.parse((try? await call("agents:list")) ?? .null)
            if chosenProvider == id { chosenProvider = nil }
        }
    }

    func makeDefaultLogin() {
        guard let profileId = decided?.profileId else { return }
        Task {
            do {
                _ = try await call("profiles:set-default", [profileId])
                snapshot = CodingAIAccountsParse.snapshot(try await call("profiles:list"))
            } catch {
                self.error = (error as? EngineWireError)?.description ?? "Could not change the default login."
            }
        }
    }

    func edit(_ field: String, _ value: String) {
        switch field {
        case "label": draft.label = String(value.prefix(NewSessionAddAgent.maxLabel))
        case "description": draft.description = String(value.prefix(NewSessionAddAgent.maxDescription))
        case "command": draft.command = value
        case "args": draft.args = value
        default: draft.resumeArgs = value
        }
        problems[field] = nil
    }

    func submit() {
        guard !starting else { return }
        if let server {
            starting = true
            var body: [String: Any] = ["serverId": server.id, "serverName": server.name]
            body["path"] = serverPath ?? NSNull()
            runOnPage("server", object: body)
            NativeNewSession.close()
            return
        }
        guard let request = decided else { return }
        starting = true
        var body: [String: Any] = ["request": request.json, "machineId": selectedMachine as Any? ?? NSNull()]
        // Remembered for this folder only on this Mac (see the page dialog's note on Remember).
        if remember && here {
            memory = memory.remembering(request)
            body["memory"] = memory.json
        }
        runOnPage("start", object: body)
        NativeNewSession.close()
    }

    func cancel() {
        runOnPage("close")
        NativeNewSession.close()
    }

    // MARK: Back to the page

    private func runOnPage(_ name: String, argument: String? = nil, object: [String: Any]? = nil) {
        var arg = "undefined"
        if let argument { arg = PageCommand.javaScriptString(argument) }
        if let object, let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8) {
            arg = text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        bridge?.webView.evaluateJavaScript("window.tdNewSession && window.tdNewSession.run('\(name)', \(arg))", completionHandler: nil)
    }
}

// MARK: - The dialog

struct NativeNewSessionDialog: View {
    @Bindable var model: NativeNewSessionModel

    var body: some View {
        VStack(spacing: 0) {
            Text(model.addingAgent ? "Add a CLI" : "New session")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

            ScrollView {
                Group {
                    if model.addingAgent {
                        NativeAddAgentForm(model: model)
                    } else {
                        form
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 620)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.selectedPath) { model.resolveDefaultProfile() }
        .onChange(of: model.decided?.profileId) { model.checkSignIn() }
        .onChange(of: model.decided?.provider) { model.checkSignIn() }
        .onChange(of: model.profileNotice) { model.checkSignIn() }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if model.addingAgent {
                Spacer()
                // Back to the list, not out of the dialog.
                Button("Back") {
                    model.addingAgent = false
                    model.problems = [:]
                }
                Button(model.agentBusy ? "Checking…" : "Add CLI") { model.addAgent() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.agentBusy)
            } else {
                Text("⌘↩ to start").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.starting ? "Starting…" : model.server == nil ? "Start session" : "Open a terminal") { model.submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
            }
        }
        .background {
            // Esc closes the whole dialog in both views, as the page modal does.
            Button("") { model.cancel() }.keyboardShortcut(.cancelAction).hidden()
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            // What is wrong, and what the resolver quietly changed — at the top.
            if model.server == nil, let problem = model.resolution.problem {
                Text(problem).font(.callout).foregroundStyle(.orange)
            }
            if model.server == nil, !model.resolution.notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.resolution.notices) { notice in
                        Text(notice.message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            if !model.context.machines.isEmpty || !model.context.servers.isEmpty {
                whereSection
            }
            projectSection
            if model.server == nil { agentSection }
            if model.here {
                loginSection
                Toggle("Remember these choices for this project", isOn: $model.remember)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var whereSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeNewSessionHeading("Where")
            VStack(spacing: 6) {
                NativeNewSessionChoice(selected: model.here, action: model.chooseHere) {
                    Text(model.context.hereName)
                }
                ForEach(model.context.machines) { row in
                    NativeNewSessionChoice(selected: model.machine?.id == row.id, action: { model.choose(machine: row) }) {
                        Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                        Text(row.name)
                    }
                }
                ForEach(model.context.servers) { row in
                    NativeNewSessionChoice(selected: model.server?.id == row.id, action: { model.choose(server: row) }) {
                        Text(row.name)
                    }
                }
            }
            if let server = model.server {
                Text("A terminal on \(server.name). An agent and a login are programs on this Mac, so neither is asked for here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var projectSection: some View {
        if let server = model.server {
            VStack(alignment: .leading, spacing: 8) {
                NativeNewSessionHeading("Folder on \(server.name)")
                // The server's own folder picker (lane G, NativeServerFolderPicker.swift).
                NativeServerFolderPicker(serverId: server.id, serverName: server.name, path: $model.serverPath)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    NativeNewSessionHeading(model.machine.map { "Folder on \($0.name)" } ?? "Project")
                    Spacer()
                    // Browse opens this machine's file panel, so it is absent on another machine.
                    if model.machine == nil {
                        Button("Browse…") { model.browse() }
                            .buttonStyle(.link)
                            .disabled(model.browsing)
                    }
                }
                let list = model.shortlist
                if list.filtering {
                    TextField("Filter \(model.projects.count) folders", text: $model.filter)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filter projects")
                        .onSubmit { model.submit() }
                }
                if list.shown.isEmpty {
                    Text(emptyLine).font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(list.shown) { project in
                            NativeNewSessionProjectRow(project: project,
                                                       selected: project.path == model.selectedPath,
                                                       liveSessions: model.context.sessions(in: project.path),
                                                       confirming: model.confirmRemove == project.path,
                                                       model: model)
                        }
                    }
                }
                if list.hidden > 0 {
                    Text("\(list.hidden) more — narrow the filter, or Browse.").font(.callout).foregroundStyle(.secondary)
                }
                if let path = model.selectedPath, !list.shown.contains(where: { $0.path == path }) {
                    Text(path).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path)
                }
            }
        }
    }

    private var emptyLine: String {
        if let machine = model.machine {
            return "\(machine.name) is not sharing any folder with this one yet. Choose one there, in its remote access settings."
        }
        return model.filter.trimmingCharacters(in: .whitespaces).isEmpty
            ? "No recent projects. Browse for a folder to run the session in."
            : "No folder matches that. Browse for one instead."
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeNewSessionHeading("Agent")
            VStack(spacing: 6) {
                ForEach(model.providerRows) { row in
                    NativeNewSessionAgentCard(row: row, selected: row.id == model.decided?.provider, model: model)
                }
                if model.here {
                    Button { model.addingAgent = true } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("+").font(.title3).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add a CLI").fontWeight(.medium)
                                Text("Any other command-line agent on this machine.").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .contentShape(.rect)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var loginSection: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Login").fontWeight(.medium)
                if let line = model.profileNotice ?? model.loginHint {
                    Text(line).font(.callout).foregroundStyle(.secondary)
                        .help(NewSessionLogin.line(model.signIn) ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if model.canMakeDefault {
                Button("Make default") { model.makeDefaultLogin() }.buttonStyle(.link)
            }
            Picker("Login", selection: Binding(get: { model.decided?.profileId ?? "" },
                                               set: { model.chosenProfileId = $0.isEmpty ? nil : $0 })) {
                if model.decided?.profileId == nil {
                    Text(model.profileNotice != nil ? "Not applicable" : "The agent’s own login").tag("")
                }
                ForEach(model.snapshot.accounts) { account in
                    Text(NewSessionLogin.optionLabel(account, selectedId: model.decided?.profileId, report: model.signIn))
                        .tag(account.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.profileNotice != nil || model.snapshot.accounts.isEmpty)
        }
    }
}

// MARK: - Parts

private struct NativeNewSessionHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline)
    }
}

/// A radio card — the same card the Where rows and the Agent rows use.
private struct NativeNewSessionChoice<Content: View>: View {
    let selected: Bool
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct NativeNewSessionProjectRow: View {
    let project: NewSessionProject
    let selected: Bool
    let liveSessions: Int
    let confirming: Bool
    let model: NativeNewSessionModel

    var body: some View {
        HStack(spacing: 8) {
            NativeNewSessionChoice(selected: selected, action: { model.selectedPath = project.path }) {
                Text(project.name).fontWeight(.medium)
                // The path is the identity — two folders can share a name.
                Text(project.path).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(project.path)
            }
            if confirming {
                HStack(spacing: 6) {
                    Text("Delete \(liveSessions) session\(liveSessions == 1 ? "" : "s")?")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) { model.remove(project.path) }
                    Button("Keep") { model.confirmRemove = nil }
                }
                .accessibilityLabel("Remove \(project.name)")
            } else {
                Button("Remove") {
                    if liveSessions > 0 { model.confirmRemove = project.path } else { model.remove(project.path) }
                }
                .help("Remove from this list — the folder is not deleted")
                .accessibilityLabel("Remove \(project.name) from this list")
            }
        }
    }
}

private struct NativeNewSessionAgentCard: View {
    let row: NewSessionProviderRow
    let selected: Bool
    let model: NativeNewSessionModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.chosenProvider = row.id } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.label).fontWeight(.medium)
                            if !row.available {
                                Text("Not installed")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                        Text(row.hint).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !row.available, let install = row.install {
                            Text(install).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!row.available)
            if row.isCustom {
                Button("Remove") { model.removeAgent(row.id) }
            }
        }
        .padding(10)
        .opacity(row.available ? 1 : 0.75)
        .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)))
    }
}

/// Where a server terminal opens, in `folderLine`'s words, until E1's folder
/// picker (with its Browse… window) is drawn natively.
private struct NativeServerFolderLine: View {
    let name: String
    let path: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path ?? "Wherever this sign-in lands").font(.callout.monospaced())
            Text(path == nil ? "No folder chosen, so it lands wherever the sign-in does." : "Chosen for this session.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add a CLI (`AddAgentForm.tsx`)

struct NativeAddAgentForm: View {
    @Bindable var model: NativeNewSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("label", "Name", hint: "What the picker and the tab will call it.", mono: false)
            field("command", "Command",
                  hint: "A name on your PATH, or the full path to the program. Just the program — arguments go below.", mono: true)
            field("args", "Arguments", hint: NewSessionAddAgent.argsHint(model.draft.args), mono: true)
            field("resumeArgs", "Arguments to continue the last session",
                  hint: NewSessionAddAgent.resumeHint(model.draft.resumeArgs), mono: true)
            field("description", "Description", hint: "Optional. One line under the name in this list.", mono: false)
            Text(NewSessionAddAgent.note())
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func value(_ field: String) -> String {
        switch field {
        case "label": model.draft.label
        case "description": model.draft.description
        case "command": model.draft.command
        case "args": model.draft.args
        default: model.draft.resumeArgs
        }
    }

    private func field(_ key: String, _ label: String, hint: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).fontWeight(.medium)
            TextField("", text: Binding(get: { value(key) }, set: { model.edit(key, $0) }))
                .textFieldStyle(.roundedBorder)
                .font(mono ? .body.monospaced() : .body)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
                .onSubmit { model.addAgent() }
            // The complaint replaces the hint rather than joining it.
            if let problem = model.problems[key] {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else {
                Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
