// Copied from the reference CRM.
import { isYmd, todayYmd, ymdAddDays, ymdDiff, ymdWeekday } from "../../shared/crm/local-time";
import { useRef, useState } from "react";
import { CalendarDays, Check, ChevronDown, ChevronLeft, ChevronRight, ChevronUp, Repeat, X } from "lucide-react";
import { AnchoredPopover } from "./anchored-popover";
import { cn } from "./lib/utils";
import { PILL_BASE } from "./pill-select";
import {
  RECURRENCE_LABEL,
  RECURRENCE_SHORT,
  TASK_RECURRENCES,
  type TaskRecurrence,
} from "../../shared/crm/recurrence";
import { localNowHm } from "../../shared/crm/local-time";
import { nextDayOff } from "../../shared/crm/local-time";

/**
 * THE TASK'S TIMELINE — both dates, neither required, behind ONE pill.
 *
 * Asad, 2026-09-14: *"date range should be one button with all options inside
 * and date should be optional not mandatory"*, then *"call it timeline"*. The
 * presets first sat inline in the form; his ClickUp screenshot that evening
 * ("other than personal list and description layout everything exact same")
 * has a single "Due date" pill in the bottom row, so the row of presets moved
 * UNDER the pill — and on 2026-09-15 the panel took ClickUp's own layout:
 * Start date · Due date on top, presets on the left with the day they resolve
 * to, the month grid inline on the right, "Set Recurring" at the bottom
 * (docs/task-clickup-reference.md § 1.4 row 3; Asad: "its not copying well").
 *
 * Nothing here is required. `start_date` and `due_date` are both nullable and a
 * personal to-do usually has neither, which is why the fields read "Start
 * date" and "Due date" rather than showing a pre-filled date.
 */

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "2026-09-14" → "14 Sep". Year only when it is not the current one. */
function short(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  if (!y || !m || !d) return iso;
  const label = `${d} ${MONTHS[m - 1] ?? ""}`.trim();
  return y === Number(todayYmd().slice(0, 4)) ? label : `${label} ${y}`;
}

