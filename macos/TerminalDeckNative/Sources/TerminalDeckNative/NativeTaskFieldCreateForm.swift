import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - The create form

/// Pick a type, then name it: ClickUp's two steps. The type switcher goes back to
/// the list without losing the name; × closes; Create waits for a valid name.
struct CreateFieldPanel: View {
    let siblings: [TaskField]
    var team: [CrmPerson] = []
    let onCancel: () -> Void
    /// Resolves to an error in words, or nil when the field was made.
    let onCreate: (String, FieldKind, FieldConfig) async -> String?
    @State private var picking = true
    @State private var kind: FieldKind = .text
    @State private var label = ""
    @State private var config = TaskFields.defaultConfig(.text)
    @State private var error: String?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let nameOk = (try? TaskFields.normaliseLabel(label).get()) != nil
        if picking {
            FieldTypePicker(current: label.isEmpty ? nil : kind) { k in
                if k != kind { config = TaskFields.defaultConfig(k) }
                kind = k
                error = nil
                picking = false
            }
        } else {
            let info = TaskFields.info(kind)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button { picking = true } label: {
                        HStack(spacing: 6) {
                            FieldTypeIcon(kind: kind, size: 18)
                            Text(info.name).font(.system(size: 13, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Field type: \(info.name). Change type")
                    Spacer()
                    Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Close")
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Field name", required: true)
                    TextField("Enter name…", text: Binding(get: { label }, set: { label = String($0.prefix(80)); error = nil }))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { if nameOk && !saving { create() } }
                        .accessibilityLabel("Field name")
                }
                FieldConfigForm(kind: kind, config: Binding(get: { config }, set: { config = $0; error = nil }), siblings: siblings, team: team)
                if let error { Text(error).font(.caption).foregroundStyle(TaskTone.input) }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button { create() } label: {
                        HStack(spacing: 4) {
                            if saving { ProgressView().controlSize(.mini) }
                            Text("Create")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!nameOk || saving)
                }
            }
            .padding(12)
            .onAppear { nameFocused = true }
        }
    }

    private func create() {
        let name: String
        switch TaskFields.normaliseLabel(label) {
        case .failure(let f):
            error = f.error
            return
        case .success(let s):
            name = s
        }
        if siblings.contains(where: { TaskFields.sameLabel($0.label, name) }) {
            error = "This task already has a field called “\(name)”"
            return
        }
        let clean: FieldConfig
        switch TaskFields.normaliseConfig(kind, config.crm(kind), siblings: siblings) {
        case .failure(let f):
            error = f.error
            return
        case .success(let c):
            clean = c
        }
        saving = true
        error = nil
        Task {
            let err = await onCreate(name, kind, clean)
            saving = false
            if let err { error = err }
        }
    }
}
