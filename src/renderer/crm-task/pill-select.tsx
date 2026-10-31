// Copied from the reference CRM.
import { useRef, useState } from "react";
import { Check, CheckCircle2, Flag } from "lucide-react";
import { cn } from "./lib/utils";
import { AnchoredPopover } from "./anchored-popover";
import type { TaskPriority, TaskStatus } from "../../shared/crm/tasks-data";

/**
 * THE STATUS PILL, AND THE PRIORITY PILL BESIDE IT.
 *
 * Asad, 2026-09-14, on ClickUp's task box: *"for the important things will be
 * on the our top up and the rest of the things can be in a plus button…
 * overall box stay simple and short"*.
 *
 * What this replaces: two rows of chips — five statuses and four priorities,
 * nine buttons, all on screen at once, ~90px of the dialog spent showing eight
 * options nobody had chosen. The pill shows the ONE value that is set and
 * costs one line. The other options are one click away and cost nothing until
 * then.
 *
 * 🔴 SQUARE-ISH, AND NO CHEVRON. `rounded-[5px]`, not `rounded-full`: Asad's
 * screenshot is ClickUp's status tag, which is a small rectangle. The missing
 * chevron is also deliberate — a coloured tag that changes when you press it
 * is the pattern being copied, and an arrow would make it read as a form
 * `<select>` again.
 *
 * A useful side-effect of not being round: the app-wide avatar-healing rule in
 * the design-system stylesheet (`:is(span,div)[class*="rounded-full"][class*="bg-…-500"]`,
 * line 944) repaints anything round and strongly coloured to grey. A round
 * status pill would have been silently greyed out by it. This one is a
 * `<button>` and is not round, so it keeps its colour in both themes.
 */

/** The visible text is ALREADY uppercase — not `text-transform` — so what the
 *  screenshot shows and what the DOM says are the same string. */
const STATUS_TEXT: Record<TaskStatus, string> = {
  "To-Do": "TO DO",
  "Working on it": "WORKING ON IT",
  "In Progress": "IN PROGRESS",
  Done: "DONE",
  Stuck: "STUCK",
};

/**
 * 🔴 THESE COLOURS DODGE THREE SWEEPS IN the design-system stylesheet, AND EACH WAS HIT ONCE
 * ON 2026-09-14 BEFORE IT WAS CHOSEN. The sweeps match by SUBSTRING on the
 * class list, so the weight of a colour is load-bearing here:
 *
 *  · NO `bg-blue-5/6/7`, `bg-sky-*`, `bg-indigo-*` on a button — the de-blue
 *    sweep (~line 4044) repaints it white with `!important`. "In Progress" on
 *    `bg-blue-600` rendered as a white outlined box (screenshot taskbox-4).
 *  · NO `bg-slate-500` — dark mode's `[class*="bg-slate-50"]` (~line 2468)
 *    substring-matches it and repaints it to the surface colour, so the "TO DO"
 *    pill went black-on-black in dark (taskbox-10). `bg-slate-600` does not
 *    contain "bg-slate-50" and survives.
 *  · NO `-500` weight on a round DOT — the avatar-healing rule (~line 944/948)
 *    greys any round span on `bg-amber-500`, `bg-rose-500`, `bg-violet-500`,
 *    `bg-orange-500`… in dark mode. The dots below sit one weight off.
 */
export const STATUS_SOLID: Record<TaskStatus, string> = {
  // Grey, not dark: the resting state of a new task should not shout. Matches
  // the "TO DO" pill in Asad's ClickUp screenshot (2026-09-14). The four
  // ACTIVE states keep their colours — those mean something.
  "To-Do": "bg-slate-100 !text-slate-700",
  "Working on it": "bg-amber-500",
  "In Progress": "bg-violet-600",
  Done: "bg-emerald-600",
  Stuck: "bg-rose-600",
};

/** The dot beside each status in the menu — same hues, weights the dark-mode
 *  avatar sweep leaves alone (see above). */
