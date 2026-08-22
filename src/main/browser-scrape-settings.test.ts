import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { applyRule, readRenditionRules } from './browser-asset-rendition'
import {
  MAX_PACE_MS as POOL_MAX_PACE_MS,
  MAX_WORKERS as POOL_MAX_WORKERS,
  cleanPace,
} from './browser-worker-pool'
import {
  MAX_KEEP_MB as SHARED_MAX_KEEP_MB,
  MAX_PACE_MS as SHARED_MAX_PACE_MS,
  MAX_WORKERS as SHARED_MAX_WORKERS,
} from '../shared/scrape-limits'
import {
  MAX_KEEP_MB,
  captureBoundsOf,
  captureFolderFor,
  coveragePatternOf,
  emptyScrapeSettings,
  fetchRulesOf,
  ledgerModeOf,
  mergeScrapeSettings,
  onScrapeSettingsChanged,
  readScrapeSettings,
  renditionRulesOf,
  resetScrapeSettingsForTests,
  scrapeSettingsFor,
  resolveArming,
  scrapeSettingsPath,
  setScrapeSettings,
} from './browser-scrape-settings'

/**
 * The store the four scraping engines had nowhere to read from.
 *
 * Every assertion here is about one of two rules. **Unset is not a default**:
 * the panel draws "not set" and offers the control, and a store that answered
 * `false` the first time it was read would be this app inventing a decision and
 * showing it back as his. And **a stored value that could not be honoured must
 * come back changed**, so the reply the panel redraws from is what is actually
 * in force.
 */

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-scrape-settings-'))
  resetScrapeSettingsForTests()
})

afterEach(() => {
  resetScrapeSettingsForTests()
  rmSync(dir, { recursive: true, force: true })
})

describe('what a profile that has never been configured says', () => {
  it('says nobody said, in every group, and never says no', () => {
    const settings = scrapeSettingsFor(dir, 'work')
    expect(settings).toEqual(emptyScrapeSettings())
    expect(settings.capture.on).toBeNull()
    expect(settings.capture.keepMB).toBeNull()
    expect(settings.assets.upgrade.on).toBeNull()
    expect(settings.assets.ledger.on).toBeNull()
    expect(settings.checks.coverage.on).toBeNull()
    expect(settings.checks.screenshotOnBlock).toBeNull()
    // No rule per kind either: an absent kind is unset, not `allow`.
    expect(settings.requests).toEqual({})
    expect(fetchRulesOf(settings)).toBeNull()
    expect(captureBoundsOf(settings)).toBeNull()
    expect(ledgerModeOf(settings)).toBeNull()
  })

  it('answers for a profile with no id without touching the disk', () => {
    expect(scrapeSettingsFor(dir, undefined)).toEqual(emptyScrapeSettings())
    expect(setScrapeSettings(dir, '', { capture: { on: true } })).toEqual(emptyScrapeSettings())
  })
})

describe('storing a patch', () => {
  it('merges group by group and answers with the whole of it', () => {
    setScrapeSettings(dir, 'work', { requests: { image: 'fulfill' } })
    const after = setScrapeSettings(dir, 'work', { capture: { on: true } })
    // The rule set a moment ago is still there: a patch that replaced the
    // object would silently undo whatever the panel had not reloaded.
    expect(after.requests).toEqual({ image: 'fulfill' })
    expect(after.capture.on).toBe(true)
    expect(after.capture.keepMB).toBeNull()
  })

  it('takes the word the engine was renamed from, and stores the new one', () => {
    const after = setScrapeSettings(dir, 'work', { requests: { image: 'cheap' } })
    expect(after.requests.image).toBe('fulfill')
  })

  it('clamps a budget the capture store would refuse, and shows the clamp', () => {
    const after = setScrapeSettings(dir, 'work', { capture: { keepMB: 1_000_000 } })
    expect(after.capture.keepMB).toBe(MAX_KEEP_MB)
    expect(captureBoundsOf(after)?.maxTotalBytes).toBe(MAX_KEEP_MB * 1024 * 1024)
  })

  it('refuses a coverage pattern that will not compile, rather than storing it', () => {
    const after = setScrapeSettings(dir, 'work', { checks: { coverage: { on: true, pattern: '(' } } })
    // Empty, so the panel shows him his typo instead of a run that quietly
    // stops checking itself the first time the expression is used.
    expect(after.checks.coverage.pattern).toBe('')
    expect(coveragePatternOf(after)).toBe('')
  })

  it('keeps one profile out of another', () => {
    setScrapeSettings(dir, 'work', { capture: { on: true } })
    expect(scrapeSettingsFor(dir, 'personal').capture.on).toBeNull()
  })

  it('survives a relaunch', () => {
    setScrapeSettings(dir, 'work', { assets: { upgrade: { on: true, from: 'w=400', to: 'w=1920' } } })
    resetScrapeSettingsForTests()
    expect(scrapeSettingsFor(dir, 'work').assets.upgrade).toEqual({
      on: true,
      from: 'w=400',
      to: 'w=1920',
    })
  })

  it('reads an unreadable file as an empty store rather than refusing to open', () => {
    writeFileSync(scrapeSettingsPath(dir), '{ this is not json')
    resetScrapeSettingsForTests()
    expect(scrapeSettingsFor(dir, 'work')).toEqual(emptyScrapeSettings())
  })

  it('writes a file a person can read', () => {
    setScrapeSettings(dir, 'work', { checks: { screenshotOnBlock: false } })
    const raw = JSON.parse(readFileSync(scrapeSettingsPath(dir), 'utf8')) as {
      version: number
      profiles: Record<string, { checks: { screenshotOnBlock: boolean } }>
    }
    expect(raw.version).toBe(1)
    expect(raw.profiles.work.checks.screenshotOnBlock).toBe(false)
  })
})

