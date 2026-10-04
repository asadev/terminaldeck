// Copied from the reference CRM.
/**
 * FILES INSIDE THE TASK TEXT — the token, and everything that reads or writes it.
 *
 * Asad, 2026-09-15, pointing at the task text: *"should be able to attach
 * files and photos in between a text line with small icon which we can click
 * and see big view too."* So an attachment is not only a row in the
 * Attachments section: it can SIT in the text, where it was dropped, pasted or
 * picked.
 *
 * ── THE CONVENTION (decided 2026-09-15, docs/task-clickup-reference.md § 5) ──
 *   · STORAGE: `[[file:<attachment-id>]]` in ops.tasks.title, one token per
 *     placement. The attachment row itself stays in ops.task_attachments; the
 *     token only says WHERE it sits. A draft (not yet uploaded) uses
 *     `[[file:draft:<key>]]` and is rewritten to the real id once the row
 *     exists — or dropped, if the upload was refused.
 *   · EDIT MODE (a contenteditable field, components/tasks/task-text-field.tsx):
 *     each token is drawn as a small non-editable chip — the REAL picture at
 *     text height for an image, a file glyph otherwise. The field works in
 *     the FLAT form (toFlat / fromFlat below): one U+FFFC character per chip,
 *     so a caret is a plain string index and the @mention machinery needs no
 *     knowledge of files. Deleting a chip removes the placement only; the
 *     file stays in the attachments list under the text.
 *   · READ MODE: splitInlineFiles() gives text runs and file ids; the panel
 *     draws an image as a thumbnail (click → lightbox) and any other file as
 *     an icon + name (click → the signed serve route).
 *   · THE LIST ROW strips tokens (stripFileTokens) and shows a 📎 count.
 *   · THE 300-CHARACTER CAP counts VISIBLE text only (visibleLength): a token
 *     is ~44 characters and three photos must not eat half of somebody's
 *     sentence. The raw column is capped at RAW_TITLE_MAX so a title can never
 *     grow without bound either way. The server (tasks-actions.ts) applies the
 *     same two numbers; this module is the one place they live.
 *
 * Pure. No React, no I/O — the server action, the textarea and the list row
 * all import from here so there is exactly one reading of the token.
 */

/** What a person may type: 300 characters of their own words. */
export const VISIBLE_TITLE_MAX = 300;
/** What the column may hold once tokens are counted: 300 + ~80 placements. */
export const RAW_TITLE_MAX = 4000;

const TOKEN_SRC = "\\[\\[file:((?:draft:)?[A-Za-z0-9_-]+)\\]\\]";
/** A fresh global regex each call — a shared /g regex carries lastIndex between callers. */
const tokenRe = () => new RegExp(TOKEN_SRC, "g");

export function fileToken(id: string): string {
  return `[[file:${id}]]`;
}

export function draftFileId(key: string): string {
  return `draft:${key}`;
}

export function isDraftFileId(id: string): boolean {
  return id.startsWith("draft:");
}

export type InlinePart = { kind: "text"; text: string } | { kind: "file"; id: string };

/** Text runs and file placements, in order. Never returns an empty text run. */
export function splitInlineFiles(text: string): InlinePart[] {
  const out: InlinePart[] = [];
  const re = tokenRe();
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push({ kind: "text", text: text.slice(last, m.index) });
    out.push({ kind: "file", id: m[1] });
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push({ kind: "text", text: text.slice(last) });
  return out;
}

/** Every attachment id placed in the text, in order, duplicates kept. */
export function fileTokenIds(text: string): string[] {
  return splitInlineFiles(text).flatMap((p) => (p.kind === "file" ? [p.id] : []));
}

export function countFileTokens(text: string): number {
  return fileTokenIds(text).length;
}

/**
 * The text without its tokens — for the list row and for measuring. Spaces
 * left around a removed token are folded to one so "see [[file:x]] here" reads
 * "see here", and a token on its own line does not leave a blank line.
 */
export function stripFileTokens(text: string): string {
  return text
    .replace(tokenRe(), "")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/^[ \t]+|[ \t]+$/gm, "")
    .trim();
}

/** How many characters the PERSON typed — tokens are not theirs. */
export function visibleLength(text: string): number {
  return text.replace(tokenRe(), "").length;
}

/**
 * Cut the text so that its visible length is at most `max`, keeping every
 * token whole (a half token is garbage that would render literally). Used
 * where a paste would otherwise overshoot the cap.
 */
export function truncateVisible(text: string, max: number = VISIBLE_TITLE_MAX): string {
  if (visibleLength(text) <= max) return text;
  let out = "";
  let seen = 0;
  for (const part of splitInlineFiles(text)) {
    if (part.kind === "file") {
      out += fileToken(part.id);
      continue;
    }
    const room = max - seen;
    if (room <= 0) continue;
    const take = part.text.slice(0, room);
    out += take;
    seen += take.length;
  }
  return out;
}

