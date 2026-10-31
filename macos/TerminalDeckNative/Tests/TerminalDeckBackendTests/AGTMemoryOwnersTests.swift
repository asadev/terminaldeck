import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Deck Memory, Agents side: which seat a session sits in, the lead on the project registry,
/// and the brief a new job starts from. Fixture data only; no store, no AI.
final class AGTMemoryOwnersTests: XCTestCase {
    private let projects = [
        PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"], lead: "session:abc", leadName: "Commander"),
        PROJProject(id: "crm", name: "CRM", folders: ["/p/crm"], lead: "agent:alex", leadName: "Alex"),
        PROJProject(id: PROJProjects.independentID, name: "Independent"),
    ]
    private func row(_ id: String, project: String?, seat: String? = nil, claude: String? = nil) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("id", .string(id)), .init("name", .string(id.capitalized))])
        if let project { value = value.setting("projectId", .string(project)) }
        if let seat { value = value.setting("seat", .string(seat)) }
        if let claude { value = value.setting("claudeAgent", .string(claude)) }
        return value
    }
    private var agents: [NativeRPCValue] {
        [row("alex", project: "crm"), row("crm-db", project: "crm"), row("sam-2", project: "imatch", seat: "ios-engineer", claude: "ios"),
         row("writer", project: nil)]
    }
    private func resolve(profile: String? = nil, claude: String? = nil, project: String? = nil, folder: String? = nil,
                         session: String? = nil, title: String? = nil) -> DeckMemorySessionOwner {
        BackendAGTMemoryOwners.resolve(profileID: profile, claudeAgent: claude, projectID: project, folder: folder,
                                       sessionID: session, sessionTitle: title, projects: projects, agents: agents)
    }

    func testAnAgentSessionSitsInItsRoleSeatWhoeverTheHireIs() {
        let owner = resolve(profile: "sam-2", folder: "/p/imatch")
        XCTAssertEqual(owner.kind, .agent); XCTAssertEqual(owner.id, "ios-engineer"); XCTAssertEqual(owner.project, "imatch")
        XCTAssertEqual(owner.name, "Sam-2"); XCTAssertTrue(owner.memoryOn)
        XCTAssertEqual(BackendAGTMemoryOwners.memoryOwner(owner), .role(project: "imatch", role: "ios-engineer"))
        XCTAssertEqual(BackendAGTMemoryOwners.memoryOwner(owner)?.folder, "projects/imatch/roles/ios-engineer")
        // Unset seat = the role named after it; outside any project.
        let writer = resolve(profile: "writer")
        XCTAssertEqual(BackendAGTMemoryOwners.memoryOwner(writer)?.folder, "roles/writer")
        // Started as a Claude Code agent by name, inside the project.
        XCTAssertEqual(resolve(claude: "ios", folder: "/p/imatch/app").id, "ios-engineer")
    }

    func testLeadsAgentOrSession() {
        let alex = resolve(profile: "alex", folder: "/p/crm")
        XCTAssertEqual(alex.kind, .lead); XCTAssertEqual(alex.project, "crm")
        XCTAssertEqual(BackendAGTMemoryOwners.memoryOwner(alex), .lead("crm"))
        // A session lead is the chosen identity; a matching display name cannot borrow its memory.
        XCTAssertEqual(resolve(folder: "/p/imatch", session: "abc", title: "whatever").kind, .lead)
        let restarted = resolve(folder: "/p/imatch", session: "zzz", title: "Commander")
        XCTAssertEqual(restarted.kind, .plain); XCTAssertNil(BackendAGTMemoryOwners.memoryOwner(restarted))
        // Same name in another project is not the lead.
        XCTAssertEqual(resolve(folder: "/p/crm", session: "zzz", title: "Commander").kind, .plain)
    }

    /// 13 Oct: a session the person opens in a project led by a saved agent works as that lead, with its memory.
    func testASessionOpenedInAnAgentLedProjectWorksAsTheLead() {
        func opened(folder: String, claude: String? = nil, profile: String? = nil, session: String? = "s9", title: String? = "ClaudeCRM") -> DeckMemorySessionOwner {
            BackendAGTMemoryOwners.resolve(profileID: profile, claudeAgent: claude, projectID: nil, folder: folder, sessionID: session, sessionTitle: title,
                                           projects: projects, agents: agents, worksAsTheLead: true)
        }
        let lead = opened(folder: "/p/crm/web")
        XCTAssertEqual(lead.kind, .lead); XCTAssertEqual(lead.project, "crm"); XCTAssertEqual(lead.name, "Alex"); XCTAssertTrue(lead.memoryOn)
        XCTAssertEqual(BackendAGTMemoryOwners.memoryOwner(lead), .lead("crm"))
        // The person picked another agent: it is that agent, or (an agent the app does not know) nobody's.
        XCTAssertEqual(opened(folder: "/p/crm", profile: "crm-db").kind, .agent)
        XCTAssertEqual(opened(folder: "/p/crm", claude: "someone-else").kind, .plain)
        // A session lead is the one session the person chose; other sessions there stay plain.
        XCTAssertEqual(opened(folder: "/p/imatch", title: "ClaudeiMatch").kind, .plain)
        XCTAssertEqual(opened(folder: "/elsewhere").kind, .plain)
        // Without the flag (Hoot's, a routine's or a task's session) nothing changes.
        XCTAssertEqual(resolve(folder: "/p/crm/web", session: "s9", title: "ClaudeCRM").kind, .plain)
    }

    func testOnlySessionsThePersonOpenedOnAnAIMayWorkAsTheLead() {
        func input(_ change: (inout BackendCreateSessionInput) -> Void = { _ in }) -> BackendCreateSessionInput {
            var value = BackendCreateSessionInput(cwd: "/p/crm", provider: "claude"); change(&value); return value
        }
        XCTAssertTrue(BackendAGTMemoryOwners.openedByThePerson(input(), provider: "claude", origin: nil, routine: nil))
        XCTAssertTrue(BackendAGTMemoryOwners.openedByThePerson(input(), provider: "codex", origin: .user, routine: nil))
        XCTAssertTrue(BackendAGTMemoryOwners.openedByThePerson(input(), provider: "gemini", origin: nil, routine: ""))
        XCTAssertFalse(BackendAGTMemoryOwners.openedByThePerson(input(), provider: "shell", origin: nil, routine: nil))
        XCTAssertFalse(BackendAGTMemoryOwners.openedByThePerson(input(), provider: "claude", origin: .copilot, routine: nil))
        XCTAssertFalse(BackendAGTMemoryOwners.openedByThePerson(input(), provider: "claude", origin: .app, routine: nil))
        XCTAssertFalse(BackendAGTMemoryOwners.openedByThePerson(input(), provider: "claude", origin: nil, routine: "nightly"))
        XCTAssertFalse(BackendAGTMemoryOwners.openedByThePerson(input { $0.taskID = "t1" }, provider: "claude", origin: nil, routine: nil))
        XCTAssertFalse(BackendAGTMemoryOwners.openedByThePerson(input { $0.claudeAgent = "reviewer" }, provider: "claude", origin: nil, routine: nil))
        XCTAssertFalse(BackendAGTMemoryOwners.openedByThePerson(input { $0.agentInstructions = "crm-db" }, provider: "claude", origin: nil, routine: nil))
    }

    func testAPlainSessionKeepsOnlyItsProject() {
        let plain = resolve(folder: "/p/crm/sub", session: "s1", title: "Session 1")
        XCTAssertEqual(plain.kind, .plain); XCTAssertEqual(plain.project, "crm"); XCTAssertFalse(plain.memoryOn)
        XCTAssertNil(BackendAGTMemoryOwners.memoryOwner(plain))
        XCTAssertNil(resolve(folder: "/elsewhere").project)
        XCTAssertEqual(BackendAGTMemoryOwners.categoryWord(plain), "plain")
    }

    func testRegistryKeepsOneLeadPerProjectAndOneProjectPerLead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("L4-leads-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = PROJMadeUp.seed(folder.appendingPathComponent("projects.registry.json"))
        let registry = BackendPROJRegistry(fileURL: file)
        _ = try await registry.setLead(projectID: "imatch", lead: "session:abc", leadName: "Commander")
        _ = try await registry.setLead(projectID: "crm", lead: "agent:alex", leadName: "Alex")
        // The same lead cannot hold two projects: it moves.
        _ = try await registry.setLead(projectID: "imatch", lead: "agent:alex", leadName: "Alex")
        let listed = try await registry.projects()
        XCTAssertEqual(listed.first { $0.id == "imatch" }?.lead, "agent:alex")
        XCTAssertEqual(listed.first { $0.id == "crm" }?.lead, "")
        // It is saved, and it survives a reload.
        let reloaded = try await BackendPROJRegistry(fileURL: file).projects()
        XCTAssertEqual(reloaded.first { $0.id == "imatch" }?.leadName, "Alex")
        // Clearing, and the refusals.
        _ = try await registry.setLead(projectID: "imatch", lead: nil, leadName: nil)
        let cleared = try await registry.projects()
        XCTAssertEqual(cleared.first { $0.id == "imatch" }?.lead, "")
        for (project, lead) in [(PROJProjects.independentID, "agent:x"), ("nope", "agent:x"), ("crm", "boss")] {
            do { _ = try await registry.setLead(projectID: project, lead: lead, leadName: nil); XCTFail("accepted \(project) \(lead)") } catch {}
        }
    }

    func testAProfileSavesItsSeatAndRefusesABadOne() throws {
        XCTAssertNil(AGTSeats.roleProblem("ios-engineer"))
        XCTAssertNotNil(AGTSeats.roleProblem("iOS Engineer"))
        XCTAssertTrue(BackendAGTOrg.fields.contains("seat"))
        XCTAssertTrue(BackendAGOPTProfileChanges.editableFields.contains("seat"))
        let kept = BackendAGTOrg.carry(.object([.init("id", .string("sam-2")), .init("name", .string("Sam"))]),
                                       existing: .object([.init("id", .string("sam-2")), .init("seat", .string("ios-engineer"))]))
        XCTAssertEqual(kept["seat"].string, "ios-engineer")
    }

    // MARK: 3b: several hands on one seat

    func testHandsAreNumberedPerSeatAndASeatDropsBackWhenTheyClose() async {
        let hands = BackendAGTHands()
        let seat = DeckMemoryOwner.role(project: "imatch", role: "db-fixer"), other = DeckMemoryOwner.role(project: "imatch", role: "ios-engineer")
        let first = await hands.join(sessionID: "s1", seat: seat, job: "Fix the March import", taskID: nil)
        let second = await hands.join(sessionID: "s2", seat: seat, job: "Rebuild the index\nnow", taskID: nil)
        let third = await hands.join(sessionID: "s3", seat: seat, job: nil, taskID: nil)
        let elsewhere = await hands.join(sessionID: "s4", seat: other, job: "Ship build 412", taskID: nil)
        XCTAssertEqual([first.number, second.number, third.number, elsewhere.number], [1, 2, 3, 1])
        XCTAssertEqual(second.job, "Rebuild the index now")
        // Joining again keeps the number and takes a new job.
        let again = await hands.join(sessionID: "s3", seat: seat, job: "Check the totals", taskID: "t9")
        XCTAssertEqual(again.number, 3); XCTAssertEqual(again.job, "Check the totals"); XCTAssertEqual(again.taskID, "t9")
        var onSeat = await hands.hands(seat: seat)
        XCTAssertEqual(onSeat.map(\.number), [1, 2, 3])
        // Hand 2 closes: the others keep their numbers, and the next one takes the free number.
        await hands.leave(sessionID: "s2")
        onSeat = await hands.hands(seat: seat)
        XCTAssertEqual(onSeat.map(\.number), [1, 3])
        let refill = await hands.join(sessionID: "s5", seat: seat, job: "Another piece", taskID: nil)
        XCTAssertEqual(refill.number, 2)
        // A session that moves to another seat leaves the first one.
        _ = await hands.join(sessionID: "s5", seat: other, job: nil, taskID: nil)
        let counts = [await hands.count(seat: seat), await hands.count(seat: other), await hands.count(project: "imatch")]
        XCTAssertEqual(counts, [2, 2, 4])
        for id in ["s1", "s3", "s4", "s5"] { await hands.leave(sessionID: id) }
        let empty = await hands.all()
        XCTAssertTrue(empty.isEmpty)
    }

    func testTheCapComesFromTheTemplateAndAHandStillStartingCounts() async {
        let hands = BackendAGTHands()
        let seat = DeckMemoryOwner.role(project: "crm", role: "crm-db")
        _ = await hands.join(sessionID: "a", seat: seat, job: "One", taskID: nil)
        _ = await hands.join(sessionID: "b", seat: seat, job: "Two", taskID: nil)
        var refusal = await hands.refusal(adding: seat, perSeat: 3, perProject: 12, seatTitle: "CRM database")
        XCTAssertNil(refusal)
        await hands.reserve(taskID: "task-3", seat: seat)   // asked for, not started yet
        refusal = await hands.refusal(adding: seat, perSeat: 3, perProject: 12, seatTitle: "CRM database")
        XCTAssertEqual(refusal, "CRM database already has 3 hands, the limit for one seat (3). Change it in Templates if you want more.")
        // Its session starts: the reservation becomes the hand, not a fourth.
        _ = await hands.join(sessionID: "c", seat: seat, job: nil, taskID: "task-3")
        let count = await hands.count(seat: seat)
        XCTAssertEqual(count, 3)
        // The project cap.
        let project = await hands.refusal(adding: .role(project: "crm", role: "portal"), perSeat: 3, perProject: 3, seatTitle: "Portal")
        XCTAssertEqual(project, "This project already has 3 agent hands at work, its limit (3). Change it in Templates if you want more.")
        let fine = await hands.refusal(adding: .role(project: "imatch", role: "ios"), perSeat: 3, perProject: 3, seatTitle: "iOS")
        XCTAssertNil(fine)
    }

    func testAHelperSeatSitsUnderItsParentAndFoldsBackWhenItsLastHandCloses() async {
        let parent = DeckMemoryOwner.role(project: "imatch", role: "db-fixer")
        let first = BackendAGTHelperSeats.next(under: parent, existing: [])
        XCTAssertEqual(first, .role(project: "imatch", role: "db-fixer--helper-1"))
        let second = BackendAGTHelperSeats.next(under: parent, existing: [first!, .role(project: "crm", role: "db-fixer--helper-2")])
        XCTAssertEqual(second?.roleID, "db-fixer--helper-2")
        XCTAssertEqual(BackendAGTHelperSeats.parent(of: first!), parent)
        XCTAssertTrue(BackendAGTHelperSeats.isHelper(first!)); XCTAssertFalse(BackendAGTHelperSeats.isHelper(parent))
        XCTAssertNil(BackendAGTHelperSeats.next(under: first!, existing: []), "a helper has no helpers of its own")
        XCTAssertNil(BackendAGTHelperSeats.parent(of: parent))
        // The seat's emptying is what triggers the fold-back.
        let hands = BackendAGTHands()
        let folded = FoldedSeats()
        await hands.bind(taskTitle: { id in id == "t1" ? "Named by its task" : nil }, seatEmptied: { await folded.add($0) })
        let helper = await hands.join(sessionID: "h1", seat: first!, job: nil, taskID: "t1")
        XCTAssertEqual(helper.job, "Named by its task")
        _ = await hands.join(sessionID: "h2", seat: first!, job: "Second piece", taskID: nil)
        await hands.leave(sessionID: "h1")
        var seats = await folded.seats
        XCTAssertTrue(seats.isEmpty, "one hand is still on the helper seat")
        await hands.leave(sessionID: "h2")
        seats = await folded.seats
        XCTAssertEqual(seats, [first!])
        // The helper's job runs on the helper seat, whoever the hire is.
        let owner = BackendAGTMemoryOwners.resolve(profileID: "crm-db", claudeAgent: nil, seatOverride: "crm-db--helper-1", projectID: nil, folder: "/p/crm",
                                                   sessionID: nil, sessionTitle: nil, projects: projects, agents: agents)
        XCTAssertEqual(BackendAGTMemoryOwners.memoryOwner(owner), .role(project: "crm", role: "crm-db--helper-1"))
    }

    func testTheJobBriefPointsAtTheSeatAndCarriesTheReportForm() {
        let labels = DeckMemoryLabels(owner: .role(project: "imatch", role: "ios-engineer"), project: "imatch", date: Date(timeIntervalSince1970: 1_791_000_000), type: "decision")
        let hit = DeckMemorySearchHit(kind: .note, ref: "n1", title: "Use the new upload path", snippet: "TestFlight uploads go through\nthe signed script.",
                                      labels: labels, path: "projects/imatch/roles/ios-engineer/notes/n1.md", score: 1, matchedBy: .words)
        let text = BackendAGTJobStart.brief(category: .agent, hits: [hit], memoryRoot: "/m", ownerFolder: "projects/imatch/roles/ios-engineer")
        XCTAssertTrue(text.contains("## From your memory"))
        XCTAssertTrue(text.contains("decision · Use the new upload path: TestFlight uploads go through the signed script."))
        XCTAssertTrue(text.contains("(/m/projects/imatch/roles/ios-engineer/notes/n1.md)"))
        XCTAssertTrue(text.contains("it belongs to the role"))
        XCTAssertTrue(text.contains(BackendAGTJobStart.reportForm))
        XCTAssertFalse(text.contains("You lead this project"))
        let lead = BackendAGTJobStart.brief(category: .lead, hits: [], memoryRoot: "/m", ownerFolder: "projects/crm/lead")
        XCTAssertTrue(lead.contains("No saved note matches this job yet")); XCTAssertTrue(lead.contains("You lead this project"))
        XCTAssertEqual(BackendAGTJobStart.query(title: "Fix sign-in", details: "The button\nfails"), "Fix sign-in The button fails")
    }
    /// Known gap closed (11 Oct): an agent moved to another project can bring its role's memory along. The app
    /// moves it through M1's store: the notes and topics into the same role in the new project (same ids,
    /// labelled where they came from), the card copied in; the old role's diary stays as history.
    func testARolesMemoryMovesToTheSameRoleInAnotherProject() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("L4-move-memory-" + UUID().uuidString).resolvingSymlinksInPath().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: base) }
        let data = base.appendingPathComponent("data"), root = base.appendingPathComponent("root/Memory")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try await DeckMemoryStore.open(root: root, dataRoot: data, embedder: nil, watch: false)
        let old = DeckMemoryOwner.role(project: "atlas", role: "builder"), new = DeckMemoryOwner.role(project: "birch", role: "builder")
        _ = try await store.ensureOwner(old, name: "Builder")
        let note = try await store.addNote(.init(title: "Deploy order", body: "Database first, then the app.", type: .lesson, stamp: .init(owner: old, session: "s1", job: "release")))
        _ = try await store.updateTopic(old, title: "Release", body: "Half done.", stamp: .init(owner: old, job: "release"))
        _ = try await store.saveCard(old, text: "Code word AMBER-OTTER-27.")
        _ = try await store.ensureOwner(new, name: "Builder")
        let report = try await store.foldBack(old, into: new)
        XCTAssertEqual(report.notes, 1); XCTAssertEqual(report.topics, 1)
        let moved = try await store.note(id: note.id)
        XCTAssertEqual(moved?.labels.owner, new, "the same note, now the new role's")
        _ = try await store.saveCard(new, text: "Code word AMBER-OTTER-27.")   // what the app does with the old card
        let card = try await store.card(new)
        XCTAssertTrue(card.text.contains("AMBER-OTTER-27"))
        let topics = try await store.topics(new, job: "release", includeClosed: false)
        XCTAssertEqual(topics.count, 1)
        await store.close()
    }

    /// Retest of install 3: deleting an agent that led a project left the project naming it as lead.
    func testADeletedAgentIsNoLongerAProjectsLead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("L4-deleted-lead-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: folder); PROJProjects.publishRegistered([PROJProjects.independent]) }
        let registry = BackendPROJRegistry(fileURL: PROJMadeUp.seed(folder.appendingPathComponent("projects.registry.json")))
        _ = try await registry.setLead(projectID: "imatch", lead: "agent:mt-builder", leadName: "MT Builder")
        _ = try await registry.setLead(projectID: "crm", lead: "session:abc", leadName: "Commander")
        let changed = try await registry.clearLeads { $0 == "mt-builder" }
        XCTAssertEqual(changed, ["imatch"])
        let projects = try await registry.projects()
        XCTAssertEqual(projects.first { $0.id == "imatch" }?.lead, "")
        XCTAssertEqual(projects.first { $0.id == "imatch" }?.leadName, "")
        XCTAssertEqual(projects.first { $0.id == "crm" }?.lead, "session:abc", "a session lead is never touched")
        let again = try await registry.clearLeads { $0 == "mt-builder" }
        XCTAssertTrue(again.isEmpty, "nothing to do the second time")
    }
}

private actor FoldedSeats {
    private(set) var seats: [DeckMemoryOwner] = []
    func add(_ seat: DeckMemoryOwner) { seats.append(seat) }

}
