// Copied from the reference CRM.
/**
 * EVERY CALL THE TASK DETAIL PANEL MAKES — as one injectable bundle.
 *
 * The panel (task-detail-panel.tsx) never talks to storage itself. It takes
 * this bundle as a prop. In the reference CRM the default bundle is its server
 * actions; here the bundle is `local-actions.ts`, which sends every call to the
 * main process (`src/main/tasks/task-detail-local.ts`), and a unit test hands
 * it a recorder.
 *
 * Every function returns the result shape the CRM's own actions return
 * (`{ ok: true, id? } | { ok: false, error }`). The panel reads `ok` on every
 * call and puts `error` on screen; nothing is swallowed.
 */

import type { RecurrenceRule, TaskPageExtras, TaskType, TimeEntry } from "../../shared/crm/task-page";
import type { RoutineView } from "../../shared/crm/routine-actions";
import type { RoutineRule } from "../../shared/crm/recurrence-rules";
import type { DescriptionVersion, TaskMore } from "../../shared/crm/task-more-actions";
import type { LabelColor } from "../../shared/crm/task-more";
import type { CommentExtras } from "../../shared/crm/task-comments";
import type { TaskTag } from "../../shared/crm/tag-areas";
import type { TaskBoard } from "../../shared/crm/tasks-data";
import type { TaskActivityRow } from "../../shared/crm/task-activity";
import type { DependencyKind, TaskAttachment, TaskDetailBundle } from "../../shared/crm/collab-types";
import type { TaskComment, TaskPriority, TaskRecurrence, TaskStatus } from "../../shared/crm/tasks-data";

export type ActionResult = { ok: true; id?: string } | { ok: false; error: string };

/** The columns on ops.tasks the panel edits in place. */
export type TaskCorePatch = {
  title?: string;
  priority?: TaskPriority | null;
  description?: string;
  startDate?: string;
  dueDate?: string;
  /** null = stop repeating. */
  recurrence?: TaskRecurrence | null;
};

