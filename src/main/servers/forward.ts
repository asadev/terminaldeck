/**
 * A server's own `localhost`, carried here over the connection we already have.
 *
 * ## The complaint this answers
 *
 * From the review of 2026-08-18, after the servers feature landed:
 *
 *   > *"does it also cover to open sessions, and local browsers in server"*
 *
 * It did not. A server could be looked at and acted on, and the one thing a
 * paired laptop could do that a server could not was the thing a person spends
 * all day doing: open what it is serving. The rule that makes that a defect
 * rather than a missing extra is his, and it is the same sentence the whole
 * browser was arranged around three nights running:
 *
 *   > *"Keep the same one browser window for every device… **shape of the
 *   > application should not be changing for local and remote devices.** It
 *   > should act like that same."*
 *
 * A server is a machine in that sentence. So it appears in the same picker
 * beside the same laptops, `localhost` means it in the same address bar, and
 * what comes back is an ordinary `http://` page in the same tab.
 *
 * ## Why this file is a *translator* and not a tunnel
 *
 * The pipe already exists twice and has been proved twice — once as the host
 * half in `src/main/remote/tunnel.ts`, once as the guest half in
 * `src/main/localhost-reach.ts` — and the guest half is the one this feature
 * needs, unchanged. It walks the three-rung ladder that keeps the port number,
 * it claims the local port so a tunnel cannot become a chain, and it carries
 * the flush-versus-discard fix that a Windows runner found today: `destroy()`
 * throws away everything Node accepted from `write()` and has not handed to the
 * kernel, which on Windows is everything past 64 KB, so a response larger than
 * that arrived truncated and the reader waited forever for an `end` that never
 * came. Writing a second listener here would have been a second chance to
 * reintroduce exactly that.
 *
 * So the guest half is used as it stands, and what this file provides is the
 * **other end of its conversation**. `RemoteReach` speaks six frames —
 * `tunnel.open`, `net.open`, `net.data`, `net.ack`, `net.close`,
 * `tunnel.close` — into a `send()` it is handed, and expects five back. Over a
 * relay those frames cross a sealed channel to another copy of this app. Here
 * they cross nothing at all: this object answers them in-process, and where
 * `tunnel.ts` would dial its own loopback with `net.createConnection`, this
 * asks the SSH connection for a channel to the server's loopback with
 * `forwardOut`. Same conversation, same ordering, same flow control, different
 * last inch.
 *
 * `forwardOut` is the library's name for what `ssh -L` does, and `ssh2` — which
 * is already a dependency, chosen and measured in `SERVERS-DESIGN.md` §2 — has
 * had it all along. Nothing new is installed and nothing new is invented.
 *
 * ## Detect, do not assume
 *
 * A server may refuse this outright. `AllowTcpForwarding no` in its own
 * settings is real, is common on hardened machines, and is invisible from here
 * until it is asked. Rule 4 of the servers design — *"we need something common…
 * they might have different settings"* — makes guessing the wrong move in both
 * directions: assuming it works draws a control that fails on a click, and
 * assuming it does not would hide a working feature from everybody.
 *
 * So it is asked, and {@link askWhetherItForwards} is the asking. What comes
 * back is the same three-state answer every other fact about a server carries,
 * because "it refuses" and "we could not find out" are different things to put
 * on a screen.
 */

import { MAX_NET_CHUNK_BYTES, NET_WINDOW_BYTES, type ServerMessage } from '../remote/protocol'
import type { LocalhostMessage } from '../remote/tunnel'

/**
 * The two loopback literals, in the order they are tried.
 *
 * Literals rather than the name `localhost`, for the reason `tunnel.ts` gives
 * about its own dial: a name is resolved by the far end and can be pointed
 * anywhere, and the whole promise of this feature is that `localhost` means
 * that machine's loopback and nothing else.
 *
 * IPv4 first because that is what almost everything binds, and IPv6 second
 * rather than not at all: a service bound only to `::1` is invisible to a v4
 * dial, which is precisely the shape of the bug the Windows runner found in the
 * relay path and it would have been rebuilt here.
 */
