import AppKit
import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("AGT the Agents page: directory, groups, org chart, icons")
struct AGTAgentsTests {
    private func profile(_ id: String, _ name: String, role: String = "general", project: String? = nil, boss: String? = nil,
                         status: String = "active", icon: String? = nil, source: String? = nil) -> AGTProfileInput {
        AGTProfileInput(id: id, name: name, role: role, icon: icon, reportsTo: boss, project: project, provider: "claude",
                        model: "opus", status: status, sourceFile: source)
    }
    private func live(_ source: String, kind: String = "session", name: String, state: AWWatchState, task: String? = nil,
                      project: String = "/work/app", action: String = "Working") -> AWWatchAgent {
        AWWatchAgent.decode(.object([.init("id", .string("[\"\",\"\(kind)\",\"\(source)\"]")), .init("sourceID", .string(source)),
            .init("kind", .string(kind)), .init("name", .string(name)), .init("provider", .string("claude")), .init("project", .string(project)),
            .init("sessionID", .string(source)), .init("taskID", task.map(NativeRPCValue.string) ?? .null),
            .init("taskTitle", task.map { .string("Task " + $0) } ?? .null), .init("state", .string(state.rawValue)),
            .init("action", .string(action)), .init("updatedAt", .number(1_000))]))!
    }

    @Test func firstRunShowsHootAndRunningSessionsWithIcons() {
        let agents = AGTDirectory.build(profiles: [], live: [live("s1", name: "Session 1", state: .waiting)], tasks: [])
        #expect(agents.map(\.kind) == [.hoot, .session])
        #expect(agents[0].id == AGTDirectory.hootID)
        #expect(agents[1].icon == .symbol("terminal"))
        #expect(agents[1].statusLabel == "Waiting for you")
        #expect(AGTOrgChart.chart(agents).independent.count == 2)
    }

    @Test func orderingIsHootThenProfilesThenSessionsThenArchived() {
        let agents = AGTDirectory.build(profiles: [profile("zed", "Zed"), profile("old", "Aardvark", status: "archived"), profile("amy", "amy")],
                                        live: [live("s1", name: "A session", state: .idle)], tasks: [])
        #expect(agents.map(\.name) == ["Hoot", "amy", "Zed", "A session", "Aardvark"])
    }

    @Test func liveTaskRunsFoldIntoTheirProfileAndShowWhatTheyDo() {
        let tasks = [AGTTaskInput(id: "t1", title: "Fix login", assignee: "inspector", agentName: "Inspector", state: "running", updatedAt: 500)]
        let agents = AGTDirectory.build(profiles: [profile("inspector", "Inspector")],
                                        live: [live("s9", name: "Inspector", state: .working, task: "t1", action: "Editing · Edit"),
                                               live("h", kind: "hoot", name: "Hoot", state: .idle, action: "Idle")], tasks: tasks)
        let inspector = agents.first { $0.id == "inspector" }!
        #expect(inspector.live == .working)
        #expect(inspector.activity == "Editing · Edit")
        #expect(inspector.taskTitle == "Task t1")
        #expect(inspector.liveIDs.count == 1)
        #expect(!agents.contains { $0.kind == .session })
        #expect(agents.first?.live == .idle)
    }

    @Test func groupsByProjectAndByManager() {
        let agents = AGTDirectory.build(profiles: [
            profile("a", "A", project: "/w/zeta"), profile("b", "B", project: "/w/alpha", boss: "a"),
            profile("c", "C"), profile("d", "D", project: "/w/alpha", boss: AGTDirectory.hootID)], live: [], tasks: [])
        let byProject = AGTDirectory.groups(agents, by: .project)
        #expect(byProject.map(\.title) == ["Every project", "alpha", "zeta", "No project"])
        #expect(byProject[1].agents.map(\.id) == ["b", "d"])
        let byBoss = AGTDirectory.groups(agents, by: .reportsTo)
        #expect(byBoss.map(\.title) == ["Reports to Hoot", "Reports to A", "Independent"])
        #expect(byBoss.last?.agents.map(\.id) == [AGTDirectory.hootID, "a", "c"])
        #expect(AGTDirectory.filtered(agents, query: "zeta").map(\.id) == ["a"])
    }

    @Test func commanderLikeHierarchyBuildsTreesAndIndependents() {
        var profiles = [profile("commander", "Commander", project: "/w/imatch", boss: AGTDirectory.hootID)]
        for index in 1...23 {
            let project = ["/w/imatch", "/w/crm", "/w/site"][index % 3]
            let boss: String? = index <= 6 ? "commander" : index <= 18 ? "lead-\(index % 6 + 1)" : nil
            profiles.append(profile(index <= 6 ? "lead-\(index)" : "agent-\(index)", index <= 6 ? "Lead \(index)" : "Agent \(index)", project: project, boss: boss))
        }
        let agents = AGTDirectory.build(profiles: profiles, live: [], tasks: [])
        let chart = AGTOrgChart.chart(agents)
        #expect(chart.trees.count == 1)
        #expect(chart.trees[0].agent.id == AGTDirectory.hootID)
        #expect(chart.trees[0].size == 1 + 1 + 6 + 12)
        #expect(chart.independent.map(\.id).count == 5)
        let everyone = Set(agents.map(\.id))
        func ids(_ node: AGTOrgChart.Node) -> [String] { [node.id] + node.reports.flatMap(ids) }
        #expect(Set(chart.trees.flatMap(ids)).union(chart.independent.map(\.id)) == everyone)
    }

