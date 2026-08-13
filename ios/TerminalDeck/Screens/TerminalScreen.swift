/**
 * One session, full screen.
 *
 * Attaches on appear and detaches on disappear. Detaching matters: the desktop
 * fans output out to every attached client, and a phone that never says it has
 * gone keeps a session pushing bytes at a socket nobody is reading.
 *
 * The keyboard is not raised automatically. A terminal that grabs the keyboard
 * on entry covers half of the thing the person came to look at, and the usual
 * reason to open this screen from a phone is to read what an agent has been
 * doing, not to type at it. Tapping the terminal, or the keyboard button in the
 * toolbar, raises it — and `KeyboardAccessory` comes with it.
 *
 * ## What happens when the connection drops here
 *
 * The banner appears, `send` starts refusing rather than buffering, and the
 * terminal keeps showing what it already had — which is honest, because that
 * output really did arrive. What it must not do is accept keystrokes into a
 * socket that is gone, so the toolbar's keyboard button goes away with the
 * connection and the accessory's keys refuse through the same path as typing.
 * When the socket comes back the model re-attaches by itself; the button here is
 * for the case where the user wants to force a fresh replay.
 */

import SwiftUI

struct TerminalScreen: View {
    let model: DeckModel
    let sessionID: String

    @State private var title: String?
    @State private var toast: String?

    private var bridge: TerminalBridge { model.bridge(for: sessionID) }
    private var session: RemoteSession? { model.session(sessionID) }

    var body: some View {
        ZStack {
            Color(Palette.terminalBackground).ignoresSafeArea()

            TerminalHostView(bridge: bridge)
                .ignoresSafeArea(.container, edges: .bottom)

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                        // Named so a UI test can find it, and because a
                        // transient message is worth announcing to VoiceOver
                        // rather than leaving as a flash of text.
                        .accessibilityIdentifier("terminal.toast")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(title ?? session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        show(model.copy(from: sessionID))
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.paste(into: sessionID)
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!model.connection.isLive)
                    Divider()
                    Button {
                        model.reattach(sessionID)
                        show("Re-attaching…")
                    } label: {
                        Label("Re-attach", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.connection.isLive)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Session actions")
                .accessibilityIdentifier("terminal.actions")

                Button {
                    // Toggle rather than raise: the same button has to put it
                    // away again.
                    if bridge.isFocused { bridge.blur() } else { bridge.focus() }
                } label: {
                    Image(systemName: "keyboard")
                }
                .disabled(!model.connection.isLive)
                .accessibilityLabel("Toggle keyboard")
                .accessibilityIdentifier("terminal.keyboard")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.connection.isLive {
                // The one thing this screen must never do is look connected when
                // it is not. The banner is the honest half of that; `send`
                // refusing rather than buffering is the other.
                Banner(text: model.connection.detail, tone: .warning)
            }
        }
        .onAppear {
            bridge.onTitle = { title = $0 }
            bridge.onCopy = { show(model.copy(from: sessionID)) }
            bridge.onPaste = { model.paste(into: sessionID) }
            model.attach(sessionID)
        }
        .onDisappear {
            bridge.onCopy = nil
            bridge.onPaste = nil
            model.detach(sessionID)
        }
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text(title ?? session?.title ?? "Session")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                if let session {
                    StatusDot(status: session.status)
                    Text(session.status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                } else {
                    Text(model.connection.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                }
            }
        }
    }

    /// Copy and paste are silent by nature; without this the buttons feel
    /// broken even when they worked.
    ///
    /// Two and a half seconds, which is the shortest anyone has measured people
    /// reliably reading a four-word message — and long enough that a UI test
    /// polling for it does not race the animation that dismissed the menu.
    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }
}
