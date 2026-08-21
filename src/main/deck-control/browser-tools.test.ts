import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import { ActionLog } from './action-log'
import { attach, resetForTests } from '../browser-binding'
import { browserTools, isPrivateOrigin } from './browser-tools'
import { buildCatalogue, catalogueCost } from './catalogue'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { ALL_TIERS as ALL, NO_TIERS, type Caller, type DeckSurface } from './surface'

/**
 * The tool surface, and the one promise it makes about a password.
 *
 * The drive itself is exercised against real websites by
 * `scripts/check-browser-drive.mjs`, because everything interesting about it is
 * a fact about Chromium. What is tested here is the layer above: who may call
 * these at all, when a click needs asking about, and — the one that matters
 * most — that a string typed into a page cannot reach the file on disk that
 * records what the copilot did.
 */

/** A sentinel nobody would ever type by accident, so a grep for it means something. */
const SENTINEL = 'zzq-SENTINEL-7fa19d4c-not-a-real-password'

/** A drive that answers, records what it was asked, and touches no Electron. */
function fakeDrive(origin: string | null): BrowserDrive & { calls: unknown[] } {
  const calls: unknown[] = []
  let granted: string | null = null
  const drive = {
    calls,
    origin: () => origin,
    originGranted: (value: string) => granted === value,
    // The default: a drive that has not read the page yet knows nothing about
    // its fields, which is the state the run-time refusal exists for.
    knownSecret: () => false,
    noteOriginGranted: (value: string) => {
      granted = value
    },
    open: async (input: unknown) => {
      calls.push(['open', input])
      return { url: 'https://example.com/', title: 'Example', settled: true, created: true }
    },
    // The page's own words travel with the outline. Mirrored here because a
    // stub that disagrees with the real shape invents bugs and hides real ones
    // — the standing rule for `.harness/stub.ts`, and it applies to this fake
    // for the same reason: `browser.read` reads `outline.text` directly.
    outline: async () => ({
      url: 'https://example.com/',
      title: 'Example',
      text: 'Example Domain\n\nThis domain is for use in documentation examples.',
      textTruncated: false,
      elements: [
        { kind: 'field', tag: 'input', type: 'password', label: 'Password', selector: '#pw', secret: true, enabled: true },
      ],
      matched: 1,
      truncated: false,
    }),
    textAt: async () => ({ found: true, secret: false, text: 'hello', truncated: false }),
    waitFor: async () => ({ found: true, count: 1 }),
    act: async (input: unknown, target: unknown) => {
      calls.push(['act', input, target])
      return { verb: 'type', selector: '#user', label: 'Username', url: 'https://example.com/' }
    },
    screenshot: async (target: unknown) => {
      calls.push(['screenshot', target])
      return { path: '/tmp/x.png', width: 100, height: 100, masked: 1 }
    },
    handover: async () => ({ outcome: 'resumed' as const, waitedMs: 10, url: '', title: '' }),
    close: async (target: unknown) => {
      calls.push(['close', target])
      return true
    },
  }
  return drive as unknown as BrowserDrive & { calls: unknown[] }
}

/**
 * A broker that says yes the moment it is asked.
 *
 * Answered inside `ask`, which works because the broker registers the pending
 * entry *before* it delivers — see the long note on that ordering in
 * `consent.ts`. Standing in for a person who clicks Allow, so the tests below
 * can be about the tier decision rather than about the dialog.
 */
function approving(): ConsentBroker {
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  return broker
}

