import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Item 100: one agent's profile. Tabs Dashboard · Memory · Instructions · Skills · Runs
/// (Hoot: Dashboard · Runs · Budget). Budget opens from its Dashboard card as a sheet (the
/// switch holds five tabs at most; Memory took the fifth, 11 Oct). The gear opens the Agent settings window.
/// "new" is the create page (AGTNewAgentView); every other setting is changed in the settings window.
struct AGTProfileView: View {
    let agentID: String
    var fixtureModel: AGOPTProfileModel?
    var fixtureActions: AgentMenu.Actions?
    var initialTab: String
    @State private var selectedTab: String
    @State private var connectedModel: AGOPTProfileModel?
    @State private var showingBudget = false

    init(agentID: String, fixtureModel: AGOPTProfileModel? = nil, fixtureActions: AgentMenu.Actions? = nil,
         initialTab: String = "dashboard") {
        self.agentID = agentID; self.fixtureModel = fixtureModel; self.fixtureActions = fixtureActions
        self.initialTab = initialTab
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        if agentID == "new" { AGTNewAgentView() } else { profile }
    }

    private var model: AGOPTProfileModel { fixtureModel ?? .owner(agentID) }
    private var agent: AGTAgent? { model.agent }
    private var isHoot: Bool { agentID == AGTDirectory.hootID || agent?.isHoot == true }
    private var actions: AgentMenu.Actions {
        if let fixtureActions { return fixtureActions }
        if model.isFixture { return .init(name: model.draft.name) }
        var value = agent.map { AgentMenu.actions(for: $0) } ?? .init(name: model.draft.name)
        // Wake, Stop and Reset sessions go through the task engine's own agent actions.
        // The engine asks the owner once through the approval path (agopt:profile-action).
        if !isHoot, agent?.kind == .profile {
            let paused = value.paused, pause = value.perform[.pause]
            if value.perform[.wake] != nil {
                value.perform[.wake] = { if paused { pause?() } else { Task { await model.perform("wake") } } }
            }
            value.reasons[.stop] = nil
            value.perform[.stop] = { Task { await model.perform("stop_all") } }
            value.reasons[.reset] = nil
            value.perform[.reset] = { Task { await model.perform("reset_sessions") } }
        }
        return value
    }
    private var tabs: [DeckSwitchItem<String>] {
        if isHoot { return [.init(id: "dashboard", title: "Dashboard"), .init(id: "runs", title: "Runs"), .init(id: "budget", title: "Budget")] }
        return [.init(id: "dashboard", title: "Dashboard"), .init(id: "memory", title: "Memory"), .init(id: "instructions", title: "Instructions"),
                .init(id: "skills", title: "Skills"), .init(id: "runs", title: "Runs")]
    }
    private var title: String {
        model.draft.name.isEmpty ? agent?.name ?? (isHoot ? "Hoot" : "Agent") : model.draft.name
    }
    private var subtitle: String {
        let project = isHoot ? "Every project" : model.snapshot["project"]["name"].string ?? AGTLeads.projectName(agent)
        let role = Self.roleLine(model.draft.role.isEmpty ? agent?.role ?? "" : model.draft.role)
        return project + (role.isEmpty ? "" : " · " + role)
    }
    /// The role's first written line; a role of only blank lines has none (and never crashes the page).
    static func roleLine(_ role: String) -> String {
        role.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    private var profile: some View {
        DeckPage(title: title, subtitle: subtitle, scrolls: selectedTab == "dashboard" || selectedTab == "skills") {
            lead
        } switcher: {
            GlassSwitch(selection: $selectedTab, items: tabs)
        } actions: {
            headerActions
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if let problem = model.problem {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(DeckTokens.warn)
                        Text(problem).font(.callout).lineLimit(2)
                        Spacer()
                        if model.settingsChangedElsewhere {
                            Button("Discard and reload") { Task { await model.discardAndReload() } }
                        } else { DeckRetryButton { Task { await model.reload() } } }
                    }.controlSize(.small)
                }
                if let notice = model.notice, model.problem == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(notice).font(.callout).lineLimit(2)
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
                    }.controlSize(.small)
                }
                if agent == nil && !model.isFixture && AGTAgentsStore.shared.tasksState != nil {
                    missing
                } else if !model.loaded && model.problem == nil { skeleton }
                else { content }
            }
            .padding(.top, selectedTab == "dashboard" || selectedTab == "skills" ? 0 : DeckTokens.Metrics.pageTop)
            .padding(.bottom, selectedTab == "dashboard" || selectedTab == "skills" ? 0 : 16)
            .frame(minHeight: 0, maxHeight: selectedTab == "dashboard" || selectedTab == "skills" ? nil : .infinity, alignment: .top)
        }
        .sheet(isPresented: $showingBudget) { budgetSheet }
        .task(id: agentID) {
            if !tabs.contains(where: { $0.id == selectedTab }) {
                // An older link to the Budget tab opens the Dashboard with the budget form on top.
                if selectedTab == "budget" { showingBudget = true }
                selectedTab = "dashboard"
            }
            let owner = model
            if connectedModel !== owner {
                connectedModel?.release(); connectedModel = owner
                await owner.acquire()
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == "instructions" { Task { await model.loadInstructions() } }
        }
        .onDisappear { connectedModel?.release(); connectedModel = nil }
    }

    private var lead: some View {
        HStack(spacing: 10) {
            Button { if !model.isFixture { AGTAgentsStore.shared.openProfile = nil } } label: {
                HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("Agents") }
                    .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Back to Agents").keyboardShortcut("[", modifiers: .command)
            if let agent { AgentAvatar(agent: agent, size: 38) }
            else if isHoot { AgentAvatar(icon: .symbol("bird"), size: 38, hoot: true) }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                guard !model.isFixture else { return }
                if isHoot { HootProfileRoute.open(tab: "brain") } else { AGTAgentSettingsWindow.open(agentID) }
            } label: { Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.borderless).help(isHoot ? "Hoot settings" : "Agent settings").accessibilityLabel("Agent settings")
            AgentMenuButton(actions: actions)
            Button { actions.perform[.assign]?() } label: { Label("Assign task", systemImage: "text.badge.plus") }
                .buttonStyle(.borderedProminent)
                .disabled(actions.perform[.assign] == nil || actions.busy)
                .help(actions.reasons[.assign] ?? "Open a new task with this agent already chosen")
        }
        .contextMenu { AgentMenu(actions: actions) }
    }

    @ViewBuilder private var content: some View {
        switch selectedTab {
        case "memory":
            if let agent { AGTMemoryTab(agent: agent) }
            else { DeckEmpty(title: "No memory yet", message: "Save this agent first.", symbol: "tray") }
        case "instructions": AGTProfileInstructions(model: model)
        case "skills": AGTProfileSkills(model: model, giveSkills: { navigate(.skills) }, showSkill: { showSkill($0) })
        case "runs": AGTProfileRuns(model: model, openRun: { openRun($0) }, showChange: { model.showChange(ofRun: $0) })
        case "budget":
            AGTProfileBudget(value: model.budget, isAPI: model.isAPI, monthlyLimit: model.monthlyLimit,
                warningPercent: model.warningPercent, exhaustionAction: model.exhaustionAction, perTaskTokens: model.perTaskTokens,
                busy: model.busy, changed: { model.changed() })
        default:
            AGTProfileDashboard(model: model, actions: actions,
                selectTab: { if $0 == "budget", !isHoot { showingBudget = true } else { selectedTab = $0 } },
                openTask: { openTask($0) }, showTasks: { navigate(.tasks) },
                showTeam: { navigate(.org) }, showRoutines: { navigate(.routines) },
                openRun: { openRun($0) }, showChange: { model.showChange(ofRun: $0) })
        }
    }

    private var budgetSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Budget").font(.headline)
                Spacer()
                Button("Done") { showingBudget = false }.keyboardShortcut(.defaultAction)
            }.padding(16)
            Divider()
            ScrollView {
                AGTProfileBudget(value: model.budget, isAPI: model.isAPI, monthlyLimit: model.monthlyLimit,
                    warningPercent: model.warningPercent, exhaustionAction: model.exhaustionAction, perTaskTokens: model.perTaskTokens,
                    busy: model.busy, changed: { model.changed() })
                    .padding(20)
            }
        }
        .frame(width: 620, height: 520)
    }

    private enum Destination { case tasks, org, routines, skills }
    private func navigate(_ destination: Destination) {
        guard !model.isFixture else { return }
        switch destination {
        case .tasks: AGTAgentsStore.shared.openProfile = nil; AppModel.shared.select("tasks")
        case .org: AGTAgentsStore.shared.openProfile = nil; AppModel.shared.select(NativeINT2Navigation.orgID)
        case .routines: AGTAgentsStore.shared.openProfile = nil; AppModel.shared.select(NativeINT2Navigation.routinesID)
        case .skills: AGTAgentsStore.shared.openProfile = nil; AppModel.shared.select(NativeINT2Navigation.skillsID)
        }
    }
    /// "Show the skill": the Skills page opens on that skill, not on the whole list.
    private func showSkill(_ id: String) {
        guard !model.isFixture else { return }
        navigate(.skills)
        Task { await ROUTINESSkillsStore.shared.open(id: id) }
    }
    private func openTask(_ id: String) {
        guard !model.isFixture else { return }
        TasksStore.shared.openTask(id); AppModel.shared.select("tasks")
    }
    private func openRun(_ id: String) {
        guard !model.isFixture else { return }
        let row = model.runs.first { $0["id"].string == id }
        if let task = row?["taskID"].string { openTask(task) }
        else if let session = row?["sessionID"].string,
                let conversation = AGTTeamChatHistory.shared.sessions(of: agentID).first(where: { $0["session"]["id"].string == session }) {
            AGTTeamChatHistory.shared.openedByAgent[agentID] = conversation
            selectedTab = "dashboard"
        } else { actions.perform[.watch]?() }
    }

    private var missing: some View {
        DeckEmpty(title: "Can't find \(agentID)", message: "It was moved or deleted.", symbol: "questionmark.folder",
                  actionLabel: "Back to all agents") { AGTAgentsStore.shared.openProfile = nil }
    }

    private var skeleton: some View {
        VStack(spacing: 12) {
            AGOPTCard { Rectangle().fill(DeckTokens.selection).frame(height: 40) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in AGOPTCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Rectangle().fill(DeckTokens.selection).frame(width: 80, height: 24)
                        Rectangle().fill(DeckTokens.selection).frame(height: 18)
                        Rectangle().fill(DeckTokens.selection).frame(height: 28)
                    }
                } }
            }
        }.redacted(reason: .placeholder).accessibilityLabel("Reading the agent profile")
    }
}
