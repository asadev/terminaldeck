// Copied from the reference CRM.
/**
 * THE SHAPES THE COLLABORATIVE TASK IS BUILT FROM.
 *
 * Defined in one place BEFORE the actions and the UI are written, because those
 * two are being built in parallel and a type invented twice is a type that
 * drifts. Backed by migrations/2026-09-14-task-collaboration.sql.
 *
 * Asad, 2026-09-14: "one thing can be assigned to multiple people. It cannot it
 * should not be to only one person… If we don't choose it to different people,
 * then the whatever is assigned to as a main person will see it."
 */
import type { TaskAssignee } from "./tasks-data";

/**
 * Everyone on a task. `primary` is ops.tasks.assignee_user_id — kept as the one
 * the notification addresses and the one a sub-item falls back to. The rest
 * come from ops.task_assignees and are equals in every other respect.
 */
export type TaskPeople = {
  primary: TaskAssignee | null;
  others: TaskAssignee[];
};

/** A unit of work under a task. Carries its own person, or inherits. */
export type TaskSubtaskRow = {
  id: string;
  title: string;
  done: boolean;
  sortOrder: number | null;
  /** null = whoever the task is assigned to. */
  assigneeUserId: string | null;
};

export type TaskChecklistItem = {
  id: string;
  title: string;
  done: boolean;
  sortOrder: number | null;
  /** null = whoever the task is assigned to. */
  assigneeUserId: string | null;
};

/** A named tick-list inside a task. A task may have several. */
export type TaskChecklist = {
  id: string;
  title: string;
  sortOrder: number | null;
  items: TaskChecklistItem[];
};

export const DEPENDENCY_KINDS = ["blocked_by", "blocks", "linked"] as const;
export type DependencyKind = (typeof DEPENDENCY_KINDS)[number];

export const DEPENDENCY_LABELS: Record<DependencyKind, string> = {
  blocked_by: "Blocked by",
  blocks: "Blocks",
  linked: "Linked",
};

export type TaskDependency = {
  kind: DependencyKind;
  otherTaskId: string;
  /** The other task's title, resolved for display. */
  otherTitle: string;
  otherDone: boolean;
};

/**
 * An attachment is either an upload of ours or a pointer at a file already in
 * the Files library — never a copy of one, so a document keeps the permissions
 * it already had instead of growing a second, looser set.
 */
export type TaskAttachment = {
  id: string;
  kind: "upload" | "document";
  fileName: string;
  mimeType: string | null;
  sizeBytes: number | null;
  /** Set when kind === "document". */
  documentId: string | null;
  /** Set when kind === "upload". */
  storagePath: string | null;
  uploadedBy: string | null;
  createdAt: string;
  /**
   * Local only: a picture's preview as a `data:` address, for an image small
   * enough to carry — the app's window shows no other kind of image address.
   * Absent or null: the chip shows the file glyph and opens the file instead.
   */
  previewUrl?: string | null;
};

/** Everything the expanded task box needs, in one fetch. */
export type TaskDetailBundle = {
  people: TaskPeople;
  subtasks: TaskSubtaskRow[];
  checklists: TaskChecklist[];
  dependencies: TaskDependency[];
  attachments: TaskAttachment[];
};

/** "0 of 2" — the counter the checklist header shows. */
export function checklistProgress(list: TaskChecklist): { done: number; total: number } {
  return { done: list.items.filter((i) => i.done).length, total: list.items.length };
}

/**
 * Who is actually responsible for a sub-item. The fallback is the product rule,
 * not a convenience: an unassigned item belongs to the task's primary assignee,
 * so nothing is ever ownerless.
 */
export function effectiveAssignee(
  itemAssigneeUserId: string | null,
  people: TaskPeople,
): string | null {
  return itemAssigneeUserId ?? people.primary?.id ?? null;
}
