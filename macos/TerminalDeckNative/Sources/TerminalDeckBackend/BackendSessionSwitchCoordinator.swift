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
    /// 12 Oct: said first, in plain words, when a session that should switch in place has to restart
    /// instead (it started before switching was ready). Nil for every ordinary plan.
    public var notice: String? = nil
    /// 12 Oct: the Claude conversation copied into the target account's history just before that restart
    /// resumes it, where the target cannot read this account's history. Only for the restart offer above.
    var claudeCarry: BackendSessionSwitchClaudeCarry? = nil
    /// 13 Oct: the session already runs as (or was just switched to) that account. Nothing to do; said plainly.
    public var already = false
    /// 13 Oct: a chat session: switched by relaunching its tab's chat (BackendSessionChatSwitch).
    public var chat = false
    /// 18 Oct (#428): the two histories this plan read as one, joined only when the switch is made.
    var historyJoin: BackendSessionSwitchHistoryJoin? = nil
    public var wireValue: NativeRPCValue {
        func account(_ value: BackendAccountProfile?) -> NativeRPCValue {
            value.map { .object([.init("id", .string($0.id)), .init("name", .string($0.name)), .init("provider", .string($0.provider))]) } ?? .null
        }
        return .object([.init("sessionId", .string(sessionID)), .init("refusal", refusal.map(NativeRPCValue.string) ?? .null),
            .init("from", account(from)), .init("to", account(to)), .init("conversation", .string(conversation)),
            .init("resume", .bool(resume)), .init("mode", .string(mode.rawValue)), .init("notice", notice.map(NativeRPCValue.string) ?? .null),
            .init("already", .bool(already)), .init("chat", .bool(chat))])
    }
    /// The plan for picking the account a session is already on, or was just switched to (13 Oct, Asad's
    /// recording: the second pick of sherzod gave the red refusal). Never the offer, never red.
    public static func alreadyOn(sessionID: String, account: BackendAccountIdentity, provider: String) -> BackendSessionSwitchPlan {
        let profile = BackendAccountProfile(id: account.id, name: account.name, provider: provider, configDir: "", system: false, color: "", createdAt: 0, lastUsedAt: nil)
        var plan = BackendSessionSwitchPlan(sessionID: sessionID, refusal: "Already on \(account.name).", from: profile, to: profile, conversation: "same",
                                            resume: false, conversationID: nil, mode: .inPlace, saved: nil, carried: nil)
        plan.already = true
        return plan
    }
}

/// 18 Oct (#428): two accounts a switch puts on one conversation history. Planning only describes the joined
/// history; the join itself happens when the switch is made (BackendSessionSwitchCoordinator.replace).
struct BackendSessionSwitchHistoryJoin: Sendable {
    let history: BackendSessionSwitchSharedHistory
    let source: BackendAccountProfile
    let target: BackendAccountProfile
}

