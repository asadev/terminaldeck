import Foundation
import Observation
import TerminalDeckNativeCore

/// State for the guided page. The app supplies its existing engine bridge; the
/// isolated review harness supplies the same channels without touching app data.
@MainActor
@Observable
final class NativeSFXModel {
    enum Busy: Equatable { case preview, prepare, setup, check, mark, agents, report, fix }
    typealias Invoke = @MainActor (String, [Any?]) async throws -> Any
    typealias Subscribe = @MainActor (@escaping @MainActor (String) -> Void) -> (() -> Void)
    typealias AskAI = @MainActor (String, String) async throws -> String

    private(set) var projectPath: String?
    private(set) var status: StaysFixedStatus?
    private(set) var preview: SFXSetupPreview?
    private(set) var busy: Busy?
    private(set) var loading = false
    private(set) var stopping = false
    private(set) var loadError: String?
    private(set) var problem: String?
    private(set) var notice: String?
    private(set) var mark: FixedMarkOutcome?
    private(set) var fullReport: FixedResults?
    private(set) var readiness: FixedReadiness?
    private(set) var readinessError: String?
    private(set) var readingReadiness = false
    private(set) var readingSetupCompletion = false
    private(set) var partialSetup = false
    private(set) var retrySetupToken: String?
    private(set) var now = Date().timeIntervalSince1970 * 1000
    var setupStep = 1
    var commandDraft = ""

    @ObservationIgnored private let invoke: Invoke
    @ObservationIgnored private let subscribe: Subscribe
    @ObservationIgnored private let askAI: AskAI
    @ObservationIgnored private let describeError: (any Error) -> String
    @ObservationIgnored private var cancelSubscription: (() -> Void)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var loadingGeneration: UInt64?
    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var previewCommand = ""
    @ObservationIgnored private var recoveryReadPerformed = false

