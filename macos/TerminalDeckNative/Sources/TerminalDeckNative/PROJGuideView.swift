import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The New project guide's own pop-up window (one per project; one for a new project).
@MainActor
enum PROJGuideWindow {
    private static var windows: [String: (NSWindow, PROJGuideModel)] = [:]

    /// A new project from nothing.
    static func open() { show(key: "new", make: { PROJGuideModel() }) }
    /// A new project from an open folder (a plain session folder).
    static func open(folder: String) {
        show(key: "folder:" + PROJProjects.normalize(folder), make: { PROJGuideModel(folder: folder) })
    }
    /// An existing project, at one page (the setup card's buttons), or the first missing one.
    static func open(project: PROJProject, step: PROJGuideStep? = nil) {
        show(key: "project:" + project.id, step: step, make: { PROJGuideModel(mode: .edit(project.id), step: step ?? .name) })
    }

    private static func show(key: String, step: PROJGuideStep? = nil, make: @escaping () -> PROJGuideModel) {
        NativeFront.whenPersonActs("project-guide-" + key) {
            if let open = windows[key] {
                if let step { open.1.go(step) }
                open.0.makeKeyAndOrderFront(nil); return
            }
            let model = make()
            let host = NSHostingController(rootView: PROJGuideView(model: model, close: { close(key) }))
            let window = NSPanel(contentViewController: host)
            window.title = model.creating ? "New project" : "Set up " + model.name
            window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 780, height: 640))
            window.contentMinSize = NSSize(width: 640, height: 520)
            window.isReleasedWhenClosed = false
            window.center()
            windows[key] = (window, model)
            closing[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { forget(key) }
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
    static func close(_ key: String) { windows[key]?.0.close(); forget(key) }
    /// U143 (#626): a closed guide window takes its close listener with it.
    private static var closing: [String: any NSObjectProtocol] = [:]
    private static func forget(_ key: String) {
        windows[key] = nil
        if let token = closing.removeValue(forKey: key) { NotificationCenter.default.removeObserver(token) }
    }
}

/// One page per step, a step bar, Back / Skip / Next. Only the name and the home folder are required.
struct PROJGuideView: View {
    @State var model: PROJGuideModel
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            PROJGuideStepBar(model: model).padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DeckTokens.Spacing.s16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: model.step.symbol).foregroundStyle(.secondary)
                            Text(model.step.heading).font(DeckTokens.Typography.title)
                            if model.step.required { Text("Required").font(DeckTokens.Typography.caption).foregroundStyle(.secondary) }
                            Spacer(minLength: 8)
                            // Asad, 11 Oct: offered beside doing it yourself. Hoot walks the same steps by chat.
                            if model.step == .name {
                                Button { model.setUpWithHoot(); if !model.fixture { close() } } label: {
                                    Label { Text("Set up with Hoot") } icon: { HootMark(size: 14) }
                                }
                                .help("Hoot asks what it needs and sets the project up by chat")
                            }
                        }
                        Text(model.step.why).font(DeckTokens.Typography.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    page
                }
                .padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider()
            footer.padding(.horizontal, 20).frame(height: 56)
        }
        .background(DeckTokens.page)
        .font(DeckTokens.Typography.body)
        .task { await model.load() }
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .name: PROJGuideNamePage(model: model)
        case .folders: PROJGuideFoldersPage(model: model)
        case .lead: PROJGuideLeadPage(model: model)
        case .team: PROJGuideTeamPage(model: model)
        case .skills: PROJGuideSkillsPage(model: model)
        case .card: PROJGuideCardPage(model: model)
        case .connections: PROJGuideConnectionsPage(model: model)
        case .review: PROJGuideReviewPage(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(DeckTokens.warn).lineLimit(2)
            } else if model.busy {
                ProgressView().controlSize(.small)
                Text(model.creating ? "Creating…" : "Saving…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Back") { model.back() }.disabled(model.step == .name || model.busy)
            if !model.step.required, model.step != .review {
                Button("Skip") { model.skip() }.disabled(model.busy)
            }
            if model.step == .review {
                Button(model.creating ? "Create project" : "Save") { finish() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
            } else {
                Button("Next") { model.next() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
    }

    private func finish() {
        Task {
            guard let id = await model.apply() else { return }
            guard model.notes.isEmpty, !model.fixture else { return }   // anything that did not work stays on show
            if let home = model.home { AppModel.shared.select("project:" + home) }
            NSLog("[project guide] %@ saved", id)
            close()
        }
    }
}

/// The numbered steps; each is clickable. Done steps show a tick, skipped ones a dash.
struct PROJGuideStepBar: View {
    @Bindable var model: PROJGuideModel
    var body: some View {
        HStack(spacing: 0) {
            ForEach(PROJGuideStep.allCases) { step in
                Button { model.go(step) } label: { item(step) }
                    .buttonStyle(.plain)
                    .help(step.heading)
                    .accessibilityLabel(step.heading + (model.step == step ? ", current step" : ""))
                if step != .review {
                    Rectangle().fill(DeckTokens.hairline).frame(height: 1).frame(maxWidth: .infinity).padding(.bottom, 16)
                }
            }
        }
    }
    private func item(_ step: PROJGuideStep) -> some View {
        let current = model.step == step
        let done = model.visited.contains(step) && model.isSet(step) && !current
        let skipped = model.skipped.contains(step) && !current
        return VStack(spacing: 4) {
            ZStack {
                Circle().fill(current ? Color.accentColor : done ? Color.accentColor.opacity(0.14) : DeckTokens.card)
                Circle().strokeBorder(current ? Color.clear : DeckTokens.hairline, lineWidth: 1)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.accentColor) }
                else if skipped { Image(systemName: "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                else { Text("\(step.number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(current ? Color.white : Color.secondary) }
            }
            .frame(width: 22, height: 22)
            Text(step.title).font(DeckTokens.Typography.caption).foregroundStyle(current ? Color.primary : Color.secondary).lineLimit(1).fixedSize()
        }
        .frame(minWidth: 56)
        .contentShape(.rect)
    }
}

/// A label column beside its control, as the New agent page lays them out.
private struct PROJGuideRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(DeckTokens.Typography.rowTitle).frame(width: 130, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: 1 Name and look

struct PROJGuideNamePage: View {
    @Bindable var model: PROJGuideModel
    @State private var dropping = false
    @State private var suggestions: [URL] = []
    var body: some View {
        DeckCard {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 8) {
                    Button(action: chooseLogo) { logo }.buttonStyle(.plain).help("Choose a logo").accessibilityLabel("Logo")
                        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                guard let url else { return }
                                Task { @MainActor in model.logoFile = url; model.removeLogo = false }
                            }
                            return true
                        }
                    if model.logoFile != nil || (!model.existingLogo.isEmpty && !model.removeLogo) {
                        Button("Remove") { model.logoFile = nil; model.removeLogo = true }.buttonStyle(.link).font(DeckTokens.Typography.caption)
                    } else {
                        Button("Choose…", action: chooseLogo).buttonStyle(.link).font(DeckTokens.Typography.caption)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    PROJGuideRow(label: "Name") {
                        TextField("Name", text: $model.name).textFieldStyle(.roundedBorder).labelsHidden()
                    }
                    PROJGuideRow(label: "What it is") {
                        TextField("One line on what the project is", text: $model.about).textFieldStyle(.roundedBorder).labelsHidden()
                    }
                    PROJGuideRow(label: "Colour") {
                        HStack(spacing: 8) {
                            ForEach(PROJProjects.colours, id: \.self) { name in
                                Button { model.colour = name } label: {
                                    Circle().fill(DeckTokens.projectColour(PROJProject(id: "x", name: "", colour: name)))
                                        .frame(width: 18, height: 18)
                                        .overlay { if model.colour == name { Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 2).padding(-3) } }
                                        .contentShape(Circle())
                                }.buttonStyle(.plain).help(name.capitalized).accessibilityLabel(name.capitalized)
                            }
                        }
                    }
                    if !suggestions.isEmpty {
                        PROJGuideRow(label: "Found in the folder") {
                            HStack(spacing: 6) {
                                ForEach(suggestions, id: \.self) { url in
                                    Button { model.logoFile = url; model.removeLogo = false } label: {
                                        Group {
                                            if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                                            else { Image(systemName: "photo") }
                                        }
                                        .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).contentShape(.rect)
                                    }.buttonStyle(.plain).help(url.lastPathComponent).accessibilityLabel("Use " + url.lastPathComponent)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: model.home) {
            guard !model.fixture, let folder = model.home else { suggestions = []; return }
            suggestions = await Task.detached(priority: .utility) { ProjectLogos.suggestions(folder: folder) }.value
        }
    }
    @ViewBuilder private var logo: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if let file = model.logoFile, let image = NSImage(contentsOf: file) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).clipShape(shape)
            } else if !model.removeLogo, !model.existingLogo.isEmpty,
                      let image = ProjectLogos.image(PROJProject(id: "x", name: model.name, logo: model.existingLogo)) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).clipShape(shape)
            } else {
                shape.fill(Color.primary.opacity(0.08)).overlay {
                    Text(ProjectLogoView.letter(model.name.isEmpty ? "?" : model.name))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(model.colour.isEmpty ? Color.secondary : DeckTokens.projectColour(PROJProject(id: "x", name: "", colour: model.colour)))
                }
            }
        }
        .frame(width: 64, height: 64)
        .overlay { shape.strokeBorder(dropping ? Color.accentColor : DeckTokens.hairline, lineWidth: dropping ? 2 : 1) }
    }
    private func chooseLogo() {
        guard !model.fixture else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .svg, .icns, .ico]
        panel.begin { response in
            MainActor.assumeIsolated { if response == .OK, let url = panel.url { model.logoFile = url; model.removeLogo = false } }
        }
    }
}

