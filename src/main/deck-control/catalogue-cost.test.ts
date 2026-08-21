import { describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import { serverTools, type ServerToolsDeps } from '../servers/tools'
import { assetTools } from './asset-tools'
import { browserNetworkTool } from './browser-network-tool'
import { browserTools } from './browser-tools'
import { storeTools } from './store-tools'
import { workerTools } from './worker-tools'
import {
  buildCatalogue,
  catalogueCost,
  MAX_CATALOGUE_TOKENS,
  MAX_CATALOGUE_TOOLS,
  type ToolSpec,
} from './catalogue'
import { advertisedCatalogue, withDescribe } from './describe-tool'
import { SESSION_TOOLS } from './session-tools'
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
 * assembles nine sources, not two:
 *
 *  - `buildCatalogue()` — the built-ins, in `catalogue.ts`;
 *  - `tour.play` and `app.where`, contributed in `deck-control/index.ts`;
 *  - the six browser verbs, `browser.network`, the two worker verbs, the four
 *    asset checks, `browser.extract` and the three `servers.*` verbs,
 *    contributed in `main/index.ts`;
 *  - `tools.describe`, appended by `DeckControl` itself over all of the above.
 *
 * A budget measured against a subset is not a budget. `catalogueCost`'s own
 * header says so — *"Measuring only the built-ins would leave the one growth
 * path nobody is watching outside the budget it is meant to be held to"* — and
 * then the only caller measured a subset anyway, one source further along.
 *
 * **It happened again, and this file was the one doing it.** The list here was
 * seven sources and the app assembles nine: `browserWorkerTools()` and
 * `assetTools()` are handed to `registerDeckControlIpc` in `main/index.ts` and
 * were outside every measurement anybody was running. The figure this file
 * reported on 2026-08-21 was 27 tools and 8,261 tokens; the real assembled list
 * was **33 tools and 10,670 tokens**. Both are now here, so the miss is one
 * source rather than a whole feature — and `deck-control/index.ts` is a better
 * place to look than this list when the next lane lands.
 *
 * ## What is measured, now that not everything is advertised
 *
 * `advertisedCatalogue(...)`, not the catalogue. Since `tools.describe` landed
 * these are different lists: fifteen tools carry an {@link ToolSpec.index} and
 * cost one line inside the meta-tool's description instead of a description and
 * a schema. The budget is about what a turn *pays*, so the payload is the thing
 * to measure — and measuring the catalogue behind it would report a bill nobody
 * is charged.
 *
 * The deps below are stand-ins because none of them is read to build a schema:
 * a tool's name, title, description and `inputSchema` are what cross to the
 * model, and those are literals in the factories. Nothing here calls a `run`.
 */

/** The list `main/index.ts` and `deck-control/index.ts` between them assemble. */
function shipped(): ToolSpec[] {
  return withDescribe([
    ...buildCatalogue(),
    tourTool({} as TourStage),
    whereTool({ window: { read: async () => null }, page: () => null }),
    ...browserTools({} as BrowserDrive),
    browserNetworkTool({} as BrowserDrive),
    ...workerTools({} as never),
    ...assetTools({ userData: () => '/tmp', probe: async () => ({}) as never }),
    ...storeTools({ drive: {} as BrowserDrive, installed: () => [] }),
    ...serverTools({} as ServerToolsDeps),
  ])
}

/** What `tools/list` puts on the wire for the copilot, which holds every tool. */
function advertised(): ToolSpec[] {
  return advertisedCatalogue(shipped())
}

describe('the catalogue that ships', () => {
  it('is the nine sources the app assembles, not the seven that were being measured', () => {
    const wire = shipped().map((spec) => spec.wire)
    expect(new Set(wire).size, 'two tools share a wire name').toBe(wire.length)
    // Named rather than counted, so that a tool disappearing from the list is a
    // failure here rather than a quietly smaller number.
    expect(wire).toContain('tour_play')
    expect(wire).toContain('app_where')
    expect(wire).toContain('browser_open')
    expect(wire).toContain('browser_close')
    expect(wire).toContain('browser_network')
    expect(wire).toContain('servers_look')
    expect(wire).toContain('browser_extract')
    // The two sources this file was missing until 2026-08-21.
    expect(wire).toContain('browser_workers')
    expect(wire).toContain('assets_ledger')
    expect(wire).toContain('tools_describe')
  })

  it('costs what it costs, written down so a rewrite that doubles it is visible', () => {
    const cost = catalogueCost(advertised())
    /*
     * Measured 2026-08-21 on the assembled list, after `tools.describe`: **19
     * tools advertised out of 34, 20,454 characters, ~5,844 estimated tokens.**
     * Pinned rather than bounded because the point of writing it down is that
     * somebody expanding a description sees the figure move — a `toBeLessThan`
     * at a round number hides every change under it.
     *
     * Generous slack on the characters and none on the count: prose is edited
     * constantly and a tool is added deliberately.
     *
     * ## What these numbers replaced
     *
     * The line above used to read *"26 tools, 27,982 characters, ~7,995
     * estimated tokens"* with eighteen characters of headroom, and then said
     * that the next tool could not be trimmed into the list. It could not, and
     * four lanes added five tools anyway: the real assembled list on the night
     * was 33 tools and 10,670 tokens, over both ceilings.
     *
     * Neither ceiling was raised. Fifteen tools moved behind `tools.describe`
     * and the standing bill fell from 10,670 to 5,844 — 2,156 tokens of
     * headroom under a cap that was breached by 2,670. `describe-tool.ts` holds
     * which fifteen and the argument for each.
     *
     * ## Read this before adding the next tool
     *
     * There is room for one more advertised tool under the count cap and about
     * 7,500 characters under the token one, and neither is the answer. **Give
     * the new tool an `index` and let it cost one line**, unless a turn will
     * genuinely reach for it before it has reached for anything else — that is
     * the rule, it is written out in `describe-tool.ts`, and it is cheaper than
     * this conversation every time.
     */
    expect(cost.tools).toBe(19)
    expect(cost.chars).toBeGreaterThan(18_000)
    expect(cost.chars).toBeLessThan(23_000)
  })

  it('is inside the token ceiling', () => {
    expect(catalogueCost(advertised()).tokens).toBeLessThanOrEqual(MAX_CATALOGUE_TOKENS)
  })

  it('is inside the tool-count ceiling, which is the one that was breached', () => {
    /*
     * **This was a known breach and is not one any more.**
     *
     * `MAX_CATALOGUE_TOOLS` is 20 and the app shipped 26 at `0.8.1`, then 33
     * once four lanes landed on 2026-08-21. The count cap answers a different
     * question from the token cap and it is the one that bound: past twenty
     * tools the problem is not the bill, it is that a model choosing between
     * thirty-three things chooses worse.
     *
     * The way out was written on `MAX_CATALOGUE_TOKENS` long before it was
     * needed and it was followed rather than argued with: no number was raised,
     * no tool was removed, no description was trimmed. Fifteen tools that a turn
     * only reaches for *after* it has used another one now cost one index line
     * each, and `control.cost()` reports `overBudget: false` for the first time
     * since the ceilings were written.
     */
    const cost = catalogueCost(advertised())
    expect(cost.tools).toBeLessThanOrEqual(MAX_CATALOGUE_TOOLS)
    expect(cost.tokens).toBeLessThanOrEqual(MAX_CATALOGUE_TOKENS)
    expect(cost.overBudget).toBe(false)
  })

  it('costs a session less still, because a session may see less', () => {
    /*
     * The other listing this app serves, and it is measured for the same reason
     * the copilot's is: a session's config file is written on the launch path of
     * every session in the app, so its tool list is a standing cost on somebody
     * else's context window as well.
     *
     * Measured 2026-08-21: **7 tools, ~2,322 estimated tokens** — the six
     * browser verbs and the meta-tool, whose index carries the eight scraping
     * tools a session may also call. It was 14 full schemas before tonight.
     */
    const visible = shipped().filter(
      (spec) => SESSION_TOOLS.has(spec.id) || SESSION_TOOLS.has(spec.wire),
    )
    const cost = catalogueCost(advertisedCatalogue(visible))
    expect(cost.tools).toBe(7)
    expect(cost.tokens).toBeLessThan(3_000)
    expect(cost.overBudget).toBe(false)
  })
})