/**
 * Swap ids: a draft key for the real attachment id once the upload exists, or
 * `null` to remove the placement when the upload was refused. Ids not in the
 * map are left alone.
 */
export function rewriteFileTokens(text: string, map: ReadonlyMap<string, string | null>): string {
  const rewritten = text.replace(tokenRe(), (whole, id: string) => {
    if (!map.has(id)) return whole;
    const next = map.get(id);
    return next ? fileToken(next) : "";
  });
  return rewritten === text ? text : rewritten.replace(/[ \t]{2,}/g, " ").replace(/[ \t]+$/gm, "").trim();
}

/** Insert `snippet` at `index`, returning the new text and where the caret should go. */
export function insertAt(text: string, index: number, snippet: string, spaced = true): { text: string; caret: number } {
  const i = Math.max(0, Math.min(index, text.length));
  // A file dropped mid-word gets a space either side so the chip never glues
  // to a word — unless the caller is at the cap and has no room for spaces.
  const before = text.slice(0, i);
  const after = text.slice(i);
  const lead = spaced && before && !/\s$/.test(before) ? " " : "";
  const tail = spaced && after && !/^\s/.test(after) ? " " : "";
  const inserted = `${lead}${snippet}${tail}`;
  return { text: before + inserted + after, caret: i + inserted.length };
}

// ── the flat form the editor works in ──────────────────────────────────────
//
// Asad, 2026-09-15, looking at `[🖼1]` markers in the create box: *"it should
// show small icon or thumbnail of real photo"*. A textarea cannot draw a
// picture, so the field is a contenteditable editor whose chips are real
// <img>s — but its VALUE is still the storage string above. Between the two
// sits the FLAT form: the storage text with every token replaced by ONE
// character, U+FFFC (the Unicode "object replacement character", which exists
// for exactly this). A chip is then one caret step, the caret is a plain
// string index, and slicing, @mention triggers and the cap all work on a
// string as they did on the textarea. Converting back is by ORDER: the k-th
// U+FFFC is the k-th token of the storage text it was made from.

export type InlineFileKind = "image" | "file";

/** The one character that stands for a chip in the flat form. */
export const CHIP_CHAR = "￼";
const chipRe = () => /￼/g;

function countChips(flat: string): number {
  return (flat.match(chipRe()) ?? []).length;
}

/** Storage → flat: each token becomes one U+FFFC. */
export function toFlat(text: string): string {
  return text.replace(tokenRe(), CHIP_CHAR);
}

/**
 * Flat → storage: the k-th U+FFFC becomes the token for `ids[k-1]`. One with no
 * id behind it is DROPPED — never guessed into somebody else's file.
 */
export function fromFlat(flat: string, ids: readonly string[]): string {
  let k = 0;
  return flat.replace(chipRe(), () => {
    const id = ids[k++];
    return id ? fileToken(id) : "";
  });
}

/**
 * Text a person typed, pasted or dropped, made fit for the field: Windows line
 * ends folded, no token syntax (a pasted `[[file:…]]` would otherwise become a
 * real placement pointing at somebody's file), and neither of the two
 * invisible characters the editor uses for itself.
 */
export function plainTextForField(s: string): string {
  return s.replace(/\r\n?/g, "\n").replace(tokenRe(), "").replace(/[￼​]/g, "");
}

/**
 * Replace the FLAT range [start, end) of storage `text` with plain `insert`.
 * Chips inside the range go; chips outside keep their ids. Returns the new
 * storage text and the flat caret after the insert.
 */
export function spliceStorage(text: string, start: number, end: number, insert: string): { text: string; caret: number } {
  const flat = toFlat(text);
  const ids = fileTokenIds(text);
  const s = Math.max(0, Math.min(start, flat.length));
  const e = Math.max(s, Math.min(end, flat.length));
  const clean = plainTextForField(insert);
  const before = flat.slice(0, s);
  const kBefore = countChips(before);
  const kGone = countChips(flat.slice(s, e));
  const nextIds = [...ids.slice(0, kBefore), ...ids.slice(kBefore + kGone)];
  return { text: fromFlat(before + clean + flat.slice(e), nextIds), caret: s + clean.length };
}

/**
 * Place file `id` at FLAT index `at` of storage `text`, padded with a space
 * either side as insertAt does (unless `spaced` is false — at the cap).
 */
export function insertFileAt(text: string, at: number, id: string, spaced = true): { text: string; caret: number } {
  const flat = toFlat(text);
  const ids = fileTokenIds(text);
  const i = Math.max(0, Math.min(at, flat.length));
  const kBefore = countChips(flat.slice(0, i));
  const placed = insertAt(flat, i, CHIP_CHAR, spaced);
  return { text: fromFlat(placed.text, [...ids.slice(0, kBefore), id, ...ids.slice(kBefore)]), caret: placed.caret };
}

/** How many person-typed characters sit in the flat range [start, end). */
export function visibleInFlatRange(text: string, start: number, end: number): number {
  return toFlat(text).slice(start, end).replace(chipRe(), "").length;
}