// MARK: 2 Folders

struct PROJGuideFoldersPage: View {
    @Bindable var model: PROJGuideModel
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 14) {
                PROJGuideRow(label: "Home folder") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let home = model.home {
                            Label(PROJPAGEStyle.shortPath(home), systemImage: "folder").font(DeckTokens.Typography.mono).lineLimit(1).truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            Button(model.home == nil ? "Choose a folder…" : "Change…") { choose { model.setHome($0) } }
                            Button("New folder…") { makeFolder() }
                        }
                    }
                }
                Divider()
                PROJGuideRow(label: "More folders") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.extraFolders, id: \.self) { folder in
                            HStack(spacing: 8) {
                                Label(PROJPAGEStyle.shortPath(folder), systemImage: "folder").font(DeckTokens.Typography.mono).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { model.extraFolders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this folder").accessibilityLabel("Remove " + folder)
                            }
                        }
                        Button("Add a folder…") {
                            choose { path in
                                let folder = PROJProjects.normalize(path)
                                if folder != model.home, !model.extraFolders.contains(folder) { model.extraFolders.append(folder) }
                            }
                        }
                    }
                }
            }
        }
    }
    private func choose(_ done: @escaping (String) -> Void) {
        guard !model.fixture else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = "Choose"
        panel.begin { response in
            MainActor.assumeIsolated { if response == .OK, let path = panel.url?.path { done(path) } }
        }
    }
    /// A new, empty folder for the project, named after it.
    private func makeFolder() {
        guard !model.fixture else { return }
        let panel = NSSavePanel(); panel.canCreateDirectories = true; panel.prompt = "Create"
        panel.nameFieldLabel = "Folder name"; panel.nameFieldStringValue = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    model.setHome(url.path)
                } catch { model.problem = "The folder could not be made: " + error.localizedDescription }
            }
        }
    }
}

