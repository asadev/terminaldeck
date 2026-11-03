// Copied from the reference CRM.
import { useEffect, useRef, useState } from "react";
import type { FeedMention } from "./feed-types";

const MENTION_DEBOUNCE_MS = 200;
// GET /api/feed/people itself caps at 8 — this just guards against a
// misbehaving response handing back more than the picker was built for.
const MENTION_MAX_RESULTS = 8;

export type PickedMention = { id: string; name: string };

type Trigger = { start: number; query: string };

/** The least a mention candidate needs: something to insert and something to key on. */
export type MentionCandidate = { id: string; name: string };

/**
 * Where the "@" the caret is inside starts, and what has been typed after it.
 * A space or newline between the "@" and the caret closes the trigger —
 * matches components/mention-input.tsx's rule for the same reason: an "@"
 * left behind in a finished sentence must not reopen the picker.
 */
export function findMentionTrigger(text: string, caret: number): Trigger | null {
  const head = text.slice(0, caret);
  const at = head.lastIndexOf("@");
  if (at === -1) return null;
  // An "@" glued to the end of a word ("ss@Ab…", an email address) is not a
  // mention: it must start the text or follow whitespace. Asad's textarea
  // read "@Abdurashid Mutalibov ss@Abdurashid Mutalibov" on 2026-09-15
  // because the second "@" fired mid-word.
  if (at > 0 && !/\s/.test(head[at - 1])) return null;
  const sliceAfterAt = head.slice(at + 1);
  if (/\s/.test(sliceAfterAt)) return null;
  return { start: at, query: sliceAfterAt };
}

/**
 * THE @-MENTION MACHINERY, AS A HOOK — shared by the feed composer below and
 * the task box (components/tasks/task-text-field.tsx, 2026-09-15: Asad,
 * "type @ and see list of people and select them there").
 *
 * It owns: spotting the "@" trigger, running `search` for what is typed after
 * it (debounced, and guarded so a slow search never clobbers a faster, more
 * recent one — the classic "typed three letters, the first letter's response
 * lands last" race a debounce alone does not fix), arrow/Enter/Escape, and the
 * insertion of "@Name " over the trigger with the caret parked after it.
 *
 * `search` is injected: the feed hands it GET /api/feed/people; the task box
 * filters the team list it already holds, so a mention and the people control
 * draw from ONE list. Either may return synchronously or as a promise.
 */
/** What the hook needs from the field to park the caret after a pick — a
 *  <textarea> has both; a contenteditable field (components/tasks/
 *  task-text-field.tsx) provides an adapter with the same two calls. */
export type CaretHost = { focus: () => void; setSelectionRange: (start: number, end: number) => void };

export function useMentionTrigger<P extends MentionCandidate>({
  value,
  onChange,
  search,
  onPick,
  textareaRef,
  debounceMs = MENTION_DEBOUNCE_MS,
  maxResults = MENTION_MAX_RESULTS,
}: {
  value: string;
  onChange: (next: string) => void;
  search: (query: string) => Promise<P[]> | P[];
  onPick: (person: P) => void;
  textareaRef: React.RefObject<CaretHost | null>;
  debounceMs?: number;
  maxResults?: number;
}) {
  const [trigger, setTrigger] = useState<Trigger | null>(null);
  const [results, setResults] = useState<P[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [activeIndex, setActiveIndex] = useState(0);
  const requestIdRef = useRef(0);

  useEffect(() => {
    if (activeIndex >= results.length) setActiveIndex(0);
  }, [results, activeIndex]);

  useEffect(() => {
    if (!trigger) {
      setResults([]);
      setError(null);
      setLoading(false);
      return;
    }
    const myRequestId = ++requestIdRef.current;
    let cancelled = false;
    const run = async () => {
      try {
        const found = await search(trigger.query);
        if (cancelled || requestIdRef.current !== myRequestId) return;
        setResults(Array.isArray(found) ? found.slice(0, maxResults) : []);
      } catch (e) {
        if (cancelled || requestIdRef.current !== myRequestId) return;
        setResults([]);
        setError(e instanceof Error ? e.message : "Couldn't search people — try again.");
      } finally {
        if (!cancelled && requestIdRef.current === myRequestId) setLoading(false);
      }
    };
    setLoading(true);
    setError(null);
    const t = debounceMs > 0 ? window.setTimeout(run, debounceMs) : (run(), 0);
    return () => {
      cancelled = true;
      if (debounceMs > 0) window.clearTimeout(t);
    };
  }, [trigger, search, debounceMs, maxResults]);

  /** The field changed: `next` is its whole text, `caret` the index the caret is at. */
  function noteChange(next: string, caret: number) {
    onChange(next);
    setTrigger(findMentionTrigger(next, caret));
    setActiveIndex(0);
  }

  function handleChange(e: React.ChangeEvent<HTMLTextAreaElement>) {
    noteChange(e.target.value, e.target.selectionStart ?? e.target.value.length);
  }

  function pick(person: P) {
    if (!trigger) return;
    const before = value.slice(0, trigger.start);
    const after = value.slice(trigger.start + 1 + trigger.query.length);
    const inserted = `@${person.name} `;
    const next = before + inserted + after;
    onChange(next);
    onPick(person);
    setTrigger(null);
    const caretPos = before.length + inserted.length;
    queueMicrotask(() => {
      const el = textareaRef.current;
      if (!el) return;
      el.focus();
      el.setSelectionRange(caretPos, caretPos);
    });
  }

  /** Returns true when the key was consumed by the picker. */
  function handleKeyDown(e: React.KeyboardEvent<HTMLElement>): boolean {
    if (!trigger) return false;
    if (results.length > 0) {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setActiveIndex((i) => (i + 1) % results.length);
        return true;
      }
      if (e.key === "ArrowUp") {
        e.preventDefault();
        setActiveIndex((i) => (i - 1 + results.length) % results.length);
        return true;
      }
      if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault();
        const person = results[activeIndex];
        if (person) pick(person);
        return true;
      }
    }
    if (e.key === "Escape") {
      // Dismiss without touching the text — if the "@" wasn't meant as a
      // mention the user just keeps typing past it.
      e.preventDefault();
      e.stopPropagation();
      setTrigger(null);
      return true;
    }
    return false;
  }

  /** A short delay so a mousedown on a result (which blurs the textarea first) still lands as a click. */
  function closeSoon() {
    window.setTimeout(() => setTrigger(null), 150);
  }

  const open = trigger !== null && (loading || error !== null || results.length > 0);
  return { trigger, results, loading, error, activeIndex, setActiveIndex, open, handleChange, noteChange, handleKeyDown, pick, closeSoon, close: () => setTrigger(null) };
}

