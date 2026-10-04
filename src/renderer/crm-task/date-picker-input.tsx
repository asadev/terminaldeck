// Copied from the reference CRM.
import { localToday } from "../../shared/crm/local-time";
import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { createPortal } from "react-dom";
import { portalRoot } from "./lib/portal-root";
import { Calendar, ChevronLeft, ChevronRight } from "lucide-react";
import { useOutsideClick } from "./lib/use-outside-click";
import { cn } from "./lib/utils";

/**
 * Custom date picker — text input + portalled calendar popover.
 *
 * Behaviour contract:
 *   - AUTO-SAVE on day click. The picker calls onChange(iso) and
 *     closes the popover the instant a day cell is clicked. There
 *     is no OK button. This matches the Follow-up cell spec where
 *     a single click must persist immediately to Supabase.
 *   - "Clear" persists the empty value and closes.
 *   - "Today" picks today — this computer's day (the
 *     whole business runs locally; 2026-09-15: a browser in another zone
 *     picked, and ringed, a different day) — and closes.
 *   - "Cancel" closes without committing — useful only when the user
 *     has merely browsed months without picking a day.
 *   - Escape = Cancel · Enter on a focused day cell triggers the
 *     native button onClick = same auto-save path.
 *   - When `redWhenToday` is true AND the saved value equals today's
 *     local date, the trigger button renders in a high-contrast red
 *     state (red-50 bg, red-500 border, red-600 semibold text). The
 *     "today" comparison uses `useTodayISO()` which re-evaluates every
 *     60 s so a row open at 23:59 drops the red styling at 00:00
 *     without a manual refresh. Past-due dates are NOT red — the
 *     spec scopes red to today only.
 *   - Renders into document.body via a portal at z-index 60.
 *   - Anchored with viewport-aware flip + shift, recomputed on
 *     scroll and resize.
 *   - Value contract: ISO yyyy-mm-dd, a calendar date ("today" is local). Display: dd/mm/yyyy.
 */
