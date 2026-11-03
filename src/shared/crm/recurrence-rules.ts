// Copied from the reference CRM.
/**
 * ROUTINES — ClickUp's full Recurring panel, as rules and date maths (pure).
 *
 * Asad, 2026-09-15: *"check how clickup does recurring, we need same, most
 * probably routine task which assignee needs to daily mark as done or any
 * status, and we can choose the period how long this routine should continue
 * or till we stop"* — and yes to the server job "On a schedule" needs.
 *
 * ClickUp's panel (docs/clickup-task-inventory.md § 2.2 / 2.2a; the frequency
 * list is from ClickUp's documentation — the automation could not open it):
 *   FREQUENCY  Daily · Weekly (on chosen weekdays) · Monthly (on day N, or the
 *              nth weekday — "last Friday") · Yearly · Days after (N days after
 *              it was completed) · Custom (every N days / weeks / months / years)
 *   TRIGGER    On status change: <a status> · On a schedule (at a local time)
 *   ENDS       Recur forever, or until a date, or after N times
 *   OPTIONS    Create new task · Update status to · Sync recurrence to due date ·
 *              Skip weekends (the weekend — local-time.ts DAYS_OFF;
 *              the stored key stays `skipWeekends`, read by the phones)
 *   OURS       One copy per assignee (each person marks their own) · when the
 *              next one arrives, the previous open one is left open or marked
 *              Missed · Pause / Stop (history is kept)
 *
 * Stored in ops.tasks.recurrence_rule (jsonb). The legacy `recurrence` column
 * keeps a coarse value (daily · weekdays · weekly · monthly · yearly) so every
 * older reader — the phones, the list's repeat glyph — keeps working.
 *
 * Dates are "YYYY-MM-DD" and all arithmetic is done on UTC calendar days, so
 * there is no timezone drift; a time of day is local local .
 */
import type { TaskStatus } from "./tasks-data";
import { isTaskRecurrence, type TaskRecurrence } from "./recurrence";
import { DAYS_OFF, DAYS_OFF_LABEL, isLocalDayOff, localInstantAt, localToday, nextWorkingDay } from "./local-time";

export type Frequency = "daily" | "weekly" | "monthly" | "yearly" | "days_after" | "custom";
export type CustomUnit = "day" | "week" | "month" | "year";
/** 1–4 = first…fourth, -1 = last. */
export type Nth = 1 | 2 | 3 | 4 | -1;
export type MonthlySpec = { mode: "day"; day: number } | { mode: "nth"; nth: Nth; weekday: number };
export type RoutineEnds = { type: "never" } | { type: "until"; until: string } | { type: "count"; count: number };

export type RoutineRule = {
  frequency: Frequency;
  /** Every N (days / weeks / months / years); for days_after, N days after completion. */
  interval: number;
  /** Custom's unit. */
  unit: CustomUnit;
  /** 0 = Sun … 6 = Sat. Weekly / custom-week: the days it falls on (none = the anchor's weekday). */
  weekdays: number[];
  /** Monthly / custom-month: on day N, or the nth weekday. null = the anchor's day of the month. */
  monthly: MonthlySpec | null;
  trigger: "status" | "schedule";
  /** On status change: this status brings the next one. */
  triggerStatus: TaskStatus;
  /** On a schedule: the local time the next one is created at, "HH:MM". */
  timeOfDay: string;
  ends: RoutineEnds;
  /** On: a new task each time. Off: this task comes back with the next dates. */
  createNew: boolean;
  /** The status the next one starts in. */
  updateStatusTo: TaskStatus;
  /** On: count from the due date. Off: from the day it was completed (status trigger). */
  syncToDue: boolean;
  /**
   * "Skip weekends": never on a day off (local-time.ts DAYS_OFF — Saturday and Sunday here) — a date
   * that lands there moves to the next working day. The key keeps its
   * old name: it is stored in every rule and read by the phones.
   */
  skipWeekends: boolean;
  /** Each person on the task gets their own occurrence to mark done. */
  perAssignee: boolean;
  /** When the next one arrives, what happens to the previous open one. */
  missedPolicy: "leave_open" | "mark_missed";
  /** Paused: no new occurrences until resumed. */
  pausedAt: string | null;
  /** Stopped: the routine is over; its history stays. */
  stoppedAt: string | null;
  /** On a spawned occurrence: the task the routine began on (its history lives there). */
  rootTaskId: string | null;
  /**
   * The routine's first date. EVERY date is counted from it — never from the
   * previous occurrence — so a date clamped to a short month (31st → 28th), a
   * leap day (29 Feb → 28 Feb) or a weekend moved to Monday never shifts the
   * dates after it. null (older rules) = count from the date in hand.
   */
  anchor: string | null;
};

