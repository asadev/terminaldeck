import AppKit
import Quartz
import SwiftUI
import TerminalDeckNativeCore

/// The artifact itself, first — rendered by Quick Look — with how it came to
/// be behind a History switch, and the actions that hand it to this Mac.
struct ArtifactDetail: View {
    let model: ArtifactsScreenModel
    let artifact: Artifact

    private enum PageMode: Hashable { case preview, source }
    @State private var pageMode: PageMode = .preview

    var body: some View {
        let previewKind = ArtifactRules.previewKindOf(artifact.relPath)
        VStack(alignment: .leading, spacing: 0) {
            header(previewKind)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            content(previewKind)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func header(_ previewKind: ArtifactRules.PreviewKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(artifact.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(artifact.relPath)
                .textSelection(.enabled)
            Text(ArtifactRules.detailMeta(artifact, now: model.now))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                // The artifact, or how it came to be: two words, not two panes.
                Toggle(isOn: Binding(get: { model.showHistory }, set: { _ in model.toggleHistory() })) {
                    Text(model.showHistory ? "Show the file" : historyLabel)
                }
                .toggleStyle(.button).nativeUIGGreyControl()

                if artifact.onDisk != nil {
                    Button(ArtifactRules.openLabel(previewKind)) { model.open(artifact) }
                        .buttonStyle(.borderedProminent)
                    Button("Show in Finder") { model.reveal(artifact) }
                }
                Menu {
                    ArtifactActionsMenu(model: model, artifact: artifact)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")

                Spacer(minLength: 0)

                if previewKind == .page, artifact.onDisk != nil, !model.showHistory {
                    Picker("Show", selection: $pageMode) {
                        Text("Preview").tag(PageMode.preview)
                        Text("Source").tag(PageMode.source)
                    }
                    .pickerStyle(.segmented).nativeUIGGreyControl()
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .controlSize(.regular)

            if let failed = model.openFailed {
                Text(failed)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historyLabel: String {
        let summary = ArtifactRules.changeSummary(artifact)
        return summary.isEmpty ? "History" : "History \(summary)"
    }

    @ViewBuilder
    private func content(_ previewKind: ArtifactRules.PreviewKind) -> some View {
        if model.showHistory {
            ArtifactHistoryView(model: model, relPath: artifact.relPath)
                .task(id: model.history[artifact.relPath] == nil) {
                    if model.history[artifact.relPath] == nil { model.ensureHistory() }
                }
        } else if artifact.onDisk == nil {
            ArtifactsNote("An agent made this and it is not on disk any more. Its history is still here.")
        } else if let url = model.url(for: artifact) {
            if previewKind == .page && pageMode == .source {
                ArtifactsSourceView(state: model.source[artifact.relPath])
                    .task(id: model.source[artifact.relPath] == nil) {
                        if model.source[artifact.relPath] == nil { model.loadSource(artifact) }
                    }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if previewKind == .page {
                        Text("A page. Run it in your browser to use it — its stylesheet, its script and its relative links all resolve from the folder it lives in.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    ArtifactsQuickLook(url: url, revision: artifact.onDisk?.modifiedAt ?? 0)
                }
            }
        } else {
            ArtifactsNote("That file could not be read.")
        }
    }
}

/// A quiet sentence, centred, in place of content.
struct ArtifactsNote: View {
    let text: String
    var busy = false

    init(_ text: String, busy: Bool = false) {
        self.text = text
        self.busy = busy
    }

    var body: some View {
        VStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Quick Look

/// The file as the Mac draws it: pages, pictures, PDFs, video and sound.
struct ArtifactsQuickLook: NSViewRepresentable {
    let url: URL
    /// The file's modified time: when it moves, the preview is drawn again.
    let revision: Double

    final class Coordinator {
        var url: URL?
        var revision: Double = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false
        view.shouldCloseWithWindow = false
        show(in: view, context: context)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        show(in: view, context: context)
    }

    private func show(in view: QLPreviewView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.url != url {
            coordinator.url = url
            coordinator.revision = revision
            view.previewItem = url as NSURL
        } else if coordinator.revision != revision {
            coordinator.revision = revision
            view.refreshPreviewItem()
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

// MARK: - A page's markup

private struct ArtifactsSourceView: View {
    let state: ArtifactsScreenModel.SourceState?

    var body: some View {
        switch state {
        case nil, .loading?:
            ArtifactsNote("Opening it…", busy: true)
        case .read(.text(let text))?:
            ArtifactsPlainText(text: text)
        case .read(.note(let message))?, .read(.error(let message))?:
            ArtifactsNote(message)
        }
    }
}

/// Selectable monospaced text, without SwiftUI laying out a megabyte of it.
struct ArtifactsPlainText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 12, height: 10)
            textView.string = text
        }
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}

// MARK: - History

private struct ArtifactHistoryView: View {
    let model: ArtifactsScreenModel
    let relPath: String

    var body: some View {
        switch model.history[relPath] {
        case nil, .loading?:
            ArtifactsNote("Reading the changes…", busy: true)
        case .error(let message)?:
            VStack(spacing: 10) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try again", action: model.retryHistory)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let history)?:
            if history.changes.isEmpty {
                ArtifactsNote("No recorded changes for this file.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(history.changes.enumerated()), id: \.offset) { _, change in
                            ArtifactsChangeCard(change: change, now: model.now)
                        }
                        if history.truncated {
                            Text("Older changes to this file were not read — the scan stops at the newest sessions.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct ArtifactsChangeCard: View {
    let change: ArtifactChange
    let now: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(change.action == .write ? "Wrote" : "Edited")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(change.action == .write ? Color.accentColor : Color.primary)
                Text(change.tool)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if change.replaceAll { ArtifactsTag(text: "every occurrence") }
                if change.clipped { ArtifactsTag(text: "shortened") }
                Spacer(minLength: 6)
                Text(ArtifactRules.relativeTime(change.at, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ArtifactsChangeBody(change: change)
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// A write is shown as its text (there is no "before" to line up against); an
/// edit as the lines it removed and added.
private struct ArtifactsChangeBody: View {
    let body_: ArtifactsDiff.Body

    init(change: ArtifactChange) {
        body_ = ArtifactsDiff.body(for: change)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch body_ {
            case .write(let text, let more):
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                if let more { ArtifactsMoreLine(text: more) }
            case .edit(let lines, let more):
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        ArtifactsDiffLine(line: line)
                    }
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
                if let more { ArtifactsMoreLine(text: more) }
            }
        }
    }
}

private struct ArtifactsDiffLine: View {
    let line: ArtifactsDiff.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.kind.mark)
                .foregroundStyle(markColor)
                .frame(width: 10, alignment: .center)
                .accessibilityHidden(true)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 0.5)
        .background(background)
    }

    private var markColor: Color {
        switch line.kind {
        case .add: return .green
        case .del: return .red
        case .same: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .add: return .green.opacity(0.14)
        case .del: return .red.opacity(0.14)
        case .same: return .clear
        }
    }
}

private struct ArtifactsMoreLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }
}
