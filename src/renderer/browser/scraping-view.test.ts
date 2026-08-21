import { describe, expect, it } from 'vitest'
import type { BrowserProfile } from './accounts-bridge'
import type { FleetConfig, ScrapingStatus, ToolListing } from './scraping-bridge'
import {
  FULFILL_NOTE,
  NOT_MEASURED,
  bytesLine,
  canInstall,
  countLine,
  coverageVerdict,
  droppedLine,
  enrollable,
  fleetLine,
  installBlockedReason,
  liftBlockedReason,
  liftLine,
  liftRequestLine,
  reachLine,
  resourceLabel,
  ruleChange,
  scopeLabel,
  workerRows,
  workerStateLabel,
} from './scraping-view'

/**
 * The scraping panel's reasoning, run.
 *
 * The panel itself is a `Modal` and cannot be rendered in this project's test
 * run — `createPortal` throws under `renderToStaticMarkup` — so what is worth
 * pinning is here, in the functions that decide what it is allowed to say. Every
 * block below is one way this screen could come to report something nobody
 * measured, which is the failure the whole panel is built against: a tool that
 * skipped 48,473 assets and exited reporting success, and 7% of a dataset
 * shipped as complete.
 */

const profile = (id: string, name: string): BrowserProfile => ({
  id,
  name,
  partition: `persist:${id}`,
  createdAt: 0,
  isDefault: id === 'default',
  avatar: '',
})

describe('a number nobody measured', () => {
  it('says so, and is never a zero', () => {
    expect(countLine(null, 'response', 'responses')).toBe(NOT_MEASURED)
    expect(countLine(null, 'response', 'responses')).not.toContain('0')
  })

  it('prints a real zero as a real zero, because that is a measurement', () => {
    // "0 dropped" is a fact, and it is the one fact this panel cannot fake: it
    // can only come from something that counted.
    expect(countLine(0, 'response', 'responses')).toBe('0 responses')
  })

  it('agrees with itself about one', () => {
    expect(countLine(1, 'response', 'responses')).toBe('1 response')
    expect(countLine(2, 'response', 'responses')).toBe('2 responses')
  })

  it('groups a big one the way this machine does', () => {
    expect(countLine(16498, 'plan', 'plans')).toBe(`${(16498).toLocaleString()} plans`)
  })

  it('makes the same bargain for a size', () => {
    expect(bytesLine(null, () => 'never called')).toBe(NOT_MEASURED)
    expect(bytesLine(2048, (bytes) => `${bytes} B`)).toBe('2048 B')
  })
})

describe('the line beside Fulfill', () => {
  /*
   * Blocking images is what cost him 16,498 floor plans: the requests never
   * went, the page's lazy-loading never fired, and the real image URLs were
   * never written into the document. The difference between Block and Fulfill is
   * invisible from their names, so it is said in a sentence — and this test is
   * what keeps the sentence saying the part that matters.
   */
  it('says what block costs, not just what fulfill does', () => {
    expect(FULFILL_NOTE).toContain('lazy-loading')
    expect(FULFILL_NOTE).toContain('placeholder')
    expect(FULFILL_NOTE.toLowerCase()).toContain('never reveals its real urls')
  })
})

describe('the resource rows', () => {
  it('names each type the way a person would say it', () => {
    expect(resourceLabel('image')).toBe('Images')
    expect(resourceLabel('xhr')).toBe('XHR')
    expect(resourceLabel('fetch')).toBe('Fetch')
    expect(resourceLabel('stylesheet')).toBe('Stylesheets')
    // Not "Medias".
    expect(resourceLabel('media')).toBe('Media')
  })

  it('changes one rule and only that rule', () => {
    expect(ruleChange('image', 'fulfill')).toEqual({ image: 'fulfill' })
    expect(Object.keys(ruleChange('script', 'block'))).toEqual(['script'])
  })
})

