import SwiftUI
import AppKit
import TerminalDeckNativeCore

// Shared shell pieces (DeckCard, DeckPage, GlassSwitch, ProjectPicker) and the
// AGKIT agent kit.
typealias AGFRAMECard = DeckCard
typealias AGFRAMEProjectChip = ProjectChip
typealias AGFRAMEAvatar = AgentAvatar
typealias AGFRAMEAgentMenu = AgentMenu

@MainActor enum AGFRAMEStyle {
    static func glyphColour(_ icon: AGTIcon) -> Color {
        guard case .symbol(let name) = icon else { return .primary }
        if name.contains("key") { return .orange }
        if name.contains("star") || name.contains("heart") { return .pink }
        if name.contains("location") || name.contains("leaf") { return .green }
        if name.contains("bug") || name.contains("ant") { return .red }
        if name.contains("iphone") || name.contains("ipad") { return .gray }
        if name.contains("wrench") || name.contains("cylinder") || name.contains("server") { return .purple }
        if name.contains("shield") || name.contains("bubble") { return .teal }
        return .blue
    }
    static func projectID(_ agent: AGTAgent) -> String {
        PROJProjects.resolve(projectID: agent.projectID, folder: agent.project, projects: NativePROJLabels.shared.projects)
    }
    static func project(_ agent: AGTAgent) -> PROJProject {
        let id = projectID(agent)
        return NativePROJLabels.shared.projects.first { $0.id == id }
            ?? PROJProject(id: id, name: id, colour: "graphite")
    }
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func statusColour(_ agent: AGTAgent) -> Color {
        if agent.live == .working { return .green }
        if agent.live == .waiting { return .orange }
        if agent.status == "failed" { return .red }
        return .secondary
    }
}

struct AGFRAMEStatus: View {
    let agent: AGTAgent
    var body: some View {
        StatusLabel(state, text: agent.statusLabel, fontSize: 11)
    }
    private var state: StatusLabel.State {
        if agent.status == "paused" { return .paused }
        if agent.status == "failed" { return .failed }
        switch agent.live { case .working?: return .working; case .waiting?: return .waiting; case .idle?: return .idle; default: return .ready }
    }
}

struct AGFRAMEAgentCard: View {
    let agent: AGTAgent
    var onWatch: (AGTAgent) -> Void = { AGTAgentsStore.shared.openSession($0) }
    @State private var hovering = false
    @State private var pendingOpen: Task<Void, Never>?
    @State private var doubleClicking = false
    var body: some View {
        Button {
            guard !doubleClicking else { return }
            pendingOpen?.cancel()
            pendingOpen = Task { @MainActor in
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard !Task.isCancelled else { return }
                AGTAgentsStore.shared.openProfile = agent.id
            }
        } label: {
            AGFRAMECard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        AGFRAMEAvatar(agent: agent, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(agent.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                AGTSeatBadge(agent: agent)
                            }
                            Text(agent.role).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 7) {
                        AGFRAMEStatus(agent: agent)
                        if agent.live == .working || agent.live == .waiting {
                            Text(agent.taskTitle ?? agent.activity).font(.system(size: 12)).lineLimit(1)
                        }
                    }
                    HStack(spacing: 6) {
                        let project = AGFRAMEStyle.project(agent)
                        AGFRAMEProjectChip(project: project, name: project.name)
                        AGTSessionsChip(agent: agent)   // the sessions working as this agent: on its card, not cards of their own
                        Text(agent.model ?? "—").font(.system(size: 11)).foregroundStyle(.secondary)
                            .task(id: AGTAgentsStore.shared.modelRequestID(agent)) { await AGTAgentsStore.shared.resolveInheritedModel(agent) }
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(AGTTime.ago(agent.lastActivity, none: "—")).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(agent.live == .waiting ? Color.orange.opacity(0.4) : Color.primary.opacity(hovering ? 0.14 : 0), lineWidth: 1))
            .offset(y: hovering ? -1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                doubleClicking = true; pendingOpen?.cancel()
                if agent.live == .working || agent.live == .waiting { onWatch(agent) }
                else { AGTAgentsStore.shared.openProfile = agent.id }
                Task { @MainActor in try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)); doubleClicking = false }
            })
            .onDisappear { pendingOpen?.cancel() }
            .contextMenu { AGFRAMEAgentMenu(agent: agent) }
            .accessibilityLabel("\(agent.name), \(AGFRAMEStyle.project(agent).name), \(agent.statusLabel)")
    }
}

