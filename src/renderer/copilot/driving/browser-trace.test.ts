import { describe, expect, it } from 'vitest'
import {
  MAX_TRACE_STEPS,
  driveNowOf,
  driveStepOf,
  shortUrl,
  withStep,
  type DriveStep,
} from './browser-trace'

/**
 * The scrape, made showable — and the rules that keep the showing honest.
 *
 * *"Asked to scrape, it goes, shows the page and how it is scraping, then returns
 * with the result."* The panel that does that is `BrowserWatch`; everything it
 * prints comes through this file, and every claim here is a fact the app already
 * recorded because it happened.
 *
 * Three of the assertions below are about **not** showing something, and they are
 * the ones worth having. A trace of a driven browser is the easiest place in this
 * app to invent activity — a spinner, a plausible URL, a step that is really the
 * request rather than the result — and the instruction was explicit: *do not fake
 * it with a screenshot animation pretending to be live.*
 */

const row = (over: Record<string, unknown> = {}): Record<string, unknown> => ({
  id: 'row-1',
  at: '2026-08-18T01:20:00.000Z',
  tool: 'browser.step',
  detail: 'click .next on https://example.com',
  outcome: 'ok',
  result: { verb: 'click', selector: '.next', label: 'Next page', url: 'https://example.com/1' },
  error: null,
  ...over,
})

describe('turning an action-log row into something to show', () => {
  it('keeps only the calls that are about a page', () => {
    /*
     * This subscription sees *every* tool call the copilot makes, and most of
     * them are sessions, git and settings. Null is the ordinary answer, and
     * filtering here rather than in the component means the panel never holds a
     * row it will not draw.
     */
    expect(driveStepOf(row({ tool: 'sessions.stop' }))).toBeNull()
    expect(driveStepOf(row({ tool: 'settings.write' }))).toBeNull()
    expect(driveStepOf(row())?.verb).toBe('step')
    expect(driveStepOf(row({ tool: 'browser.read' }))?.verb).toBe('read')
  })

  it('shows the element it resolved, not the selector it was asked for', () => {
    /*
     * The two are different claims. The selector is what the model wrote; the
     * label is what the driver *found* — the element's own text, read off the
     * page after resolving it. Showing the label is showing that the click landed
     * on the button somebody can see, which is the whole question a person
     * watching this wants answered.
     */
    expect(driveStepOf(row())?.element).toBe('Next page')
  })

  it('falls back to the selector when the element had no words of its own', () => {
    // An icon button, an empty div. The selector is then the only handle there
    // is, and a blank line would be this panel going quiet about a real step.
    const step = driveStepOf(row({ result: { selector: 'button.icon', url: 'https://x.test' } }))
    expect(step?.element).toBe('button.icon')
  })

  it('measures a read in what actually came back', () => {
    const step = driveStepOf(
      row({
        tool: 'browser.read',
        result: { url: 'https://example.com', elements: 18, textChars: 12480 },
      }),
    )
    // Grouped, because a page's text runs to five figures and `12480 characters`
    // is a number somebody has to stop and parse.
    expect(step?.took).toContain('12,480 characters')
    expect(step?.took).toContain('18 elements')
  })

  it('keeps a refused call, with its reason', () => {
    /*
     * "It clicked, and it was refused" is the most useful line this panel can
     * print — it is the answer to "why did the scrape stop". A trace that only
     * showed successes would go quiet exactly when somebody starts watching it.
     */
    const step = driveStepOf(
      row({ outcome: 'refused', error: 'the person has the page right now' }),
    )
    expect(step?.outcome).toBe('refused')
    expect(step?.error).toBe('the person has the page right now')
  })

  it('treats an outcome it has never seen as a failure rather than a success', () => {
    // The row crossed the bridge as `unknown` from an append-only file written by
    // another process. A value this build does not know must not read as "fine".
    expect(driveStepOf(row({ outcome: 'partial' }))?.outcome).toBe('error')
  })

  it('refuses anything that is not a row', () => {
    expect(driveStepOf(null)).toBeNull()
    expect(driveStepOf('browser.read')).toBeNull()
    expect(driveStepOf({})).toBeNull()
    // No id means no React key and no way to dedupe. Better nothing than a row
    // that can be added twice.
    expect(driveStepOf(row({ id: '' }))).toBeNull()
  })

  it('invents no url, no element and no amount when the result carried none', () => {
    const step = driveStepOf(row({ tool: 'browser.handover', result: null }))
    expect(step).toMatchObject({ url: '', element: '', took: '' })
  })
})

describe('the trace itself', () => {
  const step = (id: string): DriveStep => ({
    id,
    at: 0,
    verb: 'step',
    detail: 'click',
    url: '',
    element: '',
    took: '',
    outcome: 'ok',
    error: '',
  })

  it('adds each call once, however many times it is announced', () => {
    // The same rule `addSession` states about `session:created`: a subscription
    // that re-registers must not turn one call into two lines.
    const one = withStep([], step('a'))
    expect(withStep(one, step('a'))).toHaveLength(1)
    expect(withStep(one, step('b'))).toHaveLength(2)
  })

  it('keeps the newest and drops the oldest past its bound', () => {
    // A long scrape is hundreds of calls and this list lives in a panel two
    // hundred pixels wide. The whole history is in `actions.jsonl`, which is
    // where a record belongs.
    let trace: DriveStep[] = []
    for (let index = 0; index < MAX_TRACE_STEPS + 10; index += 1) {
      trace = withStep(trace, step(`s${index}`))
    }
    expect(trace).toHaveLength(MAX_TRACE_STEPS)
    expect(trace[trace.length - 1].id).toBe(`s${MAX_TRACE_STEPS + 9}`)
    expect(trace[0].id).toBe('s10')
  })
})

describe('the live line', () => {
  it('reads the drive’s own state and its present-tense step', () => {
    const now = driveNowOf({ state: 'agent', tabId: 't1', step: 'clicking “Sign in”', url: 'https://x.test' })
    expect(now).toEqual({ state: 'agent', tabId: 't1', step: 'clicking “Sign in”', url: 'https://x.test' })
  })

  it('carries the tab, because that is which errand this is', () => {
    /*
     * The drive has exactly one tab by design — the tools take no `tabId`
     * anywhere and calling open again navigates the same one — so it is the
     * closest thing to an identity a scrape has, and it is what "put this panel
     * away for the page it is on" is keyed on. A new tab is a new errand and
     * gets the panel back, with nothing having to expire.
     */
    expect(driveNowOf({ state: 'agent' })?.tabId).toBe('')
    expect(driveNowOf({ state: 'agent', tabId: 'tab-9' })?.tabId).toBe('tab-9')
  })

  it('refuses a state this build does not know', () => {
    expect(driveNowOf({ state: 'driving' })).toBeNull()
    expect(driveNowOf(null)).toBeNull()
  })
})

describe('the address, shortened for a narrow column', () => {
  it('drops the scheme and the www, and keeps the path', () => {
    expect(shortUrl('https://www.example.com/a/b')).toBe('example.com/a/b')
    expect(shortUrl('https://example.com/')).toBe('example.com')
  })

  it('drops the query string, because that is where a token ends up', () => {
    // This panel is on screen while somebody may be recording it.
    expect(shortUrl('https://example.com/callback?code=SECRET&state=x')).toBe('example.com/callback')
  })

  it('returns something unparseable untouched rather than blanking it', () => {
    // An unparseable string is still the only thing anybody can be told.
    expect(shortUrl('not a url')).toBe('not a url')
    expect(shortUrl('')).toBe('')
  })
})