function control(drive: BrowserDrive, logDir: string): DeckControl {
  return new DeckControl({
    // The browser tools never reach the surface — they talk to the drive — so an
    // empty one is honest here rather than lazy. A tool that started using it
    // would fail loudly on the first call.
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: logDir }),
    consent: approving(),
    extraTools: browserTools(drive),
  })
}

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-browser-tools-'))
  resetForTests()
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('what a page text never reaches', () => {
  it('keeps typed text out of the action log', async () => {
    /*
     * The whole of §3.4's sixth mechanism, as one assertion.
     *
     * `scrubArgs` redacts by key *name* and `SECRET_KEY` matches nothing called
     * `value`, so before `redactArgs` existed this exact call wrote the string
     * into `actions.jsonl` verbatim. The tool refuses to type into a field the
     * page marks secret — that is the first line of defence and it is tested
     * against a real login form by the drive check — and this is what holds for
     * a site that renders its password box as `type="text"`, which is rare and
     * real.
     */
    const deck = control(fakeDrive('https://example.com'), dir)
    const result = await deck.call('browser_step', {
      verb: 'type',
      selector: '#pw',
      value: SENTINEL,
    })
    expect(result.ok).toBe(true)

    const written = readFileSync(join(dir, 'actions.jsonl'), 'utf8')
    expect(written).not.toContain(SENTINEL)
    // …and it says how much was typed, so the row is still readable as a record
    // of what happened rather than as a blank.
    expect(written).toContain(`[${SENTINEL.length} characters]`)
  })

  it('keeps typed text out of the sentence a person is shown', async () => {
    // The same string is the confirmation dialog's text and the log's `detail`.
    // `sessions.send` quotes its text on purpose; this must not.
    const deck = control(fakeDrive('https://example.com'), dir)
    await deck.call('browser_step', { verb: 'type', selector: '#pw', value: SENTINEL })
    const written = readFileSync(join(dir, 'actions.jsonl'), 'utf8')
    const row = JSON.parse(written.trim().split('\n').pop() ?? '{}')
    expect(String(row.detail)).not.toContain(SENTINEL)
    expect(String(row.detail)).toContain(`${SENTINEL.length} characters`)
  })

  it('keeps typed text out of the tool’s own result and summary', async () => {
    const deck = control(fakeDrive('https://example.com'), dir)
    const result = await deck.call('browser_step', { verb: 'type', selector: '#pw', value: SENTINEL })
    expect(JSON.stringify(result.value)).not.toContain(SENTINEL)
    expect(JSON.stringify(result.row.result)).not.toContain(SENTINEL)
  })

  it('never hands back a secret field’s value in an outline', async () => {
    const deck = control(fakeDrive('https://example.com'), dir)
    const result = await deck.call('browser_read', {})
    const payload = JSON.stringify(result.value)
    expect(payload).toContain('"secret":true')
    expect(payload).not.toContain('"value"')
  })

  it('gives the model the page’s words, and the log only their length', async () => {
    /*
     * The half of `browser.read` that was missing until 2026-08-18. Asked in
     * words to read a form's result line, the copilot had to guess four
     * selectors to reach one sentence, because the outline described the
     * controls and never the page. It is pinned in both directions: the text
     * reaches the model, and it does *not* reach `actions.jsonl`, which is a
     * list somebody skims rather than a copy of every page that was looked at.
     */
    const deck = control(fakeDrive('https://example.com'), dir)
    const result = await deck.call('browser_read', {})
    expect(JSON.stringify(result.value)).toContain('This domain is for use in documentation examples.')

    const written = readFileSync(join(dir, 'actions.jsonl'), 'utf8')
    expect(written).not.toContain('This domain is for use in documentation examples.')
    expect(written).toContain('textChars')
  })
})

