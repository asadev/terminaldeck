import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor ReviewStartGate {
    var pause: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    var used = false
    func waitOnce() async {
        guard !used else { return }; used = true
        await withCheckedContinuation { pause = $0; entered?.resume(); entered = nil }
    }
    func waitForEntry() async { if used { return }; await withCheckedContinuation { entered = $0 } }
    func release() { pause?.resume(); pause = nil }
}

private actor ReviewHandoffStarter: BackendRestoreSessionStarting {
    let runtime: BackendF4Runtime
    var live: [BackendSessionMeta] = []
    var attempts = 0
    var failTabs = Set<String>()
    var raceAfterBind = false
    var gate: ReviewStartGate?
    var histories: [String: String] = [:]
    var contents: [String: String] = [:]
    init(_ runtime: BackendF4Runtime) { self.runtime = runtime }
    func fail(_ key: String) { failTabs.insert(key) }
    func race() { raceAfterBind = true }
    func block(_ gate: ReviewStartGate) { self.gate = gate }
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool) async throws -> BackendSessionMeta {
        try await create(input, context: context, holdOnFailure: holdOnFailure, named: nil)
    }
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool, named: String?) async throws -> BackendSessionMeta {
        attempts += 1
        await gate?.waitOnce()
        if failTabs.contains(input.tabKey ?? "") { throw BackendAccountFailure("Fixture launch failed") }
        guard !live.contains(where: { $0.agentSessionId == input.resumeConversationId }) else { throw BackendAccountFailure("A second writer was attempted") }
        let spec = BackendProviderSpec(id: "claude", command: "/never-run", args: [], resumeArgs: ["--resume"])
        let account = try await runtime.adapter.resolve(input, provider: spec, loginPath: "/usr/bin:/bin", context: context)
        var meta = BackendSessionMeta(id: UUID().uuidString, input: input,
            spawn: .init(provider: "claude", command: "/never-run", args: [], path: "/usr/bin", profile: account.profile,
                homeProfileId: account.homeProfileID, agentSessionId: input.resumeConversationId, resumed: input.resume == true, tabKey: input.tabKey))
        if let named { meta.title = named }
        do {
            try await runtime.adapter.bind(account, session: meta)
            let config = try #require(await runtime.adapter.transcriptConfiguration(sessionID: meta.id))
            let id = try #require(input.resumeConversationId)
            let file = URL(fileURLWithPath: config).appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(input.cwd) + "/" + id + ".jsonl")
            contents[input.tabKey ?? ""] = try String(contentsOf: file, encoding: .utf8)
            histories[input.tabKey ?? ""] = config
            try await runtime.state.ledgerNote(meta.id, saved: BackendNativeLedger.savedLaunch(meta, input: input, deviceKey: nil))
        } catch { await runtime.adapter.abandon(account); throw error }
        live.append(meta)
        if raceAfterBind { raceAfterBind = false; throw BackendAccountFailure("configuration changed during launch") }
        return meta
    }
    func liveSessions() async -> [BackendSessionMeta] { live }
}

private struct ReviewConfinement: BackendConfinementLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func resolve(command: String, args: [String], input: BackendCreateSessionInput, account: BackendAccountLaunch, context: BackendLaunchContext) async throws -> BackendConfinedLaunch { .init(command: command, args: args) }
}
private struct ReviewInstructions: BackendInstructionLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, context: BackendLaunchContext) async throws -> [String] { [] }
}
private struct ReviewProjectTools: BackendProjectMCPSource {
    let readiness: BackendLaunchReadiness = .ready
    func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { nil }
}

