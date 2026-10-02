/**
 * How a tool types into a session: a line, or the keys a person presses.
 *
 * ## The rule this file exists to hold
 *
 * **A message and its carriage return are two writes, never one.** The agent
 * CLIs classify each stdin chunk before they look at the keys inside it, and a
 * chunk of about 64 bytes or more is *pasted text*, where a carriage return is a
 * newline rather than submit. So `write(id, text + '\r')` types the message into
 * the agent's input box and leaves it there — for almost every real prompt, since
 * almost every real prompt is longer than half a line.
 *
 * This repository has paid for that three times. `brief.ts` found it first
 * (*"a 271-character burst arriving in one pty write is a paste"*), the account
 * switch's replay found it second (`switch-later.ts`, `replayWrites`), and the
 * chat composers found it third, in four places at once
 * (`renderer/chat/attach/one-write-never-submits.test.ts`, commit 4bde795). And
 * `sessions.send` in `catalogue.ts` was still doing it on the day this file was
 * written — a remote AI's "send" was a paste that never submitted, which is the
 * whole of "start sessions, drive sessions, look for the answers" failing at the
 * second verb. The fix there is a call to {@link typeLine}, which is the same
 * sequence `replayWrites` names, with the same measured gap between the halves.
 *
 * ## Keys are a different thing from text, on purpose
 *
 * `sanitizeSendText` refuses every control character, and it is right to: a
 * message that could carry `\x1b` or `\x03` is a keyboard wearing the costume of
 * a sentence. But an agent stopped on a permission menu is waiting for exactly
 * those — an arrow, an Enter, an Escape, a `2` — and a remote AI that could only
 * type sentences could start a session and never get it past its first
 * question.
 *
 * So keys arrive *by name*, from a closed table, one key per name. A call can
 * press Escape; it cannot smuggle an arbitrary escape sequence, because there is
 * no name for one. The single exception is one printable character, which is
 * what a menu choice is (`y`, `n`, `1`), and is no wider than `sessions.send`
 * already is.
 *
 * Each key is its own write with a gap after it. Two keys arriving in one chunk
 * are read as one input event by an Ink-based CLI, and Escape followed at once by
 * a digit is not "Escape, then 1" — it is Alt-1. The gap after Escape is longer
 * than the others because a lone ESC byte is ambiguous by construction: the
 * reader has to wait to learn that nothing follows it.
 */

import { REPLAY_SUBMIT_GAP_MS, replayWrites } from '../switch-later'

/**
 * The gap between the typed text and its Enter, and between two keys.
 *
 * The same 50ms `switch-later.ts` measured and named — *"written back to back
 * the two are read as one chunk and nothing is sent; 30ms apart submits"* —
 * imported rather than restated so the two paths into a session cannot drift.
 */
export const KEY_GAP_MS = REPLAY_SUBMIT_GAP_MS

/**
 * How long to leave after a lone Escape before the next byte.
 *
 * An escape byte on its own is only known to be the Escape *key* once enough time
 * has passed that nothing else arrived; a terminal app decides that with a timer
 * of its own. 150ms is comfortably past the ones the agent CLIs use and is still
 * far below anything a person would call a pause.
 */
export const ESCAPE_GAP_MS = 150

/** Most keys one call may press. A menu needs a handful; a loop needs a cap. */
export const MAX_KEYS = 24

export type Write = (data: string) => void
export type Sleep = (ms: number) => Promise<void>

export const realSleep: Sleep = (ms) => new Promise((done) => setTimeout(done, ms))

/**
 * Type one line into a session, and submit it when asked — as two writes.
 *
 * `replayWrites` supplies both halves, including its other measured rule: a line
 * containing an `@` gets one trailing space before an Enter, or the CLI's file
 * completion popup eats the Enter and the line collapses to a bare path. Asking
 * for no submit gets the text alone, with no space nobody typed.
 */
export async function typeLine(write: Write, text: string, submit: boolean, sleep: Sleep = realSleep): Promise<void> {
  const [typed, enter] = replayWrites(text, submit)
  write(typed)
  if (!submit) return
  await sleep(KEY_GAP_MS)
  write(enter)
}

/** One named key: what it is called, what a person would call it, and its bytes. */
interface NamedKey {
  bytes: string
  /** Said back in the result and the confirmation, so a person reads a key, not a byte. */
  label: string
}

/**
 * Every key a call may name.
 *
 * The cursor keys are the ordinary (not "application") forms, which is what an
 * Ink-based CLI reads either way and what a shell's line editor reads in its
 * default mode. Ctrl keys are the ones a person driving an agent actually uses:
 * C to interrupt, D to end input, L to redraw, U to clear the line, R to search
 * history, O and T for the CLIs that bind them. Ctrl-Z is deliberately absent —
 * it suspends the agent into the background of its own shell, and getting it
 * back needs a `fg` typed at a prompt this app then cannot see.
 */
