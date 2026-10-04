import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { asCheck, asMark, asReadiness, asStatus, resolveStaysFixedBridge, type StaysFixedStatus } from './bridge'
import { agentNames, elapsed, headline, listWords, markedSinceLastCheck, startedBy, statusTone, subline } from './model'
import { StaysFixedPage } from './StaysFixedPage'

/**
 * The page's words and its tolerance of what crosses the bridge.
 *
 * The page itself is looked at in the harness (`?sf=…`, light and dark) and in
 * a scratch app — see `WIRING-staysfixed.md`. What is pinned here is what a
 * screenshot cannot hold still: every sentence the head can say, and that a
 * main process older or newer than the page cannot blank it.
 */

const NOW = Date.parse('2026-10-04T12:00:00Z')

function status(extra: Partial<StaysFixedStatus> = {}): StaysFixedStatus {
  return {
    ...asStatus({ available: true, setUp: true, agents: true }, '/work/shop'),
    ...extra,
  }
}

const differences = {
  runId: 'r',
  at: '2026-10-04T11:55:00Z',
  durationMs: 3000,
  verdict: 'differences' as const,
  headline: '1 difference nobody asked for.',
  against: '1.0.0',
  checked: '1.0.0',
  differences: [],
  unchanged: '',
  notChecked: null,
  unsteady: 0,
  detail: '',
  gaps: [],
  pictures: {},
}

describe('reading what crosses the bridge', () => {
  it('fills every missing field with its empty value rather than failing', () => {
    const s = asStatus({}, '/work/shop')
    expect(s).toMatchObject({ projectPath: '/work/shop', available: false, setUp: false, guards: [], last: null, running: null })
  })

  it('reads the check, readiness and mark answers in both their shapes', () => {
    expect(asCheck({ ok: false, message: 'Set it up first.' })).toEqual({ results: null, message: 'Set it up first.' })
    expect(asReadiness({ ok: false, message: 'no' }).readiness).toBeNull()
    expect(asReadiness({ ok: true, readiness: { ready: ['websites'], gaps: [{ name: 'x', fix: 'git init', byPerson: false }] } }).readiness?.gaps[0]?.fix).toBe('git init')
    expect(asMark({ refusedFor: 'differences', summary: 's' }).refusedFor).toBe('differences')
    expect(asMark({ refusedFor: 'something else' }).refusedFor).toBeNull()
  })

  it('calls the preload through its host, and leaves out what it does not have', () => {
    const host = {
      calls: 0,
      staysFixedStatus(this: { calls: number }) {
        this.calls += 1
        return Promise.resolve({})
      },
    }
    const bridge = resolveStaysFixedBridge(host)
    void bridge.staysFixedStatus?.('/x')
    expect(host.calls).toBe(1)
    expect(bridge.staysFixedCheck).toBeUndefined()
  })
})

describe('the head of the page', () => {
  it('says not checked, checking, or the last verdict', () => {
    expect(headline(status())).toBe('Not checked yet.')
    expect(headline(status({ running: { startedAt: 1, step: 'x', steps: 1, by: 'you' } }))).toBe('Checking…')
    expect(headline(status({ last: differences }))).toBe('1 difference nobody asked for.')
  })

  it('stops asking for "mark as good" once the build has been marked', () => {
    const marked = status({
      last: { ...differences, verdict: 'not-compared', headline: 'Nothing to compare against yet. Mark this build as good to start.' },
      reference: { name: '1.0.0', setAt: '2026-10-04T11:56:00Z', forced: false },
    })
    expect(markedSinceLastCheck(marked)).toBe(true)
    expect(headline(marked)).toBe('Ready. Run a check after your next change.')
    expect(statusTone(marked)).toBe('positive')
    const anyway = status({ last: differences, reference: { name: '1.0.0', setAt: '2026-10-04T11:56:00Z', forced: true } })
    expect(headline(anyway)).toBe('Marked as good, with these differences as the new normal.')
  })

  it('says when, and against which good build — or that there is none', () => {
    expect(subline(status({ last: differences }), NOW)).toBe('Checked 5m ago · No build is marked as good yet')
    expect(subline(status({ reference: { name: '1.0.0', setAt: '2026-10-02T12:00:00Z', forced: false } }), NOW)).toBe(
      'Good build: 1.0.0, marked 2d ago',
    )
  })

  it('names who started a check and how long it has run', () => {
    expect(startedBy({ startedAt: 0, step: '', steps: 0, by: 'you' })).toBe('You started this check')
    expect(startedBy({ startedAt: 0, step: '', steps: 0, by: 'Hoot' })).toBe('Hoot started this check')
    expect(elapsed(754_000)).toBe('12:34')
    expect(elapsed(-5)).toBe('0:00')
  })

  it('names every agent the server reaches, never only one', () => {
    expect(agentNames()).toBe('Claude Code, Codex CLI and Gemini CLI')
    expect(listWords(['a'])).toBe('a')
  })
})

describe('the page, rendered', () => {
  it('draws nothing broken before its first answer arrives', () => {
    const html = renderToStaticMarkup(<StaysFixedPage projectPath="/work/shop" bridge={{}} />)
    expect(html).toContain('aria-busy="true"')
  })
})
