import SwiftUI
import TerminalDeckNativeCore

// Hoot's window, drawn in Swift (lane R) — src/renderer/copilot/CopilotView.tsx,
// with the window bar's Restart (CopilotRestart.tsx) and, while another machine's
// Hoot is chosen, the bar that names it ("on <machine>").
//
// Top to bottom, as the page draws it: the bar (Hoot's session bar and Restart);
// which machine's Hoot (G's `NativeCopilotMachines`, nothing with one machine);
// the record strip (sign-in notices, a failed start, the turn that opened the
// window, A's `NativeTourRecap`, the sessions it started), capped and scrolling;
// then Hoot's terminal — or another machine's conversation (G's
// `NativeRemoteCopilot`), or the "not running" page with Start it.

/// Hoot on this computer: its state, its sign-in, and what the strip reads.
@MainActor
@Observable
final class NativeHootModel {
    static let shared = NativeHootModel()

    private(set) var state: CopilotState?
    private(set) var signIn: CopilotSignIn?
    /// True until the first answer has landed, so nothing says "stopped" too early.
    private(set) var loading = true
    /// The action-log row the window opens on (a session's "why does this exist").
    var focus: String?
    private(set) var turns: [HootScreen.Turn] = []
    private(set) var metas: [HootScreen.Meta] = []

    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var turnsRead = false

    private init() {}

    var stage: HootStage {
        HootScreen.stage(status: state?.status.rawValue, signIn: signIn?.state.rawValue)
    }

    /// Open Hoot's window on one turn of the action log — the other half of a
    /// copilot-started session's "why does this exist".
    func show(turn: String?) {
        focus = turn
        turnsRead = false
        AppModel.shared.select("hoot")
    }

    /// Read once, then on the two pushes Hoot's state moves on when nobody here touched it.
    func start() {
        if subscriptions.isEmpty {
            subscriptions = [
                EngineBridge.shared.on("session:exit") { [weak self] _ in self?.refresh() },
                EngineBridge.shared.on("session:created") { [weak self] _ in self?.refresh() },
            ]
        }
        refresh()
    }

    func refresh() {
        Task {
            if let raw = try? await EngineBridge.shared.invoke("copilot:state") { apply(raw) } else { loading = false }
            await readStarted()
        }
    }

    /// Start it if it is not running ("Start it"). Idempotent in the engine.
    func ensure() {
        loading = true
        Task {
            if let raw = try? await EngineBridge.shared.invoke("copilot:ensure") { apply(raw) } else { loading = false }
        }
    }

    /// Restart: stop, then start — in that order, never together (`useCopilot.restart`).
    func restart() {
        loading = true
        signIn = nil
        Task {
            _ = try? await EngineBridge.shared.invoke("copilot:stop")
            if let raw = try? await EngineBridge.shared.invoke("copilot:ensure") { apply(raw) } else { loading = false }
        }
    }

    /// The action log, read only while there is a turn to show or sessions it started.
    func readTurnsIfWanted(started: Bool) {
        guard focus != nil || started, !turnsRead else { return }
        turnsRead = true
        Task {
            if let raw = try? await EngineBridge.shared.invoke("deck-control:activity", [200]) {
                turns = HootScreen.turns(raw)
            }
        }
    }

    private func apply(_ raw: Any) {
        loading = false
        guard let next = CopilotState.from(CodingAIJSON(raw)) else { return }
        state = next
        // Signed in? Only asked of a running Hoot; cleared otherwise.
        guard next.status == .running else { signIn = nil; return }
        Task {
            if let raw = try? await EngineBridge.shared.invoke("copilot:signin") {
                signIn = CopilotSignIn.from(CodingAIJSON(raw))
            }
        }
    }

    private func readStarted() async {
        if let raw = try? await EngineBridge.shared.invoke("session:list") { metas = HootScreen.metas(raw) }
    }
}

/// The main window's (or Hoot's own window's) Hoot screen.
struct NativeHootScreen: View {
    @State private var chosenMachine = ""
    @State private var height: CGFloat = 600
    private let model = NativeHootModel.shared
    private let app = AppModel.shared
    private let machines = NativeCopilotMachinesModel.shared