describe('who may drive', () => {
  const remote: Caller = { kind: 'remote', deviceId: 'phone-1', tiers: { read: true, act: true, alter: true } }

  /*
   * Each tool's own arguments, rather than one object carrying every field any
   * of them takes.
   *
   * That object used to work because nothing checked; `additionalProperties:
   * false` is enforced at the door now — see `schema.ts` — so `browser_read`
   * handed a `verb` is refused for the wrong reason and these cases would stop
   * testing the thing they are named after.
   */
  const ARGS: Record<string, Record<string, unknown>> = {
    browser_open: { url: 'https://x.test' },
    browser_read: {},
    browser_step: { verb: 'click', selector: '#a' },
    browser_screenshot: {},
    browser_handover: { prompt: 'hi' },
    browser_close: { sessionId: 's1', window: 'B1' },
  }

  it.each(['browser_open', 'browser_read', 'browser_step', 'browser_screenshot', 'browser_handover'])(
    'refuses %s from a paired device, at every tier it holds',
    async (tool) => {
      /*
       * Not only the handover. A phone that can make this Mac open a page, click
       * through it and raise a banner saying "type your password", inside his
       * own trusted app chrome, is a remote phishing primitive with the best
       * possible disguise — and a remote `act` grant is a real thing somebody
       * might hand out.
       */
      const deck = control(fakeDrive('https://example.com'), dir)
      const result = await deck.call(tool, ARGS[tool], { caller: remote })
      expect(result.ok).toBe(false)
      expect(result.refusal).toBe('not-granted')
    },
  )

  it.each(['browser_open', 'browser_read', 'browser_step', 'browser_screenshot', 'browser_handover'])(
    'refuses %s from a run with nobody at the machine',
    async (tool) => {
      const deck = control(fakeDrive('https://example.com'), dir)
      const result = await deck.call(tool, ARGS[tool], { attended: false })
      expect(result.ok).toBe(false)
      expect(result.refusal).toBe('not-permitted-unattended')
      // The sentence has to stop a retry loop rather than describe a state.
      expect(result.error).toContain('Do not retry')
    },
  )

  it('refuses a local caller that was never granted act', async () => {
    const deck = control(fakeDrive('https://example.com'), dir)
    const stripped: Caller = { kind: 'local', tiers: NO_TIERS }
    const result = await deck.call('browser_open', { url: 'https://x.test' }, { caller: stripped })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
  })
})

describe('when a click has to be asked about', () => {
  it('is an ordinary action on his own machine', async () => {
    for (const origin of ['http://localhost:3000', 'http://127.0.0.1:8080', 'http://192.168.1.4', 'http://dev.local']) {
      const deck = control(fakeDrive(origin), dir)
      const result = await deck.call('browser_step', { verb: 'click', selector: '#go' })
      expect(result.ok).toBe(true)
      expect(result.row.tier).toBe('act')
    }
  })

  it('asks once on a public website, then stops asking for that site', async () => {
    const drive = fakeDrive('https://amazon.co.uk')
    const deck = control(drive, dir)

    const first = await deck.call('browser_step', { verb: 'click', selector: '#buy' })
    expect(first.row.tier).toBe('alter')
    expect(first.row.confirmed.required).toBe(true)

    const second = await deck.call('browser_step', { verb: 'click', selector: '#confirm' })
    expect(second.row.tier).toBe('act')
    expect(second.row.confirmed.required).toBe(false)
  })

  it('does not remember a grant for a step that was refused', async () => {
    // Otherwise a declined confirmation would leave an origin unlocked that
    // nothing was ever done to.
    const drive = fakeDrive('https://amazon.co.uk')
    const deck = new DeckControl({
      surface: {} as DeckSurface,
      log: new ActionLog({ dir }),
      consent: new ConsentBroker({ ask: () => true, timeoutMs: 5 }),
      extraTools: browserTools(drive),
    })
    // No approver answers within the 5 ms timeout, so the first call is refused.
    const first = await deck.call('browser_step', { verb: 'click', selector: '#buy' })
    expect(first.ok).toBe(false)
    const second = await deck.call('browser_step', { verb: 'click', selector: '#buy' })
    expect(second.row.tier).toBe('alter')
  })

  it('treats anything it cannot place as public', () => {
    expect(isPrivateOrigin('http://localhost:3000')).toBe(true)
    expect(isPrivateOrigin('http://10.0.0.1')).toBe(true)
    expect(isPrivateOrigin('http://172.16.0.1')).toBe(true)
    expect(isPrivateOrigin('http://172.32.0.1')).toBe(false)
    expect(isPrivateOrigin('https://example.com')).toBe(false)
    // `localhost.evil.com` resolves wherever its owner says, so it is not his
    // machine however much it looks like it.
    expect(isPrivateOrigin('https://localhost.evil.com')).toBe(false)
    expect(isPrivateOrigin('not a url')).toBe(false)
  })
})

