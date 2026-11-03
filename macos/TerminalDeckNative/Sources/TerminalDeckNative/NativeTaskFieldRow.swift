import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - One row

struct FieldRow: View {
    let field: TaskField
    let ctx: FieldCtx
    let first: Bool
    let last: Bool
    let error: String?
    let store: FieldsStore
    private enum Menu { case menu, options, delete }
    @State private var menu: Menu?
    @State private var renaming = false
    @State private var name = ""
    @State private var cfg = FieldConfig()
    @State private var menuErr: String?
    @State private var saving = false
    @State private var hover = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let info = TaskFields.info(field.kind)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 6) {
                    FieldTypeIcon(kind: field.kind, size: 18)
                    if renaming {
                        TextField("Field name", text: Binding(get: { name }, set: { name = String($0.prefix(80)) }))
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onAppear { nameFocused = true }
                            .onSubmit { nameFocused = false }
                            .onExitCommand {
                                name = field.label
                                renaming = false
                            }
                            .onChange(of: nameFocused) { _, now in if !now && renaming { commitRename() } }
                            .accessibilityLabel("Field name")
                    } else {
                        Text(field.label).lineLimit(1)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 170, height: 28, alignment: .leading)
                .help(info.name)
                FieldValueEditor(field: field, ctx: ctx) { v in Task { await store.commitValue(field, v) } }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                if !ctx.readOnly {
                    Button {
                        menuErr = nil
                        menu = menu == nil ? .menu : nil
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hover || menu != nil ? 1 : 0)
                    .accessibilityLabel("More for \(field.label)")
                    .popover(isPresented: Binding(get: { menu != nil }, set: { if !$0 { menu = nil } }), arrowEdge: .bottom) {
                        menuContent.frame(width: menu == .options ? 320 : 200)
                    }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.secondary.opacity(0.06) : .clear))
            .onHover { hover = $0 }
            if let error {
                Text(error).font(.caption).foregroundStyle(TaskTone.input).padding(.leading, 32).padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder private var menuContent: some View {
        switch menu {
        case .menu?:
            VStack(alignment: .leading, spacing: 0) {
                FieldMenuRow(action: {
                    menu = nil
                    name = field.label
                    renaming = true
                }) { Label("Rename", systemImage: "pencil") }
                if TaskFields.hasOptions(field.kind) {
                    FieldMenuRow(action: {
                        cfg = field.config
                        menuErr = nil
                        menu = .options
                    }) { Label("Edit options", systemImage: "gearshape") }
                }
                FieldMenuRow(action: {
                    menu = nil
                    Task { await store.move(field, -1) }
                }) { Label("Move up", systemImage: "arrow.up") }
                    .disabled(first).opacity(first ? 0.4 : 1)
                FieldMenuRow(action: {
                    menu = nil
                    Task { await store.move(field, 1) }
                }) { Label("Move down", systemImage: "arrow.down") }
                    .disabled(last).opacity(last ? 0.4 : 1)
                Divider().padding(.vertical, 4)
                FieldMenuRow(action: { menu = .delete }) { Label("Delete", systemImage: "trash").foregroundStyle(.red) }
            }
            .padding(4)
        case .delete?:
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete “\(field.label)” and its value?").font(.system(size: 13))
                HStack {
                    Spacer()
                    Button("Cancel") { menu = nil }
                    Button("Delete field", role: .destructive) {
                        menu = nil
                        Task { await store.delete(field) }
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                }
                .controlSize(.small)
            }
            .padding(12)
        case .options?:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    FieldTypeIcon(kind: field.kind, size: 18)
                    Text(field.label).font(.system(size: 13, weight: .medium))
                }
                FieldConfigForm(kind: field.kind, config: $cfg, siblings: ctx.fields.filter { $0.id != field.id }, selfId: field.id, team: ctx.team)
                if let menuErr { Text(menuErr).font(.caption).foregroundStyle(TaskTone.input) }
                HStack {
                    Spacer()
                    Button("Cancel") { menu = nil }
                    Button("Save") { saveOptions() }.buttonStyle(.borderedProminent).disabled(saving)
                }
            }
            .padding(12)
        case nil:
            EmptyView()
        }
    }

    private func commitRename() {
        let next = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        renaming = false
        guard !next.isEmpty, next != field.label else {
            name = field.label
            return
        }
        let original = field.label
        Task {
            if await store.rename(field, next) != nil { name = original }
        }
    }

    private func saveOptions() {
        let siblings = ctx.fields.filter { $0.id != field.id }
        switch TaskFields.normaliseConfig(field.kind, cfg.crm(field.kind), siblings: siblings) {
        case .failure(let f):
            menuErr = f.error
        case .success(let clean):
            saving = true
            Task {
                let err = await store.saveConfig(field, clean)
                saving = false
                if let err { menuErr = err } else { menu = nil }
            }
        }
    }
}