// MARK: 3 Lead

struct PROJGuideLeadPage: View {
    @Bindable var model: PROJGuideModel
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Metrics.cardGap) {
            if !model.currentLead.isEmpty {
                choice(.keep, "Keep " + (model.currentLeadName.isEmpty ? model.currentLead : model.currentLeadName), "person.crop.circle.badge.checkmark")
            }
            choice(.hire, "Hire a new lead", "person.crop.circle.badge.plus") {
                PROJGuideNewAgentForm(agent: $model.leadHire, fixture: model.fixture)
            }
            if let first = model.eligibleAgents.first {
                choice(existingSelected ? model.lead : .existing(first.id), "Choose an existing agent", "person.2") {
                    Picker("Agent", selection: Binding(get: { if case .existing(let id) = model.lead { return id } else { return "" } },
                                                       set: { model.lead = .existing($0) })) {
                        ForEach(model.eligibleAgents) { DeckRowLabel.agent(id: $0.id, name: $0.name, icon: $0.icon).tag($0.id) }
                    }.labelsHidden().fixedSize()
                }
            }
            choice(.hoot, "Hoot leads for now", "bird")
        }
    }
    private var existingSelected: Bool { if case .existing = model.lead { return true } else { return false } }
    private func isOn(_ choice: PROJGuideModel.LeadChoice) -> Bool {
        if case .existing = choice { return existingSelected }
        return model.lead == choice
    }
    private func choice(_ value: PROJGuideModel.LeadChoice, _ title: String, _ symbol: String) -> some View {
        choice(value, title, symbol) { EmptyView() }
    }
    private func choice<Extra: View>(_ value: PROJGuideModel.LeadChoice, _ title: String, _ symbol: String, @ViewBuilder extra: () -> Extra) -> some View {
        let on = isOn(value)
        return VStack(alignment: .leading, spacing: 12) {
            Button { model.lead = value } label: {
                HStack(spacing: 10) {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Color.accentColor : Color.secondary)
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                    Text(title).font(DeckTokens.Typography.rowTitle)
                    Spacer(minLength: 0)
                }.contentShape(.rect)
            }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            if on { extra().padding(.leading, 52) }
        }
        .padding(DeckTokens.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Color.accentColor.opacity(0.08) : DeckTokens.card, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: DeckTokens.Metrics.cardRadius).strokeBorder(on ? Color.accentColor.opacity(0.5) : DeckTokens.hairline, lineWidth: 1) }
    }
}

