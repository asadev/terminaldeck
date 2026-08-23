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
 *
 * ## Why this is no longer the only thing holding them together
 *
 * It used to be, and it went red the first time the store was widened. The fetch
 * script carried its own hardcoded list of thirty-seven marks and never read the
 * catalogues; a lane added thirty-three rows, correctly, and thirty-three keys
 * resolved to nothing. Nobody had made a mistake — there was simply no point at
 * which the two halves were compared until this file ran.
 *
 * `scripts/store-logos.mjs` now derives its work list from these same two
 * catalogues and refuses to write when a row names a key it has no source for,
 * so the failure arrives while somebody is adding the row rather than after.
 * This file stays as the check on what actually **shipped**: the script proves
 * the intent, and the generated module is what the app draws from.
 */

/** Both catalogues as `{ id, logo }`, so one loop covers every row. */
const ROWS: readonly { id: string; logo: string | undefined; store: string }[] = [
  ...BROWSER_EXTENSION_CATALOGUE.map((one) => ({ id: one.id, logo: one.logo, store: 'browser' })),
  ...MCP_CATALOGUE.map((one) => ({ id: one.id, logo: one.logo, store: 'mcp' })),
]

/**
 * The rows that deliberately have no mark, and why each one has none.
 *
 * `logo` is optional on both catalogue types on purpose — a row draws the
 * monogram in `StoreLogo.tsx` rather than nothing, and requiring a picture would
 * mean the only way to add a row was to have the network. But "optional" and
 * "forgotten" look identical from here, so the exceptions are named: a row that
 * loses the mark it had fails, and a new row without one is a line somebody
 * wrote on purpose with a reason beside it.
 */
const NO_MARK = new Map<string, string>([
  [
    'mcp/google-workspace',
    'Google publishes no Workspace mark at a fetchable address the way it does for Docs, Drive ' +
      'and Keep, and the four-colour Google “G” identifies Google rather than Workspace.',
  ],
])

describe('every catalogue row has a mark, and every mark has a row', () => {
  it('is the two catalogues this store was looked at with', () => {
    /* Not a magic number for its own sake: a change to either count should be
       something somebody did on purpose, not something they find out from a
       screenshot with a monogram in it. */
    /* Twelve, down from thirty-six on 2026-08-23: the browser catalogue now
       holds only what installs in this browser and was watched running here.
       Twenty-two marks came out of `logo-data.ts` with those rows — see
       `browser-extension-catalogue.ts` for which rows went and why. */
    expect(BROWSER_EXTENSION_CATALOGUE.length).toBe(12)
    expect(MCP_CATALOGUE.length).toBe(39)
  })

  for (const row of ROWS) {
    const named = `${row.store}/${row.id}`
    if (NO_MARK.has(named)) {
      it(`${named} draws the monogram, on purpose`, () => {
        expect(row.logo).toBeUndefined()
      })
      continue
    }
    it(`${named} names a mark that is in the module`, () => {
      expect(row.logo).toBeTruthy()
      expect(Object.keys(STORE_LOGO_ASSETS)).toContain(row.logo)
    })
  }

  it('keeps the no-mark list to rows that exist', () => {
    /* The half of an exception list that rots: a row is renamed or dropped, and
       its excuse stays behind as precedent for the next person. */
    const real = new Set(ROWS.map((row) => `${row.store}/${row.id}`))
    expect([...NO_MARK.keys()].filter((named) => !real.has(named))).toEqual([])
  })

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

  it('lets a mark stand for more than one row where the product is the same', () => {
    /* Pinned for the same reason as the six above: each is one product wearing
       its own mark on more than one row, not a mark borrowed to fill a gap.
       Postgres is the reference server and the community one.

       Two of these used to be pairs across the two stores — Drive was an
       extension and a server, Notion was Notion and its clipper — and both
       extensions were Chrome Web Store links that could not be installed here,
       so both are gone. What is checked now is that neither mark is left
       standing for a row that no longer exists. */
    const rowsFor = (logo: string): string[] =>
      ROWS.filter((row) => row.logo === logo).map((row) => `${row.store}/${row.id}`)
    expect(rowsFor('google-drive')).toEqual(['mcp/google-drive'])
    expect(rowsFor('notion')).toEqual(['mcp/notion'])
    expect(rowsFor('postgres')).toEqual(['mcp/postgres-mcp', 'mcp/postgres'])
  })
})
