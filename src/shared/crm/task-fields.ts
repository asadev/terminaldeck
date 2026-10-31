/**
 * Copied from the reference CRM's task fields module, so local tasks have its
 * custom fields exactly: the 23 kinds, their config and value rules, the
 * formula engine and auto progress. Only the three imports below changed —
 * they come from `./crm-shim` instead of the rest of the CRM.
 */
/**
 * TASK CUSTOM FIELDS — the catalogue, the rule every value obeys, and how it reads.
 *
 * All 23 of ClickUp's field types, in ClickUp's order, with ClickUp's names.
 * One row per field on ONE task: label · kind · config (the type's settings) ·
 * value (null = empty).
 *
 * ── WHY THIS FILE IS PURE ──────────────────────────────────────────────────
 * The server actions (task-fields-actions.ts) and the browser (the Fields
 * section, the create box's draft) run the SAME normalisers, so a value the
 * browser accepted is the value the server stores, and garbage is refused by
 * the same sentence on both sides. Nothing here touches a database or React.
 *
 * ── WHO STAMPS WHAT ────────────────────────────────────────────────────────
 *   · Formula and Progress (Auto) are COMPUTED — their value is always null
 *     and a write is refused.
 *   · Voting and Button are written only by their own actions (toggle MY vote;
 *     press the button) — a client can never post a vote on someone's behalf
 *     or a press count.
 *   · Signature records who signed and when from the SESSION, never the body.
 *
 * ── THE FORMULA ENGINE NEVER EVALUATES CODE ────────────────────────────────
 * A hand-written tokenizer + recursive-descent parser over numbers, {Field
 * name} references, + − × ÷ %, parentheses and six named functions. There is
 * no eval, no Function(), no property access — an expression that is not in
 * that grammar is a parse error, full stop.
 */

import { isTagArea, type TagAreaKey } from "./crm-shim";
import { TASK_STATUSES, isTaskStatus } from "./crm-shim";
import type { TaskStatus } from "./crm-shim";

// ── the catalogue ───────────────────────────────────────────────────────────

/** Storage keys — a vocabulary, never renamed (the CHECK lists them). */
export const FIELD_KINDS = [
  "dropdown",
  "text",
  "date",
  "long_text",
  "number",
  "labels",
  "checkbox",
  "money",
  "website",
  "formula",
  "files",
  "relationship",
  "people",
  "progress_auto",
  "email",
  "phone",
  "tasks",
  "location",
  "progress_manual",
  "rating",
  "voting",
  "signature",
  "button",
] as const;
export type FieldKind = (typeof FIELD_KINDS)[number];

export function isFieldKind(v: unknown): v is FieldKind {
  return typeof v === "string" && (FIELD_KINDS as readonly string[]).includes(v);
}

export type FieldGroup = "basic" | "choice" | "contact" | "numbers" | "links" | "actions";

/** The picker's filter row: "All" first, then the groups. */
export const FIELD_GROUPS: { key: FieldGroup; label: string }[] = [
  { key: "basic", label: "Basic" },
  { key: "choice", label: "Choice" },
  { key: "numbers", label: "Numbers" },
  { key: "contact", label: "Contact" },
  { key: "links", label: "Links" },
  { key: "actions", label: "Actions" },
];

export type FieldTypeInfo = {
  kind: FieldKind;
  /** ClickUp's own name for it — what the picker shows. */
  name: string;
  /** The one line under the name. */
  hint: string;
  group: FieldGroup;
  /** A design-system hue token (the CRM design system's `--hue-*`) for the icon tile. */
  hue: string;
};

/** ClickUp's order, ClickUp's names. */
export const FIELD_TYPES: readonly FieldTypeInfo[] = [
  { kind: "dropdown", name: "Dropdown", hint: "One option from a list", group: "choice", hue: "--hue-emerald" },
  { kind: "text", name: "Text", hint: "A single line of text", group: "basic", hue: "--hue-sky" },
  { kind: "date", name: "Date", hint: "A day, with an optional time", group: "basic", hue: "--hue-amber" },
  { kind: "long_text", name: "Text area (Long Text)", hint: "Several lines of text", group: "basic", hue: "--hue-sky" },
  { kind: "number", name: "Number", hint: "A number, with decimals", group: "numbers", hue: "--hue-teal" },
  { kind: "labels", name: "Labels", hint: "Several coloured tags", group: "choice", hue: "--hue-violet" },
  { kind: "checkbox", name: "Checkbox", hint: "Yes or no", group: "basic", hue: "--hue-fuchsia" },
  { kind: "money", name: "Money", hint: "An amount in a currency", group: "numbers", hue: "--hue-emerald" },
  { kind: "website", name: "Website", hint: "A link", group: "contact", hue: "--hue-blue" },
  { kind: "formula", name: "Formula", hint: "Maths over this task's numbers", group: "numbers", hue: "--hue-indigo" },
  { kind: "files", name: "Files", hint: "Upload files to this field", group: "links", hue: "--hue-orange" },
  { kind: "relationship", name: "Relationship", hint: "Link any CRM record", group: "links", hue: "--hue-indigo" },
  { kind: "people", name: "People", hint: "Team members", group: "links", hue: "--hue-blue" },
  { kind: "progress_auto", name: "Progress (Auto)", hint: "From subtasks and checklists", group: "numbers", hue: "--hue-teal" },
  { kind: "email", name: "Email", hint: "An email address", group: "contact", hue: "--hue-rose" },
  { kind: "phone", name: "Phone", hint: "A phone number", group: "contact", hue: "--hue-violet" },
  { kind: "tasks", name: "Tasks", hint: "Link other tasks", group: "links", hue: "--hue-indigo" },
  { kind: "location", name: "Location", hint: "A place, with a map link", group: "contact", hue: "--hue-rose" },
  { kind: "progress_manual", name: "Progress (Manual)", hint: "A slider you set", group: "numbers", hue: "--hue-teal" },
  { kind: "rating", name: "Rating", hint: "Stars out of a maximum", group: "choice", hue: "--hue-amber" },
  { kind: "voting", name: "Voting", hint: "One vote per person", group: "choice", hue: "--hue-orange" },
  { kind: "signature", name: "Signature", hint: "Draw or type a signature", group: "actions", hue: "--hue-violet" },
  { kind: "button", name: "Button", hint: "One press runs an action", group: "actions", hue: "--hue-blue" },
];