const LOOPBACK_V4 = '127.0.0.1'
const LOOPBACK_V6 = '::1'

/**
 * How long one channel may take to open before it is abandoned.
 *
 * The same five seconds `tunnel.ts` allows its own dial, and for the same
 * reason: something that is listening and has not accepted inside this is
 * wedged, and a person is better told than left watching a spinner. It is a
 * ceiling and not a delay — the ordinary answer, refusal included, comes back
 * in one round trip.
 */
const OPEN_TIMEOUT_MS = 5_000

/**
 * Browser connections one server may hold open at once, and pages at once.
 *
 * Chromium opens six connections per origin and a live page holds a few more
 * for its hot-reload socket and its images, so sixty-four is roughly ten pages'
 * worth. The ceiling exists because every one of these is a channel on a single
 * SSH connection, and a connection with unbounded channels on it is a way to
 * make somebody's server refuse the shell they were about to open.
 */
const MAX_STREAMS = 64

/** Ports one server may have open at once. A person looks at one page, maybe two. */
const MAX_TUNNELS = 4

/* ------------------------------------------------------- what a refusal is -- */

/**
 * Why a channel would not open, in the terms the far end answered in.
 *
 * `prohibited` and `unreachable` are the two the SSH protocol distinguishes and
 * they are the two that matter here, because they are facts about completely
 * different things. `prohibited` is a fact about the **server's settings** —
 * it will not forward at all, or not to that address — and the person's next
 * move is to change them or ask whoever can. `unreachable` is a fact about
 * **what is running on it**: the server tried, and nothing answered on that
 * port. Collapsing them would send somebody to edit a settings file because
 * their website was not running.
 */
export type ForwardRefusal = 'prohibited' | 'unreachable' | 'unknown'

/**
 * The numeric reasons in the SSH protocol, from `ssh2`'s own constants.
 *
 * Written out rather than imported: `ssh2`'s constants live under
 * `lib/protocol/constants.js`, which is not part of the package's public
 * surface, and `ssh2.d.ts` in this folder is deliberately a narrow declaration
 * of what this app uses rather than a description of the whole library. These
 * four numbers are in RFC 4254 §5.1 and have not moved since 2006.
 */
const PROHIBITED = 1
const CONNECT_FAILED = 2

/**
 * A live connection, named by what this module asks of it rather than by which
 * library opened it.
 *
 * **This file deliberately does not import `ssh2`.** `host-key-checked.test.ts`
 * walks the syntax tree of every source in this folder and fails the build if
 * anything but `connection.ts` reaches the transport, and that guard is worth
 * more than the convenience of naming the class: it is what stops a second
 * connection path — a quick reconnect, a health check, a file transfer — from
 * being written in eight months by somebody who has not read why
 * `hostVerifier` is required.
 *
 * Nothing is lost by describing the one call instead. An `ssh2` `Client`
 * satisfies this structurally, so `connection.ts` hands one straight over; a
 * test satisfies it with an object; and this module cannot open a connection
 * at all, which is the property the guard is protecting. The declaration of the
 * real method, with everything odd about its failure path, is in `ssh2.d.ts`.
 */
export interface ForwardingConnection {
  /**
   * The connection has gone.
   *
   * Listened to rather than polled — his standing rule — and it is the only
   * thing that ends a page served through one of these: a listener still
   * accepting on this machine after the connection has died is an address in
   * somebody's browser that answers and then hangs.
   */
  on(event: 'close', listener: () => void): unknown
  forwardOut(
    srcIP: string,
    srcPort: number,
    dstIP: string,
    dstPort: number,
    callback: (error: (Error & { reason?: number }) | undefined, channel: ForwardChannel) => void,
  ): unknown
}

