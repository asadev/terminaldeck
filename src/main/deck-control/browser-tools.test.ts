import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import { ActionLog } from './action-log'
import { browserTools, isPrivateOrigin } from './browser-tools'
import { buildCatalogue, catalogueCost, MAX_CATALOGUE_TOKENS, MAX_CATALOGUE_TOOLS } from './catalogue'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { NO_TIERS, type Caller, type DeckSurface } from './surface'

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
    act: async (input: unknown) => {
      calls.push(['act', input])
      return { verb: 'type', selector: '#user', label: 'Username', url: 'https://example.com/' }
    },
    screenshot: async () => ({ path: '/tmp/x.png', width: 100, height: 100, masked: 1 }),
    handover: async () => ({ outcome: 'resumed' as const, waitedMs: 10, url: '', title: '' }),
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
      const result = await deck.call(tool, { url: 'https://x.test', selector: '#a', verb: 'click', prompt: 'hi' }, { caller: remote })
      expect(result.ok).toBe(false)
      expect(result.refusal).toBe('not-granted')
    },
  )

  it.each(['browser_open', 'browser_read', 'browser_step', 'browser_screenshot', 'browser_handover'])(
    'refuses %s from a run with nobody at the machine',
    async (tool) => {
      const deck = control(fakeDrive('https://example.com'), dir)
      const result = await deck.call(
        tool,
        { url: 'https://x.test', selector: '#a', verb: 'click', prompt: 'hi' },
        { attended: false },
      )
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
  it('is five tools with wire names the API will accept', () => {
    const tools = browserTools(fakeDrive(null))
    expect(tools.map((tool) => tool.id)).toEqual([
      'browser.open',
      'browser.read',
      'browser.step',
      'browser.screenshot',
      'browser.handover',
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

describe('what these five cost the copilot on every turn', () => {
  it('leaves the assembled catalogue inside its budget', () => {
    /*
     * A tool definition is not free and it is not paid once: its name,
     * description and schema sit in the context of *every* request the copilot
     * makes, including the ones that will never call it. `catalogue.ts`
     * measures the built-ins; this measures what actually reaches the model,
     * which is the built-ins plus everything contributed through `extraTools` —
     * the growth path nobody is watching.
     *
     * If this fails, the instruction on `MAX_CATALOGUE_TOKENS` stands and it is
     * not "raise the number": add a `tools.describe` meta-tool and move the
     * rarely-used definitions behind it.
     */
    const cost = catalogueCost([...buildCatalogue(), ...browserTools(fakeDrive(null))])
    expect(cost.overBudget).toBe(false)
    expect(cost.tools).toBeLessThanOrEqual(MAX_CATALOGUE_TOOLS)
    expect(cost.tokens).toBeLessThanOrEqual(MAX_CATALOGUE_TOKENS)
  })

  it('records what the five actually add, so a rewrite that doubles it is visible', () => {
    // Measured, not asserted at a round number: the point of writing it down is
    // that somebody expanding a description sees the figure move.
    const base = catalogueCost(buildCatalogue())
    const withBrowser = catalogueCost([...buildCatalogue(), ...browserTools(fakeDrive(null))])
    expect(withBrowser.tools - base.tools).toBe(5)
    // 4,151 characters and ~1,187 estimated tokens when this was written.
    expect(withBrowser.chars - base.chars).toBeLessThan(5_500)
  })
})
