import XCTest
@testable import TerminalDeckNativeCore

/// Deck Memory, Agents side (MEMORY-SPEC §3a): three categories, memory belongs to the seat.
final class AGTSeatsTests: XCTestCase {
    private let projects = [
        PROJProject(id: "imatch", name: "iMatch", folders: ["/p/imatch"], lead: "session:abc", leadName: "Commander"),
        PROJProject(id: "crm", name: "CRM", folders: ["/p/crm"], lead: "agent:alex", leadName: "Alex"),
        PROJProject(id: "daftar", name: "Daftar", folders: ["/p/daftar"]),
        PROJProject(id: PROJProjects.independentID, name: "Independent", lead: "agent:nobody"),
    ]

    func testALeadIsNamedOnItsProjectAndIndependentNeverHasOne() {
        XCTAssertEqual(AGTSeats.lead(of: projects[0]), .init(kind: .session, id: "abc", name: "Commander", projectID: "imatch"))
        XCTAssertEqual(AGTSeats.lead(of: projects[1])?.raw, "agent:alex")
        XCTAssertNil(AGTSeats.lead(of: projects[2]))
        XCTAssertNil(AGTSeats.lead(of: projects[3]))
        XCTAssertTrue(AGTSeats.isValidLead("")); XCTAssertTrue(AGTSeats.isValidLead("agent:x")); XCTAssertTrue(AGTSeats.isValidLead("session:1"))
        for bad in ["alex", "agent:", "hoot:1", "agent:a\nb"] { XCTAssertFalse(AGTSeats.isValidLead(bad), bad) }
    }

    func testARestartedLeadSessionIsFoundAgainByNameInsideItsProject() {
        XCTAssertEqual(AGTSeats.ledProject(sessionID: "abc", sessionName: nil, sessionProjectID: nil, projects: projects)?.id, "imatch")
        XCTAssertNil(AGTSeats.ledProject(sessionID: "new-id", sessionName: "commander", sessionProjectID: "imatch", projects: projects))
        XCTAssertNil(AGTSeats.ledProject(sessionID: "new-id", sessionName: "Commander", sessionProjectID: "crm", projects: projects))
        XCTAssertNil(AGTSeats.ledProject(sessionID: "", sessionName: "", sessionProjectID: "imatch", projects: projects))
    }

    func testMemoryBelongsToTheSeatNotTheHire() {
        // Unset seat: the role named after the agent, inside its project.
        let first = AGTSeats.seat(agentID: "ios-engineer", seat: nil, projectID: "imatch", projects: projects)
        XCTAssertEqual(first, .role(projectID: "imatch", role: "ios-engineer"))
        XCTAssertEqual(first.folder, "projects/imatch/roles/ios-engineer")
        XCTAssertEqual(first.owner, .role(project: "imatch", role: "ios-engineer"))
        // A NEW hire with another id (and name) in the same role gets the very same seat: nothing is lost.
        let rehire = AGTSeats.seat(agentID: "sam-2", seat: "ios-engineer", projectID: "imatch", projects: projects)
        XCTAssertEqual(rehire, first)
        XCTAssertEqual(rehire.owner.key, first.owner.key)
        // Outside any project.
        XCTAssertEqual(AGTSeats.seat(agentID: "writer", seat: nil, projectID: PROJProjects.independentID, projects: projects).folder, "roles/writer")
        // The lead sits in the project's lead seat and keeps its own role seat for later.
        XCTAssertEqual(AGTSeats.seat(agentID: "alex", seat: nil, projectID: "crm", projects: projects), .lead(projectID: "crm"))
        XCTAssertEqual(AGTSeats.roleSeat(agentID: "alex", seat: nil, projectID: "crm"), .role(projectID: "crm", role: "alex"))
        XCTAssertEqual(AGTSeat.lead(projectID: "crm").folder, "projects/crm/lead")
    }

