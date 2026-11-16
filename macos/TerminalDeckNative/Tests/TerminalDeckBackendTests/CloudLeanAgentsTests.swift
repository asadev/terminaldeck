import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane A2 lean item 3: agents and their instruction files arrive on a second Mac by the signed field list.
/// Real `BackendTaskConfiguration` files in scratch folders; no network, no real app data, no session started.
@Suite("Cloud lean — agents arrive on a second Mac; nothing widens, nothing starts")
struct CloudLeanAgentsTests {
    struct Side: Sendable {
        let mac: CloudLeanFixtureMac
        let config: BackendTaskConfiguration
        let owner: BackendCloudLeanAgents
        let adapter: CloudBrainRecordAdapter
        let notices: CloudLeanFixture.Counter
        let displays: CloudLeanFixture.Counter
    }
    /// `confirmed`: the person confirmed this Mac's set-up from the Cloud in its own window (lane A's new-Mac sheet).
    /// `projects`: this Mac's project ids as the agents owner reads them (nil: the list cannot be read).
    /// `trust`: replaces `confirmed` when given (nil answers: the trusted list cannot be read).
    static func side(_ device: String, clock: CloudLeanFixture.Clock, subject: String = CloudLeanFixture.subjectX, root: URL? = nil,
                     confirmed: Bool = false, projects: @escaping @Sendable () async -> [String]? = { nil },
                     trust: (@Sendable () async -> Bool?)? = nil) async throws -> Side {
        let mac = try CloudLeanFixture.mac(device, clock: clock, subject: subject, root: root)
        let notices = CloudLeanFixture.Counter(), displays = CloudLeanFixture.Counter()
        let folder = mac.root.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = try BackendTaskConfiguration(persistence: try BackendTaskPersistence(directory: folder, ownership: .exclusive), changed: { notices.bump() })
        try await config.start()
        let fixed: @Sendable () async -> Bool? = { confirmed }
        let decided: @Sendable () async -> Bool? = trust ?? fixed
        let owner = BackendCloudLeanAgents(config: config, historyFile: mac.root.appendingPathComponent("cloud").appendingPathComponent("a2-agent-names.json"),
            firstArrivalConfirmed: decided, projects: projects, display: { displays.bump() })
        let adapter = try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins)
        return Side(mac: mac, config: config, owner: owner, adapter: adapter, notices: notices, displays: displays)
    }
    static func agent(_ id: String, _ name: String, _ pairs: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        .object(([("id", .string(id)), ("name", .string(name)), ("provider", .string("claude"))] + pairs).map { NativeRPCValue.Field($0.0, $0.1) })
    }
    static func list(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    private func waiting(_ side: Side) async throws -> [String] {
        let listing = try await side.adapter.listing()
        return listing.waiting.map { $0.record + "/" + $0.field }
    }

    @Test func anAgentArrivesWithItsInstructionsAndWhatWouldWidenItWaitsOnThisMac() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent("reviewer", "Reviewer", [("role", .string("Reviews every change")), ("model", .string("opus")),
            ("instructions", .string("Read the diff first.")), ("permissionMode", .string("bypassPermissions")), ("seat", .string("reviewer")),
            ("projectId", .string("deck")), ("account", .string("login-on-mac-a")), ("verifyCommand", .string("/Users/person-a/bin/check.sh")),
            ("blockedTools", Self.list(["Edit"]))]))

        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let kinds = startedA.sent.map { $0.entityId }
        #expect(kinds == ["instruction:reviewer.md", "agent:reviewer"], "The instruction text goes first, then its agent")
        let travelled = CloudLeanFixture.text(startedA.sent)
        for never in ["login-on-mac-a", "person-a", "creatorKeyId", "keyInitializedFields", "verifyCommand", "instructionsFile", "sourceDirectory"] {
            #expect(!travelled.contains(never), "\(never) never travels")
        }

        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        let noticesBefore = b.notices.count
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let found = try await b.config.agent("reviewer")
        let arrived = try #require(found)
        #expect(arrived["name"].string == "Reviewer")
        #expect(arrived["role"].string == "Reviews every change")
        #expect(arrived["model"].string == "opus")
        #expect(arrived["instructions"].string == "Read the diff first.", "Its instruction file is in place")
        #expect(arrived["blockedTools"].elements?.count == 1, "A blocked tool only narrows: it applies")
        #expect(arrived["permissionMode"].string == nil, "A wider permission mode is never applied from another device")
        #expect(arrived["seat"].string == nil)
        #expect(arrived["projectId"].string == PROJProjects.independentID)
        #expect(arrived["account"].string == nil, "This Mac's logins are its own")
        #expect(arrived["verifyCommand"].string == nil)
        let waitingB = try await waiting(b)
        #expect(waitingB.contains("agent:reviewer/permissionMode") && waitingB.contains("agent:reviewer/seat") && waitingB.contains("agent:reviewer/projectId"),
            "What would widen it is listed as waiting on this Mac: \(waitingB)")
        #expect(!waitingB.contains("instruction:reviewer.md/"), "Its instructions no longer wait once the agent is here")
        #expect(b.notices.count == noticesBefore, "An import is never an event: no change notice")
        #expect(b.displays.count >= 1, "Screens refresh, display only")
        let listing = try await b.adapter.listing()
        let added = listing.changes.contains { $0.record == "agent:reviewer" && $0.field == CloudBrainMerge.existsField && $0.device == a.mac.device }
        #expect(added, "A new agent from another device is listed")

        // An import is not an edit, and what waits here is never sent back as this Mac's value.
        let echo = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(echo.isEmpty)
    }

    @Test func aNarrowingAppliesAndAWideningNeverDoes() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent("builder", "Builder", [("permissionMode", .string("acceptEdits"))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)
        let first = try await b.config.agent("builder")
        #expect(first?["permissionMode"].string == nil, "acceptEdits is wider than a fresh agent here: it waits")

        // The person sets it on B: the same value as the Cloud's, so nothing waits and nothing is sent.
        _ = try await b.config.saveAgent(Self.agent("builder", "Builder", [("permissionMode", .string("acceptEdits"))]))
        let fromB = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(fromB.isEmpty)
        let cleared = try await waiting(b)
        #expect(!cleared.contains("agent:builder/permissionMode"))

        // A narrows: plan mode, a blocked tool, paused. All three apply on B.
        _ = try await a.config.saveAgent(Self.agent("builder", "Builder", [("permissionMode", .string("plan")), ("blockedTools", Self.list(["Edit"]))]))
        _ = try await a.config.setStatus("builder", action: "pause")
        let narrower = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(narrower, from: a.mac.device, to: b.adapter)
        let narrowed = try await b.config.agent("builder")
        #expect(narrowed?["permissionMode"].string == "plan")
        #expect(narrowed?["blockedTools"].elements?.count == 1)
        #expect(narrowed?["status"].string == "paused")

        // A widens again: bypass, no blocked tool, switched back on. None of it applies on B; all of it is listed.
        _ = try await a.config.saveAgent(Self.agent("builder", "Builder", [("permissionMode", .string("bypassPermissions")), ("blockedTools", Self.list([]))]))
        _ = try await a.config.setStatus("builder", action: "resume")
        let wider = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(wider, from: a.mac.device, to: b.adapter)
        let held = try await b.config.agent("builder")
        #expect(held?["permissionMode"].string == "plan", "A wider permission mode never applies from another device")
        #expect(held?["blockedTools"].elements?.count == 1, "A block is never removed from another device")
        #expect(held?["status"].string == "paused", "A paused agent is never switched on from another device")
        let waitingB = try await waiting(b)
        #expect(waitingB.contains("agent:builder/permissionMode") && waitingB.contains("agent:builder/blockedTools") && waitingB.contains("agent:builder/status"), "\(waitingB)")
        let back = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(back.isEmpty, "The Mac that holds a change back never sends its own value over it")
    }

    /// The names rule itself (`BackendCloudLeanAgents.nameProblem`), case by case (Decker's ruling of 12 Nov).
    @Test func theNamesRuleCaseByCase() {
        let others = ["review": "Review", "tester": "Tester"]
        let history: [String: Set<String>] = ["review": ["review", "checker"], "tester": ["tester"]]
        func problem(_ name: String, id: String = "incoming", rename: Bool = false) -> String? {
            BackendCloudLeanAgents.nameProblem(name, agent: id, others: others, history: history, rename: rename)
        }
        // (a) A reserved name, or the beginning of one, would answer to @me or @hoot: refused.
        #expect(problem("Me") != nil)
        #expect(problem("me") != nil)
        #expect(problem("Hoot") != nil)
        #expect(problem("Hoo") != nil)
        #expect(problem("h") != nil)
        // A name that only BEGINS WITH a reserved name is accepted: this team has a seat called "Memory".
        #expect(problem("Memory") == nil)
        #expect(problem("Hoot builder") == nil)
        // (b) A name that equals, or is the beginning of, another agent's name here would answer to its mentions: refused.
        #expect(problem("Rev") != nil)
        #expect(problem("review") != nil)
        #expect(problem("REVIEW") != nil)
        // A name that only begins WITH another agent's name is accepted, and listed once.
        #expect(problem("Reviewer") == nil)
        let reviewer = BackendCloudLeanAgents.alsoAnswers("Reviewer", agent: "incoming", others: others)
        #expect(reviewer == "'Review' also answers to mentions of 'Reviewer'")
        let memory = BackendCloudLeanAgents.alsoAnswers("Memory", agent: "incoming", others: others)
        #expect(memory == "'me' also answers to mentions of 'Memory'")
        let planner = BackendCloudLeanAgents.alsoAnswers("Planner", agent: "incoming", others: others)
        #expect(planner == nil)
        // The same agent id is never compared with itself.
        #expect(problem("Rev", id: "review") == nil)
        #expect(problem("Review", id: "review", rename: true) == nil)
        // (c) A rename to a name a different agent here has ever had: refused. A new agent with that name is no rename.
        #expect(problem("Checker", id: "tester", rename: true) != nil)
        #expect(problem("Checker", id: "incoming", rename: false) == nil)
        // One plain line, before anything else.
        #expect(problem("Two\nlines") != nil)
        #expect(problem("") != nil)
        #expect(problem(" padded ") != nil)
    }

    @Test func memoryArrivesAndANameThatOnlyBeginsWithAnotherIsTakenAndListedOnce() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await b.config.saveAgent(Self.agent("review", "Review"))
        _ = try await a.config.saveAgent(Self.agent("memory", "Memory", [("instructions", .string("Keep the notes."))]))
        _ = try await a.config.saveAgent(Self.agent("reviewer", "Reviewer"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        let memory = try await b.config.agent("memory"), reviewer = try await b.config.agent("reviewer")
        #expect(memory?["name"].string == "Memory", "A name that begins with a reserved name arrives")
        #expect(memory?["instructions"].string == "Keep the notes.")
        #expect(reviewer?["name"].string == "Reviewer", "A name that begins with another agent's name arrives")
        let line = "'Review' also answers to mentions of 'Reviewer'"
        let first = try await b.adapter.listing()
        let once = first.mentions.filter { $0 == line }.count
        #expect(once == 1, "It is listed once instead of refused: \(first.mentions)")
        #expect(first.mentions.contains("'me' also answers to mentions of 'Memory'"))
        let nothingWaits = first.waiting.filter { $0.field == "name" || $0.field.isEmpty }
        #expect(nothingWaits.isEmpty, "Neither agent waits: \(nothingWaits)")

        // Still once after a later change to the same agent and another look at this Mac's records.
        _ = try await a.config.saveAgent(Self.agent("reviewer", "Reviewer", [("role", .string("Reviews every change"))]))
        let later = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(later, from: a.mac.device, to: b.adapter)
        _ = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        let second = try await b.adapter.listing()
        let still = second.mentions.filter { $0 == line }.count
        #expect(still == 1)
        let tool = BackendCloudLeanTools(adapters: [b.adapter])
        let answer = try await tool.invoke(BackendCloudLeanTools.toolID, arguments: CloudValue(.object([])))
        #expect(answer.raw["mentions"].elements?.count == 2, "The page's list carries both lines")
    }

    @Test func aNameThatWouldCaptureAnothersMentionsIsNotTakenAndEveryRenameIsListed() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await b.config.saveAgent(Self.agent("review", "Review"))
        _ = try await a.config.saveAgent(Self.agent("rev-agent", "Rev"))
        _ = try await a.config.saveAgent(Self.agent("helper", "Helper"))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(startedA.sent, from: a.mac.device, to: b.adapter)

        // "Rev" is the beginning of "Review", an agent with another id on this Mac: it would answer to Review's mentions.
        let refused = try await b.config.agent("rev-agent"), helper = try await b.config.agent("helper")
        #expect(refused == nil, "It is not added on this Mac")
        #expect(helper?["name"].string == "Helper", "The agent beside it arrives")
        let first = try await b.adapter.listing()
        let reason = first.waiting.first { $0.record == "agent:rev-agent" }?.reason ?? ""
        #expect(reason.contains("would answer to mentions of another agent on this Mac (Review)"), "\(reason)")

        // Renames of an agent this Mac already has.
        func rename(_ name: String) async throws -> String? {
            _ = try await a.config.saveAgent(Self.agent("helper", name))
            let sent = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
            try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.adapter)
            let row = try await b.config.agent("helper")
            return row?["name"].string
        }
        let afterHoo = try await rename("Hoo")
        #expect(afterHoo == "Helper", "The beginning of a reserved name (it would answer to @hoot) is not taken; the agent keeps its name")
        let listed = try await waiting(b)
        #expect(listed.contains("agent:helper/name"), "The held rename is listed with its reason: \(listed)")
        _ = try await b.config.saveAgent(Self.agent("review", "Checker"))
        let afterOld = try await rename("Review")
        #expect(afterOld == "Helper", "A rename to a name another agent here once had is not taken")
        let afterPlanner = try await rename("Planner")
        #expect(afterPlanner == "Planner", "A plain, free name applies")
        let last = try await b.adapter.listing()
        let renameListed = last.changes.contains { $0.record == "agent:helper" && $0.field == "name" && $0.from == "Helper" && $0.to == "Planner" && $0.device == a.mac.device }
        #expect(renameListed, "Every applied rename of the same agent id is listed")
        let stillWaiting = last.waiting.contains { $0.record == "agent:helper" && $0.field == "name" }
        #expect(!stillWaiting)
    }

    @Test func anAgentRowWaitsForItsInstructionRecordAndNothingIsEverStarted() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock: clock), b = try await Self.side(CloudLeanFixture.deviceB, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent("writer", "Writer", [("instructions", .string("Write plainly."))]))
        let startedA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        let agentOnly = startedA.sent.filter { $0.entityId.hasPrefix("agent:") }
        let device = a.mac.device, adapter = b.adapter

        // The agent's row before its instruction record: "cannot apply this record" (the sync core parks it).
        await #expect(throws: CloudRecordRefusal.self) { try await CloudLeanFixture.deliver(agentOnly, from: device, to: adapter) }
        let early = try await b.config.agent("writer")
        #expect(early == nil, "An agent is never usable here without its instructions")

        // As the sync core does: one record at a time, the instruction record, then the parked row again.
        let parked = try await CloudLeanFixture.deliverParking(startedA.sent, from: device, to: adapter)
        #expect(parked.isEmpty)
        let retry = await b.adapter.takeRetryWanted()
        #expect(retry, "The adapter asks for parked records to be tried again once the needed record arrived")
        let found = try await b.config.agent("writer")
        #expect(found?["instructions"].string == "Write plainly.")
        #expect(b.notices.count == 0, "No change notice was raised by any import on this Mac")
    }
}
