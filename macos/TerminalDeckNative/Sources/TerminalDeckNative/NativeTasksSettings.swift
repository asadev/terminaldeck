import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Settings → Tasks (settings/sections/TasksSection.tsx): the agents that take
// work from a CRM, and the CRMs allowed to send it. Plain words: every field
// says what it does in one line, and a refusal from the engine is shown as the
// sentence it was written as, beside the form it is about.

struct NativeTasksSettings: View {
    private let store = TasksStore.shared
    @State private var busy = false

    var body: some View {
        NativeSettingsPage(sectionId: "tasks") {
            switch store.phase {
            case .loading:
                Section { Text("Reading the task settings…").foregroundStyle(.secondary) }
            case .failed:
                Section { NativeCodingAINotice(tone: .error, text: "The app answered with something this page cannot read.") }
            case .ready(let state):
                TaskAgentsGroup(state: state, busy: busy, run: run)
                CrmConnectionsGroup(state: state, busy: busy, run: run)
            }
        }
        .onAppear { store.start() }
    }

    /// Run one change and keep what came back. The caller shows a refusal beside its own form.
    private func run(_ work: @escaping @MainActor () async -> TasksResult) async -> TasksResult {
        busy = true
        let result = await work()
        busy = false
        store.adopt(result)
        return result
    }
}

typealias TasksSettingsRun = @MainActor (@escaping @MainActor () async -> TasksResult) async -> TasksResult

// MARK: - Small pieces

/// One labelled box, its control, and the line under it — with what keeps it beside the name.
private struct TaskSettingField<Control: View, Tag: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var tag: Tag
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(.callout.weight(.medium))
                tag
            }
            control
            if let help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TaskSettingField where Tag == EmptyView {
    init(label: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(label: label, help: help, tag: { EmptyView() }, control: control)
    }
}

/// Beside a field: whether the chosen coding agent applies it, only reads it, or cannot take it.
private struct SupportTag: View {
    let provider: String?
    let setting: AgentSetting

    var body: some View {
        let support = AgentCapabilities.support(provider, setting)
        Text(support.tag)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(support == .enforced ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14)))
            .foregroundStyle(support == .enforced ? Color.accentColor : .secondary)
            .help(AgentCapabilities.how(provider, setting))
    }
}

private struct QuietBadge: View {
    let text: String
    var on = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14)))
            .foregroundStyle(on ? Color.accentColor : .secondary)
    }
}

private struct LinesBox: View {
    @Binding var text: String
    var placeholder = ""
    var mono = false
    let disabled: Bool
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
            }
            TextEditor(text: $text)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 160)
                .padding(.vertical, 4)
                .disabled(disabled)
                .accessibilityLabel(label)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }
}

/// Copy, then "Copied" for a moment.
private struct TasksCopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            let board = NSPasteboard.general
            board.clearContents()
            copied = board.setString(value, forType: .string)
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }
}

/// A secret shown once: the value, Copy, and "I've copied it".
private struct OnceSecret: View {
    let note: String
    let value: String
    let onSeen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeCodingAINotice(tone: .warn, text: note)
            HStack(spacing: 8) {
                Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                TasksCopyButton(value: value)
                Button("I’ve copied it", action: onSeen)
            }
        }
    }
}