/** One channel to a port on the server, as this module needs it. */
export interface ForwardChannel {
  on(event: 'data', listener: (chunk: Buffer) => void): unknown
  on(event: 'end' | 'close', listener: () => void): unknown
  on(event: 'error', listener: (error: Error) => void): unknown
  write(chunk: Buffer, callback: () => void): boolean
  /** Send what is queued and then end-of-file. Never `destroy` for an orderly close. */
  end(): void
  destroy(): void
  pause(): void
  resume(): void
}

export type ForwardResult =
  | { ok: true; channel: ForwardChannel }
  | { ok: false; refusal: ForwardRefusal; message: string }

/** Ask the connection for one channel to an address on the server itself. */
export type Forwarder = (host: string, port: number) => Promise<ForwardResult>

/**
 * The real one: `forwardOut` on a live connection.
 *
 * Everything about this that is not obvious is a property of the library and
 * was read out of `node_modules/ssh2/lib/client.js` at 1.17.0 rather than
 * assumed:
 *
 *  - It **throws synchronously** when the socket has gone, rather than calling
 *    back with an error, so the call is inside the `try`.
 *  - A refusal from the far end arrives as an ordinary `Error` carrying a
 *    numeric `reason` — `onChannelOpenFailure` in the library's `utils.js`
 *    attaches it — and that number is the only thing that separates *"this
 *    server will not forward"* from *"nothing is listening there"*.
 *  - There is no timeout of its own. A server that never answers the channel
 *    request would leave the callback pending forever, so the ceiling is here.
 */
export function forwardOn(client: ForwardingConnection): Forwarder {
  return (host, port) =>
    new Promise<ForwardResult>((resolve) => {
      let settled = false
      const done = (result: ForwardResult): void => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve(result)
      }
      const timer = setTimeout(() => {
        done({
          ok: false,
          refusal: 'unknown',
          message: 'That server did not answer about the address in time.',
        })
      }, OPEN_TIMEOUT_MS)
      timer.unref?.()

      try {
        /*
         * The first two arguments are what the *server* records this connection
         * as having come from, not where it goes. They reach its own log and
         * nothing else, so they say the loopback and a port of zero — which is
         * the truth: this end is not listening anywhere on the server's behalf.
         */
        client.forwardOut(LOOPBACK_V4, 0, host, port, (error, channel) => {
          if (error) {
            const reason = (error as Error & { reason?: number }).reason
            if (reason === PROHIBITED) {
              return done({
                ok: false,
                refusal: 'prohibited',
                message: error.message,
              })
            }
            if (reason === CONNECT_FAILED) {
              return done({ ok: false, refusal: 'unreachable', message: error.message })
            }
            return done({ ok: false, refusal: 'unknown', message: error.message })
          }
          done({ ok: true, channel })
        })
      } catch (error) {
        done({
          ok: false,
          refusal: 'unknown',
          message: error instanceof Error ? error.message : 'That connection is gone.',
        })
      }
    })
}

/* ----------------------------------------------- does this server allow it -- */

/**
 * Whether this server will let its own ports be opened here.
 *
 * The same three states every other fact about a server carries, and for the
 * same reason `facts.ts` argues at length: `no` is a fact about their server
 * and `cannot` is a fact about our ability to ask, and a screen that cannot
 * tell them apart states the first when it means the second.
 */
export type Forwarding =
  | { known: 'yes' }
  | { known: 'no'; why: string }
  | { known: 'cannot'; why: string }

/**
 * The sentence a person reads when their server will not do this.
 *
 * Exported because a test asserts it and a picker row renders it, and those two
 * must be the same string. Written here, beside the code that establishes it,
 * which is the rule this whole feature follows for every sentence with a fact
 * behind it.
 *
 * No mechanism in it. The setting is called `AllowTcpForwarding` and saying so
 * would be precise and would tell the reader nothing they can act on; what they
 * can act on is that the refusal came from the server and is a setting on it.
 *
 * Two short sentences rather than one long one, and that was measured on screen
 * rather than judged: `lostMachine` appends *"Addresses now open on this
 * machine."* to whatever this says before putting it in the notice band, and
 * the first draft ran to three lines there while also being the caption under a
 * row in a dropdown. A sentence read in two places has to fit both.
 */
