import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeTAGKeepOpenControl: View {
    @Binding var draft: AgentDraft
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Until I close it", isOn: $draft.keepAliveUntilClose).disabled(busy)
            if !draft.keepAliveUntilClose {
                TextField("Minutes", text: Binding(get: { draft.keepAliveMinutes }, set: { draft.keepAliveMinutes = String($0.prefix(6)) }))
                    .textFieldStyle(.roundedBorder).disabled(busy).accessibilityLabel("Keep open minutes")
            }
        }
    }
}

/// Extra settings belong to the existing agent form, beside its other controls.
struct NativeTAGProfileSettings: View {
    @Binding var draft: AgentDraft
    let agents: [AgentProfile]
    let busy: Bool
    let showsScalars: Bool
    @State private var allowedText: String

    init(draft: Binding<AgentDraft>, agents: [AgentProfile], busy: Bool, showsScalars: Bool = true) {
        _draft = draft
        self.agents = agents
        self.busy = busy
        self.showsScalars = showsScalars
        _allowedText = State(initialValue: draft.wrappedValue.allowedTools?.joined(separator: "\n") ?? "")
    }

    private var claude: Bool { AgentCapabilities.family(draft.provider.isEmpty ? nil : draft.provider) == .claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    field("Claude Code agent", help: "A name from .claude/agents/. Claude Code runs this identity.") {
                        TextField("Optional, e.g. builder", text: $draft.claudeAgent)
                            .textFieldStyle(.roundedBorder).disabled(busy || (!claude && draft.claudeAgent.isEmpty))
                            .accessibilityLabel("Claude Code agent")
                    }
                    if showsScalars { field("Permission mode", help: "Applies to this agent's task sessions.") {
                        Picker("Permission mode", selection: $draft.permissionMode) {
                            Text("App default").tag("")
                            Text("Default — ask before changes").tag("default")
                            Text("Accept edits").tag("acceptEdits")
                            Text("Plan — read only").tag("plan")
                            Text("Bypass permissions").tag("bypassPermissions")
                        }.labelsHidden().disabled(busy || (!claude && draft.permissionMode.isEmpty))
                    } }
                }
            }
            if showsScalars { field("Default project folder", help: "Used when a task has no project folder.") {
                HStack(spacing: 6) {
                    TextField("Optional full folder path", text: $draft.defaultProject)
                        .textFieldStyle(.roundedBorder).disabled(busy)
                        .accessibilityLabel("Default project folder")
                    Button("Choose…", action: chooseProject).disabled(busy)
                }
            }
            allowList }
            reviewer
            if let source = draft.sourceFile {
                NativeTAGSourceStatus(source: source, status: draft.syncStatus, syncedAt: draft.syncedAt, error: draft.syncError)
            }
        }
    }

    private var allowList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Allow only these tools", isOn: Binding(get: { draft.allowedTools != nil }, set: {
                draft.allowedTools = $0 ? TAGAgentSettings.tools(from: allowedText) : nil
            }))
                .disabled(busy || (!claude && draft.allowedTools == nil))
            if draft.allowedTools != nil {
                TextEditor(text: $allowedText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 120)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    .disabled(busy).accessibilityLabel("Allowed tools, one per line")
                    .onChange(of: allowedText) { _, value in
                        if draft.allowedTools != nil { draft.allowedTools = TAGAgentSettings.tools(from: value) }
                    }
                Text("One tool per line, including MCP names. Empty means no tools. Blocked tools still win.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Uses Claude Code's tools. Blocks below still apply.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var reviewer: some View {
        let choices = agents.filter { $0.id != draft.id && $0.status != .archived }
        return field("Reviewer agent", help: "Checks the result before the task is marked complete. Takes priority over the check command.") {
            Picker("Reviewer agent", selection: $draft.reviewerAgent) {
                Text("Check command or Hoot").tag("")
                if !draft.reviewerAgent.isEmpty && !choices.contains(where: { $0.id == draft.reviewerAgent }) {
                    Text("\(draft.reviewerAgent) (unavailable)").tag(draft.reviewerAgent)
                }
                ForEach(choices) { Text($0.name).tag($0.id) }
            }.labelsHidden().disabled(busy)
        }
    }

    private func field<Content: View>(_ name: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.callout.weight(.medium))
            content()
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        if !draft.defaultProject.isEmpty { panel.directoryURL = URL(fileURLWithPath: draft.defaultProject) }
        NativeFront.whenPersonActs("main") { if panel.runModal() == .OK, let url = panel.url { draft.defaultProject = url.path }
        }
    }
}

struct NativeTAGSourceStatus: View {
    let source: String
    let status: String?
    let syncedAt: Double?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Label(label, systemImage: status == "synced" ? "checkmark.circle" : "doc.text")
                if status == "synced", let syncedAt {
                    Text(Date(timeIntervalSince1970: syncedAt / 1000).formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
                Button("Show source") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source)]) }
            }
            Text(source).lineLimit(2).textSelection(.enabled).help(source)
            if let error, !error.isEmpty { Text(error).fixedSize(horizontal: false, vertical: true) }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var label: String {
        switch status {
        case "synced": "Synced"
        case "missing": "Source missing"
        case "error": "Sync failed"
        default: "Sync not confirmed"
        }
    }
}
