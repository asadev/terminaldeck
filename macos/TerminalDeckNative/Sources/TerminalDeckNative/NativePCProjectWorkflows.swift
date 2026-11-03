import SwiftUI
import TerminalDeckNativeCore

struct ProjectWorkflowsGroup: View {
    var body: some View {
        Section("Project workflows") {
            ForEach(NativePROJLabels.shared.projects) { project in
                ForEach(project.folders, id: \.self) { folder in
                    DisclosureGroup(project.name) { PCProjectWorkflowEditor(project: folder) }
                }
            }
        }
        .onAppear { NativePROJLabels.shared.start() }
    }
}

private struct PCProjectWorkflowEditor: View {
    let project: String
    @State private var policies: [NativeRPCValue] = []
    @State private var selected = ""
    @State private var name = ""
    @State private var mode = "off"
    @State private var pending = false
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading) {
            Picker("Workflow", selection: $selected) {
                Text("New workflow").tag("")
                ForEach(Array(policies.enumerated()), id: \.offset) { _, policy in
                    Text(policy["name"].string ?? "Workflow").tag(policy["id"].string ?? "")
                }
            }
            TextField("Workflow name", text: $name)
            Picker("Requirement", selection: $mode) {
                Text("Off").tag("off")
                Text("Owner before start").tag("owner-before-start")
            }
            Button(selected.isEmpty ? "Create workflow" : "Save workflow") { Task { await call(save: true) } }
                .disabled(pending || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if pending { ProgressView().controlSize(.small) }
            if let problem { Text(problem).foregroundStyle(.red) }
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
