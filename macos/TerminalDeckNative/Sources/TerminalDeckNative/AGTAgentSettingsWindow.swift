import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Items 100 + 87: the Agent settings pop-up window (ObjectWindows kind "agent", 600×690).
/// Tabs General · Coding AI · Limits · Tools · Advanced. One grouped Form per tab, no disclosure
/// triangles. Changes save as you make them through the profile model (tasks:agent-save + AGS).
/// U114 (#190): the one editor of a saved agent. Settings › Tasks and the New agent page open it; no other form edits an agent.
struct AGTAgentSettingsWindow: View {
    @Bindable var model: AGOPTProfileModel
    @State private var tab: String
    @State private var choosingIcon = false
    @State private var editingHooks = false
    @State private var editingEnvironment = false
    @State private var accountLine: String?

    init(model: AGOPTProfileModel, initialTab: String = "general") {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    static let size = CGSize(width: 600, height: 690)

    /// Opens (or focuses) the window for one saved agent. Registers the provider on first use.
    @MainActor static func open(_ agentID: String) {
        register()
        if !ObjectWindows.open(ObjectRef(kind: "agent", id: agentID)) {
            AGTAgentsStore.shared.message = ObjectWindows.shared.lastError ?? "Agent settings could not open."
        }
    }

    @MainActor static func register() {
        let ref = ObjectRef(kind: "agent", id: "probe")
        guard !ObjectWindows.hasProvider(for: ref) else { return }
        ObjectWindows.register(kind: "agent", title: { ref in
            AGTAgentsStore.shared.agent(ref.id)?.name ?? "Agent settings"
        }, defaultSize: size, content: { ref in
            AnyView(AGTAgentSettingsWindowHost(agentID: ref.id))
        })
    }

    private var tabs: [DeckSwitchItem<String>] {
        [.init(id: "general", title: "General", symbol: "person.2"), .init(id: "coding", title: "Coding AI", symbol: "cpu"),
         .init(id: "limits", title: "Limits", symbol: "clock"), .init(id: "tools", title: "Tools", symbol: "wrench.and.screwdriver"),
         .init(id: "advanced", title: "Advanced", symbol: "slider.horizontal.3")]
    }
    private var servers: [String] {
        let offered = (model.snapshot["choices"]["mcp"].elements ?? []).compactMap { $0["name"].string ?? $0.string }
        return Array(Set(offered).union(model.ags.settings.mcpServers.keys)).sorted()
    }
    private var fileName: String { model.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "\(model.id).md" }

    var body: some View {
        VStack(spacing: 0) {
            GlassSwitch(selection: $tab, items: tabs).padding(.top, 14).padding(.bottom, 6)
            Form {
                if let problem = model.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(DeckTokens.warn) }
                }
                switch tab {
                case "coding": coding
                case "limits": limits
                case "tools": tools
                case "advanced": advanced
                default: general
                }
            }
            .formStyle(.grouped)
            .disabled(!model.loaded)
            Divider()
            HStack(spacing: 8) {
                Text(model.saveStatus.isEmpty || model.saveStatus == "Saved"
                     ? "Changes save as you make them, and are written back to \(fileName)." : model.saveStatus)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show the file") { model.showFile() }.buttonStyle(.borderless).disabled(model.filePath == nil)
            }
            .padding(.horizontal, 16).frame(height: 38)
        }
        .frame(minWidth: 520, minHeight: 520)
        .background(DeckTokens.page)
        .onChange(of: model.draft) { _, _ in model.changed() }
        .onChange(of: model.ags.settings) { _, _ in model.changed() }
        .sheet(isPresented: $editingHooks) {
            sheet("Hooks") { NativeAGSHooksEditor(settings: $model.ags.settings) }
        }
        .sheet(isPresented: $editingEnvironment) {
            sheet("Environment variables") { NativeAGSEnvironmentEditor(values: $model.ags.settings.environment) }
        }
    }

    private func sheet<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView { content().frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer(); Button("Done") { editingHooks = false; editingEnvironment = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 560, height: 480)
    }

    private func row<Control: View>(_ label: String, _ help: String, @ViewBuilder control: () -> Control) -> some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: General

    private var pictureIcon: AGTIcon { AGTIcon.parse(model.draft.icon) ?? model.agent?.icon ?? .symbol("person.crop.circle") }
    private var pictureColour: String? { model.draft.icon == nil ? model.agent?.iconColour : AGTIcon.colour(model.draft.icon) }

    private var general: some View {
        Section {
            row("Name", "What you call it everywhere.") {
                TextField("Agent name", text: $model.draft.name).textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 230)
            }
            row("Picture", "Shown on cards and in the org chart.") {
                Button { choosingIcon = true } label: {
                    AgentAvatar(icon: pictureIcon, size: 34, id: model.agent?.profileID ?? model.agent?.id, colour: pictureColour)
                }
                .buttonStyle(.plain).help("Change the picture")
                .popover(isPresented: $choosingIcon) {
                    AGTIconPicker(current: pictureIcon) { icon in
                        model.draft.icon = icon.map { AGTIcon.raw($0, colour: pictureColour) }; choosingIcon = false
                    }
                }
            }
            if let agent = model.agent, agent.kind == .profile {
                row("Role", "The seat it sits in. Memory belongs to the role, so a new hire in this role inherits it.") {
                    AGTRolePicker(agent: agent)
                }
            }
            row("Colour", "The picture's colour. Automatic keeps one fixed colour for this agent.") {
                AgentColourPicker(id: model.agent?.profileID ?? model.agent?.id, colour: Binding(
                    get: { pictureColour },
                    set: { model.draft.icon = AGTIcon.raw(pictureIcon, colour: $0) }))
            }
            row("What it does", "One line about what it does.") {
                TextField("What it does", text: $model.draft.role).textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 260)
            }
            row("Project", "The project it works in.") {
                Picker("Project", selection: Binding(get: { model.draft.projectID ?? PROJProjects.independentID }, set: { next in
                    let before = model.agent.map { AGTLeads.projectID($0) }
                    model.draft.projectID = next
                    // Its role's memory stays with the old project unless the person brings it along.
                    if let agent = model.agent, !model.isFixture {
                        AGTLeads.offerToMoveMemory(agent, from: before == PROJProjects.independentID ? nil : before,
                                                   to: next == PROJProjects.independentID ? nil : next)
                    }
                })) {
                    DeckRowLabel.independent.tag(PROJProjects.independentID)
                    ForEach(NativePROJLabels.shared.projects.filter { $0.id != PROJProjects.independentID }) { DeckRowLabel.project($0).tag($0.id) }
                    if let current = model.draft.projectID, current != PROJProjects.independentID,
                       !NativePROJLabels.shared.projects.contains(where: { $0.id == current }) {
                        DeckRowLabel(current, image: DeckRowIcon.project(nil, name: current)).tag(current)
                    }
                }.labelsHidden().fixedSize()
            }
            row("Reports to", "Its manager in the org chart.") {
                Picker("Reports to", selection: Binding(get: { model.draft.reportsTo ?? "" }, set: { model.draft.reportsTo = $0.isEmpty ? nil : $0 })) {
                    DeckRowLabel("No one", image: DeckRowIcon.assignee("none")).tag("")
                    DeckRowLabel("Hoot", image: DeckRowIcon.hoot).tag(AGTDirectory.hootID)
                    ForEach(managers) { DeckRowLabel.agent(id: $0.id, name: $0.name, icon: $0.icon).tag($0.id) }
                }.labelsHidden().fixedSize()
            }
            row("Reviewer", "Who checks its work before it is done.") {
                Picker("Reviewer", selection: $model.draft.reviewerAgent) {
                    DeckRowLabel("You check it (Hoot checks tasks it asked for)", image: DeckRowIcon.assignee("me")).tag("") // SETTINGS-TRUTH row 77
                    ForEach(AGTAgentsStore.shared.profiles.filter { $0.id != model.id && $0.status == .active }) {
                        DeckRowLabel.agent(id: $0.id, name: $0.name, icon: $0.icon).tag($0.id)
                    }
                    if !model.draft.reviewerAgent.isEmpty, !AGTAgentsStore.shared.profiles.contains(where: { $0.id == model.draft.reviewerAgent }) {
                        DeckRowLabel(model.draft.reviewerAgent, image: DeckRowIcon.agent(id: model.draft.reviewerAgent)).tag(model.draft.reviewerAgent)
                    }
                }.labelsHidden().fixedSize()
            }
        }
    }
    private var managers: [AgentProfile] {
        let blocked = AGTOrgChart.below(model.id, managers: AGTAgentsStore.shared.managers).union([model.id])
        return AGTAgentsStore.shared.profiles.filter { !blocked.contains($0.id) && $0.status != .archived }
    }

    // MARK: Coding AI (+ Save tokens, item 87)

    private var efficiency: AGOPTEfficiencySettings { model.ags.settings.efficiency ?? .init() }
    private func efficiencyBinding<T>(_ path: WritableKeyPath<AGOPTEfficiencySettings, T>) -> Binding<T> {
        Binding(get: { efficiency[keyPath: path] }, set: { value in
            var next = efficiency; next[keyPath: path] = value; model.ags.settings.efficiency = next
        })
    }
    private func toggle(_ path: WritableKeyPath<AGOPTEfficiencySettings, Bool?>, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { efficiency[keyPath: path] ?? fallback }, set: { value in
            var next = efficiency; next[keyPath: path] = value; model.ags.settings.efficiency = next
        })
    }

    private static let fixtureAccountLine = "This Mac’s own Claude Code login · nothing is set in Settings"
    /// What the account line depends on: the AI, the agent's own old pick, its folder and its seat.
    private func accountQuery(_ provider: String) -> String {
        [provider, model.draft.account, model.draft.defaultProject, model.agent.flatMap { AGTLeads.seat($0)?.key } ?? ""].joined(separator: "\u{1F}")
    }
    /// "Work · from its role": the account a new session of this agent gets and where that was chosen.
    private func accountText(_ provider: String) async -> String? {
        if model.isFixture { return Self.fixtureAccountLine }
        var input: [String: Any] = ["provider": provider]
        if !model.draft.defaultProject.isEmpty { input["projectPath"] = model.draft.defaultProject }
        if !model.draft.account.isEmpty { input["sessionProfileId"] = model.draft.account }
        if let seat = model.agent.flatMap({ AGTLeads.seat($0)?.key }) { input["seat"] = seat }
        guard let raw = try? await EngineBridge.shared.invoke("profiles:effective", [input]) as? [String: Any], let name = raw["name"] as? String else {
            return "Could not read the account"
        }
        switch raw["source"] as? String {
        case "session": return name + " · picked for this agent alone"
        case "seat": return name + " · from its role"
        case "project": return name + " · from its project"
        case "app": return name + " · from the Terminal Deck default"
        default: return "This Mac’s own " + NativeAGSWords.provider(provider) + " login · nothing is set in Settings"
        }
    }

    private var coding: some View {
        let provider = model.ags.settings.provider
        return Group {
            Section("Who runs it") {
                row("Coding AI", "Claude Code, Codex or Gemini.") {
                    Picker("Coding AI", selection: $model.ags.settings.provider) {
                        ForEach(AGSCapabilities.providers, id: \.self) { Text(NativeAGSWords.provider($0)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if model.snapshot["choices"]["providersInstalled"][provider].bool == false {
                    HStack {
                        Text("\(NativeAGSWords.provider(provider)) isn't installed on this Mac yet.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        // CONNECT-SKILLS: one click installs it, then its sign-in opens; this window reads again.
                        if model.isFixture || !["claude", "codex", "gemini"].contains(provider) {
                            Button("Set up…") { if !model.isFixture { NativeBRSettingsLink.open("agents") } }
                        } else {
                            NativeAIToolInstallButton(tool: provider) {
                                Task { await model.reload() }
                                NativeAIToolInstallModel.continueToSignIn(provider)
                            }
                        }
                    }
                }
                // ACCOUNTS-SPEC §4: shown here, changed in the one place (Settings › Coding AIs › Who uses what).
                row("Account", "Chosen in Settings: for its role, its project or the whole app.") {
                    // The line above, the buttons below: the window is narrow and the line can be long.
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(accountLine ?? (model.isFixture ? Self.fixtureAccountLine : "…")).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Account: " + (accountLine ?? "loading"))
                        HStack(spacing: 8) {
                            // An account once picked for this agent alone still wins until it is let go.
                            if !model.draft.account.isEmpty {
                                Button("Use its role’s account") { model.draft.account = "" }
                                    .help("Stops using the account picked for this agent alone. It then follows its role, its project or the whole app, as set in Settings.")
                            }
                            Button("Change in Settings…") {
                                guard !model.isFixture else { return }
                                AppModel.shared.requestSettings()
                                AppModel.shared.selectSettingsSection("agents")
                            }
                        }
                    }
                }
                .task(id: accountQuery(provider)) { accountLine = await accountText(provider) }
                row("Model", "Used where the playbook row for a job leaves the model “Not set”. Leave empty for the app default.") { // PLAYBOOK-SEATS: playbook row, then this, then the app default
                    TextField("App default", text: Binding(get: { model.ags.settings.model ?? "" }, set: { model.ags.settings.model = NativeAGSWords.optional($0) }))
                        .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 200).accessibilityLabel("Model")
                }
                // FINAL-CONNECT (row 82): "App default" clears a set effort; Gemini takes one only with a Gemini 3 model.
                row("Effort", provider == "gemini" ? "How hard it thinks on each task. Gemini takes this only with a Gemini 3 model named above; otherwise the agent does not start." : "How hard it thinks on each task.") {
                    Picker("Effort", selection: Binding(get: { model.ags.settings.effort ?? "" }, set: { model.ags.settings.effort = $0.isEmpty ? nil : $0 })) {
                        Text("App default").tag("")
                        ForEach(AGSCapabilities.efforts(provider: provider).filter { !["xhigh", "minimal", "ultra"].contains($0) || $0 == model.ags.settings.effort }, id: \.self) { Text(NativeAGSWords.option($0)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                row("Before it changes files", "Ask first, plan only, or change without asking.") {
                    Picker("Before it changes files", selection: Binding(get: { model.ags.settings.permissionMode ?? "" }, set: { model.ags.settings.permissionMode = $0.isEmpty ? nil : $0 })) {
                        Text("App default").tag("")
                        ForEach(AGSCapabilities.permissionModes(provider: provider), id: \.self) { Text(NativeAGSWords.option($0)).tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            Section("Save tokens") {
                row("Reuse the session that knows the work", "Its next task continues the same conversation when the project and settings match.") {
                    Toggle("Reuse the session", isOn: toggle(\.reuseContext, default: true)).labelsHidden().toggleStyle(.switch)
                }
                row("Stop when the job is done", "Close the coding AI as soon as the task finishes. Its conversation is kept for next time.") {
                    Toggle("Stop when done", isOn: model.stopWhenDone).labelsHidden().toggleStyle(.switch)
                }
                // SETTINGS-TRUTH row 107: not a setting (it cannot change), so plain info, not a row with a value.
                Text("It always waits for news and never checks in a loop: it sleeps until an event wakes it.")
                    .font(.caption).foregroundStyle(.secondary)
                // SETTINGS-TRUTH row 49: the engine's real default (on), and it is a request to the agent.
                row("Heavy jobs one at a time", "Asks the agent to take a shared lock before builds and test runs, so they wait for each other across all agents.") {
                    Toggle("Heavy jobs one at a time", isOn: toggle(\.serializeHeavyJobs, default: true)).labelsHidden().toggleStyle(.switch)
                }
                row("Extra add-ons", "Switch off add-ons and their servers. Terminal Deck's own tools stay.") {
                    Toggle("Add-ons on", isOn: Binding(get: { !(efficiency.addonsOff ?? false) }, set: { on in
                        var next = efficiency; next.addonsOff = !on; model.ags.settings.efficiency = next
                    })).labelsHidden().toggleStyle(.switch)
                }
                row("Token budget per task", "A warning note on the task at the share set in Warn me at; nothing stops the task. Leave empty for none.") { // SETTINGS-TRUTH row 80
                    tokenField("No limit", value: model.perTaskTokens)
                }
                row("Warn me at", "A note on the task when it gets close to its budget.") {
                    Picker("Warn me at", selection: Binding(get: { efficiency.warningPercent ?? 80 }, set: { value in
                        var next = efficiency; next.warningPercent = value; model.ags.settings.efficiency = next
                    })) {
                        Text("50%").tag(50); Text("80%").tag(80); Text("90%").tag(90)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            // PC remote workers: a worker on another computer is a separate choice from the local coding AI above.
            if !model.isFixture { Section("Remote workers") { NativeRemoteWorkersView() } }
        }
    }

    private func tokenField(_ placeholder: String, value: Binding<Int?>) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 120)
            Text("tokens").foregroundStyle(.secondary)
        }
    }

    // MARK: Limits

    private var limits: some View {
        Section {
            row("Tasks at once", "How many tasks it may run at the same time.") {
                Stepper((Int(model.draft.maxConcurrent) ?? 0) == 0 ? "No limit" : "\(Int(model.draft.maxConcurrent) ?? 0)", value: Binding(get: { Int(model.draft.maxConcurrent) ?? 0 }, set: { model.draft.maxConcurrent = String($0) }), in: 0...TasksLimits.maxConcurrent)
                    .fixedSize()
            }
            row("Longest run", "Stop a task that runs longer than this.") {
                Picker("Longest run", selection: $model.draft.maxRunMinutes) {
                    Text("30 min").tag("30"); Text("1 h").tag("60"); Text("2 h").tag("120"); Text("No limit").tag("0")
                    if !["30", "60", "120", "0"].contains(model.draft.maxRunMinutes) { Text("\(model.draft.maxRunMinutes) min").tag(model.draft.maxRunMinutes) }
                }.labelsHidden().fixedSize()
            }
            row("Keep open after finishing", "Leave its session open so you can look at it.") {
                Picker("Keep open", selection: Binding(get: {
                    model.draft.keepAliveUntilClose ? "close" : (["0", "30", "60", "120"].contains(model.draft.keepAliveMinutes) ? model.draft.keepAliveMinutes : (model.draft.keepAliveMinutes.isEmpty ? "0" : model.draft.keepAliveMinutes))
                }, set: { value in
                    if value == "close" { model.draft.keepAliveUntilClose = true }
                    else { model.draft.keepAliveUntilClose = false; model.draft.keepAliveMinutes = value }
                    model.ags.settings.keepOpen = value != "0"
                })) {
                    Text("Close at once").tag("0"); Text("30 min").tag("30"); Text("1 h").tag("60"); Text("2 h").tag("120"); Text("Until I close it").tag("close")
                    if !["0", "30", "60", "120", ""].contains(model.draft.keepAliveMinutes) && !model.draft.keepAliveUntilClose {
                        Text("\(model.draft.keepAliveMinutes) min").tag(model.draft.keepAliveMinutes)
                    }
                }.labelsHidden().fixedSize()
            }
        }
    }

    // MARK: Tools

    private var tools: some View {
        Group {
            Section("Tools") {
                NativeToolUseRestrictionsEditor(value: $model.draft.toolUseRestrictions, agentName: model.draft.name, busy: model.saving)
                NativeAGSToolsField(label: "Tools it should use", values: $model.draft.toolsPreferred)
                NativeAGSToolsField(label: "Tools it should avoid", values: $model.draft.toolsAvoided)
                Text("Advice. It may still pick others. To stop a tool, block it below.").font(.caption).foregroundStyle(.secondary)
                NativeAGSToolsField(label: "Tools it must not use", values: $model.ags.settings.deniedTools)
                Label("Blocked: it cannot use these.", systemImage: "nosign").font(.caption).foregroundStyle(DeckTokens.bad)
                row("Allow only these tools", "Off: it uses its coding AI's own tools. Blocked tools always win.") {
                    Toggle("Allow only these tools", isOn: Binding(get: { model.ags.settings.allowedTools != nil }, set: {
                        model.ags.settings.allowedTools = $0 ? (model.ags.settings.allowedTools ?? []) : nil
                    })).labelsHidden().toggleStyle(.switch)
                }
                if model.ags.settings.allowedTools != nil {
                    NativeAGSToolsField(label: "Allowed tools", values: Binding(get: { model.ags.settings.allowedTools ?? [] }, set: { model.ags.settings.allowedTools = $0 }))
                    Text("An empty list allows no tools.").font(.caption).foregroundStyle(.secondary)
                }
                // SETTINGS-TRUTH row 84: Codex can block or allow only app tools (mcp__server__tool); a built-in name stops it starting.
                if model.ags.settings.provider == "codex" {
                    Text("Codex can block or allow only add-on tools (names like mcp__server__tool). A built-in name such as Bash stops this agent starting on Codex.")
                        .font(.caption).foregroundStyle(DeckTokens.warn)
                }
                row("Turn all skills off", "It starts with no skills at all.") {
                    Toggle("Turn all skills off", isOn: $model.draft.skillsOff).labelsHidden().toggleStyle(.switch)
                        .disabled(!AgentCapabilities.enforces(model.profile?.provider, .skillsOff))
                }
            }
            Section("MCP servers") {
                if servers.isEmpty {
                    Text("No MCP servers are installed.").foregroundStyle(.secondary)
                } else {
                    // FINAL-CONNECT (row 85): On means "as its own settings say" (it never forces a server on, which made
                    // every launch fail for a server that is off there); Off keeps it from this agent.
                    ForEach(servers, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { model.ags.settings.mcpServers[name] ?? true }, set: { model.ags.settings.mcpServers[name] = $0 ? nil : false }))
                    }
                    Text("On follows the server's own settings: a server that is off there stays off. A Codex plugin's server cannot be turned off for one agent; switching it off stops this agent starting on Codex.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        Section {
            row("Working folder", "Used when a task has no folder of its own.") {
                HStack(spacing: 6) {
                    Text(model.ags.settings.workingFolder.map(AGFRAMEStyle.shortPath) ?? "None") // SETTINGS-TRUTH row 87
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            // SETTINGS-TRUTH row 86: it forces a Claude Code run, so it is only for agents whose Coding AI is Claude Code
            // (a name already saved on another AI can still be cleared).
            row("Claude Code agent name", model.ags.settings.provider == "claude" ? "Runs it as claude --agent <name>." : "Only for Claude Code agents. This agent runs on \(NativeAGSWords.provider(model.ags.settings.provider)).") {
                TextField("Optional", text: $model.draft.claudeAgent).textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 200)
                    .disabled(model.ags.settings.provider != "claude" && model.draft.claudeAgent.isEmpty)
            }
            row("Hooks", "Commands it runs at set moments.") {
                HStack {
                    Text(model.ags.settings.hooks.isEmpty ? "None" : "\(model.ags.settings.hooks.count) hook\(model.ags.settings.hooks.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Button("Edit…") { editingHooks = true }
                }
            }
            row("Environment variables", "Values it starts with.") {
                HStack {
                    Text(model.ags.settings.environment.isEmpty ? "None" : "\(model.ags.settings.environment.count) set").foregroundStyle(.secondary)
                    Button("Edit…") { editingEnvironment = true }
                }
            }
            row("Check command", "Runs after a task to check the work. A reviewer agent, when one is set, replaces it.") { // SETTINGS-TRUTH row 78
                TextField("Optional", text: $model.draft.verifyCommand).textFieldStyle(.roundedBorder).labelsHidden()
                    .font(.system(size: 12, design: .monospaced)).frame(maxWidth: 240)
            }
            // U114 (#190): this window is the one editor; what it is told and which skills it uses are its page's own tabs.
            row("Instructions and skills", "Written and chosen on its page, under Instructions and Skills.") {
                Button("Open its page") {
                    guard !model.isFixture else { return }
                    AGTAgentsStore.shared.openProfile = model.id; AppModel.shared.select(NativeINT2Navigation.allID)
                }
            }
            row("Its file", fileName) {
                Button("Show its file") { model.showFile() }.disabled(model.filePath == nil)
            }
        }
    }

    private func chooseFolder() {
        guard !model.isFixture else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.ags.settings.workingFolder = url.path } // front-ok: person's button
    }
}

/// The window's owner: acquires the shared profile model while the window is open.
private struct AGTAgentSettingsWindowHost: View {
    let agentID: String
    @State private var held: AGOPTProfileModel?
    var body: some View {
        let model = AGOPTProfileModel.owner(agentID)
        AGTAgentSettingsWindow(model: model)
            .task(id: agentID) {
                if held !== model { held?.release(); held = model; await model.acquire() }
            }
            .onDisappear { held?.release(); held = nil }
    }
}
