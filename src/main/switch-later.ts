/**
 * Changing a session's account without interrupting what it is doing.
 *
 * ## What was asked for
 *
 * `session-switch.ts` builds the immediate switch: stop the agent, start another
 * one under the other account in the same tab, hand it `--continue`. It works,
 * and Asad accepted its one cost — whatever the agent was half way through does
 * not finish. Then he described the version he actually wants by default:
 *
 * > *"if we change the account, the running agent will keep running on the
 * > previous one. Once it stops and starts another task, then it will be
 * > switched automatically. I mean when we give another command and it starts
 * > working, it will be changed."*
 *
 * So the choice is made now and takes effect at the next thing he sends. The
 * agent finishes what it was doing on the account it started on; the switch
 * happens in the gap, before the next message is delivered. From where he sits
 * it switched by itself.
 *
 * ## Why "the next message" is the right moment and not a compromise
 *
 * It is the only moment that is provably between two pieces of work. The app
 * cannot see whether an agent is thinking — it has a pty and a screen, not a
 * status — so "wait until it is idle" would be a guess, and a guess that fires
 * early is the interruption this exists to avoid. A person typing a new message
 * has, by doing so, told the app the last one finished. That is a fact rather
 * than an inference.
 *
 * ## The typed line has to be carried across, or the feature is a bug
 *
 * The message is typed into the *old* process, one keystroke at a time, long
 * before the Enter that reveals it was a message. That process is about to be
 * stopped. Without carrying the line across, pressing Enter would kill the
 * session, start another, and silently drop what was typed — which reads as the
 * app eating a message.
 *
 * So while a switch is armed, this module keeps its own copy of the line as it
 * is typed, passing every keystroke through to the old session unchanged so
 * nothing looks different on screen. The Enter is the one keystroke that is
 * *not* passed through: it is intercepted, the switch runs, and the line is
 * replayed into the replacement. The old process therefore never submits it,
 * which is what makes this safe — the message is delivered exactly once, to
 * exactly one account.
 *
 * ## What it deliberately does not try to be
 *
 * It is not a terminal emulator. It understands the keys that edit a line —
 * backspace, kill-line, kill-word, and Ctrl-C as "forget it" — and nothing
 * else. Anything it does not understand (arrow keys and every other escape
 * sequence, a paste carrying control bytes, a TUI that redraws the input
 * itself) leaves its copy of the line and the real one out of step.
 *
 * That is handled by admitting it rather than by guessing: {@link Composing.exact}
 * goes false the moment an unrecognised control byte arrives, and the caller
 * replays the line **without** a trailing Enter in that case, so the message
 * lands in the new session's prompt for the person to check and send. A message
 * sent on their behalf that is not the message they typed is the one outcome
 * worth spending a whole extra state on.
 */

import type { SwitchPlan } from './session-switch'

/* --------------------------------------------------------------- channels -- */

/*
 * Named here rather than at the registration, for the house reason
 * `session-switch.ts` gives: `preload/contract.test.ts` can only resolve a
 * channel that is registered through an exported constant, so a renamed string
 * fails a test instead of rendering a control that quietly does nothing.
 */

/** Arm one: switch this session's account when he next sends something. */
export const SESSION_SWITCH_LATER_CHANNEL = 'session:switch-later'

/** Changed his mind before it fired. */
export const SESSION_SWITCH_CANCEL_CHANNEL = 'session:switch-cancel'

/** What is armed right now, so the window can redraw the hint after a reload. */
export const SESSION_SWITCH_ARMED_CHANNEL = 'session:switch-armed'

/**
 * Main → renderer: a deferred switch has happened, here is the replacement.
 *
 * It needs a channel of its own because the immediate switch does not: there
 * the window called `session:switch-account` and gets the new `SessionMeta`
 * back as the return value, so it knows to swap the row itself. Nothing asked
 * for this one — it fired inside a keystroke — so without an announcement the
 * window would show a tab whose process is gone and never learn why.
 */
export const SESSION_SWITCHED_CHANNEL = 'session:switched'

/**
 * Main → renderer: an armed switch was tried and did not take.
 *
 * A separate channel from the one above and not a field on it, because the two
 * are opposite facts and a consumer that reads the wrong one draws the wrong
 * account. The session is still running as it was — the start-then-stop order
 * in the switch handler is what makes that true — and the sentence carried here
 * is the agent's own.
 */
export const SESSION_SWITCH_FAILED_CHANNEL = 'session:switch-failed'

