import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Tasks → Connected task systems: connect a CRM or tracker by its MCP
/// address and an access token made there, test it (who answers, as whom, what it can
/// do), and choose what happens to changes made here.
struct ConnectedTaskSystemsGroup: View {
    @State private var store = ConnectedTasksStore.shared
    @State private var adding = false
    @State private var open: String?
    var draft = ConnectedTaskSystemDraft()

    init(draft: ConnectedTaskSystemDraft = ConnectedTaskSystemDraft(), open: String? = nil) {
        self.draft = draft
        _open = State(initialValue: open)
    }

    var body: some View {
        Section {
            Text("See and work on tasks that live in another system — your CRM or tracker — on the Tasks page. Terminal Deck reads them through the system’s MCP address, signed in with an access token you make there. The token stays in your Mac’s Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(store.systems) { system in
                ConnectedTaskSystemRow(system: system, open: open == system.id) { open = open == system.id ? nil : system.id }
            }
            if adding || store.systems.isEmpty && draft.prefilled {
                ConnectedTaskSystemForm(draft: draft) { adding = false }
            } else {
                Button("Connect a task system") { adding = true }.buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Connected task systems")
        }
        .onAppear { store.start() }
    }
}

/// What the add form starts with (renders pass a filled one).
struct ConnectedTaskSystemDraft {
    var name = ""
    var url = ""
    var token = ""
    var changes = ConnectedTaskSystem.Changes.ask
    var tested: NativeRPCValue? = nil
    var prefilled = false
}

/// Also shown by the New project guide's Connections page, in its own sheet (GUIDE-CONNECT).
struct ConnectedTaskSystemForm: View {
    @State private var name: String
    @State private var url: String
    @State private var token: String
    @State private var changes: ConnectedTaskSystem.Changes
    @State private var tested: NativeRPCValue?
    @State private var busy = false
    @State private var problem: String?
    let onDone: () -> Void
    private let store = ConnectedTasksStore.shared

