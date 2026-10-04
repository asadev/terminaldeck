// Copied from the reference CRM.
/**
 * THE TASK PAGE — the pure rules behind ClickUp's open task, copied.
 *
 * Asad, 2026-09-15, with ClickUp's task tab open beside ours: *"i need same size
 * of window and exact same layout … i need a pure copy of this tab"*
 * (docs/clickup-task-inventory.md § 2, docs/task-redesign-backlog.md § K).
 * Everything here is pure — no React, no I/O — so the page, the server actions
 * and the tests read one definition.
 */
import { localClock, localDayStartMs, localParts } from "./local-time";
import { splitInlineFiles, fileToken } from "./inline-files";
import type { TaskStatus } from "./tasks-data";

// ── the heading and the body ───────────────────────────────────────────────

/** ClickUp's title is one line. Ours is the whole task text, so the page shows its first line or sentence as the heading. */
export const HEADING_MAX = 80;

/**
 * Split the task text (STORAGE form, `[[file:…]]` tokens kept whole) into the
 * heading ClickUp would show as the title and the body it would show as the
 * description. DISPLAY ONLY — the stored value stays one field, and editing
 * edits the whole text.
 *
 *   · the first line, when there is more than one line and it fits;
 *   · else the first sentence (". ", "? ", "! "), when it fits;
 *   · else everything, when the whole text fits;
 *   · else a cut at the last word boundary before HEADING_MAX, the heading
 *     ending "…" and the body carrying on from the cut.
 * Lengths count the person's characters only; a token never splits.
 */
export function splitTaskText(text: string): { heading: string; body: string; cut: boolean } {
  const trimmed = text.trim();
  const parts = splitInlineFiles(trimmed);
  // Walk visible characters, remembering where each storage index maps.
  type Pos = { storage: number; visible: number; ch: string | null };
  const positions: Pos[] = [];
  let s = 0;
  let v = 0;
  for (const p of parts) {
    if (p.kind === "file") {
      positions.push({ storage: s, visible: v, ch: null });
      s += fileToken(p.id).length;
      continue;
    }
    for (const ch of p.text) {
      positions.push({ storage: s, visible: v, ch });
      s += ch.length;
      v += 1;
    }
  }
  const visibleTotal = v;
  const at = (i: number) => (i < positions.length ? positions[i].storage : trimmed.length);

  // 1. first line
  const nl = positions.findIndex((p) => p.ch === "\n");
  if (nl > 0 && positions[nl].visible <= HEADING_MAX) {
    return { heading: trimmed.slice(0, at(nl)).trim(), body: trimmed.slice(at(nl) + 1).trim(), cut: false };
  }
  // 2. first sentence
  for (let i = 0; i < positions.length - 1; i++) {
    const p = positions[i];
    if (p.visible >= HEADING_MAX) break;
    if ((p.ch === "." || p.ch === "?" || p.ch === "!") && positions[i + 1].ch === " ") {
      const end = at(i + 1);
      const rest = trimmed.slice(end).trim();
      if (rest) return { heading: trimmed.slice(0, end).trim(), body: rest, cut: false };
    }
  }
  // 3. all of it
  if (visibleTotal <= HEADING_MAX && nl < 0) return { heading: trimmed, body: "", cut: false };
  if (visibleTotal <= HEADING_MAX) return { heading: trimmed.slice(0, at(nl)).trim(), body: trimmed.slice(at(nl) + 1).trim(), cut: false };
  // 4. a word-boundary cut
  let cutIdx = positions.findIndex((p) => p.visible >= HEADING_MAX && p.ch !== null);
  for (let i = cutIdx; i > 0; i--) {
    if (positions[i].ch === " " || positions[i].ch === "\n") {
      cutIdx = i;
      break;
    }
  }
  const end = at(cutIdx);
  return { heading: `${trimmed.slice(0, end).trim()}…`, body: `…${trimmed.slice(end).trim()}`, cut: true };
}

// ── status: ClickUp's ▸ "next status" arrow ───────────────────────────────

/** The order ▸ walks: open → working → in progress → done. Stuck resumes as In Progress. */
export const STATUS_FLOW: TaskStatus[] = ["To-Do", "Working on it", "In Progress", "Done"];

