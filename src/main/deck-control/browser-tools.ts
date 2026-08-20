import type { BoundWindow } from '../browser-binding'
import { slotName, windowNamed, windowsOf } from '../browser-binding'
import { boundKey } from '../browser-driver'
import type { BrowserDrive, DriveTarget, StepVerb } from '../browser-driver'
import {
  DEFAULT_OUTLINE_TEXT_CHARS,
  DriveRefused,
  MAX_OUTLINE_TEXT_CHARS,
  PRESSABLE_KEYS,
} from '../browser-driver'
import { HANDOVER_WINDOW_MS } from '../browser-drive'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * The five browser tools, and the decisions inside them.
 *
 * Contributed through `DeckControlOptions.extraTools`, which exists for exactly
 * this and whose comment says so: a feature that wants to give the copilot a
 * capability reaches it *through* the dispatcher rather than beside it, so it
 * is prechecked, tiered, escalated, budgeted, gated and logged like the
 * fourteen in `catalogue.ts`. Nothing here re-implements any of that.
 *
 * ## Why five schemas rather than a Playwright handle
 *
 * Asad asked for Playwright. What he described wanting from it is *stable
 * driving* — *"it goes back many times, turns off"* — and the stability lives
 * in the engine, not in the API surface the model sees. A model cannot express
 * auto-waiting or a selector engine; on every turn it sees a handful of JSON
 * schemas whatever is underneath.
 *
 * Handing an agent the library instead would mean handing it a way to run
 * arbitrary code against a browser holding his live logins, outside the tier
 * system, outside the budgets, outside `actions.jsonl` — a strictly larger
 * power than any tool in `catalogue.ts`, given away as a convenience. So the
 * driving is as good as it can be made (`browser-driver.ts`) and the surface is
 * five bounded verbs.
 *
 * ## Why there is still no tabId anywhere, and what changed
 *
 * The rule used to be that the agent has *one* tab — the one `browser.open`
 * gave it — and can never touch a tab the person opened. Asad's answer to that,
 * on 2026-08-20:
 *
 * > *"sessions still dont have full control to the browser windows and they
 * > dont know about the ones attached to them specifically and they can only
 * > open a new browser with whatever the link we ask with then they cant do
 * > anything"*
 *
 * He is describing the cost of the rule rather than disputing its reasoning,
 * and the fix keeps the reasoning. **There is still no tab id in any schema.**
 * What a verb may name is a *session* and one of that session's slot names —
 * `B1`, `B2` — the pair a person and an agent both already say out loud. That
 * pair is resolved by {@link windowNamed}, which looks inside one binding's own
 * list, so:
 *
 *  - a window belonging to another session cannot be named,
 *  - a window belonging to no session cannot be named,
 *  - and neither of those is distinguishable, in the refusal, from a name that
 *    was never a window at all. One sentence for all three; nothing here
 *    confirms that a page exists somewhere else in the app.
 *
 * The tier argument moves with it. Reading a page the agent navigated to itself
 * discloses nothing new, which is why `browser.read` is `read`; reading a page
 * the *person* attached to that session discloses nothing new either, because
 * attaching is the act by which he says which pages that agent may look at. It
 * is made by hand, in the window's own menu, one window at a time. An attached
 * window an agent may not read would be a control that did nothing.
 */

/* ------------------------------------------------------------- the origin -- */

/**
 * Is this a machine of his own, rather than the internet?
 *
 * A dev server on localhost is the ordinary case and asking about every click
 * on it is the confirmation fatigue `consent.ts` is unambiguous about. A public
 * origin is where a click can send money.
 *
 * Deliberately conservative: anything this cannot confidently place is treated
 * as public, because the failure directions are not symmetric — a needless
 * dialog on a private address costs one click, and a missing dialog on a public
 * one costs whatever the click did.
 */
export function isPrivateOrigin(origin: string): boolean {
  let host: string
  try {
    host = new URL(origin).hostname.toLowerCase()
  } catch {
    return false
  }
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) return true
  if (host === '::1' || host === '[::1]') return true
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host)
  if (!v4) return false
  const [a, b] = [Number(v4[1]), Number(v4[2])]
  if (a === 127 || a === 10) return true
  if (a === 192 && b === 168) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 169 && b === 254) return true
  return false
}

/* ---------------------------------------------------------------- helpers -- */

