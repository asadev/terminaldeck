import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Small pieces the native project pages share (lane A: Artifacts, Overview,
// Memory, Stays Fixed, Store): the page's project, the scope line above a project
// page (`PageScope`), the "i" note (`HoverNote`), a blank page with a reason
// (`PageEmpty`) and the project gate (`NeedsProject` in PanelView.tsx).

@MainActor
enum DeckProject {
    /// The project the page's views are about — the page's own `activeProjectPath`
    /// from its `sidebar` state, else the first open project (the page's rule).
    static var current: String? {
        let app = AppModel.shared
        return ArtifactRules.currentProject(pageProject: ArtifactRules.pageProject(in: app.sidebar),
                                            projects: app.sidebar?.projects ?? [])
    }

    /// Show another view in the main window, as `onShowPanel(id)` does.
    static func show(_ panelId: String) { AppModel.shared.select(panelId) }

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// The page's own doors, run in the page (E2's page commands): another view with a
/// focus, a file on the Files page, the session inspector, every session at once.
@MainActor
enum DeckPage {
    static func run(_ command: PageCommand) { AppModel.shared.web.run(command) }
    /// `onNavigate(panel, focus)`.
    static func navigate(_ panelId: String, focus: String? = nil) { run(.showPanel(panelId, focus: focus)) }
    /// `onOpenFile(relPath)`.
    static func openFile(_ relPath: String) { run(.openFile(relPath)) }
    /// The page's `features.v2` record (feature id → "on" / "off" / "uninstalled"), read from its storage.
    static func features() async -> [String: String] {
        await withCheckedContinuation { done in
            AppModel.shared.web.webView.evaluateJavaScript("localStorage.getItem('features.v2')") { value, _ in
                done.resume(returning: DashboardRules.featureState(value as? String))
            }
        }
    }
}

/// `PageScope`: the folder a project page is about, and the machine — "path · on this Mac".
struct DeckScopeLine: View {
    let path: String
    var machine = "this Mac"
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(path)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Text("·").accessibilityHidden(true)
            Text("on \(machine)").fixedSize()
            if let detail, !detail.isEmpty {
                Text("·").accessibilityHidden(true)
                Text(detail).lineLimit(1)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `HoverNote`: an "i" that tells its sentence on hover and on press.
struct DeckInfoNote: View {
    let label: String
    let text: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(label)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

/// `PageEmpty`: the view's mark, one line, a reason and at most one thing to do.
struct DeckPageEmpty: View {
    let symbol: String
    let title: String
    var message: String?
    var actionLabel: String?
    var primary = true
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message, !message.isEmpty { Text(message).textSelection(.enabled) }
        } actions: {
            if let actionLabel, let action {
                if primary {
                    Button(actionLabel, action: action).buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button(actionLabel, action: action).controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `NeedsProject` (PanelView.tsx): "<View> needs an open project", and the one button.
struct DeckNeedsProject: View {
    let label: String
    let symbol: String

    var body: some View {
        DeckPageEmpty(symbol: symbol, title: "\(label) needs an open project",
                      actionLabel: "Open a project", action: { AppModel.shared.openProject() })
    }
}

/// The tones the pages colour a verdict or a note with.
extension FixedTone {
    var color: Color {
        switch self {
        case .positive: return .green
        case .warning: return .orange
        case .critical: return .red
        case .muted: return .secondary
        }
    }
}

/// Describe an engine failure in the page's words (`error.message`).
func deckMessage(_ error: any Error) -> String {
    if let wire = error as? EngineWireError { return wire.description }
    return error.localizedDescription
}