struct AGFRAMEAllAgentsContent: View {
    let projectID: String?
    var live = true
    var onImport: () -> Void
    var onWatch: (AGTAgent) -> Void = { AGTAgentsStore.shared.openSession($0) }
    @Binding var focusSearch: Bool
    @AppStorage("AGFRAME.search21") private var search = ""
    @AppStorage("AGFRAME.filter21") private var state: AGFRAMEStateFilter = .all
    @State private var contentWidth: CGFloat = 1100
    @FocusState private var searchFocused: Bool
    private var store: AGTAgentsStore { .shared }
    private var groups: [AGFRAMEAgentGroup] {
        AGFRAMEPresentation.groups(agents: store.agents, projects: NativePROJLabels.shared.projects,
                                   projectID: projectID, search: search, state: state)
    }
    private var scoped: [AGTAgent] {
        store.scopedAgents(projectID: projectID)
    }
    var body: some View {
        @Bindable var bound = AGTAgentsStore.shared
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { searchField; filters; Spacer(minLength: 0); toolbar(bound: bound) }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { searchField; Spacer(minLength: 0); toolbar(bound: bound) }
                    filters
                }
            }
            // A project with no lead whose folder says who its AI is: offer that name as the lead.
            AGTDeclaredLeadOffers(projectID: projectID, live: live)
            if !store.liveLoaded && store.fixture == nil {
                skeleton
            } else if scoped.isEmpty {
                empty(title: "No agents yet", detail: "Import the agents your projects already have, or make a new one.", canImport: true)
            } else if groups.isEmpty {
                empty(title: search.isEmpty ? "No agents in this view" : "No agent matches “\(search)”.", detail: "Try another search or state.", canImport: false)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        if projectID == nil { groupHeader(group) }
                        if store.layout == .cards {
                            let columns = contentWidth >= 1100 ? 4 : contentWidth >= 800 ? 3 : 2
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                                ForEach(group.agents) { AGFRAMEAgentCard(agent: $0, onWatch: onWatch) }
                            }
                        } else {
                            AGFRAMEAgentsTable(agents: group.agents, onWatch: onWatch)
                                .frame(height: min(700, CGFloat(group.agents.count * 46 + 36)))
                        }
                    }.id(group.id)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .onChange(of: focusSearch) { _, value in if value { searchFocused = true; focusSearch = false } }
        .task(id: AGTDeclaredLeadOffers.readKey) { if live { await AGTDeclaredLeadOffers.read() } }
    }
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find an agent, role or model", text: $search).textFieldStyle(.plain).focused($searchFocused)
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(minWidth: 220, idealWidth: 260, maxWidth: 280).frame(height: 30)
            .background(Color.primary.opacity(0.055), in: Capsule())
    }
    private var filters: some View {
        FilterChips(selection: $state, items: AGFRAMEStateFilter.allCases.map { filter in
            let title: String = switch filter { case .all: "All"; case .working: "Working"; case .waiting: "Waiting"; case .paused: "Paused" }
            let count = scoped.filter { filter.includes($0) }.count
            let dot: Color? = filter == .working ? .green : filter == .waiting ? .orange : nil
            return AGKITFilterItem(id: filter, title: title, count: count, dot: dot)
        }).fixedSize()
    }
    private func toolbar(bound: AGTAgentsStore) -> some View {
        HStack(spacing: 8) {
            // The three category templates (L5's one editor; Hoot's profile opens the same sheet).
            NativeMemoryTemplatesButton().buttonStyle(.bordered).controlSize(.small)
            Button(action: onImport) { Label("Import…", systemImage: "square.and.arrow.down") }.buttonStyle(.bordered).controlSize(.small)
            Picker("Layout", selection: Binding(get: { bound.layout }, set: { bound.layout = $0 })) {
                Image(systemName: "square.grid.2x2").tag(AGTAgentsStore.Layout.cards).help("Cards")
                Image(systemName: "list.bullet").tag(AGTAgentsStore.Layout.list).help("List")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 80).help("Cards or list")
        }
    }
    private func groupHeader(_ group: AGFRAMEAgentGroup) -> some View {
        let project = NativePROJLabels.shared.projects.first { $0.id == group.id }
        return HStack(spacing: 8) {
            ProjectLogoView(project: project, name: group.name, size: 14)
            Text(group.name).font(.system(size: 15, weight: .semibold))
            let work = group.agents.filter { $0.live == .working }.count
            let wait = group.agents.filter { $0.live == .waiting }.count
            Text("\(group.agents.count) agents" + (work > 0 ? " · \(work) working" : "") + (wait > 0 ? " · \(wait) waiting" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let source = group.agents.compactMap(\.sourceFile).first {
                let folder = URL(fileURLWithPath: source).deletingLastPathComponent().path
                Text(AGFRAMEStyle.shortPath(folder)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(folder)
            }
            Spacer(minLength: 0)
        }
    }
    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], spacing: 12) {
            ForEach(0..<6) { _ in
                AGFRAMECard {
                    VStack(alignment: .leading, spacing: 12) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)).frame(width: 160, height: 18)
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(height: 14)
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(width: 120, height: 22)
                    }
                }
            }
        }.redacted(reason: .placeholder).accessibilityLabel("Reading agents")
    }
    private func empty(title: String, detail: String, canImport: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            if canImport { Button("Import agents…", action: onImport).buttonStyle(.borderedProminent) }
        }.frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

