import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// New agent: the hire (picture, manager, role, project) and what it needs to exist (name, what it does, its coding AI),
/// saved with AgentForm.payload → tasks:agent-save. U114 (#190): everything else is set in the one editor, its settings
/// window, which opens with its profile after the first save.
struct AGTNewAgentView: View {
    @State private var picking = false
    @State private var draft: AgentDraft = {
        var draft = AgentDraft(nil); draft.provider = AGSCapabilities.providers.first ?? "claude"; return draft
    }()
    @State private var problem: String?
    @State private var pendingIcon: AGTIcon?
    @State private var pendingBoss: String?
    /// The seat it is hired into: an existing role (its key), or "" for a new role.
    @State private var seatKey = ""
    @State private var newRole = ""
    /// For a new role: its project. "" = the project its working folder lies in (Independent when none).
    @State private var projectChoice = ""
    private var store: AGTAgentsStore { .shared }
    private var chosenSeat: AGTSeat? { AGTSeat(key: seatKey) }

    var body: some View {
        DeckPage(title: "New agent", subtitle: "Pick the project and the role. An existing role brings its memory.") {
            NativeSessionButton { store.openProfile = nil } label: {
                HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("Agents") }
                    .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Back to Agents")
        } switcher: {
            EmptyView()
        } actions: {
            EmptyView()
        } content: {
            DeckCard {
                HStack(alignment: .center, spacing: 14) {
                    NativeSessionButton { picking = true } label: { AgentAvatar(icon: pendingIcon ?? .symbol("person.crop.circle"), size: 48) }
                        .buttonStyle(.plain).help("Choose a picture").accessibilityLabel("Picture")
                        .popover(isPresented: $picking, arrowEdge: .bottom) {
                            AGTIconPicker(current: pendingIcon ?? .symbol("person.crop.circle")) { pendingIcon = $0; picking = false }
                        }
                    Text("Reports to").foregroundStyle(.secondary)
                    Picker("Reports to", selection: Binding(get: { pendingBoss ?? "" }, set: { pendingBoss = $0.isEmpty ? nil : $0 })) {
                        DeckRowLabel("No one (independent)", image: DeckRowIcon.independent).tag("")
                        DeckRowLabel("Hoot", image: DeckRowIcon.hoot).tag(AGTDirectory.hootID)
                        ForEach(store.agents.filter { $0.kind == .profile && $0.status != "archived" }) {
                            DeckRowLabel($0.name, image: DeckRowIcon.agent($0)).tag($0.id)
                        }
                    }.labelsHidden().fixedSize()
                    Spacer()
                }
            }
            seatCard
            basicsCard
        }
    }

