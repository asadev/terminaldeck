import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The app and the isolated preview show this same page. Grey native controls,
/// the shared empty/scope pieces, and compact rows match the other project pages.
struct NativeSFXPage: View {
    @Bindable var model: NativeSFXModel
    var sourceControl: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    @State private var showCoverage = false
    @State private var showGuards = false
    @State private var confirmDifferences = false
    @State private var showFix = false
    @State private var fixPrompt = ""
    @State private var copiedPrompt = false

    var body: some View {
        Group {
            if let error = model.loadError, model.status == nil {
                NativePageEmpty(symbol: "checkmark.shield", title: "Stays Fixed could not be read",
                                action: PageEmptyAction(label: "Try again", perform: { Task { await model.load() } })) {
                    Text(error + " Try again. If it keeps failing, reopen this project.")
                }
            } else if let status = model.status, !status.available {
                NativePageEmpty(symbol: "checkmark.shield", title: "Stays Fixed is unavailable",
                                action: PageEmptyAction(label: "Try again", perform: { Task { await model.load() } })) {
                    Text((status.unavailable ?? "The bundled checker could not be found.") + " Reopen Terminal Deck and try again.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        NativePageScope(path: model.projectPath)
                        heading
                        if let status = model.status {
                            if let label = pendingLabel {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(label).font(.callout).foregroundStyle(.secondary) }
                            }
                            if let problem = model.problem { NativeSFXNotice(problem, error: true, next: "Follow the step below, then try again.") }
                            if let notice = model.notice { NativeSFXNotice(notice) }
                            if let error = model.loadError { NativeSFXNotice("The latest status could not be read. " + error, error: true, next: "Try Refresh.") }
                            if !status.setUp { setup(status) }
                            else if let report = model.fullReport { fullReport(report) }
                            else { checks(status) }
                        } else {
                            NativeSFXSkeleton(label: "Reading this project…")
                        }
                    }
                    .frame(maxWidth: 880, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .tint(.secondary)
        .confirmationDialog("Accept these differences as the new good build?", isPresented: $confirmDifferences, titleVisibility: .visible) {
            Button("Accept differences and mark as good", role: .destructive) { Task { await model.markGood(anyway: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Future checks will compare against this build. Only continue if you have reviewed every difference and want to keep it.")
        }
        .sheet(isPresented: $showFix) { fixSheet }
        .onChange(of: model.projectPath) { _, _ in
            showFix = false; confirmDifferences = false; showCoverage = false; showGuards = false; fixPrompt = ""; copiedPrompt = false
        }
    }

    private var pendingLabel: String? {
        switch model.busy {
        case .mark: return "Saving this build as good…"
        case .agents: return "Saving AI access…"
        case .report: return "Reading the full report…"
        case .fix: return "Opening an AI session…"
        case .setup where model.status?.setUp == true: return "Finishing setup…"
        case .preview where model.status?.setUp == true: return "Reviewing saved setup…"
        default: return nil
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stays Fixed").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Check that your next change keeps the things that already worked.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.status?.setUp == true {
                Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.busy != nil)
                    .accessibilityIdentifier("sfx.refresh")
            }
        }
    }

    @ViewBuilder private func setup(_ status: StaysFixedStatus) -> some View {
        NativeSFXSteps(current: model.setupStep, titles: ["Choose checks", "Review setup", "First check"])
        if !status.git {
            NativeSFXNotice("This project needs source control before a check can run.", next: "Open Source control and create a Git repository. Then come back and refresh the preview.")
            Button("Open Source control", action: sourceControl).accessibilityIdentifier("sfx.source-control")
        }
        if model.busy == .preview || model.busy == .prepare || model.preview == nil {
            NativeSFXSkeleton(label: model.busy == .prepare ? "Preparing the bundled checker…" : "Finding sensible checks for this project…")
            if model.busy == nil {
                Button("Try preview again") { Task { await model.loadPreview() } }
            }
        } else if let preview = model.preview {
            if preview.prepareNeeded {
                NativeSFXSection(title: "Prepare the checker") {
                    Text("Stays Fixed needs a one-time download on this Mac (about 60 MB).")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Your project stays unchanged until you review and save setup.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Prepare Stays Fixed") { Task { await model.loadPreview(prepare: true) } }
                        .disabled(model.busy != nil).accessibilityIdentifier("sfx.prepare")
                }
            } else if model.setupStep == 1 {
                chooseChecks(preview)
            } else {
                reviewSetup(preview)
            }
        }
        if !status.versionNote.isEmpty, model.preview?.prepareNeeded != true {
            Text(status.versionNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseChecks(_ preview: SFXSetupPreview) -> some View {
        NativeSFXSection(title: "1. Choose what to check") {
            Text(preview.summary.isEmpty ? "Stays Fixed looks at this project and chooses checks it can run here." : preview.summary)
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if !preview.products.isEmpty {
                ForEach(preview.products) { product in
                    NativeSFXRow(symbol: "folder", title: product.name, detail: product.evidence.joined(separator: " · "))
                }
            }
            coverage(ready: preview.ready, gaps: preview.gaps, notHere: preview.notHere, showFixes: false)
            if preview.commandNeeded || preview.checkCommand != nil || !model.commandDraft.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Command to check").font(.callout.weight(.medium))
                    Text("Choose a local test or help command for this project. Use a command that needs no live account or production data.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("For example: swift run MyApp --help", text: $model.commandDraft)
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                        .accessibilityIdentifier("sfx.check-command")
                        .disabled(model.busy != nil)
                    if !preview.commandExplanation.isEmpty {
                        Text(preview.commandExplanation).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Preview this command") { Task { await model.loadPreview() } }
                        .disabled(model.busy != nil || model.commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("sfx.preview-command")
                    if model.commandNeedsPreview { Text("Preview this command before continuing.").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 10) {
                Button("Continue") { model.setupStep = 2 }
                    .disabled(!model.canApplyPreview || model.status?.git != true)
                    .accessibilityIdentifier("sfx.continue")
                Button("Refresh preview") { Task { await model.loadPreview() } }.disabled(model.busy != nil)
            }
        }
    }

    private func reviewSetup(_ preview: SFXSetupPreview) -> some View {
        NativeSFXSection(title: "2. Review setup") {
            Text("Stays Fixed will save these settings in this project. Detected checks use the recommended defaults.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(preview.files) { file in
                NativeSFXRow(symbol: "doc.text", title: file.path, detail: file.summary.isEmpty ? file.action : file.summary)
            }
            if let command = preview.checkCommand {
                NativeSFXRow(symbol: "terminal", title: "Command that checks this project", detail: command)
                Text(preview.commandExplanation).font(.caption).foregroundStyle(.secondary)
            }
            if !preview.configText.isEmpty {
                DisclosureGroup("View generated settings") {
                    Text(preview.configText).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }
            NativeSFXRow(symbol: "person.2", title: "Available to your AI sessions", detail: "New sessions in this project can check their own work. You can turn this off later.")
            HStack(spacing: 10) {
                Button(model.busy == .setup ? "Saving setup…" : "Set up this project") { Task { await model.applySetup() } }
                    .disabled(!model.canApplyPreview || model.status?.git != true)
                    .accessibilityIdentifier("sfx.apply-setup")
                Button("Back") { model.setupStep = 1 }.disabled(model.busy != nil)
                if model.busy == .setup { ProgressView().controlSize(.small) }
            }
        }
    }

    @ViewBuilder private func checks(_ status: StaysFixedStatus) -> some View {
        if model.readingSetupCompletion { NativeSFXSkeleton(label: "Checking that saved setup finished…") }
        if model.partialSetup {
            NativeSFXSection(title: "Finish setup before the first check") {
                NativeSFXNotice("The reviewed settings were saved, but setup did not finish.", next: "Finish setup to add the missing check-evidence ignore lines. Your existing settings will be kept.")
                if let preview = model.preview {
                    ForEach(preview.files) { file in NativeSFXRow(symbol: "doc.text", title: file.path, detail: file.summary) }
                }
                HStack(spacing: 10) {
                    Button(model.busy == .setup ? "Finishing setup…" : "Finish setup") { Task { await model.applySetup() } }
                        .disabled(!model.canFinishSetup).accessibilityIdentifier("sfx.finish-setup")
                    Button("Refresh setup review") { Task { await model.loadPreview() } }.disabled(model.busy != nil)
                }
            }
        }
        if status.reference == nil {
            NativeSFXSteps(current: 3, titles: ["Choose checks", "Review setup", "First check"])
        }
        NativeSFXSection(title: outcomeTitle(status)) {
            if model.checking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.running?.step ?? "Starting the check…").font(.callout)
                        if let running = status.running {
                            Text("\(StaysFixedRules.startedBy(running)) · \(StaysFixedRules.elapsed(model.now - running.startedAt))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer()
                    Button(model.stopping ? "Stopping…" : "Stop") { Task { await model.stop() } }
                        .disabled(model.stopping).accessibilityIdentifier("sfx.stop")
                }
                NativeSFXSkeleton(label: "Your result will appear here.", showSpinner: false)
            } else {
                Text(outcomeDetail(status)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if status.last != nil {
                    Text(StaysFixedRules.subline(status, now: model.now)).font(.caption).foregroundStyle(.secondary)
                }
                if !status.git {
                    NativeSFXNotice("This folder has no Git repository, so the check cannot run.", next: "Open Source control and create one, then re-check.")
                    Button("Open Source control", action: sourceControl)
                }
                HStack(spacing: 10) {
                    Button(checkLabel(status)) { Task { await model.runCheck() } }
                        .disabled(!model.canCheck).accessibilityIdentifier("sfx.run-check")
                    if status.last != nil && status.last?.verdict != .couldNotRun && !StaysFixedRules.markedSinceLastCheck(status) {
                        Button(model.busy == .mark ? "Saving good build…" : "Mark this build as good") {
                            if status.last?.verdict == .differences && !StaysFixedRules.markedSinceLastCheck(status) { confirmDifferences = true }
                            else { Task { await model.markGood() } }
                        }
                        .disabled(!model.canMark).accessibilityIdentifier("sfx.mark-good")
                    }
                    if status.last != nil {
                        Button("Full report") { Task { await model.readReport() } }
                            .disabled(model.busy != nil).accessibilityIdentifier("sfx.full-report")
                    }
                }
                if let last = status.last {
                    result(last, all: false)
                    if (last.verdict == .differences || last.verdict == .couldNotRun) && !StaysFixedRules.markedSinceLastCheck(status) {
                        HStack(spacing: 10) {
                            Button("Ask an AI to fix it") { openFix(model.fixPrompt()) }
                                .disabled(model.busy != nil).accessibilityIdentifier("sfx.ask-fix")
                            Text("After the fix, choose Re-check.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if model.mark?.refusedFor == .unchecked {
            NativeSFXNotice("Run a check before saving the first good build.", next: "Choose Run first check above.")
        }
        if model.mark?.refusedFor == .differences {
            Button("Review and accept differences") { confirmDifferences = true }.disabled(!model.canMark)
        }
        NativeSFXSection(title: "AI sessions") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Let AI sessions use Stays Fixed").font(.callout.weight(.medium))
                    Text("New \(StaysFixedRules.agentNames()) sessions in this project can check their work.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Let AI sessions use Stays Fixed", isOn: Binding(get: { status.agents }, set: { on in Task { await model.setAgents(on) } }))
                    .toggleStyle(.switch).labelsHidden().disabled(model.busy != nil || model.checking)
                    .accessibilityIdentifier("sfx.agents")
            }
        }
        DisclosureGroup("Rules that keep fixed bugs from returning", isExpanded: $showGuards) {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = status.guardProblem { NativeSFXNotice(problem, error: true, next: "Ask an AI to repair this rule, then re-check.") }
                if status.guards.isEmpty { Text("No saved rules yet. Ask an AI to add a small check for a bug you already fixed.").font(.callout).foregroundStyle(.secondary) }
                ForEach(status.guards, id: \.name) { item in NativeSFXRow(symbol: "checkmark.shield", title: item.name, detail: item.because) }
                Button("Ask an AI to add a rule") {
                    openFix("In this project, ask me which previously fixed bug should stay fixed. Add one small Stays Fixed guard for that bug using the project's current configuration, without changing unrelated files or the good reference. Run a check and report what it covers.")
                }.disabled(model.busy != nil || model.checking)
            }.padding(.top, 8)
        }
        DisclosureGroup("What this Mac can check", isExpanded: $showCoverage) {
            VStack(alignment: .leading, spacing: 10) {
                if model.readingReadiness { NativeSFXSkeleton(label: "Reading check coverage…") }
                else if let readiness = model.readiness {
                    coverage(ready: readiness.ready, gaps: readiness.gaps, notHere: readiness.notHere, showFixes: true)
                }
                if let error = model.readinessError { NativeSFXNotice(error, error: true, next: "Try Refresh coverage. If the checker still needs preparation, reopen this project.") }
                Button("Refresh coverage") { Task { await model.readReadiness(refresh: true) } }
                    .disabled(model.readingReadiness || model.busy != nil || model.checking)
            }.padding(.top, 8)
        }
        .onChange(of: showCoverage) { _, open in if open && model.readiness == nil { Task { await model.readReadiness() } } }
    }

    private func outcomeTitle(_ status: StaysFixedStatus) -> String {
        if model.checking { return "Checking this project" }
        guard let last = status.last else { return "3. Run your first check" }
        if StaysFixedRules.markedSinceLastCheck(status) { return "Good build saved" }
        switch last.verdict {
        case .clean: return status.reference == nil ? "First check passed" : "Still good"
        case .notCompared: return "First check complete — review it"
        case .differences: return "Something changed — review and fix it"
        case .couldNotRun: return "The check could not finish"
        }
    }

    private func outcomeDetail(_ status: StaysFixedStatus) -> String {
        guard let last = status.last else {
            return "Run the checks for this project. Review the result, then mark this build as good. Later checks compare your changes with that saved build."
        }
        if StaysFixedRules.markedSinceLastCheck(status) { return "Future checks will compare against this build. Run a check after your next change." }
        switch last.verdict {
        case .notCompared: return "Nothing is saved as good yet. Review what was checked below. If this build works as you expect, mark it as good."
        case .clean where status.reference == nil: return "The checks passed. Review the coverage below, then mark this build as good to save your starting point."
        case .differences: return "Compare the before and now values below. Restore the behavior you want to keep, then re-check. Accept differences only if you intended them."
        case .couldNotRun: return "Read the reason below, complete the missing step, then re-check. Your good build has not changed."
        default: return last.headline
        }
    }

    private func checkLabel(_ status: StaysFixedStatus) -> String {
        if status.last == nil { return "Run first check" }
        if StaysFixedRules.markedSinceLastCheck(status) { return "Run check" }
        if status.last?.verdict == .differences || status.last?.verdict == .couldNotRun { return "Re-check after fix" }
        return "Run check"
    }

    @ViewBuilder private func coverage(ready: [String], gaps: [FixedGap], notHere: [String], showFixes: Bool) -> some View {
        if !ready.isEmpty { NativeSFXRow(symbol: "checkmark", title: "Can check here", detail: StaysFixedRules.listWords(ready)) }
        else { NativeSFXNotice("No useful check was found automatically.", next: "Choose a local command below so the first check has something real to compare.") }
        ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
            VStack(alignment: .leading, spacing: 5) {
                NativeSFXRow(symbol: "exclamationmark.circle", title: gap.what.isEmpty ? gap.name : gap.what, detail: gap.why)
                if !gap.fix.isEmpty { Text("Next: " + gap.fix).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !gap.unlocks.isEmpty { Text("This enables " + gap.unlocks).font(.caption).foregroundStyle(.secondary) }
                if showFixes { Button("Ask an AI to help") { openFix(model.fixPrompt(gap: gap)) }.disabled(model.busy != nil || model.checking) }
            }
        }
        if !notHere.isEmpty { Text("Not checked here: " + StaysFixedRules.listWords(notHere) + ".").font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func result(_ result: FixedResults, all: Bool) -> some View {
        if !result.checked.isEmpty { NativeSFXRow(symbol: "checklist", title: "Checked", detail: result.checked) }
        ForEach(result.differences) { difference in
            NativeSFXDifference(difference: difference, result: result, all: all) {
                openFix(model.fixPrompt(for: difference))
            }.disabled(model.busy != nil)
        }
        if !result.unchanged.isEmpty { Text(result.unchanged).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        if let notChecked = result.notChecked, !notChecked.isEmpty { NativeSFXNotice(notChecked, next: "Review the coverage before treating this build as good.") }
        ForEach(Array(result.gaps.enumerated()), id: \.offset) { _, gap in
            NativeSFXNotice(gap.what + ". " + gap.why, next: gap.unlockedBy.isEmpty ? "Ask an AI to help with this missing check, then re-check." : gap.unlockedBy)
        }
        if result.verdict == .couldNotRun, !result.detail.isEmpty {
            Text(result.detail).font(.callout.monospaced()).textSelection(.enabled)
        }
    }

    private func fullReport(_ report: FixedResults) -> some View {
        NativeSFXSection(title: "Full report") {
            Button("Back to checks") { model.closeReport() }
            Text(report.headline).font(.callout.weight(.medium)).textSelection(.enabled)
            result(report, all: true)
            if !report.detail.isEmpty {
                Text(report.detail).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func openFix(_ prompt: String) { fixPrompt = prompt; copiedPrompt = false; showFix = true }

    private var fixSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask an AI to help").font(.title3.weight(.semibold))
            Text("Review this request. It will be copied, and a new AI session will open in this project using your normal agent and login. Paste and send the request there. Come back to re-check after the fix.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $fixPrompt).font(.callout.monospaced())
                .frame(minHeight: 220).padding(6)
                .background(.quaternary, in: .rect(cornerRadius: 6))
                .accessibilityIdentifier("sfx.fix-prompt")
            HStack {
                Button(copiedPrompt ? "Copied" : "Copy prompt") { copy(fixPrompt); copiedPrompt = true }
                Spacer()
                Button("Cancel") { showFix = false }.keyboardShortcut(.cancelAction)
                Button("Copy request and open AI session") {
                    let prompt = fixPrompt
                    showFix = false
                    Task { await model.startFix(prompt: prompt) }
                }
                .disabled(model.busy != nil || fixPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("sfx.start-fix")
            }
        }
        .padding(24).frame(width: 620, height: 420)
        .onChange(of: fixPrompt) { _, _ in copiedPrompt = false }
    }
}

private struct NativeSFXSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeSFXRow: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeSFXNotice: View {
    let text: String
    var error = false
    var next: String? = nil
    init(_ text: String, error: Bool = false, next: String? = nil) { self.text = text; self.error = error; self.next = next }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error ? "exclamationmark.circle" : "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).foregroundStyle(error ? Color.red : Color.primary)
                if let next, !next.isEmpty { Text(next).foregroundStyle(.secondary) }
            }.font(.callout).textSelection(.enabled)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct NativeSFXSteps: View {
    let current: Int
    let titles: [String]
    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    Image(systemName: index + 1 < current ? "checkmark.circle" : "\(index + 1).circle")
                    Text(title)
                }
                .font(.callout.weight(index + 1 == current ? .semibold : .regular))
                .foregroundStyle(index + 1 == current ? Color.primary : Color.secondary)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current) of \(titles.count): \(titles[max(0, min(current - 1, titles.count - 1))])")
    }
}

private struct NativeSFXSkeleton: View {
    let label: String
    var showSpinner = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if showSpinner { ProgressView().controlSize(.small) }
                Text(label).font(.callout).foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 240, height: 14)
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(maxWidth: 540).frame(height: 10)
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(maxWidth: 430).frame(height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

private struct NativeSFXDifference: View {
    let difference: FixedDifference
    let result: FixedResults
    let all: Bool
    let fix: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(difference.title).font(.callout.weight(.semibold)).textSelection(.enabled)
            if difference.needsPerson { NativeSFXNotice(difference.needsPersonWhy, next: "Decide whether this change is intended before accepting it.") }
            ForEach(Array(difference.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 5) {
                    Text(change.what).font(.callout.weight(.medium)).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        GridRow { Text("Before").foregroundStyle(.secondary); Text(change.before ?? "Not present") }
                        GridRow { Text("Now").foregroundStyle(.secondary); Text(change.after ?? "Not present") }
                    }.font(.callout).textSelection(.enabled)
                }
            }
            ForEach(Array(StaysFixedRules.pictures(result, difference.id).enumerated()), id: \.offset) { _, picture in
                HStack(alignment: .top, spacing: 12) {
                    pictureView(picture.before, label: "Before")
                    pictureView(picture.after, label: "Now")
                }
            }
            if !all, difference.more > 0 { Text("\(difference.more) more changes are in the full report.").font(.caption).foregroundStyle(.secondary) }
            Button("Ask an AI to fix this", action: fix)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
    @ViewBuilder private func pictureView(_ url: String?, label: String) -> some View {
        if let data = StaysFixedRules.pictureData(url), let image = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
            }.frame(maxWidth: .infinity)
        }
    }
}
