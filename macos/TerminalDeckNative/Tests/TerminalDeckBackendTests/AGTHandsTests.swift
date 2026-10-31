import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Deck Memory 3b: several hands on one seat. Registry numbering, the cap, helper seats, and the
/// add-a-hand / ask-for-hands service against in-memory fakes (no engine, no store, no AI).
final class AGTHandsTests: XCTestCase {
    private let seat = DeckMemoryOwner.role(project: "imatch", role: "db-fixer")

    func testHandsGetTheLowestFreeNumberAndKeepIt() async {
        let hands = BackendAGTHands()
        let one = await hands.join(sessionID: "s1", seat: seat, job: "Fix March import", taskID: nil)
        let two = await hands.join(sessionID: "s2", seat: seat, job: "Fix April import", taskID: nil)
        let three = await hands.join(sessionID: "s3", seat: seat, job: nil, taskID: nil)
        XCTAssertEqual([one.number, two.number, three.number], [1, 2, 3])
        // Asking again keeps the number and takes a new job.
        let again = await hands.join(sessionID: "s2", seat: seat, job: "Fix May import", taskID: "t9")
        XCTAssertEqual(again.number, 2); XCTAssertEqual(again.job, "Fix May import"); XCTAssertEqual(again.taskID, "t9")
        // Hand 1 closes: the others keep their numbers, and the next hand takes the free 1.
        await hands.leave(sessionID: "s1")
        let listed = await hands.hands(seat: seat)
        XCTAssertEqual(listed.map(\.number), [2, 3])
        let next = await hands.join(sessionID: "s4", seat: seat, job: "x", taskID: nil)
        XCTAssertEqual(next.number, 1)
        // Another seat numbers on its own.
        let other = await hands.join(sessionID: "s5", seat: .lead("imatch"), job: nil, taskID: nil)
        XCTAssertEqual(other.number, 1)
    }

    func testTheCapCountsHandsThatAreStillStarting() async {
        let hands = BackendAGTHands()
        _ = await hands.join(sessionID: "s1", seat: seat, job: "a", taskID: nil)
        await hands.reserve(taskID: "t2", seat: seat)
        var refusal = await hands.refusal(adding: seat, perSeat: 3, perProject: 12, seatTitle: "Database fixer")
        XCTAssertNil(refusal)
        await hands.reserve(taskID: "t3", seat: seat)
        refusal = await hands.refusal(adding: seat, perSeat: 3, perProject: 12, seatTitle: "Database fixer")
        XCTAssertEqual(refusal?.hasPrefix("Database fixer already has 3 hands"), true)
        // The reserved hand's session joins: still three, not four.
        _ = await hands.join(sessionID: "s2", seat: seat, job: nil, taskID: "t2")
        let count = await hands.count(seat: seat)
        XCTAssertEqual(count, 3)
        // The project cap.
        refusal = await hands.refusal(adding: .role(project: "imatch", role: "ios"), perSeat: 3, perProject: 3, seatTitle: "iOS")
        XCTAssertEqual(refusal?.contains("already has 3 agent hands"), true)
        refusal = await hands.refusal(adding: .role(project: "crm", role: "ios"), perSeat: 3, perProject: 3, seatTitle: "iOS")
        XCTAssertNil(refusal)
    }

    func testAnEmptiedSeatIsReportedOnceItsLastHandLeaves() async {
        let hands = BackendAGTHands()
        let emptied = Emptied()
        await hands.bind(taskTitle: { $0 == "t1" ? "Title from the task" : nil }, seatEmptied: { await emptied.add($0) })
        let first = await hands.join(sessionID: "s1", seat: seat, job: nil, taskID: "t1")
        XCTAssertEqual(first.job, "Title from the task")
        _ = await hands.join(sessionID: "s2", seat: seat, job: "b", taskID: nil)
        await hands.leave(sessionID: "s1")
        var seen = await emptied.seats
        XCTAssertTrue(seen.isEmpty)
        await hands.leave(sessionID: "s2")
        seen = await emptied.seats
        XCTAssertEqual(seen, [seat])
    }
    private actor Emptied { var seats: [DeckMemoryOwner] = []; func add(_ seat: DeckMemoryOwner) { seats.append(seat) } }