/* ------------------------------------------------------------- the line -- */

/**
 * ## The bug this model was rebuilt to make impossible
 *
 * Asad, 2026-08-20, on a switch armed for his next message:
 *
 *   > *"See, what the fuck is this? This came in my message automatically. I
 *   > don't know what is this. It's not even showing completely in one, maybe."*
 *
 * Reproduced exactly, and it was this file. The old model classified one byte
 * at a time: Escape was "a control I do not understand", so it gave up its
 * certainty and moved on — and then the *rest* of the escape sequence, which is
 * ordinary printable ASCII, was appended to the line as though he had typed it.
 * One press of the Up arrow turned `run the tests` into `run the tests[A`, and
 * that is what the replacement session was handed:
 *
 *     up arrow        -> line="fix the bug[A"
 *     left arrow      -> line="abc[Ddef"
 *     bracketed paste -> line="[200~pasted text[201~"
 *     delete key      -> line="abcd[3~"
 *
 * `exact` was false in every one of those, so nothing was ever *sent* — but the
 * text was still typed into his prompt, which is the thing he saw. An escape
 * sequence is a unit, and the only safe way to skip one is to skip **all** of
 * it. That is what the state machine below does, and it is the property the
 * tests assert head-on: whatever arrives, `line` holds nothing but characters
 * he typed.
 *
 * ## Why it now carries a cursor
 *
 * Skipping sequences whole would have been enough to stop the leak, but it
 * would have left `exact` false for every message anybody edits — arrows are
 * how a person fixes a typo — and a switch that never sends is a switch that
 * always makes him press Enter twice. Modelling the cursor is what turns the
 * common case back into "his exact line is sent": left, right, home, end and
 * the forward-delete key are all reproducible with a cursor and nothing else.
 *
 * What is still not modelled is anything that rewrites the line from somewhere
 * this process cannot see — history recall, a completion popup, a TUI redraw.
 * Those keep `exact` false, and `exact` false means the text is placed in the
 * prompt and left there for him to read. So the two outcomes are the only two
 * there are: the line he typed is sent, or the line he typed sits unsent.
 * Never a fragment of a control sequence.
 */

const ESC = '\u001b'
const BEL = '\u0007'
/** Backspace, in both spellings a terminal sends it. */
const BACKSPACE = /[\u0008\u007f]/
/** Ctrl-U, and readline's meaning of it: kill from the cursor back to the start. */
const KILL_TO_START = '\u0015'
/** Ctrl-K — kill from the cursor to the end. */
const KILL_TO_END = '\u000b'
/** Ctrl-W — kill the word before the cursor. */
const KILL_WORD = '\u0017'
/** Ctrl-A / Ctrl-E — start of line, end of line. */
const GO_START = '\u0001'
const GO_END = '\u0005'
/** Ctrl-B / Ctrl-F — the arrow keys, spelled the other way. */
const GO_LEFT = '\u0002'
const GO_RIGHT = '\u0006'

/**
 * Ctrl-C, and Ctrl-C only.
 *
 * Escape was in here once and had to come out, because Escape is not a key — it
 * is the first byte of nearly every key that is not a letter. An arrow press
 * arrives as `ESC [ A`, so treating Escape as "forget the line" read a cursor
 * move as an erase and then declared itself *certain* about the empty line it
 * had just invented.
 */
const ABANDON = '\u0003'

export interface Composing {
  /**
   * The line as this module believes it stands.
   *
   * The invariant, and the one the leak broke: **every character in here is a
   * character the person typed.** No escape-sequence payload, no paste bracket,
   * no control byte, whatever else went wrong.
   */
  line: string
  /**
   * Whether that belief is certain.
   *
   * False once something arrived that this module cannot reproduce. The line is
   * then still his — see the invariant above — but it may be out of date, so it
   * must not be submitted on his behalf.
   */
  exact: boolean
  /** Where the next character lands. Always between 0 and `line.length`. */
  cursor: number
  /**
   * An escape sequence that has not finished arriving.
   *
   * A write is one keystroke almost always, but a paste is one chunk and a pty
   * can split anything — so the parser's state has to survive between chunks or
   * a sequence torn in half leaks its tail into the line, which is the whole
   * bug in a subtler dress.
   */
  pending: string
  /**
   * Inside a bracketed paste: the bytes are text, and a carriage return among
   * them is a newline rather than the Enter that fires the switch.
   *
   * Without this a multi-line paste fires the switch on its first newline and
   * carries across the first line only — a fragment, which is the other half of
   * what he must never see.
   */
  pasting: boolean
}

