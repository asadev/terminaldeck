import Foundation
import TerminalDeckNativeCore

/// Session and transcript owners supply these reads; no folder-wide answer is guessed here.
public protocol BackendDeckCoreEventsDetectionSurface: Sendable {
    func notificationSessions() async throws -> [NativeRPCValue]
    func notificationScreen(sessionId: String) async throws -> String?
    /// Source latestAnswerOn: the newest answer matched to this session, with {at,text,truncated}.
    func notificationAnswer(session: NativeRPCValue) async throws -> NativeRPCValue?
}

public actor BackendDeckCoreEventsDetector {
    public static let settleMilliseconds: Double = 1_500
    public static let maximumAnswer = 2_000
    public static let maximumScreen = 1_500
    public static let answerLagRetries = 3
    public static let answerLagMilliseconds: Double = 1_000
    public static let answerSlackMilliseconds: Double = 2_000
    private enum Phase { case quiet, turn, asked, settling }
    private struct Track { var phase: Phase = .quiet; var trigger: String?; var settle: UUID?; var startedAt: Double? }
    private struct Facts: Sendable { let trigger: String?; let startedAt: Double?; let expectAnswer: Bool }
    private let surface: any BackendDeckCoreEventsDetectionSurface
    private let starterOf: @Sendable (String) async -> String?
    private let enqueue: @Sendable (String, NativeRPCValue, String?) async -> Bool
    private let clock: any BackendDeckCoreEventsClock
    private let report: @Sendable (String) -> Void
    private var tracks: [String: Track] = [:]
    private var pendingBuilds: [UUID: Task<Void,Never>] = [:]
    /// Settle-timer hops onto this actor, recorded as they start, for awaitIdle().
    private let settles = BackendDeckCoreEventsWork()
    public init(surface: any BackendDeckCoreEventsDetectionSurface, starterOf: @escaping @Sendable (String) async -> String?,
                enqueue: @escaping @Sendable (String, NativeRPCValue, String?) async -> Bool,
                clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock(), report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.surface = surface; self.starterOf = starterOf; self.enqueue = enqueue; self.clock = clock; self.report = report
    }
    public func noteRow(_ row: NativeRPCValue) {
        guard row["outcome"].string == "ok", ["sessions.send","sessions.keys"].contains(row["tool"].string ?? ""), let session = row["sessionId"].string else { return }
        let caller = row["caller"], trigger = caller["kind"].string == "key" && caller["keyId"].string != nil ? "key:" + caller["keyId"].string! : "copilot"
        var track = tracks[session] ?? Track(); track.trigger = trigger; tracks[session] = track
    }
    public func noteStatus(sessionId: String, status: String) {
        var track = tracks[sessionId] ?? Track()
        switch status {
        case "working":
            cancelSettle(&track); if track.phase == .quiet { track.startedAt = clock.now() }; track.phase = .turn
        case "input":
            cancelSettle(&track); if track.phase == .quiet { track.startedAt = clock.now() }
            if track.phase == .asked { tracks[sessionId] = track; return }
            track.phase = .asked; emit(sessionId:sessionId,type:"needs-input",trigger:track.trigger,facts:nil)
        case "completed":
            if track.phase == .quiet { return }; finish(sessionId:sessionId,track:&track,definitive:true)
        case "waiting", "idle":
            guard track.phase == .turn || track.phase == .asked else { return }
            track.phase = .settling; cancelSettle(&track)
            track.settle = clock.schedule(after:Self.settleMilliseconds) { [settles] in settles.start { await self.settled(sessionId) } }
        default: break
        }
        tracks[sessionId] = track
    }
    public func noteExit(sessionId: String, exitCode: Double) {
        var track = tracks.removeValue(forKey:sessionId) ?? Track(); cancelSettle(&track); let trigger = track.trigger
        let pendingID = UUID()
        pendingBuilds[pendingID] = Task {
            defer { self.pendingBuilds[pendingID] = nil }
            let starter = await starterOf(sessionId), key = keyId(starter) ?? keyId(trigger)
            guard let key, let built = await build(sessionId:sessionId,type:"exited",facts:nil,exitCode:exitCode) else { return }
            _ = await enqueue(key,built.0,built.1)
        }
    }
    public func stop() { for var track in tracks.values { cancelSettle(&track) }; tracks.removeAll() }
    /// Deterministic completion seam for callers/tests that must know a negative
    /// detection result has settled. It awaits a settle timer that has fired and
    /// the real build tasks, never polls. (A build parked on its answer-lag pause
    /// finishes only once the clock passes that pause.)
    public func awaitIdle() async {
        while true {
            await settles.awaitIdle()
            if pendingBuilds.isEmpty { return }
            let tasks = Array(pendingBuilds.values)
            for task in tasks { await task.value }
        }
    }
    private func keyId(_ who: String?) -> String? { guard let who, who.hasPrefix("key:") else { return nil }; return String(who.dropFirst(4)) }
    private func settled(_ session: String) {
        guard var track = tracks[session], track.phase == .settling else { return }
        track.settle = nil; finish(sessionId:session,track:&track,definitive:false); tracks[session] = track
    }
    private func finish(sessionId: String, track: inout Track, definitive: Bool) {
        cancelSettle(&track); let facts = Facts(trigger:track.trigger,startedAt:track.startedAt,expectAnswer:track.trigger != nil || definitive)
        track.phase = .quiet; track.trigger = nil; track.startedAt = nil
        emit(sessionId:sessionId,type:"finished",trigger:facts.trigger,facts:facts)
    }
    private func cancelSettle(_ track: inout Track) { if let settle = track.settle { clock.cancel(settle) }; track.settle = nil }
    private func emit(sessionId: String, type: String, trigger: String?, facts: Facts?) {
        let pendingID = UUID()
        pendingBuilds[pendingID] = Task {
            defer { self.pendingBuilds[pendingID] = nil }
            let who: String?; if let trigger { who = trigger } else { who = await starterOf(sessionId) }
            guard let key = keyId(who), let built = await build(sessionId:sessionId,type:type,facts:facts,exitCode:nil) else { return }
            _ = await enqueue(key,built.0,built.1)
        }
    }
    private func build(sessionId: String, type: String, facts: Facts?, exitCode: Double?) async -> (NativeRPCValue, String?)? {
        var base = BackendDeckCoreEventsSupport.object([("id",.string(UUID().uuidString.lowercased())),("type",.string(type)),("sessionId",.string(sessionId)),("sessionName",.string(sessionId)),("at",.number(clock.now()))])
        do {
            let meta = try await surface.notificationSessions().first { $0["id"].string == sessionId }
            base = base.setting("sessionName",.string(meta?["title"].string ?? sessionId))
            if type == "exited" {
                let code = exitCode ?? meta?["exitCode"].number ?? 0
                return (base.setting("exitCode",.number(code)).setting("crashed",.bool(code != 0)).setting("suggestedTool",.string("sessions_result")).setting("note",.string(code == 0 ? "The session ended on its own. sessions_result reports what it did." : "The session stopped with exit code \(String(format:"%.0f",code)). sessions_result reports what it did before it stopped.")),nil)
            }
            if type == "needs-input" {
                let screen = try await surface.notificationScreen(sessionId:sessionId) ?? ""
                return (base.setting("screen",BackendDeckCoreEventsSupport.cap(screen,max:Self.maximumScreen,fromEnd:true)).setting("suggestedTool",.string("sessions_keys")).setting("note",.string("The session stopped to ask something — a permission prompt, a menu or a question. The screen shows it. Answer with sessions_keys (for example [\"1\"] or [\"enter\"]) or type a reply with sessions_send.")),nil)
            }
            func fresh(_ answer: NativeRPCValue?) -> Bool {
                guard let answer, let at = answer["at"].number else { return false }
                return facts?.startedAt == nil || at >= facts!.startedAt! - Self.answerSlackMilliseconds
            }
            var answer: NativeRPCValue?
            if let meta { answer = try await surface.notificationAnswer(session:meta) }
            if let meta, facts?.expectAnswer == true {
                for _ in 0..<Self.answerLagRetries where !fresh(answer) {
                    await pause(Self.answerLagMilliseconds); answer = try await surface.notificationAnswer(session:meta)
                }
            }
            if fresh(answer), let answer, let text = answer["text"].string, let at = answer["at"].number {
                let turn = "answer:\(String(format:"%.0f",at)):\(BackendDeckCoreEventsSupport.digest(text,length:22))"
                return (base.setting("answer",BackendDeckCoreEventsSupport.cap(text,max:Self.maximumAnswer)).setting("suggestedTool",.string("sessions_send")).setting("note",.string("The session finished its turn. answer is the newest thing it said; sessions_transcript has the rest.")),turn)
            }
            if let meta, facts?.trigger == nil, meta["provider"].isNullish || meta["provider"].string == "claude" { return nil }
            let text = try await surface.notificationScreen(sessionId:sessionId) ?? "", screen = BackendDeckCoreEventsSupport.cap(text,max:Self.maximumScreen,fromEnd:true)
            return (base.setting("screen",screen).setting("suggestedTool",.string("sessions_screen")).setting("note",.string("The session finished its turn. It keeps no transcript, so screen shows its last lines.")),"screen:\(sessionId):\(BackendDeckCoreEventsSupport.digest(screen["text"].string ?? "",length:22))")
        } catch {
            report("[notify] could not build a notification: \(error.localizedDescription)")
            return (base.setting("suggestedTool",.string("sessions_get")).setting("note",.string("Something changed in this session; sessions_get shows its state.")),nil)
        }
    }
    private func pause(_ milliseconds: Double) async {
        await withCheckedContinuation { continuation in _ = clock.schedule(after:milliseconds) { continuation.resume() } }
    }
}
