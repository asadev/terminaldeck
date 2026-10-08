import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Small AGS-owned pieces, using the existing native Settings typography.
enum NativeAGSWords {
    static func provider(_ value: String) -> String {
        switch value {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini"
        default: value
        }
    }

    static func option(_ value: String) -> String {
        switch value {
        case "default": "Ask before changes"
        case "acceptEdits": "Allow file edits"
        case "plan": "Plan only"
        case "bypassPermissions": "Skip permission checks"
        case "dontAsk": "Never ask"
        case "read-only": "Read only"
        case "workspace-write": "Allow project changes"
        case "danger-full-access": "Full access"
        case "auto_edit": "Allow file edits"
        case "yolo": "Skip permission checks"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        case "max": "Maximum"
        case "ultra": "Ultra"
        default: value
        }
    }

    static func optional(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func event(_ value: String) -> String {
        switch value {
        case "session.started", "SessionStart": "Session started"
        case "session.finished", "SessionEnd": "Session finished"
        case "task.finished": "Task finished"
        case "alert.raised": "Alert raised"
        case "receiver.event": "Receiver event"
        case "PreToolUse", "BeforeTool": "Before a tool runs"
        case "PostToolUse", "AfterTool": "After a tool runs"
        case "PostToolUseFailure": "After a tool fails"
        case "PermissionRequest": "When permission is needed"
        case "UserPromptSubmit": "When a prompt is sent"
        case "Stop": "When the agent stops"
        case "Interrupt": "When the agent is interrupted"
        case "SubagentStart": "Child agent started"
        case "SubagentStop": "Child agent stopped"
        case "PreCompact", "PreCompress": "Before conversation is shortened"
        case "PostCompact": "After conversation is shortened"
        case "Notification": "Agent notification"
        case "BeforeAgent": "Before the agent answers"
        case "AfterAgent": "After the agent answers"
        case "BeforeModel": "Before the model answers"
        case "AfterModel": "After the model answers"
        case "BeforeToolSelection": "Before tools are selected"
        default: value
        }
    }

    static func tools(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.components(separatedBy: .newlines)
            .compactMap(optional).filter { seen.insert($0).inserted }
    }

    static func validEnvironmentName(_ value: String) -> Bool {
        let reserved: Set<String> = ["HOME", "PATH", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES"]
        return value.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,79}$", options: .regularExpression) != nil
            && !reserved.contains(value) && !value.hasPrefix("GEMINI_CLI_") && !value.hasPrefix("CLAUDE_CODE_")
    }
}

struct NativeAGSOptionPicker: View {
    let label: String
    let options: [String]
    @Binding var value: String?
    var defaultLabel = "App default"

    private var choices: [String] {
        var seen = Set<String>()
        return options.filter { seen.insert($0).inserted }
    }

    var body: some View {
        if choices.isEmpty, value == nil {
            Text("Uses the agent's default").foregroundStyle(.secondary)
        } else {
            Picker(label, selection: Binding(get: { value ?? "" }, set: { value = NativeAGSWords.optional($0) })) {
                Text(defaultLabel).tag("")
                if let value, !choices.contains(value) {
                    Text("\(value) (unavailable)").tag(value)
                }
                ForEach(choices, id: \.self) { Text(NativeAGSWords.option($0)).tag($0) }
            }
            .labelsHidden()
        }
    }
}

struct NativeAGSField<Content: View>: View {
    let label: String
    var help: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout.weight(.medium))
            content()
            if let help {
                Text(help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeAGSToolsField: View {
    let label: String
    @Binding var values: [String]
    @State private var text: String

    init(label: String, values: Binding<[String]>) {
        self.label = label
        _values = values
        _text = State(initialValue: values.wrappedValue.joined(separator: "\n"))
    }

    var body: some View {
        NativeAGSField(label: label, help: "One tool per line. Include the full name for tools from an MCP server.") {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 120)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel(label)
                .onChange(of: text) { _, next in values = NativeAGSWords.tools(next) }
                .onChange(of: values) { _, next in
                    if NativeAGSWords.tools(text) != next { text = next.joined(separator: "\n") }
                }
        }
    }
}

/// Values stay masked while entering or changing them. No secret appears in row summaries.
struct NativeAGSEnvironmentEditor: View {
    @Binding var values: [String: String]
    @State private var editing = false
    @State private var originalName: String?
    @State private var name = ""
    @State private var value = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var collision: Bool { trimmedName != originalName && values[trimmedName] != nil }
    private var valid: Bool {
        NativeAGSWords.validEnvironmentName(trimmedName) && !collision && !value.contains("\0")
            && value.utf8.count <= 16_384 && (originalName != nil || values.count < 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if values.isEmpty, !editing {
                Text("No environment variables added.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(values.keys.sorted(), id: \.self) { key in
                HStack(spacing: 8) {
                    Text(key).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text("••••••••").foregroundStyle(.secondary).accessibilityLabel("Value hidden")
                    Spacer(minLength: 8)
                    Button("Change") { start(key) }
                    Button("Remove", role: .destructive) {
                        values.removeValue(forKey: key)
                        if originalName == key { cancel() }
                    }
                }
            }
            if editing {
                NativeAGSField(label: "Variable name", help: "Up to 80 letters, numbers and underscores. Start with a letter or underscore. System and CLI settings cannot be replaced.") {
                    TextField("e.g. PROJECT_TOKEN", text: $name).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled().accessibilityLabel("Environment variable name")
                }
                NativeAGSField(label: "Value") {
                    SecureField("Value", text: $value).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Environment variable value, hidden")
                }
                if collision { Text("That name is already used.").font(.caption).foregroundStyle(.red) }
                if !trimmedName.isEmpty, !NativeAGSWords.validEnvironmentName(trimmedName) {
                    Text("Choose a valid variable name that is not reserved by the system or agent.").font(.caption).foregroundStyle(.red)
                }
                if value.utf8.count > 16_384 || value.contains("\0") {
                    Text("This value is too long or has an invalid character.").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Save variable") {
                        guard valid else { return }
                        if let originalName { values.removeValue(forKey: originalName) }
                        values[trimmedName] = value
                        cancel()
                    }.disabled(!valid)
                    Button("Cancel", action: cancel)
                }
            } else {
                Button("Add variable") { start(nil) }.disabled(values.count >= 100)
                if values.count >= 100 { Text("Up to 100 variables per agent.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func start(_ key: String?) {
        originalName = key
        name = key ?? ""
        value = key.flatMap { values[$0] } ?? ""
        editing = true
    }

    private func cancel() {
        editing = false
        originalName = nil
        name = ""
        value = ""
    }
}
