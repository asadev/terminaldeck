import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// AI readiness, drawn in Swift — the web page (`components/ReadinessPanel.tsx`)
/// one-to-one: the score ring and its band, the weighted headline, Rescan, the
/// "Report on" agent pills, the error and cap lines, the agent-update rows, then
/// the checks (failures first) with their fixes, "Open it" and Dismiss, the
/// "Not applicable" aside, and the hidden-rows line that brings them back.
///
/// `readiness:scan` reads the project and `readiness:fix` applies a fix, as the
/// page called them; a file opens through `link:system`. Dismissed rows are kept
/// where the page kept them (`readiness.dismissed.v1`, in the page's storage), so
/// the agent-update rows and this page share one list.
struct NativeReadinessScreen: View {
    @State private var model = ReadinessScreenModel()

    var body: some View {
        let project = DeckProject.current
        Group {
            if AppModel.shared.sidebar == nil {
                LoadingView(message: "Loading Terminal Deck…")
            } else if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        DeckScopeLine(path: project)
                            .padding(.bottom, 16)
                        ReadinessPage(model: model)
                    }
                    .frame(maxWidth: 1312, alignment: .leading)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                DeckNeedsProject(label: "AI readiness", symbol: "checklist.checked")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onChange(of: project, initial: true) { _, path in model.show(path) }
    }
}

// MARK: - Model

@MainActor
@Observable
final class ReadinessScreenModel {
    private(set) var projectPath: String?
    private(set) var report: ReadinessReport?
    private(set) var error: String?
    private(set) var scanning = false
    private(set) var busyFix: String?
    private(set) var results: [String: ReadinessFixResult] = [:]
    private(set) var dismissed: ReadinessDismissed.Map = [:]
    /// Which agent the page is graded for; nil is "Any agent".
    var pick: String?

    @ObservationIgnored private var request = 0
    @ObservationIgnored private var context = 0

    /// A new project starts over: no report, no results, no pick — then a scan.
    func show(_ path: String?) {
        guard path != projectPath || report == nil && !scanning else { return }
        projectPath = path
        context += 1
        report = nil
        results = [:]
        busyFix = nil
        pick = nil
        loadDismissed()
        Task { await scan() }
    }

    func scan() async {
        guard let projectPath else { return }
        request += 1
        let token = request
        scanning = true
        error = nil
        defer { if token == request { scanning = false } }
        do {
            let answer = try await EngineBridge.shared.invoke("readiness:scan", [projectPath])
            guard token == request else { return }
            if let next = ReadinessReport(json: answer) {
                report = next
            } else {
                error = "The readiness scan gave no answer."
            }
        } catch {
            guard token == request else { return }
            self.error = Self.sentence(error)
        }
    }

    func apply(_ check: ReadinessCheck) async {
        guard let projectPath, let fix = check.fix else { return }
        let mine = context
        busyFix = check.id
        do {
            let answer = try await EngineBridge.shared.invoke("readiness:fix", [projectPath, fix.id])
            guard mine == context else { return }
            results[check.id] = ReadinessFixResult(json: answer)
            await scan()
        } catch {
            guard mine == context else { return }
            results[check.id] = ReadinessFixResult(ok: false, message: Self.sentence(error))
        }
        if mine == context { busyFix = nil }
    }

    /// "Open it": the file, in whatever this Mac opens it with — the page's `openLinkExternally`.
    func open(_ check: ReadinessCheck) {
        guard let projectPath, let opens = check.opens else { return }
        let url = ReadinessRules.fileURL(projectPath: projectPath, relPath: opens)
        Task { _ = try? await EngineBridge.shared.invoke("link:system", [url]) }
    }

    func dismiss(_ check: ReadinessCheck) {
        guard let projectPath else { return }
        change { ReadinessDismissed.dismiss($0, scope: projectPath, id: check.id) }
    }

    func bringBack() {
        guard let projectPath else { return }
        change { ReadinessDismissed.restoreAll($0, scope: projectPath) }
    }