/// The New agent form's essential pieces: picture, name, coding agent (all three offered) and what it does.
struct PROJGuideNewAgentForm: View {
    @Binding var agent: PROJGuideModel.NewAgent
    var fixture = false
    var compact = false
    @State private var picking = false
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { picking = true } label: { AgentAvatar(icon: agent.icon ?? .symbol("person.crop.circle"), size: compact ? 28 : 40) }
                .buttonStyle(.plain).help("Choose a picture").accessibilityLabel("Picture")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    AGTIconPicker(current: agent.icon ?? .symbol("person.crop.circle")) { agent.icon = $0; picking = false }
                }
            TextField("Agent name", text: $agent.name).textFieldStyle(.roundedBorder).frame(maxWidth: compact ? 160 : 200)
            Picker("Coding agent", selection: $agent.provider) {
                Text("App default").tag("")
                ForEach(TasksSettingsText.lookupAgents, id: \.id) { DeckRowLabel.provider($0.label, id: $0.id).tag($0.id) }
            }.labelsHidden().fixedSize()
            if !compact {
                TextField("What it does", text: $agent.role).textFieldStyle(.roundedBorder)
            }
        }
    }
}

// MARK: 4 Team

struct PROJGuideTeamPage: View {
    @Bindable var model: PROJGuideModel
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Metrics.cardGap) {
            DeckCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Roles").font(DeckTokens.Typography.section)
                    ForEach(model.existingTeam) { agent in
                        HStack(spacing: 10) {
                            AgentAvatar(id: agent.id, iconRaw: agent.icon, size: 26)
                            Text(agent.name).font(DeckTokens.Typography.rowTitle)
                            Text(AGTSeatsStore.shared.title(for: AGTSeats.roleSeat(agentID: agent.id, seat: agent.seat, projectID: agent.projectID)) ?? AGTSeats.title(forRole: agent.seat ?? agent.id))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    ForEach($model.seats) { $seat in
                        HStack(spacing: 10) {
                            TextField("Role, like iOS engineer", text: $seat.title).textFieldStyle(.roundedBorder).frame(width: 190)
                            Picker("Agent", selection: Binding(get: { seat.existing ?? "" }, set: { seat.existing = $0.isEmpty ? nil : $0 })) {
                                Label("New agent", systemImage: "plus").tag("")
                                ForEach(available(for: seat)) { DeckRowLabel.agent(id: $0.id, name: $0.name, icon: $0.icon).tag($0.id) }
                            }.labelsHidden().fixedSize()
                            if seat.existing == nil { PROJGuideNewAgentForm(agent: $seat.agent, fixture: model.fixture, compact: true) }
                            Spacer(minLength: 0)
                            Button { model.seats.removeAll { $0.id == seat.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this role").accessibilityLabel("Remove role")
                        }
                    }
                    Button { model.seats.append(.init()) } label: { Label("Add a role", systemImage: "plus") }
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Agent files in the folder").font(DeckTokens.Typography.section)
                        Spacer()
                        if model.scanning { ProgressView().controlSize(.small) }
                        Button("Look in another folder…") { lookElsewhere() }.disabled(model.scanning)
                    }
                    if model.found.isEmpty {
                        Text(model.scanning ? "Looking…" : "None found in .claude/agents.").foregroundStyle(.secondary)
                    }
                    ForEach($model.found) { $row in
                        Toggle(isOn: $row.selected) {
                            HStack(spacing: 8) {
                                Text(row.name)
                                if row.alreadyImported { Text("Already in the app").font(DeckTokens.Typography.caption).foregroundStyle(.secondary) }
                            }
                        }.toggleStyle(.checkbox).disabled(row.alreadyImported)
                    }
                }
            }
        }
    }
    /// Free agents not already picked for another role or as the lead.
    private func available(for seat: PROJGuideModel.Seat) -> [AgentProfile] {
        let taken = Set(model.seats.filter { $0.id != seat.id }.compactMap(\.existing))
        return model.eligibleAgents.filter { agent in
            !taken.contains(agent.id) && model.lead != .existing(agent.id)
        }
    }
    private func lookElsewhere() {
        guard !model.fixture else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.prompt = "Look here"
        panel.begin { response in
            MainActor.assumeIsolated { if response == .OK, let path = panel.url?.path { Task { await model.scan(folder: path) } } }
        }
    }
}

