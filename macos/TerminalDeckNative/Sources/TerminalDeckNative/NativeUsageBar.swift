import SwiftUI
import TerminalDeckNativeCore

// MARK: - State (`useUsageBar`, `useContextWindow`)

/// One session's plan limits and context window, read where the session runs: this
/// Mac's engine (`usage:*`), a paired machine (`machines:usage:read`), or nothing for
/// a terminal on a server — whose figures would be this Mac's, so none are shown.
@MainActor
@Observable
final class NativeUsageState {
    let target: SessionTarget
    private(set) var report: UsageReport?
    private(set) var context: ContextReading?
    private(set) var checking = false
    private(set) var blocked: String?
    private(set) var noLimits = false
    private(set) var detail: String?
    private(set) var failed = false
    private(set) var accountLabel: String?

    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var watching = false
    /// How many bars show this session (the cluster can hold more than one while it re-fits).
    @ObservationIgnored private var shown = 0
    @ObservationIgnored private var lastContextRead = Date.distantPast
    @ObservationIgnored private var cap: Task<Void, Never>?

    init(target: SessionTarget) { self.target = target }

    var withheld: String? {
        if case .server = target { return UsageBarRules.serverWithheld }
        return nil
    }

    /// Start reading while a bar shows the session; the engine pushes plan changes.
    func start() {
        shown += 1
        guard !watching, withheld == nil else { return }
        watching = true
        switch target {
        case .local(let id):
            subscriptions.append(EngineBridge.shared.on("usage:update") { [weak self] args in
                guard let self, args.first as? String == id, let next = UsageReport.decode(args.count > 1 ? args[1] : nil) else { return }
                self.report = next
                self.readAccount()
            })
            Task { [weak self] in
                let next = UsageReport.decode(try? await EngineBridge.shared.invoke("usage:watch", [id]))
                if let next { self?.report = next }
                self?.readAccount()
            }
        case .machine:
            Task { [weak self] in
                guard let self else { return }
                if let next = UsageReport.decode(await self.machine("plan", force: false)) { self.report = next }
            }
        case .server:
            break
        }
        readContext(force: true)
    }

    func stop() {
        shown = max(0, shown - 1)
        guard watching, shown == 0 else { return }
        watching = false
        subscriptions.removeAll()
        if case .local(let id) = target { EngineBridge.shared.send("usage:unwatch", [id]) }
    }

    /// The context window, re-read when the session prints (at most once a second) and on focus.
    func readContext(force: Bool) {
        guard withheld == nil, force || Date().timeIntervalSince(lastContextRead) >= 1 else { return }
        lastContextRead = Date()
        Task { [weak self] in
            guard let self else { return }
            let raw: Any?
            switch self.target {
            case .local(let id): raw = try? await EngineBridge.shared.invoke("usage:context", [id])
            case .machine: raw = await self.machine("context", force: false)
            case .server: raw = nil
            }
            if let next = ContextReading.decode(raw) { self.context = next }
        }
    }

    /// Opening the plan panel is the refresh (`check`); "Check again" forces past a settled answer.
    func check(force: Bool = false) {
        guard withheld == nil else { return }
        checking = true
        if force {
            blocked = nil
            noLimits = false
        }
        cap?.cancel()
        cap = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UsageBarRules.refreshCap))
            guard !Task.isCancelled, let self, self.checking else { return }
            self.checking = false
            self.detail = UsageBarRules.gaveUp
            self.failed = true
        }
        Task { [weak self] in
            guard let self else { return }
            let raw: Any?
            switch self.target {
            case .local(let id): raw = try? await EngineBridge.shared.invoke("usage:refresh", [id, force])
            case .machine: raw = await self.machine("refresh", force: force)
            case .server: raw = nil
            }
            if case .machine = self.target, let report = UsageReport.decode((raw as? [String: Any])?["report"]) { self.report = report }
            let answer = UsageBarRules.outcome(raw)
            self.cap?.cancel()
            self.checking = false
            self.detail = raw == nil ? UsageBarRules.outcomeMessage("unreadable") : answer.detail
            self.failed = raw == nil || !answer.ok
            if answer.ok {
                self.blocked = nil
                self.noLimits = false
                return
            }
            if answer.settled { self.blocked = answer.detail }
            if answer.noLimits { self.noLimits = true }
        }
    }

    private func machine(_ want: String, force: Bool) async -> Any? {
        guard case .machine(let machineId, let sessionId) = target else { return nil }
        return try? await EngineBridge.shared.invoke("machines:usage:read", [machineId, sessionId, want, force])
    }

    /// The login as the account chip states it (`useAccountIdentity` + `accountIdentity`).
    private func readAccount() {
        guard let account = report?.reportedAccount else {
            accountLabel = nil
            return
        }
        let name = account.name ?? ""
        guard case .local = target, let id = account.id else {
            accountLabel = name.isEmpty ? nil : name
            return
        }
        Task { [weak self] in
            let raw = try? await EngineBridge.shared.invoke("profiles:signin", [id, ["refresh": false]])
            let signIn = raw.map { CodingAIAccountsParse.signIn(CodingAIJSON($0)) }
            let label = AccountChipRules.identity((id, name, nil), signIn).label.trimmingCharacters(in: .whitespaces)
            self?.accountLabel = label.isEmpty ? nil : label
        }
    }
}

