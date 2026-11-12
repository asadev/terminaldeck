import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Restart 1112: saved history never follows a new default login")
struct Restart1112RestoreTests {
    @Test func apiAccountOwnershipIsStillCheckedWhenLocatingSavedHistory() async throws {
        let id = "api-key-" + String(repeating: "a", count: 24)
        let raw = BackendFoundationTestsAccountsObject([("version", .number(1)),
            ("profiles", .array([BackendFoundationTestsAccountsRawProfile(id)]))])
        try await BackendFoundationTestsAccountsWithFixture(raw: raw) { fixture in
            let world = BackendFoundationTestsS5SessionsWorld(fixture)
            let saved = try world.saved(try world.folder("unowned-api"), profile: id)
            do {
                _ = try await world.planner.accountFolder(saved)
                Issue.record("An unowned API folder cannot be used for saved history")
            } catch { #expect(error.localizedDescription.contains("original API account is no longer available")) }
        }
    }

    @Test func systemTabsResumeTheirOwnConversationEvenWhenDefaultBorrowsAnotherLogin() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let account = try await world.fixture.create("Saved login")
            await world.fixture.profiles.setDefaultLoginResolver { _, _, _ in account }
            let system = try #require(try await world.fixture.profiles.find("system"))
            let folders = [try world.folder("imatch"), try world.folder("ipresent"), try world.folder("deck"), try world.folder("crm")]
            var saved: [BackendSessionSaved] = []
            for (index, folder) in folders.enumerated() {
                let id = "conversation-\(index)"
                try world.writeTranscript(config: index < 2 ? system.configDir : account.configDir, cwd: folder, id: id, body: "{\"type\":\"user\"}\n")
                saved.append(try world.saved(folder, profile: index < 2 ? "system" : account.id,
                    extra: [.init("agentSessionId", .string(id)), .init("tabKey", .string("tab-\(index)"))]))
            }
            let plan = await world.planner.plan(saved)
            #expect(plan.map(\.outcome) == [.resume, .resume, .resume, .resume])
            #expect(plan.map(\.configDirectory) == [system.configDir, system.configDir, account.configDir, account.configDir])
            #expect(plan.map { $0.session.input(resume: true).homeProfileId } == ["system", "system", nil, nil])
            #expect(plan.map { $0.session.conversationID } == saved.map(\.conversationID))
            let run = try await Restore1110Run(world, rows: saved.map(\.raw),
                stamps: Dictionary(uniqueKeysWithValues: saved.map { ($0.tabKey!, 1_800_000_000_000) }))
            let restored = try await run.coordinator.restore()
            #expect(restored.started.count == 4)
            #expect(await run.starter.inputs.allSatisfy { $0.resume == true })
            #expect(try await run.store.heldSessions().isEmpty)
        }
    }

    @Test func planningSeventyNineSavedSystemRowsNeverChecksLoginAvailability() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            await world.fixture.profiles.setDefaultLoginResolver { _, _, _ in
                throw BackendAccountFailure("Planning must not check sign-in")
            }
            let cwd = try world.folder("stale")
            let saved = try (0..<79).map { index in
                try world.saved(cwd, profile: "system", extra: [.init("tabKey", .string("saved-\(index)")),
                    .init("agentSessionId", .string("missing-\(index)"))])
            }
            let plan = await world.planner.plan(saved)
            #expect(plan.count == 79)
            #expect(plan.allSatisfy { $0.outcome == .skip && $0.conversation == BackendSessionRestoreDecision.Conversation.none })
        }
    }

    @Test func anExplicitHomeAndNamedAccountKeepTheirExistingHistory() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let account = try await world.fixture.create("Named")
            let saved = try world.saved(try world.folder("named"), profile: account.id,
                extra: [.init("agentSessionId", .string(BackendFoundationTestsS5SessionsWorld.uuid1))])
            try world.writeTranscript(config: account.configDir, cwd: saved.cwd,
                id: BackendFoundationTestsS5SessionsWorld.uuid1, body: "{\"type\":\"user\"}\n")
            let plan = await world.planner.plan([saved])
            #expect(plan.first?.outcome == .resume)
            #expect(plan.first?.session.homeProfileID == nil)
            #expect(plan.first?.configDirectory == account.configDir)
            let oldHome = try BackendSessionSaved(saved.raw.setting("homeProfileId", .string("system")))
            #expect(try await world.planner.accountFolder(oldHome).system == true)
        }
    }
}
