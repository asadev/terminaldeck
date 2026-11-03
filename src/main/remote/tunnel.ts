/**
 * The desktop's half of "see your localhost on your phone".
 *
 * A phone taps a port; this dials that port on this machine's loopback and
 * copies bytes between that socket and the sealed channel the phone is already
 * on. That is the whole feature, and the smallness is the point — it is a
 * **byte pipe, not an HTTP proxy**.
 *
 * ## Why bytes and not requests
 *
 * The obvious design is to parse the phone's HTTP request, replay it against the
 * dev server, and send the response back. It is also wrong, and expensively so:
 * a request/response proxy has to reimplement chunked transfer, keep-alive,
 * `Expect: 100-continue`, trailers, server-sent events and the WebSocket
 * upgrade, and it gets one of them wrong in a way that only shows up in one
 * framework. Worse, it has to rewrite `Host` and absolute URLs, and then every
 * redirect and every cookie domain is a decision somebody has to get right.
 *
 * Tunnelling the TCP stream instead makes all of that somebody else's problem —
 * specifically, the dev server's and the browser's, which already agree. Hot
 * reload works because a WebSocket upgrade is just bytes. Service workers,
 * cookies and `fetch` work because the page really is served from an HTTP origin
 * on the phone's own loopback, at the same port number, so nothing about it
 * needs rewriting.
 *
 * ## The security boundary, in four sentences
 *
 * Only an authenticated, approved device gets here at all — the server hands a
 * message to this module only after `hello` has succeeded, which is the same
 * gate that guards attaching to a terminal. The only hosts this will ever dial
 * are the two loopback literals below; there is no field for a host and no code
 * path that builds one, so a phone cannot reach the printer on this machine's
 * LAN or a machine on its tailnet. The only ports it will dial are the ones a
 * fresh scan says are being listened on right now, minus the app's own, so a
 * phone cannot use this to sweep the loopback for services that are not there.
 * And nothing is reachable until a `tunnel.open` arrives, which is a message
 * this app's phone client sends only when a person taps a port — the tap is the
 * consent, and closing the view is the revocation.
 *
 * ## Flow control
 *
 * `net.ack` exists because a tunnelled socket has no window of its own. Each
 * side acknowledges bytes once its own socket has taken them, and a sender that
 * is `NET_WINDOW_BYTES` ahead stops reading. Without it, a phone on a train
 * loading a 40 MB source map would sit in the desktop's heap until the server's
 * backpressure cap dropped the phone — a feature that fails only on the large
 * files, which is the worst way for it to fail.
 */

import { createConnection, type Socket } from 'node:net'
import type { PortFamilies } from '../dev-ports'
import {
  MAX_NET_CHUNK_BYTES,
  NET_WINDOW_BYTES,
  type LocalPort,
  type ServerMessage,
} from './protocol'

/**
 * The only two hosts this module will ever connect to.
 *
 * Literals, not a name: `localhost` goes through the resolver, and a resolver
 * is a thing that can be told to answer with something else — an `/etc/hosts`
 * line, a DNS search domain, a VPN's split resolver. These two cannot be
 * pointed anywhere. There is deliberately no way for a caller to supply a host;
 * the *choice between them* is made from the scan, never from the phone.
 *
 * ## Why there are two, which cost a night on Windows
 *
 * `127.0.0.1` alone loses the common case on Windows. Windows resolves
 * `localhost` to `::1` first, so Vite, Next and `node --host localhost` bind
 * what the name gave them and bind **only** that. `platform/ports.ts` accepts
 * `::1`, `[::1]` and `::` as locally reachable, so the scan lists the port, the
 * phone is offered it, `listening()` agrees it is there — and the dial is
 * refused. `openStream` answers that with a bare `net.close` carrying no
 * reason, which is right for a browser and here meant the phone showed a blank
 * page with nothing anywhere saying why. A port that is listed and unreachable
 * is worse than one that is not listed.
 *
 * Measured on `desktop-ddgmncv`, not reasoned about:
 *
 *     listening {"address":"::1","family":"IPv6","port":5199}
 *     TCP    [::1]:5199    [::]:0    LISTENING    22200
 *     127.0.0.1  ERROR ECONNREFUSED
 *     ::1        CONNECTED
 *
 * macOS never sees it because the same servers bind `127.0.0.1` first there.
 *
 * ## Which one a tunnel uses, and why it is decided once
 *
 * The family comes from the scan, which is the only thing that knows it, and it
 * is resolved **at `tunnel.open`, once, by actually dialling** — not per stream
 * and not by guessing. `openTunnel` then pins the winner on the tunnel, so
 * every browser connection inside it goes to an address something has already
 * accepted a connection on. When neither answers, the tunnel is refused with a
 * sentence instead of opened as a pipe that cannot carry bytes.
 *
 * The wire type gains nothing. A phone names a port; the desktop decides where
 * that port lives. Adding a family to `LocalPort` would be three clients having
 * to agree about an answer only this process can produce.
 */
