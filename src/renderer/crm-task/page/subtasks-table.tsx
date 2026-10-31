// Copied from the reference CRM.
import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowUpDown, CalendarDays, Check, ChevronDown, CircleDashed, Flag, Plus, X } from "lucide-react";
import { cn } from "../lib/utils";
import { AnchoredPopover } from "../anchored-popover";
import { RowAssignButton } from "../task-people-field";
import { relativeDay } from "../timeline-field";
import { assigneeFor, newSubtask } from "../task-collab-draft";
import type { SubtaskMeta } from "../../../shared/crm/task-page";
import type { TaskPeople, TaskSubtaskRow } from "../../../shared/crm/collab-types";
import type { TaskAssignee, TaskPriority } from "../../../shared/crm/tasks-data";

/**
 * CLICKUP'S SUBTASKS SECTION (inventory § 2.6): `▾ Subtasks  2 open ▬▬ [2 for
 * me]` · ⇅ Sort · + │ a table Name · Assignee · Priority · Due date, rows of
 * 35px with a status ring, and "+ Add Task" opening an inline row: ring ·
 * "Task Name or type '/' for commands" · Cancel · Save ↵ — Enter saves and
 * keeps the row open for the next one.
 *
 * Priority and Due date are columns of ops.task_subtasks from
 * migrations/2026-09-15-task-page.sql; until it is applied (`meta` null) the
 * table shows Name and Assignee only.
 */

const PRIORITIES: TaskPriority[] = ["Critical", "High", "Medium", "Low"];
const FLAG: Record<TaskPriority, string> = { Critical: "text-rose-600", High: "text-amber-500", Medium: "text-blue-600", Low: "text-slate-400" };
type SortKey = "manual" | "name" | "status" | "assignee" | "priority" | "due";
const SORTS: { key: SortKey; label: string; needsMeta?: boolean }[] = [
  { key: "manual", label: "Manual" },
  { key: "name", label: "Name" },
  { key: "status", label: "Status" },
  { key: "assignee", label: "Assignee" },
  { key: "priority", label: "Priority", needsMeta: true },
  { key: "due", label: "Due date", needsMeta: true },
];

export function progressBar(done: number, total: number) {
  return (
    <span className="inline-block h-1 w-12 overflow-hidden rounded-full bg-slate-200" aria-hidden>
      <span className="block h-full rounded-full bg-emerald-500" style={{ width: total ? `${Math.round((done / total) * 100)}%` : "0%" }} />
    </span>
  );
}

