import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// PROJECT-GUIDE (Asad, 11 Oct): "starting a project in the app should not be just simply choose a folder and
/// start session ... that will be just a normal session not project". The side panel no longer registers an
/// open folder as a project; the New project guide does, page by page; the project page shows Setup N%.
@Suite("PROJ guide", .serialized)
@MainActor
struct PROJGuideTests {
    private static let imatch = PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], colour: "blue")
    private static let crm = PROJProject(id: "crm", name: "CRM", folders: ["/scratch/CRM"], colour: "purple")

    private func withRegistry<T>(_ projects: [PROJProject], _ body: () async throws -> T) async rethrows -> T {
        let store = SIDEBARProjectStore.shared, saved = store.projects
        store.projects = projects
        defer { store.projects = saved }
        return try await body()
    }

    @Test func anOpenFolderIsNotMadeAProject() async throws {
        try await withRegistry([Self.imatch, PROJProjects.independent]) {
            let before = SIDEBARProjectStore.shared.projects
            let plain = SHELLRoutes.project(forPath: "/scratch/Notes")
            #expect(plain.name == "Notes")
            #expect(!before.contains { $0.id == plain.id })
            #expect(!SHELLRoutes.isProject(path: "/scratch/Notes"))
            // Asking again (the side panel and the tab strip draw it many times) never saves anything.
            for _ in 0..<3 { _ = SHELLRoutes.project(forPath: "/scratch/Notes") }
            try await Task.sleep(for: .milliseconds(150))
            #expect(SIDEBARProjectStore.shared.projects == before)
            // A folder inside a registered project is that project.
            #expect(SHELLRoutes.isProject(path: "/scratch/iMatch/api"))
            #expect(SHELLRoutes.project(forPath: "/scratch/iMatch/api").id == "imatch")
            // A plain folder still opens its own page (with "Set up as a project…"); its settings action is an action.
            #expect(SHELLRoutes.owns("project:/scratch/Notes"))
            #expect(SHELLRoutes.isAction("project:/scratch/Notes:settings"))
        }
    }

    /// Asad, 11 Oct: Terminal Deck (~/Deck Dev, a space in the path) was missing from Projects.
    @Test func aProjectFolderWithASpaceIsAProjectWithItsName() async throws {
        let deck = PROJProject(id: "terminal-deck", name: "Terminal Deck", folders: ["/scratch/Deck Dev"])
        await withRegistry([Self.imatch, deck, PROJProjects.independent]) {
            #expect(SHELLRoutes.isProject(path: "/scratch/Deck Dev"))
            #expect(SHELLRoutes.project(forPath: "/scratch/Deck Dev").name == "Terminal Deck")
            #expect(SHELLRoutes.project(forPath: "/scratch/Deck Dev/code").id == "terminal-deck")
            #expect(SHELLRoutes.owns("project:/scratch/Deck Dev"))
            #expect(AppModel.nativeOnly("project:/scratch/Deck Dev"))
        }
    }

    @Test func theGuideNeedsOnlyANameAndAHomeFolder() async throws {
        await withRegistry([Self.imatch, Self.crm, PROJProjects.independent]) {
            let model = PROJGuideModel(folder: "/scratch/Notes", fixture: true)
            #expect(model.creating)
            #expect(model.name == "Notes")
            #expect(model.home == "/scratch/Notes")
            #expect(model.firstBlocker == nil)
            model.name = "  "
            model.next()
            #expect(model.step == .name)
            #expect(model.problem == "Give the project a name.")
            model.name = "Notes"
            model.next()
            #expect(model.step == .folders)
            model.home = "/scratch/CRM"
            #expect(model.blocker(.folders) == "This folder is already the project CRM.")
            model.home = nil
            #expect(model.blocker(.folders) != nil)
            model.home = "/scratch/Notes"
            model.next()
            #expect(model.step == .lead)
            // Everything after the folder is optional: Skip moves on and is remembered.
            model.skip()
            #expect(model.step == .team)
            #expect(model.skipped.contains(.lead))
            #expect(model.summary(.lead) == "No lead")
            // Required pages cannot be skipped.
            model.go(.name); model.skip()
            #expect(model.step == .name)
        }
    }

    @Test func thePlanCountsTheLeadTheTeamAndTheScoreItWillHave() async throws {
        await withRegistry([Self.imatch, PROJProjects.independent]) {
            let model = PROJGuideModel(folder: "/scratch/Notes", fixture: true)
            #expect(model.expectedScore.percent == 0)
            model.about = "Notes for the team"
            model.lead = .hire
            model.leadHire.name = "Noor"
            #expect(model.blocker(.lead) == nil)
            model.leadHire.name = ""
            #expect(model.blocker(.lead) == "Give the new lead a name.")
            model.leadHire.name = "Noor"
            var seat = PROJGuideModel.Seat(); seat.title = "iOS engineer"
            model.seats = [seat, PROJGuideModel.Seat()]   // an empty row is ignored
            #expect(model.planAgents.map(\.name) == ["Noor", "iOS engineer"])
            #expect(model.teamAgents.map(\.name) == ["iOS engineer"])
            #expect(model.isSet(.team))
            model.skills = [.init(id: "/s/review", name: "review", summary: "", source: "Every project", agents: [model.teamAgents[0].key], original: [])]
            model.go(.card)
            #expect(model.isSet(.card))   // prefilled with what it is and the home folder
            #expect(model.card.contains("- What it is: Notes for the team"))
            let score = model.expectedScore
            #expect(score.missing == [.logo])
            #expect(score.percent == 83)
            model.skip()
            #expect(!model.isSet(.card))
            #expect(model.expectedScore.missing == [.logo, .card])
        }
    }

    @Test func theSetupCardShowsOnlyWhatIsMissing() {
        let model = PROJSetupStatusModel(settings: .object([.init("values", .object([.init("about", .string("Dating app"))]))]), card: "")
        let project = PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], logo: "imatch.png", lead: "agent:boss")
        let agents = [AgentProfile(id: "boss", name: "Boss", skills: ["review"], projectID: "imatch"),
                      AgentProfile(id: "ios", name: "iOS", projectID: "imatch")]
        let score = model.score(project, agents: agents)
        #expect(score?.missing == [.card])
        #expect(score?.percent == 83)
        #expect(model.score(PROJProjects.independent, agents: agents) == nil)
        let full = PROJSetupStatusModel(settings: .object([.init("values", .object([.init("about", .string("x"))]))]), card: "## Goals\n- Ship")
        #expect(full.score(project, agents: agents)?.complete == true)
    }

    /// Pictures to look at: every guide page, the setup card and the side panel with a plain folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROJ_GUIDE_RENDER_OUT"] != nil))
    func lightAndDarkRenders() async throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PROJ_GUIDE_RENDER_OUT"]))
        #expect(out.lastPathComponent.hasSuffix(".noindex"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await withRegistry([Self.imatch, Self.crm, PROJProjects.independent]) {
            var views: [(String, CGSize, AnyView)] = []
            for step in PROJGuideStep.allCases {
                let model = PROJGuideModel(step: step, folder: "/scratch/Notes", fixture: true)
                model.about = "Notes and plans for the whole team"
                model.colour = "teal"
                model.extraFolders = ["/scratch/Notes-assets"]
                model.lead = .hire; model.leadHire.name = "Noor"; model.leadHire.provider = "claude"
                var seat = PROJGuideModel.Seat(); seat.title = "Writer"; seat.agent.name = "Sam"; seat.agent.provider = "codex"
                model.seats = [seat]
                model.found = [.init(file: "/scratch/Notes/.claude/agents/editor.md", folder: "/scratch/Notes/.claude/agents", name: "editor", alreadyImported: false, selected: true),
                               .init(file: "/scratch/Notes/.claude/agents/old.md", folder: "/scratch/Notes/.claude/agents", name: "old", alreadyImported: true, selected: false)]
                model.skills = [.init(id: "/s/review", name: "review", summary: "Reads a change and lists what is wrong.", source: "Every project", agents: ["lead"], original: []),
                                .init(id: "/s/release", name: "release", summary: "Ships a build.", source: "This project", agents: [], original: [])]
                model.repo = "asadev/notes"
                model.card = PROJSetup.cardText(name: "Notes", about: model.about, folder: "/scratch/Notes")
                model.visited = Set(PROJGuideStep.allCases.prefix(while: { $0 != step })).union([step])
                model.skipped = step == .review ? [.connections] : []
                views.append(("guide-\(step.number)-\(step.rawValue)", CGSize(width: 780, height: 640), AnyView(PROJGuideView(model: model).frame(width: 780, height: 640))))
            }
            let project = PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], lead: "agent:boss")
            let score = PROJSetup.score(.init(about: "Dating app", lead: "agent:boss", teamAgents: 2))
            views.append(("setup-card", CGSize(width: 900, height: 260), AnyView(PROJSetupCard(project: project, score: score).padding(24).frame(width: 900, height: 260).background(DeckTokens.page))))
            views.append(("plain-folder-card", CGSize(width: 900, height: 120), AnyView(PROJPlainFolderCard(folder: "/scratch/Notes").padding(24).frame(width: 900, height: 120).background(DeckTokens.page))))
            // Terminal Deck is registered but missing from the page's folder list; Commander runs in iMatch
            // (its logo before the name), "Notes shell" in a plain folder (no logo).
            let commander = SidebarItem(id: "s-imatch", title: "Commander", kind: .session, status: "working")
            let plainSession = SidebarItem(id: "s-notes", title: "Notes shell", kind: .session, status: "idle")
            let deckSession = SidebarItem(id: "s-deck", title: "Decker", kind: .session, status: "working")
            let state = SidebarState(groups: [.init(id: "running", title: nil, items: [deckSession])], projects: [
                .init(id: "/scratch/iMatch", title: "iMatch", expanded: false, sessions: [commander]),
                .init(id: "/scratch/CRM", title: "CRM", expanded: false, sessions: []),
                .init(id: "/scratch/Notes", title: "Notes", expanded: false, sessions: [plainSession])
            ], selectedId: nil)
            let deck = PROJProject(id: "terminal-deck", name: "Terminal Deck", folders: ["/scratch/Deck Dev"])
            let store = SIDEBARProjectStore(); store.projects = [Self.imatch, Self.crm, deck, PROJProjects.independent]
            store.liveIDs = ["s-imatch", "s-notes", "s-deck"]
            store.sessionProjects = ["s-deck": ("terminal-deck", "/scratch/Deck Dev")]
            views.append(("side-panel", CGSize(width: 264, height: 860), AnyView(SIDEBARPanel(state: state, selected: nil, store: store,
                choose: { _ in }, openProject: {}, newSession: { _ in }, closeProject: { _ in }, openWindow: { _ in }, rename: { _ in },
                close: { _ in }, stop: { _ in }) { EmptyView() } hostFailure: { EmptyView() }.frame(width: 264, height: 860))))
            for (scheme, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                for (name, size, view) in views {
                    try await L1ShellTests.render(view, size: size, appearance: scheme, to: out.appendingPathComponent("\(name)-\(label).png"))
                }
            }
        }
    }
}