const LOOPBACK_V4 = '127.0.0.1'
const LOOPBACK_V6 = '::1'

/** One live tunnel, as the desktop lists it. */
export interface TunnelInfo {
  id: string
  port: number
  /** Byte streams currently open inside it — roughly, browser connections. */
  streams: number
  openedAt: number
}

/**
 * Sockets are a process-wide resource, so the ceiling is too.
 *
 * Per-connection caps alone would let sixty-four paired phones open sixty-four
 * streams each and exhaust the descriptors of the process running the user's
 * terminals. One budget, shared by every hub the endpoint makes.
 */
export interface StreamBudget {
  take(): boolean
  give(): void
}

export function streamBudget(ceiling: number): StreamBudget {
  let used = 0
  return {
    take(): boolean {
      if (used >= ceiling) return false
      used += 1
      return true
    },
    give(): void {
      if (used > 0) used -= 1
    },
  }
}

/**
 * A scanned port, as this module wants it.
 *
 * `families` is optional so that every caller which already had a `LocalPort[]`
 * still type-checks — `scripts/remote-host.ts`, the socket tests, a stand-in.
 * An entry without it is treated as "could be either", which is what this
 * module assumed about every port until today.
 */
export interface TunnelPort extends LocalPort {
  families?: PortFamilies
}

export interface TunnelDeps {
  /** What is listening on this machine. Injected; the real one shells out to `lsof`. */
  scan(): Promise<readonly TunnelPort[]>
  /** Send a frame to the phone this hub belongs to. */
  send(message: ServerMessage): void
  /** Ports this app is itself serving on, which it will not tunnel to. */
  reserved?: number[]
  budget?: StreamBudget
  /** Fires when the tunnel list changes, so the desktop can redraw it. */
  onChange?: () => void
  /**
   * Test seam. Defaults to a real loopback socket.
   *
   * `host` is one of the two literals above and never anything a phone chose;
   * it is a parameter so a test can assert *which* loopback was dialled, which
   * is the whole of the Windows bug.
   */
  connect?: (port: number, host: string) => Socket
  now?: () => number
}

export interface TunnelHub {
  /** The `localhost` verbs. Anything else is not this module's business. */
  handle(message: LocalhostMessage): void
  list(): TunnelInfo[]
  /**
   * Stop one tunnel from the Mac. False when it had already gone.
   *
   * This is the other half of "killable from either end": the phone hears a
   * `tunnel.closed` carrying this sentence and takes its page down, rather than
   * being left showing a screenshot of a server it can no longer reach.
   */
  stop(id: string, message: string): boolean
  /** The phone is gone. Every socket this hub holds goes with it. */
  closeAll(): void
}

/** The subset of `ClientMessage` this module answers. */
export type LocalhostMessage =
  | { t: 'ports' }
  | { t: 'tunnel.open'; id: string; port: number }
  | { t: 'tunnel.close'; id: string }
  | { t: 'net.open'; ch: string; tunnel: string }
  | { t: 'net.data'; ch: string; data: string }
  | { t: 'net.ack'; ch: string; bytes: number }
  | { t: 'net.close'; ch: string }

/** Tunnels one phone may hold at once. A person looks at one page, maybe two. */
const MAX_TUNNELS = 4

