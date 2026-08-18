/**
 * The other end of `remote/tunnel.ts`: a port on **another** machine, given an
 * address on this one.
 *
 * ## Why this file had to exist for the browser to be one browser
 *
 * From the recorded review of 2026-08-18, looking at the in-app browser while a
 * PC was connected in the sidebar:
 *
 *   > *"When I click on browser there is no way for me to find all the localhost
 *   > pages of the remote device. I should be able to see the available whole
 *   > ports, and I should be able to type and reach the devices which are not
 *   > here on this device but they are from the other remote device."*
 *
 * and the sentence that governs the whole item:
 *
 *   > *"Keep the same one browser window for every device — remote device, local
 *   > device, all should have the same type of same browser window with the same
 *   > tabs, everything. **Shape of the application should not be changing for
 *   > local and remote devices.**"*
 *
 * A browser tab can only load a URL. So the only arrangement in which the
 * browser does not change shape is the one where a remote port *is* a URL —
 * an ordinary `http://` address this window opens through its ordinary
 * navigation, with the ordinary tab strip, address bar and history around it.
 * That is what this module makes: a loopback listener here, whose bytes are
 * carried to a port over there.
 *
 * Everything about the pipe itself was already written and proved, twice. This
 * end is the third implementation of the same conversation and deliberately the
 * least inventive:
 *
 *  - `src/main/remote/tunnel.ts` is the **host** half — it dials its own
 *    loopback and copies bytes onto the sealed channel. It is unchanged.
 *  - `ios/TerminalDeck/Tunnel/PortTunnel.swift` is the **phone's** guest half —
 *    it listens on the phone's loopback and hands a web view a URL. This file is
 *    that, for a desktop, in TypeScript.
 *
 * Both of those files argue at length for a **byte pipe rather than an HTTP
 * proxy**, and the argument is not repeated here: read the top of `tunnel.ts`.
 * The short version is that a TCP relay costs nothing and gets chunked
 * encoding, keep-alive, server-sent events, the WebSocket upgrade and every
 * cookie and redirect right by not participating in any of them.
 *
 * ## Where the listener binds, and why the answer is a ladder
 *
 * The phone binds **the same port number** the desktop serves on, and its file
 * says why in a paragraph worth reading: a dev server writes its own port into
 * its own output — a redirect to `http://localhost:3000/login`, a hot-reload
 * socket at `ws://localhost:3000/…`, a cookie scoped to a port — and every one
 * of those escapes anything served at a different number.
 *
 * A phone can always have that number, because a phone is not running dev
 * servers. **A desktop very often cannot**, and in exactly the case this
 * feature is for: somebody working on the same project on two machines has
 * `3000` busy on both. So the port cannot simply be demanded, and the phone's
 * answer — refuse, and say the port is taken — would refuse the common case.
 *
 * Three rungs, in order, and the first two keep the number:
 *
 *  1. **`127.0.0.1:<same port>`**, when nothing is answering there.
 *  2. **`[::1]:<same port>`**, when nothing is answering there. This is not a
 *     consolation: `localhost` resolves to `::1` first on macOS and Windows and
 *     Chromium prefers it, so a page served here still catches most of what a
 *     dev server writes about itself. It is the same rung the iOS build uses in
 *     the Simulator, for the same reason and with the same reasoning.
 *  3. **`127.0.0.1:0`** — whatever port the OS hands out. The page loads and
 *     everything relative to it works; only a link the far server writes as an
 *     absolute `localhost:<port>` would leave, and it would leave to *this*
 *     machine's own server on that number. That is a real caveat rather than a
 *     hidden one, so {@link ReachOpened.sameNumber} carries it up to the window,
 *     which says so on screen.
 *
 * A loopback **alias** — `127.0.0.2`, one address per machine, every port number
 * preserved and never a collision — was the first design and is not here
 * because it does not work. Measured on this Mac before a line was written:
 *
 *     bind 127.0.0.2:39001 → EADDRNOTAVAIL
 *
 * macOS assigns only `127.0.0.1` to `lo0`; reaching any other address in
 * `127/8` needs `ifconfig lo0 alias`, which needs a password, which no browser
 * button may ask for.
 *
 * ## "Answers", not "binds"
 *
 * Whether a rung is free is decided by **connecting to it**, not by trying to
 * bind it. `PortTunnel.swift` records why, measured rather than reasoned: BSD
 * lets a socket bound to the specific address `127.0.0.1` sit underneath one
 * already bound to a wildcard, so the bind succeeds, the kernel then splits
 * incoming connections between the two by specificity, and half a page comes
 * from one server and half from the other. A connect asks the question directly
 * and has no such gap. A rung that neither answers nor refuses inside
 * {@link PROBE_TIMEOUT_MS} is treated as busy — one honest sentence is cheaper
 * than a page assembled from two servers.
 *
 * ## The port this takes is given back to the port scan
 *
 * Every listener here claims its port with `claimOwnPort`, which is what keeps
 * a tunnel from becoming a *chain*. Without it, a phone paired to this Mac would
 * be offered `3000` in its own port list — this listener — and tunnelling to it
 * would put the phone inside a PC it was never paired with, past that PC's
 * approval screen and its folder grants. `own-ports.ts` was written for the
 * copilot's control plane and this is the same hole with one more machine in it.
 *
 * ## What is not here
 *
 * There is no close button and no idle reaper. A tunnel lives for as long as the
 * link to that machine does — `machines/ipc.ts` drops them the moment the link
 * leaves `online`, and again at shutdown — because the alternative is a page
 * that dies while somebody is reading it, and because a listener costs one file
 * descriptor. The cost of keeping it is that a port taken by rung 1 stays taken
 * until the machine disconnects, which is the same bargain the phone makes.
 */

