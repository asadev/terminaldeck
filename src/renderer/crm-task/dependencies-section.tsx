// Copied from the reference CRM.
import { useState } from "react";
import { Link2, Loader2, Search, X } from "lucide-react";
import { cn } from "./lib/utils";
import { Section } from "./section-shell";
import { MIN_TAG_QUERY, useTagSearch } from "./use-tag-search";
import {
  DEPENDENCY_KINDS,
  DEPENDENCY_LABELS,
  type DependencyKind,
  type TaskDependency,
} from "../../shared/crm/collab-types";

/**
 * DEPENDENCIES — how this task relates to another one.
 *
 * Drafts ops.task_dependencies. Three kinds (collab-types: blocked_by / blocks
 * / linked) shown as chips, and the other task found through the same
 * cross-CRM search the Related-to chips use (`area=task`), which is already
 * scoped to tasks the viewer may see — yours to do or yours to raise.
 *
 * Nothing is fetched until two characters are typed, and the same task cannot
 * be added twice under the same kind.
 */
export function DependenciesSection({
  rows,
  onChange,
  justAdded = false,
  initialKind,
}: {
  rows: TaskDependency[];
  onChange: (next: TaskDependency[]) => void;
  justAdded?: boolean;
  /** The task page's "Relate items" menu picked a kind: open the search on it at once. */
  initialKind?: DependencyKind;
}) {
  const [kind, setKind] = useState<DependencyKind>(initialKind ?? "blocked_by");
  const [query, setQuery] = useState("");
  const [adding, setAdding] = useState(!!initialKind || (justAdded && rows.length === 0));
  const { hits, busy, failed, tooShort } = useTagSearch("task", adding ? query : "");

  const taken = new Set(rows.map((r) => `${r.kind}:${r.otherTaskId}`));

  return (
    <Section title="Dependencies" aside={rows.length ? String(rows.length) : undefined} testId="dependencies-section">
      {rows.length > 0 && (
        <ul className="mb-1 space-y-0.5">
          {rows.map((r) => (
            <li key={`${r.kind}:${r.otherTaskId}`} className="group flex items-center gap-2 rounded-md px-1 py-1 hover:bg-slate-50">
              <span className="shrink-0 rounded-[4px] bg-slate-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-slate-600">
                {DEPENDENCY_LABELS[r.kind]}
              </span>
              <span className={cn("min-w-0 flex-1 truncate text-sm", r.otherDone ? "text-slate-400 line-through" : "text-slate-800")}>
                {r.otherTitle}
              </span>
              <button
                type="button"
                aria-label={`Remove dependency on "${r.otherTitle}"`}
                onClick={() => onChange(rows.filter((x) => !(x.kind === r.kind && x.otherTaskId === r.otherTaskId)))}
                className="shrink-0 rounded-full p-0.5 text-slate-300 opacity-0 transition-opacity hover:bg-slate-200 hover:text-slate-700 group-hover:opacity-100 focus:opacity-100"
              >
                <X className="h-3 w-3" />
              </button>
            </li>
          ))}
        </ul>
      )}

      {!adding ? (
        <button
          type="button"
          onClick={() => setAdding(true)}
          className="inline-flex h-7 items-center gap-1 rounded-md px-2 text-xs text-slate-500 hover:bg-slate-100 hover:text-slate-800"
        >
          <Link2 className="h-3.5 w-3.5" aria-hidden />
          Add dependency
        </button>
      ) : (
        <div className="rounded-md border border-slate-200">
          <div className="flex flex-wrap items-center gap-1 border-b border-slate-100 px-2 py-1.5">
            {DEPENDENCY_KINDS.map((k) => (
              <button
                key={k}
                type="button"
                onClick={() => setKind(k)}
                aria-pressed={kind === k}
                className={cn(
                  "rounded-[4px] px-2 py-0.5 text-[11px] font-medium transition-colors",
                  kind === k ? "bg-slate-900 text-white" : "text-slate-600 hover:bg-slate-100",
                )}
              >
                {DEPENDENCY_LABELS[k]}
              </button>
            ))}
            <button
              type="button"
              aria-label="Stop adding dependencies"
              onClick={() => { setAdding(false); setQuery(""); }}
              className="ml-auto rounded-full p-0.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700"
            >
              <X className="h-3 w-3" />
            </button>
          </div>
          <div className="flex items-center gap-2 border-b border-slate-100 px-2.5 py-1.5">
            <Search className="h-3.5 w-3.5 shrink-0 text-slate-400" aria-hidden />
            <input
              autoFocus
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                // Inside the New-item form: Enter must never press "Add task".
                if (e.key === "Enter") e.preventDefault();
              }}
              placeholder="Search your tasks"
              aria-label="Search tasks"
              className="w-full bg-transparent text-sm outline-none placeholder:text-slate-400"
            />
            {busy && <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-slate-400" aria-hidden />}
          </div>
          <div className="max-h-44 overflow-y-auto p-1">
            {failed ? (
              <p className="px-3 py-3 text-center text-xs text-rose-600">{failed}</p>
            ) : tooShort ? (
              <p className="px-3 py-3 text-center text-xs text-slate-500">Type at least {MIN_TAG_QUERY} characters.</p>
            ) : hits === null ? (
              <p className="px-3 py-3 text-center text-xs text-slate-500">Searching…</p>
            ) : hits.length === 0 ? (
              <p className="px-3 py-3 text-center text-xs text-slate-500">No task matches “{query.trim()}”.</p>
            ) : (
              hits.map((h) => {
                const already = taken.has(`${kind}:${h.id}`);
                return (
                  <button
                    key={h.id}
                    type="button"
                    disabled={already}
                    onClick={() =>
                      onChange([
                        ...rows,
                        { kind, otherTaskId: h.id, otherTitle: h.label, otherDone: h.status === "Done" },
                      ])
                    }
                    className={cn(
                      "flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-left",
                      already ? "opacity-45" : "hover:bg-slate-100",
                    )}
                  >
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-sm text-slate-800">{h.label}</span>
                      {h.secondary && <span className="block truncate text-xs text-slate-500">{h.secondary}</span>}
                    </span>
                    {h.status && (
                      <span className="shrink-0 rounded-md bg-slate-100 px-1.5 py-0.5 text-[10px] text-slate-600">{h.status}</span>
                    )}
                    {already && <span className="shrink-0 text-[10px] text-slate-500">Added</span>}
                  </button>
                );
              })
            )}
          </div>
        </div>
      )}
    </Section>
  );
}