const STATUSES: TaskStatus[] = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"];
const YMD = /^\d{4}-\d{2}-\d{2}$/;

export const DEFAULT_ROUTINE: RoutineRule = {
  frequency: "weekly",
  interval: 1,
  unit: "day",
  weekdays: [],
  monthly: null,
  trigger: "status",
  triggerStatus: "Done",
  timeOfDay: "08:00",
  ends: { type: "never" },
  createNew: true,
  updateStatusTo: "To-Do",
  syncToDue: true,
  skipWeekends: false,
  perAssignee: false,
  missedPolicy: "leave_open",
  pausedAt: null,
  stoppedAt: null,
  rootTaskId: null,
  anchor: null,
};

// ── calendar arithmetic on "YYYY-MM-DD" ────────────────────────────────────

function parts(ymd: string): { y: number; m: number; d: number } | null {
  if (!YMD.test(ymd)) return null;
  const [y, m, d] = ymd.split("-").map(Number);
  return { y, m, d };
}
function utc(y: number, m: number, d: number): Date {
  return new Date(Date.UTC(y, m - 1, d));
}
function fmt(dt: Date): string {
  return dt.toISOString().slice(0, 10);
}
export function addDays(ymd: string, n: number): string {
  const p = parts(ymd)!;
  return fmt(utc(p.y, p.m, p.d + n));
}
export function weekdayOf(ymd: string): number {
  const p = parts(ymd)!;
  return utc(p.y, p.m, p.d).getUTCDay();
}
function daysInMonth(y: number, m: number): number {
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}
/** The Monday of the week `ymd` is in. */
function mondayOf(ymd: string): string {
  return addDays(ymd, -((weekdayOf(ymd) + 6) % 7));
}
/** Whole days from a to b (b − a). */
export function daysBetween(a: string, b: string): number {
  const pa = parts(a)!;
  const pb = parts(b)!;
  return Math.round((utc(pb.y, pb.m, pb.d).getTime() - utc(pa.y, pa.m, pa.d).getTime()) / 86400000);
}
/** A day off (Saturday or Sunday) — asked of local-time.ts, the one place that knows. */
export function isDayOff(ymd: string): boolean {
  return isLocalDayOff(ymd);
}
/** A day off moves to the next working day (Saturday or Sunday → Monday). */
export function skipDayOff(ymd: string): string {
  return nextWorkingDay(ymd);
}
/** The option's words, the same on the panel, the summary and the MCP tool: "Skip weekends". */
export const SKIP_DAYS_OFF_LABEL = `Skip ${DAYS_OFF_LABEL}s`;
/** The working days (0 = Sunday … 6 = Saturday) — every day but the days off. */
export const WORKING_WEEKDAYS: readonly number[] = [0, 1, 2, 3, 4, 5, 6].filter((d) => !DAYS_OFF.includes(d));

/** The nth weekday of a month (nth -1 = the last one); null when there is no fifth. */
export function nthWeekdayOfMonth(y: number, m: number, nth: Nth, weekday: number): string {
  if (nth === -1) {
    const last = daysInMonth(y, m);
    const w = utc(y, m, last).getUTCDay();
    return fmt(utc(y, m, last - ((w - weekday + 7) % 7)));
  }
  const firstW = utc(y, m, 1).getUTCDay();
  const day = 1 + ((weekday - firstW + 7) % 7) + (nth - 1) * 7;
  return fmt(utc(y, m, Math.min(day, daysInMonth(y, m))));
}

function addMonths(ymd: string, n: number, spec: MonthlySpec | null): string {
  const p = parts(ymd)!;
  const total = p.m - 1 + n;
  const y = p.y + Math.floor(total / 12);
  const m = (((total % 12) + 12) % 12) + 1;
  if (spec?.mode === "nth") return nthWeekdayOfMonth(y, m, spec.nth, spec.weekday);
  const day = spec?.mode === "day" ? spec.day : p.d;
  return fmt(utc(y, m, Math.min(day, daysInMonth(y, m))));
}

function addYears(ymd: string, n: number): string {
  const p = parts(ymd)!;
  const y = p.y + n;
  return fmt(utc(y, p.m, Math.min(p.d, daysInMonth(y, p.m)))); // Feb 29 → Feb 28 in a common year
}


function monthsBetween(a: string, b: string): number {
  const pa = parts(a)!;
  const pb = parts(b)!;
  return (pb.y - pa.y) * 12 + (pb.m - pa.m);
}

