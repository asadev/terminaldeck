import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// MARK: - State (`useSessionControls`, `useAgentPresence`, `useConnectors`)

/// One session's model, effort and fast mode, read from the session and written
/// back to it — and whether an agent is in it at all. Every change is typed into
/// the session by the engine (`agent:controls:*`, or `machines:controls:*` for a
/// session on another machine).
@MainActor
@Observable
final class NativeSessionControlsState {
    let target: SessionTarget
    private(set) var readings: TerminalControls?
    /// What the screen says about an agent in a shell session (nil: not said / not sure).
    private(set) var screenPresence: Bool?
    private(set) var busy: String?
    private(set) var notice: (ok: Bool, text: String)?
    private(set) var connectors: [McpRow] = []
    private(set) var connectorsLoaded = false

    @ObservationIgnored weak var session: NativeTerminalSession?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var seenAgent = false
    @ObservationIgnored private var mcpSubscription: EngineSubscription?
    @ObservationIgnored private var connectorsCwd: String??
    /// Sessions given the remembered effort already, once each (`defaulted`).
    private static var defaulted = Set<String>()
    /// 18 Oct (#434): a closed session leaves the set, which no longer grows for the whole app run.
    static func forget(_ id: String) { defaulted.remove(id) }

    init(target: SessionTarget) {
        self.target = target
    }

    func options(_ control: String) -> [TerminalControlOption] {
        guard control == "model" else { return TerminalControlCatalog.options(control) }
        let current = BackendSharedModelCatalog.fallbackModels.map {
            TerminalControlOption(id: $0.alias, label: $0.model, hint: $0.recommended ? "your account’s default" : nil)
        }
        let previous = BackendSharedModelCatalog.previousModels.enumerated().map { index, row in
            TerminalControlOption(id: row.alias, label: row.model, group: index == 0 ? "Earlier models" : nil)
        }
        return TerminalControlCatalog.options(control, models: current + previous)
    }

    // The facts the cluster is drawn from.
    var provider: String? { session?.info?.provider }
    var exited: Bool { session?.ended ?? false }

    /// `presenceFromSession`, else the screen.
    var agentRunning: Bool? {
        SessionPresence.fromSession(provider: provider, exited: exited) ?? screenPresence
    }

    /// `runningProvider`.
    var running: String? {
        SessionPresence.runningProvider(provider, agentRunning: agentRunning)
    }

    // MARK: Reading

