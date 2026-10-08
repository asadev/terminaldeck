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
                NativeSessionTitle(title: header.title, rename: renamer)
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
            NativeSessionControls(session: session)
                .layoutPriority(0)
            if showsModeSwitch, inMainWindow, let layout = AppModel.shared.tabs?.layout, layout.modeSwitch {
                NativeModeSwitch(layout: layout)
            }
            if popOutOffered {
                Button {
                    NativePoppedSessions.shared.popOut(session.sessionId, title: header.title)
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 14))
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
        .foregroundStyle(NativeSessionChrome.ink)
        .background(Color(nsColor: session.ground))
        .environment(\.colorScheme, NativeSessionChrome.scheme.isLight ? .light : .dark)
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

/// The session's state as a dot, with its word for VoiceOver and the tooltip.
struct NativeSessionStatusDot: View {
    let status: TerminalStatus

    var body: some View {
        Group {
            if status == .working {
                dot.phaseAnimator([1.0, 0.35]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.8) }
            } else {
                dot
            }
        }
        .help(status.label)
        .accessibilityLabel(status.label)
    }

    private var filled: Bool { ![.idle, .waiting].contains(status) }

    private var dot: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(Color.secondary, lineWidth: filled ? 0 : 1.5))
            .frame(width: 7, height: 7)
    }

    private var fill: Color {
        switch status {
        case .working: return Color(red: 0x64 / 255, green: 0xa6 / 255, blue: 0xe8 / 255)
        case .input: return Color(red: 0xf0 / 255, green: 0x91 / 255, blue: 0x3f / 255)
        case .completed: return Color(red: 0x5f / 255, green: 0xbf / 255, blue: 0x95 / 255)
        case .exited: return .secondary
        case .idle, .waiting: return .clear
        }
    }
}

/// `SessionTitle`: the session's name; double-click or F2 opens it for typing —
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
            TextField("", text: Binding(get: { draft }, set: { self.draft = String($0.prefix(SessionTitleRules.maxLength)) }))
                .textFieldStyle(.roundedBorder)
                .font(scale)
                .frame(minWidth: 120, maxWidth: 280)
                .focused($focused)
                .accessibilityLabel("New name for \(title)")
                .onSubmit { finish(save: true) }
                .onExitCommand { finish(save: false) }
                .onChange(of: focused) { _, now in if !now { finish(save: true) } }
                .onAppear { focused = true }
        } else if rename != nil {
            Text(title)
                .font(scale)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("\(title) — double-click or F2 to rename")
                .onTapGesture(count: 2) { begin() }
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
