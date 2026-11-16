import SwiftUI
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Settings › Agents, for ONE coding AI (owner, 15 Nov; DESIGN.md section 6): three groups, "Defaults" (Model,
/// Thinking, Permission), "Budgets" (Monthly tokens, Monthly API money, When it runs out, Per task, Warn at) and
/// "Behaviour" (Reuse conversation, When keep-open is off, Extra add-ons, One heavy job at a time). Every row: title,
/// one control, (i). Unset fields say "Default". Bound to a host-owned draft; saving is explicit (the page's top bar).
struct NativeAGSDefaultsEditor: View {
    @Binding var defaults: AGSDefaults
    var busy = false
    /// Last successfully saved hooks (the hooks page's Test needs them).
    var savedHooks: [AGSAppHook] = []
    let testHook: (String) async throws -> String
    var provider = "claude"

    static let defaultWord = "Default"

    var body: some View {
        let settings = providerBinding(provider)
        Group {
            DeckSettingsGroup("Defaults") {
                DeckSettingsRow("Model", info: "Use a model name supported by \(NativeAGSWords.provider(provider)). Empty: the AI's own default.") {
                    NativeSessionTextField(Self.defaultWord, text: Binding(get: { settings.wrappedValue.model ?? "" }, set: { settings.wrappedValue.model = NativeAGSWords.optional($0) }))
                        .textFieldStyle(.plain).modifier(DeckSettingsQuietField()).accessibilityLabel("Agent model")
                }
                DeckSettingsRow("Thinking", info: provider == "gemini"
                                ? "How much thought the agent gives each answer. Thinking levels need an explicit compatible Gemini 3 model. Flash Lite does not support this setting."
                                : "How much thought the agent gives each answer.") {
                    NativeAGSOptionPicker(label: "Thinking", options: AGSCapabilities.efforts(provider: provider), value: settings.effort,
                                          defaultLabel: Self.effortDefaultLabel(provider: provider)).fixedSize()
                }
                DeckSettingsRow("Permission", info: "When the agent asks before making changes.") {
                    NativeAGSOptionPicker(label: "Permission", options: AGSCapabilities.permissionModes(provider: provider), value: settings.permissionMode,
                                          defaultLabel: Self.defaultWord).fixedSize()
                }
            }
            NativeAGSBudgetRows(settings: settings)
            NativeAGSBehaviourRows(settings: settings)
        }
        .disabled(busy)
    }

    private func providerBinding(_ provider: String) -> Binding<AGSAgentSettings> {
        Binding(get: { Self.shown(defaults, provider: provider) }, set: { next in
            var next = next
            next.provider = provider
            defaults.providers[provider] = next
        })
    }

    /// What the form shows for one AI: exactly what is stored. 18 Oct (#516): an unset thinking level stays unset
    /// (the launch applies the app default), so "Default" can be chosen and nothing is written by itself.
    static func shown(_ defaults: AGSDefaults, provider: String) -> AGSAgentSettings {
        var value = defaults.providers[provider] ?? AGSAgentSettings()
        value.provider = provider
        return value
    }

    /// "Default (Extra high)": the level a launch uses when none is chosen here.
    static func effortDefaultLabel(provider: String) -> String {
        AGSCapabilities.defaultEffort(provider: provider).map { defaultWord + " (" + NativeAGSWords.option($0) + ")" } ?? defaultWord
    }
}

/// The efficiency fields of one AI's defaults, split into the page's Budgets and Behaviour groups (the same fields
/// `NativeAGOPTEfficiencyEditor` edits on an agent's own settings).
private struct NativeAGSEfficiencyField {
    @Binding var settings: AGSAgentSettings
    func field<Value>(_ key: WritableKeyPath<AGOPTEfficiencySettings, Value?>) -> Binding<Value?> {
        Binding(get: { settings.efficiency?[keyPath: key] }, set: {
            var next = settings.efficiency ?? AGOPTEfficiencySettings()
            next[keyPath: key] = $0
            settings.efficiency = next
        })
    }
}

private struct NativeAGSBudgetRows: View {
    @Binding var settings: AGSAgentSettings
    private var fields: NativeAGSEfficiencyField { NativeAGSEfficiencyField(settings: $settings) }
    var body: some View {
        DeckSettingsGroup("Budgets") {
            DeckSettingsRow("Monthly tokens", info: "Tokens across this AI's agent tasks this month. Empty: inherited. 0: no budget.") {
                number("Monthly tokens", fields.field(\.agentTokenBudget))
            }
            DeckSettingsRow("Monthly API money", info: "Money in US dollars for API accounts. Plan accounts use tokens. Empty: inherited. 0: no budget.") {
                HStack(spacing: DeckTokens.Spacing.s4) {
                    NativeSessionNumberField(NativeAGSDefaultsEditor.defaultWord, value: fields.field(\.monthlyBudgetUSD), format: .number.grouping(.never))
                        .quietField().modifier(DeckSettingsQuietField()).accessibilityLabel("Monthly API money in USD")
                    Text("USD").foregroundStyle(.secondary)
                }
            }
            DeckSettingsRow("When it runs out", info: "Pause keeps new tasks waiting until you resume the agent.") {
                choice("When it runs out", fields.field(\.onExhaustion), [("warn", "Only warn"), ("pause", "Pause")])
            }
            DeckSettingsRow("Per task", info: "A warning budget in tokens for each task. Empty: inherited. 0: unlimited.") {
                number("Per task", fields.field(\.taskTokenBudget))
            }
            DeckSettingsRow("Warn at", info: "Percentage of the token budget, from 1 to 100. The default is 80%.") {
                HStack(spacing: DeckTokens.Spacing.s4) {
                    NativeSessionNumberField(NativeAGSDefaultsEditor.defaultWord, value: fields.field(\.warningPercent), format: .number.grouping(.never))
                        .quietField().modifier(DeckSettingsQuietField()).accessibilityLabel("Budget warning percentage")
                    Text("%").foregroundStyle(.secondary)
                }
            }
        }
    }
    private func number(_ label: String, _ value: Binding<Int?>) -> some View {
        NativeSessionNumberField(NativeAGSDefaultsEditor.defaultWord, value: value, format: .number.grouping(.never))
            .quietField().modifier(DeckSettingsQuietField()).accessibilityLabel(label)
    }
}

private struct NativeAGSBehaviourRows: View {
    @Binding var settings: AGSAgentSettings
    private var fields: NativeAGSEfficiencyField { NativeAGSEfficiencyField(settings: $settings) }
    var body: some View {
        DeckSettingsGroup("Behaviour") {
            DeckSettingsRow("Reuse conversation", info: "Use the agent's existing conversation when the task, project and saved settings match.") {
                flag("Reuse conversation", fields.field(\.reuseContext), on: "Reuse", off: "Start fresh")
            }
            DeckSettingsRow("When keep-open is off", info: "Keep-open settings take priority. Otherwise, Park stops the agent and keeps its conversation for the next task. Stop ends its session. Waiting agents wake when an event arrives; they never check files or task status in a loop.") {
                choice("When keep-open is off", fields.field(\.completion), [("park", "Park"), ("stop", "Stop")])
            }
            DeckSettingsRow("Extra add-ons", info: "Switch off extra add-ons and their MCP child processes. Terminal Deck's own tools stay available.") {
                flag("Extra add-ons", fields.field(\.addonsOff), on: "Off", off: "On")
            }
            // SETTINGS-TRUTH row 63: the default is On, the value the engine uses when nothing is chosen.
            DeckSettingsRow("One heavy job at a time", info: "Task runs are asked to take one shared lock for builds and tests, so they wait for each other across agents. Sessions you start yourself are not asked.") {
                flag("One heavy job at a time", fields.field(\.serializeHeavyJobs), on: "On", off: "Off", defaultText: NativeAGSDefaultsEditor.defaultWord + " (On)")
            }
        }
    }
}

private func choice(_ label: String, _ value: Binding<String?>, _ options: [(String, String)]) -> some View {
    Picker(label, selection: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })) {
        Text(NativeAGSDefaultsEditor.defaultWord).tag("")
        ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
    }
    .labelsHidden().fixedSize()
}

