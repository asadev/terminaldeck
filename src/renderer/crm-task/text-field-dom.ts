// Copied from the reference CRM.
/**
 * THE TASK TEXT EDITOR'S DOM — how the storage string becomes nodes, and back.
 *
 * task-text-field.tsx is a contenteditable <div> (a textarea cannot draw a
 * picture, and Asad wants the REAL photo in the line: *"it should show small
 * icon or thumbnail of real photo"*, 2026-09-15). React does not own its
 * children: the browser edits them as the person types, and these helpers
 * turn the storage string (lib/tasks/inline-files.ts) into nodes, the nodes
 * back into the storage string, and a caret into a FLAT index (one character
 * per chip) and back.
 *
 * THE CANONICAL SHAPE the field is always put back into:
 *   · text runs are plain text nodes (the div is `white-space: pre-wrap`, so a
 *     "\n" is a line break — no <br>, no <div> per line);
 *   · each `[[file:<id>]]` is `<span contenteditable="false" data-file-id>`
 *     holding an <img> (an image with a source) or a small SVG glyph;
 *   · a ZERO-WIDTH SPACE text node sits where a caret would otherwise have
 *     nowhere to go — before a chip that opens the text, after a chip that
 *     ends it or is followed by another chip or a line break, and after a
 *     trailing "\n" (without it the new empty line does not render). The
 *     serialiser drops every U+200B, so it never reaches storage.
 * Anything else the browser leaves behind (a <br> in an emptied field, a <div>
 * from an undo, a styled <span>) is read tolerantly by `serialise` and the
 * caller re-renders the canonical shape.
 */
import { CHIP_CHAR, fileToken, splitInlineFiles, toFlat, type InlineFileKind } from "../../shared/crm/inline-files";

export const ZWSP = "​";
const INVISIBLE = /[​￼]/g;
const ID_RE = /^(?:draft:)?[A-Za-z0-9_-]+$/;

const TEXT = 3;
const ELEMENT = 1;
const FRAGMENT = 11;

/** What a chip needs to draw itself. */
export type InlineFileInfo = {
  kind: InlineFileKind;
  /** The picture: an object URL for a draft, the signed GET route for a saved upload. */
  src?: string | null;
  /** The file's name — hover text and the lightbox's alt. */
  name?: string | null;
};

// lucide's "file-text" and "image" glyphs (ISC), inlined because the chips are
// built outside React. Constant strings, never interpolated.
const SVG_OPEN =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="width:0.85em;height:0.85em">';
const FILE_SVG = `${SVG_OPEN}<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/></svg>`;
const IMAGE_SVG = `${SVG_OPEN}<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/></svg>`;

/** Text-height, rounded, cover-cropped — the read mode's thumbnail, in the editor. */
export const CHIP_CLASS =
  "mx-0.5 inline-flex h-[1.4em] w-[1.4em] cursor-pointer select-none items-center justify-center overflow-hidden rounded bg-slate-100 align-text-bottom text-slate-500 ring-1 ring-slate-200 hover:ring-slate-400";

export function isChip(n: Node | null | undefined): n is HTMLElement {
  return !!n && n.nodeType === ELEMENT && (n as Element).hasAttribute("data-file-id");
}

/** Draw (or redraw) a chip. Idempotent: an unchanged chip is not touched, so its <img> never reloads. */
export function paintChip(span: HTMLElement, info: InlineFileInfo): void {
  const src = info.kind === "image" && info.src ? info.src : "";
  const key = `${info.kind}|${src}|${info.name ?? ""}`;
  if (span.getAttribute("data-painted") === key) return;
  span.setAttribute("data-painted", key);
  span.setAttribute("data-kind", info.kind);
  const label = info.name || (info.kind === "image" ? "Image" : "File");
  span.setAttribute("title", info.kind === "image" && src ? `${label} — click for the big view` : label);
  span.setAttribute("role", "img");
  span.setAttribute("aria-label", label);
  if (src) {
    const img = span.ownerDocument.createElement("img");
    img.setAttribute("src", src);
    img.setAttribute("alt", "");
    img.setAttribute("draggable", "false");
    img.className = "h-full w-full object-cover";
    span.replaceChildren(img);
  } else {
    span.innerHTML = info.kind === "image" ? IMAGE_SVG : FILE_SVG;
  }
}

