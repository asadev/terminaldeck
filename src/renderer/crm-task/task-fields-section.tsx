// Copied from the reference CRM.
/**
 * THE TASK'S "Fields" SECTION — ClickUp's "+ Create new field", on one task.
 *
 * Asad, 2026-09-15, pointing at ClickUp's field-type picker: *"i need these
 * all"*. What ClickUp shows (docs/task-clickup-reference.md §1.5): a grey
 * "Fields" label, each field a row (icon · name · value), and a small grey
 * filled pill "+ Create new field" that opens a searchable, filterable list of
 * the field types with coloured icons; choosing one opens a short form — the
 * type switcher "Text ⌄" + × · Field name* · Cancel / Create, Create disabled
 * until named.
 *
 * Mount: `<TaskFieldsSection taskId={task.id} canEdit={canEditRow} team={team} />`.
 * The create box drafts the same thing before the task exists — see
 * task-fields-draft.tsx, which reuses every piece exported here.
 *
 * ── RULES THIS FILE KEEPS ──────────────────────────────────────────────────
 *  · OPTIMISTIC, AND HONEST. A value shows the moment it is chosen; a refusal
 *    puts the old value back and says why under the row.
 *  · FAIL SOFT. Until ops.task_fields exists the list read errors, and the
 *    section says "Fields unavailable: …" — never a crash, never an empty
 *    list pretending.
 *  · ENTER NEVER SUBMITS THE FORM AROUND US. The create box is a <form> whose
 *    submit writes a task; every key handler here calls preventDefault on
 *    Enter, and every button is type="button".
 *  · EVERY MENU IS AN AnchoredPopover (portalled, `.dialog-pop`), so nothing
 *    is clipped by `.dlg-b` and nothing is a full-bleed invisible layer.
 *  · NO GREY BORDERS ON CONTROLS. Inputs are filled wells with a focus ring.
 *    Colours that mean something (option colours, icon hues) are inline
 *    styles, which no class-substring dark-mode sweep can repaint.
 */

import { localParts } from "../../shared/crm/local-time";
import { useEffect, useMemo, useRef, useState, type ComponentType, type ReactNode } from "react";
import {
  AlignLeft,
  ArrowDown,
  ArrowUp,
  Banknote,
  Calendar,
  Check,
  ChevronDown,
  CircleChevronDown,
  ExternalLink,
  Gauge,
  Globe,
  Hash,
  ListTodo,
  Loader2,
  Mail,
  MapPin,
  MoreHorizontal,
  MousePointerClick,
  Paperclip,
  Pencil,
  Phone,
  Plus,
  Search,
  Settings2,
  Sigma,
  Signature,
  SlidersHorizontal,
  SquareCheck,
  Star,
  Tags,
  ThumbsUp,
  Trash2,
  Type,
  Upload,
  Users,
  Waypoints,
  X,
} from "lucide-react";
import { cn } from "./lib/utils";
// Local: a stored swatch is drawn in the app's colours.
import { appColour, appInk } from "./lib/app-colour";
import { AnchoredPopover } from "./anchored-popover";
import { PersonAvatar } from "./people/person-picker";
import { PersonSearchList } from "./person-search-list";
import { MIN_TAG_QUERY, useTagSearch } from "./use-tag-search";
import { DatePickerInput } from "./date-picker-input";
import { TAG_AREAS, isTagArea, tagAreaLabel, type TagAreaKey } from "../../shared/crm/tag-areas";
import { taskAttachmentHref } from "../../shared/crm/attachment-rules";
import type { TaskAttachment } from "../../shared/crm/collab-types";
import {
  BUTTON_STATUSES,
  BUTTON_TARGET_KINDS,
  CURRENCIES,
  FIELD_COLORS,
  FIELD_GROUPS,
  FIELD_TYPES,
  RATING_ICONS,
  autoProgressOf,
  computeFormula,
  defaultConfig,
  fieldTypeInfo,
  formatDateValue,
  formatMoney,
  formatNumber,
  hasOptions,
  manualPercent,
  mapHref,
  newFieldKey,
  normaliseConfig,
  normaliseFieldLabel,
  normaliseValue,
  numericValueOf,
  sameLabel,
  sortFields,
  type AutoProgress,
  type ButtonAction,
  type DateValue,
  type FieldConfig,
  type FieldGroup,
  type FieldKind,
  type FieldOption,
  type FileRef,
  type LocationValue,
  type RecordRef,
  type SignatureValue,
  type SiblingField,
  type TaskField,
  type TaskRef,
} from "../../shared/crm/task-fields";
import type { TaskAssignee, TaskStatus } from "../../shared/crm/tasks-data";

// ── the actions, injectable ─────────────────────────────────────────────────

type Fail = { ok: false; error: string };
export type FieldResult = { ok: true; field: TaskField } | Fail;
export type ListFieldsResult =
  | {
      ok: true;
      fields: TaskField[];
      /** Faces for every person a field names (People, signers, voters). */
      people: Record<string, TaskAssignee>;
      /** Subtask/checklist counts, when a Progress (Auto) field needs them. */
      auto: AutoProgress | null;
      viewerId: string;
    }
  | Fail;
export type UploadResult = { ok: true; attachment: TaskAttachment } | Fail;

/**
 * The CRM's field actions, as one injectable bundle (its default is its server
 * actions; here it is `local-actions.ts`'s `localFieldActions`).
 */
export type TaskFieldActions = {
  listTaskFields: (taskId: string) => Promise<ListFieldsResult>;
  createTaskField: (taskId: string, input: { label: string; kind: FieldKind; config?: unknown; value?: unknown }) => Promise<FieldResult>;
  updateTaskFieldValue: (fieldId: string, value: unknown) => Promise<FieldResult>;
  renameTaskField: (fieldId: string, label: string) => Promise<{ ok: true; field: TaskField; formulas: TaskField[] } | Fail>;
  updateTaskFieldConfig: (fieldId: string, config: unknown) => Promise<FieldResult>;
  reorderTaskFields: (taskId: string, orderedIds: string[]) => Promise<{ ok: true } | Fail>;
  deleteTaskField: (fieldId: string) => Promise<{ ok: true } | Fail>;
  toggleTaskFieldVote: (fieldId: string) => Promise<FieldResult>;
  pressTaskFieldButton: (fieldId: string) => Promise<{ ok: true; field: TaskField; target: TaskField | null; status: TaskStatus | null } | Fail>;
  /** The file's bytes to the task; the Files field keeps the row's id. */
  uploadTaskFile: (taskId: string, file: File) => Promise<UploadResult>;
};

// ── look ────────────────────────────────────────────────────────────────────

/** A value cell: flat until hovered, a well with a focus ring when typed in. */
const CELL =
  "h-7 w-full min-w-0 rounded-md border border-transparent bg-transparent px-2 text-[13px] text-[var(--text)] outline-none placeholder:text-[var(--text-3)] hover:bg-[var(--surface-3)] focus:border-[var(--primary)] focus:bg-[var(--surface)]";
/** A form control inside a popover: a filled well, no grey border. */
const WELL =
  "h-8 w-full min-w-0 rounded-md border border-transparent bg-[var(--surface-2)] px-2 text-[13px] text-[var(--text)] outline-none placeholder:text-[var(--text-3)] focus:border-[var(--primary)] focus:bg-[var(--surface)]";
const MENU_ROW =
  "flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-left text-[13px] text-[var(--text)] hover:bg-[var(--surface-3)] disabled:opacity-40 disabled:hover:bg-transparent";
const EMPTY = "text-[13px] text-[var(--text-3)]";

const KIND_ICON: Record<FieldKind, ComponentType<{ className?: string }>> = {
  dropdown: CircleChevronDown,
  text: Type,
  date: Calendar,
  long_text: AlignLeft,
  number: Hash,
  labels: Tags,
  checkbox: SquareCheck,
  // Banknote, not a dollar sign: AED-only rule (tests/unit/currency-aed.test.ts).
  money: Banknote,
  website: Globe,
  formula: Sigma,
  files: Paperclip,
  relationship: Waypoints,
  people: Users,
  progress_auto: Gauge,
  email: Mail,
  phone: Phone,
  tasks: ListTodo,
  location: MapPin,
  progress_manual: SlidersHorizontal,
  rating: Star,
  voting: ThumbsUp,
  signature: Signature,
  button: MousePointerClick,
};

/** The coloured icon tile each type wears — in the picker and on every row. */
export function FieldTypeIcon({ kind, size = 20 }: { kind: FieldKind; size?: number }) {
  const info = fieldTypeInfo(kind);
  const Icon = KIND_ICON[kind];
  return (
    <span
      aria-hidden
      data-kind-icon={kind}
      className="inline-grid shrink-0 place-items-center rounded-[5px]"
      style={{
        width: size,
        height: size,
        color: `var(${info.hue})`,
        background: `color-mix(in srgb, var(${info.hue}) 15%, transparent)`,
      }}
    >
      <Icon className="h-3.5 w-3.5" />
    </span>
  );
}

/** An option's chip: tinted with its own colour, inline so no sweep eats it. */
function OptionChip({ option, onRemove }: { option: FieldOption; onRemove?: () => void }) {
  return (
    <span
      className="inline-flex h-6 max-w-full items-center gap-1 rounded-[5px] px-2 text-xs font-medium"
      style={{ background: `color-mix(in srgb, ${appColour(option.color)} 18%, transparent)`, color: `color-mix(in srgb, ${appColour(option.color)} 70%, var(--text))` }}
    >
      <span className="truncate">{option.label}</span>
      {onRemove && (
        <button type="button" aria-label={`Remove ${option.label}`} onClick={onRemove} className="-mr-1 rounded p-0.5 hover:bg-black/10">
          <X className="h-3 w-3" />
        </button>
      )}
    </span>
  );
}

/** A link-ish chip (a file, a record, a task). */
function RefChip({ href, label, icon, onRemove, external }: { href?: string; label: string; icon?: ReactNode; onRemove?: () => void; external?: boolean }) {
  return (
    <span className="inline-flex h-6 max-w-[220px] items-center gap-1 rounded-[5px] bg-[var(--surface-3)] px-2 text-xs text-[var(--text)]">
      {icon}
      {href ? (
        <a href={href} target={external ? "_blank" : undefined} rel={external ? "noreferrer" : undefined} className="truncate hover:underline">
          {label}
        </a>
      ) : (
        <span className="truncate">{label}</span>
      )}
      {onRemove && (
        <button type="button" aria-label={`Remove ${label}`} onClick={onRemove} className="-mr-1 rounded p-0.5 text-[var(--text-3)] hover:bg-[var(--surface-2)] hover:text-[var(--text)]">
          <X className="h-3 w-3" />
        </button>
      )}
    </span>
  );
}

