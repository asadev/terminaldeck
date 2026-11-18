import SwiftUI
import TerminalDeckBackend
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
                                         status: session.movingHere ? .working : session.status ?? TerminalStatus.parse(railItem?.status), ended: session.ended && !session.movingHere)
        // The bar's frame is shared with the New session page (`NativeSessionBarFrame`): a change here changes it there.
        NativeSessionBarFrame {
            // A pop-out window's bar marks the title with the status dot (PopoutWindow titleMark);
            // the main window's bar has none.
            if !inMainWindow {
                NativeSessionStatusDot(status: header.status)
            }
        } title: {
            NativeSessionTitle(title: sharedTitle(fallback: header.title), rename: renamer)
        } place: {
            // 18 Nov (item 23): WHERE it runs, never the folder's bare name again: the project's picture and name, or a
            // folder glyph and the path from the home folder ("~/Deck Dev").
            if !header.folderPath.isEmpty {
                NativeSessionWhere(path: header.folderPath, project: project)
            }
            // 18 Nov (items 31, 34): a session on another device has the same bar; only its device's glyph and name
            // are added here.
            if let machine = machineName {
                if !header.folderPath.isEmpty { ChipSeparator() }
                NativeDeviceMark(name: machine, kind: deviceKind(machine))
                if let row = NativeCloudChats.shared.remoteRow(tabId: session.sessionId) {
                    NativeCloudMoveLine(state: NativeCloudMoveLine.state(row: row, machine: machine,
                        move: NativeCloudChats.shared.moveLine(ref: row.ref, sessionId: row.sessionId)),
                        onSwitch: { NativeCloudChats.shared.switchHere(ref: row.ref) },
                        onCancel: { NativeCloudChats.shared.cancelMove(ref: row.ref) }, inBar: true)
                }
            }
            switch session.target {
            case .local(let id):
                if !header.folderPath.isEmpty { ChipSeparator() }
                NativeLocalAccountChip(session: session)
                // WhatsApp (DESIGN-WHATSAPP section 3): only while a WhatsApp agent is attached to this session.
                NativeWhatsAppChip(here: .session(id: id, name: sharedTitle(fallback: header.title)))
                // Switch to this Mac: the move's one done line, once, on the session it started here.
                if let moved = NativeCloudChats.shared.arrivals[id] {
                    ChipSeparator()
                    Text(moved).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(moved)
                        .onDisappear { NativeCloudChats.shared.arrivals[id] = nil }
                }
            case .machine:
                NativeMachineAccountChip(session: session).disabled(session.movingHere)
            case .server:
                if !header.folderPath.isEmpty { ChipSeparator() }
                NativeServerAccountChip(session: session)
            }
        } trailing: {
            // Model, effort and fast mode are read off a terminal's screen. A chat session keeps them under its box and
            // only its usage (plan limits, context window) up here, where it always was.
            if !session.isChat {
                // Above the spacer's priority, so the pills are folded only when they truly do not fit.
                NativeSessionControls(session: session)
                    .disabled(session.movingHere)
                    .layoutPriority(0.5)
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
        .overlay(alignment: .bottom) { if session.movingHere { DeckMovingLine() } }
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
        if session.movingHere, let name = NativeCloudChats.shared.remoteRow(tabId: session.sessionId)?.name, !name.isEmpty { return name }
        guard case .local = session.target else { return fallback }
        if let railItem { return SIDEBARSessionLine.title(railItem, store: SIDEBARProjectStore.shared) }
        return SIDEBARSessionLine.title(given: NativeSessionNames.shared.names[session.sessionId],
            own: SIDEBARProjectStore.shared.sessionTitles[session.sessionId] ?? session.info?.title,
            rail: fallback, folder: session.info?.cwd,
            retained: NativeSessionRailContinuity.shared.title(session.sessionId))
    }

    /// The registered project this session belongs to (the side panel's own rule), nil for an independent session or
    /// one that runs elsewhere.
    private var project: PROJProject? {
        guard case .local = session.target else { return nil }
        let store = SIDEBARProjectStore.shared
        let registry = store.projects.isEmpty ? PROJProjects.defaults : store.projects
        let saved = store.sessionProjects[session.sessionId]
        let resolved = PROJProjects.resolve(projectID: saved?.projectID, folder: saved?.cwd ?? session.info?.cwd, projects: registry)
        guard resolved != PROJProjects.independentID else { return nil }
        return registry.first { $0.id == resolved }
    }

    /// The other device's picture: a server is a server; a machine by its reported type once one exists (SEAM,
    /// LOGIC-HANDOFF R1), until then by what its name says.
    private func deviceKind(_ name: String) -> DeckDeviceKind {
        if case .server = session.target { return .server }
        return DeckDeviceKind.resolve(reported: nil, name: name)
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

/// The frame of a session's bar: an optional mark, the name on its own line with "where and who" under it, and the
/// session's own controls at the trailing end. An open session and the New session page both draw their bar through
/// this one view, so the two can never drift apart.
struct NativeSessionBarFrame<Mark: View, Title: View, Place: View, Trailing: View>: View {
    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var title: () -> Title
    @ViewBuilder var place: () -> Place
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            mark()
            // The page's window bar: the name on its own line, "where and who" under it.
            VStack(alignment: .leading, spacing: 1) {
                title()
                HStack(spacing: 5) { place() }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 48)
    }
}

/// `toolbar-chip-sep`: the small dot between the folder and the account.
struct ChipSeparator: View {
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
                // 18 Nov: the field sits exactly where the name was (same font, same 28 height); only an accent hairline
                // appears around it, outside the layout. The bordered field pushed line two up (recording 1, 7:55).
                .textFieldStyle(.plain)
                .font(scale)
                .frame(minWidth: 120, maxWidth: 280, minHeight: 28, maxHeight: 28)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1).padding(.horizontal, -5))
                .accessibilityLabel("New name for \(title)")
                .onChange(of: focused) { _, now in if !now { finish(save: true) } }
                .onAppear { focused = true }
        } else if rename != nil {
            NativeSessionButton(action: begin) {
                // 18 Nov: the name takes its own width. Asking for all of it squeezed the session's controls into the
                // sliders glyph whenever the name was not being edited (recording 1, 7:45 against 7:55).
                Text(title)
                    .font(scale)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: 28, alignment: .leading)
                    .contentShape(.rect)
            }
                .buttonStyle(NativeSessionTitleStyle())
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