function str(args: Record<string, unknown>, key: string): string {
  const value = args[key]
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Refused('not-permitted', `${key} is required and must be a non-empty string`)
  }
  return value
}

function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') {
    throw new Refused('not-permitted', `${key} must be a string`)
  }
  return value
}

function optInt(args: Record<string, unknown>, key: string, fallback: number, min: number, max: number): number {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Refused('not-permitted', `${key} must be a number`)
  }
  return Math.min(Math.max(Math.trunc(value), min), max)
}

const VERBS: readonly StepVerb[] = ['click', 'type', 'select', 'check', 'press', 'submit']

function verbOf(args: Record<string, unknown>): StepVerb {
  const raw = args.verb
  if (typeof raw !== 'string' || !VERBS.includes(raw as StepVerb)) {
    throw new Refused('not-permitted', `verb must be one of: ${VERBS.join(', ')}`)
  }
  return raw as StepVerb
}

/**
 * Turn the driver's refusals into the dispatcher's.
 *
 * `DriveRefused` is a *rule*, not a fault — "that is a password field", "the
 * person has the page", "gave up waiting". Every one of those has to reach the
 * action log as a refusal rather than as an error, so that "the copilot was
 * told no" and "the copilot broke" stay different rows. `control.ts` does that
 * translation for `Refused`; this is what makes the driver's own vocabulary
 * arrive in it.
 */
async function asTool<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run()
  } catch (error) {
    if (error instanceof DriveRefused) throw new Refused('not-permitted', error.message)
    throw error
  }
}

/* -------------------------------------------------------------- the target -- */

/**
 * The one refusal a bad target ever produces.
 *
 * Deliberately the same words for "no such session", "that session has no such
 * window" and "that window is somebody else's", because the differences between
 * those three are exactly what an agent must not be able to learn by trying. A
 * sentence that said *"that window belongs to another session"* would confirm
 * the window exists, which is a fact about a page in his browser that nobody
 * gave this caller.
 */
const NO_SUCH_WINDOW =
  'that session has no window by that name. sessions.list says which windows each session has.'

/** A resolved target: the page to drive, and the window it belongs to. */
interface Bound {
  target: DriveTarget
  window: BoundWindow
}

/**
 * Which page a call names, or null for the caller's own tab.
 *
 * Both arguments or neither: a `window` with no session is a name with nothing
 * to resolve it against, and a `sessionId` with no window would have to guess
 * which of that session's windows was meant. Guessing here means driving a page
 * he is looking at, so it is refused instead.
 */
function boundOf(args: Record<string, unknown>): Bound | null {
  const sessionId = optStr(args, 'sessionId')
  const name = optStr(args, 'window')
  if (sessionId === null && name === null) return null
  if (sessionId === null || name === null) {
    throw new Refused('not-permitted', 'name sessionId and window together, or neither')
  }
  const window = windowNamed(sessionId, name)
  if (window === null) throw new Refused('not-permitted', NO_SUCH_WINDOW)
  if (window.viewId === null) {
    // Reaching here means the window *is* this session's — `windowNamed` has
    // already said so — so a specific sentence discloses nothing, and the state
    // is real and temporary: the renderer has registered the window but not yet
    // told us which view is in it.
    throw new Refused('not-permitted', `${slotName(window.n)} has no page in it yet`)
  }
  return {
    target: {
      key: boundKey(window.browserTabId),
      viewId: window.viewId,
      browserTabId: window.browserTabId,
      name: slotName(window.n),
    },
    window,
  }
}

/**
 * Wait for the window a session was just given to be steerable, and name it.
 *
 * ## Why an agent must not be handed a name it cannot use yet
 *
 * `openForSession` answers the moment the *shell* tab exists — which is what
 * makes the shim's `open <url>` fast — and the view inside it is registered a
 * beat later, on `browser:window-opened`. Measured in the running app: an
 * `open … newWindow` answered `Opened in B3`, and a `browser.open` naming `B3`
 * on the very next call was refused *"B3 has no page in it yet"*, while the
 * call after that worked.
 *
 * That refusal is true and is exactly the wrong thing to say to a model. It
 * reads as "that window is not real", so the sensible reaction is to open
 * another one — and the person ends up with two windows and an agent driving
 * the wrong one. So the open does not return until the window it made can be
 * driven, and the name it returns is the name the next call may use.
 *
 * `null` when it never settles, which is reported rather than guessed at: the
 * page did open and the person can see it, so the honest answer is the sentence
 * the route composed, without a name the agent would only be refused on.
 */
