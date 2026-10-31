import SwiftUI
import TerminalDeckNativeCore

/// Project-scoped readiness content. ProjectPage owns the page header and scroll.
struct NativeAIRReadinessScreen: View {
    @State private var model: NativeAIRReadinessModel
    private let suppliedProject: String?
    private let suppliedProjectName: String?
    private let onFixAllWithHoot: (() -> Void)?
    private let onReviewChanges: (() -> Void)?
    private let embedded: Bool

    init(model: NativeAIRReadinessModel = NativeAIRReadinessModel(), projectPath: String? = nil, projectName: String? = nil,
         onFixAllWithHoot: (() -> Void)? = nil, onReviewChanges: (() -> Void)? = nil,
         embedded: Bool = false) {
        _model = State(initialValue: model)
        suppliedProject = projectPath
        suppliedProjectName = projectName
        self.onFixAllWithHoot = onFixAllWithHoot
        self.onReviewChanges = onReviewChanges
        self.embedded = embedded
    }

    var body: some View {
        let project = suppliedProject ?? DeckProject.current
        Group {
            if project != nil {
                if embedded { content }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text("Readiness").font(.system(size: 20, weight: .semibold))
                                Spacer()
                                reportMenu
                            }
                            content
                        }
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                NativePageEmpty(symbol: "checklist.checked", title: "Choose a project",
                    action: PageEmptyAction(label: "Open a folder", primary: true,
                        perform: { AppModel.shared.openFolder() })) {
                    Text("Readiness checks the files and tools in a project folder.")
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            summary
            if let error = model.error {
                PROJPAGEReadinessCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Couldn't check readiness.").font(.system(size: 13, weight: .semibold))
                            Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Try Again") { Task { await model.recheck() } }
                            .buttonStyle(.bordered).disabled(model.working)
                    }.padding(16)
                }
            } else if model.report == nil {
                NativeAIRReadinessSkeleton()
            } else {
                if let result = model.lastResult {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                checkSections
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 6)
    }

