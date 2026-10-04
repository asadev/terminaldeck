/**
 * What the copied CRM task modules (`./task-fields`, `./task-rules`) import
 * from the rest of the CRM, answered locally so they run unchanged here.
 *
 * - The five task statuses, exactly as the CRM stores them.
 * - "Tag areas" — the CRM's record kinds (lead, landlord, listing, deal…) a
 *   relationship field can point at. Those records live only in the CRM, so a
 *   local task's relationship field points at other local tasks; any area name
 *   is accepted and read as a label.
 */

export const TASK_STATUSES = ['To-Do', 'Working on it', 'In Progress', 'Done', 'Stuck'] as const
export type TaskStatus = (typeof TASK_STATUSES)[number]

export function isTaskStatus(value: unknown): value is TaskStatus {
  return typeof value === 'string' && (TASK_STATUSES as readonly string[]).includes(value)
}

export type TagAreaKey = string

export function isTagArea(value: unknown): value is TagAreaKey {
  return typeof value === 'string' && value.length > 0 && value.length <= 40
}
