import { describe, expect, it } from 'vitest'
import { hostIdFor, isHostId } from '../../../shared/relay-wire'
import { generateStatic, respondToHandshake, startHandshake, SealedRefusal } from '../../../shared/sealed'
import { encodeOffer, parseOffer, rendezvousIdentity, type MachineOffer } from './rendezvous'

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

describe('deriving a rendezvous from a code', () => {
  it('lands two machines on the same slot and the same key', () => {
    const first = rendezvousIdentity('H4K9-2FQT')
    const second = rendezvousIdentity('H4K9-2FQT')
    expect(first).not.toBeNull()
    expect(second).not.toBeNull()
    expect(first?.hostId).toBe(second?.hostId)
    expect(first?.keys.publicKey.equals(second?.keys.publicKey ?? Buffer.alloc(0))).toBe(true)
    expect(first?.keys.privateKey.equals(second?.keys.privateKey ?? Buffer.alloc(0))).toBe(true)
  })

  it('does not care how the code was typed', () => {
    // The person reading it off the other screen types what their keyboard
    // gives them. All of these are the same code.
    const canonical = rendezvousIdentity('H4K9-2FQT')?.hostId
    expect(rendezvousIdentity('h4k92fqt')?.hostId).toBe(canonical)
    expect(rendezvousIdentity('  H4K9 2FQT  ')?.hostId).toBe(canonical)
  })

  it('lands two different codes somewhere else entirely', () => {
    expect(rendezvousIdentity('H4K9-2FQT')?.hostId).not.toBe(rendezvousIdentity('H4K9-2FQV')?.hostId)
  })

  it('produces a slot the relay will route on, and a real key pair', () => {
    const identity = rendezvousIdentity('ZZZZ-ZZZZ')
    expect(identity).not.toBeNull()
    expect(isHostId(identity?.hostId ?? '')).toBe(true)
    expect(identity?.hostSecret).toHaveLength(32)
    expect(identity?.keys.publicKey).toHaveLength(32)
    expect(identity?.fingerprint).toMatch(/^[A-Z2-9]{4}(-[A-Z2-9]{4}){5}$/)
  })

  it('refuses anything that is not a code', () => {
    expect(rendezvousIdentity('nope')).toBeNull()
    expect(rendezvousIdentity('')).toBeNull()
    expect(rendezvousIdentity('UUUU-UUUU')).toBeNull()
  })

  it('is the whole gate: a handshake against the wrong code fails to authenticate', () => {
    /*
     * The security argument for the rendezvous, as an assertion rather than a
     * paragraph. A relay that wants to answer for the far machine has to
     * complete `es` against the responder key, and that key comes from the code.
     * With the wrong code it holds the wrong private half and the initiator's
     * static never opens.
     */
    const right = rendezvousIdentity('H4K9-2FQT')
    const wrong = rendezvousIdentity('H4K9-2FQV')
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

  it('keeps a machine whose label is missing, and strips one that is an escape sequence', () => {
    // The name is a label, so its absence is not a reason to refuse a machine —
    // and it is rendered next to terminal output, so a control character in it
    // is an injection rather than a name.
    expect(parseOffer(encodeOffer({ ...OFFER, name: '' }))?.name).toBe('')
    expect(parseOffer(encodeOffer({ ...OFFER, name: '[31mred' }))?.name).toBe('[31mred')
  })
})
