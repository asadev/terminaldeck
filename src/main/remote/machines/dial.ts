/**
 * The other end of `relay-client.ts`: this desktop dialling *out* as a guest.
 *
 * ## Why there are two of these and not one
 *
 * `relay-client.ts` claims a name at the relay and holds one socket for every
 * phone attached to it, so it carries a 17-byte envelope on every frame to say
 * which phone a payload belongs to, a channel table, a reconnect loop and a
 * heartbeat. A guest has none of that. It dials `/v1/join?host=…`, gets one
 * channel and nothing else, and the relay hands its frames over unwrapped — a
 * guest has one channel and does not need to be told its own name.
 *
 * Trying to serve both roles from one module would mean an envelope layer with
 * a flag saying whether to use it, on the one file in this app whose bugs are
 * somebody else's shell. Two files, each doing one job, is the cheaper mistake.
 *
 * What *is* shared is everything that decides bytes: the paths and the sealed
 * framing from `shared/relay-wire.ts`, the WebSocket framing from
 * `shared/ws-frame.ts`, and the handshake from `shared/sealed.ts`. Nothing about
 * the wire is restated here.
 *
 * ## What this file is not
 *
 * It is not a session, not a protocol and not a reconnect policy. It opens a
 * socket, proves the far end is the machine we meant, and hands back something
 * that sends and receives strings. `guest.ts` decides what to say down it and
 * `machines/ipc.ts` decides when to try again. That seam is the same one
 * `relay-client.ts` draws with `RemoteWire`, and for the same reason: the layer
 * that knows about sockets must not also be the layer that knows about trust.
 */

import { randomBytes } from 'node:crypto'
import { connect as netConnect } from 'node:net'
import type { Duplex } from 'node:stream'
import { connect as tlsConnect } from 'node:tls'
import {
  HANDSHAKE_REPLY_BYTES,
  MAX_PAYLOAD_BYTES,
  RELAY_GUEST_PATH,
  readSealedHandshake,
  withSealedVersion,
} from '../../../shared/relay-wire'
import {
  SealedRefusal,
  finishHandshake,
  startHandshake,
  type SealedTransport,
  type StaticKeyPair,
} from '../../../shared/sealed'
import { FrameReader, OPCODE, acceptKey, encodeMaskedFrame } from '../../../shared/ws-frame'
import { relayTarget } from '../relay-client'

/** Longest a dial may take before it is a dial that is not going to happen. */
export const DIAL_TIMEOUT_MS = 15_000

/**
 * Cap on the HTTP response head, so a peer that never sends `\r\n\r\n` cannot
 * make this process hold an unbounded string. The same number
 * `relay-client.ts` uses, for the same reason.
 */
const MAX_RESPONSE_HEAD_BYTES = 8 * 1024

/** What a caller gets: a way to speak, a way to listen, and a way to stop. */
export interface GuestChannel {
  /** One protocol message, sealed and posted. Silently dropped once closed. */
  send(text: string): void
  /** Ends the channel. Safe to call twice; the handlers fire at most once. */
  close(): void
  /** True until something closed it, from either end. */
  readonly open: boolean
}

export interface GuestHandlers {
  /** One decrypted protocol message. Never called after `closed`. */
  message(text: string): void
  /**
   * The channel ended, with the reason in a sentence somebody can read.
   *
   * Called exactly once, whether the far end hung up, the relay dropped it, a
   * frame failed its tag, or this process asked. A caller that has to tell those
   * apart is a caller building a retry policy out of error strings, and the
   * only distinction that changes what anyone does is already in the type of
   * `dialMachine`'s rejection: refused before the channel existed versus lost
   * after it did.
   */
  closed(reason: string): void
}

export interface DialRequest {
  /** The relay's base address, `wss://…`. Validated by `relayTarget`. */
  relayUrl: string
  /** The 26-character public name of the machine being dialled. */
  hostId: string
  /** That machine's X25519 static public key. What makes this Noise IK. */
  hostPublicKey: Buffer
  /** This desktop's identity *as a guest of that machine*. See `store.ts`. */
  guestKeys: StaticKeyPair
  handlers: GuestHandlers
  timeoutMs?: number
}