// MARK: 5 Skills

struct PROJGuideSkillsPage: View {
    @Bindable var model: PROJGuideModel
    var body: some View {
        let agents = model.planAgents
        VStack(alignment: .leading, spacing: DeckTokens.Metrics.cardGap) {
            if agents.isEmpty {
                DeckCard {
                    HStack {
                        Text("Add a lead or a team first.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Go to Team") { model.go(.team) }
                    }
                }
            } else if model.skills.isEmpty {
                DeckCard { Text("No skills found for this project.").foregroundStyle(.secondary) }
            } else {
                DeckCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.skills.enumerated()), id: \.element.id) { index, skill in
                            if index > 0 { Divider().padding(.vertical, 10) }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(skill.name).font(DeckTokens.Typography.rowTitle)
                                    Text(skill.source).font(DeckTokens.Typography.caption).foregroundStyle(.secondary)
                                }
                                if !skill.summary.isEmpty {
                                    Text(skill.summary).font(DeckTokens.Typography.callout).foregroundStyle(.secondary).lineLimit(2)
                                }
                                NativeSkillClashNotice(folder: skill.id, name: skill.name) { name, folder in
                                    if let at = model.skills.firstIndex(where: { $0.id == skill.id }) {
                                        let old = model.skills[at]
                                        model.skills[at] = .init(id: folder, name: name, summary: old.summary, source: old.source, agents: old.agents, original: old.original)
                                    }
                                }
                                PROJGuideChips(agents: agents, selected: Binding(
                                    get: { model.skills.first { $0.id == skill.id }?.agents ?? [] },
                                    set: { value in if let at = model.skills.firstIndex(where: { $0.id == skill.id }) { model.skills[at].agents = value } }))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Agents as toggle chips: picture + name; a chosen one is tinted.
struct PROJGuideChips: View {
    let agents: [PROJGuideModel.PlanAgent]
    @Binding var selected: Set<String>
    var body: some View {
        HStack(spacing: 6) {
            ForEach(agents) { agent in
                let on = selected.contains(agent.key)
                Button {
                    if on { selected.remove(agent.key) } else { selected.insert(agent.key) }
                } label: {
                    HStack(spacing: 5) {
                        Image(nsImage: DeckRowIcon.agent(id: agent.key, icon: agent.icon))
                        Text(agent.name).lineLimit(1)
                        if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                    }
                    .font(DeckTokens.Typography.callout)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(on ? Color.accentColor.opacity(0.14) : DeckTokens.selection, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.chipRadius))
                    .foregroundStyle(on ? Color.accentColor : Color.primary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).help(on ? "Take it away from \(agent.name)" : "Give it to \(agent.name)")
            }
        }
    }
}

// MARK: 6 Card

struct PROJGuideCardPage: View {
    @Bindable var model: PROJGuideModel
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Lead of " + (model.name.isEmpty ? "this project" : model.name)).font(DeckTokens.Typography.section)
                    Spacer()
                    NativeMemoryTemplatesButton(title: "Lead template…", category: .lead)
                }
                TextEditor(text: Binding(get: { model.card }, set: { model.card = $0; model.cardEdited = true }))
                    .font(.system(size: 12.5, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight: 260)
                    .background(DeckTokens.page, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeckTokens.hairline))
            }
        }
    }
}

