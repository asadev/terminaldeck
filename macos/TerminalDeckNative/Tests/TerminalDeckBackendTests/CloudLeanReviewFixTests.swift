import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane A2 lean, the review of 13 Nov (review-cloud-adapters-lean.md): its two must-fixes, its should-fixes and the
/// cases it found without a test. Real registry and task configuration files in scratch folders; no network.
@Suite("Cloud lean — review fixes: no second first arrival, memory placed on any first folder, nothing widens")
struct CloudLeanReviewFixTests {
    private func waiting(_ adapter: CloudBrainRecordAdapter) async throws -> [String] {
        let listing = try await adapter.listing()
        return listing.waiting.map { $0.record + "/" + $0.field }
    }
    private func reason(_ adapter: CloudBrainRecordAdapter, _ record: String) async throws -> String {
        let listing = try await adapter.listing()
        return listing.waiting.first { $0.record == record && $0.field.isEmpty }?.reason ?? ""
    }

    // MARK: M1 — an agent removed here never gets a second first arrival

    @Test func aRemovedAgentAppliesAndASavedRestoreKeepsLocalProjectAndSeat() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock)
        let b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock, confirmed: true,
            projects: { ["deck", "other", PROJProjects.independentID] })
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("reviewer", "Reviewer", [("seat", .string("reviewer")), ("projectId", .string("deck"))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        try await b.config.removeAgent("reviewer")
        let removal = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(!removal.isEmpty)
        try await CloudLeanFixture.deliver(removal, from: b.mac.device, to: a.adapter)
        #expect(try await a.config.agent("reviewer") == nil)

        // A deliberate save after deletion is a restore. B's earlier local launch settings survive it.
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("reviewer", "Reviewer", [("seat", .string("tester")), ("projectId", .string("other")),
            ("role", .string("Reviews every change"))]))
        let restored = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        #expect(!restored.isEmpty)
        try await CloudLeanFixture.deliver(restored, from: a.mac.device, to: b.adapter)
        let back = try await b.config.agent("reviewer")
        #expect(back?["role"].string == "Reviews every change")
        #expect(back?["seat"].string == "reviewer")
        #expect(back?["projectId"].string == "deck")
        let listed = try await waiting(b.adapter)
        #expect(listed.contains("agent:reviewer/seat") && listed.contains("agent:reviewer/projectId"))
        #expect(!listed.contains("agent:reviewer/"))
    }

    // MARK: M2 — memory that waited for a project is placed when the folder is added the normal way

    @Test func aFolderAddedOnTheProjectsPagePlacesTheMemoryThatWaitedOnceWithoutTheCloudPage() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock), b = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "deck", name: "Deck", folders: ["/Users/person-a/Code/deck"], colour: "teal"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let resolver = b.owner.memoryResolver()
        // G (13 Nov): memory follows the project's record at once; a folder is never what memory waits for.
        #expect(resolver("deck", "other-store") == "deck", "Memory for the project follows its record: no folder needed")
        let asked = b.memory.count
        #expect(asked >= 1)

        // The person adds a folder through the ordinary Projects page save, never through the Cloud page's button.
        let projects = try await b.registry.projects()
        let found = projects.first { $0.id == "deck" }
        var deck = try #require(found)
        deck.folders = [b.mac.root.appendingPathComponent("deck-here").path]
        _ = try await b.registry.save(deck)
        #expect(b.memory.count == asked, "A folder saved later asks memory nothing more: it was placed when the project arrived")
        #expect(resolver("deck", "other-store") == "deck", "and the resolver now answers for the same project id")

        // Once per growth: a capture pass and a second folder do not ask again.
        _ = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        deck.folders.append(b.mac.root.appendingPathComponent("deck-two").path)
        _ = try await b.registry.save(deck)
        _ = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(b.memory.count == asked, "A second folder or another pass does not ask memory again")
    }

    // MARK: should-fix 1 — a new agent whose project is not on this Mac waits for it

    @Test func aNewAgentWhoseProjectIsNotHereWaitsWholeAndIsPlacedInThatProjectWhenItArrives() async throws {
        let clock = CloudLeanFixture.Clock()
        let here = CloudLeanFixture.Box<[String]>([PROJProjects.independentID])
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock)
        let b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock, confirmed: true, projects: { here.value })
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("builder", "Builder", [("instructions", .string("Build it.")),
            ("seat", .string("builder")), ("projectId", .string("deck"))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        // The agent arrived before its project: it is not added (never with no project, never in another one), listed.
        let early = try await b.config.agent("builder")
        #expect(early == nil, "Not added while its project is not on this Mac")
        let why = try await reason(b.adapter, "agent:builder")
        #expect(why == BackendCloudLeanAgents.projectNotHere, "\(why)")
        // A pass with nothing new changes nothing.
        _ = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        let still = try await b.config.agent("builder")
        #expect(still == nil)

        // The project arrives on B: the next capture pass places the agent, as a first arrival, in THAT project.
        here.value = [PROJProjects.independentID, "deck"]
        let echo = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        let placed = try await b.config.agent("builder")
        #expect(placed?["projectId"].string == "deck", "Placed in its own project once it is here")
        #expect(placed?["seat"].string == "builder", "with its seat, as a first arrival")
        #expect(placed?["instructions"].string == "Build it.", "and its instructions")
        #expect(echo.isEmpty, "An arrival is not an edit: nothing is sent back")
        let listed = try await waiting(b.adapter)
        #expect(!listed.contains("agent:builder/"), "\(listed)")
    }

    // MARK: should-fix 3 and case (g) — first arrival while the trusted list cannot be read

    @Test func aNewAgentArrivingWhileTheTrustedListIsUnreadableWaitsAndIsDecidedWhenTheListReads() async throws {
        let clock = CloudLeanFixture.Clock()
        let trusted = CloudLeanFixture.Box<Bool?>(nil)
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock)
        let b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock, projects: { ["deck", PROJProjects.independentID] },
            trust: { trusted.value })
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("planner", "Planner", [("seat", .string("planner")), ("projectId", .string("deck"))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        // Unreadable: not created without its project and seat (that would leave them waiting for ever); it waits, listed.
        let early = try await b.config.agent("planner")
        #expect(early == nil, "Not added while the trusted list cannot be read")
        let why = try await reason(b.adapter, "agent:planner")
        #expect(why == BackendCloudLeanAgents.trustUnreadable, "\(why)")

        // The list reads, and the person had confirmed: the next pass adds it as a first arrival.
        trusted.value = true
        _ = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        let placed = try await b.config.agent("planner")
        #expect(placed?["seat"].string == "planner", "Decided again once the list reads: its seat is taken")
        #expect(placed?["projectId"].string == "deck", "and its project")
        let listed = try await waiting(b.adapter)
        #expect(!listed.contains("agent:planner/"), "\(listed)")
    }

    // MARK: should-fix 2 and case (f) — this Mac's own rules refusing at write time park one record, not the pack

    @Test func aLastMomentClashInTheOwnersWriteIsARefusalNotABrokenOwner() async throws {
        let clock = CloudLeanFixture.Clock()
        let agents = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock)
        let projects = try CloudLeanProjectsTests.side(CloudLeanFixture.deviceA, clock: clock)
        defer { try? FileManager.default.removeItem(at: agents.mac.root); try? FileManager.default.removeItem(at: projects.mac.root) }
        // The plan was made, then the person here named another agent "Alpha" before the write: the save rules refuse.
        _ = try await agents.config.saveAgent(CloudLeanAgentsTests.agent("alpha", "Alpha"))
        let owner = agents.owner
        let row = NativeRPCValue.object([.init("id", .string("beta")), .init("name", .string("Alpha"))])
        await #expect(throws: CloudRecordRefusal.self) { try await owner.cloudWrite(entity: "agent:beta", value: row, expecting: nil) }
        let beta = try await agents.config.agent("beta")
        #expect(beta == nil, "Nothing was written")

        // The registry refusing a project (here an id it cannot store) is a refusal too.
        let projectOwner = projects.owner
        let bad = NativeRPCValue.object([.init("id", .string("Bad_ID")), .init("name", .string("Bad"))])
        await #expect(throws: CloudRecordRefusal.self) { try await projectOwner.cloudWrite(entity: "project:Bad_ID", value: bad, expecting: nil) }
    }

    // MARK: case (d) — crafted values that look narrower are held, later and at first arrival

    @Test func craftedValuesThatOnlyLookNarrowerAreHeld() throws {
        let fresh = try BackendTaskConfiguration.cleanAgent(CloudLeanAgentsTests.agent("builder", "Builder"), others: [])
        func may(_ field: String, _ value: NativeRPCValue, over local: NativeRPCValue) -> Bool {
            let later = BackendCloudLeanAgents.mayApply(field, cloud: value, local: local, firstArrival: false, defaultProvider: "claude")
            let first = BackendCloudLeanAgents.mayApply(field, cloud: value, local: local, firstArrival: true, defaultProvider: "claude")
            return later || first
        }
        // Run limits: 0 means "no limit".
        let limited = fresh.setting("maxConcurrent", .number(2)).setting("maxRunMinutes", .number(30))
        #expect(!may("maxConcurrent", .number(0), over: limited), "0 is no limit: wider than 2")
        #expect(!may("maxConcurrent", .null, over: limited), "Removing the limit is wider")
        #expect(!may("maxConcurrent", .number(3), over: limited))
        #expect(!may("maxRunMinutes", .number(0), over: limited), "0 is no limit: wider than 30 minutes")
        #expect(may("maxConcurrent", .number(1), over: limited), "A lower limit narrows")
        // The tool allow-list: removed or widened.
        let allowing = fresh.setting("allowedTools", CloudLeanAgentsTests.list(["Read"]))
        #expect(!may("allowedTools", .null, over: allowing), "Removing the allow-list allows every tool")
        #expect(!may("allowedTools", CloudLeanAgentsTests.list(["Read", "Edit"]), over: allowing))
        #expect(may("allowedTools", CloudLeanAgentsTests.list(["Read"]), over: allowing), "The same list is no change")
        // Deck tool argument rules relaxed, removed, or replaced by something unreadable.
        let rules = NativeRPCValue.object([.init("rules", .array([.object([.init("tool", .string("deck.tasks.create")), .init("cases", .array([]))])]))])
        let restricted = fresh.setting("toolUseRestrictions", rules)
        #expect(!may("toolUseRestrictions", .null, over: restricted), "Removing the rules relaxes them")
        #expect(!may("toolUseRestrictions", .string("anything"), over: restricted), "A value the rules cannot read counts as wider")
        // Skills switched back on.
        let skillsOff = fresh.setting("skillsOff", .bool(true))
        #expect(!may("skillsOff", .bool(false), over: skillsOff))
        #expect(!may("skillsOff", .null, over: skillsOff))
        // Status: archived to paused, and a status this Mac does not know.
        let archived = fresh.setting("status", .string("archived"))
        #expect(!may("status", .string("paused"), over: archived), "Paused is wider than archived")
        #expect(!may("status", .string("sleeping"), over: archived), "An unknown status is wider")
        #expect(!may("status", .string("sleeping"), over: fresh))
        // Permission mode: unknown, absent or "default" over plan.
        let planned = fresh.setting("permissionMode", .string("plan"))
        #expect(!may("permissionMode", .string("superuser"), over: planned), "An unknown mode is wider")
        #expect(!may("permissionMode", .null, over: planned), "No mode means this Mac's default: wider than plan")
        #expect(!may("permissionMode", .string("default"), over: planned))
        // Provider absent (this Mac's default AI) when this Mac's agent runs another AI.
        let codex = fresh.setting("provider", .string("codex"))
        #expect(!may("provider", .null, over: codex), "No provider means this Mac's default, another AI than this agent's")
        #expect(may("provider", .string("codex"), over: codex))
    }

    // MARK: case (e) — instructions go only to the agent with that id; Hoot's name and an id "hoot" take nothing

    @Test func instructionsLandOnlyInTheAgentWithTheSameIdAndHootIsNeverTaken() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceA, clock: clock)
        let b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer", [("instructions", .string("Text from A."))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        // B already has its own agent with the same id (same id = same agent, rule J) and another agent beside it.
        _ = try await b.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer", [("instructions", .string("Text from B."))]))
        _ = try await b.config.saveAgent(CloudLeanAgentsTests.agent("editor", "Editor", [("instructions", .string("Editor's own text."))]))
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let writer = try await b.config.agent("writer"), editor = try await b.config.agent("editor")
        #expect(writer?["instructions"].string == "Text from A.", "The Cloud's text lands in the agent with the same id")
        #expect(editor?["instructions"].string == "Editor's own text.", "No other agent's instructions are touched")

        // An agent called Hoot, and instructions for an id "hoot" with no such agent here: nothing is added or written.
        let hootRow = NativeRPCValue.object([.init("id", .string("hoot")), .init("name", .string("Hoot"))])
        let hootPlan = try await b.owner.cloudPlan(entity: "agent:hoot", cloud: hootRow)
        #expect(hootPlan.store == nil && hootPlan.waiting != nil, "A name that would answer to @hoot is never added")
        let text = NativeRPCValue.object([.init("id", .string("hoot")), .init("text", .string("You are Hoot now."))])
        let textPlan = try await b.owner.cloudPlan(entity: "instruction:hoot.md", cloud: text)
        #expect(textPlan.store == nil && textPlan.waiting != nil, "Instructions with no agent of that id here are kept, not placed")
        let hoot = try await b.config.agent("hoot")
        #expect(hoot == nil)
    }

    // MARK: case (h) — an `account` value in an incoming agent row is never applied

    @Test func anAccountInAnIncomingAgentRowIsNeverPlannedOrWritten() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await CloudLeanAgentsTests.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await b.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer", [("account", .string("login-on-b"))]))
        let crafted = CloudLeanAgentsTests.agent("writer", "Writer", [("account", .string("login-on-a")), ("role", .string("Writes"))])
        let plan = try await b.owner.cloudPlan(entity: "agent:writer", cloud: crafted)
        let planned = try #require(plan.store)
        #expect(!planned.has("account"), "An account is never part of what this Mac plans to store from another device")
        // Even a value handed to the write with an account in it keeps this Mac's own login.
        // `expecting` is this Mac's captured image, as the sync passes it. (Delete rule, records result "After the
        // review" / hooks line: `cloudPlan(cloud: nil)` now plans a removal, so it no longer returns the kept row.)
        let mine = try #require(try await b.owner.cloudRecords()["agent:writer"])
        let kept = CloudBrainRecordAdapter.travelling(mine, table: BackendCloudLeanAgents.agentKind.table)
        try await b.owner.cloudWrite(entity: "agent:writer", value: planned.setting("account", .string("login-on-a")), expecting: kept)
        let after = try await b.config.agent("writer")
        #expect(after?["account"].string == "login-on-b", "This Mac's login stays this Mac's")
        #expect(after?["role"].string == "Writes", "The shared field was written")
    }
}