export const NAMED_KEYS: Readonly<Record<string, NamedKey>> = Object.freeze({
  enter: { bytes: '\r', label: 'Enter' },
  escape: { bytes: '\x1b', label: 'Escape' },
  tab: { bytes: '\t', label: 'Tab' },
  'shift-tab': { bytes: '\x1b[Z', label: 'Shift-Tab' },
  backspace: { bytes: '\x7f', label: 'Backspace' },
  delete: { bytes: '\x1b[3~', label: 'Delete' },
  space: { bytes: ' ', label: 'Space' },
  up: { bytes: '\x1b[A', label: 'Up' },
  down: { bytes: '\x1b[B', label: 'Down' },
  right: { bytes: '\x1b[C', label: 'Right' },
  left: { bytes: '\x1b[D', label: 'Left' },
  home: { bytes: '\x1b[H', label: 'Home' },
  end: { bytes: '\x1b[F', label: 'End' },
  'page-up': { bytes: '\x1b[5~', label: 'Page Up' },
  'page-down': { bytes: '\x1b[6~', label: 'Page Down' },
  'ctrl-c': { bytes: '\x03', label: 'Ctrl-C' },
  'ctrl-d': { bytes: '\x04', label: 'Ctrl-D' },
  'ctrl-l': { bytes: '\x0c', label: 'Ctrl-L' },
  'ctrl-u': { bytes: '\x15', label: 'Ctrl-U' },
  'ctrl-r': { bytes: '\x12', label: 'Ctrl-R' },
  'ctrl-o': { bytes: '\x0f', label: 'Ctrl-O' },
  'ctrl-t': { bytes: '\x14', label: 'Ctrl-T' },
  'ctrl-a': { bytes: '\x01', label: 'Ctrl-A' },
  'ctrl-e': { bytes: '\x05', label: 'Ctrl-E' },
})

/** The spellings a model reaches for, folded onto the table's own names. */
const ALIASES: Readonly<Record<string, string>> = Object.freeze({
  return: 'enter',
  esc: 'escape',
  'arrow-up': 'up',
  'arrow-down': 'down',
  'arrow-left': 'left',
  'arrow-right': 'right',
  pageup: 'page-up',
  pagedown: 'page-down',
  shifttab: 'shift-tab',
  'shift+tab': 'shift-tab',
})

export interface ResolvedKey {
  /** The table's own name, or `char:<c>` for a single character. */
  name: string
  label: string
  bytes: string
}

export class KeyError extends Error {}

/**
 * One key name, or one printable character, to the bytes it sends.
 *
 * A name is matched case-insensitively and with `+`/`_` read as `-`, so
 * `Ctrl+C`, `ctrl_c` and `ctrl-c` are one key. A string of length one is a
 * character, *including* a letter that happens to also start a name — `y` is
 * the letter y. Anything else is refused with the list, because a model that
 * guessed a name wrong needs to see the right ones rather than retry.
 */
export function resolveKey(raw: unknown): ResolvedKey {
  if (typeof raw !== 'string' || raw.length === 0) throw new KeyError('each key must be a non-empty string')
  if ([...raw].length === 1) {
    const code = raw.codePointAt(0) ?? 0
    if (code < 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) {
      throw new KeyError('a single-character key must be printable; name control keys instead, e.g. "ctrl-c"')
    }
    return { name: `char:${raw}`, label: raw === ' ' ? 'Space' : `“${raw}”`, bytes: raw }
  }
  const folded = raw.trim().toLowerCase().replace(/[+_\s]/g, '-')
  const name = ALIASES[folded] ?? folded
  const key = NAMED_KEYS[name]
  if (key === undefined) {
    throw new KeyError(
      `there is no key called "${raw}". Name one of: ${Object.keys(NAMED_KEYS).join(', ')} — ` +
        'or give a single printable character such as "y" or "2".',
    )
  }
  return { name, label: key.label, bytes: key.bytes }
}

/** The whole list, checked before anything is pressed. */
export function resolveKeys(raw: unknown): ResolvedKey[] {
  if (!Array.isArray(raw) || raw.length === 0) throw new KeyError('keys must be a non-empty list')
  if (raw.length > MAX_KEYS) throw new KeyError(`at most ${MAX_KEYS} keys in one call; got ${raw.length}`)
  return raw.map(resolveKey)
}

/** Press them, one write each, with the gap each one needs after it. */
export async function pressKeys(write: Write, keys: readonly ResolvedKey[], sleep: Sleep = realSleep): Promise<void> {
  for (const [index, key] of keys.entries()) {
    write(key.bytes)
    if (index === keys.length - 1) break
    await sleep(key.bytes === '\x1b' ? ESCAPE_GAP_MS : KEY_GAP_MS)
  }
}
