import Foundation
import TerminalDeckNativeCore

/// Source task/knowledge/server title/index/audience over real native specs. Schemas, tiers,
/// handlers and capability descriptions remain their native owners' actual values.
public enum BackendDeckCoreSupplementMetadata {
    public static let retiredIDs: Set<String> = ["browser.import", "browser.extensions"]
    public static func entries(specs: [BackendMCPTool], requireComplete: Bool = false) throws -> [BackendDeckCoreCatalogueMetadata] {
        let rows = try NativeRPCValue.parseJSON(Data(literals.utf8)).elements ?? []
        if requireComplete {
            let expected = Set(rows.compactMap { $0["id"].string })
            let actual = Set(specs.filter { !retiredIDs.contains($0.id) }.map(\.id))
            guard actual == expected else { throw BackendSessionFailure.missingCapability("the complete source-compatible task/knowledge/server contribution") }
        }
        var names = Set<String>()
        return try specs.filter { !retiredIDs.contains($0.id) }.map { spec in
            guard names.insert(spec.id).inserted else {
                throw NativeRPCError.invalidArguments("Supplement metadata needs distinct real tool specs.")
            }
            guard let row = rows.first(where: { $0["id"].string == spec.id }), row["wire"].string == spec.wireName else {
                throw BackendSessionFailure.missingCapability("the source supplementary metadata for \(spec.id)")
            }
            return .init(tool: spec, title: try row["title"].requireString("source supplementary title"),
                aliases: row["aliases"].elements?.compactMap(\.string) ?? [], index: row["index"].string,
                audience: row["audience"].string, keyIndex: row["keyIndex"].string, keyGrant: row["keyGrant"].string)
        }
    }
    /// The source rows are inspectable; they are descriptors, never invented tools.
    public static func sourceDescriptors() throws -> [NativeRPCValue] { try NativeRPCValue.parseJSON(Data(literals.utf8)).elements ?? [] }
    private static let literals = ####"""
[
  {
    "module": "../tasks/task-tools",
    "id": "crm.task",
    "wire": "crm_task",
    "title": "CRM task API",
    "index": "For a CRM: give Hoot or an agent a task, assign, read, cancel, pass on a comment or a status change.",
    "audience": "keys"
  },
  {
    "module": "../tasks/task-tools",
    "id": "tasks.list",
    "wire": "tasks_list",
    "title": "CRM tasks in hand",
    "index": "The CRM tasks given to you and your agents, with their CRM status and whether they finished.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/task-tools",
    "id": "tasks.get",
    "wire": "tasks_get",
    "title": "Read a CRM task",
    "index": "One CRM task: its instructions, its CRM status and its result.",
    "keyGrant": "tasks"
  },
  {
    "module": "../tasks/task-tools",
    "id": "tasks.delegate",
    "wire": "tasks_delegate",
    "title": "Hand part of a CRM task to an agent",
    "index": "Create a linked child task for a partner agent, within the handoff limit.",
    "keyGrant": "tasks"
  },
  {
    "module": "../tasks/task-tools",
    "id": "tasks.comment",
    "wire": "tasks_comment",
    "title": "Comment on a CRM task as Hoot",
    "index": "Post progress, a blocker, a question or the completion on the CRM task, as Hoot.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/task-tools",
    "id": "tasks.verify",
    "wire": "tasks_verify",
    "title": "Say whether a CRM task is done",
    "index": "After reading a finished task’s result: verified sets it complete in the CRM; not verified marks it blocked.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/task-tools",
    "id": "tasks.set_status",
    "wire": "tasks_set_status",
    "title": "Set a CRM task’s status",
    "index": "Set a CRM task to one of the CRM’s own statuses.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/local-task-tools",
    "id": "tasks.local",
    "wire": "tasks_local",
    "title": "Your tasks",
    "index": "Read your own tasks (the Tasks page): the list, one task in full, its comments, history, repeat, or the Trash.",
    "keyGrant": "tasks"
  },
  {
    "module": "../tasks/local-task-tools",
    "id": "tasks.local_change",
    "wire": "tasks_local_change",
    "title": "Change your tasks",
    "index": "Create, edit, assign, comment on, archive, delete (to the Trash) or restore one of your own tasks.",
    "keyGrant": "tasks"
  },
  {
    "module": "../tasks/local-task-tools",
    "id": "tasks.local_parts",
    "wire": "tasks_local_parts",
    "title": "The parts of a task",
    "index": "Work the parts of one of your tasks: subtasks, checklists, links to other tasks, custom fields, attached files, and tracked time.",
    "keyGrant": "tasks"
  },
  {
    "module": "../tasks/local-task-tools",
    "id": "tasks.local_schedule",
    "wire": "tasks_local_schedule",
    "title": "Repeats, reminders and scheduled comments",
    "index": "Make one of your tasks repeat (or pause, stop, restart it), set or clear a reminder, or schedule a comment for later.",
    "keyGrant": "tasks"
  },
  {
    "module": "../tasks/local-task-tools",
    "id": "tasks.agents",
    "wire": "tasks_agents",
    "title": "Task agents",
    "index": "List, create, change or remove the task agents your tasks can be given to: their role, coding agent, model, instructions, tools and skills.",
    "keyGrant": "tasks"
  },
  {
    "module": "../tasks/local-task-tools",
    "id": "tasks.agents_import",
    "wire": "tasks_agents_import",
    "title": "Import Claude Code agents",
    "index": "Import agent definitions from .claude/agents and keep profiles synced to source changes.",
    "keyGrant": "tasks"
  },
  {
    "module": "../tasks/local-task-tools",
    "id": "hoot.island",
    "wire": "hoot_island",
    "title": "Hoot’s island",
    "index": "Whether Hoot’s island shows at the top of the screen, and show or hide it.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/goal-tools",
    "id": "tasks.goals",
    "wire": "tasks_goals",
    "title": "Goals",
    "index": "Your goals: list, read, make, change or remove one, and link a task to the goal it serves.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/goal-tools",
    "id": "tasks.plan",
    "wire": "tasks_plan",
    "title": "Plan tasks under a goal",
    "index": "Make several tasks under a goal in one call, each handed to an agent, with the tasks each has to wait for.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/goal-tools",
    "id": "tasks.progress",
    "wire": "tasks_progress",
    "title": "Where a goal stands",
    "index": "Where a goal stands: its tasks by status, what waits on what, what stalled, and what is verified versus only claimed.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/goal-tools",
    "id": "tasks.retry",
    "wire": "tasks_retry",
    "title": "Try a task again",
    "index": "Start one of your tasks again with the same agent and brief, plus a note on what to do differently.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/goal-tools",
    "id": "tasks.reassign",
    "wire": "tasks_reassign",
    "title": "Give a task to another agent",
    "index": "Give one of your tasks to another task agent, who starts it from the beginning.",
    "audience": "copilot"
  },
  {
    "module": "../tasks/goal-tools",
    "id": "tasks.review",
    "wire": "tasks_review",
    "title": "Review a finished task",
    "index": "Your verdict on a finished task: pass with the evidence you checked, or fail with what is wrong, which sends it back.",
    "audience": "copilot"
  },
  {
    "module": "../knowledge/knowledge-tools",
    "id": "knowledge.search",
    "wire": "knowledge_search",
    "title": "Search project knowledge",
    "index": "Search what a project knows — verified results, claims, decisions, constraints — and what is stale or in conflict.",
    "audience": "copilot"
  },
  {
    "module": "../knowledge/knowledge-tools",
    "id": "knowledge.get",
    "wire": "knowledge_get",
    "title": "Read a project knowledge record",
    "index": "Read one project knowledge record in full: its evidence, its status and why, and the records it replaced.",
    "audience": "copilot"
  },
  {
    "module": "../knowledge/knowledge-tools",
    "id": "knowledge.record",
    "wire": "knowledge_record",
    "title": "Record project knowledge",
    "index": "Write down a decision, constraint, goal or architecture fact for a project, as a claim from you or the owner.",
    "audience": "copilot"
  },
  {
    "module": "../knowledge/knowledge-tools",
    "id": "knowledge.supersede",
    "wire": "knowledge_supersede",
    "title": "Replace or withdraw project knowledge",
    "index": "Replace or withdraw a project knowledge record; the old one is kept as history and your reason is logged.",
    "audience": "copilot"
  },
  {
    "module": "../knowledge/knowledge-tools",
    "id": "knowledge.note",
    "wire": "knowledge_note",
    "title": "Note project knowledge",
    "index": "Note a decision, constraint or architecture fact about the project you are working in, as an unverified claim.",
    "audience": "copilot"
  },
  {
    "module": "../servers/tools",
    "id": "servers.look",
    "wire": "servers_look",
    "title": "Look at a server"
  },
  {
    "module": "../servers/tools",
    "id": "servers.logs",
    "wire": "servers_logs",
    "title": "Read a server’s recent output",
    "index": "The last lines one site, app or database on a server printed. Call servers.look first."
  },
  {
    "module": "../servers/tools",
    "id": "servers.control",
    "wire": "servers_control",
    "title": "Start, stop, update or copy something on a server",
    "index": "Do one named thing to one site, app or database on a server: start, restart, stop, update, go-back or backup. Call servers.look first."
  }
]
"""####
}
