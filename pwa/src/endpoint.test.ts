/**
 * Where this browser is pointed, and the identity it keeps.
 *
 * Two things are being defended here and both are migrations rather than
 * features. A browser paired before the relay existed has a credential and no
 * endpoint, and must keep working exactly as it did — so an absent endpoint is
 * the direct route rather than an error. And a browser paired *through* the
 * relay must present the same X25519 key on every reconnect, because
 * `isKnownDevice` on the machine matches it, so a client that generated a fresh
 * one per socket would pair successfully and be refused by its own next attempt.
 */

import { describe, expect, it } from 'vitest'
import {
  asEndpoint,
  clearDeviceKeys,
  DEVICE_KEY,
  DIRECT,
  hostKeyBytes,
  loadDeviceIdentity,
  readDeviceKeys,
  saveDeviceKeys,
} from './endpoint'
import type { StorageLike } from './endpoint'
import { generateStatic } from '../../src/shared/sealed'

const HOST_ID = 'ZWG39KXXW8GKVHZP6UF2SGUARD'
/** 32 bytes as base64url, the way a pairing link carries them. */
const LINK_KEY = 'aQPhyoFeCJkVcrnoSvne9Eft2vkXQrmYitfzy2JowX8'
/** The same 32 bytes as standard base64, the way an offer carries them. */
const OFFER_KEY = 'NinFdauDs0+5UobA6Txvq2rhXZiyD1c4676VktxUN0A='

function memory(initial: Record<string, string> = {}): StorageLike & { data: Record<string, string> } {
  const data = { ...initial }
  return {
    data,
    getItem: (key) => data[key] ?? null,
    setItem: (key, value) => {
      data[key] = value
    },
    removeItem: (key) => {
      delete data[key]
    },
  }
}

/** Storage that throws, which is Safari in private mode rather than a fiction. */
function hostile(): StorageLike {
  return {
    getItem: () => {
      throw new Error('denied')
    },
    setItem: () => {
      throw new Error('denied')
    },
    removeItem: () => {
      throw new Error('denied')
    },
  }
}

describe('reading an endpoint back', () => {
  it('reads a relay endpoint whole', () => {
    expect(asEndpoint({ kind: 'relay', url: 'wss://relay.terminaldeck.dev', hostId: HOST_ID, hostKey: LINK_KEY })).toEqual(
      { kind: 'relay', url: 'wss://relay.terminaldeck.dev', hostId: HOST_ID, hostKey: LINK_KEY },
    )
  })

  it('treats a missing endpoint as the direct route', () => {
    // The migration. Every browser paired before this field existed was talking
    // to the address it was served from, and making it pair again to introduce a
    // field would be an absurd trade.
    expect(asEndpoint(undefined)).toEqual(DIRECT)
    expect(asEndpoint(null)).toEqual(DIRECT)
    expect(asEndpoint({ kind: 'direct' })).toEqual(DIRECT)
  })

  it('treats a half-written relay endpoint as direct rather than as a relay', () => {
    // Not "as much of it as parses". A relay endpoint missing its key is one
    // that would pair against whoever answered.
    const whole = { kind: 'relay', url: 'wss://relay.terminaldeck.dev', hostId: HOST_ID, hostKey: LINK_KEY }
    expect(asEndpoint({ ...whole, hostKey: undefined })).toEqual(DIRECT)
    expect(asEndpoint({ ...whole, hostKey: 'AAAA' })).toEqual(DIRECT)
    expect(asEndpoint({ ...whole, hostId: 'too-short' })).toEqual(DIRECT)
    expect(asEndpoint({ ...whole, url: 'https://relay.terminaldeck.dev' })).toEqual(DIRECT)
    expect(asEndpoint([whole])).toEqual(DIRECT)
  })
})

