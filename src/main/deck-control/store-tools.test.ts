import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import type { InstalledTool, StoreEntry } from '../browser-store'
import { parseRecipe } from '../browser-store-recipe'
import { ActionLog } from './action-log'
import { resetForTests } from '../browser-binding'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import {
  collectedBy,
  completenessNote,
  isComplete,
  listInstalled,
  STORE_PLACE,
  storeTools,
  trustedStated,
} from './store-tools'
import { SESSION_TOOLS } from './session-tools'
import type { DeckSurface } from './surface'

/**
 * The one door every installed store tool comes through.
 *
 * Three things are asserted here and they are the three the feature would be
 * dishonest without: an uninstalled tool cannot be run and the refusal says
 * where to install one; a host-bound tool is refused on every other page; and a
 * page that states a bigger number than came back says so out loud rather than
 * letting a partial read pass as a complete one.
 */

const RECIPE_TEXT = JSON.stringify({
  id: 'demo',
  name: 'Demo',
  summary: 'A recipe for the tests.',
  version: '1.0.0',
  grants: ['page-read'],
  origins: ['portal.example'],
  fields: [{ name: 'headline', selector: 'h1', op: 'text' }],
  rows: { selector: '.row', fields: [{ name: 'price', selector: '.p', op: 'text' }] },
  stated: { name: 'total', selector: '.count', op: 'number' },
})

function installed(): InstalledTool[] {
  const parsed = parseRecipe(RECIPE_TEXT, 'demo')
  if (!parsed.ok) throw new Error(parsed.why)
  return [
    {
      entry: { id: 'demo', name: 'Demo' } as StoreEntry,
      recipe: parsed.recipe,
      installedAt: 0,
    },
  ]
}

/** A drive that answers what a page would, and records the plan it was given. */
function fakeDrive(
  origin: string | null,
  answer: Partial<{ rowsOnPage: number; rowsReturned: number; stated: number | null }> = {},
): BrowserDrive & { plans: unknown[] } {
  const plans: unknown[] = []
  const drive = {
    plans,
    origin: () => origin,
    extract: async (plan: unknown) => {
      plans.push(plan)
      return {
        url: 'https://portal.example/list',
        title: 'Listings',
        fields: { headline: 'Listings' },
        rows: [{ price: '1' }],
        rowsOnPage: answer.rowsOnPage ?? 1,
        rowsReturned: answer.rowsReturned ?? 1,
        counts: {},
        stated: answer.stated === undefined ? null : answer.stated,
        next: null,
      }
    },
  }
  return drive as unknown as BrowserDrive & { plans: unknown[] }
}

function approving(): ConsentBroker {
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  return broker
}

function control(
  drive: BrowserDrive,
  logDir: string,
  tools: () => InstalledTool[] = installed,
): DeckControl {
  return new DeckControl({
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: logDir }),
    consent: approving(),
    extraTools: storeTools({ drive, installed: tools }),
  })
}

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-store-tools-'))
  resetForTests()
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('finding out what is installed', () => {
  it('lists what is installed, with what it reads and where it runs', async () => {
    const deck = control(fakeDrive('https://portal.example'), dir)
    const result = await deck.call('browser_extract', {})
    expect(result.ok).toBe(true)
    const value = result.value as { tools: { tool: string; runsOn: string; fields: string[] }[] }
    expect(value.tools[0].tool).toBe('demo')
    expect(value.tools[0].runsOn).toBe('portal.example')
    expect(value.tools[0].fields).toContain('headline')
    expect(value.tools[0].fields).toContain('price (per row)')
  })

  it('an empty store answers with the place a person installs one', async () => {
    const deck = control(fakeDrive('https://portal.example'), dir, () => [])
    const result = await deck.call('browser_extract', {})
    const value = result.value as { tools: unknown[]; note: string }
    expect(value.tools).toHaveLength(0)
    // Not a shrug. A model told only "nothing is installed" invents a way to
    // install one; this names the door.
    expect(value.note).toContain(STORE_PLACE)
  })

  it('refuses a tool nobody installed, and says so', async () => {
    const deck = control(fakeDrive('https://portal.example'), dir, () => [])
    const result = await deck.call('browser_extract', { tool: 'whatever' })
    expect(result.ok).toBe(false)
    expect(String(result.error)).toContain(STORE_PLACE)
  })

  it('names the ones that are installed when the wanted one is not', async () => {
    const deck = control(fakeDrive('https://portal.example'), dir)
    const result = await deck.call('browser_extract', { tool: 'whatever' })
    expect(result.ok).toBe(false)
    expect(String(result.error)).toContain('demo')
  })
})