describe('the shape of the surface', () => {
  it('is six tools with wire names the API will accept', () => {
    const tools = browserTools(fakeDrive(null))
    expect(tools.map((tool) => tool.id)).toEqual([
      'browser.open',
      'browser.read',
      'browser.step',
      'browser.screenshot',
      'browser.handover',
      'browser.close',
    ])
    for (const tool of tools) {
      // A dot is rejected by the Anthropic API, not by this app, which is the
      // worst place to find out. `catalogue.ts` pins the same rule for the
      // built-ins.
      expect(tool.wire).toMatch(/^[a-zA-Z0-9_-]+$/)
    }
  })

  it('has no tool that takes a free-form expression', () => {
    /*
     * The load-bearing absence. §3.4's first mechanism and §2.6's last
     * paragraph both say the same thing: the day somebody adds a sixth tool
     * that takes an expression, every other guarantee in this feature becomes
     * decorative. This is what fails when they do.
     */
    for (const tool of browserTools(fakeDrive(null))) {
      const properties = Object.keys(
        (tool.inputSchema.properties ?? {}) as Record<string, unknown>,
      )
      for (const name of ['expression', 'script', 'code', 'js', 'eval', 'fn']) {
        expect(properties).not.toContain(name)
      }
    }
    expect(browserTools(fakeDrive(null)).map((t) => t.id)).not.toContain('browser.eval')
  })

  it('reads and screenshots at the read tier, because the agent can only see pages it opened', () => {
    const byId = new Map(browserTools(fakeDrive(null)).map((tool) => [tool.id, tool]))
    expect(byId.get('browser.read')?.tier).toBe('read')
    expect(byId.get('browser.screenshot')?.tier).toBe('read')
    expect(byId.get('browser.open')?.tier).toBe('act')
    expect(byId.get('browser.handover')?.tier).toBe('act')
  })
})

describe('a password field is refused before anybody is asked', () => {
  /**
   * A drive that has already read the page and knows which field is secret.
   *
   * Which is what any real flow looks like: the tool descriptions tell the
   * model to read the page before acting on it, and `browser.read` is what
   * teaches the drive the answer this precheck reads.
   */
  function driveKnowingSecret(): BrowserDrive {
    const base = fakeDrive('https://auth.wikimedia.org') as unknown as Record<string, unknown>
    base.knownSecret = (selector: string) => selector === '#wpPassword1'
    return base as unknown as BrowserDrive
  }

  it('never draws a dialog for typing into one', async () => {
    /*
     * The bug this exists for, in one assertion. It was photographed against a
     * real login form: the dialog said "Type 21 characters into #wpPassword1",
     * the person clicked Allow, and the refusal arrived *after*. `control.ts`
     * names that shape — a rule the person is asked about is not a rule — and
     * the same mistake was found once before in `settings.write`.
     */
    let asked = 0
    const deck = new DeckControl({
      surface: {} as DeckSurface,
      log: new ActionLog({ dir }),
      consent: new ConsentBroker({
        ask: () => {
          asked++
          return true
        },
        timeoutMs: 20,
      }),
      extraTools: browserTools(driveKnowingSecret()),
    })
    const result = await deck.call('browser_step', {
      verb: 'type',
      selector: '#wpPassword1',
      value: SENTINEL,
    })
    expect(asked).toBe(0)
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('handover')
  })

  it('still lets the person be asked about an ordinary field on the same form', async () => {
    const deck = control(driveKnowingSecret(), dir)
    const result = await deck.call('browser_step', { verb: 'type', selector: '#wpName1', value: 'someone' })
    expect(result.ok).toBe(true)
  })

  it('does not refuse a click on the password field, only typing into it', async () => {
    // Focusing it is how a person is handed a form with the cursor in the right
    // box. It is reading and writing the *value* that is refused.
    const deck = control(driveKnowingSecret(), dir)
    const result = await deck.call('browser_step', { verb: 'click', selector: '#wpPassword1' })
    expect(result.ok).toBe(true)
  })

  it('keeps the sentinel out of the log even on the refused path', async () => {
    const deck = control(driveKnowingSecret(), dir)
    await deck.call('browser_step', { verb: 'type', selector: '#wpPassword1', value: SENTINEL })
    expect(readFileSync(join(dir, 'actions.jsonl'), 'utf8')).not.toContain(SENTINEL)
  })
})

