/**
 * The browser's end of a sealed channel, against the responder a real machine
 * runs.
 *
 * Nothing here is a stand-in for the crypto. The far side is
 * `respondToHandshake` from `src/shared/sealed.ts` — the same function
 * `relay-client.ts` calls when a phone arrives — and the frames are opened and
 * produced by the same `SealedTransport` a desktop holds. A test that answered
 * with a hand-made buffer would pass against a client that cannot complete one
 * real connection, which is the specific way this project has been fooled before.
 *
 * What is faked is the relay, and only the relay: a socket that hands bytes to a
 * responder sitting in the same process. That is the part with no bugs worth
 * finding — it carries opaque payloads and preserves their boundaries — and
 * faking it is what lets the interesting cases be reached at all. A wrong host
 * key, a reply of the wrong length and a frame with a broken tag are all things
 * a live relay will never produce on demand.
 */

import { describe, expect, it } from 'vitest'
import {
  HANDSHAKE_OPEN_BYTES,
  readSealedHandshake,
  withSealedVersion,
} from '../../src/shared/relay-wire'
import {
  generateStatic,
  respondToHandshake,
  type SealedTransport,
  type StaticKeyPair,
} from '../../src/shared/sealed'
import { CHANNEL_CLOSE, type SocketLike } from './connection'
import { guestUrl, relaySocket, type BinarySocketLike } from './relay-socket'

/* ------------------------------------------------------------- test rig -- */

/** The relay, as far as one guest is concerned: a pipe with two ends. */
class FakeRelay implements BinarySocketLike {
  readonly sent: Buffer[] = []
  url = ''
  closedWith: number | null = null
  onopen: (() => void) | null = null
  onmessage: ((event: { data: unknown }) => void) | null = null
  onclose: ((event: { code: number; reason: string }) => void) | null = null
  onerror: (() => void) | null = null

  send(data: Uint8Array): void {
    this.sent.push(Buffer.from(data))
  }

  close(code?: number): void {
    this.closedWith = code ?? 1000
  }

  /** The socket reached the relay. */
  connect(): void {
    this.onopen?.()
  }

  deliver(payload: Uint8Array): void {
    this.onmessage?.({ data: payload })
  }

  drop(code = 1006, reason = ''): void {
    this.onclose?.({ code, reason })
  }
}

interface Rig {
  relay: FakeRelay
  socket: SocketLike
  host: StaticKeyPair
  closes: Array<{ code: number; reason: string }>
  opened: number
  received: string[]
}

/**
 * A browser socket wired to a fake relay, with the machine's real static key.
 *
 * `wrongHost` is the whole point of one of the tests below: the client is given
 * a key that is not the responder's, which is exactly what a relay answering in
 * a machine's place would produce.
 */
function rig(options: { wrongHost?: boolean } = {}): Rig {
  const relay = new FakeRelay()
  const host = generateStatic()
  const state: Rig = {
    relay,
    host,
    closes: [],
    opened: 0,
    received: [],
    socket: relaySocket({
      relayUrl: 'wss://relay.example',
      hostId: 'ABCDEFGHJKLMNPQRSTUVWXYZ23',
      hostPublicKey: options.wrongHost === true ? generateStatic().publicKey : host.publicKey,
      deviceKeys: generateStatic(),
      open: (url) => {
        relay.url = url
        return relay
      },
    }),
  }
  state.socket.onopen = () => {
    state.opened += 1
  }
  state.socket.onmessage = (event) => {
    state.received.push(String(event.data))
  }
  state.socket.onclose = (event) => state.closes.push(event)
  return state
}

/** Answer the client's first frame the way a machine does, and keep the channel. */
function answer(state: Rig): SealedTransport {
  state.relay.connect()
  const first = state.relay.sent[0]
  const opened = readSealedHandshake(first, HANDSHAKE_OPEN_BYTES)
  if (!opened.ok) throw new Error(`the client's first frame was ${opened.reason}`)
  const result = respondToHandshake(state.host, opened.message, () => true)
  state.relay.deliver(withSealedVersion(result.reply))
  return result.transport
}

/* ------------------------------------------------------------------ url -- */

describe('the address a guest opens', () => {
  it('asks the relay to join a named host', () => {
    expect(guestUrl('wss://relay.terminaldeck.dev', 'ABCDEFGHJKLMNPQRSTUVWXYZ23')).toBe(
      'wss://relay.terminaldeck.dev/v1/join?host=ABCDEFGHJKLMNPQRSTUVWXYZ23',
    )
  })

  it('keeps a sub-path and a carried query, and appends host last', () => {
    // A relay behind a reverse proxy needs the first; a deployment that needs a
    // token in the URL is silently broken by dropping the second. `host` goes
    // last because the relay reads the first value of a repeated parameter.
    expect(guestUrl('wss://edge.example/deck/?k=v', 'ABCDEFGHJKLMNPQRSTUVWXYZ23')).toBe(
      'wss://edge.example/deck/v1/join?k=v&host=ABCDEFGHJKLMNPQRSTUVWXYZ23',
    )
  })
})

/* ---------------------------------------------------------- the channel -- */

