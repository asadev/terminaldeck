import SwiftUI
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

    init(target: SessionTarget) {
        self.target = target
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

    var wired: Bool { true }

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
        guard wired, !exited, let call = call(read: true) else { return }
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke(call.0, call.1)
            guard let self else { return }
            if let parsed = TerminalControls.decode(answer) {
                self.readings = parsed
                if parsed.agentSaid {
                    self.screenPresence = SessionPresence.settle(previous: self.screenPresence, reading: parsed.agentRunning,
                                                                 seenAgent: self.seenAgent)
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
            // `rememberEffort`: in the page's own storage, so both sides share it.
            if control == "effort", result.ok {
                NativeCodingAIPages.evaluate(CodingAIPageScripts.writeStorage(SessionEffortMemory.key, value), in: .main)
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
        guard case .local(let id) = target, !Self.defaulted.contains(id), AppModel.shared.web.origin != nil else { return }
        // `preferredEffort` reads the page's storage, where the page remembers it too.
        NativeCodingAIPages.evaluate(CodingAIPageScripts.readStorage(SessionEffortMemory.key), in: .main) { [weak self] stored in
            self?.applyRemembered(stored, id: id)
        }
    }

    private func applyRemembered(_ stored: String?, id: String) {
        let want = SessionEffortMemory.preferred(stored: stored)
        guard SessionEffortMemory.shouldApply(want: want, local: true, provider: provider, readings: readings,
                                              busy: busy != nil, alreadyDefaulted: Self.defaulted.contains(id)),
              let want, let call = call(read: false, control: "effort", value: want) else { return }
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
/// first, then a chip per control — or, when the bar is too narrow, one chip with
/// both values that opens a panel of every control. Absent for a bare shell; over
/// an ended session it says so instead.
struct NativeSessionControls: View {
    let session: NativeTerminalSession

    private var state: NativeSessionControlsState { session.controlsState }

    var body: some View {
        Group {
            if let end = session.end {
                HStack(spacing: 8) {
                    usage(tight: false)
                    Text(end.notice.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(end.notice.detail)
                }
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
                        if hasConnectors { ConnectorsChip(state: state, session: session) }
                    }
                    .fixedSize()
                    HStack(spacing: 6) {
                        usage(tight: false)
                        SummaryChip(state: state, session: session, blocked: blocked, hasConnectors: hasConnectors, glyph: false)
                    }
                    .fixedSize()
                    HStack(spacing: 6) {
                        usage(tight: true)
                        SummaryChip(state: state, session: session, blocked: blocked, hasConnectors: hasConnectors, glyph: true)
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

    private var hasConnectors: Bool { state.connectorsLoaded && !state.connectors.isEmpty }

    /// `blockedFor`.
    private func blocked(_ control: String) -> String? {
        if !state.wired { return TerminalControlCatalog.notWired }
        if let note = TerminalControlCatalog.foreignAgentNote(state.running) { return note }
        guard let readings = state.readings else { return nil }
        return readings.blocked(readings.reading(control))
    }
}

/// The notice an applied change answers with, under the bar: the CLI's own
/// confirmation (gone after four seconds) or its refusal (kept until dismissed).
struct NativeSessionControlsNotice: View {
    let state: NativeSessionControlsState

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
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

// MARK: - Chips and menus (`ControlPicker`, `ControlToggleItem`, `ControlSection`)

/// `cc-chip`: a value and a caret, the control's name only while the value is unknown.
private struct ChipLabel: View {
    let name: String?
    let value: String
    let unknown: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let name { Text(name).foregroundStyle(.secondary) }
            Text(value)
                .italic(unknown)
                .foregroundStyle(unknown ? .secondary : .primary)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .contentShape(.capsule)
    }
}

/// One control on the row: its chip opens its list; the model's list ends with fast mode.
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
        let value = TerminalControlCatalog.value(reading, control: control)
        let shown = control == "model" && reading?.label != nil ? TerminalControlCatalog.shortModelLabel(value) : value
        Button { open.toggle() } label: {
            ChipLabel(name: reading?.label == nil ? TerminalControlCatalog.name(control) : nil,
                      value: busy ? "Working…" : shown, unknown: reading?.label == nil || busy)
        }
        .buttonStyle(.plain)
        .disabled(state.busy != nil)
        .opacity(blocked != nil ? 0.6 : 1)
        .help(TerminalControlCatalog.chipHelp(control, reading: reading, busy: busy, blocked: blocked))
        .accessibilityLabel("\(TerminalControlCatalog.name(control)): \(value)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let blocked { BlockedLine(text: blocked) }
                OptionRows(state: state, control: control, disabled: blocked != nil) { open = false }
                if let nestedFast { FastSwitchRow(state: state, blocked: nestedFast) }
            }
            .padding(6)
            .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        }
    }
}

private struct BlockedLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
    }
}

/// The rows of one control: a tick on the one in force, a hint where a row has
/// one, and a caption over the rows that are a different kind of claim.
private struct OptionRows: View {
    let state: NativeSessionControlsState
    let control: String
    let disabled: Bool
    var picked: () -> Void = {}

    var body: some View {
        let reading = state.readings?.reading(control)
        ForEach(TerminalControlCatalog.options(control)) { option in
            if let group = option.group {
                Text(group)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
            let current = TerminalControlCatalog.isCurrent(reading, option)
            Button {
                picked()
                state.pick(control, option.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(current ? "✓" : "").frame(width: 12, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                        if let hint = option.hint {
                            Text(hint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(MenuRowStyle(current: current))
            .disabled(disabled || state.busy != nil)
            .accessibilityAddTraits(current ? .isSelected : [])
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
        Divider().padding(.vertical, 2)
        if let blocked {
            caption
            BlockedLine(text: blocked)
        } else if read {
            Button {
                state.pick("fast", isOn ? "off" : "on")
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fast mode")
                        Text("off if you switch model").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if busy {
                        Text("Working…").font(.caption).italic().foregroundStyle(.secondary)
                    } else {
                        Toggle("", isOn: .constant(isOn)).toggleStyle(.switch).controlSize(.mini).labelsHidden().allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(MenuRowStyle(current: false))
            .disabled(state.busy != nil)
            .help("Fast mode: \(busy ? "Working…" : TerminalControlCatalog.value(reading, control: "fast")) — \(TerminalControlCatalog.sourceNote(reading?.source)) · \(TerminalControlCatalog.reach("fast") ?? "")")
            .accessibilityAddTraits(isOn ? .isSelected : [])
        } else {
            caption
            Text(TerminalControlCatalog.toggleUnreadBrief("fast"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            OptionRows(state: state, control: "fast", disabled: false)
        }
    }

    private var caption: some View {
        Text("Fast mode")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}

private struct MenuRowStyle: ButtonStyle {
    let current: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.25) : (current ? Color.accentColor.opacity(0.10) : .clear),
                        in: .rect(cornerRadius: 5))
    }
}

/// The folded cluster: one chip carrying both values (or the sliders mark when
/// even that does not fit), opening a panel with a section per control.
private struct SummaryChip: View {
    let state: NativeSessionControlsState
    let session: NativeTerminalSession
    let blocked: (String) -> String?
    let hasConnectors: Bool
    let glyph: Bool
    @State private var open = false

    var body: some View {
        let model = state.readings?.model
        let effort = state.readings?.effort
        let modelValue = TerminalControlCatalog.value(model, control: "model")
        let effortValue = TerminalControlCatalog.value(effort, control: "effort")
        let label = TerminalControlCatalog.summaryLabel(model: modelValue, effort: effortValue, withConnectors: hasConnectors)
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                if glyph {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                } else {
                    if model?.label == nil { Text("Model").foregroundStyle(.secondary) }
                    Text(model?.label == nil ? modelValue : TerminalControlCatalog.shortModelLabel(modelValue))
                        .italic(model?.label == nil)
                    Divider().frame(height: 10)
                    if effort?.label == nil { Text("Effort").foregroundStyle(.secondary) }
                    Text(effortValue).italic(effort?.label == nil)
                }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("Session controls: \(label)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    NativeSessionControlsNotice(state: state)
                    ForEach(TerminalControlCatalog.chromeControls, id: \.self) { control in
                        ControlSection(state: state, control: control, blocked: blocked(control))
                    }
                    if hasConnectors {
                        ConnectorsChip(state: state, session: session)
                    }
                }
                .padding(12)
            }
            .frame(width: 340)
            .frame(maxHeight: 520)
        }
    }
}

/// One control in the folded panel (`ControlSection`): its name (with the ⓘ
/// where there is something behind it), then a switch or its rows.
private struct ControlSection: View {
    let state: NativeSessionControlsState
    let control: String
    let blocked: String?

    var body: some View {
        let reading = state.readings?.reading(control)
        let name = TerminalControlCatalog.name(control)
        let dotNote = blocked ?? (reading?.isUnread ?? true ? TerminalControlCatalog.unreadNote(control) : nil) ?? TerminalControlCatalog.note(control)
        let toggle = TerminalControlCatalog.options(control).count == 2
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(name).font(.subheadline.weight(.semibold))
                if let dotNote {
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary).help(dotNote)
                        .accessibilityLabel("About \(name)")
                }
            }
            if toggle, reading?.value == "on" || reading?.value == "off", blocked == nil {
                let isOn = reading?.value == "on"
                Toggle(isOn: Binding(get: { isOn }, set: { state.pick(control, $0 ? "on" : "off") })) {
                    Text(state.busy == control ? "Working…" : TerminalControlCatalog.value(reading, control: control))
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(state.busy != nil)
                .help("\(name): \(TerminalControlCatalog.value(reading, control: control)) — \(TerminalControlCatalog.sourceNote(reading?.source)) · \(TerminalControlCatalog.reach(control) ?? "")")
            } else {
                if let blocked { BlockedLine(text: blocked) }
                OptionRows(state: state, control: control, disabled: blocked != nil)
            }
        }
        .help(blocked ?? TerminalControlCatalog.chipHelp(control, reading: reading, busy: state.busy == control, blocked: nil))
    }
}

/// `ConnectorsPicker`: this session's MCP servers, each with the CLI's reason it
/// would skip one or what was read of it, and the way to the MCP servers view —
/// for a session on this Mac only.
private struct ConnectorsChip: View {
    let state: NativeSessionControlsState
    let session: NativeTerminalSession
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            ChipLabel(name: nil, value: "Connectors", unknown: false)
        }
        .buttonStyle(.plain)
        .help("Connectors")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.connectors) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.name)
                        Spacer(minLength: 8)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .opacity(row.enabled ? 1 : 0.55)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
                if case .local = state.target {
                    Divider()
                    // `panelOn('mcp')`: with the MCP servers feature off the door stays, disabled.
                    let mcpOn = NativeSessionFeatures.shared.value.mcpOn
                    Button(mcpOn ? "Open MCP servers" : TerminalControlCatalog.connectorsUnavailable) {
                        open = false
                        AppModel.shared.select("mcp")
                    }
                    .disabled(!mcpOn)
                    .help(mcpOn ? "Open MCP servers" : TerminalControlCatalog.mcpUninstalled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
            .padding(6)
            .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
        }
    }
}

// MARK: - The page's feature switches

/// `features.v2`, read from the page's storage: on first use, and again whenever a
/// window of this app becomes key — the way back from Settings, where they change.
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
        guard AppModel.shared.web.origin != nil else { return }
        NativeCodingAIPages.evaluate(CodingAIPageScripts.readStorage(SessionFeatures.storageKey), in: .main) { [weak self] json in
            let next = SessionFeatures.decode(json)
            if self?.value != next { self?.value = next }
        }
    }
}