export const WILL_NOT_FORWARD =
  'This server does not let another computer open the things it is running. That is a setting on ' +
  'the server itself.'

/**
 * Ask the server whether it forwards, without touching anything it is running.
 *
 * ## The question, and why it is asked of a port with nothing on it
 *
 * A connection request to a port **nothing is listening on** has exactly two
 * interesting answers, and they are the two this needs to tell apart:
 *
 *  - *administratively prohibited* — the server refused to make the connection
 *    at all. It never looked at whether anything was there.
 *  - *connect failed* — the server tried, and nothing answered.
 *
 * The second is a yes: a server that will try is a server that forwards. And
 * because the port has nothing on it, asking costs no real service a single
 * byte. That matters more than it sounds — the box this was proved against runs
 * somebody's live relay, and a probe that opened a connection to it to find out
 * whether probes are allowed would be exactly the kind of side effect a
 * read-only question must not have.
 *
 * ## The second question, and the trap it exists for
 *
 * `AllowTcpForwarding no` is not the only way a server says no. `PermitOpen`
 * names an allow-list of addresses, and on such a server *every* address
 * outside the list is answered `prohibited` — including the empty port above.
 * A single probe would therefore report "this server refuses" about a server
 * that forwards the one port somebody actually wants, and the row would be
 * greyed out over a working feature.
 *
 * So a `prohibited` answer is not believed on its own. When something **is**
 * known to be listening, the question is asked again about that, because that
 * is the address a person would really have opened. Only a server that refuses
 * both is reported as refusing. The second question is the only one that
 * touches a real service, it is one connection that is closed the instant it
 * opens, and it is asked only on the machines where the first one already said
 * no — which on an ordinary server is never.
 */
export async function askWhetherItForwards(
  forward: Forwarder,
  options: { listening?: readonly number[] } = {},
): Promise<Forwarding> {
  const first = await forward(LOOPBACK_V4, deadPort(options.listening ?? []))
  if (first.ok) {
    // Something answered on a port we picked as empty. Unlikely and harmless:
    // the channel opened, which is the whole question, so it is closed and the
    // answer is yes.
    first.channel.destroy()
    return { known: 'yes' }
  }
  if (first.refusal === 'unreachable') return { known: 'yes' }
  if (first.refusal === 'unknown') return { known: 'cannot', why: first.message }

  const real = (options.listening ?? [])[0]
  if (real === undefined) return { known: 'no', why: WILL_NOT_FORWARD }

  const second = await forward(LOOPBACK_V4, real)
  if (second.ok) {
    second.channel.destroy()
    return { known: 'yes' }
  }
  // `unreachable` here means the server tried to reach its own listening port
  // and could not, which is odd but is still a server that forwards.
  if (second.refusal === 'unreachable') return { known: 'yes' }
  if (second.refusal === 'unknown') return { known: 'cannot', why: second.message }
  return { known: 'no', why: WILL_NOT_FORWARD }
}

/**
 * A port on that server with nothing listening on it.
 *
 * Counted up from 1 rather than picked at random, because the point is a port
 * that is *certainly* empty and a random high port is only probably empty. Port
 * 1 has no assigned service and nothing binds it; the walk exists so that the
 * one server in the world that does bind it is still asked a fair question.
 *
 * Exported for the test that pins it: the failure this guards against is a
 * probe that quietly picks a port somebody's database is on.
 */
