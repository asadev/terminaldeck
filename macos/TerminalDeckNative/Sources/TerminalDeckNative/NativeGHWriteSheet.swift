import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeGHFormField: Identifiable {
    enum Kind { case text, body, list, choice, boolean }
    let key: String
    let label: String
    var value = ""
    var hint = ""
    var required = false
    var kind = Kind.text
    var choices: [(String, String)] = []
    var id: String { key }

    static func text(_ key: String, _ label: String, value: String = "", required: Bool = true, hint: String = "") -> Self {
        .init(key: key, label: label, value: value, hint: hint, required: required)
    }
    static func body(_ key: String, _ label: String, value: String = "", required: Bool = false) -> Self {
        .init(key: key, label: label, value: value, required: required, kind: .body)
    }
    static func list(_ key: String, _ label: String, value: String = "", hint: String = "") -> Self {
        .init(key: key, label: label, value: value, hint: hint, kind: .list)
    }
    static func choice(_ key: String, _ label: String, choices: [(String, String)], value: String, kind: Kind = .choice) -> Self {
        .init(key: key, label: label, value: value, kind: kind, choices: choices)
    }
}

struct NativeGHWriteDraft: Identifiable {
    let id = UUID()
    let title: String
    let action: String
    let operation: String
    var arguments: [String: CodingAIJSON]
    let fields: [NativeGHFormField]
    let message: String
}

/// Every native mutation is two steps: edit, then inspect the frozen target and
/// the exact text that will be sent. The approved bit only exists on Confirm.
struct NativeGHWriteSheet: View {
    let draft: NativeGHWriteDraft
    let completed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String]
    @State private var reviewing = false
    @State private var busy = false
    @State private var error: String?

    init(draft: NativeGHWriteDraft, completed: @escaping (String) -> Void) {
        self.draft = draft
        self.completed = completed
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: draft.fields.map { ($0.key, $0.value) }))
        _reviewing = State(initialValue: draft.fields.isEmpty)
    }

    private var valid: Bool {
        draft.fields.allSatisfy { !$0.required || !(values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reviewing ? "Review change" : draft.title).font(.title3.weight(.semibold))
            Text(draft.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if reviewing { preview } else { editor }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
            .frame(maxHeight: 420)
            if let error { NativeGHErrorNote(message: error) }
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sending your change to GitHub…").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if reviewing, !draft.fields.isEmpty {
                    Button("Edit") { reviewing = false; error = nil }.disabled(busy)
                }
                Button(reviewing ? draft.action : "Review change") {
                    if reviewing { Task { await submit() } } else { reviewing = true }
                }
                .disabled(!valid || busy)
            }
        }
        .padding(24)
        .frame(width: 540)
        .tint(.secondary)
        .interactiveDismissDisabled(busy)
    }

    private var editor: some View {
        ForEach(draft.fields) { field in
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label).font(.callout.weight(.medium))
                switch field.kind {
                case .body:
                    TextEditor(text: binding(field.key))
                        .font(.body)
                        .frame(minHeight: 112)
                        .padding(6)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                        .accessibilityLabel(field.label)
                case .choice, .boolean:
                    Picker(field.label, selection: binding(field.key)) {
                        ForEach(field.choices, id: \.0) { choice in Text(choice.1).tag(choice.0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                case .text, .list:
                    TextField(field.hint.isEmpty ? field.label : field.hint, text: binding(field.key))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(field.label)
                }
                if !field.hint.isEmpty { Text(field.hint).font(.caption).foregroundStyle(.secondary) }
                if field.key == "parentPath" {
                    Button("Choose folder…") { chooseFolder() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let repo = draft.arguments["repo"]?.text {
                NativeGHKeyValue(label: "Repository", value: repo)
            }
            if let number = draft.arguments["number"]?.ghText {
                NativeGHKeyValue(label: "Number", value: "#\(number)")
            }
            if let event = draft.arguments["event"]?.text {
                NativeGHKeyValue(label: "Review", value: event.replacingOccurrences(of: "_", with: " ").lowercased())
            }
            if let body = draft.arguments["body"]?.text, !draft.fields.contains(where: { $0.key == "body" }) {
                NativeGHKeyValue(label: "Review text", value: body)
            }
            if let sha = draft.arguments["expectedHeadSHA"]?.text ?? draft.arguments["commitId"]?.text {
                NativeGHKeyValue(label: "Commit", value: String(sha.prefix(12)))
            }
            ForEach(draft.fields) { field in
                let value = values[field.key] ?? ""
                let readable = field.choices.first(where: { $0.0 == value })?.1 ?? value
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    Text(readable.isEmpty ? "None" : readable).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Confirming sends this change to GitHub using your connected account.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        NativeFront.whenPersonActs("main") { if panel.runModal() == .OK, let url = panel.url { values["parentPath"] = url.path }
        }
    }

    @MainActor private func submit() async {
        guard valid, !busy else { return }
        busy = true
        error = nil
        var args = draft.arguments
        for field in draft.fields {
            let text = values[field.key] ?? ""
            if field.key == "lineCommentBody" {
                if var comments = args["comments"]?.array, !comments.isEmpty, var first = comments[0].object {
                    first["body"] = .string(text)
                    comments[0] = .object(first)
                    args["comments"] = .array(comments)
                }
                continue
            }
            switch field.kind {
            case .list:
                args[field.key] = .array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { $0.text != nil })
            case .boolean: args[field.key] = .bool(text == "true")
            default:
                if !text.isEmpty || field.required || field.kind == .body { args[field.key] = .string(text) }
            }
        }
        do {
            let payload: [String: Any] = ["operation": draft.operation, "arguments": args.mapValues(\.foundation), "approved": true]
            let answer = CodingAIJSON(try await EngineBridge.shared.invoke("github:workspace", [payload]))
            if answer["ok"].bool == false || !answer["error"].isNull {
                throw NativeGHFailure(message: answer["error"]["message"].text ?? answer["error"].text ?? answer["message"].text ?? "GitHub could not finish this change. Try again.")
            }
            var message = "\(draft.action) — done."
            if let warning = answer["warning"].text { message = warning }
            else if draft.operation == "repos.clone", let path = answer["path"].text {
                message = answer["projectAdded"].isTrue ? "Cloned and added project: \(path)" : "Cloned to \(path). Add this folder from Projects."
            }
            completed(message)
            dismiss()
        } catch {
            self.error = CodingAIErrorText.from(error, fallback: "Could not send your change. Try again.")
        }
        busy = false
    }
}

struct NativeGHErrorNote: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 4)
            if let retry { Button("Try again", action: retry).controlSize(.small) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }
}

struct NativeGHKeyValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}