describe('where an installed tool may run', () => {
  it('runs on a page inside its own hosts', async () => {
    const drive = fakeDrive('https://portal.example')
    const deck = control(drive, dir)
    const result = await deck.call('browser_extract', { tool: 'demo' })
    expect(result.ok).toBe(true)
    expect(drive.plans).toHaveLength(1)
  })

  it('is refused on every other page, before it runs', async () => {
    const drive = fakeDrive('https://bank.example')
    const deck = control(drive, dir)
    const result = await deck.call('browser_extract', { tool: 'demo' })
    expect(result.ok).toBe(false)
    expect(String(result.error)).toContain('portal.example')
    // The gate is ahead of the page, not inside the recipe: nothing was run.
    expect(drive.plans).toHaveLength(0)
  })

  it('is refused when the page has no address this app can read', async () => {
    const drive = fakeDrive(null)
    const deck = control(drive, dir)
    const result = await deck.call('browser_extract', { tool: 'demo' })
    expect(result.ok).toBe(false)
    expect(drive.plans).toHaveLength(0)
  })
})

describe('how much came back', () => {
  it('says nothing when the page and the answer agree', () => {
    expect(completenessNote({ stated: 10, onPage: 10, returned: 10 })).toBe('')
    expect(completenessNote({ stated: null, onPage: 3, returned: 3 })).toBe('')
  })

  it('says so when the page accounts for more than came back', () => {
    const note = completenessNote({ stated: 1248, onPage: 200, returned: 200 })
    expect(note).toContain('1248')
    expect(note).toContain('not the whole set')
  })

  it('says so when the limit bit, separately from the page being short', () => {
    const note = completenessNote({ stated: null, onPage: 500, returned: 200 })
    expect(note).toContain('limit')
  })

  it('refuses to believe a stated total smaller than what came back, and says so', () => {
    /*
     * The dangerous direction. A selector pointed at "showing 1-20 of 1,248"
     * reads 1, and believing it would compute 20 >= 1 and call a partial read
     * complete — which is the seven-per-cent bug exactly.
     */
    expect(isComplete(1, 20)).toBeNull()
    expect(trustedStated(1, 20)).toBeNull()
    expect(completenessNote({ stated: 1, onPage: 20, returned: 20 })).toContain('not believed')
  })

  it('counts a list field when the recipe has no rows, and rows when it has', () => {
    const withRows = { rows: {} }
    const noRows = { rows: null }
    const answer = {
      rowsOnPage: 40,
      rowsReturned: 20,
      counts: { images: { matched: 240, returned: 200 }, alts: { matched: 12, returned: 12 } },
    }
    expect(collectedBy(withRows, answer)).toEqual({ onPage: 40, returned: 20 })
    // `page-images` has no rows at all — a check written only against rows would
    // have said "0 came back" on a page with two hundred images.
    expect(collectedBy(noRows, answer)).toEqual({ onPage: 240, returned: 200 })
  })

  it('carries the numbers and a three-valued complete into the result', async () => {
    const deck = control(
      fakeDrive('https://portal.example', { rowsOnPage: 200, rowsReturned: 200, stated: 1248 }),
      dir,
    )
    const result = await deck.call('browser_extract', { tool: 'demo' })
    const value = result.value as { stated: number; complete: boolean | null; note: string }
    expect(value.stated).toBe(1248)
    expect(value.complete).toBe(false)
    expect(value.note).toContain('1248')
  })

  it('leaves complete null when the recipe names no total, rather than guessing', async () => {
    const deck = control(fakeDrive('https://portal.example', { stated: null }), dir)
    const result = await deck.call('browser_extract', { tool: 'demo' })
    expect((result.value as { complete: boolean | null }).complete).toBeNull()
  })

  it('writes the counts to the action log and never the payload', async () => {
    const deck = control(
      fakeDrive('https://portal.example', { rowsOnPage: 9, rowsReturned: 4, stated: 9 }),
      dir,
    )
    await deck.call('browser_extract', { tool: 'demo' })
    const row = JSON.parse(readFileSync(join(dir, 'actions.jsonl'), 'utf8').trim().split('\n').pop() ?? '{}')
    expect(row.result).toMatchObject({ tool: 'demo', rows: 4, onPage: 9, stated: 9, short: true })
    // An audit trail, not a second copy of the app's data.
    expect(JSON.stringify(row)).not.toContain('Listings')
  })
})

describe('the reach a store tool has', () => {
  it('is one written-down id on the session allow-list, however many are installed', () => {
    // Installing must never be able to widen what a session may call. The store
    // adds exactly these two spellings of one tool and nothing else.
    expect(SESSION_TOOLS.has('browser.extract')).toBe(true)
    expect(SESSION_TOOLS.has('browser_extract')).toBe(true)
    for (const tool of installed()) {
      expect(SESSION_TOOLS.has(tool.recipe.id)).toBe(false)
    }
  })

  it('is a read, so it discloses nothing browser.read on the same page would not', () => {
    const [spec] = storeTools({ drive: fakeDrive(null), installed })
    expect(spec.tier).toBe('read')
  })

  it('lists what a tool collects without running it', () => {
    const listing = listInstalled(installed())
    expect(listing[0].reads).toBe('A recipe for the tests.')
    expect(listing[0].runsOn).toBe('portal.example')
  })
})