export function nextStatus(s: TaskStatus): TaskStatus | null {
  if (s === "Stuck") return "In Progress";
  const i = STATUS_FLOW.indexOf(s);
  return i >= 0 && i < STATUS_FLOW.length - 1 ? STATUS_FLOW[i + 1] : null;
}

export const STATUS_WORD: Record<TaskStatus, string> = {
  "To-Do": "TO DO",
  "Working on it": "WORKING ON IT",
  "In Progress": "IN PROGRESS",
  Done: "DONE",
  Stuck: "STUCK",
};

// ── time ──────────────────────────────────────────────────────────────────

// The time helpers are the ones already kept in ./task-rules (copied from the same CRM module).
export { formatClock, formatDuration, parseDuration, totalTracked, type TimeEntry } from "./task-rules";
import type { TimeEntry } from "./task-rules";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/**
 * The Activity pane's right-hand time, ClickUp's words: "Just now", "7 mins",
 * "2 hours", "Yesterday at 11:58 pm", "Sep 13 at 4:10 pm", "Sep 13, 2025" —
 * the day and the clock locally. It depends on `now`, so the page renders it
 * through <RelativeTime> (after mount), with activityStamp() before.
 */
export function activityTime(iso: string, now: Date = new Date()): string {
  const ms = new Date(iso).getTime();
  if (!Number.isFinite(ms)) return "";
  const s = Math.max(0, Math.round((now.getTime() - ms) / 1000));
  if (s < 60) return "Just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min${m === 1 ? "" : "s"}`;
  const h = Math.round(m / 60);
  const startToday = localDayStartMs(now);
  if (ms >= startToday) return `${h} hour${h === 1 ? "" : "s"}`;
  if (ms >= startToday - 86400000) return `Yesterday at ${localClock(ms)}`;
  const t = localParts(ms)!;
  if (t.y === localParts(now)!.y) return `${MONTHS[t.m - 1]} ${t.d} at ${localClock(ms)}`;
  return `${MONTHS[t.m - 1]} ${t.d}, ${t.y}`;
}

/** The activity time with no "now" in it — what the server and the first browser render show: "Sep 13 at 4:10 pm". */
export function activityStamp(iso: string): string {
  const t = localParts(iso);
  return t ? `${MONTHS[t.m - 1]} ${t.d} at ${localClock(iso)}` : "";
}

/**
 * A TIME ENTRY'S DAY (local-time review F5): the local day it ENDED — the
 * running timer's, the day it started. A manual entry ends on the day the
 * person chose (now, for today; midday local for another day), and a timer's
 * activity line is logged on the day it stopped, so the row and the line always
 * name the same day — however long the entry, and across midnight.
 */
export function timeEntryDay(e: Pick<TimeEntry, "startedAt" | "endedAt">): string {
  return localParts(e.endedAt ?? e.startedAt)?.ymd ?? "";
}

/** "2026-09-15" → "Sep 15" (a calendar date, no zone involved). */
export function ymdMonthDay(ymd: string): string {
  const [, m, d] = ymd.split("-").map(Number);
  return m && d ? `${MONTHS[m - 1]} ${d}` : "";
}

/** "Sep 15" — the header's "Created Sep 15", the local day. */
export function monthDay(iso: string): string {
  const t = localParts(iso);
  return t ? `${MONTHS[t.m - 1]} ${t.d}` : "";
}

// ── recurring: ClickUp's panel, the options behind the frequency ───────────

/**
 * The options ClickUp's Recurring panel carries beside the frequency (inventory
 * § 2.2): Create new task · Recur forever · Update status to · Sync recurrence
 * to due date. Stored in ops.tasks.recurrence_rule (jsonb,
 * migrations/2026-09-15-task-page.sql); the frequency stays in the
 * `recurrence` column so every older reader keeps working.
 *
 * The trigger is "On status change: Done" — the next occurrence comes when the
 * task is marked done. ClickUp's other trigger, "On schedule", needs a job that
 * runs on a clock; that is a decision for the lead (no scheduler exists), so it
 * is not offered yet.
 */