private func flag(_ label: String, _ value: Binding<Bool?>, on: String, off: String, defaultText: String? = nil) -> some View {
    Picker(label, selection: Binding(get: { value.wrappedValue.map { $0 ? "on" : "off" } ?? "" }, set: {
        value.wrappedValue = $0.isEmpty ? nil : $0 == "on"
    })) {
        Text(defaultText ?? NativeAGSDefaultsEditor.defaultWord).tag("")
        Text(on).tag("on")
        Text(off).tag("off")
    }
    .labelsHidden().fixedSize()
}

/// Settings › Agents › Terminal Deck hooks: run a command or send a web request when something happens. Same rows,
/// editor, Test and Remove as before (they were the foot of the Agents page).
struct NativeAGSAppHooksEditor: View {
    @Binding var defaults: AGSDefaults
    var busy = false
    var savedHooks: [AGSAppHook] = []
    let testHook: (String) async throws -> String
    @State private var editingHook: AGSAppHook?
    @State private var testingID: String?
    @State private var testResults: [String: String] = [:]
    @State private var failedTests = Set<String>()

    static let info = "Run a command or send a web request when something happens in Terminal Deck. New hooks start off. Up to 50 hooks."

    var body: some View {
        DeckSettingsGroup {
            if defaults.hooks.isEmpty, editingHook == nil {
                DeckSettingsRow("No hooks yet")
            }
            ForEach(defaults.hooks) { hook in appHookRow(hook) }
            if let hook = editingHook {
                NativeAGSAppHookEditor(hook: hook, save: { next in
                    if let index = defaults.hooks.firstIndex(where: { $0.id == next.id }) { defaults.hooks[index] = next }
                    else { defaults.hooks.append(next) }
                    testResults.removeValue(forKey: next.id)
                    failedTests.remove(next.id)
                    editingHook = nil
                }, cancel: { editingHook = nil }).id(hook.id)
                    .padding(DeckSettingsLook.rowPadding)
            } else if let event = AGSCapabilities.appEvents.first {
                DeckSettingsButtonRow(title: "+ Add hook") { editingHook = AGSAppHook(event: event) }
                    .disabled(defaults.hooks.count >= 50)
            }
        }
        .disabled(busy)
    }

