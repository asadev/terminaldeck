import AppKit
import SwiftUI
import Observation
import TerminalDeckNativeCore

/// Reads PROJ's folder inventory. The only write is the person's Import press.
@MainActor @Observable final class AGFRAMEImportModel {
    enum Activity: Equatable { case idle, scanning, importing, creatingProject }
    var folders: [AGFRAMEImportFolder]
    var busy = false
    var activity = Activity.idle
    var needsRescan = false
    var firstImportedProjectID: String?
    var loaded = false
    var error: String?
    var outcome: String?
    var expanded = Set<String>()
    let live: Bool
    @ObservationIgnored private var addedFolderIDs = Set<String>()
    @ObservationIgnored private var lastScanFolder: String?
    @ObservationIgnored private var pendingReconcileFolders: [String] = []
    @ObservationIgnored var invoke: (String, [Any?]) async throws -> Any
    init(folders: [AGFRAMEImportFolder] = [], live: Bool = true,
         invoke: ((String, [Any?]) async throws -> Any)? = nil) {
        self.folders = folders; self.live = live; loaded = !live
        self.invoke = invoke ?? { channel, args in try await EngineBridge.shared.invoke(channel, args, timeout: channel == "tasks:agents-scan" ? 10 : 30) }
    }
    var count: Int { folders.reduce(0) { $0 + $1.pendingCandidates.count } }
    func select(folder: String, id: String, selected: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folder }), !busy else { return }
        folders[index].setSelected(selected, id: id)
    }
    func assign(folder: String, projectID: String) {
        guard let index = folders.firstIndex(where: { $0.id == folder }), !busy else { return }
        folders[index].projectID = projectID
    }
    @discardableResult func scan(additionalFolder: String? = nil) async -> Bool {
        guard live, !busy else { return !live }
        lastScanFolder = additionalFolder
        busy = true; activity = .scanning; error = nil
        defer { busy = false; activity = .idle; loaded = true }
        do {
            let options: [String: Any] = additionalFolder.map { ["folders": [$0]] } ?? [:]
            let value = try NativeRPCValue.fromFoundation(try await invoke("tasks:agents-scan", [options]))
            guard let batches = value["batches"].elements else { throw NativeRPCError.invalidArguments("Could not read the agent folders.") }
            var next: [AGFRAMEImportFolder] = []
            var failures = (value["errors"].elements ?? []).compactMap { $0["message"].string }
            for batch in batches {
                guard let folder = batch["folder"].string else { continue }
                failures += (batch["errors"].elements ?? []).compactMap { $0["message"].string }
                let candidates = (batch["agents"].elements ?? []).compactMap { row -> AGFRAMEImportCandidate? in
                    guard let file = row["file"].string, let name = row["name"].string else { return nil }
                    return .init(id: file, name: name, alreadyImported: row["alreadyImported"].bool ?? false)
                }
                var group = AGFRAMEImportFolder(folder: folder, candidates: candidates, projectID: batch["projectId"].string,
                                               projects: NativePROJLabels.shared.projects)
                if let previous = folders.first(where: { $0.id == group.id }) { group.keepChoices(of: previous) }
                if !next.contains(where: { $0.id == group.id }) { next.append(group) }
            }
            if additionalFolder != nil {
                for group in next {
                    addedFolderIDs.insert(group.id)
                    if let index = folders.firstIndex(where: { $0.id == group.id }) { folders[index] = group }
                    else { folders.append(group) }
                }
            } else {
                let ids = Set(next.map(\.id))
                folders = next + folders.filter { addedFolderIDs.contains($0.id) && !ids.contains($0.id) }
            }
            if !failures.isEmpty { error = failures.joined(separator: "\n"); return false }
            needsRescan = false
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func retryScan() async {
        if pendingReconcileFolders.isEmpty { _ = await scan(additionalFolder: lastScanFolder) }
        else { await reconcileAfterUncertainImport(pendingReconcileFolders) }
    }
    func importSelected() async -> Bool {
        guard count > 0, !busy, !needsRescan else { return false }
        let selected = folders.filter { !$0.pendingCandidates.isEmpty }
        firstImportedProjectID = selected.first?.projectID
        guard live else { outcome = "Fixture import checked."; return true }
        busy = true; activity = .importing; error = nil; outcome = nil
        defer { busy = false; activity = .idle }
        let batches: [[String: Any]] = selected.map {
            ["folder": $0.folder, "projectId": $0.projectID, "selectedFiles": $0.pendingCandidates.map(\.id)]
        }
        do {
            let raw = try await invoke("tasks:agents-import", [["batches": batches]])
            let result = TasksDecode.result(raw)
            TasksStore.shared.adopt(result)
            let value = try NativeRPCValue.fromFoundation(raw)
            let failures = (value["errors"].elements ?? []).compactMap { $0["message"].string ?? $0.string }
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
            guard result.ok, failures.isEmpty else {
                if error == nil { error = result.message ?? "The agents could not be imported." }
                await reconcileAfterUncertainImport(selected.map(\.folder))
                return false
            }
            let names = Array(Set(selected.map { NativePROJLabels.shared.name(for: $0.projectID) })).sorted()
            if let imported = value["imported"].number {
                outcome = "Imported \(Int(imported)) agents into \(ListFormatter.localizedString(byJoining: names))."
            } else { outcome = result.message ?? "Imported agents into \(ListFormatter.localizedString(byJoining: names))." }
            return true
        } catch {
            self.error = error.localizedDescription
            await reconcileAfterUncertainImport(selected.map(\.folder))
            return false
        }
    }
    private func reconcileAfterUncertainImport(_ folders: [String]) async {
        pendingReconcileFolders = folders
        let problem = error
        busy = false; activity = .idle
        var refreshed = true
        var readFailures: [String] = []
        for folder in folders {
            if !(await scan(additionalFolder: folder)) { refreshed = false; if let error { readFailures.append(error) } }
        }
        needsRescan = !refreshed
        if refreshed { pendingReconcileFolders = [] }
        error = ([problem].compactMap { $0 } + readFailures).joined(separator: "\n")
    }
    func addFolder() {
        guard live, !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder or an agents folder."
        panel.prompt = "Add folder"; panel.showsHiddenFiles = true
        // Its own key: parked under "main" it replaced (or was replaced by) the main-window request.
        NativeFront.whenPersonActs("agents-import-folder") {
            guard panel.runModal() == .OK, let path = panel.url?.path else { return } // front-ok: person's Add another folder press
            Task { await self.scan(additionalFolder: path) }
        }
    }
    func createProject(name: String, folder: String) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !busy else { return nil }
        let taken = NativePROJLabels.shared.projects.map(\.id)
        let id = AgentForm.slug(name, taken: taken)
        // The folder being imported belongs to the new project, unless another project already has it.
        let root = PROJProjects.normalize(folders.first { $0.id == folder }?.projectRoot ?? folder)
        let owned = NativePROJLabels.shared.projects.contains { $0.folders.map(PROJProjects.normalize).contains(root) }
        let item = PROJProject(id: id, name: name, folders: owned ? [] : [root], colour: PROJProjects.colours[taken.count % PROJProjects.colours.count])
        guard live else { assignAfterCreate(folder: folder, projectID: id); return id }
        busy = true; activity = .creatingProject; error = nil; defer { busy = false; activity = .idle }
        do {
            _ = try await invoke("project-registry:save", [item.wireValue.foundation])
            if !NativePROJLabels.shared.projects.contains(where: { $0.id == id }) { NativePROJLabels.shared.projects.append(item) }
            assignAfterCreate(folder: folder, projectID: id)
            return id
        } catch { self.error = error.localizedDescription; return nil }
    }
    private func assignAfterCreate(folder: String, projectID: String) {
        if let index = folders.firstIndex(where: { $0.id == folder }) { folders[index].projectID = projectID }
    }
}

