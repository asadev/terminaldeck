import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// A6 body only: AGFRAME owns the sole page/header/switch and New skill button.
struct AGTSkillsView: View {
    var projectID: String? = nil
    var model: ROUTINESSkillsStore = .shared
    @State private var installing: CommunityItem?
    @State private var assignment: String?
    @FocusState private var searchFocused: Bool
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            if let error = model.problem, model.tab == .installed {
                ROUTINESSkillsNote(text: error, retry: { Task { await model.load() } })
            }
            if model.tab == .installed {
                if model.loading { skeleton }
                else if model.installed.isEmpty && model.problem == nil {
                    NativePageEmpty(symbol: "books.vertical", title: "No skills yet",
                                    action: .init(label: "Get more", perform: { model.tab = .getMore })) {
                        Text("Skills teach agents how your project does things.")
                    }.frame(minHeight: 280)
                } else {
                    ForEach(groupIDs, id: \.self) { id in
                        let rows = visible.filter { ($0.projectID ?? "every") == id }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                if groupIDs.count > 1 { groupHeader(id, count: rows.count) }
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                    ForEach(rows) { row in installedCard(row) }
                                }
                            }
                        }
                    }
                    if visible.isEmpty && !model.installed.isEmpty { Text("No skills match those filters.").foregroundStyle(.secondary).padding(.vertical, 32) }
                    ForEach(model.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                if let error = model.catalogueProblem { ROUTINESSkillsNote(text: error, retry: { Task { await model.load() } }) }
                else if model.catalogueLoading { skeleton }
                else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) { ForEach(more) { item in catalogueCard(item) } }
                    if more.isEmpty { Text(model.query.isEmpty ? "No more skills are available right now." : "No skills match those filters.").foregroundStyle(.secondary).padding(.vertical, 32) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: .ROUTINESNewSkill)) { _ in model.newSkill = true }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AGFRAME.focusSearch"))) { note in
            if (note.object as? String) == "skills" { searchFocused = true }
        }
        .sheet(isPresented: $model.newSkill) { ROUTINESSkillEditor(model: model, projectID: projectID) }
        .sheet(item: $installing) { item in ROUTINESSkillInstall(item: item, model: model, projectID: projectID) }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.preview = nil } })) {
            if let value = model.preview { ROUTINESSkillPreview(value: value, model: model) }
        }
    }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 12, alignment: .top)] }
    private var visible: [ROUTINESSkill] { ROUTINESSkillsRules.filtered(model.installed, projectID: projectID, query: model.query, category: model.category) }
    private var groupIDs: [String] {
        let order = NativePROJLabels.shared.projects.map(\.id)
        return Array(Set(visible.map { $0.projectID ?? "every" })).sorted { a, b in
            if a == b { return false }
            if a == "every" { return false }
            if b == "every" { return true }
            let left = order.firstIndex(of: a) ?? Int.max
            let right = order.firstIndex(of: b) ?? Int.max
            return left == right ? a < b : left < right
        }
    }
    private var more: [CommunityItem] {
        model.available(projectID: projectID).filter { item in
            StoreRules.matchesQuery(CommunityRules.facets(item), model.query)
                && (model.category == "All" || item.tags.contains { $0.caseInsensitiveCompare(model.category) == .orderedSame })
        }
    }
    private var toolbar: some View {
        @Bindable var model = model
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { filters; categories }
            VStack(alignment: .leading, spacing: 12) { filters; categories }
        }
    }
    private var filters: some View {
        @Bindable var model = model
        return HStack(spacing: 16) {
            Picker("Skills", selection: $model.tab) {
                Text("Installed \(ROUTINESSkillsRules.filtered(model.installed, projectID: projectID, query: "", category: "All").count)").tag(ROUTINESSkillsStore.Tab.installed)
                Text("Get more \(model.available(projectID: projectID).count)").tag(ROUTINESSkillsStore.Tab.getMore)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                NativeSessionTextField("Find a skill", text: $model.query).textFieldStyle(.plain).sessionFocused($searchFocused)
            }.padding(.horizontal, 12).frame(minWidth: 170, maxWidth: 280, minHeight: 28)
                .background(ROUTINESKit.selection, in: Capsule())
        }
    }
    private var categories: some View {
        FilterChips(selection: Binding(get: { model.category }, set: { model.category = $0 }),
                    items: model.categories.map { .init(id: $0, title: $0) })
    }
    private func groupHeader(_ id: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(id == "every" ? .gray : ROUTINESKit.projectColor(id)).frame(width: 8, height: 8)
            Text(id == "every" ? "Every project" : NativePROJLabels.shared.name(for: id)).font(.caption.weight(.semibold))
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func installedCard(_ row: ROUTINESSkill) -> some View {
        let users = model.users(row)
        return ROUTINESCard {
            VStack(alignment: .leading, spacing: 0) {
            NativeSessionButton { Task { await model.open(row) } } label: {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeading(name: row.name, source: row.source, category: row.category)
                    Text(row.summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .topLeading)
                    HStack(spacing: 6) {
                        HStack(spacing: -5) {
                            ForEach(Array(users.prefix(4).enumerated()), id: \.offset) { _, profile in
                                ROUTINESAgentAvatar(icon: AGTIcon.parse(profile["icon"].string) ?? .symbol("person"), size: 22,
                                                id: profile["id"].string, colour: AGTIcon.colour(profile["icon"].string))
                            }
                        }
                        Text(users.isEmpty ? "No agent has it yet" : users.map { $0["name"].string ?? $0["id"].string ?? "Unnamed agent" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain)
            if row.clash != nil {
                NativeSkillClashNotice(folder: row.folder, name: row.name, builtIn: row.builtIn)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            HStack { Spacer()
            NativeSessionButton { assignment = row.id } label: { Label("Assign skill", systemImage: "person.2") }
                .buttonStyle(.bordered).controlSize(.small).padding(16)
                .popover(isPresented: Binding(get: { assignment == row.id }, set: { if !$0 { assignment = nil } }), arrowEdge: .bottom) {
                    ROUTINESSkillAssignment(row: row, model: model, done: { assignment = nil })
                }
            }
            }
        }
        .contextMenu {
            NativeSessionButton("Show the skill") { Task { await model.open(row) } }
            NativeSessionButton("Assign skill") { assignment = row.id }
            NativeSessionButton("Show in Finder") { NSWorkspace.shared.selectFile(row.folder, inFileViewerRootedAtPath: "") }
        }
    }
    private func catalogueCard(_ item: CommunityItem) -> some View {
        ROUTINESCard {
            VStack(alignment: .leading, spacing: 12) {
                cardHeading(name: item.name, source: item.publisher + " · Store", category: item.tags.first ?? "Code")
                Text(item.summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .topLeading)
                HStack {
                    Text(item.version).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    NativeSessionButton("Install") { installing = item }.buttonStyle(.bordered).controlSize(.small)
                        .disabled(!CommunityRules.installable(item))
                }.frame(height: 22)
            }.padding(16).frame(minHeight: 150)
        }.contextMenu { NativeSessionButton("Install") { installing = item }.disabled(!CommunityRules.installable(item)) }
    }
    private func cardHeading(name: String, source: String, category: String) -> some View {
        HStack(spacing: 10) {
            Text(StoreLogoRules.monogram(name)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(LinearGradient(colors: [tileColor(category).opacity(0.72), tileColor(category)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(source).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
    private func tileColor(_ category: String) -> Color {
        switch category.lowercased() { case "data": .green; case "messaging": .cyan; case "release": .orange; case "design": .pink; default: .blue }
    }
    private var skeleton: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                ROUTINESCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { RoundedRectangle(cornerRadius: 8).frame(width: 34, height: 34); RoundedRectangle(cornerRadius: 4).frame(width: 150, height: 12) }
                        RoundedRectangle(cornerRadius: 4).frame(height: 28)
                        RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 12)
                    }.foregroundStyle(ROUTINESKit.selection).padding(16).frame(height: 150)
                }.accessibilityHidden(true)
            }
        }
    }
}

private struct ROUTINESSkillsNote: View {
    let text: String
    let retry: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            DeckRetryButton(action: retry).buttonStyle(.bordered)
        }.padding(12).background(ROUTINESKit.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ROUTINESSkillAssignment: View {
    let row: ROUTINESSkill
    var model: ROUTINESSkillsStore
    let done: () -> Void
    @State private var query = ""
    private var profiles: [NativeRPCValue] { model.profiles.filter { $0["name"].string?.localizedCaseInsensitiveContains(query) == true || query.isEmpty } }
    private var groups: [String] { Array(Set(profiles.map(model.project))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Give “\(row.name)” to…").font(.headline)
            NativeSessionTextField("Find an agent", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle().fill(ROUTINESKit.projectColor(id)).frame(width: 8, height: 8)
                                Text(NativePROJLabels.shared.name(for: id)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 4)
                            ForEach(Array(profiles.filter { model.project($0) == id }.enumerated()), id: \.offset) { _, profile in
                                let agentID = profile["id"].string ?? ""
                                HStack(spacing: 8) {
                                    Toggle(isOn: Binding(get: { model.assigned(row, to: agentID) }, set: { enabled in Task { await model.assign(row, to: agentID, enabled: enabled) } })) {
                                        HStack(spacing: 8) {
                                            ROUTINESAgentAvatar(icon: AGTIcon.parse(profile["icon"].string) ?? .symbol("person"), size: 22,
                                                id: profile["id"].string, colour: AGTIcon.colour(profile["icon"].string))
                                            Text(profile["name"].string ?? agentID).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                                        }.contentShape(.rect)
                                    }.toggleStyle(.checkbox).tint(ROUTINESKit.switchOn).disabled(model.pending.contains("assign:" + agentID))
                                    if model.pending.contains("assign:" + agentID) { ProgressView().controlSize(.mini) }
                                }.frame(minHeight: 28)
                            }
                        }
                    }
                    if profiles.isEmpty { Text("No saved agents match that.").font(.callout).foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 320)
            if let error = model.problem { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Text("Named in each ticked agent's task brief from its next task (a suggestion; it does not reach sessions opened by hand).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                NativeSessionButton("Done", action: done).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }.padding(14).frame(width: 330)
    }
}

private struct ROUTINESSkillInstall: View {
    let item: CommunityItem
    var model: ROUTINESSkillsStore
    @State var projectID: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install “\(item.name)”").font(.title3.weight(.semibold))
            ROUTINESSkillProjectPicker(projectID: $projectID)
            Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Text(CommunityRules.tierWord(item.tier)).font(.caption).foregroundStyle(.secondary)
            if let error = model.problem { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                NativeSessionButton("Cancel") { dismiss() }.buttonStyle(.bordered)
                NativeSessionButton(model.pending.contains("install") ? "Installing…" : "Install") {
                    Task { if await model.action("skills:install", args: ["id": item.id, "project": projectID as Any? ?? NSNull()], key: "install") { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(model.pending.contains("install"))
            }
        }.padding(24).frame(width: 520)
    }
}

private struct ROUTINESSkillEditor: View {
    var model: ROUTINESSkillsStore
    @State var projectID: String?
    @State private var name = ""
    @State private var summary = ""
    @State private var category = "Code"
    @State private var instructions = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New skill").font(.title3.weight(.semibold))
            NativeSessionTextField("Skill name, e.g. release-checks", text: $name).textFieldStyle(.roundedBorder)
            NativeSessionTextField("One-line description", text: $summary).textFieldStyle(.roundedBorder)
            HStack {
                ROUTINESSkillProjectPicker(projectID: $projectID)
                Picker("Category", selection: $category) { ForEach(ROUTINESSkillsRules.categories.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) } }
            }
            Text("Instructions").font(.headline)
            NativeSessionTextEditor(text: $instructions).font(.system(size: 12, design: .monospaced)).frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            if let error = model.problem { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) }
            HStack {
                Spacer()
                NativeSessionButton("Cancel") { dismiss() }.buttonStyle(.bordered)
                NativeSessionButton(model.pending.contains("create") ? "Creating…" : "Create skill") {
                    Task { if await model.action("skills:create", args: ["name": name, "summary": summary, "category": category, "markdown": instructions, "project": projectID as Any? ?? NSNull()], key: "create") { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(model.pending.contains("create") || !ROUTINESSkillsRules.safeName(name) || summary.isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 600)
    }
}

private struct ROUTINESSkillProjectPicker: View {
    @Binding var projectID: String?
    var body: some View {
        Picker("Install in", selection: $projectID) {
            DeckRowLabel("Every project", image: DeckRowIcon.allProjects).tag(String?.none)
            ForEach(NativePROJLabels.shared.projects.filter { !$0.folders.isEmpty }) { project in DeckRowLabel.project(project).tag(Optional(project.id)) }
        }
    }
}

private struct ROUTINESSkillPreview: View {
    let value: NativeRPCValue
    var model: ROUTINESSkillsStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(value["name"].string ?? "Skill").font(.title3.weight(.semibold)); Spacer(); NativeSessionButton("Done") { dismiss() }.buttonStyle(.borderedProminent) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(value["markdown"].string ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    ROUTINESSkillVersionsView(skill: value["id"].string ?? "", model: model)
                    Text("Files").font(.headline)
                    ForEach((value["files"].elements ?? []).compactMap(\.string), id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
                    Text("Agents using it").font(.headline)
                    let agents = value["agents"].elements ?? []
                    if agents.isEmpty { Text("No agent has it yet").foregroundStyle(.secondary) }
                    ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in Text(agent["name"].string ?? agent["id"].string ?? "Agent") }
                }.padding(12)
            }.frame(height: 360).background(ROUTINESKit.card, in: RoundedRectangle(cornerRadius: 8))
            if let error = model.problem { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) }
            HStack {
                NativeSessionButton("Show in Finder") { NSWorkspace.shared.selectFile(value["folder"].string, inFileViewerRootedAtPath: "") }.buttonStyle(.bordered)
                Spacer()
                if value["builtIn"].bool != true { NativeSessionButton("Remove skill…", role: .destructive) { confirming = true }.buttonStyle(.bordered).disabled(model.pending.contains("remove")) }
            }
        }.padding(24).frame(width: 620)
        .alert("Remove “\(value["name"].string ?? "skill")”?", isPresented: $confirming) {
            NativeSessionButton("Cancel", role: .cancel) {}
            NativeSessionButton("Remove skill", role: .destructive) {
                Task { if await model.action("skills:remove", args: ["skill": value["id"].string ?? ""], key: "remove") { dismiss(); model.preview = nil } }
            }
        } message: { Text("Its folder and all its files will be removed. Agents will keep the skill name in their settings until you remove it there.") }
    }
}
