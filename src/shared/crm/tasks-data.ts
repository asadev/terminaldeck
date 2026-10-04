// Copied from the reference CRM.
import type { TaskTag } from "./tag-areas";
import type { TaskRecurrence } from "./recurrence";
import type { RoutineRule } from "./recurrence-rules";

export type { TaskRecurrence } from "./recurrence";

export type TaskStatus = "To-Do" | "In Progress" | "Done" | "Stuck" | "Working on it";
/**
 * A board: the CRM keeps a fixed list of its own; a local task's board is any
 * name you give it, and "" is no board.
 */
export type TaskBoard = string;
export type TaskPriority = "Low" | "Medium" | "High" | "Critical";

export type Task = {
  id: string;
  title: string;
  group: TaskStatus;
  board: TaskBoard;
  /**
   * null = no priority chosen. Asad, 2026-09-15, pointing at the pill's
   * "Medium priority": "it should not have any pre selected and should not be
   * required too". The column was NOT NULL DEFAULT 'Medium' until
   * migrations/2026-09-15-task-priority-optional.sql; the 19 tasks that
   * carried the default are left as "Medium" — nobody can tell a chosen Medium
   * from a defaulted one after the fact.
   */
  priority: TaskPriority | null;
  /** "YYYY-MM-DD" or "" when the task has no planned start. */
  startDate: string;
  dueDate: string;
  /**
   * How often it comes back; null = one-off. Marking it Done creates the next
   * occurrence (lib/tasks/recurrence.ts). Asad, 2026-09-15: "we must need
   * recurring as well".
   */
  recurrence: TaskRecurrence | null;
  /** Free-text details; "" for legacy tasks that never had one. */
  description: string;
  assigneeUserId: string | null;
  assigneeName: string;
  assigneeInitials: string;
  assigneeColor: string;
  assigneeAvatarUrl: string | null;
  /**
   * Who raised it. Needed to separate "work on my plate" from "work I handed
   * out" — the two piles a person actually thinks in (Asad, 2026-09-14: "we
   * need proper segregation for My tasks and assigned to me type of tasks").
   */
  createdBy: string | null;
  /**
   * ISO, when it was raised. Optional so optimistic client-side objects and
   * the phone route keep compiling; the server read always fills it. The task
   * page paints "You created this task · when" from this on FIRST render,
   * before the activity feed has been fetched (task-detail-panel.tsx).
   */
  createdAt?: string;
  /** Manual position. null = never reordered; those keep the due-date order. */
  sortOrder: number | null;
  /** What the task is about — see tags/tag-areas.ts. */
  links: TaskTag[];
  /**
   * True when the viewer is on this task ONLY through ops.task_assignees —
   * not its assignee_user_id, not its creator (2026-09-14, "one thing can be
   * assigned to multiple people"). The "Assigned to me" pile should count these
   * alongside `assigneeUserId === me`. Optional so the optimistic client-side
   * Task objects and the phone route keep compiling; absent means false.
   */
  isExtraAssignee?: boolean;
  /**
   * The list's row anatomy (ClickUp's "▸ ◌ name ≡ ⚭ 2 ☰ 0/2 · faces"), read in
   * one batch by fetchMyTasks. Absent when that read failed or for an
   * optimistic row — the row then simply draws none of them.
   */
  subtasks?: { id: string; title: string; done: boolean; assigneeUserId: string | null }[];
  checklistTotal?: number;
  checklistDone?: number;
  /** Everyone on the task besides the main person (ops.task_assignees), for the faces. */
  extraAssignees?: TaskAssignee[];
  /**
   * Where the VIEWER dragged this task in their Today group (ops.task_user_order, Umer 2026-09-29) — their
   * own order, never anyone else's. Absent/null = never placed: it follows the placed ones in due-time order.
   */
  myPosition?: number | null;
  /** ClickUp's Tags (ops.tasks.labels) — chips after the name in the list. */
  labels?: string[];
  /** ClickUp's task type (ops.tasks.task_type) — a Milestone draws a diamond instead of the status ring. */
  taskType?: "task" | "milestone";
  /** ⋯ → Archive (migrations/2026-09-15-task-page-2.sql): archived tasks leave the list. */
  archivedAt?: string | null;
  /**
   * Part of a routine, running or STOPPED — it carries a rule, or it is a link in a repeat chain (the server's own
   * test before a merge). ⋯ Merge never offers it (inc8 re-panel #3). Absent when the list's extras read failed.
   */
  isRoutine?: boolean;
  /** Dates → "Add time": a local time of day, "HH:MM". */
  startTime?: string | null;
  dueTime?: string | null;
  /**
   * Held by an AI agent (ops.ai_task_links, ai-tasks/overlay.ts): the assignee fields then name the agent and
   * assigneeUserId is null. Agents appear in Tasks only — never in Employees, the feed or the people lists.
   */
  aiAgent?: { id: string; handle: string; name: string; state: string };
};

