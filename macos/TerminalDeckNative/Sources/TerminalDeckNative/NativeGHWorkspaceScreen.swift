import SwiftUI
import TerminalDeckNativeCore

/// Connected-account workspace. Sign-in and account controls remain owned by
/// NativeGitHubScreen; this view never acquires or stores a second credential.
struct NativeGHWorkspaceScreen: View {
    let cwd: String
    @State private var model: NativeGHWorkspaceModel
    @State private var repoEntry = ""
    @State private var showingIssueFilters = false
    @State private var enteringRepo = false

    init(cwd: String) {
        self.cwd = cwd
        _model = State(initialValue: NativeGHWorkspaceModel(cwd: cwd))
    }

    init(model: NativeGHWorkspaceModel) {
        cwd = model.cwd
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            repositoryBar
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(NativeGHArea.allCases) { area in
                        NativeGHTabButton(title: area.title, selected: model.area == area) { model.changeArea(area) }
                    }
                    Spacer(minLength: 0)
                }
            }
            .scrollIndicators(.hidden)
            filters
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss message")
                }
            }
            if let error = model.error { NativeGHErrorNote(message: error) { Task { await model.reload() } } }
            GeometryReader { geometry in
                if geometry.size.width < 760 {
                    if let item = model.selection {
                        VStack(alignment: .leading, spacing: 8) {
                            Button { model.selection = nil } label: { Label("Back to \(model.area.title.lowercased())", systemImage: "chevron.left") }
                                .buttonStyle(.borderless)
                            detail(item)
                        }
                    } else { list }
                } else {
                    HSplitView {
                        list.frame(minWidth: 260, idealWidth: 310, maxWidth: 390)
                        Group {
                            if let item = model.selection { detail(item) }
                            else {
                                NativePageEmpty(symbol: model.area.symbol, title: "Choose \(selectionNoun)") {
                                    Text("Open a row to see its details and actions here.")
                                }
                            }
                        }
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(minHeight: 340)
        }
        .tint(.secondary)
        .task { await model.start(); repoEntry = model.repo }
        .onChange(of: model.repo) { _, repo in repoEntry = repo }
        .onChange(of: PanelHandoff.pageFocus) { _, focus in
            if focus == "issues" { model.changeArea(.issues) }
            else if focus == "pulls" { model.changeArea(.pulls) }
        }
        .sheet(item: $model.draft) { draft in
            NativeGHWriteSheet(draft: draft) { model.completed($0) }
        }
    }

    private var selectionNoun: String {
        switch model.area {
        case .pulls: "a pull request"
        case .issues: "an issue"
        case .actions: "a run"
        case .repos: "a repository"
        case .inbox: "a notification"
        }
    }

    private var repositoryBar: some View {
        HStack(spacing: 8) {
            if model.area == .inbox {
                Label("Your GitHub inbox", systemImage: "tray").foregroundStyle(.secondary)
            } else if !model.repositories.isEmpty {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Menu {
                    ForEach(model.repositories) { repo in
                        Button(repo.title) { model.chooseRepo(repo.repo) }
                    }
                    Divider()
                    Button("Enter another repository…") { enteringRepo = true }
                } label: { Text(model.repo.isEmpty ? "Choose repository" : model.repo).lineLimit(1).truncationMode(.middle) }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 300, alignment: .leading)
                .popover(isPresented: $enteringRepo) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose repository").font(.callout.weight(.semibold))
                        TextField("owner/repository", text: $repoEntry).textFieldStyle(.roundedBorder)
                        Button("Use repository") { model.chooseRepo(repoEntry); enteringRepo = false }
                            .disabled(!repoEntry.contains("/") || repoEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(16).frame(width: 280).tint(.secondary)
                }
            } else {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                TextField("owner/repository", text: $repoEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.chooseRepo(repoEntry) }
                    .frame(maxWidth: 300)
                    .accessibilityLabel("Repository")
                Button("Use repository") { model.chooseRepo(repoEntry) }
                    .disabled(!repoEntry.contains("/") || repoEntry == model.repo)
            }
            if model.area != .inbox && !model.branch.isEmpty { Text(model.branch).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh GitHub data")
                .disabled(model.loading || model.loadingMore)
        }
        .font(.callout)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            if model.area == .pulls {
                Picker("Pull requests", selection: $model.scope) {
                    Text("This repository").tag("repo")
                    Text("Mine").tag("mine")
                    Text("Review requested").tag("review-requested")
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 155)
                .onChange(of: model.scope) { _, _ in model.selection = nil; Task { await model.reload() } }
            }
            if model.area == .pulls || model.area == .issues {
                Picker("State", selection: $model.state) {
                    Text("Open").tag("open")
                    Text("Closed").tag("closed")
                    Text("All").tag("all")
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 90)
                .onChange(of: model.state) { _, _ in model.selection = nil; Task { await model.reload() } }
            }
            if model.area == .inbox {
                Picker("Notifications", selection: $model.state) {
                    Text("Unread").tag("open")
                    Text("All").tag("all")
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 110)
                .onChange(of: model.state) { _, _ in Task { await model.reload() } }
            }
            if model.area == .issues {
                Button("Filters\(model.label.isEmpty && model.assignee.isEmpty ? "" : " •")") { showingIssueFilters = true }
                    .popover(isPresented: $showingIssueFilters) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Filter issues").font(.callout.weight(.semibold))
                            TextField("Label", text: $model.label).textFieldStyle(.roundedBorder)
                            TextField("Assigned GitHub name", text: $model.assignee).textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Clear") { model.label = ""; model.assignee = "" }
                                Spacer()
                                Button("Apply") { showingIssueFilters = false; model.selection = nil; Task { await model.reload() } }
                            }
                        }
                        .padding(16).frame(width: 260).tint(.secondary)
                    }
            }
            TextField("Search loaded \(model.area.title.lowercased())", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search loaded \(model.area.title.lowercased())")
            if model.area == .pulls || model.area == .issues {
                Button(model.area == .pulls ? "New pull request" : "New issue") { model.create() }.disabled(model.repo.isEmpty)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var list: some View {
        if model.loading && model.items.isEmpty {
            NativeGHListSkeleton()
        } else if model.shownItems.isEmpty {
            NativePageEmpty(symbol: model.area.symbol, title: emptyTitle) {
                Text(emptyMessage)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.loading { NativePageNote("Refreshing…", busy: true).padding(8) }
                    ForEach(model.shownItems) { item in
                        Button { model.selection = item } label: {
                            NativeGHListRow(item: item, selected: model.selection?.id == item.id)
                        }
                        .buttonStyle(.plain)
                    }
                    if model.hasMore {
                        Button {
                            Task { await model.reload(more: true) }
                        } label: {
                            HStack(spacing: 8) {
                                if model.loadingMore { ProgressView().controlSize(.small) }
                                Text(model.loadingMore ? "Loading more…" : "Load more")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(model.loadingMore)
                        .padding(.top, 8)
                    }
                }
                .padding(.trailing, 8)
            }
        }
    }

    private var emptyTitle: String {
        if model.error != nil { return "GitHub could not load" }
        if !model.query.isEmpty { return "No matches" }
        let needsRepo = model.area == .issues || model.area == .actions || (model.area == .pulls && model.scope == "repo")
        if needsRepo && model.repo.isEmpty { return "Choose a repository" }
        return model.area == .inbox ? "Your inbox is clear" : "No \(model.area.title.lowercased()) here"
    }

    private var emptyMessage: String {
        if model.error != nil { return "Try again using the message above." }
        if !model.query.isEmpty { return "Try another search, or clear it to see the loaded rows." }
        if model.repo.isEmpty && model.area != .repos && model.area != .inbox {
            return "Pick a repository above, or use Repositories to find one." }
        return model.area == .inbox ? "Unread GitHub notifications appear here." : "Try another filter or repository."
    }

    private func detail(_ item: NativeGHItem) -> some View {
        NativeGHDetailScreen(item: item, cwd: cwd, completed: { model.completed($0) }, open: { target in
            if target.area == .repos { model.chooseRepo(target.repo) }
            else { model.selection = target }
        })
            .id("\(item.area.rawValue):\(item.id):\(item.raw["updated_at"].text ?? ""):\(item.raw["status"].text ?? ""):\(item.raw["unread"].bool == true)")
    }
}

struct NativeGHTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.callout.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NativeGHListRow: View {
    let item: NativeGHItem
    let selected: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.area.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let description = item.raw["description"].text { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if item.area == .inbox && item.raw["unread"].isTrue {
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary).padding(.top, 5).accessibilityLabel("Unread")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NativeGHListSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(index % 2 == 0 ? "Loading a GitHub item" : "Reading the next GitHub item").font(.callout)
                        Text("Repository · status · author").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading GitHub rows")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
