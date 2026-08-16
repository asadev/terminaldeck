import { describe, expect, it } from 'vitest'
import { DEVICE_KEY, DIRECT, loadDeviceIdentity, readDeviceKeys, saveDeviceKeys } from './endpoint'
import {
  CREDENTIAL_KEY,
  REMEMBERED_TTL_MS,
  clearCredential,
  clearPairing,
  describeDevice,
  loadCredential,
  loadPairing,
  renewed,
  saveCredential,
  savePairing,
  type StorageLike,
  type StoredCredential,
} from './pair'
import { generateStatic } from '../../src/shared/sealed'
import type { Stores } from './remember'

const NOW = 1_700_000_000_000

function memoryStorage(initial: Record<string, string> = {}): StorageLike & { data: Record<string, string> } {
  const data = { ...initial }
  return {
    data,
    getItem: (key) => (key in data ? data[key] : null),
    setItem: (key, value) => {
      data[key] = value
    },
    removeItem: (key) => {
      delete data[key]
    },
  }
}

function memoryStores(): Stores & { browser: ReturnType<typeof memoryStorage>; tab: ReturnType<typeof memoryStorage> } {
  return { browser: memoryStorage(), tab: memoryStorage() }
}

describe('the stored credential', () => {
  const credential: StoredCredential = {
    token: 'dev-1.c2VjcmV0',
    deviceId: 'dev-1',
    deviceName: 'iPhone',
    pairedAt: NOW,
    hostPlatform: 'windows',
    endpoint: DIRECT,
    expiresAt: NOW + REMEMBERED_TTL_MS,
  }

  it('round-trips', () => {
    const storage = memoryStorage()
    saveCredential(storage, credential)
    expect(loadCredential(storage, NOW)).toEqual(credential)
    expect(Object.keys(storage.data)).toEqual([CREDENTIAL_KEY])
  })

  it('is gone after clearing', () => {
    const storage = memoryStorage()
    saveCredential(storage, credential)
    clearCredential(storage)
    expect(loadCredential(storage, NOW)).toBeNull()
  })

  it('treats anything half-written as nothing', () => {
    // A credential without its device id cannot authenticate, and sending the
    // app to the session list holding one strands the user on a screen that
    // fails forever with no route back to pairing.
    expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: 'not json' }), NOW)).toBeNull()
    expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: '"a string"' }), NOW)).toBeNull()
    expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: '{"deviceId":"dev-1"}' }), NOW)).toBeNull()
    expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: '{"token":""}' }), NOW)).toBeNull()
    expect(loadCredential(memoryStorage(), NOW)).toBeNull()
  })

  it('fills in a name rather than showing an empty one', () => {
    const storage = memoryStorage({ [CREDENTIAL_KEY]: '{"token":"a.b","deviceId":"a"}' })
    expect(loadCredential(storage, NOW)?.deviceName).toBe('This device')
    expect(loadCredential(storage, NOW)?.pairedAt).toBe(0)
  })

  /*
   * A credential written before `hostPlatform` existed, and a credential
   * carrying nonsense in it, must both read as "I do not know what that
   * machine is" — never as a Mac.
   *
   * This is the same defect as the wire one, moved into storage: the very
   * first thing the session list paints after a relaunch is drawn from this
   * record, before any socket is up, so a wrong answer here is on screen for
   * as long as the handshake takes.
   */
  it('reads an absent or unrecognisable platform as unknown, never as a Mac', () => {
    expect(
      loadCredential(memoryStorage({ [CREDENTIAL_KEY]: '{"token":"a.b","deviceId":"a"}' }), NOW)?.hostPlatform,
    ).toBe('unknown')
    // `"darwin"` is in this list on purpose: it is the *wire* word, and nothing
    // this client writes to storage ever spells it that way. Accepting it here
    // would mean the two vocabularies had been merged again.
    for (const value of ['"darwin"', '"win32"', '"MAC"', '""', '42', 'null', 'true', '{}']) {
      const raw = `{"token":"a.b","deviceId":"a","hostPlatform":${value}}`
      expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: raw }), NOW)?.hostPlatform).toBe('unknown')
    }
  })

  it('remembers which kind of machine the credential is for', () => {
    const storage = memoryStorage()
    saveCredential(storage, { ...credential, hostPlatform: 'windows' })
    expect(loadCredential(storage, NOW)?.hostPlatform).toBe('windows')
    saveCredential(storage, { ...credential, hostPlatform: 'mac' })
    expect(loadCredential(storage, NOW)?.hostPlatform).toBe('mac')
  })

  it('reads as unpaired when storage itself refuses', () => {
    // Safari in private mode throws on access rather than returning null.
    const hostile: StorageLike = {
      getItem: () => {
        throw new Error('SecurityError')
      },
      setItem: () => {
        throw new Error('QuotaExceededError')
      },
      removeItem: () => {
        throw new Error('SecurityError')
      },
    }
    expect(loadCredential(hostile, NOW)).toBeNull()
    // And saving must not take the session down with it — the credential in
    // memory still works for as long as the app is open.
    expect(() => saveCredential(hostile, credential)).not.toThrow()
    expect(() => clearCredential(hostile)).not.toThrow()
  })
})