export const EMPTY_LINE: Composing = {
  line: '',
  exact: true,
  cursor: 0,
  pending: '',
  pasting: false,
}

/** The Enter that submits, returned in place of a state. */
const SUBMITS = Symbol('submit')

function insert(state: Composing, text: string): Composing {
  return {
    ...state,
    line: state.line.slice(0, state.cursor) + text + state.line.slice(state.cursor),
    cursor: state.cursor + text.length,
  }
}

/** Something happened that cannot be reproduced. The line stands; the claim does not. */
function unsure(state: Composing): Composing {
  return { ...state, exact: false, pending: '' }
}

/**
 * Give up on a sequence because of the byte that arrived in the middle of it.
 *
 * Distinct from {@link unsure} by one case, and the fuzz case in the tests
 * found it before anybody read this far: when the byte that spoils a sequence
 * is itself an Escape, it is the *start of the next one*, and dropping it
 * leaves the parser back at plain text with `[4~` still on the wire. Which it
 * then types into the line — the exact bug this rewrite is here to remove,
 * arriving by a second route.
 *
 * So the offending byte is re-offered rather than swallowed: an Escape opens a
 * fresh sequence, anything else is discarded with the sequence it broke.
 */
function abandon(state: Composing, ch: string): Composing {
  return { ...state, exact: false, pending: ch === ESC ? ESC : '' }
}

/**
 * A completed escape sequence, interpreted.
 *
 * `params` is what came between the introducer and the final byte. Only the
 * bare forms are acted on: `ESC [ 1 ; 5 D` is a *word* jump rather than a
 * character one, and treating it as the latter would put the cursor somewhere
 * it is not — the same class of silent wrongness as the leak, only quieter.
 * Anything carrying a modifier falls through to {@link unsure}.
 */
function escapeSequence(state: Composing, params: string, final: string): Composing {
  const bare = params === '' || params === '1'
  const done = { ...state, pending: '' }
  const end = state.line.length

  switch (final) {
    case 'D':
      return bare ? { ...done, cursor: Math.max(0, state.cursor - 1) } : unsure(state)
    case 'C':
      return bare ? { ...done, cursor: Math.min(end, state.cursor + 1) } : unsure(state)
    case 'H':
      return bare ? { ...done, cursor: 0 } : unsure(state)
    case 'F':
      return bare ? { ...done, cursor: end } : unsure(state)
    case '~':
      switch (params) {
        // Home and End, in the numbered spelling half the terminals in the
        // world send instead of the lettered one.
        case '1':
        case '7':
          return { ...done, cursor: 0 }
        case '4':
        case '8':
          return { ...done, cursor: end }
        // The forward-delete key.
        case '3':
          return {
            ...done,
            line: state.line.slice(0, state.cursor) + state.line.slice(state.cursor + 1),
          }
        /*
         * Bracketed paste. What arrives between these two is text he chose, so
         * it belongs in the line — whereas the brackets themselves are exactly
         * what he watched appear in his prompt.
         */
        case '200':
          return { ...done, pasting: true }
        case '201':
          return { ...done, pasting: false }
        default:
          return unsure(state)
      }
    /*
     * Up and down among them. In a single-line prompt those recall history, and
     * in a multi-line one they move between visual rows — either way the line
     * that results is composed somewhere this process cannot see. The text
     * stays, because he typed it and it is safe to put in front of him; the
     * certainty goes, which is the whole difference between sending and
     * offering.
     */
    default:
      return unsure(state)
  }
}

/**
 * The next byte of a sequence already in flight.
 *
 * The shapes are the ones a keyboard and a terminal actually produce: `CSI`
 * (`ESC [`), parameter and intermediate bytes then a final in `@`–`~`; `SS3`
 * (`ESC O`) with exactly one byte after it, which is what a terminal in
 * application-cursor mode sends for the arrow keys; the string sequences
 * (`OSC`, `DCS`, `PM`, `APC`) which run until `BEL` or `ESC \`; and the bare
 * two-byte `ESC <char>` that Option-and-a-letter produces on a Mac.
 *
 * Every one of them ends by being either interpreted or discarded whole. There
 * is deliberately no path out of here that appends a byte to the line.
 */
