// Copied from the reference CRM.
import { LABEL_COLORS, LABEL_TONE, type LabelColor } from "../../../shared/crm/task-more";
import { todayYmd } from "../../../shared/crm/local-time";
import { useEffect, useMemo, useRef, useState } from "react";
import { AlignLeft, CalendarDays, Check, ChevronDown, ChevronRight, CircleDot, Diamond, Loader2, Play, Plus, Square, X, Tag, MoreHorizontal, Trash2 } from "lucide-react";
import { cn } from "../lib/utils";
import { AnchoredPopover } from "../anchored-popover";
import { PersonAvatar } from "../people/person-picker";
import { STATUS_SOLID, StatusPill } from "../pill-select";
import {
  MAX_LABELS,
  STATUS_WORD,
  TASK_TYPES,
  TASK_TYPE_LABEL,
  formatClock,
  formatDuration,
  nextStatus,
  normalizeLabels,
  parseDuration,
  totalTracked,
  type TaskType,
  type TimeEntry,
  timeEntryDay,
  ymdMonthDay,
} from "../../../shared/crm/task-page";
import type { TaskAssignee, TaskStatus } from "../../../shared/crm/tasks-data";

/**
 * THE TASK PAGE'S PROPERTY CELLS — ClickUp's grid (inventory § 2.0): two
 * columns, 36px rows, a 152px label (icon + 14px grey) and a value cell that
 * greys on hover across its whole width. Status · Assignees / Dates · Priority
 * / Track time · Tags. Plus the "Task ⌄" type pill of the row above the title.
 */

export function Property({
  icon: Icon,
  label,
  children,
  testId,
}: {
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  children: React.ReactNode;
  testId?: string;
}) {
  return (
    <div className="grid min-h-9 grid-cols-[152px_minmax(0,1fr)] items-center" data-testid={testId}>
      <dt className="inline-flex items-center gap-2 text-sm text-slate-500">
        <Icon className="h-4 w-4 shrink-0 text-slate-400" aria-hidden />
        {label}
      </dt>
      <dd className="flex min-h-9 min-w-0 items-center rounded-md px-1.5 hover:bg-slate-100">{children}</dd>
    </div>
  );
}

/** "Unavailable" with the reason on hover — a control waiting on a migration, never one that pretends. */
export function Unavailable({ reason }: { reason: string }) {
  return (
    <span className="text-sm text-slate-400" title={reason} data-testid="cell-unavailable">
      Unavailable
    </span>
  );
}

// ── Status: [TO DO ▸] [✓] ───────────────────────────────────────────────────

export function StatusCell({
  value,
  statuses,
  canEdit,
  onChange,
}: {
  value: TaskStatus;
  statuses: readonly TaskStatus[];
  canEdit: boolean;
  onChange: (next: TaskStatus) => void;
}) {
  if (!canEdit) {
    return (
      <span
        className={cn("inline-flex h-7 items-center rounded-[5px] px-2.5 text-[11px] font-semibold text-white", STATUS_SOLID[value])}
        title="Only the main assignee or the person who raised this task can change its status"
        aria-label={`Status: ${value}`}
      >
        {STATUS_WORD[value]}
      </span>
    );
  }
  const next = nextStatus(value);
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className="inline-flex items-stretch">
        <StatusPill value={value} options={statuses} onChange={onChange} />
        {next && (
          <button
            type="button"
            onClick={() => onChange(next)}
            aria-label={`Next status: ${STATUS_WORD[next]}`}
            title={`Move to ${STATUS_WORD[next]}`}
            className={cn("-ml-1.5 grid h-7 w-5 place-content-center rounded-r-[5px] border-l border-black/10 text-white hover:opacity-90", STATUS_SOLID[value])}
          >
            <ChevronRight className="h-3 w-3" aria-hidden />
          </button>
        )}
      </span>
      {value !== "Done" && (
        <button
          type="button"
          onClick={() => onChange("Done")}
          aria-label="Mark complete"
          title="Mark complete"
          className="inline-grid h-7 w-7 place-content-center rounded-[5px] border border-slate-200 bg-white text-slate-500 hover:border-emerald-300 hover:text-emerald-600"
        >
          <Check className="h-4 w-4" aria-hidden />
        </button>
      )}
    </span>
  );
}

