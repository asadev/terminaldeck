import { describe, expect, it } from 'vitest'
import {
  originWords,
  readStoreResult,
  readStoreView,
  resolveStoreApi,
  storeAvailable,
} from './store-bridge'

/**
 * The renderer's half, held to the rule the whole bridge layer lives by: an
 * older or newer main process is a quiet no-op, never a crash inside an effect.
 *
 * The interesting assertion is {@link storeAvailable}. Every other bridge in
 * this folder takes "the reads are the bar" and lets the verbs degrade one
 * control each. A store cannot: a list with no Install is a catalogue of things
 * you cannot have, and an Install with no Remove is worse than no store at all.
 * So all three are the bar, and a build missing one loses the menu row rather
 * than opening a panel whose buttons do nothing.
 */

describe('resolving the store', () => {
  it('takes only the functions it knows about, bound to the host', () => {
    const host = {
      browserStore: () => Promise.resolve({}),
      browserStoreInstall: () => Promise.resolve({}),
      browserStoreRemove: () => Promise.resolve({}),
      somethingElse: () => Promise.resolve({}),
    }
    const api = resolveStoreApi(host) as Record<string, unknown>
    expect(Object.keys(api).sort()).toEqual([
      'browserStore',
      'browserStoreInstall',
      'browserStoreRemove',
    ])
  })

  it('is empty rather than throwing when there is no bridge at all', () => {
    expect(resolveStoreApi(null)).toEqual({})
    expect(resolveStoreApi(undefined)).toEqual({})
    expect(storeAvailable(resolveStoreApi({}))).toBe(false)
  })

  it('needs all three, so a half-wired preload takes the row and not the panel', () => {
    const two = resolveStoreApi({
      browserStore: () => Promise.resolve({}),
      browserStoreInstall: () => Promise.resolve({}),
    })
    expect(storeAvailable(two)).toBe(false)
    const three = resolveStoreApi({
      browserStore: () => Promise.resolve({}),
      browserStoreInstall: () => Promise.resolve({}),
      browserStoreRemove: () => Promise.resolve({}),
    })
    expect(storeAvailable(three)).toBe(true)
  })
})

describe('narrowing what arrives', () => {
  it('reads a real answer', () => {
    const view = readStoreView({
      view: {
        folder: '/tmp/browser-tools',
        tools: [
          {
            id: 'page-images',
            name: 'Full-size images',
            summary: 'Everything.',
            homepage: 'https://example.com',
            licence: 'MIT',
            version: '1.0.0',
            grants: ['page-read'],
            origins: ['*'],
            url: '',
            fetched: false,
            state: 'installed',
            installedVersion: '1.0.0',
            installedAt: 5,
            message: '',
            reads: ['images'],
          },
        ],
      },
      orphans: ['withdrawn'],
    })
    expect(view.tools).toHaveLength(1)
    expect(view.tools[0].state).toBe('installed')
    expect(view.orphans).toEqual(['withdrawn'])
  })

  it('drops a row with no id rather than drawing a nameless button', () => {
    const view = readStoreView({ view: { tools: [{ name: 'no id' }, { id: 'ok' }] } })
    expect(view.tools.map((tool) => tool.id)).toEqual(['ok'])
    // A row that arrived with nothing but an id still draws, named by it.
    expect(view.tools[0].name).toBe('ok')
  })

  it('falls back to available for a state this build has never heard of', () => {
    const view = readStoreView({ view: { tools: [{ id: 'x', state: 'quarantined' }] } })
    expect(view.tools[0].state).toBe('available')
  })

  it('answers with an empty store for anything that is not an answer', () => {
    for (const raw of [null, undefined, 0, 'nope', [], {}]) {
      expect(readStoreView(raw)).toEqual({ tools: [], folder: '', orphans: [] })
    }
  })

  it('treats a missing result as a failure rather than a success', () => {
    expect(readStoreResult(null).ok).toBe(false)
    expect(readStoreResult({ message: 'done' }).ok).toBe(false)
    expect(readStoreResult({ ok: true, message: 'done' })).toEqual({ ok: true, message: 'done' })
  })
})

describe('the words on a row', () => {
  it('says any page for a star, and the hosts otherwise', () => {
    expect(originWords(['*'])).toBe('any page')
    expect(originWords(['a.example'])).toBe('a.example')
    // A tool that runs nowhere is a real state and it is said, not blanked.
    expect(originWords([])).toBe('nowhere')
  })
})
