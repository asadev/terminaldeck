import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  createToolStore,
  digestMatches,
  orphanIds,
  sha256Hex,
  storeRoot,
  type FetchBytes,
  type StoreCatalogue,
} from './browser-store'

/**
 * The store, driven over a real directory.
 *
 * Every assertion below is one of the four questions a store has to answer, and
 * the failures are the interesting half: a store that installs is easy, and a
 * store that refuses the right things is the feature.
 *
 * The `fetched` entry is exercised end to end even though nothing in the shipped
 * catalogue is fetched yet — the code path is real and this is where it is
 * proven, so the day a registry exists the change is a table row rather than an
 * untested feature.
 */

const RECIPE = `${JSON.stringify(
  {
    id: 'demo',
    name: 'Demo',
    summary: 'A recipe for the tests.',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['example.com'],
    fields: [{ name: 'headline', selector: 'h1', op: 'text' }],
  },
  null,
  2,
)}\n`

function catalogue(over: Partial<StoreCatalogue[number]> = {}): StoreCatalogue {
  return [
    {
      id: 'demo',
      name: 'Demo',
      summary: 'A recipe for the tests.',
      homepage: 'https://example.com',
      licence: 'MIT',
      version: '1.0.0',
      grants: ['page-read'],
      origins: ['example.com'],
      source: { kind: 'bundled', text: RECIPE },
      sha256: sha256Hex(RECIPE),
      ...over,
    },
  ]
}

let root = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-store-'))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

describe('installing and removing', () => {
  it('offers a tool as available before anybody chooses it, and nothing is on disk', () => {
    const store = createToolStore({ root, catalogue: catalogue() })
    const view = store.view()
    expect(view.tools).toHaveLength(1)
    expect(view.tools[0].state).toBe('available')
    // "which tools will not be here only when they download" — the file does not
    // exist until Install is pressed.
    expect(store.installed()).toHaveLength(0)
  })

  it('installs, writes the file, and reports where it went', async () => {
    const store = createToolStore({ root, catalogue: catalogue(), now: () => 1234 })
    const result = await store.install('demo')
    expect(result.ok).toBe(true)
    // The confirmation names a place rather than a category.
    expect(result.message).toContain('extract')
    expect(readFileSync(join(root, 'demo', 'recipe.json'), 'utf8')).toBe(RECIPE)
    const view = store.view()
    expect(view.tools[0].state).toBe('installed')
    expect(view.tools[0].installedAt).toBe(1234)
    // The row lists what the recipe actually collects, read off the disk.
    expect(view.tools[0].reads).toEqual(['headline'])
    expect(store.installed()[0].recipe.id).toBe('demo')
  })

  it('removes, and reads the disk back before saying so', async () => {
    const store = createToolStore({ root, catalogue: catalogue() })
    await store.install('demo')
    const result = store.remove('demo')
    expect(result.ok).toBe(true)
    expect(store.view().tools[0].state).toBe('available')
    expect(store.installed()).toHaveLength(0)
    // Actually gone. An uninstall that left the file behind would make the next
    // install write over something somebody thought they had deleted.
    expect(() => readFileSync(join(root, 'demo', 'recipe.json'), 'utf8')).toThrow()
  })

  it('removing something that was never installed is honest rather than an error', () => {
    const store = createToolStore({ root, catalogue: catalogue() })
    expect(store.remove('demo')).toEqual({ ok: true, message: 'It was not installed.' })
  })

  it('refuses an id that is not a tool id, so nothing can be aimed at another folder', async () => {
    const store = createToolStore({ root, catalogue: catalogue() })
    await expect(store.install('../../etc')).resolves.toEqual({
      ok: false,
      message: 'that is not a tool id',
    })
    expect(store.remove('../../etc').ok).toBe(false)
  })

  it('refuses a tool this store does not offer', async () => {
    const store = createToolStore({ root, catalogue: catalogue() })
    const result = await store.install('something-else')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('no tool by that name')
  })
})

