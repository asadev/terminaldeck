import SwiftUI
import TerminalDeckNativeCore

/// Artifacts, drawn in Swift: the prototypes, pictures and recordings agents
/// made in the page's current project — the same rows, chips, counts and empty
/// states as the web page (src/renderer/components/ArtifactsPanel.tsx), with the
/// file itself shown by Quick Look and opened, revealed or copied on this Mac.
struct NativeArtifactsScreen: View {
    @State private var model = ArtifactsScreenModel()

    private var app: AppModel { AppModel.shared }

    /// The project the page's Artifacts view is about: the page's own word, in
    /// its `sidebar` state (`activeProjectPath`), else the first open project.
    private var project: String? {
        ArtifactRules.currentProject(pageProject: ArtifactRules.pageProject(in: app.sidebar),
                                     projects: app.sidebar?.projects ?? [])
    }

    var body: some View {
        let project = self.project
        Group {
            if app.sidebar == nil {
                LoadingView(message: "Loading Terminal Deck…")
            } else if project == nil {
                ContentUnavailableView {
                    Label("Artifacts needs an open project", systemImage: "doc.text")
                } actions: {
                    Button("Open a project") { app.openProject() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                ArtifactsContent(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onChange(of: project, initial: true) { _, newProject in model.show(project: newProject) }
        .task {
            // Relative times ("5m ago") move on while the page is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.tick()
            }
        }
    }
}

// MARK: - The page

private struct ArtifactsContent: View {
    let model: ArtifactsScreenModel

    var body: some View {
        // The controls sit at the top, as on the web page; the body takes the
        // rest. Without both frames an empty state that does not stretch leaves
        // the whole page centred, with a blank band above the filter bar.
        VStack(spacing: 0) {
            NativeUIGArtifactsControls(model: model)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            ArtifactsBody(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// What to show (filter, Made/Changed) on the first row; which work to read
/// (scope, sessions) on the second; then the one-line summary.
private struct ArtifactsControls: View {
    let model: ArtifactsScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ArtifactsFilterField(text: Binding(get: { model.filter }, set: { model.setFilter($0) }))
                    .frame(maxWidth: 280)
                Spacer(minLength: 8)
                let counts = model.counts
                Picker("What to show", selection: Binding(get: { model.kind }, set: { model.setKind($0) })) {
                    Text("Made here \(counts.made)").tag(ArtifactScopeKind.made)
                    Text("Changed \(counts.changed)").tag(ArtifactScopeKind.changed)
                }
                .pickerStyle(.segmented).nativeUIGGreyControl()
                .labelsHidden()
                .fixedSize()
                .help("Made here: files an agent wrote whole — the things it produced. Changed: files that already existed and an agent edited.")
                Button(action: model.refresh) {
                    Label("Read Again", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Read this project’s history again")
                .disabled(model.projectPath == nil)
            }

            HStack(spacing: 10) {
                Picker("Which sessions to read", selection: Binding(get: { model.scope }, set: { model.setScope($0) })) {
                    Text("This project’s sessions").tag(ArtifactScope.project)
                    Text("Every session").tag(ArtifactScope.all)
                }
                .pickerStyle(.segmented).nativeUIGGreyControl()
                .labelsHidden()
                .fixedSize()
                .help("Every session also reads sessions started elsewhere that wrote into this folder")

                let sessions = model.sessions
                if sessions.count > 1 {
                    Divider().frame(height: 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ArtifactsChip(title: "All sessions", on: model.session == nil) { model.toggleSession(nil) }
                            ForEach(sessions) { entry in
                                ArtifactsChip(title: ArtifactRules.sessionChipLabel(entry, names: model.sessionNames, now: model.now),
                                     on: model.session == entry.sessionId) {
                                    model.toggleSession(entry.sessionId)
                                }
                                .help(entry.sessionId)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            HStack(spacing: 6) {
                if model.refreshing {
                    ProgressView().controlSize(.mini)
                }
                Text(model.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 16)
        }
    }
}

private struct ArtifactsFilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField("Filter by name…", text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 7))
        .accessibilityLabel("Filter artifacts by name")
    }
}

/// One pressable chip; the lit one is filled.
private struct ArtifactsChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(on ? AnyShapeStyle(Color.primary.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                            in: .capsule)
                .overlay(Capsule().strokeBorder(on ? Color.secondary.opacity(0.45) : .clear, lineWidth: 1))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Body: a reason, an empty page, or the list and the artifact

private struct ArtifactsBody: View {
    let model: ArtifactsScreenModel

    var body: some View {
        switch model.list {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let message):
            // A failed scan is a page with a reason and a way out.
            ContentUnavailableView {
                Label("Could not read this project’s history", systemImage: "doc.text")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try again", action: model.retry)
                    .buttonStyle(.borderedProminent)
            }

        case .ready:
            if let found = model.found, found.artifacts.isEmpty {
            NativeUIGArtifactsEmptyState(model: model)
            } else {
                HSplitView {
                    ArtifactsList(model: model)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 520)
                    Group {
                        if let current = model.current {
                            ArtifactDetail(model: model, artifact: current)
                                .id(current.relPath)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// Two different empty pages: a folder nothing was written in, and one whose
/// every file was prose — the second says which rule emptied it.
private struct EmptyArtifacts: View {
    let model: ArtifactsScreenModel
    let found: ArtifactList
    @State private var showNote = false

    var body: some View {
        let hidden = model.hidden
        ContentUnavailableView {
            Label(hidden > 0 ? "No prototypes here yet" : "Nothing produced here yet", systemImage: "doc.text")
        } description: {
            Text(hidden > 0 ? ArtifactRules.nothingButFiles(found, hidden: hidden) : ArtifactRules.nothingFound(found))
                .textSelection(.enabled)
        } actions: {
            HStack {
                if model.scope == .project {
                    Button("Read every session") { model.setScope(.all) }
                }
                Button {
                    showNote.toggle()
                } label: {
                    Label(hidden > 0 ? "What counts as an artifact" : "What was read", systemImage: "info.circle")
                }
                .buttonStyle(.link)
                .popover(isPresented: $showNote, arrowEdge: .bottom) {
                    Text(note(hidden: hidden))
                        .font(.callout)
                        .frame(width: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                }
            }
        }
    }

    private func note(hidden: Int) -> String {
        if hidden > 0 {
            return "A prototype, a picture or a recording — the things an agent makes to be looked at. Its notes, plans and source are files, and Files is the page that reads them."
        }
        return model.scope == .project
            ? "Only the sessions started in this folder were read. Read every session to include agents launched from a parent folder."
            : "No session on this machine has written or edited a file inside this folder."
    }
}

// MARK: - The list

private struct ArtifactsList: View {
    let model: ArtifactsScreenModel

    var body: some View {
        let visible = model.visible
        List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
            ForEach(visible) { artifact in
                ArtifactRow(artifact: artifact, now: model.now)
                    .tag(artifact.relPath as String?)
            }
            if visible.isEmpty {
                Text(ArtifactRules.noRowsNote(filter: model.filter, session: model.session, kind: model.kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .selectionDisabled()
            }
        }
        .listStyle(.inset)
        .accessibilityLabel(model.kind == .made ? "Things this project’s agents made" : "Artifacts this project’s agents changed")
        .contextMenu(forSelectionType: String.self) { ids in
            if let artifact = artifact(ids, in: visible) {
                ArtifactActionsMenu(model: model, artifact: artifact)
            }
        } primaryAction: { ids in
            // Double-click or Return opens it, as Finder does.
            if let artifact = artifact(ids, in: visible), artifact.onDisk != nil { model.open(artifact) }
        }
    }

    private func artifact(_ ids: Set<String>, in visible: [Artifact]) -> Artifact? {
        guard let id = ids.first else { return nil }
        return visible.first(where: { $0.relPath == id })
    }
}

/// A row is a thing: its name, when, what kind, how big — the folder last and quietest.
private struct ArtifactRow: View {
    let artifact: Artifact
    let now: Double

    var body: some View {
        let kind = ArtifactRules.kindOf(artifact.relPath)
        let folder = ArtifactRules.directoryOf(artifact.relPath)
        HStack(spacing: 10) {
            Image(systemName: ArtifactSymbols.symbol(forKind: kind))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(artifact.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(ArtifactRules.relativeTime(artifact.lastAt, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(kind)
                    if let disk = artifact.onDisk {
                        Text(ArtifactRules.formatBytes(disk.bytes)).monospacedDigit()
                    } else {
                        // A fact, not a warning: agents write scratch files and delete them.
                        ArtifactsTag(text: "not on disk")
                    }
                    if !folder.isEmpty {
                        Text(folder)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .help(artifact.relPath)
    }
}

struct ArtifactsTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
    }
}

enum ArtifactSymbols {
    static func symbol(forKind kind: String) -> String {
        switch kind {
        case "Web page": return "globe"
        case "Image": return "photo"
        case "Document": return "doc.richtext"
        case "Video": return "film"
        case "Sound": return "waveform"
        default: return "doc"
        }
    }
}

/// The same actions on a row's menu and in the detail heading.
struct ArtifactActionsMenu: View {
    let model: ArtifactsScreenModel
    let artifact: Artifact

    var body: some View {
        let onDisk = artifact.onDisk != nil
        Button(ArtifactRules.openLabel(ArtifactRules.previewKindOf(artifact.relPath))) { model.open(artifact) }
            .disabled(!onDisk)
        Button("Show in Finder") { model.reveal(artifact) }
            .disabled(!onDisk)
        Divider()
        Button("Copy Path") { model.copyPath(artifact) }
    }
}
