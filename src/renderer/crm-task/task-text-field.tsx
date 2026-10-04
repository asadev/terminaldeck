// Copied from the reference CRM.
import { forwardRef, useCallback, useEffect, useImperativeHandle, useLayoutEffect, useMemo, useRef, useState } from "react";
import { cn } from "./lib/utils";
import { PersonAvatar } from "./people/person-picker";
import { AnchoredPopover } from "./anchored-popover";
import { TaskLightbox } from "./task-lightbox";
import { useMentionTrigger, type CaretHost } from "./feed/mention";
import {
  CHIP_CHAR,
  VISIBLE_TITLE_MAX,
  fileTokenIds,
  fromFlat,
  insertFileAt,
  spliceStorage,
  toFlat,
  truncateVisible,
  visibleInFlatRange,
  visibleLength,
} from "../../shared/crm/inline-files";
import {
  caretBox,
  caretPointFromXY,
  isCanonical,
  paintChip,
  placeCaret,
  readSelection,
  renderStorage,
  serialise,
  type InlineFileInfo,
} from "./text-field-dom";
import type { TaskAssignee } from "../../shared/crm/tasks-data";

export type { InlineFileInfo };

/**
 * THE TASK TEXT — a small editor that knows three things a plain field does not.
 *
 *   1. FILES IN THE LINE, AS THE REAL THING. Asad, 2026-09-15, looking at the
 *      `[🖼1]` markers the textarea used to show: *"it should show small icon
 *      or thumbnail of real photo … only small icons"*. A textarea cannot draw
 *      a picture, so this is a contenteditable <div>. Each `[[file:<id>]]`
 *      token in `value` is drawn as a non-editable chip the height of the
 *      text: an image is its actual thumbnail (a draft's object URL, or the
 *      signed GET route once saved), any other file a small glyph. Backspace
 *      or Delete over a chip removes that placement; arrows step over it; a
 *      click on a picture opens the big view. `insertFile` puts one at the
 *      caret — where a drop, paste or paperclip pick lands.
 *
 *   2. @MENTIONS (Asad, 2026-09-15: "type @ and see list of people and select
 *      them there"). The feed composer's own hook (components/feed/
 *      mention.tsx), fed the FLAT form of the text (lib/tasks/inline-files.ts:
 *      one U+FFFC per chip), so a caret is a plain index and the hook needs no
 *      idea that files exist. It parks the caret through a CaretHost adapter.
 *
 *   3. THE CAP counts the person's words, not the chips (visibleLength). Typing
 *      at the cap is refused; a paste that overshoots is cut to fit.
 *
 * THE VALUE IS STILL THE PLAIN STRING. React does not own the editor's
 * children (text-field-dom.ts draws them). Every input is serialised back to
 * the storage string at once and handed to `onChange`, so Rewrite, the cap,
 * save and the list see exactly what they saw with the textarea. A change
 * that comes from OUTSIDE (Rewrite, Revert, the mic) redraws the editor.
 * Pastes are plain text only; formatting shortcuts do nothing.
 */

export type TaskTextFieldHandle = {
  /**
   * Put a file at the caret (or the end when the caret is not in the field).
   * `info` travels WITH the id: the row was added to the caller's state a
   * moment ago and `fileOf` may not have seen it yet this tick.
   */
  insertFile: (attachmentId: string, info: InlineFileInfo) => void;
  /** Plain text at the caret — the comment box's emoji. */
  insertText: (text: string) => void;
  /** The comment box's @ button: an "@" at a word start at the caret, which opens the people list. */
  startMention: () => void;
  focus: () => void;
};

export const TaskTextField = forwardRef<
  TaskTextFieldHandle,
  {
    value: string;
    onChange: (next: string) => void;
    team: TaskAssignee[];
    onMention: (person: TaskAssignee) => void;
    /** What a placed file looks like: image or file, its picture, its name. Unknown ids draw as files. */
    fileOf: (attachmentId: string) => InlineFileInfo | null | undefined;
    placeholder?: string;
    ariaLabel?: string;
    autoFocus?: boolean;
    className?: string;
    style?: React.CSSProperties;
    /** Escape while no menu is open — the caller may want to cancel an edit. */
    onEscape?: () => void;
    /** The person's characters allowed (tokens not counted). The task text is 300; the comment box more. */
    maxVisible?: number;
    /** ⌘↵ / Ctrl+↵ — the comment box sends. */
    onSubmit?: () => void;
    /** "/" typed into an empty field — the comment box opens its slash commands (ClickUp's). */
    onSlash?: () => void;
  }
