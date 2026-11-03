import SwiftUI
import TerminalDeckNativeCore

// Hoot's window, drawn in Swift (lane R) — src/renderer/copilot/CopilotView.tsx,
// with the window bar's Restart (CopilotRestart.tsx) and, while another machine's
// Hoot is chosen, the bar that names it ("on <machine>").
//
// Top to bottom, as the page draws it: the bar (Hoot's session bar and Restart);
// which machine's Hoot (G's `NativeCopilotMachines`, nothing with one machine);
// the record strip (sign-in notices, a failed start, the turn that opened the
// window and A's `NativeTourRecap`), capped and scrolling;
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
            if let raw = try? await EngineBridge.shared.invoke("hoot:state") { apply(raw) } else { loading = false }
            await readStarted()
        }
    }

    /// Start it if it is not running ("Start it"). Idempotent in the engine.
    func ensure() {
        loading = true
        Task {
            if let raw = try? await EngineBridge.shared.invoke("hoot:ensure") { apply(raw) } else { loading = false }
        }
    }

    /// Restart: stop, then start — in that order, never together (`useCopilot.restart`).
    func restart() {
        loading = true
        signIn = nil
        Task {
            _ = try? await EngineBridge.shared.invoke("hoot:stop")
            if let raw = try? await EngineBridge.shared.invoke("hoot:ensure") { apply(raw) } else { loading = false }
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
            if let raw = try? await EngineBridge.shared.invoke("hoot:signin") {
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
    private let fixturePhonePanels: [NativeUIGSessionSimulatorController]?
    private let fixtureTrailing: AnyView?
    @AppStorage("page.hoot.machine21") private var chosenMachine = ""
    @State private var chat: NativeHootChatModel
    @Environment(\.nativeScreenActive) private var screenActive
    private let fixtureMode: Bool
    init(fixture: NativeRPCValue? = nil, phonePanels: [NativeUIGSessionSimulatorController]? = nil, trailing: AnyView? = nil) {
        fixturePhonePanels = fixture == nil ? nil : phonePanels
        fixtureTrailing = fixture == nil ? nil : trailing
        fixtureMode = fixture != nil
        _chat = State(initialValue: fixture.map { NativeHootChatModel(fixture: $0) } ?? .shared)
    }
    private var local: NativeHootModel? { fixtureMode ? nil : .shared }
    private var machines: NativeCopilotMachinesModel? { fixtureMode ? nil : .shared }
    var body: some View {
        let remote = machines?.machine(chosenMachine).flatMap { $0.id.isEmpty ? nil : $0 }
        let profile = !fixtureMode && HootProfileRoute.shared.showing
        ZStack {
        // The chat stays alive under the profile (scroll and draft survive), just hidden.
        VStack(spacing: 0) {
            header(remote: remote)
            if let remote {
                NativeRemoteCopilot(machine: remote).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeUIGSessionSimulatorHost(session: NativeHootSimulatorOwner.shared, content: {
                    HStack(spacing: 0) {
                        NativeHootChat(model: chat, notices: notices).frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        if !fixtureMode { NativeHandoffSide(owner: .hoot); DeployHootPanel() }
                        if let fixtureTrailing { fixtureTrailing }
                    }
                }, panels: fixtureMode ? (fixturePhonePanels ?? []) : nil)
            }
        }
        .opacity(profile ? 0 : 1).allowsHitTesting(!profile).accessibilityHidden(profile)
        // Hidden under the profile, the chat's box lets go of the keyboard (its draft stays).
        .environment(\.nativeScreenActive, screenActive && !profile)
        // Hoot's profile takes the whole page under the tab strip (it draws its own header).
        if profile { HootProfileView(onBack: { HootProfileRoute.close() }) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeckTokens.page)
        .onAppear {
            guard !fixtureMode else { return }
            local?.start(); machines?.start()
            local?.readTurnsIfWanted(started: false)
        }
        .onDisappear { if !fixtureMode { local?.focus = nil } }
    }
    private var notices: AnyView? {
        guard let local, !fixtureMode else { return nil }
        let started = HootScreen.started(metas: local.metas, sidebar: AppModel.shared.sidebar)
        return AnyView(HootStrip(model: local, elsewhere: false, started: started, cap: 240))
    }
    private func header(remote: CopilotMachineRow?) -> some View {
        HStack(spacing: 12) {
            // Hoot's avatar and name open his profile (the status line keeps its own link).
            HootAvatar(state: chat.avatarState, animated: !fixtureMode, showsStatus: remote == nil)
                .contentShape(.circle).onTapGesture { if !fixtureMode { HootProfileRoute.open() } }
                .help("Open Hoot's profile").accessibilityAddTraits(.isButton).accessibilityLabel("Open Hoot's profile")
                .accessibilityAction { if !fixtureMode { HootProfileRoute.open() } } // L5: a press from VoiceOver opens the profile too
            VStack(alignment: .leading, spacing: 2) {
                Button { if !fixtureMode { HootProfileRoute.open() } } label: {
                    Text("Hoot").font(.system(size: 20, weight: .semibold)).foregroundStyle(.primary)
                }.buttonStyle(.plain).help("Open Hoot's profile")
                if let remote {
                    Text("On \(remote.name)").font(.callout).foregroundStyle(.secondary)
                } else {
                    HootStatusLine(state: chat.avatarState, text: chat.status,
                        action: { if chat.avatarState == .waiting { chat.requestFocus += 1 } else if !fixtureMode { local?.ensure() } })
                    if let off = chat.guardOff {
                        // Hoot runs, but the app's guard on its own records is not on; the app keeps trying.
                        Label("Safety guard is off: retrying", systemImage: "exclamationmark.shield")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .help("Hoot is running without the app's guard on its own records (its action log, routines, trusted devices, access keys and plugin grants). The app tries again every 30 seconds and restarts Hoot with the guard as soon as it holds; the chat is kept. Why: " + off)
                    }
                }
            }
            Spacer(minLength: 12)
            if let machines, machines.machines.count > 1 {
                NativeCopilotMachines(chosen: $chosenMachine)
            }
            Button("New chat", systemImage: "square.and.pencil") { chat.newChat() }
                .buttonStyle(.bordered).disabled(remote != nil || chat.busy || chat.sending || chat.changingConversation)
            NativeUIGSessionSimulatorButton(session: NativeHootSimulatorOwner.shared, panels: fixtureMode ? (fixturePhonePanels ?? []) : nil)
                .disabled(fixtureMode)
            // Asad (12 Oct): no Handoff button up here; each message has its own (under the message, on hover).
            // Hoot's quick settings popover (model, effort, permission and more) on the sliders button.
            HootQuickSettingsButton(live: !fixtureMode)
            NativePagePopoutButton(ref: ScreenRef(kind: .panel, id: "hoot", isHoot: true), enabled: !fixtureMode)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .nativePageDrag(ScreenRef(kind: .panel, id: "hoot", isHoot: true), title: "Hoot")
        .frame(minHeight: 52)
        .overlay(alignment: .bottomLeading) {
            if !fixtureMode, let notice = NativeHOOTSIMTargets.shared.notice, !notice.isEmpty {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.leading, 76)
            }
        }
    }
}


private struct HootStrip: View {
    let model: NativeHootModel
    let elsewhere: Bool
    let started: [HootScreen.Started]
    /// 38% of the screen's height.
    let cap: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let notices = HootReadyDefaults.enabled() && !elsewhere && NativeHootChatModel.shared.readyToSend == false
            ? [] : HootScreen.notices(stage: model.stage, problem: model.state?.problem, elsewhere: elsewhere)
        let showsTurn = !elsewhere && model.focus != nil
        // On this computer's Hoot only: over another machine's they would be true sentences about the wrong subject.
        if !elsewhere {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                        HootNotice(notice: notice)
                    }
                    if showsTurn { turnCard }
                    NativeTourRecap()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, notices.isEmpty && !showsTurn ? 0 : 12)
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
