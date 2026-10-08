import SwiftUI
import TerminalDeckNativeCore

/// Round two's controls keep the existing scan, filters, counts and file actions.
struct NativeUIGArtifactsControls: View {
    let model: ArtifactsScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { search; Spacer(minLength: 8); kind; refresh }
                VStack(alignment: .leading, spacing: 8) {
                    search
                    HStack(spacing: 8) { kind; Spacer(minLength: 0); refresh }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { scope; sessions }
                VStack(alignment: .leading, spacing: 8) { scope; sessions }
            }
            if model.refreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating artifacts…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let found = model.found, !found.artifacts.isEmpty {
                Text("\(model.visible.count) of \(found.artifacts.count) artifacts")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let found = model.found, found.truncated {
                Text("Older history was not included in this scan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find an artifact", text: Binding(get: { model.filter }, set: { model.setFilter($0) }))
                .textFieldStyle(.plain).autocorrectionDisabled()
            if !model.filter.isEmpty {
                Button { model.setFilter("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 7))
        .frame(minWidth: 160, maxWidth: 280)
        .accessibilityLabel("Find an artifact")
    }

    private var kind: some View {
        Picker("Artifacts", selection: Binding(get: { model.kind }, set: { model.setKind($0) })) {
            Text("Made here \(model.counts.made)").tag(ArtifactScopeKind.made)
            Text("Changed \(model.counts.changed)").tag(ArtifactScopeKind.changed)
        }
        .pickerStyle(.segmented).nativeUIGGreyControl().labelsHidden().fixedSize()
        .help("Made here shows files an AI created. Changed shows existing artifacts an AI edited.")
    }

    private var scope: some View {
        Picker("Sessions to include", selection: Binding(get: { model.scope }, set: { model.setScope($0) })) {
            Text("This project’s sessions").tag(ArtifactScope.project)
            Text("All sessions").tag(ArtifactScope.all)
        }
        .pickerStyle(.segmented).nativeUIGGreyControl().labelsHidden().fixedSize()
        .help("All sessions also includes work made in this project by sessions started elsewhere.")
    }

    @ViewBuilder private var sessions: some View {
        if model.sessions.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All sessions", selected: model.session == nil) { model.toggleSession(nil) }
                    ForEach(model.sessions) { session in
                        chip(ArtifactRules.sessionChipLabel(session, names: model.sessionNames, now: model.now),
                             selected: model.session == session.sessionId) {
                            model.toggleSession(session.sessionId)
                        }
                    }
                }.padding(.vertical, 1)
            }
        }
    }

    private var refresh: some View {
        Button(action: model.refresh) { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
            .buttonStyle(.borderless).nativeUIGGreyControl()
            .help("Refresh artifacts").disabled(model.refreshing || model.projectPath == nil)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1).font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .nativeUIGSelection(selected)
        }.buttonStyle(.plain)
    }
}

struct NativeUIGArtifactsEmptyState: View {
    let model: ArtifactsScreenModel

    var body: some View {
        NativeUIGArtifactsEmptyContent(canIncludeOtherSessions: canIncludeOtherSessions) {
            model.setScope(.all)
        }
    }

    /// Offer a wider scan only when named sessions exist beyond the completed scan.
    /// The scope control remains available for an intentional wider scan at any time.
    private var canIncludeOtherSessions: Bool {
        model.scope == .project && model.raw.map { model.sessionNames.count > $0.sessionsScanned } == true
    }
}

/// Kept separate so the whole empty frame can be reviewed without opening user data.
struct NativeUIGArtifactsEmptyContent: View {
    var canIncludeOtherSessions = false
    var includeOtherSessions: () -> Void = {}

    var body: some View {
        ContentUnavailableView {
            Label("No artifacts yet", systemImage: "doc.richtext")
        } description: {
            Text("Artifacts are pages, images, documents or recordings an AI makes in a session. Ask an AI working in this project to create one, and it will appear here.")
                .frame(maxWidth: 420)
        } actions: {
            if canIncludeOtherSessions {
                Button("Include sessions from other projects", action: includeOtherSessions)
                    .buttonStyle(.bordered).nativeUIGGreyControl()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
