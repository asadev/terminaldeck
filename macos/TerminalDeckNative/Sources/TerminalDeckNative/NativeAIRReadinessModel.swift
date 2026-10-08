import Foundation
import Observation
import TerminalDeckNativeCore

/// The screen and its review harness use the same calls. Session startup keeps
/// the existing provider resolver and session creation path.
@MainActor
struct NativeAIRReadinessDependencies {
    var invoke: @MainActor (String, [Any?]) async throws -> Any
    var launchSession: @MainActor (NewSessionRequest) async throws -> String
    var observe: @MainActor (String, @escaping ([Any]) -> Void) -> (() -> Void) = { _, _ in {} }

    static var live: Self {
        Self(invoke: { channel, arguments in
            try await EngineBridge.shared.invoke(channel, arguments)
        }, launchSession: { request in
            // The ordinary native session:create input does not carry a first
            // prompt. AIR's adapter reuses that creator and the existing observed
            // brief delivery before returning a successful session.
            let answer = try await EngineBridge.shared.invoke("readiness:startAI", [request.json])
            guard let raw = answer as? [String: Any], let id = raw["id"] as? String, !id.isEmpty else {
                throw NativeAIRReadinessError("The AI session did not start. Try again or open a session from the project.")
            }
            AppModel.shared.selectTab(id)
            guard raw["promptDelivered"] as? Bool == true else {
                throw NativeAIRReadinessError(raw["message"] as? String
                    ?? "The AI session opened, but its ready prompt could not be delivered. Open the session and send the directions shown here.")
            }
            return id
        }, observe: { channel, receive in
            let subscription = EngineBridge.shared.on(channel, receive)
            return { subscription.cancel() }
        })
    }
}

struct NativeAIRReadinessError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct NativeAIRPendingPreview: Identifiable {
    let preview: AIRReadinessFixPreview
    var id: String { preview.id }
}

@MainActor
@Observable
final class NativeAIRReadinessModel {
    private(set) var projectPath: String?
    private(set) var report: ReadinessReport?
    private(set) var scanning = false
    private(set) var busyCheck: String?
    private(set) var operation: String?
    private(set) var error: String?
    private(set) var results: [String: ReadinessFixResult] = [:]
    private(set) var lastResult: ReadinessFixResult?
    private(set) var aiSessions: Set<String> = []
    var agent: String?
    var pendingPreview: NativeAIRPendingPreview?
    var aiSession: NativeAIRSessionModel?

    @ObservationIgnored private let dependencies: NativeAIRReadinessDependencies
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scanTicket = 0
    @ObservationIgnored private var subscriptions: [() -> Void] = []
    @ObservationIgnored private var hasAppeared = false

    init(report: ReadinessReport? = nil, dependencies: NativeAIRReadinessDependencies = .live) {
        self.report = report
        projectPath = report?.projectPath
        self.dependencies = dependencies
    }

    var view: ReadinessView? { report.map { ReadinessRules.view(of: $0, agent: agent) } }
    var checks: [ReadinessCheck] { ReadinessRules.sorted(view?.checks ?? []) }
    var progress: AIRReadinessProgress? { report.map { AIRReadinessProgress(report: $0, agent: agent) } }
    var working: Bool { scanning || busyCheck != nil }

    func plan(for check: ReadinessCheck) -> AIRReadinessActionPlan {
        AIRReadinessActions.plan(for: check, projectPath: projectPath ?? "", agent: agent)
    }

    func show(_ path: String?) {
        guard path != projectPath || report == nil && !scanning else { return }
        generation += 1
        scanTicket += 1
        projectPath = path
        report = nil
        error = nil
        results = [:]
        lastResult = nil
        scanning = false
        busyCheck = nil
        operation = nil
        pendingPreview = nil
        aiSession = nil
        aiSessions = []
        agent = nil
        if path != nil { Task { await recheck() } }
    }

    /// A different report target invalidates a preview that belonged to the
    /// previous agent, including a preview still arriving from the backend.
    func changedAgent() {
        generation += 1
        busyCheck = nil
        operation = nil
        results = [:]
        lastResult = nil
        pendingPreview = nil
        aiSession = nil
    }

    func appeared() {
        // Session and readiness events share the app's single event stream.
        // Returning from the AI also rechecks: an agent may stay alive after it
        // finishes its changes, so session exit alone is not a completion signal.
        if subscriptions.isEmpty {
            for channel in ["session:exit", "session:removed"] {
                subscriptions.append(dependencies.observe(channel) { [weak self] arguments in
                    guard let self else { return }
                    let raw = arguments.first as? [String: Any]
                    let id = (arguments.first as? String) ?? (raw?["id"] as? String)
                    guard let id, self.aiSessions.contains(id), !self.working else { return }
                    Task { await self.recheck() }
                })
            }
        }
        if hasAppeared, report != nil, !working { Task { await recheck() } }
        hasAppeared = true
    }