    @Test func cyclesAreRefusedAndStoredLoopsNeverHideAnyone() {
        let managers: [String: String?] = ["a": nil, "b": "a", "c": "b"]
        #expect(AGTOrgChart.refusal(id: "a", reportsTo: "a", managers: managers) == "An agent cannot report to itself.")
        #expect(AGTOrgChart.refusal(id: "a", reportsTo: "c", managers: managers, names: ["a": "Ann", "c": "Cy"])
                == "Cy already reports to Ann, so Ann cannot report to Cy.")
        #expect(AGTOrgChart.refusal(id: "a", reportsTo: "ghost", managers: managers) != nil)
        #expect(AGTOrgChart.refusal(id: "a", reportsTo: AGTDirectory.hootID, managers: managers) == nil)
        #expect(AGTOrgChart.refusal(id: "c", reportsTo: "a", managers: managers) == nil)
        #expect(AGTOrgChart.refusal(id: "a", reportsTo: nil, managers: managers) == nil)
        #expect(AGTOrgChart.below("a", managers: managers) == ["b", "c"])
        // A loop written by hand into the file shows both agents, independent.
        let agents = AGTDirectory.build(profiles: [profile("x", "X", boss: "y"), profile("y", "Y", boss: "x")], live: [], tasks: [])
        let chart = AGTOrgChart.chart(agents)
        #expect(Set(chart.independent.map(\.id)) == [AGTDirectory.hootID, "x", "y"])
    }

    @Test func iconsParseAndRefuseNonsense() {
        #expect(AGTIcon.parse("sf:checkmark.seal") == .symbol("checkmark.seal"))
        #expect(AGTIcon.parse("emoji:🦉") == .emoji("🦉"))
        #expect(AGTIcon.parse("emoji:👩‍💻") == .emoji("👩‍💻"))
        for bad in ["sf:Bad Name", "emoji:ab", "emoji:🦉🦉", "emoji:a", "png:x", "sf:"] { #expect(AGTIcon.parse(bad) == nil, "\(bad)") }
        #expect(AGTIcon.problem(nil) == nil)
        #expect(AGTIcon.problem("emoji:hi") != nil)
    }

    @Test func atLeastAHundredRealSymbolsAndAHundredEmoji() {
        let symbols = AGTIconCatalog.symbolCategories.flatMap(\.choices)
        #expect(symbols.count >= 100)
        #expect(AGTIconCatalog.emojiChoices.count >= 100)
        #expect(Set(AGTIconCatalog.all.map(\.id)).count == AGTIconCatalog.all.count)
        for choice in symbols {
            guard case .symbol(let name) = choice.icon else { continue }
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "Missing SF Symbol \(name)")
            #expect(AGTIcon.parse(choice.icon.raw) == choice.icon)
        }
        for choice in AGTIconCatalog.emojiChoices { #expect(AGTIcon.parse(choice.icon.raw) == choice.icon, "\(choice.icon.raw)") }
        #expect(AGTIconCatalog.search("owl", in: AGTIconCatalog.all).contains { $0.icon == .emoji("🦉") })
        #expect(AGTIconCatalog.defaultIcon(name: "inspector", role: "Reviews work", provider: "claude") == .symbol("checkmark.seal"))
    }

    @Test func oldProfilesLoadWithoutOrgFieldsAndNewOnesRoundTrip() throws {
        let state = try #require(TasksDecode.state(["agents": [["id": "old", "name": "Old"],
            ["id": "new", "name": "New", "icon": "emoji:🦊", "reportsTo": "old"]], "connections": []]))
        #expect(state.agents[0].icon == nil && state.agents[0].reportsTo == nil)
        #expect(state.agents[1].icon == "emoji:🦊" && state.agents[1].reportsTo == "old")
        // The settings form carries them unchanged.
        let draft = AgentDraft(state.agents[1])
        let saved = try AgentForm.payload(draft, agents: state.agents).get()
        #expect(saved.icon == "emoji:🦊" && saved.reportsTo == "old")
        #expect(saved.wire["reportsTo"] as? String == "old")
        let input = AGTProfileInput(state.agents[0])
        #expect(AGTDirectory.build(profiles: [input], live: [], tasks: []).last?.icon == .symbol("person.crop.circle"))
    }
}