describe('the workers list', () => {
  const profiles = [profile('default', 'Default'), profile('w1', 'Work'), profile('w2', 'Research')]
  const fleet = (ids: string[]): FleetConfig => ({ profileIds: ids, concurrency: 2, delayMs: 250 })
  const status = (workers: ScrapingStatus['workers']): ScrapingStatus => ({
    workers,
    capture: null,
    assets: null,
    lastCheck: null,
  })

  it('is empty when nothing is enrolled, so the panel can say "no workers yet"', () => {
    expect(workerRows(null, null, profiles)).toEqual([])
    expect(workerRows(fleet([]), status([]), profiles)).toEqual([])
  })

  it('never invents "idle" for a worker nothing reported', () => {
    // Idle is a claim about a running process. Unreported is what a panel
    // actually knows when a profile is enrolled and the engine said nothing.
    const [row] = workerRows(fleet(['w1']), status([]), profiles)
    expect(row.state).toBe('unreported')
    expect(workerStateLabel(row.state)).toBe('Not reported')
    expect(row.requests).toBeNull()
  })

  it('carries the measured state and count when there is one', () => {
    const [row] = workerRows(
      fleet(['w1']),
      status([{ id: 'k1', profileId: 'w1', state: 'busy', requests: 12, lastAt: 5 }]),
      profiles,
    )
    expect(row.state).toBe('busy')
    expect(row.requests).toBe(12)
    expect(row.name).toBe('Work')
  })

  it('still shows a worker whose profile has been deleted, marked as such', () => {
    const [row] = workerRows(fleet(['gone']), null, profiles)
    expect(row.orphaned).toBe(true)
    expect(row.name).toBe('gone')
  })

  it('still shows a running worker nobody enrolled', () => {
    const rows = workerRows(
      fleet([]),
      status([{ id: 'k9', profileId: 'w2', state: 'idle', requests: null, lastAt: null }]),
      profiles,
    )
    expect(rows).toHaveLength(1)
    expect(rows[0].enrolled).toBe(false)
    expect(rows[0].name).toBe('Research')
  })

  it('keeps the fleet order, so the list does not reshuffle as work starts', () => {
    const rows = workerRows(fleet(['w2', 'w1']), status([]), profiles)
    expect(rows.map((row) => row.profileId)).toEqual(['w2', 'w1'])
  })

  it('will not say how many are busy on a build that reports nothing', () => {
    // "4 workers · 0 busy" while four of them are hammering a site is exactly
    // the number this panel exists to never print.
    const rows = workerRows(fleet(['w1', 'w2']), null, profiles)
    expect(fleetLine(rows, false)).toBe(`2 workers · busy ${NOT_MEASURED}`)
  })

  it('counts the busy ones when something measured them', () => {
    const rows = workerRows(
      fleet(['w1', 'w2']),
      status([{ id: 'k1', profileId: 'w1', state: 'busy', requests: 3, lastAt: 1 }]),
      profiles,
    )
    expect(fleetLine(rows, true)).toBe('2 workers · 1 busy')
  })

  it('offers only profiles that are not workers yet', () => {
    expect(enrollable(fleet(['w1']), profiles).map((p) => p.id)).toEqual(['default', 'w2'])
    expect(enrollable(fleet(['default', 'w1', 'w2']), profiles)).toEqual([])
  })
})

describe('the session lift', () => {
  it('refuses until both ends are named', () => {
    expect(liftBlockedReason('', ['w1'])).toContain('Choose the profile')
    expect(liftBlockedReason('default', [])).toContain('at least one worker')
    expect(liftBlockedReason('default', ['w1'])).toBe('')
  })

  it('refuses a profile lifted into itself', () => {
    expect(liftBlockedReason('default', ['w1', 'default'])).toContain('into itself')
  })

  it('names both ends on the control that does it, never a count', () => {
    // "Copy into 4 workers" is the shape of confirmation somebody presses
    // without reading. This one cannot be pressed without reading which account
    // is being handed to which profiles.
    expect(liftLine('Default', ['Work'])).toBe(
      'Copy the signed-in session from Default into Work.',
    )
    expect(liftLine('Default', ['Work', 'Research'])).toContain('Work and Research')
    expect(liftLine('Default', ['A', 'B', 'C'])).toContain('A, B and C')
    expect(liftLine('Default', ['A', 'B', 'C'])).not.toMatch(/\b3\b/)
  })

  it('reads an ask as an ask, with whoever asked named first', () => {
    const line = liftRequestLine('session 4', 'Default', ['Work'])
    expect(line.startsWith('session 4 asked to copy')).toBe(true)
  })

  it('does not guess what asked when the request did not say', () => {
    expect(liftRequestLine('  ', 'Default', ['Work']).startsWith('Something asked to')).toBe(true)
  })
})

