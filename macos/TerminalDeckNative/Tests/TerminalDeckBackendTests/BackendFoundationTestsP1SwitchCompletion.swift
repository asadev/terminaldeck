import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Lane P1: the three pieces of session switching that had no Swift caller —
// the kept-login rule (runtime.ts keptBy / vaultSignedIn / keptUnavailable),
// shared history joined before planning (session-switch-run.ts subject), and
// the conversation recovered for a tab restored with --continue.

private typealias Kept = BackendSessionSwitchKeptLogin
private func account(_ id: String = "work", provider: String = "claude", system: Bool = false,
                     loginStore: String? = nil, keptSlots: [String]? = nil) -> BackendAccountProfile {
    var profile = S5SwitchFixture.profile(id, name: id + "@example.com", provider: provider, configDir: "/accounts/" + id)
    profile.system = system; profile.loginStore = loginStore; profile.keptSlots = keptSlots
    return profile
}
private let loginSlot = "keychain:Claude Code-credentials"

@Suite("P1 switch: where a login is kept (TS vault-profiles.test.ts over runtime.ts keptBy)")
struct BackendFoundationTestsP1SwitchKeptLogin {
    // TS vault-profiles.test.ts:110
    @Test func aNewAccountIsKeptByTheAppFromItsFirstMoment() {
        #expect(Kept.keptBy(account(loginStore: "app"), managed: true, usable: true) == .app)
    }
    // TS vault-profiles.test.ts:120 (no vault: TS keptManaged is false for an account never kept)
    @Test func withoutAVaultNothingChanges() {
        #expect(Kept.keptBy(account(), managed: false, usable: false) == .agent)
        #expect(Kept.keptBy(account(), managed: true, usable: false) == .agent)
    }
    // TS vault-profiles.test.ts:165
    @Test func anAccountMadeBeforeTheVaultMovesAcrossInsteadOfSigningOut() {
        let old = account()
        let kept = Kept.keptBy(old, managed: true, usable: true)
        #expect(kept == .adopting)
        #expect(Kept.signedIn(old, kept: kept, held: false) == nil)
    }
    // TS vault-profiles.test.ts:190
    @Test func anAccountRemadeUnderADeletedOnesNameStartsSignedOut() {
        let again = account(loginStore: "app")
        #expect(Kept.signedIn(again, kept: Kept.keptBy(again, managed: true, usable: true), held: false) == false)
    }
    // TS vault-profiles.test.ts:201
    @Test func aCodexAccountIsFollowedFromTheMomentItIsMade() {
        #expect(Kept.keptBy(account("codex", provider: "codex"), managed: true, usable: true) == .app)
    }
    // TS vault-profiles.test.ts:235
    @Test func refusesToSwitchToAKeptAccountWithNoLoginBeforeAnythingIsStopped() throws {
        let empty = account("empty", loginStore: "app")
        let meta = S5SwitchFixture.meta(profileId: "system", profileName: "Default"), saved = try S5SwitchFixture.saved()
        let kept = Kept.keptBy(empty, managed: true, usable: true)
        let refusal = BackendSessionSwitchCoordinator.refusal(meta: meta, saved: saved, target: empty,
                                                              targetSignedIn: Kept.signedIn(empty, kept: kept, held: false))
        #expect(refusal?.contains("is not signed in yet") == true)
        // Signed in, it goes ahead.
        #expect(BackendSessionSwitchCoordinator.refusal(meta: meta, saved: saved, target: empty,
                                                        targetSignedIn: Kept.signedIn(empty, kept: kept, held: true)) == nil)
    }
    // TS vault-profiles.test.ts:247 (the list's keptBy/signedIn pair)
    @Test func aKeptAccountReadsKeptAndSignedInAndTheMachinesOwnReadsAgent() {
        let work = account(loginStore: "app")
        let kept = Kept.keptBy(work, managed: true, usable: true)
        #expect(kept == .app); #expect(Kept.signedIn(work, kept: kept, held: true) == true)
        let system = account("system", system: true)
        let mine = Kept.keptBy(system, managed: false, usable: true)
        #expect(mine == .agent); #expect(Kept.signedIn(system, kept: mine, held: false) == nil)
    }
    // TS vault-profiles.test.ts:279
    @Test func aCodexAccountInAFolderThePersonChoseIsTheAgents() {
        #expect(Kept.keptBy(account("mine", provider: "codex"), managed: false, usable: true) == .agent)
    }
    // TS vault-profiles.test.ts:296
    @Test func anAccountTheAppKeepsIsUnavailableWhereNoVaultRunsAndTheSwitchIsRefused() throws {
        let work = account(loginStore: "app")
        let kept = Kept.keptBy(work, managed: true, usable: false)
        #expect(kept == .unavailable)
        #expect(Kept.unavailable(kept) == Kept.unavailableSentence)
        let meta = S5SwitchFixture.meta(profileId: "system", profileName: "Default")
        #expect(BackendSessionSwitchCoordinator.refusal(meta: meta, saved: try S5SwitchFixture.saved(), target: work,
                                                        targetUnavailable: Kept.unavailable(kept)) == Kept.unavailableSentence)
    }
    // TS vault-profiles.test.ts:337
    @Test func aVaultThatWillNotUnlockLeavesItsKeptAccountsUnavailable() {
        let work = account(keptSlots: [loginSlot])
        #expect(Kept.keptBy(work, managed: true, usable: false) == .unavailable)
        #expect(Kept.unavailable(Kept.keptBy(account(), managed: true, usable: true)) == nil)
    }
    // TS vault-profiles.test.ts:359
    @Test func aCodexAccountReadsCannotTellUntilSomethingHasBeenKeptForIt() {
        let fresh = account("codex", provider: "codex")
        #expect(Kept.signedIn(fresh, kept: .app, held: false) == nil)
        #expect(Kept.signedIn(fresh, kept: .app, held: true) == true)
        let followed = account("codex", provider: "codex", keptSlots: ["file:auth.json"])
        #expect(Kept.signedIn(followed, kept: .app, held: false) == false)
    }
    // TS runtime.ts keptBy: an account whose login slot has moved in is the app's.
    @Test func anAccountWhoseLoginSlotMovedInIsTheApps() {
        #expect(Kept.keptBy(account(keptSlots: [loginSlot]), managed: true, usable: true) == .app)
        #expect(Kept.keptBy(account(keptSlots: ["keychain:Claude Code"]), managed: true, usable: true) == .adopting)
        #expect(Kept.keptBy(account(provider: "gemini", loginStore: "app"), managed: true, usable: true) == .agent)
    }
}

