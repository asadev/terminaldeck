import { describe, expect, it } from 'vitest'
import { assembledCatalogue, assembledControl } from './assembled-catalogue.fixture'
import { catalogueCost, MAX_CATALOGUE_TOKENS, MAX_CATALOGUE_TOOLS, type ToolSpec } from './catalogue'
import { advertisedCatalogue, INLINE_INDEX_MAX, TOOL_AREAS } from './describe-tool'
import { RUN_WIRE } from './run-tool'
import { SESSION_TOOLS } from './session-tools'

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
 *
 * ## It happened a third time, and the list moved out of this file (0.16.0)
 *
 * Four areas landed in one release — sessions, machines, agents, the rest of the
 * browser — and a hundred and twenty tools with them, every one an index line.
 * This file still assembled the nine sources above, so it reported ~5,900
 * tokens and passed while the real listing was **~9,250**, over the ceiling;
 * the index lines alone were ~3,850. The miss was not one source this time but
 * four, and the reason was the same as both times before: a list typed out
 * here is a list that drifts from the app.
 *
 * So the list is not here any more. `assembled-catalogue.fixture.ts` builds it
 * with `DeckControl`'s own constructor over every `extraTools` source the app
 * hands in, and the name-clash test reads the same one. What this file measures
 * is `control.cost()` — the figure the status channel shows — and the
 * access-key caller's listing beside it.
 *
 * And the ceilings did not move. The index went **by area** instead
 * (`describe-tool.ts`): five lines saying what each area covers, and the
 * one-liners fetched by `tools.describe {area}` on the turn that wants them.
 */

/** Every tool the app serves, built the way the app builds it. */
function shipped(): readonly ToolSpec[] {
  return assembledCatalogue()
}

/** What `tools/list` puts on the wire for the copilot, which holds every tool. */
function advertised(): ToolSpec[] {
  return advertisedCatalogue(shipped())
}

/** What an AI app on an access key is listed: the same, plus `tools.run`. */
function keyListing(): ToolSpec[] {
  return advertisedCatalogue(shipped(), { run: true })
}