describe('the sealed channel', () => {
  it('sends one handshake message, versioned, and does not report open yet', () => {
    const state = rig()
    state.relay.connect()

    expect(state.relay.sent).toHaveLength(1)
    expect(state.relay.sent[0]).toHaveLength(HANDSHAKE_OPEN_BYTES)
    // A socket that said "open" here would be one `connection.ts` answers by
    // sending `hello` — a bearer credential — to whoever happened to answer.
    expect(state.opened).toBe(0)
  })

  it('reports open once the machine has proved it holds the paired key', () => {
    const state = rig()
    answer(state)
    expect(state.opened).toBe(1)
    expect(state.closes).toEqual([])
  })

  it('carries protocol text both ways, sealed', () => {
    const state = rig()
    const host = answer(state)

    state.socket.send('{"t":"list"}')
    const carried = state.relay.sent[1]
    // The relay sees ciphertext. The plaintext is not on the wire at any point.
    expect(carried.indexOf(Buffer.from('list', 'utf8'))).toBe(-1)
    expect(host.receive(carried).toString('utf8')).toBe('{"t":"list"}')

    state.relay.deliver(host.send(Buffer.from('{"t":"pong"}', 'utf8')))
    expect(state.received).toEqual(['{"t":"pong"}'])
  })

  it('refuses to send before the handshake has completed', () => {
    const state = rig()
    state.relay.connect()
    // Throwing rather than buffering is what `connection.ts` reads as "this
    // socket is gone", which is what makes it tell the user the keystroke did
    // not land instead of echoing it locally.
    expect(() => state.socket.send('{"t":"list"}')).toThrow()
  })
})

describe('what it refuses', () => {
  it('ends the channel when the far end cannot prove it holds the paired key', () => {
    /*
     * The relay answering in a machine's place.
     *
     * It cannot answer *correctly*: the client's first message sealed its static
     * key to the machine's public key, so a relay holding a different key cannot
     * even open it, let alone produce a confirmation that authenticates. What it
     * can do is send 48 bytes of the right shape and hope, which is what this
     * delivers — and the client's own `finishHandshake` is what refuses it. That
     * is the property the whole design rests on: the far end proves itself with
     * a decrypt, not with a claim.
     */
    const state = rig()
    state.relay.connect()
    const reply = withSealedVersion(Buffer.from(generateStatic().publicKey))
    state.relay.deliver(Buffer.concat([reply, Buffer.alloc(16)]))
    expect(state.opened).toBe(0)
    expect(state.closes).toEqual([
      { code: CHANNEL_CLOSE.sealedRefused, reason: 'the handshake did not complete' },
    ])
  })

  it('is refused by the machine when this device dials one it is not paired with', () => {
    // The mirror image, and the reason a wrong host key is not merely a wrong
    // address: the client seals its own static key to the key it was told, so a
    // machine holding a different one cannot read who is calling. It refuses
    // before it has produced anything to reply with.
    const state = rig({ wrongHost: true })
    expect(() => answer(state)).toThrow(/handshake failed authentication/)
    expect(state.opened).toBe(0)
  })

  it('ends the channel on a first frame that is not a handshake reply', () => {
    const state = rig()
    state.relay.connect()
    state.relay.deliver(Buffer.from('not a handshake', 'utf8'))
    expect(state.closes[0].code).toBe(CHANNEL_CLOSE.malformed)
  })

  it('tells a version mismatch apart from a malformed frame', () => {
    const state = rig()
    state.relay.connect()
    const first = state.relay.sent[0]
    const opened = readSealedHandshake(first, HANDSHAKE_OPEN_BYTES)
    if (!opened.ok) throw new Error('the client produced an unreadable handshake')
    const result = respondToHandshake(state.host, opened.message, () => true)
    const reply = withSealedVersion(result.reply)
    reply[0] = 99
    state.relay.deliver(reply)
    expect(state.closes[0].code).toBe(CHANNEL_CLOSE.sealedVersion)
  })

  it('ends the channel on a frame that fails its tag', () => {
    const state = rig()
    const host = answer(state)
    const frame = host.send(Buffer.from('{"t":"pong"}', 'utf8'))
    frame[frame.length - 1] ^= 0xff
    state.relay.deliver(frame)
    expect(state.received).toEqual([])
    expect(state.closes[0].code).toBe(CHANNEL_CLOSE.sealedRefused)
  })

  it('ends the channel on a text frame, which is not this protocol', () => {
    const state = rig()
    answer(state)
    state.relay.onmessage?.({ data: 'hello?' })
    expect(state.closes[0].code).toBe(CHANNEL_CLOSE.malformed)
  })
})

describe('when the relay drops it', () => {
  it('says the machine was never reached, before the handshake', () => {
    const state = rig()
    state.relay.connect()
    state.relay.drop()
    expect(state.closes).toEqual([
      { code: CHANNEL_CLOSE.relayUnreached, reason: 'the relay closed the connection' },
    ])
  })

  it('says the connection was lost, after it', () => {
    const state = rig()
    answer(state)
    state.relay.drop()
    expect(state.closes[0].code).toBe(CHANNEL_CLOSE.relayLost)
  })

  it('does not pass the relay a way to choose the sentence a person reads', () => {
    // A close code is turned into a sentence by `closeReason`. The relay is the
    // party this design treats as hostile, so its own code and reason are
    // dropped rather than forwarded — otherwise it could put "this device is no
    // longer paired" on somebody's screen and make them re-pair on its say-so.
    const state = rig()
    answer(state)
    state.relay.drop(CHANNEL_CLOSE.sealedRefused, 'this device is no longer paired')
    expect(state.closes[0].code).toBe(CHANNEL_CLOSE.relayLost)
    expect(state.closes[0].reason).toBe('the relay closed the connection')
  })

  it('reports a close exactly once, however many the browser delivers', () => {
    // Two closes for one drop is two retries scheduled for one drop, and the
    // second is a connection attempt nothing is waiting for.
    const state = rig()
    answer(state)
    state.relay.drop()
    state.relay.drop()
    expect(state.closes).toHaveLength(1)
  })

  it('says nothing more after the caller closes it', () => {
    const state = rig()
    answer(state)
    state.socket.close(1000, 'client closed')
    state.relay.drop()
    expect(state.closes).toEqual([])
    expect(state.relay.closedWith).toBe(1000)
  })
})
