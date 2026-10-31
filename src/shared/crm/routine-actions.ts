/**
 * Copied from the reference CRM: the shape of a task's routine as its task
 * page reads it. Only the type; the local answer comes from
 * `src/main/tasks/task-detail-local.ts`.
 */
import type { OccurrenceRow, RoutineRule } from "./recurrence-rules";

export type RoutineView = {
  rootTaskId: string;
  rootTitle: string;
  /** This page IS the routine's own task (not one of its occurrences). */
  isRoot: boolean;
  rule: RoutineRule | null;
  /** The caller may change the routine. */
  canEdit: boolean;
  /** Newest first; null when there is no history to read. */
  history: (OccurrenceRow & { who: string | null })[] | null;
  historyError: string | null;
  /** The routine's last failure, as a sentence. */
  lastError: { at: string; message: string } | null;
  /** The next few dates, when active. */
  next: string[];
  /** People on the routine's task. */
  peopleCount: number;
  /** The rule's version as read; Save sends it back. */
  version: number | null;
  /** Why nothing more will come although the rule is running, shown instead of next dates. */
  stuck: string | null;
  /** Restart is offered. */
  canRestart: boolean;
  /** What the next-date line is computed from. */
  anchor: string | null;
  /** This task's own occurrence date, when it has one. */
  occurrence: string | null;
  /** Occurrence dates made so far. */
  datesSoFar: number;
};