/// The session's name as a button that keeps its own width. The side panel's row style, which it wore before, asks
/// for the full width; in the bar that starved the session's controls, so the model and effort were folded into the
/// sliders glyph whenever the name was not being edited (recording 1, 7:45 against 7:55). Same hover tint, drawn
/// 4 pt wider than the words without taking room.
private struct NativeSessionTitleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TitleBody(configuration: configuration)
    }

    private struct TitleBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 4)
                .background(configuration.isPressed || hovering ? DeckTokens.cardHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
                .padding(.horizontal, -4)
                .onHover { hovering = $0 }
        }
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

/// Line two's first part: WHERE the session runs (Asad, 18 Nov: "it is not showing as folder location. It is just
/// showing same as name ... it should show slash deck dev. So we know that this is running in this folder ... Or if it
/// is a project name, then it is fine"). A project: its picture and its name. No project: a folder glyph and the path
/// with the home folder as "~". The full path is the tooltip either way.
struct NativeSessionWhere: View {
    let path: String
    var project: PROJProject? = nil

    /// "/Users/asad/Deck Dev" as "~/Deck Dev"; a path outside the home folder as it is.
    static func shownPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        HStack(spacing: 5) {
            if let project {
                ProjectLogoView(project: project, name: project.name, size: 14, onAccent: false)
                Text(project.name)
            } else {
                Image(systemName: "folder").font(.system(size: 11))
                Text(Self.shownPath(path))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(SessionFolder.help(path))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.map { "Project \($0.name)" } ?? "Folder \(Self.shownPath(path))")
    }
}
