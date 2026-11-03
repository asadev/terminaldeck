import XCTest
@testable import TerminalDeckNativeCore

/// 13 Oct: a session the person opens in a project led by a saved agent works as that lead (named after it, in
/// the lead seat), and a project with no lead is offered the name its own CLAUDE.md gives its AI.
final class AGTWorksAsLeadTests: XCTestCase {
    private let projects = [
        PROJProject(id: "imatch", name: "iMatch", folders: ["/p/ClaudeiMatch"], lead: "agent:commander", leadName: "Commander"),
        PROJProject(id: "crm", name: "CRM", folders: ["/p/ClaudeCRM"], lead: "session:abc", leadName: "Alex"),
        PROJProject(id: "daftar", name: "Daftar", folders: ["/p/daftar"]),
        PROJProject(id: PROJProjects.independentID, name: "Independent", lead: "agent:nobody"),
    ]

    func testOnlyAProjectLedByASavedAgentTakesItsFolderSessions() {
        XCTAssertEqual(AGTSeats.folderLead(sessionProjectID: "imatch", projects: projects)?.id, "imatch")
        // A session lead is the one session the person chose: other sessions in its folder stay plain.
        XCTAssertNil(AGTSeats.folderLead(sessionProjectID: "crm", projects: projects))
        XCTAssertNil(AGTSeats.folderLead(sessionProjectID: "daftar", projects: projects))
        XCTAssertNil(AGTSeats.folderLead(sessionProjectID: PROJProjects.independentID, projects: projects))
        XCTAssertNil(AGTSeats.folderLead(sessionProjectID: nil, projects: projects))
    }

    private func live(_ id: String, title: String, folder: String, session: String) -> AWWatchAgent {
        AWWatchAgent(id: id, sourceID: session, kind: "session", name: title, provider: "claude", project: folder, machineID: "",
                     machineName: "This Mac", sessionID: session, taskID: nil, taskTitle: nil, state: .waiting, action: "Waiting for you",
                     since: nil, updatedAt: nil)
    }

    func testASessionInTheLeadSeatShowsUnderTheLeadsNameUnlessThePersonNamedIt() {
        let rows = [live("a", title: "ClaudeiMatch", folder: "/p/ClaudeiMatch", session: "s1"),
                    live("b", title: "Fix the matcher", folder: "/p/ClaudeiMatch", session: "s2"),
                    live("c", title: "ClaudeiMatch", folder: "/p/ClaudeiMatch", session: "s3"),
                    live("d", title: "daftar", folder: "/p/daftar", session: "s4")]
        let seats = ["s1": "lead:imatch", "s2": "lead:imatch", "s4": "role:daftar/writer"]
        let agents = AGTDirectory.build(profiles: [], live: rows, tasks: [], sessionSeats: seats, projects: projects)
        func row(_ session: String) -> AGTAgent? { agents.first { $0.sessionID == session } }
        // Default title (its folder's name) → the lead's name; its own title is kept beside it.
        XCTAssertEqual(row("s1")?.name, "Commander"); XCTAssertEqual(row("s1")?.sessionTitle, "ClaudeiMatch"); XCTAssertEqual(row("s1")?.sitsIn, "lead:imatch")
        // A title the person gave it stays; it still sits in the lead seat.
        XCTAssertEqual(row("s2")?.name, "Fix the matcher"); XCTAssertEqual(row("s2")?.sitsIn, "lead:imatch")
        // No seat from the app: nothing is guessed.
        XCTAssertEqual(row("s3")?.name, "ClaudeiMatch"); XCTAssertNil(row("s3")?.sitsIn)
        // A role seat never renames a session.
        XCTAssertEqual(row("s4")?.name, "daftar"); XCTAssertEqual(row("s4")?.sitsIn, "role:daftar/writer")
        // Agents and their tools see the same.
        XCTAssertEqual(row("s1")?.wireValue["sitsIn"].string, "lead:imatch")
        XCTAssertEqual(row("s1")?.wireValue["sessionTitle"].string, "ClaudeiMatch")
        // Without seats (an older caller) the rows are as before.
        XCTAssertEqual(AGTDirectory.build(profiles: [], live: rows, tasks: []).first { $0.sessionID == "s1" }?.name, "ClaudeiMatch")
    }