    /// One labelled line in the page's cards: the name and its help on the left, the control beside it.
    private func line<Control: View>(_ title: String, _ help: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(help).font(.caption).foregroundStyle(.secondary)
            }.frame(width: 210, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    private var basicsCard: some View {
        let unnamed = draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        return DeckCard {
            VStack(alignment: .leading, spacing: 10) {
                line("Name", "What you call it everywhere.") {
                    NativeSessionTextField("Agent name", text: Binding(get: { draft.name }, set: { draft.name = String($0.prefix(60)) }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                }
                line("What it does", "One line about what it does.") {
                    NativeSessionTextField("What it does", text: Binding(get: { draft.role }, set: { draft.role = String($0.prefix(4000)) }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                }
                line("Coding AI", "Claude Code, Codex or Gemini.") {
                    Picker("Coding AI", selection: $draft.provider) {
                        ForEach(AGSCapabilities.providers, id: \.self) { Text(NativeAGSWords.provider($0)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text("Its model, limits, tools and the rest are set in its settings window, which opens once it is added.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem { NativeCodingAINotice(tone: .error, text: problem) }
                HStack(spacing: 8) {
                    NativeSessionButton("Add agent") { Task { await save(draft) } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(store.busy || unnamed)
                        .help(unnamed ? "Give the agent a name first" : "")
                    NativeSessionButton("Cancel") { problem = nil; store.openProfile = nil }
                    Spacer()
                }
            }
        }
    }

    /// Hiring = choosing a seat. No memory setup: a seat that exists already brings its memory.
    private var seatCard: some View {
        let groups = AGTLeads.projects.map { project in
            (project, AGTLeads.seatChoices(projectID: project.id, agents: store.agents).filter { $0.filledBy.isEmpty })
        }.filter { !$0.1.isEmpty }
        return DeckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Role").font(.system(size: 13, weight: .semibold))
                        Text("Memory belongs to the role, not to the agent.").font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 210, alignment: .leading)
                    Picker("Role", selection: $seatKey) {
                        Label("A new role", systemImage: "plus").tag("")
                        if case .lead(let id)? = chosenSeat {
                            DeckRowLabel("Lead of " + NativePROJLabels.shared.name(for: id),
                                         image: DeckRowIcon.project(id: id, in: NativePROJLabels.shared.projects)).tag(seatKey)
                        }
                        ForEach(groups, id: \.0.id) { project, choices in
                            Section(project.name) {
                                ForEach(choices) { DeckRowLabel($0.label, image: $0.image).tag($0.seat.key) }
                            }
                        }
                    }.labelsHidden().fixedSize()
                    if seatKey.isEmpty {
                        NativeSessionTextField("Role name, for example iOS engineer", text: $newRole).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .help("Leave it empty and the role is named after the agent.")
                    }
                    Spacer(minLength: 0)
                }
                if seatKey.isEmpty {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Project").font(.system(size: 13, weight: .semibold))
                            Text("Where the role lives. Its memory is kept with that project.").font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 210, alignment: .leading)
                        Picker("Project", selection: $projectChoice) {
                            DeckRowLabel("From its working folder", image: DeckRowIcon.symbolIcon("folder")).tag("")
                            ForEach(AGTLeads.projects.filter { $0.id != PROJProjects.independentID }) { DeckRowLabel.project($0).tag($0.id) }
                            DeckRowLabel.independent.tag(PROJProjects.independentID)
                        }.labelsHidden().fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                if let seat = chosenSeat {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full").foregroundStyle(.secondary)
                        Text("The new agent joins \(NativePROJLabels.shared.name(for: seat.projectID ?? PROJProjects.independentID)) in this role and inherits its memory"
                             + (AGTSeatsStore.shared.summary(for: seat).map { " (\($0))" } ?? "") + ". The project below follows the role.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            if store.fixture == nil { AGTSeatsStore.shared.start() }
            // "Hire into this seat…" from the org chart arrives with the seat already chosen.
            if let seat = AGTLeads.pendingHire { seatKey = seat.key; AGTLeads.pendingHire = nil }
        }
    }

    private func save(_ submitted: AgentDraft) async {
        var draft = submitted
        draft.icon = pendingIcon?.raw; draft.reportsTo = pendingBoss
        // The seat decides the project: hiring into an existing role puts the agent where the role is.
        let seat = chosenSeat
        if let seat { draft.projectID = seat.projectID ?? PROJProjects.independentID }
        else if !projectChoice.isEmpty { draft.projectID = projectChoice }
        switch AgentForm.payload(draft, agents: store.profiles) {
        case .failure(let refusal): problem = refusal.message
        case .success(let profile):
            var payload = profile.wire
            let role: String?
            if case .role(_, let chosen)? = seat { role = chosen }
            else { let slug = AGTSeats.slug(newRole); role = slug.isEmpty ? nil : slug }
            if let role { payload["seat"] = role }
            guard store.fixture == nil else { var saved = profile; saved.seat = role; await store.save(saved); return }
            store.busy = true
            let result = await TasksStore.shared.call("tasks:agent-save", [payload])
            store.busy = false
            TasksStore.shared.adopt(result)
            if result.ok {
                problem = nil
                await seated(profile, role: role, seat: seat)
                store.openProfile = profile.id
                AGTAgentSettingsWindow.open(profile.id)
            }
            else { problem = result.message ?? "That did not save." }
        }
    }

    /// After the hire: the seat's folder exists (an existing seat is left exactly as it is), and a
    /// hire into a project's lead seat becomes that project's lead.
    private func seated(_ profile: AgentProfile, role: String?, seat: AGTSeat?) async {
        if case .lead(let id)? = seat, let project = AGTLeads.projects.first(where: { $0.id == id }),
           let agent = store.agent(profile.id) {
            await AGTLeads.setLead(agent, of: project)
            return
        }
        let own = AGTSeats.roleSeat(agentID: profile.id, seat: role, projectID: profile.projectID)
        let title = seat == nil ? (newRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? profile.name : newRole.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        _ = try? await DeckMemory.store.ensureOwner(own.owner, name: title ?? AGTSeatsStore.shared.title(for: own))
        await AGTSeatsStore.shared.refresh()
    }
}
