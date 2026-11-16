import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Decker's ruling of 12 Nov on first arrival: an agent this Mac does not have yet, arriving after the person
/// confirmed this Mac's set-up from the Cloud in its own window, is created with its PROJECT and SEAT as on the
/// source. Nothing else that could widen it is taken, and every later change to project or seat waits.
@Suite("Cloud lean — first arrival of an agent: its project and seat arrive, nothing else widens")
struct CloudLeanFirstArrivalTests {
    private func may(_ field: String, _ value: NativeRPCValue, first: Bool, local: NativeRPCValue) -> Bool {
        BackendCloudLeanAgents.mayApply(field, cloud: value, local: local, firstArrival: first, defaultProvider: "claude")
    }
    private func waiting(_ side: CloudLeanAgentsTests.Side) async throws -> [String] {
        let listing = try await side.adapter.listing()
        return listing.waiting.map { $0.record + "/" + $0.field }
    }

    /// The one rule (`BackendCloudLeanAgents.mayApply`), branch by branch.
    @Test func theRuleBranchByBranch() throws {
        // What a fresh agent would launch with on this Mac.
        let fresh = try BackendTaskConfiguration.cleanAgent(CloudLeanAgentsTests.agent("reviewer", "Reviewer"), others: [])

        // First arrival: the project and the seat are taken as on the source.
        #expect(may("projectId", .string("deck"), first: true, local: fresh))
        #expect(may("seat", .string("reviewer"), first: true, local: fresh))
        // Without the confirmation in this Mac's window they wait.
        #expect(!may("projectId", .string("deck"), first: false, local: fresh))
        #expect(!may("seat", .string("reviewer"), first: false, local: fresh))

        // Capped at first arrival: nothing else that could widen the agent is taken.
        #expect(!may("permissionMode", .string("bypassPermissions"), first: true, local: fresh), "A wider permission mode waits; the agent is created at this Mac's default")
        #expect(!may("permissionMode", .string("acceptEdits"), first: true, local: fresh))
        #expect(!may("skills", CloudLeanAgentsTests.list(["release-notes"]), first: true, local: fresh), "An added skill waits")
        #expect(!may("provider", .string("codex"), first: true, local: fresh), "Another AI than this Mac's default waits")
        #expect(!may("claudeAgent", .string("inspector"), first: true, local: fresh))
        #expect(!may("keepAliveUntilClose", .bool(true), first: true, local: fresh), "A run limit above this Mac's waits")
        #expect(!may("keepAliveMinutes", .number(600), first: true, local: fresh))
        // What only narrows applies, at first arrival and later.
        #expect(may("blockedTools", CloudLeanAgentsTests.list(["Edit"]), first: true, local: fresh))
        #expect(may("status", .string("paused"), first: true, local: fresh))
        #expect(may("permissionMode", .null, first: true, local: fresh), "The same value applies")

        // An agent this Mac already has: every later change to its project or seat waits; a paused agent stays paused.
        let placed = fresh.setting("seat", .string("reviewer")).setting("projectId", .string("deck"))
        #expect(!may("seat", .string("tester"), first: false, local: placed))
        #expect(!may("projectId", .string("other"), first: false, local: placed))
        #expect(may("seat", .string("reviewer"), first: false, local: placed), "The same seat is no change")
        let paused = fresh.setting("status", .string("paused")).setting("statusAt", .number(1))
        #expect(!may("status", .string("active"), first: false, local: paused), "A paused agent is never switched on from another device")
        #expect(!may("status", .string("active"), first: true, local: paused))
    }

    @Test func aNewAgentArrivesWithItsProjectAndSeatAtThisMacsDefaultModeAndALaterSeatChangeWaits() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock)
        // The new-Mac sheet was answered on B, and the agent's project is already on B.
        let b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock, confirmed: true, projects: { ["deck", PROJProjects.independentID] })
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("reviewer", "Reviewer", [("instructions", .string("Read the diff first.")),
            ("seat", .string("reviewer")), ("projectId", .string("deck")), ("permissionMode", .string("bypassPermissions"))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        // First arrival: created in one step with its project and seat, at this Mac's default permission mode.
        let found = try await b.config.agent("reviewer")
        let arrived = try #require(found)
        #expect(arrived["seat"].string == "reviewer", "Its seat arrives with it")
        #expect(arrived["projectId"].string == "deck", "Its project arrives with it")
        #expect(arrived["instructions"].string == "Read the diff first.")
        #expect(arrived["permissionMode"].string == nil, "It is created at this Mac's default permission mode")
        let first = try await waiting(b)
        #expect(first.contains("agent:reviewer/permissionMode"), "The source's wider mode is listed as waiting: \(first)")
        #expect(!first.contains("agent:reviewer/seat") && !first.contains("agent:reviewer/projectId"))

        // The agent exists here now: a later change to its seat or project on another device waits.
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("reviewer", "Reviewer", [("instructions", .string("Read the diff first.")),
            ("seat", .string("tester")), ("projectId", .string("other")), ("permissionMode", .string("bypassPermissions"))]))
        let later = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        #expect(later.count == 1)
        try await CloudLeanFixture.deliver(later, from: a.mac.device, to: b.adapter)
        let after = try await b.config.agent("reviewer")
        #expect(after?["seat"].string == "reviewer", "A later seat change from another device is not applied")
        #expect(after?["projectId"].string == "deck")
        let second = try await waiting(b)
        #expect(second.contains("agent:reviewer/seat") && second.contains("agent:reviewer/projectId"), "Both are listed as waiting: \(second)")
        let back = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(back.isEmpty, "This Mac never sends its own value over a change it holds back")
    }

    @Test func withoutTheConfirmationInThisMacsWindowANewAgentsProjectAndSeatWait() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock)
        let b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock, confirmed: false)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("reviewer", "Reviewer", [("seat", .string("reviewer")), ("projectId", .string("deck"))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let arrived = try await b.config.agent("reviewer")
        #expect(arrived?["name"].string == "Reviewer", "The agent itself still arrives")
        #expect(arrived?["seat"].string == nil)
        #expect(arrived?["projectId"].string == PROJProjects.independentID)
        let listed = try await waiting(b)
        #expect(listed.contains("agent:reviewer/seat") && listed.contains("agent:reviewer/projectId"), "\(listed)")
    }
}