export function deadPort(listening: readonly number[]): number {
  const taken = new Set(listening)
  for (let port = 1; port < 65535; port += 1) {
    if (!taken.has(port)) return port
  }
  /* istanbul ignore next — a server listening on all 65,534 ports does not exist. */
  return 1
}

/* --------------------------------------------------------------- the host -- */

export interface SshTunnelHostDeps {
  /** Open one channel to an address on the server. {@link forwardOn} in the app. */
  forward: Forwarder
  /** Answer the guest half. Wired straight to `RemoteReach.handle`. */
  send(message: ServerMessage): void
  /** What the person calls this server, for the sentences they read. */
  name: string
}

export interface SshTunnelHost {
  /** One frame from the guest half. */
  handle(message: LocalhostMessage): void
  /** Everything goes: the connection dropped, or the app is quitting. */
  closeAll(): void
  /** How many ports are open through it. For a test, and for a panel later. */
  openPorts(): number[]
}

/**
 * One browser connection, and the channel carrying it — once there is one.
 *
 * ## Why `channel` is nullable, and what it cost to find out
 *
 * `net.createConnection` returns an object that accepts writes immediately and
 * queues them until the socket is up, so the relay's host half never had to
 * think about the gap between *asking* for a connection and *having* one.
 * **`forwardOut` has no such object.** Opening a channel is a request and a
 * reply on the SSH connection, and nothing exists until the far end answers.
 *
 * The gap is not theoretical and it is not small. A browser writes its request
 * the instant its socket connects, so `net.open` and the first `net.data`
 * arrive in the same turn of the event loop, one round trip before the channel
 * can possibly exist. The first version of this file held a do-nothing channel
 * in the slot for that instant; every request landed on it and was silently
 * dropped, and the page hung forever with no error anywhere — a green unit
 * suite, a clean typecheck, and a browser tab that never finished. The
 * end-to-end test in `reach.ssh.test.ts` is what caught it, which is exactly
 * the reason that test puts a real SSH server in the path.
 *
 * So the bytes wait here instead, and are handed over in order the moment the
 * channel opens.
 */
interface Stream {
  ch: string
  /** Null until the server has answered the channel request. */
  channel: ForwardChannel | null
  /** The browser's own bytes, held only for the instant before the channel exists. */
  waiting: Buffer[]
  /** Bytes sent to the browser that it has not said it has taken. */
  unacked: number
  paused: boolean
  closed: boolean
}

interface Tunnel {
  id: string
  port: number
  /** The loopback literal that proved to answer, so every connection agrees. */
  host: string
  streams: Set<string>
}

/**
 * The half of the tunnel conversation that lives on the server's side of the
 * wire — except that here it lives in this process, on the far end of an SSH
 * connection rather than a relay.
 *
 * Deliberately shaped like `createTunnelHub` in `remote/tunnel.ts`, frame for
 * frame, because the guest half cannot tell the two apart and must not be able
 * to. Where that one holds a `net.Socket` this holds an SSH channel; where it
 * decides which loopback to dial by scanning this machine, this decides by
 * asking the server; everything between those two facts is the same code
 * written against a different object, and the places where it had to differ are
 * commented as such.
 */
