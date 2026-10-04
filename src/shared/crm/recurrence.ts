// Copied from the reference CRM.
/**
 * RECURRING TASKS — the rule, and what "next" means.
 *
 * ClickUp's due-date panel ends in "Set Recurring ›"; Asad, 2026-09-15: "we
 * must need recurring as well". Ours recurs WHEN THE TASK IS MARKED DONE: the
 * next occurrence is created at that moment, due one interval after this one's
 * due date (or after today when it had none). No scheduler — a task nobody
 * finishes never multiplies, and there is nothing to run at 3 a.m.
 *
 * This file is pure: the rule vocabulary, the labels the panel shows, and the
 * date arithmetic. The database step that copies the task lives in
 * recurrence-spawn.ts so the web action and the phone route share one copy.
 */

import { nextWorkingDay } from "./local-time";

/** The stored value "weekdays" means EVERY WORKING DAY — Monday to Friday; Saturday and Sunday are the days off. */
export const TASK_RECURRENCES = ["daily", "weekdays", "weekly", "monthly", "yearly"] as const;
export type TaskRecurrence = (typeof TASK_RECURRENCES)[number];

export function isTaskRecurrence(s: unknown): s is TaskRecurrence {
  return typeof s === "string" && (TASK_RECURRENCES as readonly string[]).includes(s);
}

/** What the panel's rows say. */
export const RECURRENCE_LABEL: Record<TaskRecurrence, string> = {
  daily: "Daily",
  weekdays: "Every working day (Mon–Sat)",
  weekly: "Weekly",
  monthly: "Monthly",
  yearly: "Yearly",
};

/** The short word the pill and the list show next to the repeat glyph. */
export const RECURRENCE_SHORT: Record<TaskRecurrence, string> = {
  daily: "Daily",
  weekdays: "Working days",
  weekly: "Weekly",
  monthly: "Monthly",
  yearly: "Yearly",
};

function parse(iso: string): { y: number; m: number; d: number } | null {
  const [y, m, d] = iso.split("-").map(Number);
  if (!y || !m || !d) return null;
  return { y, m, d };
}

function fmt(y: number, m: number, d: number): string {
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

function daysInMonth(y: number, m: number): number {
  return new Date(y, m, 0).getDate(); // m is 1-based here; day 0 of the next month
}

/**
 * The due date of the NEXT occurrence, given this one's due date.
 *
 * daily     +1 day
 * weekdays  the next working day, Mon–Fri (local-time.ts: Saturday and Sunday are the days off)
 * weekly    +7 days
 * monthly   same day next month; the 31st becomes the last day of a shorter
 *           month (Jan 31 → Feb 28/29), never spills into the month after
 * yearly    same day next year; Feb 29 → Feb 28 in a common year
 */
export function nextDueDate(due: string, rule: TaskRecurrence): string {
  const p = parse(due);
  if (!p) return due;
  const base = new Date(p.y, p.m - 1, p.d);
  const plusDays = (n: number) => {
    const d = new Date(base);
    d.setDate(d.getDate() + n);
    return fmt(d.getFullYear(), d.getMonth() + 1, d.getDate());
  };
  switch (rule) {
    case "daily":
      return plusDays(1);
    case "weekdays":
      // The day after, or the first working day after it: Fri → Mon, Sat → Mon.
      return nextWorkingDay(plusDays(1));
    case "weekly":
      return plusDays(7);
    case "monthly": {
      const m = p.m === 12 ? 1 : p.m + 1;
      const y = p.m === 12 ? p.y + 1 : p.y;
      return fmt(y, m, Math.min(p.d, daysInMonth(y, m)));
    }
    case "yearly": {
      const y = p.y + 1;
      return fmt(y, p.m, Math.min(p.d, daysInMonth(y, p.m)));
    }
  }
}

/** Whole days from a to b (b − a). */
function dayDelta(a: string, b: string): number {
  const pa = parse(a);
  const pb = parse(b);
  if (!pa || !pb) return 0;
  return Math.round((new Date(pb.y, pb.m - 1, pb.d).getTime() - new Date(pa.y, pa.m - 1, pa.d).getTime()) / 86400000);
}

/**
 * Both dates of the next occurrence. A start date keeps its distance to the
 * due date ("3 days before"); a task with no due date recurs from today.
 */
export function nextOccurrenceDates(
  startDate: string | null,
  dueDate: string | null,
  rule: TaskRecurrence,
  today: string,
  /**
   * Count the next date from here instead of the due date — ClickUp's "Sync
   * recurrence to due date" switched OFF (the next one is one interval after
   * the day it was completed). The start still keeps its lead.
   */
  from?: string | null,
): { startDate: string | null; dueDate: string } {
  const due = nextDueDate(from || dueDate || today, rule);
  if (!startDate) return { startDate: null, dueDate: due };
  const lead = dueDate ? dayDelta(startDate, dueDate) : 0;
  const dp = parse(due)!;
  const s = new Date(dp.y, dp.m - 1, dp.d);
  s.setDate(s.getDate() - Math.max(0, lead));
  return { startDate: fmt(s.getFullYear(), s.getMonth() + 1, s.getDate()), dueDate: due };
}
