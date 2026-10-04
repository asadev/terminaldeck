// Copied from the reference CRM.
import { useEffect, useState } from "react";
import { MoreHorizontal } from "lucide-react";
import { cn } from "./lib/utils";
import {
  DEFAULT_ROUTINE,
  SKIP_DAYS_OFF_LABEL,
  defaultUntil,
  routineRefusal,
  routineSummary,
  shortDay,
  upcoming,
  weekdayOf,
  type CustomUnit,
  type Frequency,
  type Nth,
  type RoutineRule,
} from "../../shared/crm/recurrence-rules";
import { STATUS_WORD } from "../../shared/crm/task-page";
import { localTodayClient } from "./page/routine-block";
import type { TaskStatus } from "../../shared/crm/tasks-data";

/**
 * CLICKUP'S RECURRING PANEL, WHOLE (docs/clickup-task-inventory.md § 2.2 /
 * 2.2a; its frequency list from ClickUp's documentation) — and ours on top,
 * for a team's routine (Asad, 2026-09-15: a task each assignee marks done
 * every day, for a period or "till we stop").
 *
 *   Recurring                                        ⋯  Pause · Stop recurring
 *   [Daily ▾]   presets: Every working day · Mon/Wed/Fri · Every 2 weeks · Last Friday · 1st of month
 *   Every [1] day(s) … / on S M T W T F S / on day [15] | on the [last] [Friday] / [3] days after it is done
 *   [On status change ▾] when the status becomes [Done ▾]   |   [On a schedule ▾] at [08:00] local time
 *   ☑ Recur forever  →  ( ) Until [31 Dec]  ( ) After [10] times
 *   ☐ Create new task   ☐ Update status to [To Do ▾]   ☐ Sync recurrence to due date   ☐ Skip weekends
 *   FOR A TEAM  ☐ One copy per assignee   The previous open one is [left open (overdue) ▾]
 *   Every working day at 08:00, until 31 Dec, one copy per assignee — next Wed 16 Sep · Thu 17 Sep · Fri 18 Sep
 *                                                                              Cancel  Save
 *
 * Differences from ClickUp, on purpose:
 *   · the office's only day off is Sunday (Mon–Fri is worked — local-time.ts), and the box says "Skip weekends";
 *   · "Update status to" off means the next one starts in To Do (ClickUp's
 *     first status) — the next occurrence always starts somewhere;
 *   · before migrations/2026-09-15-task-recurrence-routines.sql, On a schedule,
 *     After N times and One copy per assignee are shown switched off with the
 *     file named — never offered and then refused.
 */

/** A new routine opens on ClickUp's panel defaults. */
export const NEW_ROUTINE: RoutineRule = { ...DEFAULT_ROUTINE, frequency: "weekly", createNew: false, syncToDue: false };

const FREQUENCIES: { id: Frequency; label: string }[] = [
  { id: "daily", label: "Daily" },
  { id: "weekly", label: "Weekly" },
  { id: "monthly", label: "Monthly" },
  { id: "yearly", label: "Yearly" },
  { id: "days_after", label: "Days after" },
  { id: "custom", label: "Custom" },
];

/** Our old five, and the common shapes ClickUp's docs show, one click each. */
const PRESETS: { label: string; patch: Partial<RoutineRule> }[] = [
  { label: "Every working day", patch: { frequency: "daily", interval: 1, skipWeekends: true, weekdays: [], monthly: null } },
  { label: "Mon / Wed / Fri", patch: { frequency: "weekly", interval: 1, weekdays: [1, 3, 5], skipWeekends: false, monthly: null } },
  { label: "Every 2 weeks", patch: { frequency: "weekly", interval: 2, weekdays: [], monthly: null } },
  { label: "Last Friday", patch: { frequency: "monthly", interval: 1, weekdays: [], monthly: { mode: "nth", nth: -1, weekday: 5 } } },
  { label: "1st of the month", patch: { frequency: "monthly", interval: 1, weekdays: [], monthly: { mode: "day", day: 1 } } },
];