// MARK: 7 Connections

/// Each connection shows its real state and finishes right here, through the app's own flows: GitHub's sign-in
/// (then this folder's repository, picked or made on GitHub), the connected-task form, and the Add a server sheet.
/// Asad, 11 Oct: "currently its showing missing but not showing a way to complete it". All optional.
struct PROJGuideConnectionsPage: View {
    @Bindable var model: PROJGuideModel
    @State private var addingTaskSystem = false
    /// The person pressed Connect: the next new system is theirs (the sheet may close before the list updates).
    @State private var connectingTaskSystem = false
    @State private var taskSystemsBefore: Set<String> = []
    @State private var addingServer = false
    @State private var serverRoute = NativeServersRoute.add
    private var tasks: ConnectedTasksStore { .shared }
    private var servers: NativeServersModel { .shared }

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 14) {
                PROJGuideRow(label: "GitHub") { github }
                Divider()
                PROJGuideRow(label: "Task source") { taskSource }
                Divider()
                PROJGuideRow(label: "Servers") { serverList }
            }
        }
        .task(id: model.home) { if !model.fixture { model.github.show(model.home) } }
        .onChange(of: model.github.auth?.repo?.ref?.nameWithOwner) { _, found in
            if model.repo.isEmpty, let found { model.repo = found }
        }
        .sheet(isPresented: $addingTaskSystem) {
            ScrollView { ConnectedTaskSystemForm(draft: ConnectedTaskSystemDraft()) { addingTaskSystem = false }.padding(24) }
                .frame(width: 600, height: 520)
        }
        .onChange(of: tasks.systems.map(\.id)) { _, ids in
            // Only a system connected in the sheet becomes this project's task source; the list arriving
            // after the page appeared (it reads "Checking…" first) never picks one by itself.
            if connectingTaskSystem, let added = ids.first(where: { !taskSystemsBefore.contains($0) }) {
                model.taskSystem = added
                connectingTaskSystem = false
            }
            taskSystemsBefore = Set(ids)
        }
        .sheet(isPresented: $addingServer) {
            MACHINESAddServerSheet(model: servers, route: $serverRoute) { addingServer = false }
        }
        .onChange(of: serverRoute) { _, route in
            // The sheet moves to the new server when it was added: back to the guide, with it ticked.
            guard case .server(let id) = route else { return }
            addingServer = false
            if let added = servers.servers.first(where: { $0.id == id }) { model.servers.insert(added.name) }
            serverRoute = .add
        }
        .onAppear { taskSystemsBefore = Set(tasks.systems.map(\.id)) }
    }

    // MARK: GitHub

    @ViewBuilder private var github: some View {
        let auth = model.github.auth
        VStack(alignment: .leading, spacing: 8) {
            if auth == nil && !model.fixture {
                PROJGuideConnectionState(text: "Checking…", tone: .busy)
            } else if let pending = auth?.pending {
                PROJGuideConnectionState(text: "Connecting: enter this code on GitHub", tone: .busy)
                HStack(spacing: 8) {
                    Text(pending.userCode).font(.system(size: 15, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Button(model.github.copied ? "Copied" : "Copy code") { model.github.copyCode(pending.userCode) }
                    Button("Open GitHub") { GitHubScreenModel.openExternally(pending.verificationUri) }
                    Button("Cancel") { model.github.cancelConnect() }
                }
            } else if auth?.connected == true {
                PROJGuideConnectionState(text: "Connected" + (auth?.login.map { " as @" + $0 } ?? ""), tone: .good)
                HStack(spacing: 8) {
                    Picker("Repository", selection: $model.repo) {
                        Text("No repository").tag("")
                        ForEach(repoChoices(auth), id: \.self) { name in
                            Text(name == auth?.repo?.ref?.nameWithOwner ? name + " (this folder)" : name).tag(name)
                        }
                    }.labelsHidden().fixedSize()
                    Button("Create on GitHub…") { createOnGitHub() }
                    Button("Check again") { Task { await model.github.loadAuth() } }
                }
            } else {
                PROJGuideConnectionState(text: auth?.failure?.message ?? "Not connected", tone: .missing)
                HStack(spacing: 8) {
                    Button(model.github.authBusy ? "Connecting…" : "Connect GitHub") { model.github.connect() }.disabled(model.github.authBusy)
                    if !model.repo.isEmpty { Text(model.repo).font(DeckTokens.Typography.mono).foregroundStyle(.secondary) }
                }
            }
        }
    }
    /// This folder's repository first, the one chosen, then what the sign-in can reach.
    private func repoChoices(_ auth: GitHubAuthState?) -> [String] {
        var names: [String] = []
        if let own = auth?.repo?.ref?.nameWithOwner { names.append(own) }
        if !model.repo.isEmpty { names.append(model.repo) }
        if case .list(let list)? = auth?.access { names += list.repos.map(\.nameWithOwner) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
    /// GitHub's own New repository page, named after the project; then "Check again" picks it up.
    private func createOnGitHub() {
        var parts = URLComponents(string: "https://github.com/new")!
        let name = PROJSetup.projectID(for: model.name, taken: [])
        parts.queryItems = [URLQueryItem(name: "name", value: name)] + (model.about.isEmpty ? [] : [URLQueryItem(name: "description", value: model.about)])
        if let url = parts.url { GitHubScreenModel.openExternally(url.absoluteString) }
    }

    // MARK: Task source

    @ViewBuilder private var taskSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tasks.systems.isEmpty {
                PROJGuideConnectionState(text: tasks.loaded || model.fixture ? "Not connected" : "Checking…", tone: tasks.loaded || model.fixture ? .missing : .busy)
            } else {
                let chosen = tasks.systems.first { $0.id == model.taskSystem }
                PROJGuideConnectionState(text: chosen.map { "Connected: " + $0.name } ?? "\(tasks.systems.count) connected, none chosen",
                                         tone: chosen == nil ? .missing : (chosen?.problem == nil ? .good : .missing))
            }
            HStack(spacing: 8) {
                if !tasks.systems.isEmpty {
                    Picker("Task source", selection: $model.taskSystem) {
                        Text("None").tag("")
                        ForEach(tasks.systems) { Text($0.name).tag($0.id) }
                        if !model.taskSystem.isEmpty, !tasks.systems.contains(where: { $0.id == model.taskSystem }) {
                            Text(model.taskSystem).tag(model.taskSystem)
                        }
                    }.labelsHidden().fixedSize()
                }
                Button(tasks.systems.isEmpty ? "Connect a task system…" : "Connect another…") {
                    taskSystemsBefore = Set(tasks.systems.map(\.id)); connectingTaskSystem = true; addingTaskSystem = true
                }
            }
        }
    }

    // MARK: Servers

    @ViewBuilder private var serverList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if servers.servers.isEmpty {
                PROJGuideConnectionState(text: servers.reading && !model.fixture ? "Checking…" : "No servers yet", tone: servers.reading && !model.fixture ? .busy : .missing)
            } else {
                PROJGuideConnectionState(text: model.servers.isEmpty ? "None chosen" : "\(model.servers.count) chosen", tone: model.servers.isEmpty ? .missing : .good)
            }
            ForEach(servers.servers) { server in
                Toggle(isOn: Binding(get: { model.servers.contains(server.name) },
                                     set: { if $0 { model.servers.insert(server.name) } else { model.servers.remove(server.name) } })) {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        Text(server.name)
                        Text(server.address).font(DeckTokens.Typography.caption).foregroundStyle(.secondary)
                        if let link = servers.states[server.id]?.link {
                            Text(link == .ready ? "Connected" : link == .connecting ? "Connecting…" : "Not reachable")
                                .font(DeckTokens.Typography.caption).foregroundStyle(link == .failed ? DeckTokens.warn : Color.secondary)
                        }
                    }
                }.toggleStyle(.checkbox)
            }
            Button("Add a server…") { serverRoute = .add; servers.clearAddError(); addingServer = true }
        }
    }
}

