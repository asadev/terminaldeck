// Copied from the reference CRM.
import { useMemo, useRef, useState, type ReactNode, useEffect } from "react";
import {
  Archive,
  ArchiveRestore,
  ArrowRightLeft,
  Bell,
  BellOff,
  CalendarRange,
  Check,
  ChevronRight,
  Clock,
  CopyPlus,
  Diamond,
  FolderInput,
  GitMerge,
  History,
  MoreHorizontal,
  Network,
  Printer,
  Repeat,
  Star,
  Trash2,
  X,
} from "lucide-react";
import { cn } from "../lib/utils";
import { AnchoredPopover } from "../anchored-popover";
import { localInstantAt, localParts, localStamp, todayYmd, ymdAddDays, ymdWeekday, DAY_SHORT } from "../../../shared/crm/local-time";
import type { TaskMore } from "../../../shared/crm/task-more-actions";
import type { TaskType } from "../../../shared/crm/task-page";

/**
 * ⋯ — CLICKUP'S TASK MENU (docs/clickup-task-inventory.md § 2.8, 21 items, in
 * its order and groups):
 *
 *   [ Copy link | Copy ID | New tab ]
 *   ☆ Favorite · ⏰ Remind me › (the CRM has Follow / Unfollow and "in Inbox" here; one person, no Inbox — a Mac notification)
 *   ⇥ Move to › · ⤳ Merge › · ⧉ Duplicate · ⟳ Convert to › Subtask
 *   ↯ Relationships › · 🕘 Description history · ⬡ Task Type › · 📅 Sync dates with subtasks [toggle]
 *   🖨 Print
 *   🗄 Archive · 🗑 Delete
 *   [ Sharing & Permissions ]
 *
 * Left out, because nothing here can hold them: Add to › (a task lives on one
 * board; Favorites is our "pin"), Templates › (no task templates), Send email
 * to task (no inbound mail per task), Convert to › List (no lists). Ours on
 * top: ↻ Stop recurring when the task is a routine.
 *
 * Submenus open in place, under their row — one layer, so Escape closes the
 * menu and never the task behind it.
 */

/** Why a local task has no link to copy. */
export const NO_LINK = "A task on this computer has no link — nothing else can open it. Copy its ID instead.";

export type RelateKind = "relate" | "blocks" | "blocked_by";

export type MoreMenuProps = {
  taskId: string;
  canEditRow: boolean;
  fav: boolean;
  toggleFav: () => void;
  /** The header's board list, closing the menu on a pick. */
  renderMove: (done: () => void) => ReactNode;
  copy: (text: string) => Promise<boolean>;
  /** The task's link to copy; null: it has none (a task on this computer opens nowhere else). */
  link: ((taskId: string) => string) | null;
  onDuplicate?: () => void;
  canDelete: boolean;
  onDelete?: () => void;
  onStopRecurring?: () => void;
  /** Part 2 — null while loading or before migrations/2026-09-15-task-page-2.sql. */
  more?: TaskMore | null;
  moreUnavailable?: string | null;
  onFollow?: (following: boolean) => void;
  onRemind?: (atIso: string) => void;
  onClearReminder?: (id: string) => void;
  onArchive?: (archived: boolean) => void;
  /** Tasks to merge into or convert under (the list the page came from). */
  taskOptions?: { id: string; title: string }[];
  onMerge?: (targetId: string) => void;
  onConvertToSubtask?: (parentId: string) => void;
  onRelate?: (kind: RelateKind) => void;
  onDescriptionHistory?: () => void;
  taskType?: TaskType | null;
  onTaskType?: (t: TaskType) => void;
  onSyncDates?: (on: boolean) => void;
  onShare?: () => void;
};

type Sub = null | "remind" | "move" | "merge" | "convert" | "relate" | "type";

const item = "flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50";
const nested = "border-y border-slate-100 bg-slate-50/60 py-1";

/** ClickUp's reminder times, locally: In 1 hour · Later today 6 pm · Tomorrow 9 am · Next week Mon 9 am. */
export function reminderPresets(now: Date = new Date()): { key: string; label: string; at: Date }[] {
  const today = todayYmd(now);
  const out = [{ key: "1h", label: "In 1 hour", at: new Date(now.getTime() + 3600_000) }];
  const evening = localInstantAt(today, 18);
  if (evening.getTime() - now.getTime() > 3600_000) out.push({ key: "later", label: "Later today", at: evening });
  out.push({ key: "tomorrow", label: "Tomorrow", at: localInstantAt(ymdAddDays(today, 1), 9) });
  const toMonday = ((8 - ymdWeekday(today)) % 7) || 7;
  out.push({ key: "next-week", label: "Next week", at: localInstantAt(ymdAddDays(today, toMonday), 9) });
  return out;
}