/** Streams one phone may hold. WebKit opens six per origin, plus sockets. */
const MAX_STREAMS_PER_CONNECTION = 64

/** Streams the whole app will hold, across every phone. */
export const MAX_STREAMS_TOTAL = 256

/**
 * How long a dial to a port that is listening may take.
 *
 * A port that `lsof` reports and that then does not accept within this is a
 * process wedged mid-start, and the browser is better told quickly.
 */
const DIAL_TIMEOUT_MS = 5000

/**
 * How a stream's socket is taken down. See {@link createTunnelHub}'s `dropStream`.
 *
 * The same pair, with the same meanings, as the guest half in
 * `localhost-reach.ts`. Two spellings of this would be two chances to get the
 * argument wrong on one side only, which is exactly how the guest half came to
 * be wrong for as long as it was.
 */
type StreamEnding = 'flush' | 'discard'

/**
 * How long a flushing close may take before the socket is taken down anyway.
 *
 * `end()` writes what is queued and then sends FIN, and how long that takes
 * belongs to the peer — a dev server that has stopped reading leaves the queue
 * where it is. Without a ceiling that socket is a descriptor this process holds
 * until it quits, which is the leak the flush would have traded for the
 * truncation. Five seconds is far longer than a loopback flush can honestly
 * need and short enough that a peer which has gone away costs a timer rather
 * than a file descriptor. The timer is unref'd, so it never holds the app open.
 */
const FLUSH_LINGER_MS = 5_000

/** Send what is queued, then close — with a ceiling on how long that may take. */
function flushAndClose(socket: Socket): void {
  if (socket.destroyed) return
  const linger = setTimeout(() => socket.destroy(), FLUSH_LINGER_MS)
  linger.unref?.()
  socket.once('close', () => clearTimeout(linger))
  socket.end()
}

interface Stream {
  id: string
  tunnel: string
  socket: Socket
  /** Bytes sent to the phone that it has not said it has written yet. */
  unacked: number
  paused: boolean
  closed: boolean
}

interface Tunnel {
  id: string
  port: number
  /** The loopback literal `openTunnel` proved this port answers on. */
  host: string
  openedAt: number
  streams: Set<string>
}

/**
 * Which loopbacks to try, in order, for a port the scan described.
 *
 * IPv4 first when both are live, because that is what every tunnel did before
 * this existed and what macOS still resolves to — the fix adds a fallback, it
 * does not move the common case. A port whose families are unknown gets both,
 * for the same reason: it behaves exactly as it used to and then tries the one
 * it never tried.
 */
export function loopbackCandidates(families: PortFamilies | undefined): readonly string[] {
  if (!families) return [LOOPBACK_V4, LOOPBACK_V6]
  if (families.v4 && families.v6) return [LOOPBACK_V4, LOOPBACK_V6]
  if (families.v6) return [LOOPBACK_V6]
  return [LOOPBACK_V4]
}