/// A connection's real state: a green dot when connected, a grey one when not, a spinner while it connects.
struct PROJGuideConnectionState: View {
    enum Tone { case good, missing, busy }
    let text: String
    let tone: Tone
    var body: some View {
        HStack(spacing: 6) {
            switch tone {
            case .busy: ProgressView().controlSize(.mini)
            case .good: Circle().fill(DeckTokens.good).frame(width: 7, height: 7)
            case .missing: Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            }
            Text(text).foregroundStyle(tone == .good ? Color.primary : Color.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 8 Review

struct PROJGuideReviewPage: View {
    @Bindable var model: PROJGuideModel
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Metrics.cardGap) {
            DeckCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(PROJGuideStep.allCases.filter { $0 != .review }.enumerated()), id: \.element) { index, step in
                        if index > 0 { Divider().padding(.vertical, 8) }
                        Button { model.go(step) } label: { row(step) }.buttonStyle(.plain).help("Open " + step.heading)
                    }
                }
            }
            let score = model.expectedScore
            HStack(spacing: 10) {
                PROJSetupMeter(percent: score.percent).frame(width: 140)
                Text("Setup \(score.percent)%").font(DeckTokens.Typography.rowTitle).monospacedDigit()
                if !score.missing.isEmpty {
                    Text("Missing: " + score.missing.map(\.title).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if !model.notes.isEmpty {
                DeckCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(model.creating ? "Not done yet" : "Saved, except:", systemImage: "exclamationmark.triangle").foregroundStyle(DeckTokens.warn)
                        ForEach(model.notes, id: \.self) { Text($0).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
            }
        }
    }
    private func row(_ step: PROJGuideStep) -> some View {
        let set = model.isSet(step)
        let missingRequired = step.required && !set
        let skipped = model.skipped.contains(step) || (!set && !step.required)
        return HStack(spacing: 10) {
            Image(systemName: missingRequired ? "exclamationmark.circle.fill" : set ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(missingRequired ? DeckTokens.warn : set ? DeckTokens.good : Color.secondary)
                .frame(width: 18)
            Text(step.heading).font(DeckTokens.Typography.rowTitle).frame(width: 120, alignment: .leading)
            Text(set ? model.summary(step) : missingRequired ? "Required" : skipped ? "Skipped" : "")
                .foregroundStyle(set ? Color.primary : Color.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }.contentShape(.rect)
    }
}