    private func appHookRow(_ hook: AGSAppHook) -> some View {
        let enabled = Binding(get: { defaults.hooks.first(where: { $0.id == hook.id })?.enabled ?? false }, set: { on in
            if let index = defaults.hooks.firstIndex(where: { $0.id == hook.id }) { defaults.hooks[index].enabled = on }
        })
        return VStack(spacing: 0) {
            DeckSettingsRow(NativeAGSWords.event(hook.event), info: hook.webhook != nil ? "Sends a web request (its address stays hidden)." : "Runs a command (it stays hidden).",
                            state: testingID == hook.id ? "Testing…" : nil) {
                HStack(spacing: DeckTokens.Spacing.s8) {
                    NativeSettingsMoreMenu(label: NativeAGSWords.event(hook.event)) {
                        Button("Test") { test(hook) }.disabled(testingID != nil || editingHook != nil || !canTest(hook))
                        Button("Change") { editingHook = hook }.disabled(testingID != nil)
                        Divider()
                        Button("Remove", role: .destructive) {
                            defaults.hooks.removeAll { $0.id == hook.id }
                            testResults.removeValue(forKey: hook.id)
                            failedTests.remove(hook.id)
                            if editingHook?.id == hook.id { editingHook = nil }
                        }.disabled(testingID != nil)
                    }
                    Toggle("On", isOn: enabled).toggleStyle(.switch).controlSize(.small)
                        .disabled(!AGSCapabilities.appEvents.contains(hook.event) || testingID != nil)
                }
            }
            if let result = testResults[hook.id] {
                DeckSettingsProblem(text: result, warn: failedTests.contains(hook.id))
            }
        }
    }

