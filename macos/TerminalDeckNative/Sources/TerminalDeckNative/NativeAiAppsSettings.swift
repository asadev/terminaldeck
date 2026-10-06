import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Connect an AI app, drawn in Swift (web: `settings/sections/AiAppsSection.tsx`).
///
/// The same pane, top to bottom: the section's line, any problem, From the
/// internet (Internet reach), On this Mac (Local address), then Keys — each key
/// with its level, last use, where it may work, how it is told, and Change,
/// which opens rename, level, ask-first, tasks, folders, notify, pushes and
/// Revoke. New key makes one and shows it once with the setup for each app.
/// Every control calls the channel the web one calls (`ai-apps:*`).
struct NativeAiAppsSettings: View {
    @State private var model = AiAppsSettingsModel()

    var body: some View {
        NativeSettingsPage(sectionId: "ai-apps") {
            // Only when there is something to say: an empty group draws as a gap.
            if model.problem != nil || model.state?.problem != nil || model.state == nil {
            Section {
                if let problem = model.problem {
                    NativeCodingAINotice(tone: .error, text: problem)
                }
                if let warn = model.state?.problem {
                    NativeCodingAINotice(tone: .warn, text: warn)
                }
                if model.state == nil {
                    Text("Reading the keys…").foregroundStyle(.secondary)
                }
            }
            }

            if let state = model.state {
                Section("From the internet") {
                    AiSwitchRow(label: "Internet reach", help: AiAppsLines.internetHelp(state),
                                more: AiAppsLines.internetMore(state),
                                isOn: state.internetOn, disabled: model.busy) { model.setInternet($0) }
                    if state.internetOn, !state.connected, let reason = state.reason {
                        NativeCodingAINotice(tone: .warn, text: reason)
                    }
                }

                Section("On this Mac") {
                    HStack(alignment: .top) {
                        AiLabel(label: "Local address",
                                help: state.localURL ?? "The tools are not running right now.",
                                more: "Apps on this Mac connect here with a key in their settings. The address stays the same after a restart unless something else takes its port.")
                        Spacer(minLength: 8)
                        if let url = state.localURL { AiCopyButton(id: "local", value: url) }
                    }
                    if let moved = state.movedFrom {
                        NativeCodingAINotice(tone: .warn, text: "The address moved from port \(Int(moved)), because something else was using it. Apps you set up before need the new address.")
                    }
                }

                Section("Keys") {
                    if state.keys.isEmpty, !model.making, model.made == nil {
                        Text("No keys yet. Make one for each AI app you connect, so you can take one back without the others.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.keys) { key in
                        AiKeyRow(key: key, state: state, model: model)
                    }
                    if let made = model.made {
                        AiNewKeyMade(made: made, state: state, model: model)
                    } else if model.making {
                        AiNewKeyForm(folders: state.folders, model: model)
                    } else {
                        Button("New key") { model.making = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy)
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .task {
            // "5 minutes ago" moves on while the pane is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.now = Date().timeIntervalSince1970 * 1000
            }
        }
    }
}

// MARK: - Rows

/// A label with its help line and ⓘ (`Row` in the web controls).
private struct AiLabel: View {
    let label: String
    let help: String?
    var more: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                if let more { NativeCodingAIInfo(label: label, text: more) }
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct AiSwitchRow: View {
    let label: String
    let help: String
    let more: String
    let isOn: Bool
    let disabled: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
            AiLabel(label: label, help: help, more: more)
        }
        .toggleStyle(.switch)
        .disabled(disabled)
    }
}

/// `CopyButton`: Copy → Copied (or "Select and copy it by hand") for a moment.
private struct AiCopyButton: View {
    let id: String
    let value: String
    @State private var copied: String?

    var body: some View {
        Button(copied == id ? "Copied" : copied == "\(id):failed" ? "Select and copy it by hand" : "Copy") {
            let board = NSPasteboard.general
            board.clearContents()
            copied = board.setString(value, forType: .string) ? id : "\(id):failed"
            let mark = copied
            Task {
                try? await Task.sleep(for: .milliseconds(1600))
                if copied == mark { copied = nil }
            }
        }
        .help("Copy to the clipboard")
    }
}

private struct AiKeyRow: View {
    let key: AiAccessKey
    let state: AiAppsState
    let model: AiAppsSettingsModel
    @State private var open = false
    @State private var revoking = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(key.name).fontWeight(.medium)
                        NativeCodingAIBadge(text: key.level.label, quiet: true)
                    }
                    note(AiAppsLines.used(key, now: model.now))
                    note(AiAppsLines.scope(key))
                    if let line = AiAppsLines.delivery(state.delivery[key.id], now: model.now) { note(line) }
                    if let line = AiAppsLines.pushes(state.subscriptions[key.id] ?? []) { note(line) }
                }
                Spacer(minLength: 8)
                Button(open ? "Close" : "Change") { open.toggle() }
                    .disabled(model.busy)
            }