describe('verification', () => {
  it('refuses bytes that do not match the digest written into the app', async () => {
    const store = createToolStore({ root, catalogue: catalogue({ sha256: 'a'.repeat(64) }) })
    const result = await store.install('demo')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('not the bytes this app has written down')
    // Nothing saved. A refusal that left a file behind would be a refusal that
    // installed it.
    expect(store.installed()).toHaveLength(0)
  })

  it('refuses a recipe that asks for more than the row a person read', async () => {
    const wider = RECIPE.replace('"example.com"', '"example.com", "bank.example"')
    const store = createToolStore({
      root,
      catalogue: catalogue({ source: { kind: 'bundled', text: wider }, sha256: sha256Hex(wider) }),
    })
    const result = await store.install('demo')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('bank.example')
  })

  it('refuses a recipe whose version is not the one the row offered', async () => {
    const other = RECIPE.replace('"1.0.0"', '"2.0.0"')
    const store = createToolStore({
      root,
      catalogue: catalogue({ source: { kind: 'bundled', text: other }, sha256: sha256Hex(other) }),
    })
    const result = await store.install('demo')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('2.0.0')
  })

  it('catches a file edited on disk after it was installed, and refuses to run it', async () => {
    const store = createToolStore({ root, catalogue: catalogue() })
    await store.install('demo')
    // `<userData>` is writable by every process running as this user. This is
    // the check that notices one of them having rewritten a recipe.
    writeFileSync(join(root, 'demo', 'recipe.json'), RECIPE.replace('h1', 'input[type=password]'))
    const view = store.view()
    expect(view.tools[0].state).toBe('damaged')
    expect(view.tools[0].message).toContain('not the one that was installed')
    expect(store.installed()).toHaveLength(0)
  })

  it('a damaged tool can still be removed', async () => {
    const store = createToolStore({ root, catalogue: catalogue() })
    await store.install('demo')
    writeFileSync(join(root, 'demo', 'recipe.json'), '{}')
    expect(store.view().tools[0].state).toBe('damaged')
    expect(store.remove('demo').ok).toBe(true)
    expect(store.view().tools[0].state).toBe('available')
  })
})

describe('a fetched tool', () => {
  const url = 'https://example.com/demo.json'

  /** The same row, offered from a URL instead of from the app's own bytes. */
  function fetched(): StoreCatalogue {
    return catalogue({
      source: { kind: 'fetched', url, bytes: Buffer.byteLength(RECIPE, 'utf8') },
      sha256: sha256Hex(RECIPE),
    })
  }

  const answer =
    (text: string): FetchBytes =>
    async () => ({ ok: true, text, message: '' })

  it('installs what the digest says it should be', async () => {
    const store = createToolStore({ root, catalogue: fetched(), fetchBytes: answer(RECIPE) })
    const result = await store.install('demo')
    expect(result.ok).toBe(true)
    expect(store.installed()).toHaveLength(1)
  })

  it('refuses a response of the wrong length before it hashes it', async () => {
    const short = RECIPE.slice(0, RECIPE.length - 5)
    const store = createToolStore({ root, catalogue: fetched(), fetchBytes: answer(short) })
    const result = await store.install('demo')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('bytes and this app')
  })

  it('refuses a response of the right length whose bytes are different', async () => {
    // Same length, one character changed — which is exactly what a length check
    // alone would wave through.
    const swapped = RECIPE.replace('"h1"', '"h2"')
    expect(Buffer.byteLength(swapped)).toBe(Buffer.byteLength(RECIPE))
    const store = createToolStore({ root, catalogue: fetched(), fetchBytes: answer(swapped) })
    const result = await store.install('demo')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('not the bytes this app has written down')
  })

  it('says why when the network refused, and installs nothing', async () => {
    const store = createToolStore({
      root,
      catalogue: fetched(),
      fetchBytes: async () => ({ ok: false, text: '', message: 'the download answered 404' }),
    })
    const result = await store.install('demo')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('404')
    expect(store.installed()).toHaveLength(0)
  })

  it('a fetched row says so, so the button can say Download rather than Install', () => {
    const store = createToolStore({ root, catalogue: fetched() })
    expect(store.view().tools[0].fetched).toBe(true)
    expect(store.view().tools[0].url).toBe(url)
  })
})

describe('the odds and ends', () => {
  it('a digest that is not a digest never matches', () => {
    expect(digestMatches('x', 'not-a-digest')).toBe(false)
    expect(digestMatches('x', sha256Hex('x').slice(0, 32))).toBe(false)
    expect(digestMatches('x', sha256Hex('x').toUpperCase())).toBe(true)
  })

  it('names folders this build no longer has a row for', () => {
    mkdirSync(join(root, 'withdrawn'), { recursive: true })
    mkdirSync(join(root, 'demo'), { recursive: true })
    expect(orphanIds(root, catalogue())).toEqual(['withdrawn'])
  })

  it('an orphan can be removed even though nothing offers it', () => {
    mkdirSync(join(root, 'withdrawn'), { recursive: true })
    const store = createToolStore({ root, catalogue: catalogue() })
    expect(store.remove('withdrawn').ok).toBe(true)
    expect(orphanIds(root, catalogue())).toEqual([])
  })

  it('puts its folder under userData rather than anywhere a caller names', () => {
    expect(storeRoot('/tmp/ud')).toBe(join('/tmp/ud', 'browser-tools'))
  })
})