function unitOf(rule: RoutineRule): CustomUnit {
  if (rule.frequency === "custom") return rule.unit;
  return rule.frequency === "weekly" ? "week" : rule.frequency === "monthly" ? "month" : rule.frequency === "yearly" ? "year" : "day";
}

/** The k-th date of a plain (non-weekday) rule, counted from its anchor; k = 0 is the anchor. */
function rawNth(anchor: string, rule: RoutineRule, k: number): string {
  const n = Math.max(1, Math.floor(rule.interval || 1));
  const unit = unitOf(rule);
  if (unit === "week") return addDays(anchor, 7 * n * k);
  if (unit === "month") return addMonths(anchor, n * k, rule.monthly);
  if (unit === "year") return addYears(anchor, n * k);
  return addDays(anchor, n * k);
}

/**
 * THE FIRST DATE OF THE RULE STRICTLY AFTER `after`, every date counted from
 * `anchor`. "Days after" counts from `after` itself (the day it was done).
 * Skip weekends moves a day off to the next working day — unless the person
 * picked that weekday themselves, which is a clearer instruction than the box —
 * and a moved date never moves the ones after it.
 */
export function nextAfter(anchor: string, rule: RoutineRule, after: string): string {
  const n = Math.max(1, Math.floor(rule.interval || 1));
  const unit = unitOf(rule);
  const pickedDayOff = unit === "week" && rule.weekdays.some((w) => DAYS_OFF.includes(w));
  const shift = (d: string) => (rule.skipWeekends && !pickedDayOff ? skipDayOff(d) : d);
  if (rule.frequency === "days_after") return shift(addDays(after, n));
  if (unit === "week" && rule.weekdays.length) {
    // Before the anchor, the anchor itself is the first date (as in the plain branch below).
    const start = after >= anchor ? after : addDays(anchor, -1);
    const anchorWeek = mondayOf(anchor);
    for (let i = 1; i <= 7 * n + 14; i++) {
      const d = addDays(start, i);
      if (!rule.weekdays.includes(weekdayOf(d))) continue;
      if (Math.round(daysBetween(anchorWeek, mondayOf(d)) / 7) % n !== 0) continue;
      const out = shift(d);
      if (out > after) return out;
    }
    return addDays(after, 7 * n);
  }
  // Jump near `after` so an old anchor costs nothing, then walk.
  let k0 = 0;
  if (after > anchor) {
    if (unit === "month") k0 = Math.floor(monthsBetween(anchor, after) / n) - 1;
    else if (unit === "year") k0 = Math.floor((parts(after)!.y - parts(anchor)!.y) / n) - 1;
    else k0 = Math.floor(daysBetween(anchor, after) / (n * (unit === "week" ? 7 : 1))) - 1;
  }
  for (let k = Math.max(0, k0); k < Math.max(0, k0) + 400; k++) {
    const out = shift(rawNth(anchor, rule, k));
    if (out > after) return out;
  }
  return shift(rawNth(anchor, rule, Math.max(0, k0) + 400));
}

/** The next date after `from`, counted from the rule's anchor (or from `from` for a rule without one). */
export function nextOccurrence(from: string, rule: RoutineRule): string {
  return nextAfter(rule.anchor ?? from, rule, from);
}

/** Would an occurrence on `ymd`, the (count+1)-th, be past the routine's end? */
export function isPastEnd(rule: RoutineRule, ymd: string, occurrencesSoFar: number): boolean {
  if (rule.ends.type === "until") return ymd > rule.ends.until;
  if (rule.ends.type === "count") return occurrencesSoFar >= rule.ends.count;
  return false;
}

/** Active = neither paused nor stopped. */
export function isActive(rule: RoutineRule | null): boolean {
  return !!rule && !rule.pausedAt && !rule.stoppedAt;
}

/** A local time on a day, as the instant it is ("2026-09-16", "08:00" → 08:00 on this computer). */
export function localInstant(ymd: string, timeOfDay: string): Date {
  const t = /^\d{2}:\d{2}$/.test(timeOfDay) ? timeOfDay : "08:00";
  return localInstantAt(ymd, Number(t.slice(0, 2)), Number(t.slice(3, 5)));
}

/**
 * THE SCHEDULE'S CATCH-UP: after the routine's last occurrence (`last`), which
 * dates' moments have come by `now` (local time of day)? Returns the LATEST
 * one — the only one the job creates — and at most the 14 before it (recorded
 * as skipped), with the true count of the gap. Never a pile of stale tasks:
 * a routine anchored in January creates today's, not January's.
 */
