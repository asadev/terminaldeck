import SwiftUI
import TerminalDeckNativeCore

/// Item 104. The page owns scrolling; artifacts are one day-grouped grid in its content column.
struct NativeArtifactsCatalogScreen: View {
    @State private var model: NativeArtifactsCatalogModel
    private let fixture: Bool
    @State private var contentWidth: CGFloat = 1024
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 140), spacing: 12), count: max(1, min(5, Int((contentWidth + 12) / 192))))
    }
    init(model: NativeArtifactsCatalogModel? = nil, fixture: Bool = false) {
        _model = State(initialValue: model ?? NativeArtifactsCatalogModel())
        self.fixture = fixture
    }
    /// Every registered project's folders, plus any folder open in the side panel. Reading only the
    /// open ones left a project with no session in this copy (iMatch, CRM) showing nothing (Asad 11 Oct).
    private var roots: [String] {
        guard !fixture else { return [] }
        let open = AppModel.shared.sidebar?.projects.map(\.id) ?? []
        // Folders only: a side-panel heading with no folder (runs that belong to no project) is never asked about.
        return ArtifactRules.scanRoots(open: open, registered: NativePROJLabels.shared.projects.flatMap(\.folders))
    }
    var body: some View {
        NativeCatalogPage(title: "Artifacts", subtitle: "Pages, pictures and recordings your sessions and agents made") {
            NativeUIGArtifactsCatalogSearch(model: model)
            NativeCatalogProjectPicker(selection: $model.projectID, projects: NativePROJLabels.shared.projects)
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                NativeUIGArtifactsCatalogControls(model: model)
                if let pending = model.pendingAction {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(pending).font(.caption).foregroundStyle(.secondary) }
                } else if let notice = model.actionNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if let skipped = model.skippedNote {
                    Text(skipped).font(.caption).foregroundStyle(.secondary)
                        .help("These histories were left out; everything else is listed. Their paths are in the app's log.")
                }
                if model.loading {
                    NativeUIGArtifactsCatalogSkeleton(columns: columns)
                } else {
                    ForEach(model.visibleFailures) { failure in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Couldn't read \(NativePROJLabels.shared.name(for: failure.projectID))'s history.")
                                Text(failure.message).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(failure.message)
                            }
                            Spacer()
                            // This card's own folder is read again, in place; nothing else on the page moves.
                            if failure.trying { ProgressView().controlSize(.small) }
                            DeckRetryButton(failure.trying ? "Trying…" : "Try Again", autoRetry: true, instance: failure.id) { model.retry(failure) } // autoRetry: re-reads this project's artifacts from disk
                                .buttonStyle(.bordered).disabled(failure.trying)
                        }.padding(16).background(NativeCatalogTokens.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.visible.isEmpty && model.visibleFailures.isEmpty {
                        NativeUIGArtifactsCatalogEmpty(filtered: !model.search.isEmpty || model.kind != .all)
                    }
                    ForEach(model.days) { day in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(day.title).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text(day.rows.count.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(day.rows) { row in NativeArtifactsCatalogCard(row: row, model: model) }
                            }
                        }
                    }
                }
            }.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }.sheet(item: $model.presented) { presentation in
            switch presentation {
            case .file(let row): NativeArtifactsCatalogPreview(row: row, model: model)
            case .source(let row):
                NativeArtifactsSourcePreview(request: NativeArtifactsSourceRequest(projectRoot: row.root, relativePath: row.artifact.relPath, sessionIDs: row.artifact.sessionIds, title: row.artifact.name))
            }
        }
            .confirmationDialog("Delete \(model.pendingDelete?.artifact.name ?? "artifact") from the list?", isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }), titleVisibility: .visible, presenting: model.pendingDelete) { row in
                NativeSessionButton("Delete from list", role: .destructive) { model.deleteFromList(row); model.pendingDelete = nil }
                NativeSessionButton("Cancel", role: .cancel) { model.pendingDelete = nil }
            } message: { _ in Text("The file and its chat stay where they are.") }
            .alert("Couldn't complete that action", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.clearError() } })) {
                NativeSessionButton("OK") { model.clearError() }
            } message: { Text(model.actionError ?? "") }
            .task { if !fixture { NativePROJLabels.shared.start(); model.show(roots: roots) } }
            .onChange(of: roots) { _, new in if !fixture { model.show(roots: new) } }
            .onDisappear { if !fixture { model.stop() } }
    }
}

struct NativeUIGArtifactsCatalogSearch: View {
    @Bindable var model: NativeArtifactsCatalogModel
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            NativeSessionTextField("Search artifacts", text: $model.search).textFieldStyle(.plain).autocorrectionDisabled()
            if !model.search.isEmpty {
                NativeSessionButton { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Clear search").accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, 12).frame(minWidth: 120, idealWidth: 200, maxWidth: 200).frame(height: 28)
            .background(NativeCatalogTokens.selection, in: Capsule())
    }
}
struct NativeUIGArtifactsCatalogControls: View {
    @Bindable var model: NativeArtifactsCatalogModel
    var body: some View {
        HStack {
            Picker("Artifact type", selection: $model.kind) {
                ForEach(NativeArtifactsCatalogModel.Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl().fixedSize()
            Spacer(minLength: 12)
            Text("Newest first").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct NativeUIGArtifactsCatalogEmpty: View {
    var filtered = false
    var body: some View {
        ContentUnavailableView(filtered ? "No matching artifacts" : "No artifacts yet", systemImage: "doc.richtext", description: Text(filtered ? "Try another search or artifact type." : "Pages, pictures and recordings your sessions make show up here."))
            .frame(maxWidth: .infinity).padding(.top, 80)
    }
}
struct NativeUIGArtifactsCatalogSkeleton: View {
    var columns: [GridItem] = Array(repeating: GridItem(.flexible(minimum: 140), spacing: 12), count: 5)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(NativeCatalogTokens.selection).frame(width: 75, height: 18)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<10, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 9) {
                        Rectangle().fill(NativeCatalogTokens.selection).frame(height: 132)
                        RoundedRectangle(cornerRadius: 3).fill(NativeCatalogTokens.selection).frame(height: 12).padding(.horizontal, 12)
                        RoundedRectangle(cornerRadius: 3).fill(NativeCatalogTokens.selection).frame(height: 9).padding(.horizontal, 12).padding(.bottom, 12)
                    }.background(NativeCatalogTokens.card, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .phaseAnimator([false, true]) { content, phase in content.opacity(phase ? 0.55 : 1) } animation: { _ in reduceMotion ? nil : .easeInOut(duration: 1.2) }
                }
            }
        }.accessibilityLabel("Loading artifacts")
    }
}