    func testHelperSeatsSitUnderTheirParentAndCannotNest() {
        let first = BackendAGTHelperSeats.next(under: seat, existing: [])
        XCTAssertEqual(first, .role(project: "imatch", role: "db-fixer--helper-1"))
        let second = BackendAGTHelperSeats.next(under: seat, existing: [first!, .role(project: "crm", role: "db-fixer--helper-2")])
        XCTAssertEqual(second?.roleID, "db-fixer--helper-2")
        XCTAssertTrue(BackendAGTHelperSeats.isHelper(first!)); XCTAssertFalse(BackendAGTHelperSeats.isHelper(seat))
        XCTAssertEqual(BackendAGTHelperSeats.parent(of: first!), seat)
        XCTAssertNil(BackendAGTHelperSeats.parent(of: seat))
        XCTAssertNil(BackendAGTHelperSeats.next(under: first!, existing: []))
        XCTAssertEqual(first?.folder, "projects/imatch/roles/db-fixer--helper-1")
    }

    // MARK: The service

    private actor World {
        var agents: [String: NativeRPCValue]
        var tasks: [(id: String, input: NativeRPCValue, by: String)] = []
        var patches: [String: NativeRPCValue] = [:]
        var told: [(String, String)] = []
        var nudges = 0
        init(agents: [String: NativeRPCValue]) { self.agents = agents }
        func agent(_ id: String) -> NativeRPCValue? { agents[id] }
        func save(_ row: NativeRPCValue) { if let id = row["id"].string { agents[id] = row } }
        func create(_ input: NativeRPCValue, by: String) -> String { let id = "task-\(tasks.count + 1)"; tasks.append((id, input, by)); return id }
        func patch(_ id: String, _ value: NativeRPCValue) { patches[id] = value }
        func tell(_ id: String, _ text: String) { told.append((id, text)) }
        func nudge() { nudges += 1 }
    }
    private func service(_ world: World, hands: BackendAGTHands, projects: [PROJProject], sessions: [(id: String, title: String, project: String)] = []) -> BackendAGTHandsService {
        BackendAGTHandsService(.init(projects: { projects }, agent: { await world.agent($0) }, saveAgent: { await world.save($0) },
            createTask: { await world.create($0, by: $1) }, patchTask: { await world.patch($0, $1) }, nudge: { await world.nudge() },
            sessions: { sessions }, tell: { await world.tell($0, $1) }, memory: { DeckMemoryCenter.shared.store }), hands: hands)
    }
    private func fixer(maxConcurrent: Double = 1) -> NativeRPCValue {
        .object([.init("id", .string("db-fixer")), .init("name", .string("Database fixer")), .init("projectId", .string("imatch")),
                 .init("defaultProject", .string("/p/imatch")), .init("maxConcurrent", .number(maxConcurrent))])
    }

    func testAddingAHandStartsATaskOnTheSameSeatAndStopsAtTheCap() async throws {
        let hands = BackendAGTHands(), world = World(agents: ["db-fixer": fixer()])
        let projects = [PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"])]
        let service = service(world, hands: hands, projects: projects)
        _ = await hands.join(sessionID: "s1", seat: seat, job: "Fix March", taskID: nil)
        let reply = try await service.addHand(agentID: "db-fixer", job: "Fix April import", details: "Rows 200 to 400", helper: false, by: "me")
        XCTAssertEqual(reply["seat"].string, seat.key); XCTAssertEqual(reply["helper"].bool, false); XCTAssertEqual(reply["ownFolder"].bool, true)
        var tasks = await world.tasks
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].input["title"].string, "Fix April import"); XCTAssertEqual(tasks[0].input["assignee"].string, "db-fixer")
        XCTAssertEqual(tasks[0].input["useWorkspace"].bool, true); XCTAssertEqual(tasks[0].input["project"].string, "/p/imatch")
        // The agent may now run two at once, so the engine starts a second session instead of queueing.
        let raised = await world.agent("db-fixer")?["maxConcurrent"].number
        XCTAssertEqual(raised, 2)
        _ = try await service.addHand(agentID: "db-fixer", job: "Fix May import", details: "", helper: false, by: "me")
        // Three hands (one live, two starting): the default cap for an agent seat is 3.
        do { _ = try await service.addHand(agentID: "db-fixer", job: "Fix June import", details: "", helper: false, by: "me"); XCTFail("went past the cap") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already has 3 hands"), error.localizedDescription) }
        tasks = await world.tasks
        XCTAssertEqual(tasks.count, 2)
        let nudges = await world.nudges
        XCTAssertEqual(nudges, 2)
    }