export function dueScheduleDates(
  anchor: string,
  last: string,
  rule: RoutineRule,
  now: Date,
  datesSoFar: number,
): { latest: string | null; gap: string[]; gapTotal: number } {
  // "After N times" counts occurrences MADE. The gap's dates are recorded as
  // skipped and never made, so they never use up the count (routines review
  // round 2, #7) — the one made is the latest due date, never an old one.
  if (rule.ends.type === "count" && datesSoFar >= rule.ends.count) return { latest: null, gap: [], gapTotal: 0 };
  let cur = last;
  let latest: string | null = null;
  const recent: string[] = [];
  let total = 0;
  for (let i = 0; i < 20000; i++) {
    const next = nextAfter(anchor, rule, cur);
    if (localInstant(next, rule.timeOfDay).getTime() > now.getTime()) break;
    if (rule.ends.type === "until" && next > rule.ends.until) break;
    if (latest) {
      recent.push(latest);
      if (recent.length > 14) recent.shift();
    }
    latest = next;
    total++;
    cur = next;
  }
  return { latest, gap: recent, gapTotal: Math.max(0, total - 1) };
}

/** The next few dates, for the calendar's tint and the summary. */
export function upcoming(from: string, rule: RoutineRule, count = 3, occurrencesSoFar = 0): string[] {
  const out: string[] = [];
  let cur = from;
  const anchor = rule.anchor ?? from;
  for (let i = 0; i < count; i++) {
    const next = nextAfter(anchor, rule, cur);
    if (isPastEnd(rule, next, occurrencesSoFar + out.length)) break;
    out.push(next);
    cur = next;
  }
  return out;
}

// ── the legacy column, and reading what is stored ───────────────────────────

/** The coarse value the older `recurrence` column holds for this rule. */
/** Exactly the working days (Mon–Fri): the older column's "weekdays" — its words are "Every working day". */
function isWorkingWeek(weekdays: number[]): boolean {
  return weekdays.length === WORKING_WEEKDAYS.length && WORKING_WEEKDAYS.every((d) => weekdays.includes(d));
}

export function legacyRecurrence(rule: RoutineRule): TaskRecurrence {
  const unit = rule.frequency === "custom" ? rule.unit : rule.frequency;
  if ((unit === "daily" || unit === "day") && rule.skipWeekends && rule.interval === 1) return "weekdays";
  if ((unit === "weekly" || unit === "week") && rule.interval === 1 && isWorkingWeek(rule.weekdays)) return "weekdays";
  if (unit === "weekly" || unit === "week") return "weekly";
  if (unit === "monthly" || unit === "month") return "monthly";
  if (unit === "yearly" || unit === "year") return "yearly";
  return "daily";
}

/** A rule for one of the older frequencies (no stored options). */
export function ruleFromLegacy(rec: TaskRecurrence): RoutineRule {
  switch (rec) {
    case "daily":
      return { ...DEFAULT_ROUTINE, frequency: "daily" };
    case "weekdays":
      // "Every working day": Monday to Friday — Saturday and Sunday are the days off here.
      return { ...DEFAULT_ROUTINE, frequency: "weekly", weekdays: [...WORKING_WEEKDAYS] };
    case "weekly":
      return { ...DEFAULT_ROUTINE, frequency: "weekly" };
    case "monthly":
      return { ...DEFAULT_ROUTINE, frequency: "monthly" };
    case "yearly":
      return { ...DEFAULT_ROUTINE, frequency: "yearly" };
  }
}

const FREQS: Frequency[] = ["daily", "weekly", "monthly", "yearly", "days_after", "custom"];
const UNITS: CustomUnit[] = ["day", "week", "month", "year"];
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

/**
 * Anything read from recurrence_rule, made safe, understood with the legacy
 * `recurrence` column. The first options shape (createNew · forever · until ·
 * updateStatusTo · syncToDue, from the task-page increment) reads as the same
 * routine it described. Null = the task does not recur.
 */