describe('the one from→to pair, as the engine wants it', () => {
  it('is one rule, and both halves are literal', () => {
    const settings = mergeScrapeSettings(emptyScrapeSettings(), {
      assets: { upgrade: { on: true, from: '?w=400', to: '?w=1920' } },
    })
    const rules = renditionRulesOf(settings)
    expect(rules).toHaveLength(1)
    // It compiles under the engine's own reader, which is the only thing that
    // makes this pair reachable from the panel at all.
    expect(readRenditionRules(rules)).toHaveLength(1)
    // `?` is a question mark here, not a quantifier: the whole point of
    // escaping is that a person types the URL fragment they can see.
    expect(applyRule('https://x.test/a.jpg?w=400', rules[0])).toBe('https://x.test/a.jpg?w=1920')
  })

  it('does not read a $ in the replacement as a back-reference', () => {
    const settings = mergeScrapeSettings(emptyScrapeSettings(), {
      assets: { upgrade: { on: true, from: 'small', to: 'big$1' } },
    })
    expect(applyRule('https://x.test/small.jpg', renditionRulesOf(settings)[0])).toBe(
      'https://x.test/big$1.jpg',
    )
  })

  it('is nothing at all while the switch is off, or while there is nothing to match', () => {
    const off = mergeScrapeSettings(emptyScrapeSettings(), {
      assets: { upgrade: { on: false, from: 'small', to: 'big' } },
    })
    expect(renditionRulesOf(off)).toEqual([])
    const blank = mergeScrapeSettings(emptyScrapeSettings(), {
      assets: { upgrade: { on: true, from: '', to: 'big' } },
    })
    expect(renditionRulesOf(blank)).toEqual([])
  })
})

describe('the ledger, which is two questions', () => {
  it('says nothing until somebody answers one of them', () => {
    expect(ledgerModeOf(emptyScrapeSettings())).toBeNull()
  })

  it('reads the switch and the refetch flag as the engine’s two modes', () => {
    const on = mergeScrapeSettings(emptyScrapeSettings(), { assets: { ledger: { on: true } } })
    expect(ledgerModeOf(on)).toBe('resume')
    const again = mergeScrapeSettings(on, { assets: { ledger: { refetch: true } } })
    expect(ledgerModeOf(again)).toBe('refetch')
    // Off means "do not skip", and the file is still written — which is what
    // makes changing your mind cheap. See the note on `ledgerModeOf`.
    const off = mergeScrapeSettings(on, { assets: { ledger: { on: false } } })
    expect(ledgerModeOf(off)).toBe('refetch')
  })
})

describe('reading a file somebody else wrote', () => {
  it('drops what it cannot read rather than guessing at it', () => {
    const settings = readScrapeSettings({
      requests: { image: 'nonsense', notakind: 'block', script: 'block' },
      capture: { on: 'yes', keepMB: -4 },
      assets: { upgrade: { on: true, from: 5 } },
      checks: { coverage: { pattern: 42 } },
    })
    expect(settings.requests).toEqual({ script: 'block' })
    expect(settings.capture.on).toBeNull()
    expect(settings.capture.keepMB).toBe(1)
    expect(settings.assets.upgrade.from).toBe('')
    expect(settings.checks.coverage.pattern).toBe('')
  })
})

describe('the capture folder', () => {
  it('is the parent of every run this profile writes, and cannot be escaped', () => {
    expect(captureFolderFor('/data', 'work')).toBe(join('/data', 'browser-captures', 'work'))
    expect(captureFolderFor('/data', '../../etc')).toBe(join('/data', 'browser-captures', 'etc'))
    // A tab with no profile files under one name rather than at the root.
    expect(captureFolderFor('/data', '')).toBe(join('/data', 'browser-captures', 'isolated'))
  })
})