export function createTunnelHub(deps: TunnelDeps): TunnelHub {
  const now = deps.now ?? Date.now
  const connect = deps.connect ?? ((port: number, host: string) => createConnection({ host, port }))
  const budget = deps.budget ?? streamBudget(MAX_STREAMS_TOTAL)
  const reserved = new Set(deps.reserved ?? [])
  const tunnels = new Map<string, Tunnel>()
  const streams = new Map<string, Stream>()
  /**
   * Tunnels whose port scan has not come back yet.
   *
   * Opening is the one thing here that is asynchronous, and that breaks the
   * property every other message on this connection relies on: that frames are
   * handled in the order they arrived. A `tunnel.close` sent while the scan is
   * still running would find nothing to close, return, and then be overtaken by
   * an open that installs the tunnel it was meant to cancel — a page the user
   * has already dismissed, left holding a socket. So an open is visible from the
   * moment it starts, and a close that lands on one cancels it.
   */
  const opening = new Map<string, { cancelled: boolean }>()

  function changed(): void {
    try {
      deps.onChange?.()
    } catch (error) {
      console.error('[tunnel] change listener threw:', error)
    }
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
    // Copied first: `dropStream` mutates the set this is walking.
    //
    // `'discard'`: the tunnel itself is being taken down and the guest has
    // already been told, so nothing on either side is still waiting for these
    // bytes. A lingering socket here would be a descriptor held open past the
    // tunnel that owned it.
    for (const streamId of [...tunnel.streams]) dropStream(streamId, false, 'discard')
    deps.send({ t: 'tunnel.closed', id, message })
    changed()
    return true
  }

  /**
   * Close one connection to the dev server, and say whether what is still
   * queued for it has to arrive first.
   *
   * The guest half of this argument is written out at length in
   * `localhost-reach.ts`, on its own `dropStream`, and it is the same argument
   * with the direction reversed: `destroy()` throws away everything Node has
   * accepted from `write()` but not yet handed to the kernel — measured on this
   * Mac at 66.8 MB of a 64 MB write lost, against nothing lost through `end()` —
   * and the queue is only ever non-empty once a body is larger than the socket's
   * in-flight capacity, which is about 320 KB here and **64 KB on Windows**.
   *
   * What is queued on *this* side is the browser's own bytes on their way to the
   * dev server: a form post, a file upload, a long PUT. So the failure this
   * prevents here is an upload silently arriving short — the server sees fewer
   * bytes than `Content-Length` promised and hangs waiting for the rest, which
   * is the same never-settles shape the guest side produced, one machine over.
   */
  function dropStream(id: string, tell: boolean, ending: StreamEnding): void {
    const stream = streams.get(id)
    if (!stream) return
    streams.delete(id)
    tunnels.get(stream.tunnel)?.streams.delete(id)
    if (!stream.closed) {
      stream.closed = true
      budget.give()
    }
    if (ending === 'flush') flushAndClose(stream.socket)
    else stream.socket.destroy()
    if (tell) deps.send({ t: 'net.close', ch: id })
  }

  /**
   * Read from the dev server and post it to the phone, in bounded pieces.
   *
   * One `data` event can be far larger than a frame — the kernel hands over
   * whatever has arrived — so it is cut to `MAX_NET_CHUNK_BYTES` before base64
   * takes a third more on top. A chunk that overshot the message cap would be
   * refused by the far end's parser and close the whole connection, taking the
   * terminal session with it.
   */
  function forward(stream: Stream, chunk: Buffer): void {
    for (let at = 0; at < chunk.length; at += MAX_NET_CHUNK_BYTES) {
      const piece = chunk.subarray(at, at + MAX_NET_CHUNK_BYTES)
      stream.unacked += piece.length
      deps.send({ t: 'net.data', ch: stream.id, data: piece.toString('base64') })
    }
    if (!stream.paused && stream.unacked >= NET_WINDOW_BYTES) {
      stream.paused = true
      stream.socket.pause()
    }
  }

  async function offerPorts(): Promise<void> {
    let ports: readonly TunnelPort[]
    try {
      ports = await deps.scan()
    } catch (error) {
      // A scan that failed is not a phone's problem to solve, and an empty list
      // is the honest answer: this machine cannot say what is listening.
      console.error('[tunnel] port scan failed:', error)
      ports = []
    }
    deps.send({
      t: 'ports',
      // Rebuilt field by field rather than passed through. The scan carries
      // more than the wire type does — the address families — and `LocalPort`
      // is a contract with three clients: whatever this sends becomes what they
      // are allowed to see. Copying the three named fields makes it impossible
      // for a field added to the scan to reach a phone by accident.
      ports: ports
        .filter((entry) => !reserved.has(entry.port))
        .map((entry): LocalPort => ({ port: entry.port, process: entry.process, guessed: entry.guessed })),
    })
  }

  /**
   * Is this a port this machine is willing to dial, and where does it answer?
   *
   * Asked against a fresh scan every time rather than against whatever was last
   * offered, and that is the check that keeps this from being a port scanner: a
   * phone can only reach a port that something here is *already* serving, so a
   * `tunnel.open` for a port nothing is listening on is refused before a socket
   * exists, and cannot be used to learn which ports would have answered.
   */
  async function listening(port: number): Promise<TunnelPort | null> {
    if (reserved.has(port)) return null
    try {
      return (await deps.scan()).find((entry) => entry.port === port) ?? null
    } catch {
      return null
    }
  }

  /**
   * Connect, then hang up. True when something accepted.
   *
   * A whole TCP connection to answer a yes/no question, and worth it: the scan
   * can only say a socket is bound, and on Windows that is exactly the claim
   * that turned out not to imply reachability. One of these per `tunnel.open` —
   * per *tap*, not per browser connection — buys `tunnel.opened` the meaning
   * "bytes have already gone to this address and come back", which is what lets
   * the failure be a sentence on the phone instead of a blank page.
   */
  function reachable(port: number, host: string): Promise<boolean> {
    return new Promise((resolve) => {
      const socket = connect(port, host)
      let settled = false
      const done = (answer: boolean): void => {
        if (settled) return
        settled = true
        socket.destroy()
        resolve(answer)
      }
      socket.setTimeout(DIAL_TIMEOUT_MS, () => done(false))
      socket.once('connect', () => done(true))
      socket.once('error', () => done(false))
    })
  }

  async function openTunnel(id: string, port: number): Promise<void> {
    if (tunnels.has(id) || opening.has(id)) {
      deps.send({ t: 'tunnel.closed', id, message: 'A tunnel with that id is already open.' })
      return
    }
    if (tunnels.size + opening.size >= MAX_TUNNELS) {
      deps.send({
        t: 'tunnel.closed',
        id,
        message: `This phone already has ${MAX_TUNNELS} ports open. Close one first.`,
      })
      return
    }

    const pending = { cancelled: false }
    // Held for the whole of the asynchronous work, not just the scan: the dial
    // below is the longer half, and a tunnel that is invisible while it is being
    // proved is one a `tunnel.close` cannot cancel and one `MAX_TUNNELS` cannot
    // count.
    opening.set(id, pending)
    let host: string | null = null
    let tried: readonly string[] = []
    try {
      const entry = await listening(port)
      if (pending.cancelled) return
      if (entry === null) {
        deps.send({
          t: 'tunnel.closed',
          id,
          message: `Nothing is listening on port ${port} on that computer any more.`,
        })
        return
      }

      tried = loopbackCandidates(entry.families)
      for (const candidate of tried) {
        if (await reachable(port, candidate)) {
          host = candidate
          break
        }
        // Re-read after every dial: each one is a turn of the event loop, and a
        // phone that closed the view is not owed a second five-second timeout.
        if (pending.cancelled) return
      }
    } finally {
      opening.delete(id)
    }

    // A close overtook the scan or the dial. It has already answered the phone;
    // saying anything else here would contradict it.
    if (pending.cancelled) return

    if (host === null) {
      deps.send({
        t: 'tunnel.closed',
        id,
        message:
          `Port ${port} is listed as listening but refused a connection on ` +
          `${tried.join(' and ')}. Whatever holds it is not accepting connections.`,
      })
      return
    }

    tunnels.set(id, { id, port, host, openedAt: now(), streams: new Set() })
    deps.send({ t: 'tunnel.opened', id, port })
    changed()
  }

  function openStream(ch: string, tunnelId: string): void {
    const tunnel = tunnels.get(tunnelId)
    // Every refusal below is the same `net.close`, with no reason attached. The
    // browser end of this is one TCP connection; the only thing it can do with
    // an explanation is discard it, and a phone that could tell "no such
    // tunnel" from "out of descriptors" would learn nothing it may act on.
    if (!tunnel || streams.has(ch)) return deps.send({ t: 'net.close', ch })
    if (streams.size >= MAX_STREAMS_PER_CONNECTION || !budget.take()) {
      return deps.send({ t: 'net.close', ch })
    }

    // `tunnel.host`, not a constant: the address was chosen and proved once at
    // open, so every connection inside one tunnel goes to the same place and
    // none of them re-runs the choice.
    const socket = connect(tunnel.port, tunnel.host)
    const stream: Stream = { id: ch, tunnel: tunnelId, socket, unacked: 0, paused: false, closed: false }
    streams.set(ch, stream)
    tunnel.streams.add(ch)
    changed()

    // Keystroke-sized writes go through this too — a WebSocket frame carrying a
    // hot-reload notice is forty bytes — and Nagle would hold each one.
    socket.setNoDelay(true)
    socket.setTimeout(DIAL_TIMEOUT_MS, () => {
      // Only ever armed for the dial: cleared on connect, because a live page
      // holding an idle keep-alive socket is normal and must not be torn down.
      if (!stream.closed) dropStream(ch, true, 'discard')
    })
    socket.once('connect', () => socket.setTimeout(0))
    socket.on('data', (chunk: Buffer) => forward(stream, chunk))
    socket.on('error', () => dropStream(ch, true, 'discard'))
    // 'end' as well as 'close': a dev server that answers and hangs up sends a
    // FIN, and waiting for 'close' would hold the browser's socket open past the
    // end of the response.
    //
    // It flushes: a server that half-closes after answering is still reading —
    // that is what a half-close means — and the tail of an upload still queued
    // here is owed to it.
    socket.on('end', () => dropStream(ch, true, 'flush'))
    socket.on('close', () => dropStream(ch, true, 'discard'))
  }

  function write(ch: string, data: string): void {
    const stream = streams.get(ch)
    if (!stream || stream.closed) return
    const bytes = Buffer.from(data, 'base64')
    if (bytes.length === 0) return
    // The acknowledgement is sent from the write callback rather than beside
    // the write, so it means "the kernel has this" rather than "we called
    // write". That is the difference between the window measuring the far end's
    // appetite and it measuring nothing at all.
    stream.socket.write(bytes, () => {
      if (stream.closed) return
      deps.send({ t: 'net.ack', ch, bytes: bytes.length })
    })
  }

  function acknowledge(ch: string, bytes: number): void {
    const stream = streams.get(ch)
    if (!stream || stream.closed) return
    stream.unacked = Math.max(0, stream.unacked - bytes)
    if (stream.paused && stream.unacked < NET_WINDOW_BYTES) {
      stream.paused = false
      stream.socket.resume()
    }
  }

  return {
    handle(message: LocalhostMessage): void {
      switch (message.t) {
        case 'ports':
          void offerPorts()
          return
        case 'tunnel.open':
          void openTunnel(message.id, message.port)
          return
        case 'tunnel.close':
          // Answered even when there is no such tunnel: the phone is telling us
          // it has taken the page down, and it should hear the same thing back
          // whether or not we had already forgotten the tunnel.
          if (!closeTunnel(message.id, 'Closed on the phone.')) {
            deps.send({ t: 'tunnel.closed', id: message.id, message: 'Closed on the phone.' })
          }
          return
        case 'net.open':
          openStream(message.ch, message.tunnel)
          return
        case 'net.data':
          write(message.ch, message.data)
          return
        case 'net.ack':
          acknowledge(message.ch, message.bytes)
          return
        case 'net.close':
          // No echo: the phone closed it, so it already knows.
          //
          // `'flush'`, for the reason on `dropStream`: the browser over there
          // finished its request and hung up, and the tail of that request can
          // still be queued for the dev server here.
          dropStream(message.ch, false, 'flush')
          return
      }
    },

    list(): TunnelInfo[] {
      return [...tunnels.values()]
        .map((tunnel) => ({
          id: tunnel.id,
          port: tunnel.port,
          streams: tunnel.streams.size,
          openedAt: tunnel.openedAt,
        }))
        .sort((a, b) => a.openedAt - b.openedAt)
    },

    stop(id: string, message: string): boolean {
      return closeTunnel(id, message)
    },

    closeAll(): void {
      // `'discard'`: the link has gone, so nothing is left to deliver these to.
      for (const id of [...streams.keys()]) dropStream(id, false, 'discard')
      // Opens still waiting on a scan are cancelled rather than left to install
      // a tunnel against a phone that has gone.
      for (const pending of opening.values()) pending.cancelled = true
      opening.clear()
      const had = tunnels.size > 0
      tunnels.clear()
      // Nothing is announced when there was nothing: this runs on every
      // disconnection, and most phones never open a tunnel at all.
      if (had) changed()
    },
  }
}