describe('the coverage check', () => {
  it('has no verdict at all before one has run', () => {
    expect(coverageVerdict(null)).toEqual({ tone: 'unknown', line: 'No check has run.' })
  })

  it('refuses to call a run complete when the page stated no total', () => {
    // This is the whole failure: 7% of a dataset shipped as complete because
    // nothing ever compared it to a number the page itself printed.
    const verdict = coverageVerdict({ url: 'https://x/', stated: null, got: 1200, at: 1 })
    expect(verdict.tone).toBe('unknown')
    expect(verdict.tone).not.toBe('complete')
  })

  it('refuses to call it complete when nothing counted what was taken', () => {
    const verdict = coverageVerdict({ url: 'https://x/', stated: 16498, got: null, at: 1 })
    expect(verdict.tone).toBe('unknown')
    expect(verdict.line).toContain('nothing counted')
  })

  it('says the percentage when a run came up short', () => {
    const verdict = coverageVerdict({ url: 'https://x/', stated: 16498, got: 1155, at: 1 })
    expect(verdict.tone).toBe('short')
    expect(verdict.line).toContain('7%')
  })

  it('reads as complete only when both numbers exist and one covers the other', () => {
    expect(coverageVerdict({ url: 'https://x/', stated: 24, got: 24, at: 1 }).tone).toBe('complete')
    expect(coverageVerdict({ url: 'https://x/', stated: 24, got: 25, at: 1 }).tone).toBe('complete')
  })
})

describe('what capture dropped', () => {
  it('says it is unmeasured rather than saying nothing was dropped', () => {
    expect(droppedLine(null)).toContain(NOT_MEASURED)
    expect(
      droppedLine({ recorded: 10, bytes: 10, dropped: null, droppedReason: '' }),
    ).toContain(NOT_MEASURED)
  })

  it('says nothing was dropped only when something counted zero', () => {
    expect(droppedLine({ recorded: 10, bytes: 10, dropped: 0, droppedReason: '' })).toBe(
      'Nothing dropped.',
    )
  })

  it('says which bound did it when the engine said', () => {
    const line = droppedLine({ recorded: 10, bytes: 10, dropped: 902, droppedReason: 'the 200 MB bound' })
    expect(line).toContain('902 responses dropped')
    expect(line).toContain('200 MB bound')
  })
})

describe('the tools store', () => {
  const tool = (patch: Partial<ToolListing>): ToolListing => ({
    id: 't1',
    name: 'Tool',
    version: '1.0.0',
    publisher: 'Someone',
    reach: [],
    installed: false,
    identity: 'verified',
    digest: 'abc',
    ...patch,
  })

  it('installs only what the store could prove', () => {
    expect(canInstall(tool({ identity: 'verified' }))).toBe(true)
    for (const identity of ['unverified', 'mismatch', 'unknown'] as const) {
      expect(canInstall(tool({ identity }))).toBe(false)
      expect(installBlockedReason(tool({ identity }))).not.toBe('')
    }
  })

  it('does not offer to install what is already installed', () => {
    expect(canInstall(tool({ installed: true }))).toBe(false)
    // And says nothing about it: an installed tool has a Remove, not a refusal.
    expect(installBlockedReason(tool({ installed: true }))).toBe('')
  })

  it('tells a missing signature apart from one it could not evaluate', () => {
    expect(installBlockedReason(tool({ identity: 'unverified' }))).toContain('not signed')
    expect(installBlockedReason(tool({ identity: 'unknown' }))).toContain('could not check')
    expect(installBlockedReason(tool({ identity: 'mismatch' }))).toContain('not what this listing signed')
  })

  it('shows what a tool reaches, and says when it declares nothing', () => {
    expect(reachLine(tool({ reach: ['the pages you open', 'the downloads folder'] }))).toBe(
      'the pages you open · the downloads folder',
    )
    expect(reachLine(tool({ reach: [] }))).toContain('does not declare')
  })
})

describe('whose setting is this', () => {
  it('names the profile for a per-profile section, and the browser for the rest', () => {
    expect(scopeLabel('profile', 'Work')).toBe('Work')
    expect(scopeLabel('browser', 'Work')).toBe('This browser')
  })

  it('falls back to a phrase rather than an empty label before profiles load', () => {
    expect(scopeLabel('profile', '')).toBe('This profile')
  })
})