import { createConnection, createServer, type Server, type Socket } from 'node:net'
import { randomUUID } from 'node:crypto'
import { claimOwnPort, releaseOwnPort } from './own-ports'
import {
  MAX_NET_CHUNK_BYTES,
  NET_WINDOW_BYTES,
  type ServerMessage,
} from './remote/protocol'
import type { LocalhostMessage } from './remote/tunnel'

/**
 * How long the far machine may take to answer `tunnel.open`.
 *
 * Arithmetic rather than a round number, and the same sum the phone's client
 * does: the honest worst case over there is a port scan (`SCAN_TIMEOUT_MS`, 5s
 * in `dev-ports.ts`) followed by two dials that each time out (`DIAL_TIMEOUT_MS`,
 * 5s in `tunnel.ts`, IPv4 then IPv6), plus a relay round trip. Twenty seconds is
 * that with room, and anything past it is a link that is not going to answer.
 */
const OPEN_TIMEOUT_MS = 20_000

/**
 * How long a rung of the ladder may take to say whether it is busy.
 *
 * Loopback answers or refuses immediately — there is no network in the path —
 * so this is not a network timeout. It exists so that an address in a state
 * neither of those covers cannot hold a person's click open.
 */
const PROBE_TIMEOUT_MS = 600

/** Browser connections one remote port may hold. Chromium opens six per origin. */
const MAX_STREAMS_PER_TUNNEL = 64

/** The loopback literals, for the reason `tunnel.ts` gives: a name can be pointed elsewhere. */
const LOOPBACK_V4 = '127.0.0.1'
const LOOPBACK_V6 = '::1'

/** A port on another machine, now reachable at a URL on this one. */
export interface ReachOpened {
  ok: true
  /** What to put in the address bar. Ends in `/` so it is a page, not a host. */
  url: string
  /** The port over there. */
  port: number
  /** The port here. Equal to `port` on the first two rungs. */
  localPort: number
  /**
   * False when rung 3 was taken, i.e. the numbers differ.
   *
   * The window says so in a sentence rather than leaving somebody to notice
   * that a link out of the page went somewhere strange.
   */
  sameNumber: boolean
}

export interface ReachRefused {
  ok: false
  /** Why, in a sentence a person can act on. Written for a reader, not a log. */
  message: string
}

export type ReachAnswer = ReachOpened | ReachRefused

/** One live tunnel, as a panel would list it. */
export interface ReachInfo {
  port: number
  localPort: number
  url: string
  streams: number
  openedAt: number
}

