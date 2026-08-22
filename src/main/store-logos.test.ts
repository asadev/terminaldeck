import { describe, expect, it } from 'vitest'
import { BROWSER_EXTENSION_CATALOGUE } from './browser-extension-catalogue'
import { MCP_CATALOGUE } from './mcp-catalogue'
import { STORE_LOGO_ASSETS } from '../renderer/store/logo-data'

/**
 * The join between the catalogues and the marks, which nothing else can check.
 *
 * `logo` is a string key. The compiler has nothing to compare it against, so a
 * typo, a row renamed, or a mark dropped from `scripts/store-logos.mjs` all
 * produce the same thing: a row that quietly draws the fallback monogram while
 * its author believes they gave it a logo. Every row in both catalogues is
 * resolved here, by name, which is the only place that can be done — the
 * catalogues are in the main process and the pictures are in the renderer's
 * bundle, and no module imports across that line at runtime.
 *
 * A **test** importing across it is a different thing from code doing so, and it
 * is why `tsconfig.node.json` names `src/renderer/store/logo-data.ts` alongside
 * the two renderer files it already lists. Nothing in `src/main` imports it, so
 * none of those bytes reach the main bundle; this file is where the two halves
 * of one feature are held to each other.
 */

/** Both catalogues as `{ id, logo }`, so one loop covers all forty-two rows. */
const ROWS: readonly { id: string; logo: string | undefined; store: string }[] = [
  ...BROWSER_EXTENSION_CATALOGUE.map((one) => ({ id: one.id, logo: one.logo, store: 'browser' })),
  ...MCP_CATALOGUE.map((one) => ({ id: one.id, logo: one.logo, store: 'mcp' })),
]

describe('every catalogue row has a mark, and every mark has a row', () => {
  it('is the two catalogues this store was looked at with', () => {
    /* Not a magic number for its own sake: a change to either count should be
       something somebody did on purpose, not something they find out from a
       screenshot with a monogram in it. */
    expect(BROWSER_EXTENSION_CATALOGUE.length).toBe(24)
    expect(MCP_CATALOGUE.length).toBe(18)
  })

  for (const row of ROWS) {
    it(`${row.store}/${row.id} names a mark that is in the module`, () => {
      expect(row.logo).toBeTruthy()
      expect(Object.keys(STORE_LOGO_ASSETS)).toContain(row.logo)
    })
  }

  it('ships no mark that no row asks for', () => {
    const asked = new Set(ROWS.map((row) => row.logo))
    const unused = Object.keys(STORE_LOGO_ASSETS).filter((key) => !asked.has(key))
    expect(unused).toEqual([])
  })

  it('gives the six reference servers the one mark that is true of all of them', () => {
    /* Six rows sharing `modelcontextprotocol` is the point rather than a
       shortcut — see `McpCatalogueEntry.logo`. Pinned so that somebody
       "fixing the duplicates" has to read why first. */
    const shared = MCP_CATALOGUE.filter((one) => one.logo === 'modelcontextprotocol').map(
      (one) => one.id,
    )
    expect(shared).toEqual([
      'filesystem',
      'memory',
      'sequential-thinking',
      'everything',
      'fetch',
      'time',
    ])
  })
})
