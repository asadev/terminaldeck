import type { DriveState } from './browser-cdp'

/**
 * The baton: who is holding the page, and how it changes hands.
 *
 * This module is the answer to the thing Asad actually asked for. He described
 * two browsers — *"you are driving your Chromium over your Playwright, and
 * whenever I need to do something you give me a Chromium where I can type the
 * password"* — because that is what the tools force. Here there is one page,
 * and the two of them take turns.
 *
 * Everything below is pure logic over plain values. There is no `WebContents`
 * in this file, no `ipcMain`, no Electron import at all; `browser-driver.ts`
 * owns the live objects and calls in here for every decision. That split is the
 * same one `shouldComposite` in `browser-tab.ts` was pulled out for, and for
 * the same reason: an effect is the one place a rule cannot be tested, and this
 * rule is the one standing between somebody's password and an agent's
 * transcript.
 *
 * ## Three states, and why `human` refuses reads
 *
 * | State   | Who has the page | What the channel does                        |
 * |---------|------------------|----------------------------------------------|
 * | `idle`  | nobody           | nothing is attached                          |
 * | `agent` | the driver       | commands pass, subject to `browser-cdp.ts`   |
 * | `human` | the person       | **every** command is refused, reads included |
 *
 * Refusing reads is the whole enforcement story for the password, and it is
 * worth being blunt about why it is not only mutations: a screenshot taken
 * while he is typing is the leak. During `human` there is no page read, no
 * screenshot, no element outline and no navigation report. **You cannot redact
 * what was never produced.**
 *
 * ## Taking it back without being asked
 *
 * The other half of what he described — *"I do my step on the Chromium which is
 * attached to your Playwright"* — needs no gesture at all. Any real interaction
 * with the page while the state is `agent` flips it to `human` immediately and
 * the driver's next command is refused. That mirrors the house pattern in
 * `DRIVING-MODE.md` §8, where a `pointerdown` anywhere pauses the tour.
 *
 * The hard part is telling his input from the driver's, and it is worth
 * recording what was measured rather than what the design hoped:
 *
 *  - CDP-dispatched input is `isTrusted: true` — that is why it works at all —
 *    so the *page* cannot tell them apart, and neither can a capture-phase
 *    listener.
 *  - `webContents.on('input-event')` **does** fire for CDP-dispatched input.
 *    Measured on Electron 41.10.5: dispatching `Input.dispatchMouseEvent` and
 *    `Input.insertText` produced `mouseDown`, `mouseUp`, `rawKeyDown`, `char`,
 *    `keyUp` on that listener, indistinguishable by type from the events
 *    `sendInputEvent` produces. So the clean signal the design hoped for does
 *    not exist, and this is the heuristic branch it named as the fallback.
 *  - `before-input-event` fires for keys in both cases and not at all for the
 *    mouse, so it is no better.
 *
 * So {@link DispatchRing} correlates: the driver announces each event it is
 * about to send, and an observed event that matches a recent announcement is
 * consumed as its own. Anything left over is a person.
 *
 * **The failure directions are deliberately asymmetric.** Reading a synthetic
 * event as human parks the drive and costs a retry. Reading a human keystroke
 * as synthetic means the agent keeps typing while he does, into a form he is
 * filling. So an unmatched event is *always* a person, and the ring is
 * deliberately generous about what counts as a match.
 *
 * ## What is deliberately not watched
 *
 * Pointer *movement*. A single dispatched `mouseMoved` was observed to produce
 * five `mouseMove`s and a `mouseLeave` on the listener — Chromium re-synthesises
 * moves when content shifts under a stationary cursor — so treating a move as a
 * takeover would park the drive constantly, on its own output. Only the events
 * that carry an intention are watched: a press, and a key.
 */

/* ------------------------------------------------------- observed input -- */

/**
 * The `input-event` types this module reacts to at all.
 *
 * A press and a key are intentions. Everything else — moves, leaves, enters,
 * wheels, releases — is either noise or the tail of an intention already
 * counted, and counting the tail twice would need the ring to hold two entries
 * per gesture for no gain.
 */
const TAKEOVER_TYPES = new Set(['mouseDown', 'keyDown', 'rawKeyDown', 'char'])

export function isTakeoverCandidate(type: unknown): boolean {
  return typeof type === 'string' && TAKEOVER_TYPES.has(type)
}