function hint(at: Date): string {
  const p = localParts(at)!;
  return `${DAY_SHORT[p.weekday]}, ${localStamp(at).split(", ")[1]}`;
}

export function MoreMenu(p: MoreMenuProps) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const [sub, setSub] = useState<Sub>(null);
  const [copied, setCopied] = useState<"link" | "id" | null>(null);
  const [arming, setArming] = useState<null | "delete" | "stop">(null);
  const [pick, setPick] = useState<{ id: string; title: string } | null>(null);
  const [q, setQ] = useState("");
  const [custom, setCustom] = useState("");
  const close = () => {
    setOpen(false);
    setSub(null);
    setArming(null);
    setPick(null);
    setQ("");
    setCustom("");
    // Focus goes back to ⋯ (inc8 L12): the menu is portalled, so the page would otherwise lose the keyboard's place.
    ref.current?.focus();
  };
  /**
   * The keyboard (inc8 L12): the menu is portalled out of the header, so Tab from ⋯ never reached it. On open
   * the first item takes focus; ↑ ↓ Home End walk the items; Tab and Shift+Tab stay inside the menu; closing
   * returns focus to ⋯. Arrows typed in a field (the search, the date and time) stay the field's.
   */
  const menuRef = useRef<HTMLDivElement | null>(null);
  const items = () =>
    Array.from(menuRef.current?.querySelectorAll<HTMLElement>('[role="menuitem"]:not([disabled]), [role="switch"]:not([disabled]), input') ?? []);
  useEffect(() => {
    if (!open) return;
    const t = window.setTimeout(() => items().find((el) => el.getAttribute("role") === "menuitem")?.focus(), 0);
    return () => window.clearTimeout(t);
  }, [open]);
  const onMenuKey = (e: React.KeyboardEvent<HTMLDivElement>) => {
    const inField = (e.target as HTMLElement).tagName === "INPUT";
    const list = items();
    if (!list.length) return;
    const at = list.indexOf(document.activeElement as HTMLElement);
    const go = (i: number) => {
      e.preventDefault();
      list[(i + list.length) % list.length]?.focus();
    };
    if (e.key === "Tab") go(e.shiftKey ? at - 1 : at + 1);
    else if (inField) return;
    else if (e.key === "ArrowDown") go(at + 1);
    else if (e.key === "ArrowUp") go(at < 0 ? list.length - 1 : at - 1);
    else if (e.key === "Home") go(0);
    else if (e.key === "End") go(list.length - 1);
  };
  const toggleSub = (s: Sub) => {
    setSub((cur) => (cur === s ? null : s));
    setPick(null);
    setQ("");
  };
  const flash = (what: "link" | "id") => {
    setCopied(what);
    setTimeout(() => setCopied(null), 1500);
  };
  const more = p.more ?? null;
  const partTwo = !!more;
  const choices = useMemo(() => {
    const words = q.trim().toLowerCase();
    return (p.taskOptions ?? []).filter((t) => t.id !== p.taskId && (!words || t.title.toLowerCase().includes(words))).slice(0, 8);
  }, [p.taskOptions, p.taskId, q]);

  const picker = (verb: "Merge into" | "Make a subtask of", run?: (id: string) => void) =>
    !run ? null : pick ? (
      <div className="flex flex-wrap items-center gap-1 px-3 py-1.5" role="group" aria-label={`Confirm ${verb.toLowerCase()}`}>
        <span className="min-w-0 flex-1 truncate text-xs text-slate-600">
          {verb} “{pick.title}”? {verb === "Merge into" ? "This task's comments, subtasks, checklists and time move there; this one goes to Trash." : "This task goes to Trash; its first line becomes the subtask."}
        </span>
        <button
          type="button"
          role="menuitem"
          onClick={() => {
            const id = pick.id;
            close();
            run(id);
          }}
          className="btn btn-primary btn-sm"
        >
          {verb === "Merge into" ? "Merge" : "Convert"}
        </button>
        <button type="button" role="menuitem" onClick={() => setPick(null)} className="btn btn-ghost btn-sm">
          Cancel
        </button>
      </div>
    ) : (
      <div className="px-2 py-1">
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search tasks…" aria-label="Search tasks" autoFocus className="mb-1 h-7 w-full rounded-md border border-slate-200 bg-white px-2 text-sm outline-none focus:border-violet-500" />
        {choices.length === 0 ? (
          <p className="px-1 py-1 text-xs text-slate-400">No other task in this list.</p>
        ) : (
          choices.map((t) => (
            <button key={t.id} type="button" role="menuitem" onClick={() => setPick(t)} className="block w-full truncate rounded px-1.5 py-1 text-left text-sm text-slate-700 hover:bg-white">
              {t.title || "Untitled"}
            </button>
          ))
        )}
      </div>
    );

  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => {
          if (open) close();
          else setOpen(true);
        }}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="More"
        title="More"
        className="grid h-7 w-7 shrink-0 place-content-center rounded-md text-slate-500 hover:bg-slate-100 hover:text-slate-800"
      >
        <MoreHorizontal className="h-4 w-4" aria-hidden />
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={close} label="Task actions" width={256} align="right">
        <div ref={menuRef} role="menu" onKeyDown={onMenuKey} className="max-h-[min(80vh,720px)] overflow-y-auto" data-testid="more-menu">
          {/* The segmented top row. */}
          {/* The CRM's third cell, "New tab", opens the task's web page; a local task has none, so the row has two. */}
          <div className="mx-2 mb-1 mt-1 grid grid-cols-2 overflow-hidden rounded-md border border-slate-200 text-xs text-slate-700">
            <button
              type="button"
              role="menuitem"
              disabled={p.link === null}
              title={p.link === null ? NO_LINK : undefined}
              onClick={async () => {
                if (p.link !== null && (await p.copy(p.link(p.taskId)))) flash("link");
              }}
              className="h-7 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-transparent"
            >
              {copied === "link" ? "Copied" : "Copy link"}
            </button>
            <button
              type="button"
              role="menuitem"
              onClick={async () => {
                if (await p.copy(p.taskId)) flash("id");
              }}
              className="h-7 border-l border-slate-200 hover:bg-slate-50"
            >
              {copied === "id" ? "Copied" : "Copy ID"}
            </button>
          </div>

          <button type="button" role="menuitem" onClick={p.toggleFav} className={item}>
            <Star className={cn("h-4 w-4 text-slate-500", p.fav && "fill-amber-400 text-amber-400")} aria-hidden />
            {p.fav ? "Remove from Favorites" : "Favorite"}
          </button>
          {p.onFollow && (
            <button type="button" role="menuitem" disabled={!partTwo} onClick={() => more && p.onFollow?.(!more.iFollow)} className={item}>
              {more?.iFollow === false ? <Bell className="h-4 w-4 text-slate-500" aria-hidden /> : <BellOff className="h-4 w-4 text-slate-500" aria-hidden />}
              {more?.iFollow === false ? "Follow task" : "Unfollow task"}
            </button>
          )}
          {p.onRemind && (
            <>
              <button type="button" role="menuitem" aria-expanded={sub === "remind"} disabled={!partTwo} onClick={() => toggleSub("remind")} className={item}>
                <Clock className="h-4 w-4 text-slate-500" aria-hidden />
                <span className="flex-1">Remind me</span>
                {!!more?.reminders.length && <span className="text-xs text-violet-600">{more.reminders.length}</span>}
                <ChevronRight className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              </button>
              {sub === "remind" && more && (
                <div className={nested} role="group" aria-label="Remind me">
                  {reminderPresets().map((r) => (
                    <button
                      key={r.key}
                      type="button"
                      role="menuitem"
                      onClick={() => {
                        close();
                        p.onRemind?.(r.at.toISOString());
                      }}
                      className="flex w-full items-center px-4 py-1 text-left text-sm text-slate-700 hover:bg-white"
                    >
                      <span className="flex-1">{r.label}</span>
                      <span className="text-xs text-slate-400">{hint(r.at)}</span>
                    </button>
                  ))}
                  <div className="flex items-center gap-1 px-4 py-1">
                    <input type="datetime-local" value={custom} onChange={(e) => setCustom(e.target.value)} aria-label="Remind me at" className="h-7 min-w-0 flex-1 rounded border border-slate-200 bg-white px-1 text-xs" />
                    <button
                      type="button"
                      role="menuitem"
                      disabled={!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(custom)}
                      onClick={() => {
                        const [d, t] = custom.split("T");
                        const [hh, mm] = t.split(":").map(Number);
                        close();
                        p.onRemind?.(localInstantAt(d, hh, mm).toISOString());
                      }}
                      className="btn btn-primary btn-sm"
                    >
                      Set
                    </button>
                  </div>
                  {more.reminders.map((r) => (
                    <div key={r.id} className="flex items-center gap-1 px-4 py-1 text-xs text-slate-600">
                      <Clock className="h-3 w-3 text-violet-600" aria-hidden />
                      <span className="flex-1">{localStamp(r.remindAt)}</span>
                      {p.onClearReminder && (
                        <button type="button" role="menuitem" aria-label="Cancel reminder" onClick={() => p.onClearReminder?.(r.id)} className="rounded p-0.5 text-slate-400 hover:bg-white hover:text-slate-700">
                          <X className="h-3 w-3" aria-hidden />
                        </button>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </>
          )}

          <div className="my-1 border-t border-slate-100" aria-hidden />
          {p.canEditRow && (
            <>
              <button type="button" role="menuitem" aria-expanded={sub === "move"} onClick={() => toggleSub("move")} className={item}>
                <FolderInput className="h-4 w-4 text-slate-500" aria-hidden />
                <span className="flex-1">Move to</span>
                <ChevronRight className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              </button>
              {sub === "move" && <div className={nested}>{p.renderMove(close)}</div>}
            </>
          )}
          {p.canEditRow && p.onMerge && (
            <>
              <button type="button" role="menuitem" aria-expanded={sub === "merge"} onClick={() => toggleSub("merge")} className={item}>
                <GitMerge className="h-4 w-4 text-slate-500" aria-hidden />
                <span className="flex-1">Merge</span>
                <ChevronRight className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              </button>
              {sub === "merge" && <div className={nested}>{picker("Merge into", p.onMerge)}</div>}
            </>
          )}
          {p.onDuplicate && (
            <button
              type="button"
              role="menuitem"
              onClick={() => {
                close();
                p.onDuplicate?.();
              }}
              className={item}
            >
              <CopyPlus className="h-4 w-4 text-slate-500" aria-hidden />
              Duplicate
            </button>
          )}
          {p.canEditRow && p.onConvertToSubtask && (
            <>
              <button type="button" role="menuitem" aria-expanded={sub === "convert"} onClick={() => toggleSub("convert")} className={item}>
                <ArrowRightLeft className="h-4 w-4 text-slate-500" aria-hidden />
                <span className="flex-1">Convert to subtask</span>
                <ChevronRight className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              </button>
              {sub === "convert" && <div className={nested}>{picker("Make a subtask of", p.onConvertToSubtask)}</div>}
            </>
          )}

          <div className="my-1 border-t border-slate-100" aria-hidden />
          {p.onRelate && (
            <>
              <button type="button" role="menuitem" aria-expanded={sub === "relate"} onClick={() => toggleSub("relate")} className={item}>
                <Network className="h-4 w-4 text-slate-500" aria-hidden />
                <span className="flex-1">Relationships</span>
                <ChevronRight className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              </button>
              {sub === "relate" && (
                <div className={nested} role="group" aria-label="Relationships">
                  {(
                    [
                      ["relate", "Relate a task"],
                      ["blocks", "This task blocks…"],
                      ["blocked_by", "This task is blocked by…"],
                    ] as const
                  ).map(([k, label]) => (
                    <button
                      key={k}
                      type="button"
                      role="menuitem"
                      onClick={() => {
                        close();
                        p.onRelate?.(k);
                      }}
                      className="block w-full px-4 py-1 text-left text-sm text-slate-700 hover:bg-white"
                    >
                      {label}
                    </button>
                  ))}
                </div>
              )}
            </>
          )}
          {p.onDescriptionHistory && (
            <button
              type="button"
              role="menuitem"
              onClick={() => {
                close();
                p.onDescriptionHistory?.();
              }}
              className={item}
            >
              <History className="h-4 w-4 text-slate-500" aria-hidden />
              Description history
            </button>
          )}
          {p.canEditRow && p.onTaskType && (
            <>
              <button type="button" role="menuitem" aria-expanded={sub === "type"} onClick={() => toggleSub("type")} className={item}>
                <Diamond className="h-4 w-4 text-slate-500" aria-hidden />
                <span className="flex-1">Task Type</span>
                <ChevronRight className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              </button>
              {sub === "type" && (
                <div className={nested} role="group" aria-label="Task Type">
                  {(["task", "milestone"] as const).map((t) => (
                    <button
                      key={t}
                      type="button"
                      role="menuitemradio"
                      aria-checked={(p.taskType ?? "task") === t}
                      onClick={() => {
                        close();
                        p.onTaskType?.(t);
                      }}
                      className="flex w-full items-center px-4 py-1 text-left text-sm text-slate-700 hover:bg-white"
                    >
                      <span className="flex-1">{t === "task" ? "Task (default)" : "Milestone"}</span>
                      {(p.taskType ?? "task") === t && <Check className="h-3.5 w-3.5 text-violet-600" aria-hidden />}
                    </button>
                  ))}
                </div>
              )}
            </>
          )}
          {p.canEditRow && p.onSyncDates && (
            <div className={cn(item, "cursor-default hover:bg-transparent")}>
              <CalendarRange className="h-4 w-4 text-slate-500" aria-hidden />
              <span className="flex-1">Sync dates with subtasks</span>
              <button
                type="button"
                role="switch"
                aria-label="Sync dates with subtasks"
                aria-checked={!!more?.syncSubtaskDates}
                disabled={!partTwo}
               
                onClick={() => more && p.onSyncDates?.(!more.syncSubtaskDates)}
                className={cn("relative h-4 w-7 rounded-full transition-colors disabled:opacity-50", more?.syncSubtaskDates ? "bg-violet-600" : "bg-slate-200")}
              >
                <span className={cn("absolute top-0.5 h-3 w-3 rounded-full bg-white shadow transition-all", more?.syncSubtaskDates ? "left-[14px]" : "left-0.5")} />
              </button>
            </div>
          )}
          {p.onStopRecurring &&
            (arming !== "stop" ? (
              <button type="button" role="menuitem" onClick={() => setArming("stop")} className={item}>
                <Repeat className="h-4 w-4 text-slate-500" aria-hidden />
                Stop recurring
              </button>
            ) : (
              <div className="flex items-center gap-1 px-2 py-1.5" role="group" aria-label="Confirm stop recurring">
                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    close();
                    p.onStopRecurring?.();
                  }}
                  className="btn btn-danger btn-sm"
                >
                  Stop recurring?
                </button>
                <button type="button" role="menuitem" onClick={() => setArming(null)} className="btn btn-ghost btn-sm">
                  Cancel
                </button>
              </div>
            ))}

          <div className="my-1 border-t border-slate-100" aria-hidden />
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              close();
              window.print();
            }}
            className={item}
          >
            <Printer className="h-4 w-4 text-slate-500" aria-hidden />
            Print
          </button>

          {(p.onArchive || (p.canDelete && p.onDelete)) && <div className="my-1 border-t border-slate-100" aria-hidden />}
          {p.canEditRow && p.onArchive && (
            <button
              type="button"
              role="menuitem"
              disabled={!partTwo}
             
              onClick={() => {
                const archived = !more?.archivedAt;
                close();
                p.onArchive?.(archived);
              }}
              className={item}
            >
              {more?.archivedAt ? <ArchiveRestore className="h-4 w-4 text-slate-500" aria-hidden /> : <Archive className="h-4 w-4 text-slate-500" aria-hidden />}
              {more?.archivedAt ? "Restore from archive" : "Archive"}
            </button>
          )}
          {p.canDelete &&
            p.onDelete &&
            (arming !== "delete" ? (
              <button type="button" role="menuitem" onClick={() => setArming("delete")} className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-rose-700 hover:bg-rose-50">
                <Trash2 className="h-4 w-4" aria-hidden />
                Delete task
              </button>
            ) : (
              <div className="flex items-center gap-1 px-2 py-1.5" role="group" aria-label="Confirm delete">
                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    close();
                    p.onDelete?.();
                  }}
                  className="btn btn-danger btn-sm"
                >
                  <Trash2 className="h-3.5 w-3.5" aria-hidden />
                  Delete?
                </button>
                <button type="button" role="menuitem" onClick={() => setArming(null)} className="btn btn-ghost btn-sm">
                  Cancel
                </button>
              </div>
            ))}
          {!partTwo && p.moreUnavailable && (
            <p className="px-3 py-1 text-[11px] leading-snug text-amber-700" data-testid="more-unavailable">
              {p.moreUnavailable}
            </p>
          )}
          {p.onShare && (
            <div className="px-2 pb-2 pt-1">
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  close();
                  p.onShare?.();
                }}
                className="h-8 w-full rounded-md bg-violet-600 text-sm font-medium text-white hover:bg-violet-700"
              >
                Sharing &amp; Permissions
              </button>
            </div>
          )}
        </div>
      </AnchoredPopover>
    </>
  );
}