const stopEnter = (e: React.KeyboardEvent) => {
  if (e.key === "Enter") e.preventDefault();
};

// ── the editor context ─────────────────────────────────────────────────────

export type FieldCtx = {
  /** null while drafting in the create box — the task has no id yet. */
  taskId: string | null;
  /** Every field on the task, current (optimistic) values — formulas read these. */
  fields: readonly TaskField[];
  people: Record<string, TaskAssignee>;
  team: readonly TaskAssignee[];
  auto: AutoProgress | null;
  viewerId: string | null;
  readOnly: boolean;
  busy: ReadonlySet<string>;
  rememberPerson: (p: TaskAssignee) => void;
  onVote: (field: TaskField) => void;
  onPress: (field: TaskField) => void;
  onFiles: (field: TaskField, files: File[]) => void;
  /** Drafting only: files chosen before the task exists. */
  pendingFiles?: (field: TaskField) => File[];
  onRemovePending?: (field: TaskField, index: number) => void;
};

// ── small editors ──────────────────────────────────────────────────────────

/**
 * A text cell that saves on blur (and on Enter for one line). Escape puts the
 * saved value back. While not focused it shows the SAVED value (or its
 * formatted form), so an optimistic revert is visible at once.
 */
function TextCell({
  value,
  display,
  onCommit,
  readOnly,
  multiline,
  placeholder = "Empty",
  ariaLabel,
  inputMode,
  prefix,
}: {
  value: string;
  display?: string;
  onCommit: (next: string) => void;
  readOnly: boolean;
  multiline?: boolean;
  placeholder?: string;
  ariaLabel: string;
  inputMode?: "decimal" | "email" | "tel" | "url" | "text";
  prefix?: string;
}) {
  const [draft, setDraft] = useState(value);
  const [focused, setFocused] = useState(false);
  const cancel = useRef(false);
  const shown = focused ? draft : display ?? value;
  const common = {
    "aria-label": ariaLabel,
    value: shown,
    readOnly,
    placeholder: readOnly ? "—" : placeholder,
    onFocus: () => {
      setDraft(value);
      setFocused(true);
    },
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setDraft(e.target.value),
    onBlur: () => {
      setFocused(false);
      if (cancel.current) {
        cancel.current = false;
        return;
      }
      if (!readOnly && draft !== value) onCommit(draft);
    },
    onKeyDown: (e: React.KeyboardEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      if (e.key === "Enter" && !multiline) {
        e.preventDefault();
        e.currentTarget.blur();
      } else if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        cancel.current = true;
        e.currentTarget.blur();
      }
    },
  };
  return (
    <div className="flex min-w-0 flex-1 items-center">
      {prefix && <span className="pl-2 text-xs font-medium text-[var(--text-2)]">{prefix}</span>}
      {multiline ? (
        <textarea {...common} rows={Math.min(8, Math.max(1, shown.split("\n").length))} className={cn(CELL, "h-auto min-h-7 resize-y py-1 leading-5", readOnly && "hover:bg-transparent")} />
      ) : (
        <input {...common} inputMode={inputMode} className={cn(CELL, readOnly && "hover:bg-transparent")} />
      )}
    </div>
  );
}

function LinkOut({ href, label }: { href: string; label: string }) {
  return (
    <a href={href} target="_blank" rel="noreferrer" aria-label={label} title={label} className="grid h-6 w-6 shrink-0 place-items-center rounded-md text-[var(--text-2)] hover:bg-[var(--surface-3)] hover:text-[var(--primary)]">
      <ExternalLink className="h-3.5 w-3.5" />
    </a>
  );
}

function AddButton({ label, onClick, btnRef }: { label: string; onClick: () => void; btnRef?: React.RefObject<HTMLButtonElement | null> }) {
  return (
    <button
      ref={btnRef}
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
      className="grid h-6 w-6 shrink-0 place-items-center rounded-md text-[var(--text-3)] hover:bg-[var(--surface-3)] hover:text-[var(--text)]"
    >
      <Plus className="h-3.5 w-3.5" />
    </button>
  );
}

function ProgressBar({ percent, label }: { percent: number; label: string }) {
  return (
    <div className="flex min-w-0 flex-1 items-center gap-2 px-2" role="progressbar" aria-valuenow={percent} aria-valuemin={0} aria-valuemax={100} aria-label={label}>
      <div className="h-1.5 min-w-[60px] flex-1 overflow-hidden rounded-full bg-[var(--surface-3)]">
        <div className="h-full rounded-full" style={{ width: `${percent}%`, background: "var(--ok)" }} />
      </div>
      <span className="w-10 shrink-0 text-right text-xs tabular-nums text-[var(--text-2)]">{percent}%</span>
    </div>
  );
}

// ── choice editors ─────────────────────────────────────────────────────────

function DropdownEditor({ field, onCommit, readOnly }: { field: TaskField; onCommit: (v: unknown) => void; readOnly: boolean }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const ref = useRef<HTMLButtonElement | null>(null);
  const options = field.config.options ?? [];
  const current = options.find((o) => o.id === field.value) ?? null;
  const shown = q.trim() ? options.filter((o) => o.label.toLowerCase().includes(q.trim().toLowerCase())) : options;
  return (
    <>
      <button
        ref={ref}
        type="button"
        disabled={readOnly}
        onClick={() => setOpen((o) => !o)}
        aria-label={`${field.label}: ${current?.label ?? "Empty"}`}
        className="flex h-7 min-w-0 items-center gap-1 rounded-md px-1.5 text-left hover:bg-[var(--surface-3)] disabled:hover:bg-transparent"
      >
        {current ? <OptionChip option={current} /> : <span className={EMPTY}>{readOnly ? "—" : "Select option"}</span>}
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label={`${field.label} options`} width={240}>
        {options.length > 7 && (
          <div className="flex items-center gap-2 px-2.5 py-1.5">
            <Search className="h-3.5 w-3.5 text-[var(--text-3)]" aria-hidden />
            <input autoFocus value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={stopEnter} placeholder="Search…" aria-label="Search options" className="w-full bg-transparent text-[13px] outline-none" />
          </div>
        )}
        <div className="max-h-60 overflow-y-auto p-1">
          {options.length === 0 && <p className="px-2.5 py-2 text-xs text-[var(--text-2)]">No options yet — use ⋯ › Edit options to add some.</p>}
          {shown.map((o) => (
            <button
              key={o.id}
              type="button"
              className={MENU_ROW}
              onClick={() => {
                setOpen(false);
                onCommit(o.id === field.value ? null : o.id);
              }}
            >
              <OptionChip option={o} />
              {o.id === field.value && <Check className="ml-auto h-3.5 w-3.5 text-[var(--primary)]" />}
            </button>
          ))}
          {current && (
            <button type="button" className={cn(MENU_ROW, "text-[var(--text-2)]")} onClick={() => { setOpen(false); onCommit(null); }}>
              <X className="h-3.5 w-3.5" /> Clear
            </button>
          )}
        </div>
      </AnchoredPopover>
    </>
  );
}

function LabelsEditor({ field, onCommit, readOnly }: { field: TaskField; onCommit: (v: unknown) => void; readOnly: boolean }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLButtonElement | null>(null);
  const options = field.config.options ?? [];
  const picked = Array.isArray(field.value) ? (field.value as string[]) : [];
  const toggle = (id: string) => {
    const next = picked.includes(id) ? picked.filter((x) => x !== id) : [...picked, id];
    onCommit(next.length ? next : null);
  };
  return (
    <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1 px-1 py-0.5">
      {picked.map((id) => {
        const o = options.find((x) => x.id === id);
        return o ? <OptionChip key={id} option={o} onRemove={readOnly ? undefined : () => toggle(id)} /> : null;
      })}
      {!picked.length && readOnly && <span className={EMPTY}>—</span>}
      {!readOnly && (
        <>
          {picked.length ? <AddButton btnRef={ref} label={`Add ${field.label}`} onClick={() => setOpen((o) => !o)} /> : (
            <button ref={ref} type="button" onClick={() => setOpen((o) => !o)} className={cn("h-6 rounded-md px-1.5 hover:bg-[var(--surface-3)]", EMPTY)}>
              Select labels
            </button>
          )}
          <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label={`${field.label} labels`} width={240}>
            <div className="max-h-60 overflow-y-auto p-1">
              {options.length === 0 && <p className="px-2.5 py-2 text-xs text-[var(--text-2)]">No labels yet — use ⋯ › Edit options to add some.</p>}
              {options.map((o) => (
                <button key={o.id} type="button" role="menuitemcheckbox" aria-checked={picked.includes(o.id)} className={MENU_ROW} onClick={() => toggle(o.id)}>
                  <span className={cn("grid h-3.5 w-3.5 place-items-center rounded-[3px]", picked.includes(o.id) ? "bg-[var(--primary)] text-white" : "bg-[var(--surface-3)]")}>
                    {picked.includes(o.id) && <Check className="h-3 w-3" />}
                  </span>
                  <OptionChip option={o} />
                </button>
              ))}
            </div>
          </AnchoredPopover>
        </>
      )}
    </div>
  );
}

function RatingEditor({ field, onCommit, readOnly }: { field: TaskField; onCommit: (v: unknown) => void; readOnly: boolean }) {
  const max = field.config.max ?? 5;
  const glyph = RATING_ICONS.find((r) => r.key === field.config.icon)?.glyph ?? "★";
  const value = typeof field.value === "number" ? field.value : 0;
  const [hover, setHover] = useState(0);
  const lit = hover || value;
  return (
    <div className="flex items-center gap-0.5 px-1.5" onMouseLeave={() => setHover(0)} role="radiogroup" aria-label={field.label}>
      {Array.from({ length: max }, (_, i) => i + 1).map((n) => (
        <button
          key={n}
          type="button"
          role="radio"
          aria-checked={value === n}
          aria-label={`${n} of ${max}`}
          disabled={readOnly}
          onMouseEnter={() => !readOnly && setHover(n)}
          onClick={() => onCommit(n === value ? null : n)}
          className="text-base leading-none transition-transform hover:scale-110 disabled:hover:scale-100"
          style={{ color: n <= lit ? "var(--warn)" : "var(--line-2)", filter: glyph.length > 1 && n > lit ? "grayscale(1) opacity(.35)" : undefined }}
        >
          {glyph}
        </button>
      ))}
    </div>
  );
}

