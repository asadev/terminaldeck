import SwiftUI
import TerminalDeckNativeCore

// Lane T — Hoot's side panel (`copilot/driving/CopilotRailPanel.tsx`, `rail-panel.ts`).
//
// While an agent drives the browser tab that is in front, the sidebar's list
// gives its place to this: whose conversation it is, the page it is about, and
// that session's chat — or, for a session on another machine, a note and the
// box alone. Folding it parks it in the Commander row, which brings it back.
//
// The sidebar mounts it: `if NativeCopilotRailPanel.shown { NativeCopilotRailPanel() } else { … }`.
// The Commander row reads `NativeRailPanel.shared.state == .folded` and calls `open()`.

@MainActor
@Observable
final class NativeRailPanel {
    static let shared = NativeRailPanel()

    /// Put away by its chevron; it stays away across pages, tabs and errands until reopened.
    private(set) var folded = false
    private(set) var bindings = BrowserBindings()
    private(set) var sessions: [TerminalSessionInfo] = []
    /// The one place a send can fail and say why (`target.problem`).
    private(set) var problem = ""

    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    private init() {}

    /// `railPanelState`, from A's drive and the browser tab in front.
    var state: RailPanelState {
        RailPanelRules.state(drive: DriveHost.shared.now, frontTab: AppModel.shared.shownBrowserTab,
                             folded: folded, touring: DriveHost.shared.playing)
    }

    func fold() { folded = true }
    func open() { folded = false }

    func start() {
        guard subscriptions.isEmpty, EngineBridge.shared.isReady else { return }
        let bridge = EngineBridge.shared
        subscriptions = [
            bridge.on("browser:bindings") { [weak self] args in
                if let value = args.first { self?.bindings = BrowserBindings.read(value) }
            },
            bridge.on("session:created") { [weak self] _ in self?.readSessions() },
            bridge.on("session:exit") { [weak self] _ in self?.readSessions() },
            bridge.on("session:renamed") { [weak self] _ in self?.readSessions() },
        ]
        NativeMachineLinks.shared.start()
        Task { [weak self] in
            if let value = try? await bridge.invoke("browser:bindings") { self?.bindings = BrowserBindings.read(value) }
        }
        readSessions()
    }

    private func readSessions() {
        Task { [weak self] in
            guard let list = try? await EngineBridge.shared.invoke("session:list") as? [Any] else { return }
            self?.sessions = list.compactMap(TerminalSessionInfo.decode)
        }
    }

    /// `target.send(text, { submit: true })`: the words, a moment, the Return —
    /// into a session here or on a paired machine; a refusal is kept to show.
    func send(_ text: String, sessionId: String, machineId: String) {
        let line = RailPanelRules.payload(text, submit: true)
        guard !line.isEmpty else { return }
        problem = ""
        let tabId = machineId.isEmpty ? sessionId : SessionTarget.machine(machineId: machineId, sessionId: sessionId).tabId
        let name = NativeMachineLinks.shared.snapshot.names[machineId] ?? "that machine"
        Task { [weak self] in
            let writes = ChatAttach.terminalWrites(line)
            let first = await NativeSessionInput.send(tabId: tabId, text: writes[0], name: name)
            guard first.ok else {
                self?.problem = first.message ?? ""
                return
            }
            try? await Task.sleep(for: .milliseconds(ChatAttach.submitGapMs))
            let second = await NativeSessionInput.send(tabId: tabId, text: writes[1], name: name)
            if !second.ok { self?.problem = second.message ?? "" }
        }
    }
}

struct NativeCopilotRailPanel: View {
    /// Whether the sidebar draws this in place of its list (`railPanel.state === 'panel'`).
    static var shown: Bool { NativeRailPanel.shared.state == .panel }

    @State private var rail = NativeRailPanel.shared
    @State private var hoveringFold = false

    var body: some View {
        let drive = DriveHost.shared.now
        let bound = RailPanelRules.boundSession(rail.bindings, tabId: drive?.tabId ?? "")
        let copilotId = DriveHost.shared.copilotSessionId
        let sessionId = bound?.sessionId ?? copilotId
        let machineId = bound?.machineId ?? ""
        let local = sessionId.flatMap { id in rail.sessions.first { $0.id == id } }
        let name = name(sessionId: sessionId, machineId: machineId, copilotId: copilotId, local: local)
        let place = DriveNow.shortUrl(drive?.url ?? "")

        VStack(alignment: .leading, spacing: 0) {
            header(name: name, place: place)
            if let sessionId {
                if !machineId.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        quiet(RailPanelRules.elsewhere(name: name, machine: NativeMachineLinks.shared.snapshot.names[machineId]))
                        NativeChatComposer(sessionId: sessionId, plain: true, compact: true) { text in
                            rail.send(text, sessionId: sessionId, machineId: machineId)
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    NativeChatView(sessionId: sessionId, cwd: local?.cwd,
                                   session: local.map { SessionScope(startedAt: $0.createdAt ?? 0, resumed: $0.resumed,
                                                                     agentSessionId: $0.agentSessionId) },
                                   provider: local.map(\.provider).flatMap { $0.isEmpty ? nil : $0 },
                                   plain: true, compact: true) { text in
                        rail.send(text, sessionId: sessionId, machineId: "")
                    }
                    .frame(maxHeight: .infinity)
                }
            } else {
                quiet(RailPanelRules.nobody)
                Spacer(minLength: 0)
            }
            if !rail.problem.isEmpty {
                quiet(rail.problem, color: .orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.offset(x: -10).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RailPanelRules.label(name: name))
        .onAppear { rail.start() }
    }

    private func header(name: String, place: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button { withAnimation(.easeOut(duration: 0.18)) { rail.fold() } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(hoveringFold ? Color.primary.opacity(0.08) : .clear))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hoveringFold ? .primary : .secondary)
                .onHover { hoveringFold = $0 }
                .help(RailPanelRules.fold)
                .accessibilityLabel(RailPanelRules.fold)
            }
            // The page this conversation is about: host and path, never the query.
            if !place.isEmpty {
                Text(place)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func quiet(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.footnote)
            .lineSpacing(2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
    }

    /// The session's own name — the one the rest of the window uses — or Hoot's
    /// for its own session before the list has it.
    private func name(sessionId: String?, machineId: String, copilotId: String?, local: TerminalSessionInfo?) -> String {
        guard let sessionId else { return "" }
        let tabId = machineId.isEmpty ? sessionId : SessionTarget.machine(machineId: machineId, sessionId: sessionId).tabId
        let items = AppModel.shared.sidebar?.allItems ?? []
        if let title = items.first(where: { $0.id == tabId })?.title, !title.isEmpty { return title }
        if sessionId == copilotId {
            let hoot = items.first(where: { $0.kind == .hoot })?.title ?? ""
            return hoot.isEmpty ? HootScreen.assistant : hoot
        }
        return local?.title ?? ""
    }
}