describe('what a browser.network call actually arms', () => {
  const bounds = { maxBodyBytes: 1, maxTotalBytes: 2, maxEntries: 3 }
  const stored = {
    rules: { image: 'fulfill' } as const,
    capture: false,
    bounds: { maxBodyBytes: 9, maxTotalBytes: 9, maxEntries: 9 },
    blockShots: false,
  }

  it('fills a silence with the profile’s answer', () => {
    expect(resolveArming({ rules: {}, capture: true, bounds }, stored)).toEqual({
      rules: { image: 'fulfill' },
      capture: false,
      bounds: stored.bounds,
    })
  })

  it('never overrules an argument the caller named', () => {
    expect(
      resolveArming(
        {
          rules: { script: 'block' },
          capture: true,
          bounds,
          named: { rules: true, capture: true, bounds: true },
        },
        stored,
      ),
    ).toEqual({ rules: { script: 'block' }, capture: true, bounds })
  })

  it('lets a caller ask for a page that behaves normally', () => {
    // An explicit empty rule set is a decision, not a silence. If a stored rule
    // beat it there would be no way to ask this browser to leave a page alone.
    const armed = resolveArming({ rules: {}, capture: true, bounds, named: { rules: true } }, stored)
    expect(armed.rules).toEqual({})
  })

  it('is exactly the call on a build or a profile that stored nothing', () => {
    expect(resolveArming({ rules: { font: 'block' }, capture: true, bounds }, null)).toEqual({
      rules: { font: 'block' },
      capture: true,
      bounds,
    })
    expect(
      resolveArming(
        { rules: { font: 'block' }, capture: true, bounds },
        { rules: null, capture: null, bounds: null, blockShots: null },
      ),
    ).toEqual({ rules: { font: 'block' }, capture: true, bounds })
  })
})

/**
 * The three numbers a person can type, and the ceilings behind them.
 *
 * The panel's fields are in the renderer, which cannot import this file, so
 * they read their maxima from `shared/scrape-limits.ts`. That is a copy of what
 * is enforced here and in the pool, and a copy is a second answer to one
 * question — so these assert the two answers agree. Before they did, "Keep at
 * most" accepted 1,000,000 MB against a store that keeps 4,096, "Between
 * requests" accepted ten minutes against a pool that keeps thirty seconds, and
 * "At once" accepted 64 workers against a pool of 16. Each was a field that
 * took a number it could not keep and only looked corrected because the engine
 * answers with what it stored.
 */
describe('the ceilings the panel draws are the ceilings this store enforces', () => {
  it('offers the same megabyte cap the capture store will accept', () => {
    expect(SHARED_MAX_KEEP_MB).toBe(MAX_KEEP_MB)
  })

  it('clamps a number above it rather than keeping what was typed', () => {
    const after = setScrapeSettings(dir, 'work', { capture: { keepMB: SHARED_MAX_KEEP_MB + 1 } })
    expect(after.capture.keepMB).toBe(MAX_KEEP_MB)
  })

  it('offers the same fleet and pace ceilings the pool enforces', () => {
    // Re-exported by the pool rather than copied into it, so these are the same
    // binding; the assertion is that the re-export has not been unpicked.
    expect(SHARED_MAX_WORKERS).toBe(POOL_MAX_WORKERS)
    expect(SHARED_MAX_PACE_MS).toBe(POOL_MAX_PACE_MS)
    expect(cleanPace({ maxConcurrent: 64, minDelayMs: 600_000, jitterMs: 0 })).toEqual({
      maxConcurrent: SHARED_MAX_WORKERS,
      minDelayMs: SHARED_MAX_PACE_MS,
      jitterMs: 0,
    })
  })
})

/**
 * The change event that makes a toggle a live control.
 *
 * `browser-profile-arm.ts` re-arms open pages off this announcement — events,
 * not polling — so a write that stored without announcing would be the old
 * defect back in a quieter form: the file changes and the page does not.
 */
describe('announcing a stored write', () => {
  it('tells the listener which profile changed and what now stands', () => {
    const heard: { profileId: string; capture: boolean | null }[] = []
    onScrapeSettingsChanged((profileId, settings) => {
      heard.push({ profileId, capture: settings.capture.on })
    })
    setScrapeSettings(dir, 'work', { capture: { on: true } })
    expect(heard).toEqual([{ profileId: 'work', capture: true }])
  })

  it('does not let a throwing listener take the panel reply down', () => {
    onScrapeSettingsChanged(() => {
      throw new Error('a listener with a bug')
    })
    const after = setScrapeSettings(dir, 'work', { capture: { on: true } })
    expect(after.capture.on).toBe(true)
  })

  it('says nothing for a write that was refused for want of a profile', () => {
    let called = 0
    onScrapeSettingsChanged(() => {
      called += 1
    })
    setScrapeSettings(dir, '', { capture: { on: true } })
    expect(called).toBe(0)
  })
})
