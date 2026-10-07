import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendSessionSwitchPlan: Sendable {
    public enum Mode: String, Sendable { case inPlace = "in-place", restart }
    public let sessionID: String
    public let refusal: String?
    public let from: BackendAccountProfile?
    public let to: BackendAccountProfile?
    public let conversation: String
    public let resume: Bool
    public let conversationID: String?
    public let mode: Mode
    let saved: BackendSessionSaved?
    let carried: BackendSessionSwitchCodexCarry.Thread?
    public var wireValue: NativeRPCValue {
        func account(_ value: BackendAccountProfile?) -> NativeRPCValue {
            value.map { .object([.init("id", .string($0.id)), .init("name", .string($0.name)), .init("provider", .string($0.provider))]) } ?? .null
        }
        return .object([.init("sessionId", .string(sessionID)), .init("refusal", refusal.map(NativeRPCValue.string) ?? .null),
            .init("from", account(from)), .init("to", account(to)), .init("conversation", .string(conversation)),
            .init("resume", .bool(resume)), .init("mode", .string(mode.rawValue))])
    }
}

public actor BackendSessionSwitchCoordinator {
    public struct Execution: Sendable {
        public enum Phase: String, Sendable { case awaitingReread = "awaiting-reread", confirmed, replaced }
        public let phase: Phase
        public let session: BackendSessionMeta
        public let requestedAccount: BackendAccountIdentity
    }
    private struct Pending: Sendable {
        let target: BackendAccountProfile
        let previousID: String
        let saved: BackendSessionSaved
        let seat: BackendAccountSeatSnapshot
        let afterSequence: UInt64
        let requested: Date
        var applied = false
        var createdNudge: String?
        var earlyEvidence: BackendAccountCredentialLookup?
    }
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let accounts: BackendAccountLaunchAdapter
    private let attribution: BackendAccountAttribution
    private let planner: BackendSessionRestorePlanner
    private let store: NativeStateStore
    private let emit: @Sendable (BackendSessionLifecycleEvent) -> Void
    private let sharedHistory: BackendSessionSwitchSharedHistory?
    private var observer: UUID?
    private var lifecycleObserver: UUID?
    private var pending: [String: Pending] = [:]
    private var busy = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    private init(lifecycle: BackendSessionLifecycleCoordinator, accounts: BackendAccountLaunchAdapter,
                 attribution: BackendAccountAttribution, planner: BackendSessionRestorePlanner, store: NativeStateStore,
                 sharedHistory: BackendSessionSwitchSharedHistory?, emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) {
        self.lifecycle = lifecycle; self.accounts = accounts; self.attribution = attribution; self.planner = planner; self.store = store
        self.sharedHistory = sharedHistory; self.emit = emit
    }
    /// `sharedHistory`: TS joinSharedHistory before planning (nil = no shared
    /// history service in this process; both stores are then described as they are).
    public static func start(lifecycle: BackendSessionLifecycleCoordinator, accounts: BackendAccountLaunchAdapter,
                             attribution: BackendAccountAttribution, planner: BackendSessionRestorePlanner, store: NativeStateStore,
                             sharedHistory: BackendSessionSwitchSharedHistory? = nil,
                             emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) async throws -> BackendSessionSwitchCoordinator {
        // D11 / TS wire.ts: with the vault off (no secure store, or logins that will not unlock) there is
        // no broker socket, and switching still works for plain and agent-kept accounts; app-kept ones
        // read unavailable upstream. Credential-lookup notes then simply never arrive.
        let coordinator = BackendSessionSwitchCoordinator(lifecycle: lifecycle, accounts: accounts, attribution: attribution, planner: planner, store: store,
                                                          sharedHistory: sharedHistory, emit: emit)
        await coordinator.attach()
        return coordinator
    }
    private func attach() async {
        observer = await accounts.broker.onCredentialLookup { [weak self] event in Task { await self?.noteLookup(event) } }
        lifecycleObserver = await lifecycle.observe { [weak self] event in
            switch event { case .exit(let id, _), .removed(let id, _): await self?.ended(id); default: break }
        }
    }
    /// TS createSessionSwitch().subject (session-switch-run.ts): the cheap
    /// refusals first, in place wherever a seat can take the login, otherwise
    /// the restart plan over the restore planner's decision under the target.
    public func subject(sessionID: String, accountID: String) async throws -> BackendSessionSwitchPlan {
        let meta = lifecycle.manager.list().first { $0.id == sessionID }
        let raw = try await store.ledgerGet(sessionID)
        let savedEntry = raw.isNullish ? nil : try BackendSessionSaved(raw)
        let targetProfile = try await accounts.profiles.find(accountID)
        // TS targetSignedIn / targetUnavailable: known for certain only where
        // the app keeps the login (runtime.ts keptBy, vaultSignedIn, keptUnavailable).
        var signedIn: Bool?, unavailable: String?
        if Self.refusal(meta: meta, saved: savedEntry, target: targetProfile) == nil, let target = targetProfile {
            let managed = await accounts.profiles.managed(target)
            var usable = true
            if managed, !target.system, BackendSessionSwitchKeptLogin.keptProviders.contains(target.provider) {
                do { try await accounts.vault.open() } catch { usable = false }
            }
            let kept = BackendSessionSwitchKeptLogin.keptBy(target, managed: managed, usable: usable)
            unavailable = BackendSessionSwitchKeptLogin.unavailable(kept)
            if kept == .app || kept == .adopting {
                let held = try await accounts.vault.summaries().first { $0.accountId == target.id }?.held == true
                signedIn = BackendSessionSwitchKeptLogin.signedIn(target, kept: kept, held: held)
            }
        }
        func refused(_ sentence: String) -> BackendSessionSwitchPlan {
            BackendSessionSwitchPlan(sessionID: sessionID, refusal: sentence, from: Self.account(of: meta), to: targetProfile, conversation: "stays",
                                     resume: false, conversationID: nil, mode: .restart, saved: savedEntry, carried: nil)
        }
        if let sentence = Self.refusal(meta: meta, saved: savedEntry, target: targetProfile, targetSignedIn: signedIn, targetUnavailable: unavailable) { return refused(sentence) }
        guard let live = meta, let target = targetProfile, let saved = savedEntry else { return refused("This session cannot be switched.") }
        if pending[sessionID] != nil { return refused("The previous account change is waiting for the provider's credential reread. Cancel it or let it settle first.") }
        if live.provider == "claude", target.provider == "claude", await accounts.broker.seatSnapshot(sessionID: sessionID) != nil {
            return BackendSessionSwitchPlan(sessionID: sessionID, refusal: nil, from: Self.account(of: live), to: target, conversation: "same",
                                            resume: false, conversationID: nil, mode: .inPlace, saved: saved, carried: nil)
        }
        // Both accounts on one history before anything is asked about it (TS D1 fix).
        let source = try await planner.accountFolder(saved)
        if let sharedHistory, let warning = await sharedHistory.joinBoth(source: source, target: target) {
            FileHandle.standardError.write(Data(("[accounts] " + warning + "\n").utf8))
        }
        let switched = try BackendSessionSaved(saved.raw.setting("profileId", .string(target.id)).setting("homeProfileId", .missing))
        let others = lifecycle.manager.list().filter { $0.id != sessionID }
        let decision = await planner.plan([switched], exact: false, claimedLive: others).first
        if live.provider == "codex" {
            let claimed = Set(others.filter { $0.exitCode == nil }.compactMap(\.agentSessionId))
            let found = try await Task.detached(priority: .utility) {
                try BackendSessionSwitchCodexCarry.find(home: source.configDir, cwd: saved.cwd, startedAt: live.createdAt, knownID: live.agentSessionId, claimed: claimed)
            }.value
            let plan = Self.plan(sessionID: sessionID, meta: live, saved: saved, target: target, decision: decision, occupied: false,
                                 sharedStore: false, targetSignedIn: signedIn, targetUnavailable: unavailable, carried: found != nil)
            guard let thread = found, plan.conversation == "carried" else { return plan }
            return plan.carrying(conversationID: thread.id, thread: thread)
        }
        // Which conversation is on screen, and can the target's store read it.
        let configDir = decision?.configDirectory
        let claimed = Set(others.filter { $0.exitCode == nil }.compactMap { $0.agentSessionId.flatMap { $0.isEmpty ? nil : $0 } })
        // The id on its command line, or one recovered for a tab restored with --continue.
        let named = await Task.detached(priority: .utility) {
            Self.onScreenConversation(meta: live, cwd: saved.cwd, configDir: source.configDir, claimed: claimed)
        }.value
        var readableInTarget = false
        if let named, let configDir {
            readableInTarget = NativeTranscriptPaths.projectSpellings(saved.cwd).contains { spelling in
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: configDir).appendingPathComponent("projects")
                    .appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(spelling)).appendingPathComponent(named + ".jsonl").path)
            }
        }
        var occupied = false
        if decision?.outcome == .resume {
            if readableInTarget, let named { occupied = claimed.contains(named) }
            else if let configDir {
                let mine = Self.scope(provider: switched.provider, config: configDir, cwd: switched.cwd)
                for entry in try await store.ledgerEntries() where entry.id != sessionID {
                    guard let other = try? BackendSessionSaved(entry.saved), let folder = try? await planner.accountFolder(other) else { continue }
                    if Self.scope(provider: other.provider, config: folder.configDir, cwd: other.cwd) == mine { occupied = true; break }
                }
            }
        }
        let sharedStore = configDir.map { BackendSessionRestorePlanner.store($0) == BackendSessionRestorePlanner.store(source.configDir) } ?? false
        let plan = Self.plan(sessionID: sessionID, meta: live, saved: saved, target: target, decision: decision, occupied: occupied,
                             sharedStore: sharedStore, targetSignedIn: signedIn, targetUnavailable: unavailable)
        let carried = named.flatMap { Self.conversationToCarry(plan: plan, agentSessionID: $0, readableInTarget: readableInTarget) }
        return plan.carrying(conversationID: carried, thread: nil)
    }
    /// TS perform: start the replacement, prove it ready, only then stop the
    /// old session. `note` is what the window is told once it happened
    /// (TS SESSION_SWITCHED_CHANNEL); the immediate switch passes none.
    public func perform(sessionID: String, accountID: String, note: String = "") async throws -> Execution {
        await enter(); defer { leave() }
        guard !closed else { throw BackendSessionFailure.closed }
        let plan = try await subject(sessionID: sessionID, accountID: accountID)
        guard plan.refusal == nil, let target = plan.to, let saved = plan.saved else { throw BackendSessionFailure.unsupported(plan.refusal ?? "This session cannot be switched.") }
        if plan.mode == .inPlace { return try await inPlace(plan, target: target, saved: saved) }
        // A Codex conversation is put under the other account first; if it
        // cannot be, the replacement starts fresh rather than resuming nothing.
        var resume = plan.resume, conversationID = plan.conversationID
        if let thread = plan.carried {
            let carriedTo = await Task.detached(priority: .utility) { BackendSessionSwitchCodexCarry.carry(thread, targetHome: target.configDir) }.value
            if carriedTo == nil { resume = false; conversationID = nil }
        }
        var (created, readiness) = try await launch(saved, target: target, replacing: sessionID, resume: resume, conversationID: conversationID)
        // A Codex resume that did not take is started once more, fresh.
        if readiness.outcome == .died, plan.carried != nil, resume {
            try? await lifecycle.close(sessionID: created.id)
            (created, readiness) = try await launch(saved, target: target, replacing: sessionID, resume: false, conversationID: nil)
        }
        do {
            guard readiness.outcome != .died, readiness.outcome != .signedOut else {
                throw BackendSessionFailure.unsupported(readiness.outcome == .signedOut ? Self.startSignedOutMessage(accountName: target.name)
                    : Self.startFailedMessage(accountName: target.name, said: readiness.said))
            }
            var remembered = saved.raw.setting("profileId", .string(target.id)).setting("homeProfileId", .missing)
            if let id = created.agentSessionId { remembered = remembered.setting("agentSessionId", .string(id)) }
            else if !created.resumed { remembered = remembered.setting("agentSessionId", .missing) }
            try await store.ledgerNote(created.id, saved: remembered)
            try await lifecycle.close(sessionID: sessionID, reason: .replaced)
            emit(.replaced(oldID: sessionID, session: created, note: note))
            return Execution(phase: .replaced, session: created, requestedAccount: target.identity)
        } catch { try? await lifecycle.close(sessionID: created.id); throw error }
    }
    private func launch(_ saved: BackendSessionSaved, target: BackendAccountProfile, replacing sessionID: String, resume: Bool,
                        conversationID: String?) async throws -> (BackendSessionMeta, BackendSessionReplacementReadiness.Result) {
        var input = saved.input(resume: resume, profileID: target.id, conversationID: conversationID, replaces: sessionID)
        input.homeProfileId = nil
        if conversationID == nil { input.resumeConversationId = nil }
        let created = try await lifecycle.create(input, context: BackendLaunchContext(rememberTab: false), holdOnFailure: false, announce: false)
        do { return (created, try await BackendSessionReplacementReadiness.awaitReady(sessionID: created.id, manager: lifecycle.manager)) }
        catch { try? await lifecycle.close(sessionID: created.id); throw error }
    }
    /// TS session-switch-run.ts performInPlace over account-vault/switch-in-place.ts
    /// (BackendAccountSwitchInPlace): refuse before anything changes, wait out a
    /// refresh in the session's folder, retarget the seat, nudge. The process is never
    /// signalled; the record catches up when the provider rereads the new login.
    private func inPlace(_ plan: BackendSessionSwitchPlan, target: BackendAccountProfile, saved: BackendSessionSaved) async throws -> Execution {
        let broker = accounts.broker
        guard let seat = await broker.seatSnapshot(sessionID: plan.sessionID), let pid = lifecycle.manager.pidOf(plan.sessionID),
              seat.processPID == pid, let previous = seat.servingAccountID else { throw BackendSessionFailure.unsupported("This session has no verified live provider seat.") }
        // Only an app-owned folder is ever nudged; refused before anything changes.
        if let directory = seat.storeDirectory {
            let configuration = await accounts.profiles.configuration
            guard BackendAccountFiles.descendant(directory, root: configuration.dataDirectory.path) else {
                throw BackendSessionFailure.unsupported("The credential cache trigger is not in an app-owned folder. Nothing there was touched.")
            }
        }
        let sequence = await broker.credentialSequence()
        pending[plan.sessionID] = Pending(target: target, previousID: previous, saved: saved, seat: seat, afterSequence: sequence, requested: Date())
        let moved = await BackendAccountSwitchInPlace.switchInPlace(sessionID: plan.sessionID,
            account: .init(id: target.id, name: target.name, configDir: target.configDir), dependencies: broker.switchInPlaceDependencies())
        switch moved {
        case .refused(let why):
            // Nothing was retargeted: the seat is as it was.
            pending[plan.sessionID] = nil
            throw BackendSessionFailure.unsupported(why)
        case .switched(let nudged, let file, _):
            // TS noteCreatedNudge: a `{}` this switch created is taken back once the reread is seen.
            if nudged == .created, let file { pending[plan.sessionID]?.createdNudge = file }
        }
        pending[plan.sessionID]?.applied = true
        let evidence = pending[plan.sessionID]?.earlyEvidence
        if let evidence { await noteLookup(evidence) }
        guard let meta = lifecycle.manager.list().first(where: { $0.id == plan.sessionID }) else { await cancel(sessionID: plan.sessionID); throw BackendSessionFailure.missingSession }
        if pending[plan.sessionID] == nil { return Execution(phase: .confirmed, session: meta, requestedAccount: target.identity) }
        emit(.switchPending(sessionID: plan.sessionID, targetID: target.id, targetName: target.name))
        return Execution(phase: .awaitingReread, session: meta, requestedAccount: target.identity)
    }
    public func noteLookup(_ event: BackendAccountCredentialLookup) async {
        guard var change = pending[event.sessionID], event.accountID == change.target.id, event.sequence > change.afterSequence,
              event.deliveredAt >= change.requested, lifecycle.manager.pidOf(event.sessionID) == event.processPID else { return }
        if !change.applied { change.earlyEvidence = event; pending[event.sessionID] = change; return }
        guard let meta = lifecycle.manager.setAccount(event.sessionID, account: change.target.identity, home: change.seat.launchAccountID) else { await ended(event.sessionID); return }
        pending[event.sessionID] = nil
        if let file = change.createdNudge { BackendAccountSwitchInPlace.clearNudge(file) }
        await attribution.drop(sessionID: event.sessionID)
        var saved = change.saved.raw.setting("profileId", .string(change.target.id))
        saved = saved.setting("homeProfileId", meta.homeProfileId.map(NativeRPCValue.string) ?? .missing)
        do { try await store.ledgerNote(meta.id, saved: saved); try await accounts.profiles.markUsed(id: change.target.id) }
        catch { emit(.switchFailed(sessionID: meta.id, message: "The provider reread the new login, but its recovery record could not be saved: " + error.localizedDescription)) }
        emit(.accountChanged(meta, event))
    }
    public func cancel(sessionID: String) async {
        guard let change = pending.removeValue(forKey: sessionID) else { return }
        _ = try? await accounts.retargetSeat(sessionID: sessionID, accountID: change.previousID)
        if let directory = change.seat.storeDirectory {
            let configuration = await accounts.profiles.configuration
            if BackendAccountFiles.descendant(directory, root: configuration.dataDirectory.path) { BackendAccountSwitchInPlace.nudge(directory) }
        }
        if let file = change.createdNudge { BackendAccountSwitchInPlace.clearNudge(file) }
        emit(.switchFailed(sessionID: sessionID, message: "The pending account change was cancelled before a credential reread was confirmed."))
    }
    public func pendingAccount(sessionID: String) -> BackendAccountIdentity? { pending[sessionID]?.target.identity }
    private func ended(_ id: String) async { if let change = pending.removeValue(forKey: id), let file = change.createdNudge { BackendAccountSwitchInPlace.clearNudge(file) } }
    public func stop() async {
        closed = true
        for id in Array(pending.keys) { await cancel(sessionID: id) }
        if let observer { await accounts.broker.removeCredentialLookupListener(observer) }; observer = nil
        if let lifecycleObserver { await lifecycle.removeObserver(lifecycleObserver) }; lifecycleObserver = nil
    }
    private func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { entrants.append($0) } }
    private func leave() { if entrants.isEmpty { busy = false } else { entrants.removeFirst().resume() } }
}