/// A list picked from what is installed: the choices so far as pills, and a menu of
/// the rest. A saved name not found on this Mac is kept and marked.
private struct ChoicePicker<Tag: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var tag: Tag
    let choices: [InventoryChoice]
    let selected: [String]
    let disabled: Bool
    var missing = "not found here"
    let onChange: ([String]) -> Void

    var body: some View {
        let known = Dictionary(choices.map { ($0.value, $0) }, uniquingKeysWith: { a, _ in a })
        let left = choices.filter { !selected.contains($0.value) }
        TaskSettingField(label: label, help: help, tag: { tag }) {
            VStack(alignment: .leading, spacing: 6) {
                if !selected.isEmpty {
                    FieldFlow(spacing: 4) {
                        ForEach(selected, id: \.self) { value in
                            HStack(spacing: 4) {
                                Text(known[value] != nil ? value : "\(value) (\(missing))")
                                Button { onChange(selected.filter { $0 != value }) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                    .buttonStyle(.plain).disabled(disabled)
                                    .accessibilityLabel("Remove \(value)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(known[value] == nil ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.14)))
                            .help(known[value]?.label ?? "\(value): \(missing)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(label): chosen")
                }
                Menu(left.isEmpty ? (choices.isEmpty ? "Nothing found" : "All chosen") : "Add…") {
                    ForEach(left, id: \.value) { choice in
                        Button(choice.where.isEmpty ? choice.label : "\(choice.label) (\(choice.where))") { onChange(selected + [choice.value]) }
                    }
                }
                .fixedSize()
                .disabled(disabled || left.isEmpty)
                .accessibilityLabel(label)
            }
        }
    }
}

// MARK: - Agents

private struct TaskAgentsGroup: View {
    let state: TasksState
    let busy: Bool
    let run: TasksSettingsRun
    /// Which form is open: an agent's id, "new", or none.
    @State private var editing: String?
    @State private var removing: String?
    @State private var problem: String?
    @State private var importMessage: String?

    var body: some View {
        let current = TasksRules.pickableAgents(state.agents)
        let archived = state.agents.filter { $0.status == .archived }
        Section {
            if current.isEmpty && editing != "new" {
                Text("No agents yet. Add one for each kind of work, such as building or reviewing.").foregroundStyle(.secondary)
            }
            ForEach(current) { agent in
                agentRow(agent)
            }
            if !archived.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Archived").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(archived) { agent in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(agent.name).font(.body.weight(.medium))
                                }
                                Text(agent.role).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if let line = TasksSettingsText.statusLine(agent.status, at: agent.statusAt) {
                                    Text(line).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Restore") { Task { await lifecycle(agent.id, .restore) } }.disabled(busy)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Archived agents")
            }
            if editing == "new" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New agent").font(.callout.weight(.semibold))
                    AgentFormView(agent: nil, agents: state.agents, busy: busy, problem: problem, onSave: save, onCancel: { open(nil) })
                }
            } else {
                HStack {
                    Button("Add agent") { open("new") }.buttonStyle(.borderedProminent).disabled(busy || state.agents.count >= TasksLimits.maxAgents)
                    Button("Import from .claude/agents/…", action: importAgents).disabled(busy)
                    Spacer()
                    Text("\(state.agents.count) of \(TasksLimits.maxAgents) agents").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
            if editing == nil, let problem { NativeCodingAINotice(tone: .error, text: problem) }
        } header: {
            Text("Task agents")
        }
    }

    @ViewBuilder private func agentRow(_ agent: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name).font(.body.weight(.medium))
                        if let badge = TasksSettingsText.statusBadge(agent.status) { QuietBadge(text: badge) }
                    }
                    Text(agent.role).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(TasksSettingsText.agentSummary(agent)).font(.caption).foregroundStyle(.secondary)
                    if let stack = TasksSettingsText.agentStackSummary(agent) { Text(stack).font(.caption).foregroundStyle(.secondary) }
                    if let line = TasksSettingsText.statusLine(agent.status, at: agent.statusAt) { Text(line).font(.caption).foregroundStyle(.secondary) }
                    Text(TAGAgentSettings.reviewerLabel(agent, agents: state.agents)).font(.caption).foregroundStyle(.secondary)
                    if let source = agent.sourceFile {
                        NativeTAGSourceStatus(source: source, status: agent.syncStatus, syncedAt: agent.syncedAt, error: agent.syncError)
                    }
                }
                Spacer()
                Button(editing == agent.id ? "Close" : "Change") { open(editing == agent.id ? nil : agent.id) }.disabled(busy)
            }
            if editing == agent.id {
                AgentFormView(agent: agent, agents: state.agents, busy: busy, problem: problem, onSave: save, onCancel: { open(nil) })
                HStack(spacing: 8) {
                    if agent.status == .paused {
                        Button("Resume") { Task { await lifecycle(agent.id, .resume) } }.disabled(busy).help("Takes new work again")
                    } else {
                        Button("Pause") { Task { await lifecycle(agent.id, .pause) } }.disabled(busy).help("Takes no new work; what it is running carries on")
                    }
                    Button("Archive") { Task { await lifecycle(agent.id, .archive) } }.disabled(busy).help("Kept, and offered nowhere until restored")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Whether \(agent.name) takes work")
                if removing == agent.id {
                    HStack(spacing: 8) {
                        Text("Remove “\(agent.name)”? CRM identities that point at it are cleared too.").font(.callout)
                        Spacer()
                        Button("Remove", role: .destructive) { Task { await remove(agent.id) } }.disabled(busy)
                        Button("Keep it") { removing = nil }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Remove \(agent.name)")
                } else {
                    Button("Remove…", role: .destructive) { removing = agent.id }.disabled(busy)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func open(_ which: String?) {
        editing = which
        removing = nil
        problem = nil
    }

    private func save(_ draft: AgentDraft) {
        Task {
            let agents = state.agents
            let result = await run {
                switch AgentForm.payload(draft, agents: agents) {
                case .failure(let p): return .refused(p.message)
                case .success(let profile):
                    var payload = profile.wire
                    if SourceNamespace.agentSettingsEnabled, let settings = draft.agsSettings, let revision = draft.agsRevision {
                        do { payload["ags"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)); payload["agsRevision"] = Double(revision) }
                        catch { return .refused("The complete agent settings could not be encoded. Your draft was kept.") }
                    }
                    return await TasksStore.shared.call("tasks:agent-save", [payload], refusal: "This build cannot save agents.")
                }
            }
            if result.ok { open(nil) } else { problem = result.message ?? "That did not save." }
        }
    }

    private func importAgents() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder or its .claude/agents folder. Changes to its agent files stay in sync while Terminal Deck is open."
        panel.prompt = "Import agents"
        panel.showsHiddenFiles = true
        NativeFront.whenPersonActs("main") { guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        problem = nil
        importMessage = "Importing agents…"
        Task {
            let result = await run { await TasksStore.shared.call("tasks:agents-import", [folder], refusal: "This build cannot import Claude Code agents.") }
            if result.ok {
                open(nil)
                importMessage = result.message ?? "Agents imported. Their source files stay in sync while Terminal Deck is open."
            } else {
                importMessage = nil
                problem = result.message ?? "The agents could not be imported."
            }
        }
        }
    }

    private func remove(_ id: String) async {
        let result = await run { await TasksStore.shared.call("tasks:agent-remove", [id]) }
        if result.ok { open(nil) } else { problem = result.message ?? "That did not go through." }
    }

    /// Pause, resume, archive or restore. The form stays open on a refusal, which is said beside it.
    private func lifecycle(_ id: String, _ action: AgentAction) async {
        let result = await run { await TasksStore.shared.call("tasks:agent-status", [id, action.rawValue], refusal: "This build cannot pause or archive agents.") }
        if result.ok {
            if action == .archive { open(nil) } else { problem = nil }
        } else {
            problem = result.message ?? "That did not go through."
        }
    }
}

private struct AgentFormView: View {
    let agent: AgentProfile?
    let agents: [AgentProfile]
    let busy: Bool
    let problem: String?
    let onSave: (AgentDraft) -> Void
    let onCancel: () -> Void
    @State private var draft: AgentDraft
    @State private var found: AgentInventory?
    @State private var ags = NativeAGSSettingsModel()

    init(agent: AgentProfile?, agents: [AgentProfile], busy: Bool, problem: String?, onSave: @escaping (AgentDraft) -> Void, onCancel: @escaping () -> Void) {
        self.agent = agent
        self.agents = agents
        self.busy = busy
        self.problem = problem
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: AgentDraft(agent))
    }

    var body: some View {
        let provider: String? = draft.provider.isEmpty ? nil : draft.provider
        let supportsAGS = SourceNamespace.agentSettingsEnabled && AGSCapabilities.providers.contains(draft.provider.isEmpty ? ags.settings.provider : draft.provider)
        let canEnforce = AgentCapabilities.enforces(provider, .blockedTools)
        let tools = found?.tools ?? TasksSettingsText.defaultTools(provider)
        let whereLine = found.map { "Found for \($0.account)." } ?? "Nothing was read from this Mac, so only what is saved is listed."
        var providers = TasksSettingsText.lookupAgents
        if !draft.provider.isEmpty && !providers.contains(where: { $0.id == draft.provider }) { providers.append((draft.provider, draft.provider)) }
        let account = draft.account.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    TaskSettingField(label: "Name") { box("Name", \.name, max: 60) }
                    TaskSettingField(label: "Role or description") {
                        LinesBox(text: Binding(get: { draft.role }, set: { draft.role = String($0.prefix(4000)) }),
                                 placeholder: "What this agent does", disabled: busy, label: "Role or description")
                    }
                }
                GridRow {
                    TaskSettingField(label: "Coding agent") {
                        Picker("Coding agent", selection: $draft.provider) {
                            Text("App default").tag("")
                            ForEach(providers, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden().disabled(busy)
                    }
                    TaskSettingField(label: "Account") { box("Default", \.account, max: 80, label: "Account") }
                }
                if !supportsAGS {
                    GridRow {
                        TaskSettingField(label: "Model", help: AgentCapabilities.how(provider, .model),
                                         tag: { SupportTag(provider: provider, setting: .model) }) {
                            box("Default", \.model, max: 80, label: "Model", off: !can(provider, .model) && draft.model.isEmpty)
                        }
                        TaskSettingField(label: "Effort", help: helpFor(provider, .effort, "Set when the session starts. A refusal is shown on the task."),
                                         tag: { SupportTag(provider: provider, setting: .effort) }) {
                            Picker("Effort", selection: $draft.effort) {
                                Text("Agent default").tag("")
                                ForEach(EFFORT_CHOICES.filter { !SourceNamespace.agentSettingsEnabled || $0.id == "auto" || AGSCapabilities.efforts(provider: provider ?? "claude").contains($0.id) }, id: \.id) {
                                    Text($0.label).tag($0.id)
                                }
                                if SourceNamespace.agentSettingsEnabled, !draft.effort.isEmpty, draft.effort != "auto", !AGSCapabilities.efforts(provider: provider ?? "claude").contains(draft.effort) {
                                    Text("\(draft.effort) (unavailable)").tag(draft.effort)
                                }
                            }.labelsHidden().disabled(busy || (!can(provider, .effort) && draft.effort.isEmpty))
                        }
                    }
                }
                GridRow {
                    TaskSettingField(label: "Tasks at once", help: "1 to \(TasksLimits.maxConcurrent)") { box("", \.maxConcurrent, max: 4, label: "Tasks at once") }
                    TaskSettingField(label: "Longest run", help: "Minutes. 0 means no limit.") { box("", \.maxRunMinutes, max: 6, label: "Longest run") }
                }
                GridRow {
                    TaskSettingField(label: "Keep open after finishing", help: "Timed keep-open is capped at 24 hours. 0 closes it at once.") {
                        NativeTAGKeepOpenControl(draft: $draft, busy: busy)
                    }
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            if supportsAGS {
                NativeAGSAgentSettingsEditor(settings: $ags.settings, busy: busy || ags.busy || !ags.loaded, availableMCPServers: [])
                Text("The complete account-specific MCP inventory and private CLI launch plan are not installed yet. Unverified session overrides are refused when starting, without changing the CLI's global settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NativeTAGProfileSettings(draft: $draft, agents: agents, busy: busy, showsScalars: !supportsAGS)
            TaskSettingField(label: "Instructions", help: TasksSettingsText.instructionsHelp(provider, file: draft.instructionsFile,
                                                                                         claudeAgent: draft.claudeAgent.isEmpty ? nil : draft.claudeAgent),
                       tag: {
                           if draft.claudeAgent.isEmpty { SupportTag(provider: provider, setting: .instructions) }
                           else { QuietBadge(text: "Task brief") }
                       }) {
                LinesBox(text: Binding(get: { draft.instructions }, set: { draft.instructions = String($0.prefix(TasksLimits.maxInstructionsChars)) }),
                         placeholder: "Optional, e.g. Work on a branch. Run the tests before you finish.",
                         disabled: busy || (!can(provider, .instructions) && draft.instructions.isEmpty), label: "Instructions")
            }
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    ChoicePicker(label: "Tools to prefer", help: helpFor(provider, .toolAdvice, "Asked of the agent in its brief, not enforced."),
                                 tag: { SupportTag(provider: provider, setting: .toolAdvice) }, choices: tools, selected: draft.toolsPreferred,
                                 disabled: busy || (!can(provider, .toolAdvice) && draft.toolsPreferred.isEmpty)) { draft.toolsPreferred = $0 }
                    ChoicePicker(label: "Tools to avoid",
                                 help: helpFor(provider, .toolAdvice, canEnforce ? "Also a request, not a lock. To stop a tool, block it below." : "Also a request, not a lock."),
                                 tag: { SupportTag(provider: provider, setting: .toolAdvice) }, choices: tools, selected: draft.toolsAvoided,
                                 disabled: busy || (!can(provider, .toolAdvice) && draft.toolsAvoided.isEmpty)) { draft.toolsAvoided = $0 }
                }
            }
            ChoicePicker(label: "Skills",
                         help: helpFor(provider, .skillSelection, draft.skillsOff
                                       ? "All skills are switched off below, so none are named in its brief."
                                       : "\(TasksSettingsText.skillsHelp(provider)) A request: the agent cannot be limited to only these. Nothing is installed. \(whereLine)"),
                         tag: { SupportTag(provider: provider, setting: .skillSelection) }, choices: found?.skills ?? [], selected: draft.skills,
                         disabled: busy || ((!can(provider, .skillSelection) || draft.skillsOff) && draft.skills.isEmpty),
                         missing: "not in a skill folder") { draft.skills = $0 }
            if !supportsAGS {
                Text("Enforced by Claude Code").font(.callout.weight(.medium))
                Text(canEnforce ? "Claude Code itself refuses these tools. Another coding agent is not started with them set." : "Choose Claude Code to enforce these limits, or leave them empty.")
                    .font(.caption).foregroundStyle(.secondary)
                ChoicePicker(label: "Block these tools", help: "Off unless you choose some. Nothing is ever allowed from here.",
                             tag: { SupportTag(provider: provider, setting: .blockedTools) }, choices: tools, selected: draft.blockedTools,
                             disabled: busy || (!canEnforce && draft.blockedTools.isEmpty)) { draft.blockedTools = $0 }
            }
            NativeSettingRow(label: "Turn all skills off",
                             help: "\(AgentCapabilities.support(provider, .skillsOff).tag): starts Claude Code with no skills at all.",
                             more: AgentCapabilities.how(provider, .skillsOff)) {
                Toggle("Turn all skills off", isOn: $draft.skillsOff)
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(busy || (!canEnforce && !draft.skillsOff))
            }
            TaskSettingField(label: "Check command",
                       help: "When set, a task is only marked complete after this command passes in the project. When empty, \(BRAND_ASSISTANT) checks the result.") {
                TextField("Check command", text: Binding(get: { draft.verifyCommand }, set: { draft.verifyCommand = String($0.prefix(500)) }), prompt: Text("Optional, e.g. npm test"))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
                    .disabled(busy)
                    .accessibilityLabel("Check command")
            }
            if let problem { NativeCodingAINotice(tone: .error, text: problem) }
            if supportsAGS, let problem = ags.problem { NativeCodingAINotice(tone: .error, text: problem) }
            HStack(spacing: 8) {
                Button(agent == nil ? "Add agent" : "Save") {
                    var submitted = draft
                    if supportsAGS, ags.loaded, let revision = ags.revision {
                        var settings = ags.settings
                        settings.keepOpen = draft.keepAliveUntilClose
                        submitted.provider = settings.provider; submitted.model = settings.model ?? ""; submitted.effort = settings.effort ?? ""
                        submitted.allowedTools = settings.allowedTools; submitted.blockedTools = settings.deniedTools
                        submitted.permissionMode = settings.permissionMode ?? ""; submitted.defaultProject = settings.workingFolder ?? ""
                        submitted.agsSettings = settings; submitted.agsRevision = revision
                    }
                    onSave(submitted)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (supportsAGS && (ags.busy || !ags.loaded)) || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the agent a name first" : "")
                Button("Cancel", action: onCancel)
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .task {
            guard SourceNamespace.agentSettingsEnabled else { return }
            if draft.provider.isEmpty || AGSCapabilities.providers.contains(draft.provider) {
                await ags.start(profile: agent?.id, provider: draft.provider.isEmpty ? "claude" : draft.provider)
                if agent == nil { ags.settings = AGSAgentSettings(provider: draft.provider.isEmpty ? ags.settings.provider : draft.provider) }
            }
        }
        .onChange(of: draft.provider) { _, provider in if SourceNamespace.agentSettingsEnabled, !provider.isEmpty { ags.settings.provider = provider } }
        .onDisappear { ags.stop() }
        // Read again when the account or agent changes: its skills and MCP servers are its own.
        .task(id: "\(draft.provider)|\(account)") {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let input: [String: Any] = ["provider": provider.map { $0 as Any } ?? NSNull(), "account": account.isEmpty ? NSNull() : account]
            let raw = try? await EngineBridge.shared.invoke("tasks:inventory", [input])
            guard !Task.isCancelled else { return }
            found = TasksDecode.inventory(raw)
        }
    }

    private func can(_ provider: String?, _ setting: AgentSetting) -> Bool { AgentCapabilities.support(provider, setting) != .unsupported }

    /// The help line, or what the agent cannot do instead of it.
    private func helpFor(_ provider: String?, _ setting: AgentSetting, _ help: String) -> String {
        can(provider, setting) ? help : AgentCapabilities.how(provider, setting)
    }

    private func box(_ placeholder: String, _ key: WritableKeyPath<AgentDraft, String>, max: Int, label: String? = nil, off: Bool = false) -> some View {
        TextField(label ?? placeholder, text: Binding(get: { draft[keyPath: key] }, set: { draft[keyPath: key] = String($0.prefix(max)) }), prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
            .disabled(busy || off)
            .accessibilityLabel(label ?? placeholder)
    }
}

// MARK: - CRM connections

private struct CrmConnectionsGroup: View {
    let state: TasksState
    let busy: Bool
    let run: TasksSettingsRun
    private static let newKey = "new"
    @State private var open: String?
    @State private var problem: String?
    /// A secret the engine just made, for one connection. Gone once copied or closed.
    @State private var shown: (keyId: String, secret: String)?
    @State private var picked = CrmConnectionsGroup.newKey
    @State private var crmName = ""
    /// The press that makes a key waits for a second, explicit one.
    @State private var confirming = false
    /// A CRM's new access key, shown once.
    @State private var madeKey: (keyId: String, key: String)?

    var body: some View {
        let free = state.keys.filter { key in !state.connections.contains { $0.keyId == key.id } }
        let chosen = picked == Self.newKey || free.contains(where: { $0.id == picked }) ? picked : Self.newKey
        let name = crmName.trimmingCharacters(in: .whitespaces)
        Section {
            if state.connections.isEmpty {
                Text("A CRM sends work here with an access key. Nothing runs until you switch its connection on.").foregroundStyle(.secondary)
            }
            ForEach(state.connections) { connection in
                connectionRow(connection)
            }
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        TaskSettingField(label: "CRM name", help: "Your own name for it, shown here and on its tasks.") {
                            TextField("CRM name", text: Binding(get: { crmName }, set: {
                                confirming = false
                                crmName = String($0.prefix(50))
                            }), prompt: Text("e.g. Sales CRM"))
                            .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading).disabled(busy).accessibilityLabel("CRM name")
                        }
                        TaskSettingField(label: "Signs in with", help: TasksSettingsText.keyHelp(chosen == Self.newKey ? nil : free.first { $0.id == chosen })) {
                            Picker("Signs in with", selection: Binding(get: { chosen }, set: {
                                confirming = false
                                picked = $0
                            })) {
                                Text("A new key just for this CRM").tag(Self.newKey)
                                ForEach(free) { Text(TasksSettingsText.keyOption($0)).tag($0.id) }
                            }
                            .labelsHidden().disabled(busy)
                        }
                    }
                }
                if confirming {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Make a new access key named “\(name) (CRM)”? It is shown once, it can only send tasks, and it can be revoked in Connect an AI app.")
                            .font(.callout)
                        HStack(spacing: 8) {
                            Button("Make the key and connect") { Task { await connectWithNewKey(state: state) } }
                                .buttonStyle(.borderedProminent).disabled(busy)
                            Button("Cancel") { confirming = false }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Make a key for this CRM")
                } else {
                    HStack(spacing: 8) {
                        Button("Connect a CRM") { Task { await connect(chosen) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || name.isEmpty)
                            .help(name.isEmpty ? "Give the CRM a name first" : "")
                        if state.keys.isEmpty {
                            Button("Open Connect an AI app") { AppModel.shared.selectSettingsSection("ai-apps") }
                        }
                    }
                }
            }
            if open == nil, let problem { NativeCodingAINotice(tone: .error, text: problem) }
        } header: {
            Text("CRM connections")
        }
    }

    @ViewBuilder private func connectionRow(_ connection: CrmConnection) -> some View {
        let key = state.keys.first { $0.id == connection.keyId }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(connection.name ?? "Unnamed CRM").font(.body.weight(.medium))
                        QuietBadge(text: connection.enabled ? "On" : "Off", on: connection.enabled)
                    }
                    Text(TasksSettingsText.connectionSummary(connection)).font(.caption).foregroundStyle(.secondary)
                    Text(TasksSettingsText.keyLine(key, name: key?.name ?? "a removed key")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(open == connection.keyId ? "Close" : "Change") { toggle(open == connection.keyId ? nil : connection.keyId) }.disabled(busy)
            }
            if open == connection.keyId {
                if let madeKey, madeKey.keyId == connection.keyId {
                    OnceSecret(note: "Copy this CRM’s access key now. It is shown only this once. The CRM sends it with each task; it cannot use anything else on this Mac.",
                               value: madeKey.key) { self.madeKey = nil }
                }
                ConnectionEditorView(connection: connection, agents: state.agents, busy: busy, problem: problem,
                                     secret: shown?.keyId == connection.keyId ? shown?.secret : nil,
                                     onSecretSeen: { shown = nil },
                                     onSave: { patch in await save(connection.keyId, patch) },
                                     onRemove: { Task { await remove(connection.keyId) } })
            }
        }
        .padding(.vertical, 2)
    }

    private func toggle(_ which: String?) {
        open = which
        problem = nil
        if which == nil || (shown != nil && shown?.keyId != which) { shown = nil }
    }

    /// Save one change, keep any new secret to show once, and say a refusal beside it.
    private func save(_ keyId: String, _ patch: [String: Any]) async -> Bool {
        let result = await run { await TasksStore.shared.call("tasks:connection-save", [keyId, patch]) }
        if let secret = result.secret { shown = (keyId, secret) }
        problem = result.ok ? nil : (result.message ?? "That did not save.")
        return result.ok
    }

    private func connect(_ chosen: String) async {
        let name = crmName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            problem = "Give the CRM a name first."
            return
        }
        problem = nil
        if chosen == Self.newKey {
            confirming = true
            return
        }
        // Made switched off, with nobody allowed, and a fresh signing secret on this one answer.
        if await save(chosen, ["name": name]) {
            crmName = ""
            open = chosen
        }
    }

    /// The owner's second press: make the CRM's own key, and the connection with it.
    private func connectWithNewKey(state: TasksState) async {
        confirming = false
        let before = Set(state.connections.map(\.keyId))
        let name = crmName.trimmingCharacters(in: .whitespaces)
        let result = await run { await TasksStore.shared.call("tasks:connection-create", [["name": name, "confirmed": true] as [String: Any]]) }
        guard result.ok, let made = result.state?.connections.first(where: { !before.contains($0.keyId) }) else {
            problem = result.message ?? "That did not go through."
            return
        }
        crmName = ""
        if let key = result.key { madeKey = (made.keyId, key) }
        if let secret = result.secret { shown = (made.keyId, secret) }
        open = made.keyId
    }

    private func remove(_ keyId: String) async {
        let result = await run { await TasksStore.shared.call("tasks:connection-remove", [keyId]) }
        if result.ok { toggle(nil) } else { problem = result.message ?? "That did not go through." }
    }
}

