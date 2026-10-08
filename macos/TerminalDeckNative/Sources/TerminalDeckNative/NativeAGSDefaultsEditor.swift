import SwiftUI
import TerminalDeckNativeCore

/// Content for Settings → Agent settings. Bind to a host-owned draft; saving is explicit.
struct NativeAGSDefaultsEditor: View {
    @Binding var defaults: AGSDefaults
    var busy = false
    /// Last successfully saved hooks. A draft must match its saved version before Test can run.
    var savedHooks: [AGSAppHook] = []
    let testHook: (String) async throws -> String
    @State private var editingHook: AGSAppHook?
    @State private var testingID: String?
    @State private var testResults: [String: String] = [:]
    @State private var failedTests = Set<String>()

    var body: some View {
        Group {
            ForEach(["claude", "codex", "gemini"], id: \.self) { provider in
                Section(NativeAGSWords.provider(provider)) {
                    NativeAGSModelControls(settings: providerBinding(provider), defaultLabel: "Agent default")
                }
            }
            Section("Terminal Deck hooks") {
                Text("Run a command or send a web request when something happens in Terminal Deck. New hooks start off.")
                    .font(.callout).foregroundStyle(.secondary)
                if defaults.hooks.isEmpty, editingHook == nil {
                    Text("No Terminal Deck hooks added.").foregroundStyle(.secondary)
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
                } else if let event = AGSCapabilities.appEvents.first {
                    Button("Add hook") { editingHook = AGSAppHook(event: event) }.disabled(defaults.hooks.count >= 50)
                    if defaults.hooks.count >= 50 { Text("Up to 50 Terminal Deck hooks.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .disabled(busy)
    }

    private func providerBinding(_ provider: String) -> Binding<AGSAgentSettings> {
        Binding(get: {
            if let value = defaults.providers[provider] { return value }
            var value = AGSAgentSettings()
            value.provider = provider
            return value
        }, set: { next in
            var next = next
            next.provider = provider
            defaults.providers[provider] = next
        })
    }

    private func appHookRow(_ hook: AGSAppHook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(NativeAGSWords.event(hook.event), isOn: Binding(get: {
                    defaults.hooks.first(where: { $0.id == hook.id })?.enabled ?? false
                }, set: { enabled in
                    if let index = defaults.hooks.firstIndex(where: { $0.id == hook.id }) { defaults.hooks[index].enabled = enabled }
                })).toggleStyle(.checkbox).disabled(!AGSCapabilities.appEvents.contains(hook.event) || testingID != nil)
                Text(hook.webhook != nil ? "Web address hidden" : "Command hidden")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(testingID == hook.id ? "Testing…" : "Test") { test(hook) }
                    .disabled(testingID != nil || editingHook != nil || !canTest(hook))
                    .help(canTest(hook) ? "Run this saved hook once through the app's approval path, even when the hook is off" : "Save this hook before testing")
                Button("Change") { editingHook = hook }.disabled(testingID != nil)
                Button("Remove", role: .destructive) {
                    defaults.hooks.removeAll { $0.id == hook.id }
                    testResults.removeValue(forKey: hook.id)
                    failedTests.remove(hook.id)
                    if editingHook?.id == hook.id { editingHook = nil }
                }.disabled(testingID != nil)
            }
            if testingID == hook.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval or the hook result…").font(.caption).foregroundStyle(.secondary)
                }.accessibilityAddTraits(.updatesFrequently)
            }
            if let result = testResults[hook.id] {
                NativeCodingAINotice(tone: failedTests.contains(hook.id) ? .error : .info, text: result)
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
        var values = [hook.command, hook.webhook].compactMap { $0 }.filter { !$0.isEmpty }
        values += defaults.providers.values.flatMap { Array($0.environment.values) }.filter { !$0.isEmpty }
        let redacted = values.sorted { $0.count > $1.count }.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "••••••••")
        }
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
                    SecureField("Command to run", text: Binding(get: { draft.command ?? "" }, set: { draft.command = $0 }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Terminal Deck hook command, hidden")
                }
            } else {
                NativeAGSField(label: "Web address", help: "Use an HTTPS address. Any secret in the address stays hidden.") {
                    SecureField("https://…", text: Binding(get: { draft.webhook ?? "" }, set: { draft.webhook = $0 }))
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
                Button("Save hook") {
                    var next = draft
                    if kind == "command" { next.webhook = nil }
                    else { next.command = nil; next.webhook = NativeAGSWords.optional(next.webhook ?? "") }
                    save(next)
                }.disabled(!valid)
                Button("Cancel", action: cancel)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { draft.timeoutSeconds = min(120, max(1, draft.timeoutSeconds)) }
    }

}
