/**
 * The browser client's half of the colour schemes.
 *
 * The schemes themselves are tested where they live — `src/shared/
 * terminal-theme.test.ts` — and this file deliberately does not repeat any of
 * it. What is only true on this side is the *store*: which key, what a
 * throwing `localStorage` means, and what happens to a choice that points at a
 * scheme somebody deleted in another tab.
 *
 * Every one of those is a failure this client has already had in a different
 * feature. Safari in private mode throws on `setItem`, which is why every read
 * and write here is wrapped and why `remember.ts` exists; and a stored value
 * from a build with different rules is the ordinary case for a page that
 * updates itself out of a service-worker cache while nobody is watching.
 */

import { describe, expect, it } from 'vitest'
import {
  BUILTIN_SCHEMES,
  FOLLOW_APP_SCHEME_ID,
  MAX_CUSTOM_SCHEMES,
  copyOf,
  schemeById,
} from '../../src/shared/terminal-theme'
import { memoryStorage, type StorageLike } from './remember'
import {
  CUSTOM_SCHEMES_KEY,
  SCHEME_KEY,
  readCustomSchemes,
  readSchemeChoice,
  resolveScheme,
  schemesToOffer,
  writeCustomSchemes,
  writeSchemeChoice,
} from './terminal-scheme'

/** A store that refuses everything, the way Safari does in a private window. */
const refusing: StorageLike = {
  getItem() {
    throw new Error('SecurityError')
  },
  setItem() {
    throw new Error('SecurityError')
  },
  removeItem() {
    throw new Error('SecurityError')
  },
}

describe('the chosen scheme', () => {
  it('is to follow the appearance until somebody says otherwise', () => {
    expect(readSchemeChoice(memoryStorage())).toBe(FOLLOW_APP_SCHEME_ID)
  })

  it('comes back the way it went in', () => {
    const store = memoryStorage()
    writeSchemeChoice(store, 'nord')
    expect(store.getItem(SCHEME_KEY)).toBe('nord')
    expect(readSchemeChoice(store)).toBe('nord')
  })

  /**
   * A store that throws is an unanswered question, not an error.
   *
   * The terminal in front of the person is already in the colours they asked
   * for — only the next launch forgets. A client that let this throw would
   * white-screen on the Settings tab in a private window.
   */
  it('survives a store that refuses to answer', () => {
    expect(readSchemeChoice(refusing)).toBe(FOLLOW_APP_SCHEME_ID)
    expect(() => writeSchemeChoice(refusing, 'nord')).not.toThrow()
    expect(() => writeCustomSchemes(refusing, [])).not.toThrow()
    expect(readCustomSchemes(refusing)).toEqual([])
  })
})

describe('the schemes this browser holds', () => {
  const mine = copyOf(schemeById('nord')!, [])

  it('round-trip under their own key', () => {
    const store = memoryStorage()
    writeCustomSchemes(store, [mine])
    expect(store.getItem(CUSTOM_SCHEMES_KEY)).not.toBeNull()
    const back = readCustomSchemes(store)
    expect(back).toHaveLength(1)
    expect(back[0].name).toBe('Nord (yours)')
    expect(back[0].brightCyan).toBe('#8fbcbb')
  })

  it.each([
    ['not JSON at all', 'not json'],
    ['a JSON value that is not a list', '{"nord":true}'],
    ['a list of things that are not schemes', '[{"name":"Half"},7,null]'],
  ])('drops %s rather than throwing', (_what, stored) => {
    const store = memoryStorage()
    store.setItem(CUSTOM_SCHEMES_KEY, stored)
    expect(readCustomSchemes(store)).toEqual([])
  })

  it('keeps the good ones out of a list with a bad one in it', () => {
    const store = memoryStorage()
    store.setItem(CUSTOM_SCHEMES_KEY, JSON.stringify([{ name: 'Half' }, mine]))
    expect(readCustomSchemes(store).map((scheme) => scheme.name)).toEqual(['Nord (yours)'])
  })

  /**
   * A ceiling, because `localStorage` is shared with everything else this page
   * keeps and a list nobody can trim is a quota error waiting for the pairing
   * credential beside it.
   */
  it('holds no more than the ceiling, in either direction', () => {
    const store = memoryStorage()
    const many = Array.from({ length: MAX_CUSTOM_SCHEMES + 5 }, (_unused, at) => ({
      ...mine,
      id: `custom-${at}`,
    }))
    writeCustomSchemes(store, many)
    expect(readCustomSchemes(store)).toHaveLength(MAX_CUSTOM_SCHEMES)
  })
})

describe('what actually gets painted', () => {
  it('is nothing at all while the choice is to follow the appearance', () => {
    expect(resolveScheme(FOLLOW_APP_SCHEME_ID, [])).toBeNull()
    expect(resolveScheme('', [])).toBeNull()
  })

  it('is the built-in an id names', () => {
    expect(resolveScheme('pure-black', [])?.background).toBe('#000000')
  })

  it('is one of this browser’s own when the id is one of theirs', () => {
    const mine = { ...copyOf(schemeById('dracula')!, []), name: 'Mine' }
    expect(resolveScheme(mine.id, [mine])?.name).toBe('Mine')
  })

  /**
   * And nothing, rather than a substitute, for an id that has gone.
   *
   * This is a real state: two tabs of this client share one `localStorage`, so
   * deleting a scheme in one leaves the other holding its id until it next
   * reads. Falling back to the appearance is the only answer that is never
   * wrong; falling back to the first built-in would repaint somebody's session
   * in a colour they never chose.
   */
  it('is nothing for a scheme deleted in another tab', () => {
    expect(resolveScheme('custom-9', [])).toBeNull()
  })

  it('offers every scheme that ships, then the ones somebody made', () => {
    const mine = copyOf(schemeById('nord')!, [])
    const offered = schemesToOffer([mine])
    expect(offered).toHaveLength(BUILTIN_SCHEMES.length + 1)
    expect(offered[offered.length - 1].id).toBe(mine.id)
  })
})