            if open {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.callout)
                        HStack {
                            TextField("Name", text: $name)
                                .labelsHidden()
                                .disabled(model.busy)
                                .onChange(of: name) { _, value in if value.count > 60 { name = String(value.prefix(60)) } }
                            Button("Rename") { model.rename(key.id, name.trimmingCharacters(in: .whitespaces)) }
                                .disabled(model.busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                                          || name.trimmingCharacters(in: .whitespaces) == key.name)
                        }
                    }

                    AiLevelPicker(level: Binding(get: { key.level }, set: { model.setLevel(key.id, $0) }), disabled: model.busy)

                    if key.level == .full {
                        AiSwitchRow(label: "Ask me before big changes", help: AiAppsLines.askFirstHelp(key.askFirst),
                                    more: AiAppsLines.askFirstMore, isOn: key.askFirst, disabled: model.busy) { model.setAskFirst(key.id, $0) }
                    }

                    AiSwitchRow(label: "Your tasks", help: AiAppsLines.tasksHelp(key.tasks, limited: key.folders != nil),
                                more: AiAppsLines.tasksMore, isOn: key.tasks, disabled: model.busy) { model.setTasks(key.id, $0) }

                    AiFolderPicker(available: state.folders, chosen: key.folders, busy: model.busy) { model.setFolders(key.id, $0) }

                    AiNotifyBlock(key: key, model: model)

                    if let subs = state.subscriptions[key.id], !subs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pushes this app asked for").font(.callout)
                            ForEach(subs) { sub in
                                HStack(alignment: .top) {
                                    Text(AiAppsLines.subscription(sub, now: model.now))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Button("Stop") { model.stopPush(key.id, sub.id) }.disabled(model.busy)
                                }
                            }
                        }
                    }

                    if revoking {
                        HStack {
                            Text("Revoke “\(key.name)”? The app stops working right away.")
                            Spacer(minLength: 8)
                            Button("Revoke", role: .destructive) { model.revoke(key.id) }.disabled(model.busy)
                            Button("Keep it") { revoking = false }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Revoke \(key.name)")
                    } else {
                        Button("Revoke…", role: .destructive) { revoking = true }.disabled(model.busy)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 2)
        .onAppear { name = key.name }
        .onChange(of: key.name) { _, value in name = value }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// "What it may do": the three levels, and the chosen one's help.
private struct AiLevelPicker: View {
    @Binding var level: AiAccessLevel
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What it may do").font(.callout)
            Picker("What this key may do", selection: $level) {
                ForEach(AiAccessLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(disabled)
            Text(level.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Where it may start sessions": the summary and Choose…, or the ticks with Save/Cancel.
private struct AiFolderPicker: View {
    let available: [String]
    let chosen: [String]?
    let busy: Bool
    let onSave: ([String]?) -> Void
    @State private var editing = false
    @State private var picked: Set<String> = []

    private var all: [String] {
        var seen = Set<String>()
        return ((chosen ?? []) + available).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Where it may start sessions").font(.callout)
            if !editing {
                HStack {
                    Text(AiAppsLines.folders(chosen)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Choose…") {
                        picked = Set(chosen ?? [])
                        editing = true
                    }
                    .disabled(busy || all.isEmpty)
                    .help(all.isEmpty ? "Open a project first" : "")
                }
            } else {
                Text("Tick none for any project. This decides where it may start one, not what that session can touch.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(all, id: \.self) { folder in
                    Toggle(isOn: Binding(get: { picked.contains(folder) },
                                         set: { if $0 { picked.insert(folder) } else { picked.remove(folder) } })) {
                        Text(folder).font(.system(.callout, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(busy)
                }
                HStack {
                    Button("Save") {
                        onSave(picked.isEmpty ? nil : all.filter(picked.contains))
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    Button("Cancel") { editing = false }
                }
            }
        }
        .onChange(of: chosen) { _, value in picked = Set(value ?? []) }
    }
}

/// "Notify this app": Off / When it asks / Webhook, and for a webhook its address, Test and secret.
private struct AiNotifyBlock: View {
    let key: AiAccessKey
    let model: AiAppsSettingsModel
    @State private var mode: AiNotifyMode = .wait
    @State private var url = ""
    @State private var secret: String?
    @State private var tested: (ok: Bool, message: String)?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notify this app").font(.callout)
            Picker("How this app hears about its sessions", selection: Binding(get: { mode }, set: choose)) {
                ForEach(AiNotifyMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.busy)
            Text(mode.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if mode == .webhook {
                HStack {
                    TextField("https://…", text: $url)
                        .labelsHidden()
                        .accessibilityLabel("Notify this app")
                        .disabled(model.busy)
                    Button("Save") { save() }
                        .disabled(model.busy || url.trimmingCharacters(in: .whitespaces).isEmpty
                                  || url.trimmingCharacters(in: .whitespaces) == key.notifyURL)
                    Button(testing ? "Testing…" : "Test") { test() }
                        .disabled(model.busy || testing || key.notifyURL == nil || key.notifyMode != .webhook)
                        .help(key.notifyURL == nil ? "Save an address first" : "Send one signed test notification now")
                }
                if let tested {
                    NativeCodingAINotice(tone: tested.ok ? .info : .warn, text: tested.message)
                }
                if let secret {
                    NativeCodingAINotice(tone: .warn, text: "Copy the signing secret now — it is shown only this once. The receiver uses it to check each post came from this Mac.")
                    HStack {
                        Text(secret).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Spacer(minLength: 8)
                        AiCopyButton(id: "secret-\(key.id)", value: secret)
                    }
                } else if key.hasSecret {
                    HStack {
                        Text("Posts are signed (Standard Webhooks).").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("New secret") {
                            model.newSecret(key.id) { if let shown = $0 { secret = shown } }
                        }
                        .disabled(model.busy)
                    }
                }
            }
        }
        .onAppear {
            mode = key.notifyMode
            url = key.notifyURL ?? ""
        }
        .onChange(of: key.notifyMode) { _, value in mode = value }
        .onChange(of: key.notifyURL) { _, value in url = value ?? "" }
    }

    private func choose(_ next: AiNotifyMode) {
        mode = next
        tested = nil
        if next != .webhook || key.notifyURL != nil {
            model.notify(key.id, mode: next, url: nil) { if let shown = $0 { secret = shown } }
        }
    }

    private func save() {
        tested = nil
        model.notify(key.id, mode: .webhook, url: url.trimmingCharacters(in: .whitespaces)) { if let shown = $0 { secret = shown } }
    }

    private func test() {
        testing = true
        model.testNotify(key.id) { result in
            tested = result
            testing = false
        }
    }
}

// MARK: - A new key

private struct AiNewKeyForm: View {
    let folders: [String]
    let model: AiAppsSettingsModel
    @State private var name = ""
    @State private var level: AiAccessLevel = .work
    @State private var askFirst = true
    @State private var limit: [String]?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New key").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.callout)
                TextField("Which app is this for?", text: $name)
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(make)
                    .onChange(of: name) { _, value in if value.count > 60 { name = String(value.prefix(60)) } }
            }
            AiLevelPicker(level: $level, disabled: false)
            if level == .full {
                AiSwitchRow(label: "Ask me before big changes", help: AiAppsLines.askFirstHelp(askFirst),
                            more: AiAppsLines.askFirstMore, isOn: askFirst, disabled: model.busy) { askFirst = $0 }
            }
            AiFolderPicker(available: folders, chosen: limit, busy: model.busy) { limit = $0 }
            HStack {
                Button("Make key", action: make)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { model.making = false }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { focused = true }
    }

    private func make() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.create(name: trimmed, level: level, askFirst: askFirst, folders: limit)
    }
}

private struct AiNewKeyMade: View {
    let made: AiAppsSettingsModel.Made
    let state: AiAppsState
    let model: AiAppsSettingsModel
    @State private var app: AiApp = .claudeWeb
    @State private var place: AiSetupWhere = .thisMac

    var body: some View {
        let setup = AiAppsSetup.setup(app, key: made.key, name: made.name, internetBase: state.internetBase,
                                      localURL: state.localURL, where: place, channelBridge: state.channelBridge)
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(made.name)” is ready").font(.headline)
            NativeCodingAINotice(tone: .warn, text: "Copy the key now. It is shown only this once — lose it and you make a new one.")
            HStack {
                Text(made.key).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer(minLength: 8)
                AiCopyButton(id: "key", value: made.key)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Set it up in").font(.callout)
                Picker("Which app to set it up in", selection: $app) {
                    ForEach(AiApp.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if !app.web {
                Picker("Where that app runs", selection: $place) {
                    Text("On this Mac").tag(AiSetupWhere.thisMac)
                    Text("On another computer").tag(AiSetupWhere.elsewhere)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if setup.needsInternet, !state.internetOn {
                HStack {
                    Text("This needs internet reach, which is off.")
                    Spacer(minLength: 8)
                    Button("Turn it on") { model.setInternet(true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(setup.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").fixedSize(horizontal: false, vertical: true)
                }
            }

            if let snippet = setup.snippet {
                AiSnippet(text: snippet)
                HStack {
                    AiCopyButton(id: "snippet-\(app.rawValue)-\(place.rawValue)", value: snippet)
                    if app.web {
                        Text("The link holds the key. Treat it like a password.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let missing = setup.missing {
                NativeCodingAINotice(tone: .warn, text: missing)
            }

            if let after = setup.after, setup.snippet != nil {
                Text(after).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let extra = setup.extra {
                VStack(alignment: .leading, spacing: 6) {
                    Text(extra.title).font(.callout.weight(.medium))
                    ForEach(extra.steps, id: \.self) { step in
                        Text(step).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    AiSnippet(text: extra.snippet)
                    AiCopyButton(id: "extra-\(app.rawValue)", value: extra.snippet)
                    Text(extra.caution).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Button("I’ve copied the key") { model.made = nil }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AiSnippet: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - The model

@MainActor
@Observable
final class AiAppsSettingsModel {
    struct Made: Equatable { let key: String; let id: String; let name: String }

    var state: AiAppsState?
    var problem: String?
    var busy = false
    var making = false
    var made: Made?
    var now = Date().timeIntervalSince1970 * 1000
    @ObservationIgnored private var changed: EngineSubscription?

    func start() {
        load()
        changed = EngineBridge.shared.on("ai-apps:changed") { [weak self] _ in self?.load() }
    }

    func stop() {
        changed?.cancel()
        changed = nil
    }

    func load() {
        Task {
            do {
                let next = AiAppsState.from(CodingAIJSON(try await EngineBridge.shared.invoke("ai-apps:state")))
                if next == nil { problem = AiAppsCopy.unreadable }
                state = next
                now = Date().timeIntervalSince1970 * 1000
            } catch {
                problem = CodingAIErrorText.from(error, fallback: "Could not read the keys.")
            }
        }
    }

    func setInternet(_ on: Bool) { run("ai-apps:internet", [on]) }
    func rename(_ id: String, _ name: String) { run("ai-apps:rename", [id, name]) }
    func setLevel(_ id: String, _ level: AiAccessLevel) { run("ai-apps:level", [id, level.rawValue]) }
    func setAskFirst(_ id: String, _ on: Bool) { run("ai-apps:ask-first", [id, on]) }
    func setTasks(_ id: String, _ on: Bool) { run("ai-apps:tasks", [id, on]) }
    func setFolders(_ id: String, _ folders: [String]?) { run("ai-apps:folders", [id, folders.map { $0 as Any } ?? NSNull()]) }
    func revoke(_ id: String) { run("ai-apps:revoke", [id]) }
    func stopPush(_ id: String, _ subscription: String) { run("ai-apps:events-stop", [id, subscription]) }

    func create(name: String, level: AiAccessLevel, askFirst: Bool, folders: [String]?) {
        let input: [String: Any] = ["name": name, "level": level.rawValue, "askFirst": askFirst, "folders": folders.map { $0 as Any } ?? NSNull()]
        run("ai-apps:create", [input]) { [weak self] result in
            guard let self, let result, result.ok, let key = result.key, let id = result.id else { return }
            self.making = false
            self.made = Made(key: key, id: id, name: name)
        }
    }

    func notify(_ id: String, mode: AiNotifyMode, url: String?, secret: @escaping (String?) -> Void) {
        var input: [String: Any] = ["mode": mode.rawValue]
        if let url { input["url"] = url }
        run("ai-apps:notify", [id, input]) { secret($0?.secret) }
    }

    func newSecret(_ id: String, secret: @escaping (String?) -> Void) {
        run("ai-apps:notify-secret", [id]) { secret($0?.secret) }
    }

    /// Test sends one notification; its answer is shown under the row, not as the pane's problem.
    func testNotify(_ id: String, done: @escaping ((ok: Bool, message: String)) -> Void) {
        Task {
            do {
                let result = AiAppsResult.from(CodingAIJSON(try await EngineBridge.shared.invoke("ai-apps:notify-test", [id])))
                done((result.ok, result.message ?? (result.ok ? "Delivered." : "Not delivered.")))
            } catch {
                done((false, CodingAIErrorText.from(error, fallback: "Not delivered.")))
            }
        }
    }

    /// `run`: one change at a time, its answer's state taken, its refusal shown.
    private func run(_ channel: String, _ args: [Any?], then: ((AiAppsResult?) -> Void)? = nil) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = AiAppsResult.from(CodingAIJSON(try await EngineBridge.shared.invoke(channel, args)))
                if let next = result.state { state = next }
                problem = result.ok ? nil : result.message
                then?(result)
            } catch {
                problem = CodingAIErrorText.from(error, fallback: "That did not go through.")
                then?(nil)
            }
        }
    }
}
