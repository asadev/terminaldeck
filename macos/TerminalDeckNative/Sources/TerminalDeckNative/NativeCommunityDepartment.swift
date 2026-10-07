import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The Store's Community department, drawn in Swift — src/renderer/community/
/// CommunityDepartment.tsx, CommunityRow.tsx and InstallSheet.tsx one for one:
/// the catalogue on `community:list`, shelved by kind with the filter chips, each
/// row with its facts, and Install / Update / Remove through the install sheet
/// (`community:install`, `community:remove`).
struct CommunityDepartmentView: View {
    @Binding var filter: StoreFilter
    @Binding var detail: String
    let onRows: ([StoreFacets]) -> Void
    @State private var model = CommunityModel()

    var body: some View {
        Group {
            if model.loaded {
                if let open = model.view.items.first(where: { "c:\($0.id)" == detail }) {
                    StoreDetailView(backTo: CommunityRules.kindName(open.kind), onBack: { detail = "" }) {
                        CommunityRowView(item: open, model: model, onOpen: nil)
                    }
                } else {
                    CommunityBodyView(model: model, filter: $filter, onOpenRow: { detail = $0 })
                }
            } else {
                // Nothing to draw before the first read (as on the page) — but something
                // has to exist, or the view never appears and the read never starts.
                Color.clear.frame(height: 1)
            }
        }
        // Started once, in a task that outlives the view.
        .onAppear { model.start() }
        .onChange(of: model.view, initial: true) { _, view in onRows(view.items.map(CommunityRules.facets)) }
        .sheet(isPresented: Binding(get: { model.sheetItem != nil }, set: { if !$0 { model.sheet = "" } })) {
            if let item = model.sheetItem { InstallSheetView(item: item, model: model) }
        }
    }
}

@MainActor
@Observable
final class CommunityModel {
    var view = CommunityView.none
    var loaded = false
    /// The id being installed or removed, or "catalogue" while it is read again.
    var busy = ""
    /// What the last action said, per item.
    var said: [String: String] = [:]
    /// The item whose install sheet is open, or "".
    var sheet = ""
    var chosen: [String] = []

    var sheetItem: CommunityItem? { sheet.isEmpty ? nil : view.items.first { $0.id == sheet } }

    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task {
            await load()
            loaded = true
        }
    }

    func load() async {
        do {
            view = CommunityRules.view(try await EngineBridge.shared.invoke(CommunityRules.listChannel, []))
            view.items.removeAll { $0.kind == "extension" }
        } catch {
            var empty = CommunityView.none
            empty.problem = deckMessage(error)
            view = empty
        }
    }

    func refresh() async {
        busy = "catalogue"
        await load()
        busy = ""
    }

    private func act(_ id: String, closesSheet: Bool, _ channel: String, _ args: [Any?]) async {
        busy = id
        do {
            let result = CommunityRules.result(try await EngineBridge.shared.invoke(channel, args))
            said[id] = result.message
            if result.ok && closesSheet { sheet = "" }
        } catch {
            said[id] = deckMessage(error)
        }
        busy = ""
        await load()
    }

    func install(_ id: String) {
        let agents = chosen
        Task { await act(id, closesSheet: true, CommunityRules.installChannel, [id, ["agents": agents]]) }
    }

    func remove(_ id: String) {
        Task { await act(id, closesSheet: false, CommunityRules.removeChannel, [id]) }
    }

    func openSheet(_ item: CommunityItem) {
        sheet = item.id
        chosen = CommunityRules.defaultChoice(item, agents: view.agents)
    }
}

private struct CommunityBodyView: View {
    let model: CommunityModel
    @Binding var filter: StoreFilter
    let onOpenRow: (String) -> Void