describe('the host key, in both alphabets it arrives in', () => {
  it('decodes the base64url a link carries', () => {
    expect(hostKeyBytes(LINK_KEY)?.length).toBe(32)
  })

  it('decodes the standard base64 an offer carries', () => {
    // Standard base64 of 32 random bytes contains a `+` or a `/` most of the
    // time, and the browser `Buffer` behind this client silently drops `-` and
    // `_` rather than refusing them — so handling one alphabet and not the other
    // is a pairing route that fails at random.
    expect(hostKeyBytes(OFFER_KEY)?.length).toBe(32)
  })

  it('refuses anything that is not 32 bytes', () => {
    expect(hostKeyBytes('')).toBeNull()
    expect(hostKeyBytes('AAAA')).toBeNull()
    expect(hostKeyBytes(`${LINK_KEY}AAAA`)).toBeNull()
  })
})

describe('this browser’s own identity', () => {
  it('reads back the same key every time, because the machine matches it', () => {
    // A fresh one per socket would pair and then be refused by the next attempt.
    const storage = memory()
    const made = loadDeviceIdentity({ browser: storage, tab: memory() })
    saveDeviceKeys(storage, made)
    const read = readDeviceKeys(storage)
    expect(read?.privateKey.toString('base64')).toBe(made.privateKey.toString('base64'))
    expect(read?.publicKey.toString('base64')).toBe(made.publicKey.toString('base64'))
  })

  it('derives the public half rather than storing it', () => {
    // Two fields that must agree are two fields that can disagree. Only the
    // private key is written, so there is nothing to fall out of step with it.
    const storage = memory()
    const keys = loadDeviceIdentity({ browser: storage, tab: memory() })
    saveDeviceKeys(storage, keys)
    expect(Object.keys(storage.data)).toEqual([DEVICE_KEY])
    expect(storage.data[DEVICE_KEY]).toBe(keys.privateKey.toString('base64'))
  })

  it('writes nothing merely because somebody opened the page', () => {
    /*
     * This is the change, and it is the reason `loadDeviceKeys` was split in
     * two. The old function generated *and persisted* on first use, so simply
     * visiting this client on a computer somebody had borrowed left a durable
     * identifier for this app in its `localStorage` — before anyone had paired,
     * and whatever they were about to answer about being remembered.
     *
     * The key is written by `savePairing`, at the same moment as the credential
     * and into the same store. Until then it exists only in memory.
     */
    const browser = memory()
    const tab = memory()
    expect(loadDeviceIdentity({ browser, tab }).privateKey.length).toBe(32)
    expect(Object.keys(browser.data)).toEqual([])
    expect(Object.keys(tab.data)).toEqual([])
  })

  it('takes the identity from whichever store has one, tab first', () => {
    const browser = memory()
    const tab = memory()
    const durable = loadDeviceIdentity({ browser, tab })
    saveDeviceKeys(browser, durable)
    expect(loadDeviceIdentity({ browser, tab }).publicKey.toString('base64')).toBe(
      durable.publicKey.toString('base64'),
    )
    // A key in the tab is this tab's decision and wins, for the same reason the
    // credential beside it does.
    const perTab = loadDeviceIdentity({ browser: memory(), tab: memory() })
    saveDeviceKeys(tab, perTab)
    expect(loadDeviceIdentity({ browser, tab }).publicKey.toString('base64')).toBe(
      perTab.publicKey.toString('base64'),
    )
  })

  it('replaces a stored value that cannot be a key', () => {
    const storage = memory({ [DEVICE_KEY]: 'not-a-key' })
    expect(readDeviceKeys(storage)).toBeNull()
    expect(loadDeviceIdentity({ browser: storage, tab: memory() }).privateKey.length).toBe(32)
  })

  it('still starts when storage refuses to answer', () => {
    // Safari in private mode throws rather than returning null. The consequence
    // is a machine that will not recognise this browser and says so; refusing to
    // start would leave somebody unable to reach the screen that fixes it.
    expect(loadDeviceIdentity({ browser: hostile(), tab: hostile() }).privateKey.length).toBe(32)
    expect(() => saveDeviceKeys(hostile(), generateStatic())).not.toThrow()
    expect(() => clearDeviceKeys(hostile())).not.toThrow()
  })
})