function PeopleEditor({ field, ctx, onCommit }: { field: TaskField; ctx: FieldCtx; onCommit: (v: unknown) => void }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLButtonElement | null>(null);
  const ids = Array.isArray(field.value) ? (field.value as string[]) : [];
  const face = (id: string) => ctx.people[id] ?? ctx.team.find((p) => p.id === id) ?? null;
  return (
    <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1 px-1.5 py-0.5">
      {ids.map((id) => {
        const p = face(id);
        return (
          <span key={id} className="inline-flex items-center gap-1 rounded-full bg-[var(--surface-3)] py-0.5 pl-0.5 pr-2 text-xs" title={p?.name ?? "Someone"}>
            {p ? <PersonAvatar name={p.name} initials={p.initials} color={p.color} avatarUrl={p.avatarUrl} size="xs" /> : null}
            <span className="max-w-[110px] truncate">{p?.name ?? "Someone"}</span>
            {!ctx.readOnly && (
              <button type="button" aria-label={`Remove ${p?.name ?? "person"}`} onClick={() => { const next = ids.filter((x) => x !== id); onCommit(next.length ? next : null); }} className="rounded-full p-0.5 text-[var(--text-3)] hover:text-[var(--text)]">
                <X className="h-3 w-3" />
              </button>
            )}
          </span>
        );
      })}
      {!ids.length && ctx.readOnly && <span className={EMPTY}>—</span>}
      {!ctx.readOnly && (
        <>
          {ids.length ? <AddButton btnRef={ref} label={`Add to ${field.label}`} onClick={() => setOpen((o) => !o)} /> : (
            <button ref={ref} type="button" onClick={() => setOpen((o) => !o)} className={cn("h-6 rounded-md px-1.5 hover:bg-[var(--surface-3)]", EMPTY)}>
              Add people
            </button>
          )}
          <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label={`${field.label} people`} width={260}>
            <PersonSearchList
              team={[...ctx.team]}
              isPicked={(id) => ids.includes(id)}
              onPick={(p) => {
                ctx.rememberPerson(p);
                const next = ids.includes(p.id) ? ids.filter((x) => x !== p.id) : [...ids, p.id];
                onCommit(next.length ? next : null);
              }}
            />
          </AnchoredPopover>
        </>
      )}
    </div>
  );
}

/** Search one or more CRM areas and pick a record — Relationship and Tasks. */
function RecordSearch({
  areas,
  excludeIds,
  onPick,
}: {
  areas: readonly TagAreaKey[];
  excludeIds: ReadonlySet<string>;
  onPick: (hit: { area: TagAreaKey; id: string; label: string; href: string; secondary?: string | null }) => void;
}) {
  const [area, setArea] = useState<TagAreaKey>(areas[0] ?? "listing");
  const [q, setQ] = useState("");
  const { hits, busy, failed, tooShort } = useTagSearch(area, q);
  return (
    <div>
      {areas.length > 1 && (
        <div className="flex flex-wrap gap-1 px-2 pt-1.5" role="tablist" aria-label="Where to search">
          {areas.map((a) => (
            <button
              key={a}
              type="button"
              role="tab"
              aria-selected={a === area}
              onClick={() => setArea(a)}
              className="chip h-7 px-2.5 text-xs"
            >
              {tagAreaLabel(a)}
            </button>
          ))}
        </div>
      )}
      <div className="flex items-center gap-2 px-2.5 py-1.5">
        <Search className="h-3.5 w-3.5 shrink-0 text-[var(--text-3)]" aria-hidden />
        <input autoFocus value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={stopEnter} placeholder={`Search ${tagAreaLabel(area).toLowerCase()}…`} aria-label={`Search ${tagAreaLabel(area)}`} className="w-full bg-transparent text-[13px] outline-none placeholder:text-[var(--text-3)]" />
        {busy && <Loader2 className="h-3.5 w-3.5 animate-spin text-[var(--text-3)]" aria-hidden />}
      </div>
      <div className="max-h-52 overflow-y-auto p-1">
        {failed ? (
          <p className="px-3 py-2 text-center text-xs text-[var(--danger-text)]">{failed}</p>
        ) : tooShort ? (
          <p className="px-3 py-2 text-center text-xs text-[var(--text-2)]">Type at least {MIN_TAG_QUERY} characters.</p>
        ) : hits === null ? (
          <p className="px-3 py-2 text-center text-xs text-[var(--text-2)]">Searching…</p>
        ) : hits.filter((h) => !excludeIds.has(h.id)).length === 0 ? (
          <p className="px-3 py-2 text-center text-xs text-[var(--text-2)]">Nothing matches “{q.trim()}”.</p>
        ) : (
          hits
            .filter((h) => !excludeIds.has(h.id))
            .map((h) => (
              <button key={`${h.area}:${h.id}`} type="button" className={MENU_ROW} onClick={() => onPick(h)}>
                <span className="min-w-0 flex-1">
                  <span className="block truncate">{h.label}</span>
                  {h.secondary && <span className="block truncate text-xs text-[var(--text-2)]">{h.secondary}</span>}
                </span>
                {h.status && <span className="shrink-0 rounded bg-[var(--surface-3)] px-1.5 py-0.5 text-[10px] text-[var(--text-2)]">{h.status}</span>}
              </button>
            ))
        )}
      </div>
    </div>
  );
}

function RelationshipEditor({ field, ctx, onCommit }: { field: TaskField; ctx: FieldCtx; onCommit: (v: unknown) => void }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLButtonElement | null>(null);
  const refs = Array.isArray(field.value) ? (field.value as RecordRef[]) : [];
  // Local: only the areas this computer has (a stored CRM area that is not one of them is left out).
  const configured = (field.config.areas ?? []).filter(isTagArea);
  const areas: TagAreaKey[] = configured.length ? configured : TAG_AREAS.map((a) => a.key);
  return (
    <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1 px-1.5 py-0.5">
      {refs.map((r) => (
        <RefChip
          key={`${r.area}:${r.id}`}
          href={r.href}
          label={r.label}
          icon={<span className="text-[10px] uppercase text-[var(--text-3)]">{tagAreaLabel(r.area)}</span>}
          onRemove={ctx.readOnly ? undefined : () => { const next = refs.filter((x) => !(x.area === r.area && x.id === r.id)); onCommit(next.length ? next : null); }}
        />
      ))}
      {!refs.length && ctx.readOnly && <span className={EMPTY}>—</span>}
      {!ctx.readOnly && (
        <>
          {refs.length ? <AddButton btnRef={ref} label={`Link to ${field.label}`} onClick={() => setOpen((o) => !o)} /> : (
            <button ref={ref} type="button" onClick={() => setOpen((o) => !o)} className={cn("h-6 rounded-md px-1.5 hover:bg-[var(--surface-3)]", EMPTY)}>
              Link a record
            </button>
          )}
          <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label={`${field.label} link`} width={300}>
            <RecordSearch
              areas={areas}
              excludeIds={new Set(refs.map((r) => r.id))}
              onPick={(h) => onCommit([...refs, { area: h.area, id: h.id, label: h.label, href: h.href }])}
            />
          </AnchoredPopover>
        </>
      )}
    </div>
  );
}

function TasksEditor({ field, ctx, onCommit }: { field: TaskField; ctx: FieldCtx; onCommit: (v: unknown) => void }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLButtonElement | null>(null);
  const refs = Array.isArray(field.value) ? (field.value as TaskRef[]) : [];
  const exclude = new Set([...refs.map((r) => r.id), ...(ctx.taskId ? [ctx.taskId] : [])]);
  return (
    <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1 px-1.5 py-0.5">
      {refs.map((r) => (
        <RefChip
          key={r.id}
          href={`/tasks?task=${encodeURIComponent(r.id)}`}
          label={r.label}
          icon={<ListTodo className="h-3 w-3 text-[var(--text-3)]" aria-hidden />}
          onRemove={ctx.readOnly ? undefined : () => { const next = refs.filter((x) => x.id !== r.id); onCommit(next.length ? next : null); }}
        />
      ))}
      {!refs.length && ctx.readOnly && <span className={EMPTY}>—</span>}
      {!ctx.readOnly && (
        <>
          {refs.length ? <AddButton btnRef={ref} label={`Link a task to ${field.label}`} onClick={() => setOpen((o) => !o)} /> : (
            <button ref={ref} type="button" onClick={() => setOpen((o) => !o)} className={cn("h-6 rounded-md px-1.5 hover:bg-[var(--surface-3)]", EMPTY)}>
              Link a task
            </button>
          )}
          <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label={`${field.label} tasks`} width={300}>
            <RecordSearch areas={["task"]} excludeIds={exclude} onPick={(h) => onCommit([...refs, { id: h.id, label: h.label }])} />
          </AnchoredPopover>
        </>
      )}
    </div>
  );
}

function FilesEditor({ field, ctx, onCommit }: { field: TaskField; ctx: FieldCtx; onCommit: (v: unknown) => void }) {
  const input = useRef<HTMLInputElement | null>(null);
  const refs = Array.isArray(field.value) ? (field.value as FileRef[]) : [];
  const pending = ctx.pendingFiles?.(field) ?? [];
  const busy = ctx.busy.has(field.id);
  return (
    <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1 px-1.5 py-0.5">
      {refs.map((f) => (
        <RefChip
          key={f.id}
          href={ctx.taskId ? taskAttachmentHref(ctx.taskId, f.id) : undefined}
          external
          label={f.name}
          icon={<Paperclip className="h-3 w-3 text-[var(--text-3)]" aria-hidden />}
          onRemove={ctx.readOnly ? undefined : () => { const next = refs.filter((x) => x.id !== f.id); onCommit(next.length ? next : null); }}
        />
      ))}
      {pending.map((f, i) => (
        <RefChip key={`p-${i}-${f.name}`} label={f.name} icon={<Paperclip className="h-3 w-3 text-[var(--text-3)]" aria-hidden />} onRemove={ctx.onRemovePending ? () => ctx.onRemovePending!(field, i) : undefined} />
      ))}
      {!refs.length && !pending.length && ctx.readOnly && <span className={EMPTY}>—</span>}
      {busy && <Loader2 className="h-3.5 w-3.5 animate-spin text-[var(--text-3)]" aria-label="Uploading" />}
      {!ctx.readOnly && (
        <>
          <button type="button" onClick={() => input.current?.click()} disabled={busy} className="inline-flex h-6 items-center gap-1 rounded-md px-1.5 text-xs text-[var(--text-2)] hover:bg-[var(--surface-3)] hover:text-[var(--text)]">
            <Upload className="h-3.5 w-3.5" aria-hidden /> Upload
          </button>
          <input
            ref={input}
            type="file"
            multiple
            hidden
            aria-label={`Upload to ${field.label}`}
            onChange={(e) => {
              const files = Array.from(e.target.files ?? []);
              e.target.value = "";
              if (files.length) ctx.onFiles(field, files);
            }}
          />
        </>
      )}
    </div>
  );
}