const STATUS_DOT_MENU: Record<TaskStatus, string> = {
  "To-Do": "bg-slate-400",
  "Working on it": "bg-amber-400",
  "In Progress": "bg-violet-600",
  Done: "bg-emerald-600",
  Stuck: "bg-rose-600",
};

/**
 * ClickUp's priority pill (docs/task-clickup-reference.md § 1.4, row 4): the
 * SAME bordered white pill as the due-date pill, a flag coloured by level, and
 * the label "<Level> priority" — "High priority", not "HIGH". Only the status
 * tag is uppercase in that row; everything else is a bordered pill in sentence
 * case, and Asad asked for the row "as it is".
 *
 * Flag colours are TEXT colours on an svg, so none of the three the design-system stylesheet
 * sweeps (they match `bg-*` on buttons and on round spans) can touch them.
 * ClickUp: Urgent red · High yellow · Normal blue · Low grey → ours: Critical ·
 * High · Medium · Low.
 */
/**
 * No priority chosen: ClickUp's own empty pill — an outline flag and the word
 * "Priority" (Asad, 2026-09-15: "it should not have any pre selected and should
 * not be required too"). Nothing is pre-picked; the menu carries a "Clear" row
 * once something is.
 */
const PRIORITY_EMPTY_TEXT = "Priority";

const PRIORITY_TEXT: Record<TaskPriority, string> = {
  Low: "Low priority",
  Medium: "Medium priority",
  High: "High priority",
  Critical: "Critical priority",
};

const PRIORITY_FLAG: Record<TaskPriority, string> = {
  Low: "text-slate-400",
  Medium: "text-blue-600",
  High: "text-amber-500",
  Critical: "text-rose-600",
};

/** The status TAG: small, square-ish, uppercase, bold, no icon, no chevron. */
const TAG_BASE =
  "inline-flex h-7 items-center gap-1.5 rounded-[5px] px-2.5 text-[11px] font-semibold " +
  "tracking-[0.03em] transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500";

/**
 * Every OTHER pill in the row (due date, priority, related-to, attach): white,
 * 1px border, 5px radius, 28px tall, 12px sentence-case text, icon on the
 * left. Exported so the timeline pill and the tag picker draw the same thing.
 */
export const PILL_BASE =
  "inline-flex h-7 items-center gap-1.5 rounded-[5px] border border-slate-200 bg-white px-2.5 text-xs font-medium " +
  "text-slate-700 transition-colors hover:border-slate-300 hover:bg-slate-50 focus:outline-none focus:ring-2 focus:ring-blue-500";

function Option<T extends string>({
  value,
  current,
  label,
  glyph,
  onPick,
}: {
  value: T;
  current: boolean;
  label: string;
  glyph: React.ReactNode;
  onPick: (v: T) => void;
}) {
  return (
    <button
      type="button"
      role="option"
      aria-selected={current}
      onClick={() => onPick(value)}
      className={cn(
        "flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-700",
        current ? "bg-slate-100" : "hover:bg-slate-50",
      )}
    >
      <span className="inline-grid h-4 w-4 shrink-0 place-content-center" aria-hidden>
        {glyph}
      </span>
      <span className="flex-1 truncate">{label}</span>
      {current && <Check className="h-3.5 w-3.5 shrink-0 text-blue-600" aria-hidden />}
    </button>
  );
}

/** ClickUp draws To Do as a dashed ring, an active status as a filled dot and
 *  a closed one as a green tick-in-a-circle (§ 1.4 row 1). Same here. */
function StatusGlyph({ status }: { status: TaskStatus }) {
  if (status === "To-Do") return <span className="h-3 w-3 rounded-full border-[1.5px] border-dashed border-slate-400" />;
  if (status === "Done") return <CheckCircle2 className="h-4 w-4 text-emerald-600" />;
  return <span className={cn("h-3 w-3 rounded-full", STATUS_DOT_MENU[status])} />;
}

/** "Closed" is the group a done task lives in; everything else is a status. */
function isClosed(s: TaskStatus): boolean {
  return s === "Done";
}

