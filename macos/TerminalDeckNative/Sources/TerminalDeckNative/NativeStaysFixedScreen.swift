import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Stays Fixed, drawn in Swift — src/renderer/staysfixed/StaysFixedPage.tsx one for
/// one: the same states, sections, wording and actions, on the same engine channels
/// (`staysfixed:*`), with the page's live `staysfixed:changed` event.
struct NativeStaysFixedScreen: View {
    @State private var model = StaysFixedScreenModel()

    var body: some View {
        let project = DeckProject.current
        Group {
            if AppModel.shared.sidebar == nil {
                LoadingView(message: "Loading Terminal Deck…")
            } else if let project {
                VStack(alignment: .leading, spacing: 0) {
                    DeckScopeLine(path: project)
                        .padding(.horizontal, 44)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    StaysFixedPage(model: model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                DeckNeedsProject(label: StaysFixedRules.name, symbol: "checkmark.shield")
            }
        }
        .background(.background)
        .onChange(of: project, initial: true) { _, path in model.show(path) }
        .onDisappear { model.leave() }
    }
}

// MARK: - Model

@MainActor
@Observable
final class StaysFixedScreenModel {
    enum Busy { case setup, check, mark }
    /// nil while it is being looked at.
    struct ReadinessState: Equatable {
        var value: FixedReadiness?
        var message: String?
    }

    private(set) var projectPath: String?
    private(set) var status: StaysFixedStatus?
    private(set) var loadError: String?
    private(set) var busy: Busy?
    private(set) var problem: String?
    private(set) var mark: FixedMarkOutcome?
    private(set) var readiness: ReadinessState?
    var readinessOpen = false
    private(set) var full: FixedResults?
    private(set) var now = Date().timeIntervalSince1970 * 1000

    @ObservationIgnored private var loading = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var changed: EngineSubscription?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func show(_ path: String?) {
        guard path != projectPath else { return }
        projectPath = path
        status = nil
        readiness = nil
        readinessOpen = false
        mark = nil
        problem = nil
        full = nil
        loadError = nil
        guard path != nil else { return }
        if changed == nil {
            changed = EngineBridge.shared.on(StaysFixedWire.changed) { [weak self] args in
                guard let self, let path = args.first as? String, path == self.projectPath else { return }
                Task { await self.load() }
            }
        }
        Task { await load() }
    }

    func leave() {
        changed?.cancel()
        changed = nil
        ticker?.cancel()
        ticker = nil
    }

    private func call(_ channel: String, _ args: [Any?]) async throws -> Any {
        try await EngineBridge.shared.invoke(channel, args)
    }

    /// One read at a time; a change during it asks for one more.
    func load() async {
        guard let projectPath else { return }
        if loading { again = true; return }
        loading = true
        defer { loading = false }
        do {
            repeat {
                again = false
                let raw = try await call(StaysFixedWire.status, [projectPath])
                guard projectPath == self.projectPath else { return }
                status = StaysFixedWire.status(raw, projectPath: projectPath)
                loadError = nil
            } while again
        } catch {
            loadError = deckMessage(error)
        }
        updateTicker()
        if status?.setUp == false, status?.available == true, readiness == nil { await loadReadiness(false) }
    }

    /// The elapsed time moves every second while a check runs.
    private func updateTicker() {
        if status?.running == nil {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        now = Date().timeIntervalSince1970 * 1000
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.now = Date().timeIntervalSince1970 * 1000
            }
        }
    }

    func loadReadiness(_ refresh: Bool) async {
        guard let projectPath else { return }
        readiness = nil
        do {
            let answer = StaysFixedWire.readiness(try await call(StaysFixedWire.readiness, [projectPath, refresh]))
            readiness = ReadinessState(value: answer.readiness, message: answer.message)
        } catch {
            readiness = ReadinessState(value: nil, message: deckMessage(error))
        }
    }

    func runSetup() async {
        guard let projectPath else { return }
        busy = .setup
        problem = nil
        do {
            let outcome = StaysFixedWire.setup(try await call(StaysFixedWire.setup, [projectPath]))
            if !outcome.ok { problem = outcome.problem }
        } catch {
            problem = deckMessage(error)
        }
        busy = nil
        await load()
    }

    func runCheck() async {
        guard let projectPath else { return }
        busy = .check
        problem = nil
        mark = nil
        full = nil
        // The check runs for minutes; the page shows its progress straight away.
        let started = Task { () -> String? in
            StaysFixedWire.check(try await self.call(StaysFixedWire.check, [projectPath])).message
        }
        Task { await load() }
        do {
            if let message = try await started.value { problem = message }
        } catch {
            problem = deckMessage(error)
        }
        busy = nil
        await load()
    }

    func stop() async {
        guard let projectPath else { return }
        _ = try? await call(StaysFixedWire.stop, [projectPath])
        await load()
    }

    func markGood(anyway: Bool) async {
        guard let projectPath else { return }
        busy = .mark
        mark = nil
        do {
            mark = StaysFixedWire.mark(try await call(StaysFixedWire.markGood, [projectPath, anyway]))
        } catch {
            mark = FixedMarkOutcome(ok: false, marked: false, already: false, refused: nil, refusedFor: nil, summary: deckMessage(error))
        }
        busy = nil
        await load()
    }

    func setAgents(_ on: Bool) async {
        guard let projectPath else { return }
        status?.agents = on
        do {
            status = StaysFixedWire.status(try await call(StaysFixedWire.agents, [projectPath, on]), projectPath: projectPath)
        } catch {
            await load()
        }
    }

    func openFull() async {
        guard let projectPath else { return }
        full = StaysFixedWire.results(try? await call(StaysFixedWire.results, [projectPath, true]))
    }

    func closeFull() { full = nil }

    func toggleReadiness() {
        readinessOpen.toggle()
        if readinessOpen && readiness == nil { Task { await loadReadiness(false) } }
    }
}

// MARK: - The page

private struct StaysFixedPage: View {
    let model: StaysFixedScreenModel

