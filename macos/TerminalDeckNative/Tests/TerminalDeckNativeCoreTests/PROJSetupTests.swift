import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// PROJECT-GUIDE (Asad, 11 Oct): a folder opened alone is not a project; the setup score and its missing parts.
@Suite("PROJ setup")
struct PROJSetupTests {
    private let imatch = PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], logo: "imatch-1.png", lead: "agent:boss", leadName: "Boss")

    // MARK: Open folder ≠ project

    @Test func anOpenFolderOutsideEveryProjectIsPlainAndIndependent() {
        let registry = [imatch, PROJProjects.independent]
        let split = PROJOpenFolders.split(["/scratch/iMatch", "/scratch/iMatch/api", "/scratch/Notes", "not-a-path"], registry: registry)
        #expect(split.projects == ["/scratch/iMatch", "/scratch/iMatch/api"])
        #expect(split.plain == ["/scratch/Notes"])
        #expect(!PROJOpenFolders.isProject("/scratch/Notes", registry: registry))
        #expect(PROJProjects.resolve(projectID: nil, folder: "/scratch/Notes", projects: registry) == PROJProjects.independentID)
        // A folder whose name only starts like a project's folder is still plain.
        #expect(!PROJOpenFolders.isProject("/scratch/iMatchOld", registry: registry))
        // With nothing registered, every open folder is plain.
        #expect(PROJOpenFolders.split(["/a", "/b"], registry: [PROJProjects.independent]).plain == ["/a", "/b"])
    }

    /// Asad, 11 Oct: "i am not seeing terminal deck in side panel as project means Deck Dev". A registered project
    /// whose folder has a space shows under Projects with its registered name, even when the page's folder list lags.
    @Test func aRegisteredProjectWithASpaceInItsFolderIsListedUnderProjects() {
        let deck = PROJProject(id: "terminal-deck", name: "Terminal Deck", folders: ["/Users/me/Deck Dev"])
        let registry = [imatch, deck, PROJProjects.independent]
        #expect(PROJOpenFolders.isProject("/Users/me/Deck Dev", registry: registry))
        #expect(PROJOpenFolders.isProject("/Users/me/Deck Dev/code/app", registry: registry))
        #expect(!PROJOpenFolders.isProject("/Users/me/Deck", registry: registry))
        // The page knows iMatch and a plain folder only: Terminal Deck is still a row, by its first folder and name.
        let open = [SidebarProject(id: "/scratch/iMatch", title: "iMatch", expanded: false, sessions: []),
                    SidebarProject(id: "/scratch/Notes", title: "Notes", expanded: false, sessions: [])]
        let rows = SIDEBARLayout.projectRows(open: open, registry: registry)
        #expect(rows.map(\.id) == ["/scratch/iMatch", "/Users/me/Deck Dev"])
        #expect(rows.last?.title == "Terminal Deck")
        // Once the page lists the folder (with its space), it is listed once, from the page.
        let both = open + [SidebarProject(id: "/Users/me/Deck Dev", title: "Deck Dev", expanded: false, sessions: [])]
        #expect(SIDEBARLayout.projectRows(open: both, registry: registry).map(\.id) == ["/scratch/iMatch", "/Users/me/Deck Dev"])
        // Independent and a project with no folder are never rows.
        let empty = PROJProject(id: "empty", name: "Empty")
        #expect(SIDEBARLayout.projectRows(open: [], registry: [empty, PROJProjects.independent]).isEmpty)
    }

    @Test func newProjectIDsAreValidUniqueAndNeverIndependent() {
        #expect(PROJSetup.projectID(for: "My App!", taken: []) == "my-app")
        #expect(PROJSetup.projectID(for: "My App", taken: ["my-app"]) == "my-app-2")
        #expect(PROJSetup.projectID(for: "Independent", taken: []) == "independent-2")
        #expect(PROJSetup.projectID(for: "   ", taken: []) == "project")
        #expect(PROJSetup.projectID(for: "Café Ünïcode", taken: []) == "cafe-unicode")
        #expect(PROJProjects.isValidID(PROJSetup.projectID(for: String(repeating: "x-", count: 200), taken: [])))
    }

    // MARK: Score

    @Test func emptyProjectScoresZeroWithEveryPartMissing() {
        let score = PROJSetup.score(.init())
        #expect(score.percent == 0)
        #expect(score.missing == PROJSetupPart.allCases)
        #expect(!score.complete)
    }

    @Test func everyPartSetScoresAHundredAndTheCardGoesAway() {
        let score = PROJSetup.score(.init(about: "Dating app", logo: "a.png", lead: "agent:boss", teamAgents: 2, agentsWithSkills: 1,
                                          cardText: "# Lead\n\n## Goals\n- Ship v2\n"))
        #expect(score.percent == 100)
        #expect(score.complete)
        #expect(score.missing.isEmpty)
    }

    @Test func eachPartCountsOneSixth() {
        #expect(PROJSetup.score(.init(about: "x")).percent == 17)
        #expect(PROJSetup.score(.init(about: "x", logo: "l")).percent == 33)
        #expect(PROJSetup.score(.init(about: "x", logo: "l", lead: "agent:a")).percent == 50)
        #expect(PROJSetup.score(.init(about: "  ")).missing.contains(.description))
    }

    @Test func hootLeadsForNowCountsAsALeadChoice() {
        #expect(PROJSetup.score(.init(hootLeads: true)).done == [.lead])
        #expect(PROJSetup.score(.init(lead: "session:s1")).done == [.lead])
    }

    @Test func aMissingPartComesBackWhenItGoesMissingAgain() {
        var facts = PROJSetupFacts(about: "x", logo: "l", lead: "agent:a", teamAgents: 1, agentsWithSkills: 1, cardText: "- Goal: ship")
        #expect(PROJSetup.score(facts).complete)
        facts.teamAgents = 0
        #expect(PROJSetup.score(facts).missing == [.team])
        #expect(PROJSetup.score(facts).percent == 83)
    }

    @Test func factsCountTheTeamWithoutTheLeadAndSkillsAcrossTheProject() {
        let agents = [
            PROJSetupAgent(id: "boss", projectID: "imatch", skills: ["review"]),
            PROJSetupAgent(id: "ios", projectID: "imatch"),
            PROJSetupAgent(id: "old", projectID: "imatch", skills: ["x"], archived: true),
            PROJSetupAgent(id: "elsewhere", projectID: "crm", skills: ["y"]),
        ]
        let settings = NativeRPCValue.object([.init("projectId", .string("imatch")),
                                              .init("values", .object([.init("about", .string("Dating app"))]))])
        let facts = PROJSetup.facts(project: imatch, settings: settings, agents: agents, card: "# Lead of iMatch\n\n## Goals\n- \n")
        #expect(facts.about == "Dating app")
        #expect(facts.teamAgents == 1)         // ios (boss leads, old is archived, elsewhere is CRM's)
        #expect(facts.agentsWithSkills == 1)   // boss
        #expect(facts.lead == "agent:boss")
        let score = PROJSetup.score(facts)
        #expect(score.missing == [.card])
        #expect(score.percent == 83)
    }

    @Test func hootLeadsSettingIsRead() {
        let settings = NativeRPCValue.object([.init("values", .object([.init(PROJSetup.hootLeadsKey, .bool(true))]))])
        let project = PROJProject(id: "crm", name: "CRM", folders: ["/scratch/CRM"])
        #expect(PROJSetup.facts(project: project, settings: settings, agents: [], card: "").hootLeads)
    }

    @Test func agentRowsResolveTheirProjectLikeAProfile() throws {
        let registry = [imatch, PROJProjects.independent]
        let explicit = try #require(PROJSetupAgent(row: .object([.init("id", .string("a")), .init("projectId", .string("imatch")),
                                                                  .init("skills", .array([.string("s")]))]), projects: registry))
        #expect(explicit.projectID == "imatch")
        #expect(explicit.skills == ["s"])
        let byFolder = try #require(PROJSetupAgent(row: .object([.init("id", .string("b")), .init("defaultProject", .string("/scratch/iMatch/app"))]), projects: registry))
        #expect(byFolder.projectID == "imatch")
        let archived = try #require(PROJSetupAgent(row: .object([.init("id", .string("c")), .init("status", .string("archived"))]), projects: registry))
        #expect(archived.archived && archived.projectID == PROJProjects.independentID)
        #expect(PROJSetupAgent(row: .object([]), projects: registry) == nil)
    }

    // MARK: Card

    @Test func aStarterCardOrBlankGuideCardIsNotFilled() {
        #expect(!PROJSetup.cardIsFilled(""))
        #expect(!PROJSetup.cardIsFilled("# Lead of iMatch\n\n## Top rules\n\n## What this seat is for\n\n## Permissions\n"))
        #expect(!PROJSetup.cardIsFilled("# Lead of X\n\n## Goals\n- \n\n## Top rules\n- \n\n## Key facts\n- What it is:\n"))
        #expect(PROJSetup.cardIsFilled("## Goals\n- Ship the beta"))
        #expect(PROJSetup.cardIsFilled("Plain sentence about the project."))
    }

    @Test func theGuideCardIsPrefilledFromTheFirstPage() {
        let text = PROJSetup.cardText(name: "iMatch", about: "Dating app for the Gulf", folder: "/scratch/iMatch")
        #expect(text.hasPrefix("# Lead of iMatch\n"))
        #expect(text.contains("## Goals\n- \n"))
        #expect(text.contains("## Top rules\n"))
        #expect(text.contains("- What it is: Dating app for the Gulf\n"))
        #expect(text.contains("- Home folder: /scratch/iMatch\n"))
        #expect(PROJSetup.cardIsFilled(text))
        #expect(!PROJSetup.cardIsFilled(PROJSetup.cardText(name: "", about: "", folder: nil)))
        #expect(PROJSetup.cardText(name: "A", about: "", folder: nil, goals: ["Ship", " "]).contains("## Goals\n- Ship\n"))
    }

    // MARK: Set up with Hoot

    @Test func hootStartsFromWhatTheGuideAlreadyKnows() {
        let fresh = PROJSetup.hootStarter(name: " Notes ", folder: "/scratch/Notes", about: "Plans for the team")
        #expect(fresh.contains("project-setup skill"))
        #expect(fresh.contains("Name: Notes\nHome folder: /scratch/Notes\nWhat it is: Plans for the team"))
        let empty = PROJSetup.hootStarter(name: "", folder: nil, about: "")
        #expect(!empty.contains("Name:") && !empty.contains("Home folder:"))
        let existing = PROJSetup.hootStarter(name: "iMatch", folder: "/scratch/iMatch", about: "", projectID: "imatch")
        #expect(existing.contains("(id imatch)") && existing.contains("project_setup_status"))
        #expect(PROJSetup.guideWire()["skill"].string == "project-setup")
        #expect(PROJGuideStep.connections.tools.contains("github_connect") && PROJGuideStep.connections.tools.contains("connected_tasks_connect"))
    }

    // MARK: Guide and tools

    @Test func theGuideHasEightPagesAndOnlyNameAndFolderAreRequired() {
        #expect(PROJGuideStep.allCases.map(\.rawValue) == ["name", "folders", "lead", "team", "skills", "card", "connections", "review"])
        #expect(PROJGuideStep.allCases.filter(\.required) == [.name, .folders])
        #expect(PROJGuideStep.allCases.allSatisfy { !$0.why.isEmpty && $0.why.hasSuffix(".") && !$0.title.isEmpty })
        #expect(PROJGuideStep.allCases.map(\.number) == Array(1...8))
        // Every missing part opens a page of the guide, and connections never count.
        #expect(Set(PROJSetupPart.allCases.map(\.step)).isSubset(of: [.name, .lead, .team, .skills, .card]))
    }

    @Test func toolAnswersCarryTheScoreAndTheSteps() {
        let score = PROJSetup.score(.init(about: "x", logo: "l", lead: "agent:a", teamAgents: 1))
        let wire = PROJSetup.statusWire(project: imatch, score: score)
        #expect(wire["projectId"].string == "imatch")
        #expect(wire["percent"].number == 67)
        #expect(wire["complete"].bool == false)
        let missing = wire["missing"].elements ?? []
        #expect(missing.compactMap { $0["part"].string } == ["skills", "card"])
        #expect(missing.last?["how"].string?.contains("memory_card_save") == true)
        #expect(missing.last?["how"].string?.contains("lead:imatch") == true)
        let guide = PROJSetup.guideWire()
        #expect((guide["steps"].elements ?? []).count == 8)
        #expect(guide["steps"].elements?.first?["required"].bool == true)
        #expect(guide["rule"].string?.contains("plain session under Independent") == true)
        #expect((guide["scoreCounts"].elements ?? []).count == 6)
    }
}