    func testAHandNeverGivesANoLimitAgentALimit() async throws {
        let hands = BackendAGTHands(), world = World(agents: ["db-fixer": fixer(maxConcurrent: 0)])
        let service = service(world, hands: hands, projects: [PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"])])
        _ = await hands.join(sessionID: "s1", seat: seat, job: "Fix March", taskID: nil)
        _ = try await service.addHand(agentID: "db-fixer", job: "Fix April import", details: "", helper: false, by: "me")
        let kept = await world.agent("db-fixer")?["maxConcurrent"].number
        XCTAssertEqual(kept, 0)
        let tasks = await world.tasks
        XCTAssertEqual(tasks.count, 1)
    }

    func testAHelperGetsItsOwnShortLivedSeatUnderTheParent() async throws {
        let hands = BackendAGTHands(), world = World(agents: ["db-fixer": fixer()])
        let service = service(world, hands: hands, projects: [PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"])])
        let reply = try await service.addHand(agentID: "db-fixer", job: "Check the backups", details: "", helper: true, by: "lead")
        XCTAssertEqual(reply["seat"].string, "role:imatch/db-fixer--helper-1"); XCTAssertEqual(reply["helper"].bool, true)
        let patches = await world.patches
        XCTAssertEqual(patches["task-1"]?[BackendAGTHandsService.taskSeatField].string, "db-fixer--helper-1")
        // The task's session then resolves to the helper seat, not the agent's own.
        let owner = BackendAGTMemoryOwners.resolve(profileID: "db-fixer", claudeAgent: nil, seatOverride: "db-fixer--helper-1", projectID: "imatch", folder: "/p/imatch",
            sessionID: "s9", sessionTitle: nil, projects: [PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"])], agents: [fixer()])
        XCTAssertEqual(BackendAGTMemoryOwners.memoryOwner(owner), .role(project: "imatch", role: "db-fixer--helper-1"))
    }

    func testAnAgentsRequestGoesToItsLeadOrToHoot() async throws {
        let hands = BackendAGTHands(), world = World(agents: ["db-fixer": fixer(), "alex": .object([.init("id", .string("alex")), .init("name", .string("Alex"))])])
        _ = await hands.join(sessionID: "s1", seat: seat, job: "Fix March", taskID: "t1")
        // A lead that is a running session is told in its own session.
        let led = [PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"], lead: "session:old-id", leadName: "Commander")]
        var reply = try await service(world, hands: hands, projects: led, sessions: [("new-id", "Commander", "imatch")])
            .requestHands(fromSession: "s1", count: 2, job: "Split the import by month", why: "Three months are independent", helper: false)
        XCTAssertEqual(reply["sentTo"].string, "lead"); XCTAssertEqual(reply["session"].string, "new-id")
        let told = await world.told
        XCTAssertEqual(told.count, 1)
        XCTAssertTrue(told[0].1.contains("asks for 2 more hands on its seat")); XCTAssertTrue(told[0].1.contains("agents_add_hand"))
        // A lead that is a saved agent gets a task.
        let agentLed = [PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"], lead: "agent:alex", leadName: "Alex")]
        reply = try await service(world, hands: hands, projects: agentLed).requestHands(fromSession: "s1", count: 1, job: "A helper for backups", why: "", helper: true)
        XCTAssertEqual(reply["sentTo"].string, "lead")
        var tasks = await world.tasks
        XCTAssertEqual(tasks.last?.input["assignee"].string, "alex")
        // No lead: Hoot decides.
        reply = try await service(world, hands: hands, projects: [PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"])])
            .requestHands(fromSession: "s1", count: 1, job: "One more hand", why: "", helper: false)
        XCTAssertEqual(reply["sentTo"].string, "hoot")
        tasks = await world.tasks
        XCTAssertEqual(tasks.last?.input["assignee"].string, "hoot")
        // A mention of a VACANT seat asks the lead to fill it; a vacant LEAD seat goes to Hoot.
        let vacant = DeckMemoryOwner.role(project: "imatch", role: "release-captain")
        reply = try await service(world, hands: hands, projects: led, sessions: [("new-id", "Commander", "imatch")]).requestFill(seat: vacant, note: "needed for Friday", by: "You")
        XCTAssertEqual(reply["sentTo"].string, "lead"); XCTAssertEqual(reply["seat"].string, "role:imatch/release-captain")
        let filled = await world.told
        XCTAssertTrue(filled.last?.1.contains("is vacant and still holds its memory") == true)
        XCTAssertTrue(filled.last?.1.contains("needed for Friday") == true)
        reply = try await service(world, hands: hands, projects: led, sessions: [("new-id", "Commander", "imatch")]).requestFill(seat: .lead("imatch"), note: "", by: "You")
        XCTAssertEqual(reply["sentTo"].string, "hoot")
        do { _ = try await service(world, hands: hands, projects: led).requestFill(seat: .project("imatch"), note: "", by: "You"); XCTFail("a project is not a seat") } catch {}
        // Somebody who is not in a seat cannot ask.
        do { _ = try await service(world, hands: hands, projects: led).requestHands(fromSession: "nobody", count: 1, job: "x", why: "", helper: false); XCTFail("accepted") } catch {}
    }

    /// #23: a request typed into the lead's terminal is one line: a newline or carriage return in the job or the
    /// reason cannot become a second command or prompt.
    func testARequestTypedIntoTheLeadIsOneLine() async throws {
        let hands = BackendAGTHands(), world = World(agents: ["db-fixer": fixer()])
        _ = await hands.join(sessionID: "s1", seat: seat, job: "Fix\rMarch", taskID: "t1")
        let led = [PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"], lead: "session:old-id", leadName: "Commander")]
        _ = try await service(world, hands: hands, projects: led, sessions: [("new-id", "Commander", "imatch")])
            .requestHands(fromSession: "s1", count: 1, job: "fix tests\rrm -rf ~\r", why: "because\n\u{1b}[2Jnow", helper: false)
        let all = await world.told, told = try XCTUnwrap(all.last?.1)
        XCTAssertNil(told.rangeOfCharacter(from: .controlCharacters), told)
        XCTAssertTrue(told.contains("The job: fix testsrm -rf ~."), told)
    }

    // MARK: Through the real task engine (memory stores, no AI)

    /// TEST-RESULTS T12 / MEM 1e: the second hand's task went into the first hand's open session. A hand added
    /// on a seat always starts its own session, and never closes or waits for the other hand's session.
    func testASecondHandStartsItsOwnSessionBesideTheFirst() async throws {
        typealias F = BackendRoutinesTaskEngineParityFixture
        try await F.withFixture { rig in
            let first = try await rig.local.create(F.obj([("title", .string("MT job D")), ("instructions", .string("Fix March.")), ("project", .string("/work/app")), ("assignee", .string("builder"))]))
            let firstRecord = try await rig.record(first.id)
            let one = try XCTUnwrap(firstRecord.sessionID)
            try await rig.finish(one, answer: "hand D ready")
            // The first hand's session stays open after its job (kept open), in the same folder.
            let second = try await rig.local.create(F.obj([("title", .string("MT job E")), ("instructions", .string("Fix April.")), ("project", .string("/work/app")),
                                                           ("assignee", .string("builder")), ("agtHand", .bool(true))]))
            let after = try await rig.record(second.id)
            XCTAssertEqual(after.value["agtHand"].bool, true, "the mark is on the task from the first moment")
            let two = try XCTUnwrap(after.sessionID, "the second hand started at once")
            XCTAssertNotEqual(two, one, "its own session, not the first hand's")
            let launches = await rig.probe.launches
            XCTAssertEqual(launches.count, 2)
            let stops = await rig.probe.stops
            XCTAssertFalse(stops.contains(one), "the first hand's session was not closed to make room")
        }
    }
}
