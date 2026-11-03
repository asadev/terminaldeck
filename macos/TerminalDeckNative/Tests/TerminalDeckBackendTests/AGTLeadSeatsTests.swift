import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// A project's lead seat as a task holder (a lead that is a plain session): who fills the seat, what
/// a task saves, and the delivery by SEAT against in-memory fakes (no engine, no store, no AI, no typing).
final class AGTLeadSeatsTests: XCTestCase {
    private let seat = "lead:mt"
    private func project(lead: String = "session:s1", name: String = "MT Lead") -> PROJProject {
        PROJProject(id: "mt", name: "Memory Test", folders: ["/p/mt"], lead: lead, leadName: name)
    }
    private func session(_ id: String, _ title: String = "MT Lead", project: String = "mt", provider: String = "claude") -> BackendAGTLeadSeatSession {
        .init(id: id, title: title, projectID: project, provider: provider)
    }

    /// The fakes: projects, running sessions, the open seat tasks, and everything that was done.
    private actor World {
        var projects: [PROJProject], running: [BackendAGTLeadSeatSession], tasks: [String: BackendAGTLeadSeatTask] = [:]
        var typed: [(session: String, line: String)] = [], notes: [(task: String, kind: String, text: String)] = [], handed: [(task: String, agent: String)] = []
        var busy = false
        init(projects: [PROJProject], running: [BackendAGTLeadSeatSession]) { self.projects = projects; self.running = running }
        func add(_ id: String, title: String = "Check the import", details: String = "Look at March.") {
            tasks[id] = .init(id: id, title: title, details: details, seat: "lead:mt", toldSession: nil, givenBy: "the owner")
        }
        func set(running next: [BackendAGTLeadSeatSession]) { running = next }
        func set(projects next: [PROJProject]) { projects = next }
        func set(busy next: Bool) { busy = next }
        func type(_ session: String, _ line: String) throws {
            if busy { throw NativeRPCError(code: "brief-not-delivered", message: "This session is mid-turn.") }
            typed.append((session, line))
        }
        func told(_ id: String, _ session: String?) { tasks[id]?.toldSession = session; if session != nil { tasks[id]?.toldBefore = true } }
        func note(_ id: String, _ kind: String, _ text: String) { notes.append((id, kind, text)) }
        func hand(_ id: String, _ agent: String) { handed.append((id, agent)); tasks[id] = nil }
    }
    private func seats(_ world: World) -> BackendAGTLeadSeats {
        BackendAGTLeadSeats(.init(
            projects: { await world.projects }, sessions: { await world.running },
            tell: { session, line in try await world.type(session, line) },
            tasks: { await Array(world.tasks.values).sorted { $0.id < $1.id } }, task: { await world.tasks[$0] },
            told: { id, session in await world.told(id, session) }, note: { id, kind, text in await world.note(id, kind, text) },
            handToAgent: { id, agent in await world.hand(id, agent) }))
    }

    func testWhoFillsTheSeat() {
        let running = [session("s1"), session("x9", "Scratch")]
        XCTAssertEqual(BackendAGTLeadSeats.holder(seat, projects: [project()], running: running), .session(id: "s1", name: "MT Lead", provider: "claude"))
        // A different session with the same name cannot inherit the seat.
        XCTAssertEqual(BackendAGTLeadSeats.holder(seat, projects: [project()], running: [session("s2", "mt lead")]), .away(name: "MT Lead"))
        // The same name in another project is not the lead.
        XCTAssertEqual(BackendAGTLeadSeats.holder(seat, projects: [project()], running: [session("s3", "MT Lead", project: "other")]), .away(name: "MT Lead"))
        XCTAssertEqual(BackendAGTLeadSeats.holder(seat, projects: [project()], running: []), .away(name: "MT Lead"))
        XCTAssertEqual(BackendAGTLeadSeats.holder(seat, projects: [project(lead: "agent:fixer", name: "Fixer")], running: running), .agent(id: "fixer", name: "Fixer"))
        XCTAssertEqual(BackendAGTLeadSeats.holder(seat, projects: [project(lead: "", name: "")], running: running), .vacant(project: "Memory Test"))
        XCTAssertEqual(BackendAGTLeadSeats.holder("lead:nowhere", projects: [project()], running: running), .gone)
        // Only a lead seat is an address.
        XCTAssertTrue(BackendAGTLeadSeats.isAddress(seat))
        for other in ["hoot", "me", "fixer", "role:mt/db-fixer", "lead:", "orchestrator"] { XCTAssertFalse(BackendAGTLeadSeats.isAddress(other), other) }
    }