export function fieldTypeInfo(kind: FieldKind): FieldTypeInfo {
  return FIELD_TYPES.find((t) => t.kind === kind) ?? FIELD_TYPES[1];
}

/** Types whose value is computed, never written. */
export function isComputedKind(kind: FieldKind): boolean {
  return kind === "formula" || kind === "progress_auto";
}

/** Types written only by their own action (vote / press). */
export function isActionOnlyKind(kind: FieldKind): boolean {
  return kind === "voting" || kind === "button";
}

/** Types with an "Edit options" entry in the row's ⋯ menu. */
export function hasOptions(kind: FieldKind): boolean {
  return [
    "dropdown",
    "labels",
    "number",
    "money",
    "date",
    "rating",
    "progress_manual",
    "progress_auto",
    "formula",
    "relationship",
    "button",
  ].includes(kind);
}

// ── shapes ──────────────────────────────────────────────────────────────────

export type Fail = { ok: false; error: string };
export type Res<T> = { ok: true; value: T } | Fail;
const fail = (error: string): Fail => ({ ok: false, error });
const ok = <T>(value: T): Res<T> => ({ ok: true, value });

export type FieldOption = { id: string; label: string; color: string };
export type RatingIcon = "star" | "heart" | "fire" | "thumb" | "smile";
export type ButtonAction =
  | { type: "status"; status: TaskStatus }
  | { type: "comment"; body: string }
  | { type: "field"; fieldId: string; value: unknown };

/**
 * ONE flat bag, normalised per kind so the keys that kind needs are always
 * present (normaliseConfig). Keys a kind does not use are dropped.
 */
export type FieldConfig = {
  options?: FieldOption[];
  decimals?: number;
  currency?: string | null;
  includeTime?: boolean;
  max?: number;
  icon?: RatingIcon;
  start?: number;
  end?: number;
  subtasks?: boolean;
  checklists?: boolean;
  expression?: string;
  areas?: TagAreaKey[];
  label?: string;
  color?: string;
  action?: ButtonAction;
};

export type DateValue = { date: string; time: string | null };
export type FileRef = { id: string; name: string; mime: string | null };
export type RecordRef = { area: TagAreaKey; id: string; label: string; href: string };
export type TaskRef = { id: string; label: string };
export type LocationValue = { text: string; lat: number | null; lng: number | null };
export type VotingValue = { votes: Record<string, true> };
export type SignatureValue =
  | { mode: "drawn"; dataUrl: string; by: string; at: string }
  | { mode: "typed"; text: string; by: string; at: string };
export type ButtonValue = { count: number; lastBy: string | null; lastAt: string | null };

/** A field as the browser sees it. */
export type TaskField = {
  id: string;
  taskId: string;
  label: string;
  kind: FieldKind;
  config: FieldConfig;
  /** null = empty. Shape per kind, as normaliseValue returns it. */
  value: unknown;
  sortOrder: number | null;
  createdBy: string | null;
  createdAt: string;
  updatedAt: string | null;
};

/** What the config/formula checks need to know about the other fields. */
export type SiblingField = Pick<TaskField, "id" | "label" | "kind" | "config"> & { value?: unknown };

/** The counts Progress (Auto) is computed from. */
export type AutoProgress = {
  subtasks: { done: number; total: number };
  checklists: { done: number; total: number };
};

// ── small helpers ───────────────────────────────────────────────────────────

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuidLike = (v: unknown): v is string => typeof v === "string" && UUID_RE.test(v);

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

/** An id for an option, a draft row — anywhere a key must be unique and never undefined. */
export function newFieldKey(): string {
  const c = typeof globalThis !== "undefined" ? globalThis.crypto : undefined;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  return `k-${Math.random().toString(36).slice(2)}-${Date.now().toString(36)}`;
}

/** ClickUp's option palette, as hex so no Tailwind sweep can repaint it. */
export const FIELD_COLORS = [
  "#6B7280",
  "#3B82F6",
  "#10B981",
  "#F59E0B",
  "#EF4444",
  "#8B5CF6",
  "#EC4899",
  "#14B8A6",
  "#F97316",
  "#0EA5E9",
  "#84CC16",
  "#A855F7",
] as const;
const HEX_RE = /^#[0-9a-f]{6}$/i;

/** The Money field's currencies, the first one the default. */
export const CURRENCIES = [
  "AED",
  "EUR",
  "GBP",
  "SAR",
  "QAR",
  "OMR",
  "KWD",
  "BHD",
  "INR",
  "PKR",
  "CNY",
  "RUB",
  "CAD",
  "AUD",
  "CHF",
  "JPY",
] as const;
export const DEFAULT_CURRENCY = "AED";

export const RATING_ICONS: { key: RatingIcon; glyph: string; label: string }[] = [
  { key: "star", glyph: "★", label: "Stars" },
  { key: "heart", glyph: "♥", label: "Hearts" },
  { key: "fire", glyph: "🔥", label: "Fire" },
  { key: "thumb", glyph: "👍", label: "Thumbs" },
  { key: "smile", glyph: "😀", label: "Smiles" },
];

/** Kinds a Button may set, and the only kinds whose value a button can carry. */
export const BUTTON_TARGET_KINDS: readonly FieldKind[] = [
  "text",
  "long_text",
  "number",
  "money",
  "date",
  "checkbox",
  "dropdown",
  "labels",
  "rating",
  "progress_manual",
  "website",
  "email",
  "phone",
  "location",
];

export const MAX_FIELD_LABEL = 80;
export const MAX_TEXT = 500;
export const MAX_LONG_TEXT = 5000;
export const MAX_LIST = 30;
export const MAX_SIGNATURE_BYTES = 200_000;
const MAX_ABS_NUMBER = 1e15;

function clampInt(v: unknown, lo: number, hi: number, dflt: number): number {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() ? Number(v) : NaN;
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, Math.round(n)));
}

export function roundTo(n: number, decimals: number): number {
  const f = 10 ** decimals;
  return Math.round((n + Number.EPSILON) * f) / f;
}