private func reviewRow(_ cwd: String, key: String, account: String, conversation: String) -> NativeRPCValue {
    .object([.init("cwd", .string(cwd)), .init("tabKey", .string(key)), .init("provider", .string("claude")),
        .init("profileId", .string(account)), .init("agentSessionId", .string(conversation)), .init("lastSeenAt", .number(1_000))])
}
private func writeReviewTranscript(_ config: String, cwd: String, id: String, text: String = "fixture") throws -> String {
    let file = URL(fileURLWithPath: config).appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(cwd) + "/" + id + ".jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
    return file.path
}
private func reviewCoordinator(_ runtime: BackendF4Runtime, rows: [NativeRPCValue], starter: ReviewHandoffStarter) async throws -> (BackendSessionRestoreCoordinator, BackendSessionRestorePlanner, BackendSessionRestoreContext) {
    try await runtime.state.setOpenSessions(rows)
    try await runtime.state.startSessionLedger()
    let context = BackendSessionRestoreContext(readiness: .ready) { device, cwd in .init(deviceKey: device, folder: cwd) }
    let planner = BackendSessionRestorePlanner(profiles: await runtime.profiles, providers: BackendFoundationTestsS5SessionsResolver(), context: context)
    let coordinator = BackendSessionRestoreCoordinator(starter: starter, planner: planner, store: runtime.state, context: context, excludedAppWorkingDirectories: [], emit: { _ in })
    return (coordinator, planner, context)
}
private func withReviewRuntime(_ body: (BackendF4Runtime) async throws -> Void) async throws {
    let runtime = try await BackendF4Runtime.wire()
    do { try await body(runtime); await runtime.dispose(removeRoot: true) }
    catch { await runtime.dispose(removeRoot: true); throw error }
}
private func withReviewRPC(_ runtime: BackendF4Runtime, restore: BackendSessionRestoreCoordinator, planner: BackendSessionRestorePlanner,
                           body: (BackendSessionLifecycleRPC) async throws -> Void) async throws {
    let manager = BackendPTYManager(inheritedEnvironment: [:]) { _ in }
    let ledger = try await BackendNativeLedger.activate(store: runtime.state)
    let providers = BackendFoundationTestsS5SessionsResolver()
    let launcher = BackendSessionLauncher(manager: manager, dependencies: try .init(providers: providers, accounts: runtime.adapter,
        confinement: ReviewConfinement(), instructions: ReviewInstructions(), ledger: ledger))
    let endpoint = BackendTestMCPEndpoint(readiness: .ready, description: { nil }, catalogue: { [] },
        register: { _, _ in throw BackendAccountFailure("No tool launch in this fixture") }, bind: { _, _, _ in }, revoke: { _ in })
    let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: providers,
        sessionTools: try .init(endpoint: endpoint, userData: runtime.configuration.dataDirectory),
        projectTools: try .init(source: ReviewProjectTools(), userData: runtime.configuration.dataDirectory, inheritedEnvironment: [:]),
        reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
    let attribution = BackendAccountAttribution(configuration: runtime.configuration, profiles: await runtime.profiles)
    let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch, accounts: runtime.adapter, attribution: attribution,
        ledger: ledger, store: runtime.state, cleanup: .init(readiness: .ready, release: { _ in }), emit: { _ in })
    let switches = try await BackendSessionSwitchCoordinator.start(lifecycle: lifecycle, accounts: runtime.adapter, attribution: attribution,
        planner: planner, store: runtime.state, apiCredentialAvailable: { _ in false }, emit: { _ in })
    let deferred = await BackendSessionSwitchDeferred.start(lifecycle: lifecycle, switches: switches, emit: { _ in })
    let rpc = BackendSessionLifecycleRPC(lifecycle: lifecycle, switches: switches, restore: restore, deferred: deferred,
        store: runtime.state, authorizeMutation: { _ in })
    do { try await body(rpc); await deferred.stop(); await switches.stop() }
    catch { await deferred.stop(); await switches.stop(); throw error }
}