/*
 * A browser credential expires and a phone's does not, because a browser
 * credential is the one that gets left behind on a computer somebody borrowed.
 * See REMEMBERED_TTL_MS.
 */
describe('how long a remembered pairing lasts', () => {
  const credential: StoredCredential = {
    token: 'dev-1.c2VjcmV0',
    deviceId: 'dev-1',
    deviceName: 'Chrome on Windows',
    pairedAt: NOW,
    hostPlatform: 'windows',
    endpoint: DIRECT,
    expiresAt: NOW + REMEMBERED_TTL_MS,
  }

  it('reads back while it is alive', () => {
    const storage = memoryStorage()
    saveCredential(storage, credential)
    expect(loadCredential(storage, NOW + REMEMBERED_TTL_MS - 1)?.token).toBe(credential.token)
  })

  it('is gone the moment it expires, and is removed rather than just refused', () => {
    // Refusing without deleting would leave a dead secret in the profile of a
    // machine that may not be this person's, for as long as the profile lasts.
    // The expiry exists precisely for that machine.
    const storage = memoryStorage()
    saveCredential(storage, credential)
    expect(loadCredential(storage, NOW + REMEMBERED_TTL_MS)).toBeNull()
    expect(storage.data[CREDENTIAL_KEY]).toBeUndefined()
  })

  it('starts the clock at the upgrade for a credential written before it existed', () => {
    /*
     * The trap this avoids: `pairedAt` defaults to 0 for credentials from builds
     * older still, so deriving the expiry from it would land in 1970 and unpair
     * every existing browser on the launch that introduced the field.
     */
    const storage = memoryStorage({ [CREDENTIAL_KEY]: '{"token":"a.b","deviceId":"a"}' })
    expect(loadCredential(storage, NOW)?.expiresAt).toBe(NOW + REMEMBERED_TTL_MS)
  })

  it('slides forward on a welcome, so a browser in use is never signed out', () => {
    const later = NOW + 20 * 86_400_000
    expect(renewed(credential, later).expiresAt).toBe(later + REMEMBERED_TTL_MS)
    // Everything else about it is untouched: this renews a pairing, it does not
    // make a new one.
    expect(renewed(credential, later).pairedAt).toBe(NOW)
    expect(renewed(credential, later).token).toBe(credential.token)
  })
})

/*
 * The rule: exactly one store ever holds a pairing, and the credential and this
 * browser's key are always in the same one. Anything else leaves half a pairing
 * on a computer whose owner asked us to leave nothing.
 */