    var body: some View {
        let view = model.view
        let all = view.items.map(CommunityRules.facets)
        let kept = view.items.filter { StoreRules.matches(CommunityRules.facets($0), filter) }
        let shelves = StoreRules.shelve(kept, order: CommunityRules.shelves, facetsOf: CommunityRules.facets, rank: { _ in 0 })
        let controls = StoreRules.facetControls(all, filter, StoreRules.withoutShelf(CommunityRules.vocabularies))
        let dated = view.kept ? CommunityRules.catalogueDate(view.at) : ""

        if view.items.isEmpty && !view.problem.isEmpty {
            DeckPageEmpty(symbol: "bag", title: "Nothing has been fetched yet", message: view.problem,
                          actionLabel: model.busy == "catalogue" ? "Trying…" : "Try again", action: { Task { await model.refresh() } })
                .frame(minHeight: 280)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Published by other people. Terminal Deck lists them; it does not review, endorse or sell them.")
                    .font(.callout).foregroundStyle(.secondary)
                if !dated.isEmpty || !view.because.isEmpty || !view.stale.isEmpty {
                    HStack(spacing: 8) {
                        if !dated.isEmpty { Text("Catalogue from \(dated)") }
                        if !view.stale.isEmpty { Text(view.stale).foregroundStyle(.secondary) }
                        if !view.because.isEmpty { Text(view.because).foregroundStyle(.red) }
                        Button(model.busy == "catalogue" ? "Checking…" : "Check again") { Task { await model.refresh() } }
                            .buttonStyle(.link)
                            .disabled(model.busy == "catalogue")
                    }
                    .font(.callout)
                }
                StoreFilterBarView(search: false, filter: $filter, controls: controls, showing: kept.count,
                                   total: view.items.count, active: filter.active)
                if shelves.isEmpty {
                    Text(filter.active ? "Nothing here matches that." : "There is nothing in this department yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(shelves) { shelf in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(shelf.name).font(.system(size: 14, weight: .semibold))
                            ForEach(shelf.rows) { item in
                                CommunityRowView(item: item, model: model, onOpen: { onOpenRow("c:\(item.id)") })
                                Divider()
                            }
                        }
                    }
                }
                if !view.folder.isEmpty {
                    Text("What you install from here is kept in \(Text(view.folder).font(.system(size: 12, design: .monospaced))).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// `CommunityRow`: logo, name and version, the action; chips; summary; who and GitHub facts; the folded details.
struct CommunityRowView: View {
    let item: CommunityItem
    let model: CommunityModel
    let onOpen: (() -> Void)?

    var body: some View {
        let busy = model.busy == item.id
        let action = CommunityRules.rowAction(item)
        let rating = CommunityRules.ratingChip(item)
        let domain = CommunityRules.domainOf(item.offsiteUrl)
        let github = CommunityRules.githubLine(item, now: Date().timeIntervalSince1970 * 1000)
        HStack(alignment: .top, spacing: 12) {
            StoreLogoView(name: item.name, id: item.id, logo: item.logo)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StoreRowNameView(name: item.name, onOpen: onOpen)
                    if !item.version.isEmpty { Text(item.version).font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    if !CommunityRules.installable(item) && !domain.isEmpty {
                        StoreLinkOutView(url: item.offsiteUrl, label: "Get it from \(domain)", describes: "\(item.name), published by @\(item.handle)")
                    }
                    if action == .install {
                        Button(busy ? "Installing…" : "Install") { model.openSheet(item) }.buttonStyle(.borderedProminent).disabled(busy)
                    }
                    if action == .update {
                        Button(busy ? "Working…" : "Update") { model.openSheet(item) }.buttonStyle(.borderedProminent).disabled(busy)
                    }
                    if !item.installedVersion.isEmpty {
                        Button(busy ? "Working…" : "Remove") { model.remove(item.id) }.buttonStyle(.link).disabled(busy)
                    }
                }
                HStack(spacing: 6) {
                    CommunityChip(CommunityRules.kindName(item.kind))
                    if !item.licence.isEmpty { CommunityChip(item.licence) }
                    CommunityChip(StoreFront.costWord(item.cost) ?? item.cost)
                    CommunityChip(CommunityRules.tierWord(item.tier), tint: item.tier == 3 ? .orange : item.tier == 2 ? .yellow : nil)
                    if !rating.isEmpty { CommunityChip(rating) }
                }
                if !item.summary.isEmpty { Text(item.summary).font(.callout) }
                HStack(spacing: 4) {
                    Text("by").foregroundStyle(.secondary)
                    if item.profileUrl.isEmpty {
                        Text("@\(item.handle)")
                    } else {
                        StoreLinkOutView(url: item.profileUrl, label: "@\(item.handle)",
                                         describes: "the page of @\(item.handle), who published \(item.name)")
                    }
                    if !github.isEmpty { Text(github).foregroundStyle(.secondary).padding(.leading, 6) }
                }
                .font(.caption)
                if !item.costNote.isEmpty { Text(item.costNote).font(.caption).foregroundStyle(.secondary) }
                StoreRowMoreView(label: "Publisher, repository, the exact commit, download and fingerprint") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        CommunityFact("Published by", "@\(item.handle)")
                        if !item.repo.isEmpty { CommunityFact("Repository", item.repo) }
                        if !item.commit.isEmpty { CommunityFact("Commit", item.commit, mono: true) }
                        if !item.artifactUrl.isEmpty { CommunityFact("Download", CommunityRules.downloadLine(item)) }
                        if !item.sha256.isEmpty {
                            GridRow {
                                Text("sha256").foregroundStyle(.secondary)
                                Text("\(Text(item.sha256).font(.system(size: 11, design: .monospaced)))\(CommunityRules.shaLine(item))")
                                    .textSelection(.enabled)
                            }
                        }
                        if !item.network.isEmpty { CommunityFact("Talks to", item.network.joined(separator: ", ")) }
                        if !item.installedVersion.isEmpty { CommunityFact("On this machine", item.installedVersion) }
                    }
                    .font(.caption)
                }
                if item.state == "withdrawn" {
                    Text(item.reason.isEmpty ? "Withdrawn from the store." : "Withdrawn: \(item.reason)").font(.callout).foregroundStyle(.red)
                }
                if item.state == "damaged" && !item.message.isEmpty { Text(item.message).font(.callout).foregroundStyle(.red) }
                if let said = model.said[item.id], !said.isEmpty { Text(said).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CommunityChip: View {
    let text: String
    let tint: Color?
    init(_ text: String, tint: Color? = nil) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((tint ?? Color.secondary).opacity(0.15), in: .capsule)
    }
}

private struct CommunityFact: View {
    let label: String
    let value: String
    var mono = false
    init(_ label: String, _ value: String, mono: Bool = false) { self.label = label; self.value = value; self.mono = mono }
    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(mono ? .system(size: 11, design: .monospaced) : .caption).textSelection(.enabled)
        }
    }
}

/// `InstallSheet`: what the item is and does, who reads it, what it needs — then Cancel / Install.
private struct InstallSheetView: View {
    let item: CommunityItem
    let model: CommunityModel

    var body: some View {
        let busy = model.busy == item.id
        let presence = Dictionary(model.view.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 14) {
            Text(item.name).font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Text(CommunityRules.tierWord(item.tier)).font(.callout.weight(.medium))
                DeckInfoNote(label: CommunityRules.tierWord(item.tier), text: CommunityRules.tierNote(item.tier))
            }
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Lands in").foregroundStyle(.secondary)
                    if item.lands.isEmpty {
                        Text("This build could not name the folders.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(item.lands, id: \.self) { Text($0).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled) }
                        }
                    }
                }
                GridRow {
                    Text("Read by").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(CommunityRules.agentIds, id: \.self) { id in
                            let found = presence[id]
                            let name = found?.name ?? CommunityRules.agentLabel(id)
                            let here = found?.found == true
                            HStack(spacing: 8) {
                                if here {
                                    Toggle(name, isOn: Binding(
                                        get: { model.chosen.contains(id) },
                                        set: { on in model.chosen = on ? model.chosen + [id] : model.chosen.filter { $0 != id } }))
                                        .toggleStyle(.checkbox)
                                } else {
                                    Text(name).foregroundStyle(.secondary)
                                    Text("not on this machine").font(.caption).foregroundStyle(.tertiary)
                                }
                                if here && !item.agents.contains(id) {
                                    Text("the publisher did not test this one").font(.caption).foregroundStyle(.tertiary)
                                }
                                if here, let note = found?.note, !note.isEmpty {
                                    Text(note).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                GridRow {
                    Text("Needs").foregroundStyle(.secondary)
                    if item.needs.isEmpty {
                        Text("Nothing you do not already have.")
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(item.needs, id: \.self) { need in
                                HStack(spacing: 6) {
                                    Text(CommunityRules.needWord(need))
                                    if item.missing.contains(need) { Text("not found here").font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                }
                if item.kind == "mcp" && !item.command.isEmpty {
                    GridRow { Text("Runs").foregroundStyle(.secondary); Text(item.command).font(.system(size: 11.5, design: .monospaced)) }
                }
                if item.kind == "mcp" && !item.variables.isEmpty {
                    GridRow { Text("Wants").foregroundStyle(.secondary); Text(item.variables.joined(separator: ", ")).font(.system(size: 11.5, design: .monospaced)) }
                }
                if item.kind == "routine" && !item.trigger.isEmpty {
                    GridRow {
                        Text("Trigger").foregroundStyle(.secondary)
                        Text("\(item.trigger) \(Text("arrives switched off").foregroundStyle(.secondary))")
                    }
                }
                if item.kind == "extension" && !item.reach.isEmpty {
                    GridRow { Text("Reaches").foregroundStyle(.secondary); Text(item.reach.joined(separator: ", ")).font(.system(size: 11.5, design: .monospaced)) }
                }
                GridRow { Text("Not ours").foregroundStyle(.secondary); Text("Terminal Deck did not write this and has not run it.") }
            }
            .font(.callout)
            if let said = model.said[item.id], !said.isEmpty { Text(said).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = "" }.keyboardShortcut(.cancelAction).disabled(busy)
                if CommunityRules.installable(item) {
                    Button(CommunityRules.confirmLabel(item, busy: busy)) { model.install(item.id) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