export function DatePickerInput({
  value,
  onChange,
  placeholder = "dd/mm/yyyy",
  disabled,
  className,
  inputClassName,
  redWhenToday = false,
  ariaLabel,
  emptyLabel,
}: {
  value: string; // ISO yyyy-mm-dd, "" when empty
  onChange: (next: string) => void;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  inputClassName?: string;
  /**
   * When true, the trigger button paints red whenever `value` equals
   * today (local day). Off by default so non-Follow-up usages
   * (event date pickers, etc.) stay visually unchanged.
   */
  redWhenToday?: boolean;
  /**
   * What this date IS, for assistive tech. Defaults to the follow-up wording
   * this component was born with (the leads board's Follow-up column). Any
   * other caller should say its own thing: a task's start date announced as
   * "Pick a follow-up date" is simply wrong, and there are nine callers now.
   */
  ariaLabel?: string;
  /**
   * Text to show when there is no date yet. Omitted, the trigger stays
   * icon-only — which is what the narrow table cells it was designed for need,
   * and what every existing caller still gets.
   */
  emptyLabel?: string;
}) {
  const [open, setOpen] = useState(false);
  const [cursor, setCursor] = useState<{ year: number; month: number }>(() => {
    // local month when there is no value — never the browser's zone.
    const seed = parseIso(value || readTodayISO());
    return { year: seed.getFullYear(), month: seed.getMonth() };
  });
  const [pos, setPos] = useState<{ top: number; left: number; placement: "top" | "bottom" }>({
    top: 0,
    left: 0,
    placement: "bottom",
  });

  const containerRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const popoverRef = useRef<HTMLDivElement | null>(null);

  const todayISO = useTodayISO();
  const isToday = redWhenToday && !!value && value === todayISO;

  useOutsideClick([containerRef, popoverRef], () => setOpen(false), open);

  function commit(next: string) {
    // Auto-save contract: the click closes first so the popover
    // disappears immediately, then onChange fires which kicks off
    // the optimistic update + Supabase write. Closing first avoids
    // a millisecond-long flicker where the just-clicked day cell
    // shows "selected" before the popover unmounts.
    setOpen(false);
    onChange(next);
  }

  function openPicker() {
    if (disabled) return;
    if (value) {
      const d = parseIso(value);
      setCursor({ year: d.getFullYear(), month: d.getMonth() });
    } else {
      const t = parseIso(readTodayISO());
      setCursor({ year: t.getFullYear(), month: t.getMonth() });
    }
    setOpen(true);
  }

  // Compute portal position from trigger's bounding rect. Smart
  // flip + shift so the popover never escapes the viewport — and
  // critically, doesn't bleed BACKWARDS over preceding form fields.
  //
  // 2026-05-23 fix — Haji reported the calendar "opens wherever I
  // click" with a screenshot showing the popover covering the
  // adjacent UNIT NO column. Root cause: the previous algorithm
  // right-aligned to the trigger (`left = rect.right - POPOVER_W`),
  // so for a 100 px-wide table cell the 256 px popover extended
  // ~156 px to the LEFT of the trigger — directly on top of the
  // columns to its left.
  //
  // New rule: LEFT-align by default (popover extends rightward into
  // the empty space past the trigger). Fall back to right-align only
  // when the popover would overflow the viewport's right edge.
  // Final clamp keeps it inside the viewport regardless.
  function recomputePosition() {
    const trigger = triggerRef.current;
    if (!trigger) return;
    const rect = trigger.getBoundingClientRect();
    const POPOVER_W = 256;
    const POPOVER_H = 320;
    const OFFSET = 8;
    const VIEWPORT_PAD = 8;
    const spaceBelow = window.innerHeight - rect.bottom;
    const spaceAbove = rect.top;
    const placement: "top" | "bottom" =
      spaceBelow < POPOVER_H + OFFSET && spaceAbove > spaceBelow ? "top" : "bottom";
    const top =
      placement === "bottom"
        ? rect.bottom + OFFSET
        : Math.max(VIEWPORT_PAD, rect.top - POPOVER_H - OFFSET);
    // Prefer left-align — popover opens to the RIGHT of the trigger,
    // away from any preceding columns / form fields.
    let left = rect.left;
    // Flip to right-align only if left-align would overflow the
    // viewport's right edge.
    if (left + POPOVER_W > window.innerWidth - VIEWPORT_PAD) {
      left = rect.right - POPOVER_W;
    }
    // Final clamp — never leave the viewport even if the trigger
    // itself is partially off-screen (e.g., during a horizontal
    // scroll).
    if (left < VIEWPORT_PAD) left = VIEWPORT_PAD;
    if (left + POPOVER_W > window.innerWidth - VIEWPORT_PAD) {
      left = window.innerWidth - POPOVER_W - VIEWPORT_PAD;
    }
    setPos({ top, left, placement });
  }

  useLayoutEffect(() => {
    if (!open) return;
    recomputePosition();
  }, [open]);

  useEffect(() => {
    if (!open) return;
    function onScrollOrResize() {
      recomputePosition();
    }
    window.addEventListener("scroll", onScrollOrResize, true);
    window.addEventListener("resize", onScrollOrResize);
    return () => {
      window.removeEventListener("scroll", onScrollOrResize, true);
      window.removeEventListener("resize", onScrollOrResize);
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        setOpen(false);
      }
      // Enter is intentionally not handled here. With auto-save on
      // click, the focused day cell's native onKeyDown -> onClick
      // already commits + closes via `commit()`. Catching Enter at
      // document level would double-commit.
    };
    document.addEventListener("keydown", handler, true);
    return () => document.removeEventListener("keydown", handler, true);
  }, [open]);

  const cells = useMemo(() => buildMonthGrid(cursor.year, cursor.month), [cursor]);
  const mounted = typeof window !== "undefined";

  return (
    <div ref={containerRef} className={cn("relative", className)}>
      <button
        ref={triggerRef}
        type="button"
        disabled={disabled}
        onClick={openPicker}
        className={cn(
          "w-full h-7 rounded-md border text-xs px-2 text-left focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-slate-50 disabled:cursor-not-allowed transition-colors",
          isToday
            ? "border-red-500 bg-red-50 text-red-600 font-semibold"
            : "border-slate-200 bg-white text-slate-800",
          inputClassName,
        )}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={
          ariaLabel
            ? value
              ? `${ariaLabel} — ${formatDisplay(value)}`
              : ariaLabel
            : isToday
              ? `Follow-up due today (${formatDisplay(value)})`
              : value
                ? `Follow-up ${formatDisplay(value)}`
                : "Pick a follow-up date"
        }
        title={isToday ? "Follow-up due today" : undefined}
      >
        {value ? (
          formatDisplay(value)
        ) : (
          <span className="inline-flex items-center gap-1.5 text-slate-400">
            <Calendar className="h-3.5 w-3.5" aria-label={emptyLabel ? undefined : placeholder} />
            {emptyLabel}
          </span>
        )}
      </button>
      {open && mounted &&
        createPortal(
          <div
            ref={popoverRef}
            role="dialog"
            aria-label="Pick a date"
            onMouseDown={(e) => e.stopPropagation()}
            className="dialog-pop fixed z-[95] w-64 rounded-lg border border-slate-200 bg-white shadow-xl p-2"
            style={{ top: pos.top, left: pos.left }}
          >
            {/* Month header */}
            <div className="flex items-center justify-between mb-1.5">
              <button
                type="button"
                onClick={() =>
                  setCursor((c) => {
                    const d = new Date(c.year, c.month - 1, 1);
                    return { year: d.getFullYear(), month: d.getMonth() };
                  })
                }
                className="h-6 w-6 rounded-md hover:bg-slate-100 flex items-center justify-center text-slate-500"
                aria-label="Previous month"
              >
                <ChevronLeft className="h-3.5 w-3.5" />
              </button>
              <div className="text-[12px] font-semibold text-slate-800">
                {MONTH_NAMES[cursor.month]} {cursor.year}
              </div>
              <button
                type="button"
                onClick={() =>
                  setCursor((c) => {
                    const d = new Date(c.year, c.month + 1, 1);
                    return { year: d.getFullYear(), month: d.getMonth() };
                  })
                }
                className="h-6 w-6 rounded-md hover:bg-slate-100 flex items-center justify-center text-slate-500"
                aria-label="Next month"
              >
                <ChevronRight className="h-3.5 w-3.5" />
              </button>
            </div>

            <div className="grid grid-cols-7 mb-0.5">
              {WEEKDAYS.map((d) => (
                <div
                  key={d}
                  className="text-[9px] font-semibold uppercase tracking-wider text-slate-400 text-center py-0.5"
                >
                  {d}
                </div>
              ))}
            </div>

            <div className="grid grid-cols-7 gap-0">
              {cells.map((d) => {
                const k = ymd(d);
                const isOtherMonth = d.getMonth() !== cursor.month;
                const dayIsToday = k === todayISO;
                const isSelected = k === value;
                return (
                  <button
                    key={k}
                    type="button"
                    onClick={() => commit(k)}
                    className={cn(
                      "h-7 w-full rounded-md text-[11px] tabular-nums transition-colors",
                      isSelected
                        ? "bg-blue-600 text-white font-semibold"
                        : dayIsToday
                          ? "bg-blue-50 text-blue-700 font-semibold hover:bg-blue-100"
                          : isOtherMonth
                            ? "text-slate-300 hover:bg-slate-50"
                            : "text-slate-700 hover:bg-slate-100",
                    )}
                    aria-selected={isSelected}
                    aria-label={k}
                  >
                    {d.getDate()}
                  </button>
                );
              })}
            </div>

            {/* Footer — Clear / Today / Cancel. OK is intentionally
                absent: every click on a day cell auto-saves + closes,
                so a separate confirm step would only confuse. */}
            <div className="flex items-center justify-between gap-1 mt-2 pt-1.5 border-t border-slate-100">
              <div className="flex items-center gap-0.5">
                <button
                  type="button"
                  onClick={() => commit("")}
                  className="h-6 px-1.5 text-[10px] text-slate-600 hover:bg-slate-100 rounded-md"
                >
                  Clear
                </button>
                <button
                  type="button"
                  onClick={() => commit(todayISO)}
                  className="h-6 px-1.5 text-[10px] text-slate-600 hover:bg-slate-100 rounded-md"
                >
                  Today
                </button>
              </div>
              <div className="flex items-center gap-1">
                <button
                  type="button"
                  onClick={() => setOpen(false)}
                  className="h-6 px-2 text-[10px] font-medium text-slate-700 bg-white border border-slate-200 hover:bg-slate-50 rounded-md"
                >
                  Cancel
                </button>
              </div>
            </div>
          </div>,
          portalRoot(),
        )}
    </div>
  );
}