/// A Claude home and an app-owned accounts folder in a scratch directory.
private final class HistoryRig {
    let scratch: BackendFoundationTestsSessionsScratch
    let system: URL, managed: URL
    init() throws {
        scratch = try BackendFoundationTestsSessionsScratch()
        system = scratch.root.appendingPathComponent("home/.claude"); managed = scratch.root.appendingPathComponent("accounts")
        try FileManager.default.createDirectory(at: system.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }
    func service(writable: Bool = true) -> BackendAppSharedProjects {
        BackendAppSharedProjects(systemConfig: system, managedRoot: managed, writable: writable, changed: {})
    }
    /// An account with a history of its own: one conversation in one folder.
    func account(_ id: String, inside: Bool = true, conversation: String) throws -> BackendAccountProfile {
        let folder = (inside ? managed : scratch.root.appendingPathComponent("elsewhere")).appendingPathComponent(id)
        let file = folder.appendingPathComponent("projects/-w-app").appendingPathComponent(conversation + ".jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"user\"}\n".utf8).write(to: file)
        return S5SwitchFixture.profile(id, name: id, configDir: folder.path)
    }
    func isLink(_ profile: BackendAccountProfile) -> Bool {
        let path = URL(fileURLWithPath: profile.configDir).appendingPathComponent("projects").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}

@Suite("P1 switch: both accounts on one history before planning (TS session-switch-run.ts subject, D1)")
struct BackendFoundationTestsP1SwitchSharedHistory {
    // TS subject: canJoinSharedHistory(source) && canJoinSharedHistory(target) → join both, then plan.
    @Test func joinsBothAccountsBeforeThePlanReadsEitherStore() async throws {
        let rig = try HistoryRig(), service = rig.service()
        let source = try rig.account("home", conversation: "conv-home"), target = try rig.account("work", conversation: "conv-work")
        let warning = await BackendSessionSwitchSharedHistory.projects(service).joinBoth(source: source, target: target)
        #expect(warning == nil)
        #expect(await service.readsShared(source)); #expect(await service.readsShared(target))
        // One store, so the plan may say the conversation on screen follows.
        let shared = BackendSessionRestorePlanner.store(source.configDir) == BackendSessionRestorePlanner.store(target.configDir)
        #expect(shared)
        #expect(FileManager.default.fileExists(atPath: rig.system.appendingPathComponent("projects/-w-app/conv-home.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: rig.system.appendingPathComponent("projects/-w-app/conv-work.jsonl").path))
    }
    // TS subject: an account the app must not restructure is left alone, and the sheet says what really happens.
    @Test func anAccountTheAppMustNotRestructureLeavesBothAsTheyAre() async throws {
        let rig = try HistoryRig(), service = rig.service()
        let source = try rig.account("home", conversation: "conv-home")
        let foreign = try rig.account("theirs", inside: false, conversation: "conv-theirs")
        #expect(await BackendSessionSwitchSharedHistory.projects(service).joinBoth(source: source, target: foreign) == nil)
        #expect(!rig.isLink(source)); #expect(!rig.isLink(foreign))
        #expect(BackendSessionRestorePlanner.store(source.configDir) != BackendSessionRestorePlanner.store(foreign.configDir))
    }
    // TS subject catch: "A link that could not be made is not a switch that cannot happen."
    @Test func aLinkThatCouldNotBeMadeIsNotASwitchThatCannotHappen() async throws {
        let rig = try HistoryRig(), service = rig.service(writable: false)
        let source = try rig.account("home", conversation: "conv-home"), target = try rig.account("work", conversation: "conv-work")
        let warning = await BackendSessionSwitchSharedHistory.projects(service).joinBoth(source: source, target: target)
        #expect(warning?.contains("could not join the shared conversation history") == true)
        #expect(!rig.isLink(source)); #expect(!rig.isLink(target))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: source.configDir).appendingPathComponent("projects/-w-app/conv-home.jsonl").path))
    }
}

@Suite("P1 switch: a tab restored at launch switches with its own conversation (TS session-switch-reliability.test.ts:241)")
struct BackendFoundationTestsP1SwitchRestoredConversation {
    private static let restored = "11111111-1111-4111-8111-111111111111"
    private static let newerOther = "22222222-2222-4222-8222-222222222222"
    private typealias F = BackendFoundationTestsSessionsFixtures
    /// The tab's own account folder, with its transcripts under the folder's encoded name.
    private func world() throws -> (scratch: BackendFoundationTestsSessionsScratch, cwd: String, config: String) {
        let scratch = try BackendFoundationTestsSessionsScratch()
        let cwd = scratch.root.appendingPathComponent("app").path, config = scratch.root.appendingPathComponent("cfg").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        return (scratch, cwd, config)
    }
    private func transcript(_ world: (scratch: BackendFoundationTestsSessionsScratch, cwd: String, config: String), _ id: String, at milliseconds: Double) throws {
        let relative = "cfg/projects/" + NativeTranscriptPaths.encodeProjectPath(world.cwd) + "/" + id + ".jsonl"
        try world.scratch.modified(world.scratch.write(relative, "{\"type\":\"user\"}\n"), milliseconds: milliseconds)
    }
    // TS session-switch-reliability.test.ts:241 — the restored tab (no id, started at 1000 ms) attached to the
    // folder's newest conversation then; another tab has since started, and is on, a newer one.
    @Test func recoversTheIdFromTheTranscriptsAndCarriesIt() throws {
        let w = try world()
        try transcript(w, Self.restored, at: 500)
        try transcript(w, Self.newerOther, at: 5_000)
        let tab = F.meta("restored", cwd: w.cwd)
        let named = BackendSessionSwitchCoordinator.onScreenConversation(meta: tab, cwd: w.cwd, configDir: w.config, claimed: [Self.newerOther])
        #expect(named == Self.restored)
        // And it is the id the replacement is told to continue when the plan says it follows.
        let decision = BackendSessionRestoreDecision(session: try S5SwitchFixture.saved(profileId: "home"), outcome: .resume,
                                                     reason: "continuing the conversation on disk", configDirectory: w.config, conversation: .found)
        let plan = BackendSessionSwitchCoordinator.plan(sessionID: "restored", meta: S5SwitchFixture.meta("restored"), saved: try S5SwitchFixture.saved(),
                                                        target: S5SwitchFixture.profile(), decision: decision, occupied: false, sharedStore: true)
        #expect(BackendSessionSwitchCoordinator.conversationToCarry(plan: plan, agentSessionID: named, readableInTarget: true) == Self.restored)
    }
    // TS subject: the id this app put on the command line is used as it is.
    @Test func theIdOnTheCommandLineIsTheAnswer() throws {
        let w = try world()
        try transcript(w, Self.newerOther, at: 5_000)
        let tab = F.meta("fresh", cwd: w.cwd, conversation: Self.restored)
        #expect(BackendSessionSwitchCoordinator.onScreenConversation(meta: tab, cwd: w.cwd, configDir: w.config, claimed: []) == Self.restored)
    }
    // TS subject: recovery is asked only for Claude (`meta.provider === 'claude'`).
    @Test func onlyAClaudeTabIsRecovered() throws {
        let w = try world()
        try transcript(w, Self.restored, at: 5_000)
        let tab = F.meta("codex", cwd: w.cwd, provider: "codex")
        #expect(BackendSessionSwitchCoordinator.onScreenConversation(meta: tab, cwd: w.cwd, configDir: w.config, claimed: []) == nil)
    }
    // TS conversation-id.ts rule 3, reached through the switch: two unclaimed conversations moving is no answer.
    @Test func twoUnclaimedConversationsMovingIsNoAnswer() throws {
        let w = try world()
        try transcript(w, Self.restored, at: 2_000)
        try transcript(w, Self.newerOther, at: 3_000)
        let tab = F.meta("restored", cwd: w.cwd)
        #expect(BackendSessionSwitchCoordinator.onScreenConversation(meta: tab, cwd: w.cwd, configDir: w.config, claimed: []) == nil)
    }
}
