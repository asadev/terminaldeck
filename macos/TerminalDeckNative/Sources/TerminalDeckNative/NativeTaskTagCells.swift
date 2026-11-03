import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - Tags

struct TagsCell: View {
    let model: TaskDetailModel
    let labels: [String]
    @State private var open = false
    @State private var query = ""
    @State private var menuFor: String?
    @State private var confirmDelete = false

    private func colorName(_ l: String) -> String { model.more?.labelColors[l.lowercased()] ?? "grey" }

    var body: some View {
        Button { open.toggle() } label: {
            if labels.isEmpty {
                Text("Empty").font(.system(size: 13)).foregroundStyle(.tertiary)
            } else {
                TasksFlow(spacing: 4, lineSpacing: 4) {
                    ForEach(labels, id: \.self) { tag($0) }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canEditRow)
        .accessibilityLabel(labels.isEmpty ? "Tags" : "Tags: \(labels.joined(separator: ", "))")
        .popover(isPresented: $open, arrowEdge: .bottom) { editor }
    }

    private func tag(_ l: String) -> some View {
        let c = CrmColor.label(colorName(l))
        return Text(l).font(.caption.weight(.medium)).foregroundStyle(c).padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.16)))
    }

    private var editor: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let exists = labels.contains { $0.lowercased() == trimmed.lowercased() }
        let canColor = model.more?.canColorTags == true
        let canDelete = model.more != nil
        return VStack(alignment: .leading, spacing: 8) {
            TasksFlow(spacing: 4, lineSpacing: 4) {
                ForEach(labels, id: \.self) { l in
                    let c = CrmColor.label(colorName(l))
                    HStack(spacing: 2) {
                        Text(l).font(.caption)
                        if canColor || canDelete {
                            Button {
                                menuFor = menuFor == l ? nil : l
                                confirmDelete = false
                            } label: { Image(systemName: "ellipsis").font(.system(size: 9)) }
                                .buttonStyle(.plain).accessibilityLabel("Tag options: \(l)")
                        }
                        Button { model.changeLabels(labels.filter { $0 != l }) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove tag \(l)")
                    }
                    .foregroundStyle(c)
                    .padding(.leading, 8).padding(.trailing, 4).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.16)))
                }
                TextField("Search or add tags...", text: Binding(get: { query }, set: { query = String($0.prefix(40)) }))
                    .textFieldStyle(.plain)
                    .frame(minWidth: 128)
                    .onSubmit(add)
                    .onKeyPress(.delete) {
                        if query.isEmpty, !labels.isEmpty {
                            model.changeLabels(Array(labels.dropLast()))
                            return .handled
                        }
                        return .ignored
                    }
                    .accessibilityLabel("Search or add tags")
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if let menuFor {
                VStack(alignment: .leading, spacing: 6) {
                    if canColor {
                        Text("Add color").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        TasksFlow(spacing: 6, lineSpacing: 6) {
                            ForEach(CrmColor.labelColors, id: \.self) { c in
                                let on = colorName(menuFor) == c
                                Button { model.setLabelColor(menuFor, c) } label: {
                                    Circle().fill(CrmColor.label(c)).frame(width: 20, height: 20)
                                        .overlay(Circle().stroke(Color.primary.opacity(on ? 0.6 : 0), lineWidth: 2).padding(-2))
                                }
                                .buttonStyle(.plain)
                                .help(c == "grey" ? "Light Grey" : c)
                                .accessibilityLabel("Colour \(c == "grey" ? "Light Grey" : c)")
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                    if canDelete {
                        if !confirmDelete {
                            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        } else {
                            Text("Are you sure you want to delete the **\(menuFor)** tag everywhere? It comes off every task you can change.")
                                .font(.caption)
                            HStack {
                                Button("Delete", role: .destructive) {
                                    let t = menuFor
                                    self.menuFor = nil
                                    confirmDelete = false
                                    model.deleteLabelEverywhere(t)
                                }
                                .buttonStyle(.borderedProminent).tint(TaskTone.input).controlSize(.small)
                                Button("Cancel") { confirmDelete = false }.controlSize(.small)
                            }
                        }
                    }
                }
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .onExitCommand {
                    self.menuFor = nil
                    confirmDelete = false
                }
            }
            Text(labels.isEmpty ? "Select an option" : "On this task").font(.caption2).foregroundStyle(.secondary)
            if !trimmed.isEmpty && !exists {
                Button(action: add) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.caption).foregroundStyle(.tertiary)
                        Text("Create")
                        Text(trimmed).font(.caption.weight(.medium)).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                        Spacer()
                        Text("⏎").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(labels.count >= 20)
            } else if labels.isEmpty {
                Text("No tags created").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(width: 280)
    }

    private func add() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !labels.contains(where: { $0.lowercased() == trimmed.lowercased() }), labels.count < 20 else { return }
        model.changeLabels(CrmText.normalizeLabels(labels + [trimmed]))
        query = ""
    }
}