describe('what these six cost the copilot on every turn', () => {
  /*
   * **The budget is not measured here, and it used to be — wrongly.**
   *
   * What stood here measured `buildCatalogue()` plus these six, called the
   * result "the assembled catalogue", asserted it was inside both ceilings, and
   * concluded that the tool count was "now exactly `MAX_CATALOGUE_TOOLS`". The
   * app assembles nine sources: `tour.play`, `app.where`, the worker verbs, the
   * asset checks, `browser.extract` and the three `servers.*` verbs were all
   * outside the measurement, and with them the shipped list reached 33 tools
   * against a cap of 20 — over the ceiling, and green here the whole time.
   *
   * The whole list is measured in `catalogue-cost.test.ts`, which is the file
   * to change when a tool is added, and which since 2026-08-21 measures what is
   * *advertised* rather than what exists — fifteen tools are held behind
   * `tools.describe`. These six are not among them: they are the first reach on
   * every browser turn, which is the rule `describe-tool.ts` states. What is
   * left here is the one figure this file is the right place for: what these
   * six add on their own.
   */
  it('records what the six actually add, so a rewrite that doubles it is visible', () => {
    // Measured, not asserted at a round number: the point of writing it down is
    // that somebody expanding a description sees the figure move.
    const base = catalogueCost(buildCatalogue())
    const withBrowser = catalogueCost([...buildCatalogue(), ...browserTools(fakeDrive(null))])
    expect(withBrowser.tools - base.tools).toBe(6)
    /*
     * 4,151 characters over five tools when this was first measured; 6,312 over
     * six once every verb grew `sessionId` and `window` and `browser.close`
     * arrived. Per tool that is 830 → 1,052, which is the figure to watch: the
     * jump is a sixth tool and two fields on five schemas, not descriptions
     * getting longer.
     */
    expect(withBrowser.chars - base.chars).toBeLessThan(7_000)
  })
})

/**
 * Q2 and the boundary under it: a verb may name a window, and only one the
 * session it names actually holds.
 *
 * These are about the *tool* layer rather than the driver — that a target is
 * built from the binding map and from nothing the model said, and that the
 * three ways a name can fail are one sentence.
 */