/**
 * Draw with a finger or a mouse, or type a name. Stored as a PNG data URL or
 * the typed text; WHO signed and WHEN are stamped by the server.
 */
function SignaturePad({ onSave, onCancel }: { onSave: (raw: { mode: "drawn"; dataUrl: string } | { mode: "typed"; text: string }) => void; onCancel: () => void }) {
  const [mode, setMode] = useState<"draw" | "type">("draw");
  const [text, setText] = useState("");
  const [inked, setInked] = useState(false);
  const canvas = useRef<HTMLCanvasElement | null>(null);
  const drawing = useRef(false);

  const point = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const c = canvas.current!;
    const r = c.getBoundingClientRect();
    return { x: ((e.clientX - r.left) * c.width) / (r.width || c.width), y: ((e.clientY - r.top) * c.height) / (r.height || c.height) };
  };
  const ctx2d = () => canvas.current?.getContext("2d") ?? null;

  return (
    <div className="p-2">
      <div className="mb-2 flex gap-1" role="tablist" aria-label="How to sign">
        {(["draw", "type"] as const).map((m) => (
          <button key={m} type="button" role="tab" aria-selected={mode === m} onClick={() => setMode(m)} className="chip h-7 px-2.5 text-xs">
            {m === "draw" ? "Draw" : "Type"}
          </button>
        ))}
      </div>
      {mode === "draw" ? (
        <canvas
          ref={canvas}
          width={560}
          height={200}
          aria-label="Draw your signature"
          className="h-[100px] w-full touch-none rounded-md bg-white"
          style={{ boxShadow: "inset 0 0 0 1px var(--line)" }}
          onPointerDown={(e) => {
            const g = ctx2d();
            if (!g) return;
            e.currentTarget.setPointerCapture?.(e.pointerId);
            drawing.current = true;
            const p = point(e);
            g.lineWidth = 3;
            g.lineCap = "round";
            g.lineJoin = "round";
            g.strokeStyle = appInk();
            g.beginPath();
            g.moveTo(p.x, p.y);
          }}
          onPointerMove={(e) => {
            if (!drawing.current) return;
            const g = ctx2d();
            if (!g) return;
            const p = point(e);
            g.lineTo(p.x, p.y);
            g.stroke();
            if (!inked) setInked(true);
          }}
          onPointerUp={() => (drawing.current = false)}
          onPointerLeave={() => (drawing.current = false)}
        />
      ) : (
        <input autoFocus value={text} onChange={(e) => setText(e.target.value)} onKeyDown={stopEnter} maxLength={80} placeholder="Type your full name" aria-label="Type your signature" className={cn(WELL, "h-10 font-serif text-lg italic")} />
      )}
      <div className="mt-2 flex items-center gap-2">
        {mode === "draw" && (
          <button type="button" className="btn btn-ghost btn-xs" onClick={() => { const g = ctx2d(); if (g && canvas.current) g.clearRect(0, 0, canvas.current.width, canvas.current.height); setInked(false); }}>
            Clear
          </button>
        )}
        <span className="ml-auto" />
        <button type="button" className="btn btn-ghost btn-xs" onClick={onCancel}>Cancel</button>
        <button
          type="button"
          className="btn btn-primary btn-xs"
          disabled={mode === "draw" ? !inked : !text.trim()}
          onClick={() => {
            if (mode === "type") onSave({ mode: "typed", text: text.trim() });
            else if (canvas.current) onSave({ mode: "drawn", dataUrl: canvas.current.toDataURL("image/png") });
          }}
        >
          Sign
        </button>
      </div>
    </div>
  );
}

function SignatureEditor({ field, ctx, onCommit }: { field: TaskField; ctx: FieldCtx; onCommit: (v: unknown) => void }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLButtonElement | null>(null);
  const sig = field.value as SignatureValue | null;
  if (sig) {
    const who = ctx.people[sig.by]?.name ?? (sig.by === ctx.viewerId ? "you" : null);
    // The local day it was signed — sig.at is an instant (UTC in the string).
    const when = sig.at ? formatDateValue({ date: localParts(sig.at)?.ymd ?? sig.at.slice(0, 10), time: null }) : "";
    return (
      <div className="flex min-w-0 flex-1 items-center gap-2 px-1.5">
        {sig.mode === "drawn" ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={sig.dataUrl} alt="Signature" className="h-9 rounded bg-white px-1" />
        ) : (
          <span className="font-serif text-base italic text-[var(--text)]">{sig.text}</span>
        )}
        <span className="truncate text-[11px] text-[var(--text-3)]">{[who && `by ${who}`, when].filter(Boolean).join(" · ")}</span>
        {!ctx.readOnly && (
          <button type="button" aria-label={`Clear ${field.label}`} onClick={() => onCommit(null)} className="ml-auto rounded p-0.5 text-[var(--text-3)] hover:bg-[var(--surface-3)] hover:text-[var(--text)]">
            <X className="h-3.5 w-3.5" />
          </button>
        )}
      </div>
    );
  }
  if (ctx.readOnly) return <span className={cn(EMPTY, "px-2")}>—</span>;
  return (
    <>
      <button ref={ref} type="button" onClick={() => setOpen((o) => !o)} className="inline-flex h-7 items-center gap-1.5 rounded-md px-2 text-[13px] text-[var(--text-2)] hover:bg-[var(--surface-3)] hover:text-[var(--text)]">
        <Signature className="h-3.5 w-3.5" aria-hidden /> Sign
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label={`Sign ${field.label}`} width={320}>
        <SignaturePad onCancel={() => setOpen(false)} onSave={(raw) => { setOpen(false); onCommit(raw); }} />
      </AnchoredPopover>
    </>
  );
}

function ProgressManualEditor({ field, onCommit, readOnly }: { field: TaskField; onCommit: (v: unknown) => void; readOnly: boolean }) {
  const start = field.config.start ?? 0;
  const end = field.config.end ?? 100;
  const saved = typeof field.value === "number" ? field.value : start;
  const [drag, setDrag] = useState<number | null>(null);
  const shown = drag ?? saved;
  const commit = () => {
    if (drag !== null && drag !== saved) onCommit(drag);
    setDrag(null);
  };
  return (
    <div className="flex min-w-0 flex-1 items-center gap-2 px-2">
      <input
        type="range"
        min={start}
        max={end}
        step={(end - start) / 100 >= 1 ? 1 : (end - start) / 100}
        value={shown}
        disabled={readOnly}
        aria-label={field.label}
        onChange={(e) => setDrag(Number(e.target.value))}
        onPointerUp={commit}
        onKeyUp={commit}
        onBlur={commit}
        className="h-1.5 min-w-[80px] flex-1 cursor-pointer accent-[var(--ok)]"
      />
      <span className="w-10 shrink-0 text-right text-xs tabular-nums text-[var(--text-2)]">{manualPercent(field.config, shown)}%</span>
    </div>
  );
}

function DateEditor({ field, onCommit, readOnly }: { field: TaskField; onCommit: (v: unknown) => void; readOnly: boolean }) {
  const v = field.value as DateValue | null;
  if (readOnly) return <span className={cn("px-2 text-[13px]", !v && EMPTY)}>{v ? formatDateValue(v) : "—"}</span>;
  return (
    <div className="flex min-w-0 flex-1 items-center gap-1.5 px-1">
      <DatePickerInput value={v?.date ?? ""} onChange={(iso) => onCommit(iso ? { date: iso, time: v?.time ?? null } : null)} ariaLabel={field.label} emptyLabel="Empty" />
      {field.config.includeTime && v && (
        <input
          type="time"
          aria-label={`${field.label} time`}
          defaultValue={v.time ?? ""}
          key={v.time ?? ""}
          onBlur={(e) => { const t = e.target.value || null; if (t !== v.time) onCommit({ date: v.date, time: t }); }}
          onKeyDown={stopEnter}
          className={cn(CELL, "w-[92px]")}
        />
      )}
      {v && (
        <button type="button" aria-label={`Clear ${field.label}`} onClick={() => onCommit(null)} className="rounded p-0.5 text-[var(--text-3)] hover:bg-[var(--surface-3)] hover:text-[var(--text)]">
          <X className="h-3.5 w-3.5" />
        </button>
      )}
    </div>
  );
}

// ── the value editor, per kind ─────────────────────────────────────────────

