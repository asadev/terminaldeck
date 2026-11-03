import SwiftUI
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor @Observable final class NativeAPIAccounts {
    static let shared = NativeAPIAccounts()
    @ObservationIgnored private var keyWriter: (@MainActor (String, String) async throws -> Void)?
    private(set) var busy: Set<String> = []
    private(set) var problem: String?
    var requestedEditorID: String?
    var available: Bool { keyWriter != nil }
    private init() {}
    func configure(_ writer: @escaping @MainActor (String, String) async throws -> Void) { keyWriter = writer }
    private func invoke(_ channel: String, _ value: NativeRPCValue) async throws -> NativeRPCValue {
        try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke(channel, [value.foundation]))
    }
    func save(_ draft: NativeAPIAccountDraft, account: CodingAIAccount?, pendingID: String?, created: (String) -> Void) async throws {
        guard let keyWriter else { throw BackendAccountFailure("The API account store is not ready.") }
        if !draft.key.isEmpty {
            try BackendAPIAccountKeychain.validate(draft.key)
            guard !draft.name.contains(draft.key), !draft.endpoint.contains(draft.key), !draft.model.contains(draft.key), !draft.workspace.contains(draft.key) else {
                throw BackendAccountFailure("Keep the API key in the secure key field only.")
            }
        }
        let slot = account?.id ?? pendingID ?? "adding"
        guard !busy.contains(slot) else { return }
        busy.insert(slot); defer { busy.remove(slot) }
        var input = draft.metadata
        if let id = account?.id ?? pendingID { input = .object((input.fields ?? []).filter { $0.key != "name" }); input = input.setting("id", .string(id)) }
        let value = try await invoke(account == nil && pendingID == nil ? "profiles:api:add" : "profiles:api:update", input)
        let id = try value["id"].requireString("API account id", nonempty: true)
        created(id)
        if !draft.key.isEmpty { try await keyWriter(id, draft.key) }
        changed()
    }
    func check(_ id: String) {
        guard !busy.contains(id) else { return }
        busy.insert(id); problem = nil
        Task {
            defer { busy.remove(id); changed() }
            do { _ = try await invoke("profiles:api:check", .object([.init("id", .string(id))])) }
            catch { problem = error.localizedDescription }
        }
    }
    /// `closing`: the account's open sessions, ended first (Close them and remove).
    func remove(_ id: String, closing: [String] = []) {
        guard !busy.contains(id) else { return }
        busy.insert(id); problem = nil
        Task {
            defer { busy.remove(id); changed() }
            do {
                let result = try await NativeCodingAIStore.closeThenRemove(closing) {
                    try await invoke("profiles:api:remove", .object([.init("id", .string(id))]))
                }
                problem = result["warning"].string
            } catch { problem = error.localizedDescription }
        }
    }
    private func changed() {
        NativeCodingAIStore.shared.refreshAll()
        NativeCodingAIPages.announceAccountsChanged()
    }
    static func status(_ account: CodingAIAccount) -> String {
        let state: String = switch account.apiCheckState {
        case "valid": "Valid"
        case "invalid": "Invalid key"
        case "no-access": "No access"
        case "unavailable": "API settings unavailable"
        default: account.apiConfigured ? "Not checked" : "Needs key"
        }
        // #169: the provider's own reason ("API key expired") follows, not only "No access".
        guard ["invalid", "no-access"].contains(account.apiCheckState ?? ""), let detail = account.apiCheckDetail, !detail.isEmpty else { return state }
        return state + ": " + detail
    }
}

/// This draft is intentionally not Codable. Only metadata crosses an RPC boundary.
struct NativeAPIAccountDraft {
    var provider = "claude"
    var name = ""
    var key = ""
    var endpoint = ""
    var model = ""
    var workspace = ""
    var compatible = false
    var local = false
    var bearer = false
    var kind: BackendAPIAccountRecord.Kind {
        switch provider {
        case "codex": compatible ? (local ? .compatibleLocal : .compatible) : .openai
        case "gemini": .gemini
        default: bearer ? .anthropicToken : .anthropic
        }
    }
    var metadata: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("kind", .string(kind.rawValue)), .init("model", model.isEmpty ? .null : .string(model)),
            .init("baseURL", endpoint.isEmpty ? .null : .string(endpoint))]
        if provider == "claude" { fields.append(.init("workspaceID", .string(workspace))) }
        if !name.isEmpty { fields.append(.init("name", .string(name))) }
        return .object(fields)
    }
}