    func testTheSeatASessionFills() {
        XCTAssertEqual(BackendAGTLeadSeats.address(of: session("s1"), projects: [project()]), seat)
        XCTAssertNil(BackendAGTLeadSeats.address(of: session("s2", "MT Lead"), projects: [project()]))
        XCTAssertNil(BackendAGTLeadSeats.address(of: session("x9", "Scratch"), projects: [project()]))
        // A project led by a saved agent has no session seat.
        XCTAssertNil(BackendAGTLeadSeats.address(of: session("s1"), projects: [project(lead: "agent:fixer", name: "Fixer")]))
    }

    func testWhatATaskSaves() async throws {
        let world = World(projects: [project()], running: [])
        let seats = seats(world)
        // A session lead, running or not: held by the seat.
        let held = try await seats.assignment(seat)
        XCTAssertEqual(held["kind"].string, "seat"); XCTAssertEqual(held["agentId"].string, seat); XCTAssertEqual(held["identity"].string, seat)
        // A saved agent leads: the task is simply that agent's.
        await world.set(projects: [project(lead: "agent:fixer", name: "Fixer")])
        let agent = try await seats.assignment(seat)
        XCTAssertEqual(agent["kind"].string, "agent"); XCTAssertEqual(agent["agentId"].string, "fixer")
        let target = await seats.mentionTarget(seat)
        XCTAssertEqual(target, "fixer")
        // Nobody leads: refused in plain words.
        await world.set(projects: [project(lead: "", name: "")])
        do { _ = try await seats.assignment(seat); XCTFail("a vacant lead seat took a task") }
        catch { XCTAssertTrue(error.localizedDescription.contains("has no lead yet"), error.localizedDescription) }
        let nobody = await seats.mentionTarget(seat)
        XCTAssertNil(nobody)
    }

