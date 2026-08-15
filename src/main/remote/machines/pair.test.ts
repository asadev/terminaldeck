import { describe, expect, it } from 'vitest'
import { hostIdFor } from '../../../shared/relay-wire'
import { generateStatic } from '../../../shared/sealed'
import { serialize } from '../protocol'
import type { DialRequest, GuestChannel } from './dial'
import { pairWithCode } from './pair'
import { encodeOffer, rendezvousIdentity, type MachineOffer } from './rendezvous'

/**
 * The two dials pairing makes, and what each of them is allowed to conclude.
 *
 * The real thing runs against a real relay in `live.test.ts`. Isolated here are
 * the answers a live test cannot easily produce: a machine that hangs up
 * part-way, a code the far end has already spent, and a `welcome` with no
 * credential in it — the last of which no build of `server.ts` sends and which
 * would leave a machine stored with nothing to reconnect with.
 */

const OFFER: MachineOffer = {
  relayUrl: 'wss://relay.example',
  hostId: hostIdFor(Buffer.alloc(32, 4)),
  publicKey: generateStatic().publicKey.toString('base64'),
  name: 'Studio PC',
  platform: 'win32',
}

const CODE = 'H4K9-2FQT'

type Script = (request: DialRequest) => 'offer' | 'welcome' | 'refuse' | 'hang-up' | 'no-credential'

/**
 * A dial that answers according to which host id it was pointed at.
 *
 * Routing on the host id rather than on call order is deliberate: it is the same
 * thing the relay does, and it is what makes "the lookup went to the rendezvous
 * and the pairing went to the machine it named" a fact the test can assert
 * rather than an ordering it assumes.
 */
function dialler(script: Script): {
  dial: (request: DialRequest) => Promise<GuestChannel>
  seen: string[]
  sent: string[]
} {
  const seen: string[] = []
  const sent: string[] = []
  return {
    seen,
    sent,
    dial(request: DialRequest): Promise<GuestChannel> {
      seen.push(request.hostId)
      const answer = script(request)
      let open = true
      const channel: GuestChannel = {
        send: (text) => {
          sent.push(text)
        },
        close: () => {
          open = false
        },
        get open(): boolean {
          return open
        },
      }
      // Answered a tick later, the way a real one is: the dial resolves on the
      // handshake and the first frame arrives after it.
      setTimeout(() => {
        if (answer === 'offer') request.handlers.message(encodeOffer(OFFER))
        else if (answer === 'welcome') {
          request.handlers.message(
            serialize({
              t: 'welcome',
              protocol: 1,
              deviceId: 'device-9',
              deviceName: 'This Mac',
              token: 'device9.secret',
              sessions: [],
              capabilities: [],
            }),
          )
        } else if (answer === 'no-credential') {
          request.handlers.message(
            serialize({
              t: 'welcome',
              protocol: 1,
              deviceId: 'device-9',
              deviceName: 'This Mac',
              token: null,
              sessions: [],
              capabilities: [],
            }),
          )
        } else if (answer === 'refuse') {
          request.handlers.message(
            serialize({
              t: 'error',
              code: 'unauthorized',
              message: 'That pairing code has already been used or has expired.',
            }),
          )
        } else {
          open = false
          request.handlers.closed('That machine closed the connection.')
        }
      }, 0)
      return Promise.resolve(channel)
    },
  }
}

describe('pairing with a typed code', () => {
  it('looks the machine up at the code’s rendezvous, then pairs with the machine it named', async () => {
    const rig = dialler((request) =>
      request.hostId === rendezvousIdentity(CODE)?.hostId ? 'offer' : 'welcome',
    )
    const result = await pairWithCode({ code: CODE, relayUrl: 'wss://relay.example', dial: rig.dial })

    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.credential).toBe('device9.secret')
    expect(result.offer).toEqual(OFFER)
    // Two dials, to two different places, in that order.
    expect(rig.seen).toEqual([rendezvousIdentity(CODE)?.hostId, OFFER.hostId])
    // And the second one presented the code, not the credential it does not
    // have yet.
    const hello: unknown = JSON.parse(rig.sent[0])
    expect(hello).toMatchObject({ t: 'hello', protocol: 1, token: CODE })
  })

  it('normalises the code before it derives anything or sends it', async () => {
    const rig = dialler((request) =>
      request.hostId === rendezvousIdentity(CODE)?.hostId ? 'offer' : 'welcome',
    )
    const result = await pairWithCode({
      code: '  h4k9 2fqt ',
      relayUrl: 'wss://relay.example',
      dial: rig.dial,
    })
    expect(result.ok).toBe(true)
    // The far end hashed the canonical form when it minted the code, so this is
    // the only spelling that can match.
    expect(JSON.parse(rig.sent[0])).toMatchObject({ token: CODE })
  })

  it('refuses a string that is not a code without dialling anything', async () => {
    const rig = dialler(() => 'offer')
    const result = await pairWithCode({ code: 'nope', relayUrl: 'wss://relay.example', dial: rig.dial })
    expect(result).toMatchObject({ ok: false, reason: 'bad-code' })
    expect(rig.seen).toEqual([])
  })

  it('says nobody is showing that code when the rendezvous is empty', async () => {
    const rig = dialler(() => 'hang-up')
    const result = await pairWithCode({
      code: CODE,
      relayUrl: 'wss://relay.example',
      dial: rig.dial,
      lookupTimeoutMs: 200,
    })
    expect(result).toMatchObject({ ok: false, reason: 'not-found' })
    expect(result.ok === false && result.message).toMatch(/last a minute/)
  })

  it('passes the far machine’s refusal through in its own words', async () => {
    const rig = dialler((request) =>
      request.hostId === rendezvousIdentity(CODE)?.hostId ? 'offer' : 'refuse',
    )
    const result = await pairWithCode({ code: CODE, relayUrl: 'wss://relay.example', dial: rig.dial })
    expect(result).toEqual({
      ok: false,
      reason: 'refused',
      message: 'That pairing code has already been used or has expired.',
    })
  })

  it('refuses a welcome with no credential rather than storing a machine it cannot come back to', async () => {
    const rig = dialler((request) =>
      request.hostId === rendezvousIdentity(CODE)?.hostId ? 'offer' : 'no-credential',
    )
    const result = await pairWithCode({ code: CODE, relayUrl: 'wss://relay.example', dial: rig.dial })
    expect(result).toMatchObject({ ok: false, reason: 'refused' })
  })

  it('reports a machine that hangs up part-way through', async () => {
    const rig = dialler((request) =>
      request.hostId === rendezvousIdentity(CODE)?.hostId ? 'offer' : 'hang-up',
    )
    const result = await pairWithCode({ code: CODE, relayUrl: 'wss://relay.example', dial: rig.dial })
    expect(result).toMatchObject({ ok: false, reason: 'unreachable' })
  })

  it('mints a guest identity per pairing and hands it back for the store', async () => {
    const rig = dialler((request) =>
      request.hostId === rendezvousIdentity(CODE)?.hostId ? 'offer' : 'welcome',
    )
    const first = await pairWithCode({ code: CODE, relayUrl: 'wss://relay.example', dial: rig.dial })
    const second = await pairWithCode({ code: CODE, relayUrl: 'wss://relay.example', dial: rig.dial })
    expect(first.ok && second.ok).toBe(true)
    if (!first.ok || !second.ok) return
    // One key per machine, never one key for every machine — see `store.ts`.
    expect(first.guestKeys.privateKey.equals(second.guestKeys.privateKey)).toBe(false)
  })
})