/** A number from what a person typed: "1,200", "AED 1200.5", 3. "bad" = not a number. */
export function toNumber(raw: unknown): number | null | "bad" {
  if (raw === null || raw === undefined) return null;
  if (typeof raw === "number") return Number.isFinite(raw) ? raw : "bad";
  if (typeof raw !== "string") return "bad";
  // Only a REAL currency code in front of a number is dropped ("AED 1,200").
  // Stripping any three letters turned "abc" into "" — i.e. an empty value
  // accepted instead of garbage refused (caught by the tests, 2026-09-15).
  const code = /^([A-Za-z]{3})\s*(?=[-+.\d])/.exec(raw.trim());
  const body = code && (CURRENCIES as readonly string[]).includes(code[1].toUpperCase()) ? raw.trim().slice(code[0].length) : raw;
  const s = body.trim().replace(/[,\s]/g, "");
  if (!s) return null;
  if (!/^[-+]?(\d+\.?\d*|\.\d+)(e[-+]?\d+)?$/i.test(s)) return "bad";
  const n = Number(s);
  return Number.isFinite(n) ? n : "bad";
}

// ── labels ──────────────────────────────────────────────────────────────────

export function normaliseFieldLabel(raw: unknown): Res<string> {
  if (typeof raw !== "string") return fail("Field name is required");
  const s = raw.replace(/\s+/g, " ").trim();
  if (!s) return fail("Field name is required");
  if (s.length > MAX_FIELD_LABEL) return fail(`Field name is too long (${MAX_FIELD_LABEL} characters max)`);
  // Formulas refer to fields as {Name}; a brace in a name would break that.
  if (/[{}]/.test(s)) return fail("Field names cannot contain { or }");
  return ok(s);
}

/** Case-insensitive: "Price" and "price" are the same name on one task. */
export function sameLabel(a: string, b: string): boolean {
  return a.trim().toLowerCase() === b.trim().toLowerCase();
}

// ── config ──────────────────────────────────────────────────────────────────

export function defaultConfig(kind: FieldKind): FieldConfig {
  const r = normaliseConfig(kind, {});
  return r.ok ? r.value : {};
}

function normaliseOptions(raw: unknown): Res<FieldOption[]> {
  if (raw === undefined || raw === null) return ok([]);
  if (!Array.isArray(raw)) return fail("Options must be a list");
  if (raw.length > 200) return fail("Too many options (200 max)");
  const out: FieldOption[] = [];
  for (let i = 0; i < raw.length; i++) {
    const o = raw[i];
    if (!isObj(o)) return fail("An option is malformed");
    const label = typeof o.label === "string" ? o.label.replace(/\s+/g, " ").trim() : "";
    if (!label) return fail("Every option needs a name");
    if (label.length > 60) return fail(`Option “${label.slice(0, 20)}…” is too long (60 max)`);
    if (out.some((x) => sameLabel(x.label, label))) return fail(`Two options are called “${label}”`);
    const id = typeof o.id === "string" && /^[A-Za-z0-9_-]{1,40}$/.test(o.id) ? o.id : newFieldKey().slice(0, 36);
    if (out.some((x) => x.id === id)) return fail("Two options share an id");
    const color = typeof o.color === "string" && HEX_RE.test(o.color) ? o.color.toUpperCase() : FIELD_COLORS[i % FIELD_COLORS.length];
    out.push({ id, label, color });
  }
  return ok(out);
}

/**
 * The type's settings, cleaned. `siblings` lets a Button check that the field
 * it sets is on this task and that the value fits it; without them (the
 * browser drafting a button before its target exists) that check is skipped
 * and the server makes it on save.
 */
export function normaliseConfig(
  kind: FieldKind,
  raw: unknown,
  siblings?: readonly SiblingField[],
): Res<FieldConfig> {
  if (raw !== undefined && raw !== null && !isObj(raw)) return fail("Settings are malformed");
  const c = (raw ?? {}) as Record<string, unknown>;
  switch (kind) {
    case "dropdown":
    case "labels": {
      const o = normaliseOptions(c.options);
      return o.ok ? ok({ options: o.value }) : o;
    }
    case "number":
      return ok({ decimals: clampInt(c.decimals, 0, 6, 2) });
    case "money": {
      const cur = typeof c.currency === "string" ? c.currency.toUpperCase() : DEFAULT_CURRENCY;
      if (!(CURRENCIES as readonly string[]).includes(cur)) return fail(`Unknown currency “${String(c.currency)}”`);
      return ok({ currency: cur, decimals: clampInt(c.decimals, 0, 4, 2) });
    }
    case "date":
      return ok({ includeTime: c.includeTime === true });
    case "rating": {
      const icon = RATING_ICONS.some((r) => r.key === c.icon) ? (c.icon as RatingIcon) : "star";
      return ok({ max: clampInt(c.max, 1, 10, 5), icon });
    }
    case "progress_manual": {
      const start = c.start === undefined ? 0 : toNumber(c.start);
      const end = c.end === undefined ? 100 : toNumber(c.end);
      if (start === "bad" || end === "bad" || start === null || end === null) return fail("Start and end must be numbers");
      if (Math.abs(start) > 1e9 || Math.abs(end) > 1e9) return fail("Start and end are too large");
      if (!(start < end)) return fail("Start must be less than end");
      return ok({ start, end });
    }
    case "progress_auto": {
      const subtasks = c.subtasks === undefined ? true : c.subtasks === true;
      const checklists = c.checklists === undefined ? true : c.checklists === true;
      if (!subtasks && !checklists) return fail("Count subtasks, checklists, or both");
      return ok({ subtasks, checklists });
    }
    case "formula": {
      const expression = typeof c.expression === "string" ? c.expression.trim() : "";
      if (expression.length > 500) return fail("Formula is too long (500 characters max)");
      if (expression) {
        const p = parseFormula(expression);
        if (!p.ok) return fail(`Formula: ${p.error}`);
      }
      const currency =
        typeof c.currency === "string" && c.currency
          ? (CURRENCIES as readonly string[]).includes(c.currency.toUpperCase())
            ? c.currency.toUpperCase()
            : null
          : null;
      if (typeof c.currency === "string" && c.currency && !currency) return fail(`Unknown currency “${c.currency}”`);
      return ok({ expression, decimals: clampInt(c.decimals, 0, 6, 2), currency });
    }
    case "relationship": {
      if (c.areas !== undefined && !Array.isArray(c.areas)) return fail("Areas must be a list");
      const areas: TagAreaKey[] = [];
      for (const a of (c.areas as unknown[] | undefined) ?? []) {
        if (!isTagArea(a)) return fail(`Unknown area “${String(a)}”`);
        if (!areas.includes(a)) areas.push(a);
      }
      return ok({ areas });
    }
    case "button": {
      const label = typeof c.label === "string" && c.label.trim() ? c.label.replace(/\s+/g, " ").trim() : "Button";
      if (label.length > 40) return fail("Button label is too long (40 max)");
      const color = typeof c.color === "string" && HEX_RE.test(c.color) ? c.color.toUpperCase() : "#2F6BFF";
      const a = c.action === undefined ? { type: "status", status: "Done" } : c.action;
      if (!isObj(a)) return fail("Choose what the button does");
      let action: ButtonAction;
      if (a.type === "status") {
        if (!isTaskStatus(a.status)) return fail("Choose a status for the button");
        action = { type: "status", status: a.status };
      } else if (a.type === "comment") {
        const body = typeof a.body === "string" ? a.body.trim() : "";
        if (!body) return fail("Write the comment the button adds");
        if (body.length > 2000) return fail("Comment is too long (2000 max)");
        action = { type: "comment", body };
      } else if (a.type === "field") {
        if (typeof a.fieldId !== "string" || !a.fieldId) return fail("Choose the field the button sets");
        action = { type: "field", fieldId: a.fieldId, value: a.value ?? null };
        if (siblings) {
          const target = siblings.find((s) => s.id === a.fieldId);
          if (!target) return fail("The field this button sets is not on this task");
          if (!BUTTON_TARGET_KINDS.includes(target.kind)) return fail(`A button cannot set a ${fieldTypeInfo(target.kind).name} field`);
          const v = normaliseValue(target.kind, target.config, a.value ?? null, { userId: "", now: "" });
          if (!v.ok) return fail(`Button value for “${target.label}”: ${v.error}`);
          action = { type: "field", fieldId: a.fieldId, value: v.value };
        }
      } else {
        return fail("Choose what the button does");
      }
      return ok({ label, color, action });
    }
    default:
      return ok({});
  }
}