function makeChip(doc: Document, id: string, info: InlineFileInfo): HTMLElement {
  const span = doc.createElement("span");
  span.setAttribute("contenteditable", "false");
  span.setAttribute("data-file-id", id);
  span.className = CHIP_CLASS;
  paintChip(span, info);
  return span;
}

/** Replace the field's content with the canonical nodes for storage `text`. */
export function renderStorage(root: HTMLElement, text: string, infoOf: (id: string) => InlineFileInfo): void {
  const doc = root.ownerDocument;
  const frag = doc.createDocumentFragment();
  const parts = splitInlineFiles(text);
  parts.forEach((p, i) => {
    if (p.kind === "text") {
      frag.appendChild(doc.createTextNode(p.text));
      return;
    }
    if (i === 0) frag.appendChild(doc.createTextNode(ZWSP));
    frag.appendChild(makeChip(doc, p.id, infoOf(p.id)));
    const next = parts[i + 1];
    if (!next || next.kind === "file" || next.text.startsWith("\n")) frag.appendChild(doc.createTextNode(ZWSP));
  });
  if (text.endsWith("\n")) frag.appendChild(doc.createTextNode(ZWSP));
  root.replaceChildren(frag);
}

/** Is the field in the shape renderStorage makes? (Text nodes with content, and chips.) */
export function isCanonical(root: HTMLElement): boolean {
  for (const n of Array.from(root.childNodes)) {
    if (n.nodeType === TEXT) {
      if (!n.nodeValue) return false;
      continue;
    }
    if (!isChip(n)) return false;
  }
  return true;
}

const BLOCK = new Set(["DIV", "P", "LI"]);

/**
 * The storage string a subtree says. Tolerant of what browsers insert: a
 * <div>/<p> starts a new line, a <br> is a line break unless it is the lone
 * placeholder of an empty block, any other element is read for its text.
 */
export function serialise(root: Node): string {
  let out = "";
  const visit = (n: Node, walkRoot: boolean) => {
    if (n.nodeType === TEXT) {
      out += (n.nodeValue ?? "").replace(INVISIBLE, "");
      return;
    }
    if (n.nodeType !== ELEMENT && n.nodeType !== FRAGMENT) return;
    if (n.nodeType === ELEMENT) {
      const el = n as Element;
      const id = el.getAttribute("data-file-id");
      if (id !== null) {
        if (ID_RE.test(id)) out += fileToken(id);
        return;
      }
      if (el.tagName === "BR") {
        // A <br> that ENDS its parent is the browser's placeholder that keeps
        // a line open (Chrome leaves one after the last character following a
        // chip is deleted) — not a line break the person typed. Ours never
        // uses <br>: Enter inserts "\n" text.
        if (el.nextSibling) out += "\n";
        return;
      }
      if (!walkRoot && BLOCK.has(el.tagName) && out.length > 0 && !out.endsWith("\n")) out += "\n";
    }
    n.childNodes.forEach((c) => visit(c, false));
  };
  visit(root, true);
  return out;
}

/** The FLAT index of a DOM point inside `root` — everything before it, serialised, flattened, counted. */
export function flatOffset(root: HTMLElement, node: Node, offset: number): number {
  const r = root.ownerDocument.createRange();
  r.setStart(root, 0);
  try {
    r.setEnd(node, offset);
  } catch {
    return toFlat(serialise(root)).length;
  }
  return toFlat(serialise(r.cloneContents())).length;
}

