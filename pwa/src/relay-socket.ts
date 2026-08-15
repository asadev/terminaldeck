/**
 * The browser's socket to a machine, through the relay, sealed end to end.
 *
 * ## Why this file exists, stated as the defect it fixes
 *
 * Every other client in this product dials `relay.terminaldeck.dev` and runs a
 * Noise IK channel inside it. This one did not. It opened a plain WebSocket to
 * an address whose TLS was terminated by `tailscale serve`, which meant the
 * browser client worked for exactly one kind of person: somebody already running
 * Tailscale. That was never a design. It is what was left over from before the
 * relay existed, and it made the most reachable client in the product the least
 * reachable one.
 *
 * So this module is the missing half. `connection.ts` is unchanged above it —
 * the banner, the heartbeat, the reconnect schedule and the refusal to buffer a
 * keystroke are all the same code — because what a socket carries and how it is
 * protected are different questions, and only the second one is answered here.
 *
 * ## What the relay can and cannot do to this channel
 *
 * `src/shared/sealed.ts` carries the full argument; the short version is that
 * the relay is treated as hostile by construction. It sees a host id in a query
 * string and ciphertext after that. It can drop this connection, which is honest
 * failure, and it cannot read a keystroke, inject one, replay one, or answer in
 * the machine's place — the last of those because the handshake is IK and the
 * machine's static public key came out of the pairing code rather than off the
 * wire.
 *
 * The one thing worth being precise about: **this file is not the crypto.** It
 * runs `startHandshake` and `finishHandshake` from the shared module, the same
 * two functions `src/main/remote/machines/dial.ts` runs when one desktop dials
 * another. A second implementation of the handshake for the browser would agree
 * with itself and drift from the other four clients, which is exactly how a dead
 * cipher hid behind 3,628 passing tests for a day.
 *
 * ## Why "open" here means the handshake finished, not the socket
 *
 * `onopen` fires when the sealed transport exists, not when the WebSocket does.
 * `connection.ts` answers `onopen` by sending `hello`, and `hello` carries a
 * bearer credential — so a channel that reported itself open before the far end
 * had proved anything would be a channel that hands a secret to whoever answered.
 * There is no state in between worth telling the user about either: from the
 * outside, "the relay accepted a socket" and "still connecting" are the same
 * sentence.
 *
 * ## Framing
 *
 * The relay preserves message boundaries, so one WebSocket binary frame is
 * exactly one payload and nothing here needs a length prefix. The shapes are in
 * `src/shared/relay-wire.ts` and imported rather than restated:
 *
 *     out  [version][80-byte Noise IK message 1]
 *     in   [version][48-byte Noise IK message 2]
 *     both one sealed frame per protocol message, forever after
 */

import {
  HANDSHAKE_REPLY_BYTES,
  MAX_PAYLOAD_BYTES,
  RELAY_GUEST_PATH,
  readSealedHandshake,
  withSealedVersion,
} from '../../src/shared/relay-wire'
import {
  SealedRefusal,
  finishHandshake,
  startHandshake,
  type InitiatorStart,
  type SealedTransport,
  type StaticKeyPair,
} from '../../src/shared/sealed'
import { CHANNEL_CLOSE, type SocketLike } from './connection'

/* ------------------------------------------------------------- injected -- */

/**
 * A WebSocket that carries bytes, behind an interface with no DOM in it.
 *
 * The same reason `browserSocket` in `connection.ts` exists: depending on
 * `MessageEvent` and `CloseEvent` would drag a DOM into every test of this
 * module, and the interesting behaviour here — a handshake reply of the wrong
 * length, a frame that fails its tag — has nothing to do with a browser.
 */
export interface BinarySocketLike {
  send(data: Uint8Array): void
  close(code?: number, reason?: string): void
  onopen: (() => void) | null
  onmessage: ((event: { data: unknown }) => void) | null
  onclose: ((event: { code: number; reason: string }) => void) | null
  onerror: (() => void) | null
}

/**
 * A real browser socket in binary mode.
 *
 * `binaryType` is set before anything can arrive. Left at its default the
 * browser delivers a `Blob`, whose contents are only readable asynchronously —
 * so a handshake reply would arrive one microtask after the frame that carried
 * it, and the code below would be reading frames out of order without ever
 * seeing an error.
 */
export function browserBinarySocket(url: string): BinarySocketLike {
  const socket = new WebSocket(url)
  socket.binaryType = 'arraybuffer'
  const adapter: BinarySocketLike = {
    send: (data) => socket.send(data),
    close: (code, reason) => socket.close(code, reason),
    onopen: null,
    onmessage: null,
    onclose: null,
    onerror: null,
  }
  socket.onopen = () => adapter.onopen?.()
  socket.onmessage = (event) => adapter.onmessage?.({ data: event.data })
  socket.onclose = (event) => adapter.onclose?.({ code: event.code, reason: event.reason })
  socket.onerror = () => adapter.onerror?.()
  return adapter
}

/* ------------------------------------------------------------- the dial -- */

