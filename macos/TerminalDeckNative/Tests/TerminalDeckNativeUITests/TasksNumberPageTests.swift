import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 15 Nov: the page's widest view (My Work, All projects, no filter) lists exactly the open tasks the side panel
/// counts, with and without tasks from a connected system, with archived and Trash rows present.
@Suite(.serialized) @MainActor struct TasksNumberPageTests {
    private func openRows(_ state: TasksState) throws -> [String] {
        let suite = "tasks-number-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MyWorkModel(defaults: defaults, importPage: false, fixtureFavorites: [])
        model.view = TasksViewState()
        let projects = TKTasksProjectScope.renderFixture(projects: [], selectedProjectID: nil)
        let drawn = model.drawn(projects.scoped(state), now: 1_794_700_000_000, projects: projects)
        var seen: Set<String> = []
        return drawn.groups.flatMap(\.items).filter { $0.crmStatus != "Done" && seen.insert($0.id).inserted }.map(\.id)
    }

    @Test func theNumberEqualsTheOpenRowsOfHisOwnTasks() throws {
        let state = TasksState(tasks: TasksNumberFixtures.own)
        let rows = try openRows(state)
        #expect(Set(rows) == Set(TaskList.openInWidestView(state.tasks).map(\.id)))
        #expect(rows.count == 5)
    }

    @Test func theNumberEqualsTheOpenRowsWithConnectedSystemTasks() throws {
        let state = TasksState(connections: [TasksNumberFixtures.crm("k1", name: "iLoop")],
                               tasks: TasksNumberFixtures.own + TasksNumberFixtures.connected)
        let rows = try openRows(state)
        #expect(Set(rows) == Set(TaskList.openInWidestView(state.tasks).map(\.id)))
        #expect(rows.count == 9)
        // A connected system's task is on the widest view, with its one mark of where it comes from.
        #expect(rows.contains("c1") && rows.contains("c7"))
        let c1 = try #require(state.tasks.first { $0.id == "c1" })
        #expect(TaskList.source(c1, connections: state.connections) == "From iLoop")
    }
}

/// The same fixtures as TerminalDeckNativeCoreTests.TasksNumberTests (another test target cannot be imported here).
enum TasksNumberFixtures {
    static func crm(_ keyId: String, name: String?) -> CrmConnection {
        CrmConnection(keyId: keyId, name: name, enabled: true, eventsUrl: nil, hasEventsSecret: false,
                      statuses: DEFAULT_CRM_STATUSES, hootIdentity: nil, identities: [:], identityOrder: [],
                      allowedSenders: [], folders: [], maxHops: 3)
    }

    /// 5 own open, 2 own Done, 1 own archived, 1 own in the Trash.
    static let own: [TaskRow] = [
        TaskRow(id: "o1", crmStatus: "Stuck", local: true), TaskRow(id: "o2", crmStatus: "Stuck", local: true),
        TaskRow(id: "o3", crmStatus: "Stuck", local: true), TaskRow(id: "o4", crmStatus: "Working on it", local: true),
        TaskRow(id: "o5", crmStatus: "To-Do", local: true),
        TaskRow(id: "d1", crmStatus: "Done", local: true), TaskRow(id: "d2", crmStatus: "Done", local: true),
        TaskRow(id: "a1", crmStatus: "To-Do", local: true, archivedAt: 1),
        TaskRow(id: "t1", crmStatus: "To-Do", local: true, deletedAt: 1),
    ]
    /// 3 open from a CRM, 3 archived from it, 1 copy from another Mac, 1 CRM task in the Trash.
    static let connected: [TaskRow] = [
        TaskRow(id: "c1", keyId: "k1", crmStatus: "To-Do"), TaskRow(id: "c2", keyId: "k1", crmStatus: "Stuck"),
        TaskRow(id: "c3", keyId: "k2", crmStatus: "Working on it"),
        TaskRow(id: "c4", keyId: "k1", crmStatus: "To-Do", archivedAt: 1),
        TaskRow(id: "c5", keyId: "k1", crmStatus: "Done", archivedAt: 1),
        TaskRow(id: "c6", keyId: "k2", crmStatus: "Stuck", archivedAt: 1),
        TaskRow(id: "c7", keyId: "k9", crmStatus: "To-Do", copyFrom: "From iLoop, on Mac mini"),
        TaskRow(id: "c8", keyId: "k1", crmStatus: "To-Do", deletedAt: 1),
    ]
}
