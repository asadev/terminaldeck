// Copied from the reference CRM.
import { useEffect, useRef, useState } from "react";
import { Loader2, Search } from "lucide-react";
import { cn } from "./lib/utils";
import { PersonAvatar } from "./people/person-picker";
import { assigneeFromHit } from "./task-collab-draft";
import { useTagSearch } from "./use-tag-search";
import type { TaskAssignee } from "../../shared/crm/tasks-data";

/**
 * SEARCH THE PEOPLE — the list body inside every "assign" popover.
 *
 * Asad, 2026-09-14: *"there should be a search option and all should come with
 * profile photos"*, and the assignment control is *"a small avatar + button
 * that searches people"* — never a labelled "Assigned to" field.
 *
 * TWO SOURCES, ONE LIST, AND THE ORDER MATTERS:
 *   1. the `team` we were already handed (listAssignableUsers) — filtered in
 *      the browser, so typing a colleague's name costs NO request and the list
 *      is never empty while a fetch is in flight;
 *   2. `/api/tags/search?area=person` — the cross-CRM search, for anyone the
 *      page's own list does not carry.
 * Team rows win on id: they carry the real photo, and a remote hit only has a
 * name to build initials from.
 */

function matches(name: string, q: string): boolean {
  const n = name.toLowerCase();
  // Word-start as well as substring, so "sam" finds "Ali Sameer" and a surname
  // works as well as a first name.
  return n.includes(q) || n.split(/\s+/).some((w) => w.startsWith(q));
}

export function PersonSearchList({
  team,
  onPick,
  isPicked,
  autoFocus = true,
  header,
}: {
  team: TaskAssignee[];
  onPick: (person: TaskAssignee) => void;
  /** Draws the "on task" mark and lets the caller decide what a second press means. */
  isPicked?: (id: string) => boolean;
  autoFocus?: boolean;
  /** Rendered above the search box — e.g. who is already on the task. */
  header?: React.ReactNode;
}) {
  const [query, setQuery] = useState("");
  const { hits, busy, failed } = useTagSearch("person", query);
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus();
  }, [autoFocus]);

  const q = query.trim().toLowerCase();
  const local = q ? team.filter((p) => matches(p.name, q)) : team;
  const remote = (hits ?? [])
    .filter((h) => !team.some((t) => t.id === h.id))
    .map((h) => assigneeFromHit({ id: h.id, label: h.label }));
  const rows = [...local, ...remote];

  return (
    <div className="w-full">
      {header}
      <div className="flex items-center gap-2 border-b border-slate-100 px-2.5 py-1.5">
        <Search className="h-3.5 w-3.5 shrink-0 text-slate-400" aria-hidden />
        <input
          ref={inputRef}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          // Enter inside a <form> submits it. This list lives inside the
          // New-item form, and "Add task" writes to the database — so Enter
          // here must never reach the form.
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              const first = rows[0];
              if (first) onPick(first);
            }
          }}
          placeholder="Search people"
          aria-label="Search people"
          className="w-full bg-transparent text-sm outline-none placeholder:text-slate-400"
        />
        {busy && <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-slate-400" aria-hidden />}
      </div>

      <div className="max-h-56 overflow-y-auto py-1">
        {failed && <p className="px-3 py-2 text-center text-xs text-rose-600">{failed}</p>}
        {rows.length === 0 && !failed ? (
          <p className="px-3 py-4 text-center text-xs text-slate-500">
            {q ? `Nobody matches “${query.trim()}”.` : "No people to show."}
          </p>
        ) : (
          rows.map((p) => {
            const picked = isPicked?.(p.id) ?? false;
            return (
              <button
                key={p.id}
                type="button"
                onClick={() => onPick(p)}
                aria-pressed={picked}
                // The name alone, not "AK Aisha Khan On task" — assistive tech
                // and tests both want the person, not the paint.
                aria-label={picked ? `${p.name} (on task)` : p.name}
                className={cn(
                  "flex w-full items-center gap-2 px-2.5 py-1.5 text-left text-sm",
                  picked ? "bg-slate-100 text-slate-900" : "text-slate-700 hover:bg-slate-50",
                )}
              >
                <PersonAvatar
                  name={p.name}
                  initials={p.initials}
                  color={p.color}
                  avatarUrl={p.avatarUrl}
                  size="sm"
                />
                <span className="flex-1 truncate">{p.name}</span>
                {picked && <span className="shrink-0 text-[10px] text-slate-500">On task</span>}
              </button>
            );
          })
        )}
      </div>
    </div>
  );
}