function continueEscape(state: Composing, ch: string): Composing | typeof SUBMITS {
  const pending = state.pending

  /*
   * His Enter is never eaten, whatever is half-arrived in front of it.
   *
   * A carriage return is not a legal byte anywhere inside these sequences, so
   * one arriving means the sequence was torn — and the alternative reading,
   * that this byte belongs to the sequence, costs him the keypress: he presses
   * Enter, nothing happens, and the switch he armed never fires. The sequence
   * is abandoned and the Enter is the Enter. Certainty is already gone by then,
   * because the caller refuses to submit a line with an unfinished sequence
   * behind it, so the message is offered rather than sent.
   */
  if (ch === '\r' || ch === '\n') return SUBMITS

  if (pending === ESC) {
    if (ch === ESC) return state // a fresh sequence; the abandoned one is dropped
    if (
      ch === '[' ||
      ch === ']' ||
      ch === 'O' ||
      ch === 'P' ||
      ch === '^' ||
      ch === '_' ||
      ch === 'X'
    ) {
      return { ...state, pending: pending + ch }
    }
    // `ESC b`, `ESC f`, `ESC` and anything else — a complete two-byte sequence
    // and one this module has no model for. Consumed, never appended.
    return unsure(state)
  }

  const introducer = pending[1]

  if (introducer === '[') {
    const code = ch.charCodeAt(0)
    // Parameter bytes `0-9:;<=>?` and intermediates ` ` to `/` keep it open.
    if ((code >= 0x30 && code <= 0x3f) || (code >= 0x20 && code <= 0x2f)) {
      return { ...state, pending: pending + ch }
    }
    if (code >= 0x40 && code <= 0x7e) return escapeSequence(state, pending.slice(2), ch)
    // A control byte inside a CSI is a torn sequence. Abandoned rather than
    // guessed at, because guessing where it ends is how the tail gets typed.
    return abandon(state, ch)
  }

  if (introducer === 'O') {
    // SS3: one byte, and the arrow keys use the same finals CSI does — but only
    // a real final byte counts as one. This is where the fuzz case landed: an
    // `ESC O` with an Escape behind it handed the Escape in as though it were
    // the final, ate it, and left the sequence it opened to be typed as text.
    const code = ch.charCodeAt(0)
    if (code >= 0x40 && code <= 0x7e) return escapeSequence(state, '', ch)
    return abandon(state, ch)
  }

  // OSC and the other string sequences: everything up to BEL or ESC-backslash
  // is somebody else's payload.
  if (ch === BEL) return unsure(state)
  if (ch === '\\' && pending.endsWith(ESC)) return unsure(state)
  return { ...state, pending: pending + ch }
}

/** One character, folded in — or {@link SUBMITS} when it is the Enter that ends the message. */
function step(state: Composing, ch: string): Composing | typeof SUBMITS {
  if (state.pending !== '') return continueEscape(state, ch)
  if (ch === ESC) return { ...state, pending: ESC }

  if (state.pasting) {
    // A newline inside a paste is part of the text rather than a submit. It is
    // kept, and the certainty is not: replaying a multi-line message through a
    // pty is not something this module can promise reproduces it.
    if (ch === '\r' || ch === '\n') return { ...insert(state, '\n'), exact: false }
    if (ch < ' ' || ch === '\u007f') return unsure(state)
    return insert(state, ch)
  }

  if (ch === '\r' || ch === '\n') return SUBMITS
  if (ch === ABANDON) {
    // Certain again on purpose: an empty line is a line both sides agree about,
    // whatever went before it.
    return { ...EMPTY_LINE }
  }
  if (BACKSPACE.test(ch)) {
    if (state.cursor === 0) return state
    return {
      ...state,
      line: state.line.slice(0, state.cursor - 1) + state.line.slice(state.cursor),
      cursor: state.cursor - 1,
    }
  }
  if (ch === KILL_TO_START) return { ...state, line: state.line.slice(state.cursor), cursor: 0 }
  if (ch === KILL_TO_END) return { ...state, line: state.line.slice(0, state.cursor) }
  if (ch === KILL_WORD) {
    const kept = state.line.slice(0, state.cursor).replace(/\S*\s*$/, '')
    return { ...state, line: kept + state.line.slice(state.cursor), cursor: kept.length }
  }
  if (ch === GO_START) return { ...state, cursor: 0 }
  if (ch === GO_END) return { ...state, cursor: state.line.length }
  if (ch === GO_LEFT) return { ...state, cursor: Math.max(0, state.cursor - 1) }
  if (ch === GO_RIGHT) return { ...state, cursor: Math.min(state.line.length, state.cursor + 1) }

  // Tab, and every other C0 byte with no meaning here. Nothing is appended:
  // that is the rule the leak broke.
  if (ch < ' ' || ch === '\u007f') return unsure(state)

  return insert(state, ch)
}

