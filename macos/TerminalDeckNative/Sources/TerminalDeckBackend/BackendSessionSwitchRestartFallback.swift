import Foundation
import Darwin
import TerminalDeckNativeCore

/// A live Claude session that has no account seat: it was started while switching was not ready (its session
/// host's saved-login store would not open), so nothing can hand it another login in place. Thrown by the app
/// side of the session host for a newer host's `reason: "no-seat"` answer and for an older host's refusal,
/// and caught by BackendSessionSwitchRestartFallback, which offers a restart instead. Its own words are plain.
public struct BackendSessionSwitchNoSeat: Error, LocalizedError, Sendable {
    public let sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
    public var errorDescription: String? { SwitchAccountRestartOffer.notReady }

    /// The exact refusal of a session host from before 12 Oct (BackendHOSTResources `switch.plan`). That host
    /// keeps running until its sessions end, so the app must keep understanding it.
    public static let olderHostSentence = "This session has no verified live Claude broker seat and target account."
    /// The same host's `switch.request` refusal.
    static let olderHostRequestSentence = "This session has no verified live Claude broker seat."

    public static func recognizes(_ error: Error) -> Bool {
        if error is BackendSessionSwitchNoSeat { return true }
        let text = error.localizedDescription
        return text.contains(olderHostSentence) || text.contains(olderHostRequestSentence)
    }
    /// What a host refusal says, without the transport's "The persistent host service could not complete
    /// switch.plan:" in front (a channel name nobody using the app has heard of).
    public static func plain(_ error: Error) -> String {
        var text = error.localizedDescription
        let prefix = "The persistent host service could not complete "
        if let range = text.range(of: prefix), let colon = text.range(of: ": ", range: range.upperBound..<text.endIndex) {
            text = String(text[colon.upperBound...])
        }
        if recognizes(error) { return SwitchAccountRestartOffer.notReady + " Nothing was changed." }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The account could not be switched just now. Nothing was changed." : trimmed
    }
    /// A host refusal said in plain words; any other error (cancelled, not allowed, gone) unchanged.
    public static func plainHostError(_ error: Error) -> Error {
        error.localizedDescription.contains("The persistent host service could not complete ") ? BackendSessionFailure.unsupported(plain(error)) : error
    }
}

extension BackendSessionSwitchPlan {
    /// The same restart plan, with the plain-words offer said first (Restart it on …? The conversation carries on).
    func offeringRestart() -> BackendSessionSwitchPlan {
        guard refusal == nil, mode == .restart, let to else { return self }
        var plan = self
        plan.notice = SwitchAccountRestartOffer.sentence(accountName: to.name, carriesOn: carriesConversation)
        return plan
    }
    /// The replacement continues the conversation on screen now.
    var carriesConversation: Bool { conversation == "follows" || conversation == "carried" }
}