export interface ReachDeps {
  /**
   * Put one frame on the wire to that machine. False when it did not go.
   *
   * False is not an error path to be logged and swallowed: it is the link being
   * offline or the far machine never having offered `localhost`, and both are
   * sentences somebody reads. See `machines/ipc.ts` for what is passed here.
   */
  send(message: LocalhostMessage): boolean
  now?: () => number
}

export interface RemoteReach {
  /**
   * Give this port on that machine an address on this one.
   *
   * Idempotent per port: a second tab asking for `3000` gets the URL the first
   * one is already using, and two clicks in the same instant share one open
   * rather than racing to bind the same rung.
   */
  open(port: number): Promise<ReachAnswer>
  /** A frame arrived from that machine. Anything not a tunnel frame is ignored. */
  handle(message: ServerMessage): void
  /** The link dropped, or the app is quitting. Every socket goes with it. */
  closeAll(reason: string): void
  list(): ReachInfo[]
}

interface Stream {
  ch: string
  socket: Socket
  /** Bytes sent to the far machine that it has not said it has written. */
  unacked: number
  paused: boolean
  closed: boolean
}

interface Tunnel {
  id: string
  port: number
  localPort: number
  url: string
  server: Server
  openedAt: number
  streams: Map<string, Stream>
}

/**
 * Is something already answering on this address?
 *
 * Resolves `true` for "busy", including for an address that answers neither
 * way — see the header. Nothing is written to the socket: a connect that is
 * accepted and immediately destroyed is the smallest question that can be
 * asked, and dev servers log it as a dropped connection at worst.
 */
function answers(host: string, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host, port })
    let settled = false
    const done = (busy: boolean): void => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(busy)
    }
    socket.setTimeout(PROBE_TIMEOUT_MS, () => done(true))
    socket.once('connect', () => done(true))
    // A refusal is the answer this is looking for: nothing is there, so the
    // address is free. Any other error — a permission, an unassigned address —
    // is not a free address and is treated as busy.
    socket.once('error', (error: NodeJS.ErrnoException) => done(error.code !== 'ECONNREFUSED'))
  })
}

/** Bind a loopback listener, or null when the address will not take it. */
function bind(host: string, port: number): Promise<Server | null> {
  return new Promise((resolve) => {
    const server = createServer()
    const fail = (): void => {
      server.close()
      resolve(null)
    }
    server.once('error', fail)
    server.listen(port, host, () => {
      server.removeListener('error', fail)
      resolve(server)
    })
  })
}