    /// Read again once output has been quiet for a moment (`SETTLE_MS`).
    func outputArrived() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.read()
        }
    }

    func read() {
        guard !exited, let call = call(read: true) else { return }
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke(call.0, call.1)
            guard let self else { return }
            if let parsed = TerminalControls.decode(answer) {
                // PERF: an unchanged reading is not written back — every write redraws the session bar.
                if parsed != self.readings { self.readings = parsed }
                if parsed.agentSaid {
                    let presence = SessionPresence.settle(previous: self.screenPresence, reading: parsed.agentRunning,
                                                          seenAgent: self.seenAgent)
                    if presence != self.screenPresence { self.screenPresence = presence }
                    if parsed.agentRunning { self.seenAgent = true }
                }
                if case .machine = self.target, let rows = parsed.connectors {
                    self.connectors = rows
                    self.connectorsLoaded = true
                }
                self.applyRememberedEffort()
            }
        }
        loadConnectors()
    }

    // MARK: Changing

    func pick(_ control: String, _ value: String) {
        guard busy == nil, let call = call(read: false, control: control, value: value) else { return }
        busy = control
        notice = nil
        Task { [weak self] in
            let answer: Any?
            do {
                answer = try await EngineBridge.shared.invoke(call.0, call.1)
            } catch {
                self?.busy = nil
                self?.say(ok: false, (error as? EngineWireError)?.description ?? "The change failed.")
                self?.read()
                return
            }
            guard let self else { return }
            let result = TerminalControlResult.decode(answer)
            self.say(ok: result.ok, result.message)
            self.readings = self.readings?.with(control, result.reading)
            // `rememberEffort`: in the app's settings, with a copy for the page while it still reads it.
            if control == "effort", result.ok {
                NativePageChoices.write(SessionEffortMemory.key, value, mirror: .main)
            }
            self.busy = nil
            self.read()
        }
    }

    func dismissNotice() {
        noticeTimer?.cancel()
        notice = nil
    }

    /// A confirmation goes after four seconds (`CONFIRM_MS`); a failure stays until dismissed.
    private func say(ok: Bool, _ text: String) {
        noticeTimer?.cancel()
        notice = text.isEmpty ? nil : (ok, text)
        guard ok, notice != nil else { return }
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// The remembered effort, typed once into a fresh Claude Code session on this Mac.
    private func applyRememberedEffort() {
        guard case .local(let id) = target, !Self.defaulted.contains(id) else { return }
        // `preferredEffort`: the app's own copy, whether or not the page is loaded (#55).
        NativePageChoices.adopting(SessionEffortMemory.key, from: .main) { [weak self] stored in
            self?.applyRemembered(stored, id: id)
        }
    }

    private func applyRemembered(_ stored: String?, id: String) {
        let want = SessionEffortMemory.preferred(stored: stored)
        guard SessionEffortMemory.shouldApply(want: want, local: true, provider: provider, readings: readings,
                                              busy: busy != nil, alreadyDefaulted: Self.defaulted.contains(id)),
              let want, var call = call(read: false, control: "effort", value: want) else { return }
        // Row 91: marked as the remembered default, so a session an agent or a task started keeps its own effort.
        if var request = call.1.first as? [String: Any?] { request["remembered"] = true; call.1[0] = request }
        Self.defaulted.insert(id)
        busy = "effort"
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke(call.0, call.1)
            guard let self else { return }
            self.readings = self.readings?.with("effort", TerminalControlResult.decode(answer).reading)
            self.busy = nil
            self.read()
        }
    }

    /// `readControlsAt` / `applyControlAt`: the channel for where the session runs.
    private func call(read: Bool, control: String = "", value: String = "") -> (String, [Any?])? {
        switch target {
        case .local(let id):
            var request: [String: Any?] = ["sessionId": id]
            if let cwd = session?.info?.cwd, !cwd.isEmpty { request["cwd"] = cwd }
            if let running { request["provider"] = running }
            if !read {
                request["control"] = control
                request["value"] = value
            }
            return (read ? "agent:controls:read" : "agent:controls:apply", [request])
        case .machine(let machineId, let sessionId):
            return read ? ("machines:controls:read", [machineId, sessionId])
                        : ("machines:controls:apply", [machineId, sessionId, control, value])
        case .server:
            guard let shellId = session?.shellId else { return nil }
            return read ? ("servers:controls:read", [shellId]) : ("servers:controls:apply", [shellId, control, value])
        }
    }

    // MARK: Connectors

    /// This session's directory's MCP servers (`mcp:list`), asked again whenever
    /// a server is added, removed or connected (`mcp:state`).
    private func loadConnectors() {
        guard case .local = target else { return }
        let cwd = session?.info?.cwd
        if mcpSubscription == nil {
            mcpSubscription = EngineBridge.shared.on("mcp:state") { [weak self] _ in self?.askConnectors() }
        }
        guard connectorsCwd != .some(cwd) else { return }
        connectorsCwd = .some(cwd)
        askConnectors()
    }

    private func askConnectors() {
        let cwd = connectorsCwd ?? nil
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke("mcp:list", [cwd?.isEmpty == false ? cwd : nil])
            guard let self else { return }
            self.connectors = McpRow.list(answer) ?? []
            self.connectorsLoaded = true
        }
    }

    /// Exited, or the ended sessions' readings go: the screen they were read from is a photograph.
    func sessionEnded() {
        settle?.cancel()
        readings = nil
    }
}

// MARK: - The cluster (`SessionControls`)

/// The session's own controls, at the trailing end of its bar: the usage reading
/// first, then a pill per control — or, when the bar is too narrow, one pill with
/// both values that opens a panel of every control. Absent for a bare shell.
/// Review of 18 Nov: small solid pills (item 17), no Connectors drop-down here (item 21), a value that is not known
/// yet shows the control's own name, never "Unknown" (item 20's look), and every list is the app's own menu.
struct NativeSessionControls: View {
    let session: NativeTerminalSession

    private var state: NativeSessionControlsState { session.controlsState }

    var body: some View {
        Group {
            if session.end != nil, !session.movingHere {
                // The ended page already explains the outcome.
                usage(tight: false)
            } else if state.running == "shell" {
                EmptyView()
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        usage(tight: false)
                        ForEach(TerminalControlCatalog.rowControls, id: \.self) { control in
                            ControlChip(state: state, control: control, blocked: blocked(control),
                                        nestedFast: control == "model" ? blocked("fast") : nil)
                        }
                    }
                    .fixedSize()
                    HStack(spacing: 6) {
                        usage(tight: false)
                        SummaryChip(state: state, blocked: blocked, glyph: false)
                    }
                    .fixedSize()
                    HStack(spacing: 6) {
                        usage(tight: true)
                        SummaryChip(state: state, blocked: blocked, glyph: true)
                    }
                }
            }
        }
    }

    /// The usage reading, first in the cluster (`UsageBar`), for the agent running in the session —
    /// absent while the page's Usage feature is off (`controlOn('chrome.usage')`).
    @ViewBuilder private func usage(tight: Bool) -> some View {
        if NativeSessionFeatures.shared.value.usageOn {
            NativeUsageBar(usage: session.usageState, provider: state.running, tight: tight)
                .driveAnchor(DriveAnchor.usage(sessionId: session.sessionId).id)
        }
    }

    /// `blockedFor`.
    private func blocked(_ control: String) -> String? {
        if let note = TerminalControlCatalog.foreignAgentNote(state.running) { return note }
        guard let readings = state.readings else { return nil }
        return readings.blocked(readings.reading(control))
    }
}