private struct ConnectionEditorView: View {
    let connection: CrmConnection
    let agents: [AgentProfile]
    let busy: Bool
    let problem: String?
    /// The signing secret, only on the answer that made it.
    let secret: String?
    let onSecretSeen: () -> Void
    let onSave: ([String: Any]) async -> Bool
    let onRemove: () -> Void
    @State private var draft: ConnectionDraft
    @State private var rotating = false
    @State private var removing = false
    /// What to fix before this form can be sent, said beside it like a refusal.
    @State private var unfinished: String?
    @State private var saved = false

    init(connection: CrmConnection, agents: [AgentProfile], busy: Bool, problem: String?, secret: String?, onSecretSeen: @escaping () -> Void,
         onSave: @escaping ([String: Any]) async -> Bool, onRemove: @escaping () -> Void) {
        self.connection = connection
        self.agents = agents
        self.busy = busy
        self.problem = problem
        self.secret = secret
        self.onSecretSeen = onSecretSeen
        self.onSave = onSave
        self.onRemove = onRemove
        _draft = State(initialValue: ConnectionDraft(connection))
    }

    var body: some View {
        let statuses = ConnectionForm.lines(draft.statuses)
        let incomplete = connection.enabled && (connection.allowedSenders.isEmpty || connection.folders.isEmpty)
        VStack(alignment: .leading, spacing: 12) {
            NativeSettingRow(label: "On", help: connection.enabled ? "This CRM can give work to your agents." : "Nothing runs until this is on.") {
                Toggle("On", isOn: Binding(get: { connection.enabled }, set: { next in Task { _ = await onSave(["enabled": next]) } }))
                    .toggleStyle(.switch).labelsHidden().disabled(busy)
            }
            if incomplete { NativeCodingAINotice(tone: .warn, text: "Add your CRM user id and a project folder below, or every task is refused.") }

            VStack(alignment: .leading, spacing: 6) {
                Text("Signing secret").font(.callout.weight(.medium))
                if let secret {
                    OnceSecret(note: "Copy the signing secret now. It is shown only this once. Your CRM uses it to check each update came from this Mac.",
                               value: secret, onSeen: onSecretSeen)
                } else if rotating {
                    HStack(spacing: 8) {
                        Text("Make a new secret? The old one stops working right away.").font(.callout)
                        Spacer()
                        Button("Make a new secret", role: .destructive) {
                            rotating = false
                            Task { _ = await onSave(["rotateSecret": true]) }
                        }
                        .disabled(busy)
                        Button("Keep the old one") { rotating = false }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Make a new secret")
                } else {
                    HStack(spacing: 8) {
                        Text(connection.hasEventsSecret ? "Secret set." : "No secret yet.").font(.caption).foregroundStyle(.secondary)
                        Button("Make a new secret") {
                            if connection.hasEventsSecret { rotating = true } else { Task { _ = await onSave(["rotateSecret": true]) } }
                        }
                        .disabled(busy)
                    }
                }
            }

            TaskSettingField(label: "CRM name", help: "Your own name for it, shown here and on its tasks.") { text("e.g. Sales CRM", \.name, max: 60, label: "CRM name") }
            TaskSettingField(label: "Events address", help: "Where status changes and comments are sent. It has to start with https://.") {
                text("https://…", \.eventsUrl, max: 2000, label: "Events address")
            }
            TaskSettingField(label: "Allowed senders", help: "Only these CRM users can give work to these agents. Put only your own CRM user id here. One per line.") {
                LinesBox(text: edit(\.allowedSenders), disabled: busy, label: "Allowed senders")
            }
            TaskSettingField(label: "\(BRAND_ASSISTANT)’s CRM identity id", help: "The CRM user that stands for \(BRAND_ASSISTANT). Work given to it is handed to the right agent.") {
                text("", \.hootIdentity, max: 200, mono: true, label: "\(BRAND_ASSISTANT)’s CRM identity id")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Agent identities").font(.callout.weight(.medium))
                Text("The CRM user that stands for each agent.").font(.caption).foregroundStyle(.secondary)
                if agents.isEmpty {
                    Text("Add an agent above first.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(draft.identities.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 8) {
                            TextField("CRM identity id", text: Binding(get: { row.identity }, set: { setIdentity(index, identity: $0) }), prompt: Text("CRM identity id"))
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading).disabled(busy)
                                .accessibilityLabel("CRM identity id")
                            Picker("Agent", selection: Binding(get: { row.agentId }, set: { setIdentity(index, agentId: $0) })) {
                                Text("Choose an agent…").tag("")
                                // Archived agents are offered nowhere — except as the one this row already names.
                                ForEach(agents.filter { $0.status != .archived || $0.id == row.agentId }) { agent in
                                    let badge = TasksSettingsText.statusBadge(agent.status)
                                    Text(badge.map { "\(agent.name) (\($0.lowercased()))" } ?? agent.name).tag(agent.id)
                                }
                            }
                            .labelsHidden().disabled(busy)
                            .accessibilityLabel("Agent")
                            Button("Remove") {
                                saved = false
                                draft.identities.remove(at: index)
                            }
                            .disabled(busy)
                        }
                    }
                    Button("Add an identity") {
                        saved = false
                        draft.identities.append(ConnectionDraft.Identity(identity: "", agentId: ""))
                    }
                    .disabled(busy)
                }
            }
            TaskSettingField(label: "Allowed project folders", help: "Full folder paths, one per line. Work anywhere else is refused.") {
                LinesBox(text: edit(\.folders), placeholder: "/Users/you/Projects/site", disabled: busy, label: "Allowed project folders")
            }
            TaskSettingField(label: "Hand-off limit", help: "How many times agents may pass one task on, 1 to \(TasksLimits.maxHops).") {
                text("", \.maxHops, max: 3, label: "Hand-off limit").frame(maxWidth: 80)
            }
            TaskSettingField(label: "CRM statuses", help: "Spelt exactly as your CRM spells them, one per line.") {
                LinesBox(text: edit(\.statuses), disabled: busy, label: "CRM statuses")
            }
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    statusSelect(\.initial, "New tasks start as", optional: false, statuses)
                    statusSelect(\.completed, "Counts as complete", optional: false, statuses)
                }
                GridRow {
                    statusSelect(\.onStarted, "When an agent starts", optional: true, statuses)
                    statusSelect(\.onVerified, "After a checked finish", optional: true, statuses)
                }
                GridRow {
                    statusSelect(\.onBlocked, "When it is stuck", optional: true, statuses)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            if let line = unfinished ?? problem { NativeCodingAINotice(tone: .error, text: line) }
            HStack(spacing: 8) {
                Button("Save") {
                    switch ConnectionForm.patch(draft) {
                    case .failure(let p):
                        unfinished = p.message
                    case .success(let patch):
                        unfinished = nil
                        Task { saved = await onSave(patch.wire) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                if saved { Text("Saved.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !removing { Button("Remove…", role: .destructive) { removing = true }.disabled(busy) }
            }
            if removing {
                HStack(spacing: 8) {
                    Text("Remove this connection? The CRM can no longer send work here.").font(.callout)
                    Spacer()
                    Button("Remove", role: .destructive, action: onRemove).disabled(busy)
                    Button("Keep it") { removing = false }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Remove this connection")
            }
        }
        .padding(.vertical, 4)
    }

    private func edit(_ key: WritableKeyPath<ConnectionDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] }, set: {
            saved = false
            draft[keyPath: key] = $0
        })
    }

    private func text(_ placeholder: String, _ key: WritableKeyPath<ConnectionDraft, String>, max: Int, mono: Bool = false, label: String) -> some View {
        TextField(label, text: Binding(get: { draft[keyPath: key] }, set: {
            saved = false
            draft[keyPath: key] = String($0.prefix(max))
        }), prompt: Text(placeholder))
        .font(mono ? .system(.body, design: .monospaced) : .body)
        .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
        .disabled(busy)
        .accessibilityLabel(label)
    }

    private func setIdentity(_ index: Int, identity: String? = nil, agentId: String? = nil) {
        guard draft.identities.indices.contains(index) else { return }
        saved = false
        if let identity { draft.identities[index].identity = identity }
        if let agentId { draft.identities[index].agentId = agentId }
    }

    private func statusSelect(_ key: WritableKeyPath<ConnectionDraft, String>, _ label: String, optional: Bool, _ statuses: [String]) -> some View {
        let value = draft[keyPath: key]
        return TaskSettingField(label: label) {
            Picker(label, selection: Binding(get: { statuses.contains(value) ? value : "" }, set: {
                saved = false
                draft[keyPath: key] = $0
            })) {
                if optional {
                    Text("Comment only").tag("")
                } else if !statuses.contains(value) {
                    Text("Choose…").tag("")
                }
                ForEach(statuses, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .disabled(busy)
        }
    }
}