// ── the "Task ⌄" type pill ─────────────────────────────────────────────────

const TYPE_ICON: Record<TaskType, React.ComponentType<{ className?: string }>> = { task: CircleDot, milestone: Diamond };

export function TypePill({ value, canEdit, onChange }: { value: TaskType; canEdit: boolean; onChange: (t: TaskType) => void }) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const Icon = TYPE_ICON[value];
  return (
    <>
      <button
        ref={ref}
        type="button"
        disabled={!canEdit}
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={`Task type: ${TASK_TYPE_LABEL[value]}`}
        className="inline-flex h-[26px] items-center gap-1.5 rounded-md border border-slate-200 bg-white px-2 text-[13px] text-slate-700 hover:bg-slate-50 disabled:cursor-default disabled:hover:bg-white"
      >
        <Icon className="h-3.5 w-3.5 text-slate-500" aria-hidden />
        {TASK_TYPE_LABEL[value]}
        {canEdit && <ChevronDown className="h-3 w-3 text-slate-400" aria-hidden />}
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Task type" width={200}>
        <div role="menu">
          <div className="px-3 pb-1 pt-1.5 text-[11px] font-medium text-slate-500">Task type</div>
          {TASK_TYPES.map((t) => {
            const I = TYPE_ICON[t];
            return (
              <button
                key={t}
                type="button"
                role="menuitemradio"
                aria-checked={t === value}
                onClick={() => {
                  setOpen(false);
                  if (t !== value) onChange(t);
                }}
                className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50"
              >
                <I className="h-4 w-4 text-slate-500" aria-hidden />
                <span className="flex-1">{TASK_TYPE_LABEL[t]}</span>
                {t === value && <Check className="h-3.5 w-3.5 text-violet-600" aria-hidden />}
              </button>
            );
          })}
        </div>
      </AnchoredPopover>
    </>
  );
}

// ── Track time ─────────────────────────────────────────────────────────────

/** What a time action answers: null when it worked, the reason when it did not. */
type Outcome = Promise<string | null>;

/** local today — never the machine's (lib/tasks/local-time.ts). */
function todayIso(): string {
  return todayYmd();
}

/**
 * ClickUp's "▶ Start" cell and its "Time on this task" popover (inventory
 * § 2.3): whose time · "Enter time (ex: 3h 20m) or start timer" + the ▶ timer ·
 * the day · Notes · billable · Save — and, ours, the entries already on the
 * task and the time estimate. A running timer counts on the cell itself.
 */
