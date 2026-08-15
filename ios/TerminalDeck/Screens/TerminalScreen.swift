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
 * toolbar, raises it — and the key bar comes with it.
 *
 * ## What happens when the connection drops here
 *
 * The banner appears, `send` starts refusing rather than buffering, and the
 * terminal keeps showing what it already had — which is honest, because that
 * output really did arrive. What it must not do is accept keystrokes into a
 * socket that is gone, so the toolbar's keyboard button goes away with the
 * connection and the key bar's keys refuse through the same path as typing.
 * When the socket comes back the model re-attaches by itself; the button here is
 * for the case where the user wants to force a fresh replay.
 */

import SwiftUI

struct TerminalScreen: View {
    let model: DeckModel
    /**
     * Which machine this session belongs to.
     *
     * Named rather than inferred from "whichever host is current". Session ids
     * come from each machine's own session layer and nothing makes them unique
     * across machines, so a screen that resolved its session against the current
     * host would attach to the wrong machine's session the moment the ids
     * happened to collide — and would silently show a *different* session rather
     * than failing.
     */
    let hostID: String
    let sessionID: String

    @State private var title: String?
    @State private var toast: String?
    /// Bumped by every message so an earlier one's dismissal cannot take a later
    /// one off the screen. Without it a pinch — which changes the text size
    /// several times in a second — leaves the last size on screen for a fraction
    /// of the time it should be, because the first message's timer clears it.
    @State private var toastGeneration = 0
    /// Which picker is up, if any. One `@State` rather than two booleans, so the
    /// impossible state — both sheets at once — cannot be expressed.
    @State private var picking: Picking?
    /// The find bar's state, built on first appearance because it needs the
    /// bridge, and kept across rebuilds because the term is worth keeping.
    @State private var find: FindSession?
    /// The file the share sheet is showing, if any. Written at the moment Share
    /// is chosen — see `ShareOutput`.
    @State private var sharing: SharedFile?

    /// The two ways in. Both run out of process; see `FilePickers.swift`.
    private enum Picking: String, Identifiable {
        case photos
        case files
        var id: String { rawValue }
    }

    /// A written transcript, on its way to the share sheet. Identifiable so the
    /// sheet is presented by *item*: presenting by boolean would open the sheet
    /// a frame before the file existed.
    private struct SharedFile: Identifiable {
        let url: URL
        let subject: String
        var id: String { url.path }
    }

    /// The machine, or nil when it has just been unpaired out from under this
    /// screen. Every use below tolerates that rather than force-unwrapping: an
    /// unpair while a terminal is open is a real sequence, not an impossible one.
    private var host: HostLink? { model.host(hostID) }
    private var bridge: TerminalBridge { host?.bridge(for: sessionID) ?? model.bridge(for: sessionID) }
    private var session: RemoteSession? { host?.session(sessionID) }
    private var connection: ConnectionState { host?.connection ?? .offline }

