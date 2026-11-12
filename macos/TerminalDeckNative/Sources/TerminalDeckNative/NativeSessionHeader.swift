import SwiftUI
import TerminalDeckNativeCore

/// A session's bar, as the page's window toolbar drew it over a session: its name
/// (double-click or F2 to rename), then "where and who" — the folder, and the
/// account (or, for a session on another machine, which machine) — and at the
/// trailing end the session's own controls.
struct NativeSessionHeader: View {
    let session: NativeTerminalSession
    /// The window's own bar carries the mode switch; a pop-out window's does not.
    var showsModeSwitch = true
    @Environment(\.colorScheme) private var windowScheme

    var body: some View {
        let header = TerminalHeader.make(info: session.info, railTitle: railItem?.title,
                                         status: session.status ?? TerminalStatus.parse(railItem?.status), ended: session.ended)
        HStack(alignment: .center, spacing: 8) {
            // A pop-out window's bar marks the title with the status dot (PopoutWindow titleMark);
            // the main window's bar has none.
            if !inMainWindow {
                NativeSessionStatusDot(status: header.status)
            }
            // The page's window bar: the name on its own line, "where and who" under it.
            VStack(alignment: .leading, spacing: 1) {
                NativeSessionTitle(title: sharedTitle(fallback: header.title), rename: renamer)
                HStack(spacing: 5) {
                    if !header.folderPath.isEmpty {
                        NativeFolderChip(path: header.folderPath)
                    }
                    if let machine = machineName {
                        if !header.folderPath.isEmpty { ChipSeparator() }
                        Text("on \(machine)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    switch session.target {
                    case .local:
                        if !header.folderPath.isEmpty { ChipSeparator() }
                        NativeLocalAccountChip(session: session)
                    case .machine:
                        NativeMachineAccountChip(session: session)
                    case .server:
                        if !header.folderPath.isEmpty { ChipSeparator() }
                        NativeServerAccountChip(session: session)
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // Model, effort and fast mode are read off a terminal's screen. A chat session keeps them under its box and
            // only its usage (plan limits, context window) up here, where it always was.
            if !session.isChat {
                NativeSessionControls(session: session)
                    .layoutPriority(0)
            } else {
                if NativeSessionFeatures.shared.value.usageOn {
                    NativeUsageBar(usage: session.usageState, provider: session.info?.provider ?? "claude", tight: false)
                }
            }
            NativeUIGSessionSimulatorButton(session: session)
            if showsModeSwitch, inMainWindow, let layout = AppModel.shared.tabs?.layout, layout.modeSwitch {
                NativeModeSwitch(layout: layout)
            }
            if popOutOffered {
                NativeSessionButton {
                    NativePoppedSessions.shared.popOut(session.sessionId, title: header.title)
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Move to new window")
                .accessibilityLabel("Move to new window")
                .accessibilityAction {
                    NativePoppedSessions.shared.popOut(session.sessionId, title: header.title)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        // A chat session's bar wears the window's own look, like the chat under it.
        .foregroundStyle(session.isChat ? AnyShapeStyle(.primary) : AnyShapeStyle(NativeSessionChrome.ink))
        .background(session.isChat ? Color.clear : Color(nsColor: session.ground))
        .environment(\.colorScheme, session.isChat ? windowScheme : (NativeSessionChrome.scheme.isLight ? .light : .dark))
        // Grab the header to move this session beside the simulator or another pane; outside the window it pops out.
        .nativePaneDrag(.pane(tabId: session.sessionId), title: header.title, enabled: inMainWindow)
        .nativePopoutDragBack() // in a pop-out: drag it over the main window to merge it back
        .background(NativeWindowReader { window in
            inMainWindow = window == nil || window === AppModel.shared.web.webView.window
        })
        .overlay(alignment: .bottomTrailing) {
            NativeSessionControlsNotice(state: session.controlsState)
                .padding(.trailing, 12)
                .offset(y: 30)
                .allowsHitTesting(session.controlsState.notice != nil)
        }
        .zIndex(1)
        .onAppear { NativeSessionFeatures.shared.refresh() }
    }

    /// "Move to new window" (`popOutTarget`): a session on this Mac, in the main window,
    /// not already out — and not the assistant's own.
    private var popOutOffered: Bool {
        guard case .local = session.target, inMainWindow, !(AppModel.shared.tabs?.layout?.swarm ?? false) else { return false }
        return NativePoppedSessions.shared.window(for: session.sessionId) == nil
    }

    @State private var inMainWindow = true

    /// The rail's own row for this session, so its name and dot are the rail's.
    private var railItem: SidebarItem? {
        for project in AppModel.shared.sidebar?.projects ?? [] {
            if let item = project.sessions.first(where: { $0.id == session.sessionId }) { return item }
        }
        return nil
    }

    private func sharedTitle(fallback: String) -> String {
        guard case .local = session.target else { return fallback }
        if let railItem { return SIDEBARSessionLine.title(railItem, store: SIDEBARProjectStore.shared) }
        return SIDEBARSessionLine.title(given: NativeSessionNames.shared.names[session.sessionId],
            own: SIDEBARProjectStore.shared.sessionTitles[session.sessionId] ?? session.info?.title,
            rail: fallback, folder: session.info?.cwd,
            retained: NativeSessionRailContinuity.shared.title(session.sessionId))
    }

    /// Which computer the session runs on, when it is not this one (`on <name>`).
    private var machineName: String? {
        switch session.target {
        case .local: return nil
        case .machine(let id, _): return NativeMachineLinks.shared.snapshot.names[id] ?? "that machine"
        case .server: return session.serverInfo?.serverName ?? "that server"
        }
    }

    /// Who can rename this session: the pty on this Mac, or the far machine.
    private var renamer: ((String) -> Void)? {
        switch session.target {
        case .local, .machine: return { session.rename(to: $0) }
        case .server: return nil
        }
    }
}

/// `toolbar-chip-sep`: the small dot between the folder and the account.
private struct ChipSeparator: View {
    var body: some View {
        Circle().fill(Color.secondary.opacity(0.6)).frame(width: 3, height: 3).accessibilityHidden(true)
    }
}

/// The session's state as a dot, with its word for VoiceOver and the tooltip. It is the side panel's own
/// SessionStatusDot, so a working session blinks at one speed and in one colour in the rail, bars and panes.
struct NativeSessionStatusDot: View {
    let status: TerminalStatus

    var body: some View {
        SessionStatusDot(status: status.rawValue, size: 7).help(status.label)
    }
}

/// `SessionTitle`: the session's name; click or F2 opens it for typing —
/// Return keeps the new name, Escape keeps the old one, at most 40 characters.
struct NativeSessionTitle: View {
    let title: String
    /// Nil: a heading that cannot be renamed.
    let rename: ((String) -> Void)?
    /// The window's scale (the bar's heading) or a pane's (`scale="pane"`).
    var pane = false
    private var scale: Font { pane ? .callout.weight(.semibold) : .title3.weight(.semibold) }
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        if let draft {
            NativeSessionTextField("", text: Binding(get: { draft }, set: { self.draft = String($0.prefix(SessionTitleRules.maxLength)) }))
                .sessionFocused($focused)
                .onSubmit { finish(save: true) }
                .onExitCommand { finish(save: false) }
                .textFieldStyle(.roundedBorder)
                .font(scale)
                .frame(minWidth: 120, maxWidth: 280)
                .accessibilityLabel("New name for \(title)")
                .onChange(of: focused) { _, now in if !now { finish(save: true) } }
                .onAppear { focused = true }
        } else if rename != nil {
            NativeSessionButton(action: begin) {
                Text(title)
                    .font(scale)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(.rect)
            }
                .buttonStyle(SIDEBARRowStyle())
                .help("\(title) — click or F2 to rename")
                .contextMenu { NativeSessionButton("Rename", action: begin) }
                .focusable()
                .onKeyPress(keys: [KeyEquivalent(Character(UnicodeScalar(0xF705)!))]) { _ in begin(); return .handled }
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: "Rename") { begin() }
        } else {
            Text(title)
                .font(scale)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func begin() {
        draft = title
    }

    private func finish(save: Bool) {
        guard let typed = draft else { return }
        draft = nil
        guard save, let name = SessionTitleRules.typed(typed), name != title else { return }
        rename?(name)
    }
}

/// `FolderTitle`: the folder the session was started in — not a menu, because a
/// session keeps its folder for its whole life.
struct NativeFolderChip: View {
    let path: String
    var assistant: Bool = false

    var body: some View {
        Text(SessionFolder.shown(path, assistant: assistant))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(SessionFolder.help(path))
    }
}