describe('which store a pairing goes in', () => {
  const credential: StoredCredential = {
    token: 'dev-1.c2VjcmV0',
    deviceId: 'dev-1',
    deviceName: 'Chrome on Windows',
    pairedAt: NOW,
    hostPlatform: 'windows',
    endpoint: DIRECT,
    expiresAt: NOW + REMEMBERED_TTL_MS,
  }
  const keys = generateStatic()

  it('puts a remembered pairing where it survives the tab, and says so on the way back', () => {
    const stores = memoryStores()
    savePairing(stores, 'this-browser', credential, keys)
    expect(Object.keys(stores.browser.data).sort()).toEqual([CREDENTIAL_KEY, DEVICE_KEY].sort())
    expect(Object.keys(stores.tab.data)).toEqual([])
    expect(loadPairing(stores, NOW)).toEqual({ credential, remember: 'this-browser' })
  })

  it('puts a "just for this visit" pairing where the tab takes it with it', () => {
    const stores = memoryStores()
    savePairing(stores, 'this-tab', credential, keys)
    expect(Object.keys(stores.tab.data).sort()).toEqual([CREDENTIAL_KEY, DEVICE_KEY].sort())
    expect(Object.keys(stores.browser.data)).toEqual([])
    expect(loadPairing(stores, NOW)?.remember).toBe('this-tab')
  })

  it('clears the other store, so answering "just for this visit" leaves nothing durable', () => {
    // The failure this is for: somebody who had remembered this browser pairs
    // again and answers "not this time". The durable copy is the one they cannot
    // see, and the tab's copy is the one the client would be using — so without
    // the clear, the change would look like it worked and would not have.
    const stores = memoryStores()
    savePairing(stores, 'this-browser', credential, keys)
    savePairing(stores, 'this-tab', credential, keys)
    expect(Object.keys(stores.browser.data)).toEqual([])
    expect(loadPairing(stores, NOW)?.remember).toBe('this-tab')
  })

  it('forgets in both, because half a pairing left behind is the whole problem', () => {
    const stores = memoryStores()
    savePairing(stores, 'this-browser', credential, keys)
    stores.tab.setItem(CREDENTIAL_KEY, '{"token":"x.y","deviceId":"x"}')
    clearPairing(stores)
    expect(Object.keys(stores.browser.data)).toEqual([])
    expect(Object.keys(stores.tab.data)).toEqual([])
    expect(loadPairing(stores, NOW)).toBeNull()
  })

  it('never separates the credential from the key that has to accompany it', () => {
    // A credential the machine accepts and a key it does not is a device that
    // pairs and is then refused by its own next handshake, and a key left in
    // `localStorage` beside a tab-only credential is a durable identifier for
    // this app on a computer that is not this person's.
    const stores = memoryStores()
    savePairing(stores, 'this-browser', credential, keys)
    expect(readDeviceKeys(stores.browser)?.publicKey).toEqual(keys.publicKey)
    savePairing(stores, 'this-tab', credential, keys)
    expect(readDeviceKeys(stores.browser)).toBeNull()
    expect(readDeviceKeys(stores.tab)?.publicKey).toEqual(keys.publicKey)
  })

  it('makes an identity in memory rather than writing one just for opening the page', () => {
    // Visiting this client on a borrowed computer must leave nothing at all. The
    // key reaches a store at the same moment the credential does and never
    // before it.
    const stores = memoryStores()
    const identity = loadDeviceIdentity(stores)
    expect(identity.publicKey).toHaveLength(32)
    expect(Object.keys(stores.browser.data)).toEqual([])
    expect(Object.keys(stores.tab.data)).toEqual([])
  })

  it('keeps using the identity it already has, in whichever store holds it', () => {
    const stores = memoryStores()
    saveDeviceKeys(stores.tab, keys)
    expect(loadDeviceIdentity(stores).publicKey).toEqual(keys.publicKey)
  })

  it('lets the tab’s answer win over anything durable beside it', () => {
    // Not a preference. The tab holds the most recent decision somebody made,
    // and it is the one that has to be honoured if the two ever disagree.
    const stores = memoryStores()
    saveCredential(stores.browser, { ...credential, deviceId: 'old' })
    saveCredential(stores.tab, { ...credential, deviceId: 'new' })
    expect(loadPairing(stores, NOW)?.credential.deviceId).toBe('new')
  })

  it('falls through to the durable store when the tab has expired out from under it', () => {
    const stores = memoryStores()
    saveCredential(stores.tab, { ...credential, deviceId: 'stale', expiresAt: NOW - 1 })
    saveCredential(stores.browser, { ...credential, deviceId: 'live' })
    expect(loadPairing(stores, NOW)?.credential.deviceId).toBe('live')
  })
})