    /// Shown at once, then written over what the page holds now — the agent-update rows
    /// keep their own (machine-wide) entries in the same map, and must not be overwritten.
    private func change(_ edit: @escaping (ReadinessDismissed.Map) -> ReadinessDismissed.Map) {
        dismissed = edit(dismissed)
        let read = NativeCodingAIPages.evaluate(CodingAIPageScripts.readStorage(ReadinessDismissed.key), in: .main) { [weak self] value in
            let next = edit(ReadinessDismissed.parse(value))
            self?.dismissed = next
            _ = NativeCodingAIPages.evaluate(CodingAIPageScripts.writeStorage(ReadinessDismissed.key, ReadinessDismissed.serialize(next)), in: .main)
        }
        if !read { saveDismissed() }
    }

    private func loadDismissed() {
        _ = NativeCodingAIPages.evaluate(CodingAIPageScripts.readStorage(ReadinessDismissed.key), in: .main) { [weak self] value in
            self?.dismissed = ReadinessDismissed.parse(value)
        }
    }

    private func saveDismissed() {
        _ = NativeCodingAIPages.evaluate(CodingAIPageScripts.writeStorage(ReadinessDismissed.key, ReadinessDismissed.serialize(dismissed)), in: .main)
    }

    static func sentence(_ error: Error) -> String {
        if let wire = error as? EngineWireError { return wire.description }
        return error.localizedDescription
    }
}

// MARK: - The page

private struct ReadinessPage: View {
    @Bindable var model: ReadinessScreenModel