extension BackendSessionSwitchPlan {
    /// The same plan naming the conversation the replacement continues by id.
    func carrying(conversationID: String?, thread: BackendSessionSwitchCodexCarry.Thread?) -> BackendSessionSwitchPlan {
        BackendSessionSwitchPlan(sessionID: sessionID, refusal: refusal, from: from, to: to, conversation: conversation, resume: resume,
                                 conversationID: conversationID, mode: mode, saved: saved, carried: thread)
    }
}

/// The pure halves of session-switch.ts: refusals, the plan, the conversation
/// carried by id, and the sentences a failed switch says (REQ S5-5).
extension BackendSessionSwitchCoordinator {
    /// TS SEPARATE_HISTORIES: agents whose conversations never follow a switch.
    static let separateHistories: Set<String> = ["codex"]

    /// TS agentLabel.
    static func agentLabel(_ provider: String) -> String { CodingAICatalog.agent(provider)?.label ?? provider }

    /// TS `from`: the account the session runs as, read off the session itself.
    static func account(of meta: BackendSessionMeta?) -> BackendAccountProfile? {
        guard let meta, let id = meta.profileId, let name = meta.profileName else { return nil }
        return BackendAccountProfile(id: id, name: name, provider: meta.provider, configDir: "", system: false, color: "", createdAt: 0, lastUsedAt: nil)
    }