struct NativeAPIAccountEditor: View {
    let account: CodingAIAccount?
    let done: () -> Void
    @State private var draft: NativeAPIAccountDraft
    @State private var problem: String?
    @State private var pendingID: String?
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss
    init(account: CodingAIAccount? = nil, provider: String = "claude", done: @escaping () -> Void = {}) {
        self.account = account; self.done = done
        var draft = NativeAPIAccountDraft(provider: account?.provider ?? provider)
        if let account {
            draft.name = account.name; draft.endpoint = account.apiBaseURL ?? ""; draft.model = account.apiModel ?? ""; draft.workspace = account.apiWorkspaceID ?? ""
            draft.compatible = ["compatible", "compatibleLocal"].contains(account.apiKind ?? "")
            draft.local = account.apiKind == "compatibleLocal"; draft.bearer = account.apiKind == "anthropicToken"
        }
        _draft = State(initialValue: draft)
    }
    private var changedConnection: Bool {
        guard let account else { return true }
        return draft.kind.rawValue != account.apiKind || (draft.endpoint.isEmpty ? draft.kind.defaultBaseURL : draft.endpoint) != account.apiBaseURL
    }
    private var saving: Bool { NativeAPIAccounts.shared.busy.contains(account?.id ?? pendingID ?? "adding") }
    private var canSave: Bool {
        NativeAPIAccounts.shared.available && !saving &&
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (draft.kind == .compatibleLocal || (!draft.key.isEmpty || (account?.apiConfigured == true && !changedConnection))) &&
        (!draft.compatible || (!draft.endpoint.isEmpty && !draft.model.isEmpty))
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("AI", selection: $draft.provider) {
                    Text("Claude").tag("claude"); Text("Codex").tag("codex"); Text("Gemini").tag("gemini")
                }.disabled(account != nil || pendingID != nil)
                TextField("Account name", text: $draft.name).disabled(account != nil || pendingID != nil)
                if draft.provider == "codex" {
                    Toggle("OpenAI-compatible (Responses)", isOn: $draft.compatible)
                    if draft.compatible { Toggle("No key (local server)", isOn: $draft.local) }
                }
                if draft.kind != .compatibleLocal {
                    SecureField(account == nil ? "API key" : "New API key", text: $draft.key)
                        .textContentType(.password)
                }
                if draft.provider == "claude" {
                    Toggle("Gateway bearer token", isOn: $draft.bearer)
                }
                if draft.provider == "claude" || draft.compatible {
                    TextField("Base URL", text: $draft.endpoint, prompt: Text(draft.provider == "claude" ? "https://api.anthropic.com" : "https://provider.example/v1"))
                }
                if draft.provider == "claude" {
                    TextField("Workspace ID (optional)", text: $draft.workspace, prompt: Text("wrkspc_…"))
                    Text("Needed for a personal or service-account key that is not scoped to one workspace. Find it on platform.claude.com/settings/workspaces (starts with wrkspc_).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                TextField(draft.compatible ? "Default model ID" : "Default model (optional)", text: $draft.model)
                if draft.provider == "gemini" {
                    Text(BackendAPIAccountRecord.geminiShellNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let problem { Text(problem).foregroundStyle(DeckTokens.bad).fixedSize(horizontal: false, vertical: true) }
                if !NativeAPIAccounts.shared.available { Text("The API account store is not ready.").foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { draft.key = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(account == nil && pendingID == nil ? "Add account" : "Save") {
                    problem = nil
                    Task { @MainActor in
                        do { try await NativeAPIAccounts.shared.save(draft, account: account, pendingID: pendingID) { if account == nil { pendingID = $0 } }; saved = true; draft.key = ""; done(); dismiss() }
                        catch { problem = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(!canSave)
            }.padding(20)
        }
        .frame(minWidth: 420, minHeight: 390)
        .interactiveDismissDisabled(saving)
        .onChange(of: draft.provider) { _, _ in draft.key = ""; draft.endpoint = ""; draft.model = ""; draft.workspace = ""; draft.compatible = false; draft.local = false; draft.bearer = false }
        .onChange(of: draft.kind) { _, _ in draft.key = "" }
        .onChange(of: draft.compatible) { _, value in if !value && draft.provider == "codex" { draft.endpoint = ""; draft.local = false } }
        .onDisappear { draft.key = ""; if !saved, account == nil, let pendingID { NativeAPIAccounts.shared.remove(pendingID) } }
    }
}

struct NativeAPIAccountActions: View {
    let account: CodingAIAccount
    @State private var editing = false
    var body: some View {
        HStack(spacing: 8) {
            Button(account.apiKind == "compatibleLocal" ? "Check connection" : "Check key", systemImage: "checkmark.shield") { NativeAPIAccounts.shared.check(account.id) }
            Button { editing = true } label: { Image(systemName: "key") }.help("Edit API connection and key")
        }
        .disabled(NativeAPIAccounts.shared.busy.contains(account.id))
        .sheet(isPresented: $editing) { NativeAPIAccountEditor(account: account) }
        .onAppear { openRequestedEditor() }
        .onChange(of: NativeAPIAccounts.shared.requestedEditorID) { _, _ in openRequestedEditor() }
    }
    private func openRequestedEditor() {
        guard NativeAPIAccounts.shared.requestedEditorID == account.id else { return }
        editing = true
        NativeAPIAccounts.shared.requestedEditorID = nil
    }
}