    var body: some View {
        let view = model.report.map { ReadinessRules.view(of: $0, agent: model.pick) }
        let rows = view.map { ReadinessRules.sorted($0.checks) } ?? []
        let passing = rows.filter { $0.status == .pass }.count
        let applicable = rows.filter { $0.status != .skip }.count
        let away = Set(ReadinessDismissed.ids(model.dismissed, scope: model.projectPath ?? ""))
        let shown = rows.filter { !away.contains($0.id) }
        let hidden = rows.count - shown.count

        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                if let view {
                    ScoreRing(score: view.score, band: view.band)
                } else {
                    Color.clear.frame(width: 100, height: 100)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let view {
                        Text(ReadinessRules.bandWords(view.band))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(view.band == .atRisk ? ReadinessColors.fail : .primary)
                        Text(ReadinessRules.headline(score: view.score, passing: passing, applicable: applicable,
                                                     skipped: rows.count - applicable))
                            .foregroundStyle(.secondary)
                            .help("Each check carries a share of the score, sized by how much it matters.")
                        if let agent = view.agent {
                            Text("Graded for \(agent.label) · reads \(agent.file)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(model.error != nil ? "Scan failed" : "Scanning…").foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button(model.scanning ? "Scanning…" : "Rescan") { Task { await model.scan() } }
                    .disabled(model.scanning)
            }

            if let agents = model.report?.agents, !agents.isEmpty {
                AgentPills(agents: agents, pick: $model.pick)
            }

            if let error = model.error {
                Text(error).foregroundStyle(ReadinessColors.fail).textSelection(.enabled)
            }

            if let view, let cappedBy = view.cappedBy {
                (Text("Score held at \(view.score) by ") + Text(cappedBy).bold() + Text(" — fix that first."))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ReadinessColors.fail.opacity(0.09), in: .rect(cornerRadius: 8))
                    .accessibilityAddTraits(.updatesFrequently)
            }

            NativeCodingAIStaleAgents(store: .shared)
                .onAppear { NativeCodingAIStore.shared.refreshStaleAgents() }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, check in
                    if check.status == .skip && (index == 0 || shown[index - 1].status != .skip) {
                        Text("Not applicable to this project")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                            .padding(.horizontal, 12)
                    }
                    CheckRow(check: check, busy: model.busyFix == check.id, result: model.results[check.id],
                             apply: { Task { await model.apply(check) } },
                             open: { model.open(check) },
                             dismiss: { model.dismiss(check) })
                }
            }

            if hidden > 0 {
                HStack(spacing: 4) {
                    Text("\(ReadinessRules.hiddenWords(hidden)) — still counted in the score.")
                    Button("Show \(hidden == 1 ? "it" : "them") again") { model.bringBack() }
                        .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI readiness")
    }
}

enum ReadinessColors {
    static let pass = Color.green
    static let warn = Color.orange
    static let fail = Color.red
    static let working = Color.blue

    static func band(_ band: ReadinessBand) -> Color {
        switch band {
        case .strong: pass
        case .fair: working
        case .weak: warn
        case .atRisk: fail
        }
    }

    static func status(_ status: ReadinessStatus) -> Color {
        switch status {
        case .pass: pass
        case .warn: warn
        case .fail: fail
        case .skip: .secondary
        }
    }
}

/// The score, as a ring filled to its share of 100, coloured by its band.
private struct ScoreRing: View {
    let score: Int
    let band: ReadinessBand

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
            Circle()
                .trim(from: 0, to: ReadinessRules.ringFraction(score))
                .stroke(ReadinessColors.band(band), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                .accessibilityHidden(true)
        }
        .frame(width: 96, height: 96)
        .padding(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ReadinessRules.ringLabel(score: score, band: band))
    }
}

/// "Report on": Any agent, then each agent the scan answered for.
private struct AgentPills: View {
    let agents: [ReadinessForAgent]
    @Binding var pick: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("Report on").font(.callout).foregroundStyle(.secondary).padding(.trailing, 4)
            ReadinessPill(title: "Any agent", on: pick == nil,
                          help: "Any agent — passes if any of their instructions files is here") { pick = nil }
            ForEach(agents) { entry in
                ReadinessPill(title: entry.label, on: pick == entry.agent,
                              help: "Grade this project for \(entry.label), which reads \(entry.file)") { pick = entry.agent }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Which agent this page is graded for")
    }
}

/// The page's `Pill`: a quiet capsule that fills when it is the one chosen.
struct ReadinessPill: View {
    let title: String
    let on: Bool
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(on ? .medium : .regular))
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(on ? Color.primary.opacity(0.12) : (hovering ? Color.primary.opacity(0.06) : .clear), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One check: its glyph, title (and "caps the score"), finding, what the fix
/// changes, the fix's description while confirming, the outcome, and its buttons.
private struct CheckRow: View {
    let check: ReadinessCheck
    let busy: Bool
    let result: ReadinessFixResult?
    let apply: () -> Void
    let open: () -> Void
    let dismiss: () -> Void
    @State private var confirming = false

    var body: some View {
        let action = ReadinessRules.action(for: check, canOpen: true)
        let dismissable = check.status != .pass
        HStack(alignment: .top, spacing: 12) {
            Text(ReadinessRules.glyph(check.status))
                .font(.footnote.bold())
                .foregroundStyle(ReadinessColors.status(check.status))
                .frame(width: 20, height: 20)
                .background(ReadinessColors.status(check.status).opacity(check.status == .skip ? 0.15 : 0.2), in: .circle)
                .accessibilityLabel(ReadinessRules.statusWords(check.status))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(check.title).font(.body.weight(.medium))
                    if check.gate && check.status != .pass {
                        Text("caps the score")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ReadinessColors.fail)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(ReadinessColors.fail.opacity(0.12), in: .capsule)
                    }
                }
                Text(check.detail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 620, alignment: .leading)
                    .textSelection(.enabled)
                if let fix = check.fix, !fix.touches.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Changes").font(.caption).foregroundStyle(.tertiary)
                        Text(fix.touches.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if let fix = check.fix, confirming {
                    Text(fix.description).font(.callout).foregroundStyle(.secondary)
                }
                if let result {
                    Text(result.message)
                        .font(.callout)
                        .foregroundStyle(result.ok ? ReadinessColors.pass : ReadinessColors.fail)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if action != .none || dismissable {
                HStack(spacing: 6) {
                    if check.fix != nil && confirming {
                        Button("Cancel") { confirming = false }.buttonStyle(.borderless)
                    }
                    if action == .fix, let fix = check.fix {
                        Button(busy ? "Working…" : confirming ? "Yes, apply it" : fix.label) {
                            if fix.destructive && !confirming {
                                confirming = true
                                return
                            }
                            confirming = false
                            apply()
                        }
                        .tint(fix.destructive && confirming ? ReadinessColors.fail : nil)
                        .disabled(busy)
                        .help(fix.description)
                    }
                    if action == .open {
                        Button("Open it", action: open)
                            .help("Open \(check.opens ?? "") on this machine")
                    }
                    if dismissable {
                        Button("Dismiss", action: dismiss)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Hide this check. It still counts towards the score, and you can bring it back.")
                    }
                }
            }
        }
        .padding(12)
        .background(check.gate && (check.status == .fail || check.status == .warn) ? ReadinessColors.fail.opacity(0.09) : .clear,
                    in: .rect(cornerRadius: 10))
        .onChange(of: result) { confirming = false }
        .onChange(of: check.fix?.id) { confirming = false }
    }
}
