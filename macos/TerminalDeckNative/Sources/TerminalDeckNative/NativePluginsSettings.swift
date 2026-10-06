import SwiftUI
import TerminalDeckNativeCore

/// Settings → Plugins, drawn in Swift (web: `settings/sections/PluginsSection.tsx`).
///
/// The same pane: the section's line, any problem, "Adding one" with Show the
/// folder, "What holds it in", then the Plugins group — each plugin with its
/// version and state, summary, note, what it asks for, its tools, the on/off
/// switch, Allow/Change, and Remove with its confirmation. Every control calls
/// the channel the web one calls (`plugins:*`).
struct NativePluginsSettings: View {
    @State private var model = PluginsSettingsModel()

    var body: some View {
        NativeSettingsPage(sectionId: "plugins") {
            // Only when there is something to say: an empty group draws as a gap.
            if model.problem != nil || model.state == nil {
            Section {
                if let problem = model.problem {
                    NativeCodingAINotice(tone: .error, text: problem)
                }
                if model.state == nil {
                    Text("Reading the plugins folder…")
                        .foregroundStyle(.secondary)
                }
            }
            }

            if let state = model.state {
                Section {
                    PluginsExplain(title: "Adding one") {
                        Text("Put a plugin’s folder in \(state.folder). Nothing is ever downloaded for you, and nothing in a new folder runs until you allow it here.")
                        Button("Show the folder") { model.openFolder() }
                            .disabled(model.busy)
                    }
                    PluginsExplain(title: "What holds it in") {
                        Text(state.confinement)
                    }
                }

                Section("Plugins") {
                    if state.plugins.isEmpty {
                        Text("No plugins yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.plugins) { plugin in
                        PluginRow(plugin: plugin, projects: state.projects, model: model)
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// `Explain`: a small title, then its body.
private struct PluginsExplain<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct PluginRow: View {
    let plugin: PluginItem
    let projects: [String]
    let model: PluginsSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(plugin.name).fontWeight(.medium)
                        if !plugin.version.isEmpty { NativeCodingAIBadge(text: plugin.version, quiet: true) }
                        NativeCodingAIBadge(text: plugin.state.words, quiet: true)
                    }
                    if !plugin.summary.isEmpty { note(plugin.summary) }
                    note(plugin.note)
                    if plugin.declared.isEmpty {
                        note(PluginItem.nothingAsked)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(plugin.declared, id: \.self) { capability in
                                Text(plugin.capabilityLine(capability))
                                    .font(.caption)
                                    .foregroundStyle(plugin.granted.contains(capability) ? Color.primary : Color.secondary)
                            }
                        }
                        .accessibilityLabel("What \(plugin.name) asks for")
                    }
                    if let tools = plugin.toolsLine { note(tools) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if plugin.allowed {
                        Toggle(plugin.name, isOn: Binding(get: { plugin.enabled }, set: { model.enable(plugin.id, $0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(model.busy)
                    }
                    if plugin.state != .broken {
                        let editing = model.editing == plugin.id
                        if plugin.allowed {
                            Button(plugin.editLabel(editing: editing)) { model.toggleEditing(plugin.id) }
                                .disabled(model.busy)
                        } else {
                            Button(plugin.editLabel(editing: editing)) { model.toggleEditing(plugin.id) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.busy)
                        }
                    }
                    Button("Remove…", role: .destructive) { model.toggleRemoving(plugin.id) }
                        .disabled(model.busy)
                }
            }

            if model.editing == plugin.id {
                PluginAllowForm(plugin: plugin, projects: projects, model: model)
            }

            if model.removing == plugin.id {
                HStack(spacing: 8) {
                    Text("Remove “\(plugin.name)”? Its folder goes to the Trash, and its data and what it was allowed are forgotten.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Remove", role: .destructive) { model.remove(plugin.id) }
                        .disabled(model.busy)
                    Button("Keep it") { model.removing = nil }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Remove \(plugin.name)")
            }
        }
        .padding(.vertical, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `AllowForm`: a switch per capability, the projects for a per-project one, then Allow…/Save and Cancel.
private struct PluginAllowForm: View {
    let plugin: PluginItem
    let projects: [String]
    let model: PluginsSettingsModel
    @State private var draft: PluginAllowDraft

    init(plugin: PluginItem, projects: [String], model: PluginsSettingsModel) {
        self.plugin = plugin
        self.projects = projects
        self.model = model
        _draft = State(initialValue: PluginAllowDraft(plugin: plugin))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(plugin.declared, id: \.self) { capability in
                Toggle(PluginCatalog.words(capability), isOn: Binding(
                    get: { draft.chosen.contains(capability) },
                    set: { draft.setCapability(capability, $0) }
                ))
                .toggleStyle(.switch)
                .disabled(model.busy)

                if PluginCatalog.projectScoped.contains(capability), draft.chosen.contains(capability) {
                    VStack(alignment: .leading, spacing: 4) {
                        if projects.isEmpty {
                            Text("This app has no projects yet, so there is nothing to choose.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(projects, id: \.self) { project in
                            Toggle(isOn: Binding(get: { draft.places.contains(project) }, set: { draft.setProject(project, $0) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(PluginCatalog.projectName(project))
                                    Text(project).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .disabled(model.busy)
                        }
                    }
                    .padding(.leading, 16)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Which projects")
                }
            }
            if plugin.declared.isEmpty {
                Text("It asks for nothing; allowing it lets it run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(draft.buttonLabel) { model.allow(plugin.id, draft.input) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || draft.missingPlace)
                    .help(draft.buttonHelp ?? "")
                Button("Cancel") { model.editing = nil }
                    .disabled(model.busy)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - The model

@MainActor
@Observable
final class PluginsSettingsModel {
    var state: PluginsState?
    var problem: String?
    var busy = false
    var editing: String?
    var removing: String?
    @ObservationIgnored private var changed: EngineSubscription?

    func start() {
        load()
        changed = EngineBridge.shared.on("plugins:changed") { [weak self] _ in self?.load() }
    }

    func stop() {
        changed?.cancel()
        changed = nil
    }

    func load() {
        Task {
            do {
                let next = PluginsState.from(CodingAIJSON(try await EngineBridge.shared.invoke("plugins:state")))
                problem = next == nil ? PluginsResult.unreadable : nil
                if let next { state = next }
            } catch {
                problem = CodingAIErrorText.from(error, fallback: "Could not read the plugins folder.")
            }
        }
    }

    func toggleEditing(_ id: String) { editing = editing == id ? nil : id }
    func toggleRemoving(_ id: String) { removing = removing == id ? nil : id }

    func openFolder() {
        Task { _ = try? await EngineBridge.shared.invoke("plugins:open-folder") }
    }

    func enable(_ id: String, _ on: Bool) {
        run("plugins:enable", [id, on]) { _ in }
    }

    func allow(_ id: String, _ input: [String: Any]) {
        run("plugins:allow", [id, input]) { [weak self] ok in if ok { self?.editing = nil } }
    }

    func remove(_ id: String) {
        run("plugins:remove", [id]) { [weak self] _ in self?.removing = nil }
    }

    /// `run`: one change at a time, its answer's state taken, its refusal shown.
    private func run(_ channel: String, _ args: [Any?], then: @escaping (Bool) -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = PluginsResult.from(CodingAIJSON(try await EngineBridge.shared.invoke(channel, args)))
                if let next = result.state { state = next }
                problem = result.ok ? nil : (result.message ?? "That did not go through.")
                then(result.ok)
            } catch {
                problem = CodingAIErrorText.from(error, fallback: "That did not go through.")
                then(false)
            }
        }
    }
}