/** Where a machine is, as a pairing code or a stored credential says. */
export interface RelayTarget {
  /** The relay's base address, `wss://…`. */
  relayUrl: string
  /** The 26-character public name of the machine. */
  hostId: string
  /** That machine's X25519 static public key. What makes this Noise IK. */
  hostPublicKey: Buffer
}

export interface RelaySocketOptions extends RelayTarget {
  /** This browser's identity, as the machine knows it. See `endpoint.ts`. */
  deviceKeys: StaticKeyPair
  /** Seam for the tests and for the live harness. */
  open?: (url: string) => BinarySocketLike
}

/**
 * The URL a guest actually opens.
 *
 * Any path already on the configured relay is kept as a prefix and any query is
 * kept in front of ours, for the same two reasons `dial.ts` gives: a relay
 * behind a reverse proxy on a sub-path needs the first, and a deployment that
 * needs a token in the URL is silently broken by dropping the second. `host` is
 * appended last so it cannot be shadowed — the relay reads the first value of a
 * repeated parameter.
 */
export function guestUrl(relayUrl: string, hostId: string): string {
  const url = new URL(relayUrl)
  const prefix = url.pathname.replace(/\/+$/, '')
  const carried = url.search === '' ? '' : `${url.search.slice(1)}&`
  return `${url.protocol}//${url.host}${prefix}${RELAY_GUEST_PATH}?${carried}host=${encodeURIComponent(hostId)}`
}

/**
 * One sealed channel to one machine, wearing the same interface as a plain
 * socket so that nothing above it has to know which of the two it got.
 *
 * Reconnection is deliberately not here. `connection.ts` owns the schedule, the
 * jitter and the reasons for resetting it, and a socket that retried on its own
 * behalf would be a second policy racing the first — two dials per drop, and a
 * banner that cannot describe either.
 */
export function relaySocket(options: RelaySocketOptions): SocketLike {
  const open = options.open ?? browserBinarySocket

  const adapter: SocketLike = {
    send: () => {
      throw new Error('the sealed channel is not open')
    },
    close: () => {},
    onopen: null,
    onmessage: null,
    onclose: null,
    onerror: null,
  }

  /*
   * Built before the socket, because the pending half has to survive into the
   * first inbound frame. Building it there would mean a second ephemeral key for
   * one handshake, which is the shape of bug that produces a channel that opens
   * and then fails to decrypt anything.
   *
   * A throw here is a *fault* — the crypto could not run in this browser at all —
   * and it is reported as a close rather than raised, which is not fussiness.
   * `connection.ts` catches anything `open` throws and says "that address cannot
   * be opened from this page", because the only thing that used to throw was
   * `new WebSocket` on a URL the browser refused. This client spent an afternoon
   * saying exactly that about a perfectly good relay address while the real
   * problem was a `Buffer` implementation two versions too old to write the Noise
   * nonce. A close carries a sentence about the crypto instead.
   */
  const started = build(options.deviceKeys, options.hostPublicKey)
  if (started === null) return brokenSocket(adapter, CHANNEL_CLOSE.sealedFault)
  let transport: SealedTransport | null = null
  let closed = false

  let socket: BinarySocketLike
  try {
    socket = open(guestUrl(options.relayUrl, options.hostId))
  } catch (error) {
    // `new WebSocket` throws synchronously on a URL the browser will not accept
    // — a `ws://` relay from an `https:` page, most likely. Rethrown rather than
    // swallowed: `connection.ts` catches it and says so.
    throw error instanceof Error ? error : new Error(String(error))
  }

  /**
   * The one way this channel ends, from either side.
   *
   * Everything is unhooked before the close goes out, so a browser that fires
   * `onclose` in response to our own `close()` cannot deliver a second event —
   * which would be a second retry scheduled for one drop.
   */
  const finish = (code: number, reason: string): void => {
    if (closed) return
    closed = true
    socket.onopen = null
    socket.onmessage = null
    socket.onerror = null
    const notify = adapter.onclose
    socket.onclose = null
    try {
      socket.close(1000, 'closing')
    } catch {
      // Closing an already-closed socket is not worth reporting.
    }
    notify?.({ code, reason })
  }

  adapter.close = (code, reason) => {
    if (closed) return
    closed = true
    socket.onopen = null
    socket.onmessage = null
    socket.onerror = null
    socket.onclose = null
    try {
      socket.close(code ?? 1000, reason ?? '')
    } catch {
      // As above.
    }
  }

  adapter.send = (text: string) => {
    if (closed || transport === null) throw new Error('the sealed channel is not open')
    // Not caught here. `connection.ts` treats a throwing `send` as a socket that
    // is already gone and refuses the keystroke, which is the honest answer: the
    // only way this throws is the nonce counter reaching its ceiling, and a
    // channel at that point has to end rather than reuse a nonce.
    socket.send(transport.send(Buffer.from(text, 'utf8')))
  }

  socket.onopen = () => {
    // The relay does not tell a guest whether the host it asked for exists —
    // answering that would make the endpoint an oracle for which machines are
    // online — so the first message goes out immediately and silence afterwards
    // is indistinguishable from a machine that is switched off. The handshake
    // timeout in `connection.ts` is what turns that silence into a sentence.
    try {
      socket.send(withSealedVersion(started.message))
    } catch {
      finish(CHANNEL_CLOSE.relayLost, 'the relay closed while the handshake was going out')
    }
  }

  socket.onmessage = (event) => {
    if (closed) return
    const payload = asBytes(event.data)
    if (payload === null) {
      // The relay carries binary. A text frame is something else on the other
      // end — a proxy's error page, most likely — and parsing it would be this
      // client guessing.
      finish(CHANNEL_CLOSE.malformed, 'the relay sent something that is not a sealed frame')
      return
    }
    if (payload.length > MAX_PAYLOAD_BYTES) {
      finish(CHANNEL_CLOSE.malformed, 'the relay sent a frame larger than the protocol allows')
      return
    }

    if (transport === null) {
      const opened = readSealedHandshake(payload, HANDSHAKE_REPLY_BYTES)
      if (!opened.ok) {
        finish(
          opened.reason === 'wrong-version' ? CHANNEL_CLOSE.sealedVersion : CHANNEL_CLOSE.malformed,
          'the first frame was not a handshake reply',
        )
        return
      }
      try {
        transport = finishHandshake(started.pending, opened.message)
      } catch (error) {
        /*
         * A refusal and a fault are different events and are reported as such —
         * this is the distinction `SealedRefusal` exists for. A refusal means the
         * far end could not prove it holds the key this browser paired against:
         * a relay answering in its place, or a machine that regenerated its
         * identity. A fault means the crypto could not run at all, which is a
         * broken build and not that machine's fault. Reporting both as "not
         * allowed in" is what hid a dead cipher for a day.
         */
        finish(
          error instanceof SealedRefusal ? CHANNEL_CLOSE.sealedRefused : CHANNEL_CLOSE.sealedFault,
          'the handshake did not complete',
        )
        return
      }
      adapter.onopen?.()
      return
    }

    let text: string
    try {
      text = transport.receive(payload).toString('utf8')
    } catch {
      // Uniform on purpose, all the way down: which check failed is not the
      // network's business, and the answer is the same either way — this channel
      // is over.
      finish(CHANNEL_CLOSE.sealedRefused, 'a frame failed its seal')
      return
    }
    adapter.onmessage?.({ data: text })
  }

  socket.onerror = () => {
    // Browsers deliberately give no detail here, to avoid leaking whether a host
    // exists. The close that follows carries what there is.
    adapter.onerror?.()
  }

  socket.onclose = () => {
    if (closed) return
    closed = true
    /*
     * The relay's own close code is not passed through, and that is deliberate.
     *
     * It is a number chosen by the party this whole design treats as hostile, and
     * `connection.ts` turns a close code into a sentence a person reads. A relay
     * that wanted to could otherwise put "this device is no longer paired" on
     * somebody's screen and make them re-pair on its say-so. What it can honestly
     * cause is a lost connection, so that is what it is reported as.
     */
    adapter.onclose?.({
      code: transport === null ? CHANNEL_CLOSE.relayUnreached : CHANNEL_CLOSE.relayLost,
      reason: 'the relay closed the connection',
    })
  }

  return adapter
}

