import SwiftUI

/// The host supplies rows, forms and actions. The phone has no second task store.
struct ProjectWorkView: View {
    let model: DeckModel
    @State private var project = ""

    private var panels: [PanelKind] {
        PanelKind.allCases.filter { !$0.isLegacy && model.current?.canReadPanel($0) == true }
    }

    var body: some View {
        List {
            Section {
                if let host = model.current {
                    LabeledContent(host.label, value: host.phoneAccess?.level.title ?? "Waiting for access")
                    Text("Access is granted on the machine. It can be changed or taken back there.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if model.startableFolders.count > 1 {
                Section("Project") {
                    Picker("Project", selection: $project) {
                        ForEach(model.startableFolders, id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                        }
                    }
                }
            } else if let path = model.startableFolders.first {
                Section("Project") { Text(path).font(.footnote).textSelection(.enabled) }
            }
            Section {
                ForEach(panels, id: \.self) { panel in
                    NavigationLink {
                        PanelView(panel: panel, title: panel.title, model: model,
                                  path: project.isEmpty ? nil : project)
                    } label: { Label(panel.title, systemImage: panel.symbol) }
                    .accessibilityIdentifier("work.\(panel.rawValue)")
                }
            }
            if panels.isEmpty {
                ContentUnavailableView("No project tools offered", systemImage: "checklist",
                    description: Text("This machine has not offered project tools to this phone yet."))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Project work")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { chooseProject() }
        .onChange(of: model.currentHostId) { _, _ in chooseProject() }
    }

    private func chooseProject() {
        if !model.startableFolders.contains(project) { project = model.startableFolders.first ?? "" }
    }
}
