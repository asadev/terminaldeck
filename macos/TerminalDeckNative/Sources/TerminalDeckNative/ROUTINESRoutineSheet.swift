import SwiftUI
import TerminalDeckNativeCore

struct ROUTINESRoutineSheet: View {
    let model: ROUTINESPageModel
    let introduction: String?
    @State private var draft: ROUTINESDraft
    @State private var saving = false
    @State private var problem: String?
    @State private var destinations: Routines21DestinationsModel
    @Environment(\.dismiss) private var dismiss
    init(model: ROUTINESPageModel, initial: ROUTINESDraft, introduction: String? = nil) {
        self.introduction = introduction
        self.model = model; _draft = State(initialValue: initial)
        _destinations = State(initialValue: Routines21DestinationsModel(routineID: initial.id, call: { channel, args in try await model.call(channel, args) }))
    }
    private var agents: [AGTAgent] { AGTAgentsStore.shared.agents.filter { $0.kind == .profile && $0.status != "archived" } }
    private var agentGroups: [String] { Array(Set(agents.map(\.resolvedProjectID))).sorted() }
    private var projects: [PROJProject] { NativePROJLabels.shared.projects }
    private var clock: Binding<Date> {
        Binding(get: { let parts = draft.time.split(separator: ":"); return Calendar.current.date(from: DateComponents(hour: parts.first.flatMap { Int($0) } ?? 8, minute: parts.last.flatMap { Int($0) } ?? 30)) ?? Date() }, set: { date in let parts = Calendar.current.dateComponents([.hour, .minute], from: date); draft.time = String(format: "%02d:%02d", parts.hour ?? 8, parts.minute ?? 30) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.originalText.isEmpty ? "New routine" : "Edit routine").font(.title3.weight(.semibold)).padding(20)
            if let introduction { Text(introduction).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 8) }
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Who does it", selection: $draft.agentID) {
                        DeckRowLabel("Hoot · Every project", image: DeckRowIcon.hoot).tag("@hoot")
                        ForEach(agentGroups, id: \.self) { id in
                            Section(NativePROJLabels.shared.name(for: id)) { ForEach(agents.filter { $0.resolvedProjectID == id }) { agent in DeckRowLabel(agent.name, image: DeckRowIcon.agent(id: agent.id)).tag(agent.id) } }
                        }
                        if draft.agentID != "@hoot", !agents.contains(where: { $0.id == draft.agentID }) { Text("Unavailable agent").tag(draft.agentID) }
                    }
                    Picker("Project", selection: $draft.projectID) { if draft.agentID == "@hoot" { DeckRowLabel("Every project", image: DeckRowIcon.allProjects).tag("every-project") }; ForEach(projects) { project in DeckRowLabel.project(project).tag(project.id) } }
                    if draft.projectID == PROJProjects.independentID { TextField("Folder", text: $draft.folder).help("The full folder where this routine works") }
                }
                Section("When") {
                    Picker("Trigger", selection: $draft.whenKind) { Text("On a schedule").tag("schedule"); Text("When something happens").tag("event") }.pickerStyle(.segmented).labelsHidden()
                    if draft.whenKind == "schedule" {
                        Picker("Repeat", selection: $draft.schedule) { Text("Every day").tag("daily"); Text("Weekdays").tag("weekdays"); Text("Every week").tag("weekly"); Text("Every N hours").tag("hours") }
                        if draft.schedule == "weekly" { Picker("Day", selection: $draft.day) { ForEach(["mon", "tue", "wed", "thu", "fri", "sat", "sun"], id: \.self) { day in Text(["mon":"Monday", "tue":"Tuesday", "wed":"Wednesday", "thu":"Thursday", "fri":"Friday", "sat":"Saturday", "sun":"Sunday"][day] ?? day).tag(day) } } }
                        if draft.schedule == "hours" { Stepper("Every \(draft.hours) hours", value: $draft.hours, in: 1...168) }
                        else { DatePicker("Time", selection: clock, displayedComponents: .hourAndMinute) }
                    } else {
                        Picker("Event", selection: $draft.event) { Text("A session fails").tag("session-failed"); Text("A session finishes").tag("session-finished"); Text("A task is created").tag("task-created"); Text("A task is finished").tag("task-finished"); Text("A file changes in…").tag("file-change"); if !["session-failed", "session-finished", "task-created", "task-finished", "file-change"].contains(draft.event) { Text(draft.event.replacingOccurrences(of: "-", with: " ")).tag(draft.event) } }
                        if draft.event == "file-change" { TextField("File pattern", text: $draft.glob).help("For example: src/** or **/*.swift") }
                    }
                }
                Section("If it fires again") {
                    Picker("While busy", selection: Binding(get: { draft.overlap == "merge" ? "queue" : draft.overlap }, set: { draft.overlap = $0 })) {
                        Text("Combine pending triggers").tag("queue")
                        Text("Queue each trigger").tag("queue-all")
                        Text("Skip").tag("skip")
                        Text("Stop and restart with latest").tag("cancel")
                    }
                    if draft.overlap == "queue-all" { Stepper("Keep up to \(draft.maxPending) pending", value: $draft.maxPending, in: 1...100) }
                    Picker("Missed schedules", selection: $draft.catchUp) {
                        Text("Keep existing timing").tag("legacy")
                        Text("Skip missed runs").tag("skip")
                        Text("Run once").tag("once")
                        Text("Replay missed runs").tag("replay")
                    }
                    if draft.catchUp == "replay" { Stepper("Replay up to \(draft.maxCatchUp) runs", value: $draft.maxCatchUp, in: 1...50) }
                    Text("Replay runs one at a time. Extra missed times are reported and skipped. New or changed schedules start from now. After an interrupted run, check its work before resuming.").font(.caption).foregroundStyle(.secondary)
                }
                Section("What to do") {
                    ZStack(alignment: .topLeading) {
                        if draft.prompt.isEmpty { Text("e.g. Read last night’s sessions and tell me what needs me.").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 7).allowsHitTesting(false) }
                        TextEditor(text: $draft.prompt).font(.body).scrollContentBackground(.hidden).frame(height: 90).accessibilityLabel("What to do")
                    }
                    Toggle("On", isOn: $draft.enabled).tint(ROUTINESKit.switchOn)
                }
                Section { Routines21DestinationsView(model: destinations, canTest: !draft.originalText.isEmpty) }
            }.formStyle(.grouped)
            if let problem { Text(problem).font(.callout).foregroundStyle(ROUTINESKit.bad).padding(.horizontal, 20).padding(.top, 8) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(saving ? "Saving…" : "Save routine") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving) }.padding(20)
        }.frame(width: 640, height: 740)
        .task { await destinations.load(existing: !draft.originalText.isEmpty) }
        .onChange(of: draft.agentID) { _, id in
            if id == "@hoot" { draft.projectID = "every-project"; Task { do { let folder = try await model.defaultHootFolder(); if draft.agentID == "@hoot" { draft.folder = folder } } catch { problem = "Couldn’t read Hoot’s folder." } } }
            else if let agent = agents.first(where: { $0.id == id }) { draft.projectID = agent.resolvedProjectID; draft.folder = agent.project }
        }
        .onChange(of: draft.projectID) { _, id in
            if let folder = projects.first(where: { $0.id == id })?.folders.first { draft.folder = folder }
        }
    }
    private func save() {
        if let reason = draft.problem { problem = reason; return }
        if destinations.loading { problem = "Wait for result destinations to finish loading."; return }
        if destinations.loadFailed { problem = "Result destinations could not be read. Reopen this routine and try again."; return }
        if let reason = destinations.destinations.compactMap(\.problem).first { problem = reason; return }
        saving = true; problem = nil
        Task { let saved = await model.save(draft, destinations: destinations.destinations); saving = false; if saved { dismiss() } else { problem = model.actionProblem ?? "The routine did not save." } }
    }
}
