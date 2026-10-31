import SwiftUI
import TerminalDeckNativeCore

// Settings → Hoot's file boxes, drawn in SwiftUI (web: settings/sections/CopilotEditor.tsx).
// Configuration files: no smart quotes, dashes or capitals (McpPlainEditor).

/// `FileEditor`: a file in a box, Save / Undo my changes, the rule for saving and what saving does.
struct NativeFileEditor<Extra: View>: View {
    let label: String
    /// Nil while it is being read.
    let text: String?
    let problem: String?
    /// What saving does, said under the box ("Unsaved. …" while there are changes).
    let effect: String
    /// Why Save is refused right now, or nil when it is not.
    let saveBecause: String?
    let saving: Bool
    let note: (text: String, ok: Bool)?
    var rows: Int = 18
    let onSave: (String) -> Void
    @ViewBuilder var extra: () -> Extra

    @State private var draft = ""
    @State private var seen: String?

    var body: some View {
        if let problem {
            Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if let text {
            let dirty = draft != text
            let because = saveBecause ?? (dirty ? nil : "Nothing has changed.")
            VStack(alignment: .leading, spacing: 8) {
                McpTextBox(text: $draft, placeholder: "", minHeight: CGFloat(rows) * 15, disabled: saving)
                    .accessibilityLabel(label)
                HStack(spacing: 8) {
                    Button(saving ? "Saving…" : "Save") { onSave(draft) }
                        .buttonStyle(.borderedProminent)
                        .disabled(because != nil || saving)
                    Button("Undo my changes") { draft = text }
                        .disabled(!dirty || saving)
                    extra()
                }
                if let saveBecause { help("Save: \(saveBecause)") }
                help(dirty ? "Unsaved. \(effect)" : effect)
                if let note { NativeCodingAINotice(tone: note.ok ? .info : .error, text: note.text) }
            }
            .onAppear { adopt(text) }
            .onChange(of: text) { _, next in adopt(next) }
        } else {
            Text("Reading…").foregroundStyle(.secondary)
        }
    }

    /// A new copy from the disk replaces the draft (the page's `seen` ref).
    private func adopt(_ next: String) {
        guard seen != next else { return }
        seen = next
        if draft != next { draft = next }
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension NativeFileEditor where Extra == EmptyView {
    init(label: String, text: String?, problem: String?, effect: String, saveBecause: String?, saving: Bool,
         note: (text: String, ok: Bool)?, rows: Int = 18, onSave: @escaping (String) -> Void) {
        self.init(label: label, text: text, problem: problem, effect: effect, saveBecause: saveBecause, saving: saving,
                  note: note, rows: rows, onSave: onSave, extra: { EmptyView() })
    }
}

/// `ReadOnlyFile`: a generated file, selectable, with why it cannot be edited.
struct NativeReadOnlyFile<Extra: View>: View {
    let label: String
    let text: String?
    let problem: String?
    let because: String
    var rows: Int = 18
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        if let problem {
            Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if let text {
            VStack(alignment: .leading, spacing: 8) {
                McpPlainEditor(text: .constant(text), editable: false)
                    .frame(minHeight: CGFloat(rows) * 15)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                    .accessibilityLabel(label)
                HStack(spacing: 8) { extra() }
                Text(because).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Reading…").foregroundStyle(.secondary)
        }
    }
}

extension NativeReadOnlyFile where Extra == EmptyView {
    init(label: String, text: String?, problem: String?, because: String, rows: Int = 18) {
        self.init(label: label, text: text, problem: problem, because: because, rows: rows, extra: { EmptyView() })
    }
}