    private func test(_ hook: AGSAppHook) {
        guard testingID == nil, canTest(hook) else { return }
        testingID = hook.id
        testResults.removeValue(forKey: hook.id)
        failedTests.remove(hook.id)
        Task { @MainActor in
            defer { testingID = nil }
            do {
                let result = try await testHook(hook.id)
                testResults[hook.id] = masked(result.isEmpty ? "Test finished." : result, hook: hook)
            } catch {
                failedTests.insert(hook.id)
                testResults[hook.id] = masked(error.localizedDescription, hook: hook)
            }
        }
    }

    private func canTest(_ hook: AGSAppHook) -> Bool {
        AGSCapabilities.appEvents.contains(hook.event) && savedHooks.contains(hook)
    }

    /// The runner must redact stdout/stderr too; this catches configured values echoed in replies.
    private func masked(_ text: String, hook: AGSAppHook) -> String {
        var values = [hook.command, hook.webhook].compactMap { $0 }
        values += defaults.providers.values.flatMap { Array($0.environment.values) }
        // The codec's one rule: short values such as "1" stay readable (#528).
        let redacted = BackendAGSCodec.masking(.string(text), secrets: values).string ?? text
        return String(redacted.prefix(2_000))
    }
}

private struct NativeAGSAppHookEditor: View {
    @State private var draft: AGSAppHook
    @State private var kind: String
    let save: (AGSAppHook) -> Void
    let cancel: () -> Void

    init(hook: AGSAppHook, save: @escaping (AGSAppHook) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: hook)
        _kind = State(initialValue: hook.webhook == nil ? "command" : "webhook")
        self.save = save
        self.cancel = cancel
    }

    private var valid: Bool {
        guard AGSCapabilities.appEvents.contains(draft.event), UUID(uuidString: draft.id) != nil,
              (1...120).contains(draft.timeoutSeconds) else { return false }
        if kind == "command" {
            let command = draft.command ?? ""
            return NativeAGSWords.optional(command) != nil && command.utf8.count <= 8_000 && !command.contains("\0")
        }
        guard let address = NativeAGSWords.optional(draft.webhook ?? ""),
              address.utf8.count <= 4_000, let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeSettingRow(label: "When") {
                Picker("Terminal Deck event", selection: $draft.event) {
                    if !AGSCapabilities.appEvents.contains(draft.event) { Text("\(draft.event) (unavailable)").tag(draft.event) }
                    ForEach(AGSCapabilities.appEvents, id: \.self) { Text(NativeAGSWords.event($0)).tag($0) }
                }.labelsHidden()
            }
            NativeSettingRow(label: "Action") {
                Picker("Hook action", selection: $kind) {
                    Text("Run a command").tag("command")
                    Text("Send a web request").tag("webhook")
                }.labelsHidden()
            }
            if kind == "command" {
                NativeAGSField(label: "Command") {
                    NativeSessionSecureField("Command to run", text: Binding(get: { draft.command ?? "" }, set: { draft.command = $0 }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Terminal Deck hook command, hidden")
                }
            } else {
                NativeAGSField(label: "Web address", help: "Use an HTTPS address. Any secret in the address stays hidden.") {
                    NativeSessionSecureField("https://…", text: Binding(get: { draft.webhook ?? "" }, set: { draft.webhook = $0 }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Hook web address, hidden")
                }
            }
            NativeSettingRow(label: "Time limit") {
                Stepper("\(draft.timeoutSeconds) seconds", value: $draft.timeoutSeconds, in: 1...120)
            }
            if kind == "command", (draft.command?.utf8.count ?? 0) > 8_000 {
                Text("Keep commands within 8,000 bytes.").font(.caption).foregroundStyle(.red)
            }
            Toggle("Enabled", isOn: $draft.enabled)
            HStack {
                NativeSessionButton("Save hook") {
                    var next = draft
                    if kind == "command" { next.webhook = nil }
                    else { next.command = nil; next.webhook = NativeAGSWords.optional(next.webhook ?? "") }
                    save(next)
                }.disabled(!valid)
                NativeSessionButton("Cancel", action: cancel)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { draft.timeoutSeconds = min(120, max(1, draft.timeoutSeconds)) }
    }

}
