import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - Checklists

struct ChecklistsBlock: View {
    let model: TaskDetailModel
    let lists: [Checklist]
    let people: TaskPeople
    let justAdded: Bool
    @State private var collapsed = false

    var body: some View {
        let items = lists.flatMap(\.items)
        let open = items.filter { !$0.done }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { collapsed.toggle() } label: {
                    HStack(spacing: 8) {
                Image(systemName: "chevron.down").rotationEffect(.degrees(collapsed ? -90 : 0)).foregroundStyle(.secondary)
                Text("Checklists").font(.callout.weight(.semibold))
                if !items.isEmpty {
                    Text("\(open) open").foregroundStyle(.secondary)
                    ProgressBarSmall(done: items.count - open, total: items.count)
                }
                Spacer()
                    }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(SIDEBARRowStyle())
                    .accessibilityLabel(collapsed ? "Expand checklists" : "Collapse checklists")
                Button(action: addList) { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Add checklist").accessibilityLabel("New checklist")
            }
            .font(.callout)
            .frame(height: 36)
            if !collapsed {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lists.enumerated()), id: \.element.id) { li, list in
                        ChecklistCard(model: model, list: list, people: people, autoOpen: justAdded && li == 0 && list.items.isEmpty)
                    }
                    Button(action: addList) { Label("Add checklist", systemImage: "plus").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checklists")
    }

    private func addList() {
        Task { await model.addChecklist(title: lists.isEmpty ? "Checklist" : "Checklist \(lists.count + 1)") }
    }
}

struct ChecklistCard: View {
    let model: TaskDetailModel
    let list: Checklist
    let people: TaskPeople
    let autoOpen: Bool
    @State private var title = ""
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TextField("", text: Binding(get: { list.title }, set: { model.renameChecklist(list.id, String($0.prefix(120))) }))
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .accessibilityLabel("Checklist name")
                Button { model.deleteChecklist(list) } label: { Image(systemName: "xmark").font(.caption2).frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Remove checklist \"\(list.title)\"")
            }
            .frame(height: 28)
            ForEach(list.items) { item in
                HStack(spacing: 10) {
                    Button { model.setItemDone(item, !item.done) } label: {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.done ? TaskTone.completed : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mark \"\(item.title)\" \(item.done ? "not done" : "done")")
                    Text(item.title).lineLimit(1).strikethrough(item.done)
                        .foregroundStyle(item.done ? Color(nsColor: .tertiaryLabelColor) : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RowAssignButton(value: item.assigneeUserId, people: people, team: model.team, what: "item \"\(item.title)\"") {
                        model.setItemAssignee(item, $0)
                    }
                    Button { model.deleteItem(item) } label: { Image(systemName: "xmark").font(.caption2).frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).opacity(hovered == item.id ? 1 : 0)
                        .accessibilityLabel("Remove item \"\(item.title)\"")
                }
                .font(.callout)
                .padding(.horizontal, 4)
                .frame(height: 35)
                .onHover { hovered = $0 ? item.id : nil }
            }
            InlineAdd(label: "Add item", placeholder: "Item name", autoOpen: autoOpen) { model.addChecklistItem(list, $0) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.7)))
    }
}

/// "+ Add …" that becomes a text box; Enter adds and keeps it open, Escape closes it.
struct InlineAdd: View {
    let label: String
    let placeholder: String
    var autoOpen = false
    let onAdd: (String) -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing || autoOpen && text.isEmpty && !dismissed {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit {
                        let t = text.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        onAdd(t)
                        text = ""
                    }
                    .onExitCommand {
                        editing = false
                        dismissed = true
                    }
            } else {
                Button {
                    editing = true
                } label: { Label(label, systemImage: "plus").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    @State private var dismissed = false
}