    var body: some View {
        if let error = model.loadError, model.status == nil {
            DeckPageEmpty(symbol: "checkmark.shield", title: "\(StaysFixedRules.name) could not be read", message: error)
        } else if let status = model.status {
            if !status.available {
                DeckPageEmpty(symbol: "checkmark.shield", title: "\(StaysFixedRules.name) is not part of this build",
                              message: status.unavailable ?? "")
            } else if !status.setUp {
                FixedColumn { NotSetUp(model: model) }
            } else if let full = model.full {
                FixedColumn { FullReport(results: full, back: model.closeFull) }
            } else {
                FixedColumn { SetUpPage(model: model, status: status) }
            }
        } else {
            Color.clear
        }
    }
}

/// The page's column: scrolls, left-aligned, as wide as the web page's.
private struct FixedColumn<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The verdict at the head of the page: its mark, headline and subline, and the actions.
private struct FixedHead<Actions: View>: View {
    let tone: FixedTone
    var running = false
    var symbol: String
    let headline: String
    let subline: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tone.color.opacity(tone == .muted ? 0.16 : 0.18))
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tone == .muted ? Color.secondary : tone.color)
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                Text(subline).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) { actions }
        }
    }
}

private func toneSymbol(_ tone: FixedTone) -> String {
    switch tone {
    case .positive: return "checkmark"
    case .warning: return "exclamationmark"
    case .critical: return "xmark"
    case .muted: return "minus"
    }
}

private struct FixedSectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            trailing
            Spacer(minLength: 0)
        }
    }
}

private struct FixedProblem: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.red).textSelection(.enabled)
    }
}

private struct FixedQuiet: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

// MARK: Not set up

private struct NotSetUp: View {
    let model: StaysFixedScreenModel

    var body: some View {
        FixedHead(tone: .muted, symbol: "checkmark.shield", headline: "Not set up in this project",
             subline: "After you or an agent change something, \(StaysFixedRules.name) checks that nothing that already worked has changed.") {
            Button(model.busy == .setup ? "Setting up…" : "Set up") { Task { await model.runSetup() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy == .setup)
        }
        if let problem = model.problem { FixedProblem(text: problem) }
        VStack(alignment: .leading, spacing: 10) {
            FixedSectionTitle(title: "On this Mac") {
                if model.readiness != nil {
                    Button("Look again") { Task { await model.loadReadiness(true) } }
                        .buttonStyle(.link)
                }
            }
            FixedReadinessView(state: model.readiness)
        }
        .padding(.top, 14)
    }
}

// MARK: Set up

private struct SetUpPage: View {
    let model: StaysFixedScreenModel
    let status: StaysFixedStatus