/**
 * Open a sealed channel to another machine, or say why not.
 *
 * Rejects rather than resolving with a failed channel. Everything that can go
 * wrong before the handshake completes leaves nothing to close and nothing to
 * report through `handlers` — there is no channel yet — and a caller that had to
 * check a flag on a resolved object would eventually forget to.
 *
 * The promise settles when the handshake is done, not when the socket opens.
 * Until then the far end has proved nothing, and a `GuestChannel` that existed
 * before that point would be one somebody could send a credential down.
 */
export function dialMachine(request: DialRequest): Promise<GuestChannel> {
  const target = relayTarget(request.relayUrl)
  if (!target.ok) return Promise.reject(new Error(target.reason))

  const { url, secure } = target
  const port = url.port === '' ? (secure ? 443 : 80) : Number(url.port)
  // The configured value is the relay's base, not its endpoint. Any path it
  // carries is kept as a prefix — that is what a relay behind a reverse proxy on
  // a sub-path needs — and any query it carries is kept too, because dropping it
  // silently is how a deployment that needs a token in the URL fails with no
  // explanation. `host` is appended last so it cannot be shadowed by one already
  // there: the relay reads the *first* value of a repeated parameter.
  const prefix = url.pathname.replace(/\/+$/, '')
  const carried = url.search === '' ? '' : `${url.search.slice(1)}&`
  const path = `${prefix}${RELAY_GUEST_PATH}?${carried}host=${encodeURIComponent(request.hostId)}`
  const key = randomBytes(16).toString('base64')

  return new Promise<GuestChannel>((resolve, reject) => {
    let socket: Duplex
    try {
      socket = secure
        ? // Certificate verification is on, which is the default and is what
          // makes `wss:` mean anything. It is not what proves the far end is the
          // machine we meant — the relay is the party holding that certificate,
          // and it is treated as hostile. The handshake below is that proof.
          tlsConnect({ host: url.hostname, port, servername: url.hostname, ALPNProtocols: ['http/1.1'] })
        : netConnect({ host: url.hostname, port })
    } catch (error) {
      reject(new Error(`Could not dial the relay: ${describe(error)}.`))
      return
    }

    // Keystrokes are one-byte writes; Nagle would hold each one waiting for an
    // ack and a session on another machine would feel like a satellite link.
    if ('setNoDelay' in socket && typeof socket.setNoDelay === 'function') socket.setNoDelay(true)

    const reader = new FrameReader(MAX_PAYLOAD_BYTES, 'client')
    let transport: SealedTransport | null = null
    let settled = false
    let closed = false
    let head: string | null = null
    let pending = Buffer.alloc(0)
    let upgraded = false
    let onHead: (() => void) | null = null
    let onFailure: ((error: Error) => void) | null = null

    const timer = setTimeout(() => {
      socket.destroy(new Error('timed out'))
    }, request.timeoutMs ?? DIAL_TIMEOUT_MS)
    timer.unref?.()

    /**
     * The one way this channel ends.
     *
     * Before the handshake settles it is a rejection and there is nothing to
     * tell the caller's handlers about; afterwards it is exactly one `closed`.
     * Both paths destroy the socket, because a relay that has stopped answering
     * leaves one that stays writable for as long as TCP feels like it.
     */
    const finish = (why: string): void => {
      if (closed) return
      closed = true
      clearTimeout(timer)
      socket.removeAllListeners()
      // A no-op error listener, deliberately, and it goes on *after* the others
      // come off. A socket that is being torn down can still deliver one last
      // read error — `ECONNRESET` when the far end pulled the plug rather than
      // closing — and a Node socket with no `error` listener turns that into an
      // uncaught exception that takes the process with it. There is nothing left
      // to report by then: the caller has already been told why this ended.
      socket.on('error', () => {})
      socket.destroy()
      if (!settled) {
        settled = true
        reject(new Error(why))
        return
      }
      request.handlers.closed(why)
    }

    const write = (opcode: number, payload: Buffer): void => {
      if (closed || socket.destroyed) return
      try {
        socket.write(encodeMaskedFrame(opcode, payload))
      } catch (error) {
        finish(`The link to ${request.hostId} failed while sending: ${describe(error)}.`)
      }
    }

    const onBinary = (payload: Buffer): void => {
      if (transport === null) {
        // The first binary frame is the handshake reply and nothing else. A
        // relay that sent anything here would be a relay trying to make this
        // process parse something before it holds a key.
        const opened = readSealedHandshake(payload, HANDSHAKE_REPLY_BYTES)
        if (!opened.ok) {
          finish(
            opened.reason === 'wrong-version'
              ? 'That machine is running a different version of the sealed channel. Update whichever build is older.'
              : 'The relay answered with something that is not a handshake.',
          )
          return
        }
        try {
          transport = finishHandshake(handshake.pending, opened.message)
        } catch (error) {
          // A refusal here means the far end could not prove it holds the key
          // this machine was paired against — a relay answering for it, or a
          // machine that has regenerated its identity. A fault means the crypto
          // could not run at all, which is a broken build and not that machine's
          // fault. Saying which is the whole point of `SealedRefusal`; reporting
          // both as "not allowed in" is what hid a dead cipher for a day.
          finish(
            error instanceof SealedRefusal
              ? 'That machine could not prove it is the one this device paired with. Pair it again.'
              : `The sealed handshake could not run on this build: ${describe(error)}.`,
          )
          return
        }
        clearTimeout(timer)
        settled = true
        resolve(channel)
        return
      }

      let text: string
      try {
        text = transport.receive(payload).toString('utf8')
      } catch {
        // Uniform on purpose, all the way down: which check failed is not the
        // network's business, and the answer is the same either way — this
        // channel is over.
        finish('A message from that machine failed its seal, so the connection was dropped.')
        return
      }
      try {
        request.handlers.message(text)
      } catch (error) {
        // The caller's own bookkeeping threw. It must not take the app down, and
        // it must not leave a channel nobody is reading.
        console.error('[machines] a message handler threw:', error)
        finish('This machine could not handle a message from that one.')
      }
    }

    const channel: GuestChannel = {
      send(text: string): void {
        if (closed || transport === null) return
        let sealed: Buffer
        try {
          sealed = transport.send(Buffer.from(text, 'utf8'))
        } catch {
          // The only way this throws is the counter reaching its ceiling, which
          // is a channel that has to end rather than one that reuses a nonce.
          finish('This connection has been open long enough to need a fresh one.')
          return
        }
        write(OPCODE.binary, sealed)
      },
      close(): void {
        // A close frame first, so the relay forgets the channel now rather than
        // when its own heartbeat notices. `finish` destroys the socket, so the
        // write has to happen before it.
        write(OPCODE.close, Buffer.alloc(0))
        finish('Closed by this machine.')
      },
      get open(): boolean {
        return !closed
      },
    }

    /**
     * One `data` listener for the whole life of this socket, switched by a flag.
     *
     * Removing a listener does not take a stream out of flowing mode, so a
     * handshake that reads the head with a temporary listener and then installs
     * the real one loses whatever arrived in between. `relay-client.ts` learnt
     * that the hard way and the note there is the same one: bytes only ever go
     * two places, into the response head or into the framer.
     */
    socket.on('data', (chunk: Buffer) => {
      if (upgraded) {
        const batch = reader.push(chunk)
        for (const frame of batch.frames) {
          if (closed) return
          if (frame.opcode === OPCODE.close) return finish('That machine closed the connection.')
          if (frame.opcode === OPCODE.ping) {
            write(OPCODE.pong, frame.payload)
            continue
          }
          if (frame.opcode === OPCODE.pong) continue
          // Fragmentation is refused rather than reassembled: the relay does not
          // fragment, and buffering on behalf of one that started to would be a
          // way to make this process hold any amount of memory.
          if (!frame.fin) return finish('The relay sent a fragmented frame.')
          if (frame.opcode === OPCODE.binary) onBinary(frame.payload)
          // Text frames are ignored rather than fatal: nothing sends them.
        }
        if (!batch.ok) finish(`The relay sent a frame this build cannot read: ${batch.error.detail}.`)
        return
      }
      pending = Buffer.concat([pending, chunk])
      if (head !== null) return
      const end = pending.indexOf('\r\n\r\n')
      if (end === -1) {
        if (pending.length > MAX_RESPONSE_HEAD_BYTES) {
          onFailure?.(new Error('the relay sent a response head with no end to it'))
        }
        return
      }
      head = pending.subarray(0, end).toString('latin1')
      pending = Buffer.from(pending.subarray(end + 4))
      onHead?.()
    })

    const gone = (phrase: string): void => {
      /*
       * The same fact reads two ways: before the upgrade it is why the dial
       * failed, after it is why the connection ended.
       *
       * The condition is `head === null` rather than `!upgraded`, and getting
       * that wrong cost an afternoon. A relay with nowhere to route a guest
       * answers `101` and hangs up immediately, so Node emits `data`, `end` and
       * `close` in one tick. The head resolves its promise on `data`; `end`
       * arrives *before* the microtask that sets `upgraded`, and calling the
       * head's rejecter at that point is a no-op on a promise that is already
       * settled. Nothing settled the dial, nothing destroyed the socket, and the
       * only symptom was a lookup that timed out after twelve seconds instead of
       * failing in two milliseconds — with the socket left open behind it.
       *
       * Having the head is the honest test for "the promise chain can still
       * carry this": before it, the chain is waiting and a rejection reaches
       * `run`'s catch; after it, the chain has moved on and this is the only
       * thing that will close the channel.
       */
      if (onFailure !== null && head === null) onFailure(new Error(phrase))
      else finish(`${phrase[0].toUpperCase()}${phrase.slice(1)}.`)
    }
    socket.on('error', () => gone('the link to the relay failed'))
    socket.on('close', () => gone('the relay closed the connection'))
    // A peer that vanishes delivers 'end' and then stays writable forever;
    // listening only for 'close' leaves a link that is gone but looks fine.
    socket.on('end', () => gone('the relay stopped answering'))

    // Built before the socket is even up, because the pending half has to
    // survive into `onBinary` and building it there would mean two ephemeral
    // keys for one handshake.
    const handshake = startHandshake(request.guestKeys, request.hostPublicKey)

    const run = async (): Promise<void> => {
      await new Promise<void>((settle, fail) => {
        onFailure = fail
        socket.once(secure ? 'secureConnect' : 'connect', () => settle())
      })

      const host = url.port === '' ? url.hostname : `${url.hostname}:${url.port}`
      socket.write(
        [
          `GET ${path} HTTP/1.1`,
          `Host: ${host}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${key}`,
          'Sec-WebSocket-Version: 13',
          '',
          '',
        ].join('\r\n'),
      )

      await new Promise<void>((settle, fail) => {
        if (head !== null) return settle()
        onHead = settle
        onFailure = fail
      })

      const answered = head ?? ''
      const status = Number(/^HTTP\/1\.1 (\d+)/.exec(answered)?.[1] ?? 0)
      if (status !== 101) {
        throw new Error(`the relay answered ${status || 'nothing'} instead of upgrading the connection`)
      }
      // Checked rather than assumed: a `101` from something that did not
      // understand the request is a peer about to be fed WebSocket frames it
      // will read as HTTP.
      if (headerOf(answered, 'sec-websocket-accept') !== acceptKey(key)) {
        throw new Error('the relay answered an upgrade that does not match the request')
      }

      onHead = null
      onFailure = null
      upgraded = true

      // Message one goes out immediately. The relay does not tell a guest
      // whether the host it asked for exists — answering that would make the
      // endpoint an oracle for which machines are online — so silence here is
      // indistinguishable from a machine that is switched off, and the timeout
      // above is what turns it into a sentence.
      write(OPCODE.binary, withSealedVersion(handshake.message))

      // Whatever rode in behind the `101`. Replayed after `upgraded` is set, or
      // the framer would never see it.
      if (pending.length > 0) {
        const rest = pending
        pending = Buffer.alloc(0)
        socket.emit('data', rest)
      }
    }

    void run().catch((error: unknown) => {
      finish(`Could not reach that machine: ${describe(error)}.`)
    })
  })
}

function headerOf(head: string, name: string): string | null {
  for (const line of head.split('\r\n').slice(1)) {
    const at = line.indexOf(':')
    if (at === -1) continue
    if (line.slice(0, at).trim().toLowerCase() !== name) continue
    return line.slice(at + 1).trim()
  }
  return null
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