/// The notice an applied change answers with, under the bar: the CLI's own
/// confirmation (gone after four seconds) or its refusal (kept until dismissed). A solid surface, no glass.
struct NativeSessionControlsNotice: View {
    let state: NativeSessionControlsState
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let notice = state.notice {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notice.text)
                    .font(.caption)
                    .foregroundStyle(notice.ok ? Color.primary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: state.dismissNotice) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 360, alignment: .leading)
            .background(DeckMenuColours.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeckMenuColours.border, lineWidth: 1 / max(displayScale, 1)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

// MARK: - Pills and menus (`ControlPicker`, `ControlToggleItem`, `ControlSection`)

/// The header's small solid pill (DESIGN-shell §4): 22 high, a capsule, a quiet solid fill that only darkens under the
/// pointer. Shared by model, effort, the folded pill and "Switch to this Mac".
enum DeckPill {
    static let height: CGFloat = 22
    static let font = Font.system(size: 11, weight: .medium)
    static func fill(_ scheme: ColorScheme, hovering: Bool) -> Color {
        Color.primary.opacity(scheme == .dark ? (hovering ? 0.20 : 0.13) : (hovering ? 0.12 : 0.07))
    }
}

/// A pill's frame around its own words.
struct DeckPillLabel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) { content() }
            .font(DeckPill.font)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: DeckPill.height)
            .background(DeckPill.fill(scheme, hovering: hovering), in: .capsule)
            .contentShape(.capsule)
            .onHover { hovering = $0 }
    }
}

/// A control's pill: its value and a caret. A value that is not known yet shows the control's own name in grey:
/// never the word "Unknown", never italics.
private struct ChipLabel: View {
    let name: String
    /// nil: not known yet.
    let value: String?
    var busy = false