export function FieldValueEditor({ field, ctx, onCommit }: { field: TaskField; ctx: FieldCtx; onCommit: (value: unknown) => void }) {
  const ro = ctx.readOnly;
  const v = field.value;
  const str = typeof v === "string" ? v : "";
  switch (field.kind) {
    case "text":
      return <TextCell value={str} onCommit={onCommit} readOnly={ro} ariaLabel={field.label} />;
    case "long_text":
      return <TextCell value={str} onCommit={onCommit} readOnly={ro} ariaLabel={field.label} multiline placeholder="Write something…" />;
    case "number": {
      const d = field.config.decimals ?? 2;
      return <TextCell value={typeof v === "number" ? String(v) : ""} display={typeof v === "number" ? formatNumber(v, d) : ""} onCommit={onCommit} readOnly={ro} ariaLabel={field.label} inputMode="decimal" />;
    }
    case "money": {
      const d = field.config.decimals ?? 2;
      const cur = field.config.currency ?? "AED";
      return <TextCell prefix={cur} value={typeof v === "number" ? String(v) : ""} display={typeof v === "number" ? formatNumber(v, d, true) : ""} onCommit={onCommit} readOnly={ro} ariaLabel={field.label} inputMode="decimal" />;
    }
    case "website":
    case "email":
    case "phone": {
      const href = !str ? null : field.kind === "website" ? str : field.kind === "email" ? `mailto:${str}` : `tel:${str.replace(/[^\d+]/g, "")}`;
      return (
        <div className="flex min-w-0 flex-1 items-center">
          <TextCell value={str} onCommit={onCommit} readOnly={ro} ariaLabel={field.label} inputMode={field.kind === "website" ? "url" : field.kind === "email" ? "email" : "tel"} placeholder={field.kind === "website" ? "https://" : field.kind === "email" ? "name@example.com" : "+971 50 000 0000"} />
          {href && <LinkOut href={href} label={field.kind === "website" ? "Open link" : field.kind === "email" ? "Send email" : "Call"} />}
        </div>
      );
    }
    case "location": {
      const loc = v as LocationValue | null;
      return (
        <div className="flex min-w-0 flex-1 items-center">
          <TextCell value={loc?.text ?? ""} onCommit={(t) => onCommit(t)} readOnly={ro} ariaLabel={field.label} placeholder="Address or lat, lng" />
          {loc && <LinkOut href={mapHref(loc)} label="Open in Maps" />}
        </div>
      );
    }
    case "checkbox":
      return (
        <label className="flex h-7 items-center px-2">
          <input type="checkbox" checked={v === true} disabled={ro} onChange={(e) => onCommit(e.target.checked)} aria-label={field.label} className="h-4 w-4 cursor-pointer rounded accent-[var(--primary)]" />
        </label>
      );
    case "date":
      return <DateEditor field={field} onCommit={onCommit} readOnly={ro} />;
    case "dropdown":
      return <DropdownEditor field={field} onCommit={onCommit} readOnly={ro} />;
    case "labels":
      return <LabelsEditor field={field} onCommit={onCommit} readOnly={ro} />;
    case "rating":
      return <RatingEditor field={field} onCommit={onCommit} readOnly={ro} />;
    case "people":
      return <PeopleEditor field={field} ctx={ctx} onCommit={onCommit} />;
    case "relationship":
      return <RelationshipEditor field={field} ctx={ctx} onCommit={onCommit} />;
    case "tasks":
      return <TasksEditor field={field} ctx={ctx} onCommit={onCommit} />;
    case "files":
      return <FilesEditor field={field} ctx={ctx} onCommit={onCommit} />;
    case "signature":
      return <SignatureEditor field={field} ctx={ctx} onCommit={onCommit} />;
    case "progress_manual":
      return <ProgressManualEditor field={field} onCommit={onCommit} readOnly={ro} />;
    case "progress_auto": {
      if (!ctx.taskId) return <span className={cn(EMPTY, "px-2")}>Counted from subtasks and checklists once the task is saved</span>;
      const p = autoProgressOf(field.config, ctx.auto);
      return (
        <div className="flex min-w-0 flex-1 items-center" title={`${p.done} of ${p.total} done`}>
          <ProgressBar percent={p.percent} label={field.label} />
          <span className="shrink-0 pr-2 text-[11px] tabular-nums text-[var(--text-3)]">{p.done}/{p.total}</span>
        </div>
      );
    }
    case "formula": {
      const r = computeFormula(field.config.expression, ctx.fields.filter((f) => f.id !== field.id));
      if (!r.ok) return <span className="truncate px-2 text-xs text-[var(--danger-text)]" title={field.config.expression}>{r.error}</span>;
      const d = field.config.decimals ?? 2;
      return (
        <span className="px-2 text-[13px] tabular-nums text-[var(--text)]" title={field.config.expression}>
          {field.config.currency ? formatMoney(r.value, field.config.currency, d) : formatNumber(r.value, d)}
        </span>
      );
    }
    case "voting": {
      const votes = v && typeof v === "object" ? Object.keys((v as { votes?: object }).votes ?? {}) : [];
      const mine = !!ctx.viewerId && votes.includes(ctx.viewerId);
      const names = votes.map((id) => ctx.people[id]?.name ?? (id === ctx.viewerId ? "You" : "Someone")).join(", ");
      return (
        <button
          type="button"
          aria-pressed={mine}
          disabled={ro || ctx.busy.has(field.id)}
          title={names || "No votes yet"}
          onClick={() => ctx.onVote(field)}
          className={cn("mx-1.5 inline-flex h-7 items-center gap-1.5 rounded-full px-2.5 text-[13px] font-medium", mine ? "bg-[var(--primary-soft)] text-[var(--primary-active)]" : "bg-[var(--surface-3)] text-[var(--text-2)] hover:text-[var(--text)]")}
        >
          <ThumbsUp className="h-3.5 w-3.5" aria-hidden /> <span className="tabular-nums">{votes.length}</span>
        </button>
      );
    }
    case "button": {
      const count = v && typeof v === "object" ? (v as { count?: number }).count ?? 0 : 0;
      const disabled = ro || !ctx.taskId || ctx.busy.has(field.id);
      return (
        <div className="flex items-center gap-2 px-1.5">
          <button
            type="button"
            disabled={disabled}
            title={!ctx.taskId ? "Works once the task is created" : undefined}
            onClick={() => ctx.onPress(field)}
            className="inline-flex h-7 items-center gap-1.5 rounded-md px-3 text-xs font-semibold text-white shadow-sm hover:brightness-95 disabled:opacity-50"
            style={{ background: appColour(field.config.color) }}
          >
            {ctx.busy.has(field.id) && <Loader2 className="h-3 w-3 animate-spin" aria-hidden />}
            {field.config.label ?? "Button"}
          </button>
          {count > 0 && <span className="text-[11px] text-[var(--text-3)]">Pressed {count}×</span>}
        </div>
      );
    }
  }
}

// ── the type picker ────────────────────────────────────────────────────────

/** ClickUp's list: a search box, the "All" filter and its groups, then every type. */
export function FieldTypePicker({ onPick, current }: { onPick: (kind: FieldKind) => void; current?: FieldKind }) {
  const [q, setQ] = useState("");
  const [group, setGroup] = useState<FieldGroup | "all">("all");
  const needle = q.trim().toLowerCase();
  const shown = FIELD_TYPES.filter((t) => (group === "all" || t.group === group) && (!needle || t.name.toLowerCase().includes(needle) || t.hint.toLowerCase().includes(needle)));
  return (
    <div data-testid="field-type-picker">
      <div className="flex items-center gap-2 px-2.5 py-1.5">
        <Search className="h-3.5 w-3.5 shrink-0 text-[var(--text-3)]" aria-hidden />
        <input
          autoFocus
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              if (shown[0]) onPick(shown[0].kind);
            }
          }}
          placeholder="Search…"
          aria-label="Search field types"
          className="w-full bg-transparent text-[13px] outline-none placeholder:text-[var(--text-3)]"
        />
      </div>
      <div className="flex flex-wrap gap-1 px-2 pb-1.5" role="tablist" aria-label="Filter field types">
        {[{ key: "all" as const, label: "All" }, ...FIELD_GROUPS].map((g) => (
          <button
            key={g.key}
            type="button"
            role="tab"
            aria-selected={group === g.key}
            onClick={() => setGroup(g.key)}
            className="chip h-7 px-2.5 text-xs"
          >
            {g.label}
          </button>
        ))}
      </div>
      <div className="max-h-72 overflow-y-auto p-1" role="listbox" aria-label="Field types">
        {shown.length === 0 && <p className="px-3 py-3 text-center text-xs text-[var(--text-2)]">No field type matches “{q.trim()}”.</p>}
        {shown.map((t) => (
          <button key={t.kind} type="button" role="option" aria-selected={t.kind === current} data-kind={t.kind} onClick={() => onPick(t.kind)} className={MENU_ROW}>
            <FieldTypeIcon kind={t.kind} />
            <span className="min-w-0 flex-1">
              <span className="block truncate">{t.name}</span>
            </span>
            {t.kind === current && <Check className="h-3.5 w-3.5 text-[var(--primary)]" />}
          </button>
        ))}
      </div>
    </div>
  );
}

// ── type-specific settings ─────────────────────────────────────────────────

function Lbl({ children, htmlFor, req }: { children: ReactNode; htmlFor?: string; req?: boolean }) {
  return (
    <label htmlFor={htmlFor} className="mb-1 block text-xs font-medium text-[var(--text-2)]">
      {children}
      {req && <span className="text-[var(--danger)]"> *</span>}
    </label>
  );
}

function OptionsEditor({ options, onChange, noun }: { options: FieldOption[]; onChange: (next: FieldOption[]) => void; noun: string }) {
  const [adding, setAdding] = useState("");
  const [palette, setPalette] = useState<string | null>(null);
  const add = () => {
    const label = adding.replace(/\s+/g, " ").trim();
    if (!label || options.some((o) => sameLabel(o.label, label))) return;
    onChange([...options, { id: newFieldKey().slice(0, 36), label, color: FIELD_COLORS[options.length % FIELD_COLORS.length] }]);
    setAdding("");
  };
  return (
    <div>
      <Lbl>{noun === "label" ? "Labels" : "Options"}</Lbl>
      <div className="flex flex-col gap-1">
        {options.map((o, i) => (
          <div key={o.id}>
            <div className="flex items-center gap-1.5">
              <button type="button" aria-label={`Colour of ${o.label}`} onClick={() => setPalette(palette === o.id ? null : o.id)} className="h-4 w-4 shrink-0 rounded-full" style={{ background: appColour(o.color) }} />
              <input
                value={o.label}
                aria-label={`${noun} ${i + 1}`}
                maxLength={60}
                onKeyDown={stopEnter}
                onChange={(e) => onChange(options.map((x) => (x.id === o.id ? { ...x, label: e.target.value } : x)))}
                className={cn(WELL, "h-7")}
              />
              <button type="button" aria-label={`Remove ${o.label}`} onClick={() => onChange(options.filter((x) => x.id !== o.id))} className="rounded p-1 text-[var(--text-3)] hover:bg-[var(--surface-3)] hover:text-[var(--text)]">
                <X className="h-3.5 w-3.5" />
              </button>
            </div>
            {palette === o.id && (
              <div className="mt-1 flex flex-wrap gap-1 pl-5" role="radiogroup" aria-label={`Colours for ${o.label}`}>
                {FIELD_COLORS.map((c) => (
                  <button key={c} type="button" role="radio" aria-checked={o.color === c} aria-label={c} onClick={() => { onChange(options.map((x) => (x.id === o.id ? { ...x, color: c } : x))); setPalette(null); }} className="grid h-5 w-5 place-items-center rounded-full" style={{ background: appColour(c) }}>
                    {o.color === c && <Check className="h-3 w-3 text-white" />}
                  </button>
                ))}
              </div>
            )}
          </div>
        ))}
        <div className="flex items-center gap-1.5">
          <span className="h-4 w-4 shrink-0 rounded-full" style={{ background: appColour(FIELD_COLORS[options.length % FIELD_COLORS.length]), opacity: 0.5 }} />
          <input
            value={adding}
            onChange={(e) => setAdding(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                add();
              }
            }}
            onBlur={add}
            maxLength={60}
            placeholder={`Add ${noun}…`}
            aria-label={`New ${noun}`}
            className={cn(WELL, "h-7")}
          />
        </div>
      </div>
    </div>
  );
}

