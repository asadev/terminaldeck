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
    @ObservationIgnored private var chatContext = false
    /// The engine's answer to the last usage:watch, still on its way (18 Oct, #651).
    @ObservationIgnored private var watchCall: Task<Void, Never>?

    init(target: SessionTarget) { self.target = target }
    func useChatContext(_ value: Bool) {
        guard value != chatContext else { return }
        chatContext = value
        if value { readContext(force: true) }
    }
    func acceptChatContext(_ snapshot: Any?) {
        guard let row = snapshot as? [String: Any], row.keys.contains("contextReading") else { return }
        guard let next = ContextReading.decode(row["contextReading"]) else { context = nil; return }
        if next != context { context = next }
    }

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
            subscriptions.append(EngineBridge.shared.on("session:chat:changed") { [weak self] args in
                guard let self, self.chatContext, args.first as? String == id else { return }
                self.acceptChatContext(args.count > 1 ? args[1] : nil)
            })
            subscriptions.append(EngineBridge.shared.on("usage:update") { [weak self] args in
                guard let self, let next = UsageReport.update(args, sessionID: id) else { return }
                self.acceptReport(next)
            })
            watchCall = Task { [weak self] in
                let next = UsageReport.decode(try? await EngineBridge.shared.invoke("usage:watch", [id]))
                if let next { self?.acceptReport(next) }
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
        if case .local(let id) = target {
            // #651: the unwatch goes only after the watch has answered, so it can never reach the engine first and
            // leave the session watched until the app quits. Shown again meanwhile: that bar keeps the watch.
            let pending = watchCall
            watchCall = nil
            Task { [weak self] in
                await pending?.value
                guard self?.watching != true else { return }
                EngineBridge.shared.send("usage:unwatch", [id])
            }
        }
    }

    /// The context window, re-read when the session prints (at most once a second) and on focus.
    func readContext(force: Bool) {
        guard withheld == nil, force || Date().timeIntervalSince(lastContextRead) >= 1 else { return }
        lastContextRead = Date()
        Task { [weak self] in
            guard let self else { return }
            let raw: Any?
            switch self.target {
            case .local(let id):
                if self.chatContext {
                    let snapshot = try? await EngineBridge.shared.invoke("session:chat:read", [id])
                    self.acceptChatContext(snapshot)
                    return
                }
                raw = try? await EngineBridge.shared.invoke("usage:context", [id])
            case .machine: raw = await self.machine("context", force: false)
            case .server: raw = nil
            }
            // PERF: only a changed reading is written (each write redraws the bar, once a second while output flows).
            if let next = ContextReading.decode(raw), next != self.context { self.context = next }
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

    private func acceptReport(_ next: UsageReport) {
        if next.account != report?.account || !next.numberedReadings.isEmpty {
            blocked = nil
            noLimits = false
            failed = false
            detail = nil
        }
        if next != report { report = next }
        readAccount()
    }

    private func readAccount() {
        accountLabel = report?.accountLabel
    }

}

// MARK: - The bar (`UsageBar`)

/// First in the session's controls: the context window as a strip (only while the
/// figure is fresh) and the plan limits behind a ring. A press opens either one's panel (the app's own menu surface);
/// opening the plan panel asks for fresh figures. Review of 18 Nov (items 15, 22): a clean ring with no pill behind
/// it, no address in the panel, a thin bar per limit with "% used" and "Resets in …", "No reading yet" where a number
/// is missing, and one Refresh.
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
        let readouts = (usage.report?.numberedReadings ?? []).map { UsageReadout.of($0, now: now) }
        let worst = UsageBarRules.worst(readouts)
        let agent = provider.map(TerminalAgent.name)
        // Names, never addresses (item 15): an account with no chosen name shows the part before the "@".
        let account = usage.accountLabel.map(DeckAccountWords.shown)
        let whose = [agent, account].compactMap { $0 }.joined(separator: " · ")
        let title = UsageBarRules.title(readouts: readouts, whose: whose, unwired: !EngineBridge.shared.isReady, withheld: usage.withheld,
                                        blocked: usage.blocked, report: usage.report)
        let reading = usage.withheld == nil && (usage.context?.isFresh(now: now) ?? false) ? usage.context : nil
        let figure = reading?.figure(compact: tight)
        let folded = tight && figure != nil
        return HStack(spacing: 4) {
            if let reading, figure != nil, !folded {
                Button { send(.press(.context)) } label: {
                    ContextStrip(reading: reading, figure: figure)
                        .padding(.horizontal, 5).frame(height: 26)
                        .background(Color.primary.opacity(hovering.contains("context") ? 0.07 : 0), in: .rect(cornerRadius: 7, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hover("context", $0) }
                .accessibilityLabel(reading.summary(now: now) ?? "Context window")
                .deckMenu(isPresented: binding(.context), alignment: .trailing, width: 280) {
                    if let breakdown = reading.panel(now: now) { ContextSection(panel: breakdown).deckMenuInset() }
                }
            }
            Button { send(.press(.plan)) } label: {
                HStack(spacing: 5) {
                    if folded, let reading { ContextStrip(reading: reading, figure: figure) }
                    DeckUsageRing(percent: worst?.percent, level: worst?.level ?? .ok, reading: usage.checking)
                }
                .padding(.horizontal, 5).frame(height: 26)
                .background(Color.primary.opacity(hovering.contains("plan") ? 0.07 : 0), in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hover("plan", $0) }
            .help(title)
            .accessibilityLabel(folded && reading != nil ? "\(reading?.summary(now: now) ?? "") Plan limits: \(title)" : "Plan limits: \(title)")
            .deckMenu(isPresented: binding(.plan), alignment: .trailing, width: 280) {
                if folded, let breakdown = reading?.panel(now: now) {
                    ContextSection(panel: breakdown).deckMenuInset()
                    DeckMenuDivider()
                }
                NativeUsagePlanPanel(provider: provider, agent: agent, account: account, readouts: readouts, now: now,
                                     checking: usage.checking,
                                     note: UsageBarRules.panelNote(unwired: !EngineBridge.shared.isReady, withheld: usage.withheld,
                                                                   blocked: usage.blocked, failed: usage.failed, detail: usage.detail,
                                                                   reason: usage.report?.reason, rows: readouts.count),
                                     missing: usage.report?.missingNumbersNote,
                                     refresh: { usage.check(force: true) })
            }
        }
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

    /// The pointer only tints the control now; a panel opens on a press.
    private func hover(_ part: String, _ inside: Bool) {
        if inside { hovering.insert(part) } else { hovering.remove(part) }
    }
}

/// The plan panel's content (inside the app's menu surface, 280 wide): whose limits, each limit as a thin bar, and
/// Refresh. A plain view of plain values, so a picture can draw it without a session.
struct NativeUsagePlanPanel: View {
    let provider: String?
    let agent: String?
    /// The account's NAME (never its address).
    let account: String?
    let readouts: [UsageReadout]
    let now: Double
    var checking = false
    /// Why there is nothing to show (kept behind the heading's tooltip, not as a sentence in the panel).
    var note: String? = nil
    /// One calm sentence when some numbers are missing (the logic lane's `report.missingNumbersNote`); said once.
    var missing: String? = nil
    var refresh: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            if let provider { NativeCodingAIProviderMark(provider: provider, size: 13) }
            Text(agent ?? "This session").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if let account { Text(account).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Spacer(minLength: 0)
        }
        .deckMenuInset()
        .help(note ?? "")
        ForEach(readouts, id: \.reading.id) { readout in
            DeckUsageLimitRow(readout: readout, now: now).deckMenuInset()
        }
        if readouts.isEmpty {
            Text(DeckUsageWords.none).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).deckMenuInset()
        }
        if let missing, !missing.isEmpty { DeckMenuNote(missing) }
        DeckMenuDivider()
        DeckMenuRow(checking ? "Checking…" : "Refresh", symbol: "arrow.clockwise", enabled: !checking, keepsOpen: true, action: refresh)
    }
}

/// The words of the usage panel (review of 18 Nov, item 15: never "Not reported").
enum DeckUsageWords {
    static let none = "No reading yet"

    /// "Resets in 3 h 12 min" from the limit's own reset instant; its own words when it only describes one; nil when
    /// nothing is known about the reset.
    static func resets(_ readout: UsageReadout, now: Double) -> String? {
        switch readout.reading.resets {
        case .at(let at):
            let minutes = Int(((at - now) / 60_000).rounded(.up))
            guard minutes > 0 else { return nil }
            if minutes < 60 { return "Resets in \(minutes) min" }
            let hours = minutes / 60, rest = minutes % 60
            if hours < 24 { return rest == 0 ? "Resets in \(hours) h" : "Resets in \(hours) h \(rest) min" }
            let days = hours / 24, left = hours % 24
            return left == 0 ? "Resets in \(days) d" : "Resets in \(days) d \(left) h"
        case .described(let text):
            return "Resets \(text)"
        case .notReported:
            return nil
        }
    }

    /// A limit with no number.
    static func missing(_ readout: UsageReadout) -> String {
        readout.state == .expired ? "No reading yet since it reset" : none
    }
}

/// One limit: its name, "42% used", a thin bar, and when it resets. No number: the name and "No reading yet".
struct DeckUsageLimitRow: View {
    let readout: UsageReadout
    let now: Double

    var body: some View {
        let percent = min(100, max(0, readout.percent ?? 0))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(readout.name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 8)
                if readout.bar, let used = readout.percent {
                    Text(UsageFormat.percent(used) + " used").font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(readout.level == .ok ? AnyShapeStyle(.primary) : AnyShapeStyle(levelColor(readout.level)))
                }
            }
            if readout.bar {
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(levelColor(readout.level))
                            .frame(width: percent > 0 ? max(4, box.size.width * percent / 100) : 0)
                    }
                }
                .frame(height: 4)
                .opacity(readout.state == .aged ? 0.6 : 1)
                if let resets = DeckUsageWords.resets(readout, now: now) {
                    Text(resets).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text(DeckUsageWords.missing(readout)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(readout.detail)
        .accessibilityElement(children: .combine)
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

/// The plan ring (review of 18 Nov, item 22: "this icon is very bad shape"): a clean ring 15 across and 2 thick, the
/// worst limit's share from twelve o'clock; a quarter arc turns while a reading is fetched. No number: the empty ring.
struct DeckUsageRing: View {
    let percent: Double?
    let level: UsageLevel
    let reading: Bool
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let filled = percent.map { max(0, min(100, $0)) / 100 } ?? 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.16), lineWidth: 2)
            if reading, !reduceMotion {
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(turning ? 270 : -90))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
                    .onAppear { turning = true }
                    .onDisappear { turning = false }
            } else if filled > 0 {
                Circle().trim(from: 0, to: max(filled, 0.03))
                    .stroke(levelColor(level), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(1)
        .frame(width: 15, height: 15)
    }
}

/// `ContextSection`: "Context window" with the figure, the used/free bar and rows, and two facts.
/// Also the breakdown at the top of the chat's ⓘ Session › Context.
struct ContextSection: View {
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

func levelColor(_ level: UsageLevel) -> Color {
    switch level {
    case .ok: return .accentColor
    case .warning: return .orange
    case .critical: return .red
    }
}
