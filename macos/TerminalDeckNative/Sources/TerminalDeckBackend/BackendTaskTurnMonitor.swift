import Foundation
import CryptoKit
import TerminalDeckNativeCore

public struct BackendTaskAnswer: Sendable {
    public let text: String, at: Double
    public init(text: String, at: Double) { self.text = text; self.at = at }
}
public struct BackendTaskTranscriptTarget: Sendable {
    /// Claude: the transcript scope. Codex/Gemini: the account-owned roots the record must sit under.
    public let path: String, scope: NativeTranscriptScope?, roots: [String]
    public init(path: String, scope: NativeTranscriptScope) { self.path = path; self.scope = scope; roots = [] }
    public init(path: String, roots: [String]) { self.path = path; scope = nil; self.roots = roots }
}
/// Reuses Core's real bounded parser. Attribution must supply the exact
/// account-owned transcript; a cwd's newest unrelated conversation is not used.
public struct BackendTaskTranscriptAnswers: Sendable {
    private let locate: @Sendable (BackendSessionMeta) async throws -> BackendTaskTranscriptTarget?
    public init(locate: @escaping @Sendable (BackendSessionMeta) async throws -> BackendTaskTranscriptTarget?) { self.locate = locate }
    public func latest(_ session: BackendSessionMeta) async throws -> BackendTaskAnswer? {
        guard let target = try await locate(session) else { return nil }; try Task.checkCancellation()
        // HOOTFIX: every agent a task can be given to has its own record reader.
        switch session.provider {
        case "codex": return try BackendTaskAgentTranscripts.codexAnswer(target)
        case "gemini": return try BackendTaskAgentTranscripts.geminiAnswer(target)
        case "claude": break
        default: return nil
        }
        guard let scope = target.scope else { throw BackendSessionFailure.invalidInput("A Claude transcript needs its transcript scope.") }
        let path = try NativeTranscriptPaths.assertTranscript(target.path, scope: scope), roots = try NativeTranscriptPaths.approvedRoots(scope)
        let bytes = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var limits = NativeChatTranscriptLimits(); limits.chunkBytes = 1024 * 1024; limits.maximumFileBytes = 4 * 1024 * 1024; limits.maximumResidentTextBytes = 4 * 1024 * 1024
        let reader = NativeChatTranscriptReader(path: path, sessionID: session.agentSessionId, startAt: max(0, Int64(bytes) - 4 * 1024 * 1024), allowedRoots: roots, limits: limits)
        for _ in 0..<5 { try Task.checkCancellation(); let result = try await reader.readChunk(); if result.complete { break } }
        guard let answer = await reader.conversation.last(where: { $0.role == .agent }) else { return nil }
        return BackendTaskAnswer(text: answer.text, at: answer.at)
    }
}

