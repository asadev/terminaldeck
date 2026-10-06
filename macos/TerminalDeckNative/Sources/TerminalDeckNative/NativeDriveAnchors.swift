import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

// Where Hoot's tour can point, natively — the Swift side of the page's
// `data-drive-anchor` attributes and its terminal registry (driving/focus-target.ts,
// terminal-registry.ts). A view that a tour stop can name reports its frame:
//
//     GitFileRow(file).driveAnchor(DriveAnchor.gitFile(cwd: root, path: file.path).id)
//     UsageBar(session).driveAnchor(DriveAnchor.usage(sessionId: id).id)
//     ChatMessage(m).driveAnchor(DriveAnchor.message(messageId: m.id).id)
//     SidebarRow(s).driveAnchor(DriveAnchor.sessionRow(sessionId: s.id).id)
//     BrowserStage().driveAnchor(DriveAnchors.pageId)
//
// and a native terminal registers what it shows, so a quote in it can be boxed:
//
//     DriveAnchors.shared.terminals[sessionId] = { [weak self] in self?.driveView() }

@MainActor
@Observable
final class DriveAnchors {
    static let shared = DriveAnchors()

    /// The browser page's anchor id (the web's `.bw-stage`).
    static let pageId = "page"

    /// Frames in the main window's content coordinates (top-left origin), by anchor id.
    private(set) var frames: [String: CGRect] = [:]

    /// A session's terminal, as the focus layer reads it — nil while it is not open.
    @ObservationIgnored var terminals: [String: () -> DriveTerminalView?] = [:]

    /// Scroll a session's terminal so a buffer line is near the top (`term.scrollToLine`).
    @ObservationIgnored var scrollers: [String: (Int) -> Void] = [:]

    func set(_ id: String, _ rect: CGRect?) {
        if frames[id] == rect { return }
        frames[id] = rect
    }

    func frame(_ id: String) -> DriveRect? {
        frames[id].map { DriveRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
    }

    func terminal(_ sessionId: String) -> DriveTerminalView? { terminals[sessionId]?() }
}

private struct DriveAnchorModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
                DriveAnchors.shared.set(id, rect)
            }
            .onDisappear { DriveAnchors.shared.set(id, nil) }
    }
}

extension View {
    /// Let Hoot's tour box this view (`data-drive-anchor="<id>"` on the page).
    func driveAnchor(_ id: String) -> some View { modifier(DriveAnchorModifier(id: id)) }
}
