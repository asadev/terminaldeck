import { describe, expect, it } from 'vitest'
import {
  DISMISSED_KEY,
  dismiss,
  idsFor,
  isDismissed,
  MACHINE_SCOPE,
  parseDismissed,
  readDismissed,
  restore,
  restoreAll,
  writeDismissed,
} from './readiness-dismissed'

/**
 * Putting a readiness row away, and the door back.
 *
 * Two properties carry the whole feature and both are here:
 *
 *  1. **It is never a one-way door.** *"'Don't ask again' is a one-way door —
 *     once ticked there is no way to turn it back on. That has to exist."*
 *  2. **A corrupt blob costs the dismissals and nothing else.** This is a string
 *     a person can edit in devtools, and it is read during the panel's first
 *     render — a throw there is a blank page, not a lost preference.
 */

/** A `localStorage` that lives in a variable. */
function fakeStorage(seed: Record<string, string> = {}): Storage {
  const map = new Map(Object.entries(seed))
  return {
    get length() {
      return map.size
    },
    clear: () => map.clear(),
    getItem: (key: string) => map.get(key) ?? null,
    key: (index: number) => [...map.keys()][index] ?? null,
    removeItem: (key: string) => void map.delete(key),
    setItem: (key: string, value: string) => void map.set(key, value),
  } as Storage
}

describe('reading the stored map', () => {
  it('survives anything that is not the map it expected', () => {
    expect(parseDismissed(null)).toEqual({})
    expect(parseDismissed('')).toEqual({})
    expect(parseDismissed('{ not json')).toEqual({})
    expect(parseDismissed('[1,2,3]')).toEqual({})
    expect(parseDismissed('"a string"')).toEqual({})
    // Values that are not arrays of strings are dropped; the rest is kept.
    expect(parseDismissed('{"/a":["readme"],"/b":7,"/c":[1,"lockfile"]}')).toEqual({
      '/a': ['readme'],
      '/c': ['lockfile'],
    })
  })

  it('never walks the prototype', () => {
    const parsed = parseDismissed('{"__proto__":["readme"],"/a":["readme"]}')
    expect(Object.keys(parsed)).toEqual(['/a'])
    expect(({} as Record<string, unknown>).readme).toBeUndefined()
  })

  it('answers empty rather than throwing when storage refuses', () => {
    const hostile = {
      getItem: () => {
        throw new Error('storage disabled')
      },
    } as unknown as Storage
    expect(readDismissed(hostile)).toEqual({})
  })

  it('does not throw when a write is refused either', () => {
    const full = {
      setItem: () => {
        throw new Error('quota')
      },
    } as unknown as Storage
    // The in-memory state is already right; failing to remember it is a far
    // better outcome than a panel that throws while somebody is reading it.
    expect(() => writeDismissed({ '/a': ['readme'] }, full)).not.toThrow()
  })
})

describe('putting rows away and bringing them back', () => {
  it('is keyed per project, so one folder cannot silence another', () => {
    let map = dismiss({}, '/a', 'readme')
    map = dismiss(map, '/b', 'lockfile')
    expect(isDismissed(map, '/a', 'readme')).toBe(true)
    expect(isDismissed(map, '/b', 'readme')).toBe(false)
    expect(idsFor(map, '/nowhere')).toEqual([])
  })

  it('is idempotent, and returns the same map when nothing changes', () => {
    const once = dismiss({}, '/a', 'readme')
    expect(dismiss(once, '/a', 'readme')).toBe(once)
    expect(restoreAll({}, '/a')).toEqual({})
  })

  it('brings one row back, and drops the key with the last of them', () => {
    let map = dismiss(dismiss({}, '/a', 'readme'), '/a', 'lockfile')
    map = restore(map, '/a', 'readme')
    expect(idsFor(map, '/a')).toEqual(['lockfile'])
    map = restore(map, '/a', 'lockfile')
    // Not an empty array left behind: an empty scope is a scope with nothing
    // hidden in it, and the panel counts what it finds.
    expect(Object.keys(map)).toEqual([])
  })

  it('brings all of them back at once — the door that has to exist', () => {
    const map = dismiss(dismiss(dismiss({}, '/a', 'readme'), '/a', 'lockfile'), '/b', 'readme')
    const after = restoreAll(map, '/a')
    expect(idsFor(after, '/a')).toEqual([])
    expect(idsFor(after, '/b')).toEqual(['readme'])
  })

  it('files machine-wide rows away from any project', () => {
    // A stale agent CLI is the same fact in every folder on the computer, so
    // keying it by a project path would bring it back the moment you looked at
    // a different one.
    const map = dismiss({}, MACHINE_SCOPE, 'agent-cli:gemini@0.32.1')
    expect(isDismissed(map, MACHINE_SCOPE, 'agent-cli:gemini@0.32.1')).toBe(true)
    expect(isDismissed(map, '/a', 'agent-cli:gemini@0.32.1')).toBe(false)
  })

  it('round-trips through storage under one key', () => {
    const storage = fakeStorage()
    writeDismissed(dismiss({}, '/a', 'readme'), storage)
    expect(storage.getItem(DISMISSED_KEY)).toBe('{"/a":["readme"]}')
    expect(readDismissed(storage)).toEqual({ '/a': ['readme'] })
  })
})