/** Payload the New-item dialog hands back to create a task. */
export type NewTaskInput = {
  title: string;
  group: TaskStatus;
  board: TaskBoard;
  /** null = none chosen (optional, like the dates). */
  priority: TaskPriority | null;
  /** Optional "YYYY-MM-DD"; "" = no start date. */
  startDate?: string;
  dueDate: string;
  /** Optional; null/absent = one-off. */
  recurrence?: TaskRecurrence | null;
  /**
   * The create box's full Recurring rule (routine-panel.tsx). When set, createTask checks it BEFORE the
   * task is made and writes it through the routine's one writer; `recurrence` is then its coarse mirror.
   */
  routine?: RoutineRule | null;
  /** Optional free text; "" = no description. */
  description?: string;
  assigneeUserId: string | null;
  /**
   * What the task is ABOUT — a listing, a lead, a file, another task.
   * Several, because one task routinely spans two records ("shoot THIS listing
   * for THAT lead"); ops.tasks' older related_entity_type/_id pair can only
   * hold one and is left alone.
   */
  tags?: TaskTag[];
};

/** A checklist item under a task. */
export type TaskSubtask = {
  id: string;
  taskId: string;
  title: string;
  done: boolean;
  sortOrder: number;
};

/** A comment on a task (author resolved to a display avatar). */
export type TaskComment = {
  id: string;
  taskId: string;
  authorUserId: string | null;
  authorName: string;
  authorInitials: string;
  authorColor: string;
  body: string;
  /** ISO timestamp. */
  createdAt: string;
  /** Written by an AI agent (ai-tasks/overlay.ts) — authorUserId is then null. Absent for a person's comment. */
  aiAgent?: { id: string; handle: string; name: string };
};

/** A teammate who can be assigned a task (for the assignee picker + avatars). */
export type TaskAssignee = {
  id: string;
  name: string;
  initials: string;
  color: string;
  /**
   * The person's photo, or null. `initials` + `color` remain the FALLBACK and
   * are never dropped — most of the 127 profiles have no photo, and a picker
   * that shows a blank circle for them is worse than one that shows initials.
   */
  avatarUrl: string | null;
};

export const STATUS_DOT: Record<TaskStatus, string> = {
  "To-Do": "bg-blue-400",
  "In Progress": "bg-amber-400",
  "Working on it": "bg-amber-400",
  Done: "bg-emerald-500",
  Stuck: "bg-rose-500",
};

export const STATUS_PILL: Record<TaskStatus, string> = {
  "To-Do": "bg-blue-50 text-blue-700",
  "In Progress": "bg-amber-50 text-amber-700",
  "Working on it": "bg-amber-50 text-amber-700",
  Done: "bg-emerald-50 text-emerald-700",
  Stuck: "bg-rose-50 text-rose-700",
};

/** What a board is called on screen: its own name, or "No board". */
export function taskBoardLabel(board: string): string {
  return board.trim() === "" ? "No board" : board;
}

export const PRIORITY_PILL: Record<TaskPriority, string> = {
  Low: "bg-slate-100 text-slate-700",
  Medium: "bg-blue-50 text-blue-700",
  High: "bg-amber-50 text-amber-700",
  Critical: "bg-rose-50 text-rose-700",
};