export function TrackTimeCell({
  entries,
  estimateMinutes,
  me,
  team,
  canEditEstimate,
  onStart,
  onStop,
  onAdd,
  onDelete,
  onEstimate,
  entryTags,
}: {
  entries: TimeEntry[];
  estimateMinutes: number | null;
  me: TaskAssignee | null;
  team: TaskAssignee[];
  canEditEstimate: boolean;
  onStart: () => Outcome;
  onStop: () => Outcome;
  onAdd: (input: { seconds: number; date: string; note: string; billable: boolean; tags: string[] }) => Outcome;
  /** Each entry's tags (migrations/2026-09-15-task-page-2.sql); undefined = tags unavailable. */
  entryTags?: Record<string, string[]>;
  onDelete: (entryId: string) => Outcome;
  onEstimate: (minutes: number | null) => Outcome;
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  // "Now" is read only after mount: a running timer's count differs between the
  // server's render and the browser's, and React would throw the page's hydration away.
  const [now, setNow] = useState<number | null>(null);
  const running = entries.find((e) => e.userId === me?.id && !e.endedAt) ?? null;
  useEffect(() => {
    setNow(Date.now());
    if (!running) return;
    const t = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(t);
  }, [running]);
  const total = totalTracked(entries, new Date(now ?? 0));
  const elapsed = running && now !== null ? Math.max(0, Math.floor((now - new Date(running.startedAt).getTime()) / 1000)) : 0;

  const [text, setText] = useState("");
  const [date, setDate] = useState(todayIso);
  const [note, setNote] = useState("");
  const [billable, setBillable] = useState(false);
  const [newTags, setNewTags] = useState<string[]>([]);
  const [tagText, setTagText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const parsed = parseDuration(text);
  const byId = useMemo(() => new Map(team.map((p) => [p.id, p])), [team]);

  async function run(fn: () => Outcome, after?: () => void) {
    setBusy(true);
    setError(null);
    const err = await fn();
    setBusy(false);
    if (err) setError(err);
    else after?.();
  }

  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={running ? `Track time: running ${formatClock(elapsed)}` : total ? `Track time: ${formatDuration(total)}` : "Track time"}
        className="inline-flex h-7 items-center gap-1.5 rounded-md px-1 text-sm text-slate-500 hover:text-slate-800"
        data-testid="track-time"
      >
        {running ? (
          <>
            <span className="grid h-4 w-4 place-content-center rounded-full bg-rose-500 text-white">
              <Square className="h-2 w-2 fill-current" aria-hidden />
            </span>
            <span className="tabular-nums text-slate-800">{formatClock(elapsed)}</span>
          </>
        ) : (
          <>
            <span className={cn("grid h-4 w-4 place-content-center rounded-full", total ? "bg-slate-700 text-white" : "border border-slate-400 text-slate-500")}>
              <Play className="ml-px h-2 w-2 fill-current" aria-hidden />
            </span>
            <span className={cn(total && "text-slate-800")}>{total ? formatDuration(total) : "Start"}</span>
          </>
        )}
        {estimateMinutes !== null && <span className="text-xs text-slate-400">/ {formatDuration(estimateMinutes * 60)}</span>}
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Time on this task" width={486}>
        <div className="p-3" data-testid="time-popover">
          <div className="mb-2 flex items-center">
            <span className="flex-1 text-sm font-semibold text-slate-800">Time on this task</span>
            <span className="text-sm tabular-nums text-slate-600">{formatDuration(total)}</span>
          </div>
          <div className="rounded-lg border border-slate-200">
            <div className="flex items-center gap-2 border-b border-slate-100 px-3 py-2 text-sm text-slate-700">
              {me && <PersonAvatar name={me.name} initials={me.initials} color={me.color} avatarUrl={me.avatarUrl} size="xs" />}
              <span>{me?.name ?? "You"}</span>
            </div>
            <div className="flex items-center gap-2 px-3 py-2">
              <input
                value={text}
                onChange={(e) => setText(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    if (parsed && !busy) void run(() => onAdd({ seconds: parsed, date, note, billable, tags: newTags }), () => setText(""));
                  }
                }}
                placeholder="Enter time (ex: 3h 20m) or start timer"
                aria-label="Enter time"
                className="h-9 min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-slate-400"
              />
              <button
                type="button"
                disabled={busy}
                onClick={() => void run(running ? onStop : onStart)}
                aria-label={running ? "Stop timer" : "Start timer"}
                className={cn("grid h-8 w-8 shrink-0 place-content-center rounded-full text-white disabled:opacity-50", running ? "bg-rose-500" : "bg-violet-600")}
              >
                {running ? <Square className="h-3 w-3 fill-current" aria-hidden /> : <Play className="ml-0.5 h-3.5 w-3.5 fill-current" aria-hidden />}
              </button>
            </div>
            <label className="flex items-center gap-2 border-t border-slate-100 px-3 py-2 text-sm text-slate-600">
              <CalendarDays className="h-4 w-4 text-slate-400" aria-hidden />
              <input type="date" value={date} max={todayIso()} onChange={(e) => setDate(e.target.value || todayIso())} aria-label="Date" className="bg-transparent text-sm outline-none" />
            </label>
            <label className="flex items-start gap-2 border-t border-slate-100 px-3 py-2 text-sm text-slate-600">
              <AlignLeft className="mt-0.5 h-4 w-4 text-slate-400" aria-hidden />
              <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={1} maxLength={2000} placeholder="Notes" aria-label="Notes" className="min-h-6 flex-1 resize-none bg-transparent text-sm outline-none placeholder:text-slate-400" />
            </label>
            {entryTags && (
              <label className="flex flex-wrap items-center gap-1.5 border-t border-slate-100 px-3 py-2 text-sm text-slate-600">
                <Tag className="h-4 w-4 text-slate-400" aria-hidden />
                {newTags.map((t) => (
                  <span key={t} className="inline-flex items-center gap-0.5 rounded bg-slate-100 px-1.5 text-xs text-slate-700">
                    {t}
                    <button type="button" aria-label={`Remove time tag ${t}`} onClick={() => setNewTags((x) => x.filter((y) => y !== t))} className="text-slate-400 hover:text-slate-700">
                      <X className="h-3 w-3" aria-hidden />
                    </button>
                  </span>
                ))}
                <input
                  value={tagText}
                  onChange={(e) => setTagText(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key !== "Enter") return;
                    e.preventDefault();
                    const t = tagText.trim().slice(0, 40);
                    if (t && !newTags.includes(t) && newTags.length < 10) setNewTags((x) => [...x, t]);
                    setTagText("");
                  }}
                  placeholder="Add tags"
                  aria-label="Add time tags"
                  className="min-w-[6rem] flex-1 bg-transparent text-sm outline-none placeholder:text-slate-400"
                />
              </label>
            )}
          </div>
          <div className="mt-2 flex items-center gap-2">
            <button
              type="button"
              role="switch"
              aria-checked={billable}
              aria-label="Billable"
              onClick={() => setBillable((b) => !b)}
              className={cn("relative h-5 w-9 rounded-full transition-colors", billable ? "bg-violet-600" : "bg-slate-200")}
            >
              <span className={cn("absolute top-0.5 grid h-4 w-4 place-content-center rounded-full bg-white text-[9px] font-bold text-slate-500 shadow transition-all", billable ? "left-[18px]" : "left-0.5")}>$</span>
            </button>
            <span className="text-xs text-slate-500">Billable</span>
            <button
              type="button"
              disabled={!parsed || busy}
              onClick={() => parsed && void run(() => onAdd({ seconds: parsed, date, note, billable, tags: newTags }), () => {
                setText("");
                setNote("");
                setNewTags([]);
              })}
              className="ml-auto inline-flex h-8 items-center gap-1.5 rounded-md bg-violet-600 px-3 text-sm font-medium text-white hover:bg-violet-700 disabled:opacity-40"
            >
              {busy && <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden />}
              Save
            </button>
          </div>
          {text && !parsed && <p className="mt-1.5 text-xs text-amber-700">Type a time like 1h 30m, 45m or 2h.</p>}
          {error && (
            <p role="alert" className="mt-1.5 text-xs text-rose-600">
              {error}
            </p>
          )}
          {entries.length > 0 && (
            <ul className="mt-3 max-h-40 space-y-1 overflow-y-auto border-t border-slate-100 pt-2" aria-label="Time entries">
              {[...entries].reverse().map((e) => {
                const who = byId.get(e.userId);
                const mine = e.userId === me?.id;
                return (
                  <li key={e.id} className="group flex items-center gap-2 text-sm text-slate-700">
                    {who ? <PersonAvatar name={who.name} initials={who.initials} color={who.color} avatarUrl={who.avatarUrl} size="xs" /> : <span className="h-5 w-5" />}
                    <span className="w-16 tabular-nums">{e.endedAt ? formatDuration(e.seconds ?? 0) : "running"}</span>
                    <span className="text-xs text-slate-500">{ymdMonthDay(timeEntryDay(e))}</span>
                    <span className="min-w-0 flex-1 truncate text-xs text-slate-500">
                      {e.note}
                      {(entryTags?.[e.id] ?? []).map((t) => (
                        <span key={t} className="ml-1 rounded bg-slate-100 px-1 text-[10px] text-slate-600">
                          {t}
                        </span>
                      ))}
                    </span>
                    {e.billable && <span className="text-xs text-violet-600">$</span>}
                    {mine && e.endedAt && (
                      <button type="button" aria-label="Remove time entry" onClick={() => void run(() => onDelete(e.id))} className="rounded p-0.5 text-slate-300 opacity-0 hover:bg-slate-100 hover:text-slate-700 group-hover:opacity-100 focus:opacity-100">
                        <X className="h-3.5 w-3.5" aria-hidden />
                      </button>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
          <div className="mt-2 flex items-center gap-2 border-t border-slate-100 pt-2 text-sm">
            <span className="flex-1 text-slate-600">Time estimate</span>
            {canEditEstimate ? (
              <input
                key={estimateMinutes ?? "none"}
                defaultValue={estimateMinutes !== null ? formatDuration(estimateMinutes * 60) : ""}
                placeholder="e.g. 2h"
                aria-label="Time estimate"
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    (e.target as HTMLInputElement).blur();
                  }
                }}
                onBlur={(e) => {
                  const raw = e.target.value.trim();
                  const secs = raw ? parseDuration(raw) : null;
                  if (raw && secs === null) return;
                  const mins = secs === null ? null : Math.round(secs / 60);
                  if (mins !== estimateMinutes) void run(() => onEstimate(mins));
                }}
                className="h-7 w-24 rounded border border-slate-200 px-2 text-right text-sm"
              />
            ) : (
              <span className="text-slate-500">{estimateMinutes !== null ? formatDuration(estimateMinutes * 60) : "—"}</span>
            )}
          </div>
        </div>
      </AnchoredPopover>
    </>
  );
}

// ── Tags ───────────────────────────────────────────────────────────────────

/**
 * ClickUp's Tags (inventory § 2.5): grey chips; the popover "Search or add
 * tags…" creates one on Enter ("Create [x] ⏎"). Ours are the task's own
 * labels; the cross-CRM "Related to" records keep their own row.
 */
export function TagsCell({
  labels,
  canEdit,
  onChange,
  colors,
  onColor,
  onDeleteEverywhere,
}: {
  labels: string[];
  canEdit: boolean;
  onChange: (next: string[]) => void;
  /** Tag colours by lower-case name (migrations/2026-09-15-task-page-2.sql). */
  colors?: Record<string, LabelColor>;
  /** A tag's "Add color" (one colour per tag, everywhere). */
  onColor?: (label: string, color: LabelColor) => void;
  /** A tag's "Delete" — off every task the viewer may change; asks first. */
  onDeleteEverywhere?: (label: string) => void;
}) {
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [confirmDel, setConfirmDel] = useState(false);
  // Escape closes the tag's menu only — the Tags popover listens on document (capture), this on window.
  useEffect(() => {
    if (!menuFor) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      setMenuFor(null);
      setConfirmDel(false);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [menuFor]);
  const tone = (l: string) => LABEL_TONE[colors?.[l.toLowerCase()] ?? "grey"];
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const trimmed = q.trim();
  const exists = labels.some((l) => l.toLowerCase() === trimmed.toLowerCase());
  const add = () => {
    if (!trimmed || exists || labels.length >= MAX_LABELS) return;
    onChange(normalizeLabels([...labels, trimmed]));
    setQ("");
  };
  return (
    <>
      <button
        ref={ref}
        type="button"
        disabled={!canEdit}
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={labels.length ? `Tags: ${labels.join(", ")}` : "Tags"}
        className="flex min-h-7 min-w-0 flex-wrap items-center gap-1 rounded-md px-1 text-left disabled:cursor-default"
        data-testid="tags-cell"
      >
        {labels.length === 0 ? (
          <span className="text-sm text-slate-400">Empty</span>
        ) : (
          labels.map((l) => (
            <span key={l} className="inline-flex h-6 items-center rounded px-2 text-xs font-medium" style={{ background: tone(l).bg, color: tone(l).fg }}>
              {l}
            </span>
          ))
        )}
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Tags" width={280}>
        <div className="p-2">
          <div className="flex flex-wrap items-center gap-1 rounded-md border border-slate-200 px-2 py-1.5 focus-within:border-violet-500">
            {labels.map((l) => (
              <span key={l} className="inline-flex h-6 items-center gap-1 rounded pl-2 pr-1 text-xs" style={{ background: tone(l).bg, color: tone(l).fg }}>
                {l}
                {(onColor || onDeleteEverywhere) && (
                  <button
                    type="button"
                    aria-label={`Tag options: ${l}`}
                    aria-expanded={menuFor === l}
                    onClick={() => {
                      setMenuFor((m) => (m === l ? null : l));
                      setConfirmDel(false);
                    }}
                    className="rounded p-0.5 text-slate-500 hover:bg-white/70 hover:text-slate-800"
                  >
                    <MoreHorizontal className="h-3 w-3" aria-hidden />
                  </button>
                )}
                <button type="button" aria-label={`Remove tag ${l}`} onClick={() => onChange(labels.filter((x) => x !== l))} className="rounded p-0.5 text-slate-400 hover:bg-slate-200 hover:text-slate-700">
                  <X className="h-3 w-3" aria-hidden />
                </button>
              </span>
            ))}
            <input
              autoFocus
              value={q}
              onChange={(e) => setQ(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  add();
                } else if (e.key === "Backspace" && !q && labels.length) {
                  onChange(labels.slice(0, -1));
                }
              }}
              placeholder="Search or add tags..."
              aria-label="Search or add tags"
              maxLength={40}
              className="min-w-[8rem] flex-1 bg-transparent text-sm outline-none placeholder:text-slate-400"
            />
          </div>
          {menuFor && (
            <div className="mt-2 rounded-md border border-slate-200 p-2" role="group" aria-label={`Tag ${menuFor}`} data-testid="tag-menu">
              {onColor && (
                <>
                  <div className="mb-1 text-[11px] font-medium text-slate-500">Add color</div>
                  <div className="mb-2 flex flex-wrap gap-1.5">
                    {LABEL_COLORS.map((c) => {
                      const on = (colors?.[menuFor.toLowerCase()] ?? "grey") === c;
                      return (
                        <button
                          key={c}
                          type="button"
                          aria-label={`Colour ${c === "grey" ? "Light Grey" : c}`}
                          aria-pressed={on}
                          title={c === "grey" ? "Light Grey" : c}
                          onClick={() => onColor(menuFor, c)}
                          style={{ background: LABEL_TONE[c].dot }}
                          className={cn("h-5 w-5 rounded-full ring-offset-1", on && "ring-2 ring-slate-500")}
                        />
                      );
                    })}
                  </div>
                </>
              )}
              {onDeleteEverywhere &&
                (!confirmDel ? (
                  <button type="button" onClick={() => setConfirmDel(true)} className="flex w-full items-center gap-2 rounded px-1 py-1 text-left text-sm text-rose-700 hover:bg-rose-50">
                    <Trash2 className="h-3.5 w-3.5" aria-hidden />
                    Delete
                  </button>
                ) : (
                  <div role="alertdialog" aria-label="Delete tag" className="space-y-1.5">
                    <p className="text-xs text-slate-700">
                      Are you sure you want to delete the <b>{menuFor}</b> tag everywhere? It comes off every task you can change.
                    </p>
                    <div className="flex gap-1">
                      <button
                        type="button"
                        onClick={() => {
                          const t = menuFor;
                          setMenuFor(null);
                          setConfirmDel(false);
                          onDeleteEverywhere(t);
                        }}
                        className="btn btn-danger btn-sm"
                      >
                        Delete
                      </button>
                      <button type="button" onClick={() => setConfirmDel(false)} className="btn btn-ghost btn-sm">
                        Cancel
                      </button>
                    </div>
                  </div>
                ))}
            </div>
          )}
          <div className="px-1 pb-1 pt-2 text-[11px] text-slate-500">{labels.length ? "On this task" : "Select an option"}</div>
          {trimmed && !exists ? (
            <button type="button" onClick={add} disabled={labels.length >= MAX_LABELS} className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-40">
              <Plus className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              Create <span className="rounded bg-slate-100 px-1.5 text-xs font-medium">{trimmed}</span>
              <span className="ml-auto text-xs text-slate-400">⏎</span>
            </button>
          ) : labels.length === 0 ? (
            <p className="px-2 py-1.5 text-xs text-slate-400">No tags created</p>
          ) : null}
        </div>
      </AnchoredPopover>
    </>
  );
}