describe('the catalogue that ships', () => {
  it('is every source the app assembles, not the nine that were being measured', () => {
    const wire = shipped().map((spec) => spec.wire)
    expect(new Set(wire).size, 'two tools share a wire name').toBe(wire.length)
    // Named rather than counted, so that a tool disappearing from the list is a
    // failure here rather than a quietly smaller number — one from each source.
    for (const name of [
      'tour_play',
      'app_where',
      'browser_open',
      'browser_network',
      'browser_workers',
      'assets_ledger',
      'browser_extract',
      'browser_extensions',
      'servers_look',
      'machines_look',
      'agents_list',
      'browser_windows',
      'store_community',
      'sessions_wait',
      'files_read',
      'copilot_state',
      'ui_do',
      'tools_coverage',
      RUN_WIRE,
      'tools_describe',
    ]) {
      expect(wire, name).toContain(name)
    }
    // Well over a hundred: the release that made "everything" reachable.
    expect(shipped().length).toBeGreaterThan(140)
  })

  it('costs what it costs, written down so a rewrite that doubles it is visible', () => {
    const cost = assembledControl().cost()
    /*
     * Measured 2026-10-03 on every source, after the index went by area: **19
     * tools advertised out of 155, 19,869 characters, ~5,677 estimated
     * tokens.** It was 9,247 the same morning with the per-name index.
     *
     * Pinned rather than bounded because the point of writing it down is that
     * somebody expanding a description sees the figure move — a `toBeLessThan`
     * at a round number hides every change under it. Generous slack on the
     * characters and none on the count: prose is edited constantly and a tool
     * is added deliberately.
     *
     * ## Read this before adding the next tool
     *
     * **Give it an `index` and let it be one line in its area**, unless a turn
     * will genuinely reach for it before anything else — that is the rule in
     * `describe-tool.ts`. A held-back tool now costs the standing listing
     * nothing at all: it changes a count in one area line. A new advertised
     * tool costs its whole description and schema, every turn.
     */
    expect(cost.tools).toBe(19)
    expect(cost.chars).toBeGreaterThan(18_000)
    expect(cost.chars).toBeLessThan(23_000)
  })

  it('is inside both ceilings, measured the way the status channel measures it', () => {
    const cost = assembledControl().cost()
    expect(cost.tools).toBeLessThanOrEqual(MAX_CATALOGUE_TOOLS)
    expect(cost.tokens).toBeLessThanOrEqual(MAX_CATALOGUE_TOKENS)
    expect(cost.overBudget).toBe(false)
    // And `cost()` is this listing, not a different one.
    expect(cost).toEqual(catalogueCost(advertised()))
  })

  it('names the areas rather than every held-back tool, and every area it names', () => {
    const meta = advertised().find((spec) => spec.wire === 'tools_describe')
    const description = meta?.description ?? ''
    for (const area of TOOL_AREAS) expect(description, area.id).toContain(`${area.id} — `)
    // No per-tool lines: that is the bill this replaced.
    expect(description).not.toContain('sessions_wait —')
    expect(description).not.toContain('browser_passwords —')
  })

  it('keeps an access-key caller inside both ceilings too, with tools_run listed', () => {
    /*
     * The listing claude.ai and ChatGPT read. One tool more than the copilot's —
     * `tools.run`, because those clients can only call what they are listed —
     * and one sentence more in the meta-tool telling them to use it.
     *
     * Measured 2026-10-03: **20 tools, ~5,922 estimated tokens.** Then
     * `notifications_wait` joined it (0.16.2) — the call an app makes when it is
     * idle, so it has to be listed — and `app_where` moved behind tools_describe
     * for key callers only, because the screen of a Mac nobody is at is not an
     * outside app's first reach. Still twenty tools: **~6,081 tokens.**
     */
    const cost = catalogueCost(keyListing())
    const wire = keyListing().map((spec) => spec.wire)
    expect(wire).toContain(RUN_WIRE)
    expect(wire).toContain('notifications_wait')
    expect(wire).not.toContain('app_where')
    // The copilot's listing has neither the inbox nor any line about it.
    expect(advertised().map((spec) => spec.wire).filter((name) => name.startsWith('notifications_'))).toEqual([])
    expect(advertised().map((spec) => spec.wire)).toContain('app_where')
    expect(cost.tools).toBe(20)
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
     * Measured 2026-10-03: **7 tools, ~2,492 estimated tokens** — the six
     * browser verbs and the meta-tool, with eleven tools held behind it by
     * name.
     *
     * Re-measured the same day when sessions were given the phones and
     * simulators (ten `devices.*` tools, `session-tools.ts` has why): **7 tools,
     * ~2,158 tokens** — cheaper, not dearer. Twenty-one held tools is over
     * `INLINE_INDEX_MAX`, so the index turns into areas, and the two lines a
     * session is shown — browser and devices, nothing it may not call — cost
     * less than the eleven one-liners did. The rule `describe-tool.ts` chose for
     * the copilot is the right one here too.
     */
    const visible = shipped().filter((spec) => SESSION_TOOLS.has(spec.id) || SESSION_TOOLS.has(spec.wire))
    const held = visible.filter((spec) => spec.index !== undefined)
    expect(held.length).toBeGreaterThan(INLINE_INDEX_MAX)
    const listing = advertisedCatalogue(visible)
    const cost = catalogueCost(listing)
    expect(cost.tools).toBe(7)
    expect(cost.tokens).toBeLessThan(3_000)
    expect(cost.overBudget).toBe(false)
    // The areas are this caller's: the two it holds tools in, and not the
    // sessions, machines, agents or app areas it cannot reach.
    const description = listing.find((spec) => spec.id === 'tools.describe')?.description ?? ''
    expect(description).toContain('browser — ')
    expect(description).toContain('devices — ')
    for (const hidden of ['sessions — ', 'machines — ', 'agents — ', 'app — ']) expect(description).not.toContain(hidden)
  })
})