/*
 * The name this client sends is the only thing the desktop's device list can
 * show about it, and that list is the only place a browser pairing can be found
 * and killed. A row that reads like the native app on that machine makes Revoke
 * a button nobody can aim.
 *
 * Real user-agent strings throughout, because every one of these products lies
 * about the others and the order of the checks is the whole implementation.
 */
describe('naming this browser for the desktop’s device list', () => {
  const chromeWindows =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
  const edgeWindows = `${chromeWindows} Edg/140.0.0.0`
  const safariMac =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'
  const firefoxLinux = 'Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0'
  const safariIphone =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'
  const chromeAndroid =
    'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36'

  it('says the browser and the computer, which is what somebody scans the list for', () => {
    expect(describeDevice(chromeWindows)).toEqual({ name: 'Chrome on Windows', platform: 'Windows' })
    expect(describeDevice(safariMac).name).toBe('Safari on Mac')
    expect(describeDevice(firefoxLinux).name).toBe('Firefox on Linux')
    expect(describeDevice(safariIphone).name).toBe('Safari on iPhone')
    expect(describeDevice(chromeAndroid).name).toBe('Chrome on Android')
  })

  it('is never the same string the app on that machine would send', () => {
    // The defect: this used to answer "Windows PC" and "Mac", so a pairing in a
    // browser on a borrowed laptop sat in the device list looking exactly like
    // the trusted desktop install.
    expect(describeDevice(chromeWindows).name).not.toBe('Windows PC')
    expect(describeDevice(safariMac).name).not.toBe('Mac')
  })

  it('does not let Chrome answer for the browsers that impersonate it', () => {
    // Edge sends Chrome *and* Safari; Opera sends both as well; Samsung Internet
    // sends Chrome. Every one of these is a row somebody has to recognise.
    expect(describeDevice(edgeWindows).name).toBe('Edge on Windows')
    expect(describeDevice(`${chromeWindows} OPR/114.0.0.0`).name).toBe('Opera on Windows')
    expect(describeDevice(chromeAndroid.replace('Chrome/', 'SamsungBrowser/26.0 Chrome/')).name).toBe(
      'Samsung Internet on Android',
    )
  })

  it('names the iOS browsers by what they are, not by the engine they are forced to use', () => {
    // Every browser on iOS is WebKit and says Safari. The vendor prefix is the
    // only thing that tells them apart, and a person looking for "the Chrome I
    // opened on my iPad" needs it.
    expect(describeDevice(`${safariIphone} CriOS/140.0.0.0`).name).toBe('Chrome on iPhone')
    expect(describeDevice(`${safariIphone} FxiOS/131.0`).name).toBe('Firefox on iPhone')
    expect(describeDevice(safariIphone.replace('iPhone;', 'iPad;').replace('iPhone OS', 'OS')).name).toBe(
      'Safari on iPad',
    )
  })

  it('falls back to something honest rather than guessing', () => {
    expect(describeDevice('')).toEqual({ name: 'Browser', platform: 'unknown' })
    // Half an answer is still better than none: "Browser on Windows" is a row
    // somebody can act on, and it never claims to be the app.
    expect(describeDevice('Mozilla/5.0 (Windows NT 10.0)').name).toBe('Browser on Windows')
  })
})