export function SubtasksTable({
  rows,
  people,
  team,
  meta,
  currentUserId,
  onChange,
  onMeta,
  justAdded = false,
}: {
  rows: TaskSubtaskRow[];
  people: TaskPeople;
  team: TaskAssignee[];
  /** Priority / due per subtask id; null = the columns are not there yet. */
  meta: Record<string, SubtaskMeta> | null;
  currentUserId: string;
  onChange: (next: TaskSubtaskRow[]) => void;
  onMeta: (subtaskId: string, patch: { priority?: TaskPriority | null; dueDate?: string | null }) => void;
  justAdded?: boolean;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const [sort, setSort] = useState<SortKey>("manual");
  const [adding, setAdding] = useState(justAdded && rows.length === 0);
  const sortRef = useRef<HTMLButtonElement | null>(null);
  const [sortOpen, setSortOpen] = useState(false);

  const open = rows.filter((r) => !r.done).length;
  const done = rows.length - open;
  const forMe = rows.filter((r) => !r.done && assigneeFor(r.assigneeUserId, people).person?.id === currentUserId).length;
  const withMeta = !!meta;

  const sorted = useMemo(() => {
    const out = [...rows];
    const m = (id: string) => meta?.[id];
    const name = (id: string | null) => (id ? team.find((p) => p.id === id)?.name ?? "" : "");
    switch (sort) {
      case "name":
        return out.sort((a, b) => a.title.localeCompare(b.title));
      case "status":
        return out.sort((a, b) => Number(a.done) - Number(b.done));
      case "assignee":
        return out.sort((a, b) => name(a.assigneeUserId).localeCompare(name(b.assigneeUserId)));
      case "priority":
        return out.sort((a, b) => PRIORITIES.indexOf(m(a.id)?.priority ?? ("~" as TaskPriority)) - PRIORITIES.indexOf(m(b.id)?.priority ?? ("~" as TaskPriority)));
      case "due":
        return out.sort((a, b) => (m(a.id)?.dueDate ?? "9999").localeCompare(m(b.id)?.dueDate ?? "9999"));
      default:
        return out;
    }
  }, [rows, sort, meta, team]);

  const cols = withMeta ? "grid-cols-[minmax(0,1fr)_96px_72px_104px_28px]" : "grid-cols-[minmax(0,1fr)_96px_28px]";

  return (
    <section data-testid="subtasks-section" aria-label="Subtasks">
      <header className="flex h-9 items-center gap-2">
        <button
          type="button"
          onClick={() => setCollapsed((c) => !c)}
          aria-expanded={!collapsed}
          aria-label={collapsed ? "Expand subtasks" : "Collapse subtasks"}
          className="grid h-5 w-5 place-content-center rounded text-slate-500 hover:bg-slate-100"
        >
          <ChevronDown className={cn("h-4 w-4 transition-transform", collapsed && "-rotate-90")} aria-hidden />
        </button>
        <h3 className="text-sm font-semibold text-slate-900">Subtasks</h3>
        {rows.length > 0 && (
          <>
            <span className="text-sm text-slate-500">{open} open</span>
            {progressBar(done, rows.length)}
          </>
        )}
        {forMe > 0 && (
          <span className="rounded-full bg-violet-50 px-2 py-0.5 text-xs font-medium text-violet-700">{forMe} for me</span>
        )}
        <span className="ml-auto" />
        <button
          ref={sortRef}
          type="button"
          onClick={() => setSortOpen((o) => !o)}
          aria-expanded={sortOpen}
          aria-label="Sort subtasks"
          title="Sort"
          className="inline-flex h-7 items-center gap-1 rounded-md px-2 text-xs text-slate-500 hover:bg-slate-100 hover:text-slate-800"
        >
          <ArrowUpDown className="h-3.5 w-3.5" aria-hidden />
          {sort !== "manual" && SORTS.find((s) => s.key === sort)?.label}
        </button>
        <AnchoredPopover anchorRef={sortRef} open={sortOpen} onClose={() => setSortOpen(false)} label="Sort subtasks" width={180} align="right">
          <div role="menu">
            <div className="px-3 pb-1 pt-1.5 text-[11px] font-medium text-slate-500">Sort by</div>
            {SORTS.filter((s) => withMeta || !s.needsMeta).map((s) => (
              <button
                key={s.key}
                type="button"
                role="menuitemradio"
                aria-checked={sort === s.key}
                onClick={() => {
                  setSort(s.key);
                  setSortOpen(false);
                }}
                className="flex w-full items-center px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50"
              >
                <span className="flex-1">{s.label}</span>
                {sort === s.key && <Check className="h-3.5 w-3.5 text-violet-600" aria-hidden />}
              </button>
            ))}
          </div>
        </AnchoredPopover>
        <button type="button" onClick={() => setAdding(true)} aria-label="New subtask" title="Add subtask" className="grid h-7 w-7 place-content-center rounded-md text-slate-500 hover:bg-slate-100 hover:text-slate-800">
          <Plus className="h-4 w-4" aria-hidden />
        </button>
      </header>

      {!collapsed && (
        <div role="table" aria-label="Subtasks" className="mt-1 text-sm">
          <div role="row" className={cn("grid h-8 items-center border-b border-slate-200 px-2 text-xs text-slate-500", cols)}>
            <span role="columnheader">Name</span>
            <span role="columnheader">Assignee</span>
            {withMeta && <span role="columnheader">Priority</span>}
            {withMeta && <span role="columnheader">Due date</span>}
            <span aria-hidden />
          </div>
          {sorted.map((r) => (
            <div key={r.id} role="row" className={cn("group grid h-[35px] items-center border-b border-slate-100 px-2 hover:bg-slate-50", cols)}>
              <span role="cell" className="flex min-w-0 items-center gap-2">
                <button
                  type="button"
                  role="checkbox"
                  aria-checked={r.done}
                  aria-label={`Mark "${r.title}" ${r.done ? "not done" : "done"}`}
                  onClick={() => onChange(rows.map((x) => (x.id === r.id ? { ...x, done: !r.done } : x)))}
                  className="grid h-4 w-4 shrink-0 place-content-center"
                >
                  {r.done ? (
                    <span className="grid h-4 w-4 place-content-center rounded-full bg-emerald-600 text-white">
                      <Check className="h-2.5 w-2.5" aria-hidden />
                    </span>
                  ) : (
                    <CircleDashed className="h-4 w-4 text-slate-400" aria-hidden />
                  )}
                </button>
                <span className={cn("min-w-0 truncate", r.done ? "text-slate-400 line-through" : "text-slate-800")}>{r.title}</span>
              </span>
              <span role="cell">
                <RowAssignButton
                  value={r.assigneeUserId}
                  people={people}
                  team={team}
                  what={`subtask "${r.title}"`}
                  onChange={(id) => onChange(rows.map((x) => (x.id === r.id ? { ...x, assigneeUserId: id } : x)))}
                />
              </span>
              {withMeta && (
                <span role="cell">
                  <SubtaskPriority title={r.title} value={meta?.[r.id]?.priority ?? null} onChange={(p) => onMeta(r.id, { priority: p })} />
                </span>
              )}
              {withMeta && (
                <span role="cell">
                  <SubtaskDue title={r.title} value={meta?.[r.id]?.dueDate ?? null} onChange={(d) => onMeta(r.id, { dueDate: d })} />
                </span>
              )}
              <span role="cell" className="flex justify-end">
                <button
                  type="button"
                  aria-label={`Remove subtask "${r.title}"`}
                  onClick={() => onChange(rows.filter((x) => x.id !== r.id))}
                  className="rounded p-0.5 text-slate-300 opacity-0 hover:bg-slate-200 hover:text-slate-700 focus:opacity-100 group-hover:opacity-100"
                >
                  <X className="h-3.5 w-3.5" aria-hidden />
                </button>
              </span>
            </div>
          ))}
          {adding ? (
            <AddSubtaskRow
              onAdd={(title) => onChange([...rows, newSubtask(title)])}
              onCancel={() => setAdding(false)}
            />
          ) : (
            <button
              type="button"
              onClick={() => setAdding(true)}
              aria-label="Add subtask"
              className="flex h-[35px] w-full items-center gap-2 px-2 text-left text-sm text-slate-500 hover:bg-slate-50 hover:text-slate-800"
            >
              <Plus className="h-4 w-4" aria-hidden />
              Add Task
            </button>
          )}
        </div>
      )}
    </section>
  );
}

/** The inline "+ Add Task" row. Enter saves and keeps it open (ClickUp); Escape closes. Never submits a form. */
function AddSubtaskRow({ onAdd, onCancel }: { onAdd: (title: string) => void; onCancel: () => void }) {
  const [text, setText] = useState("");
  const ref = useRef<HTMLInputElement | null>(null);
  useEffect(() => ref.current?.focus(), []);
  const save = () => {
    const t = text.trim();
    if (!t) return;
    onAdd(t);
    setText("");
  };
  return (
    <div className="flex h-[35px] items-center gap-2 border-b border-slate-100 px-2">
      <CircleDashed className="h-4 w-4 shrink-0 text-slate-300" aria-hidden />
      <input
        ref={ref}
        value={text}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            save();
          } else if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            onCancel();
          }
        }}
        placeholder="Task Name or type '/' for commands"
        aria-label="Add subtask"
        maxLength={300}
        className="h-7 min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-slate-400"
      />
      <button type="button" onClick={onCancel} className="h-7 rounded-md px-2 text-xs text-slate-600 hover:bg-slate-100">
        Cancel
      </button>
      <button type="button" onClick={save} disabled={!text.trim()} className="h-7 rounded-md bg-violet-600 px-2.5 text-xs font-medium text-white disabled:opacity-40">
        Save ↵
      </button>
    </div>
  );
}