async function settledWindow(sessionId: string, before: ReadonlySet<number>): Promise<string | null> {
  const deadline = Date.now() + NEW_WINDOW_SETTLE_MS
  for (;;) {
    const made = windowsOf(sessionId).find(
      (window) => !before.has(window.n) && window.viewId !== null,
    )
    if (made) return slotName(made.n)
    if (Date.now() >= deadline) return null
    await new Promise((resolve) => {
      const timer = setTimeout(resolve, 60)
      timer.unref?.()
    })
  }
}

/**
 * How long a freshly opened window is given to register its view.
 *
 * The renderer's side is a `browserCreate` round trip inside a mounting panel,
 * so this is bounded by a React render rather than by anything on a network.
 * Comfortably inside the sixty seconds an MCP client allows a tool call, which
 * is the number that bounds every wait in this feature.
 */
const NEW_WINDOW_SETTLE_MS = 4_000

/** The same, for a rule that runs before the precheck and must not throw. */
function maybeBound(args: Record<string, unknown>): Bound | null {
  try {
    return boundOf(args)
  } catch {
    return null
  }
}

/** What a summary calls the page: `B2`, or the copilot's own tab. */
function whereOf(args: Record<string, unknown>): string {
  const name = optStr(args, 'window')
  return name === null ? 'the copilot’s browser tab' : (maybeBound(args)?.target.name ?? name)
}

/**
 * The two fields every verb grew, spelled once.
 *
 * On every tool rather than on a separate "target" tool, because Q4 is a parity
 * requirement: *"whatever it can do to its own tab it can do to an attached
 * one"*. A capability that reached attached windows through a different door
 * would be a second surface to keep in step, and the first verb somebody forgot
 * to add to it would be a dead end wearing the shape of a feature.
 */
const TARGET_PROPERTIES: Record<string, JsonSchema> = {
  sessionId: { type: 'string', description: 'With `window`, acts on that session’s window.' },
  window: { type: 'string', description: 'B1, B2 — a window attached to that session.' },
}

/* ------------------------------------------------------------- the schemas -- */

const OPEN_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    url: { type: 'string', description: 'http or https only.' },
    isolate: {
      type: 'boolean',
      description: 'Open in a throwaway session with none of the person’s cookies. Default false.',
    },
    ...TARGET_PROPERTIES,
    newWindow: {
      type: 'boolean',
      description: 'With `sessionId` and no `window`: open a new window attached to that session.',
    },
  },
  required: ['url'],
  additionalProperties: false,
}

const READ_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    selector: { type: 'string', description: 'CSS selector. Omit for the whole page.' },
    waitFor: { type: 'string', description: 'CSS selector to wait for before reading.' },
    timeoutMs: { type: 'number', description: 'How long to wait. Default 10000.' },
    textChars: {
      type: 'integer',
      description:
        `How much of the page's text to return, from the top. Default ${DEFAULT_OUTLINE_TEXT_CHARS}, ` +
        `max ${MAX_OUTLINE_TEXT_CHARS}. Raise it only when \`textTruncated\` was true and you need the rest.`,
    },
    ...TARGET_PROPERTIES,
  },
  additionalProperties: false,
}

const STEP_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    verb: { type: 'string', enum: [...VERBS] },
    selector: { type: 'string' },
    value: {
      type: 'string',
      description:
        'Required for type and select: the text to type, or the option to choose. Empty clears the field.',
    },
    key: { type: 'string', enum: [...PRESSABLE_KEYS], description: 'For press. Default Enter.' },
    timeoutMs: { type: 'number' },
    ...TARGET_PROPERTIES,
  },
  required: ['verb', 'selector'],
  additionalProperties: false,
}

const HANDOVER_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    prompt: { type: 'string', description: 'One line telling them what to do on the page.' },
    ...TARGET_PROPERTIES,
  },
  required: ['prompt'],
  additionalProperties: false,
}

const SHOT_SCHEMA: JsonSchema = {
  type: 'object',
  properties: { ...TARGET_PROPERTIES },
  additionalProperties: false,
}

const CLOSE_SCHEMA: JsonSchema = {
  type: 'object',
  properties: { ...TARGET_PROPERTIES },
  required: ['sessionId', 'window'],
  additionalProperties: false,
}

/* --------------------------------------------------------------- the tools -- */