/**
 * Which picked mentions are still actually present as "@Name" in the body
 * at submit time — if someone types "@Sara" then deletes it before
 * posting, her id must not ride along in mention_ids just because it was
 * picked once. Mirrors the "@Name" + boundary check
 * components/mention-input.tsx already uses to decide the same question
 * for its own onMention() firing. Deduplicated and capped at 20 to match
 * POST /api/feed's own `mention_ids` limit.
 */
export function computeMentionIds(body: string, picked: PickedMention[]): string[] {
  const ids: string[] = [];
  const seen = new Set<string>();
  for (const m of picked) {
    if (seen.has(m.id)) continue;
    const escaped = m.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`@${escaped}(?:[\\s.,!?;:)]|$)`);
    if (re.test(body)) {
      ids.push(m.id);
      seen.add(m.id);
    }
  }
  return ids.slice(0, 20);
}

/**
 * Renders a post body with every "@Name" that GET /api/feed resolved as a
 * mention (the post's own `mentions` array) turned into a highlighted link
 * to that person's /agents/<id> page — the only profile-shaped route this
 * app has for a person id. A mention whose id came back empty/malformed is
 * still highlighted but left unlinked rather than shipping a dead href.
 * Anything in the body that merely LOOKS like "@word" but isn't in the
 * `mentions` list (someone typed an email address, or "@" as punctuation)
 * is left as plain text — the split only ever matches names the server
 * itself resolved, never a raw regex guess over the body.
 */
export function MentionedBody({ body, mentions }: { body: string; mentions?: FeedMention[] }) {
  const valid = (mentions ?? []).filter((m) => m.name.trim().length > 0);
  if (valid.length === 0) return <>{body}</>;

  // Longest name first so "Ali" doesn't swallow half of "Ali Khan" when
  // both are mentioned on the same post.
  const byNameDesc = [...valid].sort((a, b) => b.name.length - a.name.length);
  const idByName = new Map(byNameDesc.map((m) => [m.name, m.id]));
  const escaped = byNameDesc.map((m) => m.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const re = new RegExp(`@(${escaped.join("|")})(?=[\\s.,!?;:)]|$)`, "g");

  const nodes: React.ReactNode[] = [];
  let last = 0;
  let match: RegExpExecArray | null;
  let key = 0;
  while ((match = re.exec(body)) !== null) {
    if (match.index > last) nodes.push(body.slice(last, match.index));
    const name = match[1];
    nodes.push(<MentionChip key={`m-${key++}`} id={idByName.get(name)} name={name} />);
    last = match.index + match[0].length;
  }
  if (last < body.length) nodes.push(body.slice(last));
  return <>{nodes}</>;
}

function MentionChip({ id, name }: { id: string | undefined; name: string }) {
  const style: React.CSSProperties = {
    color: "var(--primary-active)",
    background: "var(--primary-soft)",
    borderRadius: "var(--r-2)",
    padding: "0 3px",
    fontWeight: 600,
  };
  // The CRM links a mention to the person's profile page; local people have no page, so it is the chip alone.
  return <span style={style} data-person={id}>@{name}</span>;
}