    init(invoke: @escaping Invoke, subscribe: @escaping Subscribe = { _ in {} },
         askAI: @escaping AskAI = { _, _ in
             throw NSError(domain: "Stays Fixed", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "An AI session is unavailable here. Copy the fix prompt into a session in this project."])
         }, describeError: @escaping (any Error) -> String = { $0.localizedDescription }) {
        self.invoke = invoke; self.subscribe = subscribe; self.askAI = askAI; self.describeError = describeError
    }

    var checking: Bool { busy == .check || status?.running != nil }
    var canCheck: Bool { status?.available == true && status?.setUp == true && status?.git == true && busy == nil && !checking && !partialSetup && !readingSetupCompletion }
    var canMark: Bool {
        canCheck && status?.last != nil && status?.last?.verdict != .couldNotRun
    }
    var canApplyPreview: Bool {
        busy == nil && preview?.canApply == true && preview?.token != nil
            && previewCommand == commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var commandNeedsPreview: Bool { previewCommand != commandDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canFinishSetup: Bool { partialSetup && retrySetupToken != nil && busy == nil && !checking }

    /// Returning to the same project still rejoins its changed-event stream.
    func show(_ path: String?) {
        guard !active || path != projectPath else { return }
        cancelSubscription?(); cancelSubscription = nil
        ticker?.cancel(); ticker = nil
        generation &+= 1; active = true; projectPath = path
        status = nil; preview = nil; busy = nil; loading = false; stopping = false
        problem = nil; notice = nil; mark = nil; fullReport = nil; loadError = nil
        readiness = nil; readinessError = nil; readingReadiness = false
        partialSetup = false; retrySetupToken = nil; recoveryReadPerformed = false; readingSetupCompletion = false
        setupStep = 1; commandDraft = ""; previewCommand = ""; loadingGeneration = nil
        guard path != nil else { return }
        cancelSubscription = subscribe { [weak self] changedPath in
            guard let self, self.active, changedPath == self.projectPath else { return }
            Task { await self.load() }
        }
        Task { await load() }
    }

    func leave() {
        active = false; generation &+= 1
        cancelSubscription?(); cancelSubscription = nil
        ticker?.cancel(); ticker = nil
        loadingGeneration = nil; loading = false; busy = nil; stopping = false; readingSetupCompletion = false
    }

    private func current(_ token: UInt64, _ path: String) -> Bool {
        active && token == generation && path == projectPath
    }

    /// Changes that arrive during a read are coalesced into one follow-up read.
    func load() async {
        guard active, let path = projectPath else { return }
        let token = generation
        if loadingGeneration == token { reloadRequested = true; return }
        loadingGeneration = token; loading = true
        defer {
            if loadingGeneration == token { loadingGeneration = nil; loading = false }
        }
        do {
            repeat {
                reloadRequested = false
                let raw = try await invoke(StaysFixedWire.status, [path])
                guard current(token, path) else { return }
                status = StaysFixedWire.status(raw, projectPath: path); loadError = nil
            } while reloadRequested
        } catch {
            guard current(token, path) else { return }
            loadError = describeError(error)
        }
        updateTicker()
        if status?.available == true, status?.setUp == false, preview == nil, busy == nil {
            await loadPreview()
        } else if status?.available == true, status?.setUp == true, !recoveryReadPerformed {
            await readSetupRecovery()
        }
    }

    private func updateTicker() {
        guard active, checking else { ticker?.cancel(); ticker = nil; return }
        guard ticker == nil else { return }
        now = Date().timeIntervalSince1970 * 1000
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.active else { return }
                self.now = Date().timeIntervalSince1970 * 1000
            }
        }
    }

    private func start(_ operation: Busy) -> (String, UInt64)? {
        guard active, let path = projectPath, busy == nil else { return nil }
        busy = operation; problem = nil; notice = nil
        return (path, generation)
    }

    private func setupArguments(_ path: String) -> [Any?] {
        let command = commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return [path, command.isEmpty ? nil : ["checkCommand": command]]
    }

    func loadPreview(prepare: Bool = false) async {
        guard let (path, token) = start(prepare ? .prepare : .preview) else { return }
        let command = commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let raw = try await invoke(prepare ? SFXSetupWire.prepare : SFXSetupWire.preview, setupArguments(path))
            guard current(token, path) else { return }
            let answer = SFXSetupWire.preview(raw)
            preview = answer
            partialSetup = answer.partialSetup; retrySetupToken = answer.retryToken
            let effectiveCommand = answer.checkCommand ?? command
            // A suggested default must be visible. Never overwrite text the
            // person entered while this preview was being read.
            if command.isEmpty && commandDraft.trimmingCharacters(in: .whitespacesAndNewlines) == command {
                commandDraft = effectiveCommand
            }
            previewCommand = effectiveCommand
            if let problem = preview?.problem { self.problem = problem }
        } catch {
            guard current(token, path) else { return }
            problem = describeError(error)
        }
        guard current(token, path) else { return }
        busy = nil
    }

    func applySetup() async {
        guard canApplyPreview || canFinishSetup,
              let previewToken = partialSetup ? retrySetupToken : preview?.token,
              let (path, token) = start(.setup) else { return }
        do {
            let answer = SFXSetupWire.apply(try await invoke(SFXSetupWire.apply, [path, previewToken]))
            guard current(token, path) else { return }
            partialSetup = answer.partialSetup; retrySetupToken = answer.retryToken
            if answer.ok {
                notice = "Setup saved. Run your first check, then choose whether this build is good."
                setupStep = 3
            } else { problem = answer.problem ?? "Setup did not finish. Preview the project again and try once more." }
        } catch {
            guard current(token, path) else { return }
            problem = describeError(error)
        }
        guard current(token, path) else { return }
        busy = nil; recoveryReadPerformed = false; await load()
    }

    /// Config existence alone does not prove setup finished. The backend can
    /// issue a fresh, sealed Finish setup receipt after a screen or app restart.
    private func readSetupRecovery() async {
        guard active, let path = projectPath else { return }
        let token = generation; recoveryReadPerformed = true; readingSetupCompletion = true
        defer { if current(token, path) { readingSetupCompletion = false } }
        do {
            let answer = SFXSetupWire.preview(try await invoke(SFXSetupWire.preview, [path]))
            guard current(token, path) else { return }
            if answer.partialSetup {
                preview = answer; partialSetup = true; retrySetupToken = answer.retryToken
                if let problem = answer.problem { self.problem = problem }
            } else { partialSetup = false; retrySetupToken = nil }
        } catch {
            guard current(token, path) else { return }
            // Existing working checks remain usable; a failed read is visible
            // and Refresh will retry this recovery check.
            problem = "Setup completion could not be read. " + describeError(error) + " Try Refresh."
            recoveryReadPerformed = false
        }
    }

    func runCheck() async {
        guard canCheck, let (path, token) = start(.check) else { return }
        mark = nil; fullReport = nil; updateTicker()
        Task { await load() }
        do {
            let answer = StaysFixedWire.check(try await invoke(StaysFixedWire.check, [path]))
            guard current(token, path) else { return }
            if let message = answer.message { problem = message }
            if let result = answer.results { status?.last = result }
        } catch {
            guard current(token, path) else { return }
            problem = describeError(error)
        }
        guard current(token, path) else { return }
        busy = nil; await load(); updateTicker()
    }

    func stop() async {
        guard active, checking, !stopping, let path = projectPath else { return }
        let token = generation; stopping = true; problem = nil
        do {
            let result = try await invoke(StaysFixedWire.stop, [path])
            guard current(token, path) else { return }
            if (result as? Bool) == false { notice = "The check had already finished. The latest result is shown below." }
            else { notice = "Stopping the check. You can start another once it has stopped." }
        } catch {
            guard current(token, path) else { return }
            problem = "The check could not be stopped. " + describeError(error) + " Try Stop again."
        }
        guard current(token, path) else { return }
        stopping = false; await load()
    }

    /// A caller only passes anyway after the page's explicit confirmation.
    func markGood(anyway: Bool = false) async {
        guard canMark, let (path, token) = start(.mark) else { return }
        do {
            let answer = StaysFixedWire.mark(try await invoke(StaysFixedWire.markGood, [path, anyway]))
            guard current(token, path) else { return }
            mark = answer
            if answer.marked || answer.already { notice = answer.summary }
            else { problem = answer.refused ?? answer.summary }
        } catch {
            guard current(token, path) else { return }
            problem = "The good build could not be saved. " + describeError(error) + " Run a check and try again."
        }
        guard current(token, path) else { return }
        busy = nil; await load()
    }

    func setAgents(_ on: Bool) async {
        guard !checking, let (path, token) = start(.agents) else { return }
        do {
            let raw = try await invoke(StaysFixedWire.agents, [path, on])
            guard current(token, path) else { return }
            status = StaysFixedWire.status(raw, projectPath: path)
            notice = on ? "New AI sessions in this project can use Stays Fixed." : "Stays Fixed is turned off for new AI sessions in this project."
        } catch {
            guard current(token, path) else { return }
            problem = "The AI setting did not save. " + describeError(error) + " Try the switch again."
        }
        guard current(token, path) else { return }
        busy = nil
    }

    func readReport() async {
        guard let (path, token) = start(.report) else { return }
        do {
            let result = StaysFixedWire.results(try await invoke(StaysFixedWire.results, [path, true]))
            guard current(token, path) else { return }
            if let result { fullReport = result }
            else { problem = "The full report is not available yet. Run a check and try again." }
        } catch {
            guard current(token, path) else { return }
            problem = "The report could not be read. " + describeError(error) + " Try Full report again."
        }
        guard current(token, path) else { return }
        busy = nil
    }

    func closeReport() { fullReport = nil }

    func readReadiness(refresh: Bool = false) async {
        guard active, !readingReadiness, let path = projectPath else { return }
        let token = generation; readingReadiness = true; readinessError = nil
        do {
            let answer = StaysFixedWire.readiness(try await invoke(StaysFixedWire.readiness, [path, refresh]))
            guard current(token, path) else { return }
            readiness = answer.readiness; readinessError = answer.message
        } catch {
            guard current(token, path) else { return }
            readinessError = describeError(error)
        }
        guard current(token, path) else { return }
        readingReadiness = false
    }

    func startFix(prompt: String) async {
        guard !checking, let (path, token) = start(.fix) else { return }
        do {
            let session = try await askAI(path, prompt)
            guard current(token, path) else { return }
            notice = "Opened \(session). Your fix request is copied. Paste and send it there, then come back and re-check."
        } catch {
            guard current(token, path) else { return }
            problem = "The AI session could not start. " + describeError(error) + " You can copy the prompt into an existing session."
        }
        guard current(token, path) else { return }
        busy = nil
    }

    func fixPrompt(for difference: FixedDifference? = nil, gap: FixedGap? = nil) -> String {
        var lines = ["In this project, fix the Stays Fixed failure below with the smallest appropriate change.",
                     "Keep the current good reference. Do not mark differences as good, weaken checks, or change unrelated files."]
        if let gap {
            lines += ["Missing: \(gap.what)", "Why: \(gap.why)", "Steps: \(gap.fix)"]
        } else if let last = status?.last {
            lines += ["Check result: \(last.headline)"]
            for item in difference.map({ [$0] }) ?? last.differences {
                lines.append("Failure: \(item.title)")
                if item.needsPerson { lines.append("Ask me before deciding: \(item.needsPersonWhy)") }
                for change in item.changes {
                    lines.append("\(change.what): before \(change.before ?? "not present"); now \(change.after ?? "not present")")
                }
            }
            for missing in last.gaps { lines += ["Missing: \(missing.what)", "Next: \(missing.unlockedBy)"] }
            if !last.detail.isEmpty { lines.append("Details: \(last.detail)") }
        }
        lines.append("Run Stays Fixed again after the fix. Report what passed, what remains unchecked, and any remaining failure.")
        return lines.joined(separator: "\n\n")
    }
}