/**
 * How long a dispatched event stays claimable, in milliseconds.
 *
 * Generous on purpose. The driver announces an event and then hands it to
 * Chromium, which delivers it to the guest process, which reports it back on
 * this listener — three process hops, and the app is also drawing a window. Too
 * short and the drive parks itself on its own clicks, which is the failure mode
 * that reads as the flakiness this whole feature exists to remove. Too long and
 * a genuine human click landing within the window is missed, which costs one
 * beat before the *next* one parks it.
 *
 * 750 ms was chosen against the second consideration rather than the first: a
 * person who has just watched the agent click something does not click in the
 * same three-quarters of a second, because they are still reading what happened.
 */
export const DISPATCH_CLAIM_MS = 750

/** One event the driver is about to send, remembered so it can be claimed back. */
interface Announced {
  type: string
  at: number
}

/**
 * The short memory of what the driver just did.
 *
 * A queue rather than a set: two clicks on the same button are two entries and
 * must be claimed twice, or the second one — which could be his — would be
 * matched against the first one's announcement and treated as synthetic.
 *
 * Bounded, because a driver in a tight loop on a page that is not responding
 * would otherwise grow this without limit. The bound is generous relative to
 * anything a single tool call dispatches (a click is one entry, typing a
 * password's worth of text is one `insertText`), so hitting it means something
 * has already gone wrong.
 */
export const MAX_ANNOUNCED = 64

export class DispatchRing {
  private entries: Announced[] = []

  /** The driver is about to send this. Call immediately before dispatching. */
  announce(type: string, now: number): void {
    if (!isTakeoverCandidate(type)) return
    this.entries.push({ type, at: now })
    if (this.entries.length > MAX_ANNOUNCED) this.entries.shift()
  }

  /**
   * Was this observed event ours?
   *
   * Consumes the match, so the same announcement cannot absorb two events.
   * Expired announcements are dropped on the way past rather than on a timer:
   * this is called on every input event, which is the only moment the answer
   * matters, and a timer would be a second thing to tear down per tab.
   */
  claim(type: string, now: number): boolean {
    const cutoff = now - DISPATCH_CLAIM_MS
    this.entries = this.entries.filter((entry) => entry.at > cutoff)
    const index = this.entries.findIndex((entry) => entry.type === type)
    if (index === -1) return false
    this.entries.splice(index, 1)
    return true
  }

  /** Everything still claimable. For a test, and for the state report. */
  size(): number {
    return this.entries.length
  }

  clear(): void {
    this.entries = []
  }
}

/* ------------------------------------------------------------ transitions -- */

/**
 * Everything that can move the baton.
 *
 * A closed set rather than a pile of setters, because the interesting property
 * of this machine is which transitions do *not* exist — nothing here moves the
 * page from `human` back to `agent` except {@link resumed}, which is a person
 * clicking a button, and nothing at all re-arms a drive after it has ended.
 */
export type DriveEvent =
  /** A tool claimed the tab. */
  | { kind: 'claimed' }
  /** The agent asked for the person, or the person took it. */
  | { kind: 'handover' }
  /** The person said "done, carry on". */
  | { kind: 'resumed' }
  /** The person said "stop, I'll take it from here", or closed the tab. */
  | { kind: 'released' }

/**
 * The next state, and nothing else.
 *
 * `released` goes to `idle` from anywhere, including `idle`, because the two
 * ways a drive ends — he stopped it, or the tab went away — arrive from
 * different places and must not have to agree about which one got there first.
 *
 * `resumed` from `idle` stays `idle`. That looks like a missing case and is
 * deliberate: a resume arriving after the drive has already ended — he clicked
 * "carry on" a beat after the tab was closed — must not resurrect it. A drive
 * that re-armed itself is the behaviour `DRIVING-MODE.md` §8 names as *"the
 * single behaviour that would make somebody uninstall"*.
 */
export function nextDriveState(current: DriveState, event: DriveEvent): DriveState {
  switch (event.kind) {
    case 'claimed':
      // Claiming while the person holds it does not take it off them. The tool
      // layer refuses this earlier with a sentence; this is the backstop that
      // means no ordering of calls can produce it.
      return current === 'human' ? 'human' : 'agent'
    case 'handover':
      return current === 'idle' ? 'idle' : 'human'
    case 'resumed':
      return current === 'human' ? 'agent' : current
    case 'released':
      return 'idle'
  }
}

/* --------------------------------------------------------- what is shown -- */

/**
 * The drive, as the window is told about it.
 *
 * Crosses the bridge as `unknown` and is re-declared on the renderer side, the
 * way every other feature type in this app does — see `browser/bridge.ts` for
 * why that is the house rule rather than an omission.
 */