function Select<T extends string | number>({ value, options, onChange, label, id }: { value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; label: string; id?: string }) {
  return (
    <select id={id} aria-label={label} value={String(value)} onChange={(e) => { const hit = options.find((o) => String(o.value) === e.target.value); if (hit) onChange(hit.value); }} className={cn(WELL, "cursor-pointer")}>
      {options.map((o) => (
        <option key={String(o.value)} value={String(o.value)}>{o.label}</option>
      ))}
    </select>
  );
}

const DECIMALS = [0, 1, 2, 3, 4, 5, 6].map((n) => ({ value: n, label: n === 0 ? "Whole numbers" : `${n} decimal${n > 1 ? "s" : ""}` }));

/** A throwaway editing context for the Button's "set a field to…" value. */
function detachedCtx(base?: Partial<FieldCtx>): FieldCtx {
  return {
    taskId: null,
    fields: [],
    people: {},
    team: [],
    auto: null,
    viewerId: null,
    readOnly: false,
    busy: new Set(),
    rememberPerson: () => {},
    onVote: () => {},
    onPress: () => {},
    onFiles: () => {},
    ...base,
  };
}

/** Everything a type can be told, before and after it is created ("Edit options"). */
export function FieldConfigForm({
  kind,
  config,
  onChange,
  siblings,
  selfId,
  team = [],
}: {
  kind: FieldKind;
  config: FieldConfig;
  onChange: (next: FieldConfig) => void;
  siblings: readonly SiblingField[];
  /** The field being edited — never offered as its own button target. */
  selfId?: string;
  team?: readonly TaskAssignee[];
}) {
  const set = (patch: Partial<FieldConfig>) => onChange({ ...config, ...patch });
  switch (kind) {
    case "dropdown":
      return <OptionsEditor options={config.options ?? []} onChange={(options) => set({ options })} noun="option" />;
    case "labels":
      return <OptionsEditor options={config.options ?? []} onChange={(options) => set({ options })} noun="label" />;
    case "number":
      return (
        <div>
          <Lbl>Decimals</Lbl>
          <Select label="Decimals" value={config.decimals ?? 2} options={DECIMALS} onChange={(decimals) => set({ decimals })} />
        </div>
      );
    case "money":
      return (
        <div className="grid grid-cols-2 gap-2">
          <div>
            <Lbl>Currency</Lbl>
            <Select label="Currency" value={config.currency ?? "AED"} options={CURRENCIES.map((c) => ({ value: c, label: c }))} onChange={(currency) => set({ currency })} />
          </div>
          <div>
            <Lbl>Decimals</Lbl>
            <Select label="Decimals" value={config.decimals ?? 2} options={DECIMALS.slice(0, 5)} onChange={(decimals) => set({ decimals })} />
          </div>
        </div>
      );
    case "date":
      return (
        <label className="flex items-center gap-2 text-[13px] text-[var(--text)]">
          <input type="checkbox" checked={config.includeTime === true} onChange={(e) => set({ includeTime: e.target.checked })} className="h-4 w-4 accent-[var(--primary)]" />
          Include time
        </label>
      );
    case "rating":
      return (
        <div className="grid grid-cols-2 gap-2">
          <div>
            <Lbl>Out of</Lbl>
            <Select label="Rating maximum" value={config.max ?? 5} options={Array.from({ length: 10 }, (_, i) => ({ value: i + 1, label: String(i + 1) }))} onChange={(max) => set({ max })} />
          </div>
          <div>
            <Lbl>Icon</Lbl>
            <div className="flex gap-1" role="radiogroup" aria-label="Rating icon">
              {RATING_ICONS.map((r) => (
                <button key={r.key} type="button" role="radio" aria-checked={(config.icon ?? "star") === r.key} aria-label={r.label} onClick={() => set({ icon: r.key })} className={cn("grid h-8 w-8 place-items-center rounded-md text-base", (config.icon ?? "star") === r.key ? "bg-[var(--primary-soft)]" : "bg-[var(--surface-2)] hover:bg-[var(--surface-3)]")} style={{ color: "var(--warn)" }}>
                  {r.glyph}
                </button>
              ))}
            </div>
          </div>
        </div>
      );
    case "progress_manual":
      return (
        <div className="grid grid-cols-2 gap-2">
          <div>
            <Lbl htmlFor="pm-start">Start</Lbl>
            <input id="pm-start" type="number" value={config.start ?? 0} onKeyDown={stopEnter} onChange={(e) => set({ start: Number(e.target.value) })} className={WELL} />
          </div>
          <div>
            <Lbl htmlFor="pm-end">End</Lbl>
            <input id="pm-end" type="number" value={config.end ?? 100} onKeyDown={stopEnter} onChange={(e) => set({ end: Number(e.target.value) })} className={WELL} />
          </div>
        </div>
      );
    case "progress_auto":
      return (
        <div className="flex flex-col gap-1.5">
          <Lbl>Count</Lbl>
          <label className="flex items-center gap-2 text-[13px]">
            <input type="checkbox" checked={config.subtasks !== false} onChange={(e) => set({ subtasks: e.target.checked })} className="h-4 w-4 accent-[var(--primary)]" /> Subtasks
          </label>
          <label className="flex items-center gap-2 text-[13px]">
            <input type="checkbox" checked={config.checklists !== false} onChange={(e) => set({ checklists: e.target.checked })} className="h-4 w-4 accent-[var(--primary)]" /> Checklist items
          </label>
        </div>
      );
    case "formula": {
      const numeric = siblings.filter((s) => s.id !== selfId && numericValueOf({ ...s, value: 1 }).ok && s.kind !== "formula");
      const preview = config.expression ? computeFormula(config.expression, siblings.filter((s) => s.id !== selfId)) : null;
      return (
        <div className="flex flex-col gap-2">
          <div>
            <Lbl htmlFor="formula-expr">Formula</Lbl>
            <textarea id="formula-expr" value={config.expression ?? ""} onChange={(e) => set({ expression: e.target.value })} rows={2} maxLength={500} placeholder="{Price} * {Quantity}" className={cn(WELL, "h-auto py-1.5 font-mono text-xs")} />
            <p className="mt-1 text-[11px] leading-4 text-[var(--text-3)]">Fields in {"{braces}"} · + − * / % ( ) · round, min, max, abs, floor, ceil</p>
            {numeric.length > 0 && (
              <div className="mt-1 flex flex-wrap gap-1">
                {numeric.map((s) => (
                  <button key={s.id} type="button" onClick={() => set({ expression: `${(config.expression ?? "").trimEnd()} {${s.label}}`.trimStart() })} className="h-6 rounded-[5px] bg-[var(--surface-3)] px-1.5 text-[11px] text-[var(--text)] hover:bg-[var(--primary-soft)]">
                    {`{${s.label}}`}
                  </button>
                ))}
              </div>
            )}
            {preview && <p className={cn("mt-1 text-xs", preview.ok ? "text-[var(--text-2)]" : "text-[var(--danger-text)]")}>{preview.ok ? `= ${formatNumber(preview.value, config.decimals ?? 2)}` : preview.error}</p>}
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <Lbl>Show as</Lbl>
              <Select label="Show formula as" value={config.currency ?? ""} options={[{ value: "", label: "Number" }, ...CURRENCIES.map((c) => ({ value: c, label: c }))]} onChange={(c) => set({ currency: c || null })} />
            </div>
            <div>
              <Lbl>Decimals</Lbl>
              <Select label="Formula decimals" value={config.decimals ?? 2} options={DECIMALS} onChange={(decimals) => set({ decimals })} />
            </div>
          </div>
        </div>
      );
    }
    case "relationship": {
      const areas = config.areas ?? [];
      return (
        <div>
          <Lbl>Link to</Lbl>
          <div className="flex flex-wrap gap-1">
            {TAG_AREAS.map((a) => {
              const on = areas.includes(a.key);
              return (
                <button key={a.key} type="button" aria-pressed={on} onClick={() => set({ areas: on ? areas.filter((x) => x !== a.key) : [...areas, a.key] })} className="chip h-7 px-2.5 text-xs">
                  {a.label}
                </button>
              );
            })}
          </div>
          <p className="mt-1 text-[11px] text-[var(--text-3)]">{areas.length ? "Only these." : "None picked = anything in the CRM."}</p>
        </div>
      );
    }
    case "button": {
      const action: ButtonAction = config.action ?? { type: "status", status: "Done" };
      const targets = siblings.filter((s) => s.id !== selfId && BUTTON_TARGET_KINDS.includes(s.kind));
      const target = action.type === "field" ? targets.find((t) => t.id === action.fieldId) ?? null : null;
      return (
        <div className="flex flex-col gap-2">
          <div>
            <Lbl htmlFor="btn-label">Button label</Lbl>
            <input id="btn-label" value={config.label ?? ""} maxLength={40} onKeyDown={stopEnter} onChange={(e) => set({ label: e.target.value })} placeholder="Mark done" className={WELL} />
          </div>
          <div>
            <Lbl>Colour</Lbl>
            <div className="flex flex-wrap gap-1" role="radiogroup" aria-label="Button colour">
              {FIELD_COLORS.map((c) => (
                <button key={c} type="button" role="radio" aria-checked={config.color === c} aria-label={c} onClick={() => set({ color: c })} className="grid h-5 w-5 place-items-center rounded-full" style={{ background: appColour(c) }}>
                  {config.color === c && <Check className="h-3 w-3 text-white" />}
                </button>
              ))}
            </div>
          </div>
          <div>
            <Lbl>When pressed</Lbl>
            <Select
              label="Button action"
              value={action.type}
              options={[
                { value: "status", label: "Set the status" },
                { value: "field", label: "Set a field" },
                { value: "comment", label: "Add a comment" },
              ]}
              onChange={(type) =>
                set({
                  action:
                    type === "status" ? { type: "status", status: "Done" } : type === "comment" ? { type: "comment", body: "" } : { type: "field", fieldId: targets[0]?.id ?? "", value: null },
                })
              }
            />
          </div>
          {action.type === "status" && (
            <Select label="Status the button sets" value={action.status} options={BUTTON_STATUSES.map((s) => ({ value: s, label: s }))} onChange={(status: TaskStatus) => set({ action: { type: "status", status } })} />
          )}
          {action.type === "comment" && (
            <textarea aria-label="Comment the button adds" value={action.body} maxLength={2000} rows={2} onChange={(e) => set({ action: { type: "comment", body: e.target.value } })} placeholder="Comment to add…" className={cn(WELL, "h-auto py-1.5")} />
          )}
          {action.type === "field" &&
            (targets.length === 0 ? (
              <p className="text-xs text-[var(--text-2)]">Add a Text, Number, Money, Date, Checkbox, Dropdown, Labels, Rating, Progress, Website, Email, Phone or Location field first.</p>
            ) : (
              <>
                <Select label="Field the button sets" value={action.fieldId} options={[{ value: "", label: "Choose a field…" }, ...targets.map((t) => ({ value: t.id, label: t.label }))]} onChange={(fieldId) => set({ action: { type: "field", fieldId, value: null } })} />
                {target && (
                  <div className="rounded-md bg-[var(--surface-2)] py-0.5">
                    <FieldValueEditor
                      field={{ id: `btn-target-${target.id}`, taskId: "", label: `${target.label} value`, kind: target.kind, config: target.config, value: action.value ?? null, sortOrder: 0, createdBy: null, createdAt: "", updatedAt: null }}
                      ctx={detachedCtx({ team })}
                      onCommit={(raw) => {
                        const n = normaliseValue(target.kind, target.config, raw, { userId: "", now: "" });
                        set({ action: { type: "field", fieldId: target.id, value: n.ok ? n.value : raw } });
                      }}
                    />
                  </div>
                )}
              </>
            ))}
        </div>
      );
    }
    default:
      return null;
  }
}

