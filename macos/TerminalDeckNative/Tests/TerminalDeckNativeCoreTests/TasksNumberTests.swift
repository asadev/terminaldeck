import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// 15 Nov: the number beside Tasks counts exactly the open tasks the page lists in its widest view, one rule.
@Suite struct TasksNumberTests {
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

    @Test func withOnlyHisOwnTasksTheNumberIsTheOpenOnesNotArchivedNotTrash() {
        #expect(TaskList.openInWidestView(Self.own).map(\.id) == ["o1", "o2", "o3", "o4", "o5"])
    }

    @Test func connectedSystemTasksCountOnceTheyAreListed() {
        let all = Self.own + Self.connected
        #expect(Set(TaskList.openInWidestView(all).map(\.id)) == ["o1", "o2", "o3", "o4", "o5", "c1", "c2", "c3", "c7"])
        // The page's list holds them all except the Trash; the number is its open, unarchived part.
        #expect(!TaskList.listed(all).contains { $0.deletedAt != nil })
        let widest = TaskList.filter(TaskList.listed(all), ListFilters(), today: "2026-11-15", nowHm: nil)
        #expect(TaskList.openInWidestView(all).count == widest.filter { $0.crmStatus != "Done" }.count)
    }

    @Test func aConnectedTaskCarriesOneQuietMarkOfWhereItComesFrom() {
        let connections = [Self.crm("k1", name: "iLoop"), Self.crm("k2", name: nil)]
        #expect(TaskList.source(Self.own[0], connections: connections) == nil)
        #expect(TaskList.source(Self.connected[0], connections: connections) == "From iLoop")
        #expect(TaskList.source(Self.connected[2], connections: connections) == "From your CRM")
        #expect(TaskList.source(Self.connected[6], connections: connections) == "From iLoop, on Mac mini")
        #expect(TaskList.editableInList(Self.own[0]) && !TaskList.editableInList(Self.connected[0]))
    }
}
