import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite struct TaskSharedRulesTests {
    @Test func statusesAndArrowsStayTogether() {
        #expect(BackendTaskLocalService.statuses == TaskStatuses.all)
        #expect(CrmText.statuses == TaskStatuses.all)
        #expect(Routine.statuses == TaskStatuses.all)
        #expect(DEFAULT_CRM_STATUSES.statuses == TaskStatuses.all)
        #expect(TaskList.statusOrder == ["To-Do", "Working on it", "In Progress", "Stuck", "Done"])
        for status in TaskStatuses.all + ["unknown", ""] {
            #expect(TaskList.nextStatus(status) == CrmText.nextStatus(status))
            #expect(BackendCrmTaskPage.nextStatus(status) == TaskStatuses.next(status))
        }
        #expect(TaskStatuses.next("Stuck") == "In Progress")
        #expect(TaskStatuses.next("Done") == nil)
    }
    @Test func nameIDsShareNormalizationAndCollisionRules() {
        for name in ["Café Bot", "Éclair  Helper!", "ＡＢＣ", "../../etc/passwd", "!!!", String(repeating: "long-name-", count: 10)] {
            let first = AgentForm.slug(name)
            let taken: Set<String> = [first, first + "-2"]
            #expect(BackendTaskConfiguration.newID(name: name, taken: taken) == AgentForm.slug(name, taken: Array(taken)))
            #expect(AGTSeats.slug(name) == BackendRoutinesFormat.slugify(name))
            #expect(BackendRoutinesFormat.slugify(name).count <= 64)
            #expect(!BackendRoutinesFormat.slugify(name).hasSuffix("-"))
        }
        #expect(AgentForm.slug("Café Bot") == "cafe-bot")
        #expect(AgentForm.slug("!!!", taken: ["agent", "agent-2"]) == "agent-3")
    }
}