    /// TS subject's `onScreen`: the id this app put on the command line, or —
    /// for a Claude tab restored with `--continue`, which has none — the one
    /// recovered from its own account's transcripts (conversation-id.ts, ported
    /// as BackendConversationRecovery). Nil rather than a guess.
    static func onScreenConversation(meta: BackendSessionMeta, cwd: String, configDir: String, claimed: Set<String>) -> String? {
        if let id = meta.agentSessionId, !id.isEmpty { return id }
        guard meta.provider == "claude" else { return nil }
        let directories = NativeTranscriptPaths.projectSpellings(cwd).map {
            URL(fileURLWithPath: configDir).appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath($0))
        }
        return try? BackendConversationRecovery.read(directories: directories, startedAt: Date(timeIntervalSince1970: meta.createdAt / 1000), claimed: claimed)
    }

    /// TS conversationScope: which transcript `--continue` would attach to.
    static func scope(provider: String, config: String, cwd: String) -> String {
        provider + "\u{0}" + BackendSessionRestorePlanner.store(config) + "\u{0}" + cwd
    }

    /// TS switchRefusal: everything refused without looking at a disk, in the
    /// order a person would hit it.
    static func refusal(meta: BackendSessionMeta?, saved: BackendSessionSaved?, target: BackendAccountProfile?,
                        targetSignedIn: Bool? = nil, targetUnavailable: String? = nil) -> String? {
        guard let meta else { return "That session is not running any more, so there is nothing to switch." }
        if meta.exitCode != nil { return "This session has already ended. There is no agent in it to run as anybody." }
        if saved == nil {
            return "Only a session you opened here can be switched. This one was started for a paired device or by \(BRAND_ASSISTANT), and those keep the account they were given."
        }
        if meta.provider == "shell" {
            return "This tab is a plain terminal. An agent typed into it was not started by this app, so its account cannot be switched from here — open a new session on the account you want instead."
        }
        if !["claude", "codex"].contains(meta.provider) { return BackendAppAccountSignInParsing.unsupportedReason(meta.provider) }
        guard let target else { return "That account is not on this machine any more." }
        if target.provider != meta.provider {
            return "\(target.name) is a \(agentLabel(target.provider)) login and this session is running \(agentLabel(meta.provider)). An account only means anything to the agent it is a login of."
        }
        if target.id == meta.profileId { return "This session is already running as that account." }
        if let targetUnavailable, !targetUnavailable.isEmpty { return targetUnavailable }
        if targetSignedIn == false { return "\(target.name) is not signed in yet, so this session was left as it is. Sign in to it first, then switch." }
        return nil
    }

    /// TS planSwitch: what is refused, what becomes of the conversation, and
    /// whether the replacement is handed the continue flag.
    static func plan(sessionID: String, meta: BackendSessionMeta?, saved: BackendSessionSaved?, target: BackendAccountProfile?,
                     decision: BackendSessionRestoreDecision?, occupied: Bool, sharedStore: Bool,
                     targetSignedIn: Bool? = nil, targetUnavailable: String? = nil, carried: Bool = false) -> BackendSessionSwitchPlan {
        let from = account(of: meta)
        func answer(_ refusal: String?, _ conversation: String, _ resume: Bool) -> BackendSessionSwitchPlan {
            BackendSessionSwitchPlan(sessionID: sessionID, refusal: refusal, from: from, to: target, conversation: conversation,
                                     resume: resume, conversationID: nil, mode: .restart, saved: saved, carried: nil)
        }
        if let refused = refusal(meta: meta, saved: saved, target: target, targetSignedIn: targetSignedIn, targetUnavailable: targetUnavailable) {
            return answer(refused, "stays", false)
        }
        if let meta, separateHistories.contains(meta.provider) {
            if let decision, decision.outcome == .skip || decision.outcome == .failed {
                return answer("This session cannot be started again: \(decision.reason).", "stays", false)
            }
            return carried ? answer(nil, "carried", true) : answer(nil, "separate", false)
        }
        guard let decision, decision.outcome != .skip, decision.outcome != .failed else {
            return answer("This session cannot be started again: \(decision?.reason ?? "nothing could be decided about it").", "stays", false)
        }
        if decision.outcome != .resume { return answer(nil, decision.conversation == nil ? "none" : "stays", false) }
        if occupied { return answer(nil, "taken", false) }
        return answer(nil, decision.conversation == .unknown ? "unreadable" : sharedStore ? "follows" : "theirs", true)
    }

    /// TS conversationToCarry: the id only when the plan says the conversation
    /// follows, there is an id, and the target's store can read it.
    static func conversationToCarry(plan: BackendSessionSwitchPlan, agentSessionID: String?, readableInTarget: Bool) -> String? {
        guard plan.resume, plan.conversation == "follows", let id = agentSessionID, !id.isEmpty else { return nil }
        return readableInTarget ? id : nil
    }

    /// TS startFailed.
    static func startFailedMessage(accountName: String, said: String?) -> String {
        let quoted = said.map { " It said: “\($0)”." } ?? ""
        return "\(accountName) started and stopped straight away, so nothing was switched.\(quoted) This session is still running as it was."
    }

    /// TS startSignedOut.
    static func startSignedOutMessage(accountName: String) -> String {
        "\(accountName) is not signed in, so nothing was switched. This session is still running as it was. Sign in to \(accountName) first, then switch."
    }
}
