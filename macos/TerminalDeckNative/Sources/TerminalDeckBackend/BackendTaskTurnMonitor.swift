import Foundation
import CryptoKit
import TerminalDeckNativeCore

public struct BackendTaskAnswer: Sendable {
    public let text: String, at: Double
    public init(text: String, at: Double) { self.text = text; self.at = at }
}
public struct BackendTaskTranscriptTarget: Sendable {
    public let path: String, scope: NativeTranscriptScope
    public init(path: String, scope: NativeTranscriptScope) { self.path = path; self.scope = scope }
}
/// Reuses Core's real bounded parser. Attribution must supply the exact
/// account-owned transcript; a cwd's newest unrelated conversation is not used.
public struct BackendTaskTranscriptAnswers: Sendable {
    private let locate: @Sendable (BackendSessionMeta) async throws -> BackendTaskTranscriptTarget?
    public init(locate: @escaping @Sendable (BackendSessionMeta) async throws -> BackendTaskTranscriptTarget?) { self.locate = locate }
    public func latest(_ session: BackendSessionMeta) async throws -> BackendTaskAnswer? {
        guard let target = try await locate(session) else { return nil }; try Task.checkCancellation()
        guard session.provider == "claude" else { throw BackendSessionFailure.missingCapability("this provider's actual native transcript answer parser; the Claude reader cannot read its records") }
        let path = try NativeTranscriptPaths.assertTranscript(target.path, scope: target.scope), roots = try NativeTranscriptPaths.approvedRoots(target.scope)
        let bytes = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var limits = NativeChatTranscriptLimits(); limits.chunkBytes = 1024 * 1024; limits.maximumFileBytes = 4 * 1024 * 1024; limits.maximumResidentTextBytes = 4 * 1024 * 1024
        let reader = NativeChatTranscriptReader(path: path, sessionID: session.agentSessionId, startAt: max(0, Int64(bytes) - 4 * 1024 * 1024), allowedRoots: roots, limits: limits)
        for _ in 0..<5 { try Task.checkCancellation(); let result = try await reader.readChunk(); if result.complete { break } }
        guard let answer = await reader.conversation.last(where: { $0.role == .agent }) else { return nil }
        return BackendTaskAnswer(text: answer.text, at: answer.at)
    }
}

/// Task-only notify-detect state machine: observed working→calm, settled
/// 1.5s; definitive hooks, questions, 3 transcript-lag retries, fresh-answer
/// slack and stable turn hashes. No idle poll and no startup-banner completion.
public actor BackendTaskTurnMonitor {
    private enum Phase: Sendable { case quiet, turn, asked, settling }
    private struct Track: Sendable { var phase = Phase.quiet; var startedAt: Double?; var sent = false; var settle: BackendTaskTimer? }
    private let store: BackendTaskStore, engine: BackendTaskEngine, manager: BackendPTYManager
    private let answer: @Sendable (BackendSessionMeta) async throws -> BackendTaskAnswer?
    private let problem: @Sendable (String) async -> Void
    private var tracks: [String: Track] = [:], reads: [UUID: Task<Void, Never>] = [:], stopped = true, epoch = 0
    public init(store: BackendTaskStore, engine: BackendTaskEngine, manager: BackendPTYManager,
                answer: @escaping @Sendable (BackendSessionMeta) async throws -> BackendTaskAnswer?, problem: @escaping @Sendable (String) async -> Void) {
        self.store = store; self.engine = engine; self.manager = manager; self.answer = answer; self.problem = problem
    }
    public func start() { stopped = false; epoch += 1 }
    public func noteSend(sessionID: String) {
        guard !stopped else { return }; var track = tracks[sessionID] ?? Track(); track.sent = true; tracks[sessionID] = track
    }
    public func noteStatus(sessionID id: String, status: BackendSessionStatus) async throws {
        guard !stopped, let task = try await store.bySession(id), task.assigneeKind != "hoot" else { return }
        try await engine.noteStatus(sessionID: id, status: status)
        var track = tracks[id] ?? Track()
        switch status {
        case .working: track.settle?.cancel(); track.settle = nil; if track.phase == .quiet { track.startedAt = BackendTaskValues.time() }; track.phase = .turn
        case .input:
            track.settle?.cancel(); track.settle = nil; if track.phase == .quiet { track.startedAt = BackendTaskValues.time() }; if track.phase != .asked { track.phase = .asked; try await engine.noteNeedsInput(sessionID: id, screen: manager.screen(id) ?? "") }
        case .completed:
            if track.phase != .quiet { tracks[id] = track; finish(id, definitive: true); return }
        case .idle, .waiting:
            if track.phase == .turn || track.phase == .asked { track.phase = .settling; track.settle?.cancel(); track.settle = BackendTaskTimers.schedule(milliseconds: 1_500) { [weak self] in await self?.settled(id) } }
        default: break
        }; tracks[id] = track
    }
    public func noteExit(sessionID id: String, exitCode: Int) async throws { tracks.removeValue(forKey: id)?.settle?.cancel(); try await engine.noteExit(sessionID: id, exitCode: exitCode) }
    public func stop() async {
        stopped = true; epoch += 1; tracks.values.forEach { $0.settle?.cancel() }; tracks.removeAll()
        let jobs = Array(reads.values); jobs.forEach { $0.cancel() }; reads.removeAll(); for job in jobs { await job.value }
    }
    private func settled(_ id: String) { guard !stopped, tracks[id]?.phase == .settling else { return }; finish(id, definitive: false) }
    private func finish(_ id: String, definitive: Bool) {
        guard !stopped, let facts = tracks[id] else { return }; facts.settle?.cancel(); tracks[id] = Track()
        let jobID = UUID(), revision = epoch
        reads[jobID] = Task { [weak self, manager, answer] in
            do {
                guard let meta = manager.list().first(where: { $0.id == id }) else { await self?.completedRead(jobID); return }
                let fresh: @Sendable (BackendTaskAnswer?) -> Bool = { row in guard let row else { return false }; return facts.startedAt == nil || row.at >= facts.startedAt! - 2_000 }
                var latest = try await answer(meta)
                if facts.sent || definitive { for _ in 0..<3 { if fresh(latest) { break }; try await BackendTaskClockContext.sleep(milliseconds: 1_000); latest = try await answer(meta) } }
                try Task.checkCancellation()
                let text: String, turn: String
                if fresh(latest), let latest { text = String(latest.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)); turn = "answer:\(Int(latest.at)):\(Self.digest(latest.text))" }
                else {
                    guard facts.sent || !["claude", "codex"].contains(meta.provider) else { await self?.completedRead(jobID); return }
                    text = String((manager.screen(id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(1_500)); turn = "screen:\(id):\(Self.digest(text))"
                }
                await self?.deliver(id, revision: revision, turn: turn, text: text)
            } catch is CancellationError {} catch { await self?.report(error) }
            await self?.completedRead(jobID)
        }
    }
    private func deliver(_ id: String, revision: Int, turn: String, text: String) async {
        guard !stopped, revision == epoch else { return }
        do { try await engine.noteFinishedTurn(sessionID: id, turnID: turn, answer: text) } catch { await problem(error.localizedDescription) }
    }
    private func report(_ error: any Error) async { await problem("The task's turn changed, but its answer could not be read: " + error.localizedDescription) }
    private func completedRead(_ id: UUID) { reads[id] = nil }
    private static func digest(_ text: String) -> String { String(Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "").prefix(22)) }
}
