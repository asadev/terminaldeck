import { afterEach, describe, expect, it } from 'vitest'
import {
  cacheSize,
  forget,
  forgetAll,
  MAX_ENTRIES,
  recall,
  remember,
  setCacheClock,
} from './panel-cache'

afterEach(() => {
  forgetAll()
  setCacheClock()
})

describe('panel cache', () => {
  it('gives nothing back for a key that was never read', () => {
    expect(recall('files:tree:/a')).toBeNull()
  })

  /**
   * The point of the module: a page that has already read something must be
   * able to paint it again without asking. Artifacts re-walked every transcript
   * in the project on every return to the page, which is what "it re-fetches
   * from scratch every time" was.
   */
  it('calls a value fresh inside the caller’s own window and stale outside it', () => {
    let now = 1_000_000
    setCacheClock(() => now)
    remember('artifacts:list:/p|project', ['a.ts'])

    now += 5_000
    expect(recall<string[]>('artifacts:list:/p|project', 60_000)).toEqual({
      value: ['a.ts'],
      fresh: true,
      ageMs: 5_000,
    })

    now += 60_000
    const stale = recall<string[]>('artifacts:list:/p|project', 60_000)
    // Still handed back — the reader sees the page they left rather than a
    // loading sentence — but marked for a silent re-read.
    expect(stale).toEqual({ value: ['a.ts'], fresh: false, ageMs: 65_000 })
  })

  it('treats a caller that names no window as always needing a re-read', () => {
    remember('git:status:/p', { repo: true })
    expect(recall<{ repo: boolean }>('git:status:/p')?.fresh).toBe(false)
  })

  it('drops every key under a prefix, and one key by its exact name', () => {
    remember('files:tree:/a', 1)
    remember('files:tree:/b', 2)
    remember('artifacts:list:/a', 3)

    forget('files:tree:')
    expect(recall('files:tree:/a')).toBeNull()
    expect(recall('files:tree:/b')).toBeNull()
    expect(recall<number>('artifacts:list:/a')?.value).toBe(3)

    forget('artifacts:list:/a')
    expect(recall('artifacts:list:/a')).toBeNull()
  })

  /**
   * Eviction has to drop the least recently *written* entry, and re-writing a
   * key has to count as using it. Without the delete-before-set in `remember`,
   * the entry a page keeps refreshing would keep its original position and be
   * the first one thrown away.
   */
  it('evicts the oldest write once it is full, and a re-write counts as new', () => {
    for (let i = 0; i < MAX_ENTRIES; i += 1) remember(`k${i}`, i)
    expect(cacheSize()).toBe(MAX_ENTRIES)

    remember('k0', 'refreshed')
    remember('overflow', true)

    expect(cacheSize()).toBe(MAX_ENTRIES)
    expect(recall<string>('k0')?.value).toBe('refreshed')
    // k1 was the oldest write once k0 moved to the back.
    expect(recall('k1')).toBeNull()
  })
})