const UNITS: { id: CustomUnit; one: string; many: string }[] = [
  { id: "day", one: "day", many: "days" },
  { id: "week", one: "week", many: "weeks" },
  { id: "month", one: "month", many: "months" },
  { id: "year", one: "year", many: "years" },
];
const DAY_LETTER = ["S", "M", "T", "W", "T", "F", "S"];
const DAY_NAME = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const NTHS: { id: Nth; label: string }[] = [
  { id: 1, label: "first" },
  { id: 2, label: "second" },
  { id: 3, label: "third" },
  { id: 4, label: "fourth" },
  { id: -1, label: "last" },
];
const ALL_STATUSES: TaskStatus[] = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"];
const OPEN_STATUSES: TaskStatus[] = ["To-Do", "Working on it", "In Progress", "Stuck"];

const selectCls =
  "h-8 rounded-md border border-slate-200 bg-white px-2 text-[13px] text-slate-800 focus:border-violet-500 focus:outline-none disabled:cursor-not-allowed disabled:opacity-50";
const numCls = "h-8 w-14 rounded-md border border-slate-200 px-2 text-[13px] text-slate-800 focus:border-violet-500 focus:outline-none";

function unitOf(r: RoutineRule): CustomUnit {
  if (r.frequency === "custom") return r.unit;
  return r.frequency === "weekly" ? "week" : r.frequency === "monthly" ? "month" : r.frequency === "yearly" ? "year" : "day";
}

