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
    @Environment(\.colorScheme) private var windowScheme

    var body: some View {
        let isMain = window == nil || window === AppModel.shared.web.webView.window
        Group {
            if isMain, NativePoppedSessions.shared.window(for: session.sessionId) != nil {
                NativePoppedOutCard(sessionId: session.sessionId)
            } else {
                VStack(spacing: 0) {
                    bar()
                    // A refusal gets its own row, including in split panes whose header has a fixed height.
                    if case .local = session.target, session.info?.provider == "claude" {
                        NativeDefaultClaudeRefusal(sessionId: session.sessionId, cwd: session.info?.cwd,
                            title: session.info?.title ?? "", profileId: session.info?.profileId)
                    }
                    DeploySessionStrip(sessionID: session.sessionId)   // DEPLOY-PIPELINE: live when asked for here
                    NativeUIGSessionSimulatorHost(session: session) {
                        ZStack(alignment: .bottom) {
                            // A chat session shows Hoot's chat screen itself, on its own conversation (Asad, 13 Oct).
                            // One identity per session: a split pane or swarm cell that changes session must not keep
                            // the previous session's chat (its @State model, its box and draft) on the new one.
                            if session.isChat { NativeHootChat(model: session.chatModel()).environment(\.sessionChatUsage, session.usageState).id(session.sessionId) }
                            else { NativeTerminalHost(session: session) }
                            // 28 Oct: another device took the session while it was showing here. At once in, faded out
                            // when it is back (the terminal under it is already redrawn for this Mac by then).
                            if !session.isChat, session.end == nil, session.showsMoveBack {
                                NativeSessionElsewhereCard(session: session)
                                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                            }
                            if let note = session.note {
                                TerminalNoteLine(text: note)
                                    .padding(8)
                                    .allowsHitTesting(false)
                            } else if !session.isChat, session.end == nil, session.keyboardInPhone {
                                // 28 Oct (bug B): his keys are going into the phone beside this session, not here.
                                NativeTerminalKeyboardElsewhere(session: session)
                                    .padding(8)
                            }
                            // Finished chats show their own saved transcript and status.
                            if !session.isChat, let end = session.end {
                                NativeSessionEndedCard(notice: end.notice, act: { session.act($0) })
                                    .transition(.opacity)
                            }
                        }
                        .background(session.isChat ? DeckTokens.chatPage : Color(nsColor: session.ground))
                        .animation(.easeOut(duration: 0.14), value: session.ended)
                    }
                }
                // Split and swarm headers belong to this terminal's paper too (a chat keeps the window's own look).
                .background(session.isChat ? DeckTokens.chatPage : Color(nsColor: session.ground))
                .environment(\.colorScheme, session.isChat ? windowScheme : (NativeSessionChrome.scheme.isLight ? .light : .dark))
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

/// "Open on Asad's iPhone" with "Move back here" (Asad, 28 Oct): the session was chosen on another device while
/// this tab showed it, and its program now draws for that device's screen. Drawn like the card of a session open in
/// its own window (`NativePoppedOutCard`, his reference), on the terminal's own paper.
struct NativeSessionElsewhereCard: View {
    let session: NativeTerminalSession

    var body: some View {
        let owner = session.owner
        NativePageEmpty(symbol: owner?.kind == "computer" ? "desktopcomputer" : "iphone",
                        title: "Open on \(owner?.displayName ?? "another device")",
                        message: { EmptyView() },
                        action: PageEmptyAction(label: "Move back here", primary: true, busy: session.takingBack) { session.moveBackHere() },
                        hint: { EmptyView() },
                        extra: { EmptyView() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: session.ground))
            .contentShape(Rectangle())
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