describe('naming a session’s window', () => {
  it('sends the call to the window the session holds, by its name', async () => {
    attach({ sessionId: 'mine', browserTabId: 'browser:1:2', viewId: 'view-2' })
    // `B1` first so the numbering is not accidentally the identity under test.
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_screenshot', { sessionId: 'mine', window: 'B1' })

    expect(result.ok).toBe(true)
    expect(drive.calls).toContainEqual([
      'screenshot',
      { key: 'bound:browser:1:2', viewId: 'view-2', browserTabId: 'browser:1:2', name: 'B1' },
    ])
  })

  /**
   * The one that matters. `theirs` has a `B1`; `mine` does not. Both refusals
   * have to be the same sentence, or an agent can find out which pages exist in
   * the app by trying names.
   */
  it('refuses another session’s window in the same words as one that never existed', async () => {
    attach({ sessionId: 'theirs', browserTabId: 'browser:2:1', viewId: 'view-9' })
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const somebodyElses = await deck.call('browser_read', { sessionId: 'mine', window: 'B1' })
    const neverExisted = await deck.call('browser_read', { sessionId: 'nobody', window: 'B7' })

    expect(somebodyElses.ok).toBe(false)
    expect(neverExisted.ok).toBe(false)
    expect(somebodyElses.error).toBe(neverExisted.error)
    // And nothing was driven on the way to being refused.
    expect(drive.calls).toEqual([])
  })

  it('will not take a window with no session to resolve it against', async () => {
    const deck = control(fakeDrive('https://example.com'), dir)
    const result = await deck.call('browser_read', { window: 'B1' })
    expect(result.ok).toBe(false)
  })

  it('closes a window by name, and hands the driver the id it never printed', async () => {
    attach({ sessionId: 'mine', browserTabId: 'browser:1:1', viewId: 'view-1' })
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_close', { sessionId: 'mine', window: 'B1' })

    expect(result.ok).toBe(true)
    expect(drive.calls).toContainEqual([
      'close',
      { key: 'bound:browser:1:1', viewId: 'view-1', browserTabId: 'browser:1:1', name: 'B1' },
    ])
    // The summary a person reads names the window and not the id under it.
    const written = readFileSync(join(dir, 'actions.jsonl'), 'utf8')
    expect(written).toContain('Close B1')
    expect(written).not.toContain('browser:1:1')
  })

  it('refuses every one of them for a paired device, target or no target', async () => {
    attach({ sessionId: 'mine', browserTabId: 'browser:1:1', viewId: 'view-1' })
    const deck = control(fakeDrive('https://example.com'), dir)
    const phone: Caller = { kind: 'remote', deviceId: 'phone', tiers: { read: true, act: true, alter: false } }

    for (const wire of ['browser_read', 'browser_screenshot', 'browser_close']) {
      const result = await deck.call(wire, { sessionId: 'mine', window: 'B1' }, { caller: phone })
      expect(result.ok).toBe(false)
      // Refused for being remote, not for the target: a window it may not reach
      // and a window that does not exist must not be told apart from a phone.
      expect(result.error).toContain('person at this machine')
    }
  })
})

/**
 * The call that reported success at doing nothing.
 *
 * Reproduced on 2026-08-20 against the running app: `browser_step` takes
 * `value`, the call passed `text`, and nothing rejected the argument it did not
 * know. `browser-driver.ts` typed `input.value ?? ''` — which clears the field,
 * on purpose — and the tool answered `ok`. The agent had every reason to
 * believe it had typed and to carry on: click search, read the results, explain
 * why the results were odd.
 *
 * Two rules close it, and they close it separately because either one alone
 * leaves a way through: the schema is enforced at the dispatcher for *every*
 * tool, and a `type` with no `value` is a refusal rather than a clear.
 */
describe('a step with nothing to type', () => {
  it('refuses the argument the tool does not take, and names the one it does', async () => {
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_step', { verb: 'type', selector: '#q', text: 'hello' })

    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('text')
    expect(result.error).toContain('value')
    // Nothing reached the page. A refusal that arrives after the act is not a
    // refusal, and this one is the whole point.
    expect(drive.calls).toEqual([])
  })

  it('refuses a type with no value at all', async () => {
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_step', { verb: 'type', selector: '#q' })

    expect(result.ok).toBe(false)
    expect(result.error).toContain('value')
    expect(drive.calls).toEqual([])
  })

  it('still lets an empty string through, because clearing a field is a real thing to want', async () => {
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_step', { verb: 'type', selector: '#q', value: '' })

    expect(result.ok).toBe(true)
    expect(drive.calls).toHaveLength(1)
  })

  it('refuses a select with nothing to choose', async () => {
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    expect((await deck.call('browser_step', { verb: 'select', selector: '#s' })).ok).toBe(false)
    expect((await deck.call('browser_step', { verb: 'select', selector: '#s', value: '' })).ok).toBe(
      false,
    )
    expect(drive.calls).toEqual([])
  })

  it('refuses a verb that is not one of the six', async () => {
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_step', { verb: 'hover', selector: '#q' })

    expect(result.ok).toBe(false)
    expect(result.error).toContain('click')
    expect(drive.calls).toEqual([])
  })

  it('refuses a window named without the session it belongs to', async () => {
    // Not a schema rule — both fields are declared — so this is the precheck
    // still running behind the schema check rather than being replaced by it.
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_read', { window: 'B1' })

    expect(result.ok).toBe(false)
    expect(result.error).toContain('sessionId')
  })
})