/** Local-midnight ISO, so a preset never lands on yesterday in a +04 timezone. */
function iso(d: Date): string {
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${day}`;
}

/** Whole days between two ISO dates, counting both ends. */
function spanDays(a: string, b: string): number | null {
  const [ay, am, ad] = a.split("-").map(Number);
  const [by, bm, bd] = b.split("-").map(Number);
  if (!ay || !by) return null;
  const ms = new Date(by, bm - 1, bd).getTime() - new Date(ay, am - 1, ad).getTime();
  return Math.round(ms / 86400000) + 1;
}

/**
 * "Today" / "Tomorrow" / "Yesterday" for the near dates, "15 Sep" otherwise —
 * the way ClickUp's filled due-date pill reads ("Tomorrow", not "16/09/2026").
 */
export function relativeDay(isoDate: string, today: string = todayYmd()): string {
  if (!isYmd(isoDate)) return isoDate;
  // Against this computer's today.
  const delta = ymdDiff(today, isoDate);
  if (delta === 0) return "Today";
  if (delta === 1) return "Tomorrow";
  if (delta === -1) return "Yesterday";
  return short(isoDate);
}

export function summariseTimeline(startDate: string, dueDate: string): string | null {
  if (startDate && dueDate) return `${short(startDate)} → ${short(dueDate)}`;
  if (dueDate) return `Due ${short(dueDate)}`;
  if (startDate) return `From ${short(startDate)}`;
  return null;
}

/** The pill's own wording: a due date alone reads as the relative day. */
function pillLabel(startDate: string, dueDate: string): string | null {
  if (startDate && dueDate) return `${relativeDay(startDate)} → ${relativeDay(dueDate)}`;
  if (dueDate) return relativeDay(dueDate);
  if (startDate) return `From ${relativeDay(startDate)}`;
  return null;
}

/** Is a due date in the past (and the task not done)? Drawn red, as ClickUp does. */
export function isOverdue(dueDate: string, today: string = todayYmd(), dueTime: string | null = null, nowHm?: string): boolean {
  // Due today at a TIME (local wall time): overdue once that time has come (inc8 M10).
  if (dueTime && dueDate === today) return dueTime <= (nowHm ?? localNowHm());
  return isYmd(dueDate) && dueDate < today;
}

/**
 * Quick due dates, ClickUp's list (docs/task-clickup-reference.md § 1.4 row
 * 3) minus "Later" (a time of day — we store dates, not times) and minus
 * "Set Recurring" (no schema). Evaluated on each render rather than at
 * module load, so a tab left open overnight does not still think "Today" is
 * yesterday. Each carries the day it resolves to, shown on the right of the
 * row exactly as ClickUp shows "Tomorrow … Wed".
 */
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** The next `weekday` after a local date (0 = Sunday), "YYYY-MM-DD". */
function nextWeekday(from: string, weekday: number, allowToday = false): string {
  const delta = (weekday - ymdWeekday(from) + 7) % 7;
  return ymdAddDays(from, delta === 0 && !allowToday ? 7 : delta);
}

/**
 * "This weekend" / "Next weekend" from a local date. The weekend is the office's
 * day off — SUNDAY only; Saturday is a working day (Asad, 2026-09-15; local-time.ts
 * is the one place that says so). On a Sunday "This weekend" is today — it never
 * jumps a whole week (local-time review F8); "Next weekend" is the Sunday after.
 */
export function thisWeekend(today: string): string {
  return nextDayOff(today);
}
export function nextWeekend(today: string): string {
  return ymdAddDays(thisWeekend(today), 7);
}

/** Every preset counts from this computer's today. */
const PRESETS: { label: string; value: () => string; hint: (d: string) => string }[] = [
  { label: "Today", value: () => todayYmd(), hint: (d) => weekdayOf(d) },
  { label: "Tomorrow", value: () => ymdAddDays(todayYmd(), 1), hint: (d) => weekdayOf(d) },
  // Sunday — the office's only day off (Mon–Fri is the working week).
  { label: "This weekend", value: () => thisWeekend(todayYmd()), hint: (d) => weekdayOf(d) },
  { label: "Next week", value: () => nextWeekday(todayYmd(), 1), hint: (d) => weekdayOf(d) },
  { label: "Next weekend", value: () => nextWeekend(todayYmd()), hint: (d) => short(d) },
  { label: "2 weeks", value: () => ymdAddDays(todayYmd(), 14), hint: (d) => short(d) },
  { label: "4 weeks", value: () => ymdAddDays(todayYmd(), 28), hint: (d) => short(d) },
];

function weekdayOf(isoDate: string): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return WEEKDAYS[new Date(y, m - 1, d).getDay()] ?? "";
}

/**
 * THE TIMELINE PANEL — what opens under the due-date pill. ClickUp's, laid out
 * the same (Asad, 2026-09-15, holding their panel next to ours: "its not
 * copying well … we must need recurring as well"):
 *
 *   [ 📅 Start date ] [ 📅 Due date ]        ← the two fields; one is ACTIVE
 *   Today          Tue │ September 2026   Today ˄ ˅
 *   Tomorrow       Wed │ Su Mo Tu We Th Fr Sa
 *   This weekend   Sun │ 30 31  1  2  3  4  5
 *   Next week      Mon │  …   (15) …            ← today, red circle
 *   Next weekend 26 Sep│  …
 *   2 weeks     29 Sep │
 *   4 weeks     13 Oct │
 *   ───────────────────│
 *   Set Recurring    › │
 *
 * A day in the grid goes into the ACTIVE field — Due unless the person clicked
 * Start first — and after a Start pick the Due field becomes active, so
 * start-then-due is two clicks. If the two end up reversed they are swapped;
 * a range never reads backwards. A preset sets the Due date and closes the
 * panel (ClickUp closes on a preset). Nothing here is required: `start_date`
 * and `due_date` are both nullable and a personal to-do usually has neither.
 *
 * Left out on purpose: "Later" — it is a TIME today (3:35 am) and tasks store
 * dates, not times.
 *
 * "Set Recurring ›" swaps the left column for the repeat rules (Daily · Every
 * weekday · Weekly · Monthly · Yearly · Don't repeat). The line under the
 * fields says the routine's OWN words when its rule is known (routineSummary:
 * "Every Mon, Wed at 08:00, until 31 Dec") — with only a frequency, only
 * that; never a trigger the routine may not have.
 */
export type TimelineValue = { startDate: string; dueDate: string; recurrence: TaskRecurrence | null };

/**
 * THE PANEL'S PROPORTIONS (ClickUp's date panel; Asad's 1920×958 screenshot, 2026-09-15: "September 2026" wrapped,
 * the Saturday column was cut off, Cancel/Save were below the fold). One definition, used by the create box's pill
 * and the task page's Dates field alike:
 *   · the month: a FIXED column — 7 × 36 px cells plus 12 px padding each side — never squeezed by what sits
 *     beside it, so the month and year stay on one line with Today and the arrows, and all 7 columns fit;
 *   · the left column: the presets (216 px), or the Recurring panel (332 px) — the panel widens when it opens;
 *   · the panel is never taller than the window (AnchoredPopover fitViewport), and ONLY the Recurring settings
 *     scroll — the month, the date fields and Recurring's Cancel / Save stay in view.
 * Under 640 px (a phone) the columns stack; with Recurring open the month steps aside so its Save stays pinned.
 */
export const CALENDAR_CELL = 36;
export const CALENDAR_WIDTH = 7 * CALENDAR_CELL + 24;
export const PRESETS_WIDTH = 216;
export const RECURRING_WIDTH = 332;

export function TimelineField({
  startDate,
  dueDate,
  recurrence = null,
  onChange,
  onPicked,
  recurringPanel,
  startTime = null,
  dueTime = null,
  onTime,
  highlightDays,
  routineText,
  moveNote = null,
}: {
  startDate: string;
  dueDate: string;
  recurrence?: TaskRecurrence | null;
  onChange: (next: TimelineValue) => void;
  /** Called after a preset sets a date, so the pill above can close (ClickUp closes on pick). */
  onPicked?: () => void;
  /**
   * The task page's ClickUp Recurring panel (dates-field.tsx), drawn in the
   * left column when "Set Recurring ›" is pressed. Absent = the create box's
   * short frequency list below.
   */
  recurringPanel?: (back: () => void) => React.ReactNode;
  /** "Add time" on the dates (the task page; the create box has none). */
  startTime?: string | null;
  dueTime?: string | null;
  onTime?: (which: "start" | "due", t: string | null) => void;
  /** Days tinted light violet — the recurrence's next occurrences, as ClickUp tints them. */
  highlightDays?: readonly string[];
  /** The routine's own words (routineSummary) — said instead of the short frequency whenever the rule is known. */
  routineText?: string;
  /** What moving a date does to the routine (dateMoveNote) — one quiet line under the fields. */
  moveNote?: string | null;
}) {
  const [active, setActive] = useState<"start" | "due">("due");
  const [mode, setMode] = useState<"dates" | "recurring">("dates");
  const [cursor, setCursor] = useState(() => {
    const seed = dueDate || startDate;
    const d = parseIso(seed || todayYmd());
    return { year: d.getFullYear(), month: d.getMonth() };
  });
  const span = startDate && dueDate ? spanDays(startDate, dueDate) : null;

  const emit = (next: { startDate: string; dueDate: string }) => {
    let { startDate: s, dueDate: d } = next;
    if (s && d && s > d) [s, d] = [d, s];
    onChange({ startDate: s, dueDate: d, recurrence });
  };

  const pickDay = (isoDay: string) => {
    if (active === "start") {
      emit({ startDate: startDate === isoDay ? "" : isoDay, dueDate });
      setActive("due");
    } else {
      emit({ startDate, dueDate: dueDate === isoDay ? "" : isoDay });
    }
  };

  const today = todayYmd();
  const cells = buildMonthGrid(cursor.year, cursor.month);
  const inRange = (day: string) => !!startDate && !!dueDate && day > startDate && day < dueDate;
  const recurringOpen = mode === "recurring" && !!recurringPanel;
  // The panel's own width (+1 for the column rule) — the popover takes it as it is, never wider than the window.
  const panelWidth = (recurringOpen ? RECURRING_WIDTH : PRESETS_WIDTH) + CALENDAR_WIDTH + 1;

  return (
    <div className="flex min-h-0 max-w-full flex-1 flex-col" style={{ width: `min(${panelWidth}px, calc(100vw - 18px))` }} data-testid="timeline-panel">
      {/* The two fields. The active one carries the ring; clicking Start makes
          the next day-click a START pick. */}
      <div className="flex shrink-0 flex-wrap items-center gap-2 px-3 pt-3 pb-2">
        <DateField
          label="Start date"
          value={startDate}
          active={active === "start"}
          onClick={() => setActive("start")}
          onClear={() => emit({ startDate: "", dueDate })}
          time={startTime}
          onTime={onTime ? (t) => onTime("start", t) : undefined}
        />
        <DateField
          label="Due date"
          value={dueDate}
          active={active === "due"}
          onClick={() => setActive("due")}
          onClear={() => emit({ startDate, dueDate: "" })}
          time={dueTime}
          onTime={onTime ? (t) => onTime("due", t) : undefined}
        />
      </div>
      {(routineText || recurrence) && (
        <div className="flex shrink-0 items-center gap-1.5 px-3 pb-1 text-[11px] text-slate-500" data-testid="timeline-repeats">
          <Repeat className="h-3 w-3 shrink-0" aria-hidden />
          {/* The rule's own words when it is known; otherwise only the frequency — never a trigger it may not have. */}
          {routineText ? `Repeats: ${routineText}` : `Repeats ${RECURRENCE_SHORT[recurrence!].toLowerCase()}`}
        </div>
      )}
      {moveNote && (
        <p className="shrink-0 px-3 pb-1 text-[11px] text-slate-500" data-testid="timeline-move-note">
          {moveNote}
        </p>
      )}

      {/* Narrow screens (a phone, ~400 px): presets ABOVE, the calendar below — never a fixed column crushing the fields.
          The body takes what height is left: with Recurring open only its settings scroll; otherwise (a short phone)
          the stacked presets and month scroll together. */}
      <div
        className={cn("flex min-h-0 flex-1 flex-col border-t border-slate-100 sm:flex-row", !recurringOpen && "overflow-y-auto sm:overflow-visible")}
        data-testid="timeline-body"
      >
        {/* LEFT — presets, or the repeat rules. */}
        <div
          className={cn(
            "flex w-full min-h-0 flex-col border-b border-slate-100 sm:w-[var(--col-w)] sm:border-b-0 sm:border-r",
            recurringOpen ? "flex-1 sm:flex-none" : "shrink-0 py-1",
          )}
          style={{ ["--col-w" as string]: `${recurringOpen ? RECURRING_WIDTH : PRESETS_WIDTH}px` }}
          data-testid="timeline-left"
        >
          {mode === "recurring" && recurringPanel ? (
            recurringPanel(() => setMode("dates"))
          ) : mode === "dates" ? (
            <>
              <ul aria-label="Quick due dates">
                {PRESETS.map((preset) => {
                  const value = preset.value();
                  const on = dueDate === value;
                  return (
                    <li key={preset.label}>
                      <button
                        type="button"
                        onClick={() => {
                          emit({ startDate, dueDate: on ? "" : value });
                          if (!on) onPicked?.();
                        }}
                        aria-pressed={on}
                        className={cn(
                          "flex w-full items-center gap-3 px-3 py-1.5 text-left text-sm",
                          on ? "bg-slate-100 text-slate-900" : "text-slate-700 hover:bg-slate-50",
                        )}
                      >
                        <span className="flex-1">{preset.label}</span>
                        <span className="text-xs text-slate-500">{preset.hint(value)}</span>
                      </button>
                    </li>
                  );
                })}
              </ul>
              <div className="mx-3 my-1 border-t border-slate-100" />
              <button
                type="button"
                onClick={() => setMode("recurring")}
                aria-haspopup="listbox"
                className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-slate-700 hover:bg-slate-50"
              >
                {(routineText || recurrence) && <Repeat className="h-3.5 w-3.5 shrink-0 text-slate-500" aria-hidden />}
                <span className="flex-1 truncate" title={routineText}>
                  {routineText ?? (recurrence ? `Repeats ${RECURRENCE_SHORT[recurrence].toLowerCase()}` : "Set Recurring")}
                </span>
                <ChevronRight className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              </button>
            </>
          ) : (
            <div role="listbox" aria-label="Repeat">
              <button
                type="button"
                onClick={() => setMode("dates")}
                className="flex w-full items-center gap-1 px-2 py-1.5 text-left text-xs font-medium text-slate-500 hover:bg-slate-50"
              >
                <ChevronLeft className="h-3.5 w-3.5" aria-hidden />
                Recurring
              </button>
              {TASK_RECURRENCES.map((r) => (
                <button
                  key={r}
                  type="button"
                  role="option"
                  aria-selected={recurrence === r}
                  onClick={() => {
                    onChange({ startDate, dueDate, recurrence: r });
                    setMode("dates");
                  }}
                  className={cn(
                    "flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm",
                    recurrence === r ? "bg-slate-100 text-slate-900" : "text-slate-700 hover:bg-slate-50",
                  )}
                >
                  <span className="flex-1">{RECURRENCE_LABEL[r]}</span>
                  {recurrence === r && <Check className="h-3.5 w-3.5" aria-hidden />}
                </button>
              ))}
              {recurrence && (
                <>
                  <div className="mx-3 my-1 border-t border-slate-100" />
                  <button
                    type="button"
                    role="option"
                    aria-selected={false}
                    onClick={() => {
                      onChange({ startDate, dueDate, recurrence: null });
                      setMode("dates");
                    }}
                    className="flex w-full items-center px-3 py-1.5 text-left text-sm text-slate-500 hover:bg-slate-50 hover:text-slate-800"
                  >
                    Don't repeat
                  </button>
                </>
              )}
            </div>
          )}
        </div>

        {/* RIGHT — the month: a fixed column (CALENDAR_WIDTH), never squeezed. With Recurring open on a phone it steps
            aside, so the settings and their Save have the height. */}
        <div
          className={cn("shrink-0 self-center px-3 py-2 sm:self-start", recurringOpen && "hidden sm:block")}
          style={{ width: CALENDAR_WIDTH }}
          data-testid="timeline-month"
        >
          <div className="mb-1 flex h-7 items-center gap-1" data-testid="timeline-month-header">
            <span className="min-w-0 flex-1 whitespace-nowrap text-sm font-medium text-slate-800" data-testid="timeline-month-title">
              {MONTH_NAMES[cursor.month]} {cursor.year}
            </span>
            <div className="flex shrink-0 items-center gap-0.5">
              <button
                type="button"
                onClick={() => {
                  const t = parseIso(todayYmd());
                  setCursor({ year: t.getFullYear(), month: t.getMonth() });
                }}
                className="rounded px-1.5 py-0.5 text-xs text-slate-600 hover:bg-slate-100"
              >
                Today
              </button>
              <button
                type="button"
                aria-label="Previous month"
                onClick={() => setCursor((c) => (c.month === 0 ? { year: c.year - 1, month: 11 } : { ...c, month: c.month - 1 }))}
                className="rounded p-1 text-slate-500 hover:bg-slate-100"
              >
                <ChevronUp className="h-3.5 w-3.5" aria-hidden />
              </button>
              <button
                type="button"
                aria-label="Next month"
                onClick={() => setCursor((c) => (c.month === 11 ? { year: c.year + 1, month: 0 } : { ...c, month: c.month + 1 }))}
                className="rounded p-1 text-slate-500 hover:bg-slate-100"
              >
                <ChevronDown className="h-3.5 w-3.5" aria-hidden />
              </button>
            </div>
          </div>
          <div className="grid grid-cols-[repeat(7,36px)] text-center text-[11px] text-slate-400" data-testid="timeline-weekdays">
            {["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"].map((w) => (
              <span key={w} className="py-1">
                {w}
              </span>
            ))}
          </div>
          <div className="grid grid-cols-[repeat(7,36px)] gap-y-0.5" role="grid" aria-label={`${MONTH_NAMES[cursor.month]} ${cursor.year}`}>
            {cells.map((d) => {
              const k = iso(d);
              const other = d.getMonth() !== cursor.month;
              const isStart = k === startDate;
              const isDue = k === dueDate;
              const isToday = k === today;
              const tinted = !!highlightDays?.includes(k);
              return (
                <button
                  key={k}
                  type="button"
                  onClick={() => pickDay(k)}
                  aria-label={k}
                  aria-pressed={isStart || isDue}
                  className={cn(
                    "mx-auto flex h-8 w-8 items-center justify-center rounded-full text-xs transition-colors",
                    isStart || isDue
                      ? "bg-slate-900 font-semibold text-white"
                      : isToday
                        ? "bg-rose-500 font-semibold text-white"
                        : tinted
                          ? "rounded-md bg-violet-100 text-violet-800"
                          : inRange(k)
                          ? "bg-slate-100 text-slate-800"
                          : other
                            ? "text-slate-300 hover:bg-slate-50"
                            : "text-slate-700 hover:bg-slate-100",
                  )}
                >
                  {d.getDate()}
                </button>
              );
            })}
          </div>
        </div>
      </div>
      {span && (
        <div className="shrink-0 border-t border-slate-100 px-3 py-1.5 text-[11px] text-slate-500">
          {span} day{span === 1 ? "" : "s"} from start to due
        </div>
      )}
    </div>
  );
}

/** One of the two grey fields on top: "Start date" / "Due date", or the date, with an inline ×. */
function DateField({
  label,
  value,
  active,
  onClick,
  onClear,
  time = null,
  onTime,
}: {
  label: string;
  value: string;
  active: boolean;
  onClick: () => void;
  onClear: () => void;
  /** ClickUp's "Add time": a local time of day on this date ("HH:MM"). */
  time?: string | null;
  onTime?: (t: string | null) => void;
}) {
  const [editingTime, setEditingTime] = useState(false);
  /**
   * What is being typed (inc8 UI review M6): saved ONCE, on blur or Enter, and only a complete, valid time
   * that differs from the saved one. An emptied or half-typed field saves nothing — Backspace never deletes
   * the saved time; "Remove time" is the one way to clear it.
   */
  const [draft, setDraftState] = useState<string | null>(null);
  // The ref is what commit reads: Enter commits, and the blur that follows finds nothing left — one save, never two.
  const draftRef = useRef<string | null>(null);
  const setDraft = (v: string | null) => {
    draftRef.current = v;
    setDraftState(v);
  };
  const commit = () => {
    const v = draftRef.current;
    setDraft(null);
    setEditingTime(false);
    if (v && /^([01]\d|2[0-3]):[0-5]\d$/.test(v) && v !== (time ?? null)) onTime?.(v);
  };
  return (
    <span className="flex min-w-0 flex-1 items-center">
      <button
        type="button"
        onClick={onClick}
        aria-pressed={active}
        aria-label={value ? `${label}: ${formatDisplay(value)}` : label}
        className={cn(
          "flex h-8 min-w-0 flex-1 items-center gap-1.5 rounded-md bg-slate-100 px-2.5 text-xs text-left",
          value ? "text-slate-800" : "text-slate-500",
          value && "rounded-r-none",
          active && "ring-2 ring-slate-300",
        )}
      >
        <CalendarDays className="h-3.5 w-3.5 shrink-0 text-slate-500" aria-hidden />
        <span className="truncate">{value ? formatDisplay(value) : label}</span>
      </button>
      {value && (
        <button
          type="button"
          aria-label={`Clear ${label.toLowerCase()}`}
          onClick={() => {
            // Only the date: its time goes once the date's save is CONFIRMED — the task page clears it after a
            // successful date save (task-detail-panel saveDates). Clearing it here, first, lost the time when
            // the date's save then failed and the date came back (inc8 re-panel #14).
            onClear();
          }}
          className={cn("flex h-8 w-6 items-center justify-center rounded-r-md bg-slate-100 text-slate-400 hover:text-slate-700", active && "ring-2 ring-slate-300")}
        >
          <X className="h-3 w-3" aria-hidden />
        </button>
      )}
      {value && onTime && (editingTime || time ? (
        <span className="ml-1 flex shrink-0 items-center">
          <input
            type="time"
            aria-label={`${label} time`}
            value={draft ?? time ?? ""}
            autoFocus={editingTime}
            onFocus={() => setDraft(time ?? "")}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commit}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                commit();
                (e.target as HTMLInputElement).blur();
              }
            }}
            className="h-8 w-[92px] rounded-md bg-slate-100 px-1.5 text-xs text-slate-800"
          />
          {time && (
            <button
              type="button"
              aria-label={`Remove ${label.toLowerCase()} time`}
              title="Remove time"
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => {
                setDraft(null);
                setEditingTime(false);
                onTime(null);
              }}
              className="ml-0.5 grid h-6 w-5 place-content-center rounded text-slate-400 hover:bg-slate-200 hover:text-slate-700"
            >
              <X className="h-3 w-3" aria-hidden />
            </button>
          )}
        </span>
      ) : (
        <button type="button" onClick={() => setEditingTime(true)} className="ml-1.5 shrink-0 text-[11px] font-medium text-violet-700 hover:underline">
          Add time
        </button>
      ))}
    </span>
  );
}

const MONTH_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

function parseIso(s: string): Date {
  const [y, m, d] = s.split("-").map(Number);
  if (!y || !m || !d) return new Date();
  return new Date(y, m - 1, d);
}

/** "2026-09-14" → "14/09/2026", the app's date display. */
function formatDisplay(isoDate: string): string {
  const d = parseIso(isoDate);
  return `${String(d.getDate()).padStart(2, "0")}/${String(d.getMonth() + 1).padStart(2, "0")}/${d.getFullYear()}`;
}

/** Six weeks starting on the Sunday on or before the 1st — ClickUp's grid, 42 cells. */
function buildMonthGrid(year: number, month: number): Date[] {
  const first = new Date(year, month, 1);
  const start = new Date(year, month, 1 - first.getDay());
  const cells: Date[] = [];
  for (let i = 0; i < 42; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    cells.push(d);
  }
  return cells;
}

/**
 * THE DUE-DATE PILL — ClickUp's, in the bottom row (§ 1.4 row 3).
 *
 * Empty: calendar icon + "Due date", title "Change start and due dates".
 * Filled: the relative day ("Tomorrow") — or "12 Sep → 15 Sep" when there is
 * a start — a repeat glyph when the task recurs, and an inline × that clears
 * the dates without opening anything (the repeat rule survives a cleared
 * date: a weekly task with no date yet is still weekly). An overdue date is
 * drawn red. The × is a sibling of the pill button, not a child (a button
 * inside a button is invalid HTML), wrapped so the two read as one pill.
 */
export function TimelinePill({
  startDate,
  dueDate,
  recurrence = null,
  onChange,
  done = false,
  recurringPanel,
  routineText,
}: {
  startDate: string;
  dueDate: string;
  recurrence?: TaskRecurrence | null;
  onChange: (next: TimelineValue) => void;
  /** "Set Recurring ›" opens this (the create box: ClickUp's full Recurring panel). */
  recurringPanel?: (back: () => void) => React.ReactNode;
  /** A done task is never "overdue". */
  done?: boolean;
  /** The routine's own words (routineSummary), said under the dates when the rule is known. */
  routineText?: string;
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const label = pillLabel(startDate, dueDate);
  const overdue = !done && !!dueDate && isOverdue(dueDate);
  const aria = [label ? `Dates: ${label}` : "Due date", recurrence ? `repeats ${RECURRENCE_SHORT[recurrence].toLowerCase()}` : ""]
    .filter(Boolean)
    .join(", ");
  return (
    <>
      {/* The pill and its × sit side by side in one inline group. Both are
          <button>s with the row's shared border classes, so the app-wide rule
          "controls carry no grey border" (the design-system stylesheet, R1) treats them exactly
          like the status and priority pills beside them. */}
      <span className="inline-flex items-center">
        <button
          ref={ref}
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-haspopup="dialog"
          aria-expanded={open}
          aria-label={aria}
          title="Change start and due dates"
          className={cn(
            PILL_BASE,
            label && "rounded-r-none pr-2",
            overdue && "text-rose-700",
            label && !overdue && "text-slate-800",
          )}
        >
          <CalendarDays className="h-3.5 w-3.5 shrink-0" aria-hidden />
          {label ?? "Due date"}
          {recurrence && <Repeat className="h-3 w-3 shrink-0 text-slate-500" aria-hidden />}
        </button>
        {label && (
          <button
            type="button"
            aria-label="Clear dates"
            title="Clear dates"
            onClick={() => onChange({ startDate: "", dueDate: "", recurrence })}
            className={cn(PILL_BASE, "w-6 justify-center rounded-l-none border-l-0 px-0 text-slate-400 hover:text-slate-700")}
          >
            <X className="h-3 w-3" aria-hidden />
          </button>
        )}
      </span>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Start and due dates" width="content" fitViewport>
        <TimelineField
          startDate={startDate}
          dueDate={dueDate}
          recurrence={recurrence}
          onChange={onChange}
          onPicked={() => setOpen(false)}
          recurringPanel={recurringPanel}
          routineText={routineText}
          />
      </AnchoredPopover>
    </>
  );
}
