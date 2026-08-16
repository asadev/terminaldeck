import { describe, expect, it } from 'vitest'
import { hostIdFor, isHostId } from '../../../shared/relay-wire'
import { generateStatic, respondToHandshake, startHandshake, SealedRefusal } from '../../../shared/sealed'
import {
  RENDEZVOUS_SALT,
  encodeOffer,
  offerFrom,
  parseOffer,
  rendezvousIdentity,
  type MachineOffer,
} from './rendezvous'

/**
 * The derivation both machines have to agree on, and the frame that rides it.
 *
 * The channel itself is exercised for real in `live.test.ts` against a real
 * relay. What is here is the arithmetic underneath it: two machines given the
 * same code must land on the same slot *and* the same responder key, and two
 * machines given different codes must not.
 */

const OFFER: MachineOffer = {
  relayUrl: 'wss://relay.example',
  hostId: hostIdFor(Buffer.alloc(32, 5)),
  publicKey: generateStatic().publicKey.toString('base64'),
  name: 'Studio PC',
  platform: 'win32',
}

/**
 * The derivation, as bytes, shared with every other client that has to find the
 * same slot.
 *
 * These are copied from `pwa/src/rendezvous.test.ts`, character for character,
 * and that duplication is the whole point. The browser client cannot import the
 * module above — it reaches for `node:crypto` — so it restates the salt and the
 * scrypt parameters in its own file, and two restatements of one derivation
 * drift silently: nothing throws, nothing logs, and two machines simply stop
 * being able to find each other because they are deriving different slots from
 * the same six digits.
 *
 * Pinning the *output* rather than only the salt is deliberate. It catches a
 * changed salt, a changed cost parameter, a changed seed length and a changed
 * split between the slot secret and the responder key — every input to the
 * agreement, in one assertion, on both sides.
 */
const VECTORS = [
  {
    code: '482913',
    hostId: 'PNN7FEFPVPEPG8J6JD5LTK22CW',
    publicKey: 'PluJUUCYOIi9dWOnMK0Sq8NrO635DqyD0yTLIyeLlAU=',
  },
  {
    // The leading-zero case, pinned on purpose. A code is six *digits*, not a
    // number: anything that parses `000000` as an integer on the way to the
    // derivation lands on `0` and derives a different slot from every other
    // client, which reads on screen as a code that was typed correctly and
    // found nothing.
    code: '000000',
    hostId: 'ESVP7D6GDHN28MLNU5AEGRGGC7',
    publicKey: 'AFF3srTJviOR9zEbStt+iPZuTjl1Gp595oLklTIfLgc=',
  },
  {
    code: '999999',
    hostId: 'UAFTGU2WS5MN5GYUKF48KJG5SK',
    publicKey: 'bleS0Mpc5kqiW5FJ7wNs6uardUbhJgcrjUN583t7Zx4=',
  },
] as const

describe('the derivation every client has to agree on', () => {
  it('is pinned to the salt the browser client restates', () => {
    // One line, and it is the line that turns a silent disagreement into a red
    // test. `pwa/src/rendezvous.test.ts` asserts the same literal from its side.
    expect(RENDEZVOUS_SALT).toBe('terminaldeck-machine-pairing-v1')
  })

  it('produces the same slot and responder key the browser client produces', () => {
    for (const vector of VECTORS) {
      const identity = rendezvousIdentity(vector.code)
      expect(identity?.hostId).toBe(vector.hostId)
      expect(identity?.keys.publicKey.toString('base64')).toBe(vector.publicKey)
    }
  }, 20_000)
})

