import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Embed in the task-agent form or the new-session agent section. The host owns saving.
struct NativeAGSAgentSettingsEditor: View {
    @Binding var settings: AGSAgentSettings
    var busy = false
    var availableMCPServers: [String] = []
    @State private var editingHook: AGSCLIHook?
    @State private var serverName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeAGSModelControls(settings: $settings)
            DisclosureGroup("Tools and servers") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Allow only these tools", isOn: Binding(get: { settings.allowedTools != nil }, set: {
                        settings.allowedTools = $0 ? (settings.allowedTools ?? []) : nil
                    }))
                    if settings.provider == "codex" {
                        Text("Codex tool lists accept only MCP tool names, such as mcp__server__tool. Use a permission mode to limit built-in tools; a built-in name here will prevent launch.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if settings.allowedTools != nil {
                        NativeAGSToolsField(label: "Allowed tools", values: Binding(get: { settings.allowedTools ?? [] }, set: { settings.allowedTools = $0 }))
                        Text("An empty list allows no tools. Blocked tools always win.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    NativeAGSToolsField(label: "Blocked tools", values: $settings.deniedTools)
                    mcpServers
                }.padding(.top, 8)
            }
            DisclosureGroup("Agent hooks") {
                cliHooks.padding(.top, 8)
            }
            DisclosureGroup("Environment variables") {
                NativeAGSEnvironmentEditor(values: $settings.environment).padding(.top, 8)
            }
            NativeAGSField(label: "Working folder", help: "Used when a task or session has no folder of its own.") {
                HStack(spacing: 6) {
                    TextField("Optional full folder path", text: Binding(get: { settings.workingFolder ?? "" }, set: { settings.workingFolder = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Agent working folder")
                    Button("Choose…", action: chooseFolder)
                }
            }
            NativeSettingRow(label: "Keep open", help: "Leave this session open after the agent finishes.") {
                Toggle("Keep open", isOn: $settings.keepOpen).labelsHidden().toggleStyle(.switch)
            }
        }
        .disabled(busy)
        .onChange(of: settings.provider) { _, _ in editingHook = nil }
    }

    private var mcpServers: some View {
        let names = Set(availableMCPServers).union(settings.mcpServers.keys).sorted()
        return NativeAGSField(label: "MCP servers", help: "Servers provide extra tools. Unchanged servers follow the app or profile default.") {
            VStack(alignment: .leading, spacing: 6) {
                if names.isEmpty {
                    Text("No servers listed. Add the name of a configured server.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    HStack {
                        Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Picker("\(name) access", selection: Binding(get: {
                            settings.mcpServers[name].map { $0 ? "on" : "off" } ?? "default"
                        }, set: { value in
                            settings.mcpServers[name] = value == "default" ? nil : value == "on"
                        })) {
                            Text("Default").tag("default")
                            Text("On").tag("on")
                            Text("Off").tag("off")
                        }.labelsHidden()
                        if !availableMCPServers.contains(name) {
                            Button("Remove", role: .destructive) { settings.mcpServers.removeValue(forKey: name) }
                        }
                    }
                }
                HStack {
                    TextField("Configured server name", text: $serverName).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("MCP server name")
                    Button("Add server") {
                        guard let name = NativeAGSWords.optional(serverName) else { return }
                        // A new named override starts off until the person chooses On.
                        if settings.mcpServers[name] == nil { settings.mcpServers[name] = false }
                        serverName = ""
                    }.disabled(NativeAGSWords.optional(serverName) == nil)
                }
            }
        }
    }

    private var cliHooks: some View {
        let events = AGSCapabilities.hookEvents(provider: settings.provider)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Runs with this agent's own settings. Commands stay hidden here.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.hooks.isEmpty, editingHook == nil {
                Text(events.isEmpty ? "This agent has no supported CLI hook events." : "No agent hooks added.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(settings.hooks) { hook in
                HStack(spacing: 8) {
                    Toggle(NativeAGSWords.event(hook.event), isOn: Binding(get: {
                        settings.hooks.first(where: { $0.id == hook.id })?.enabled ?? false
                    }, set: { enabled in
                        if let index = settings.hooks.firstIndex(where: { $0.id == hook.id }) { settings.hooks[index].enabled = enabled }
                    })).toggleStyle(.checkbox).disabled(!events.contains(hook.event))
                    Text(events.contains(hook.event) ? "Command hidden" : "Event unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Change") { editingHook = hook }
                    Button("Remove", role: .destructive) {
                        settings.hooks.removeAll { $0.id == hook.id }
                        if editingHook?.id == hook.id { editingHook = nil }
                    }
                }
            }
            if let hook = editingHook {
                NativeAGSCLIHookEditor(hook: hook, provider: settings.provider, events: events, save: { next in
                    if let index = settings.hooks.firstIndex(where: { $0.id == next.id }) { settings.hooks[index] = next }
                    else { settings.hooks.append(next) }
                    editingHook = nil
                }, cancel: { editingHook = nil }).id(hook.id)
            } else if let first = events.first {
                Button("Add hook") { editingHook = AGSCLIHook(event: first, command: "") }.disabled(settings.hooks.count >= 50)
                if settings.hooks.count >= 50 { Text("Up to 50 agent hooks.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        if let path = settings.workingFolder { panel.directoryURL = URL(fileURLWithPath: path) }
        NativeFront.whenPersonActs("main") { if panel.runModal() == .OK, let url = panel.url { settings.workingFolder = url.path }
        }
    }
}

struct NativeAGSModelControls: View {
    @Binding var settings: AGSAgentSettings
    var defaultLabel = "App default"

    var body: some View {
        NativeSettingRow(label: "Model", help: "Use a model name supported by \(NativeAGSWords.provider(settings.provider)).") {
            TextField(defaultLabel, text: Binding(get: { settings.model ?? "" }, set: { settings.model = NativeAGSWords.optional($0) }))
                .textFieldStyle(.roundedBorder).frame(minWidth: 160, maxWidth: 260)
                .accessibilityLabel("Agent model")
        }
        NativeSettingRow(label: "Thinking level", help: "How much thought the agent gives each answer.") {
            NativeAGSOptionPicker(label: "Thinking level", options: AGSCapabilities.efforts(provider: settings.provider), value: $settings.effort, defaultLabel: defaultLabel)
        }
        if settings.provider == "gemini" {
            Text("Thinking levels need an explicit compatible Gemini 3 model. Flash Lite does not support this setting.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        NativeSettingRow(label: "Permission mode", help: "When the agent asks before making changes.") {
            NativeAGSOptionPicker(label: "Permission mode", options: AGSCapabilities.permissionModes(provider: settings.provider), value: $settings.permissionMode, defaultLabel: defaultLabel)
        }
    }
}

private struct NativeAGSCLIHookEditor: View {
    @State private var draft: AGSCLIHook
    let provider: String
    let events: [String]
    let save: (AGSCLIHook) -> Void
    let cancel: () -> Void

    init(hook: AGSCLIHook, provider: String, events: [String], save: @escaping (AGSCLIHook) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: hook)
        self.provider = provider
        self.events = events
        self.save = save
        self.cancel = cancel
    }

    private var maximumTimeout: Int { provider == "codex" && ["SessionEnd", "Interrupt"].contains(draft.event) ? 3 : 120 }
    private var valid: Bool {
        UUID(uuidString: draft.id) != nil && NativeAGSWords.optional(draft.command) != nil
            && draft.command.utf8.count <= 8_000 && !draft.command.contains("\0")
            && (1...maximumTimeout).contains(draft.timeoutSeconds) && events.contains(draft.event)
            && (draft.matcher?.utf8.count ?? 0) <= 500 && !(draft.matcher?.contains("\0") ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeSettingRow(label: "When") {
                Picker("Hook event", selection: $draft.event) {
                    if !events.contains(draft.event) { Text("\(draft.event) (unavailable)").tag(draft.event) }
                    ForEach(events, id: \.self) { Text(NativeAGSWords.event($0)).tag($0) }
                }.labelsHidden()
            }
            NativeAGSField(label: "Match", help: "Optional filter supported by this hook event.") {
                SecureField("Optional match", text: Binding(get: { draft.matcher ?? "" }, set: { draft.matcher = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Hook match, hidden")
            }
            NativeAGSField(label: "Command") {
                SecureField("Command to run", text: $draft.command).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Agent hook command, hidden")
            }
            NativeSettingRow(label: "Time limit") {
                Stepper("\(draft.timeoutSeconds) seconds", value: $draft.timeoutSeconds, in: 1...maximumTimeout)
            }
            if maximumTimeout == 3 { Text("Codex end and interrupt hooks allow up to 3 seconds.").font(.caption).foregroundStyle(.secondary) }
            if draft.command.utf8.count > 8_000 { Text("Keep commands within 8,000 bytes.").font(.caption).foregroundStyle(.red) }
            Toggle("Enabled", isOn: $draft.enabled)
            HStack {
                Button("Save hook") { save(draft) }
                    .disabled(!valid)
                Button("Cancel", action: cancel)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { draft.timeoutSeconds = min(maximumTimeout, max(1, draft.timeoutSeconds)) }
        .onChange(of: draft.event) { _, _ in draft.timeoutSeconds = min(maximumTimeout, max(1, draft.timeoutSeconds)) }
    }
}