export function normalizeRoutine(raw: unknown, legacy: unknown): RoutineRule | null {
  const base = isTaskRecurrence(legacy) ? ruleFromLegacy(legacy) : null;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return base;
  const r = raw as Record<string, unknown>;
  const start: RoutineRule = base ?? { ...DEFAULT_ROUTINE };
  const frequency = FREQS.includes(r.frequency as Frequency) ? (r.frequency as Frequency) : start.frequency;
  const interval = Number.isInteger(r.interval) && (r.interval as number) >= 1 && (r.interval as number) <= 365 ? (r.interval as number) : start.interval;
  const unit = UNITS.includes(r.unit as CustomUnit) ? (r.unit as CustomUnit) : start.unit;
  const weekdays = Array.isArray(r.weekdays)
    ? [...new Set((r.weekdays as unknown[]).filter((w): w is number => Number.isInteger(w) && (w as number) >= 0 && (w as number) <= 6))].sort()
    : start.weekdays;
  let monthly: MonthlySpec | null = start.monthly;
  const mo = r.monthly as Record<string, unknown> | null | undefined;
  if (mo && typeof mo === "object") {
    if (mo.mode === "day" && Number.isInteger(mo.day) && (mo.day as number) >= 1 && (mo.day as number) <= 31) monthly = { mode: "day", day: mo.day as number };
    else if (mo.mode === "nth" && [1, 2, 3, 4, -1].includes(mo.nth as number) && Number.isInteger(mo.weekday) && (mo.weekday as number) >= 0 && (mo.weekday as number) <= 6)
      monthly = { mode: "nth", nth: mo.nth as Nth, weekday: mo.weekday as number };
  }
  const status = (k: string, fallback: TaskStatus) => (STATUSES.includes(r[k] as TaskStatus) ? (r[k] as TaskStatus) : fallback);
  // Ends: the new shape, or the first shape's forever/until.
  let ends: RoutineEnds = start.ends;
  const e = r.ends as Record<string, unknown> | undefined;
  if (e && typeof e === "object") {
    if (e.type === "until" && typeof e.until === "string" && YMD.test(e.until)) ends = { type: "until", until: e.until };
    else if (e.type === "count" && Number.isInteger(e.count) && (e.count as number) >= 1 && (e.count as number) <= 1000) ends = { type: "count", count: e.count as number };
    else if (e.type === "never") ends = { type: "never" };
  } else if (r.forever === false && typeof r.until === "string" && YMD.test(r.until)) {
    ends = { type: "until", until: r.until };
  }
  const iso = (k: string) => (typeof r[k] === "string" && Number.isFinite(new Date(r[k] as string).getTime()) ? (r[k] as string) : null);
  return {
    frequency,
    interval,
    unit,
    weekdays,
    monthly,
    trigger: r.trigger === "schedule" ? "schedule" : "status",
    triggerStatus: status("triggerStatus", "Done"),
    timeOfDay: typeof r.timeOfDay === "string" && TIME.test(r.timeOfDay) ? r.timeOfDay : "08:00",
    ends,
    createNew: typeof r.createNew === "boolean" ? r.createNew : start.createNew,
    updateStatusTo: (() => {
      const s = status("updateStatusTo", "To-Do");
      return s === "Done" ? "To-Do" : s;
    })(),
    syncToDue: typeof r.syncToDue === "boolean" ? r.syncToDue : start.syncToDue,
    skipWeekends: r.skipWeekends === true,
    perAssignee: r.perAssignee === true,
    missedPolicy: r.missedPolicy === "mark_missed" ? "mark_missed" : "leave_open",
    pausedAt: iso("pausedAt"),
    stoppedAt: iso("stoppedAt"),
    // An id (uuid in the database); only ever used in .eq(), bounded here all the same.
    rootTaskId: typeof r.rootTaskId === "string" && /^[0-9A-Za-z-]{1,64}$/.test(r.rootTaskId) ? r.rootTaskId : null,
    anchor: typeof r.anchor === "string" && YMD.test(r.anchor) ? r.anchor : null,
  };
}

/**
 * What is written to recurrence_rule. The first options shape's keys (forever ·
 * until) are mirrored so a reader built on it — the MCP tools' get-task —
 * still reads the right end date.
 */
export function serializeRoutine(rule: RoutineRule): Record<string, unknown> {
  return {
    frequency: rule.frequency,
    interval: rule.interval,
    unit: rule.unit,
    weekdays: rule.weekdays,
    monthly: rule.monthly,
    trigger: rule.trigger,
    triggerStatus: rule.triggerStatus,
    timeOfDay: rule.timeOfDay,
    ends: rule.ends,
    createNew: rule.createNew,
    updateStatusTo: rule.updateStatusTo,
    syncToDue: rule.syncToDue,
    skipWeekends: rule.skipWeekends,
    perAssignee: rule.perAssignee,
    missedPolicy: rule.missedPolicy,
    pausedAt: rule.pausedAt,
    stoppedAt: rule.stoppedAt,
    ...(rule.rootTaskId ? { rootTaskId: rule.rootTaskId } : {}),
    anchor: rule.anchor,
    forever: rule.ends.type !== "until",
    until: rule.ends.type === "until" ? rule.ends.until : null,
  };
}

// ── the routine's history ───────────────────────────────────────────────────

/** One row of ops.task_recurrence_occurrences, as the page reads it. */
export type OccurrenceRow = {
  id: string;
  occurrenceDate: string;
  dueDate: string | null;
  /** Whose copy it is (one copy per assignee); null = the whole task. */
  assigneeUserId: string | null;
  spawnedTaskId: string | null;
  status: "open" | "done" | "missed" | "skipped";
  completedAt: string | null;
  completedBy: string | null;
};