export function browserTools(drive: BrowserDrive): ToolSpec[] {
  /**
   * Everything driving refuses to do for a caller that is not the person at
   * this keyboard.
   *
   * Both gates are checks here rather than sentences in an instruction file,
   * and both are sharper versions of `DRIVING-MODE.md` §7's:
   *
   *  - **Remote is refused at every one of the five tools**, not only at the
   *    handover. A paired phone that can make this Mac open a page, click
   *    through it and raise a banner saying "type your password", inside his own
   *    trusted app chrome, is a remote phishing primitive with the best possible
   *    disguise. A remote `act` grant is a real thing somebody might hand out
   *    (`surface.ts:92`); this must not ride in on it.
   *  - **Unattended is refused**, because a routine at 03:00 driving somebody's
   *    logged-in browser is the shape `surface.ts`'s
   *    `not-permitted-unattended` was written from. A routine may still *offer*
   *    to drive by posting an alert.
   */
  const local = (context: ToolContext, tool: string): void => {
    if (context.caller.kind !== 'local') {
      throw new Refused(
        'not-granted',
        `${tool} only works for the person at this machine. Driving a browser from a paired device is ` +
          'not something this app does, and it will not be. Say what you would have opened and let them do it.',
      )
    }
    if (context.attended === false) {
      throw new Refused(
        'not-permitted-unattended',
        `${tool} drives a browser that holds the person's logins, and there is nobody at the machine to ` +
          'watch it. Do not retry and do not look for another way. Say in your report what you would have ' +
          'driven and why.',
      )
    }
  }

  const openTool: ToolSpec = {
    id: 'browser.open',
    wire: 'browser_open',
    tier: 'act',
    title: 'Open a page',
    description:
      'Point a page at a URL. No target: your own tab, opened if you have none, in the tab strip where ' +
      'the person can see and close it. `sessionId` + `window`: that window, which they are probably ' +
      'looking at. `sessionId` + `newWindow`: a new window attached to that session. Then browser.read.',
    inputSchema: OPEN_SCHEMA,
    precheck: (args, context) => {
      local(context, 'browser.open')
      str(args, 'url')
      /*
       * Isolation is a property of a page that is being *built*, so it can only
       * be asked for about the copilot's own tab.
       *
       * A named window is a page the person is already looking at, and a
       * session's new window is opened by the route the shim uses, which has no
       * partition to hand it. Neither of them could act on this, and the old
       * behaviour was to accept the argument and ignore it — the same silent
       * success `schema.ts` exists to stop, one field along.
       */
      if (args.isolate === true && (optStr(args, 'window') !== null || args.newWindow === true)) {
        throw new Refused(
          'not-permitted',
          'isolate only applies to your own tab. A session’s window is a page the person opened, and it ' +
            'keeps the partition it was built with.',
        )
      }
      if (args.newWindow === true) {
        if (optStr(args, 'sessionId') === null) {
          throw new Refused('not-permitted', 'newWindow needs the sessionId it should be attached to')
        }
        if (optStr(args, 'window') !== null) {
          throw new Refused('not-permitted', 'name window or newWindow, not both')
        }
        return
      }
      boundOf(args)
    },
    summary: (args) =>
      args.newWindow === true
        ? `Open ${optStr(args, 'url') ?? '?'} in a new window for session ${optStr(args, 'sessionId') ?? '?'}`
        : `Open ${optStr(args, 'url') ?? '?'} in ${whereOf(args)}`,
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const url = str(args, 'url')
        if (args.newWindow === true) {
          /*
           * A window for the *session*, through the route the shim uses.
           *
           * `line` is the sentence that route already composes — it names the
           * slot the window took — so the agent learns the window's name from
           * the same place the person's `open <url>` learns it, rather than
           * from a second guess made here.
           */
          const sessionId = str(args, 'sessionId')
          const before = new Set(windowsOf(sessionId).map((window) => window.n))
          const made = await drive.openForSession({ url, sessionId, machineId: '' })
          if (!made.attached) throw new DriveRefused(made.line)
          const window = await settledWindow(sessionId, before)
          return {
            value: { ...made, window },
            summary: { attached: true, ...(window === null ? {} : { window }) },
          }
        }
        const bound = boundOf(args)
        const result = await drive.open(
          { url, isolate: args.isolate === true },
          bound?.target,
        )
        return {
          value: { ...result, window: bound?.target.name ?? null },
          summary: {
            url: result.url,
            title: result.title,
            settled: result.settled,
            ...(bound ? { window: bound.target.name } : {}),
          },
        }
      }),
  }

  const readTool: ToolSpec = {
    id: 'browser.read',
    wire: 'browser_read',
    tier: 'read',
    title: 'Read the page',
    description:
      'What is on a page: your own tab, or a session’s window. With no selector: the url, the title, ' +
      '`text` — the page\'s own words ' +
      'as they are rendered, which is what to quote and what to answer questions about — and every element ' +
      'you can act on, with the selector to name it in browser.step. Check `textTruncated`; raise ' +
      '`textChars` if you need the rest. `secret: true` marks a password, one-time-code or file field: it ' +
      'is listed so you know it is there, its value is never readable, and nothing will type into it. ' +
      'With a selector: the text at that selector — for one exact value, once the outline has shown you ' +
      'that the element exists. Do not guess selectors to find text; read the page and the text is there. ' +
      'Use waitFor instead of calling this repeatedly.',
    inputSchema: READ_SCHEMA,
    precheck: (args, context) => {
      local(context, 'browser.read')
      optStr(args, 'selector')
      optStr(args, 'waitFor')
      boundOf(args)
    },
    summary: (args) => {
      const selector = optStr(args, 'selector')
      return selector === null ? `Read ${whereOf(args)}` : `Read ${selector} in ${whereOf(args)}`
    },
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const target = boundOf(args)?.target ?? null
        const timeoutMs = optInt(args, 'timeoutMs', 10_000, 500, 30_000)
        const waitFor = optStr(args, 'waitFor')
        if (waitFor !== null) {
          // Waiting is what stops a model polling, and polling is what spends a
          // budget window in fifteen seconds.
          await drive.waitFor(waitFor, timeoutMs, target)
        }
        const selector = optStr(args, 'selector')
        if (selector !== null) {
          const text = await drive.textAt(selector, 4_000, target)
          if (!text.found) {
            throw new DriveRefused(`nothing on the page matches ${selector}`)
          }
          return {
            value: { selector, text: text.text, truncated: text.truncated, secret: text.secret },
            summary: { selector, chars: text.text.length },
          }
        }
        const outline = await drive.outline(
          60,
          optInt(args, 'textChars', DEFAULT_OUTLINE_TEXT_CHARS, 200, MAX_OUTLINE_TEXT_CHARS),
          target,
        )
        return {
          value: outline,
          summary: {
            url: outline.url,
            elements: outline.elements.length,
            // In the action log as a length, never as the text. A page is
            // somebody's browsing, and `actions.jsonl` is a list to be skimmed
            // rather than a second copy of every page the copilot looked at.
            textChars: outline.text.length,
          },
        }
      }),
  }

  const stepTool: ToolSpec = {
    id: 'browser.step',
    wire: 'browser_step',
    tier: 'act',
    title: 'Do one thing on the page',
    description:
      'One interaction on your own tab or on a session’s window: click, type, select, check, press or ' +
      'submit. It waits for the element to exist, be ' +
      'visible, stop moving, be enabled, and actually be the thing at that point — so a click never lands ' +
      'on a spinner or a cookie banner. Typing into a password, one-time-code or file field is refused: use ' +
      'browser.handover. The first change on a public website asks the person once, then the rest of that ' +
      'site is ordinary.',
    inputSchema: STEP_SCHEMA,
    /*
     * `act` on his own machines, `alter` the first time on a public website.
     *
     * `DRIVING-MODE.md` put driving at `act` because "nothing driving does
     * persists". That is true of moving the app's own screen and flatly untrue
     * of driving a website: a click on a real site can send money. One question,
     * at the point where the answer is meaningful, then silence for the rest of
     * that origin.
     *
     * The origin is read off the WebContents, so the grant lapses the moment the
     * tab moves — including by a link click or a server redirect — with no
     * cooperation needed from the model.
     */
    escalate: (args): Tier => {
      // The *target's* origin, not the drive's. A grant is a person's answer
      // about one site on one page, so reading it off the wrong page would
      // carry a yes given for the copilot's own tab onto a window he is
      // looking at. `maybeBound` never throws: this rule runs ahead of the
      // precheck, and a throw here is read as "assume alter" rather than as
      // the refusal the precheck is about to give.
      const target = maybeBound(args)?.target ?? null
      const origin = drive.origin(target)
      if (origin === null) return 'act'
      if (isPrivateOrigin(origin)) return 'act'
      return drive.originGranted(origin, target) ? 'act' : 'alter'
    },
    precheck: (args, context) => {
      local(context, 'browser.step')
      const verb = verbOf(args)
      const selector = str(args, 'selector')
      const bound = boundOf(args)
      /*
       * Before the gate, and that ordering is the whole point of it being here.
       *
       * Refusing this inside `run` — which is where it started — put a dialog on
       * screen reading "Type 21 characters into #wpPassword1", waited for the
       * person to click Allow, and *then* refused. Photographed on 2026-08-17
       * against a real Wikipedia login form. `control.ts` names that shape
       * exactly: a rule the person is asked about is not a rule, and a refusal
       * that arrives after a yes has already trained them to click yes.
       *
       * A precheck is synchronous and a page cannot be asked synchronously, so
       * this reads what the last `browser.read` already learned. See
       * `BrowserDrive.knownSecret`. The check in the driver stays as well, for
       * the selector nobody has read yet.
       */
      /*
       * A type with nothing to type, refused rather than performed.
       *
       * The schema says `value` and a call once said `text`. Nothing rejected
       * the argument it did not know, the driver typed `value ?? ''` — which
       * clears the field, deliberately — and the tool reported success. An
       * agent that believes it typed carries on: it clicks search, reads the
       * results and explains why they are odd. A refusal costs one turn.
       *
       * Absent is refused; an empty string is honoured, because clearing a
       * field is a real thing to want and it is the one spelling of it.
       */
      if ((verb === 'type' || verb === 'select') && args.value === undefined) {
        throw new Refused(
          'not-permitted',
          verb === 'type'
            ? 'a type step needs `value` — the text to type. Send an empty string only to clear the field.'
            : 'a select step needs `value` — the option to choose.',
        )
      }
      if (verb === 'select' && optStr(args, 'value') === null) {
        throw new Refused('not-permitted', 'a select step needs an option to choose; `value` is empty')
      }
      if (verb === 'type' && drive.knownSecret(selector, bound?.target)) {
        throw new Refused(
          'not-permitted',
          `${selector} is a password, one-time-code or file field. Nothing will be typed into it and the ` +
            'person was not asked. Call browser.handover with a sentence saying what they should fill in — ' +
            'you will not see what they type, and neither will the log.',
        )
      }
    },
    /*
     * The sentence in the dialog and in the log — and the one place a password
     * would otherwise be quoted.
     *
     * `sessions.send` deliberately quotes its text, because a prompt to an agent
     * is a thing a person needs to read back. A form value is not, so this says
     * how many characters and never which. See `redactArgs` below for the other
     * half: the raw arguments row.
     */
    summary: (args) => {
      const verb = typeof args.verb === 'string' ? args.verb : '?'
      const selector = optStr(args, 'selector') ?? '?'
      const value = optStr(args, 'value')
      const target = maybeBound(args)?.target ?? null
      const site = drive.origin(target) ?? 'the page'
      // The window's name leads when there is one, because `B2` is what he says
      // out loud and an origin alone cannot tell two windows apart.
      const where = target === null ? site : `${target.name} (${site})`
      if (verb === 'type') {
        return `Type ${value === null ? 0 : value.length} characters into ${selector} on ${where}`
      }
      return `${verb} ${selector} on ${where}`
    },
    redactArgs: (args) => {
      const value = args.value
      const out = { ...args }
      // Replaced by its length, not deleted: a row that says nothing about the
      // value cannot be told apart from a row where nothing was typed.
      if (typeof value === 'string') out.value = `[${value.length} characters]`
      return out
    },
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const target = boundOf(args)?.target ?? null
        const verb = verbOf(args)
        const selector = str(args, 'selector')
        const value = optStr(args, 'value')
        const key = optStr(args, 'key')
        const result = await drive.act(
          {
            verb,
            selector,
            ...(value === null ? {} : { value }),
            ...(key === null ? {} : { key }),
            timeoutMs: optInt(args, 'timeoutMs', 10_000, 500, 30_000),
          },
          target,
        )
        // Remembered *after* the step succeeded, so a refused confirmation does
        // not leave a grant behind on an origin nothing was ever done to.
        const origin = drive.origin(target)
        if (origin !== null && !isPrivateOrigin(origin)) drive.noteOriginGranted(origin, target)
        return {
          value: { ...result, window: target?.name ?? null },
          summary: {
            verb,
            selector,
            label: result.label,
            url: result.url,
            ...(target === null ? {} : { window: target.name }),
            ...(verb === 'type' && value !== null ? { chars: value.length } : {}),
          },
        }
      }),
  }

  const screenshotTool: ToolSpec = {
    id: 'browser.screenshot',
    wire: 'browser_screenshot',
    tier: 'read',
    title: 'Photograph the page',
    description:
      'A PNG of your own tab or of a session’s window, written to the copilot’s folder. Returns the path ' +
      'and the size, never the ' +
      'image. Every password, one-time-code and file field is painted out before the file is written. Prefer ' +
      'browser.read — the outline is what tells you what to click, and a picture is not.',
    inputSchema: SHOT_SCHEMA,
    precheck: (args, context) => {
      local(context, 'browser.screenshot')
      boundOf(args)
    },
    summary: (args) => `Photograph ${whereOf(args)}`,
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const target = boundOf(args)?.target ?? null
        const shot = await drive.screenshot(target)
        return {
          value: { ...shot, window: target?.name ?? null },
          summary: { ...shot, ...(target === null ? {} : { window: target.name }) },
        }
      }),
  }

  const handoverTool: ToolSpec = {
    id: 'browser.handover',
    wire: 'browser_handover',
    tier: 'act',
    title: 'Give the page to the person',
    description:
      'Hand the page over and wait. Use it for anything you must not do: signing in, a password, a ' +
      'one-time code, a payment, a CAPTCHA. While they have it you cannot read the page, photograph it, ' +
      'click it or type in it — nothing you can see records what they type. It returns after about 45 ' +
      'seconds; `resumed: false` with `still-waiting` means they are not finished, which is normal. Call it ' +
      'again to keep waiting, or say something to them. It has not failed.',
    inputSchema: HANDOVER_SCHEMA,
    precheck: (args, context) => {
      local(context, 'browser.handover')
      str(args, 'prompt')
      boundOf(args)
    },
    summary: (args) =>
      `Ask the person to take over ${whereOf(args)}: ${optStr(args, 'prompt') ?? ''}`,
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const target = boundOf(args)?.target ?? null
        const result = await drive.handover(str(args, 'prompt'), HANDOVER_WINDOW_MS, target)
        return {
          value: {
            resumed: result.outcome === 'resumed',
            reason: result.outcome,
            url: result.url,
            title: result.title,
            waitedMs: result.waitedMs,
          },
          summary: { outcome: result.outcome, waitedMs: result.waitedMs, url: result.url },
        }
      }),
  }

  /**
   * The one verb that has no equivalent on the copilot's own tab, and why.
   *
   * Q4 asks for parity — *"whatever it can do to its own tab it can do to an
   * attached one"* — and this is the direction that argument allows to be
   * uneven: an attached window can do one thing more, not one thing less. The
   * copilot's tab is not closable from a tool because the id the shell knows it
   * by never reaches the main process (the renderer answers the drive with the
   * *view* id), so a close would tear the page down and leave a row in the
   * strip pointing at nothing. The person's ✕ closes that one and already ends
   * the drive.
   *
   * `act` rather than `alter`, on the same reasoning as every other verb here:
   * the window is one this app opened, in this app's own strip, that the person
   * attached to this session by hand — and `browser.open` may already navigate
   * it away, which loses the page just as completely. What `alter` is for is a
   * change out on the internet, and closing a window is not one.
   */
  const closeTool: ToolSpec = {
    id: 'browser.close',
    wire: 'browser_close',
    tier: 'act',
    title: 'Close a window',
    description:
      'Close one of a session’s windows. Numbers are not reused, so closing B1 leaves B2 called B2. ' +
      'Your own tab is closed by the person.',
    inputSchema: CLOSE_SCHEMA,
    precheck: (args, context) => {
      local(context, 'browser.close')
      boundOf(args)
    },
    summary: (args) => `Close ${whereOf(args)}`,
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const bound = boundOf(args)
        if (bound === null) {
          throw new DriveRefused('name the session and the window to close')
        }
        await drive.close(bound.target)
        return {
          value: { closed: bound.target.name },
          summary: { window: bound.target.name },
        }
      }),
  }

  return [openTool, readTool, stepTool, screenshotTool, handoverTool, closeTool]
}
