// Copied from the reference CRM.
import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { portalRoot } from "../lib/portal-root";
import { Check, ChevronDown, Search } from "lucide-react";
import { cn } from "../lib/utils";
import { useOutsideClick } from "../lib/use-outside-click";
import type { TaskAssignee } from "../../../shared/crm/tasks-data";

/**
 * PICK A PERSON, BY NAME, WITH THEIR FACE.
 *
 * Asad, 2026-09-14: *"there should be a search option and all should come with
 * profile photos"*. What was here was a bare `<select>` over every enabled
 * profile — 127 of them, alphabetical, no photos and no way to type. Finding
 * someone meant scrolling a native dropdown past a hundred strangers.
 *
 * WHY A PORTAL AND NOT AN ABSOLUTE DROPDOWN. `.dlg-b` (the design-system stylesheet:562) is
 * `overflow-y:auto`, so a popover positioned inside the dialog body is clipped
 * by it — the list would be cut off at the panel edge. This mirrors the pattern
 * `date-picker-input.tsx` already uses: render to `document.body` and place it
 * with `position:fixed` from the trigger's rect, flipping up when there is no
 * room below.
 *
 * 🔴 THE POPOVER IS NEVER A FULL-BLEED INVISIBLE LAYER. On 2026-09-14 this app
 * spent three and a half months with an invisible `::-webkit-calendar-picker-
 * indicator` stretched over a whole dialog, swallowing every click on the page.
 * Nothing here is transparent-and-clickable: the trigger is a real `<button>`,
 * the list is a real list, and the only thing that closes it is a click that
 * genuinely lands outside.
 */

/**
 * The person's photo, or the healed initials the tasks module already computed.
 *
 * Flat props rather than a `TaskAssignee`, because a task row carries the same
 * three facts under different names (`assigneeInitials`, `assigneeColor`,
 * `assigneeAvatarUrl`) and should not have to rebuild an object to draw a face.
 *
 * `initials` + `color` are NOT a legacy path to be removed later: most of the
 * 127 profiles on this system have no photo at all, so the initials tile is the
 * common case and has to stay good.
 */
export function PersonAvatar({
  name,
  initials,
  color,
  avatarUrl,
  size,
}: {
  name?: string;
  initials: string;
  color: string;
  avatarUrl: string | null;
  size?: "xs" | "sm" | "lg";
}) {
  const cls = cn("avatar", size);
  // A profile can carry a photo URL that no longer resolves — a deleted upload,
  // an expired signed URL. A broken <img> paints NOTHING, so the person shows as
  // an empty circle: worse than the initials we already have. Fall back.
  const [broken, setBroken] = useState(false);
  if (avatarUrl && !broken) {
    // eslint-disable-next-line @next/next/no-img-element
    return (
      <img
        src={avatarUrl}
        alt={name ?? ""}
        className={cls}
        style={{ objectFit: "cover" }}
        onError={() => setBroken(true)}
      />
    );
  }
  return <span className={cn(cls, color)}>{initials}</span>;
}

/** The same face, from a TaskAssignee. */
function Face({ person, size }: { person: TaskAssignee; size?: "xs" | "sm" }) {
  return (
    <PersonAvatar
      name={person.name}
      initials={person.initials}
      color={person.color}
      avatarUrl={person.avatarUrl}
      size={size}
    />
  );
}

