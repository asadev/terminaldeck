import SwiftUI
import TerminalDeckNativeCore

struct AGFRAMEAgentsPage: View {
    enum Mode: String, CaseIterable {
        case all, org, work, routines, skills
        var title: String {
            switch self { case .all: "All agents"; case .org: "Org chart"; case .work: "At work"; case .routines: "Routines"; case .skills: "Skills" }
        }
        var sidebarID: String {
            switch self {
            case .all: "agents-all"
            case .org: "agents-org"
            case .work: "agents-watch"
            case .routines: "agents-routines"
            case .skills: "agents-skills"
            }
        }
    }
    @Environment(\.pageWindow) private var pageWindow
    let mode: Mode?
    var live = true
    @AppStorage("AGFRAME.view") private var rememberedMode = "all"
    @AppStorage("AGFRAME.project") private var rememberedProject = ""
    @State private var fixtureMode = "all"
    @State private var fixtureProject = ""
    @State private var focusSearch = false
    @State private var importPresented = false
    @State private var importModel: AGFRAMEImportModel?
    @State private var toast: String?
    @State private var firstImportedProject: String?
    @State private var workModel: AWAgentsWatchModel
    @State private var fixtureRoutines: ROUTINESPageModel
    @State private var fixtureSkills: ROUTINESSkillsStore
    /// `workModel` is for offscreen fixtures only; the live page makes its own.
    init(mode: Mode? = nil, live: Bool = true, workModel: AWAgentsWatchModel? = nil) {
        self.mode = mode; self.live = live
        _fixtureMode = State(initialValue: mode?.rawValue ?? "all")
        let work = workModel ?? (live ? NativePageWindows.agentWork : AWAgentsWatchModel(sourceEvents: [], read: { _, _ in
            throw NativeRPCError.invalidArguments("Fixture reads are disabled.")
        }))
        _workModel = State(initialValue: work)
        let routines = ROUTINESPageModel(); routines.fixture = true; routines.loading = false
        let skills = ROUTINESSkillsStore(); skills.fixture = true; skills.loading = false; skills.catalogueLoading = false
        _fixtureRoutines = State(initialValue: routines); _fixtureSkills = State(initialValue: skills)
    }
    private var store: AGTAgentsStore { .shared }
    private var selected: Mode { Mode(rawValue: live ? rememberedMode : fixtureMode) ?? .all }
    private var project: String? {
        let value = live ? rememberedProject : fixtureProject
        return value.isEmpty ? nil : value
    }
    private var viewBinding: Binding<String> {
        .init(get: { selected.rawValue }, set: { raw in
            guard Mode(rawValue: raw) != nil else { return }
            if live { rememberedMode = raw } else { fixtureMode = raw }
            store.openProfile = nil; toast = nil
        })
    }
    private var projectOptionalBinding: Binding<String?> {
        .init(get: { project }, set: { projectBinding.wrappedValue = $0 ?? "" })
    }
    private var projectBinding: Binding<String> {
        .init(get: { project ?? "" }, set: { raw in
            if live { rememberedProject = raw } else { fixtureProject = raw }
            firstImportedProject = nil
        })
    }
    var body: some View {
        Group {
            if let id = store.openProfile {
                // A session (a lead is usually one) has no agent profile: its tier and memory page.
                if let session = AGTLeads.orgAgents(store.agents).first(where: { $0.id == id && $0.kind == .session }) {
                    AGTLeadProfileView(agent: session)
                } else {
                    // AGOPT owns its detail frame, tabs and settings window.
                    AGTProfileView(agentID: id)
                }
            } else {
                ScrollViewReader { proxy in
                DeckPage(title: "Agents", subtitle: subtitle, scrolls: selected != .org && selected != .work,
                         project: projectOptionalBinding, projects: NativePROJLabels.shared.projects,
                         openProject: { if live { AppModel.shared.openProject() } },
                         switcher: {
                             GlassSwitch(selection: viewBinding,
                                         items: Mode.allCases.map { DeckSwitchItem(id: $0.rawValue, title: $0.title) })
                                 .accessibilityLabel("Agents view")
                                 .nativePageDrag(ScreenRef(kind: .panel, id: "agents-all"), title: "Agents")
                         },
                         actions: { HStack(spacing: 8) { actions; NativePagePopoutButton(ref: ScreenRef(kind: .panel, id: "agents-all"), enabled: live) } },
                         content: {
                    VStack(alignment: .leading, spacing: 12) {
                        if let message = store.message { AGTMessageLine(text: message) }
                        if let toast {
                            HStack { Image(systemName: "checkmark.circle").foregroundStyle(.green); Text(toast); Spacer(); Button("Dismiss") { self.toast = nil } }
                                .font(.callout)
                        }
                        content
                    }
                    .frame(maxWidth: .infinity, maxHeight: selected == .org || selected == .work ? .infinity : nil, alignment: .topLeading)
                })
                .background { keyboardActions }
                .onChange(of: firstImportedProject) { _, value in
                    if let value { Task { @MainActor in await Task.yield(); proxy.scrollTo(value, anchor: .top) } }
                }
                }
            }
        }
        .onAppear {
            fixtureMode = mode?.rawValue ?? "all"
            if live {
                if let mode, pageWindow == nil { rememberedMode = mode.rawValue }
                store.start(); NativePROJLabels.shared.start()
            }
            workModel.selectedProjectID = project
        }
        .onChange(of: mode) { _, next in if let next { viewBinding.wrappedValue = next.rawValue } }
        .onChange(of: live ? EngineBridge.shared.isReady : false) { _, ready in
            if live && ready { NativePROJLabels.shared.start(); store.start() }
        }
        .onChange(of: project) { _, next in workModel.selectedProjectID = next }
        // Hoot's profile is on the Hoot page; any older path that asks for it goes there.
        .onChange(of: store.openProfile) { _, id in
            if id == AGTDirectory.hootID { store.openProfile = nil; if live { HootProfileRoute.open() } }
        }
        .sheet(item: Binding(get: { AGTHandsStore.shared.adding }, set: { AGTHandsStore.shared.adding = $0 })) { agent in
            AGTAddHandSheet(agent: agent)
        }
        .sheet(isPresented: $importPresented) {
            if let importModel {
                AGFRAMEImportSheet(model: importModel) { message, projectID in
                    toast = message; firstImportedProject = projectID
                }
            }
        }
    }
    @ViewBuilder private var content: some View {
        if selected == .all {
            AGFRAMEAllAgentsContent(projectID: project, live: live, onImport: presentImport, onWatch: watch, focusSearch: $focusSearch)
        } else if selected == .org {
            AGTOrgChartView(projectID: project)
        } else if selected == .work {
            AWAgentsWatchScreen(embedded: true, projectID: project, model: workModel, live: live)
        } else if selected == .routines {
            AGTRoutinesView(projectID: project, model: live ? .shared : fixtureRoutines, live: live)
        } else {
            AGTSkillsView(projectID: project, model: live ? .shared : fixtureSkills)
        }
    }
    private var subtitle: String {
        switch selected {
        case .all:
            let agents = store.scopedAgents(projectID: project)
            return "\(agents.count) agents · \(agents.filter { !$0.isHoot && $0.live == .working }.count) working · \(agents.filter { $0.live == .waiting }.count) waiting for you"
        case .org: return "Drag a card onto its new manager"
        case .work: return workModel.subtitle
        case .routines: return live ? AGTRoutinesView.subtitle(projectID: project) : "No routines yet"
        case .skills:
            let model = live ? ROUTINESSkillsStore.shared : fixtureSkills
            let count = ROUTINESSkillsRules.filtered(model.installed, projectID: project, query: "", category: "All").count
            return "\(count) skills installed · \(model.available(projectID: project).count) more to get"
        }
    }
    @ViewBuilder private var actions: some View {
        switch selected {
        case .all:
            if store.liveLoaded && store.scopedAgents(projectID: project).isEmpty {
                newAgentButton.buttonStyle(.bordered)
            } else { newAgentButton.buttonStyle(.borderedProminent) }
        case .org:
            newAgentButton.buttonStyle(.borderedProminent)
        case .work:
            AWAtWorkHeaderActions(model: workModel).disabled(!live)
        case .routines, .skills:
            Button(selected == .routines ? "New routine" : "New skill") {
                NotificationCenter.default.post(name: .init(selected == .routines ? "ROUTINES.newRoutine" : "ROUTINES.newSkill"), object: nil)
            }.buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut("n", modifiers: .command)
        }
    }
    private var keyboardActions: some View {
        VStack {
            ForEach(Array(Mode.allCases.enumerated()), id: \.element.rawValue) { index, mode in
                Button(mode.title) { viewBinding.wrappedValue = mode.rawValue }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("Find an agent") {
                if selected == .all { focusSearch = true }
                else { NotificationCenter.default.post(name: .init("AGFRAME.focusSearch"), object: selected.rawValue) }
            }.keyboardShortcut("f", modifiers: .command)
        }.hidden().accessibilityHidden(true)
    }
    private var newAgentButton: some View {
        Button { store.openProfile = "new" } label: { Label("New agent", systemImage: "plus") }
            .controlSize(.small).keyboardShortcut("n", modifiers: .command)
    }
    private func presentImport() {
        // #117: one project per folder, only the checked files (tasks:agents-scan + batched tasks:agents-import).
        importModel = AGFRAMEImportModel(live: live)
        importPresented = true
    }
    private func watch(_ agent: AGTAgent) {
        viewBinding.wrappedValue = Mode.work.rawValue
        workModel.search = ""; workModel.stateFilter = nil; workModel.source = .all
        workModel.select(agent.liveIDs.first)
        workModel.inspectorPresented = true
    }
}