/// The hosted app's switch for a session that cannot switch in place (12 Oct). The session host answers every
/// in-place switch; when it says the session has no seat (or, an older host, refuses in its own words), this
/// plans a restart that resumes the same conversation in the same tab, says so first in plain words
/// (`notice`), and on confirmation runs the same restart the in-app coordinator runs
/// (BackendSessionSwitchCoordinator.replace). Any other refusal comes back as plain words, never a channel name.
public actor BackendSessionSwitchRestartFallback {
    public typealias Plan = @Sendable (String, String) async throws -> BackendSessionSwitchPlan
    public typealias Perform = @Sendable (String, String, String) async throws -> BackendSessionSwitchCoordinator.Execution
    public typealias Restart = @Sendable (BackendSessionSwitchPlan, String) async throws -> BackendSessionSwitchCoordinator.Execution
    private let inPlacePlan: Plan
    private let inPlacePerform: Perform
    private let restartPlan: Plan
    private let restart: Restart
    /// 13 Oct: another AI's account (nil: the same AI), and handing the session over to it.
    private let handoverPlan: @Sendable (String, String) async throws -> BackendSessionSwitchPlan?
    private let handover: Restart
    let cancelOwned: @Sendable (String) async throws -> Void
    let stopOwned: @Sendable () async -> Void
    let pendingOwned: @Sendable (String) async -> BackendAccountIdentity?
    /// The session as it is now (process, account, conversation), so a restart plan just shown is used only while
    /// nothing changed (#202). Nil: never reused.
    private let fingerprint: @Sendable (String) -> String?
    private var busy: Set<String> = []
    private var memo = BackendSessionSwitchPlanMemo()

    public init(inPlacePlan: @escaping Plan, inPlacePerform: @escaping Perform, restartPlan: @escaping Plan, restart: @escaping Restart,
                cancel: @escaping @Sendable (String) async throws -> Void, stop: @escaping @Sendable () async -> Void,
                pending: @escaping @Sendable (String) async -> BackendAccountIdentity? = { _ in nil },
                handoverPlan: @escaping @Sendable (String, String) async throws -> BackendSessionSwitchPlan? = { _, _ in nil },
                handover: @escaping Restart = { _, _ in throw BackendSessionFailure.unsupported("This session cannot be switched to another AI here.") },
                fingerprint: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.inPlacePlan = inPlacePlan; self.inPlacePerform = inPlacePerform; self.restartPlan = restartPlan; self.restart = restart
        cancelOwned = cancel; stopOwned = stop; pendingOwned = pending; self.handoverPlan = handoverPlan; self.handover = handover
        self.fingerprint = fingerprint
    }
    public func pendingAccount(sessionID: String) async -> BackendAccountIdentity? { await pendingOwned(sessionID) }

    public func subject(sessionID: String, accountID: String) async throws -> BackendSessionSwitchPlan {
        if let other = try await handoverPlan(sessionID, accountID) { return other }
        do { return try await inPlacePlan(sessionID, accountID) }
        catch where BackendSessionSwitchNoSeat.recognizes(error) {
            let plan = try await offer(sessionID, accountID)
            memo.keep(plan, accountID: accountID, fingerprint: fingerprint(sessionID))
            return plan
        }
        catch { throw BackendSessionSwitchNoSeat.plainHostError(error) }
    }
    public func perform(sessionID: String, accountID: String, note: String) async throws -> BackendSessionSwitchCoordinator.Execution {
        if let other = try await handoverPlan(sessionID, accountID) {
            guard other.refusal == nil else { throw BackendSessionFailure.unsupported(other.refusal ?? "This session cannot be switched.") }
            guard busy.insert(sessionID).inserted else { throw BackendSessionFailure.unsupported("This session is already switching to another account. Wait a moment.") }
            defer { busy.remove(sessionID) }
            return try await handover(other, note)
        }
        do { return try await inPlacePerform(sessionID, accountID, note) }
        catch where BackendSessionSwitchNoSeat.recognizes(error) {
            guard busy.insert(sessionID).inserted else {
                throw BackendSessionFailure.unsupported("This session is already switching to another account. Wait a moment.")
            }
            defer { busy.remove(sessionID) }
            // The restart the person was just offered, while the session is as it was planned (#202).
            let plan: BackendSessionSwitchPlan
            if let shown = memo.take(sessionID: sessionID, accountID: accountID, fingerprint: fingerprint(sessionID)) { plan = shown }
            else { plan = try await offer(sessionID, accountID) }
            guard plan.refusal == nil else { throw BackendSessionFailure.unsupported(plan.refusal ?? SwitchAccountRestartOffer.notReady) }
            return try await restart(plan, note)
        }
        catch { throw BackendSessionSwitchNoSeat.plainHostError(error) }
    }
    public func cancel(sessionID: String) async throws { try await cancelOwned(sessionID) }
    public func stop() async { await stopOwned() }

    private func offer(_ sessionID: String, _ accountID: String) async throws -> BackendSessionSwitchPlan {
        try await restartPlan(sessionID, accountID).offeringRestart()
    }

    /// The restart half over the app's own session parts: the same refusals, plan and restart the in-app
    /// coordinator uses. The app cannot read the host's saved logins, so whether the target is signed in is
    /// found out by starting it: a signed-out account is refused before the old session is touched.
    public static func restartParts(manager: BackendPTYManager, lifecycle: BackendSessionLifecycleCoordinator, store: NativeStateStore,
                                    planner: BackendSessionRestorePlanner, sharedHistory: BackendSessionSwitchSharedHistory?,
                                    find: @escaping @Sendable (String) async throws -> BackendAccountProfile?,
                                    apiCredentialAvailable: @escaping @Sendable (BackendAPIAccountRecord) -> Bool = { BackendAPIAccountKeychain.contains($0) },
                                    configuration: BackendAccountConfiguration? = nil,
                                    emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void)
        -> (plan: Plan, restart: Restart, handoverPlan: @Sendable (String, String) async throws -> BackendSessionSwitchPlan?, handover: Restart) {
        let plan: Plan = { sessionID, accountID in
            let meta = manager.list().first { $0.id == sessionID }
            let raw = try await store.ledgerGet(sessionID)
            let saved = raw.isNullish ? nil : try BackendSessionSaved(raw)
            let target = try await find(accountID)
            func refused(_ sentence: String) -> BackendSessionSwitchPlan {
                BackendSessionSwitchPlan(sessionID: sessionID, refusal: sentence, from: BackendSessionSwitchCoordinator.account(of: meta), to: target,
                                         conversation: "stays", resume: false, conversationID: nil, mode: .restart, saved: saved, carried: nil)
            }
            if let sentence = BackendSessionSwitchCoordinator.refusal(meta: meta, saved: saved, target: target) { return refused(sentence) }
            guard let live = meta, let target, let saved else { return refused("This session cannot be switched.") }
            // 18 Oct (#448): the same "belongs to another copy of the app" refusal the in-app switch makes.
            if let why = BackendSessionSwitchCoordinator.apiTargetRefusal(target, configuration: configuration, credentialAvailable: apiCredentialAvailable) { return refused(why) }
            return try await BackendSessionSwitchCoordinator.restartPlan(sessionID: sessionID, live: live, saved: saved, target: target,
                signedIn: nil, unavailable: nil, manager: manager, planner: planner, sharedHistory: sharedHistory, store: store,
                carryClaude: live.provider == "claude" && target.provider == "claude")
        }
        let restart: Restart = { plan, note in
            guard plan.refusal == nil, let target = plan.to, let saved = plan.saved else {
                throw BackendSessionFailure.unsupported(plan.refusal ?? "This session cannot be switched.")
            }
            // Remembered, so the switched session keeps its record when the app next starts and adopts the host's sessions.
            return try await BackendSessionSwitchCoordinator.replace(plan, target: target, saved: saved, lifecycle: lifecycle, store: store,
                                                                     emit: emit, note: note, rememberTab: true)
        }
        // 13 Oct: a chat session (any account) and another AI's account are switched here, never by the session
        // host: a chat's AI runs in the app, and another AI is a new launch in the same tab.
        let handoverPlan: @Sendable (String, String) async throws -> BackendSessionSwitchPlan? = { sessionID, accountID in
            guard let live = manager.list().first(where: { $0.id == sessionID && $0.exitCode == nil }),
                  let target = try await find(accountID), target.id != live.profileId else { return nil }
            let raw = try await store.ledgerGet(sessionID)
            guard !raw.isNullish, let saved = try? BackendSessionSaved(raw) else { return nil }
            if let why = BackendSessionSwitchCoordinator.apiTargetRefusal(target, configuration: configuration, credentialAvailable: apiCredentialAvailable) {
                return BackendSessionSwitchPlan(sessionID: sessionID, refusal: why, from: BackendSessionSwitchCoordinator.account(of: live), to: target,
                    conversation: "stays", resume: false, conversationID: nil, mode: .restart, saved: saved, carried: nil)
            }
            if let chat = BackendSessionChatSwitch.plan(sessionID: sessionID, live: live, saved: saved, target: target) { return BackendSessionSwitchCoordinator.apiReplacementOffer(chat) }
            guard target.provider != live.provider else { return nil }
            return BackendSessionAIHandover.plan(sessionID: sessionID, live: live, saved: saved, target: target)
        }
        let handover: Restart = { plan, note in
            guard plan.refusal == nil, let target = plan.to, let saved = plan.saved else {
                throw BackendSessionFailure.unsupported(plan.refusal ?? "This session cannot be switched.")
            }
            // Remembered, so the new tab keeps its record when the app next starts.
            if plan.chat {
                return try await BackendSessionChatSwitch.perform(plan, target: target, saved: saved, lifecycle: lifecycle, store: store,
                                                                 emit: emit, note: note, rememberTab: true)
            }
            return try await BackendSessionAIHandover.perform(plan, target: target, saved: saved, lifecycle: lifecycle, store: store, planner: planner,
                                                             emit: emit, note: note, rememberTab: true)
        }
        return (plan, restart, handoverPlan, handover)
    }
}

