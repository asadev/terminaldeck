import type { BrowserDrive, StepVerb } from '../browser-driver'
import { DriveRefused, PRESSABLE_KEYS } from '../browser-driver'
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
 * ## Why there is no tabId anywhere
 *
 * The agent has *one* tab: the one `browser.open` gave it. Calling `open` again
 * navigates that same tab, and it can never touch a tab the person opened. That
 * removes an entire class of "drove the wrong tab", removes "a scrape hijacked
 * the page I was reading" completely, and — the part that is load-bearing — it
 * is what makes reading safe at the `read` tier: the agent can only read pages
 * it navigated to itself, so a read discloses nothing it did not already know.
 * If the agent could adopt his tabs, `browser.read` and `browser.screenshot`
 * would both have to be `alter`.
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

/* ------------------------------------------------------------- the schemas -- */

const OPEN_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    url: { type: 'string', description: 'http or https only.' },
    isolate: {
      type: 'boolean',
      description: 'Open in a throwaway session with none of the person’s cookies. Default false.',
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
  },
  additionalProperties: false,
}

const STEP_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    verb: { type: 'string', enum: [...VERBS] },
    selector: { type: 'string' },
    value: { type: 'string', description: 'For type and select.' },
    key: { type: 'string', enum: [...PRESSABLE_KEYS], description: 'For press.' },
    timeoutMs: { type: 'number' },
  },
  required: ['verb', 'selector'],
  additionalProperties: false,
}

const HANDOVER_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    prompt: { type: 'string', description: 'One line telling them what to do on the page.' },
  },
  required: ['prompt'],
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
      'Point your one browser tab at a URL, opening it if you have none. You get exactly one tab and this ' +
      'is it — there is no tab id, and you can never touch a tab the person opened. Needs a browser open in ' +
      'the app; if there is none it says so, and the person opens one from the sidebar. Follow with ' +
      'browser.read to see what is on the page.',
    inputSchema: OPEN_SCHEMA,
    precheck: (args, context) => {
      local(context, 'browser.open')
      str(args, 'url')
    },
    summary: (args) => `Open ${optStr(args, 'url') ?? '?'} in the copilot’s browser tab`,
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const result = await drive.open({
          url: str(args, 'url'),
          isolate: args.isolate === true,
        })
        return {
          value: result,
          summary: { url: result.url, title: result.title, settled: result.settled },
        }
      }),
  }

  const readTool: ToolSpec = {
    id: 'browser.read',
    wire: 'browser_read',
    tier: 'read',
    title: 'Read the page',
    description:
      'What is on the page you opened. With no selector: the url, the title, and every element you can act ' +
      'on — role, label, and the selector to name it in browser.step. `secret: true` marks a password, ' +
      'one-time-code or file field: it is listed so you know it is there, its value is never readable, and ' +
      'nothing will type into it. With a selector: the text at that selector. Use waitFor instead of ' +
      'calling this repeatedly.',
    inputSchema: READ_SCHEMA,
    precheck: (args, context) => {
      local(context, 'browser.read')
      optStr(args, 'selector')
      optStr(args, 'waitFor')
    },
    summary: (args) => {
      const selector = optStr(args, 'selector')
      return selector === null ? 'Read the page in the copilot’s browser tab' : `Read ${selector}`
    },
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const timeoutMs = optInt(args, 'timeoutMs', 10_000, 500, 30_000)
        const waitFor = optStr(args, 'waitFor')
        if (waitFor !== null) {
          // Waiting is what stops a model polling, and polling is what spends a
          // budget window in fifteen seconds.
          await drive.waitFor(waitFor, timeoutMs)
        }
        const selector = optStr(args, 'selector')
        if (selector !== null) {
          const text = await drive.textAt(selector, 4_000)
          if (!text.found) {
            throw new DriveRefused(`nothing on the page matches ${selector}`)
          }
          return {
            value: { selector, text: text.text, truncated: text.truncated, secret: text.secret },
            summary: { selector, chars: text.text.length },
          }
        }
        const outline = await drive.outline(60)
        return {
          value: outline,
          summary: { url: outline.url, elements: outline.elements.length },
        }
      }),
  }

  const stepTool: ToolSpec = {
    id: 'browser.step',
    wire: 'browser_step',
    tier: 'act',
    title: 'Do one thing on the page',
    description:
      'One interaction: click, type, select, check, press or submit. It waits for the element to exist, be ' +
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
    escalate: (): Tier => {
      const origin = drive.origin()
      if (origin === null) return 'act'
      if (isPrivateOrigin(origin)) return 'act'
      return drive.originGranted(origin) ? 'act' : 'alter'
    },
    precheck: (args, context) => {
      local(context, 'browser.step')
      const verb = verbOf(args)
      const selector = str(args, 'selector')
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
      if (verb === 'type' && drive.knownSecret(selector)) {
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
      const where = drive.origin() ?? 'the page'
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
        const verb = verbOf(args)
        const selector = str(args, 'selector')
        const value = optStr(args, 'value')
        const key = optStr(args, 'key')
        const result = await drive.act({
          verb,
          selector,
          ...(value === null ? {} : { value }),
          ...(key === null ? {} : { key }),
          timeoutMs: optInt(args, 'timeoutMs', 10_000, 500, 30_000),
        })
        // Remembered *after* the step succeeded, so a refused confirmation does
        // not leave a grant behind on an origin nothing was ever done to.
        const origin = drive.origin()
        if (origin !== null && !isPrivateOrigin(origin)) drive.noteOriginGranted(origin)
        return {
          value: result,
          summary: {
            verb,
            selector,
            label: result.label,
            url: result.url,
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
      'A PNG of your browser tab, written to the copilot’s folder. Returns the path and the size, never the ' +
      'image. Every password, one-time-code and file field is painted out before the file is written. Prefer ' +
      'browser.read — the outline is what tells you what to click, and a picture is not.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    precheck: (_args, context) => local(context, 'browser.screenshot'),
    summary: () => 'Photograph the copilot’s browser tab',
    run: async (): Promise<ToolOutput> =>
      asTool(async () => {
        const shot = await drive.screenshot()
        return { value: shot, summary: shot }
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
      'click it or type in it — nothing you can see records what they type. It returns after about 90 ' +
      'seconds; `resumed: false` with `still-waiting` means they are not finished, which is normal. Call it ' +
      'again to keep waiting, or say something to them. It has not failed.',
    inputSchema: HANDOVER_SCHEMA,
    precheck: (args, context) => {
      local(context, 'browser.handover')
      str(args, 'prompt')
    },
    summary: (args) => `Ask the person to take over the browser: ${optStr(args, 'prompt') ?? ''}`,
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const result = await drive.handover(str(args, 'prompt'), HANDOVER_WINDOW_MS)
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

  return [openTool, readTool, stepTool, screenshotTool, handoverTool]
}
