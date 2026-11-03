import { createHash, createPrivateKey, createPublicKey } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import {
  DEV_KEY_PHRASE,
  DEV_STORE_KEY,
  liveStoreKeys,
  STORE_DEV_KEY_ENV,
  STORE_KEYS,
  storeKeysFor,
} from './store-key'

/** The 16 bytes in front of a raw Ed25519 seed that make it a PKCS#8 private key. */
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex')

/**
 * Rebuild the development key pair from the sentence its private half is made
 * of, the way the signing script has to.
 *
 * This is the guard that makes the reproducible key honest rather than a claim
 * in a comment: if the hex in `store-key.ts` and the phrase beside it ever stop
 * describing the same key, the local milestone silently stops verifying and
 * this test is the only thing that would say so.
 */
function devKeyFromPhrase(phrase: string): string {
  const seed = createHash('sha256').update(phrase, 'utf8').digest()
  const priv = createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, seed]), format: 'der', type: 'pkcs8' })
  const jwk = createPublicKey(priv).export({ format: 'jwk' }) as { x: string }
  return Buffer.from(jwk.x, 'base64url').toString('hex')
}

describe('the keys this build will believe a catalogue from', () => {
  it('has exactly two slots, so a rotation is a release and not an outage', () => {
    expect(STORE_KEYS).toHaveLength(2)
  })

  it('carries the production key in the first slot, and it is not one anybody can recompute', () => {
    const live = STORE_KEYS[0]
    expect(live).not.toBeNull()
    expect(live?.id).toBe('td-store-1')
    expect(live?.hex).toMatch(/^[0-9a-f]{64}$/)
    /* The whole point of slot one: unlike the development key, its private half
     * cannot be derived from anything printed in this repository. If these ever
     * matched, the production catalogue would be forgeable by any reader. */
    expect(live?.hex).not.toBe(devKeyFromPhrase(DEV_KEY_PHRASE))
  })

  /*
   * The slot the development key sat in until 2026-10-03, with a note on it
   * saying to delete it in the release that ships the Store. While it was
   * there, every build — the notarised one on a stranger's Mac included —
   * believed a catalogue any reader of `DEV_KEY_PHRASE` could sign.
   */
  it('leaves the second slot empty, so no build believes a key anyone can recompute', () => {
    expect(STORE_KEYS[1]).toBeNull()
    const recomputable = devKeyFromPhrase(DEV_KEY_PHRASE)
    for (const key of liveStoreKeys()) expect(key.hex).not.toBe(recomputable)
  })

  it('keeps the development key out of the slots, and it is the one the phrase makes', () => {
    expect(DEV_STORE_KEY.hex).toBe(devKeyFromPhrase(DEV_KEY_PHRASE))
    // The id the site repository's signer stamps on a preview catalogue. A key
    // is never edited in place, and that includes its name.
    expect(DEV_STORE_KEY.id).toBe('td-store-dev-1')
    expect(STORE_KEYS.some((key) => key?.hex === DEV_STORE_KEY.hex)).toBe(false)
  })

  it('writes every key as 64 lower-case hex characters, which is the raw 32 bytes', () => {
    for (const key of liveStoreKeys()) expect(key.hex).toMatch(/^[0-9a-f]{64}$/)
  })

  it('gives every key an id and a reason it may not be deleted yet', () => {
    for (const key of liveStoreKeys()) {
      expect(key.id).toMatch(/^[a-z0-9-]{3,40}$/)
      expect(key.because.split(/\s+/).length).toBeGreaterThan(12)
    }
  })

  it('says out loud that the development key must never sign a public catalogue', () => {
    expect(DEV_STORE_KEY.because).toContain('never sign')
  })

  it('never lists the same key twice, which is a rotation nobody can watch', () => {
    const hexes = liveStoreKeys().map((key) => key.hex)
    expect(new Set(hexes).size).toBe(hexes.length)
  })
})

/**
 * The one way the development key is believed.
 *
 * Every case that must refuse is a real way a run gets started: a packaged build
 * on a machine where somebody once exported the variable, a contributor's
 * checkout that never asked, a value that looks like yes and is not the switch.
 */
describe('which keys a run believes', () => {
  const dev = { [STORE_DEV_KEY_ENV]: '1' }

  it('never adds the development key to a packaged build, whatever the environment says', () => {
    expect(storeKeysFor({ env: dev, packaged: true })).toEqual(liveStoreKeys())
  })

  it('does not add it to an unpackaged run that did not ask', () => {
    expect(storeKeysFor({ env: {}, packaged: false })).toEqual(liveStoreKeys())
  })

  it('counts only the exact value 1 as asking', () => {
    for (const value of ['true', 'yes', 'on', '0', '', ' 1', '1 ']) {
      expect(storeKeysFor({ env: { [STORE_DEV_KEY_ENV]: value }, packaged: false })).toEqual(liveStoreKeys())
    }
  })

  it('adds it last for an unpackaged run that asked, so the production key still answers first', () => {
    const keys = storeKeysFor({ env: dev, packaged: false })
    expect(keys).toEqual([...liveStoreKeys(), DEV_STORE_KEY])
    expect(new Set(keys.map((key) => key.hex)).size).toBe(keys.length)
  })
})
