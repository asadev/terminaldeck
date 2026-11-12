import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One response surface for MCP forms, Codex questions and Claude's AskUserQuestion.
struct NativeChatElicitationCard: View {
    let request: NativeRPCValue
    let disabled: Bool
    let answer: (Bool, NativeRPCValue) -> Void
    @State private var text: [String: String] = [:]
    @State private var selected = NativeRPCValue.object([])
    @State private var error: String?
    @State private var validating = false
    private var isURL: Bool { request["input"]["mode"].string == "url" }
    private var fields: [BackendChatElicitation.Field] { BackendChatElicitation.fields(request) }
    private var empty: Bool { BackendChatElicitation.isEmptyForm(request) }
    private var supported: Bool { isURL || empty || BackendChatElicitation.usesFields(request) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(BackendChatElicitation.title(request)).font(.headline)
            if let message = request["input"]["message"].string {
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            if isURL {
                if let url = BackendChatElicitation.authURL(request) {
                    Link("Open sign-in page", destination: url)
                    Text("After signing in, choose Continue.").font(.caption).foregroundStyle(.secondary)
                } else { Text("The sign-in link is invalid. Choose Don't allow.").foregroundStyle(.red) }
            } else if !supported {
                Text("This request uses a form we cannot display yet. Choose Don't allow and ask the AI to use simpler questions.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(fields) { field in fieldView(field) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if validating { ProgressView().controlSize(.small); Text("Checking answer…").font(.caption) }
                Spacer()
                NativeSessionButton(empty || isURL || !supported ? "Don't allow" : "Cancel") { answer(false, .object([])) }.buttonStyle(.bordered)
                NativeSessionButton(isURL ? "Continue" : empty ? "Allow" : "Send answer", action: submit).buttonStyle(.borderedProminent)
                    .disabled(!supported || (isURL && BackendChatElicitation.authURL(request) == nil))
            }
        }.font(.system(size: 12)).padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .disabled(disabled || validating)
            .onAppear {
                selected = BackendChatElicitation.defaults(request)
                for field in fields where field.choices.isEmpty {
                    if let value = selected[field.id].string { text[field.id] = value }
                    else if let value = selected[field.id].number { text[field.id] = String(value) }
                }
            }
    }

    @ViewBuilder private func fieldView(_ field: BackendChatElicitation.Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.title + (field.required ? "" : " (optional)")).fontWeight(.medium)
            if let detail = field.schema["description"].string { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if !field.choices.isEmpty {
                ForEach(Array(field.choices.enumerated()), id: \.offset) { index, choice in
                    choiceButton(field, value: choice, title: field.choiceTitle(index),
                        detail: field.schema["enumDescriptions"].elements?.dropFirst(index).first?.string)
                }
            } else if field.schema["type"].string == "boolean" {
                HStack {
                    choiceButton(field, value: .bool(true), title: "Allow")
                    choiceButton(field, value: .bool(false), title: "Don't allow")
                }
            }
            if (field.choices.isEmpty && field.schema["type"].string != "boolean") || field.schema["allowCustom"].bool == true {
                let binding = Binding(get: { text[field.id] ?? "" }, set: {
                    text[field.id] = $0
                    if field.schema["type"].string != "array" { selected = selected.removing(field.id) }
                })
                let label = field.choices.isEmpty ? field.title : "Your own answer"
                if field.schema["secret"].bool == true { NativeSessionSecureField(label, text: binding).textFieldStyle(.roundedBorder) }
                else { NativeSessionTextField(label, text: binding).textFieldStyle(.roundedBorder) }
            }
        }
    }
    private func choiceButton(_ field: BackendChatElicitation.Field, value: NativeRPCValue, title: String, detail: String? = nil) -> some View {
        let multiple = field.schema["type"].string == "array"
        let picked = multiple ? selected[field.id].elements?.contains(value) == true : selected[field.id] == value
        return NativeSessionButton {
            if multiple {
                var values = selected[field.id].elements ?? []
                values.removeAll { $0 == value }
                if !picked { values.append(value) }
                selected = values.isEmpty && !field.required ? selected.removing(field.id) : selected.setting(field.id, .array(values))
            } else {
                selected = selected.setting(field.id, value)
                text.removeValue(forKey: field.id)
            }
        } label: {
            HStack(alignment: .top) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.bordered).tint(picked ? Color.accentColor : Color.secondary)
    }
    private func submit() {
        validating = true; error = nil
        Task { @MainActor in
            defer { validating = false }
            do {
                let values = try isURL || empty ? NativeRPCValue.object([]) : BackendChatElicitation.answers(request, text: text, selected: selected)
                try BackendChatQuestions.validate(request, answers: values)
                try await BackendChatElicitation.validate(request, answers: values)
                answer(true, values)
            } catch { self.error = error.localizedDescription }
        }
    }
}
