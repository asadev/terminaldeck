/**
 * The Mac's half of "see your localhost on your phone".
 *
 * A phone taps a port; this dials `127.0.0.1:<port>` and copies bytes between
 * that socket and the sealed channel the phone is already on. That is the whole
 * feature, and the smallness is the point — it is a **byte pipe, not an HTTP
 * proxy**.
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
 * gate that guards attaching to a terminal. The only host this will ever dial is
 * `127.0.0.1`; there is no field for a host and no code path that builds one, so
 * a phone cannot reach the printer on the Mac's LAN or a machine on its tailnet.
 * The only ports it will dial are the ones a fresh scan says are being listened
 * on right now, minus the app's own, so a phone cannot use this to sweep the
 * Mac's loopback for services that are not there. And nothing is reachable until
 * a `tunnel.open` arrives, which is a message this app's phone client sends only
 * when a person taps a port — the tap is the consent, and closing the view is
 * the revocation.
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
import {
  MAX_NET_CHUNK_BYTES,
  NET_WINDOW_BYTES,
  type LocalPort,
  type ServerMessage,
} from './protocol'

/**
 * The only host this module will ever connect to.
 *
 * A literal, not a name: `localhost` goes through the resolver, and a resolver
 * is a thing that can be told to answer with something else — an `/etc/hosts`
 * line, a DNS search domain, a VPN's split resolver. `127.0.0.1` cannot be
 * pointed anywhere. There is deliberately no way for a caller to supply a host.
 *
 * ## Known, diagnosed, and not yet fixed: an IPv6-only listener on Windows
 *
 * There is no `::1` counterpart here, and on Windows that loses the common
 * case. `platform/ports.ts` accepts `::1`, `[::1]` and `::` as locally
 * reachable, so the scan reports a dev server that is listening **only** on
 * IPv6 — and on Windows that is the normal outcome, because `localhost`
 * resolves to `::1` first and Vite, Next and `node --host localhost` bind what
 * the name gave them. The port is then offered to the phone, `listening()`
 * agrees it is there, and `createConnection({ host: '127.0.0.1' })` is refused.
 * `openStream` answers that with a bare `net.close` carrying no reason — which
 * is deliberate, and here means the phone shows a blank page and nothing
 * anywhere says why. macOS does not see it because the same servers bind
 * `127.0.0.1` first there.
 *
 * The fix is not a second literal in this constant: it is to carry the address
 * family through from the scan that already knows it, so a tunnel dials the
 * loopback its port is actually on, and `openTunnel` refuses with a sentence
 * when neither answers rather than opening one that cannot carry bytes. That
 * touches `platform/ports.ts`, `dev-ports.ts` and this file, and the wire type
 * must not gain the field — the phone has no use for it.
 */
const LOOPBACK = '127.0.0.1'

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

export interface TunnelDeps {
  /** What is listening on this Mac. Injected; the real one shells out to `lsof`. */
  scan(): Promise<LocalPort[]>
  /** Send a frame to the phone this hub belongs to. */
  send(message: ServerMessage): void
  /** Ports this app is itself serving on, which it will not tunnel to. */
  reserved?: number[]
  budget?: StreamBudget
  /** Fires when the tunnel list changes, so the desktop can redraw it. */
  onChange?: () => void
  /** Test seam. Defaults to a real loopback socket. */
  connect?: (port: number) => Socket
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
  openedAt: number
  streams: Set<string>
}

export function createTunnelHub(deps: TunnelDeps): TunnelHub {
  const now = deps.now ?? Date.now
  const connect = deps.connect ?? ((port: number) => createConnection({ host: LOOPBACK, port }))
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
    for (const streamId of [...tunnel.streams]) dropStream(streamId, false)
    deps.send({ t: 'tunnel.closed', id, message })
    changed()
    return true
  }

  function dropStream(id: string, tell: boolean): void {
    const stream = streams.get(id)
    if (!stream) return
    streams.delete(id)
    tunnels.get(stream.tunnel)?.streams.delete(id)
    if (!stream.closed) {
      stream.closed = true
      budget.give()
    }
    stream.socket.destroy()
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
    let ports: LocalPort[]
    try {
      ports = await deps.scan()
    } catch (error) {
      // A scan that failed is not a phone's problem to solve, and an empty list
      // is the honest answer: this Mac cannot say what is listening.
      console.error('[tunnel] port scan failed:', error)
      ports = []
    }
    deps.send({ t: 'ports', ports: ports.filter((entry) => !reserved.has(entry.port)) })
  }

  /**
   * Is this a port the Mac is willing to dial?
   *
   * Asked against a fresh scan every time rather than against whatever was last
   * offered, and that is the check that keeps this from being a port scanner: a
   * phone can only reach a port that something on the Mac is *already* serving,
   * so a `tunnel.open` for a port nothing is listening on is refused before a
   * socket exists, and cannot be used to learn which ports would have answered.
   */
  async function listening(port: number): Promise<boolean> {
    if (reserved.has(port)) return false
    try {
      return (await deps.scan()).some((entry) => entry.port === port)
    } catch {
      return false
    }
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
    opening.set(id, pending)
    let live: boolean
    try {
      live = await listening(port)
    } finally {
      opening.delete(id)
    }

    // A close overtook the scan. It has already answered the phone; saying
    // anything else here would contradict it.
    if (pending.cancelled) return
    if (!live) {
      deps.send({
        t: 'tunnel.closed',
        id,
        message: `Nothing is listening on port ${port} on the Mac any more.`,
      })
      return
    }
    tunnels.set(id, { id, port, openedAt: now(), streams: new Set() })
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

    const socket = connect(tunnel.port)
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
      if (!stream.closed) dropStream(ch, true)
    })
    socket.once('connect', () => socket.setTimeout(0))
    socket.on('data', (chunk: Buffer) => forward(stream, chunk))
    socket.on('error', () => dropStream(ch, true))
    // 'end' as well as 'close': a dev server that answers and hangs up sends a
    // FIN, and waiting for 'close' would hold the browser's socket open past the
    // end of the response.
    socket.on('end', () => dropStream(ch, true))
    socket.on('close', () => dropStream(ch, true))
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
          dropStream(message.ch, false)
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
      for (const id of [...streams.keys()]) dropStream(id, false)
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