// ── values ──────────────────────────────────────────────────────────────────

export type ValueCtx = {
  /** The signed-in caller — stamped onto a signature. */
  userId: string;
  /** ISO now — stamped onto a signature. */
  now: string;
};

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/;

function isCalendarDate(s: string): boolean {
  const m = DATE_RE.exec(s);
  if (!m) return false;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (y < 1900 || y > 2200 || mo < 1 || mo > 12 || d < 1) return false;
  const days = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  return d <= days;
}

function cleanString(raw: unknown, max: number, what: string, multiline: boolean): Res<string | null> {
  if (raw === null || raw === undefined) return ok(null);
  if (typeof raw !== "string") return fail(`${what} must be text`);
  let s = raw.replace(/\r\n?/g, "\n");
  s = multiline ? s.replace(/[^\S\n]+$/gm, "").trim() : s.replace(/\s+/g, " ").trim();
  if (!s) return ok(null);
  if (s.length > max) return fail(`${what} is too long (${max} characters max)`);
  return ok(s);
}

export function normaliseWebsite(raw: unknown): Res<string | null> {
  const s = cleanString(raw, 2000, "Website", false);
  if (!s.ok || s.value === null) return s;
  const withScheme = /^[a-z][a-z0-9+.-]*:/i.test(s.value) ? s.value : `https://${s.value}`;
  let u: URL;
  try {
    u = new URL(withScheme);
  } catch {
    return fail("That is not a web address");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return fail("Only http and https links");
  if (!u.hostname.includes(".") && u.hostname !== "localhost") return fail("That is not a web address");
  return ok(u.toString());
}

export function normaliseEmail(raw: unknown): Res<string | null> {
  const s = cleanString(raw, 254, "Email", false);
  if (!s.ok || s.value === null) return s;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s.value)) return fail("That is not an email address");
  return ok(s.value);
}

export function normalisePhone(raw: unknown): Res<string | null> {
  const s = cleanString(raw, 40, "Phone", false);
  if (!s.ok || s.value === null) return s;
  if (!/^\+?[\d\s().-]+$/.test(s.value)) return fail("A phone number has digits, spaces, + ( ) - only");
  const digits = s.value.replace(/\D/g, "").length;
  if (digits < 6 || digits > 15) return fail("A phone number has 6 to 15 digits");
  return ok(s.value);
}

