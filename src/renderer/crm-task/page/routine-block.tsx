// Copied from the reference CRM.
import { useState } from "react";
import { Pause, Play, Repeat, Square } from "lucide-react";
import { cn } from "../lib/utils";
import { PersonAvatar } from "../people/person-picker";
import {
  HISTORY_LABEL,
  addDays,
  localDateOf,
  historyState,
  routineSummary,
  shortDay,
  type HistoryState,
} from "../../../shared/crm/recurrence-rules";
import type { RoutineView } from "../../../shared/crm/routine-actions";
import type { TaskAssignee } from "../../../shared/crm/tasks-data";
import { localClock, localStamp } from "../../../shared/crm/local-time";

/**
 * THE ROUTINE ON THE TASK PAGE — ours, on top of ClickUp (it has no history
 * of a recurring task). Asad wants a daily routine each person marks done, so
 * the manager's question is "was it done, and on time?":
 *
 *   ↻ Routine · Every weekday at 08:00, until 31 Dec, one copy per assignee
 *     Running · next Wed 16 Sep            [Pause] [Stop recurring]
 *   Last 30 days: 18 on time · 2 late · 1 missed
 *   Date        Who          Status
 *   Tue 15 Sep  Aisha K      Done on time · 08:42
 *   Mon 14 Sep  Omar         Missed
 *
 * "Stop recurring" ends the routine; every task it made and this history stay.
 * On an occurrence's page it says which routine it belongs to.
 */

export const HISTORY_TONE: Record<HistoryState, string> = {
  on_time: "bg-emerald-50 text-emerald-700 ring-emerald-200",
  late: "bg-amber-50 text-amber-700 ring-amber-200",
  missed: "bg-rose-50 text-rose-700 ring-rose-200",
  overdue: "bg-white text-rose-600 ring-rose-300",
  open: "bg-slate-50 text-slate-600 ring-slate-200",
  skipped: "bg-white text-slate-400 ring-slate-200",
};
export const HISTORY_DOT: Record<HistoryState, string> = {
  on_time: "bg-emerald-500",
  late: "bg-amber-400",
  missed: "bg-rose-500",
  overdue: "bg-rose-300",
  open: "bg-slate-300",
  skipped: "bg-slate-200",
};

const SHOWN = 14;

export function localTodayClient(): string {
  return localDateOf(new Date().toISOString()) ?? new Date().toISOString().slice(0, 10);
}

/** "8:42 am" — local, the page's one clock (lib/tasks/local-time.ts). */
function clock(iso: string | null): string {
  return iso ? localClock(iso) : "";
}