// ── the create form ────────────────────────────────────────────────────────

/**
 * Pick a type, then name it: ClickUp's two steps. The type switcher on the
 * form goes back to the list without losing the name; × closes everything;
 * Create stays disabled until the name is valid.
 */
export function CreateFieldPanel({
  siblings,
  onCancel,
  onCreate,
  team = [],
}: {
  siblings: readonly SiblingField[];
  onCancel: () => void;
  /** Resolves to an error in words, or null when the field was made. */
  onCreate: (input: { label: string; kind: FieldKind; config: FieldConfig }) => Promise<string | null>;
  team?: readonly TaskAssignee[];
}) {
  const [step, setStep] = useState<"pick" | "form">("pick");
  const [kind, setKind] = useState<FieldKind>("text");
  const [label, setLabel] = useState("");
  const [config, setConfig] = useState<FieldConfig>(() => defaultConfig("text"));
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const nameOk = normaliseFieldLabel(label).ok;

  async function create() {
    const l = normaliseFieldLabel(label);
    if (!l.ok) return setError(l.error);
    if (siblings.some((s) => sameLabel(s.label, l.value))) return setError(`This task already has a field called “${l.value}”`);
    const c = normaliseConfig(kind, config, siblings);
    if (!c.ok) return setError(c.error);
    setSaving(true);
    setError(null);
    const err = await onCreate({ label: l.value, kind, config: c.value });
    setSaving(false);
    if (err) setError(err);
  }

  if (step === "pick") {
    return (
      <FieldTypePicker
        current={label ? kind : undefined}
        onPick={(k) => {
          if (k !== kind) setConfig(defaultConfig(k));
          setKind(k);
          setError(null);
          setStep("form");
        }}
      />
    );
  }

  const info = fieldTypeInfo(kind);
  return (
    <div className="flex flex-col gap-3 p-3" data-testid="create-field-form">
      <div className="flex items-center gap-2">
        <button type="button" onClick={() => setStep("pick")} aria-label={`Field type: ${info.name}. Change type`} className="inline-flex h-7 items-center gap-1.5 rounded-md bg-[var(--surface-2)] px-2 text-[13px] font-medium text-[var(--text)] hover:bg-[var(--surface-3)]">
          <FieldTypeIcon kind={kind} size={18} />
          {info.name}
          <ChevronDown className="h-3.5 w-3.5 text-[var(--text-2)]" aria-hidden />
        </button>
        <button type="button" aria-label="Close" onClick={onCancel} className="ml-auto rounded-md p-1 text-[var(--text-3)] hover:bg-[var(--surface-3)] hover:text-[var(--text)]">
          <X className="h-4 w-4" />
        </button>
      </div>
      <div>
        <Lbl htmlFor="new-field-name" req>Field name</Lbl>
        <input
          id="new-field-name"
          autoFocus
          value={label}
          maxLength={80}
          onChange={(e) => { setLabel(e.target.value); setError(null); }}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              if (nameOk && !saving) void create();
            }
          }}
          placeholder="Enter name…"
          className={WELL}
        />
      </div>
      <FieldConfigForm kind={kind} config={config} onChange={(c) => { setConfig(c); setError(null); }} siblings={siblings} team={team} />
      {error && <p role="alert" className="text-xs text-[var(--danger-text)]">{error}</p>}
      <div className="flex items-center justify-end gap-2">
        <button type="button" className="btn btn-ghost btn-sm" onClick={onCancel}>Cancel</button>
        <button type="button" className="btn btn-primary btn-sm" disabled={!nameOk || saving} onClick={() => void create()}>
          {saving && <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden />}
          Create
        </button>
      </div>
    </div>
  );
}

// ── one row ────────────────────────────────────────────────────────────────

export type RowHandlers = {
  onValue: (field: TaskField, value: unknown) => void;
  onRename: (field: TaskField, label: string) => Promise<string | null>;
  onConfig: (field: TaskField, config: FieldConfig) => Promise<string | null>;
  onMove: (field: TaskField, dir: -1 | 1) => void;
  onDelete: (field: TaskField) => void;
};

export function FieldRow({
  field,
  ctx,
  first,
  last,
  error,
  handlers,
}: {
  field: TaskField;
  ctx: FieldCtx;
  first: boolean;
  last: boolean;
  error?: string | null;
  handlers: RowHandlers;
}) {
  const [menu, setMenu] = useState<null | "menu" | "options" | "delete">(null);
  const [renaming, setRenaming] = useState(false);
  const [name, setName] = useState(field.label);
  const [cfg, setCfg] = useState<FieldConfig>(field.config);
  const [menuErr, setMenuErr] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const moreRef = useRef<HTMLButtonElement | null>(null);
  const info = fieldTypeInfo(field.kind);
  const siblings = ctx.fields.filter((f) => f.id !== field.id);

  async function commitRename() {
    const next = name.replace(/\s+/g, " ").trim();
    setRenaming(false);
    if (!next || next === field.label) {
      setName(field.label);
      return;
    }
    const err = await handlers.onRename(field, next);
    if (err) setName(field.label);
  }

  return (
    <div data-testid={`field-row-${field.label}`} data-kind={field.kind} className="group">
      <div className="flex min-h-8 items-start gap-2 rounded-md px-1 py-0.5 hover:bg-[var(--surface-2)]">
        <div className="flex h-7 w-[38%] max-w-[190px] shrink-0 items-center gap-1.5 text-[13px] text-[var(--text-2)]" title={info.name}>
          <FieldTypeIcon kind={field.kind} size={18} />
          {renaming ? (
            <input
              autoFocus
              value={name}
              maxLength={80}
              aria-label="Field name"
              onChange={(e) => setName(e.target.value)}
              onBlur={() => void commitRename()}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  e.currentTarget.blur();
                } else if (e.key === "Escape") {
                  e.preventDefault();
                  e.stopPropagation();
                  setName(field.label);
                  setRenaming(false);
                }
              }}
              className={cn(WELL, "h-6")}
            />
          ) : (
            <span className="truncate">{field.label}</span>
          )}
        </div>
        <div className="flex min-h-7 min-w-0 flex-1 items-center">
          <FieldValueEditor field={field} ctx={ctx} onCommit={(v) => handlers.onValue(field, v)} />
        </div>
        {!ctx.readOnly && (
          <button
            ref={moreRef}
            type="button"
            aria-label={`More for ${field.label}`}
            onClick={() => {
              setMenuErr(null);
              setMenu((m) => (m ? null : "menu"));
            }}
            className={cn("grid h-7 w-7 shrink-0 place-items-center rounded-md text-[var(--text-3)] hover:bg-[var(--surface-3)] hover:text-[var(--text)] focus:opacity-100 group-hover:opacity-100", menu ? "opacity-100" : "opacity-0")}
          >
            <MoreHorizontal className="h-4 w-4" />
          </button>
        )}
      </div>
      {error && <p role="alert" className="pb-1 pl-8 text-xs text-[var(--danger-text)]">{error}</p>}

      <AnchoredPopover anchorRef={moreRef} open={menu !== null} onClose={() => setMenu(null)} label={`${field.label} menu`} width={menu === "options" ? 320 : 200} align="right">
        {menu === "menu" && (
          <div className="p-1">
            <button type="button" className={MENU_ROW} onClick={() => { setMenu(null); setName(field.label); setRenaming(true); }}>
              <Pencil className="h-3.5 w-3.5" aria-hidden /> Rename
            </button>
            {hasOptions(field.kind) && (
              <button type="button" className={MENU_ROW} onClick={() => { setCfg(field.config); setMenuErr(null); setMenu("options"); }}>
                <Settings2 className="h-3.5 w-3.5" aria-hidden /> Edit options
              </button>
            )}
            <button type="button" className={MENU_ROW} disabled={first} onClick={() => { setMenu(null); handlers.onMove(field, -1); }}>
              <ArrowUp className="h-3.5 w-3.5" aria-hidden /> Move up
            </button>
            <button type="button" className={MENU_ROW} disabled={last} onClick={() => { setMenu(null); handlers.onMove(field, 1); }}>
              <ArrowDown className="h-3.5 w-3.5" aria-hidden /> Move down
            </button>
            <div className="my-1 h-px bg-[var(--line)]" />
            <button type="button" className={cn(MENU_ROW, "text-[var(--danger-text)]")} onClick={() => setMenu("delete")}>
              <Trash2 className="h-3.5 w-3.5" aria-hidden /> Delete
            </button>
          </div>
        )}
        {menu === "delete" && (
          <div className="flex flex-col gap-2 p-3">
            <p className="text-[13px] text-[var(--text)]">Delete “{field.label}” and its value?</p>
            <div className="flex justify-end gap-2">
              <button type="button" className="btn btn-ghost btn-xs" onClick={() => setMenu(null)}>Cancel</button>
              <button type="button" className="btn btn-danger btn-xs" onClick={() => { setMenu(null); handlers.onDelete(field); }}>Delete field</button>
            </div>
          </div>
        )}
        {menu === "options" && (
          <div className="flex flex-col gap-3 p-3">
            <div className="flex items-center gap-1.5 text-[13px] font-medium text-[var(--text)]">
              <FieldTypeIcon kind={field.kind} size={18} /> {field.label}
            </div>
            <FieldConfigForm kind={field.kind} config={cfg} onChange={setCfg} siblings={siblings} selfId={field.id} team={ctx.team} />
            {menuErr && <p role="alert" className="text-xs text-[var(--danger-text)]">{menuErr}</p>}
            <div className="flex justify-end gap-2">
              <button type="button" className="btn btn-ghost btn-sm" onClick={() => setMenu(null)}>Cancel</button>
              <button
                type="button"
                className="btn btn-primary btn-sm"
                disabled={saving}
                onClick={async () => {
                  const c = normaliseConfig(field.kind, cfg, siblings);
                  if (!c.ok) return setMenuErr(c.error);
                  setSaving(true);
                  const err = await handlers.onConfig(field, c.value);
                  setSaving(false);
                  if (err) setMenuErr(err);
                  else setMenu(null);
                }}
              >
                Save
              </button>
            </div>
          </div>
        )}
      </AnchoredPopover>
    </div>
  );
}