    var body: some View {
        let tone = StaysFixedRules.statusTone(status)
        let running = status.running
        FixedHead(tone: tone, running: running != nil, symbol: toneSymbol(tone),
             headline: StaysFixedRules.headline(status), subline: StaysFixedRules.subline(status, now: model.now)) {
            if running != nil {
                Button("Stop") { Task { await model.stop() } }
            } else {
                Button("Run check") { Task { await model.runCheck() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy != nil)
            }
            Button(model.busy == .mark ? "Marking…" : "Mark this build as good") { Task { await model.markGood(anyway: false) } }
                .disabled(running != nil || model.busy != nil)
            if status.last != nil && running == nil {
                Button("Full report") { Task { await model.openFull() } }
            }
        }

        if let running {
            VStack(alignment: .leading, spacing: 2) {
                Text(running.step).font(.callout)
                Text("\(StaysFixedRules.startedBy(running)) · \(StaysFixedRules.elapsed(model.now - running.startedAt))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }

        if let problem = model.problem { FixedProblem(text: problem) }
        if !status.git {
            FixedNote(tone: .warning, text: "This folder is not a git repository yet, so a check cannot run here.") {
                Button("Source control") { DeckProject.show("git") }
            }
        }
        if let mark = model.mark {
            FixedNote(tone: StaysFixedRules.markTone(mark), text: mark.summary) {
                if mark.refusedFor == .differences {
                    Button("Mark as good anyway") { Task { await model.markGood(anyway: true) } }
                        .disabled(model.busy != nil || running != nil)
                }
                if mark.refusedFor == .unchecked {
                    Button("Run check") { Task { await model.runCheck() } }
                        .disabled(model.busy != nil || running != nil)
                }
            }
        }
        if !status.versionNote.isEmpty { FixedQuiet(text: status.versionNote) }

        if let last = status.last, running == nil { ResultsView(results: last, all: false) }

        VStack(alignment: .leading, spacing: 10) {
            FixedSectionTitle(title: "Guards") {
                DeckInfoNote(label: "Guards", text: "A guard is one rule, in plain words, for a bug that was already fixed once — so that bug can never come back unnoticed. Each one is a small file in .staysfixed/guards in this project; an agent can write one for you.")
            }
            if let guardProblem = status.guardProblem { FixedProblem(text: guardProblem) }
            if status.guards.isEmpty {
                FixedQuiet(text: "None yet.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(status.guards, id: \.name) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.callout.weight(.medium))
                                if !item.because.isEmpty {
                                    Text(item.because).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(.top, 8)

        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Give agents \(StaysFixedRules.name)").font(.callout.weight(.medium))
                Text("\(StaysFixedRules.agentNames()) sessions you start here can check their own work.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("Give agents \(StaysFixedRules.name)", isOn: Binding(
                get: { status.agents },
                set: { on in Task { await model.setAgents(on) } }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.top, 8)

        VStack(alignment: .leading, spacing: 10) {
            Button { model.toggleReadiness() } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.readinessOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 12)
                    Text("What this Mac can check").font(.callout.weight(.medium))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.readinessOpen ? .isSelected : [])
            if model.readinessOpen { FixedReadinessView(state: model.readiness) }
        }
        .padding(.top, 8)
    }
}

/// A note with a tone, and its one or two buttons (`sf-note`, `MarkNote`).
private struct FixedNote<Buttons: View>: View {
    let tone: FixedTone
    let text: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tone.color.opacity(tone == .muted ? 0.08 : 0.12), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tone.color.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

// MARK: Results

private struct ResultsView: View {
    let results: FixedResults
    let all: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(results.differences) { difference in
                DifferenceView(difference: difference, results: results, all: all)
            }
            if !results.unchanged.isEmpty {
                Text(results.unchanged).font(.callout).textSelection(.enabled)
            }
            if !all, let notChecked = results.notChecked { FixedQuiet(text: notChecked) }
        }
    }
}

private struct DifferenceView: View {
    let difference: FixedDifference
    let results: FixedResults
    let all: Bool
    @State private var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(difference.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
            if difference.needsPerson {
                Text(difference.needsPersonWhy).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(Array(StaysFixedRules.pictures(results, difference.id).enumerated()), id: \.offset) { _, picture in
                let sides: [(String, String?)] = [("before", picture.before), ("after", picture.after)]
                let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                layout {
                    ForEach(sides, id: \.0) { side, url in
                        if let data = StaysFixedRules.pictureData(url), let image = NSImage(data: data) {
                            VStack(alignment: .leading, spacing: 4) {
                                Button { large.toggle() } label: {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: large ? .infinity : 360, alignment: .leading)
                                        .clipShape(.rect(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(large ? "Show the pictures side by side" : "Show the pictures larger")
                                .help("\(picture.journey), \(side)")
                                Text(side == "before" ? "Before" : "After").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(difference.changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(change.what).font(.callout.weight(.medium)).textSelection(.enabled)
                        HStack(alignment: .top, spacing: 10) {
                            FixedValueView(label: "Before", text: change.kind == .appeared ? nil : change.before)
                            FixedValueView(label: "After", text: change.kind == .vanished ? nil : change.after)
                        }
                    }
                }
            }
            if !all && difference.more > 0 {
                FixedQuiet(text: "And \(StaysFixedRules.count(difference.more, "more change")) — the full report has them.")
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(difference.needsPerson ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: difference.needsPerson ? 1 : 0.5))
    }
}

private struct FixedValueView: View {
    let label: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let text {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            } else {
                Text("Not there").font(.callout).italic().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Readiness

private struct FixedReadinessView: View {
    let state: StaysFixedScreenModel.ReadinessState?

    var body: some View {
        if let state {
            if let r = state.value {
                VStack(alignment: .leading, spacing: 10) {
                    if !r.ready.isEmpty {
                        Label {
                            Text("Can check \(StaysFixedRules.listWords(r.ready)).")
                        } icon: {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                        .font(.callout)
                    }
                    if !r.gaps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(r.gaps.enumerated()), id: \.offset) { _, gap in GapView(gap: gap) }
                        }
                    }
                    if !r.notHere.isEmpty { FixedQuiet(text: "Not checked here: \(StaysFixedRules.listWords(r.notHere)).") }
                }
            } else {
                FixedProblem(text: state.message ?? "")
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking at what this Mac can check…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GapView: View {
    let gap: FixedGap

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(Text(StaysFixedRules.sentenceCase(gap.name)).fontWeight(.medium)) needs \(gap.what).")
                    .font(.callout)
                if !gap.why.isEmpty {
                    DeckInfoNote(label: gap.what, text: gap.unlocks.isEmpty ? gap.why : "\(gap.why) It unlocks: \(gap.unlocks)")
                }
            }
            if !gap.fix.isEmpty {
                HStack(spacing: 8) {
                    Text(gap.byPerson ? "Only you can do this" : "An agent can do this")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    FixView(text: gap.fix)
                    if gap.what == "a git repository" {
                        Button("Source control") { DeckProject.show("git") }.buttonStyle(.link)
                    }
                }
            }
        }
    }
}

private struct FixView: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
            Button(copied ? "Copied" : "Copy") {
                DeckProject.copy(text)
                copied = true
                Task {
                    try? await Task.sleep(for: .milliseconds(1400))
                    copied = false
                }
            }
            .buttonStyle(.link)
        }
    }
}

// MARK: Full report

private struct FullReport: View {
    let results: FixedResults
    let back: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Back", action: back)
            Text(results.headline).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
        }
        if !results.detail.isEmpty {
            Text(results.detail).font(.callout).textSelection(.enabled)
        }
        ResultsView(results: results, all: true)
        if !results.gaps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                FixedSectionTitle(title: "Not looked at") { EmptyView() }
                ForEach(Array(results.gaps.enumerated()), id: \.offset) { _, gap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gap.what).font(.callout.weight(.medium))
                        if !gap.why.isEmpty { FixedQuiet(text: gap.why) }
                        if !gap.unlockedBy.isEmpty { FixedQuiet(text: "To change that: \(gap.unlockedBy)") }
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}