/// Task-only notify-detect state machine: observed working→calm, settled
/// 1.5s; definitive hooks, questions, accepted-event usage, fresh-answer
/// slack and stable turn hashes. No idle poll and no startup-banner completion.
public actor BackendTaskTurnMonitor {
    private enum Phase: Sendable { case quiet, turn, asked, settling }
    private struct Track: Sendable { var phase = Phase.quiet; var startedAt: Double?; var sent = false; var settle: BackendTaskTimer? }
    private struct Pending: Sendable {
        let token: UUID, revision: Int, generation: UInt64
        var facts: Track
        var taskID: String?, assignee: NativeRPCValue?, runID: String?, excluded = Set<String>(), reading = false, dirty = false
        var deadline: BackendTaskTimer?
    }
    private var pending: [String: Pending] = [:], generations: [String: UInt64] = [:], deliveredTurns: [String: Set<String>] = [:]
    private let store: BackendTaskStore, engine: BackendTaskEngine, manager: BackendPTYManager
    private let answer: @Sendable (BackendSessionMeta) async throws -> BackendTaskAnswer?
    private let tokenUsage: (@Sendable (BackendSessionMeta) async throws -> Double?)?
    private let usageEvents: (@Sendable (BackendSessionMeta, @escaping @Sendable () -> Void) async throws -> (@Sendable () -> Void)?)?
    private var usageStops: [String: @Sendable () -> Void] = [:], usageStarting: [String: UUID] = [:]
    private var usageSampling = Set<String>(), usageDirty = Set<String>()
    private let problem: @Sendable (String) async -> Void
    private var tracks: [String: Track] = [:], reads: [UUID: Task<Void, Never>] = [:], stopped = true, epoch = 0
    public init(store: BackendTaskStore, engine: BackendTaskEngine, manager: BackendPTYManager,
                answer: @escaping @Sendable (BackendSessionMeta) async throws -> BackendTaskAnswer?,
                tokenUsage: (@Sendable (BackendSessionMeta) async throws -> Double?)? = nil,
                usageEvents: (@Sendable (BackendSessionMeta, @escaping @Sendable () -> Void) async throws -> (@Sendable () -> Void)?)? = nil,
                problem: @escaping @Sendable (String) async -> Void) {
        self.store = store; self.engine = engine; self.manager = manager; self.answer = answer; self.tokenUsage = tokenUsage; self.usageEvents = usageEvents; self.problem = problem
    }
    public func start() { stopped = false; epoch += 1 }
    public func noteSend(sessionID: String) {
        guard !stopped else { return }
        if pending[sessionID]?.facts.sent == false { pending[sessionID]?.facts.sent = true }
        else { generations[sessionID, default: 0] &+= 1; clearPending(sessionID) }
        var track = tracks[sessionID] ?? Track(); track.sent = true; tracks[sessionID] = track
    }
    public func noteStatus(sessionID id: String, status: BackendSessionStatus) async throws {
        guard !stopped, let task = try await store.bySession(id), task.assigneeKind != "hoot" else { return }
        if status == .working || status == .input { generations[id, default: 0] &+= 1; clearPending(id) }
        await reportUsage(id)
        await observeUsage(id)
        try await engine.noteStatus(sessionID: id, status: status)
        var track = tracks[id] ?? Track()
        switch status {
        case .working: clearPending(id); track.settle?.cancel(); track.settle = nil; if track.phase == .quiet { track.startedAt = BackendTaskValues.time() }; track.phase = .turn
        case .input:
            clearPending(id); track.settle?.cancel(); track.settle = nil; if track.phase == .quiet { track.startedAt = BackendTaskValues.time() }; if track.phase != .asked { track.phase = .asked; try await engine.noteNeedsInput(sessionID: id, screen: manager.screen(id) ?? "") }
        case .completed:
            if track.phase != .quiet { tracks[id] = track; finish(id, definitive: true); return }
        case .idle, .waiting:
            if track.phase == .turn || track.phase == .asked { track.phase = .settling; track.settle?.cancel(); track.settle = BackendTaskTimers.schedule(milliseconds: 1_500) { [weak self] in await self?.settled(id) } }
        default: break
        }; tracks[id] = track
    }
    public func noteExit(sessionID id: String, exitCode: Int) async throws {
        clearPending(id); generations[id, default: 0] &+= 1; deliveredTurns[id] = nil
        usageStops.removeValue(forKey: id)?(); usageStarting[id] = nil; usageSampling.remove(id); usageDirty.remove(id)
        tracks.removeValue(forKey: id)?.settle?.cancel(); try await engine.noteExit(sessionID: id, exitCode: exitCode)
    }
    public func stop() async {
        stopped = true; epoch += 1; pending.values.forEach { $0.deadline?.cancel() }; pending.removeAll(); generations.removeAll(); deliveredTurns.removeAll(); tracks.values.forEach { $0.settle?.cancel() }; tracks.removeAll()
        usageStops.values.forEach { $0() }; usageStops.removeAll(); usageStarting.removeAll(); usageSampling.removeAll(); usageDirty.removeAll()
        let jobs = Array(reads.values); jobs.forEach { $0.cancel() }; reads.removeAll(); for job in jobs { await job.value }
    }
    private func settled(_ id: String) { guard !stopped, tracks[id]?.phase == .settling else { return }; finish(id, definitive: false) }
    private func finish(_ id: String, definitive: Bool) {
        guard !stopped, let facts = tracks[id] else { return }; facts.settle?.cancel(); tracks[id] = Track()
        clearPending(id)
        let token = UUID()
        pending[id] = Pending(token: token, revision: epoch, generation: generations[id] ?? 0, facts: facts)
        readPending(id, token: token)
    }
    private func clearPending(_ id: String, token: UUID? = nil) {
        guard token == nil || pending[id]?.token == token else { return }
        pending.removeValue(forKey: id)?.deadline?.cancel()
    }
    private func readPending(_ id: String, token: UUID) {
        guard !stopped, var item = pending[id], item.token == token, item.revision == epoch, item.generation == (generations[id] ?? 0) else { return }
        if item.reading { item.dirty = true; pending[id] = item; return }
        item.reading = true; pending[id] = item
        let jobID = UUID()
        reads[jobID] = Task { [weak self, store, manager, answer] in
            do {
                guard let meta = manager.list().first(where: { $0.id == id }), let task = try await store.bySession(id),
                      await self?.bindPending(id, token: token, task: task) == true else { await self?.completedRead(jobID); return }
                // One accepted completion read, then one read per transcript
                // change. A timer never rereads the provider's transcript.
                let latest = try await answer(meta)
                try Task.checkCancellation()
                await self?.answered(id, token: token, latest: latest)
            } catch is CancellationError {} catch { await self?.report(error); await self?.answered(id, token: token, latest: nil) }
            await self?.completedRead(jobID)
        }
    }
    private func bindPending(_ id: String, token: UUID, task: BackendTaskRecord) -> Bool {
        guard !stopped, var item = pending[id], item.token == token, item.revision == epoch, item.generation == (generations[id] ?? 0) else { return false }
        guard task.value["stopped"].bool != true,
              item.taskID == nil || item.taskID == task.id && item.assignee == task.value["assignee"] else { clearPending(id, token: token); return false }
        guard item.taskID == nil || item.runID == task.value["agoptRunID"].string else { clearPending(id, token: token); return false }
        item.taskID = task.id; item.assignee = task.value["assignee"]; item.runID = task.value["agoptRunID"].string
        item.excluded.formUnion(deliveredTurns[id] ?? [])
        for field in ["lastTurn", "agoptPriorTurn"] { if let prior = task.value[field].string { item.excluded.insert(prior) } }
        pending[id] = item; return true
    }
    private func answered(_ id: String, token: UUID, latest: BackendTaskAnswer?) async {
        guard !stopped, var item = pending[id], item.token == token, item.revision == epoch, item.generation == (generations[id] ?? 0) else { return }
        item.reading = false
        if let latest, (item.facts.startedAt == nil || latest.at >= item.facts.startedAt! - 2_000),
           !item.excluded.contains("answer:\(Int(latest.at)):\(Self.digest(latest.text))") {
            pending[id] = item
            await completePending(id, token: token, turn: "answer:\(Int(latest.at)):\(Self.digest(latest.text))",
                text: String(latest.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)))
            return
        }
        if item.deadline == nil {
            item.deadline = BackendTaskTimers.schedule(milliseconds: 3_000) { [weak self] in await self?.fallbackPending(id, token: token) }
        }
        let changed = item.dirty; item.dirty = false; pending[id] = item
        if changed { readPending(id, token: token) }
    }
    private func fallbackPending(_ id: String, token: UUID) async {
        guard !stopped, let item = pending[id], item.token == token, item.revision == epoch, item.generation == (generations[id] ?? 0) else { return }
        guard let meta = manager.list().first(where: { $0.id == id }), item.facts.sent || !["claude", "codex"].contains(meta.provider) else { clearPending(id, token: token); return }
        let text = String((manager.screen(id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(1_500))
        await completePending(id, token: token, turn: "screen:\(id):\(Self.digest(text))", text: text)
    }
    private func completePending(_ id: String, token: UUID, turn: String, text: String) async {
        guard !stopped, let item = pending[id], item.token == token, item.revision == epoch, item.generation == (generations[id] ?? 0) else { return }
        do {
            guard let task = try await store.bySession(id), task.id == item.taskID, task.value["assignee"] == item.assignee,
                  task.value["stopped"].bool != true, task.value["agoptRunID"].string == item.runID else { clearPending(id, token: token); return }
            guard pending[id]?.token == token, item.generation == (generations[id] ?? 0) else { return }
            clearPending(id, token: token)
            await reportUsage(id)
            // A new turn, assignment or stop during the usage read cancels the
            // accepted completion rather than finishing another task's work.
            guard !stopped, item.revision == epoch, item.generation == (generations[id] ?? 0), let current = try await store.bySession(id),
                  current.id == item.taskID, current.value["assignee"] == item.assignee, current.value["agoptRunID"].string == item.runID,
                  item.generation == (generations[id] ?? 0), tracks[id]?.phase != .turn, tracks[id]?.phase != .asked else { return }
            deliveredTurns[id, default: []].insert(turn)
            try await engine.noteFinishedTurn(sessionID: id, turnID: turn, answer: text,
                expectedTaskID: item.taskID, expectedAssignee: item.assignee, expectedRunID: item.runID)
        } catch is CancellationError {} catch { await problem(error.localizedDescription) }
    }
    private func reportUsage(_ id: String) async {
        let revision = epoch
        do {
            guard !stopped, let binding = try await store.bySession(id), let tokenUsage, let meta = manager.list().first(where: { $0.id == id }),
                  let total = try await tokenUsage(meta) else { return }
            guard !stopped, revision == epoch, let current = try await store.bySession(id), current.id == binding.id,
                  current.value["assignee"] == binding.value["assignee"], current.value["agoptRunID"] == binding.value["agoptRunID"] else { return }
            try await engine.noteTokenUsage(sessionID: id, totalTokens: total, expectedTaskID: binding.id,
                expectedAssignee: binding.value["assignee"], expectedRunID: binding.value["agoptRunID"].string)
        } catch is CancellationError {} catch { await problem("The task's token usage could not be read: " + error.localizedDescription) }
    }
    private func observeUsage(_ id: String) async {
        guard !stopped, let usageEvents, usageStops[id] == nil, usageStarting[id] == nil,
              let meta = manager.list().first(where: { $0.id == id && $0.exitCode == nil }) else { return }
        let token = UUID(), revision = epoch; usageStarting[id] = token
        defer { if usageStarting[id] == token { usageStarting[id] = nil } }
        do {
            let stop = try await usageEvents(meta) { [weak self] in Task { await self?.usageChanged(id, revision: revision) } }
            guard !stopped, revision == epoch, usageStarting[id] == token else { stop?(); return }
            usageStops[id] = stop
        } catch { await problem("The task's usage events could not be watched: " + error.localizedDescription) }
    }
    private func usageChanged(_ id: String, revision: Int) async {
        guard !stopped, epoch == revision, usageStops[id] != nil || usageStarting[id] != nil else { return }
        guard usageSampling.insert(id).inserted else { usageDirty.insert(id); return }
        await reportUsage(id)
        if let item = pending[id] { readPending(id, token: item.token) }
        usageSampling.remove(id)
        // Exactly one follow-up for an accepted change that arrived during a
        // read; this is event coalescing, with no timer or idle polling.
        if usageDirty.remove(id) != nil { Task { [weak self] in await self?.usageChanged(id, revision: revision) } }
    }
    private func report(_ error: any Error) async { await problem("The task's turn changed, but its answer could not be read: " + error.localizedDescription) }
    private func completedRead(_ id: UUID) { reads[id] = nil }
    private static func digest(_ text: String) -> String { String(Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "").prefix(22)) }
}
