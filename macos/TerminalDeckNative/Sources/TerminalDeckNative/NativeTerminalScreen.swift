import SwiftUI
import TerminalDeckNativeCore

/// A session drawn in Swift — on this Mac, on one of his paired machines, or a
/// shell on a server: its
/// bar (name, folder, account or machine, the session's own controls) over a
/// native terminal, with the card that says when it is over.
///
/// `NativeTerminalScreen.handles(_:)` says which tab ids: a held row or a browser
/// tab is not a session's terminal.
struct NativeTerminalScreen: View {
    let sessionId: String

    /// Whether this screen can show that tab id: a local pty, a session on a paired
    /// machine, or a shell on a server.
    static func handles(_ id: String) -> Bool {
        SessionTarget(tabId: id) != nil
    }

    var body: some View {
        // One identity per session, so a different session never inherits this one's state.
        NativeTerminalPane(session: NativeTerminalSessions.shared.session(for: sessionId))
            .id(sessionId)
    }
}

private struct NativeTerminalPane: View {
    let session: NativeTerminalSession

    var body: some View {
        NativeSessionBody(session: session) {
            NativeSessionHeader(session: session)
        }
    }
}

/// A session's terminal with what is drawn over it — the transfer line and the
/// ended card — under whatever bar its place gives it (the session's own bar on
/// its own; a pane's bar, or none for the host pane, in a split; a cell head in
/// swarm). While the session is out in a window of its own, the main window
/// shows the card that leads to it instead.
struct NativeSessionBody<Bar: View>: View {
    let session: NativeTerminalSession
    @ViewBuilder var bar: () -> Bar
    @State private var window: NSWindow?

    var body: some View {
        let isMain = window == nil || window === AppModel.shared.web.webView.window
        Group {
            if isMain, NativePoppedSessions.shared.window(for: session.sessionId) != nil {
                NativePoppedOutCard(sessionId: session.sessionId)
            } else {
                VStack(spacing: 0) {
                    bar()
                    ZStack(alignment: .bottom) {
                        NativeTerminalHost(session: session)
                        if let note = session.note {
                            TerminalNoteLine(text: note)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                        if let end = session.end {
                            NativeSessionEndedCard(notice: end.notice, act: { session.act($0) })
                                .transition(.opacity)
                        }
                    }
                    .background(Color(nsColor: session.ground))
                    .animation(.easeOut(duration: 0.14), value: session.ended)
                }
                // Split and swarm headers belong to this terminal's paper too.
                .background(Color(nsColor: session.ground))
                .environment(\.colorScheme, NativeSessionChrome.scheme.isLight ? .light : .dark)
                .onAppear { session.screenAppeared() }
                .onDisappear { session.screenDisappeared() }
            }
        }
        .background(NativeWindowReader { now in
            if let old = window, old !== now { NativePoppedSessions.shared.gone(session.sessionId, from: old) }
            window = now
            NativePoppedSessions.shared.shown(session.sessionId, in: now)
        })
    }
}

/// The one line a refused paste, drop or copy says, or a transfer in flight (`TransferNote`).
struct TerminalNoteLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}