@Suite("Restart 1112 review: identity, accounts, Retry and duplicate tabs")
struct Restart1112ReviewRestoreTests {
    @Test func item1UnrelatedMemoryCannotResumeAndTheSavedTabStaysHeld() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("hint-owner")
            let row = reviewRow(cwd, key: "mine", account: "system", conversation: "missing")
            let config = world.fixture.configuration.systemDirectory("claude")
            let transcript = try writeReviewTranscript(config, cwd: cwd, id: "other-chat")
            let folder = DeckMemorySessionHook.root(dataRoot: world.fixture.configuration.dataDirectory).appendingPathComponent("sessions/other-session")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let record: [String: Any] = ["provider": "claude", "conversationID": "other-chat", "transcriptPath": transcript,
                "tabKey": "not-mine", "historyOwnerID": "system", "lastTurnAt": 999]
            try JSONSerialization.data(withJSONObject: record).write(to: folder.appendingPathComponent("state.json"))
            let run = try await Restore1110Run(world, rows: [row], stamps: ["mine": 1_000],
                hint: BackendRestoreConversationHint.make(dataRoot: world.fixture.configuration.dataDirectory))
            _ = try await run.coordinator.restore()
            #expect(await run.starter.inputs.isEmpty)
            let held = try #require(try await run.store.heldSessions().first)
            #expect(held.pick && held.wireValue["recoveryAction"].string == "choose-conversation")
            #expect(held.saved["agentSessionId"].string == "missing")
            #expect((await run.store.getOpenSessions()).contains { $0["tabKey"].string == "mine" })
            var linked = record; linked["tabKey"] = "mine"; linked["historyOwnerID"] = "another-owner"
            try JSONSerialization.data(withJSONObject: linked).write(to: folder.appendingPathComponent("state.json"))
            let saved = try BackendSessionSaved(row)
            #expect(BackendRestoreConversationHint.best(in: folder.deletingLastPathComponent(), for: saved, claimed: [], configDirectory: config) == nil)
            linked["historyOwnerID"] = "system"
            try JSONSerialization.data(withJSONObject: linked).write(to: folder.appendingPathComponent("state.json"))
            #expect(BackendRestoreConversationHint.best(in: folder.deletingLastPathComponent(), for: saved, claimed: [], configDirectory: config)?.conversationID == "other-chat")
            #expect(BackendRestoreConversationHint.best(in: folder.deletingLastPathComponent(), for: saved, claimed: [], configDirectory: world.fixture.root.path) == nil)
        }
    }

    @Test func round2NoIDUsesOnlyALinkedHintInItsResolvedHistory() async throws {
        for absent in [NativeRPCValue.missing, .string("")] {
            try await BackendFoundationTestsS5SessionsWithWorld { world in
                let cwd = try world.folder("no-id")
                let row = reviewRow(cwd, key: "mine", account: "system", conversation: "").setting("agentSessionId", absent)
                let config = world.fixture.configuration.systemDirectory("claude")
                let transcript = try writeReviewTranscript(config, cwd: cwd, id: "linked-chat")
                let folder = DeckMemorySessionHook.root(dataRoot: world.fixture.configuration.dataDirectory).appendingPathComponent("sessions/record")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for proven in [false, true] {
                    let record: [String: Any] = ["provider": "claude", "conversationID": "linked-chat", "transcriptPath": transcript,
                        "tabKey": proven ? "mine" : "another-tab", "historyOwnerID": "system", "lastTurnAt": 999]
                    try JSONSerialization.data(withJSONObject: record).write(to: folder.appendingPathComponent("state.json"))
                    let run = try await Restore1110Run(world, rows: [row], stamps: ["mine": 1_000], hint: BackendRestoreConversationHint.make(dataRoot: world.fixture.configuration.dataDirectory))
                    let result = try await run.coordinator.restore()
                    if proven {
                        #expect(await run.starter.inputs.first?.resumeConversationId == "linked-chat")
                        #expect(try await run.store.heldSessions().isEmpty)
                    } else {
                        #expect(await run.starter.inputs.isEmpty)
                        #expect(result.decisions.first?.configDirectory == config)
                        let held = try #require(try await run.store.heldSessions().first)
                        #expect(held.pick && held.recoveryAction == "choose-conversation")
                        #expect((await run.store.getOpenSessions()).contains { $0["tabKey"].string == "mine" })
                    }
                }
                let other = reviewRow(cwd, key: "writer", account: "system", conversation: "linked-chat")
                let claimed = try await Restore1110Run(world, rows: [other, row], stamps: ["writer": 1_000, "mine": 1_000], hint: BackendRestoreConversationHint.make(dataRoot: world.fixture.configuration.dataDirectory))
                _ = try await claimed.coordinator.restore()
                #expect(await claimed.starter.inputs.count == 1)
                #expect(try await claimed.store.heldSessions().first?.saved["tabKey"].string == "mine")
            }
        }
    }

    @Test func item2RemovedLoginAndHistoryOwnersStayHeldUntilTheAccountIsAddedAgain() async throws {
        try await withReviewRuntime { runtime in
            let working = try await runtime.create("Working"), removed = try await runtime.create("Removed")
            var rows: [NativeRPCValue] = []
            for (key, owner) in [("login-gone", false), ("history-gone", true)] {
                let cwd = runtime.root.appendingPathComponent(key).path
                try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
                _ = try writeReviewTranscript(removed.configDir, cwd: cwd, id: key, text: key)
                var row = reviewRow(cwd, key: key, account: owner ? working.id : removed.id, conversation: key)
                if owner { row = row.setting("homeProfileId", .string(removed.id)) }
                rows.append(row)
            }
            _ = try await runtime.profiles.removeMetadata(id: removed.id)
            await runtime.profiles.setDefaultLoginResolver { _, _, _ in working }
            let starter = ReviewHandoffStarter(runtime)
            let (restore, planner, _) = try await reviewCoordinator(runtime, rows: rows, starter: starter)
            _ = try await restore.restore()
            let held = try await runtime.state.heldSessions()
            #expect(held.count == 2 && held.allSatisfy { $0.reason.contains("Settings › Coding AIs") && $0.reason.contains("then press Retry") && !$0.pick })
            #expect(await starter.attempts == 0)
            #expect(Set((await runtime.state.getOpenSessions()).compactMap { $0["tabKey"].string }) == ["login-gone", "history-gone"])
            let implicit = try BackendSessionSaved(rows[0].removing("profileId"))
            #expect(try await planner.accountFolder(implicit).id == working.id)
            try await withReviewRPC(runtime, restore: restore, planner: planner) { rpc in
                for tab in held {
                    _ = try await rpc.invoke("session:held-retry", args: [.string(tab.key)], context: BackendF4Runtime.context)
                }
                #expect(await starter.attempts == 0)
                await #expect(throws: (any Error).self) {
                    _ = try await rpc.invoke("session:held-retry", args: [.string(held[0].key), .object([.init("profileId", .string(working.id))])], context: BackendF4Runtime.context)
                }
                let readded = try await runtime.create("Removed")
                #expect(readded.id == removed.id)
                for tab in held {
                    _ = try await rpc.invoke("session:held-retry", args: [.string(tab.key)], context: BackendF4Runtime.context)
                }
                #expect(await starter.attempts == 2)
                #expect(try await runtime.state.heldSessions().isEmpty)
                #expect(await starter.contents["login-gone"] == "login-gone")
                #expect(await starter.contents["history-gone"] == "history-gone")
            }
        }
    }

    @Test func round3RecordedHistoryWinsWhenBothFoldersContainTheConversation() async throws {
        for earlier in [false, true] {
            try await withReviewRuntime { runtime in
                let login = try await runtime.create("Login"), history = try await runtime.create("History")
                _ = try writeReviewTranscript(login.configDir, cwd: runtime.root.path, id: "shared", text: "login copy")
                _ = try writeReviewTranscript(history.configDir, cwd: runtime.root.path, id: "shared", text: "recorded history")
                var row = reviewRow(runtime.root.path, key: "owned", account: login.id, conversation: earlier ? "missing" : "shared")
                    .setting("homeProfileId", .string(history.id))
                if earlier { row = row.setting("knownConversations", .array([.string("shared")])) }
                let starter = ReviewHandoffStarter(runtime)
                let (restore, planner, _) = try await reviewCoordinator(runtime, rows: [row], starter: starter)
                _ = try await restore.restore()
                #expect(await starter.histories["owned"] == history.configDir)
                #expect(await starter.contents["owned"] == "recorded history")
                #expect(await starter.live.first?.homeProfileId == history.id)
                let noID = try BackendSessionSaved(row.removing("agentSessionId").removing("knownConversations"))
                #expect(await planner.corrected(noID).homeProfileID == history.id)
            }
        }
    }

    @Test func round4SameNameAPIAccountGetsANewIDAndCannotReplaceTheHeldAccount() async throws {
        try await withReviewRuntime { runtime in
            let profiles = await runtime.profiles
            let service = BackendAPIAccountService(configuration: runtime.configuration, access: .init(
                find: { id, _ in try await profiles.find(id) }, list: { _ in try await profiles.list() },
                create: { name, provider, folder, _ in try await profiles.create(name: name, provider: provider, configDir: folder, vaultManaged: false) },
                rename: { id, name, _ in try await profiles.rename(id: id, name: name) },
                remove: { id, _ in _ = try await profiles.removeMetadata(id: id); return .object([.init("removed", .bool(true))]) }),
                authorizeMutation: { _ in }, inUse: { _ in .init(sessions: [], starting: false) })
            let input = NativeRPCValue.object([.init("name", .string("Original API account")), .init("kind", .string("anthropic"))])
            // Real Settings add route: random API id and folder, then the display name is applied.
            // No key is entered, no check is requested, and no provider process is started.
            let first = try await service.invoke("profiles:api:add", args: [input], context: BackendF4Runtime.context)
            let originalID = try #require(first["id"].string)
            let original = try #require(try await profiles.find(originalID))
            _ = try writeReviewTranscript(original.configDir, cwd: runtime.root.path, id: "api-chat", text: "kept conversation")
            let row = reviewRow(runtime.root.path, key: "api-tab", account: originalID, conversation: "api-chat")
            _ = try await profiles.removeMetadata(id: originalID)
            let second = try await service.invoke("profiles:api:add", args: [input], context: BackendF4Runtime.context)
            let replacementID = try #require(second["id"].string)
            #expect(replacementID != originalID)
            let starter = ReviewHandoffStarter(runtime)
            let (restore, planner, _) = try await reviewCoordinator(runtime, rows: [row], starter: starter)
            _ = try await restore.restore()
            let held = try #require(try await runtime.state.heldSessions().first)
            #expect(held.reason.contains("original API account is no longer available"))
            #expect(held.reason.contains("Its conversation is kept"))
            #expect(!held.reason.contains("Add it again") && !held.reason.contains("press Retry"))
            try await withReviewRPC(runtime, restore: restore, planner: planner) { rpc in
                _ = try await rpc.invoke("session:held-retry", args: [.string(held.key)], context: BackendF4Runtime.context)
            }
            #expect(await starter.attempts == 0)
            let kept = try #require(try await runtime.state.heldSessions().first)
            #expect(kept.saved["profileId"].string == originalID && kept.saved["agentSessionId"].string == "api-chat")
            #expect((await runtime.state.getOpenSessions()).contains { $0["profileId"].string == originalID })
            #expect(try String(contentsOfFile: original.configDir + "/projects/" + NativeTranscriptPaths.encodeProjectPath(runtime.root.path) + "/api-chat.jsonl", encoding: .utf8) == "kept conversation")
        }
    }

    @Test func item3SharedRetryUsesCorrectedConversationHistoryAndRaceLookup() async throws {
        try await withReviewRuntime { runtime in
            let account = try await runtime.create("Borrowed")
            await runtime.profiles.setDefaultLoginResolver { _, _, _ in account }
            let system = runtime.configuration.systemDirectory("claude")
            _ = try writeReviewTranscript(system, cwd: runtime.root.path, id: "right-chat", text: "correct history")
            let row = reviewRow(runtime.root.path, key: "retry-tab", account: "system", conversation: "lost-chat")
                .setting("knownConversations", .array([.string("right-chat")])).setting("title", .string("My retained tab"))
            let starter = ReviewHandoffStarter(runtime)
            let (restore, planner, _) = try await reviewCoordinator(runtime, rows: [], starter: starter)
            // Construct the same shared RPC route used by the window and sessions_held before holding the row.
            try await withReviewRPC(runtime, restore: restore, planner: planner) { rpc in
                let held = try await runtime.state.holdSession(row, reason: "Fixture interrupted restore")
                await starter.race()
                let result = try await rpc.invoke("session:held-retry", args: [.string(held.key)], context: BackendF4Runtime.context)
                #expect(result.elements?.isEmpty == true)
                #expect(await starter.attempts == 1)
                let meta = try #require(await starter.live.first)
                #expect(meta.agentSessionId == "right-chat" && meta.homeProfileId == "system" && meta.profileId == account.id)
                #expect(meta.title == "My retained tab")
                #expect(await starter.contents["retry-tab"] == "correct history")
            }
        }
    }

    @Test func item4DuplicateTabsRemainSavedAndFailedLaunchReleasesTheClaim() async throws {
        for firstFails in [false, true] {
            try await withReviewRuntime { runtime in
                let system = runtime.configuration.systemDirectory("claude")
                _ = try writeReviewTranscript(system, cwd: runtime.root.path, id: "shared")
                let rows = [reviewRow(runtime.root.path, key: "first", account: "system", conversation: "shared"),
                            reviewRow(runtime.root.path, key: "second", account: "system", conversation: "shared")]
                let starter = ReviewHandoffStarter(runtime)
                if firstFails { await starter.fail("first") }
                let (restore, _, _) = try await reviewCoordinator(runtime, rows: rows, starter: starter)
                let result = try await restore.restore()
                #expect(result.started.count == 1 && result.dropped.isEmpty)
                #expect(await starter.live.count == 1)
                let held = try #require(try await runtime.state.heldSessions().first)
                #expect(held.saved["tabKey"].string == (firstFails ? "first" : "second"))
                if !firstFails {
                    #expect(held.recoveryAction == "wait-for-conversation" && !held.pick)
                    _ = try await restore.retryHeld(held.key)
                    #expect(await starter.attempts == 1)
                }
                #expect(Set((await runtime.state.getOpenSessions()).compactMap { $0["tabKey"].string }) == ["first", "second"])
            }
        }
    }

    @Test func item4HostedWriterKeepsTheOtherSavedTabHeld() async throws {
        try await withReviewRuntime { runtime in
            let config = runtime.configuration.systemDirectory("claude")
            _ = try writeReviewTranscript(config, cwd: runtime.root.path, id: "shared")
            // Reattaching the hosted tab notes it at today's timestamp. The other shutdown row must also
            // represent this shutdown, rather than 1970, or the unrelated legacy stale-row cleanup removes it.
            let lastSeen = NativeRPCValue.number(Date().timeIntervalSince1970 * 1000)
            let first = reviewRow(runtime.root.path, key: "first", account: "system", conversation: "shared").setting("lastSeenAt", lastSeen)
            let second = reviewRow(runtime.root.path, key: "second", account: "system", conversation: "shared").setting("lastSeenAt", lastSeen)
            let starter = ReviewHandoffStarter(runtime)
            let (restore, _, context) = try await reviewCoordinator(runtime, rows: [first, second], starter: starter)
            let saved = try BackendSessionSaved(first)
            let launchContext = try await context.context(for: saved)
            let live = try await starter.create(saved.input(resume: true), context: launchContext, holdOnFailure: false)
            await restore.setHostedClaims { [live] }
            let result = try await restore.restore()
            #expect(result.started.isEmpty)
            #expect(await starter.attempts == 1)
            #expect(try await runtime.state.heldSessions().map { $0.saved["tabKey"].string } == ["second"])
            #expect(Set((await runtime.state.getOpenSessions()).compactMap { $0["tabKey"].string }) == ["first", "second"])
        }
    }

    @Test func item4OverlappingRetriesReserveOneWriter() async throws {
        try await withReviewRuntime { runtime in
            _ = try writeReviewTranscript(runtime.configuration.systemDirectory("claude"), cwd: runtime.root.path, id: "shared")
            let starter = ReviewHandoffStarter(runtime)
            let (restore, _, _) = try await reviewCoordinator(runtime, rows: [], starter: starter)
            let first = try await runtime.state.holdSession(reviewRow(runtime.root.path, key: "first", account: "system", conversation: "shared"), reason: "fixture")
            let second = try await runtime.state.holdSession(reviewRow(runtime.root.path, key: "second", account: "system", conversation: "shared"), reason: "fixture")
            let gate = ReviewStartGate(); await starter.block(gate)
            let opening = Task { try await restore.retryHeld(first.key) }
            await gate.waitForEntry()
            _ = try await restore.retryHeld(second.key)
            #expect(await starter.attempts == 1)
            await gate.release()
            _ = try await opening.value
            #expect(await starter.live.count == 1)
            #expect(try await runtime.state.heldSessions().map { $0.saved["tabKey"].string } == ["second"])
        }
    }

    @Test func fourTabsResolveTheActualBorrowedLoginAndTheirOwnHistory() async throws {
        try await withReviewRuntime { runtime in
            let account = try await runtime.create("Borrowed")
            await runtime.profiles.setDefaultLoginResolver { _, _, _ in account }
            let system = runtime.configuration.systemDirectory("claude")
            var rows: [NativeRPCValue] = []
            for n in 0..<4 {
                let cwd = runtime.root.appendingPathComponent("project-\(n)").path
                try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
                rows.append(reviewRow(cwd, key: "tab-\(n)", account: n < 2 ? "system" : account.id, conversation: "chat-\(n)"))
                _ = try writeReviewTranscript(n < 2 ? system : account.configDir, cwd: cwd, id: "chat-\(n)", text: "right-\(n)")
                _ = try writeReviewTranscript(n < 2 ? account.configDir : system, cwd: cwd, id: "chat-\(n)", text: "wrong-\(n)")
            }
            let starter = ReviewHandoffStarter(runtime)
            let (restore, _, _) = try await reviewCoordinator(runtime, rows: rows, starter: starter)
            _ = try await restore.restore()
            #expect(await starter.live.count == 4)
            for n in 0..<4 {
                #expect(await starter.contents["tab-\(n)"] == "right-\(n)")
                #expect(await starter.histories["tab-\(n)"] == (n < 2 ? system : account.configDir))
            }
            #expect(await starter.live.allSatisfy { $0.profileId == account.id })
        }
    }
}
