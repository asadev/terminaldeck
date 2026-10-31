import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 13 Oct (Asad: iMatch showed "ClaudeiMatch — Claude Code session, nobody's hire" and no Commander): on the
/// Agents page a session the app seated in a project's lead seat shows as that lead, hangs under the lead, and
/// is never offered "Stop leading" (that would remove the real lead). A project with no lead is offered the
/// name its own CLAUDE.md gives its AI. Fixture data only.
final class AGTWorksAsLeadUITests: XCTestCase {
    @MainActor private func withFixture(_ body: () throws -> Void) rethrows {
        let store = AGTAgentsStore.shared, hands = AGTHandsStore.shared, declared = AGTDeclaredLeads.shared
        let saved = (store.fixture, store.live, store.liveLoaded, store.openProfile, NativePROJLabels.shared.projects)
        defer {
            store.fixture = saved.0; store.live = saved.1; store.liveLoaded = saved.2; store.openProfile = saved.3
            NativePROJLabels.shared.projects = saved.4; hands.fixture = nil; declared.fixture = nil
        }
        NativePROJLabels.shared.projects = [
            PROJProject(id: "imatch", name: "iMatch", folders: ["/work/ClaudeiMatch"], lead: "agent:commander", leadName: "Commander"),
            PROJProject(id: "daftar", name: "Daftar", folders: ["/work/daftar"]),
            PROJProject(id: PROJProjects.independentID, name: "Independent"),
        ]
        store.fixture = TasksState(agents: [
            AgentProfile(id: "commander", name: "Commander", provider: "claude", status: .active, projectID: "imatch"),
            AgentProfile(id: "matchmaker", name: "matchmaker", provider: "claude", status: .active, projectID: "imatch"),
        ])
        store.live = [Self.session("a", title: "ClaudeiMatch", folder: "/work/ClaudeiMatch", session: "s1"),
                      Self.session("b", title: "daftar", folder: "/work/daftar", session: "s2")]
        store.liveLoaded = true; store.openProfile = nil; store.search = ""; store.message = nil
        hands.fixture = [.init(seat: .lead("imatch"), number: 1, sessionID: "s1", job: "", taskID: nil, startedAt: Date())]
        declared.fixture = ["daftar": .init(name: "Munshi", file: "CLAUDE.md", path: "/work/daftar/CLAUDE.md", provider: "claude")]
        try body()
    }

    static func session(_ id: String, title: String, folder: String, session: String) -> AWWatchAgent {
        AWWatchAgent.decode(.object([
            .init("id", .string("fixture-live:" + id)), .init("sourceID", .string(session)), .init("kind", .string("session")),
            .init("name", .string(title)), .init("state", .string("waiting")), .init("project", .string(folder)),
            .init("sessionID", .string(session)), .init("machineName", .string("This Mac")), .init("provider", .string("claude")),
            .init("action", .string("Waiting for you")),
        ]))!
    }

    @MainActor func testASessionWorkingAsTheLeadIsOnTheLeadsOneCard() throws {
        try withFixture {
            let store = AGTAgentsStore.shared
            let agents = store.agents
            // One Commander: the saved agent. The session working as it is on its card, not a card of its own.
            XCTAssertEqual(agents.filter { $0.name == "Commander" }.count, 1)
            XCTAssertNil(agents.first { $0.kind == .session && $0.sessionID == "s1" })
            let commander = try XCTUnwrap(agents.first { $0.profileID == "commander" })
            XCTAssertEqual(commander.sessionIDs, ["s1"]); XCTAssertEqual(commander.live, .waiting, "its status comes from the session")
            XCTAssertEqual(store.liveSessions(of: commander).map(\.sessionID), ["s1"])
            XCTAssertEqual(AGTLeads.madeLead(commander)?.id, "imatch")
            // The org chart has the same single node: no extra row for the session, nothing hangs under Commander but its agents.
            let org = AGTLeads.orgAgents(agents)
            XCTAssertEqual(org.filter { $0.name == "Commander" }.count, 1)
            XCTAssertEqual(AGTLeads.handRows(for: commander).count, 0, "one hand is just the agent")
            // R20: the Agents page lists named agents, never project/session cards.
            let scoped = agents.filter { $0.status != "archived" }
            XCTAssertEqual(scoped.count, 3) // Hoot plus the two saved profiles.
            XCTAssertEqual(scoped.filter { $0.live == .waiting }.count, 1)
            XCTAssertNil(agents.first { $0.sessionID == "s2" })
        }
    }