/**
 * Fold a chunk in, stopping at the Enter that ends the message.
 *
 * `submit` is that Enter's index in `data`, or -1. Everything before it is
 * already in `state`; everything after it belongs to the replacement session
 * and is not this register's to read.
 *
 * One pass rather than "find the Enter, then compose the part before it",
 * because whether a carriage return is an Enter at all depends on the state the
 * parser is in when it reaches one — inside a bracketed paste it is a newline,
 * and splitting the chunk first is how a pasted paragraph would fire the switch
 * on its first line and carry a fragment across.
 */
export function feed(state: Composing, data: string): { state: Composing; submit: number } {
  let next = state
  let index = 0
  for (const ch of data) {
    const moved = step(next, ch)
    if (moved === SUBMITS) return { state: next, submit: index }
    next = moved
    index += ch.length
  }
  return { state: next, submit: -1 }
}

/**
 * One chunk of typing folded into the line so far.
 *
 * The named entry point for a whole chunk. A submit reaching here belongs to a
 * message this register is no longer carrying, so the copy stops being of one
 * line and says so.
 */
export function compose(state: Composing, data: string): Composing {
  let next = state
  let rest = data
  for (;;) {
    const folded = feed(next, rest)
    if (folded.submit === -1) return folded.state
    next = { ...folded.state, exact: false }
    rest = rest.slice(folded.submit + 1)
  }
}

/**
 * Where the Enter that submits is in a chunk, or -1.
 *
 * Takes the parser state, because the answer depends on it: the same byte is a
 * submit at a prompt and a newline inside a bracketed paste.
 */
export function submitAt(data: string, state: Composing = EMPTY_LINE): number {
  return feed(state, data).submit
}

/* ---------------------------------------------------------- the register -- */

export interface ArmedSwitch {
  sessionId: string
  profileId: string
  /** The account's name, so the window can say what it is waiting to become. */
  accountName: string
  /** The plan as it read when it was armed. Shown; never acted on again. */
  plan: SwitchPlan
  armedAt: number
  composing: Composing
}

/**
 * What the caller should do with a write, having shown it to the register.
 *
 *  - `pass`     nothing is armed, or this is ordinary typing. Write it through.
 *  - `switch`   an Enter arrived on a session with a switch armed. The bytes
 *               before it still go to the old session (it is about to be
 *               stopped, but a person watching should see what they typed);
 *               then the switch runs and `line` is replayed.
 */
export type WriteAction =
  | { kind: 'pass' }
  | { kind: 'switch'; armed: ArmedSwitch; before: string; line: string; submit: boolean }

/**
 * Every session with a switch waiting for its next message.
 *
 * A class with its own state rather than a module-level map, because the two
 * shells that assemble this app each build their own core and a shared map
 * would leak one shell's sessions into the other's.
 */
export class PendingSwitches {
  private readonly armed = new Map<string, ArmedSwitch>()

  arm(entry: Omit<ArmedSwitch, 'armedAt' | 'composing'>): ArmedSwitch {
    const record: ArmedSwitch = { ...entry, armedAt: Date.now(), composing: EMPTY_LINE }
    this.armed.set(entry.sessionId, record)
    return record
  }

  get(sessionId: string): ArmedSwitch | null {
    return this.armed.get(sessionId) ?? null
  }

  list(): ArmedSwitch[] {
    return [...this.armed.values()]
  }

  /** Called when the person changes their mind, and when the session ends. */
  cancel(sessionId: string): boolean {
    return this.armed.delete(sessionId)
  }

  /**
   * Show a write to the register and be told what to do with it.
   *
   * The line is accumulated here rather than by the caller so that there is one
   * copy of it and one place that decides what a keystroke means.
   */
  observe(sessionId: string, data: string): WriteAction {
    const armed = this.armed.get(sessionId)
    if (!armed || typeof data !== 'string' || data === '') return { kind: 'pass' }

    /*
     * One pass, and the parser state comes with it. Finding the Enter with a
     * search over the raw chunk and *then* composing the part before it was
     * what let a bracketed paste fire the switch on its own first newline: the
     * question "is this byte a submit" has no answer without knowing whether a
     * paste is open, and only the parser knows that.
     */
    const { state: composing, submit: at } = feed(armed.composing, data)
    if (at === -1) {
      armed.composing = composing
      return { kind: 'pass' }
    }

    const before = data.slice(0, at)
    // Consumed: a switch runs once. Anything typed afterwards belongs to the
    // replacement, which is a session this register has never heard of.
    this.armed.delete(sessionId)
    return {
      kind: 'switch',
      armed: { ...armed, composing },
      before,
      line: composing.line,
      /*
       * Sent on his behalf only when the copy is certain — and certainty now
       * also requires that nothing is half-arrived. A chunk ending inside an
       * escape sequence or inside an open paste is a line whose next byte could
       * still change it, and pressing Enter on that is the failure this whole
       * flag exists for.
       */
      submit: composing.exact && composing.pending === '' && !composing.pasting,
    }
  }
}

