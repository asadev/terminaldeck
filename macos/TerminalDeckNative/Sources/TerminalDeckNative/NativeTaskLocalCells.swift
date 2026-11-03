import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - Local rows: the project folder and the workspace

/// The folder an agent works in: click to type it, or choose it in the Mac's folder chooser.
struct ProjectCell: View {
    let model: TaskDetailModel
    @State private var editing = false
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        let project = model.row.project
        HStack(spacing: 8) {
            if editing {
                TextField("/Users/you/Projects/app", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onAppear { focused = true }
                    .onSubmit(save)
                    .onChange(of: focused) { _, now in if !now { save() } }
                    .onExitCommand {
                        draft = project
                        editing = false
                    }
                    .accessibilityLabel("Project folder")
            } else {
                Button {
                    draft = project
                    editing = true
                } label: {
                    Text(project.isEmpty ? "Empty" : project)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(project.isEmpty ? Color(nsColor: .tertiaryLabelColor) : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(project.isEmpty ? "Needed before Hoot or an agent can work on it" : project)
            }
            Button("Choose…") {
                Task {
                    let result = await model.chooseProject()
                    if let chosen = result.project {
                        draft = chosen
                        problem = nil
                    } else if let message = result.problem {
                        problem = message
                    }
                }
            }
            .controlSize(.small)
            if let problem { Text(problem).font(.caption).foregroundStyle(TaskTone.input).lineLimit(1).help(problem) }
        }
        .font(.system(size: 13))
    }

    private func save() {
        guard editing else { return }
        editing = false
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != model.row.project else { return }
        Task {
            if let message = await model.setProject(value) {
                problem = message
                draft = model.row.project
            } else {
                problem = nil
            }
        }
    }
}

/// "Own workspace", then the workspace itself once there is one.
struct WorkspaceField: View {
    let model: TaskDetailModel
    @State private var on = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("Own workspace", isOn: Binding(get: { on }, set: { next in
                    on = next
                    problem = nil
                    Task {
                        if let message = await model.setUseWorkspace(next) {
                            on = !next
                            problem = message
                        }
                    }
                }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("The agent works in a separate copy of the project (a git worktree on its own branch), from its next start.")
                if let problem { Text(problem).font(.caption).foregroundStyle(TaskTone.input).lineLimit(1).help(problem) }
            }
            if model.showsWorkspace, let view = model.workspace { workspaceCell(view) }
        }
        .padding(.vertical, 8)
        .onAppear { on = model.row.useWorkspace }
        .onChange(of: model.row.useWorkspace) { _, value in on = value }
    }

    @ViewBuilder private func workspaceCell(_ view: TaskDetailModel.WorkspaceView) -> some View {
        if let w = view.workspace {
            let there = w.state != "removed"
            let below = model.workspaceNote ?? w.reason.map { (w.state != "kept", $0) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(w.branch).font(.caption.monospaced()).lineLimit(1).help("Branch \(w.branch) in \(w.repo)")
                    Text(w.state == "active" ? "Active" : w.state == "kept" ? "Kept" : "Removed")
                        .font(.caption).foregroundStyle(w.state == "kept" ? TaskTone.waiting : Color.secondary)
                    if there {
                        Button("Open folder") { model.openWorkspace() }.controlSize(.small)
                        Button(model.workspaceBusy ? "Removing…" : "Remove when clean") { model.removeWorkspace() }
                            .controlSize(.small)
                            .disabled(model.workspaceBusy)
                            .help("Removes the folder only if it has no uncommitted changes and nothing is running in it. The branch stays.")
                    }
                }
                Text(w.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(w.folder)
                if let below {
                    Text(below.1).font(.caption).foregroundStyle(below.0 ? Color.secondary : TaskTone.waiting)
                }
            }
        } else {
            Text("None. \(view.refusal ?? "")").font(.caption).foregroundStyle(.secondary)
        }
    }
}