/**
 * A binary WebSocket payload as bytes, or null for anything that is not one.
 *
 * `ArrayBuffer` is what a socket with `binaryType = 'arraybuffer'` delivers, and
 * a `Uint8Array` is what the test seam delivers. A string is a text frame and is
 * not one of ours.
 *
 * Returned as a `Buffer` because that is what the shared wire and the sealed
 * transport take, and converting once here is one copy per frame instead of one
 * per call site — with no chance of a call site forgetting and handing a plain
 * `Uint8Array` to something that will read `.subarray()` off it as a Buffer.
 */
function asBytes(data: unknown): Buffer | null {
  if (data instanceof ArrayBuffer) return Buffer.from(new Uint8Array(data))
  if (data instanceof Uint8Array) return Buffer.from(data)
  return null
}

/**
 * The first handshake message, or null when the crypto could not run.
 *
 * Separated from `relaySocket` so the one `try` in the file that means "this
 * build is broken" is not sitting in the middle of the one that means "the relay
 * refused the address" — telling those two apart is the whole reason
 * `SealedRefusal` exists, and a reader who has to work out which `catch` is
 * which has already been given the chance to get it wrong.
 */
function build(deviceKeys: StaticKeyPair, hostPublicKey: Buffer): InitiatorStart | null {
  try {
    return startHandshake(deviceKeys, hostPublicKey)
  } catch {
    return null
  }
}

/**
 * A channel that never was, reported the way every other failure is.
 *
 * Returned instead of throwing so the caller has one shape to handle. The close
 * is scheduled rather than delivered now, because the caller has not had a
 * chance to attach its handlers yet — a socket that reported itself closed
 * inside its own constructor would be a socket nobody heard close.
 */
function brokenSocket(adapter: SocketLike, code: number): SocketLike {
  setTimeout(() => adapter.onclose?.({ code, reason: 'the sealed channel could not be started' }), 0)
  return adapter
}