export function RoutineBlock({
  routine,
  team,
  onPause,
  onStop,
  onOpenRoot,
}: {
  routine: RoutineView;
  team: TaskAssignee[];
  onPause?: (paused: boolean) => void;
  onStop?: () => void;
  onOpenRoot?: () => void;
}) {
  const [all, setAll] = useState(false);
  const [arming, setArming] = useState(false);
  const rule = routine.rule;
  if (!rule) return null;
  const today = localTodayClient();
  const person = (id: string | null) => (id ? team.find((p) => p.id === id) ?? null : null);
  const state = rule.stoppedAt ? "Stopped" : rule.pausedAt ? "Paused" : "Running";
  const rows = (routine.history ?? []).map((h) => ({ ...h, state: historyState(h, today) }));
  const monthAgo = addDays(today, -30);
  const recent = rows.filter((r) => r.occurrenceDate >= monthAgo && r.occurrenceDate <= today);
  const tally = (s: HistoryState) => recent.filter((r) => r.state === s).length;
  const visible = all ? rows : rows.slice(0, SHOWN);
  const editable = routine.canEdit && !rule.stoppedAt;

  return (
    <section className="rounded-lg border border-slate-200" aria-label="Routine" data-testid="routine-block">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1 border-b border-slate-100 px-3 py-2">
        <Repeat className="h-4 w-4 shrink-0 text-violet-600" aria-hidden />
        <span className="text-sm font-medium text-slate-800">Routine</span>
        <span className="min-w-0 text-sm text-slate-700" data-testid="routine-summary">
          {routineSummary({ ...rule, stoppedAt: null, pausedAt: null })}
        </span>
        <span
          className={cn(
            "rounded-full px-2 py-0.5 text-[11px] font-medium ring-1",
            state === "Running" ? "bg-emerald-50 text-emerald-700 ring-emerald-200" : state === "Paused" ? "bg-amber-50 text-amber-700 ring-amber-200" : "bg-slate-100 text-slate-600 ring-slate-200",
          )}
        >
          {state}
        </span>
        {state === "Running" && routine.next[0] && <span className="text-xs text-slate-500">next {shortDay(routine.next[0])}</span>}
        <span className="ml-auto flex items-center gap-1">
          {editable && onPause && (
            <button type="button" onClick={() => onPause(!rule.pausedAt)} className="btn btn-ghost btn-sm">
              {rule.pausedAt ? <Play className="h-3.5 w-3.5" aria-hidden /> : <Pause className="h-3.5 w-3.5" aria-hidden />}
              {rule.pausedAt ? "Resume" : "Pause"}
            </button>
          )}
          {editable && onStop &&
            (!arming ? (
              <button type="button" onClick={() => setArming(true)} className="btn btn-ghost btn-sm text-rose-700">
                <Square className="h-3.5 w-3.5" aria-hidden />
                Stop recurring
              </button>
            ) : (
              <span className="flex items-center gap-1" role="group" aria-label="Confirm stop recurring">
                <button
                  type="button"
                  onClick={() => {
                    setArming(false);
                    onStop();
                  }}
                  className="btn btn-danger btn-sm"
                >
                  Stop recurring?
                </button>
                <button type="button" onClick={() => setArming(false)} className="btn btn-ghost btn-sm">
                  Cancel
                </button>
              </span>
            ))}
        </span>
      </div>
      {!routine.isRoot && (
        <p className="border-b border-slate-100 px-3 py-1.5 text-xs text-slate-500">
          One occurrence of the routine on{" "}
          {onOpenRoot ? (
            <button type="button" onClick={onOpenRoot} className="font-medium text-violet-700 hover:underline">
              {routine.rootTitle}
            </button>
          ) : (
            <span className="font-medium text-slate-700">{routine.rootTitle}</span>
          )}
          {" — "}changes to the routine are made there.
        </p>
      )}
      {/* Only the people who may change the routine are given it (routine-actions fetchRoutine). */}
      {routine.lastError && (
        <p className="border-b border-slate-100 bg-amber-50 px-3 py-1.5 text-xs text-amber-800" role="status" data-testid="routine-last-error">
          {routine.lastError.message} <span className="text-amber-600">· {localStamp(routine.lastError.at)}</span>
        </p>
      )}
      {routine.historyError ? (
        <p className="px-3 py-2 text-xs text-amber-700" data-testid="routine-history-unavailable">
          History unavailable: {routine.historyError}
        </p>
      ) : rows.length === 0 ? (
        <p className="px-3 py-2 text-xs text-slate-500">No occurrences yet{routine.next[0] ? ` — the first is ${shortDay(routine.next[0])}` : ""}.</p>
      ) : (
        <>
          <p className="px-3 pt-2 text-xs text-slate-500" data-testid="routine-tally">
            Last 30 days: {tally("on_time")} on time · {tally("late")} late · {tally("missed")} missed
            {tally("overdue") ? ` · ${tally("overdue")} overdue` : ""}
          </p>
          <div className="overflow-x-auto px-1 pb-1">
            <table className="w-full text-left text-[13px]" aria-label="Routine history">
              <thead>
                <tr className="text-[11px] text-slate-500">
                  <th className="px-2 py-1 font-medium">Date</th>
                  <th className="px-2 py-1 font-medium">Who</th>
                  <th className="px-2 py-1 font-medium">Status</th>
                </tr>
              </thead>
              <tbody>
                {visible.map((r) => {
                  const who = person(r.who);
                  const by = r.completedBy && r.completedBy !== r.who ? person(r.completedBy) : null;
                  return (
                    <tr key={r.id} className="border-t border-slate-100" data-testid="routine-row">
                      <td className="whitespace-nowrap px-2 py-1.5 text-slate-700">{shortDay(r.occurrenceDate)}</td>
                      <td className="px-2 py-1.5">
                        {who ? (
                          <span className="inline-flex items-center gap-1.5">
                            <PersonAvatar name={who.name} initials={who.initials} color={who.color} avatarUrl={who.avatarUrl} size="xs" />
                            <span className="text-slate-700">{who.name}</span>
                          </span>
                        ) : (
                          <span className="text-slate-400">—</span>
                        )}
                      </td>
                      <td className="px-2 py-1.5">
                        <span className={cn("rounded-full px-2 py-0.5 text-[11px] font-medium ring-1", HISTORY_TONE[r.state])}>{HISTORY_LABEL[r.state]}</span>
                        {(r.state === "on_time" || r.state === "late") && r.completedAt && (
                          <span className="ml-1.5 text-[11px] text-slate-500">
                            {r.state === "late" && localDateOf(r.completedAt) ? `${shortDay(localDateOf(r.completedAt)!)} ` : ""}
                            {clock(r.completedAt)}
                            {by ? ` by ${by.name}` : ""}
                          </span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {rows.length > SHOWN && (
            <button type="button" onClick={() => setAll((a) => !a)} className="mx-3 mb-2 text-xs font-medium text-violet-700 hover:underline">
              {all ? "Show fewer" : `Show all ${rows.length}`}
            </button>
          )}
        </>
      )}
    </section>
  );
}
