import AppKit
import SwiftUI
import TerminalDeckNativeCore

// A session in a window of its own (`popout/`): the main window's "Move to new
// window" button opens one (the page's `popOutSession` path in the native shell:
// a screen window showing the session), and while it is out the main window's
// pane shows the card that leads to it (`PoppedOutCard`).

/// Which sessions are out in a window of their own, and which window.
@MainActor
@Observable
final class NativePoppedSessions {
    static let shared = NativePoppedSessions()
    private var windows: [String: WeakWindow] = [:]

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    /// The window a session is out in, while it is still open.
    func window(for sessionId: String) -> NSWindow? {
        guard let window = windows[sessionId]?.window, window.isVisible else { return nil }
        return window
    }

    /// A screen for this session appeared in `window`: out, unless it is the main window.
    func shown(_ sessionId: String, in window: NSWindow?) {
        guard let window else { return }
        if window === AppModel.shared.web.webView.window {
            return
        }
        windows[sessionId] = WeakWindow(window)
    }

    /// Its own window closed: back in the main window.
    func gone(_ sessionId: String, from window: NSWindow?) {
        if let window, windows[sessionId]?.window !== window { return }
        windows[sessionId] = nil
    }

    /// "Move to new window": the same message the page sends in the native shell.
    func popOut(_ sessionId: String, title: String?) {
        AppModel.shared.openScreenWindow(ScreenRef(kind: .session, id: sessionId), title: title)
    }

    /// "Show window".
    func show(_ sessionId: String) {
        NativeFront.onlyForPerson("session window") { window(for: sessionId)?.makeKeyAndOrderFront(nil) }
    }

    /// "Move back here": its window closes and the session is drawn here again.
    func dock(_ sessionId: String) {
        window(for: sessionId)?.performClose(nil)
        windows[sessionId] = nil
    }

    /// `where`: which display it is on, said only when there is more than one.
    func whereShown(_ sessionId: String) -> String {
        guard NSScreen.screens.count > 1, let screen = window(for: sessionId)?.screen else { return "" }
        return screen.localizedName
    }
}

/// `PoppedOutCard`: "Open in its own window", Show window, Move back here.
struct NativePoppedOutCard: View {
    let sessionId: String

    var body: some View {
        let place = NativePoppedSessions.shared.whereShown(sessionId)
        NativePageEmpty(symbol: "arrow.up.forward.square", title: "Open in its own window",
                        message: { if !place.isEmpty { Text("On \(place)") } },
                        action: PageEmptyAction(label: "Show window", primary: true) { NativePoppedSessions.shared.show(sessionId) },
                        hint: { EmptyView() },
                        extra: { Button("Move back here") { NativePoppedSessions.shared.dock(sessionId) }.buttonStyle(.link) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reports which window a view is in (and when it leaves), for the pop-out bookkeeping.
struct NativeWindowReader: NSViewRepresentable {
    let changed: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) { nsView.changed = changed }

    final class ReaderView: NSView {
        var changed: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            changed?(window)
        }
    }
}