    func disappeared() {
        subscriptions.forEach { $0() }
        subscriptions = []
    }

    func recheck() async {
        guard let path = projectPath, !scanning else { return }
        scanTicket += 1
        let ticket = scanTicket
        scanning = true
        error = nil
        defer { if ticket == scanTicket { scanning = false } }
        do {
            let answer = try await dependencies.invoke("readiness:recheck", [path])
            guard ticket == scanTicket else { return }
            guard let next = ReadinessReport(json: answer) else {
                throw NativeAIRReadinessError("The check returned no report. Re-check the project to try again.")
            }
            guard Self.sameProject(next.projectPath, path) else {
                throw NativeAIRReadinessError("The check returned a report for a different project. Re-check this project to try again.")
            }
            report = next
        } catch {
            guard ticket == scanTicket else { return }
            self.error = Self.sentence(error)
        }
    }

    func preview(_ check: ReadinessCheck) async {
        guard let path = projectPath, !working, plan(for: check).automaticFixAvailable else { return }
        let mine = generation
        busyCheck = check.id
        operation = "Preparing the changes…"
        results[check.id] = nil
        lastResult = nil
        defer { if mine == generation { busyCheck = nil; operation = nil } }
        do {
            let answer = try await dependencies.invoke("readiness:previewFix", [path, check.id, agent])
            guard mine == generation else { return }
            guard let preview = AIRReadinessFixPreview(json: answer) else {
                throw NativeAIRReadinessError("The fix returned no preview. Re-check the project and try again.")
            }
            guard Self.sameProject(preview.projectPath, path), preview.checkID == check.id,
                  preview.agent == agent, preview.fixID == check.fix?.id else {
                throw NativeAIRReadinessError("The preview did not match this check and project. Re-check before trying again.")
            }
            pendingPreview = NativeAIRPendingPreview(preview: preview)
        } catch {
            guard mine == generation else { return }
            results[check.id] = ReadinessFixResult(ok: false, message: Self.sentence(error))
            lastResult = results[check.id]
        }
    }

    /// This is called only by the preview's explicit confirm button. The backend
    /// still asks through the app's approval path and rejects stale previews.
    func confirm(_ preview: AIRReadinessFixPreview) async {
        guard !working, pendingPreview?.id == preview.id, let path = projectPath,
              Self.sameProject(preview.projectPath, path), preview.agent == agent else { return }
        let mine = generation
        busyCheck = preview.checkID
        operation = "Waiting for approval and applying the fix…"
        defer { if mine == generation { busyCheck = nil; operation = nil } }
        do {
            let answer = try await dependencies.invoke("readiness:fixApproved", [preview.id])
            guard mine == generation else { return }
            guard let outcome = AIRReadinessFixOutcome(json: answer) else {
                throw NativeAIRReadinessError("The fix did not return an outcome. Re-check before trying again.")
            }
            guard Self.sameProject(outcome.report.projectPath, path) else {
                throw NativeAIRReadinessError("The fix returned a report for a different project. Re-check this project before trying again.")
            }
            results[preview.checkID] = outcome.result
            lastResult = outcome.result
            report = outcome.report
            pendingPreview = nil
            // fixApproved returns the backend's fresh recheck. Use it directly
            // so a successful fix does not run the same scan twice.
        } catch {
            guard mine == generation else { return }
            results[preview.checkID] = ReadinessFixResult(ok: false, message: Self.sentence(error))
            lastResult = results[preview.checkID]
            pendingPreview = nil
            // Approval may be refused, or files may have changed after preview.
            // Refresh the offered steps before another attempt.
            await recheck()
        }
    }

    func askAI(_ check: ReadinessCheck) {
        guard let path = projectPath, !working else { return }
        let mine = generation
        aiSession = NativeAIRSessionModel(projectPath: path, check: check, plan: plan(for: check),
            preferredAgent: agent, dependencies: dependencies) { [weak self] id in
                guard let self, mine == self.generation else { return }
                self.aiSessions.insert(id)
                self.results[check.id] = ReadinessFixResult(ok: true,
                    message: "AI session opened. Come back here to re-check its changes.")
                self.lastResult = self.results[check.id]
                self.aiSession = nil
            }
    }

    func open(_ check: ReadinessCheck) {
        guard let path = projectPath, let relative = check.opens else { return }
        let url = ReadinessRules.fileURL(projectPath: path, relPath: relative)
        let mine = generation
        Task {
            do { _ = try await dependencies.invoke("link:system", [url]) }
            catch { if mine == generation { self.error = Self.sentence(error) } }
        }
    }

    static func sentence(_ error: Error) -> String {
        if let wire = error as? EngineWireError { return wire.description }
        if let rpc = error as? NativeRPCError { return rpc.message }
        return error.localizedDescription
    }

    private static func sameProject(_ answer: String, _ requested: String) -> Bool {
        guard !answer.isEmpty, !requested.isEmpty else { return false }
        return answer == requested
    }
}