export function createRemoteReach(deps: ReachDeps): RemoteReach {
  const now = deps.now ?? Date.now
  const tunnels = new Map<string, Tunnel>()
  /** Port over there → tunnel id, so a second ask reuses the first pipe. */
  const byPort = new Map<number, string>()
  /** Port over there → the open in flight, so two clicks are one open. */
  const opening = new Map<number, Promise<ReachAnswer>>()
  /** Tunnel id → what to do when the far machine answers `tunnel.open`. */
  const waiting = new Map<string, (answer: { ok: true } | { ok: false; message: string }) => void>()

  function dropStream(tunnel: Tunnel, ch: string, tell: boolean): void {
    const stream = tunnel.streams.get(ch)
    if (!stream) return
    tunnel.streams.delete(ch)
    stream.closed = true
    stream.socket.destroy()
    if (tell) deps.send({ t: 'net.close', ch })
  }

  function closeTunnel(id: string, tellFarEnd: boolean): void {
    const tunnel = tunnels.get(id)
    if (!tunnel) return
    tunnels.delete(id)
    byPort.delete(tunnel.port)
    for (const ch of [...tunnel.streams.keys()]) dropStream(tunnel, ch, false)
    tunnel.server.close()
    releaseOwnPort(tunnel.localPort)
    if (tellFarEnd) deps.send({ t: 'tunnel.close', id })
  }

  /**
   * Read from the browser and post it to the far machine, in bounded pieces.
   *
   * The same cut `tunnel.ts` makes and for the same reason: one `data` event is
   * whatever the kernel had, base64 adds a third on top, and a chunk that
   * overshot the message cap would be refused by the far end's parser — which
   * closes the whole channel, taking every terminal session on that machine's
   * link with it.
   */
  function forward(stream: Stream, chunk: Buffer): void {
    for (let at = 0; at < chunk.length; at += MAX_NET_CHUNK_BYTES) {
      const piece = chunk.subarray(at, at + MAX_NET_CHUNK_BYTES)
      stream.unacked += piece.length
      deps.send({ t: 'net.data', ch: stream.ch, data: piece.toString('base64') })
    }
    if (!stream.paused && stream.unacked >= NET_WINDOW_BYTES) {
      stream.paused = true
      stream.socket.pause()
    }
  }

  function accept(tunnel: Tunnel, socket: Socket): void {
    if (tunnel.streams.size >= MAX_STREAMS_PER_TUNNEL) {
      // Refused by hanging up, with nothing written. The far side of this socket
      // is a browser; the only thing it can do with an explanation is discard it.
      socket.destroy()
      return
    }
    const ch = randomUUID()
    const stream: Stream = { ch, socket, unacked: 0, paused: false, closed: false }
    tunnel.streams.set(ch, stream)
    deps.send({ t: 'net.open', ch, tunnel: tunnel.id })

    // A hot-reload notice is forty bytes and Nagle would hold each one.
    socket.setNoDelay(true)
    socket.on('data', (chunk: Buffer) => forward(stream, chunk))
    socket.on('error', () => dropStream(tunnel, ch, true))
    // 'end' as well as 'close', for the reason `tunnel.ts` gives: a browser that
    // sends a FIN after its request is waiting for the answer, and holding the
    // far socket open past it is a request that never finishes.
    socket.on('end', () => dropStream(tunnel, ch, true))
    socket.on('close', () => dropStream(tunnel, ch, true))
  }

  /** Walk the ladder in the header. Null when every rung is taken. */
  async function bindLocally(port: number): Promise<{ server: Server; host: string; localPort: number } | null> {
    for (const host of [LOOPBACK_V4, LOOPBACK_V6]) {
      if (await answers(host, port)) continue
      const server = await bind(host, port)
      if (server) return { server, host, localPort: port }
    }
    const fallback = await bind(LOOPBACK_V4, 0)
    if (fallback === null) return null
    const address = fallback.address()
    if (address === null || typeof address === 'string') {
      fallback.close()
      return null
    }
    return { server: fallback, host: LOOPBACK_V4, localPort: address.port }
  }

  async function openTunnel(port: number): Promise<ReachAnswer> {
    const id = randomUUID()
    const asked = deps.send({ t: 'tunnel.open', id, port })
    if (!asked) {
      return {
        ok: false,
        message: 'That machine is not connected right now, so its ports cannot be reached.',
      }
    }

    const answer = await new Promise<{ ok: true } | { ok: false; message: string }>((resolve) => {
      const timer = setTimeout(() => {
        waiting.delete(id)
        // The far end may yet open it, so it is told to forget it. Without this
        // a machine that was merely slow is left holding a listener nothing here
        // will ever connect to.
        deps.send({ t: 'tunnel.close', id })
        resolve({
          ok: false,
          message: `That machine did not answer about port ${port}. It may be busy or the connection may have dropped.`,
        })
      }, OPEN_TIMEOUT_MS)
      timer.unref?.()
      waiting.set(id, (result) => {
        clearTimeout(timer)
        waiting.delete(id)
        resolve(result)
      })
    })
    if (!answer.ok) return answer

    const bound = await bindLocally(port)
    if (bound === null) {
      deps.send({ t: 'tunnel.close', id })
      return {
        ok: false,
        message: `Port ${port} answered on that machine, but this one could not open a local address to serve it on.`,
      }
    }

    const url = bound.host === LOOPBACK_V6
      ? `http://[${LOOPBACK_V6}]:${bound.localPort}/`
      : `http://${LOOPBACK_V4}:${bound.localPort}/`
    const tunnel: Tunnel = {
      id,
      port,
      localPort: bound.localPort,
      url,
      server: bound.server,
      openedAt: now(),
      streams: new Map(),
    }
    tunnels.set(id, tunnel)
    byPort.set(port, id)
    // Before the first connection, not after: a phone asking this machine for
    // its ports between the bind and the claim would be offered this listener.
    claimOwnPort(bound.localPort)
    bound.server.on('connection', (socket) => accept(tunnel, socket))
    bound.server.on('error', (error) => {
      console.error('[reach] the local listener failed:', error)
      closeTunnel(id, true)
    })
    return { ok: true, url, port, localPort: bound.localPort, sameNumber: bound.localPort === port }
  }

  function streamFor(ch: string): { tunnel: Tunnel; stream: Stream } | null {
    for (const tunnel of tunnels.values()) {
      const stream = tunnel.streams.get(ch)
      if (stream) return { tunnel, stream }
    }
    return null
  }

  return {
    open(port: number): Promise<ReachAnswer> {
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        return Promise.resolve({ ok: false, message: `${port} is not a port.` })
      }
      const existing = byPort.get(port)
      const live = existing === undefined ? undefined : tunnels.get(existing)
      if (live) {
        return Promise.resolve({
          ok: true,
          url: live.url,
          port: live.port,
          localPort: live.localPort,
          sameNumber: live.localPort === live.port,
        })
      }
      const inFlight = opening.get(port)
      if (inFlight) return inFlight
      const started = openTunnel(port).finally(() => opening.delete(port))
      opening.set(port, started)
      return started
    },

    handle(message: ServerMessage): void {
      switch (message.t) {
        case 'tunnel.opened': {
          waiting.get(message.id)?.({ ok: true })
          return
        }
        case 'tunnel.closed': {
          const pending = waiting.get(message.id)
          if (pending) {
            pending({ ok: false, message: message.message })
            return
          }
          // Not one this end was waiting on, so it is a live tunnel the far
          // machine has taken down — the server stopped, or somebody closed it
          // from over there. The listener goes with it rather than being left
          // accepting connections that can no longer go anywhere.
          closeTunnel(message.id, false)
          return
        }
        case 'net.data': {
          const found = streamFor(message.ch)
          if (!found || found.stream.closed) return
          const bytes = Buffer.from(message.data, 'base64')
          if (bytes.length === 0) return
          // Acknowledged from the write callback rather than beside the write,
          // so the window measures what the browser's socket has actually taken
          // rather than what this process has called `write` on.
          found.stream.socket.write(bytes, () => {
            if (found.stream.closed) return
            deps.send({ t: 'net.ack', ch: message.ch, bytes: bytes.length })
          })
          return
        }
        case 'net.ack': {
          const found = streamFor(message.ch)
          if (!found || found.stream.closed) return
          found.stream.unacked = Math.max(0, found.stream.unacked - message.bytes)
          if (found.stream.paused && found.stream.unacked < NET_WINDOW_BYTES) {
            found.stream.paused = false
            found.stream.socket.resume()
          }
          return
        }
        case 'net.close': {
          const found = streamFor(message.ch)
          // No echo: the far end closed it, so it already knows.
          if (found) dropStream(found.tunnel, message.ch, false)
          return
        }
        default:
          return
      }
    },

    closeAll(reason: string): void {
      if (tunnels.size > 0) console.info(`[reach] closing ${tunnels.size} tunnel(s): ${reason}`)
      for (const id of [...tunnels.keys()]) closeTunnel(id, false)
      // Anything still waiting on an answer is told, or its caller would sit on
      // a promise for the full twenty seconds after the link has plainly gone.
      for (const [id, settle] of [...waiting.entries()]) {
        waiting.delete(id)
        settle({ ok: false, message: reason })
      }
    },

    list(): ReachInfo[] {
      return [...tunnels.values()]
        .map((tunnel) => ({
          port: tunnel.port,
          localPort: tunnel.localPort,
          url: tunnel.url,
          streams: tunnel.streams.size,
          openedAt: tunnel.openedAt,
        }))
        .sort((a, b) => a.openedAt - b.openedAt)
    },
  }
}
