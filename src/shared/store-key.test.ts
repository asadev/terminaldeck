import { createHash, createPrivateKey, createPublicKey } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { DEV_KEY_PHRASE, liveStoreKeys, STORE_KEYS } from './store-key'

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

  it('carries the development key in the second slot, and it is the one the phrase makes', () => {
    const dev = STORE_KEYS[1]
    expect(dev).not.toBeNull()
    expect(dev?.hex).toBe(devKeyFromPhrase(DEV_KEY_PHRASE))
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
    expect(STORE_KEYS[1]?.because).toContain('never sign')
  })

  it('never lists the same key twice, which is a rotation nobody can watch', () => {
    const hexes = liveStoreKeys().map((key) => key.hex)
    expect(new Set(hexes).size).toBe(hexes.length)
  })
})