export type DetailActions = {
  // read
  fetchTaskDetailBundle: (taskId: string) => Promise<{ ok: true; bundle: TaskDetailBundle } | { ok: false; error: string }>;
  listTaskComments: (taskId: string) => Promise<{ ok: true; comments: TaskComment[] } | { ok: false; error: string }>;
  /** The right-hand Activity column (task-activity.ts). Its own call, so a
   *  feed that cannot be read never takes the sections down with it. `rows`
   *  are the task's newest lines; `total` is how many it has in all. */
  listTaskActivity: (taskId: string) => Promise<{ ok: true; rows: TaskActivityRow[]; total?: number } | { ok: false; error: string }>;
  // the task row
  setTaskStatus: (taskId: string, status: TaskStatus) => Promise<ActionResult>;
  updateTask: (taskId: string, patch: TaskCorePatch) => Promise<ActionResult>;
  /** Changes the PRIMARY (ops.tasks.assignee_user_id). */
  assignTask: (taskId: string, userId: string) => Promise<ActionResult>;
  // people
  addTaskAssignee: (taskId: string, userId: string) => Promise<ActionResult>;
  removeTaskAssignee: (taskId: string, userId: string) => Promise<ActionResult>;
  // subtasks
  addTaskSubtask: (taskId: string, title: string) => Promise<ActionResult>;
  setTaskSubtaskDone: (taskId: string, subtaskId: string, done: boolean) => Promise<ActionResult>;
  deleteTaskSubtask: (taskId: string, subtaskId: string) => Promise<ActionResult>;
  setTaskSubtaskAssignee: (taskId: string, subtaskId: string, userId: string | null) => Promise<ActionResult>;
  // checklists
  addChecklist: (taskId: string, title?: string | null) => Promise<ActionResult>;
  renameChecklist: (checklistId: string, title: string) => Promise<ActionResult>;
  deleteChecklist: (checklistId: string) => Promise<ActionResult>;
  addChecklistItem: (checklistId: string, title: string) => Promise<ActionResult>;
  setChecklistItemDone: (itemId: string, done: boolean) => Promise<ActionResult>;
  setChecklistItemAssignee: (itemId: string, userId: string | null) => Promise<ActionResult>;
  deleteChecklistItem: (itemId: string) => Promise<ActionResult>;
  // dependencies
  addTaskDependency: (taskId: string, otherTaskId: string, kind: DependencyKind) => Promise<ActionResult>;
  removeTaskDependency: (taskId: string, otherTaskId: string, kind: DependencyKind) => Promise<ActionResult>;
  // attachments
  attachExistingDocument: (taskId: string, documentId: string) => Promise<ActionResult>;
  detachTaskAttachment: (attachmentId: string) => Promise<ActionResult>;
  /** Bytes to POST /api/tasks/[id]/attachments (a route, not an action — server
   *  actions cannot carry a 25 MB body). Resolves to the row the route recorded. */
  uploadTaskFile: (taskId: string, file: File) => Promise<{ ok: true; attachment: TaskAttachment } | { ok: false; error: string }>;
  // comments
  addTaskComment: (taskId: string, body: string) => Promise<ActionResult>;
  // the task page (task-page-actions.ts; migrations/2026-09-15-task-page.sql)
  fetchTaskPageExtras: (taskId: string) => Promise<{ ok: true; extras: TaskPageExtras } | { ok: false; error: string }>;
  setTaskType: (taskId: string, type: TaskType) => Promise<ActionResult>;
  setTaskLabels: (taskId: string, labels: string[]) => Promise<ActionResult>;
  setTaskLinks: (taskId: string, tags: TaskTag[]) => Promise<ActionResult>;
  moveTask: (taskId: string, board: TaskBoard) => Promise<ActionResult>;
  setTimeEstimate: (taskId: string, minutes: number | null) => Promise<ActionResult>;
  setTaskRecurrence: (taskId: string, recurrence: TaskRecurrence | null, rule: RecurrenceRule | null) => Promise<ActionResult>;
  setSubtaskMeta: (taskId: string, subtaskId: string, patch: { priority?: TaskPriority | null; dueDate?: string | null }) => Promise<ActionResult>;
  startTaskTimer: (taskId: string) => Promise<{ ok: true; entry: TimeEntry } | { ok: false; error: string }>;
  stopTaskTimer: (taskId: string) => Promise<{ ok: true; entry: TimeEntry | null } | { ok: false; error: string }>;
  addTaskTimeEntry: (
    taskId: string,
    input: { seconds: number; date?: string | null; note?: string | null; billable?: boolean },
  ) => Promise<{ ok: true; entry: TimeEntry } | { ok: false; error: string }>;
  deleteTaskTimeEntry: (taskId: string, entryId: string) => Promise<ActionResult>;
  duplicateTask: (taskId: string) => Promise<ActionResult>;
  // routines (routine-actions.ts; migrations/2026-09-15-task-recurrence-routines.sql).
  // Optional: a panel without them shows no routine block and saves the frequency alone.
  fetchRoutine?: (taskId: string) => Promise<{ ok: true; routine: RoutineView } | { ok: false; error: string }>;
  saveRoutine?: (taskId: string, rule: RoutineRule | null, version?: number | null) => Promise<{ ok: true; rootTaskId: string; version?: number | null } | { ok: false; error: string }>;
  stopRoutine?: (taskId: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  pauseRoutine?: (taskId: string, paused: boolean) => Promise<{ ok: true } | { ok: false; error: string }>;
  /** A status routine with no open task makes its next one (routines round 5, F3). */
  restartRoutine?: (taskId: string) => Promise<{ ok: true; taskId: string } | { ok: false; error: string }>;
  // part 2 (task-more-actions.ts; migrations/2026-09-15-task-page-2.sql) — optional for the same reason.
  fetchTaskMore?: (taskId: string) => Promise<{ ok: true; more: TaskMore } | { ok: false; error: string }>;
  setFollowing?: (taskId: string, following: boolean) => Promise<{ ok: true } | { ok: false; error: string }>;
  addFollower?: (taskId: string, personId: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  /** Take someone off the followers — the owner, an admin, or the follower themselves (round 7, V1). */
  removeFollower?: (taskId: string, personId: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  setReminder?: (taskId: string, remindAtIso: string, note?: string | null) => Promise<{ ok: true; id: string } | { ok: false; error: string }>;
  clearReminder?: (taskId: string, reminderId: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  setArchived?: (taskId: string, archived: boolean) => Promise<{ ok: true } | { ok: false; error: string }>;
  mergeTaskInto?: (taskId: string, targetId: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  convertToSubtask?: (taskId: string, parentId: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  setSyncSubtaskDates?: (taskId: string, on: boolean) => Promise<{ ok: true; startDate: string | null; dueDate: string | null } | { ok: false; error: string }>;
  setTaskTimes?: (taskId: string, patch: { startTime?: string | null; dueTime?: string | null }) => Promise<{ ok: true } | { ok: false; error: string }>;
  setLabelColor?: (label: string, color: LabelColor) => Promise<{ ok: true } | { ok: false; error: string }>;
  deleteLabelEverywhere?: (label: string) => Promise<{ ok: true; removed: number; keptElsewhere: number; taskIds?: string[] } | { ok: false; error: string; taskIds?: string[] }>;
  setTimeEntryTags?: (taskId: string, entryId: string, tags: string[]) => Promise<{ ok: true; tags: string[] } | { ok: false; error: string }>;
  fetchDescriptionHistory?: (taskId: string) => Promise<{ ok: true; versions: DescriptionVersion[] } | { ok: false; error: string }>;
  // the comment card (task-comment-actions.ts; migrations/2026-09-15-task-comments.sql)
  fetchCommentExtras: (taskId: string) => Promise<{ ok: true; extras: CommentExtras } | { ok: false; error: string }>;
  addTaskCommentWith: (
    taskId: string,
    body: string,
    opts: { parentId?: string | null; assigneeUserId?: string | null; scheduledFor?: string | null },
  ) => Promise<ActionResult>;
  toggleCommentReaction: (taskId: string, commentId: string, emoji: string) => Promise<{ ok: true; on: boolean } | { ok: false; error: string }>;
  setCommentResolved: (taskId: string, commentId: string, resolved: boolean) => Promise<ActionResult>;
  assignComment: (taskId: string, commentId: string, userId: string | null) => Promise<ActionResult>;
  sendScheduledNow: (taskId: string, commentId: string) => Promise<ActionResult>;
  /**
   * Local only: the Mac's own file chooser, in the main process — every
   * accepted file copied in, the refusals in words. Absent: the browser picker.
   */
  chooseTaskFiles?: (taskId: string) => Promise<{ ok: true; attachments: TaskAttachment[]; errors: string[] } | { ok: false; error: string }>;
  /** Local only: open an attachment in the Mac's own app for it. */
  openTaskFile?: (taskId: string, attachmentId: string) => Promise<ActionResult>;
};
