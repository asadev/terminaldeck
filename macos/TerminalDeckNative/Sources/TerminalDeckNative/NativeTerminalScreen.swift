import SwiftUI
import TerminalDeckNativeCore

/// A session on this Mac, drawn in Swift: a slim header (status, name, folder,
/// agent and account, model and effort) over a native terminal.
///
/// Only for local sessions — `NativeTerminalScreen.handles(_:)` says which ids;
/// a held row, a session on another machine, a server shell or a browser tab
/// keeps the page.
struct NativeTerminalScreen: View {
    let sessionId: String

    /// Whether this screen can show that sidebar id (a local session's pty id).
    static func handles(_ id: String) -> Bool {
        TerminalSessionID.isLocal(id)
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
        VStack(spacing: 0) {
            NativeTerminalHeader(session: session)
            Divider()
            ZStack(alignment: .bottom) {
                NativeTerminalHost(session: session)
                if let note = session.note {
                    TerminalNoteLine(text: note)
                        .padding(8)
                        .allowsHitTesting(false)
                }
                if let ended = session.ended {
                    TerminalEndedCard(notice: ended, act: session.startAnother)
                        .transition(.opacity)
                }
            }
            .background(Color(nsColor: session.ground))
            .animation(.easeOut(duration: 0.14), value: session.ended)
        }
        .onAppear { session.screenAppeared() }
        .onDisappear { session.screenDisappeared() }
    }
}

// MARK: - Header

private struct NativeTerminalHeader: View {
    let session: NativeTerminalSession

    var body: some View {
        let header = TerminalHeader.make(info: session.info, railTitle: railTitle,
                                         status: session.status ?? railStatus, ended: session.ended != nil)
        HStack(spacing: 8) {
            TerminalStatusMark(status: header.status)
            Text(header.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)
            if !header.folder.isEmpty {
                Text(header.folder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(header.folderPath)\nA session keeps this folder for its whole life. Start another to work somewhere else.")
            }
            if !header.agent.isEmpty {
                TerminalAgentChip(agent: header.agent, account: header.account)
            }
            Spacer(minLength: 8)
            if let notice = session.controlNotice {
                TerminalControlNotice(ok: notice.ok, text: notice.text, dismiss: session.dismissControlNotice)
            }
            if session.ended == nil, let controls = session.controls, controls.shown(provider: session.info?.provider) {
                TerminalModelEffortControls(session: session, controls: controls)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    /// The rail's own name and dot for this session, so the two never disagree.
    private var railItem: SidebarItem? {
        let projects = AppModel.shared.sidebar?.projects ?? []
        for project in projects {
            if let item = project.sessions.first(where: { $0.id == session.sessionId }) { return item }
        }
        return nil
    }

    private var railTitle: String? { railItem?.title }
    private var railStatus: TerminalStatus? { TerminalStatus.parse(railItem?.status) }
}

/// The session's state as a dot, with its word for VoiceOver and the tooltip (`StatusDot`).
private struct TerminalStatusMark: View {
    let status: TerminalStatus

    var body: some View {
        Group {
            if status == .working {
                // `working` pulses, as the web dot does.
                dot.phaseAnimator([1.0, 0.35]) { view, phase in
                    view.opacity(phase)
                } animation: { _ in .easeInOut(duration: 0.8) }
            } else {
                dot
            }
        }
        .help(status.label)
        .accessibilityLabel(status.label)
    }

    /// Filled when there is something to say; a hollow ring for "Ready".
    private var dot: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(ring, lineWidth: filled ? 0 : 1.5))
            .frame(width: 7, height: 7)
    }

    private var filled: Bool { ![.idle, .waiting].contains(status) }

    private var fill: Color {
        switch status {
        case .working: return Color(red: 0x64 / 255, green: 0xa6 / 255, blue: 0xe8 / 255)
        case .input: return Color(red: 0xf0 / 255, green: 0x91 / 255, blue: 0x3f / 255)
        case .completed: return Color(red: 0x5f / 255, green: 0xbf / 255, blue: 0x95 / 255)
        case .exited: return .secondary
        case .idle, .waiting: return .clear
        }
    }

    private var ring: Color { .secondary }
}

/// Which agent the session runs and, when one applies, the account it runs as.
/// Read-only here: switching account stays in the page's account chip.
private struct TerminalAgentChip: View {
    let agent: String
    let account: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(agent)
            if let account {
                Text("·").foregroundStyle(.tertiary)
                Text(account)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .help(account.map { "\(agent), signed in as \($0)" } ?? agent)
    }
}

/// Model and effort, through the same two channels the page's header uses
/// (`agent:controls:read` / `agent:controls:apply`) — typed into the session by the engine.
private struct TerminalModelEffortControls: View {
    let session: NativeTerminalSession
    let controls: TerminalControls

    var body: some View {
        HStack(spacing: 6) {
            control(name: "Model", id: "model", reading: controls.model,
                    shown: TerminalControlCatalog.shown(controls.model, model: true),
                    sections: [(nil, TerminalControlCatalog.models), ("Earlier models", TerminalControlCatalog.earlierModels)])
            control(name: "Effort", id: "effort", reading: controls.effort,
                    shown: TerminalControlCatalog.shown(controls.effort, model: false),
                    sections: [(nil, TerminalControlCatalog.effort)])
        }
    }

    @ViewBuilder
    private func control(name: String, id: String, reading: TerminalControlReading, shown: String,
                         sections: [(String?, [TerminalControlOption])]) -> some View {
        let blocked = controls.blocked(reading)
        Menu {
            if let blocked {
                Text(blocked)
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let heading = section.0 {
                    Section(heading) { rows(section.1, id: id, reading: reading, blocked: blocked) }
                } else {
                    rows(section.1, id: id, reading: reading, blocked: blocked)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if session.busyControl == id {
                    ProgressView().controlSize(.mini)
                }
                Text(shown)
            }
            .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(session.busyControl != nil)
        .help("\(name): \(shown)")
    }

    @ViewBuilder
    private func rows(_ options: [TerminalControlOption], id: String, reading: TerminalControlReading, blocked: String?) -> some View {
        ForEach(options) { option in
            Button {
                session.pick(control: id, value: option.id)
            } label: {
                if TerminalControlCatalog.isCurrent(reading, option) {
                    Label(title(option), systemImage: "checkmark")
                } else {
                    Text(title(option))
                }
            }
            .disabled(blocked != nil)
        }
    }

    private func title(_ option: TerminalControlOption) -> String {
        guard let hint = option.hint else { return option.label }
        return "\(option.label) — \(hint)"
    }
}

private struct TerminalControlNotice: View {
    let ok: Bool
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(.caption)
        .foregroundStyle(ok ? Color.secondary : Color.red)
        .frame(maxWidth: 280, alignment: .trailing)
        .help(text)
    }
}

// MARK: - Overlays

/// The one line a refused paste, drop or copy says (`TransferNote`).
private struct TerminalNoteLine: View {
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

/// What is drawn over the bottom of a session once it has ended (`SessionEnded`):
/// what happened, and the one press that does something about it.
private struct TerminalEndedCard: View {
    let notice: TerminalEndNotice
    let act: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.secondary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(notice.actionLabel, action: act)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
    }
}