export function RoutinePanel({
  rule,
  ready,
  readyReason = null,
  peopleCount,
  from,
  onSave,
  onCancel,
  onPreview,
  onStop,
  onPause,
  stuck = null,
  stuckHidesNext = true,
  onRestart,
  saving = false,
}: {
  rule: RoutineRule | null;
  /** The history table exists — On a schedule, After N times and One copy per assignee can be saved. */
  ready: boolean;
  readyReason?: string | null;
  peopleCount: number;
  /** The day the preview counts from (the due date, or today). */
  from: string;
  onSave: (rule: RoutineRule | null) => void;
  onCancel: () => void;
  onPreview?: (rule: RoutineRule | null) => void;
  onStop?: () => void;
  onPause?: (paused: boolean) => void;
  /** Why nothing more will come although it runs (routines round 5, F3) — said instead of next dates. */
  stuck?: string | null;
  /**
   * The stuck line stands INSTEAD of next dates (nothing will come for anyone). false: it names only some people — the
   * others' next dates are still shown beside it, like the Routines list (batch-2 review #4). The server decides
   * (RoutineView: no `next` while stuck = hidden).
   */
  stuckHidesNext?: boolean;
  /** Restart the routine — only given to the people who may change it. */
  onRestart?: () => void;
  /** A Save is in flight: Save waits (routines round 5, L8). */
  saving?: boolean;
}) {
  const [r, setR] = useState<RoutineRule>(() => (rule ? { ...rule } : { ...NEW_ROUTINE }));
  // Until's default: a month after the later of the due date and local today — never already past (round 5, L7).
  const untilDefault = defaultUntil(from, localTodayClient());
  const [perTouched, setPerTouched] = useState(!!rule);
  const [updOn, setUpdOn] = useState(() => !!rule && rule.updateStatusTo !== "To-Do");
  const [menu, setMenu] = useState(false);
  const set = (patch: Partial<RoutineRule>) => {
    const next = { ...r, ...patch };
    setR(next);
    onPreview?.(next);
  };
  const unit = unitOf(r);
  const n = r.interval;

  // Escape closes the ⋯ menu only — the popover around the panel listens on
  // document (capture), so this listens earlier, on window (capture).
  useEffect(() => {
    if (!menu) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      setMenu(false);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [menu]);

  const intervalInput = (
    <input
      type="number"
      min={1}
      max={365}
      value={n}
      aria-label="Interval"
      onChange={(e) => set({ interval: Math.max(1, Math.min(365, Math.floor(Number(e.target.value) || 1))) })}
      className={numCls}
    />
  );
  const weekdayChips = (
    <div className="mt-1.5 flex gap-1" role="group" aria-label="On these days">
      {DAY_LETTER.map((l, d) => {
        const on = r.weekdays.includes(d);
        return (
          <button
            key={d}
            type="button"
            aria-pressed={on}
            aria-label={DAY_NAME[d]}
            title={DAY_NAME[d]}
            onClick={() => set({ weekdays: on ? r.weekdays.filter((x) => x !== d) : [...r.weekdays, d].sort() })}
            className={cn(
              "grid h-7 w-7 place-content-center rounded-full text-[11px] font-medium ring-1",
              on ? "bg-violet-600 text-white ring-violet-600" : "bg-white text-slate-600 ring-slate-200 hover:bg-slate-50",
            )}
          >
            {l}
          </button>
        );
      })}
    </div>
  );
  const anchorDay = Number(from.slice(8, 10)) || 1;
  const monthlyChoice = (
    <div className="mt-1.5 space-y-1.5 text-[13px] text-slate-700" role="radiogroup" aria-label="Which day of the month">
      <label className="flex items-center gap-2">
        <input
          type="radio"
          name="monthly-mode"
          checked={r.monthly?.mode !== "nth"}
          onChange={() => set({ monthly: { mode: "day", day: r.monthly?.mode === "day" ? r.monthly.day : anchorDay } })}
          className="accent-violet-600"
        />
        On day
        <input
          type="number"
          min={1}
          max={31}
          aria-label="Day of the month"
          value={r.monthly?.mode === "day" ? r.monthly.day : anchorDay}
          onChange={(e) => set({ monthly: { mode: "day", day: Math.max(1, Math.min(31, Math.floor(Number(e.target.value) || 1))) } })}
          className={numCls}
        />
      </label>
      <label className="flex flex-wrap items-center gap-2">
        <input
          type="radio"
          name="monthly-mode"
          checked={r.monthly?.mode === "nth"}
          onChange={() => set({ monthly: { mode: "nth", nth: (Math.min(4, Math.ceil(anchorDay / 7)) as Nth) || 1, weekday: weekdayOf(from) } })}
          className="accent-violet-600"
        />
        On the
        <select
          aria-label="Which week"
          value={r.monthly?.mode === "nth" ? r.monthly.nth : 1}
          onChange={(e) => set({ monthly: { mode: "nth", nth: Number(e.target.value) as Nth, weekday: r.monthly?.mode === "nth" ? r.monthly.weekday : weekdayOf(from) } })}
          className={selectCls}
        >
          {NTHS.map((x) => (
            <option key={x.id} value={x.id}>
              {x.label}
            </option>
          ))}
        </select>
        <select
          aria-label="Which weekday"
          value={r.monthly?.mode === "nth" ? r.monthly.weekday : weekdayOf(from)}
          onChange={(e) => set({ monthly: { mode: "nth", nth: r.monthly?.mode === "nth" ? r.monthly.nth : 1, weekday: Number(e.target.value) } })}
          className={selectCls}
        >
          {DAY_NAME.map((d, i) => (
            <option key={d} value={i}>
              {d}
            </option>
          ))}
        </select>
      </label>
    </div>
  );

  const next = upcoming(from, r, 3);
  // The server's own check, before Save is offered (round 5, L7): a Save the server would refuse is never offered.
  const refusal = routineRefusal(r, localTodayClient());

  return (
    // The settings scroll; the footer (Cancel / Save, and why Save waits) is pinned beneath them — never scrolled or cut
    // off (2026-09-15, Asad's screenshot). Its height comes from the dates panel, which is never taller than the window.
    <div className="flex min-h-0 flex-1 flex-col" data-testid="recurring-panel">
      <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 py-2" data-testid="recurring-scroll">
      <div className="relative mb-2 flex items-center gap-1">
        <span className="flex-1 text-sm font-medium text-slate-800">Recurring</span>
        {rule && (onStop || onPause) && (
          <button
            type="button"
            aria-label="Recurring options"
            aria-expanded={menu}
            onClick={() => setMenu((m) => !m)}
            className="grid h-6 w-6 place-content-center rounded text-slate-500 hover:bg-slate-100"
          >
            <MoreHorizontal className="h-4 w-4" aria-hidden />
          </button>
        )}
        {menu && (
          <div className="absolute right-0 top-7 z-10 w-44 rounded-md border border-slate-200 bg-white py-1 shadow-lg" role="menu">
            {onPause && !rule?.stoppedAt && (
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setMenu(false);
                  onPause(!rule?.pausedAt);
                }}
                className="w-full px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50"
              >
                {rule?.pausedAt ? "Resume" : "Pause"}
              </button>
            )}
            {onStop && (
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setMenu(false);
                  onStop();
                }}
                className="w-full px-3 py-1.5 text-left text-sm text-rose-700 hover:bg-rose-50"
              >
                Stop recurring
              </button>
            )}
          </div>
        )}
      </div>

      {/* FREQUENCY */}
      <label className="sr-only" htmlFor="recurring-frequency">
        Frequency
      </label>
      <select
        id="recurring-frequency"
        value={r.frequency}
        onChange={(e) => {
          const f = e.target.value as Frequency;
          set({
            frequency: f,
            interval: 1,
            unit: f === "custom" ? r.unit : "day",
            weekdays: f === "weekly" || f === "custom" ? r.weekdays : [],
            monthly: f === "monthly" || f === "custom" ? r.monthly : null,
          });
        }}
        className={cn(selectCls, "w-full")}
      >
        {FREQUENCIES.map((f) => (
          <option key={f.id} value={f.id}>
            {f.label}
          </option>
        ))}
      </select>
      <div className="mt-1.5 flex flex-wrap gap-1" role="group" aria-label="Presets">
        {PRESETS.map((p) => (
          <button
            key={p.label}
            type="button"
            onClick={() => set(p.patch)}
            className="rounded-full bg-slate-100 px-2 py-0.5 text-[11px] text-slate-600 hover:bg-violet-50 hover:text-violet-700"
          >
            {p.label}
          </button>
        ))}
      </div>

      <div className="mt-2 text-[13px] text-slate-700" data-testid="recurring-interval">
        {r.frequency === "days_after" ? (
          <span className="flex items-center gap-2">
            {intervalInput} {n === 1 ? "day" : "days"} after it is done
          </span>
        ) : (
          <span className="flex flex-wrap items-center gap-2">
            Every {intervalInput}
            {r.frequency === "custom" ? (
              <select aria-label="Unit" value={r.unit} onChange={(e) => set({ unit: e.target.value as CustomUnit })} className={selectCls}>
                {UNITS.map((u) => (
                  <option key={u.id} value={u.id}>
                    {n === 1 ? u.one : u.many}
                  </option>
                ))}
              </select>
            ) : (
              <span>{n === 1 ? UNITS.find((u) => u.id === unit)!.one : UNITS.find((u) => u.id === unit)!.many}</span>
            )}
          </span>
        )}
        {unit === "week" && r.frequency !== "days_after" && weekdayChips}
        {unit === "month" && r.frequency !== "days_after" && monthlyChoice}
      </div>

      {/* TRIGGER */}
      <div className="mt-2.5 space-y-1.5">
        <label className="sr-only" htmlFor="recurring-trigger">
          Trigger
        </label>
        <select
          id="recurring-trigger"
          value={r.trigger}
          onChange={(e) => set({ trigger: e.target.value as RoutineRule["trigger"] })}
          className={cn(selectCls, "w-full")}
        >
          <option value="status">On status change</option>
          <option value="schedule" disabled={!ready}>
            On a schedule{ready ? "" : " (not available yet)"}
          </option>
        </select>
        {r.trigger === "status" ? (
          <label className="flex items-center gap-2 text-[13px] text-slate-700">
            When the status becomes
            <select aria-label="Trigger status" value={r.triggerStatus} onChange={(e) => set({ triggerStatus: e.target.value as TaskStatus })} className={selectCls}>
              {ALL_STATUSES.map((s) => (
                <option key={s} value={s}>
                  {STATUS_WORD[s]}
                </option>
              ))}
            </select>
          </label>
        ) : (
          <label className="flex flex-wrap items-center gap-2 text-[13px] text-slate-700">
            Created at
            <input
              type="time"
              aria-label="Time of day"
              value={r.timeOfDay}
              onChange={(e) => set({ timeOfDay: /^\d{2}:\d{2}$/.test(e.target.value) ? e.target.value : "08:00" })}
              className="h-8 rounded-md border border-slate-200 px-2 text-[13px]"
            />
            local time — whether or not the last one was finished
          </label>
        )}
      </div>

      {/* ENDS + CLICKUP'S CHECKBOXES */}
      <div className="mt-2.5 space-y-2">
        <Check
          label="Recur forever"
          checked={r.ends.type === "never"}
          onChange={(v) => set({ ends: v ? { type: "never" } : { type: "until", until: untilDefault } })}
        />
        {r.ends.type !== "never" && (
          <div className="ml-6 space-y-1.5 text-[13px] text-slate-700" role="radiogroup" aria-label="Ends">
            <label className="flex items-center gap-2">
              <input
                type="radio"
                name="routine-ends"
                checked={r.ends.type === "until"}
                onChange={() => set({ ends: { type: "until", until: untilDefault } })}
                className="accent-violet-600"
              />
              Until
              <input
                type="date"
                aria-label="Recur until"
                value={r.ends.type === "until" ? r.ends.until : ""}
                onChange={(e) => e.target.value && set({ ends: { type: "until", until: e.target.value } })}
                disabled={r.ends.type !== "until"}
                className="h-7 rounded border border-slate-200 px-1.5 text-xs disabled:opacity-50"
              />
            </label>
            <label className={cn("flex items-center gap-2", !ready && "opacity-50")}>
              <input
                type="radio"
                name="routine-ends"
                checked={r.ends.type === "count"}
                disabled={!ready}
                onChange={() => set({ ends: { type: "count", count: 10 } })}
                className="accent-violet-600"
              />
              After
              <input
                type="number"
                min={1}
                max={1000}
                aria-label="Number of times"
                value={r.ends.type === "count" ? r.ends.count : 10}
                disabled={!ready || r.ends.type !== "count"}
                onChange={(e) => set({ ends: { type: "count", count: Math.max(1, Math.min(1000, Math.floor(Number(e.target.value) || 1))) } })}
                className={cn(numCls, "disabled:opacity-50")}
              />
              times
            </label>
          </div>
        )}
        <Check
          label="Create new task"
          checked={r.createNew}
          onChange={(v) => set({ createNew: v, perAssignee: v && ready ? (perTouched ? r.perAssignee : peopleCount > 1) : false })}
        />
        <div className="flex flex-wrap items-center gap-2">
          <Check
            label="Update status to"
            checked={updOn}
            onChange={(v) => {
              setUpdOn(v);
              if (!v) set({ updateStatusTo: "To-Do" });
            }}
          />
          <select
            aria-label="Update status to"
            value={r.updateStatusTo}
            disabled={!updOn}
            onChange={(e) => set({ updateStatusTo: e.target.value as TaskStatus })}
            className={selectCls}
          >
            {OPEN_STATUSES.map((s) => (
              <option key={s} value={s}>
                {STATUS_WORD[s]}
              </option>
            ))}
          </select>
        </div>
        <Check
          label="Sync recurrence to due date"
          checked={r.syncToDue}
          disabled={r.trigger === "schedule" || r.frequency === "days_after"}
          onChange={(v) => set({ syncToDue: v })}
        />
        <Check label={SKIP_DAYS_OFF_LABEL} checked={r.skipWeekends} onChange={(v) => set({ skipWeekends: v })} />
      </div>

      {/* OURS — a team's routine */}
      <div className="mt-3 space-y-2 border-t border-slate-100 pt-2">
        <div className="text-[11px] font-medium uppercase tracking-wide text-slate-400">For a team</div>
        <Check
          label="One copy per assignee"
          hint="Each person gets their own to mark done"
          checked={r.perAssignee}
          disabled={!ready || !r.createNew}
          onChange={(v) => {
            setPerTouched(true);
            set({ perAssignee: v });
          }}
        />
        {r.trigger === "schedule" && (
          <label className="block text-[13px] text-slate-700">
            When the next one arrives, the previous open one is
            <select
              aria-label="Previous open one"
              value={r.missedPolicy}
              onChange={(e) => set({ missedPolicy: e.target.value as RoutineRule["missedPolicy"] })}
              className={cn(selectCls, "mt-1 block w-full")}
            >
              <option value="leave_open">left open (overdue)</option>
              <option value="mark_missed">marked Missed</option>
            </select>
          </label>
        )}
      </div>

      <div className="mt-3 rounded-md bg-slate-50 px-2.5 py-2 text-xs text-slate-700" data-testid="recurring-summary">
        <div className="font-medium text-slate-800">{routineSummary({ ...r, stoppedAt: null, pausedAt: null })}</div>
        {/* BOTH, like the Routines list: a missing person's line never hides the next dates the others still have
            (batch-2 review #4); when nobody will get one, the line stands alone. */}
        {stuck && (
          <div className="mt-0.5 text-amber-700" data-testid="recurring-stuck">
            {stuck}
            {onRestart && (
              <button type="button" onClick={onRestart} className="ml-1.5 font-medium text-violet-700 underline-offset-2 hover:underline" data-testid="recurring-restart">
                Restart
              </button>
            )}
          </div>
        )}
        {next.length > 0 && !(stuck && stuckHidesNext) && (
          <div className="mt-0.5 text-slate-500" data-testid="recurring-next">
            Next: {next.map(shortDay).join(" · ")}
          </div>
        )}
      </div>
      {rule?.stoppedAt && <p className="mt-2 text-[11px] text-slate-500">This routine was stopped. Save starts it again; its history is kept.</p>}
      {rule?.pausedAt && !rule.stoppedAt && <p className="mt-2 text-[11px] text-amber-700">Paused. Save resumes it as shown.</p>}
      {!ready && readyReason && (
        <p className="mt-2 text-[11px] leading-snug text-amber-700" data-testid="recurring-locked" title={readyReason}>
          On a schedule, After N times and One copy per assignee aren't available yet.
        </p>
      )}
      </div>
      <div className="shrink-0 border-t border-slate-100 px-3 py-2" data-testid="recurring-footer">
      {refusal && (
        <p role="alert" className="mb-2 text-[11px] leading-snug text-rose-700" data-testid="recurring-refusal">
          {refusal}
        </p>
      )}
      <div className="flex justify-end gap-2">
        <button type="button" onClick={onCancel} className="h-8 rounded-md px-3 text-sm text-slate-600 hover:bg-slate-100">
          Cancel
        </button>
        <button
          type="button"
          disabled={saving || !!refusal}
          onClick={() => onSave(r)}
          className="h-8 rounded-md bg-violet-600 px-3 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {saving ? "Saving…" : "Save"}
        </button>
      </div>
      </div>
    </div>
  );
}

function Check({ label, hint, checked, disabled, onChange }: { label: string; hint?: string; checked: boolean; disabled?: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className={cn("flex cursor-pointer items-start gap-2 text-[13px] text-slate-700", disabled && "cursor-not-allowed opacity-50")}>
      <input
        type="checkbox"
        aria-label={label}
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 rounded border-slate-300 accent-violet-600"
      />
      <span>
        {label}
        {hint && <span className="block text-[11px] text-slate-500">{hint}</span>}
      </span>
    </label>
  );
}