export function StatusPill({
  value,
  options,
  onChange,
}: {
  value: TaskStatus;
  options: readonly TaskStatus[];
  onChange: (next: TaskStatus) => void;
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const active = options.filter((s) => !isClosed(s));
  const closed = options.filter(isClosed);
  const pick = (v: TaskStatus) => {
    onChange(v);
    setOpen(false);
  };
  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={`Status: ${value}`}
        title="Status"
        className={cn(TAG_BASE, "text-white hover:opacity-90", STATUS_SOLID[value])}
      >
        {STATUS_TEXT[value]}
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Status" width={220}>
        {/* Two groups, as ClickUp: "Statuses" then "Closed". */}
        <div role="listbox" aria-label="Choose a status">
          <div className="px-3 pb-0.5 pt-1.5 text-[11px] font-medium text-slate-500">Statuses</div>
          {active.map((s) => (
            <Option key={s} value={s} current={s === value} label={s} glyph={<StatusGlyph status={s} />} onPick={pick} />
          ))}
          {closed.length > 0 && (
            <>
              <div className="my-1 border-t border-slate-100" aria-hidden />
              <div className="px-3 pb-0.5 pt-1 text-[11px] font-medium text-slate-500">Closed</div>
              {closed.map((s) => (
                <Option key={s} value={s} current={s === value} label={s} glyph={<StatusGlyph status={s} />} onPick={pick} />
              ))}
            </>
          )}
        </div>
      </AnchoredPopover>
    </>
  );
}

export function PriorityPill({
  value,
  options,
  onChange,
  variant = "pill",
}: {
  value: TaskPriority | null;
  options: readonly TaskPriority[];
  onChange: (next: TaskPriority | null) => void;
  /**
   * "pill" = the create box's bordered pill ("High priority"). "cell" = the
   * task page's property cell (inventory § 2.0): "Empty" until set, then a
   * coloured flag and the level alone ("High"), no border.
   */
  variant?: "pill" | "cell";
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  // ClickUp lists Urgent first. Our options arrive Low → Critical; the menu
  // shows them highest first so the flag colours read top-down like theirs.
  const ordered = [...options].reverse();
  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={value ? `Priority: ${value}` : "Priority"}
        title="Change priority"
        className={
          variant === "cell"
            ? "inline-flex h-7 items-center gap-1.5 rounded-md px-1 text-sm text-slate-800 focus:outline-none focus:ring-2 focus:ring-blue-500"
            : PILL_BASE
        }
      >
        {variant === "cell" ? (
          value ? (
            <>
              <Flag className={cn("h-4 w-4 shrink-0 fill-current", PRIORITY_FLAG[value])} aria-hidden />
              {value}
            </>
          ) : (
            <span className="text-slate-400">Empty</span>
          )
        ) : (
          <>
            {value ? (
              <Flag className={cn("h-3.5 w-3.5 shrink-0 fill-current", PRIORITY_FLAG[value])} aria-hidden />
            ) : (
              <Flag className="h-3.5 w-3.5 shrink-0 text-slate-400" aria-hidden />
            )}
            {value ? PRIORITY_TEXT[value] : PRIORITY_EMPTY_TEXT}
          </>
        )}
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Priority" width={200}>
        <div role="listbox" aria-label="Choose a priority">
          <div className="px-3 pb-0.5 pt-1.5 text-[11px] font-medium text-slate-500">Priority</div>
          {ordered.map((p) => (
            <Option
              key={p}
              value={p}
              current={p === value}
              label={p}
              glyph={<Flag className={cn("h-3.5 w-3.5 fill-current", PRIORITY_FLAG[p])} />}
              onPick={(v) => {
                onChange(v);
                setOpen(false);
              }}
            />
          ))}
          {value && (
            <button
              type="button"
              role="option"
              aria-selected={false}
              onClick={() => {
                onChange(null);
                setOpen(false);
              }}
              className="mt-0.5 flex w-full items-center gap-2 border-t border-slate-100 px-3 py-1.5 text-left text-sm text-slate-500 hover:bg-slate-50 hover:text-slate-800"
            >
              Clear
            </button>
          )}
        </div>
      </AnchoredPopover>
    </>
  );
}