    @MainActor func testSeveralLeadSessionsStillMakeOnlyOneOrgNodeAndSidebarAgent() throws {
        try withFixture {
            let store = AGTAgentsStore.shared
            store.live.append(Self.session("c", title: "Build", folder: "/work/ClaudeiMatch", session: "s3"))
            AGTHandsStore.shared.fixture?.append(.init(seat: .lead("imatch"), number: 2, sessionID: "s3", job: "Build", taskID: nil, startedAt: Date()))
            let commander = try XCTUnwrap(store.agents.first { $0.profileID == "commander" })
            XCTAssertEqual(Set(commander.sessionIDs), ["s1", "s3"])
            XCTAssertEqual(store.liveSessions(of: commander).count, 2)
            XCTAssertTrue(AGTLeads.handRows(for: commander).isEmpty)
            XCTAssertEqual(AGTLeads.orgAgents(store.agents).filter { $0.name == "Commander" }.count, 1)
            XCTAssertEqual(SIDEBARSessionAgents.all()["s1"]?.profileID, "commander")
            XCTAssertEqual(SIDEBARSessionAgents.all()["s3"]?.profileID, "commander")
        }
    }

    /// R20: a session cannot invent a named agent while its saved profile is absent.
    @MainActor func testASessionSeatedAsTheLeadWithNoSavedAgentWaitsForItsProfile() throws {
        withFixture {
            let store = AGTAgentsStore.shared
            store.fixture = TasksState(agents: [AgentProfile(id: "matchmaker", name: "matchmaker", provider: "claude", status: .active, projectID: "imatch")])
            XCTAssertNil(store.agents.first { $0.sessionID == "s1" })
            XCTAssertEqual(store.agents.filter { $0.kind == .profile }.map(\.name), ["matchmaker"])
        }
    }

    @MainActor func testAProjectWithNoLeadIsOfferedTheNameItsFolderGives() throws {
        try withFixture {
            let projects = NativePROJLabels.shared.projects
            let offers = AGTDeclaredLeads.shared.offers(in: projects, projectID: nil)
            XCTAssertEqual(offers.map(\.project.id), ["daftar"])
            XCTAssertEqual(offers.first?.declared.name, "Munshi")
            // A project that has a lead is never offered one; nor is another project's view.
            XCTAssertTrue(AGTDeclaredLeads.shared.offers(in: projects, projectID: "imatch").isEmpty)
            XCTAssertTrue(AGTDeclaredLeads.confirmDetail(offers[0].declared, project: offers[0].project).contains("saves an agent called Munshi"))
        }
    }

    @MainActor func testMakingTheDeclaredNameTheLeadSavesItAndNamesItOnTheProject() async throws {
        let store = AGTAgentsStore.shared
        let saved = (store.fixture, NativePROJLabels.shared.projects)
        defer { store.fixture = saved.0; NativePROJLabels.shared.projects = saved.1 }
        NativePROJLabels.shared.projects = [PROJProject(id: "daftar", name: "Daftar", folders: ["/work/daftar"]),
                                            PROJProject(id: PROJProjects.independentID, name: "Independent")]
        store.fixture = TasksState(agents: [])
        let declared = AGTDeclaredLead.Found(name: "Munshi", file: "CLAUDE.md", path: "/work/daftar/CLAUDE.md", provider: "claude")
        let made = await AGTLeads.makeDeclaredLead(declared, of: NativePROJLabels.shared.projects[0])
        XCTAssertTrue(made)
        let profile = try XCTUnwrap(store.profiles.first { $0.name == "Munshi" })
        XCTAssertEqual(profile.projectID, "daftar"); XCTAssertEqual(profile.provider, "claude"); XCTAssertEqual(profile.defaultProject, "/work/daftar")
        XCTAssertEqual(NativePROJLabels.shared.projects[0].lead, "agent:" + profile.id)
        XCTAssertEqual(NativePROJLabels.shared.projects[0].leadName, "Munshi")
        // Asked again, the same agent is used: no second Munshi.
        NativePROJLabels.shared.projects[0].lead = ""
        _ = await AGTLeads.makeDeclaredLead(declared, of: NativePROJLabels.shared.projects[0])
        XCTAssertEqual(store.profiles.filter { $0.name == "Munshi" }.count, 1)
    }
}