struct AGFRAMEImportSheet: View {
    @State var model: AGFRAMEImportModel
    var onImported: (String, String?) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var newProjectFolder: String?
    @State private var newProjectName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import agents").font(.system(size: 18, weight: .semibold))
                    Text("Pick which project each folder's agents belong to.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Cancel import").disabled(model.busy)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.loaded {
                        ForEach(0..<3) { _ in
                            AGFRAMECard {
                                VStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(height: 20)
                                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(height: 56)
                                }
                            }
                        }.redacted(reason: .placeholder).accessibilityLabel("Looking for agent folders")
                    }
                    ForEach(model.folders) { folder in folderGroup(folder) }
                    if model.loaded && model.folders.isEmpty && model.error == nil {
                        Text("No agent files found. Add the folder that contains your agents.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    if let error = model.error {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        DeckRetryButton { Task { await model.retryScan() } }.disabled(model.busy)
                    }
                    Button("Add another folder…", action: model.addFolder).buttonStyle(.link).disabled(model.busy)
                }.padding(20)
            }.frame(minHeight: 0, maxHeight: 460)
            Divider()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.count) agents").font(.system(size: 12, weight: .medium))
                    Text("Their files stay where they are; changes you make here are written back.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button {
                    Task {
                        if await model.importSelected() {
                            onImported(model.outcome ?? "Imported agents.", model.firstImportedProjectID)
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if model.busy { ProgressView().controlSize(.mini) }
                        Text(model.activity == .importing ? "Importing…" : "Import \(model.count) agents")
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.count == 0 || model.busy || !model.loaded || model.needsRescan)
            }.padding(20)
        }.frame(width: 600).background(Color(nsColor: .windowBackgroundColor))
            .task { if !model.loaded { await model.scan() } }
            .sheet(isPresented: Binding(get: { newProjectFolder != nil }, set: { if !$0 { newProjectFolder = nil } })) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("New project").font(.headline)
                    TextField("Project name", text: $newProjectName)
                    HStack { Spacer(); Button("Cancel") { newProjectFolder = nil }; Button("Create project") {
                        guard let folder = newProjectFolder else { return }
                        Task { if await model.createProject(name: newProjectName, folder: folder) != nil { newProjectFolder = nil; newProjectName = "" } }
                    }.buttonStyle(.borderedProminent).disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy) }
                    if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
                }.padding(24).frame(width: 380)
            }
    }
    private func folderGroup(_ folder: AGFRAMEImportFolder) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AGFRAMEStyle.shortPath(folder.folder)).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(folder.folder)
                    Text("\(folder.candidates.count) agents found").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("Project").font(.system(size: 11)).foregroundStyle(.secondary)
                Menu {
                    ForEach(NativePROJLabels.shared.projects.filter { $0.id != PROJProjects.independentID }) { project in
                        Button { model.assign(folder: folder.id, projectID: project.id) } label: { DeckRowLabel.project(project) }
                    }
                    Divider()
                    Button { model.assign(folder: folder.id, projectID: PROJProjects.independentID) } label: {
                        DeckRowLabel("Independent (no project)", image: DeckRowIcon.independent)
                    }
                    Divider()
                    Button("New project…") { newProjectFolder = folder.id }
                } label: {
                    let project = NativePROJLabels.shared.projects.first { $0.id == folder.projectID }
                    HStack(spacing: 6) {
                        ProjectLogoView(project: project, name: project?.name ?? folder.projectID, size: 14)
                        Text(project?.name ?? folder.projectID).font(.system(size: 12))
                    }
                }.menuStyle(.borderedButton).disabled(model.busy).accessibilityLabel("Project for \(folder.folder)")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
                ForEach(Array((model.expanded.contains(folder.id) ? folder.candidates[...] : folder.candidates.prefix(9)))) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(row.name, isOn: Binding(get: { model.folders.first { $0.id == folder.id }?.selectedIDs.contains(row.id) ?? false },
                                                      set: { model.select(folder: folder.id, id: row.id, selected: $0) }))
                            .toggleStyle(.checkbox).tint(.accentColor).font(.system(size: 12)).lineLimit(1).disabled(row.alreadyImported || model.busy)
                        if row.alreadyImported { Text("already here").font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 20) }
                    }
                }
            }
            if folder.candidates.count > 9 {
                Button(model.expanded.contains(folder.id) ? "Show less" : "+ \(folder.candidates.count - 9) more · Show all") {
                    if model.expanded.contains(folder.id) { model.expanded.remove(folder.id) } else { model.expanded.insert(folder.id) }
                }.buttonStyle(.link).font(.system(size: 11))
            }
        }.padding(16).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
