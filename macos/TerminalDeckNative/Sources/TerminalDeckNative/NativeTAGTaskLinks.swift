import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeTAGTasksLoading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reading tasks…").font(.callout).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)).frame(width: 220, height: 24)
            ForEach(0..<5) { _ in
                HStack(spacing: 10) {
                    Circle().fill(Color.secondary.opacity(0.1)).frame(width: 16, height: 16)
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(height: 18)
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width: 100, height: 18)
                }.padding(.vertical, 4)
            }
            Spacer()
        }.padding(24).accessibilityElement(children: .ignore).accessibilityLabel("Reading tasks")
    }
}

/// Linked work is separate from a task's checklist-style subtasks.
struct NativeTAGTaskLinks: View {
    let task: TaskRow
    let tasks: [TaskRow]
    var compact = false
    var onOpen: (String) -> Void = { TasksStore.shared.openTask($0) }

    var body: some View {
        let parent = TAGAgentSettings.parent(of: task, in: tasks)
        let children = TAGAgentSettings.children(of: task, in: tasks)
        if compact {
            HStack(spacing: 6) {
                if let parent { link("Parent task", parent, icon: "arrow.turn.up.left") }
                if !children.isEmpty {
                    Menu {
                        ForEach(children) { child in
                            Button(child.title) { onOpen(child.id) }
                        }
                    } label: {
                        Label("\(children.count) child \(children.count == 1 ? "task" : "tasks")", systemImage: "arrow.triangle.branch")
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }.font(.caption).foregroundStyle(.secondary)
        } else if parent != nil || !children.isEmpty || task.parentTaskId != nil || task.parentExternalTaskId != nil {
            VStack(alignment: .leading, spacing: 7) {
                Text("Linked work").font(.callout.weight(.semibold))
                if let parent {
                    link("Parent: \(parent.title)", parent, icon: "arrow.turn.up.left")
                } else if task.parentTaskId != nil || task.parentExternalTaskId != nil {
                    Text("Parent task is unavailable here.").foregroundStyle(.secondary)
                }
                ForEach(children) { child in
                    HStack(spacing: 8) {
                        link("\(child.reviewOfTaskId == task.id ? "Review" : "Child"): \(child.title)", child, icon: "arrow.triangle.branch")
                        Spacer(minLength: 8)
                        if !child.crmStatus.isEmpty { Text(child.crmStatus).foregroundStyle(.secondary) }
                        Text(child.agent).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func link(_ label: String, _ target: TaskRow, icon: String) -> some View {
        Button { onOpen(target.id) } label: {
            Label(label, systemImage: icon).lineLimit(2).multilineTextAlignment(.leading)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Open \(target.title)").accessibilityLabel("Open \(target.title)")
    }
}

struct NativeTAGKeptSession: View {
    let task: TaskRow
    @State private var closing = false
    @State private var error: String?

    var body: some View {
        if task.keepAliveUntilClose == true || task.keepOpenUntil != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(task.keepAliveUntilClose == true ? "Session stays open until you close it" : "Session is kept open after finishing")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(closing ? "Closing…" : "Close session") { close() }.disabled(closing)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func close() {
        closing = true
        error = nil
        Task {
            let store = TasksStore.shared
            let result = await store.closeSession(task.id)
            store.adopt(result)
            if !result.ok { error = result.message ?? "The session could not be closed." }
            closing = false
        }
    }
}

/// The CRM mirror also needs an inspectable destination for parent/child links.
struct NativeTAGExternalTaskDetail: View {
    let task: TaskRow
    let tasks: [TaskRow]
    let onOpen: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text([task.agent, task.crmStatus, TasksRules.processLabel(task.process)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close task")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !task.project.isEmpty { Label(task.project, systemImage: "folder").font(.caption).textSelection(.enabled) }
                    if !task.instructions.isEmpty { Text(task.instructions).textSelection(.enabled) }
                    NativeTAGTaskLinks(task: task, tasks: tasks, onOpen: onOpen)
                    NativeTAGKeptSession(task: task)
                    if !task.notes.isEmpty {
                        Text("Activity").font(.callout.weight(.semibold))
                        ForEach(Array(task.notes.enumerated()), id: \.offset) { _, note in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.text).textSelection(.enabled)
                                Text("\(note.by) · \(note.kind)").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(maxWidth: 800, maxHeight: 720)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