    var body: some View {
        ZStack {
            Color(Palette.terminalBackground).ignoresSafeArea()

            TerminalHostView(bridge: bridge)
                .ignoresSafeArea(.container, edges: .bottom)

            // Over the terminal rather than above it. See `FindBar`: inserting
            // it into the layout would take rows off the session, which is a
            // `resize` on the wire and a repaint on the far end — for a bar
            // whose whole purpose is to leave the output alone while you read
            // it.
            if let find, find.isOpen {
                VStack(spacing: 0) {
                    FindBar(find: find) { closeFind() }
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        // A material rather than a fill: this floats over the
                        // terminal's own output and has to stay legible against
                        // whatever happens to be underneath it.
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
                    /*
                     * Find, at the top, because on a phone it is the thing this
                     * menu is opened for most.
                     *
                     * Deferred by one turn of the run loop for the same reason
                     * Rename is on the session list: raised in the frame the
                     * menu is dismissing in, the focus request that raises the
                     * keyboard arrives while a presentation is in flight and is
                     * dropped — the bar appears with no keyboard under it and
                     * reads as a field that will not accept typing.
                     */
                    Button {
                        DispatchQueue.main.async { openFind() }
                    } label: {
                        Label("Find in output", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("terminal.find")

                    Divider()

                    /*
                     * Copy Screen, and deliberately *only* Copy Screen.
                     *
                     * There was a "Copy Selection" item here and it had to go,
                     * because it could never do what it said. SwiftTerm clears
                     * its selection on a touch outside the terminal, so reaching
                     * this menu at all destroys the selection on the way — the
                     * item opened, correctly reported that nothing was selected,
                     * and left the pasteboard untouched. Measured on a live
                     * session: the whole screen was selected in one screenshot
                     * and the pasteboard's change count did not move.
                     *
                     * Copying a *selection* therefore lives in the two places a
                     * selection survives, and both of them are *inside* the
                     * terminal: the system callout that a long press puts over
                     * the selection itself, and the `copy` key in the key grid,
                     * which is the terminal's own `inputView`. Both are
                     * exercised in `ClipboardAndTransferUITests`.
                     */
                    Button {
                        show(host?.copyScreen(from: sessionID) ?? "Nothing to copy.")
                    } label: {
                        Label("Copy Screen", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("terminal.copyScreen")
                    Button {
                        host?.paste(into: sessionID)
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!connection.isLive)
                    .accessibilityIdentifier("terminal.paste")

                    /*
                     * Share, which is the other half of Copy rather than a
                     * second one: Copy takes the screen, this takes the whole
                     * scrollback as a file. See `ShareOutput` for why a file and
                     * not a string.
                     */
                    Button {
                        DispatchQueue.main.async { shareOutput() }
                    } label: {
                        Label("Share output", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("terminal.share")

                    Divider()

                    /*
                     * Text size: two ordinary items with the size in their
                     * labels, rather than a submenu or a section.
                     *
                     * The tidier shapes were tried — "Text size ▸" with two
                     * steps inside it, and a `Section` whose header carried the
                     * size — and both cost a tap for nothing: a step is a thing
                     * people do two or three times in a row while deciding, and
                     * a submenu doubles every one of them. The size reads fine
                     * in the label, which is where the eye already is.
                     */
                    Button {
                        step(TextSize.larger(bridge.textSize))
                    } label: {
                        Label("Bigger text — \(TextSize.label(bridge.textSize))",
                              systemImage: "textformat.size.larger")
                    }
                    .disabled(!TextSize.canGoLarger(bridge.textSize))
                    .accessibilityIdentifier("terminal.textLarger")

                    Button {
                        step(TextSize.smaller(bridge.textSize))
                    } label: {
                        Label("Smaller text — \(TextSize.label(bridge.textSize))",
                              systemImage: "textformat.size.smaller")
                    }
                    .disabled(!TextSize.canGoSmaller(bridge.textSize))
                    .accessibilityIdentifier("terminal.textSmaller")

                    // Absent rather than disabled when the Mac cannot receive
                    // one: a control that can only produce a refusal is not a
                    // control. See `DeckModel.canSendFiles`.
                    if host?.canSendFiles == true {
                        Divider()
                        Button {
                            picking = .photos
                        } label: {
                            Label("Send Photo or Video", systemImage: "photo")
                        }
                        .accessibilityIdentifier("terminal.sendPhoto")
                        Button {
                            picking = .files
                        } label: {
                            Label("Send File", systemImage: "doc")
                        }
                        .accessibilityIdentifier("terminal.sendFile")
                    }

                    Divider()
                    Button {
                        host?.reattach(sessionID)
                        show("Re-attaching…")
                    } label: {
                        Label("Re-attach", systemImage: "arrow.clockwise")
                    }
                    .disabled(!connection.isLive)
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
                .disabled(!connection.isLive)
                .accessibilityLabel("Toggle keyboard")
                .accessibilityIdentifier("terminal.keyboard")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if !connection.isLive {
                    // The one thing this screen must never do is look connected when
                    // it is not. The banner is the honest half of that; `send`
                    // refusing rather than buffering is the other.
                    Banner(text: connection.detail, tone: .warning)
                }
                if let upload = host?.upload {
                    // Under the connection banner rather than over the terminal:
                    // the point of watching an upload from a phone is to keep
                    // reading the session while it runs.
                    UploadRow(upload: upload) { host?.clearUpload() }
                }
            }
        }
        // Out-of-process pickers. Nothing in this app reads the photo library, so
        // neither of these prompts for anything — see `FilePickers.swift`.
        .sheet(item: $picking) { which in
            switch which {
            case .photos:
                PhotoPicker { picked in
                    picking = nil
                    hand(picked)
                }
                .ignoresSafeArea()
            case .files:
                DocumentPicker { picked in
                    picking = nil
                    hand(picked)
                }
                .ignoresSafeArea()
            }
        }
        .sheet(item: $sharing) { file in
            ShareSheet(url: file.url, subject: file.subject)
        }
        .onAppear {
            bridge.onTitle = { title = $0 }
            bridge.onCopy = { show(host?.copy(from: sessionID) ?? "Nothing to copy.") }
            bridge.onPaste = { host?.paste(into: sessionID) }
            // A tap into the terminal destroys the selection SwiftTerm is using
            // as the match highlight, so a find bar left standing would be
            // counting matches that are no longer on screen. Tapping in means
            // "I want to type here", and that is the end of the search.
            bridge.onTapped = { closeFind() }
            // The size can change from a gesture as well as from the menu, and
            // a pinch has no other confirmation than the number.
            bridge.onTextSizeChanged = { show(TextSize.label($0)) }
            // A terminal built before the person changed the size catches up
            // here. `setTextSize` is a no-op when it already agrees, which
            // matters: setting the font at all soft-resets the emulator.
            bridge.applyStoredTextSize()
            if find == nil { find = FindSession(terminal: bridge) }
            host?.attach(sessionID)
        }
        .onDisappear {
            bridge.onCopy = nil
            bridge.onPaste = nil
            bridge.onTapped = nil
            bridge.onTextSizeChanged = nil
            // The hold on mouse reporting belongs to a bar that is on screen.
            // Leaving the session without closing the find bar would leave it
            // held, and a finger would stop driving vim in that session.
            find?.close()
            host?.detach(sessionID)
        }
    }

    // MARK: - Find, share, size

    private func openFind() {
        let session = find ?? FindSession(terminal: bridge)
        find = session
        withAnimation(.easeOut(duration: 0.18)) { session.open() }
    }

    private func closeFind() {
        guard let find, find.isOpen else { return }
        withAnimation(.easeOut(duration: 0.18)) { find.close() }
    }

    /**
     * Write what the terminal is holding and hand it to the share sheet.
     *
     * Written here rather than when the menu was built, because the session is
     * still printing while the menu is open — a file composed a frame earlier
     * would be missing the last thing that happened, which is very often the
     * reason somebody is sharing it.
     */
    private func shareOutput() {
        let text = bridge.scrollbackText()
        guard !text.isEmpty else {
            show("There is no output to share.")
            return
        }
        let name = ShareOutput.fileName(session: title ?? session?.title ?? "session")
        guard let url = ShareOutput.write(text, named: name) else {
            show("That could not be written to a file.")
            return
        }
        sharing = SharedFile(url: url, subject: title ?? session?.title ?? "Session output")
    }

    /// One step of the text size, applied and remembered. The toast comes from
    /// the bridge's own callback, so a pinch and this button say the same thing.
    private func step(_ size: CGFloat) {
        bridge.setTextSize(size)
        TextSize.save(bridge.textSize)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(title ?? session?.title ?? "Session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            HStack(spacing: 5) {
                if let session {
                    StatusDot(status: session.status)
                    // Mono, because a status is a word the desktop chose from a
                    // fixed vocabulary rather than a sentence this app wrote.
                    Text(session.status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                } else {
                    Text(connection.label)
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
        toastGeneration += 1
        let generation = toastGeneration
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            // Only the message that scheduled this dismissal may take it away.
            guard generation == toastGeneration else { return }
            withAnimation { toast = nil }
        }
    }

    /// A picker came back. Nil means the user cancelled, which is not an error
    /// and must not produce a message.
    private func hand(_ picked: PickedFile?) {
        guard let picked else { return }
        host?.send(picked, into: sessionID)
    }
}

/**
 * The progress row for a file on its way to the Mac.
 *
 * Three things are on it and each one earns its place: **where the file is going**,
 * which the Mac names before a byte moves and which is the only chance to notice
 * it is the wrong machine; **how far it has got**, drawn from acknowledgements so
 * it measures the Mac rather than this phone's read speed; and **Cancel**, because
 * an upload that stalls on a train has to be stoppable from here — the alternative
 * is force-quitting the app, which leaves the Mac holding a partial file.
 */
private struct UploadRow: View {
    let upload: FileUpload
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(upload.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .sending = upload.phase {
                    ProgressView(value: upload.fraction)
                        .progressViewStyle(.linear)
                        .tint(tint)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: running ? "xmark.circle.fill" : "xmark")
                    .font(.system(size: running ? 18 : 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            // Two words rather than one, because the same button stops a transfer
            // and dismisses a finished one, and VoiceOver should not call those
            // the same thing.
            .accessibilityLabel(running ? "Cancel the upload" : "Dismiss")
            .accessibilityIdentifier("upload.dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("upload.row")
        // The bar moves on its own; VoiceOver should be told rather than left to
        // poll a label that changes eleven times a second.
        .accessibilityElement(children: .combine)
        .accessibilityValue(detail)
    }

    private var running: Bool {
        switch upload.phase {
        case .opening, .sending, .finishing: return true
        case .landed, .failed: return false
        }
    }

    /// The sentence under the name. It is never the same in two states, which is
    /// how a stalled upload is told apart from a slow one.
    private var detail: String {
        switch upload.phase {
        case .opening:
            return "Asking the Mac where to put it…"
        case let .sending(path):
            return "\(byteSize(upload.acked)) of \(byteSize(upload.size)) → \(path)"
        case .finishing:
            return "Checking it arrived intact…"
        case let .landed(path):
            return "Landed at \(path)"
        case let .failed(reason):
            return reason
        }
    }

    private var icon: String {
        switch upload.phase {
        case .opening, .sending, .finishing: return "arrow.up.circle"
        case .landed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// The product's own semantic colours rather than SwiftUI's `.green` and
    /// `.orange`, which are a different green and a different orange from the
    /// ones every other status in this app uses.
    private var tint: Color {
        switch upload.phase {
        case .landed: return Theme.positive
        case .failed: return Theme.critical
        default: return Theme.accent
        }
    }
}