function SubtaskPriority({ title, value, onChange }: { title: string; value: TaskPriority | null; onChange: (p: TaskPriority | null) => void }) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  return (
    <>
      <button ref={ref} type="button" onClick={() => setOpen((o) => !o)} aria-label={`Priority of "${title}": ${value ?? "none"}`} className="grid h-7 w-7 place-content-center rounded hover:bg-slate-100">
        <Flag className={cn("h-4 w-4", value ? cn("fill-current", FLAG[value]) : "text-slate-300")} aria-hidden />
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Priority" width={180}>
        <div role="menu">
          {PRIORITIES.map((p) => (
            <button
              key={p}
              type="button"
              role="menuitemradio"
              aria-checked={value === p}
              onClick={() => {
                setOpen(false);
                onChange(p);
              }}
              className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50"
            >
              <Flag className={cn("h-3.5 w-3.5 fill-current", FLAG[p])} aria-hidden />
              {p}
            </button>
          ))}
          {value && (
            <button
              type="button"
              role="menuitem"
              onClick={() => {
                setOpen(false);
                onChange(null);
              }}
              className="w-full border-t border-slate-100 px-3 py-1.5 text-left text-sm text-slate-500 hover:bg-slate-50"
            >
              Clear
            </button>
          )}
        </div>
      </AnchoredPopover>
    </>
  );
}

function SubtaskDue({ title, value, onChange }: { title: string; value: string | null; onChange: (d: string | null) => void }) {
  return (
    <span className="relative inline-flex h-7 items-center">
      <span className={cn("pointer-events-none inline-flex items-center gap-1 text-xs", value ? "text-slate-700" : "text-slate-300")} aria-hidden>
        <CalendarDays className="h-3.5 w-3.5" />
        {value ? relativeDay(value) : null}
      </span>
      <input
        type="date"
        value={value ?? ""}
        onChange={(e) => onChange(e.target.value || null)}
        aria-label={`Due date of "${title}"`}
        className="absolute inset-0 cursor-pointer opacity-0"
      />
    </span>
  );
}
