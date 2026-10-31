import { describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import { serverTools, type ServerToolsDeps } from '../servers/tools'
import { browserCoverage } from './actions/browser'
import { assetTools } from './asset-tools'
import { dataTools, importTools } from './browser-data-tools'
import { downloadTools } from './browser-download-tools'
import { historyTools, profileTools } from './browser-history-tools'
import { browserNetworkTool } from './browser-network-tool'
import { passwordTools } from './browser-password-tools'
import { scrapingTools } from './browser-scraping-tools'
import { signInTools } from './browser-signin-tools'
import { browserTools } from './browser-tools'
import { windowTools } from './browser-window-tools'
import {
  buildCatalogue,
  catalogueCost,
  estimateTokens,
  MAX_CATALOGUE_TOKENS,
  MAX_CATALOGUE_TOOLS,
  type ToolSpec,
} from './catalogue'
import { communityTools } from './community-tools'
import { advertisedCatalogue, describeIndex, withDescribe } from './describe-tool'
import { extensionTools } from './extension-tools'
import { SESSION_TOOLS } from './session-tools'
import { storeTools } from './store-tools'
import { toolsStoreTools } from './tools-store-tools'
import { tourTool } from './tour-tool'
import type { TourStage } from './tour-stage'
import { whereTool } from './where-tool'
import { workerTools } from './worker-tools'

/**
 * The browser area of the checklist, held to what it claims.
 *
 * `actions.test.ts` proves every channel has an entry. This proves the entries
 * in the browser's area are true: that every tool they name is a tool this app
 * builds, that none of the 0.16.0 browser tools is advertised in full (each is
 * one index line behind `tools.describe`, on `catalogue.ts`'s instruction), that
 * none of them is reachable by an ordinary session, and that adding all of them
 * leaves the catalogue inside both of its ceilings.
 *
 * The deps are stand-ins: nothing here calls a `run`, and a tool's name, title,
 * description and schema are literals in its factory.
 */

/** The tools this lane added, as the app builds them. */
function added(): ToolSpec[] {
  return [
    ...windowTools({} as never),
    ...downloadTools({} as never),
    ...historyTools({} as never),
    ...profileTools({} as never),
    ...passwordTools({} as never),
    ...dataTools({} as never),
    ...importTools({} as never),
    ...signInTools({} as never),
    ...scrapingTools({} as never),
    ...toolsStoreTools({} as never),
    ...communityTools({} as never),
  ]
}

/** Every tool the app assembles, the way `catalogue-cost.test.ts` assembles them, plus the added ones. */
function shipped(): ToolSpec[] {
  return withDescribe([
    ...buildCatalogue(),
    tourTool({} as TourStage),
    whereTool({ window: { read: async () => null }, page: () => null }),
    ...browserTools({} as BrowserDrive),
    browserNetworkTool({} as BrowserDrive),
    ...workerTools({} as never),
    ...assetTools({
      userData: () => '/tmp',
      probe: async () => ({}) as never,
      open: () => {
        throw new Error('this file measures definitions, it does not fetch')
      },
    }),
    ...storeTools({ drive: {} as BrowserDrive, installed: () => [] }),
    ...extensionTools({} as never),
    ...serverTools({} as ServerToolsDeps),
    ...added(),
  ])
}

describe('the browser area of the checklist', () => {
  it('has decided every entry', () => {
    const undecided = Object.entries(browserCoverage).filter(([, entry]) => entry === null)
    expect(undecided).toEqual([])
  })

  it('names only tools this app actually builds', () => {
    const ids = new Set(shipped().map((spec) => spec.id))
    const named = Object.values(browserCoverage).flatMap((entry) =>
      entry === null || !('tool' in entry) ? [] : typeof entry.tool === 'string' ? [entry.tool] : [...entry.tool],
    )
    expect(named.filter((id) => !ids.has(id))).toEqual([])
  })

  it('keeps skips few and gives each a reason that is a sentence', () => {
    const skips = Object.entries(browserCoverage).filter(([, entry]) => entry !== null && 'skip' in entry)
    // Seventeen of a hundred and seventeen, each argued in `actions/browser.ts`.
    expect(skips.length).toBeLessThanOrEqual(17)
    for (const [channel, entry] of skips) {
      const reason = (entry as { skip: string }).skip
      expect(reason.length, channel).toBeGreaterThanOrEqual(40)
      expect(reason.endsWith('.'), channel).toBe(true)
    }
  })

  it('never skips copying a password for a reason other than the secret', () => {
    const copy = browserCoverage['browser-password:copy']
    expect(copy !== null && 'skip' in copy && copy.skip).toContain('secret')
  })
})

describe('the 0.16.0 browser tools', () => {
  it('each costs one index line, never a full schema on every turn', () => {
    for (const spec of added()) expect(spec.index, spec.id).toBeTruthy()
  })

  it('keeps every index line short enough to choose by and cheap enough to carry', () => {
    for (const spec of added()) expect((spec.index ?? '').length, spec.id).toBeLessThanOrEqual(150)
    // The whole set, as it lands in `tools.describe`'s description.
    // Measured 2026-10-03: 1,326 characters, ~379 estimated tokens for twelve tools.
    expect(estimateTokens(describeIndex(added()))).toBeLessThan(420)
  })

  it('leaves the assembled catalogue inside both ceilings', () => {
    const cost = catalogueCost(advertisedCatalogue(shipped()))
    expect(cost.tools).toBeLessThanOrEqual(MAX_CATALOGUE_TOOLS)
    expect(cost.tokens).toBeLessThanOrEqual(MAX_CATALOGUE_TOKENS)
  })

  it('is reachable by no ordinary session', () => {
    for (const spec of added()) {
      expect(SESSION_TOOLS.has(spec.id) || SESSION_TOOLS.has(spec.wire), spec.id).toBe(false)
    }
  })

  it('shares no wire name with anything else the app serves', () => {
    const wires = shipped().map((spec) => spec.wire)
    expect(new Set(wires).size).toBe(wires.length)
    for (const spec of added()) expect(spec.wire).toBe(spec.id.replace(/\./g, '_'))
  })

  it('starts each tool at its gentlest tier and reads an unknown action as alter', () => {
    for (const spec of added()) {
      expect(spec.tier, spec.id).toBe('read')
      expect(spec.escalate?.({ action: 'nonsense' }, {} as never), spec.id).toBe('alter')
    }
  })
})
