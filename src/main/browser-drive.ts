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
 * ## Taking it back — by disconnecting, and by nothing else
 *
 * A person touching the page is **not** an event here, and that is a change of
 * 2026-08-21 rather than an omission. It used to be one: any unclaimed click or
 * keystroke while the state was `agent` flipped it to `human`, put a question in
 * the banner over the page, and refused the agent's next command until one of
 * two buttons was pressed. He filmed it happening to him and said what he wants
 * instead:
 *
 *   > *"if I click inside, nothing should happen actually. It should keep giving
 *   > the access until I click here and I disconnect the browser from any of the
 *   > session."*
 *
 * So the baton is moved by deliberate acts only — a tool claiming the tab, the
 * agent *asking* for the person through `browser.handover`, that person
 * answering, and the drive ending. Disconnecting the window from its session is
 * what ends the agent's access, and it is one control on the browser's own
 * toolbar (`BindChip.tsx`).
 *
 * ### What went with it, and why none of it can be half-kept
 *
 * The old rule needed to tell his input from the driver's, and that was never
 * clean: CDP-dispatched input is `isTrusted: true` and arrives on
 * `webContents.on('input-event')` with the same type names as a real press —
 * measured on Electron 41.10.5, `Input.dispatchMouseEvent` and
 * `Input.insertText` produce `mouseDown`, `mouseUp`, `rawKeyDown`, `char`,
 * `keyUp`, indistinguishable from `sendInputEvent`'s. A `DispatchRing`
 * correlated announcements with observations to guess, and its failure
 * directions were deliberately asymmetric: an event it could not account for was
 * always read as a person, so the drive parked on anything it had not
 * announced. With human input no longer a takeover at all there is nothing left
 * to guess about, so the ring, the claim window and the type list are gone
 * rather than left switched off — a heuristic nobody consults is a thing the
 * next reader has to prove is dead.
 *
 * ### What is *not* weakened by it
 *
 * `human` still refuses every command, reads included, exactly as the table
 * above says. The password guarantee is unchanged; what changed is only how the
 * page *enters* that state — the agent asks, rather than the app guessing from
 * a click. A person who wants the agent to stop has the banner's own
 * `Stop — I'll take it from here` while it is asking, and Disconnect at any
 * time.
 */

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
  /** The agent asked for the person. Never the person simply using the page. */
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