export function PersonPicker({
  people,
  value,
  onChange,
  emptyLabel = "Unassigned",
  allowUnassigned = false,
  disabled,
  id,
}: {
  people: TaskAssignee[];
  value: string;
  onChange: (id: string) => void;
  emptyLabel?: string;
  allowUnassigned?: boolean;
  disabled?: boolean;
  id?: string;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const [pos, setPos] = useState({ top: 0, left: 0, width: 0, flip: false });

  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const popRef = useRef<HTMLDivElement | null>(null);
  const searchRef = useRef<HTMLInputElement | null>(null);

  useOutsideClick([triggerRef, popRef], () => setOpen(false), open);

  const selected = people.find((p) => p.id === value) ?? null;

  const results = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return people;
    // Match on any word start as well as a plain substring, so "sam" finds
    // "Ali Sameer" and typing a surname works as well as a first name.
    return people.filter((p) => {
      const name = p.name.toLowerCase();
      return name.includes(q) || name.split(/\s+/).some((w) => w.startsWith(q));
    });
  }, [people, query]);

  function place() {
    const el = triggerRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const MAX = 320;
    const below = window.innerHeight - r.bottom;
    const flip = below < Math.min(MAX, 240) && r.top > below;
    setPos({
      top: flip ? Math.max(8, r.top - Math.min(MAX, r.top - 8) - 6) : r.bottom + 6,
      left: r.left,
      width: r.width,
      flip,
    });
  }

  function openList() {
    if (disabled) return;
    setQuery("");
    setActive(Math.max(0, results.findIndex((p) => p.id === value)));
    place();
    setOpen(true);
  }

  // Keep the popover glued to the trigger while the dialog body scrolls.
  useEffect(() => {
    if (!open) return;
    const onMove = () => place();
    window.addEventListener("scroll", onMove, true);
    window.addEventListener("resize", onMove);
    return () => {
      window.removeEventListener("scroll", onMove, true);
      window.removeEventListener("resize", onMove);
    };
  }, [open]);

  useEffect(() => {
    if (open) searchRef.current?.focus();
  }, [open]);

  function commit(personId: string) {
    onChange(personId);
    setOpen(false);
    triggerRef.current?.focus();
  }

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      setOpen(false);
      triggerRef.current?.focus();
      return;
    }
    const n = results.length + (allowUnassigned ? 1 : 0);
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setActive((i) => (n ? (i + 1) % n : 0));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((i) => (n ? (i - 1 + n) % n : 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (allowUnassigned && active === 0) return commit("");
      const pick = results[allowUnassigned ? active - 1 : active];
      if (pick) commit(pick.id);
    }
  }

  const rows: Array<{ key: string; id: string; node: React.ReactNode }> = [];
  if (allowUnassigned) {
    rows.push({
      key: "__none",
      id: "",
      node: (
        <>
          <span className="avatar sm bg-slate-300">—</span>
          <span className="flex-1 truncate text-slate-500">{emptyLabel}</span>
        </>
      ),
    });
  }
  for (const p of results) {
    rows.push({
      key: p.id,
      id: p.id,
      node: (
        <>
          <Face person={p} size="sm" />
          <span className="flex-1 truncate">{p.name}</span>
        </>
      ),
    });
  }

  return (
    <>
      <button
        id={id}
        ref={triggerRef}
        type="button"
        disabled={disabled}
        onClick={() => (open ? setOpen(false) : openList())}
        aria-haspopup="listbox"
        aria-expanded={open}
        className={cn(
          "w-full h-9 px-2 rounded-md border border-slate-200 bg-white text-sm text-left",
          "flex items-center gap-2 focus:outline-none focus:ring-2 focus:ring-blue-500",
          disabled && "bg-slate-50 text-slate-500 cursor-not-allowed",
        )}
      >
        {selected ? (
          <>
            <Face person={selected} size="xs" />
            <span className="flex-1 truncate">{selected.name}</span>
          </>
        ) : (
          <>
            <span className="avatar xs bg-slate-300">—</span>
            <span className="flex-1 truncate text-slate-500">{emptyLabel}</span>
          </>
        )}
        <ChevronDown className="h-4 w-4 shrink-0 text-slate-400" aria-hidden />
      </button>

      {open &&
        typeof window !== "undefined" &&
        createPortal(
          <div
            ref={popRef}
            role="listbox"
            aria-label="Choose a person"
            onKeyDown={onKeyDown}
            /* 🔴 z-[95], NOT z-[60]. The Dialog primitive renders at z-[90]
               (see components/ui/dialog.tsx, which documents the whole ladder),
               so a z-[60] popover opens BEHIND the dialog that owns it — the
               list is in the DOM and measurable, and invisible on screen. 95
               clears the dialog and still stays under the z-[100] reserved for
               route-progress / splash. */
            className="fixed z-[95] rounded-lg border border-slate-200 bg-white shadow-xl"
            style={{ top: pos.top, left: pos.left, width: Math.max(pos.width, 240) }}
          >
            <div className="flex items-center gap-2 border-b border-slate-100 px-2.5 py-2">
              <Search className="h-3.5 w-3.5 shrink-0 text-slate-400" aria-hidden />
              <input
                ref={searchRef}
                value={query}
                onChange={(e) => {
                  setQuery(e.target.value);
                  setActive(0);
                }}
                placeholder="Search people"
                aria-label="Search people"
                className="w-full bg-transparent text-sm outline-none placeholder:text-slate-400"
              />
            </div>
            <div className="max-h-64 overflow-y-auto py-1">
              {rows.length === 0 ? (
                // Says WHAT was searched — "no results" alone reads as a broken list.
                <p className="px-3 py-4 text-center text-xs text-slate-500">
                  Nobody matches “{query.trim()}”.
                </p>
              ) : (
                rows.map((r, i) => (
                  <button
                    key={r.key}
                    type="button"
                    role="option"
                    aria-selected={r.id === value}
                    onMouseEnter={() => setActive(i)}
                    onClick={() => commit(r.id)}
                    className={cn(
                      "flex w-full items-center gap-2 px-2.5 py-1.5 text-left text-sm",
                      i === active ? "bg-slate-100" : "bg-transparent",
                    )}
                  >
                    {r.node}
                    {r.id === value && <Check className="h-4 w-4 shrink-0 text-blue-600" aria-hidden />}
                  </button>
                ))
              )}
            </div>
          </div>,
          portalRoot(),
        )}
    </>
  );
}