    init(draft: ConnectedTaskSystemDraft, onDone: @escaping () -> Void) {
        _name = State(initialValue: draft.name); _url = State(initialValue: draft.url); _token = State(initialValue: draft.token)
        _changes = State(initialValue: draft.changes); _tested = State(initialValue: draft.tested); self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect a task system").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: $name, prompt: Text("e.g. Sales CRM")).textFieldStyle(.roundedBorder).labelsHidden()
                        Text("Shown on every task from it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("MCP address")
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("MCP address", text: $url, prompt: Text("https://…/mcp")).textFieldStyle(.roundedBorder).labelsHidden()
                            .onChange(of: url) { tested = nil }
                        Text("The system’s MCP server address — the one you would give an AI app.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Access token")
                    VStack(alignment: .leading, spacing: 2) {
                        SecureField("Access token", text: $token, prompt: Text("Paste the token")).textFieldStyle(.roundedBorder).labelsHidden()
                            .onChange(of: token) { tested = nil }
                        HStack(spacing: 4) {
                            Text("Make one in the system’s AI-access or API page. It acts as you there.").font(.caption).foregroundStyle(.secondary)
                            if let docs = tested?["docsUrl"].string, let link = URL(string: docs) {
                                Button("Open that page") { NSWorkspace.shared.open(link) }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
                GridRow {
                    Text("Changes made here")
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("Changes made here", selection: $changes) {
                            ForEach(ConnectedTaskSystem.Changes.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Text(Self.changesHelp(changes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let tested { testReport(tested) }
            if let problem { NativeCodingAINotice(tone: .error, text: problem) }
            HStack(spacing: 8) {
                Button("Test connection") { Task { await test() } }.disabled(busy || url.isEmpty || token.isEmpty)
                Button("Connect") { Task { await connect() } }.buttonStyle(.borderedProminent)
                    .disabled(busy || tested == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(tested == nil ? "Test the connection first" : "")
                Button("Cancel") { onDone() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, 4)
    }

    static func changesHelp(_ mode: ConnectedTaskSystem.Changes) -> String {
        switch mode {
        case .ask: "Your own changes in the app ask first. Changes an AI makes follow that AI's own permission setting." // SETTINGS-TRUTH row 66
        case .allow: "Changes you make here are sent straight away."
        case .off: "Tasks are shown; nothing is sent back."
        }
    }

    private func testReport(_ value: NativeRPCValue) -> some View {
        let words = (value["capabilityWords"].elements ?? []).compactMap(\.string)
        let statuses = (value["statuses"].elements ?? []).compactMap(\.string)
        return VStack(alignment: .leading, spacing: 4) {
            Label("\(value["server"]["title"].string ?? value["server"]["name"].string ?? "The system") answered", systemImage: "checkmark.circle.fill")
                .foregroundStyle(TaskTone.completed).font(.callout.weight(.medium))
            if let me = value["me"]["name"].string { Text("Signed in as \(me).").font(.callout) }
            Text("It can: " + words.joined(separator: ", ") + ".").font(.callout).fixedSize(horizontal: false, vertical: true)
            if !statuses.isEmpty { Text("Its statuses: " + statuses.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(TaskTone.completed.opacity(0.08)))
    }

    private func test() async {
        busy = true; problem = nil
        defer { busy = false }
        switch await store.call("test", [["url": url, "token": token]]) {
        case .success(let value): tested = value
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = value["server"]["title"].string ?? "" }
        case .failure(let error): tested = nil; problem = error.message
        }
    }

    private func connect() async {
        busy = true; problem = nil
        defer { busy = false }
        switch await store.call("connect", [["name": name, "url": url, "token": token, "changes": changes.rawValue]]) {
        case .success: token = ""; await store.reload(); onDone()
        case .failure(let error): problem = error.message
        }
    }
}

private struct ConnectedTaskSystemRow: View {
    let system: ConnectedTaskSystem
    let open: Bool
    let toggle: () -> Void
    @State private var busy = false
    @State private var problem: String?
    @State private var newToken = ""
    @State private var removing = false
    private let store = ConnectedTasksStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ConnectedTasksOrigin(name: system.name)
                        Text(system.enabled ? "On" : "Off").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(system.enabled ? TaskTone.completed.opacity(0.15) : Color.primary.opacity(0.08)))
                            .foregroundStyle(system.enabled ? TaskTone.completed : Color.secondary)
                    }
                    Text(system.summary).font(.caption).foregroundStyle(.secondary)
                    Text(system.host + (system.tokenEnding.map { " · token \($0) in the Keychain" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    if !system.capabilityWords.isEmpty {
                        Text("Can " + system.capabilityWords.joined(separator: ", ") + ".").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = system.problem { Text(problem).font(.caption).foregroundStyle(TaskTone.input) }
                }
                Spacer()
                Button(open ? "Close" : "Change", action: toggle).disabled(busy)
            }
            if open { editor }
        }
        .padding(.vertical, 2)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use this connection", isOn: Binding(get: { system.enabled }, set: { on in save(["enabled": on]) })).disabled(busy)
            Picker("Changes made here", selection: Binding(get: { system.changes }, set: { save(["changes": $0.rawValue]) })) {
                ForEach(ConnectedTaskSystem.Changes.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize().disabled(busy)
            if system.can("status"), let done = system.doneStatus {
                Toggle("When an agent finishes a task from here, also mark it \(done)", isOn: Binding(get: { system.markDone }, set: { save(["markDone": $0]) }))
                    .disabled(busy)
            }
            HStack(spacing: 8) {
                SecureField("New access token", text: $newToken, prompt: Text("Paste a new token to replace it")).textFieldStyle(.roundedBorder)
                Button("Replace token") { save(["token": newToken]); newToken = "" }.disabled(busy || newToken.isEmpty)
            }
            if let problem { NativeCodingAINotice(tone: .error, text: problem) }
            HStack(spacing: 8) {
                if removing {
                    Text("Remove \(system.name)? Its token leaves the Keychain; nothing changes in \(system.name).").font(.callout)
                    Button("Remove") { remove() }.buttonStyle(.borderedProminent).tint(.red)
                    Button("Cancel") { removing = false }
                } else {
                    Button("Remove this system…") { removing = true }.disabled(busy)
                }
            }
        }
        .controlSize(.small)
        .padding(.leading, 4)
    }

    private func save(_ patch: [String: Any]) {
        Task {
            busy = true; problem = nil
            defer { busy = false }
            if case .failure(let error) = await store.call("update", [system.id, patch]) { problem = error.message }
            await store.reload()
        }
    }

    private func remove() {
        Task {
            busy = true
            defer { busy = false }
            if case .failure(let error) = await store.call("remove", [system.id]) { problem = error.message; return }
            await store.reload()
        }
    }
}