    func testARunningLeadIsToldInItsOwnSession() async {
        let world = World(projects: [project()], running: [session("s1")])
        let seats = seats(world)
        await world.add("local:t1")
        await seats.assigned("local:t1"); await seats.settle()
        let typed = await world.typed
        XCTAssertEqual(typed.count, 1); XCTAssertEqual(typed.first?.session, "s1")
        let line = typed.first?.line ?? ""
        XCTAssertTrue(line.contains("A task for you as lead of Memory Test"), line)
        XCTAssertTrue(line.contains("Task id: local:t1"), line); XCTAssertTrue(line.contains("Given by: the owner"), line)
        XCTAssertTrue(line.contains("tasks_comment"), line)
        XCTAssertFalse(line.contains("\n"), "one line only: it is typed into a terminal")
        let told = await world.tasks["local:t1"]?.toldSession
        XCTAssertEqual(told, "s1")
        // A comment on it is typed into the same session, once.
        try? await seats.said("local:t1", text: "Any news?\nSecond line.", by: "the owner"); await seats.settle()
        let after = await world.typed
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after[1].line.contains("The owner wrote on your task \"Check the import\": “Any news? Second line.”"), after[1].line)
    }

    func testAnAwayLeadGetsItWhenItsSessionIsBack() async {
        let world = World(projects: [project()], running: [])
        let seats = seats(world)
        await world.add("local:t1")
        await seats.assigned("local:t1"); await seats.settle()
        var typed = await world.typed
        XCTAssertTrue(typed.isEmpty)
        let waiting = await world.notes
        XCTAssertEqual(waiting.count, 1); XCTAssertTrue(waiting.first?.text.contains("Not running right now") == true)
        // A comment while it is away waits too, and the waiting line is not written twice.
        try? await seats.said("local:t1", text: "Still needed.", by: "the owner"); await seats.settle()
        let notes = await world.notes
        XCTAssertEqual(notes.count, 1)
        // The session comes back with a NEW id and the same name; when it goes calm the task is typed there.
        await world.set(running: [session("s7", "MT Lead")])
        await seats.calm(sessionID: "s7")
        let unrelated = await world.typed
        XCTAssertTrue(unrelated.isEmpty)
        await world.set(projects: [project(lead: "session:s7")])
        await seats.calm(sessionID: "other"); await seats.calm(sessionID: "s7")
        typed = await world.typed
        XCTAssertEqual(typed.map(\.session), ["s7"])
        XCTAssertTrue(typed.first?.line.contains("A task for you as lead of") == true)
        let told = await world.tasks["local:t1"]?.toldSession
        XCTAssertEqual(told, "s7")
        // Nothing waits any more: another calm moment types nothing.
        await seats.calm(sessionID: "s7")
        let again = await world.typed
        XCTAssertEqual(again.count, 1)
    }

    func testARestartedSessionIsToldAgainAndSaysSo() async {
        let world = World(projects: [project()], running: [session("s1")])
        let seats = seats(world)
        await world.add("local:t1")
        await seats.assigned("local:t1"); await seats.settle()
        // The session ends: the task waits for the seat again.
        await world.set(running: [])
        await seats.ended(sessionID: "s1"); await seats.settle()
        let waiting = await world.tasks["local:t1"]?.toldSession
        XCTAssertNil(waiting)
        // A new session takes the seat (same name): a comment now tells the task again, saying it still holds it.
        await world.set(running: [session("s2")])
        await world.set(projects: [project(lead: "session:s2")])
        try? await seats.said("local:t1", text: "Are you back?", by: "the owner"); await seats.settle()
        let typed = await world.typed
        XCTAssertEqual(typed.map(\.session), ["s1", "s2"])
        XCTAssertTrue(typed[1].line.contains("You still hold this task as lead of Memory Test"), typed[1].line)
        XCTAssertTrue(typed[1].line.contains("read it with tasks_get"), typed[1].line)
    }

    func testABusyPromptIsTriedAgainWhenTheSessionIsFree() async {
        let world = World(projects: [project()], running: [session("s1")])
        let seats = seats(world)
        await world.add("local:t1"); await world.set(busy: true)
        await seats.assigned("local:t1"); await seats.settle()
        var typed = await world.typed
        XCTAssertTrue(typed.isEmpty)
        let notes = await world.notes
        XCTAssertEqual(notes.count, 1); XCTAssertTrue(notes.first?.text.contains("could not be told yet") == true, notes.first?.text ?? "")
        await world.set(busy: false)
        await seats.calm(sessionID: "s1")
        typed = await world.typed
        XCTAssertEqual(typed.count, 1)
    }

    func testASavedAgentTakingTheSeatGetsItsTasks() async {
        let world = World(projects: [project()], running: [])
        let seats = seats(world)
        await world.add("local:t1"); await world.add("local:t2")
        await world.set(projects: [project(lead: "agent:fixer", name: "Fixer")])
        await seats.sweep()
        let handed = await world.handed
        XCTAssertEqual(handed.map(\.task).sorted(), ["local:t1", "local:t2"]); XCTAssertEqual(Set(handed.map(\.agent)), ["fixer"])
    }

    // MARK: Through the real task engine (memory stores, no AI, typing recorded)

    /// What gets typed, and which sessions run.
    private actor Typing {
        var running: [BackendAGTLeadSeatSession], lines: [(session: String, line: String)] = []
        init(_ running: [BackendAGTLeadSeatSession]) { self.running = running }
        func set(_ next: [BackendAGTLeadSeatSession]) { running = next }
        func type(_ session: String, _ line: String) { lines.append((session, line)) }
    }
    private typealias F = BackendRoutinesTaskEngineParityFixture

    func testASessionLeadHoldsATaskIsAskedFromACommentAndSurvivesARestart() async throws {
        let led = project(), s1 = session("s1"), s2 = session("s1")
        try await F.withFixture { rig in
            let typing = Typing([s1])
            let seats = BackendAGTLeadSeats(.live(store: rig.store, engine: rig.engine, local: rig.local, configuration: rig.config,
                projects: { [led] }, sessions: { await typing.running }, tell: { session, line in await typing.type(session, line) }))
            BackendAGTLeadSeats.shared = seats
            defer { BackendAGTLeadSeats.shared = nil }
            let detail = BackendTaskDetailService(store: rig.store, local: rig.local, people: .native(configuration: rig.config), problem: { _ in })

            // 1. Given to the seat: held by the seat, typed into the session filling it, never started by the engine.
            let task = try await rig.local.create(F.obj([("title", .string("Plan the import")), ("instructions", .string("Say how you would do it.")), ("assignee", .string("lead:mt"))]))
            await seats.settle()
            var now = try await rig.record(task.id)
            XCTAssertEqual(now.assigneeKind, "seat"); XCTAssertEqual(now.agentID, "lead:mt"); XCTAssertNil(now.sessionID)
            XCTAssertEqual(now.project, "/p/mt", "the seat's project folder when none was given")
            XCTAssertEqual(now.process, "running"); XCTAssertEqual(now.value["seatSession"].string, "s1"); XCTAssertEqual(now.value["crmStatus"].string, "Working on it")
            var lines = await typing.lines
            XCTAssertEqual(lines.count, 1); XCTAssertTrue(lines.first?.line.contains("Task id: \(task.id)") == true, lines.first?.line ?? "nothing was typed")
            let launched = await rig.probe.launches
            XCTAssertTrue(launched.isEmpty, "no session is started for a seat")

            // 2. A comment on it reaches the same session and is receipted as delivered.
            let posted = await detail.call("addTaskComment", arguments: [.string(task.id), .string("Any news?")])
            await seats.settle()
            XCTAssertEqual(posted["delivery"]["state"].string, "delivered", "\(posted)")
            lines = await typing.lines
            XCTAssertEqual(lines.count, 2); XCTAssertTrue(lines.last?.line.contains("wrote on your task \"Plan the import\": “Any news?”") == true, lines.last?.line ?? "nothing was typed")

            // 3. Asked with @ from another task's comment: a question task held by the seat, answered in that thread.
            let other = try await rig.local.create(F.obj([("title", .string("Move the app")), ("instructions", .string("Move it.")), ("project", .string("/work/app")), ("assignee", .string("me"))]))
            _ = await detail.call("addTaskCommentWith", arguments: [.string(other.id), .string("@MT Lead which port does it use?"),
                F.obj([("mentions", .array([F.obj([("kind", .string("agent")), ("id", .string("lead:mt")), ("name", .string("MT Lead"))])]))])])
            await seats.settle()
            let asked = try await rig.store.all().filter { $0.value["askedFromTask"].string == other.id }
            let question = try XCTUnwrap(asked.first)
            XCTAssertEqual(asked.count, 1, "the picked mention and the @name in the text are one question")
            XCTAssertEqual(question.assigneeKind, "seat"); XCTAssertEqual(question.agentID, "lead:mt")
            lines = await typing.lines
            XCTAssertTrue(lines.last?.line.contains("asked you this in a comment on the task “Move the app”") == true, lines.last?.line ?? "")
            // The lead answers with tasks_comment on the question: it closes itself and the answer shows in the asking thread.
            try await rig.engine.comment(question.id, kind: "progress", text: "Port 8080.", by: "lead:mt")
            try await rig.engine.seatSpoke(question.id, kind: "progress", text: "Port 8080.")
            let answered = try await rig.record(question.id)
            XCTAssertEqual(answered.value["crmStatus"].string, "Done"); XCTAssertEqual(answered.process, "exited"); XCTAssertEqual(answered.value["result"]["answer"].string, "Port 8080.")
            let rows = await detail.call("listTaskComments", arguments: [.string(other.id)])["comments"].elements ?? []
            XCTAssertNotNil(rows.first { $0["body"].string == "Port 8080." }, "the seat's answer in the asking thread: \(rows)")

            // 4. The lead's session ends: its task waits for the seat. A new session with its name gets it again.
            await typing.set([])
            await seats.ended(sessionID: "s1"); await seats.settle()
            now = try await rig.record(task.id)
            XCTAssertEqual(now.process, "queued"); XCTAssertTrue(now.value["seatSession"].isNullish); XCTAssertEqual(now.assigneeKind, "seat")
            await typing.set([s2])
            await seats.calm(sessionID: "s1")
            now = try await rig.record(task.id)
            XCTAssertEqual(now.process, "running"); XCTAssertEqual(now.value["seatSession"].string, "s1")
            lines = await typing.lines
            XCTAssertEqual(lines.last?.session, "s1"); XCTAssertTrue(lines.last?.line.contains("You still hold this task") == true, lines.last?.line ?? "")
            XCTAssertEqual(lines.filter { $0.session == "s1" && $0.line.contains("You still hold this task") }.count, 1, "the answered question is not told again")

            // 5. A progress line keeps it open; "completion" finishes it for the owner to check.
            try await rig.engine.seatSpoke(task.id, kind: "progress", text: "Half way.")
            let open = try await rig.record(task.id)
            XCTAssertTrue(open.value["result"].isNullish)
            try await rig.engine.seatSpoke(task.id, kind: "completion", text: "Plan written.")
            now = try await rig.record(task.id)
            XCTAssertEqual(now.process, "exited"); XCTAssertEqual(now.value["result"]["answer"].string, "Plan written."); XCTAssertEqual(now.value["result"]["verified"].bool, false)
        }
    }

    func testALeadWithoutTaskToolsIsToldToAnswerInItsSession() {
        let task = BackendAGTLeadSeatTask(id: "local:t1", title: "Check", details: "", seat: seat, toldSession: nil, givenBy: "Hoot")
        let plain = BackendAGTLeadSeats.brief(task, project: "Memory Test", tools: false, again: false)
        XCTAssertTrue(plain.contains("no task tools"), plain); XCTAssertFalse(plain.contains("tasks_comment"), plain)
        // 11 Oct (Asad): the AI does not decide authority. Every AI the app can hand its tools to has them;
        // only one without a way to take an MCP server (a plain shell) is told to answer in its session.
        for provider in ["claude", "codex", "gemini"] { XCTAssertTrue(BackendAGTLeadSeats.hasTaskTools(provider: provider)) }
        XCTAssertFalse(BackendAGTLeadSeats.hasTaskTools(provider: "shell"))
    }
}