/// 18 Oct (#202): the plan a person was just shown is the one their click runs, so one pick in the account menu
/// does not do every heavy check twice. Used once, within half a minute, and only while the session is as it was
/// planned (same process, account and conversation); otherwise the switch plans again.
struct BackendSessionSwitchPlanMemo: Sendable {
    static let lifetime: TimeInterval = 30
    private struct Entry: Sendable { let accountID: String; let fingerprint: String; let at: Date; let plan: BackendSessionSwitchPlan }
    private var kept: [String: Entry] = [:]
    static func fingerprint(_ meta: BackendSessionMeta?, pid: Int32?) -> String? {
        guard let meta, meta.exitCode == nil else { return nil }
        return [meta.id, meta.profileId ?? "", meta.agentSessionId ?? "", pid.map { String($0) } ?? ""].joined(separator: "\u{0}")
    }
    mutating func keep(_ plan: BackendSessionSwitchPlan, accountID: String, fingerprint: String?, now: Date = Date()) {
        kept = kept.filter { now.timeIntervalSince($0.value.at) < Self.lifetime }
        guard plan.refusal == nil, !plan.already, let fingerprint else { kept[plan.sessionID] = nil; return }
        kept[plan.sessionID] = Entry(accountID: accountID, fingerprint: fingerprint, at: now, plan: plan)
    }
    mutating func take(sessionID: String, accountID: String, fingerprint: String?, now: Date = Date()) -> BackendSessionSwitchPlan? {
        guard let entry = kept.removeValue(forKey: sessionID), entry.accountID == accountID, let fingerprint,
              entry.fingerprint == fingerprint, now.timeIntervalSince(entry.at) < Self.lifetime else { return nil }
        return entry.plan
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
    private let apiCredentialAvailable: @Sendable (BackendAPIAccountRecord) -> Bool
    private var observer: UUID?
    private var lifecycleObserver: UUID?
    private var pending: [String: Pending] = [:]
    private let gate = BackendSessionAsyncGate()
    private var memo = BackendSessionSwitchPlanMemo()
    private var closed = false

    private init(lifecycle: BackendSessionLifecycleCoordinator, accounts: BackendAccountLaunchAdapter,
                 attribution: BackendAccountAttribution, planner: BackendSessionRestorePlanner, store: NativeStateStore,
                 sharedHistory: BackendSessionSwitchSharedHistory?, apiCredentialAvailable: @escaping @Sendable (BackendAPIAccountRecord) -> Bool,
                 emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) {
        self.lifecycle = lifecycle; self.accounts = accounts; self.attribution = attribution; self.planner = planner; self.store = store
        self.sharedHistory = sharedHistory; self.apiCredentialAvailable = apiCredentialAvailable; self.emit = emit
    }
    /// `sharedHistory`: TS joinSharedHistory before planning (nil = no shared
    /// history service in this process; both stores are then described as they are).
    public static func start(lifecycle: BackendSessionLifecycleCoordinator, accounts: BackendAccountLaunchAdapter,
                             attribution: BackendAccountAttribution, planner: BackendSessionRestorePlanner, store: NativeStateStore,
                             sharedHistory: BackendSessionSwitchSharedHistory? = nil,
                             apiCredentialAvailable: @escaping @Sendable (BackendAPIAccountRecord) -> Bool = { BackendAPIAccountKeychain.contains($0) },
                             emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) async throws -> BackendSessionSwitchCoordinator {
        // D11 / TS wire.ts: with the vault off (no secure store, or logins that will not unlock) there is
        // no broker socket, and switching still works for plain and agent-kept accounts; app-kept ones
        // read unavailable upstream. Credential-lookup notes then simply never arrive.
        let coordinator = BackendSessionSwitchCoordinator(lifecycle: lifecycle, accounts: accounts, attribution: attribution, planner: planner, store: store,
                                                          sharedHistory: sharedHistory, apiCredentialAvailable: apiCredentialAvailable, emit: emit)
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
    /// Reads only; the plan is kept briefly for the switch the person confirms (#202).
    public func subject(sessionID: String, accountID: String) async throws -> BackendSessionSwitchPlan {
        let plan = try await planned(sessionID: sessionID, accountID: accountID)
        memo.keep(plan, accountID: accountID, fingerprint: fingerprint(sessionID))
        return plan
    }
    private func fingerprint(_ sessionID: String) -> String? {
        BackendSessionSwitchPlanMemo.fingerprint(lifecycle.manager.list().first { $0.id == sessionID }, pid: lifecycle.manager.pidOf(sessionID))
    }
    private func planned(sessionID: String, accountID: String) async throws -> BackendSessionSwitchPlan {
        let meta = lifecycle.manager.list().first { $0.id == sessionID }
        let raw = try await store.ledgerGet(sessionID)
        let savedEntry = raw.isNullish ? nil : try BackendSessionSaved(raw)
        let targetProfile = try await accounts.profiles.find(accountID)
        // TS targetSignedIn / targetUnavailable: known for certain only where
        // the app keeps the login (runtime.ts keptBy, vaultSignedIn, keptUnavailable).
        var signedIn: Bool?, unavailable: String?
        if let target = targetProfile, BackendAPIAccountRecord.isAPIAccountID(target.id) {
            unavailable = Self.apiTargetRefusal(target, configuration: accounts.profiles.configuration, credentialAvailable: apiCredentialAvailable)
        } else if Self.refusal(meta: meta, saved: savedEntry, target: targetProfile) == nil, let target = targetProfile {
            // Subscription targets retain their existing vault checks. API targets use only their own key.
            await accounts.reviveVault()
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
        if let unavailable, let target = targetProfile, BackendAPIAccountRecord.isAPIAccountID(target.id) { return refused(unavailable) }
        // 13 Oct: a chat session switches by relaunching its tab's chat; another AI's account takes a terminal
        // session over in this tab with the same conversation.
        if let live = meta, let saved = savedEntry, let target = targetProfile, target.id != live.profileId {
            if let chat = BackendSessionChatSwitch.plan(sessionID: sessionID, live: live, saved: saved, target: target) { return Self.apiReplacementOffer(chat) }
            if let handover = BackendSessionAIHandover.plan(sessionID: sessionID, live: live, saved: saved, target: target) { return handover }
        }
        if let sentence = Self.refusal(meta: meta, saved: savedEntry, target: targetProfile, targetSignedIn: signedIn, targetUnavailable: unavailable) { return refused(sentence) }
        guard let live = meta, let target = targetProfile, let saved = savedEntry else { return refused("This session cannot be switched.") }
        if pending[sessionID] != nil { return refused("This session's last account change is still waiting for the agent to pick up the new login. Cancel it or wait a moment, then try again.") }
        if live.provider == "claude", target.provider == "claude",
           !Self.requiresAccountReplacement(sourceID: live.profileId, targetID: target.id),
           await accounts.broker.seatSnapshot(sessionID: sessionID) != nil {
            return BackendSessionSwitchPlan(sessionID: sessionID, refusal: nil, from: Self.account(of: live), to: target, conversation: "same",
                                            resume: false, conversationID: nil, mode: .inPlace, saved: saved, carried: nil)
        }
        // A Claude session with no seat would have switched in place had it started with switching ready: said
        // first, and its conversation carried to the account so the restart resumes it.
        let noSeat = live.provider == "claude" && target.provider == "claude"
        let plan = try await Self.restartPlan(sessionID: sessionID, live: live, saved: saved, target: target, signedIn: signedIn, unavailable: unavailable,
                                              manager: lifecycle.manager, planner: planner, sharedHistory: sharedHistory, store: store, carryClaude: noSeat)
        return noSeat ? plan.offeringRestart() : plan
    }
    /// API credentials belong to a launch environment, never a subscription broker seat.
    static func requiresAccountReplacement(sourceID: String?, targetID: String) -> Bool {
        sourceID.map(BackendAPIAccountRecord.isAPIAccountID) == true || BackendAPIAccountRecord.isAPIAccountID(targetID)
    }
    static func apiReplacementOffer(_ plan: BackendSessionSwitchPlan) -> BackendSessionSwitchPlan {
        guard let target = plan.to, requiresAccountReplacement(sourceID: plan.from?.id, targetID: target.id), plan.refusal == nil else { return plan }
        return BackendSessionSwitchPlan(sessionID: plan.sessionID, refusal: nil, from: plan.from, to: target,
            conversation: plan.conversation, resume: plan.resume, conversationID: plan.conversationID, mode: .restart,
            saved: plan.saved, carried: plan.carried,
            notice: SwitchAccountRestartOffer.sentence(accountName: target.name, carriesOn: plan.chat || plan.carriesConversation),
            claudeCarry: plan.claudeCarry, already: plan.already, chat: plan.chat, historyJoin: plan.historyJoin)
    }
    /// Configuration availability only: a saved key is not proof that the provider accepts it.
    static func apiTargetRefusal(_ target: BackendAccountProfile, configuration: BackendAccountConfiguration? = nil,
                                 credentialAvailable: (BackendAPIAccountRecord) -> Bool = BackendAPIAccountKeychain.contains) -> String? {
        guard BackendAPIAccountRecord.isAPIAccountID(target.id) else { return nil }
        do {
            guard let record = try BackendAPIAccountRecord.read(target) else {
                return "This API account's settings are unavailable. Open Settings › Coding AIs and check the connection. Nothing was changed."
            }
            if let configuration, record.appName != configuration.appName || !BackendAccountSignInStorage.ownsFolder(target, configuration: configuration) {
                return "This API account belongs to another copy of the app. Nothing was changed."
            }
            guard !record.requiresKey || credentialAvailable(record) else {
                return "The API key for \(target.name) is missing or unavailable. Open Settings › Coding AIs and update its key. Nothing was changed."
            }
            return nil
        } catch {
            return "This API account's settings could not be read. Open Settings › Coding AIs and check the connection. Nothing was changed."
        }
    }
    /// The restart half of TS subject: both accounts on one history, the restore planner's decision under
    /// the target, and which conversation the replacement continues. Shared with the hosted app, whose
    /// sessions that started before switching was ready restart through it (BackendSessionSwitchRestartFallback).
    static func restartPlan(sessionID: String, live: BackendSessionMeta, saved: BackendSessionSaved, target: BackendAccountProfile,
                            signedIn: Bool?, unavailable: String?, manager: BackendPTYManager, planner: BackendSessionRestorePlanner,
                            sharedHistory: BackendSessionSwitchSharedHistory?, store: NativeStateStore,
                            carryClaude: Bool = false) async throws -> BackendSessionSwitchPlan {
        // Both accounts on one history (TS D1 fix), described here and joined only when the switch is made (#428):
        // asking what a switch would do never links two histories.
        let source = try await planner.accountFolder(saved)
        var joining: BackendSessionSwitchHistoryJoin?
        if let sharedHistory, await sharedHistory.wouldJoin(source: source, target: target) {
            joining = .init(history: sharedHistory, source: source, target: target)
        }
        // The folder whose projects/ the joined history is; the source's own history is merged into it.
        var sharedConfig: String?
        if joining != nil, let root = await sharedHistory?.root() { sharedConfig = URL(fileURLWithPath: root).deletingLastPathComponent().path }
        let joinedConfigs = joining == nil ? [] : [source.configDir] + (sharedConfig.map { [$0] } ?? [])
        let switched = try BackendSessionSaved(saved.raw.setting("profileId", .string(target.id)).setting("homeProfileId", .missing))
        let others = manager.list().filter { $0.id != sessionID }
        var decision = await planner.plan([switched], exact: false, claimedLive: others).first
        // Joined, the target also reads this account's history: a conversation found only there is found.
        if joining != nil, let found = decision, found.outcome == .fresh, found.conversation == BackendSessionRestoreDecision.Conversation.none {
            for config in joinedConfigs {
                guard try await planner.conversation(switched, config: config) != BackendSessionRestoreDecision.Conversation.none else { continue }
                decision = BackendSessionRestoreDecision(session: found.session, outcome: .resume, reason: "continuing the conversation on disk",
                                                         configDirectory: found.configDirectory, conversation: .found)
                break
            }
        }
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
        // Joined, the target reads one history with this account's: what either holds, it holds.
        let readable = configDir.map { [$0] + joinedConfigs } ?? []
        var readableInTarget = false
        if let named {
            readableInTarget = readable.contains { config in
                NativeTranscriptPaths.projectSpellings(saved.cwd).contains { spelling in
                    FileManager.default.fileExists(atPath: URL(fileURLWithPath: config).appendingPathComponent("projects")
                        .appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(spelling)).appendingPathComponent(named + ".jsonl").path)
                }
            }
        }
        var occupied = false
        if decision?.outcome == .resume {
            if readableInTarget, let named { occupied = claimed.contains(named) }
            else if let configDir {
                let mine = Self.scope(provider: switched.provider, config: joining == nil ? configDir : sharedConfig ?? configDir, cwd: switched.cwd)
                for entry in try await store.ledgerEntries() where entry.id != sessionID {
                    guard let other = try? BackendSessionSaved(entry.saved), let folder = try? await planner.accountFolder(other) else { continue }
                    if Self.scope(provider: other.provider, config: folder.configDir, cwd: other.cwd) == mine { occupied = true; break }
                }
            }
        }
        let sharedStore = joining != nil
            || configDir.map { BackendSessionRestorePlanner.store($0) == BackendSessionRestorePlanner.store(source.configDir) } ?? false
        let plan = Self.plan(sessionID: sessionID, meta: live, saved: saved, target: target, decision: decision, occupied: occupied,
                             sharedStore: sharedStore, targetSignedIn: signedIn, targetUnavailable: unavailable)
        let carried = named.flatMap { Self.conversationToCarry(plan: plan, agentSessionID: $0, readableInTarget: readableInTarget) }
        var answer = plan.carrying(conversationID: carried, thread: nil)
        answer.historyJoin = joining
        // 12 Oct, the restart offer only: the conversation on screen comes along even where the two accounts keep
        // separate histories: it is copied into the target's history and resumed there by its id.
        guard carryClaude, answer.refusal == nil, answer.conversationID == nil, let named, !claimed.contains(named), let configDir,
              let carry = BackendSessionSwitchClaudeCarry.find(id: named, cwd: saved.cwd, from: source.configDir, to: configDir) else { return answer }
        return BackendSessionSwitchPlan(sessionID: sessionID, refusal: nil, from: answer.from, to: answer.to, conversation: "carried", resume: true,
                                        conversationID: named, mode: .restart, saved: saved, carried: nil, notice: nil, claudeCarry: carry,
                                        historyJoin: joining)
    }
    /// TS perform: start the replacement, prove it ready, only then stop the
    /// old session. `note` is what the window is told once it happened
    /// (TS SESSION_SWITCHED_CHANNEL); the immediate switch passes none.
    public func perform(sessionID: String, accountID: String, note: String = "") async throws -> Execution {
        await gate.enter(sessionID); defer { gate.leave(sessionID) }
        guard !closed else { throw BackendSessionFailure.closed }
        // The plan the person was just shown, while the session is as it was planned (#202); otherwise planned now.
        let plan: BackendSessionSwitchPlan
        if pending[sessionID] == nil, let shown = memo.take(sessionID: sessionID, accountID: accountID, fingerprint: fingerprint(sessionID)) { plan = shown }
        else { plan = try await planned(sessionID: sessionID, accountID: accountID) }
        guard plan.refusal == nil, let target = plan.to, let saved = plan.saved else { throw BackendSessionFailure.unsupported(plan.refusal ?? "This session cannot be switched.") }
        if plan.chat {
            return try await BackendSessionChatSwitch.perform(plan, target: target, saved: saved, lifecycle: lifecycle, store: store,
                                                             emit: emit, note: note, rememberTab: false)
        }
        if plan.conversation == "handover" {
            return try await BackendSessionAIHandover.perform(plan, target: target, saved: saved, lifecycle: lifecycle, store: store, planner: planner,
                                                             emit: emit, note: note, rememberTab: false)
        }
        if plan.mode == .inPlace { return try await inPlace(plan, target: target, saved: saved) }
        return try await Self.replace(plan, target: target, saved: saved, lifecycle: lifecycle, store: store, emit: emit, note: note)
    }
    /// The restart itself (TS perform's restart half): start the replacement on the target account, resuming
    /// the conversation the plan named, prove it ready, remember it, and only then stop the old session, so a
    /// failure leaves the old one running as it was. Shared with the hosted app (BackendSessionSwitchRestartFallback).
    /// `rememberTab`: the hosted app passes true. The session host keeps each launch's scope, and at every app
    /// start the app re-notes only the host sessions launched as remembered tabs; a replacement launched
    /// unremembered lost its record at the next app start (and with it, every later switch). A failed
    /// replacement is still forgotten (`lifecycle.close`), and no held duplicate is made (`holdOnFailure: false`).
    static func replace(_ plan: BackendSessionSwitchPlan, target: BackendAccountProfile, saved: BackendSessionSaved,
                        lifecycle: BackendSessionLifecycleCoordinator, store: NativeStateStore,
                        emit: @Sendable (BackendSessionLifecycleEvent) -> Void, note: String, rememberTab: Bool = false) async throws -> Execution {
        let sessionID = plan.sessionID
        // The two histories the plan read as one are joined now that the switch is made, never by asking (#428).
        // A conversation that follows only through that join is refused here rather than resumed from nothing.
        if let join = plan.historyJoin, let warning = await join.history.joinBoth(source: join.source, target: join.target) {
            FileHandle.standardError.write(Data(("[accounts] " + warning + "\n").utf8))
            if plan.conversation == "follows" {
                throw BackendSessionFailure.unsupported("The two accounts' conversation histories could not be joined, so nothing was changed. This session is still running as it was.")
            }
        }
        // A Codex conversation is put under the other account first; if it
        // cannot be, the replacement starts fresh rather than resuming nothing.
        var resume = plan.resume, conversationID = plan.conversationID
        // A Claude conversation the target cannot read is copied there first; if it cannot be, nothing is changed.
        if let carry = plan.claudeCarry {
            do { try await Task.detached(priority: .utility) { try carry.copy() }.value }
            catch { throw BackendSessionFailure.unsupported("This conversation could not be copied to \(target.name), so nothing was changed. This session is still running as it was.") }
        }
        if let thread = plan.carried {
            let carriedTo = await Task.detached(priority: .utility) { BackendSessionSwitchCodexCarry.carry(thread, targetHome: target.configDir) }.value
            if carriedTo == nil { resume = false; conversationID = nil }
        }
        var (created, readiness) = try await launch(saved, target: target, replacing: sessionID, resume: resume, conversationID: conversationID,
                                                    lifecycle: lifecycle, rememberTab: rememberTab)
        // A Codex resume that did not take is started once more, fresh.
        if readiness.outcome == .died, plan.carried != nil, resume {
            try? await lifecycle.close(sessionID: created.id)
            (created, readiness) = try await launch(saved, target: target, replacing: sessionID, resume: false, conversationID: nil,
                                                    lifecycle: lifecycle, rememberTab: rememberTab)
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
    private static func launch(_ saved: BackendSessionSaved, target: BackendAccountProfile, replacing sessionID: String, resume: Bool,
                               conversationID: String?, lifecycle: BackendSessionLifecycleCoordinator,
                               rememberTab: Bool) async throws -> (BackendSessionMeta, BackendSessionReplacementReadiness.Result) {
        var input = saved.input(resume: resume, profileID: target.id, conversationID: conversationID, replaces: sessionID)
        input.homeProfileId = nil
        if conversationID == nil { input.resumeConversationId = nil }
        // Sessions seat (57aba62d): a session that reopens for a switch keeps the name the person gave it.
        let created = try await lifecycle.create(input, context: BackendLaunchContext(rememberTab: rememberTab), holdOnFailure: false, announce: false,
                                                 named: saved.title)
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
              seat.processPID == pid, let previous = seat.servingAccountID else { throw BackendSessionFailure.unsupported(SwitchAccountRestartOffer.notReady + " Nothing was changed.") }
        // Only an app-owned folder is ever nudged; refused before anything changes.
        if let directory = seat.storeDirectory {
            let configuration = await accounts.profiles.configuration
            guard BackendAccountFiles.descendant(directory, root: configuration.dataDirectory.path) else {
                throw BackendSessionFailure.unsupported("This session keeps its login in a folder the app does not own, so nothing was changed.")
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
        do { try await store.ledgerNote(meta.id, saved: saved); try await accounts.profiles.markUsed(id: change.target.id, projectPath: meta.cwd) }
        catch { emit(.switchFailed(sessionID: meta.id, message: "The new login is in use, but it could not be remembered for when the app reopens: " + error.localizedDescription)) }
        emit(.accountChanged(meta, event))
    }
    public func cancel(sessionID: String) async {
        guard let change = pending.removeValue(forKey: sessionID) else { return }
        // 18 Oct (#429): "still on its previous account" only once the seat really serves it again. A refused
        // put-back leaves the change pending, so it still completes when the agent rereads, and says so.
        let putBack: Bool, why: String?
        do { putBack = try await accounts.retargetSeat(sessionID: sessionID, accountID: change.previousID); why = nil }
        catch { putBack = false; why = error.localizedDescription }
        guard putBack else {
            if pending[sessionID] == nil, lifecycle.manager.pidOf(sessionID) == change.seat.processPID { pending[sessionID] = change }
            emit(.switchFailed(sessionID: sessionID, message: Self.cancelRefusedMessage(accountName: change.target.name, why: why)))
            return
        }
        if let directory = change.seat.storeDirectory {
            let configuration = await accounts.profiles.configuration
            if BackendAccountFiles.descendant(directory, root: configuration.dataDirectory.path) { BackendAccountSwitchInPlace.nudge(directory) }
        }
        if let file = change.createdNudge { BackendAccountSwitchInPlace.clearNudge(file) }
        emit(.switchFailed(sessionID: sessionID, message: "The account change was cancelled before the agent picked up the new login. The session is still on its previous account."))
    }
    /// What a cancel says when the previous login could not be put back (#429).
    static func cancelRefusedMessage(accountName: String, why: String?) -> String {
        let reason = why.map { " It said: “\($0)”." } ?? ""
        return "The account change could not be cancelled: the previous login could not be put back.\(reason) The session will use \(accountName) from its next request."
    }
    public func pendingAccount(sessionID: String) -> BackendAccountIdentity? { pending[sessionID]?.target.identity }
    private func ended(_ id: String) async { if let change = pending.removeValue(forKey: id), let file = change.createdNudge { BackendAccountSwitchInPlace.clearNudge(file) } }
    public func stop() async {
        closed = true
        for id in Array(pending.keys) { await cancel(sessionID: id) }
        if let observer { await accounts.broker.removeCredentialLookupListener(observer) }; observer = nil
        if let lifecycleObserver { await lifecycle.removeObserver(lifecycleObserver) }; lifecycleObserver = nil
    }
    /// 18 Oct (#447): one switch at a time per session; another session's switch never waits behind it.
}

extension BackendSessionSwitchPlan {
    /// The same plan naming the conversation the replacement continues by id.
    func carrying(conversationID: String?, thread: BackendSessionSwitchCodexCarry.Thread?) -> BackendSessionSwitchPlan {
        BackendSessionSwitchPlan(sessionID: sessionID, refusal: refusal, from: from, to: to, conversation: conversation, resume: resume,
                                 conversationID: conversationID, mode: mode, saved: saved, carried: thread, notice: notice, claudeCarry: claudeCarry,
                                 historyJoin: historyJoin)
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