// MARK: - The bar (`UsageBar`)

/// First in the session's controls: the context window as a strip (only while the
/// figure is fresh) and the plan limits behind a ring. Hovering either opens its
/// panel; a press holds it open; opening the plan panel asks for fresh figures.
struct NativeUsageBar: View {
    let usage: NativeUsageState
    let provider: String?
    /// The narrowest bar folds the strip into the ring's control.
    var tight = false

    @State private var panel = UsagePanelState.shut
    @State private var hovering: Set<String> = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            bar(now: context.date.timeIntervalSince1970 * 1000)
        }
        .onAppear { usage.start() }
        .onDisappear { usage.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in usage.readContext(force: false) }
    }

    private func bar(now: Double) -> some View {
        let readouts = (usage.report?.readings ?? []).map { UsageReadout.of($0, now: now) }
        let worst = UsageBarRules.worst(readouts)
        let agent = provider.map(TerminalAgent.name)
        let whose = [agent, usage.accountLabel].compactMap { $0 }.joined(separator: " · ")
        let title = UsageBarRules.title(readouts: readouts, whose: whose, unwired: !EngineBridge.shared.isReady, withheld: usage.withheld,
                                        blocked: usage.blocked, report: usage.report)
        let reading = usage.withheld == nil && (usage.context?.isFresh(now: now) ?? false) ? usage.context : nil
        let figure = reading?.figure(compact: tight)
        let folded = tight && figure != nil
        return HStack(spacing: 6) {
            if let reading, figure != nil, !folded {
                Button { send(.press(.context)) } label: { ContextStrip(reading: reading, figure: figure) }
                    .buttonStyle(.plain)
                    .onHover { hover("context", $0) }
                    .accessibilityLabel(reading.summary(now: now) ?? "Context window")
                    .popover(isPresented: binding(.context), arrowEdge: .bottom) {
                        sheet { if let breakdown = reading.panel(now: now) { ContextSection(panel: breakdown) } }
                    }
            }
            Button { send(.press(.plan)) } label: {
                HStack(spacing: 4) {
                    if folded, let reading { ContextStrip(reading: reading, figure: figure) }
                    Ring(percent: worst?.percent, level: worst?.level ?? .ok, reading: usage.checking)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.45), in: .capsule)
            }
            .buttonStyle(.plain)
            .onHover { hover("plan", $0) }
            .accessibilityLabel(folded && reading != nil ? "\(reading?.summary(now: now) ?? "") Plan limits: \(title)" : "Plan limits: \(title)")
            .popover(isPresented: binding(.plan), arrowEdge: .bottom) {
                sheet {
                    if folded, let breakdown = reading?.panel(now: now) { ContextSection(panel: breakdown) }
                    planPanel(readouts: readouts, agent: agent)
                }
            }
        }
    }

    @ViewBuilder
    private func planPanel(readouts: [UsageReadout], agent: String?) -> some View {
        let note = UsageBarRules.panelNote(unwired: !EngineBridge.shared.isReady, withheld: usage.withheld, blocked: usage.blocked,
                                           failed: usage.failed, detail: usage.detail, reason: usage.report?.reason, rows: readouts.count)
        HStack(spacing: 6) {
            if let provider { NativeCodingAIProviderMark(provider: provider, size: 13) }
            Text(agent ?? "This session").font(.callout.weight(.semibold))
            if let account = usage.accountLabel { Text(account).font(.callout).foregroundStyle(.secondary) }
            if let note { NativeCodingAIInfo(label: "these plan limits", text: note) }
            Spacer()
        }
        ForEach(readouts, id: \.reading.id) { readout in
            WindowRow(readout: readout)
        }
        if usage.checking {
            Text("Checking with \(agent ?? "the agent")…").font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
        }
        if usage.blocked != nil {
            Button("Check again") { usage.check(force: true) }
        }
    }

    private func sheet<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(width: 300, alignment: .leading)
            .onHover { hover("sheet", $0) }
    }

    // MARK: Opening and closing

    private func binding(_ which: UsagePanelState.Panel) -> Binding<Bool> {
        Binding(get: { panel.open == which }, set: { if !$0, panel.open == which { panel = .shut } })
    }

    private func send(_ event: UsagePanelState.Event) {
        let next = panel.next(event)
        if UsagePanelState.opensPlan(panel, next) { usage.check() }
        panel = next
    }

    private func hover(_ part: String, _ inside: Bool) {
        if inside {
            hovering.insert(part)
            if part == "context" { send(.hover(.context)) }
            if part == "plan" { send(.hover(.plan)) }
        } else {
            hovering.remove(part)
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                if hovering.isEmpty { send(.leave) }
            }
        }
    }
}