export interface DriveStatus {
  state: DriveState
  /** The tab the agent holds, or null when it holds none. */
  tabId: string | null
  /**
   * What the drive is doing right now, in the words a person reads.
   *
   * `clicking “Sign in”` — present tense, the element's own label. This is the
   * only feedback a driven click has, because CDP input does not move the OS
   * pointer and nothing HTML can be drawn over a `WebContentsView`, so there is
   * no cursor to watch. Empty between steps.
   */
  step: string
  /**
   * The sentence the agent wrote when it asked for the person. Empty unless
   * the state is `human`.
   *
   * Written by a language model and rendered into the app's own chrome, so it
   * is clamped and stripped of control characters before it ever gets here —
   * see `sanitizeHandoverPrompt`.
   */
  prompt: string
  /** Where the page is, so the banner can name the site he is being asked about. */
  url: string
}

export const EMPTY_DRIVE_STATUS: DriveStatus = {
  state: 'idle',
  tabId: null,
  step: '',
  prompt: '',
  url: '',
}

/**
 * Longest handover sentence that reaches the window.
 *
 * A banner, not a paragraph. The model is told in the tool's description to
 * write one line; this is what happens when it does not.
 */
export const MAX_PROMPT_CHARS = 200

/**
 * Clean a model's sentence before it is drawn in the app's own chrome.
 *
 * Control characters, newlines and the bidirectional overrides, all collapsed
 * to spaces. The last of those is the one that is not obvious: `U+202E` in a
 * banner reverses the text after it, so a sentence can be made to read as
 * something other than what is in the log beside it — and this banner's entire
 * job is to tell somebody what they are about to type a password into.
 */
export function sanitizeHandoverPrompt(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  const flattened = raw
    .replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return flattened.length > MAX_PROMPT_CHARS
    ? `${flattened.slice(0, MAX_PROMPT_CHARS)}\u2026`
    : flattened
}

/* ------------------------------------------------------------- handovers -- */

/**
 * How a handover ended, from the tool's point of view.
 *
 * `still-waiting` is the important one and it is not a failure. The state lives
 * in the main process and is durable — the banner stays up and the baton stays
 * with him for as long as it takes — while the *tool call* is a bounded window
 * onto that state. Signing into an Apple ID with a code on a phone takes longer
 * than any tool timeout worth having, so the call returns, says the wait is
 * still live, and the agent calls again.
 *
 * It is deliberately not called `timeout`, and the tool's description
 * deliberately does not use the word "failed": a model told a thing failed goes
 * looking for another way to do it, which is the exact lesson
 * `refusalSentence('not-permitted-unattended')` in `control.ts` was written
 * from.
 */
export type HandoverOutcome = 'resumed' | 'stopped' | 'still-waiting' | 'drive-ended'

/**
 * How long one `browser.handover` call blocks before reporting back.
 *
 * It has to be under the MCP client's own call timeout, because a tool that
 * blocks past it is a tool whose answer arrives after the model has been told it
 * failed — and the whole of `HandoverOutcome`'s `still-waiting` design is an
 * answer that has to *arrive* to do its job.
 *
 * This was ninety seconds, and the comment here said that was "well under" the
 * client's timeout. It was not. Measured on 2026-08-18 against Claude Code
 * 2.1.234 driving the packaged build: `browser_handover` was called at
 * 20:46:40.985 and the client gave up at 20:47:41.129 — **60.14 seconds**, so
 * the client's cap is sixty and the ninety-second window could never be reached.
 * Every handover nobody answered inside a minute came back as *"The operation
 * timed out"*, an error, which is exactly the thing the outcome vocabulary above
 * exists to avoid: the model was told it failed, retried in a different shape,
 * and gave up. The person's banner was up and correct the whole time.
 *
 * Forty-five seconds, so there is a quarter of the client's budget spare for the
 * round trip and for a slow renderer. That is still long enough for a password
 * from a manager, and a code fetched from a phone simply takes two calls now —
 * which is the interaction `still-waiting` was written for and which now
 * actually happens. Anything raised past sixty here is a regression whatever the
 * number looks like; `browser-handover-window.test.ts` fails on it.
 */
export const HANDOVER_WINDOW_MS = 45_000

/**
 * The MCP client's own call timeout, as measured rather than as documented.
 *
 * Named so the ceiling above is checkable against something rather than being a
 * number somebody has to trust. Claude Code's `MCP_TOOL_TIMEOUT` defaults here;
 * a client configured with a longer one is free to have it, and nothing in this
 * app may *depend* on that, because the copilot is spawned with the default.
 */
export const MCP_CALL_TIMEOUT_MS = 60_000