/// A Claude conversation copied into another account's history (12 Oct), so a session that has to restart on
/// that account resumes the same conversation by its id even where the two accounts keep separate histories
/// (an account signed in through the app keeps its own folder). The original stays where it was; a different
/// copy already at the target is kept beside it, never overwritten. Only the conversation file is copied.
struct BackendSessionSwitchClaudeCarry: Sendable, Equatable {
    let source: URL
    let target: URL
    static func find(id: String, cwd: String, from: String, to: String) -> BackendSessionSwitchClaudeCarry? {
        guard id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil, !id.hasPrefix(".") else { return nil }
        let fromRoot = URL(fileURLWithPath: from).standardizedFileURL.resolvingSymlinksInPath()
        let toRoot = URL(fileURLWithPath: to).standardizedFileURL.resolvingSymlinksInPath()
        guard fromRoot.path != toRoot.path else { return nil }
        for spelling in NativeTranscriptPaths.projectSpellings(cwd) {
            let folder = NativeTranscriptPaths.encodeProjectPath(spelling)
            let source = URL(fileURLWithPath: from).appendingPathComponent("projects").appendingPathComponent(folder).appendingPathComponent(id + ".jsonl")
            var info = stat()
            guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let target = URL(fileURLWithPath: to).appendingPathComponent("projects").appendingPathComponent(folder).appendingPathComponent(id + ".jsonl")
            return BackendSessionSwitchClaudeCarry(source: source, target: target)
        }
        return nil
    }
    func copy() throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 18 Oct (#431): a copy there that holds all of it stays; one that went another way is kept beside it, one
        // per conversation, never a new full spare copy at every switch (BackendSessionSwitchCarryTarget).
        switch try BackendSessionSwitchCarryTarget.existing(source: source, target: target) {
        case .holdsAll: return
        case .differs: try BackendSessionSwitchCarryTarget.setAside(target)
        case .none, .older: break
        }
        try BackendAccountFiles.writeAtomic(try Data(contentsOf: source), to: target)
    }
}