/* ---------------------------------------------------------------- saying -- */

/**
 * How long to let the replacement settle before the carried line is replayed.
 *
 * `survivedStart` has already waited its own grace and confirmed the process is
 * alive; this is the separate question of whether the agent is *reading*. A CLI
 * that has not started reading yet does not lose the bytes — they sit in the
 * pty until it does — but one that clears the screen on start can redraw over
 * them, which looks like the message vanished even though it was delivered.
 *
 * Deliberately short. The cost of waiting too long is a visible pause between
 * pressing Enter and the message appearing; the cost of not waiting at all is
 * cosmetic and recoverable. Neither is worth more than this.
 */
export const REPLAY_SETTLE_MS = 400

/**
 * How long to leave between typing the line and pressing Enter on it.
 *
 * Measured, in `renderer/chat/attach/mentions.ts`: written back to back the two
 * are read as one chunk and nothing is sent; 30ms apart submits. 50 leaves room
 * on a slower machine and is still far below anything a person notices.
 */
export const REPLAY_SUBMIT_GAP_MS = 50

/**
 * The writes that put a replayed line into a session, in order.
 *
 * Two of them, and a single `${line}\r` in their place does not merely look
 * untidy — **it never sends.** The CLI classifies each stdin chunk before it
 * looks at the keys inside it, and a chunk of about 64 bytes or more is *pasted
 * text*, where a carriage return is a newline rather than submit. That was
 * measured from the other direction when the composer's send button turned out
 * to be a no-op for every message carrying an attachment, and it is written up
 * in `mentions.ts`. Almost every real prompt is longer than 64 characters, so a
 * one-write replay would leave the message sitting in the replacement's input
 * box while {@link switchedNote} said it had been sent — a false sentence at
 * the one moment this whole feature exists for. `agent-controls.ts` types into
 * a session as two writes for the same reason.
 *
 * The trailing space on a line containing an `@` is the second half of the same
 * measurement: with `@` and no space after it the Enter is eaten by the CLI's
 * file-completion popup and the line collapses to a bare path; with the space,
 * the identical line submits intact. A replayed message that mentions a file is
 * the ordinary case, not an exotic one.
 *
 * Wiring: write the first element, wait {@link REPLAY_SUBMIT_GAP_MS}, write the
 * second — and skip the second entirely when the copy of the line is not exact,
 * because then the person has to read it before it goes anywhere.
 *
 * Which is also why `submit` decides whether the space is added at all. The
 * space exists to stop the completion popup eating an *Enter*; where no Enter
 * is coming, it is a character he did not type sitting on the end of a line he
 * is being asked to check. The rule for the whole replay path is one rule —
 * what lands in his prompt is what he typed — and a stray space is the smallest
 * possible violation of it rather than an exception to it.
 */
export function replayWrites(line: string, submit = true): [string, string] {
  return [submit && line.includes('@') ? `${line} ` : line, '\r']
}

/** What the window says while a switch is waiting for the next message. */
export function armedNote(armed: ArmedSwitch): string {
  return `Switching to ${armed.accountName} when you send your next message.`
}

/**
 * What to say once it has happened.
 *
 * Names the account and says what became of the message, because those are the
 * two things a person is about to check for themselves.
 *
 * Three answers rather than two, and the third is the one that was missing: a
 * line this module could not carry at all leaves the prompt empty, and saying
 * *"your message is in the prompt"* over an empty prompt sends somebody looking
 * for text that is not there. The switch still happened, so that is what it
 * says, and nothing more.
 */
export function switchedNote(accountName: string, submitted: boolean, line = ' '): string {
  if (line === '') return `Switched to ${accountName}.`
  return submitted
    ? `Switched to ${accountName} and sent your message.`
    : `Switched to ${accountName}. Your message is in the prompt — check it and press Enter.`
}
