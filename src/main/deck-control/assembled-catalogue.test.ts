import { describe, expect, it } from 'vitest'
import { assembledCatalogue } from './assembled-catalogue.fixture'
import { TOOL_AREAS, areaOf } from './describe-tool'

/**
 * Every tool the app assembles, from every source, as one list — and no two of
 * them with one name.
 *
 * ## Why this is its own test
 *
 * `DeckControl` refuses a catalogue in which two tools share an id or a wire
 * name, and it refuses by throwing in its constructor. In the running app that
 * constructor is inside `registerDeckControlIpc`, whose rejection
 * `src/main/index.ts` catches and logs as *"failed to start, copilot tools
 * disabled"*. So a clash between two areas does not fail a build or a test of
 * either area: it turns the whole tool server off at boot, for every caller,
 * with the app otherwise looking normal. Four lanes built their areas in
 * parallel and each could only check its own names; this is the one place
 * they are checked together.
 *
 * The factories are given stand-ins, because a tool's id and wire name are
 * literals in its factory — nothing here calls a `run`. The list mirrors the
 * `extraTools` in `src/main/index.ts` and the two tools `deck-control/index.ts`
 * adds; a source added there and not here is the gap this file exists to close,
 * so add it here in the same change.
 *
 * The list itself is `assembled-catalogue.fixture.ts`, shared with
 * `catalogue-cost.test.ts` so the names checked here and the bill measured
 * there are the same tools — built by `DeckControl`'s own constructor.
 */
function assembled() {
  return assembledCatalogue()
}

describe('the catalogue every area assembles into', () => {
  it('has no two tools answering to one name, which would turn the tool server off at boot', () => {
    // One map, both spellings — the shape `DeckControl` registers them in.
    const names = assembled().flatMap((spec) => [spec.id, spec.wire])
    const twice = [...new Set(names.filter((name, index) => names.indexOf(name) !== index))]
    expect(twice).toEqual([])
  })

  it('spells every wire name as its id with underscores, so a call by either reaches one tool', () => {
    const odd = assembled().filter((spec) => spec.wire !== spec.id.replace(/\./g, '_'))
    expect(odd.map((spec) => `${spec.id} → ${spec.wire}`)).toEqual([])
  })

  it('names every tool the coverage tables point at', async () => {
    const { coverageRows } = await import('./coverage-tool')
    const built = new Set(assembled().map((spec) => spec.id))
    const missing = coverageRows().flatMap((row) =>
      (row.tools ?? []).filter((id) => !built.has(id)).map((id) => `${row.area} ${row.action} → ${id}`),
    )
    expect(missing).toEqual([])
  })

  it('puts every tool in an area the describe index names, so none is stranded behind an unlisted prefix', () => {
    const declared = new Set(TOOL_AREAS.map((area) => area.id))
    const stray = assembled().filter((spec) => !declared.has(areaOf(spec))).map((spec) => spec.id)
    expect(stray).toEqual([])
  })
})