export function normaliseLocation(raw: unknown): Res<LocationValue | null> {
  if (raw === null || raw === undefined || raw === "") return ok(null);
  let text: unknown = raw;
  let lat: unknown = null;
  let lng: unknown = null;
  if (isObj(raw)) {
    text = raw.text;
    lat = raw.lat ?? null;
    lng = raw.lng ?? null;
  }
  const t = cleanString(text, 300, "Location", false);
  if (!t.ok) return t;
  if (t.value === null) return ok(null);
  const coords = /^\s*(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*$/.exec(t.value);
  if (coords && lat === null && lng === null) {
    lat = Number(coords[1]);
    lng = Number(coords[2]);
  }
  const la = lat === null ? null : typeof lat === "number" ? lat : NaN;
  const ln = lng === null ? null : typeof lng === "number" ? lng : NaN;
  if ((la === null) !== (ln === null)) return fail("A location needs both latitude and longitude, or neither");
  if (la !== null && (!Number.isFinite(la) || la < -90 || la > 90)) return fail("Latitude is between -90 and 90");
  if (ln !== null && (!Number.isFinite(ln) || ln < -180 || ln > 180)) return fail("Longitude is between -180 and 180");
  return ok({ text: t.value, lat: la, lng: ln });
}

/** A Google Maps link for a location, coordinates first when we have them. */
export function mapHref(v: LocationValue): string {
  const q = v.lat !== null && v.lng !== null ? `${v.lat},${v.lng}` : v.text;
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(q)}`;
}

/** An internal link only — "/…", never "//host" or "javascript:". */
function isInternalHref(h: unknown): h is string {
  return typeof h === "string" && h.length <= 500 && h.startsWith("/") && !h.startsWith("//") && !/[\s\\]/.test(h);
}

/**
 * THE rule for a value, per kind. `raw` is whatever the editor sent; the
 * result is exactly what is stored (null = empty). Garbage is refused with a
 * sentence a person can act on.
 */
export function normaliseValue(kind: FieldKind, config: FieldConfig, raw: unknown, ctx: ValueCtx): Res<unknown> {
  if (isComputedKind(kind)) return fail("This field is calculated — it cannot be set by hand");
  if (kind === "voting") return fail("Use the vote button to vote");
  if (kind === "button") return fail("Press the button to run it");
  if (raw === undefined) raw = null;

  switch (kind) {
    case "text":
      return cleanString(raw, MAX_TEXT, "Text", false);
    case "long_text":
      return cleanString(raw, MAX_LONG_TEXT, "Text", true);
    case "number":
    case "money": {
      const n = toNumber(raw);
      if (n === "bad") return fail("That is not a number");
      if (n === null) return ok(null);
      if (Math.abs(n) > MAX_ABS_NUMBER) return fail("That number is too large");
      const d = config.decimals ?? 2;
      return ok(roundTo(n, d));
    }
    case "checkbox":
      if (raw === null) return ok(null);
      if (typeof raw !== "boolean") return fail("A checkbox is ticked or not");
      return ok(raw);
    case "date": {
      if (raw === null || raw === "") return ok(null);
      let date: unknown = raw;
      let time: unknown = null;
      if (isObj(raw)) {
        date = raw.date;
        time = raw.time ?? null;
      }
      if (date === null || date === "") return ok(null);
      if (typeof date !== "string" || !isCalendarDate(date)) return fail("That is not a date");
      if (time !== null && time !== "" && (typeof time !== "string" || !TIME_RE.test(time))) return fail("That is not a time (HH:MM)");
      const keepTime = config.includeTime === true && typeof time === "string" && time !== "";
      return ok({ date, time: keepTime ? time : null } satisfies DateValue);
    }
    case "dropdown": {
      if (raw === null || raw === "") return ok(null);
      if (typeof raw !== "string") return fail("Pick one of the options");
      if (!(config.options ?? []).some((o) => o.id === raw)) return fail("That option is not on this field");
      return ok(raw);
    }
    case "labels": {
      if (raw === null) return ok(null);
      if (!Array.isArray(raw)) return fail("Labels must be a list");
      const ids: string[] = [];
      for (const id of raw) {
        if (typeof id !== "string" || !(config.options ?? []).some((o) => o.id === id)) return fail("A label is not on this field");
        if (!ids.includes(id)) ids.push(id);
      }
      return ok(ids.length ? ids : null);
    }
    case "website":
      return normaliseWebsite(raw);
    case "email":
      return normaliseEmail(raw);
    case "phone":
      return normalisePhone(raw);
    case "location":
      return normaliseLocation(raw);
    case "rating": {
      if (raw === null || raw === 0) return ok(null);
      if (typeof raw !== "number" || !Number.isInteger(raw)) return fail("A rating is a whole number");
      const max = config.max ?? 5;
      if (raw < 1 || raw > max) return fail(`A rating is 1 to ${max}`);
      return ok(raw);
    }
    case "progress_manual": {
      const n = toNumber(raw);
      if (n === "bad") return fail("Progress is a number");
      if (n === null) return ok(null);
      const start = config.start ?? 0;
      const end = config.end ?? 100;
      if (n < start || n > end) return fail(`Progress is between ${start} and ${end}`);
      return ok(roundTo(n, 2));
    }
    case "people": {
      if (raw === null) return ok(null);
      if (!Array.isArray(raw)) return fail("People must be a list");
      if (raw.length > MAX_LIST) return fail(`At most ${MAX_LIST} people`);
      const ids: string[] = [];
      for (const id of raw) {
        if (!isUuidLike(id)) return fail("A person is malformed");
        if (!ids.includes(id)) ids.push(id);
      }
      return ok(ids.length ? ids : null);
    }
    case "files": {
      if (raw === null) return ok(null);
      if (!Array.isArray(raw)) return fail("Files must be a list");
      if (raw.length > MAX_LIST) return fail(`At most ${MAX_LIST} files`);
      const out: FileRef[] = [];
      for (const f of raw) {
        if (!isObj(f) || !isUuidLike(f.id)) return fail("A file is malformed");
        const name = typeof f.name === "string" ? f.name.trim().slice(0, 200) : "";
        if (!name) return fail("A file has no name");
        const mime = typeof f.mime === "string" && f.mime ? f.mime.slice(0, 120) : null;
        if (!out.some((x) => x.id === f.id)) out.push({ id: f.id, name, mime });
      }
      return ok(out.length ? out : null);
    }
    case "relationship": {
      if (raw === null) return ok(null);
      if (!Array.isArray(raw)) return fail("Links must be a list");
      if (raw.length > MAX_LIST) return fail(`At most ${MAX_LIST} links`);
      const allowed = config.areas ?? [];
      const out: RecordRef[] = [];
      for (const r of raw) {
        if (!isObj(r) || !isTagArea(r.area)) return fail("A link is malformed");
        if (allowed.length && !allowed.includes(r.area)) return fail("This field does not link that kind of record");
        const id = typeof r.id === "string" ? r.id.trim() : "";
        const label = typeof r.label === "string" ? r.label.replace(/\s+/g, " ").trim().slice(0, 200) : "";
        if (!id || id.length > 100 || !label) return fail("A link is malformed");
        if (!isInternalHref(r.href)) return fail("A link must point inside the CRM");
        if (!out.some((x) => x.area === r.area && x.id === id)) out.push({ area: r.area, id, label, href: r.href });
      }
      return ok(out.length ? out : null);
    }
    case "tasks": {
      if (raw === null) return ok(null);
      if (!Array.isArray(raw)) return fail("Tasks must be a list");
      if (raw.length > MAX_LIST) return fail(`At most ${MAX_LIST} tasks`);
      const out: TaskRef[] = [];
      for (const t of raw) {
        if (!isObj(t) || !isUuidLike(t.id)) return fail("A task is malformed");
        const label = typeof t.label === "string" ? t.label.replace(/\s+/g, " ").trim().slice(0, 200) : "";
        if (!out.some((x) => x.id === t.id)) out.push({ id: t.id, label: label || "Task" });
      }
      return ok(out.length ? out : null);
    }
    case "signature": {
      if (raw === null) return ok(null);
      if (!isObj(raw)) return fail("A signature is malformed");
      if (raw.mode === "drawn") {
        const d = raw.dataUrl;
        if (typeof d !== "string" || !/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+=*$/.test(d)) return fail("The drawn signature is not an image");
        if (d.length > MAX_SIGNATURE_BYTES) return fail("The drawn signature is too large");
        return ok({ mode: "drawn", dataUrl: d, by: ctx.userId, at: ctx.now } satisfies SignatureValue);
      }
      if (raw.mode === "typed") {
        const t = cleanString(raw.text, 80, "Signature", false);
        if (!t.ok) return t;
        if (t.value === null) return fail("Type your name to sign");
        return ok({ mode: "typed", text: t.value, by: ctx.userId, at: ctx.now } satisfies SignatureValue);
      }
      return fail("Draw or type a signature");
    }
    default:
      return fail("Unknown field type");
  }
}

/**
 * After "Edit options" changed a field's settings, what its stored value
 * becomes: a removed option falls out, a lowered rating max clamps, turning
 * the time off drops it. Kinds the settings cannot affect keep their value.
 */
export function reconcileValue(kind: FieldKind, config: FieldConfig, value: unknown): unknown {
  if (value === null || value === undefined) return null;
  switch (kind) {
    case "dropdown":
      return typeof value === "string" && (config.options ?? []).some((o) => o.id === value) ? value : null;
    case "labels": {
      if (!Array.isArray(value)) return null;
      const kept = value.filter((id) => (config.options ?? []).some((o) => o.id === id));
      return kept.length ? kept : null;
    }
    case "rating":
      return typeof value === "number" ? Math.min(value, config.max ?? 5) : null;
    case "progress_manual":
      return typeof value === "number" ? Math.min(config.end ?? 100, Math.max(config.start ?? 0, value)) : null;
    case "date":
      return isObj(value) && typeof value.date === "string"
        ? { date: value.date, time: config.includeTime ? (value.time as string | null) ?? null : null }
        : null;
    case "number":
    case "money":
      return typeof value === "number" ? roundTo(value, config.decimals ?? 2) : null;
    default:
      return value;
  }
}

// ── the formula engine ─────────────────────────────────────────────────────

type Tok =
  | { t: "num"; v: number }
  | { t: "ref"; name: string }
  | { t: "fn"; name: FormulaFn }
  | { t: "op"; v: "+" | "-" | "*" | "/" | "%" }
  | { t: "(" }
  | { t: ")" }
  | { t: "," };

export const FORMULA_FUNCTIONS = ["round", "min", "max", "abs", "floor", "ceil"] as const;
type FormulaFn = (typeof FORMULA_FUNCTIONS)[number];

export type FormulaAst =
  | { t: "num"; v: number }
  | { t: "ref"; name: string }
  | { t: "neg"; e: FormulaAst }
  | { t: "bin"; op: "+" | "-" | "*" | "/" | "%"; l: FormulaAst; r: FormulaAst }
  | { t: "call"; fn: FormulaFn; args: FormulaAst[] };

function tokenize(src: string): Res<Tok[]> {
  const out: Tok[] = [];
  let i = 0;
  while (i < src.length) {
    const ch = src[i];
    if (/\s/.test(ch)) {
      i++;
      continue;
    }
    if (/[0-9.]/.test(ch)) {
      const m = /^(\d+\.?\d*|\.\d+)/.exec(src.slice(i));
      if (!m) return fail(`Unexpected “${ch}”`);
      out.push({ t: "num", v: Number(m[1]) });
      i += m[1].length;
      continue;
    }
    if (ch === "{") {
      const close = src.indexOf("}", i + 1);
      if (close < 0) return fail("A { has no closing }");
      const name = src.slice(i + 1, close).replace(/\s+/g, " ").trim();
      if (!name) return fail("Empty {} — put a field name inside");
      if (name.includes("{")) return fail("Braces cannot be nested");
      out.push({ t: "ref", name });
      i = close + 1;
      continue;
    }
    if (/[A-Za-z_]/.test(ch)) {
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(src.slice(i))!;
      const word = m[0].toLowerCase();
      if (!(FORMULA_FUNCTIONS as readonly string[]).includes(word)) {
        return fail(`Unknown word “${m[0]}” — put field names in {braces}`);
      }
      out.push({ t: "fn", name: word as FormulaFn });
      i += m[0].length;
      continue;
    }
    if (ch === "+" || ch === "-" || ch === "*" || ch === "/" || ch === "%") {
      out.push({ t: "op", v: ch });
      i++;
      continue;
    }
    if (ch === "×") {
      out.push({ t: "op", v: "*" });
      i++;
      continue;
    }
    if (ch === "÷") {
      out.push({ t: "op", v: "/" });
      i++;
      continue;
    }
    if (ch === "(" || ch === ")" || ch === ",") {
      out.push({ t: ch });
      i++;
      continue;
    }
    return fail(`Unexpected “${ch}”`);
  }
  if (out.length > 300) return fail("Formula is too long");
  return ok(out);
}

const ARITY: Record<FormulaFn, [number, number]> = {
  round: [1, 2],
  min: [1, 20],
  max: [1, 20],
  abs: [1, 1],
  floor: [1, 1],
  ceil: [1, 1],
};

/** Parse only — used to refuse a malformed expression at the door. */
export function parseFormula(src: string): Res<FormulaAst> {
  if (typeof src !== "string" || !src.trim()) return fail("The formula is empty");
  if (src.length > 500) return fail("Formula is too long");
  const toks = tokenize(src);
  if (!toks.ok) return toks;
  const ts = toks.value;
  let pos = 0;
  let depth = 0;
  const peek = () => ts[pos];

  function expr(): Res<FormulaAst> {
    if (++depth > 64) return fail("Formula is nested too deeply");
    const first = term();
    if (!first.ok) return first;
    let node: FormulaAst = first.value;
    for (let tk = peek(); tk && tk.t === "op" && (tk.v === "+" || tk.v === "-"); tk = peek()) {
      pos++;
      const right = term();
      if (!right.ok) return right;
      node = { t: "bin", op: tk.v, l: node, r: right.value };
    }
    depth--;
    return ok(node);
  }
  function term(): Res<FormulaAst> {
    const first = unary();
    if (!first.ok) return first;
    let node: FormulaAst = first.value;
    for (let tk = peek(); tk && tk.t === "op" && (tk.v === "*" || tk.v === "/" || tk.v === "%"); tk = peek()) {
      pos++;
      const right = unary();
      if (!right.ok) return right;
      node = { t: "bin", op: tk.v, l: node, r: right.value };
    }
    return ok(node);
  }
  function unary(): Res<FormulaAst> {
    const tk = peek();
    if (tk && tk.t === "op" && (tk.v === "-" || tk.v === "+")) {
      pos++;
      if (++depth > 64) return fail("Formula is nested too deeply");
      const e = unary();
      depth--;
      if (!e.ok) return e;
      return tk.v === "-" ? ok({ t: "neg", e: e.value } as FormulaAst) : e;
    }
    return primary();
  }
  function primary(): Res<FormulaAst> {
    const tk = peek();
    if (!tk) return fail("The formula ends too early");
    if (tk.t === "num") {
      pos++;
      return ok({ t: "num", v: tk.v });
    }
    if (tk.t === "ref") {
      pos++;
      return ok({ t: "ref", name: tk.name });
    }
    if (tk.t === "(") {
      pos++;
      const e = expr();
      if (!e.ok) return e;
      if (peek()?.t !== ")") return fail("A ( has no closing )");
      pos++;
      return e;
    }
    if (tk.t === "fn") {
      pos++;
      if (peek()?.t !== "(") return fail(`${tk.name} needs ( )`);
      pos++;
      const args: FormulaAst[] = [];
      if (peek()?.t !== ")") {
        for (;;) {
          const a = expr();
          if (!a.ok) return a;
          args.push(a.value);
          if (peek()?.t === ",") {
            pos++;
            continue;
          }
          break;
        }
      }
      if (peek()?.t !== ")") return fail(`${tk.name}( has no closing )`);
      pos++;
      const [lo, hi] = ARITY[tk.name];
      if (args.length < lo || args.length > hi) {
        return fail(lo === hi ? `${tk.name} takes ${lo} value` : `${tk.name} takes ${lo} to ${hi} values`);
      }
      return ok({ t: "call", fn: tk.name, args });
    }
    if (tk.t === ")") return fail("Unexpected )");
    if (tk.t === ",") return fail("Unexpected ,");
    return fail(`Unexpected “${tk.v}”`);
  }

  const root = expr();
  if (!root.ok) return root;
  if (pos < ts.length) {
    const tk = ts[pos];
    return fail(tk.t === ")" ? "Unexpected )" : "Something is missing between two values");
  }
  return root;
}

/** Every {Name} an expression refers to, in order, de-duplicated. */
export function formulaRefs(src: string): string[] {
  const out: string[] = [];
  for (const m of src.matchAll(/\{([^{}]*)\}/g)) {
    const name = m[1].replace(/\s+/g, " ").trim();
    if (name && !out.some((x) => sameLabel(x, name))) out.push(name);
  }
  return out;
}

/** A field was renamed: point the formula's {Old} references at {New}. */
export function renameFormulaRefs(src: string, from: string, to: string): string {
  return src.replace(/\{([^{}]*)\}/g, (whole, name: string) => (sameLabel(name, from) ? `{${to}}` : whole));
}

function evalAst(ast: FormulaAst, resolve: (name: string) => Res<number>): Res<number> {
  switch (ast.t) {
    case "num":
      return ok(ast.v);
    case "ref":
      return resolve(ast.name);
    case "neg": {
      const e = evalAst(ast.e, resolve);
      return e.ok ? ok(-e.value) : e;
    }
    case "bin": {
      const l = evalAst(ast.l, resolve);
      if (!l.ok) return l;
      const r = evalAst(ast.r, resolve);
      if (!r.ok) return r;
      if ((ast.op === "/" || ast.op === "%") && r.value === 0) return fail("Division by zero");
      const v =
        ast.op === "+" ? l.value + r.value
        : ast.op === "-" ? l.value - r.value
        : ast.op === "*" ? l.value * r.value
        : ast.op === "/" ? l.value / r.value
        : l.value % r.value;
      return Number.isFinite(v) ? ok(v) : fail("The result is too large");
    }
    case "call": {
      const vals: number[] = [];
      for (const a of ast.args) {
        const v = evalAst(a, resolve);
        if (!v.ok) return v;
        vals.push(v.value);
      }
      switch (ast.fn) {
        case "round": {
          const d = vals.length > 1 ? Math.round(vals[1]) : 0;
          if (d < 0 || d > 10) return fail("round() keeps 0 to 10 decimals");
          return ok(roundTo(vals[0], d));
        }
        case "min":
          return ok(Math.min(...vals));
        case "max":
          return ok(Math.max(...vals));
        case "abs":
          return ok(Math.abs(vals[0]));
        case "floor":
          return ok(Math.floor(vals[0]));
        case "ceil":
          return ok(Math.ceil(vals[0]));
      }
    }
  }
}

/** Evaluate an expression against a resolver for {Name} references. */
export function evaluateFormula(src: string, resolve: (name: string) => Res<number>): Res<number> {
  const p = parseFormula(src);
  if (!p.ok) return p;
  return evalAst(p.value, resolve);
}

/** The number a field contributes to a formula, or why it cannot. */
export function numericValueOf(f: SiblingField): Res<number> {
  const v = f.value ?? null;
  switch (f.kind) {
    case "number":
    case "money":
    case "rating":
    case "progress_manual":
      return typeof v === "number" ? ok(v) : fail(`“${f.label}” is empty`);
    case "checkbox":
      return ok(v === true ? 1 : 0);
    case "formula":
      return fail(`A formula cannot use another formula (“${f.label}”)`);
    default:
      return fail(`“${f.label}” is not a number field`);
  }
}

/** A formula field's result on this task, from its siblings' current values. */
export function computeFormula(expression: string | undefined, fields: readonly SiblingField[]): Res<number> {
  if (!expression) return fail("No formula yet — Edit options to write one");
  return evaluateFormula(expression, (name) => {
    const hits = fields.filter((f) => sameLabel(f.label, name));
    if (hits.length === 0) return fail(`Unknown field “${name}”`);
    if (hits.length > 1) return fail(`Two fields are called “${name}”`);
    return numericValueOf(hits[0]);
  });
}

// ── progress ────────────────────────────────────────────────────────────────

export function autoProgressOf(config: FieldConfig, auto: AutoProgress | null): { done: number; total: number; percent: number } {
  if (!auto) return { done: 0, total: 0, percent: 0 };
  const done = (config.subtasks !== false ? auto.subtasks.done : 0) + (config.checklists !== false ? auto.checklists.done : 0);
  const total = (config.subtasks !== false ? auto.subtasks.total : 0) + (config.checklists !== false ? auto.checklists.total : 0);
  return { done, total, percent: total ? Math.round((done / total) * 100) : 0 };
}

export function manualPercent(config: FieldConfig, value: unknown): number {
  if (typeof value !== "number") return 0;
  const start = config.start ?? 0;
  const end = config.end ?? 100;
  return Math.round(Math.min(100, Math.max(0, ((value - start) / (end - start)) * 100)));
}

// ── reading a value as words ────────────────────────────────────────────────

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function formatDateValue(v: DateValue): string {
  const m = DATE_RE.exec(v.date);
  if (!m) return v.date;
  const s = `${Number(m[3])} ${MONTHS[Number(m[2]) - 1]} ${m[1]}`;
  return v.time ? `${s} ${v.time}` : s;
}

export function formatNumber(n: number, decimals: number, fixed = false): string {
  return n.toLocaleString("en-US", { minimumFractionDigits: fixed ? decimals : 0, maximumFractionDigits: decimals });
}

export function formatMoney(n: number, currency: string, decimals: number): string {
  return `${currency} ${formatNumber(n, decimals, true)}`;
}

/**
 * A value as one line of words — the activity feed's "from → to", the
 * read-only view, a tooltip. null = empty. `names` resolves people ids.
 */
export function formatFieldValue(
  field: Pick<TaskField, "kind" | "config" | "value">,
  names: (userId: string) => string | null = () => null,
): string | null {
  const v = field.value ?? null;
  const c = field.config;
  if (v === null) return null;
  switch (field.kind) {
    case "text":
    case "long_text":
    case "website":
    case "email":
    case "phone":
      return typeof v === "string" ? v : null;
    case "number":
      return typeof v === "number" ? formatNumber(v, c.decimals ?? 2) : null;
    case "money":
      return typeof v === "number" ? formatMoney(v, c.currency ?? DEFAULT_CURRENCY, c.decimals ?? 2) : null;
    case "checkbox":
      return v === true ? "Checked" : "Unchecked";
    case "date":
      return isObj(v) && typeof v.date === "string" ? formatDateValue(v as DateValue) : null;
    case "dropdown":
      return (c.options ?? []).find((o) => o.id === v)?.label ?? null;
    case "labels":
      return Array.isArray(v)
        ? v.map((id) => (c.options ?? []).find((o) => o.id === id)?.label).filter(Boolean).join(", ") || null
        : null;
    case "rating":
      return typeof v === "number" ? `${v}/${c.max ?? 5}` : null;
    case "progress_manual":
      return typeof v === "number" ? `${manualPercent(c, v)}%` : null;
    case "location":
      return isObj(v) && typeof v.text === "string" ? v.text : null;
    case "people":
      return Array.isArray(v) ? v.map((id) => names(id as string) ?? "someone").join(", ") : null;
    case "files":
      return Array.isArray(v) ? (v as FileRef[]).map((f) => f.name).join(", ") : null;
    case "relationship":
    case "tasks":
      return Array.isArray(v) ? (v as { label: string }[]).map((r) => r.label).join(", ") : null;
    case "signature":
      return isObj(v) ? (v.mode === "typed" ? `Signed “${String(v.text)}”` : "Signed") : null;
    case "voting":
      return isObj(v) && isObj(v.votes) ? `${Object.keys(v.votes).length} votes` : null;
    case "button":
      return isObj(v) && typeof v.count === "number" ? `Pressed ${v.count}×` : null;
    default:
      return null;
  }
}

/** Trim a value for a feed line — the feed is a sentence, not a document. */
export function feedValue(s: string | null): string | null {
  if (s === null) return null;
  return s.length > 120 ? `${s.slice(0, 117)}…` : s;
}

/**
 * The activity feed's sentence for a `field` row. The feed calls this from
 * its `case "field":` (one line — see the report), so the words live beside
 * the payload that feeds them.
 */
export function fieldActivitySentence(actor: string, p: Record<string, string | number | boolean | null>): string {
  const s = (k: string) => (typeof p[k] === "string" ? (p[k] as string) : null);
  const label = s("label") ?? "a field";
  switch (s("action")) {
    case "added":
      return `${actor} added field: ${label}`;
    case "removed":
      return `${actor} removed field: ${label}`;
    case "renamed":
      return `${actor} renamed field: ${s("from") ?? ""} → ${s("to") ?? ""}`;
    case "options":
      return `${actor} edited the options of ${label}`;
    case "voted":
      return `${actor} ${p.to === "voted" ? "voted on" : "took back a vote on"} ${label}`;
    case "pressed":
      return `${actor} pressed ${label}`;
    default: {
      const from = s("from");
      const to = s("to");
      if (to === null) return `${actor} cleared ${label}`;
      return from === null ? `${actor} set ${label}: ${to}` : `${actor} changed ${label}: ${from} → ${to}`;
    }
  }
}

// ── rows ────────────────────────────────────────────────────────────────────

export type TaskFieldDbRow = {
  id: string;
  task_id: string;
  label: string;
  kind: string;
  config: unknown;
  value: unknown;
  sort_order: number | null;
  created_by: string | null;
  created_at: string;
  updated_at: string | null;
};

/** A stored row → the browser's shape. An unknown kind is dropped, not guessed. */
export function rowToField(r: TaskFieldDbRow): TaskField | null {
  if (!isFieldKind(r.kind)) return null;
  const cfg = normaliseConfig(r.kind, r.config);
  return {
    id: r.id,
    taskId: r.task_id,
    label: r.label,
    kind: r.kind,
    config: cfg.ok ? cfg.value : defaultConfig(r.kind),
    value: r.value ?? null,
    sortOrder: r.sort_order ?? null,
    createdBy: r.created_by ?? null,
    createdAt: r.created_at,
    updatedAt: r.updated_at ?? null,
  };
}

/** Sort as stored: sort_order ascending (nulls last), then oldest first. */
export function sortFields<T extends Pick<TaskField, "sortOrder" | "createdAt">>(rows: T[]): T[] {
  return [...rows].sort((a, b) => {
    const as = a.sortOrder ?? Number.MAX_SAFE_INTEGER;
    const bs = b.sortOrder ?? Number.MAX_SAFE_INTEGER;
    if (as !== bs) return as - bs;
    return a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0;
  });
}

/** The status list a Button can set, re-exported so the form needs one import. */
export const BUTTON_STATUSES: readonly TaskStatus[] = TASK_STATUSES;