/**
 * `isolate`, which used to be accepted and ignored.
 *
 * The schema says *"Open in a throwaway session with none of the person's
 * cookies"*, and a partition is fixed when a view is constructed. So on a page
 * that already exists there was nothing the flag could do, and it did nothing —
 * `browser.open { isolate: true }` on the copilot's existing tab came back
 * `settled: true` in the ordinary session, sharing every cookie. Measured in the
 * running app on 2026-08-20.
 *
 * The driver's half is that the page is rebuilt when the isolation asked for is
 * not the isolation it has. This half is the two callers that could never have
 * acted on it at all.
 */
describe('isolation, asked for where it cannot apply', () => {
  it('is refused on a session’s window rather than accepted and ignored', async () => {
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)
    attach({ sessionId: 's1', machineId: '', browserTabId: 'browser:1' })

    const result = await deck.call('browser_open', {
      url: 'https://x.test',
      sessionId: 's1',
      window: 'B1',
      isolate: true,
    })

    expect(result.ok).toBe(false)
    expect(result.error).toContain('isolate')
    expect(drive.calls).toEqual([])
  })

  it('is refused on a new window for a session', async () => {
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_open', {
      url: 'https://x.test',
      sessionId: 's1',
      newWindow: true,
      isolate: true,
    })

    expect(result.ok).toBe(false)
    expect(result.error).toContain('isolate')
  })

  it('is still allowed on the copilot’s own tab, which is the one that can be built', async () => {
    const drive = fakeDrive('https://example.com')
    const deck = control(drive, dir)

    const result = await deck.call('browser_open', { url: 'https://x.test', isolate: true })

    expect(result.ok).toBe(true)
    expect(drive.calls).toEqual([['open', { url: 'https://x.test', isolate: true }]])
  })
})