export type HistoryState = "on_time" | "late" | "missed" | "overdue" | "open" | "skipped";

export const HISTORY_LABEL: Record<HistoryState, string> = {
  on_time: "Done on time",
  late: "Done late",
  missed: "Missed",
  overdue: "Overdue",
  open: "Open",
  skipped: "Skipped",
};

/** The local calendar day of an instant. */
export function localDateOf(iso: string): string | null {
  const t = new Date(iso).getTime();
  return Number.isFinite(t) ? localToday(new Date(t)) : null;
}

/**
 * A manager's question — was it done, on time? Done by the end of its due day
 * (local) is on time, after is late; a row marked missed and never done is
 * missed; an open one past its day is overdue; a date the job did not run for
 * is skipped.
 */
export function historyState(row: Pick<OccurrenceRow, "status" | "completedAt" | "dueDate" | "occurrenceDate">, today: string): HistoryState {
  const due = row.dueDate ?? row.occurrenceDate;
  if (row.status === "skipped") return "skipped";
  if (row.status === "done") {
    const d = row.completedAt ? localDateOf(row.completedAt) : null;
    return d && d > due ? "late" : "on_time";
  }
  if (row.status === "missed") return "missed";
  return due < today ? "overdue" : "open";
}

// ── words ───────────────────────────────────────────────────────────────────

const DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const DAY_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const NTH_WORD: Record<string, string> = { "1": "first", "2": "second", "3": "third", "4": "fourth", "-1": "last" };
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function shortDate(ymd: string): string {
  const p = parts(ymd);
  return p ? `${p.d} ${MON[p.m - 1]}` : ymd;
}

/** "Wed 16 Sep". */
export function shortDay(ymd: string): string {
  const p = parts(ymd);
  return p ? `${DAY_SHORT[weekdayOf(ymd)]} ${p.d} ${MON[p.m - 1]}` : ymd;
}

/** "Every weekday at 08:00, until 31 Dec, one copy per assignee" — the line the task and the list show. */
export function routineSummary(rule: RoutineRule): string {
  const n = rule.interval;
  const unit = rule.frequency === "custom" ? rule.unit : rule.frequency;
  let what: string;
  if (rule.frequency === "days_after") what = `${n} day${n === 1 ? "" : "s"} after it is done`;
  else if ((unit === "weekly" || unit === "week") && rule.weekdays.length) {
    const wd = [...rule.weekdays].sort();
    const label = isWorkingWeek(wd) ? "working day" : wd.map((d) => DAY_SHORT[d]).join(", ");
    what = n === 1 ? `Every ${label}` : `Every ${n} weeks on ${label}`;
  } else if ((unit === "daily" || unit === "day") && rule.skipWeekends && n === 1) what = "Every working day";
  else if (unit === "monthly" || unit === "month") {
    const on = rule.monthly?.mode === "nth" ? ` on the ${NTH_WORD[String(rule.monthly.nth)]} ${DAY_LONG[rule.monthly.weekday]}` : rule.monthly?.mode === "day" ? ` on day ${rule.monthly.day}` : "";
    what = (n === 1 ? "Monthly" : `Every ${n} months`) + on;
  } else {
    const word = unit === "daily" || unit === "day" ? "day" : unit === "weekly" || unit === "week" ? "week" : "year";
    const ly: Record<string, string> = { day: "Daily", week: "Weekly", year: "Yearly" };
    what = n === 1 ? ly[word] : `Every ${n} ${word}s`;
  }
  const bits = [what + (rule.trigger === "schedule" ? ` at ${rule.timeOfDay}` : "")];
  if (rule.trigger === "status") bits.push(`when ${rule.triggerStatus === "Done" ? "done" : `set to ${rule.triggerStatus}`}`);
  if (rule.ends.type === "until") bits.push(`until ${shortDate(rule.ends.until)}`);
  if (rule.ends.type === "count") bits.push(`${rule.ends.count} times`);
  if (rule.perAssignee) bits.push("one copy per assignee");
  if (rule.skipWeekends && !what.startsWith("Every working day")) bits.push(`skipping ${DAYS_OFF_LABEL}s`);
  const head = bits.join(", ");
  if (rule.stoppedAt) return `${head} — stopped`;
  if (rule.pausedAt) return `${head} — paused`;
  return head;
}