    var body: some View {
        DeckPillLabel {
            Text(busy ? "Working…" : value ?? name)
                .foregroundStyle(value == nil || busy ? .secondary : .primary)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

/// One control on the row: its pill opens its list; the model's list ends with fast mode.
private struct ControlChip: View {
    let state: NativeSessionControlsState
    let control: String
    let blocked: String?
    /// The fast-mode refusal, when this is the model chip (nil when fast mode is free).
    let nestedFast: String??
    @State private var open = false

    var body: some View {
        let reading = state.readings?.reading(control)
        let busy = state.busy == control
        let known = reading?.label != nil
        let name = TerminalControlCatalog.name(control)
        let value = TerminalControlCatalog.value(reading, control: control)
        let shown = control == "model" && known ? TerminalControlCatalog.shortModelLabel(value) : value
        Button { open.toggle() } label: {
            ChipLabel(name: name, value: known ? shown : nil, busy: busy)
        }
        .buttonStyle(.plain)
        .disabled(state.busy != nil)
        .opacity(blocked != nil ? 0.6 : 1)
        .help(blocked ?? (known || busy ? TerminalControlCatalog.chipHelp(control, reading: reading, busy: busy, blocked: nil)
                          : "\(name): not read from this session yet"))
        .accessibilityLabel(known ? "\(name): \(value)" : "\(name): not known yet")
        .deckMenu(isPresented: $open, alignment: .trailing) {
            if let blocked { DeckMenuNote(blocked) }
            OptionRows(state: state, control: control, disabled: blocked != nil)
            if let nestedFast { FastSwitchRow(state: state, blocked: nestedFast) }
        }
    }
}

/// The rows of one control: a check on the one in force, a hint where a row has
/// one, and a quiet title over the rows that are a different kind of claim.
private struct OptionRows: View {
    let state: NativeSessionControlsState
    let control: String
    let disabled: Bool

    var body: some View {
        let reading = state.readings?.reading(control)
        ForEach(state.options(control)) { option in
            if let group = option.group { DeckMenuSection(group) }
            DeckMenuRow(option.label, detail: option.hint, checked: TerminalControlCatalog.isCurrent(reading, option),
                        enabled: !(disabled || state.busy != nil)) {
                state.pick(control, option.id)
            }
        }
    }
}

/// Fast mode at the foot of the model's list (`ControlToggleItem`): a switch once
/// its position has been read, the two rows while it has not, the reason alone
/// when it is refused.
private struct FastSwitchRow: View {
    let state: NativeSessionControlsState
    let blocked: String?

    var body: some View {
        let reading = state.readings?.fast
        let read = reading?.value == "on" || reading?.value == "off"
        let isOn = reading?.value == "on"
        let busy = state.busy == "fast"
        DeckMenuDivider()
        if let blocked {
            DeckMenuSection("Fast mode")
            DeckMenuNote(blocked)
        } else if read {
            DeckMenuToggleRow(title: "Fast mode", detail: busy ? "Working…" : "off if you switch model",
                              isOn: Binding(get: { isOn }, set: { state.pick("fast", $0 ? "on" : "off") }),
                              enabled: state.busy == nil)
                .help("Fast mode: \(busy ? "Working…" : TerminalControlCatalog.value(reading, control: "fast")) — \(TerminalControlCatalog.sourceNote(reading?.source)) · \(TerminalControlCatalog.reach("fast") ?? "")")
        } else {
            DeckMenuSection("Fast mode")
            DeckMenuNote(TerminalControlCatalog.toggleUnreadBrief("fast"))
            OptionRows(state: state, control: "fast", disabled: false)
        }
    }
}

/// The folded cluster: one pill carrying both values (or the sliders mark when
/// even that does not fit), opening a panel with a section per control.
private struct SummaryChip: View {
    let state: NativeSessionControlsState
    let blocked: (String) -> String?
    let glyph: Bool
    @State private var open = false

    var body: some View {
        let model = state.readings?.model
        let effort = state.readings?.effort
        let modelValue = TerminalControlCatalog.value(model, control: "model")
        let effortValue = TerminalControlCatalog.value(effort, control: "effort")
        let modelShown = model?.label == nil ? TerminalControlCatalog.name("model") : TerminalControlCatalog.shortModelLabel(modelValue)
        let effortShown = effort?.label == nil ? TerminalControlCatalog.name("effort") : effortValue
        let label = model?.label == nil && effort?.label == nil ? "Model and effort: not read from this session yet"
            : TerminalControlCatalog.summaryLabel(model: modelShown, effort: effortShown, withConnectors: false)
        Button { open.toggle() } label: {
            DeckPillLabel {
                if glyph {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
                } else {
                    Text(modelShown).foregroundStyle(model?.label == nil ? .secondary : .primary)
                    Text("·").foregroundStyle(.secondary)
                    Text(effortShown).foregroundStyle(effort?.label == nil ? .secondary : .primary)
                }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("Session controls: \(label)")
        .deckMenu(isPresented: $open, alignment: .trailing, width: 300) {
            ForEach(TerminalControlCatalog.chromeControls, id: \.self) { control in
                ControlSection(state: state, control: control, blocked: blocked(control))
            }
        }
    }
}

/// One control in the folded panel (`ControlSection`): its name, then a switch or its rows.
private struct ControlSection: View {
    let state: NativeSessionControlsState
    let control: String
    let blocked: String?

    var body: some View {
        let reading = state.readings?.reading(control)
        let name = TerminalControlCatalog.name(control)
        let toggle = state.options(control).count == 2
        if toggle, reading?.value == "on" || reading?.value == "off", blocked == nil {
            let isOn = reading?.value == "on"
            DeckMenuToggleRow(title: name, detail: state.busy == control ? "Working…" : nil,
                              isOn: Binding(get: { isOn }, set: { state.pick(control, $0 ? "on" : "off") }),
                              enabled: state.busy == nil)
                .help("\(name): \(TerminalControlCatalog.value(reading, control: control)) — \(TerminalControlCatalog.sourceNote(reading?.source)) · \(TerminalControlCatalog.reach(control) ?? "")")
        } else {
            DeckMenuSection(name)
            if let blocked { DeckMenuNote(blocked) }
            OptionRows(state: state, control: control, disabled: blocked != nil)
        }
    }
}

// MARK: - The page's feature switches

/// `features.v2`: the app's last copy, followed from the page's storage on first use and
/// again whenever a window of this app becomes key — the way back from Settings, where they
/// change. With the page not loaded the last copy still holds, never the defaults (#55).
@MainActor
@Observable
final class NativeSessionFeatures {
    static let shared = NativeSessionFeatures()
    private(set) var value = SessionFeatures.defaults
    @ObservationIgnored private var watching: NSObjectProtocol?

    private init() {}

    func refresh() {
        if watching == nil {
            watching = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                              queue: .main) { _ in
                MainActor.assumeIsolated { NativeSessionFeatures.shared.refresh() }
            }
        }
        NativePageChoices.following(SessionFeatures.storageKey, from: .main) { [weak self] json in
            let next = SessionFeatures.decode(json)
            if self?.value != next { self?.value = next }
        }
    }
}
