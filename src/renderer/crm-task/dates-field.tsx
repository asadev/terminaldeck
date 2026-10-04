// Copied from the reference CRM.
import { useMemo, useRef, useState } from "react";
import { CalendarDays, Repeat, X } from "lucide-react";
import { cn } from "./lib/utils";
import { AnchoredPopover } from "./anchored-popover";
import { TimelineField, relativeDay, type TimelineValue } from "./timeline-field";
import { isDueTimePassed, isOverdueYmd } from "./lib/due";
import { useLocalClockHm } from "./lib/use-local-clock";
import { nextDueDate, type TaskRecurrence } from "../../shared/crm/recurrence";
import { isActive, routineSummary, upcoming, type RoutineRule } from "../../shared/crm/recurrence-rules";
import { RoutinePanel } from "./routine-panel";
import { hmLabel, todayYmd } from "../../shared/crm/local-time";

/**
 * THE TASK PAGE'S DATES CELL — ClickUp's grey "📅 Start → 📅 Due" field, and
 * the panel behind it with ClickUp's full Recurring panel
 * (docs/clickup-task-inventory.md § 2.2 / 2.2a; routine-panel.tsx).
 *
 * The field is ONE grey box (not two pills): "Start" and "Due" read as
 * placeholders until set, then as relative days; an overdue due date is red.
 * The panel is the create box's TimelineField (Start/Due fields, presets, the
 * month) — with "Set Recurring ›" opening the Recurring panel instead of the
 * create box's short list, and the month tinting the next occurrences.
 */

/** The next `n` due dates one of the older frequencies would produce from `from`. */
export function nextOccurrences(from: string, rule: TaskRecurrence, n = 3): string[] {
  const out: string[] = [];
  let cur = from;
  for (let i = 0; i < n; i++) {
    cur = nextDueDate(cur, rule);
    out.push(cur);
  }
  return out;
}

/** local today — never the machine's (lib/tasks/local-time.ts). */
function todayIso(): string {
  return todayYmd();
}