const WEEKDAYS = ["S", "M", "T", "W", "T", "F", "S"];
const MONTH_NAMES = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];

function ymd(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function parseIso(s: string): Date {
  const [y, m, d] = s.split("-").map(Number);
  if (!y || !m || !d) return new Date();
  return new Date(y, m - 1, d);
}

function formatDisplay(iso: string): string {
  const d = parseIso(iso);
  const dd = String(d.getDate()).padStart(2, "0");
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const yyyy = d.getFullYear();
  return `${dd}/${mm}/${yyyy}`;
}

function buildMonthGrid(year: number, month: number): Date[] {
  const first = new Date(year, month, 1);
  const startDow = first.getDay();
  const start = new Date(year, month, 1 - startDow);
  const cells: Date[] = [];
  for (let i = 0; i < 42; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    cells.push(d);
  }
  return cells;
}

// ---------------------------------------------------------------
// useTodayISO — module-level shared "today" value, refreshed once
// per minute. Many DatePickerInput instances on a busy table all
// subscribe to the SAME store, so the page runs exactly one timer
// regardless of row count. The minute-tick is enough to drop the
// red styling within 60 s of a midnight rollover, per spec.
// ---------------------------------------------------------------

let todaySnapshot = "";
const todayListeners = new Set<() => void>();
let todayTimer: ReturnType<typeof setInterval> | null = null;

/** local "YYYY-MM-DD" (the SSR snapshot stays "" — see useTodayISO). */
export function readTodayISO(): string {
  return localToday();
}

function ensureTodayTimerStarted() {
  if (typeof window === "undefined") return;
  if (todayTimer != null) return;
  todaySnapshot = readTodayISO();
  todayTimer = setInterval(() => {
    const next = readTodayISO();
    if (next !== todaySnapshot) {
      todaySnapshot = next;
      todayListeners.forEach((l) => l());
    }
  }, 60_000);
}

function subscribeToday(cb: () => void): () => void {
  ensureTodayTimerStarted();
  todayListeners.add(cb);
  return () => {
    todayListeners.delete(cb);
    if (todayListeners.size === 0 && todayTimer != null) {
      clearInterval(todayTimer);
      todayTimer = null;
    }
  };
}

function getTodaySnapshot(): string {
  if (!todaySnapshot) todaySnapshot = readTodayISO();
  return todaySnapshot;
}

function getTodayServerSnapshot(): string {
  // SSR has no concept of the user's local timezone. Returning ""
  // means red-when-today never matches during render-on-server,
  // which is exactly what we want — the styling lights up after
  // hydration when the local date is known.
  return "";
}

export function useTodayISO(): string {
  return useSyncExternalStore(
    subscribeToday,
    getTodaySnapshot,
    getTodayServerSnapshot,
  );
}