/// The context figure as a strip: its share of the window filled, or the figure when no window is known.
private struct ContextStrip: View {
    let reading: ContextReading
    let figure: String?

    var body: some View {
        if let share = reading.share {
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(levelColor(reading.level)).frame(width: box.size.width * share / 100)
                }
            }
            .frame(width: 36, height: 5)
        } else if let figure {
            Text(figure).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The plan ring: the worst window's share, from twelve o'clock; it pulses while a check runs.
private struct Ring: View {
    let percent: Double?
    let level: UsageLevel
    let reading: Bool

    var body: some View {
        let filled = percent.map { max(0, min(100, $0)) / 100 } ?? 0
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2)
            if filled > 0 {
                Circle().trim(from: 0, to: filled).stroke(levelColor(level), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 12, height: 12)
        .opacity(reading ? 0.55 : 1)
        .animation(reading ? .easeInOut(duration: 0.8).repeatForever() : .default, value: reading)
    }
}

/// One window of the plan (`WindowRow`): its own name, its value, a meter and when it renews.
private struct WindowRow: View {
    let readout: UsageReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(readout.name).font(.callout)
                Spacer()
                Text(readout.value).font(.callout.monospacedDigit()).foregroundStyle(levelColor(readout.level))
            }
            if readout.bar {
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(levelColor(readout.level))
                            .frame(width: box.size.width * min(100, max(0, readout.percent ?? 0)) / 100)
                    }
                }
                .frame(height: 5)
                .opacity(readout.state == .aged ? 0.55 : 1)
                if !readout.facts.isEmpty { Text(readout.facts).font(.caption).foregroundStyle(.secondary) }
            } else if !readout.detail.isEmpty {
                Text(readout.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// `ContextSection`: "Context window" with the figure, the used/free bar and rows, and two facts.
private struct ContextSection: View {
    let panel: ContextPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Context window").font(.callout)
                Spacer()
                Text(panel.headline).font(.callout.monospacedDigit()).foregroundStyle(levelColor(panel.level))
            }
            if !panel.segments.isEmpty {
                GeometryReader { box in
                    HStack(spacing: 1) {
                        ForEach(panel.segments, id: \.key) { segment in
                            Rectangle().fill(segment.key == "used" ? levelColor(panel.level) : Color.secondary.opacity(0.25))
                                .frame(width: max(0, box.size.width * segment.width / 100 - 1))
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(.capsule)
                ForEach(panel.segments, id: \.key) { segment in
                    HStack {
                        Circle().fill(segment.key == "used" ? levelColor(panel.level) : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                        Text(segment.label).font(.caption)
                        Spacer()
                        Text(segment.amount).font(.caption.monospacedDigit())
                        Text(segment.share).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            }
            ForEach(panel.facts, id: \.label) { fact in
                HStack {
                    Text(fact.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fact.value).font(.caption)
                }
            }
        }
        .help(panel.provenance)
    }
}

private func levelColor(_ level: UsageLevel) -> Color {
    switch level {
    case .ok: return .accentColor
    case .warning: return .orange
    case .critical: return .red
    }
}