export function createSshTunnelHost(deps: SshTunnelHostDeps): SshTunnelHost {
  const tunnels = new Map<string, Tunnel>()
  const streams = new Map<string, Stream>()
  /**
   * Opens that have not finished, so a `tunnel.close` can cancel one.
   *
   * The same guard `tunnel.ts` carries and for the same reason: opening is the
   * one asynchronous thing here, and without this a close sent while a channel
   * request is still in flight would find nothing to close, return, and then be
   * overtaken by the open it was meant to cancel — leaving a tunnel nobody
   * wants holding a channel on somebody's server.
   */
  const opening = new Map<string, { cancelled: boolean }>()

  /**
   * Close one browser connection, and say whether what is queued for the server
   * has to reach it first.
   *
   * The argument is written out in full on `dropStream` in
   * `localhost-reach.ts` and on the matching one in `tunnel.ts`; this is the
   * third place it applies and the reasoning does not change. What is queued on
   * *this* side is the browser's own bytes on their way to the server — a form
   * post, a file upload — so discarding them makes an upload arrive short, the
   * server waits for the rest of a `Content-Length` it will never get, and the
   * page hangs rather than failing. `end()` writes what is queued and then
   * sends end-of-file; `destroy()` does not.
   *
   * There is no linger timer here, unlike the two socket versions. An SSH
   * channel is not a file descriptor: what a stuck `end()` holds is one channel
   * number on a connection this app owns, and {@link closeAll} takes every one
   * of them down when the connection goes. The two socket halves needed the
   * ceiling because a socket the peer has stopped reading is a descriptor held
   * until the process exits.
   */
  function dropStream(ch: string, tell: boolean, ending: 'flush' | 'discard'): void {
    const stream = streams.get(ch)
    if (!stream) return
    streams.delete(ch)
    for (const tunnel of tunnels.values()) tunnel.streams.delete(ch)
    stream.closed = true
    /*
     * Nothing to be orderly with yet.
     *
     * A stream closed before its channel opened has nothing on the far end to
     * flush into, and what is queued here can no longer be delivered *back*
     * either: the guest half closes the browser's socket before it sends this
     * frame, so a reply would arrive at a connection that has gone. The bytes
     * are dropped and the channel, when it turns up, is destroyed by
     * `openStream` rather than wired to anything.
     */
    stream.waiting.length = 0
    if (stream.channel === null) {
      if (tell) deps.send({ t: 'net.close', ch })
      return
    }
    if (ending === 'flush') stream.channel.end()
    else stream.channel.destroy()
    if (tell) deps.send({ t: 'net.close', ch })
  }

  function closeTunnel(id: string, message: string): boolean {
    const pending = opening.get(id)
    if (pending) {
      pending.cancelled = true
      opening.delete(id)
      deps.send({ t: 'tunnel.closed', id, message })
      return true
    }
    const tunnel = tunnels.get(id)
    if (!tunnel) return false
    tunnels.delete(id)
    // Copied first — `dropStream` mutates the set being walked. `'discard'`,
    // because the tunnel itself is going and there is nothing left to be
    // orderly for.
    for (const ch of [...tunnel.streams]) dropStream(ch, false, 'discard')
    deps.send({ t: 'tunnel.closed', id, message })
    return true
  }

  /**
   * Read from the server and post it to the guest half, in bounded pieces.
   *
   * The same cut both other halves make: one `data` event is whatever arrived,
   * base64 adds a third on top, and a piece that overshot the message cap would
   * be refused by a parser and take the whole conversation with it. The cap is
   * shared from `remote/protocol.ts` rather than restated, so there is one
   * number to be right about.
   */
  function forward(stream: Stream, chunk: Buffer): void {
    for (let at = 0; at < chunk.length; at += MAX_NET_CHUNK_BYTES) {
      const piece = chunk.subarray(at, at + MAX_NET_CHUNK_BYTES)
      stream.unacked += piece.length
      deps.send({ t: 'net.data', ch: stream.ch, data: piece.toString('base64') })
    }
    if (!stream.paused && stream.unacked >= NET_WINDOW_BYTES) {
      stream.paused = true
      // Only reachable once the channel exists — this runs off its own `data`
      // event — so there is no null case to answer here.
      stream.channel?.pause()
    }
  }

  /**
   * Prove the port answers, and remember which loopback it answered on.
   *
   * A whole channel opened and immediately closed to answer a yes/no question,
   * exactly as `tunnel.ts` dials and hangs up for the same reason: it buys
   * `tunnel.opened` the meaning *"bytes have already been carried to this
   * address and back"*, which is what lets a port that is not running become
   * one written sentence instead of a browser error page. The alternative —
   * answering `tunnel.opened` on faith — moves the failure to the first
   * connection, where the only thing that can be said about it is that the
   * connection was reset.
   */
  async function openTunnel(id: string, port: number): Promise<void> {
    if (tunnels.has(id) || opening.has(id)) {
      deps.send({ t: 'tunnel.closed', id, message: 'A tunnel with that id is already open.' })
      return
    }
    if (tunnels.size + opening.size >= MAX_TUNNELS) {
      deps.send({
        t: 'tunnel.closed',
        id,
        message: `${deps.name} already has ${MAX_TUNNELS} addresses open here. Close one first.`,
      })
      return
    }

    const pending = { cancelled: false }
    opening.set(id, pending)
    let host: string | null = null
    let refusal: ForwardRefusal = 'unreachable'
    try {
      for (const candidate of [LOOPBACK_V4, LOOPBACK_V6]) {
        const result = await deps.forward(candidate, port)
        if (pending.cancelled) {
          if (result.ok) result.channel.destroy()
          return
        }
        if (result.ok) {
          result.channel.destroy()
          host = candidate
          break
        }
        refusal = result.refusal
        // A server that refuses to forward at all refuses both addresses, and
        // asking the second is a round trip spent confirming what the first
        // one said.
        if (result.refusal === 'prohibited') break
      }
    } finally {
      opening.delete(id)
    }

    if (pending.cancelled) return

    if (host === null) {
      deps.send({ t: 'tunnel.closed', id, message: whyNot(refusal, port, deps.name) })
      return
    }

    tunnels.set(id, { id, port, host, streams: new Set() })
    deps.send({ t: 'tunnel.opened', id, port })
  }

  async function openStream(ch: string, tunnelId: string): Promise<void> {
    const tunnel = tunnels.get(tunnelId)
    /*
     * Every refusal below is the same bare `net.close`, with no reason on it,
     * and that is not laziness. The far end of this stream is one TCP
     * connection from a browser; the only thing a browser can do with an
     * explanation is discard it. The reason a person needs is attached to the
     * *tunnel*, which is the thing they asked for.
     */
    if (!tunnel || streams.has(ch)) return deps.send({ t: 'net.close', ch })
    if (streams.size >= MAX_STREAMS) return deps.send({ t: 'net.close', ch })

    // Reserved before the await, so that sixty-four connections arriving in one
    // burst — which is what a page full of images is — cannot all pass the
    // ceiling above while none of them has finished opening yet.
    const stream: Stream = {
      ch,
      channel: null,
      waiting: [],
      unacked: 0,
      paused: false,
      closed: false,
    }
    streams.set(ch, stream)
    tunnel.streams.add(ch)

    // The address was chosen and proved once at open, so every connection
    // inside one tunnel goes to the same place and none of them re-runs the
    // choice.
    const result = await deps.forward(tunnel.host, tunnel.port)
    if (!result.ok || stream.closed || !streams.has(ch)) {
      if (result.ok) result.channel.destroy()
      if (streams.has(ch)) dropStream(ch, true, 'discard')
      return
    }
    stream.channel = result.channel

    result.channel.on('data', (chunk: Buffer) => forward(stream, chunk))
    // Handed over in the order they arrived, before anything else is written
    // to this channel. Out of order here is a corrupted request body rather
    // than a lost one, which is worse.
    for (const queued of stream.waiting.splice(0)) deliver(stream, queued)
    result.channel.on('error', () => dropStream(ch, true, 'discard'))
    /*
     * 'end' as well as 'close', for the reason both other halves give: a server
     * that answers and hangs up sends end-of-file, and waiting for 'close'
     * would hold the browser's connection open past the end of the response.
     *
     * It flushes, because a server that half-closes after answering is still
     * reading — that is what a half-close means — and the tail of an upload
     * still queued here is owed to it.
     */
    result.channel.on('end', () => dropStream(ch, true, 'flush'))
    result.channel.on('close', () => dropStream(ch, true, 'discard'))
  }

  /**
   * Put the browser's bytes on the channel, acknowledging what it took.
   *
   * The acknowledgement comes from the write callback rather than from beside
   * the write, so it means *the connection has this* rather than *we called
   * write*. That is the difference between the window measuring the far end's
   * appetite and it measuring nothing at all — the same argument both other
   * halves of this pipe make about their own sockets.
   */
  function deliver(stream: Stream, bytes: Buffer): void {
    stream.channel?.write(bytes, () => {
      if (stream.closed) return
      deps.send({ t: 'net.ack', ch: stream.ch, bytes: bytes.length })
    })
  }

  function write(ch: string, data: string): void {
    const stream = streams.get(ch)
    if (!stream || stream.closed) return
    const bytes = Buffer.from(data, 'base64')
    if (bytes.length === 0) return
    // Held rather than dropped while the channel request is in flight. See the
    // note on `Stream`: this is the instant an entire HTTP request lands in,
    // and losing it hangs the page with nothing to show for it.
    if (stream.channel === null) {
      stream.waiting.push(bytes)
      return
    }
    deliver(stream, bytes)
  }

  function acknowledge(ch: string, bytes: number): void {
    const stream = streams.get(ch)
    if (!stream || stream.closed) return
    stream.unacked = Math.max(0, stream.unacked - bytes)
    if (stream.paused && stream.unacked < NET_WINDOW_BYTES) {
      stream.paused = false
      // A stream with no channel yet has sent nothing and cannot be paused, so
      // this is unreachable before it opens — answered rather than assumed.
      stream.channel?.resume()
    }
  }

  return {
    handle(message: LocalhostMessage): void {
      switch (message.t) {
        case 'ports':
          // The guest half never sends this — it asks a server what is
          // listening through the probe, which is a different question with a
          // different answer shape. Ignored rather than answered, because an
          // empty `ports` frame would be this end claiming a server serves
          // nothing.
          return
        case 'tunnel.open':
          void openTunnel(message.id, message.port)
          return
        case 'tunnel.close':
          // Answered even when there is no such tunnel: the other half is
          // telling us it has taken the page down, and it should hear the same
          // thing back whether or not this end had already forgotten it.
          if (!closeTunnel(message.id, 'Closed here.')) {
            deps.send({ t: 'tunnel.closed', id: message.id, message: 'Closed here.' })
          }
          return
        case 'net.open':
          void openStream(message.ch, message.tunnel)
          return
        case 'net.data':
          write(message.ch, message.data)
          return
        case 'net.ack':
          acknowledge(message.ch, message.bytes)
          return
        case 'net.close':
          // No echo: the other half closed it, so it already knows. `'flush'`,
          // for the reason on `dropStream` — the browser finished its request
          // and hung up, and the tail of that request can still be queued for
          // the server.
          dropStream(message.ch, false, 'flush')
          return
      }
    },

    closeAll(): void {
      for (const pending of opening.values()) pending.cancelled = true
      opening.clear()
      for (const ch of [...streams.keys()]) dropStream(ch, false, 'discard')
      tunnels.clear()
    },

    openPorts(): number[] {
      return [...tunnels.values()].map((tunnel) => tunnel.port).sort((a, b) => a - b)
    },
  }
}

/**
 * The sentence for a port that would not open, written where the refusal is read.
 *
 * Three sentences rather than one, because they send a person to three
 * different places: the server's settings, whatever should be running on that
 * port, or nowhere at all because we genuinely do not know. Exported so a test
 * can hold the wording and a panel can render it without composing its own.
 */
export function whyNot(refusal: ForwardRefusal, port: number, name: string): string {
  if (refusal === 'prohibited') return WILL_NOT_FORWARD
  if (refusal === 'unreachable') return `Nothing is answering on port ${port} on ${name}.`
  return `${name} could not be asked about port ${port} just now.`
}
