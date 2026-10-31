import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

struct NativeChatElicitationCard: View {
    let request: NativeRPCValue
    let disabled: Bool
    let answer: (Bool, NativeRPCValue) -> Void
    @State private var text: [String: String] = [:]
    @State private var selected = NativeRPCValue.object([])
    @State private var json = "{}"
    @State private var error: String?
    @State private var validating = false
    private var isURL: Bool { request["input"]["mode"].string == "url" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isURL ? "Tool server sign-in" : "Tool server form").font(.headline)
            if let server = request["input"]["serverName"].string { Text(server).font(.caption).foregroundStyle(.secondary) }
            Text(request["input"]["message"].string ?? "This tool server needs your response.").fixedSize(horizontal: false, vertical: true)
            if isURL {
                if let url = BackendChatElicitation.authURL(request) {
                    Text(url.absoluteString).textSelection(.enabled).font(.caption).lineLimit(3)
                    Link("Open sign-in page", destination: url)
                    Text("Continue sends your response. The tool server checks whether sign-in is complete.").font(.caption).foregroundStyle(.secondary)
                } else { Text("The sign-in link is invalid. Decline this request.").foregroundStyle(.red) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if BackendChatElicitation.usesFields(request) {
                            ForEach(BackendChatElicitation.fields(request)) { field in fieldView(field) }
                        } else {
                            Text("Form answers (JSON)").font(.caption)
                            TextEditor(text: $json).font(.system(.body, design: .monospaced)).frame(minHeight: 120)
                            DisclosureGroup("Requested format") {
                                Text(request["input"]["requestedSchema"].compact).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }.padding(.trailing, 5)
                }.frame(maxHeight: 260)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if validating { ProgressView().controlSize(.small); Text("Checking answers…").font(.caption) }
                Spacer()
                Button("Decline") { answer(false, .object([])) }.buttonStyle(.bordered)
                Button(isURL ? "Continue" : "Submit answers", action: submit).buttonStyle(.borderedProminent)
                    .disabled(isURL && BackendChatElicitation.authURL(request) == nil)
            }
        }.font(.system(size: 12)).padding(12).background(.background, in: .rect(cornerRadius: 12))
            .disabled(disabled || validating)
            .onAppear {
                selected = BackendChatElicitation.defaults(request)
                for field in BackendChatElicitation.fields(request) where field.choices.isEmpty {
                    if let value = selected[field.id].string { text[field.id] = value }
                    else if let value = selected[field.id].number { text[field.id] = String(value) }
                }
                json = selected.compact
            }
    }

    @ViewBuilder private func fieldView(_ field: BackendChatElicitation.Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.title + (field.required ? " *" : " (optional)")).fontWeight(.medium)
            if let detail = field.schema["description"].string { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if !field.choices.isEmpty {
                if field.schema["type"].string == "array" {
                    ForEach(Array(field.choices.enumerated()), id: \.offset) { index, choice in
                        Toggle(field.choiceTitle(index), isOn: Binding(get: { selected[field.id].elements?.contains(choice) == true }, set: { on in
                            var values = selected[field.id].elements ?? []
                            values.removeAll { $0 == choice }; if on { values.append(choice) }
                            selected = values.isEmpty && !field.required ? selected.removing(field.id) : selected.setting(field.id, .array(values))
                        })).toggleStyle(.checkbox)
                    }
                } else {
                    Picker(field.title, selection: Binding(get: { selected[field.id].compact }, set: { raw in
                        selected = raw == "null" ? selected.removing(field.id) : selected.setting(field.id, (try? .parseJSON(Data(raw.utf8))) ?? .missing)
                    })) {
                        Text("Choose…").tag("null")
                        ForEach(Array(field.choices.enumerated()), id: \.offset) { index, choice in
                            Text(field.choiceTitle(index)).tag(choice.compact)
                        }
                    }.labelsHidden()
                }
            } else if field.schema["type"].string == "boolean" {
                Picker(field.title, selection: Binding(get: { selected[field.id].bool.map { $0 ? "true" : "false" } ?? "" }, set: {
                    selected = selected.setting(field.id, $0.isEmpty ? .missing : .bool($0 == "true"))
                })) { Text("Choose…").tag(""); Text("Yes").tag("true"); Text("No").tag("false") }.labelsHidden()
            } else {
                TextField(field.title, text: Binding(get: { text[field.id] ?? "" }, set: {
                    text[field.id] = $0; selected = selected.removing(field.id)
                })).textFieldStyle(.roundedBorder)
                if let format = field.schema["format"].string { Text("Format: " + format).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func submit() {
        validating = true; error = nil
        Task { @MainActor in
            defer { validating = false }
            do {
                let values = try isURL ? NativeRPCValue.object([]) : BackendChatElicitation.usesFields(request)
                    ? BackendChatElicitation.answers(request, text: text, selected: selected)
                    : NativeRPCValue.parseJSON(Data(json.utf8), maximumBytes: 65_536)
                try await BackendChatElicitation.validate(request, answers: values)
                answer(true, values)
            } catch { self.error = error.localizedDescription }
        }
    }
}
