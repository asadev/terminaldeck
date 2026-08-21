import { describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import { serverTools, type ServerToolsDeps } from '../servers/tools'
import { browserTools } from './browser-tools'
import { storeTools } from './store-tools'
import {
  buildCatalogue,
  catalogueCost,
  MAX_CATALOGUE_TOKENS,
  MAX_CATALOGUE_TOOLS,
  type ToolSpec,
} from './catalogue'
import { tourTool } from './tour-tool'
import { whereTool } from './where-tool'
import type { TourStage } from './tour-stage'

/**
 * What the copilot's tool list actually costs, measured on the list that ships.
 *
 * ## Why this file exists at all
 *
 * The budget was already being measured — and against the wrong list.
 * `browser-tools.test.ts` measured `buildCatalogue()` plus the browser tools and
 * concluded the count was "now exactly `MAX_CATALOGUE_TOOLS`". The running app
 * assembles five sources, not two:
 *
 *  - `buildCatalogue()` — the built-ins, in `catalogue.ts`;
 *  - `tour.play` and `app.where`, contributed in `deck-control/index.ts`;
 *  - the six browser verbs and the three `servers.*` verbs, contributed in
 *    `main/index.ts`.
 *
 * A budget measured against a subset is not a budget. `catalogueCost`'s own
 * header says so — *"Measuring only the built-ins would leave the one growth
 * path nobody is watching outside the budget it is meant to be held to"* — and
 * then the only caller measured a subset anyway, one source further along.
 *
 * The deps below are stand-ins because none of them is read to build a schema:
 * a tool's name, title, description and `inputSchema` are what cross to the
 * model, and those are literals in the factories. Nothing here calls a `run`.
 */

/** The list `main/index.ts` and `deck-control/index.ts` between them assemble. */
function shipped(): ToolSpec[] {
  return [
    ...buildCatalogue(),
    tourTool({} as TourStage),
    whereTool({ window: { read: async () => null }, page: () => null }),
    ...browserTools({} as BrowserDrive),
    ...storeTools({ drive: {} as BrowserDrive, installed: () => [] }),
    ...serverTools({} as ServerToolsDeps),
  ]
}

describe('the catalogue that ships', () => {
  it('is the five sources the app assembles, not the two that were being measured', () => {
    const wire = shipped().map((spec) => spec.wire)
    expect(new Set(wire).size, 'two tools share a wire name').toBe(wire.length)
    // Named rather than counted, so that a tool disappearing from the list is a
    // failure here rather than a quietly smaller number.
    expect(wire).toContain('tour_play')
    expect(wire).toContain('app_where')
    expect(wire).toContain('browser_open')
    expect(wire).toContain('browser_close')
    expect(wire).toContain('servers_look')
    expect(wire).toContain('browser_extract')
  })

  it('costs what it costs, written down so a rewrite that doubles it is visible', () => {
    const cost = catalogueCost(shipped())
    /*
     * Measured 2026-08-20 on the assembled list: 25 tools, 26,929 characters,
     * ~7,694 estimated tokens. Re-measured 2026-08-21 with `browser.extract`,
     * the tools store's single door: 26. Pinned rather than bounded because the
     * point of writing it down is that somebody expanding a description sees the
     * figure move — a `toBeLessThan` at a round number hides every change under
     * it.
     *
     * The store deliberately costs **one** definition however many tools are
     * installed. A schema per installed tool would have put the growth of this
     * number in a person's hands rather than in a reviewer's, which is the one
     * thing `MAX_CATALOGUE_TOKENS` asks nobody to do — see the head of
     * `store-tools.ts`.
     *
     * Generous slack on the characters and none on the count: prose is edited
     * constantly and a tool is added deliberately.
     */
    expect(cost.tools).toBe(26)
    expect(cost.chars).toBeGreaterThan(24_000)
    expect(cost.chars).toBeLessThan(30_000)
  })

  it('is inside the token ceiling', () => {
    expect(catalogueCost(shipped()).tokens).toBeLessThanOrEqual(MAX_CATALOGUE_TOKENS)
  })

  it('is over the tool-count ceiling, and that is recorded here rather than hidden', () => {
    /*
     * **This is a known breach, not a passing budget.**
     *
     * `MAX_CATALOGUE_TOOLS` is 20 and the app ships 26. The count cap answers a
     * different question from the token cap and it is the one that binds: past
     * twenty tools the problem is not the bill, it is that a model choosing
     * between twenty-five things chooses worse.
     *
     * It was breached before tonight — 24 at `0.8.1`, with `tour_play`,
     * `app_where` and the three `servers.*` verbs outside the only measurement
     * anybody was running — `browser.close` made it 25, and the tools store's
     * one door made it 26. Fixing it means
     * removing or merging tools, which is a decision about the product and not
     * one to take inside a defect fix, so what is done here is to stop the
     * number being invisible: `control.cost()` has always reported
     * `overBudget: true` at runtime, and now a test says the same thing.
     *
     * The instruction on `MAX_CATALOGUE_TOKENS` is the way out and it stands:
     * do not raise the number — add a `tools.describe` meta-tool and move the
     * rarely-used definitions behind it, so the standing cost is a short index
     * and the full schema is fetched by the one turn that needs it.
     */
    const cost = catalogueCost(shipped())
    expect(cost.tools).toBeGreaterThan(MAX_CATALOGUE_TOOLS)
    expect(cost.overBudget).toBe(true)
    // The breach is the count and only the count. If this ever fails, the
    // tokens have gone over too and the paragraph above understates the problem.
    expect(cost.tokens).toBeLessThanOrEqual(MAX_CATALOGUE_TOKENS)
  })
})