/** The selection inside the field, as flat indexes — null when it is elsewhere. */
export function readSelection(root: HTMLElement): { start: number; end: number } | null {
  const sel = root.ownerDocument.getSelection();
  if (!sel || sel.rangeCount === 0) return null;
  const r = sel.getRangeAt(0);
  if (!root.contains(r.startContainer) || !root.contains(r.endContainer)) return null;
  const start = flatOffset(root, r.startContainer, r.startOffset);
  const end = r.collapsed ? start : flatOffset(root, r.endContainer, r.endOffset);
  return { start: Math.min(start, end), end: Math.max(start, end) };
}

/** Put the caret at FLAT index `index` of a canonical field (past the end = the end). */
export function placeCaret(root: HTMLElement, index: number): void {
  const doc = root.ownerDocument;
  const sel = doc.getSelection();
  if (!sel) return;
  const range = doc.createRange();
  let left = Math.max(0, index);
  const kids = Array.from(root.childNodes);
  let placed = false;
  for (let i = 0; i < kids.length && !placed; i++) {
    const n = kids[i];
    if (n.nodeType === TEXT) {
      const data = n.nodeValue ?? "";
      if (left === 0) {
        range.setStart(n, 0);
        placed = true;
        break;
      }
      let off = 0;
      while (off < data.length && left > 0) {
        if (data[off] !== ZWSP && data[off] !== CHIP_CHAR) left--;
        off++;
      }
      if (left === 0) {
        range.setStart(n, off);
        placed = true;
      }
    } else if (isChip(n)) {
      if (left === 0) {
        range.setStartBefore(n);
        placed = true;
        break;
      }
      left--;
      if (left === 0) {
        // Just after the chip: inside the text that follows it, past its
        // zero-width space, so typed characters land in a text node.
        const next = kids[i + 1];
        if (next && next.nodeType === TEXT) {
          range.setStart(next, (next.nodeValue ?? "").startsWith(ZWSP) ? 1 : 0);
        } else {
          range.setStartAfter(n);
        }
        placed = true;
      }
    }
  }
  if (!placed) {
    range.selectNodeContents(root);
    range.collapse(false);
  } else {
    range.collapse(true);
  }
  sel.removeAllRanges();
  sel.addRange(range);
}

/** Where the caret is, in px, relative to `base` — for hanging the @mention list off it. */
export function caretBox(root: HTMLElement, base: HTMLElement): { top: number; left: number; height: number } | null {
  const sel = root.ownerDocument.getSelection();
  if (!sel || sel.rangeCount === 0) return null;
  const r = sel.getRangeAt(0).cloneRange();
  if (!root.contains(r.startContainer)) return null;
  r.collapse(true);
  if (typeof r.getBoundingClientRect !== "function") return null;
  let rect = r.getBoundingClientRect();
  if (!rect || (rect.top === 0 && rect.left === 0 && rect.height === 0)) {
    // A collapsed range between nodes can measure as nothing; the line's
    // start is a better answer than the page's corner.
    const el = r.startContainer.nodeType === ELEMENT ? (r.startContainer as Element) : r.startContainer.parentElement;
    if (!el) return null;
    rect = el.getBoundingClientRect();
  }
  const b = base.getBoundingClientRect();
  return { top: rect.top - b.top, left: rect.left - b.left, height: rect.height || 20 };
}

/** The DOM point under a screen position (a drop), where the browser can say. */
export function caretPointFromXY(doc: Document, x: number, y: number): { node: Node; offset: number } | null {
  const d = doc as Document & {
    caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null;
    caretRangeFromPoint?: (x: number, y: number) => Range | null;
  };
  if (typeof d.caretPositionFromPoint === "function") {
    const p = d.caretPositionFromPoint(x, y);
    if (p) return { node: p.offsetNode, offset: p.offset };
  }
  if (typeof d.caretRangeFromPoint === "function") {
    const r = d.caretRangeFromPoint(x, y);
    if (r) return { node: r.startContainer, offset: r.startOffset };
  }
  return null;
}