/**
 * What moving a task's date does to its routine — the rule the engine keeps (routines review round 4): a
 * date move never moves the routine, only that task. For the open task of a status-change routine the next
 * one comes after the later of its dates. null: the task does not recur, or its routine has stopped.
 *
 * THE LINE MUST BE TRUE (routines round 6, finding 3). With Sync on the next date follows the task's dates,
 * so it is said as a date. With Sync off — the panel's default — and with "days after", the next date counts
 * from the DAY IT IS DONE, which nobody knows yet: the line says it for one stated day, computed with the
 * engine's own function — its due date when that is still ahead, else today — and says that it counts from
 * the day it's done ("If done on its due date (Fri 25 Sep), the next copy is due Fri 2 Oct"). Never a
 * finish-today date read as a promise. Paused: nothing is made until it is resumed.
 */
export function dateMoveNote(
  rule: RoutineRule | null,
  ctx: { status: string; due: string | null; anchor: string | null; occurrence: string | null; today: string; datesSoFar?: number; scheduleNext?: string | null },
): string | null {
  if (!rule || rule.stoppedAt) return null;
  if (rule.pausedAt) return "Routine paused — nothing will be made until it's resumed.";
  if (rule.trigger === "schedule")
    return ctx.scheduleNext ? `Next copy: ${shortDay(ctx.scheduleNext)} — moving this date doesn't change it` : "Moving this date moves only this task.";
  const done = ctx.status === "Done" || ctx.status === rule.triggerStatus;
  if (done) return "Moving this date moves only this task.";
  const anchor = ctx.anchor ?? ctx.due ?? ctx.today;
  if (nextMovesWithDue(rule) && ctx.due) {
    const d = nextDateOnDone(rule, { anchor, occurrence: ctx.occurrence, due: ctx.due, today: ctx.today });
    if (isPastEnd(rule, d, ctx.datesSoFar ?? 0)) return "This is the last one — nothing comes after it.";
    return `${rule.createNew ? "Next copy" : "Comes back"}: ${shortDay(d)} — moves with this date`;
  }
  // Counted from the day it is done: said for one stated finish day — its due date while that is ahead, else today.
  const onDue = !!ctx.due && ctx.due >= ctx.today;
  const finish = onDue ? (ctx.due as string) : ctx.today;
  const when = onDue ? `on its due date (${shortDay(finish)})` : `today (${shortDay(finish)})`;
  const d = nextDateOnDone(rule, { anchor, occurrence: ctx.occurrence, due: ctx.due, today: finish });
  if (isPastEnd(rule, d, ctx.datesSoFar ?? 0)) {
    const until = rule.ends.type === "until" ? rule.ends.until : null;
    return until ? `If done ${when}, nothing comes after it — the routine ends ${shortDay(until)}.` : "This is the last one — nothing comes after it.";
  }
  return rule.createNew
    ? `If done ${when}, the next copy is due ${shortDay(d)} — it counts from the day it's done.`
    : `If done ${when}, it comes back on ${shortDay(d)} — it counts from the day it's done.`;
}

/** Moving a task's due date moves its routine's next one: Sync on, and not "days after" — the engine's rule. */
export function nextMovesWithDue(rule: RoutineRule): boolean {
  return rule.frequency !== "days_after" && rule.syncToDue;
}

/** The routine's anchor as the engine takes it — its rule's; an older rule without one falls back as spawnNextOccurrence says. */
export function routineAnchor(rule: RoutineRule, a: { rootDue: string | null; oldest: string | null; taskDue: string | null; today: string }): string {
  return rule.anchor ?? (rule.createNew ? a.rootDue : a.oldest ?? a.rootDue) ?? a.taskDue ?? a.today;
}

/**
 * THE NEXT DATE a status-change routine makes when its task is finished on `today` (routines round 5, M1) —
 * the ONE function the engine picks it with (spawnNextOccurrence) and the page says it with (dateMoveNote),
 * so the line can never drift from what happens. Sync on (and not days-after): after the LATER of the task's
 * occurrence date and its due date, from the anchor, never one already overdue. Sync off: after the day it is done.
 */
export function nextDateOnDone(rule: RoutineRule, a: { anchor: string; occurrence: string | null; due: string | null; today: string; own?: string[] }): string {
  const fromDue = nextMovesWithDue(rule) && !!a.due;
  const base = fromDue ? a.anchor : a.today;
  const standsFor = a.occurrence && a.due ? (a.occurrence > a.due ? a.occurrence : a.due) : (a.occurrence ?? a.due);
  let next = nextAfter(base, rule, fromDue ? (standsFor as string) : a.today);
  for (let i = 0; fromDue && next < a.today && i < 5000; i++) next = nextAfter(base, rule, next);
  // A date this task already stands for (its own occurrence — and `own`, every date the engine made FROM it) is never
  // its next one: that would be itself. HERE, not in the engine alone, so the page's line and the engine can't
  // disagree (routines round 7: a Friday task moved to Thursday said "Fri 2 Oct"; the engine made Fri 9 Oct).
  const stands = new Set([...(a.own ?? []), ...(a.occurrence ? [a.occurrence] : [])]);
  for (let i = 0; stands.has(next) && i < 5000; i++) next = nextAfter(base, rule, next);
  return next;
}