/** The grey filled pill ClickUp uses, with its test id. */
export function CreateFieldButton({ btnRef, onClick }: { btnRef: React.RefObject<HTMLButtonElement | null>; onClick: () => void }) {
  return (
    <button
      ref={btnRef}
      type="button"
      data-testid="task-custom-fields__add-or-edit-fields"
      onClick={onClick}
      className="inline-flex h-7 items-center gap-1 self-start rounded-full bg-[var(--surface-3)] px-2.5 text-xs font-medium text-[var(--text-2)] hover:bg-[var(--line)] hover:text-[var(--text)]"
    >
      <Plus className="h-3.5 w-3.5" aria-hidden /> Create new field
    </button>
  );
}

// ── the section ────────────────────────────────────────────────────────────

type Store = {
  taskId: string;
  error: string | null;
  fields: TaskField[];
  people: Record<string, TaskAssignee>;
  auto: AutoProgress | null;
  viewerId: string | null;
};

const SAY_OFFLINE = "Could not reach the server — try again.";

async function safely<T extends { ok: boolean }>(run: () => Promise<T>): Promise<T | { ok: false; error: string }> {
  try {
    return await run();
  } catch (e) {
    return { ok: false, error: (e as Error).message || SAY_OFFLINE };
  }
}

export function TaskFieldsSection({
  taskId,
  canEdit,
  team = [],
  onTaskChanged,
  actions,
}: {
  taskId: string;
  canEdit: boolean;
  /** The page's team list (listAssignableUsers) — faces, and a People picker that costs no request. */
  team?: readonly TaskAssignee[];
  /** A Button changed the task's status or added a comment; a Files upload added attachments. */
  onTaskChanged?: () => void;
  actions: TaskFieldActions;
}) {
  const [store, setStore] = useState<Store | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<ReadonlySet<string>>(new Set());
  const [creating, setCreating] = useState(false);
  const [sectionErr, setSectionErr] = useState<string | null>(null);
  const createRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    let alive = true;
    void safely(() => actions.listTaskFields(taskId)).then((r) => {
      if (!alive) return;
      if (r.ok && "fields" in r) {
        setStore({ taskId, error: null, fields: sortFields(r.fields), people: r.people, auto: r.auto, viewerId: r.viewerId });
      } else {
        setStore({ taskId, error: (r as { error: string }).error, fields: [], people: {}, auto: null, viewerId: null });
      }
    });
    return () => {
      alive = false;
    };
  }, [taskId, actions]);

  const ready = store && store.taskId === taskId ? store : null;
  const fields = useMemo(() => ready?.fields ?? [], [ready]);

  const patch = (fn: (s: Store) => Store) => setStore((s) => (s ? fn(s) : s));
  const setFieldList = (fn: (rows: TaskField[]) => TaskField[]) => patch((s) => ({ ...s, fields: fn(s.fields) }));
  const replace = (f: TaskField) => setFieldList((rows) => rows.map((r) => (r.id === f.id ? f : r)));
  const setErr = (id: string, msg: string | null) =>
    setErrors((e) => {
      const n = { ...e };
      if (msg) n[id] = msg;
      else delete n[id];
      return n;
    });
  const setBusyFor = (id: string, on: boolean) =>
    setBusy((b) => {
      const n = new Set(b);
      if (on) n.add(id);
      else n.delete(id);
      return n;
    });

  async function commitValue(field: TaskField, raw: unknown) {
    const local = normaliseValue(field.kind, field.config, raw, { userId: ready?.viewerId ?? "", now: new Date().toISOString() });
    if (!local.ok) return setErr(field.id, local.error);
    const prev = field.value;
    setErr(field.id, null);
    replace({ ...field, value: local.value });
    const r = await safely(() => actions.updateTaskFieldValue(field.id, raw));
    if (!r.ok || !("field" in r)) {
      setFieldList((rows) => rows.map((x) => (x.id === field.id ? { ...x, value: prev } : x)));
      setErr(field.id, (r as { error: string }).error);
      return;
    }
    replace(r.field);
  }

  const ctx: FieldCtx = {
    taskId,
    fields,
    people: ready?.people ?? {},
    team,
    auto: ready?.auto ?? null,
    viewerId: ready?.viewerId ?? null,
    readOnly: !canEdit,
    busy,
    rememberPerson: (p) => patch((s) => (s.people[p.id] ? s : { ...s, people: { ...s.people, [p.id]: p } })),
    onVote: async (field) => {
      setBusyFor(field.id, true);
      setErr(field.id, null);
      const r = await safely(() => actions.toggleTaskFieldVote(field.id));
      setBusyFor(field.id, false);
      if (!r.ok || !("field" in r)) return setErr(field.id, (r as { error: string }).error);
      replace(r.field);
    },
    onPress: async (field) => {
      setBusyFor(field.id, true);
      setErr(field.id, null);
      const r = await safely(() => actions.pressTaskFieldButton(field.id));
      setBusyFor(field.id, false);
      if (!r.ok || !("field" in r)) return setErr(field.id, (r as { error: string }).error);
      replace(r.field);
      if (r.target) replace(r.target);
      onTaskChanged?.();
    },
    onFiles: async (field, files) => {
      setBusyFor(field.id, true);
      setErr(field.id, null);
      const added: FileRef[] = [];
      const refused: string[] = [];
      for (const file of files) {
        const r = await safely(() => actions.uploadTaskFile(taskId, file));
        if (r.ok && "attachment" in r) added.push({ id: r.attachment.id, name: r.attachment.fileName, mime: r.attachment.mimeType ?? null });
        else refused.push((r as { error: string }).error);
      }
      setBusyFor(field.id, false);
      if (added.length) {
        const cur = Array.isArray(field.value) ? (field.value as FileRef[]) : [];
        await commitValue(field, [...cur, ...added]);
        onTaskChanged?.();
      }
      if (refused.length) setErr(field.id, refused.join(" · "));
    },
  };

  const handlers: RowHandlers = {
    onValue: (f, v) => void commitValue(f, v),
    onRename: async (field, label) => {
      const prev = field.label;
      replace({ ...field, label });
      setErr(field.id, null);
      const r = await safely(() => actions.renameTaskField(field.id, label));
      if (!r.ok || !("field" in r)) {
        setFieldList((rows) => rows.map((x) => (x.id === field.id ? { ...x, label: prev } : x)));
        const msg = (r as { error: string }).error;
        setErr(field.id, msg);
        return msg;
      }
      replace(r.field);
      for (const f of r.formulas) replace(f);
      return null;
    },
    onConfig: async (field, config) => {
      const r = await safely(() => actions.updateTaskFieldConfig(field.id, config));
      if (!r.ok || !("field" in r)) return (r as { error: string }).error;
      replace(r.field);
      return null;
    },
    onMove: async (field, dir) => {
      const before = fields;
      const i = before.findIndex((f) => f.id === field.id);
      const j = i + dir;
      if (i < 0 || j < 0 || j >= before.length) return;
      const next = [...before];
      [next[i], next[j]] = [next[j], next[i]];
      setFieldList(() => next);
      setSectionErr(null);
      const r = await safely(() => actions.reorderTaskFields(taskId, next.map((f) => f.id)));
      if (!r.ok) {
        setFieldList(() => before);
        setSectionErr((r as { error: string }).error);
      }
    },
    onDelete: async (field) => {
      const before = fields;
      setFieldList((rows) => rows.filter((r) => r.id !== field.id));
      setSectionErr(null);
      const r = await safely(() => actions.deleteTaskField(field.id));
      if (!r.ok) {
        setFieldList(() => before);
        setSectionErr(`“${field.label}” was not deleted: ${(r as { error: string }).error}`);
      }
    },
  };

  if (!ready) {
    return (
      <section data-testid="task-fields" className="flex flex-col gap-1">
        <h3 className="text-[13px] text-[var(--text-2)]">Fields</h3>
        <div aria-label="Loading fields" className="h-7 w-48 animate-pulse rounded-md bg-[var(--surface-3)]" />
      </section>
    );
  }
  if (!canEdit && !ready.error && fields.length === 0) return null;

  return (
    <section data-testid="task-fields" className="flex flex-col gap-1">
      <h3 className="text-[13px] text-[var(--text-2)]">Fields</h3>
      {ready.error ? (
        <p className="text-xs text-[var(--text-3)]">Fields unavailable: {ready.error}</p>
      ) : (
        <>
          {fields.length > 0 && (
            <div className="flex flex-col">
              {fields.map((f, i) => (
                <FieldRow key={f.id} field={f} ctx={ctx} first={i === 0} last={i === fields.length - 1} error={errors[f.id]} handlers={handlers} />
              ))}
            </div>
          )}
          {sectionErr && <p role="alert" className="text-xs text-[var(--danger-text)]">{sectionErr}</p>}
          {canEdit && (
            <>
              <CreateFieldButton btnRef={createRef} onClick={() => setCreating((c) => !c)} />
              <AnchoredPopover anchorRef={createRef} open={creating} onClose={() => setCreating(false)} label="Create new field" width={320}>
                <CreateFieldPanel
                  siblings={fields}
                  team={team}
                  onCancel={() => setCreating(false)}
                  onCreate={async (input) => {
                    const r = await safely(() => actions.createTaskField(taskId, input));
                    if (!r.ok || !("field" in r)) return (r as { error: string }).error;
                    setFieldList((rows) => [...rows, r.field]);
                    setCreating(false);
                    return null;
                  }}
                />
              </AnchoredPopover>
            </>
          )}
        </>
      )}
    </section>
  );
}