describe('deriving a rendezvous from a code', () => {
  it('lands two machines on the same slot and the same key', () => {
    const first = rendezvousIdentity('482913')
    const second = rendezvousIdentity('482913')
    expect(first).not.toBeNull()
    expect(second).not.toBeNull()
    expect(first?.hostId).toBe(second?.hostId)
    expect(first?.keys.publicKey.equals(second?.keys.publicKey ?? Buffer.alloc(0))).toBe(true)
    expect(first?.keys.privateKey.equals(second?.keys.privateKey ?? Buffer.alloc(0))).toBe(true)
  })

  it('does not care how the code was typed', () => {
    // The person reading it off the other screen types what their keyboard
    // gives them. All of these are the same code.
    const canonical = rendezvousIdentity('482913')?.hostId
    expect(rendezvousIdentity('482-913')?.hostId).toBe(canonical)
    expect(rendezvousIdentity('  482 913  ')?.hostId).toBe(canonical)
  })

  it('lands two different codes somewhere else entirely', () => {
    expect(rendezvousIdentity('482913')?.hostId).not.toBe(rendezvousIdentity('482914')?.hostId)
  })

  it('produces a slot the relay will route on, and a real key pair', () => {
    const identity = rendezvousIdentity('999999')
    expect(identity).not.toBeNull()
    expect(isHostId(identity?.hostId ?? '')).toBe(true)
    expect(identity?.hostSecret).toHaveLength(32)
    expect(identity?.keys.publicKey).toHaveLength(32)
    expect(identity?.fingerprint).toMatch(/^[A-Z2-9]{4}(-[A-Z2-9]{4}){5}$/)
  })

  it('refuses anything that is not a code', () => {
    expect(rendezvousIdentity('nope')).toBeNull()
    expect(rendezvousIdentity('')).toBeNull()
    // Five digits, seven digits, and the old eight-character shape — all of
    // them refused rather than hashed into a slot nobody else derives.
    expect(rendezvousIdentity('48291')).toBeNull()
    expect(rendezvousIdentity('4829131')).toBeNull()
    expect(rendezvousIdentity('H4K9-2FQT')).toBeNull()
  })

  it('is the whole gate: a handshake against the wrong code fails to authenticate', () => {
    /*
     * The security argument for the rendezvous, as an assertion rather than a
     * paragraph. A relay that wants to answer for the far machine has to
     * complete `es` against the responder key, and that key comes from the code.
     * With the wrong code it holds the wrong private half and the initiator's
     * static never opens.
     */
    const right = rendezvousIdentity('482913')
    const wrong = rendezvousIdentity('482914')
    expect(right).not.toBeNull()
    expect(wrong).not.toBeNull()
    if (right === null || wrong === null) return

    const guest = generateStatic()
    const message = startHandshake(guest, right.keys.publicKey).message
    // The honest machine, holding the code, answers it.
    expect(() => respondToHandshake(right.keys, message, () => true)).not.toThrow()
    // Anybody else does not.
    expect(() => respondToHandshake(wrong.keys, message, () => true)).toThrow(SealedRefusal)
  })
})

describe('the offer frame', () => {
  it('round-trips', () => {
    expect(parseOffer(encodeOffer(OFFER))).toEqual(OFFER)
  })

  it('refuses an address that cannot be dialled', () => {
    // Null rather than a best effort: what comes out of here is dialled and then
    // handed a pairing code, so a half-read address is a code typed at the wrong
    // machine.
    expect(parseOffer(encodeOffer({ ...OFFER, hostId: 'too-short' }))).toBeNull()
    expect(parseOffer(encodeOffer({ ...OFFER, relayUrl: 'https://relay.example' }))).toBeNull()
    expect(parseOffer(encodeOffer({ ...OFFER, publicKey: 'not-a-key' }))).toBeNull()
  })

  it('refuses anything that is not one of these frames', () => {
    expect(parseOffer('not json')).toBeNull()
    expect(parseOffer(JSON.stringify({ t: 'welcome' }))).toBeNull()
    expect(parseOffer(JSON.stringify([1, 2, 3]))).toBeNull()
    expect(parseOffer(42)).toBeNull()
    expect(parseOffer('x'.repeat(5000))).toBeNull()
  })

  it('is built from the relay link, or not at all', () => {
    const key = generateStatic().publicKey
    const relay = {
      url: 'wss://relay.example',
      hostId: hostIdFor(Buffer.alloc(32, 7)),
      publicKey: key.toString('base64url'),
      fingerprint: 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF',
      connected: true,
      channels: 0,
      reason: null,
      retryAt: null,
    }
    const offer = offerFrom(relay)
    if (offer === null) throw new Error('a connected relay has an address to publish')
    expect(offer.hostId).toBe(relay.hostId)
    expect(offer.relayUrl).toBe(relay.url)
    // Re-encoded, not passed through: `RelayState` publishes base64url because
    // it goes into a URL, and `parseOffer` on the other end decodes plain
    // base64. The round trip through the parser is the assertion that matters,
    // because the two spellings differ only for some keys.
    expect(parseOffer(encodeOffer(offer))?.publicKey).toBe(key.toString('base64'))
    expect(offer.name).not.toBe('')

    // Nothing to publish is null rather than a half-filled offer: a slot
    // answering with an empty host id is a machine advertising an address that
    // routes nowhere.
    expect(offerFrom(null)).toBeNull()
    expect(offerFrom({ ...relay, connected: false })).toBeNull()
    expect(offerFrom({ ...relay, hostId: '' })).toBeNull()
    expect(offerFrom({ ...relay, publicKey: '' })).toBeNull()
  })

  it('keeps a machine whose label is missing, and strips one that is an escape sequence', () => {
    // The name is a label, so its absence is not a reason to refuse a machine —
    // and it is rendered next to terminal output, so a control character in it
    // is an injection rather than a name.
    expect(parseOffer(encodeOffer({ ...OFFER, name: '' }))?.name).toBe('')
    expect(parseOffer(encodeOffer({ ...OFFER, name: '[31mred' }))?.name).toBe('[31mred')
  })
})