    /// 13 Oct, install 19 ("why I see Commander twice"): a session working as a saved agent is never a card of its own.
    func testASessionWorkingAsASavedAgentShowsOnItsOneCard() {
        let profiles = [AGTProfileInput(id: "commander", name: "Commander", role: "Lead of iMatch", provider: "claude", projectID: "imatch"),
                        AGTProfileInput(id: "matchmaker", name: "matchmaker", provider: "claude", projectID: "imatch")]
        var waiting = live("c", title: "ClaudeiMatch", folder: "/p/ClaudeiMatch", session: "s3")
        waiting = AWWatchAgent(id: waiting.id, sourceID: waiting.sourceID, kind: "session", name: "ClaudeiMatch", provider: "claude", project: "/p/ClaudeiMatch",
                               machineID: "", machineName: "This Mac", sessionID: "s3", taskID: nil, taskTitle: nil, state: .working, action: "Working",
                               since: nil, updatedAt: nil)
        let rows = [live("a", title: "ClaudeiMatch", folder: "/p/ClaudeiMatch", session: "s1"), waiting,
                    live("b", title: "ClaudeiMatch", folder: "/p/ClaudeiMatch", session: "s2"),
                    live("d", title: "daftar", folder: "/p/daftar", session: "s4")]
        // s1 and s3 work as the lead (opened by hand in iMatch); s2 was started as matchmaker; s4 is plain.
        let seats = ["s1": "lead:imatch", "s3": "lead:imatch", "s2": "role:imatch/matchmaker"]
        let agents = AGTDirectory.build(profiles: profiles, live: rows, tasks: [], sessionSeats: seats, projects: projects)
        // One card per agent: no session card for s1, s2 or s3.
        XCTAssertEqual(agents.filter { $0.name == "Commander" }.count, 1)
        XCTAssertNil(agents.first { $0.kind == .session && ["s1", "s2", "s3"].contains($0.sessionID ?? "") })
        let commander = agents.first { $0.profileID == "commander" }
        XCTAssertEqual(Set(commander?.sessionIDs ?? []), ["s1", "s3"]); XCTAssertEqual(commander?.live, .working, "the busiest session is its status")
        XCTAssertEqual(agents.first { $0.profileID == "matchmaker" }?.sessionIDs, ["s2"])
        XCTAssertEqual(agents.first { $0.profileID == "matchmaker" }?.live, .waiting)
        // A plain session keeps its own row.
        XCTAssertEqual(agents.first { $0.sessionID == "s4" }?.kind, .session)
        // The counts the page shows count agents: Hoot, 2 agents, 1 plain session; 1 working, 1 waiting (not 2 and 2).
        XCTAssertEqual(agents.count, 4)
        XCTAssertEqual(agents.filter { $0.kind != .hoot && $0.live == .working }.count, 1)
        XCTAssertEqual(agents.filter { $0.live == .waiting }.count, 2, "matchmaker and the plain session")
        XCTAssertEqual(commander?.wireValue["sessions"].elements?.count, 2)
        // A lead that is a session (crm) holds no card to fold into: its session stays a row of its own.
        let crm = AGTDirectory.build(profiles: [], live: [live("e", title: "ClaudeCRM", folder: "/p/ClaudeCRM", session: "s5")], tasks: [],
                                     sessionSeats: ["s5": "lead:crm"], projects: projects)
        XCTAssertEqual(crm.first { $0.sessionID == "s5" }?.kind, .session)
    }

    func testDeckerAlsoHasOneCardAndOnlyLiveSessionsCount() throws {
        let deck = try JSONDecoder().decode(PROJProject.self, from: Data(#"{"id":"deck-dev","name":"Deck Dev","folders":["/scratch/Deck Dev"],"lead":"agent:decker","leadName":"Decker"}"#.utf8))
        let profiles = [AGTProfileInput(id: "decker", name: "Decker", provider: "codex", projectID: deck.id)]
        let rows = [live("d1", title: "Deck Dev", folder: "/scratch/Deck Dev", session: "d1"),
                    live("d2", title: "My build", folder: "/scratch/Deck Dev", session: "d2")]
        let agents = AGTDirectory.build(profiles: profiles, live: rows, tasks: [],
            sessionSeats: ["d1": "lead:deck-dev", "d2": "lead:deck-dev"], projects: [deck])
        XCTAssertEqual(agents.filter { $0.name == "Decker" }.count, 1)
        XCTAssertEqual(agents.filter { $0.kind == .session }.count, 0)
        XCTAssertEqual(Set(agents.first { $0.profileID == "decker" }?.sessionIDs ?? []), ["d1", "d2"])
        XCTAssertEqual(agents.filter { $0.live == .waiting }.count, 1)
    }

    func testTheNameAProjectsOwnInstructionsGiveItsAI() {
        XCTAssertEqual(AGTDeclaredLead.name(in: "# CLAUDE.md — Commander Boot File\n\nYou are **Commander** 🎯 — Asad's personal AI orchestrator."), "Commander")
        XCTAssertEqual(AGTDeclaredLead.name(in: "# CLAUDE.md\n\n## Who You Are\n\n**You are Decker, the lead of the Terminal Deck team.** Asad's build partner."), "Decker")
        XCTAssertEqual(AGTDeclaredLead.name(in: "You are **Alex** 🧭 — Asad's personal AI orchestrator for **iLoop**."), "Alex")
        XCTAssertEqual(AGTDeclaredLead.name(in: "Intro\nYou are Max Power, the lead of this repo."), "Max Power")
        // Not a name: a description, an AI's own product name, or nothing at all.
        for text in ["You are a careful reviewer.", "You are **not** allowed to push.", "You are Claude Code, working here.",
                     "# Notes\nNothing about anyone.", "you are commander"] {
            XCTAssertNil(AGTDeclaredLead.name(in: text), text)
        }
        // Only the top of the file counts.
        XCTAssertNil(AGTDeclaredLead.name(in: String(repeating: "line\n", count: 80) + "You are **Late**."))
    }

    func testTheFirstDeclarationInTheProjectsFoldersWins() {
        let files = ["/p/one/AGENTS.md": "You are **Codey**.", "/p/two/CLAUDE.md": "You are **Commander**.", "/p/one/README.md": "You are **No**."]
        let found = AGTDeclaredLead.find(folders: ["/p/one", "/p/two/"]) { files[$0] }
        XCTAssertEqual(found, .init(name: "Codey", file: "AGENTS.md", path: "/p/one/AGENTS.md", provider: "codex"))
        XCTAssertEqual(AGTDeclaredLead.find(folders: ["/p/two"]) { files[$0] }?.provider, "claude")
        XCTAssertNil(AGTDeclaredLead.find(folders: ["/p/none"]) { files[$0] })
    }
}