    var body: some View {
        let machine = machines.machine(chosenMachine)
        let remote = machine.flatMap { $0.id.isEmpty ? nil : $0 }
        let started = HootScreen.started(metas: model.metas, sidebar: app.sidebar)
        Group {
            if let remote {
                VStack(spacing: 0) {
                    remoteBar(remote)
                    Divider()
                    top(elsewhere: true, started: started)
                    NativeRemoteCopilot(machine: remote)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let sessionId = model.state?.sessionId, model.state?.paths.root != nil {
                let session = NativeTerminalSessions.shared.session(for: sessionId)
                NativeSessionBody(session: session) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            NativeSessionHeader(session: session)
                            if HootScreen.showsRestart(status: model.state?.status.rawValue, elsewhere: false) {
                                restartButton
                            }
                        }
                        Divider()
                        top(elsewhere: false, started: started)
                    }
                }
                .id(sessionId)
            } else {
                VStack(spacing: 0) {
                    top(elsewhere: false, started: started)
                    NativePageEmpty(
                        mark: AnyView(HootMark(size: 200)),
                        title: HootScreen.emptyTitle(stage: model.stage),
                        message: { Text(HootScreen.emptyBody) },
                        action: PageEmptyAction(label: "Start it", primary: true, busy: model.stage == .starting) { model.ensure() },
                        hint: { EmptyView() },
                        extra: { EmptyView() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onAppear {
            model.start()
            machines.start()
            model.readTurnsIfWanted(started: !started.isEmpty)
        }
        .onChange(of: started.isEmpty) { _, empty in model.readTurnsIfWanted(started: !empty) }
        .onChange(of: model.focus) { _, _ in model.readTurnsIfWanted(started: !started.isEmpty) }
        // A door opens onto the turn it named once; the next plain open does not land there again.
        .onDisappear { model.focus = nil }
    }

    // MARK: The bar

    private var restartButton: some View {
        let line = HootScreen.stateLine(stage: model.stage, loading: model.loading,
                                        account: model.signIn?.account, recordsHeld: model.state?.records.enforced == true)
        return Button("Restart") { model.restart() }
            .controlSize(.regular)
            .help(HootScreen.restartHelp(stateLine: line))
            .padding(.trailing, 16)
    }

    /// Another machine's Hoot: the bar names it, and carries none of this Mac's controls.
    private func remoteBar(_ machine: CopilotMachineRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(assistantName).font(.headline).lineLimit(1)
            Text("on \(machine.name)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private var assistantName: String {
        let title = app.sidebar?.allItems.first(where: { $0.kind == .hoot })?.title ?? ""
        return title.isEmpty ? HootScreen.assistant : title
    }

    // MARK: Machines and the record strip

    private func top(elsewhere: Bool, started: [HootScreen.Started]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeCopilotMachines(chosen: $chosenMachine)
            HootStrip(model: model, elsewhere: elsewhere, started: started, cap: max(120, height * 0.38))
        }
    }
}

/// `.cp-strip`: everything the window has to say that is not the conversation.
/// Each part only when it has something to say; the whole strip gone when none does.
private struct HootStrip: View {
    let model: NativeHootModel
    let elsewhere: Bool
    let started: [HootScreen.Started]
    /// 38% of the screen's height.
    let cap: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let notices = HootScreen.notices(stage: model.stage, problem: model.state?.problem, elsewhere: elsewhere)
        let showsTurn = !elsewhere && model.focus != nil
        let showsStarted = !elsewhere && !started.isEmpty
        // On this computer's Hoot only: over another machine's they would be true sentences about the wrong subject.
        if !elsewhere {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                        HootNotice(notice: notice)
                    }
                    if showsTurn { turnCard }
                    NativeTourRecap()
                    if showsStarted { startedList }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, notices.isEmpty && !showsTurn && !showsStarted ? 0 : 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Capped and scrolling (`.cp-strip`, max-height 38%): the terminal is what he came for.
            .frame(height: min(contentHeight, cap))
        }
    }

    private var turnCard: some View {
        let focused = model.turns.first { $0.id == model.focus }
        let links = HootScreen.fromTurn(model.focus, in: started)
        return VStack(alignment: .leading, spacing: 6) {
            if let focused {
                Text(focused.detail).textSelection(.enabled)
                Text(HootScreen.when(focused.at)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(HootScreen.missingTurn)
            }
            if !links.isEmpty {
                HStack(spacing: 10) {
                    ForEach(links) { session in
                        Button("Open \(session.label)") { AppModel.shared.selectTab(session.id) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var startedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions it started").font(.headline)
            ForEach(started) { session in
                Button(session.label) { AppModel.shared.selectTab(session.id) }
                    .buttonStyle(.link)
            }
        }
    }
}

/// `.cp-notice`: an accent rule down the left, a soft fill; red for a failed start.
private struct HootNotice: View {
    let notice: HootScreen.Notice

    var body: some View {
        let tint: Color = notice.kind == .problem ? .red : .accentColor
        VStack(alignment: .leading, spacing: 8) {
            if let title = notice.title {
                Text(title).font(.headline)
            }
            ForEach(Array(notice.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(tint.opacity(0.7))
                .frame(width: 3)
        }
    }
}
