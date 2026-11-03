import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 12 Oct (Asad's red "switch.plan … broker seat" dialog): a session host whose saved-login store was locked
/// when it started kept its broker off for its whole life, so no Claude session it started could switch in place.
/// These prove: the broker comes up by itself once the store opens (and the next launch is seated and switches in
/// place), it stays off quietly while the store is still locked, a session with no seat gets a plain restart offer
/// that resumes the conversation (never the raw refusal), and an older host's refusal is read as the same offer.
final class AccountsSwitchRestartOfferTests: XCTestCase, @unchecked Sendable {
    private static let technical = ["broker", "seat", "switch.plan", "persistent host service", "verified live"]

    // MARK: - The host's broker comes up by itself

    private func fixture() throws -> (URL, BackendAccountConfiguration) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-revive-" + UUID().uuidString)
        for name in ["data", "home", "work"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root.appendingPathComponent("home"),
            appName: "HOST Scratch Revival", appID: "terminaldeck", helperExecutable: root.appendingPathComponent("unused-helper"),
            inheritedEnvironment: ["HOME": root.appendingPathComponent("home").path, "USER": "revival-fixture"])
        return (root, configuration)
    }
    /// Saved logins behind a key that is not there yet: the vault file exists, so the start reads "locked".
    private func lockedService(_ configuration: BackendAccountConfiguration, cipher: RevivalCipher,
                               apiCredentialAvailable: @escaping @Sendable (BackendAPIAccountRecord) -> Bool = { _ in false }) async throws -> BackendHOSTAccountService {
        let vault = configuration.dataDirectory.appendingPathComponent(BackendAccountVault.directoryName)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let blob = try cipher.encryptUnlocked(#"{"version":1,"entries":[]}"#)
        try Data(blob.base64EncodedString().utf8).write(to: vault.appendingPathComponent(BackendAccountVault.fileName))
        return try await BackendHOSTAccountService.start(configuration: configuration, nativeAccountOwnerDisabled: true,
            vaultCipher: cipher, apiCredentialAvailable: apiCredentialAvailable, brokerFactory: { configuration, profiles, vault in
                try await BackendAccountBroker.offline(configuration: configuration, profiles: profiles, vault: vault,
                    runner: { _, _ in .init(code: 44, stdout: "", stderr: "") })
            })
    }
    private func launch(_ owner: BackendHOSTAccountService, manager: BackendPTYManager, cwd: String) async throws -> (BackendHOSTAccountWire, BackendSessionMeta, Int32) {
        let input = BackendCreateSessionInput(cwd: cwd, provider: "claude")
        let provider = BackendProviderSpec(id: "claude", command: "/bin/cat", args: [], resumeArgs: [])
        let wire = try await owner.resolve(input: input, provider: provider, loginPath: "/usr/bin:/bin", scope: nil)
        let account = wire.launch
        let meta = try manager.create(input, spawn: .init(provider: "claude", command: "/bin/cat", args: [], path: account.path,
            env: account.environment, removeEnv: account.removeEnvironment, profile: account.profile, homeProfileId: account.homeProfileID))
        let pid = try XCTUnwrap(manager.pidOf(meta.id))
        try await owner.bind(handle: wire.handle, session: meta, pid: pid)
        return (wire, meta, pid)
    }
    /// The words a person can see (`refusal`, `notice`); `reason` is a code between the host and the app, never shown.
    private func assertPlain(_ value: NativeRPCValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = [value["refusal"].string, value["notice"].string].compactMap { $0 }.joined(separator: " ").lowercased()
        for word in Self.technical { XCTAssertFalse(text.contains(word), "technical word \(word) in \(text)", file: file, line: line) }
    }

    func testLockedAtStartComesUpWhenTheStoreOpensAndTheNextLaunchSwitchesInPlace() async throws {
        let (root, configuration) = try fixture(), cipher = RevivalCipher(locked: true)
        let owner = try await lockedService(configuration, cipher: cipher), broker = await owner.accounts.broker
        let manager = BackendPTYManager(inheritedEnvironment: configuration.inheritedEnvironment, onEvent: { _ in })
        defer { manager.beginShutdown() }
        var active = await broker.isActive(); XCTAssertFalse(active, "the store was locked when the host started")
        let work = try await owner.accounts.profiles.create(name: "Work", provider: "claude", configDir: root.appendingPathComponent("work").path, vaultManaged: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("play"), withIntermediateDirectories: true)
        let play = try await owner.accounts.profiles.create(name: "Play", provider: "claude", configDir: root.appendingPathComponent("play").path, vaultManaged: false)

        // Started while switching was off: no seat, and the plan says so as "no-seat", never a refusal.
        let (first, firstMeta, firstPID) = try await launch(owner, manager: manager, cwd: root.path)
        XCTAssertNil(first.environment[configuration.ticketEnvironment])
        let noSeat = try await owner.switchPlan(sessionID: firstMeta.id, targetID: work.id, live: firstMeta, pid: firstPID, currentPID: { firstPID })
        XCTAssertEqual(noSeat["reason"].string, "no-seat"); XCTAssertEqual(noSeat["mode"].string, "restart")
        XCTAssertTrue(noSeat["refusal"].isNullish); try assertPlain(noSeat)

        // The person allows the login store; the next launch brings the broker up and is seated.
        cipher.setLocked(false); await broker.setRevivalPause(0)
        let (second, secondMeta, secondPID) = try await launch(owner, manager: manager, cwd: root.path)
        active = await broker.isActive(); XCTAssertTrue(active, "the store opened, so the broker came up")
        XCTAssertNotNil(second.environment[configuration.ticketEnvironment])
        XCTAssertEqual(second.environment[configuration.socketEnvironment], broker.socketPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broker.socketPath))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: broker.shimDirectory).appendingPathComponent("security").path))
        let seat = await broker.seatSnapshot(sessionID: secondMeta.id); XCTAssertEqual(seat?.processPID, secondPID)
        let target = seat?.servingAccountID == work.id ? play : work
        let inPlace = try await owner.switchPlan(sessionID: secondMeta.id, targetID: target.id, live: secondMeta, pid: secondPID, currentPID: { secondPID })
        XCTAssertEqual(inPlace["verified"].bool, true); XCTAssertEqual(inPlace["mode"].string, "in-place")
        XCTAssertEqual(inPlace["pid"].number, Double(secondPID))

        manager.beginShutdown(); let drained = await manager.drain(); XCTAssertTrue(drained)
        await owner.exited(sessionID: firstMeta.id); await owner.exited(sessionID: secondMeta.id)
        try await owner.stop(afterProcessDrain: drained)
    }

    func testStillLockedStaysOffQuietlyWithAThrottledRetry() async throws {
        let (root, configuration) = try fixture(), cipher = RevivalCipher(locked: true)
        let owner = try await lockedService(configuration, cipher: cipher), broker = await owner.accounts.broker
        let manager = BackendPTYManager(inheritedEnvironment: configuration.inheritedEnvironment, onEvent: { _ in })
        defer { manager.beginShutdown() }
        // A launch still works (an agent-kept login) and tries once; every try right after it waits its turn.
        let (wire, meta, _) = try await launch(owner, manager: manager, cwd: root.path)
        XCTAssertNil(wire.environment[configuration.ticketEnvironment])
        let reads = cipher.reads
        for _ in 0..<20 { let on = await owner.accounts.reviveVault(); XCTAssertFalse(on) }
        XCTAssertEqual(cipher.reads, reads, "no read at all inside the pause: no prompt storm")
        // With no pause each try is exactly one quiet read, and still off.
        await broker.setRevivalPause(0)
        for _ in 0..<3 { let on = await owner.accounts.reviveVault(); XCTAssertFalse(on) }
        XCTAssertEqual(cipher.reads, reads + 3)
        let active = await broker.isActive(); XCTAssertFalse(active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broker.socketPath))
        // Refusals from the host are plain words.
        let gone = try await owner.switchPlan(sessionID: "nope", targetID: "nobody", live: nil, pid: nil, currentPID: { nil })
        XCTAssertEqual(gone["mode"].string, "refused"); XCTAssertNotNil(gone["refusal"].string); try assertPlain(gone)
        let unknown = try await owner.switchPlan(sessionID: meta.id, targetID: "nobody", live: meta, pid: manager.pidOf(meta.id), currentPID: { nil })
        XCTAssertEqual(unknown["mode"].string, "refused"); try assertPlain(unknown)
        manager.beginShutdown(); let drained = await manager.drain()
        await owner.exited(sessionID: meta.id); try await owner.stop(afterProcessDrain: drained)
    }

    private func apiAccount(_ owner: BackendHOSTAccountService, kind: BackendAPIAccountRecord.Kind = .anthropic) async throws -> BackendAccountProfile {
        let name = "api-key-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        let home = owner.configuration.accountLoginsRoot.appendingPathComponent(name)
        let profile = try await owner.accounts.profiles.create(name: name, provider: kind.provider, configDir: home.path, vaultManaged: false)
        let local = kind == .compatibleLocal
        let record = try BackendAPIAccountRecord(profile: profile, appName: owner.configuration.appName, kind: kind,
            baseURL: local ? "http://127.0.0.1:11434/v1" : nil, model: local ? "fixture-model" : nil)
        try record.save()
        return profile
    }

    func testAPIAccountOfferDoesNotOpenTheLockedSubscriptionVault() async throws {
        let (_, configuration) = try fixture(), cipher = RevivalCipher(locked: true), checks = BackendF4Box(0)
        let owner = try await lockedService(configuration, cipher: cipher, apiCredentialAvailable: { _ in checks.update { $0 += 1 }; return true })
        let target = try await apiAccount(owner)
        let before = cipher.reads
        let live = S5SwitchFixture.meta("api-plan", profileId: "system", profileName: "Default")
        let value = try await owner.switchPlan(sessionID: live.id, targetID: target.id, live: live, pid: 123, currentPID: { 123 })
        XCTAssertEqual(value["reason"].string, "no-seat"); XCTAssertEqual(value["mode"].string, "restart")
        XCTAssertFalse(value["verified"].bool ?? true); XCTAssertTrue(value["refusal"].isNullish)
        XCTAssertEqual(checks.value, 1); XCTAssertEqual(cipher.reads, before)
        let active = await owner.accounts.broker.isActive(); XCTAssertFalse(active)
        try assertPlain(value)
        try await owner.stop(afterProcessDrain: true)
    }

    func testAPIAccountTargetCannotUseAnExistingSubscriptionBrokerSeat() async throws {
        let (root, configuration) = try fixture(), cipher = RevivalCipher(locked: true)
        let owner = try await lockedService(configuration, cipher: cipher, apiCredentialAvailable: { _ in true })
        let target = try await apiAccount(owner), broker = await owner.accounts.broker
        cipher.setLocked(false); await broker.setRevivalPause(0)
        let manager = BackendPTYManager(inheritedEnvironment: configuration.inheritedEnvironment, onEvent: { _ in })
        defer { manager.beginShutdown() }
        let (_, live, pid) = try await launch(owner, manager: manager, cwd: root.path)
        let before = await broker.seatSnapshot(sessionID: live.id)
        XCTAssertNotNil(before)
        let value = try await owner.switchPlan(sessionID: live.id, targetID: target.id, live: live, pid: pid, currentPID: { pid })
        XCTAssertEqual(value["reason"].string, "no-seat"); XCTAssertFalse(value["verified"].bool ?? true)
        let after = await broker.seatSnapshot(sessionID: live.id)
        XCTAssertEqual(after?.servingAccountID, before?.servingAccountID)
        XCTAssertEqual(after?.processPID, pid)
        // The reverse direction also offers the normal replacement path without inventing a seat.
        var apiLive = live; apiLive.profileId = target.id
        let back = try await owner.switchPlan(sessionID: live.id, targetID: BackendAccountProfile.systemID("claude"), live: apiLive, pid: pid, currentPID: { pid })
        XCTAssertEqual(back["reason"].string, "no-seat"); XCTAssertFalse(back["verified"].bool ?? true)
        manager.beginShutdown(); let drained = await manager.drain()
        await owner.exited(sessionID: live.id); try await owner.stop(afterProcessDrain: drained)
    }

    func testMissingAPIKeyIsRefusedBeforeAnySwitchOfferOrVaultRead() async throws {
        let (_, configuration) = try fixture(), cipher = RevivalCipher(locked: true)
        let owner = try await lockedService(configuration, cipher: cipher)
        let target = try await apiAccount(owner), before = cipher.reads
        let live = S5SwitchFixture.meta("api-missing", profileId: "system")
        let value = try await owner.switchPlan(sessionID: live.id, targetID: target.id, live: live, pid: 123, currentPID: { 123 })
        XCTAssertEqual(value["mode"].string, "refused"); XCTAssertTrue(value["refusal"].string?.contains("API key") == true)
        XCTAssertEqual(cipher.reads, before)
        try assertPlain(value)
        try await owner.stop(afterProcessDrain: true)
    }

    func testAPIAvailabilityUsesItsRecordAndSupportsKeylessAccountsWithoutKeychain() async throws {
        let (_, configuration) = try fixture(), cipher = RevivalCipher(locked: true)
        let owner = try await lockedService(configuration, cipher: cipher)
        let api = try await apiAccount(owner), local = try await apiAccount(owner, kind: .compatibleLocal)
        var checks = 0
        XCTAssertNil(BackendSessionSwitchCoordinator.apiTargetRefusal(api, configuration: configuration, credentialAvailable: { _ in checks += 1; return true }))
        XCTAssertNotNil(BackendSessionSwitchCoordinator.apiTargetRefusal(api, configuration: configuration, credentialAvailable: { _ in false }))
        XCTAssertNil(BackendSessionSwitchCoordinator.apiTargetRefusal(local, configuration: configuration, credentialAvailable: { _ in XCTFail("Keyless account must not read Keychain"); return false }))
        XCTAssertEqual(checks, 1)
        let rpc = BackendAccountRPC(accounts: owner.accounts, configuration: configuration, authorizeMutation: { _ in })
        // Read only the keyless provider so snapshot decoration never queries a real key.
        let list = try await rpc.invoke("profiles:list", args: [.string("codex")], context: BackendF4Runtime.context)
        XCTAssertEqual(list["vault"][local.id]["keptBy"].string, "app")
        XCTAssertEqual(list["vault"][local.id]["signedIn"].bool, true)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: api.configDir).appendingPathComponent(BackendAPIAccountRecord.fileName))
        XCTAssertNotNil(BackendSessionSwitchCoordinator.apiTargetRefusal(api, configuration: configuration, credentialAvailable: { _ in XCTFail("Missing record must not read Keychain"); return true }))
        try await owner.stop(afterProcessDrain: true)
    }

    private struct CarryProviders: BackendProviderLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func loginPath() async throws -> String { "/usr/bin:/bin" }
        func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
            .init(id: "claude", command: "/bin/cat", args: [], resumeArgs: ["--continue"])
        }
    }
    func testBothAPISwitchDirectionsKeepTheNamedConversationForTheNormalLauncher() async throws {
        let (root, configuration) = try fixture(), cipher = RevivalCipher(locked: true)
        let owner = try await lockedService(configuration, cipher: cipher)
        try await owner.authority.startSessionLedger()
        let api = try await apiAccount(owner)
        let subscription = try await owner.accounts.profiles.create(name: "Subscription", provider: "claude", configDir: root.appendingPathComponent("work").path, vaultManaged: false)
        let planner = BackendSessionRestorePlanner(accounts: owner.accounts, providers: CarryProviders(),
            context: .init(readiness: .ready, resolveDevice: { _, _ in throw BackendAccountFailure("No devices in this fixture") }))
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        for (index, pair) in [(subscription, api), (api, subscription)].enumerated() {
            let (source, target) = pair, conversation = "conv-api-\(index)"
            let path = URL(fileURLWithPath: source.configDir).appendingPathComponent("projects")
                .appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(root.path)).appendingPathComponent(conversation + ".jsonl")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"type\":\"user\"}\n".utf8).write(to: path)
            var live = BackendFoundationTestsSessionsFixtures.meta("carry-\(index)", cwd: root.path, conversation: conversation)
            live.profileId = source.id; live.profileName = source.name
            let saved = try BackendSessionSaved(.object([.init("cwd", .string(root.path)), .init("provider", .string("claude")),
                .init("profileId", .string(source.id)), .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(1))]))
            let plan = try await BackendSessionSwitchCoordinator.restartPlan(sessionID: live.id, live: live, saved: saved, target: target,
                signedIn: nil, unavailable: nil, manager: manager, planner: planner, sharedHistory: nil, store: owner.authority, carryClaude: true)
            XCTAssertNil(plan.refusal); XCTAssertEqual(plan.mode, .restart)
            XCTAssertEqual(plan.conversation, "carried"); XCTAssertEqual(plan.conversationID, conversation)
            XCTAssertNotNil(plan.claudeCarry)
            let input = saved.input(resume: plan.resume, profileID: target.id, conversationID: plan.conversationID, replaces: live.id)
            XCTAssertEqual(input.profileId, target.id); XCTAssertEqual(input.resumeConversationId, conversation); XCTAssertEqual(input.replaces, live.id)
            XCTAssertTrue(manager.list().isEmpty, "A plan does not launch a process or claim a completed switch")
        }
        try await owner.stop(afterProcessDrain: true)
    }

    func testAPIChatSwitchOffersItsExistingRelaunchWithoutClaimingInPlace() throws {
        let api = S5SwitchFixture.profile("api-key-" + String(repeating: "a", count: 24), name: "API")
        let live = S5SwitchFixture.meta("chat", profileId: "system")
        let chat = try XCTUnwrap(BackendSessionChatSwitch.plan(sessionID: live.id, live: live, saved: Self.chatSaved("claude", profileId: "system"), target: api))
        let offered = BackendSessionSwitchCoordinator.apiReplacementOffer(chat)
        XCTAssertTrue(offered.chat); XCTAssertEqual(offered.mode, .restart)
        XCTAssertEqual(offered.notice, "Switch this session to API? It carries on with the same conversation.")
        let input = BackendSessionChatSwitch.relaunch(saved: try XCTUnwrap(offered.saved), target: api, from: "claude", replacing: live.id).0
        XCTAssertEqual(input.profileId, api.id); XCTAssertEqual(input.tabKey, "tab-1"); XCTAssertEqual(input.replaces, live.id)
    }

    // MARK: - A session with no seat gets the plain restart offer

    private static let work = BackendAccountProfile(id: "work", name: "Work", provider: "claude", configDir: "/cfg/work", system: false,
                                                    color: "", createdAt: 0, lastUsedAt: nil)
    private static func restartPlan(conversation: String = "carried", conversationID: String? = "conv-1") throws -> BackendSessionSwitchPlan {
        BackendSessionSwitchPlan(sessionID: "s1", refusal: nil, from: S5SwitchFixture.profile("home", name: "Home"), to: work, conversation: conversation,
                                 resume: true, conversationID: conversationID, mode: .restart, saved: try S5SwitchFixture.saved(), carried: nil)
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var restarted: [BackendSessionSwitchPlan] = []
        func add(_ plan: BackendSessionSwitchPlan) { lock.withLock { restarted.append(plan) } }
        var plans: [BackendSessionSwitchPlan] { lock.withLock { restarted } }
    }
    private func fallback(refusing: Error, calls: Calls = Calls()) -> BackendSessionSwitchRestartFallback {
        BackendSessionSwitchRestartFallback(inPlacePlan: { _, _ in throw refusing }, inPlacePerform: { _, _, _ in throw refusing },
            restartPlan: { _, _ in try Self.restartPlan() },
            restart: { plan, _ in
                calls.add(plan)
                return BackendSessionSwitchCoordinator.Execution(phase: .replaced, session: S5SwitchFixture.meta("s2", profileId: "work"), requestedAccount: Self.work.identity)
            }, cancel: { _ in }, stop: {})
    }
    private static let olderHost = BackendHOSTFailure.remote("The persistent host service could not complete switch.plan: This session has no verified live Claude broker seat and target account.")

    func testOlderHostRefusalBecomesThePlainRestartOffer() async throws {
        let plan = try await fallback(refusing: Self.olderHost).subject(sessionID: "s1", accountID: "work")
        XCTAssertNil(plan.refusal); XCTAssertEqual(plan.mode, .restart); XCTAssertTrue(plan.resume); XCTAssertEqual(plan.conversationID, "conv-1")
        XCTAssertEqual(plan.notice, "Switch this session to Work? It carries on with the same conversation.")
        try assertPlain(plan.wireValue)
        XCTAssertEqual(plan.wireValue["notice"].string, plan.notice)
    }
    func testNewerHostNoSeatAnswerBecomesTheSameOffer() async throws {
        let plan = try await fallback(refusing: BackendSessionSwitchNoSeat(sessionID: "s1")).subject(sessionID: "s1", accountID: "work")
        XCTAssertNil(plan.refusal); XCTAssertEqual(plan.notice, SwitchAccountRestartOffer.sentence(accountName: "Work", carriesOn: true))
    }
    func testRestartResumesTheSameConversationInTheSameTab() async throws {
        let calls = Calls()
        let done = try await fallback(refusing: Self.olderHost, calls: calls).perform(sessionID: "s1", accountID: "work", note: "")
        XCTAssertEqual(done.phase, .replaced)
        let plan = try XCTUnwrap(calls.plans.first)
        XCTAssertEqual(calls.plans.count, 1); XCTAssertTrue(plan.resume); XCTAssertEqual(plan.conversationID, "conv-1"); XCTAssertEqual(plan.sessionID, "s1")
        // The replacement input resumes that id and replaces this session (same tab).
        let input = try XCTUnwrap(plan.saved).input(resume: plan.resume, profileID: "work", conversationID: plan.conversationID, replaces: "s1")
        XCTAssertEqual(input.resumeConversationId, "conv-1"); XCTAssertEqual(input.replaces, "s1"); XCTAssertEqual(input.profileId, "work")
    }
    func testOtherHostRefusalsAreSaidWithoutTheChannelName() async throws {
        let raw = BackendHOSTFailure.remote("The persistent host service could not complete switch.plan: That account is not a Claude account on this Mac any more. Pick another one.")
        do { _ = try await fallback(refusing: raw).subject(sessionID: "s1", accountID: "work"); XCTFail("A refusal stays a refusal.") }
        catch { XCTAssertEqual(error.localizedDescription, "That account is not a Claude account on this Mac any more. Pick another one.") }
        XCTAssertEqual(BackendSessionSwitchNoSeat.plain(Self.olderHost), SwitchAccountRestartOffer.notReady + " Nothing was changed.")
    }
    func testInPlacePlansAreLeftAlone() async throws {
        let inPlace = BackendSessionSwitchPlan(sessionID: "s1", refusal: nil, from: nil, to: Self.work, conversation: "same", resume: false,
                                               conversationID: nil, mode: .inPlace, saved: nil, carried: nil)
        let switching = BackendSessionSwitchRestartFallback(inPlacePlan: { _, _ in inPlace }, inPlacePerform: { _, _, _ in throw CancellationError() },
            restartPlan: { _, _ in throw BackendSessionFailure.closed }, restart: { _, _ in throw CancellationError() },
            cancel: { _ in }, stop: {})
        let plan = try await switching.subject(sessionID: "s1", accountID: "work")
        XCTAssertEqual(plan.mode, .inPlace); XCTAssertNil(plan.notice)
    }
    func testOfferWordsAndTheWindowRecord() throws {
        XCTAssertTrue(try Self.restartPlan(conversation: "follows").offeringRestart().notice?.hasSuffix("It carries on with the same conversation.") == true)
        XCTAssertTrue(try Self.restartPlan(conversation: "theirs", conversationID: nil).offeringRestart().notice?.contains("new conversation") == true)
        for carries in [true, false] {
            let words = SwitchAccountRestartOffer.sentence(accountName: "sherzod.davlatov@gmail.com", carriesOn: carries).lowercased()
            for word in Self.technical { XCTAssertFalse(words.contains(word)) }
        }
        SwitchAccountRestartOffer.record(.init(sessionID: "s1", accountID: "work", carriesOn: true))
        XCTAssertEqual(SwitchAccountRestartOffer.current?.accountID, "work")
        SwitchAccountRestartOffer.record(nil); XCTAssertNil(SwitchAccountRestartOffer.current)
    }

    /// Asad, 12 Oct (permanent): an account switch is never called a restart where the person can see it. Every
    /// sentence in the switch dialog, its offer and the switch refusals is checked (comments and code names are not).
    func testSwitchWordsNeverSayRestart() throws {
        let visible = [SwitchAccountRestartOffer.confirmLabel, SwitchAccountRestartOffer.busyLabel, SwitchAccountRestartOffer.notReady,
                       SwitchAccountRestartOffer.sentence(accountName: "Work", carriesOn: true), SwitchAccountRestartOffer.sentence(accountName: "Work", carriesOn: false),
                       try Self.restartPlan().offeringRestart().notice ?? "", BackendSessionSwitchNoSeat.plain(Self.olderHost)]
        for text in visible { XCTAssertNil(text.range(of: "restart", options: .caseInsensitive), text) }
        XCTAssertEqual(SwitchAccountRestartOffer.confirmLabel, "Switch")
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = ["TerminalDeckNativeCore/SwitchAccountRestartOffer.swift", "TerminalDeckNative/NativeSwitchAccountConfirm.swift",
                     "TerminalDeckBackend/BackendSessionSwitchRestartFallback.swift", "TerminalDeckBackend/BackendHOSTFrontendResources.swift",
                     "TerminalDeckBackend/BackendHOSTAccountService.swift", "TerminalDeckBackend/BackendHOSTDeferredSwitch.swift",
                     "TerminalDeckBackend/BackendSessionSwitchCoordinator.swift", "TerminalDeckNativeCore/AccountSwitchFlow.swift",
                     "TerminalDeckNative/NativeAccountSwitch.swift", "TerminalDeckBackend/BackendSessionAIHandover.swift"]
        var checked = 0
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for literal in Self.sentenceLiterals(text) {
                checked += 1
                XCTAssertNil(literal.range(of: "restart", options: .caseInsensitive), "\(file): \(literal)")
            }
        }
        XCTAssertGreaterThan(checked, 20, "the guard read the files")
    }
    /// String literals that are sentences (have a space), outside comments. Single-word codes such as the wire
    /// mode "restart" between the app and its host are never shown and are not sentences.
    private static func sentenceLiterals(_ source: String) -> [String] {
        var found: [String] = []
        for line in source.components(separatedBy: "\n") {
            var inString = false, escaped = false, current = "", previous: Character = " "
            for character in line {
                if inString {
                    if escaped { escaped = false; current.append(character); continue }
                    if character == "\\" { escaped = true; continue }
                    if character == "\"" { inString = false; if current.contains(" ") { found.append(current) }; current = ""; continue }
                    current.append(character)
                } else {
                    if character == "/" && previous == "/" { break }
                    if character == "\"" { inString = true }
                    previous = character
                }
            }
        }
        return found
    }

    // MARK: - The chip's switch is the app's own (no page command that can be dropped)

    func testNativeChipReadsThePlanLikeThePageDid() throws {
        let offer: [String: Any] = ["sessionId": "s1", "refusal": NSNull(), "conversation": "carried", "resume": true, "mode": "restart",
                                    "from": ["id": "a", "name": "Alpha"], "to": ["id": "b", "name": "Bravo"],
                                    "notice": "Switch this session to Bravo? It carries on with the same conversation."]
        let plan = try XCTUnwrap(AccountSwitchPlanView.read(offer))
        XCTAssertFalse(plan.switchesWithoutAsking); XCTAssertEqual(plan.toName, "Bravo"); XCTAssertNotNil(plan.notice)
        let inPlace = try XCTUnwrap(AccountSwitchPlanView.read(["sessionId": "s1", "refusal": NSNull(), "conversation": "same", "mode": "in-place"]))
        XCTAssertTrue(inPlace.switchesWithoutAsking, "an in-place switch is made the moment the account is picked")
        let inPlaceNote = AccountSwitchWords.request(inPlace, title: "", from: "a", to: "b", busy: false, problem: "x", canDefer: true).note
        XCTAssertFalse(inPlaceNote.contains("stopped")); XCTAssertTrue(inPlaceNote.hasPrefix("Nothing starts again."))
        XCTAssertNil(AccountSwitchPlanView.read(["sessionId": "s1", "conversation": "same", "mode": "in-place"]), "no refusal field is no answer")
        XCTAssertNil(AccountSwitchPlanView.read(["sessionId": "s1", "refusal": NSNull(), "conversation": "elsewhere"]))
        let refused = try XCTUnwrap(AccountSwitchPlanView.read(["sessionId": "s1", "refusal": "That account is not here.", "conversation": "stays", "mode": "restart"]))
        XCTAssertFalse(refused.switchesWithoutAsking)
        // The dialog: the offer hides "at my next message"; a refusal offers nothing; the words never say restart.
        let asked = AccountSwitchWords.request(plan, title: "Session 2", from: "alpha@x", to: "bravo@x", busy: false, problem: nil, canDefer: true)
        XCTAssertTrue(asked.offersSwitch); XCTAssertFalse(asked.canDefer); XCTAssertEqual(asked.heading, "Switch to bravo@x?")
        XCTAssertNil(asked.note.range(of: "restart", options: .caseInsensitive))
        let normal = AccountSwitchWords.request(try XCTUnwrap(AccountSwitchPlanView.read(["sessionId": "s1", "refusal": NSNull(), "conversation": "theirs", "mode": "restart"])),
                                                title: "", from: "a", to: "b", busy: false, problem: nil, canDefer: true)
        XCTAssertTrue(normal.canDefer); XCTAssertEqual(normal.tag, "their conversation")
        XCTAssertFalse(AccountSwitchWords.request(refused, title: "", from: "a", to: "b", busy: false, problem: nil, canDefer: true).offersSwitch)
        for conversation in AccountSwitchPlanView.conversations {
            XCTAssertNil(AccountSwitchWords.note(conversation, from: "a", to: "b").range(of: "restart", options: .caseInsensitive), conversation)
        }
    }
    /// Asad, 12 Oct: the Switch offer warns in one line only while the session's agent is busy; idle adds nothing,
    /// and an in-place switch (no offer) never warns.
    func testSwitchOfferWarnsOnlyWhileTheAgentIsBusy() {
        XCTAssertEqual(AccountSwitchWords.warning(offer: true, status: "working"), "Its agent is working right now. Switching will stop what it's doing.")
        XCTAssertNotNil(AccountSwitchWords.warning(offer: true, status: "input"), "mid-turn, waiting on a question")
        for idle in ["idle", "waiting", "completed", nil] as [String?] { XCTAssertNil(AccountSwitchWords.warning(offer: true, status: idle), idle ?? "nil") }
        XCTAssertNil(AccountSwitchWords.warning(offer: false, status: "working"), "in place: nothing stops")
        XCTAssertNil(AccountSwitchWords.busyWarning.range(of: "restart", options: .caseInsensitive))
    }
    func testNativeChipSaysFailuresInPlainWords() {
        XCTAssertEqual(AccountSwitchWords.problem("The persistent host service could not complete switch.request: That account is not here."), "That account is not here.")
        XCTAssertEqual(AccountSwitchWords.problem("Error invoking remote method 'session:switch-account': Error: Bravo is not signed in."), "Bravo is not signed in.")
        XCTAssertEqual(AccountSwitchWords.problem("The operation couldn’t be completed. (TerminalDeckNativeCore.EngineWireError error 2.)"),
                       "The account could not be switched just now. Nothing was changed.")
        XCTAssertEqual(AccountSwitchWords.problem("  "), "The account could not be switched just now. Nothing was changed.")
    }

    // MARK: - 13 Oct, Asad's recording: after a switch the chip showed the old account, and re-picking gave the red refusal

    func testChipShowsTheSwitchedToAccountAtOnceUntilItIsProven() throws {
        let meta = S5SwitchFixture.meta("s3", profileId: "system", profileName: "imzapremium@gmail.com")
        let sherzod = BackendAccountIdentity(id: "sherzod-davlatov-gmail-com", name: "sherzod.davlatov@gmail.com")
        let spawn = BackendAccountSessionReading(provider: "claude", configDir: "/Users/x/.claude", profileId: "system",
                                                 profileName: "imzapremium@gmail.com", source: "spawn", email: "imzapremium@gmail.com", reason: nil)
        let shown = BackendSessionLifecycleRPC.account(spawn, meta: meta, pending: sherzod)
        XCTAssertEqual(shown["profileId"].string, sherzod.id); XCTAssertEqual(shown["pending"].bool, true)
        guard case .known(_, _, let profileId, let name, _) = SessionAccountView.decode(shown.foundation) else { return XCTFail("the chip reads it as known") }
        XCTAssertEqual(profileId, sherzod.id); XCTAssertEqual(name, "sherzod.davlatov@gmail.com")
        // Once the record caught up (or with nothing pending) the reading is the session's own.
        XCTAssertEqual(BackendSessionLifecycleRPC.account(spawn, meta: meta, pending: nil)["profileId"].string, "system")
        XCTAssertEqual(BackendSessionLifecycleRPC.current(meta: meta, pending: sherzod), sherzod)
        XCTAssertEqual(BackendSessionLifecycleRPC.current(meta: meta, pending: nil)?.id, "system")
    }
    func testPickingTheAccountItIsOnSaysAlreadyNeverTheRefusalOrTheOffer() throws {
        let meta = S5SwitchFixture.meta("s3", profileId: "system", profileName: "imzapremium@gmail.com")
        let sherzod = BackendAccountIdentity(id: "sherzod-davlatov-gmail-com", name: "sherzod.davlatov@gmail.com")
        let same = try XCTUnwrap(BackendSessionLifecycleRPC.already(meta: meta, pending: sherzod, accountID: sherzod.id))
        XCTAssertTrue(same.already); XCTAssertEqual(same.refusal, "Already on sherzod.davlatov@gmail.com."); XCTAssertNil(same.notice)
        XCTAssertEqual(same.wireValue["already"].bool, true)
        try assertPlain(same.wireValue)
        // Switching back to the account it started on, while the new one is pending, is a real switch.
        XCTAssertNil(BackendSessionLifecycleRPC.already(meta: meta, pending: sherzod, accountID: "system"))
        XCTAssertNotNil(BackendSessionLifecycleRPC.already(meta: meta, pending: nil, accountID: "system"))
        XCTAssertNil(BackendSessionLifecycleRPC.already(meta: S5SwitchFixture.meta("gone", exited: true), pending: nil, accountID: "work"))
        // The app's own chip reads it as "already": a note, no dialog.
        let plan = try XCTUnwrap(AccountSwitchPlanView.read(same.wireValue.foundation))
        XCTAssertTrue(plan.already); XCTAssertFalse(plan.switchesWithoutAsking)
        XCTAssertEqual(AccountSwitchWords.alreadyOn("sherzod.davlatov@gmail.com"), "Already on sherzod.davlatov@gmail.com")
    }

    // MARK: - 13 Oct: another AI takes over the session, with the same conversation

    func testAnotherAIsAccountIsAHandOverPlanWithTheConversation() throws {
        let live = S5SwitchFixture.meta("s1", provider: "claude", profileId: "system", profileName: "imzapremium@gmail.com")
        let codex = S5SwitchFixture.profile("system-codex", name: "app.imatch.ae@gmail.com", provider: "codex", configDir: "/cfg/codex")
        let plan = try XCTUnwrap(BackendSessionAIHandover.plan(sessionID: "s1", live: live, saved: try S5SwitchFixture.saved(), target: codex))
        XCTAssertEqual(plan.conversation, "handover"); XCTAssertEqual(plan.mode, .restart); XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.notice, "Switch this session to app.imatch.ae@gmail.com on Codex? Codex takes over in this tab and carries on with the same conversation.")
        try assertPlain(plan.wireValue)
        XCTAssertNil(BackendSessionAIHandover.plan(sessionID: "s1", live: live, saved: try S5SwitchFixture.saved(), target: Self.work), "same AI: not a hand-over")
        XCTAssertNil(BackendSessionAIHandover.plan(sessionID: "s1", live: S5SwitchFixture.meta("s1", provider: "shell"), saved: try S5SwitchFixture.saved(), target: codex))
        // The app's chip reads it, and says it plainly.
        let view = try XCTUnwrap(AccountSwitchPlanView.read(plan.wireValue.foundation))
        XCTAssertTrue(view.handsOver); XCTAssertEqual(view.toProvider, "codex"); XCTAssertFalse(view.switchesWithoutAsking)
        let asked = AccountSwitchWords.request(view, title: "Session 3", from: "imzapremium@gmail.com", to: "app.imatch.ae@gmail.com", busy: false, problem: nil, canDefer: true)
        XCTAssertTrue(asked.offersSwitch); XCTAssertFalse(asked.canDefer); XCTAssertNil(asked.tag)
        XCTAssertNil(asked.note.range(of: "restart", options: .caseInsensitive))
        XCTAssertNotNil(AccountSwitchWords.warning(offer: view.notice != nil, status: "working"), "busy: the same one-line warning")
        // The tool picks another AI's account for plan and switch, and still prefers the session's own AI on a tie.
        let accounts: [NativeRPCValue] = [.object([.init("id", .string("c1")), .init("name", .string("me@x")), .init("provider", .string("claude"))]),
                                          .object([.init("id", .string("x1")), .init("name", .string("me@x")), .init("provider", .string("codex"))]),
                                          .object([.init("id", .string("x2")), .init("name", .string("pro@x")), .init("provider", .string("codex"))])]
        XCTAssertEqual(try BackendDeckToolsSessionsRules.chooseAccount(accounts, wanted: "pro@x", provider: "claude", crossAI: true)["id"].string, "x2")
        XCTAssertEqual(try BackendDeckToolsSessionsRules.chooseAccount(accounts, wanted: "me@x", provider: "claude", crossAI: true)["id"].string, "c1")
        XCTAssertThrowsError(try BackendDeckToolsSessionsRules.chooseAccount(accounts, wanted: "pro@x", provider: "claude"))
    }
    func testTheNewAIIsGivenTheConversationWordForWordNewestKept() {
        let pieces = [DeckMemoryFlowPiece(role: .user, text: "Read /d/session-handover/t/handover-1.md first: it is this session's conversation so far", at: nil, key: "0"),
                      DeckMemoryFlowPiece(role: .user, text: "Fix the login bug", at: nil, key: "1"),
                      DeckMemoryFlowPiece(role: .assistant, text: "Done: the token was stale.", at: nil, key: "2"),
                      DeckMemoryFlowPiece(role: .tool, text: "ls", at: nil, key: "3")]
        let turns = BackendSessionAIHandover.turns(pieces, ai: "Claude Code", account: "imzapremium@gmail.com")
        XCTAssertEqual(turns.map(\.speaker), ["The person", "Claude Code"], "the app's own hand-over line is not the person's words; tools are left out")
        // Switching back later carries everything, including what happened under the other AI.
        let later = turns + [BackendSessionAIHandover.Turn(speaker: "The person", text: "Now add a test", fromPerson: true, ai: "Codex (pro@x)"),
                             BackendSessionAIHandover.Turn(speaker: "Codex", text: "Added LoginTests.", fromPerson: false, ai: "Codex (pro@x)")]
        let record = BackendSessionAIHandover.render(later)
        XCTAssertTrue(record.contains("## Claude Code (imzapremium@gmail.com)")); XCTAssertTrue(record.contains("## Codex (pro@x)"))
        XCTAssertTrue(record.contains("Codex: Added LoginTests."))
        let message = BackendSessionAIHandover.message(turns: later, from: "Codex", to: "Claude Code", recordPath: "/d/record-2.md")
        XCTAssertTrue(message.hasPrefix(BackendSessionAIHandover.open)); XCTAssertTrue(message.hasSuffix(BackendSessionAIHandover.close + "\n"))
        XCTAssertTrue(message.contains("not from the person")); XCTAssertTrue(message.contains("/d/record-2.md"))
        XCTAssertTrue(message.contains("The person: Fix the login bug")); XCTAssertTrue(message.contains("Codex: Added LoginTests."))
        XCTAssertNil(message.range(of: "restart", options: .caseInsensitive))
        // Over the budget: newest kept, the person's last message whole, the rest pointed at in the record.
        var long: [BackendSessionAIHandover.Turn] = (0..<40).map { BackendSessionAIHandover.Turn(speaker: $0 % 2 == 0 ? "The person" : "Codex", text: "message \($0) " + String(repeating: "x", count: 3_000), fromPerson: $0 % 2 == 0, ai: "Codex") }
        long.append(BackendSessionAIHandover.Turn(speaker: "The person", text: "the last one", fromPerson: true, ai: "Codex"))
        let cut = BackendSessionAIHandover.message(turns: long, from: "Codex", to: "Claude Code", recordPath: "/d/r.md", budget: 10_000)
        XCTAssertTrue(cut.contains("The person: the last one")); XCTAssertFalse(cut.contains("message 0 ")); XCTAssertTrue(cut.contains("are in the full record"))
        XCTAssertTrue(BackendSessionAIHandover.pointer("/d/session-handover/t/handover-9.md").hasPrefix("Read /d/session-handover/"))
        XCTAssertTrue(BackendSessionAIHandover.isPointer(BackendSessionAIHandover.pointer("/d/session-handover/t/handover-9.md")))
    }

    // MARK: - 13 Oct: chat sessions switch the Hoot way (the next turn runs on the new account or AI)

    private static func chatSaved(_ provider: String, profileId: String) throws -> BackendSessionSaved {
        try BackendSessionSaved(.object([.init("cwd", .string("/w/app")), .init("provider", .string(provider)), .init("profileId", .string(profileId)),
            .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(1)), .init("tabKey", .string("tab-1")),
            .init("chat", .bool(true)), .init("model", .string("opus")), .init("title", .string("Release notes"))]))
    }
    func testChatSessionAccountSwitchRelaunchesItsTabAtOnce() throws {
        let live = S5SwitchFixture.meta("c1", provider: "claude", profileId: "system", profileName: "imzapremium@gmail.com")
        let sherzod = S5SwitchFixture.profile("sherzod", name: "sherzod.davlatov@gmail.com", provider: "claude", configDir: "/cfg/s")
        let saved = try Self.chatSaved("claude", profileId: "system")
        let plan = try XCTUnwrap(BackendSessionChatSwitch.plan(sessionID: "c1", live: live, saved: saved, target: sherzod))
        XCTAssertTrue(plan.chat); XCTAssertEqual(plan.mode, .inPlace); XCTAssertNil(plan.refusal); XCTAssertNil(plan.notice)
        XCTAssertEqual(plan.wireValue["chat"].bool, true)
        // The chip switches it at once, like Hoot's own account change (nothing to read first).
        XCTAssertTrue(try XCTUnwrap(AccountSwitchPlanView.read(plan.wireValue.foundation)).switchesWithoutAsking)
        let (input, remembered) = BackendSessionChatSwitch.relaunch(saved: saved, target: sherzod, from: "claude", replacing: "c1")
        XCTAssertEqual(input.profileId, "sherzod"); XCTAssertEqual(input.provider, "claude"); XCTAssertEqual(input.replaces, "c1")
        XCTAssertEqual(input.tabKey, "tab-1"); XCTAssertEqual(input.model, "opus", "the same AI keeps its settings")
        XCTAssertEqual(remembered["chat"].bool, true); XCTAssertEqual(remembered["profileId"].string, "sherzod")
        XCTAssertEqual(saved.title, "Release notes", "its name goes with it (named: on the relaunch)")
        // A terminal session is not routed here.
        XCTAssertNil(BackendSessionChatSwitch.plan(sessionID: "c1", live: live, saved: try S5SwitchFixture.saved(), target: sherzod))
    }
    func testChatSessionClaudeToCodexToClaudeKeepsItsTabAndConversation() throws {
        let claude = S5SwitchFixture.meta("c1", provider: "claude", profileId: "system", profileName: "imzapremium@gmail.com")
        let codex = S5SwitchFixture.profile("system:codex", name: "Default (Codex CLI)", provider: "codex", configDir: "/cfg/codex")
        let first = try Self.chatSaved("claude", profileId: "system")
        let toCodex = try XCTUnwrap(BackendSessionChatSwitch.plan(sessionID: "c1", live: claude, saved: first, target: codex))
        XCTAssertTrue(toCodex.chat); XCTAssertEqual(toCodex.to?.provider, "codex")
        let (codexInput, codexSaved) = BackendSessionChatSwitch.relaunch(saved: first, target: codex, from: "claude", replacing: "c1")
        XCTAssertEqual(codexInput.provider, "codex"); XCTAssertEqual(codexInput.tabKey, "tab-1", "the same tab: the same conversation store")
        XCTAssertNil(codexInput.model, "Claude's own settings are left for Codex's defaults"); XCTAssertNil(codexInput.claudeAgent)
        XCTAssertEqual(codexSaved["provider"].string, "codex"); XCTAssertEqual(codexSaved["chat"].bool, true)
        // And back to Claude: the same tab again, the record is Codex's now.
        let onCodex = S5SwitchFixture.meta("c2", provider: "codex", profileId: "system:codex", profileName: "Default (Codex CLI)")
        let claudeAccount = S5SwitchFixture.profile("system", name: "imzapremium@gmail.com", provider: "claude", configDir: "/Users/x/.claude")
        let second = try BackendSessionSaved(codexSaved)
        let back = try XCTUnwrap(BackendSessionChatSwitch.plan(sessionID: "c2", live: onCodex, saved: second, target: claudeAccount))
        XCTAssertTrue(back.chat)
        let (claudeInput, claudeSaved) = BackendSessionChatSwitch.relaunch(saved: second, target: claudeAccount, from: "codex", replacing: "c2")
        XCTAssertEqual(claudeInput.provider, "claude"); XCTAssertEqual(claudeInput.tabKey, "tab-1"); XCTAssertEqual(claudeInput.replaces, "c2")
        XCTAssertEqual(claudeSaved["provider"].string, "claude"); XCTAssertEqual(claudeSaved["chat"].bool, true)
    }

    func testCrossProviderChatDropsOwnedClaudeDefinitionButSameProviderKeepsIt() throws {
        let raw = try Self.chatSaved("claude", profileId: "system").raw
            .setting("claudeAgent", .string("check-agent"))
            .setting("agentDefinitionsFile", .string("/scratch/agents/check-agent.json"))
        let saved = try BackendSessionSaved(raw)
        let codex = S5SwitchFixture.profile("system:codex", name: "Codex", provider: "codex", configDir: "/cfg/codex")
        let (input, remembered) = BackendSessionChatSwitch.relaunch(saved: saved, target: codex, from: "claude", replacing: "c1")
        XCTAssertNil(input.agentDefinitionsFile)
        XCTAssertNil(input.claudeAgent)
        XCTAssertTrue(remembered["agentDefinitionsFile"].isNullish)
        let claude = S5SwitchFixture.profile("other-claude", name: "Claude", provider: "claude", configDir: "/cfg/claude")
        let (same, sameSaved) = BackendSessionChatSwitch.relaunch(saved: saved, target: claude, from: "claude", replacing: "c1")
        XCTAssertEqual(same.agentDefinitionsFile, "/scratch/agents/check-agent.json")
        XCTAssertEqual(same.claudeAgent, "check-agent")
        XCTAssertEqual(sameSaved["agentDefinitionsFile"].string, same.agentDefinitionsFile)
    }

    // MARK: - The conversation comes along where the two accounts keep separate histories

    /// 18 Oct (#431): an older start at the target is replaced, a newer copy there stays, and a copy that went another
    /// way is kept beside it once per conversation; switching back and forth never piles up full spare copies.
    func testClaudeConversationIsCopiedIntoTheTargetHistoryWithoutLosingOrPilingUpCopies() throws {
        let (root, _) = try fixture()
        let cwd = root.appendingPathComponent("project").path, from = root.appendingPathComponent("home-cfg").path, to = root.appendingPathComponent("work-cfg").path
        let folder = NativeTranscriptPaths.encodeProjectPath(NativeTranscriptPaths.projectSpellings(cwd)[0])
        let source = URL(fileURLWithPath: from).appendingPathComponent("projects").appendingPathComponent(folder).appendingPathComponent("conv-1.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"turn\":1}\n{\"turn\":2}\n".utf8).write(to: source)
        XCTAssertNil(BackendSessionSwitchClaudeCarry.find(id: "../x", cwd: cwd, from: from, to: to))
        XCTAssertNil(BackendSessionSwitchClaudeCarry.find(id: "missing", cwd: cwd, from: from, to: to))
        let carry = try XCTUnwrap(BackendSessionSwitchClaudeCarry.find(id: "conv-1", cwd: cwd, from: from, to: to))
        let target = carry.target.deletingLastPathComponent()
        func spares() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0.hasPrefix("conv-1.jsonl.") } }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // An older start of the same conversation: replaced, nothing set aside.
        try Data("{\"turn\":1}\n".utf8).write(to: carry.target)
        try carry.copy()
        XCTAssertEqual(try Data(contentsOf: carry.target), try Data(contentsOf: source)); XCTAssertEqual(try spares(), [])
        // Later turns made under the target account: kept as they are.
        let newer = Data("{\"turn\":1}\n{\"turn\":2}\n{\"turn\":3}\n".utf8)
        try newer.write(to: carry.target); try carry.copy()
        XCTAssertEqual(try Data(contentsOf: carry.target), newer); XCTAssertEqual(try spares(), [])
        // A copy that went another way: kept beside it, once.
        let other = Data("{\"turn\":9}\n".utf8)
        try other.write(to: carry.target); try carry.copy()
        XCTAssertEqual(try Data(contentsOf: carry.target), try Data(contentsOf: source))
        XCTAssertEqual(try spares(), ["conv-1.jsonl.before-switch"])
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("conv-1.jsonl.before-switch")), other)
        // That copy went on and differs again: still one beside it, now the longer one.
        let further = Data("{\"turn\":9}\n{\"turn\":10}\n".utf8)
        try further.write(to: carry.target); try carry.copy()
        XCTAssertEqual(try spares(), ["conv-1.jsonl.before-switch"])
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("conv-1.jsonl.before-switch")), further)
        try carry.copy() // Same bytes: nothing more is set aside.
        XCTAssertEqual(try spares(), ["conv-1.jsonl.before-switch"])
    }

    /// 18 Oct (#428): asking what a switch would do (the account menu, an AI's accountPlan) describes the joined history
    /// but changes nothing on disk; the join is made only when the switch is.
    func testAskingWhatASwitchWouldDoLinksNoHistories() async throws {
        let (root, configuration) = try fixture(), cipher = RevivalCipher(locked: true)
        let owner = try await lockedService(configuration, cipher: cipher)
        try await owner.authority.startSessionLedger()
        let managed = root.appendingPathComponent("managed"), system = root.appendingPathComponent("system")
        let home = try await owner.accounts.profiles.create(name: "Home", provider: "claude", configDir: managed.appendingPathComponent("home").path, vaultManaged: false)
        let work = try await owner.accounts.profiles.create(name: "Work", provider: "claude", configDir: managed.appendingPathComponent("work").path, vaultManaged: false)
        let service = BackendAppSharedProjects(systemConfig: system, managedRoot: URL(fileURLWithPath: home.configDir).deletingLastPathComponent(),
                                               writable: true, changed: {})
        let projects = NativeTranscriptPaths.encodeProjectPath(root.path)
        let conversation = URL(fileURLWithPath: home.configDir).appendingPathComponent("projects").appendingPathComponent(projects).appendingPathComponent("conv-home.jsonl")
        try FileManager.default.createDirectory(at: conversation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"user\"}\n".utf8).write(to: conversation)
        let planner = BackendSessionRestorePlanner(accounts: owner.accounts, providers: CarryProviders(),
            context: .init(readiness: .ready, resolveDevice: { _, _ in throw BackendAccountFailure("No devices in this fixture") }))
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        var live = BackendFoundationTestsSessionsFixtures.meta("plan-only", cwd: root.path, conversation: "conv-home")
        live.profileId = home.id; live.profileName = home.name
        let saved = try BackendSessionSaved(.object([.init("cwd", .string(root.path)), .init("provider", .string("claude")),
            .init("profileId", .string(home.id)), .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(1))]))
        let plan = try await BackendSessionSwitchCoordinator.restartPlan(sessionID: live.id, live: live, saved: saved, target: work,
            signedIn: nil, unavailable: nil, manager: manager, planner: planner, sharedHistory: .projects(service), store: owner.authority)
        XCTAssertNil(plan.refusal); XCTAssertEqual(plan.conversation, "follows"); XCTAssertEqual(plan.conversationID, "conv-home")
        XCTAssertNotNil(plan.historyJoin, "the join waits for the switch")
        let homeProjects = URL(fileURLWithPath: home.configDir).appendingPathComponent("projects").path
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: homeProjects), "asking linked nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: work.configDir).appendingPathComponent("projects").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: conversation.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.appendingPathComponent("projects").appendingPathComponent(projects).appendingPathComponent("conv-home.jsonl").path))
        try await owner.stop(afterProcessDrain: true)
    }

    /// 18 Oct (#202): the restart a person was just offered is the one their click runs, planned once; a session that
    /// changed meanwhile is planned again.
    func testTheOfferJustShownIsTheOneTheSwitchRuns() async throws {
        final class Count: @unchecked Sendable { private let lock = NSLock(); private var n = 0; func add() { lock.withLock { n += 1 } }; var value: Int { lock.withLock { n } } }
        final class Print: @unchecked Sendable { private let lock = NSLock(); private var v = "a"; func set(_ s: String) { lock.withLock { v = s } }; var value: String { lock.withLock { v } } }
        let planned = Count(), print = Print()
        let switching = BackendSessionSwitchRestartFallback(inPlacePlan: { _, _ in throw Self.olderHost }, inPlacePerform: { _, _, _ in throw Self.olderHost },
            restartPlan: { _, _ in planned.add(); return try Self.restartPlan() },
            restart: { _, _ in .init(phase: .replaced, session: S5SwitchFixture.meta("s2", profileId: "work"), requestedAccount: Self.work.identity) },
            cancel: { _ in }, stop: {}, fingerprint: { _ in print.value })
        _ = try await switching.subject(sessionID: "s1", accountID: "work")
        _ = try await switching.perform(sessionID: "s1", accountID: "work", note: "")
        XCTAssertEqual(planned.value, 1, "one pick plans once")
        _ = try await switching.subject(sessionID: "s1", accountID: "work")
        print.set("b") // The session changed (another process, account or conversation) after it was shown.
        _ = try await switching.perform(sessionID: "s1", accountID: "work", note: "")
        XCTAssertEqual(planned.value, 3, "a session that changed is planned again")
        var memo = BackendSessionSwitchPlanMemo(), plan = try Self.restartPlan()
        memo.keep(plan, accountID: "work", fingerprint: "f", now: Date(timeIntervalSince1970: 0))
        XCTAssertNil(memo.take(sessionID: "s1", accountID: "other", fingerprint: "f", now: Date(timeIntervalSince1970: 1)), "another account")
        memo.keep(plan, accountID: "work", fingerprint: "f", now: Date(timeIntervalSince1970: 0))
        XCTAssertNil(memo.take(sessionID: "s1", accountID: "work", fingerprint: "f", now: Date(timeIntervalSince1970: 31)), "too old")
        memo.keep(plan, accountID: "work", fingerprint: "f", now: Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(memo.take(sessionID: "s1", accountID: "work", fingerprint: "f", now: Date(timeIntervalSince1970: 1)))
        XCTAssertNil(memo.take(sessionID: "s1", accountID: "work", fingerprint: "f", now: Date(timeIntervalSince1970: 2)), "used once")
        plan = BackendSessionSwitchPlan(sessionID: "s1", refusal: "No.", from: nil, to: Self.work, conversation: "stays", resume: false,
                                        conversationID: nil, mode: .restart, saved: nil, carried: nil)
        memo.keep(plan, accountID: "work", fingerprint: "f")
        XCTAssertNil(memo.take(sessionID: "s1", accountID: "work", fingerprint: "f"), "a refusal is never reused")
    }

    /// 18 Oct (#429): a cancel whose put-back was refused never says the session is back on its old account.
    func testACancelThatCouldNotPutTheOldLoginBackSaysSo() {
        let words = BackendSessionSwitchCoordinator.cancelRefusedMessage(accountName: "Work", why: "The seat is gone.")
        XCTAssertTrue(words.contains("could not be cancelled")); XCTAssertTrue(words.contains("Work")); XCTAssertTrue(words.contains("The seat is gone."))
        XCTAssertFalse(words.contains("still on its previous account"))
    }
}

/// Scratch-only reversible cipher that can be "locked" (the key is not there) and counts every read of it.
private final class RevivalCipher: BackendAccountVaultCipher, @unchecked Sendable {
    private static let prefix = Data("HOST-revival-fixture:".utf8)
    private let lock = NSLock()
    private var isLocked: Bool
    private var count = 0
    init(locked: Bool) { isLocked = locked }
    func setLocked(_ value: Bool) { lock.withLock { isLocked = value } }
    var reads: Int { lock.withLock { count } }
    private func key() throws {
        let locked = lock.withLock { count += 1; return isLocked }
        if locked { throw BackendAccountFailure("macOS could not open the saved login key (scratch).") }
    }
    func encryptUnlocked(_ text: String) throws -> Data { Self.prefix + Data(Data(text.utf8).reversed()) }
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws { try key() }
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { try key(); return Self.prefix + Data(Data(text.utf8).reversed()) }
    func decrypt(_ data: Data) throws -> String {
        try key()
        guard data.starts(with: Self.prefix) else { throw BackendAccountFailure("Invalid scratch ciphertext.") }
        return String(decoding: Data(data.dropFirst(Self.prefix.count).reversed()), as: UTF8.self)
    }
}
