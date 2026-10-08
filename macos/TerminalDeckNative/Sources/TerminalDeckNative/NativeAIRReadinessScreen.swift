import SwiftUI
import TerminalDeckNativeCore

/// Actionable readiness in the existing page and settings design system.
/// DKA replaces the old screen at its routing sites; no tracked file is changed
/// by this slice. A supplied model and project let local fixtures use this view.
struct NativeAIRReadinessScreen: View {
    @State private var model: NativeAIRReadinessModel
    private let suppliedProject: String?

    init(model: NativeAIRReadinessModel = NativeAIRReadinessModel(), projectPath: String? = nil) {
        _model = State(initialValue: model)
        suppliedProject = projectPath
    }

    var body: some View {
        let project = suppliedProject ?? DeckProject.current
        Group {
            if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        NativePageScope(path: project)
                        NativeSettingsHead(title: "AI readiness", blurb: "Finish the checks so an AI can work with clear directions and useful ways to test its changes.")
                        header
                        if let result = model.lastResult {
                            Label(result.message, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                        agentPicker
                        if let error = model.error {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Re-check needed", systemImage: "exclamationmark.triangle")
                                    .font(.body.weight(.medium))
                                Text(error).textSelection(.enabled)
                                Text("The rows below keep the last report. Re-check to confirm the current state.")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                        if model.report == nil {
                            if model.scanning { NativeAIRReadinessSkeleton() }
                            else if model.error == nil { NativePageNote("Preparing the project checks…", busy: true) }
                        } else {
                            checkSections
                        }
                    }
                    .frame(maxWidth: 1312, alignment: .leading)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                NativePageEmpty(symbol: "checklist.checked", title: "Choose a project",
                    action: PageEmptyAction(label: "Open a project", primary: true, perform: { AppModel.shared.openProject() })) {
                    Text("AI readiness checks the files and tools in a project folder.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onChange(of: project, initial: true) { _, path in model.show(path) }
        .onChange(of: model.agent) { _, _ in model.changedAgent() }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .sheet(item: $model.pendingPreview) { pending in
            NativeAIRFixReview(preview: pending.preview, working: model.working, operation: model.operation,
                cancel: { model.pendingPreview = nil },
                confirm: { Task { await model.confirm(pending.preview) } })
                .interactiveDismissDisabled(model.working)
        }
        .sheet(item: $model.aiSession) { session in
            NativeAIRSessionSheet(model: session, cancel: { model.aiSession = nil })
                .interactiveDismissDisabled(session.starting)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                progress
                Spacer(minLength: 12)
                recheckButton
            }
            VStack(alignment: .leading, spacing: 12) {
                progress
                recheckButton
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.scanning { ProgressView().controlSize(.small) }
                Text(model.scanning ? "Re-checking…" : model.error != nil ? "Re-check needed" : model.progress?.ready == true ? "Ready" : "Make this project ready")
                    .font(.title2.weight(.semibold))
            }
            if let progress = model.progress {
                Text(progress.label).font(.callout).foregroundStyle(.secondary)
                let total = progress.passing + progress.remaining
                ProgressView(value: Double(progress.passing), total: Double(max(1, total)))
                    .tint(.secondary)
                    .frame(maxWidth: 360)
                    .accessibilityLabel("Checks passing")
                    .accessibilityValue("\(progress.passing) passing, \(progress.remaining) to finish")
                if let report = model.report, !report.scannedAt.isEmpty {
                    Text("Last checked \(NativeAIRReadinessText.checkedAt(report.scannedAt)) · readiness score \(progress.score) of 100")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Checking the project files and tools.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var recheckButton: some View {
        Button(model.scanning ? "Re-checking…" : "Re-check") { Task { await model.recheck() } }
            .disabled(model.working)
            .help("Read the project again and update every check")
    }

    @ViewBuilder private var agentPicker: some View {
        if let agents = model.report?.agents, !agents.isEmpty {
            NativeSettingRow(label: "Report on", help: model.view?.agent.map { "Reads \($0.file)" }) {
                Picker("Report on", selection: $model.agent) {
                    Text("Any agent").tag(String?.none)
                    ForEach(agents) { agent in Text(agent.label).tag(Optional(agent.agent)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.working)
            }
        }
    }

    private var checkSections: some View {
        let unfinished = model.checks.filter { $0.status == .fail || $0.status == .warn || AIRReadinessActions.isUnverified($0) }
        let passing = model.checks.filter { $0.status == .pass }
        let skipped = model.checks.filter { $0.status == .skip && !AIRReadinessActions.isUnverified($0) }
        return VStack(alignment: .leading, spacing: 16) {
            if !unfinished.isEmpty {
                Text("To finish · \(unfinished.count)").font(.body.weight(.semibold))
                checkRows(unfinished)
            }
            if !passing.isEmpty {
                DisclosureGroup("Passing · \(passing.count) checks") { checkRows(passing) }
            }
            if !skipped.isEmpty {
                DisclosureGroup("Not applicable · \(skipped.count) checks") { checkRows(skipped) }
            }
            if model.checks.isEmpty {
                NativePageNote("No checks were returned. Re-check the project to try again.")
            }
        }
    }

    private func checkRows(_ checks: [ReadinessCheck]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(checks) { check in
                NativeAIRReadinessCheckRow(check: check, plan: model.plan(for: check),
                    busy: model.busyCheck == check.id, operation: model.operation, disabled: model.working,
                    result: model.results[check.id],
                    fix: { Task { await model.preview(check) } },
                    ask: { model.askAI(check) }, open: { model.open(check) })
                if check.id != checks.last?.id { Divider() }
            }
        }
    }
}

private struct NativeAIRReadinessCheckRow: View {
    let check: ReadinessCheck
    let plan: AIRReadinessActionPlan
    let busy: Bool
    let operation: String?
    let disabled: Bool
    let result: ReadinessFixResult?
    let fix: () -> Void
    let ask: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: NativeAIRReadinessText.symbol(check))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityLabel(NativeAIRReadinessText.status(check))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(plan.title).font(.body.weight(.medium))
                    Text(NativeAIRReadinessText.status(check)).font(.caption).foregroundStyle(.secondary)
                }
                Text(check.status == .pass ? check.detail : plan.missingAndWhy)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if check.status != .pass {
                    if !check.detail.isEmpty {
                        Text(check.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(step).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                    if let reason = plan.manualReason {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actions }
                        VStack(alignment: .leading, spacing: 8) { actions }
                    }
                    .disabled(disabled)
                }
                if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(operation ?? "Working…")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                if let result {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        if plan.automaticFixAvailable {
            Button(busy ? "Preparing…" : "Fix it", action: fix)
                .help("Review the exact changes before approving this fix")
        }
        Button("Ask an AI to do it", action: ask)
            .help("Open a session with these steps ready to send")
        if check.opens != nil {
            Button("Open file", action: open).buttonStyle(.borderless)
        }
    }
}

private struct NativeAIRReadinessSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<3) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project instructions").font(.body.weight(.medium))
                    Text("Checking the files and tools that this project gives to its AI agents.")
                    Text("1. Review the project finding and the next step to finish this check.").font(.callout)
                    HStack { Text("Fix it"); Text("Ask an AI to do it") }.font(.callout)
                }
                .redacted(reason: .placeholder)
                .padding(12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading project checks")
    }
}

enum NativeAIRReadinessText {
    static func status(_ check: ReadinessCheck) -> String {
        if AIRReadinessActions.isUnverified(check) { return "Could not check" }
        switch check.status {
        case .pass: return "Passing"
        case .warn, .fail: return "Needs work"
        case .skip: return "Not applicable"
        }
    }

    static func symbol(_ check: ReadinessCheck) -> String {
        if AIRReadinessActions.isUnverified(check) { return "questionmark.circle" }
        switch check.status {
        case .pass: return "checkmark.circle"
        case .warn, .fail: return "exclamationmark.circle"
        case .skip: return "minus.circle"
        }
    }

    static func checkedAt(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