private struct AGFRAMETableRow: Identifiable {
    let agent: AGTAgent
    let project: String
    @MainActor init(agent: AGTAgent) { self.agent = agent; self.project = AGFRAMEStyle.project(agent).name }
    var id: String { agent.id }
    var name: String { agent.name }
    var state: String { agent.statusLabel }
    var doing: String { agent.taskTitle ?? agent.activity }
    var model: String { agent.model ?? "—" }
    var activity: Double { agent.lastActivity ?? 0 }
}
struct AGFRAMEAgentsTable: View {
    let agents: [AGTAgent]
    var onWatch: (AGTAgent) -> Void = { AGTAgentsStore.shared.openSession($0) }
    @State private var selected: String?
    @State private var pendingOpen: Task<Void, Never>?
    @State private var sorting = [KeyPathComparator(\AGFRAMETableRow.name)]
    var body: some View {
        Table(agents.map { AGFRAMETableRow(agent: $0) }.sorted(using: sorting), selection: $selected, sortOrder: $sorting) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) { AGFRAMEAvatar(agent: row.agent, size: 22); Text(row.name).fontWeight(.semibold) }
            }.width(min: 180, ideal: 220)
            TableColumn("Project", value: \.project) { row in
                AGFRAMEProjectChip(project: AGFRAMEStyle.project(row.agent), name: row.project)
            }.width(min: 95, ideal: 110)
            TableColumn("State", value: \.state) { row in AGFRAMEStatus(agent: row.agent) }.width(min: 90, ideal: 110)
            TableColumn("Doing now", value: \.doing) { Text($0.doing).lineLimit(1) }.width(min: 120, ideal: 240)
            TableColumn("Model", value: \.model) { row in
                Text(row.model).task(id: AGTAgentsStore.shared.modelRequestID(row.agent)) { await AGTAgentsStore.shared.resolveInheritedModel(row.agent) }
            }.width(min: 80, ideal: 100)
            TableColumn("Last active", value: \.activity) { row in Text(AGTTime.ago(row.agent.lastActivity, none: "—")) }.width(min: 75, ideal: 90)
        }.tint(.gray)
            .onChange(of: selected) { _, id in
                pendingOpen?.cancel()
                guard let id else { return }
                pendingOpen = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                    guard !Task.isCancelled else { return }
                    AGTAgentsStore.shared.openProfile = id
                }
            }
            .onDisappear { pendingOpen?.cancel() }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let agent = agents.first(where: { $0.id == id }) { AGFRAMEAgentMenu(agent: agent) }
            } primaryAction: { ids in
                pendingOpen?.cancel()
                if let id = ids.first, let agent = agents.first(where: { $0.id == id }) {
                    if agent.live == .working || agent.live == .waiting { onWatch(agent) }
                    else { AGTAgentsStore.shared.openProfile = id }
                }
            }
    }
}