export function DatesField({
  startDate,
  dueDate,
  recurrence,
  routine,
  routineReady,
  routineUnavailable = null,
  peopleCount = 1,
  onChange,
  onRoutineSave,
  onRoutineStop,
  onRoutinePause,
  startTime = null,
  dueTime = null,
  onTime,
  done = false,
  moveNote = null,
  routineStuck = null,
  routineStuckHidesNext = true,
  onRoutineRestart,
  routineSaving = false,
}: {
  startDate: string;
  dueDate: string;
  /** The coarse frequency the older readers keep — drives the ↻ mark. */
  recurrence: TaskRecurrence | null;
  /** The routine's rule (the routine's own task's); null = the task does not recur. */
  routine: RoutineRule | null;
  /** False until migrations/2026-09-15-task-recurrence-routines.sql — On a schedule · After N times · One copy per assignee wait on it. */
  routineReady: boolean;
  /** Why they wait — shown in the panel. */
  routineUnavailable?: string | null;
  /** People on the task — "One copy per assignee" starts ticked for more than one. */
  peopleCount?: number;
  onChange: (next: TimelineValue) => void;
  onRoutineSave: (rule: RoutineRule | null) => void;
  onRoutineStop?: () => void;
  onRoutinePause?: (paused: boolean) => void;
  /** "Add time" — local times of day on the dates, and their save (null = not offered). */
  startTime?: string | null;
  dueTime?: string | null;
  onTime?: (which: "start" | "due", t: string | null) => void;
  done?: boolean;
  /** What moving the date does to the routine (dateMoveNote) — one quiet line in the panel. */
  moveNote?: string | null;
  /** Nothing more will come although the routine runs (RoutineView.stuck) — said in the panel instead of next dates. */
  routineStuck?: string | null;
  /** false: the stuck line names only some people, and the next dates stay beside it (RoutinePanel.stuckHidesNext). */
  routineStuckHidesNext?: boolean;
  /** Restart, for the people who may change the routine (RoutineView.canRestart). */
  onRoutineRestart?: () => void;
  /** The routine's Save is in flight — the panel's Save waits (routines round 5, L8). */
  routineSaving?: boolean;
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const [preview, setPreview] = useState<RoutineRule | null>(null);
  // The due TIME decides only once mounted — never during the server render (batch-2 review #5; My Work's clock).
  const nowHm = useLocalClockHm();
  const today = todayYmd();
  const overdue = !done && !!dueDate && (isOverdueYmd(dueDate, today) || isDueTimePassed(dueDate, dueTime, today, nowHm));
  const startWord = startDate ? `${relativeDay(startDate)}${startTime ? `, ${hmLabel(startTime)}` : ""}` : "";
  const dueWord = dueDate ? `${relativeDay(dueDate)}${dueTime ? `, ${hmLabel(dueTime)}` : ""}` : "";
  const summary = startDate || dueDate ? `${startWord || "Start"} → ${dueWord || "Due"}` : "none";
  const from = dueDate || todayIso();
  const highlight = useMemo(() => {
    const r = preview ?? (routine && isActive(routine) ? routine : null);
    return r ? upcoming(from, r, 3) : [];
  }, [preview, routine, from]);

  return (
    <>
      <span className="group/dates relative inline-flex">
        <button
          ref={ref}
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-haspopup="dialog"
          aria-expanded={open}
          aria-label={`Dates: ${summary}${recurrence ? `, repeats ${recurrence}` : ""}`}
          title="Change start and due dates"
          className="inline-flex h-8 min-w-[220px] items-center gap-1.5 rounded-md bg-slate-100 px-2.5 pr-7 text-[13px] text-slate-500 hover:bg-slate-200 focus:outline-none focus:ring-2 focus:ring-blue-500"
          data-testid="dates-field"
        >
          <CalendarDays className="h-3.5 w-3.5 shrink-0" aria-hidden />
          <span className={cn(startDate && "text-slate-800")}>{startWord || "Start"}</span>
          <span aria-hidden className="text-slate-400">→</span>
          <CalendarDays className={cn("h-3.5 w-3.5 shrink-0", overdue && "text-rose-600")} aria-hidden />
          <span className={cn(dueDate && "text-slate-800", overdue && "font-medium text-rose-600")}>{dueWord || "Due"}</span>
          {recurrence && <Repeat className="h-3 w-3 shrink-0 text-slate-500" aria-label="Repeats" />}
        </button>
        {(startDate || dueDate) && (
          <button
            type="button"
            aria-label="Clear dates"
            title="Clear dates"
            onClick={() => onChange({ startDate: "", dueDate: "", recurrence })}
            className="absolute right-1.5 top-1/2 grid h-5 w-5 -translate-y-1/2 place-content-center rounded text-slate-400 opacity-0 hover:bg-slate-300 hover:text-slate-700 focus:opacity-100 group-hover/dates:opacity-100"
          >
            <X className="h-3 w-3" aria-hidden />
          </button>
        )}
      </span>
      {/* The one shared panel (timeline-field.tsx proportions): its own width, never taller than the window. */}
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Start and due dates" width="content" fitViewport>
        <TimelineField
          startDate={startDate}
          dueDate={dueDate}
          recurrence={recurrence}
          onChange={onChange}
          onPicked={() => setOpen(false)}
          highlightDays={highlight}
          routineText={routine ? routineSummary(routine) : undefined}
          moveNote={moveNote}
          startTime={startTime}
          dueTime={dueTime}
          onTime={onTime}
          recurringPanel={(back) => (
            <RoutinePanel
              rule={routine}
              ready={routineReady}
              readyReason={routineUnavailable}
              peopleCount={peopleCount}
              from={from}
              onPreview={setPreview}
              onCancel={() => {
                setPreview(null);
                back();
              }}
              onSave={(rule) => {
                onRoutineSave(rule);
                setPreview(null);
                back();
              }}
              onStop={
                onRoutineStop
                  ? () => {
                      onRoutineStop();
                      setPreview(null);
                      back();
                    }
                  : undefined
              }
              onPause={onRoutinePause}
              stuck={routineStuck}
              stuckHidesNext={routineStuckHidesNext}
              saving={routineSaving}
              onRestart={
                onRoutineRestart
                  ? () => {
                      onRoutineRestart();
                      setPreview(null);
                      back();
                    }
                  : undefined
              }
            />
          )}
        />
      </AnchoredPopover>
    </>
  );
}
