import { describe, expect, it } from 'vitest'
import { BROWSER_TOOL_CATALOGUE } from './browser-store-catalogue'
import { sha256Hex } from './browser-store'
import { parseRecipe } from './browser-store-recipe'

/**
 * The shipped table, held to its own promises.
 *
 * The digests in `browser-store-catalogue.ts` are the root of trust for the
 * whole feature, and a digest maintained by hand is a digest that goes stale the
 * first time somebody fixes a typo in a selector. This is what stops that being
 * possible: an edited recipe with an unedited digest fails here, and the failure
 * prints the value it should have been.
 *
 * It is also the only place that proves every shipped entry is installable at
 * all. A catalogue row whose recipe does not parse is a store row that always
 * refuses — which looks exactly like a bug in the store rather than in the row.
 */

describe('every tool this store offers', () => {
  const entries = BROWSER_TOOL_CATALOGUE

  it('is offered at least once, so the panel is never empty', () => {
    expect(entries.length).toBeGreaterThan(0)
  })

  it('has a unique id', () => {
    const ids = entries.map((entry) => entry.id)
    expect(new Set(ids).size).toBe(ids.length)
  })

  it.each(entries.map((entry) => [entry.id, entry] as const))(
    '%s hashes to the digest written beside it',
    (_id, entry) => {
      if (entry.source.kind !== 'bundled') return
      // If this fails, the recipe was edited and the digest was not. The value
      // on the right of the diff is the one to paste.
      expect(sha256Hex(entry.source.text)).toBe(entry.sha256)
    },
  )

  it.each(entries.map((entry) => [entry.id, entry] as const))(
    '%s parses, and never asks for more than its row says',
    (_id, entry) => {
      if (entry.source.kind !== 'bundled') return
      const parsed = parseRecipe(entry.source.text, entry.id)
      expect(parsed.ok, parsed.ok ? '' : parsed.why).toBe(true)
      if (!parsed.ok) return
      expect(parsed.recipe.version).toBe(entry.version)
      for (const grant of parsed.recipe.grants) expect(entry.grants).toContain(grant)
      for (const origin of parsed.recipe.origins) expect(entry.origins).toContain(origin)
      // The row's own words and the recipe's must not drift apart: the row is
      // the disclosure a person reads before pressing Install.
      expect(parsed.recipe.name).toBe(entry.name)
      expect(parsed.recipe.summary).toBe(entry.summary)
    },
  )

  it('only ever asks to read a page', () => {
    // The whole of what this build can enforce. A row promising anything else
    // would be a permission printed on a screen and checked nowhere.
    for (const entry of entries) expect(entry.grants).toEqual(['page-read'])
  })

  it('says where each one came from and under what licence', () => {
    for (const entry of entries) {
      expect(entry.homepage.startsWith('https://')).toBe(true)
      expect(entry.licence).not.toBe('')
    }
  })
})