/** A real calendar day — "2027-02-30" and "2027-13-45" have the shape and are not. */
export function isCalendarDate(ymd: string): boolean {
  const p = parts(ymd);
  return !!p && fmt(utc(p.y, p.m, p.d)) === ymd;
}

/** n months after a day, the day of the month kept where the month has it (31 Jan + 1 → 28/29 Feb). */
export function addMonthsClamped(ymd: string, n: number): string {
  const p = parts(ymd);
  if (!p) return ymd;
  const first = utc(p.y, p.m + n, 1);
  const last = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate();
  return fmt(utc(first.getUTCFullYear(), first.getUTCMonth() + 1, Math.min(p.d, last)));
}

/** The Recurring panel's default "Until": a month after the later of the due date and local today — never already past. */
export function defaultUntil(due: string | null, today: string): string {
  const a = addMonthsClamped(due && due > today ? due : today, 1);
  return a;
}

/**
 * THE ONE CHECK of a routine someone set (routines round 5, L6 / L7): the server's one writer (and so the
 * create box and MCP, through validateRoutine) and the Recurring panel ask the SAME question, so the browser
 * never offers a Save the server refuses. A crafted value is refused with a sentence — never quietly
 * normalised into something else. `today` is local.
 */
export function routineRefusal(input: RoutineRule, today: string): string | null {
  const r = input as unknown as Record<string, unknown>;
  if (!FREQS.includes(r.frequency as Frequency)) return "Choose how often it repeats.";
  if (!(Number.isInteger(r.interval) && (r.interval as number) >= 1 && (r.interval as number) <= 365)) return "“Every” needs a number from 1 to 365.";
  if (r.frequency === "custom" && !UNITS.includes(r.unit as CustomUnit)) return "Choose days, weeks, months or years.";
  if (!Array.isArray(r.weekdays) || !(r.weekdays as unknown[]).every((w) => Number.isInteger(w) && (w as number) >= 0 && (w as number) <= 6)) return "The weekdays must be Sunday to Saturday.";
  const mo = r.monthly as Record<string, unknown> | null | undefined;
  if (mo !== null && mo !== undefined) {
    if (typeof mo !== "object") return "Choose which day of the month.";
    if (mo.mode === "day") {
      if (!(Number.isInteger(mo.day) && (mo.day as number) >= 1 && (mo.day as number) <= 31)) return "The day of the month must be 1 to 31.";
    } else if (mo.mode === "nth") {
      if (![1, 2, 3, 4, -1].includes(mo.nth as number) || !(Number.isInteger(mo.weekday) && (mo.weekday as number) >= 0 && (mo.weekday as number) <= 6)) return "Choose which weekday of the month.";
    } else return "Choose which day of the month.";
  }
  if (r.trigger !== "status" && r.trigger !== "schedule") return "Choose when the next one comes: on a status change, or on a schedule.";
  if (!STATUSES.includes(r.triggerStatus as TaskStatus)) return "Choose the status that brings the next one.";
  if (!STATUSES.includes(r.updateStatusTo as TaskStatus) || r.updateStatusTo === "Done") return "The next one must start in an open status.";
  if (r.trigger === "schedule" && !TIME.test(String(r.timeOfDay))) return "The time of day isn't valid.";
  if (r.missedPolicy !== "leave_open" && r.missedPolicy !== "mark_missed") return "Choose what happens to the previous open one.";
  for (const k of ["createNew", "syncToDue", "skipWeekends", "perAssignee"]) if (typeof r[k] !== "boolean") return "A repeat setting was neither on nor off.";
  const e = r.ends as { type?: unknown; count?: unknown; until?: unknown } | null | undefined;
  if (!e || typeof e !== "object" || !["never", "until", "count"].includes(e.type as string)) return "Choose when it ends: never, on a date, or after a number of times.";
  if (e.type === "count" && !(Number.isInteger(e.count) && (e.count as number) >= 1 && (e.count as number) <= 1000)) return "“After” needs a number of times from 1 to 1,000.";
  if (e.type === "until") {
    if (!(typeof e.until === "string" && isCalendarDate(e.until))) return "“Until” needs a date.";
    if (e.until < today) return "The end date has already passed";
  }
  return null;
}