    private var summary: some View {
        PROJPAGEReadinessCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    ring
                    summaryText
                    summaryActions
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 18) { ring; summaryText }
                    HStack { Spacer(); summaryActions }
                }
            }.padding(16)
        }
    }

    private var ring: some View {
        let passing = model.progress?.passing ?? 0
        let needed = passing + (model.progress?.remaining ?? 0)
        return ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 6)
            Circle().trim(from: 0, to: needed == 0 ? 0 : Double(passing) / Double(needed))
                .stroke(.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(model.report == nil ? "—" : "\(passing)/\(needed)")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .padding(5).frame(width: 64, height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(passing) of \(needed) checks passing")
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NativeAIRReadinessText.summary(model.progress, scanning: model.scanning, failed: model.error != nil))
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).help(subtitle)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        var lines: [String] = []
        if let progress = model.progress {
            lines.append("\(progress.passing) / \(progress.passing + progress.remaining) checks passed")
        }
        if let report = model.report, !report.scannedAt.isEmpty {
            lines.append("Checked \(NativeAIRReadinessText.checkedAt(report.scannedAt))")
        }
        if let skipped = model.progress?.skipped, skipped > 0 {
            lines.append("\(skipped) not needed for \(projectName)")
        }
        return lines.isEmpty ? "Project files and tools" : lines.joined(separator: " · ")
    }

    private var projectName: String {
        if let name = suppliedProjectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let path = suppliedProject ?? model.projectPath ?? ""
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var summaryActions: some View {
        HStack(spacing: 8) {
            Button { Task { await model.recheck() } } label: {
                Label(model.scanning ? "Checking…" : "Check again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered).disabled(model.working)
            Button { onFixAllWithHoot?() } label: {
                Label("Fix all with Hoot", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .disabled(onFixAllWithHoot == nil || model.working || (model.progress?.remaining ?? 0) == 0)
            .help(onFixAllWithHoot == nil ? "Open the project page to ask Hoot to finish these checks" : "Review the remaining checks with Hoot")
        }.controlSize(.regular).font(.system(size: 13))
    }

    private var reportMenu: some View {
        Menu {
            Picker("Report on", selection: $model.agent) {
                Text("Any agent").tag(String?.none)
                ForEach(model.report?.agents ?? []) { agent in DeckRowLabel.provider(agent.label, id: agent.agent).tag(Optional(agent.agent)) }
            }.disabled(model.working)
        } label: { Image(systemName: "gearshape").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).help("Readiness settings").accessibilityLabel("Readiness settings")
    }

    private var checkSections: some View {
        let unfinished = model.checks.filter { $0.status == .fail || $0.status == .warn || AIRReadinessActions.isUnverified($0) }
        let passing = model.checks.filter { $0.status == .pass }
        return VStack(alignment: .leading, spacing: 28) {
            if !unfinished.isEmpty { section("To finish", checks: unfinished, expandFirst: true) }
            if !passing.isEmpty { section("Done", checks: passing, expandFirst: false) }
            if unfinished.isEmpty && passing.isEmpty {
                NativePageNote("No checks need work. Check again after changing the project files.")
            }
        }
    }

    private func section(_ title: String, checks: [ReadinessCheck], expandFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(checks.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            PROJPAGEReadinessCard {
                VStack(spacing: 0) {
                    ForEach(checks) { check in
                        NativeAIRReadinessCheckRow(check: check, plan: model.plan(for: check),
                            initiallyExpanded: expandFirst && check.id == checks.first?.id,
                            busy: model.busyCheck == check.id, operation: model.operation,
                            disabled: model.working, result: model.results[check.id],
                            fix: { Task { await model.preview(check) } }, ask: { model.askAI(check) },
                            open: { model.open(check) }, review: onReviewChanges)
                        if check.id != checks.last?.id { Divider().padding(.horizontal, 12) }
                    }
                }
            }
        }
    }
}

private struct NativeAIRReadinessCheckRow: View {
    let check: ReadinessCheck
    let plan: AIRReadinessActionPlan
    @State private var expanded: Bool
    let busy: Bool
    let operation: String?
    let disabled: Bool
    let result: ReadinessFixResult?
    let fix: () -> Void
    let ask: () -> Void
    let open: () -> Void
    let review: (() -> Void)?

    init(check: ReadinessCheck, plan: AIRReadinessActionPlan, initiallyExpanded: Bool,
         busy: Bool, operation: String?, disabled: Bool, result: ReadinessFixResult?,
         fix: @escaping () -> Void, ask: @escaping () -> Void, open: @escaping () -> Void,
         review: (() -> Void)?) {
        self.check = check; self.plan = plan
        _expanded = State(initialValue: initiallyExpanded)
        self.busy = busy; self.operation = operation; self.disabled = disabled; self.result = result
        self.fix = fix; self.ask = ask; self.open = open; self.review = review
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: NativeAIRReadinessText.symbol(check))
                        .foregroundStyle(check.status == .pass ? Color.green : Color.orange)
                        .frame(width: 16, height: 18)
                        .accessibilityLabel(NativeAIRReadinessText.status(check))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NativeAIRReadinessText.title(check)).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(check.status == .pass ? check.detail : plan.missingAndWhy)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).help(check.status == .pass ? check.detail : plan.missingAndWhy)
                    }
                    Spacer(minLength: check.status == .pass ? 8 : 116)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 12, height: 18)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(PROJPAGEReadinessRowStyle())
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .overlay(alignment: .topTrailing) {
                if check.status != .pass {
                    Button(action: primaryAction) {
                        Text(busy ? "Preparing…" : primary.label)
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(disabled)
                    .padding(.trailing, 40).padding(.top, 14)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(NativeAIRReadinessText.steps(plan).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(index + 1).").monospacedDigit()
                            Text(step).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                    if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(operation ?? "Working…")
                        }.foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                    }
                    if let result {
                        Label(result.message, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .font(.system(size: 12)).padding(.leading, 44).padding(.trailing, 16).padding(.bottom, 14)
            }
        }
        .contextMenu {
            if check.status != .pass {
                if plan.automaticFixAvailable { Button("Fix it", action: fix).disabled(disabled) }
                Button("Ask an AI to do it", action: ask).disabled(disabled)
                if isCode, let review { Button("Review changes", action: review) }
            }
            if check.opens != nil { Button("Open file", action: open) }
        }
    }

    private var isCode: Bool { check.id == "git-clean" || check.id == "git-repo" }
    private var primary: NativeAIRReadinessText.Primary {
        NativeAIRReadinessText.primary(isCode: isCode, canReview: review != nil, automaticFix: plan.automaticFixAvailable)
    }
    private func primaryAction() {
        switch primary {
        case .review: review?()
        case .fix: fix()
        case .ask: ask()
        }
    }
}

/// Replace this wrapper with DeckCard when SHELL-CORE publishes its READY API.
private struct PROJPAGEReadinessCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color(red: 42/255, green: 42/255, blue: 46/255) : .white,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08), lineWidth: 1) }
    }
}

