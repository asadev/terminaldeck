import Testing
@testable import TerminalDeckNativeCore

@Suite("AGFRAME project groups and folder import")
struct AGFRAMEPresentationTests {
    private let projects: [PROJProject] = [
        .init(id: "crm", name: "CRM", folders: ["/work/crm"]),
        .init(id: "imatch", name: "iMatch", folders: ["/work/imatch"]),
        .init(id: "independent", name: "Independent")
    ]
    private func agents() -> [AGTAgent] {
        AGTDirectory.build(profiles: [
            .init(id: "match", name: "Accounts", role: "Sign-in", project: "/work/imatch", model: "opus"),
            .init(id: "crm", name: "Portal", project: "/work/crm", status: "paused"),
            .init(id: "free", name: "Independent worker", project: "/work/crm")
        ], live: [], tasks: [])
    }
    @Test func registryOrderAndExplicitIndependentSurviveExecutionFolder() {
        let groups = AGFRAMEPresentation.groups(agents: agents(), projects: projects, agentProjectIDs: ["free": "independent"])
        #expect(groups.map(\.id) == ["crm", "imatch", "independent"])
        #expect(groups.map(\.name) == ["CRM", "iMatch", "Independent"])
        #expect(groups.last?.agents.map(\.id) == ["free"])
        #expect(!groups.flatMap(\.agents).contains { $0.kind == .hoot })
    }
    @Test func scopedCountsMatchGroupsAndExcludeHootByID() {
        var rows = agents()
        var disguisedHoot = rows.first { !$0.isHoot }!
        disguisedHoot.id = "hoot"
        disguisedHoot.kind = .profile
        rows.append(disguisedHoot)
        var archived = disguisedHoot
        archived.id = "archived"
        archived.status = "archived"
        rows.append(archived)
        for project in [nil, "crm", "imatch", "missing"] as [String?] {
            let scoped = AGFRAMEPresentation.scopedAgents(rows, projects: projects, projectID: project)
            let grouped = AGFRAMEPresentation.groups(agents: rows, projects: projects, projectID: project).flatMap(\.agents)
            #expect(Set(scoped.map(\.id)) == Set(grouped.map(\.id)))
            #expect(!scoped.contains { $0.isHoot || $0.status == "archived" })
        }
    }
    @Test func searchAndProjectAndStateIntersect() {
        #expect(AGFRAMEPresentation.groups(agents: agents(), projects: projects, projectID: "imatch", search: " OPUS ").first?.agents.map(\.id) == ["match"])
        #expect(AGFRAMEPresentation.groups(agents: agents(), projects: projects, projectID: "crm", state: .paused).first?.agents.map(\.id) == ["crm"])
        #expect(AGFRAMEPresentation.groups(agents: agents(), projects: projects, projectID: "crm", search: "Sign-in").isEmpty)
    }
    @Test func namedProjectNeverUsesFolderBasename() {
        let registry = [PROJProject(id: "team", name: "Customer care", folders: ["/work/random-folder"])]
        let rows = AGTDirectory.build(profiles: [.init(id: "a", name: "A", project: "/work/random-folder/sub")], live: [], tasks: [])
        #expect(AGFRAMEPresentation.groups(agents: rows, projects: registry).first?.name == "Customer care")
    }
    @Test func unknownExplicitIdentityIsPreservedAndNotRehomed() {
        #expect(AGFRAMEPresentation.groups(agents: agents(), projects: projects, projectID: "missing", agentProjectIDs: ["match": "missing"]).first?.id == "missing")
    }
    @Test func existingImportsRemainCheckedAndDoNotCountAsNew() {
        var folder = AGFRAMEImportFolder(folder: "/work/crm/.claude/agents/../agents", candidates: [
            .init(id: "old", name: "Old", alreadyImported: true), .init(id: "new", name: "New")
        ], projects: projects)
        #expect(folder.folder == "/work/crm/.claude/agents")
        #expect(folder.projectID == "crm")
        folder.setSelected(false, id: "old")
        #expect(folder.selectedIDs.contains("old"))
        #expect(folder.pendingCandidates.map(\.id) == ["new"])
        folder.setSelected(false, id: "new")
        #expect(folder.pendingCandidates.isEmpty)
        folder.setSelected(true, id: "not-in-scan")
        #expect(!folder.selectedIDs.contains("not-in-scan"))
    }
    @Test func rescanKeepsUntickedFilesOutAndTicksNewlyFoundOnes() {
        var before = AGFRAMEImportFolder(folder: "/work/crm/.claude/agents", candidates: [.init(id: "a", name: "A"), .init(id: "b", name: "B")], projects: projects)
        before.setSelected(false, id: "b"); before.projectID = "imatch"
        var after = AGFRAMEImportFolder(folder: "/work/crm/.claude/agents", candidates: [.init(id: "a", name: "A"), .init(id: "b", name: "B"), .init(id: "c", name: "C")], projects: projects)
        after.keepChoices(of: before)
        #expect(after.pendingCandidates.map(\.id) == ["a", "c"])
        #expect(after.projectID == "imatch")
    }
    @Test func agentsFolderBelongsToItsProjectFolder() {
        #expect(AGFRAMEImportFolder(folder: "/code/foo/.claude/agents", candidates: [], projects: projects).projectRoot == "/code/foo")
        #expect(AGFRAMEImportFolder(folder: "/code/foo/agents", candidates: [], projects: projects).projectRoot == "/code/foo/agents")
    }
    @Test func oneFolderAssignmentAppliesToEverySelectedCandidate() {
        var folder = AGFRAMEImportFolder(folder: "/work/crm/.claude/agents", candidates: [.init(id: "a", name: "A"), .init(id: "b", name: "B")], projectID: "independent", projects: projects)
        #expect(folder.projectID == "independent")
        folder.projectID = "imatch"
        #expect(folder.pendingCandidates.count == 2)
        #expect(folder.projectID == "imatch")
    }
}
