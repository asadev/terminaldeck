import { describe, expect, it } from 'vitest'
import { asIsolationKey, isolationAvailable, resolveIsolationApi } from './isolation-bridge'

describe('resolveIsolationApi', () => {
  it('picks up what the preload exposes and skips what it does not', () => {
    const api = resolveIsolationApi({ browserIsolationKey: async () => 'k' })
    expect(typeof api.browserIsolationKey).toBe('function')
    expect(api.browserIsolationDispose).toBeUndefined()
  })

  it('calls through the host so a method on a prototype keeps its `this`', async () => {
    class Preload {
      readonly minted = 'pawl-tab-from-this'
      async browserIsolationKey(): Promise<string> {
        return this.minted
      }
    }
    const api = resolveIsolationApi(new Preload())
    await expect(api.browserIsolationKey?.()).resolves.toBe('pawl-tab-from-this')
  })

  it('is empty rather than throwing when there is no bridge at all', () => {
    expect(resolveIsolationApi(null)).toEqual({})
    expect(resolveIsolationApi(undefined)).toEqual({})
  })
})

describe('isolationAvailable', () => {
  it('is false on a build whose preload has not wired it', () => {
    // The point of the separate bridge: this returning false costs one toggle,
    // not the whole browser panel.
    expect(isolationAvailable({})).toBe(false)
    expect(isolationAvailable({ browserIsolationKey: async () => 'k' })).toBe(true)
  })
})

describe('asIsolationKey', () => {
  it('accepts a minted key', () => {
    expect(asIsolationKey('pawl-tab-1111')).toBe('pawl-tab-1111')
  })

  it('refuses anything that would silently produce a shared tab', () => {
    // A tab labelled Isolated that is actually on the shared partition is the
    // one failure this feature must not have, so nothing dubious gets through.
    expect(asIsolationKey(null)).toBeNull()
    expect(asIsolationKey('')).toBeNull()
    expect(asIsolationKey(42)).toBeNull()
    expect(asIsolationKey('persist:pawl-browser')).toBeNull()
  })
})
