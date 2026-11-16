import SwiftUI
import TerminalDeckNativeCore

/// Settings › Tasks › a project's workflows (owner, 15 Nov): one group per folder of the project, each with the
/// workflow chooser, its name, its requirement and Save; the same calls as before.
struct NativeProjectWorkflowPage: View {
    let projectID: String
    var body: some View {
        let project = NativePROJLabels.shared.projects.first { $0.id == projectID }
        DeckSettingsScaffold(title: project?.name ?? "Project") {
            if let project {
                ForEach(project.folders, id: \.self) { folder in
                    PCProjectWorkflowEditor(project: folder,
                                            title: project.folders.count > 1 ? URL(fileURLWithPath: folder).lastPathComponent : nil)
                }
            } else {
                DeckSettingsGroup { DeckSettingsProblem(text: "This project is no longer listed.", warn: false) }
            }
        }
        .onAppear { NativePROJLabels.shared.start() }
    }
}

struct PCProjectWorkflowEditor: View {
    let project: String
    /// The group's title when a project has more than one folder (its folder's name, never its path).
    var title: String? = nil
    @State private var policies: [NativeRPCValue] = []
    @State private var selected = ""
    @State private var name = ""
    @State private var mode = "off"
    @State private var pending = false
    @State private var problem: String?
    var body: some View {
        DeckSettingsGroup(title) {
            DeckSettingsRow("Workflow") {
                Picker("Workflow", selection: $selected) {
                    Text("New workflow").tag("")
                    ForEach(Array(policies.enumerated()), id: \.offset) { _, policy in
                        Text(policy["name"].string ?? "Workflow").tag(policy["id"].string ?? "")
                    }
                }
                .fixedSize()
            }
            DeckSettingsRow("Name") {
                NativeSessionTextField("Workflow name", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            DeckSettingsRow("Before an agent starts", info: "Owner before start: the project's owner says yes before an agent starts a task here.") {
                Picker("Requirement", selection: $mode) {
                    Text("Nothing").tag("off")
                    Text("Owner says yes").tag("owner-before-start")
                }
                .fixedSize()
            }
            DeckSettingsRow(selected.isEmpty ? "Create this workflow" : "Save changes", state: pending ? "Saving…" : nil) {
                Button(selected.isEmpty ? "Create" : "Save") { Task { await call(save: true) } }
                    .disabled(pending || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem { DeckSettingsProblem(text: problem) }
        }
        .disabled(pending)
        .task { await call(save: false) }
        .onChange(of: selected) { _, _ in
            let policy = policies.first { $0["id"].string == selected }
            name = policy?["name"].string ?? ""; mode = policy?["mode"].string ?? "off"
        }
    }
    private func call(save: Bool) async {
        guard !pending else { return }; pending = true; defer { pending = false }
        var fields: [NativeRPCValue.Field] = [.init("project", .string(project)), .init("action", .string(save ? "policy" : "get"))]
        if save {
            let policy = policies.first { $0["id"].string == selected }
            fields += [.init("name", .string(name)), .init("mode", .string(mode)), .init("policyExpected", policy?["revision"] ?? .number(0)), .init("request", .string(UUID().uuidString))]
            if !selected.isEmpty { fields.append(.init("policy", .string(selected))) }
        }
        do {
            let result = try await EngineBridge.shared.invokeNativeValue("decisions:perform", [.object(fields)])
            policies = result["policies"].elements ?? []; problem = nil
        } catch { problem = error.localizedDescription }
    }
}