    func testExactlyThreeCategories() {
        XCTAssertEqual(AGTCategory.allCases.count, 3)
        XCTAssertEqual(AGTSeat.orchestrator.category, .orchestrator)
        XCTAssertEqual(AGTSeat.lead(projectID: "crm").category, .lead)
        XCTAssertEqual(AGTSeat.role(projectID: nil, role: "helper").category, .agent)
        XCTAssertEqual(AGTSeats.category(agentID: "alex", projects: projects), .lead)
        XCTAssertEqual(AGTSeats.category(agentID: "anyone", projects: projects), .agent)
    }

    func testSeatKeysRoundTripAndRolesAreSlugs() {
        for seat in [AGTSeat.orchestrator, .lead(projectID: "crm"), .role(projectID: "imatch", role: "ios"), .role(projectID: nil, role: "writer")] {
            XCTAssertEqual(AGTSeat(key: seat.key), seat, seat.key)
            XCTAssertEqual(AGTSeat(owner: seat.owner), seat, seat.key)
        }
        XCTAssertNil(AGTSeat(owner: .project("crm")))
        XCTAssertEqual(AGTSeats.slug("iOS Engineer (iMatch)"), "ios-engineer-imatch")
        XCTAssertEqual(AGTSeats.slug("  --  "), "")
        XCTAssertNil(AGTSeats.roleProblem(nil)); XCTAssertNil(AGTSeats.roleProblem("ios-engineer"))
        XCTAssertNotNil(AGTSeats.roleProblem("iOS Engineer")); XCTAssertNotNil(AGTSeats.roleProblem("../x"))
    }

    func testProjectsKeepTheirLeadThroughTheWireAndOldFilesStillLoad() throws {
        let wire = try JSONDecoder().decode(PROJProject.self, from: projects[0].wireValue.encodedJSON())
        XCTAssertEqual(wire, projects[0])
        let old = try JSONDecoder().decode(PROJProject.self, from: Data(#"{"id":"x","name":"X"}"#.utf8))
        XCTAssertEqual(old.lead, ""); XCTAssertEqual(old.leadName, "")
        let stored = try JSONDecoder().decode(PROJProject.self, from: JSONEncoder().encode(projects[1]))
        XCTAssertEqual(stored.lead, "agent:alex")
    }

    func testRoutingLinesTellHootWhoGetsAGoal() {
        let lines = AGTSeats.routingLines(projects)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("iMatch: lead Commander"))
        XCTAssertEqual(lines[2], "Daftar: no lead. Assign its agents directly.")
    }

    func testAnAgentProfileCarriesItsSeatAndTheDirectoryShowsTheRole() {
        let profile = AgentProfile(id: "sam-2", name: "Sam", projectID: "imatch", seat: "ios-engineer")
        XCTAssertEqual(profile.wire["seat"] as? String, "ios-engineer")
        let agents = AGTDirectory.build(profiles: [AGTProfileInput(profile)], live: [], tasks: [])
        let sam = agents.first { $0.id == "sam-2" }
        XCTAssertEqual(sam?.seat, "ios-engineer")
        XCTAssertEqual(sam?.wireValue["seat"].string, "ios-engineer")
        let plain = AGTDirectory.build(profiles: [AGTProfileInput(AgentProfile(id: "writer", name: "Writer"))], live: [], tasks: [])
        XCTAssertEqual(plain.first { $0.id == "writer" }?.wireValue["seat"].string, "writer")
    }

    /// TEST-RESULTS A8: changing an agent's project in its settings window dropped its role. The form now
    /// carries the role through every save.
    func testTheRoleSurvivesASaveFromTheSettingsForm() {
        let profile = AgentProfile(id: "mt-builder", name: "MT Builder", projectID: "td-memory-test", seat: "builder")
        var draft = AgentDraft(profile)
        XCTAssertEqual(draft.seat, "builder")
        draft.projectID = "other-project"
        guard case .success(let saved) = AgentForm.payload(draft, agents: [profile]) else { return XCTFail("the save was refused") }
        XCTAssertEqual(saved.seat, "builder")
        XCTAssertEqual(saved.wire["seat"] as? String, "builder", "the role goes to the engine with the save")
    }
}