export type RecurrenceRule = {
  /** true = a NEW task is created for the next occurrence; false = THIS task comes back with new dates. */
  createNew: boolean;
  /** false = stop after `until`. */
  forever: boolean;
  /** "YYYY-MM-DD" — the last due date an occurrence may have. Only read when forever is false. */
  until: string | null;
  /** The status the next occurrence starts in; null = To-Do. */
  updateStatusTo: TaskStatus | null;
  /** true = count the next date from the DUE date; false = from the day it was completed. */
  syncToDue: boolean;
};

/** What a task with a frequency and no stored options does — exactly what it did before the options existed. */
export const DEFAULT_RECURRENCE_RULE: RecurrenceRule = {
  createNew: true,
  forever: true,
  until: null,
  updateStatusTo: null,
  syncToDue: true,
};

const STATUSES: TaskStatus[] = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"];
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** Anything read from the jsonb column, made safe; unknown keys dropped, bad values defaulted. */
export function normalizeRecurrenceRule(raw: unknown): RecurrenceRule {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { ...DEFAULT_RECURRENCE_RULE };
  const r = raw as Record<string, unknown>;
  const until = typeof r.until === "string" && ISO_DATE.test(r.until) ? r.until : null;
  const status = typeof r.updateStatusTo === "string" && (STATUSES as string[]).includes(r.updateStatusTo) ? (r.updateStatusTo as TaskStatus) : null;
  return {
    createNew: typeof r.createNew === "boolean" ? r.createNew : DEFAULT_RECURRENCE_RULE.createNew,
    forever: typeof r.forever === "boolean" ? r.forever : true,
    until: typeof r.forever === "boolean" && !r.forever ? until : null,
    updateStatusTo: status === "Done" ? null : status,
    syncToDue: typeof r.syncToDue === "boolean" ? r.syncToDue : DEFAULT_RECURRENCE_RULE.syncToDue,
  };
}

// ── labels (ClickUp's Tags) ────────────────────────────────────────────────

export const MAX_LABELS = 20;
export const MAX_LABEL_LENGTH = 40;

/** Trimmed, bounded, de-duplicated case-insensitively (the first spelling wins). */
export function normalizeLabels(input: readonly unknown[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const x of input) {
    if (typeof x !== "string") continue;
    const t = x.trim().replace(/\s+/g, " ").slice(0, MAX_LABEL_LENGTH);
    if (!t || seen.has(t.toLowerCase())) continue;
    seen.add(t.toLowerCase());
    out.push(t);
    if (out.length >= MAX_LABELS) break;
  }
  return out;
}

// ── task type ───────────────────────────────────────────────────────────────

export const TASK_TYPES = ["task", "milestone"] as const;
export type TaskType = (typeof TASK_TYPES)[number];
export const TASK_TYPE_LABEL: Record<TaskType, string> = { task: "Task", milestone: "Milestone" };

export function isTaskType(x: unknown): x is TaskType {
  return typeof x === "string" && (TASK_TYPES as readonly string[]).includes(x);
}

// ── what the page reads beyond the bundle ─────────────────────────────────

/** Subtask columns ClickUp's subtask table shows that the older table lacks. */
export type SubtaskMeta = { priority: "Low" | "Medium" | "High" | "Critical" | null; dueDate: string | null };

/**
 * The task page's extra read (task-page-actions.fetchTaskPageExtras): the
 * columns and table migrations/2026-09-15-task-page.sql adds. Until that
 * migration is applied the read fails and the page says so beside the
 * controls that need it — everything else on the page works.
 */
export type TaskPageExtras = {
  taskType: TaskType;
  labels: string[];
  estimateMinutes: number | null;
  recurrenceRule: RecurrenceRule;
  timeEntries: TimeEntry[];
  subtaskMeta: Record<string, SubtaskMeta>;
};

/** The migration the page's extra controls wait on — named in every "unavailable" line. */
export const TASK_PAGE_MIGRATION = "2026-09-15-task-page.sql";

/**
 * What a person reads when a part of the task page cannot be read (round 4): never a developer filename or
 * database text. A part that is not there yet (a table, column or function its migration adds) "isn't
 * available yet"; anything else "could not be read just now". The detail goes to the server log.
 */
export function notAvailableSentence(e: { code?: string } | null | undefined): string {
  return e && ["42P01", "PGRST205", "42703", "PGRST204", "PGRST202", "42883"].includes(e.code ?? "") ? "This isn't available yet." : "This could not be read just now.";
}
