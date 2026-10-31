import AppKit
import SwiftUI
import TerminalDeckNativeCore

extension NativeTaskCreatePopup {
    // MARK: Parts

    var header: some View {
        HStack(spacing: 8) {
            Text("Task").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    var projectRow: some View {
        let open = projectChoices
        let agentFolder = agents.first { $0.id == draft.assignee }?.defaultProject.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: 8) {
            Picker("Project", selection: Binding(get: { projectSelection(open) }, set: { pickProject($0) })) {
                ForEach(open) { project in
                    DeckRowLabel(TaskProjects.name(of: project.path, among: open), image: DeckRowIcon.project(folder: project.path))
                        .tag(TaskProjects.clean(project.path))
                }
                if !open.isEmpty { Divider() }
                DeckRowLabel(agentFolder.map { "Agent's folder (\(TaskProjects.name(of: $0, among: open)))" } ?? TaskProjects.noProject,
                             image: DeckRowIcon.independent).tag("")
                Text("Other folder…").tag(Self.otherFolder)
            }
            .labelsHidden()
            .fixedSize()
            .help(draft.project.isEmpty ? (agentFolder ?? "") : draft.project)
            .accessibilityLabel("Project")
            if typingFolder {
                TextField("Full folder path", text: $draft.project)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .folder)
                    .onSubmit(save)
                    .onExitCommand(perform: onClose)
                    .frame(maxWidth: 360)
                    .accessibilityLabel("Project folder")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    var nameField: some View {
        TextField("Task name", text: Binding(get: { draft.title }, set: { draft.title = String($0.prefix(300)) }))
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .focused($focus, equals: .name)
            .onSubmit(save)
            .onExitCommand(perform: onClose)
            .accessibilityLabel("Task name")
    }

    @ViewBuilder var descriptionArea: some View {
        if describing || !draft.instructions.isEmpty {
            TextEditor(text: $draft.instructions)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .description)
                .padding(4)
                .frame(minHeight: 84, maxHeight: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Description")
        } else {
            Button {
                describing = true
                Task { @MainActor in focus = .description }
            } label: {
                Label("Add description", systemImage: "text.alignleft")
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    var chips: some View {
        let statuses = state.localStatuses.contains(draft.status) ? state.localStatuses : state.localStatuses + [draft.status]
        let people = TasksRules.assigneeChoices(agents)
        let goals = Goals.options(state.goals)
        let today = TaskList.ymdOf(Date().timeIntervalSince1970 * 1000)
        return TasksFlow(spacing: 8, lineSpacing: 8) {
            Picker("Status", selection: $draft.status) {
                ForEach(statuses, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Status")
            .accessibilityLabel("Status")
            Picker("Assigned to", selection: $draft.assignee) {
                if !people.contains(where: { $0.id == draft.assignee }) {
                    DeckRowLabel(preset.assigneeName ?? MyWorkModel.name(of: draft.assignee, in: state),
                                 image: DeckRowIcon.assignee(draft.assignee)).tag(draft.assignee)
                }
                ForEach(people, id: \.id) { DeckRowLabel($0.label, image: DeckRowIcon.assignee($0.id)).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Assigned to")
            .accessibilityLabel("Assigned to")
            if !goals.isEmpty {
                Picker("Goal", selection: $draft.goalId) {
                    Text("No goal").tag("")
                    ForEach(goals, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Goal")
                .accessibilityLabel("Goal")
            }
            ForEach(preset.carriedChips(today: today), id: \.symbol) { chip in
                Label(chip.text, systemImage: chip.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .help(chip.help)
            }
        }
        .controlSize(.small)
    }

    var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if let line = problem ?? folderWarning {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(TaskTone.input)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer(minLength: 8)
            Button(saving ? "Creating…" : "Create task", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(saving || !hasTitle)
                .accessibilityLabel("Create task")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

}
