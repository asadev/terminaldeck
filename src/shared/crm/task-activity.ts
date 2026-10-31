/**
 * Copied from the reference CRM: the shape of one line in a task's Activity
 * column. Only the types — the CRM writes and reads these rows in its
 * database; here `src/main/tasks/task-detail-local.ts` builds them from the
 * local task's own record.
 */
import type { TaskAssignee } from "./tasks-data";

export const ACTIVITY_KINDS = [
  "created",
  "title",
  "description",
  "status",
  "priority",
  "dates",
  "assigned",
  "unassigned",
  "subtask_added",
  "subtask_done",
  "checklist_added",
  "checklist_item",
  "dependency",
  "attachment",
  "comment",
  "time_tracked",
  "estimate",
  "tags",
  "task_type",
  "moved",
  "recurrence",
  "field",
  "archived",
  "follower",
  "merged",
  "converted",
  "map",
] as const;
export type ActivityKind = (typeof ACTIVITY_KINDS)[number];

export type ActivityPayload = Record<string, string | number | boolean | null>;

/** What a payload value can be once read back. */
export type ActivityReadValue = string | number | boolean | null | ActivityReadValue[] | { [key: string]: ActivityReadValue };
export type ActivityReadPayload = Record<string, ActivityReadValue>;

export type TaskActivityRow = {
  id: string;
  taskId: string;
  kind: ActivityKind;
  payload: ActivityReadPayload;
  /** null = the system, or a person who no longer exists. */
  actor: TaskAssignee | null;
  actorUserId: string | null;
  /** ISO. */
  createdAt: string;
};

/** The most lines one read gives back; the rest are counted in `total`. */
export const ACTIVITY_READ_LIMIT = 500;