>(function TaskTextField(
  { value, onChange, team, onMention, fileOf, placeholder, ariaLabel, autoFocus, className, style, onEscape, maxVisible, onSubmit, onSlash },
  ref,
) {
  const cap = maxVisible ?? VISIBLE_TITLE_MAX;
  const rootRef = useRef<HTMLDivElement | null>(null);
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const anchorRef = useRef<HTMLSpanElement | null>(null);
  const [anchor, setAnchor] = useState<{ top: number; left: number; height: number } | null>(null);
  const [lightbox, setLightbox] = useState<{ photos: { id: string; url: string }[]; index: number } | null>(null);

  // Files this field placed itself: the caller's `fileOf` lags by a render,
  // and two files dropped together must both draw NOW.
  const known = useRef(new Map<string, InlineFileInfo>());
  const infoOf = useCallback(
    (id: string): InlineFileInfo => {
      const k = known.current.get(id);
      const f = fileOf(id);
      return { kind: f?.kind ?? k?.kind ?? "file", src: f?.src ?? k?.src ?? null, name: f?.name ?? k?.name ?? null };
    },
    [fileOf],
  );
  const infoRef = useRef(infoOf);
  infoRef.current = infoOf;

  // `latest`: the newest STORAGE value, ahead of React by up to a render, so
  // two inserts in one tick build on each other. `synced`: what the editor's
  // DOM shows right now — when it equals the incoming value there is nothing
  // to redraw, and the person's caret is left exactly where it is.
  const latest = useRef(value);
  latest.current = value;
  const synced = useRef<string | null>(null);
  const composing = useRef(false);
  // The last caret the person left in the field. A toolbar button (the comment
  // box's emoji, @, 📎) takes focus; focusing the field again must put the text
  // THERE, not at the start (jsdom resets a contenteditable's selection on
  // focus; browsers differ). Read BEFORE focusing, falling back to this.
  const lastSel = useRef<{ start: number; end: number } | null>(null);

  /** Draw `text` into the editor now; park the caret at a flat index if given. */
  const show = useCallback((text: string, caret: number | null) => {
    const el = rootRef.current;
    if (!el) return;
    renderStorage(el, text, infoRef.current);
    synced.current = text;
    if (caret !== null) {
      placeCaret(el, caret);
      lastSel.current = { start: caret, end: caret };
    }
  }, []);

  // The mention hook changes the FLAT text; the chips it knows nothing about
  // keep their ids by order.
  const commitFlat = useCallback(
    (flat: string) => {
      let next = fromFlat(flat, fileTokenIds(latest.current));
      if (visibleLength(next) > cap) next = truncateVisible(next, cap);
      latest.current = next;
      if (synced.current !== next) show(next, null);
      onChange(next);
    },
    [onChange, show, cap],
  );

  const search = useCallback(
    (q: string) => {
      const needle = q.trim().toLowerCase();
      return team.filter((p) => !needle || p.name.toLowerCase().includes(needle)).slice(0, 8);
    },
    [team],
  );

  // What the hook calls to put the caret after a pick. The editor is already
  // redrawn by then (commitFlat draws synchronously).
  const host = useRef<CaretHost>({
    focus: () => rootRef.current?.focus(),
    setSelectionRange: (start) => {
      const el = rootRef.current;
      if (el) placeCaret(el, start);
    },
  });

  const flatValue = useMemo(() => toFlat(value), [value]);
  const mention = useMentionTrigger<TaskAssignee>({
    value: flatValue,
    onChange: commitFlat,
    search,
    onPick: onMention,
    textareaRef: host,
    debounceMs: 0,
  });

  const placeAnchor = useCallback(() => {
    const el = rootRef.current;
    const w = wrapRef.current;
    if (el && w) setAnchor(caretBox(el, w));
  }, []);

  // ── a change from OUTSIDE (first mount, Rewrite, Revert, the mic): redraw ──
  useLayoutEffect(() => {
    const el = rootRef.current;
    if (!el || synced.current === value) return;
    const focused = el.ownerDocument.activeElement === el;
    show(value, focused ? toFlat(value).length : null);
  }, [value, show]);

  // A draft's picture arrives a render after its chip (the object URL is made
  // in an effect): repaint the chips in place, caret untouched.
  useLayoutEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    el.querySelectorAll<HTMLElement>("[data-file-id]").forEach((s) => paintChip(s, infoOf(s.getAttribute("data-file-id") ?? "")));
  }, [infoOf]);

  useLayoutEffect(() => {
    const el = rootRef.current;
    if (!autoFocus || !el) return;
    el.focus();
    placeCaret(el, toFlat(latest.current).length);
    // Mount only: autoFocus is a first-render instruction.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /** Replace the flat range with plain text — Enter, a paste, a drop of text, a chip deleted. */
  const replaceRange = useCallback(
    (start: number, end: number, insert: string) => {
      if (!rootRef.current) return;
      const cur = latest.current;
      const room = cap - (visibleLength(cur) - visibleInFlatRange(cur, start, end));
      const clean = insert.slice(0, Math.max(0, room));
      if (!clean && start === end) return;
      const { text, caret } = spliceStorage(cur, start, end, clean);
      latest.current = text;
      show(text, caret);
      mention.noteChange(toFlat(text), caret);
      placeAnchor();
    },
    [mention, placeAnchor, show, cap],
  );
  const replaceRef = useRef(replaceRange);
  replaceRef.current = replaceRange;

  const endRange = () => {
    const n = toFlat(latest.current).length;
    return { start: n, end: n };
  };

  useEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    const doc = el.ownerDocument;
    const onSel = () => {
      const s = readSelection(el);
      if (s) lastSel.current = s;
    };
    doc.addEventListener("selectionchange", onSel);
    return () => doc.removeEventListener("selectionchange", onSel);
  }, []);

  /** Where an insert goes: the live caret if it is in the field, else the last one it had, else the end. */
  const caretForInsert = () => {
    const el = rootRef.current;
    const live = el ? readSelection(el) : null;
    const n = toFlat(latest.current).length;
    const s = live ?? lastSel.current ?? { start: n, end: n };
    return { start: Math.min(s.start, n), end: Math.min(s.end, n) };
  };

  // Line breaks from a soft keyboard (no Enter keydown) and formatting
  // commands arrive only as native `beforeinput`.
  useEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    const onBefore = (ev: Event) => {
      const t = (ev as InputEvent).inputType ?? "";
      if (t.startsWith("format")) {
        ev.preventDefault();
        return;
      }
      if (t === "insertParagraph" || t === "insertLineBreak") {
        ev.preventDefault();
        const s = readSelection(el) ?? endRange();
        replaceRef.current(s.start, s.end, "\n");
      }
    };
    el.addEventListener("beforeinput", onBefore);
    return () => el.removeEventListener("beforeinput", onBefore);
  }, []);

  /** The person typed (or deleted plain text): read the editor back. */
  function handleInput() {
    if (composing.current) return;
    const el = rootRef.current;
    if (!el) return;
    const prev = latest.current;
    let next = serialise(el);
    const caret = readSelection(el)?.end ?? toFlat(next).length;
    if (onSlash && prev === "" && next === "/") {
      // ClickUp: "/" in an empty comment box opens the commands, not a slash.
      show("", 0);
      onSlash();
      return;
    }
    if (visibleLength(next) > cap) {
      if (visibleLength(next) - visibleLength(prev) <= 1) {
        show(prev, Math.max(0, caret - 1)); // one keystroke past the cap: refused, as maxLength would
        return;
      }
      next = truncateVisible(next, cap);
      show(next, Math.min(caret, toFlat(next).length));
    } else if (!isCanonical(el)) {
      show(next, caret); // the browser left a <br> / <div> / styled span: put the canonical shape back
    } else {
      synced.current = next;
    }
    latest.current = next;
    lastSel.current = { start: caret, end: caret };
    mention.noteChange(toFlat(next), caret);
    placeAnchor();
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLDivElement>) {
    if (mention.handleKeyDown(e)) return;
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && onSubmit) {
      e.preventDefault();
      onSubmit();
      return;
    }
    if (e.key === "Escape" && onEscape) {
      e.preventDefault();
      e.stopPropagation();
      onEscape();
      return;
    }
    if ((e.metaKey || e.ctrlKey) && /^[biu]$/i.test(e.key)) {
      e.preventDefault(); // plain text: no bold / italic / underline
      return;
    }
    const el = rootRef.current;
    if (!el || composing.current || e.nativeEvent.isComposing) return;
    if (e.key === "Enter") {
      e.preventDefault();
      const s = readSelection(el) ?? endRange();
      replaceRange(s.start, s.end, "\n");
      return;
    }
    if (e.key === "Backspace" || e.key === "Delete") {
      const s = readSelection(el);
      if (!s) return;
      const flat = toFlat(latest.current);
      let { start, end } = s;
      if (start === end) {
        if (e.key === "Backspace" && start > 0 && flat[start - 1] === CHIP_CHAR) start -= 1;
        else if (e.key === "Delete" && end < flat.length && flat[end] === CHIP_CHAR) end += 1;
        else return; // a character: the browser deletes it and handleInput reads the result
      } else if (!flat.slice(start, end).includes(CHIP_CHAR)) {
        return;
      }
      e.preventDefault();
      replaceRange(start, end, "");
    }
  }

  function handlePaste(e: React.ClipboardEvent<HTMLDivElement>) {
    const cd = e.clipboardData;
    const carriesFile = Array.from(cd?.items ?? []).some((i) => i.kind === "file") || (cd?.files?.length ?? 0) > 0;
    if (carriesFile) return; // the box's paste door takes files (use-file-drop.ts), at this caret
    e.preventDefault(); // never rich HTML into the text
    const el = rootRef.current;
    const text = cd?.getData("text/plain") ?? "";
    if (!el || !text) return;
    const s = readSelection(el) ?? endRange();
    replaceRange(s.start, s.end, text);
  }

  function handleDrop(e: React.DragEvent<HTMLDivElement>) {
    const el = rootRef.current;
    if (!el) return;
    // Wherever it is dropped on the text is where it goes — a file too, which
    // the box's drop door then places at this caret.
    const pt = caretPointFromXY(el.ownerDocument, e.clientX, e.clientY);
    const sel = el.ownerDocument.getSelection();
    if (pt && sel && el.contains(pt.node)) {
      const r = el.ownerDocument.createRange();
      r.setStart(pt.node, pt.offset);
      r.collapse(true);
      sel.removeAllRanges();
      sel.addRange(r);
    }
    if (Array.from(e.dataTransfer?.types ?? []).includes("Files")) return;
    e.preventDefault();
    const text = e.dataTransfer?.getData("text/plain") ?? "";
    if (!text) return;
    const s = readSelection(el) ?? endRange();
    replaceRange(s.start, s.end, text);
  }

  function handleClick(e: React.MouseEvent<HTMLDivElement>) {
    placeAnchor();
    const chip = (e.target as Element).closest?.("[data-file-id]");
    if (!chip) return;
    const id = chip.getAttribute("data-file-id") ?? "";
    const seen = new Set<string>();
    const photos = fileTokenIds(latest.current).flatMap((fid) => {
      if (seen.has(fid)) return [];
      seen.add(fid);
      const i = infoOf(fid);
      return i.kind === "image" && i.src ? [{ id: fid, url: i.src }] : [];
    });
    const index = photos.findIndex((p) => p.id === id);
    if (index >= 0) setLightbox({ photos, index });
  }

  useImperativeHandle(
    ref,
    () => ({
      insertFile(attachmentId, info) {
        known.current.set(attachmentId, info);
        const el = rootRef.current;
        const cur = latest.current;
        // The caret the person left in the text — it survives a click on the
        // paperclip — else the end.
        const at = caretForInsert().end;
        let placed = insertFileAt(cur, at, attachmentId);
        if (visibleLength(placed.text) > cap) {
          // At the cap the spaces around the chip are what overflow; place it bare.
          placed = insertFileAt(cur, at, attachmentId, false);
          if (visibleLength(placed.text) > cap) placed = { ...placed, text: truncateVisible(placed.text, cap) };
        }
        latest.current = placed.text;
        el?.focus();
        show(placed.text, placed.caret);
        onChange(placed.text);
      },
      insertText(text) {
        const el = rootRef.current;
        if (!el) return;
        const s = caretForInsert();
        el.focus();
        replaceRange(s.start, s.end, text);
      },
      startMention() {
        const el = rootRef.current;
        if (!el) return;
        const s = caretForInsert();
        el.focus();
        const before = toFlat(latest.current).slice(0, s.start);
        replaceRange(s.start, s.end, before && !/\s$/.test(before) ? " @" : "@");
      },
      focus() {
        const el = rootRef.current;
        if (!el) return;
        el.focus();
        if (!readSelection(el)) placeCaret(el, toFlat(latest.current).length);
      },
    }),
    // endRange reads refs only; replaceRange carries everything else.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [onChange, show, replaceRange, cap],
  );

  return (
    <div ref={wrapRef} className="relative">
      <div
        ref={rootRef}
        role="textbox"
        aria-multiline="true"
        aria-label={ariaLabel}
        aria-placeholder={placeholder}
        data-placeholder={placeholder}
        data-testid="task-text-field"
        contentEditable
        suppressContentEditableWarning
        tabIndex={0}
        spellCheck
        onInput={handleInput}
        onKeyDown={handleKeyDown}
        onKeyUp={(e) => {
          if (e.key.startsWith("Arrow")) placeAnchor();
        }}
        onClick={handleClick}
        onBlur={mention.closeSoon}
        onPaste={handlePaste}
        onDrop={handleDrop}
        onCompositionStart={() => {
          composing.current = true;
        }}
        onCompositionEnd={() => {
          composing.current = false;
          handleInput();
        }}
        style={style}
        className={cn(
          "overflow-y-auto whitespace-pre-wrap break-words outline-none",
          "empty:before:pointer-events-none empty:before:text-slate-400 empty:before:content-[attr(data-placeholder)]",
          className,
        )}
      />
      {/* The caret anchor — sized to the line so the list opens UNDER the caret. */}
      <span
        ref={anchorRef}
        aria-hidden
        className="pointer-events-none absolute w-px"
        style={{ top: anchor?.top ?? 0, left: anchor?.left ?? 0, height: anchor?.height ?? 0 }}
      />
      <AnchoredPopover anchorRef={anchorRef} open={mention.open} onClose={mention.close} label="Mention someone" width={280}>
        <div role="listbox" aria-label="People" data-testid="mention-list">
          {mention.results.length === 0 ? (
            <div className="px-3 py-2 text-xs text-slate-500">No one matches “{mention.trigger?.query}”.</div>
          ) : (
            mention.results.map((p, i) => (
              <button
                key={p.id}
                type="button"
                role="option"
                aria-selected={i === mention.activeIndex}
                onMouseDown={(e) => e.preventDefault()} // keep the editor focused so onBlur can't beat the click
                onMouseEnter={() => mention.setActiveIndex(i)}
                onClick={() => mention.pick(p)}
                className={cn(
                  "flex w-full items-center gap-2 px-2.5 py-1.5 text-left text-sm text-slate-800",
                  i === mention.activeIndex ? "bg-slate-100" : "hover:bg-slate-50",
                )}
              >
                <PersonAvatar name={p.name} initials={p.initials} color={p.color} avatarUrl={p.avatarUrl} size="xs" />
                <span className="min-w-0 flex-1 truncate">{p.name}</span>
              </button>
            ))
          )}
        </div>
      </AnchoredPopover>
      {lightbox && <TaskLightbox photos={lightbox.photos} index={lightbox.index} onClose={() => setLightbox(null)} />}
    </div>
  );
});
