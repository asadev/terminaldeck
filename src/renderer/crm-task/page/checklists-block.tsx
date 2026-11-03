// Copied from the reference CRM.
import { useState } from "react";
import { Check, ChevronDown, Plus, X } from "lucide-react";
import { cn } from "../lib/utils";
import { InlineAdd } from "../section-shell";
import { RowAssignButton } from "../task-people-field";
import { progressBar } from "./subtasks-table";
import { newChecklist, newChecklistItem } from "../task-collab-draft";
import type { TaskChecklist, TaskPeople } from "../../../shared/crm/collab-types";
import type { TaskAssignee } from "../../../shared/crm/tasks-data";

/**
 * CLICKUP'S CHECKLISTS SECTION (inventory § 2.6): `▾ Checklists  2 open ▬` · +
 * │ one bordered card per checklist, its title editable in place, item rows
 * `○ text … 👤`, "+ Add item" (Enter adds and keeps typing), and under the
 * cards "+ Add checklist".
 */
export function ChecklistsBlock({
  lists,
  people,
  team,
  onChange,
  justAdded = false,
}: {
  lists: TaskChecklist[];
  people: TaskPeople;
  team: TaskAssignee[];
  onChange: (next: TaskChecklist[]) => void;
  justAdded?: boolean;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const items = lists.flatMap((l) => l.items);
  const open = items.filter((i) => !i.done).length;
  const patch = (id: string, fn: (l: TaskChecklist) => TaskChecklist) => onChange(lists.map((l) => (l.id === id ? fn(l) : l)));
  const addList = () => onChange([...lists, newChecklist(lists.length ? `Checklist ${lists.length + 1}` : "Checklist")]);

  return (
    <section data-testid="checklist-section" aria-label="Checklists">
      <header className="flex h-9 items-center gap-2">
        <button
          type="button"
          onClick={() => setCollapsed((c) => !c)}
          aria-expanded={!collapsed}
          aria-label={collapsed ? "Expand checklists" : "Collapse checklists"}
          className="grid h-5 w-5 place-content-center rounded text-slate-500 hover:bg-slate-100"
        >
          <ChevronDown className={cn("h-4 w-4 transition-transform", collapsed && "-rotate-90")} aria-hidden />
        </button>
        <h3 className="text-sm font-semibold text-slate-900">Checklists</h3>
        {items.length > 0 && (
          <>
            <span className="text-sm text-slate-500">{open} open</span>
            {progressBar(items.length - open, items.length)}
          </>
        )}
        <button type="button" onClick={addList} aria-label="New checklist" title="Add checklist" className="ml-auto grid h-7 w-7 place-content-center rounded-md text-slate-500 hover:bg-slate-100 hover:text-slate-800">
          <Plus className="h-4 w-4" aria-hidden />
        </button>
      </header>
      {!collapsed && (
        <div className="mt-1 space-y-2">
          {lists.map((list, li) => (
            <div key={list.id} className="rounded-lg border border-slate-200 bg-white px-3 py-2" data-testid="checklist">
              <div className="flex items-center gap-2">
                <input
                  value={list.title}
                  onChange={(e) => patch(list.id, (l) => ({ ...l, title: e.target.value }))}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") e.preventDefault();
                  }}
                  aria-label="Checklist name"
                  maxLength={120}
                  className="h-7 min-w-0 flex-1 rounded bg-transparent px-1 text-sm font-semibold text-slate-900 outline-none hover:bg-slate-50 focus:bg-white focus:ring-1 focus:ring-violet-500"
                />
                <button
                  type="button"
                  aria-label={`Remove checklist "${list.title}"`}
                  onClick={() => onChange(lists.filter((l) => l.id !== list.id))}
                  className="rounded p-0.5 text-slate-300 hover:bg-slate-100 hover:text-slate-700"
                >
                  <X className="h-3.5 w-3.5" aria-hidden />
                </button>
              </div>
              <ul className="mt-1">
                {list.items.map((it) => (
                  <li key={it.id} className="group flex h-[35px] items-center gap-2.5 px-1">
                    <button
                      type="button"
                      role="checkbox"
                      aria-checked={it.done}
                      aria-label={`Mark "${it.title}" ${it.done ? "not done" : "done"}`}
                      onClick={() => patch(list.id, (l) => ({ ...l, items: l.items.map((x) => (x.id === it.id ? { ...x, done: !it.done } : x)) }))}
                      className={cn(
                        "grid h-4 w-4 shrink-0 place-content-center rounded-full border",
                        it.done ? "border-emerald-600 bg-emerald-600 text-white" : "border-slate-400 hover:border-slate-600",
                      )}
                    >
                      {it.done && <Check className="h-2.5 w-2.5" aria-hidden />}
                    </button>
                    <span className={cn("min-w-0 flex-1 truncate text-sm", it.done ? "text-slate-400 line-through" : "text-slate-800")}>{it.title}</span>
                    <RowAssignButton
                      value={it.assigneeUserId}
                      people={people}
                      team={team}
                      what={`item "${it.title}"`}
                      onChange={(id) => patch(list.id, (l) => ({ ...l, items: l.items.map((x) => (x.id === it.id ? { ...x, assigneeUserId: id } : x)) }))}
                    />
                    <button
                      type="button"
                      aria-label={`Remove item "${it.title}"`}
                      onClick={() => patch(list.id, (l) => ({ ...l, items: l.items.filter((x) => x.id !== it.id) }))}
                      className="rounded p-0.5 text-slate-300 opacity-0 hover:bg-slate-200 hover:text-slate-700 focus:opacity-100 group-hover:opacity-100"
                    >
                      <X className="h-3.5 w-3.5" aria-hidden />
                    </button>
                  </li>
                ))}
              </ul>
              <InlineAdd
                label="Add item"
                placeholder="Item name"
                autoOpen={justAdded && li === 0 && list.items.length === 0}
                onAdd={(title) => patch(list.id, (l) => ({ ...l, items: [...l.items, newChecklistItem(title)] }))}
              />
            </div>
          ))}
          <button type="button" onClick={addList} className="inline-flex h-7 items-center gap-1.5 px-1 text-xs text-slate-500 hover:text-slate-800">
            <Plus className="h-3.5 w-3.5" aria-hidden />
            Add checklist
          </button>
        </div>
      )}
    </section>
  );
}