describe('a session driving its own windows', () => {
  /**
   * The caller a session's own token resolves to.
   *
   * `machineId` is deliberately non-empty on the second one: the binding is keyed
   * `<machineId>\0<sessionId>` and half the point of this round is that a session
   * on his PC and a session on this Mac with the same id are different sessions.
   */
  const here: Caller = { kind: 'session', sessionId: 's1', machineId: '', tiers: ALL }
  const there: Caller = { kind: 'session', sessionId: 's1', machineId: 'pc-1', tiers: ALL }

  /** A drive that can also mint a window for a session, which the plain fake cannot. */
  function driveWithOpen(): BrowserDrive & { calls: unknown[]; opened: unknown[] } {
    const drive = fakeDrive('http://localhost:3000') as BrowserDrive & {
      calls: unknown[]
      opened: unknown[]
    }
    const opened: unknown[] = []
    ;(drive as unknown as Record<string, unknown>).openForSession = async (input: unknown) => {
      opened.push(input)
      // The real route attaches the window it minted before it answers, which is
      // what `settledWindow` is waiting for. A fake that did not would make this
      // test spend the full four-second settle window proving nothing.
      const asked = input as { sessionId: string; machineId?: string }
      attach({
        sessionId: asked.sessionId,
        machineId: asked.machineId ?? '',
        browserTabId: 'browser:new',
        viewId: 'view-new',
      })
      return { line: 'Opened in B1 — Terminal Deck.', attached: true }
    }
    ;(drive as unknown as Record<string, unknown>).opened = opened
    return drive
  }

  it('reads its own window without naming a session at all', async () => {
    // The window is attached the way the app attaches one — by the person, or by
    // the route a session's own `open <url>` takes — and that attaching is the
    // whole of the permission: *"if we connect any browser, they should be able
    // to drive it."*
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'view-1' })
    const deck = control(fakeDrive('http://localhost:3000'), dir)

    const result = await deck.call('browser_read', {}, { caller: here })

    expect(result.ok).toBe(true)
    // The row says which window it read, because a session caller has no
    // unnamed tab and the log has to name the page a person could look at.
    expect(result.row.detail).toContain('Read B1')
  })

  it('finds the window of a session on another machine under that machine’s key', async () => {
    attach({ sessionId: 's1', machineId: 'pc-1', browserTabId: 'browser:9', viewId: 'view-9' })
    const deck = control(fakeDrive('http://localhost:3000'), dir)

    expect((await deck.call('browser_read', {}, { caller: there })).ok).toBe(true)
    // And the same id on *this* machine is a different session with no windows,
    // which is the property the machine half of the key exists for.
    const local = await deck.call('browser_read', {}, { caller: here })
    expect(local.ok).toBe(false)
    expect(local.error).toContain('no browser window is attached')
  })

  it('cannot name another session’s window, and cannot tell that one exists', async () => {
    attach({ sessionId: 'other', browserTabId: 'browser:2', viewId: 'view-2' })
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'view-1' })
    const deck = control(fakeDrive('http://localhost:3000'), dir)

    const named = await deck.call('browser_read', { sessionId: 'other', window: 'B1' }, { caller: here })
    const invented = await deck.call('browser_read', { sessionId: 'nobody', window: 'B1' }, { caller: here })

    expect(named.ok).toBe(false)
    expect(invented.ok).toBe(false)
    // The same sentence for both, so "that session exists" is not learnable by
    // trying — the argument `windowNamed` already makes for the copilot.
    expect(named.error).toBe(invented.error)
  })

  it('has no window at all until one is attached, and says how to get one', async () => {
    const deck = control(fakeDrive('http://localhost:3000'), dir)
    const result = await deck.call('browser_read', {}, { caller: here })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('browser.open')
  })

  it('opens through the route its own `open <url>` takes, carrying its machine', async () => {
    const drive = driveWithOpen()
    const deck = control(drive, dir)

    const result = await deck.call('browser_open', { url: 'http://localhost:3000/' }, { caller: there })

    expect(result.ok).toBe(true)
    // Its own session and its own machine, neither of them supplied by the model
    // — the token is what says who it is. `machineId: ''` here would file the
    // window under a key this session could never name again.
    expect(drive.opened).toEqual([
      { url: 'http://localhost:3000/', sessionId: 's1', machineId: 'pc-1' },
    ])
    // And nothing was opened on the copilot's own pane.
    expect(drive.calls).toEqual([])
  })

  it('may not ask for an isolated tab, because it has no tab of its own', async () => {
    const drive = driveWithOpen()
    const deck = control(drive, dir)
    const result = await deck.call(
      'browser_open',
      { url: 'https://x.test', isolate: true },
      { caller: here },
    )
    expect(result.ok).toBe(false)
    expect(result.error).toContain('isolate')
    expect(drive.opened).toEqual([])
  })

  it('does not loosen the refusal for a paired device', async () => {
    // T28's other side, from T29's direction: opening the browser verbs to
    // sessions must not open them to a phone. The wording is the one
    // `browser-tools.ts` has always used, target or no target.
    const deck = control(fakeDrive('https://example.com'), dir)
    const device: Caller = { kind: 'remote', deviceId: 'phone-1', tiers: ALL }
    const result = await deck.call('browser_read', {}, { caller: device })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
    expect(result.error).toContain('paired device')
  })

  it('refuses a token whose session has not been bound yet', async () => {
    /*
     * The gap between a token being registered and the pty existing.
     * `session-tools.ts` answers a caller with no session and no tiers there,
     * and this is what that caller gets: refused, rather than resolved against
     * an empty session id.
     */
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'view-1' })
    const deck = control(fakeDrive('http://localhost:3000'), dir)
    const unbound: Caller = { kind: 'session', tiers: NO_TIERS }
    const result = await deck.call('browser_read', {}, { caller: unbound })
    expect(result.ok).toBe(false)
  })
})