/// Replace this style with DeckRowStyle when SHELL-CORE publishes its READY API.
private struct PROJPAGEReadinessRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PROJPAGEReadinessRowBody(configuration: configuration)
    }
}

private struct PROJPAGEReadinessRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    var body: some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.07)
                        : hovered ? Color.primary.opacity(0.035) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }
}

private struct NativeAIRReadinessSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("To finish").font(.system(size: 15, weight: .semibold)); Spacer(); Text("2") }
            PROJPAGEReadinessCard {
                VStack(spacing: 0) {
                    ForEach(0..<4) { _ in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Project instructions").font(.system(size: 13, weight: .semibold))
                                Text("Checking project files and tools.").font(.system(size: 12))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(.horizontal, 16).padding(.vertical, 14)
                        .redacted(reason: .placeholder)
                    }
                }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Loading project checks")
    }
}

enum NativeAIRReadinessText {
    /// A failing row's one button (#159): its words and what it does come from this one choice.
    enum Primary: Equatable {
        case review, fix, ask
        var label: String {
            switch self {
            case .review: "Review changes"
            case .fix: "Fix it"
            case .ask: "Ask an AI…"
            }
        }
    }
    static func primary(isCode: Bool, canReview: Bool, automaticFix: Bool) -> Primary {
        if isCode && canReview { return .review }
        return automaticFix ? .fix : .ask
    }

    static func title(_ check: ReadinessCheck) -> String {
        switch check.id {
        case "readme": return "README for people"
        case "git-clean": return "Changes are easy to review"
        case "agents", "agents-described", "agents-folder": return "Agents are described"
        case "test-script": return "Tests run with one command"
        case "claude-md": return "Rules for AI"
        case "secrets": return "Secrets kept out of git"
        default: return check.title.isEmpty ? check.id : check.title
        }
    }

    static func steps(_ plan: AIRReadinessActionPlan) -> [String] {
        guard plan.steps.count > 3 else { return plan.steps }
        return Array(plan.steps.prefix(2)) + [plan.steps.dropFirst(2).joined(separator: " ")]
    }

    static func summary(_ progress: AIRReadinessProgress?, scanning: Bool, failed: Bool) -> String {
        if scanning { return "Checking project files and tools…" }
        if failed { return "Readiness needs another check" }
        guard let progress else { return "Checking project files and tools…" }
        if progress.ready { return "An AI has what it needs to work well here" }
        if progress.passing + progress.remaining == 0 { return "Readiness is still unverified" }
        return "\(progress.remaining) \(progress.remaining == 1 ? "thing" : "things") before an AI can work well here"
    }

    static func status(_ check: ReadinessCheck) -> String {
        if AIRReadinessActions.isUnverified(check) { return "Could not check" }
        switch check.status {
        case .pass: return "Done"
        case .warn, .fail: return "Needs work"
        case .skip: return "Not needed"
        }
    }

    static func symbol(_ check: ReadinessCheck) -> String {
        if AIRReadinessActions.isUnverified(check) { return "questionmark.circle" }
        switch check.status {
        case .pass: return "checkmark.circle"
        case .warn, .fail: return "exclamationmark.triangle"
        case .skip: return "minus.circle"
        }
    }

    static func checkedAt(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return value }
        return date.formatted(.relative(presentation: .numeric))
    }
}
