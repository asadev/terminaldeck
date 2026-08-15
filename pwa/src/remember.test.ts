/**
 * The two-store rule is exercised end to end through `savePairing` in
 * `pair.test.ts`, which is where it matters. What is here is the part that has
 * no other cover: the probe that decides whether a browser's storage is usable
 * at all, and the memory stand-in behind it.
 */

import { describe, expect, it } from 'vitest'
import { browserStores, clearAcross, memoryStorage, readAcross, storeFor, writeAcross } from './remember'

/** Safari in private mode: hands back the object, then throws on the write. */
function lyingStorage(): Storage {
  return {
    getItem: () => null,
    setItem: () => {
      throw new Error('QuotaExceededError')
    },
    removeItem: () => {},
    clear: () => {},
    key: () => null,
    length: 0,
  } as unknown as Storage
}

/** A browser that refuses to hand over the object at all. */
function forbiddenWindow(): Window {
  return {
    get localStorage(): Storage {
      throw new Error('SecurityError')
    },
    get sessionStorage(): Storage {
      throw new Error('SecurityError')
    },
  } as unknown as Window
}

describe('deciding whether a browser will actually hold anything', () => {
  it('writes and reads back through a store that works', () => {
    const store = memoryStorage()
    store.setItem('k', 'v')
    expect(store.getItem('k')).toBe('v')
    store.removeItem('k')
    expect(store.getItem('k')).toBeNull()
  })

  it('probes with a write rather than trusting the object to exist', () => {
    /*
     * The trap: Safari in private mode returns a perfectly ordinary `Storage`
     * and throws on the first `setItem`. A check that only asked whether the
     * object was there would pass here and fail at the moment somebody paired —
     * with a credential that looked saved and was not, and a next launch back on
     * the pair screen with no explanation.
     */
    const stores = browserStores({
      localStorage: lyingStorage(),
      sessionStorage: lyingStorage(),
    } as unknown as Window)
    expect(() => stores.browser.setItem('k', 'v')).not.toThrow()
    // And it is a real store, so the session in progress still works.
    expect(stores.browser.getItem('k')).toBe('v')
  })

  it('survives a browser that will not even hand over the object', () => {
    const stores = browserStores(forbiddenWindow())
    expect(() => stores.tab.setItem('k', 'v')).not.toThrow()
    expect(stores.tab.getItem('k')).toBe('v')
  })

  it('leaves nothing behind after probing a store that works', () => {
    const local = memoryStorage()
    const session = memoryStorage()
    browserStores({ localStorage: local, sessionStorage: session } as unknown as Window)
    expect(local.getItem('__terminaldeck.probe__')).toBeNull()
    expect(session.getItem('__terminaldeck.probe__')).toBeNull()
  })
})

describe('the rule that exactly one store holds a thing', () => {
  const stores = () => ({ browser: memoryStorage(), tab: memoryStorage() })
  const write = (value: string) => (store: { setItem(k: string, v: string): void }) => store.setItem('x', value)
  const clear = (store: { removeItem(k: string): void }) => store.removeItem('x')
  const read = (store: { getItem(k: string): string | null }) => store.getItem('x')

  it('names the store an answer means', () => {
    const both = stores()
    expect(storeFor(both, 'this-tab')).toBe(both.tab)
    expect(storeFor(both, 'this-browser')).toBe(both.browser)
  })

  it('clears the other store on every write, not only when it is occupied', () => {
    const both = stores()
    writeAcross(both, 'this-browser', write('durable'), clear)
    writeAcross(both, 'this-tab', write('per-tab'), clear)
    expect(both.browser.getItem('x')).toBeNull()
    expect(both.tab.getItem('x')).toBe('per-tab')
  })

  it('reads the tab first, because it is the more recent decision', () => {
    const both = stores()
    both.browser.setItem('x', 'durable')
    both.tab.setItem('x', 'per-tab')
    expect(readAcross(both, read)).toEqual({ value: 'per-tab', remember: 'this-tab' })
  })

  it('says which store answered, so the next write lands in the same one', () => {
    const both = stores()
    both.browser.setItem('x', 'durable')
    expect(readAcross(both, read)).toEqual({ value: 'durable', remember: 'this-browser' })
    expect(readAcross(stores(), read)).toBeNull()
  })

  it('clears both, because half of something left behind is the whole problem', () => {
    const both = stores()
    both.browser.setItem('x', 'a')
    both.tab.setItem('x', 'b')
    clearAcross(both, clear)
    expect(readAcross(both, read)).toBeNull()
  })
})
