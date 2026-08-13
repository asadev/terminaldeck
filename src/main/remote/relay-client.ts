/**
 * The Mac's outbound link to the rendezvous relay.
 *
 * ## What this buys, and what it costs
 *
 * Remote access used to require Tailscale on both ends. That works and it is
 * still the better path when it is there — one hop, WireGuard, no third party —
 * but it is an install, a login and an admin console before a phone can see a
 * terminal, and most people never get that far. This file is the other path:
 * the Mac dials *out* to a relay and holds the socket open, a phone dials out
 * too, and the relay staples them together. No port forwarding, no NAT
 * traversal, no inbound listener, and nothing for a corporate firewall to
 * object to beyond ordinary HTTPS.
 *
 * The cost is a machine on the public internet that every byte passes through.
 * So it is treated as hostile: every payload it carries is sealed by
 * `shared/sealed.ts` under keys established between this Mac and one phone, from
 * material the relay never sees. It learns that a host is online, that some
 * device connected, how many bytes went each way and when. It cannot read a
 * command, cannot inject a keystroke, and cannot sit in the middle of the
 * handshake without failing to decrypt on the first frame.
 *
 * That property is not a promise about our own operational security. It is what
 * the code below does, and `relay-client.test.ts` asserts it by reading
 * everything the relay saw and checking that none of it is legible.
 *
 * ## The seam this hangs off
 *
 * `server.ts` owns the protocol: who may say hello, what an attach replays, what
 * an unauthenticated socket is allowed to do. None of that changes because a
 * connection arrived through a relay, and duplicating it here would be a second
 * copy of the one piece of this app where a mistake means someone else's shell.
 * So this file produces a `RemoteWire` — send a string, close, and nothing else
 * — and hands it to `attachTransport`. Everything past that point is identical
 * for a phone on the tailnet and a phone on the far side of the world.
 *
 * ## Why there is no heartbeat on the wire it hands over
 *
 * A `RemoteWire` may start its own liveness check, and the TCP one does, because
 * a phone that drives into a tunnel leaves a socket that looks open for minutes.
 * A relayed channel is not a socket: the relay pings both of its own sockets and
 * tears the channel down when either stops answering, and this file pings the
 * relay. A third heartbeat inside the first two would duplicate the work and the
 * failure. What it would *not* duplicate is the case that matters — the relay
 * itself vanishing — which is why the ping below is on the link and not on the
 * channel.
 *
 * ## Reconnecting is the normal state, not the error path
 *
 * A laptop sleeps, changes networks, moves between wifi and a phone hotspot, and
 * the relay itself restarts on deploys. Every one of those is a dead socket that
 * still looks writable. So the link reconnects with exponential backoff and
 * jitter, notices a wall-clock jump as the sleep it was, and treats a missing
 * pong as a dead link rather than waiting for a TCP timeout measured in minutes.
 */

import { createHash, randomBytes } from 'node:crypto'
import { connect as netConnect, isIP } from 'node:net'
import type { Duplex } from 'node:stream'
import { connect as tlsConnect } from 'node:tls'
import {
  DEFAULT_RELAY_URL,
  ENVELOPE,
  ENVELOPE_HEADER,
  HANDSHAKE_OPEN_BYTES,
  MAX_PAYLOAD_BYTES,
  RELAY_HOST_PATH,
  RELAY_SECRET_HEADER,
  decodeEnvelope,
  encodeEnvelope,
  readSealedHandshake,
  withSealedVersion,
} from '../../shared/relay-wire'
import { SealedRefusal, respondToHandshake, type SealedTransport } from '../../shared/sealed'
import { FrameReader, OPCODE, acceptKey, encodeMaskedFrame } from '../../shared/ws-frame'
import type { HostIdentity } from './host-identity'
import type { AttachTransport, RemoteWire, WireHandlers } from './server'

/* -------------------------------------------------------------- constants -- */

/** First retry, before jitter. Short enough that a relay deploy is invisible. */
const BASE_BACKOFF_MS = 1000

/**
 * Longest wait between dials.
 *
 * A minute is the point past which a user watching the panel decides the feature
 * is broken. It is also short enough that a relay that was down for an hour
 * comes back to its hosts within a minute rather than an hour, and long enough
 * that a permanently misconfigured URL costs one connection attempt a minute
 * rather than a busy loop.
 */
const MAX_BACKOFF_MS = 60_000

/** How long a link has to survive before its failure counts as a fresh one. */
const STABLE_MS = 60_000

/**
 * Ping interval on the link.
 *
 * The relay pings at 30s and drops a socket that misses one, so this is
 * deliberately faster: the Mac should notice a dead link and be reconnecting
 * before the relay has finished giving up on it, or every network change costs a
 * window where a phone gets "that machine is not online".
 */
const HEARTBEAT_MS = 20_000

/** Dialling, the TLS handshake and the upgrade, together. */
const CONNECT_TIMEOUT_MS = 15_000

/** How often the clock is checked against itself, to catch a sleep. */
const WATCHDOG_MS = 5000

/**
 * A tick this much later than it was due means the machine was asleep, not busy.
 *
 * Event-loop starvation on a loaded Mac is measured in hundreds of milliseconds;
 * a lid closing is measured in minutes. Twenty seconds is far outside the first
 * and far inside the second.
 */
const SLEEP_SLACK_MS = 20_000

/**
 * Most phones this Mac will hold through the relay at once.
 *
 * The relay caps guests per host as well, but its cap is its own configuration
 * and this one protects this process: every channel is a sealed transport, a
 * connection record and an attach the user's session layer has to serve.
 */
const MAX_CHANNELS = 16

/**
 * How much unsent output may pile up on the link before a channel is dropped.
 *
 * One socket carries every phone, so a backlog here lives in the heap of the
 * process running the user's terminals. The cap cannot say *which* phone caused
 * it — the kernel does not report per-channel — so it is charged to whichever
 * channel is writing when the line is crossed. That is the firehose far more
 * often than not, and dropping one phone is a better failure than an
 * out-of-memory crash of the desktop app.
 */
const MAX_BUFFERED_BYTES = 8 * 1024 * 1024

/** An HTTP response head that never ends is not one. */
const MAX_RESPONSE_HEAD_BYTES = 16 * 1024

/**
 * How often a *refused* handshake is worth a line in the log.
 *
 * Refusals are routine — an unpaired device, a phone still holding a credential
 * for a Mac that reinstalled — and anything on the internet can provoke one, so
 * logging every single one hands a stranger a way to fill the console. One line
 * a minute with a suppressed count says the same thing and cannot be used that
 * way. Faults are not throttled at all: nothing external can cause one, and the
 * first one is the interesting one.
 */
const REFUSAL_LOG_INTERVAL_MS = 60_000

/**
 * How long a closing link is given to flush its close frame before it is torn
 * down. A relay that never answers must not hold a descriptor open for the OS
 * default, which is measured in minutes.
 */
const CLOSE_LINGER_MS = 1000

/* ------------------------------------------------------------------ config -- */

/** Points a build at a different relay for an afternoon. */
export const RELAY_URL_ENV = 'TERMINALDECK_RELAY_URL'

/** `off`, `0`, `false` or `no` turns the relay off without changing anything else. */
export const RELAY_ENABLED_ENV = 'TERMINALDECK_RELAY'

const OFF = new Set(['off', '0', 'false', 'no'])

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

/**
 * Which relay to dial.
 *
 * The environment wins over the value compiled in. Whoever is running their own
 * relay, or a copy on loopback while working on it, should not have to change a
 * setting the UI does not yet expose — and the relay is not trusted, so pointing
 * at somebody else's is a supported thing to do rather than a downgrade.
 */
export function relayUrl(env: NodeJS.ProcessEnv, configured?: string | null): string {
  return text(env[RELAY_URL_ENV]) ?? text(configured) ?? DEFAULT_RELAY_URL
}

/** On unless something says otherwise. Remote access is the feature being asked for. */
export function relayEnabled(env: NodeJS.ProcessEnv, configured?: boolean): boolean {
  const said = text(env[RELAY_ENABLED_ENV])
  if (said !== null) return !OFF.has(said.toLowerCase())
  return configured !== false
}

/* ------------------------------------------------------------------- types -- */

/** What the settings panel can honestly say about the relay. */
export interface RelayState {
  /** The relay being dialled. Not a secret; the host secret is in a header. */
  url: string
  /** This Mac's public name at the relay. Goes in the pairing QR. */
  hostId: string
  /** The Mac's X25519 static public key, base64url. The other half of the QR. */
  publicKey: string
  /** The same key in the form a person compares against their phone. */
  fingerprint: string
  connected: boolean
  /** Phones attached through the relay right now. */
  channels: number
  /** Why it is not connected, in a sentence. Null while it is. */
  reason: string | null
  /** When the next dial is due, epoch ms, or null when one is not scheduled. */
  retryAt: number | null
}

/**
 * The relay, as the rest of the app needs it: start, stop, and what is going on.
 *
 * `server.ts` holds one of these and knows nothing else about relaying. That is
 * what keeps the lifecycle in one place — a relay that started itself on import
 * would be a socket the user never asked for.
 */
export interface RelayLink {
  /** Begin dialling, and keep dialling. Safe to call twice. */
  start(attach: AttachTransport): void
  /** Stop, drop every channel, and stay stopped. Safe to call twice. */
  stop(): void
  state(): RelayState
  /**
   * The machine just woke up. Replace the link now rather than waiting.
   *
   * Call this from a real event — in the app that is
   * `powerMonitor.on('resume')`, wired in the main process. A socket that slept
   * through a suspend is usually dead and always suspect, but nothing tells the
   * process that: TCP will sit on it for minutes, and every one of those minutes
   * is a phone that cannot reach this Mac.
   *
   * It exists as a method rather than a timer inside this module for two
   * reasons. This file imports no Electron, on purpose, so it can be tested
   * against a loopback relay with no app object anywhere near it. And an event
   * is simply better than polling the wall clock: it fires once, exactly when
   * the thing happened, instead of every `watchdogMs` forever in the hope of
   * catching it. The clock-jump watchdog remains as a fallback for hosts with no
   * power events, and the app leaves it off because it has them.
   */
  wake(): void
}

export interface RelayClientOptions {
  url: string
  identity: HostIdentity
  /**
   * Whether an X25519 key belongs to a device that may open a channel.
   *
   * Asked in the middle of the handshake, before any reply exists, so an
   * unpaired device never gets a channel it could send anything down. It is
   * deliberately not the whole authorisation: the device still has to say hello
   * with a credential, and still has to have been approved by a human.
   */
  isKnownDevice(devicePublicKey: Buffer): boolean
  now?: () => number
  baseBackoffMs?: number
  maxBackoffMs?: number
  heartbeatMs?: number
  connectTimeoutMs?: number
  /** Zero turns the sleep detector off, which is what most tests want. */
  watchdogMs?: number
}

interface Channel {
  id: Buffer
  key: string
  transport: SealedTransport | null
  handlers: WireHandlers | null
  closed: boolean
}

/* ------------------------------------------------------------------- URLs -- */

function isLoopback(host: string): boolean {
  const bare = host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host
  if (bare === 'localhost') return true
  if (isIP(bare) === 4) return bare.startsWith('127.')
  return bare === '::1'
}

type Target = { ok: true; url: URL; secure: boolean } | { ok: false; reason: string }

/**
 * Read the configured URL, and refuse the ones that would leak.
 *
 * `ws://` sends this Mac's host secret in a header in clear text, and the secret
 * is the only thing standing between an eavesdropper and impersonating this
 * machine at the relay. On loopback there is no wire to eavesdrop and it is the
 * only way to run the relay's own tests against the real client, so that is the
 * single exception — the same shape as the rule in `tailnet.ts` that the
 * listener never binds `0.0.0.0`: one address family, no override, stated in one
 * place.
 */
export function relayTarget(raw: string): Target {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return { ok: false, reason: `“${raw}” is not a URL, so there is no relay to dial.` }
  }
  if (url.protocol === 'wss:') return { ok: true, url, secure: true }
  if (url.protocol !== 'ws:') {
    return {
      ok: false,
      reason: `A relay URL has to start with wss://, and this one starts with ${url.protocol}//.`,
    }
  }
  if (!isLoopback(url.hostname)) {
    return {
      ok: false,
      reason:
        'A ws:// relay would send this Mac’s host secret in clear text. Use wss:// — ws:// is ' +
        'only allowed for a relay running on this machine.',
    }
  }
  return { ok: true, url, secure: false }
}

/* ----------------------------------------------------------------- client -- */

/**
 * A short, stable name for a device, derived from the key it just proved it holds.
 *
 * `device-auth.ts` rate-limits per source address, and a relayed connection has
 * none: the only address in sight belongs to the relay, and giving every phone
 * the same one would let a single attacker's failures lock out every relayed
 * device on the machine. Giving each channel a fresh name would be the opposite
 * mistake — a limiter that never counts twice.
 *
 * The authenticated public key is a better identity than an IP was: it cannot be
 * spoofed, it does not change with the network, and it is the same across
 * reconnects. So the limiter's per-address bucket becomes a per-device-key
 * bucket, which is what it was always trying to approximate.
 */
function addressFor(devicePublicKey: Buffer): string {
  const digest = createHash('sha256').update(devicePublicKey).digest('base64url')
  return `relay:${digest.slice(0, 16)}`
}

export function createRelayClient(options: RelayClientOptions): RelayLink {
  const now = options.now ?? Date.now
  const baseBackoffMs = options.baseBackoffMs ?? BASE_BACKOFF_MS
  const maxBackoffMs = options.maxBackoffMs ?? MAX_BACKOFF_MS
  const heartbeatMs = options.heartbeatMs ?? HEARTBEAT_MS
  const connectTimeoutMs = options.connectTimeoutMs ?? CONNECT_TIMEOUT_MS
  const watchdogMs = options.watchdogMs ?? WATCHDOG_MS
  const identity = options.identity

  const channels = new Map<string, Channel>()

  let attach: AttachTransport | null = null
  let stopped = true
  let socket: Duplex | null = null
  let reader = new FrameReader(MAX_PAYLOAD_BYTES + ENVELOPE_HEADER, 'client')
  let dialling = false
  let connectedAt = 0
  let attempts = 0
  let reason: string | null = null
  let retryAt: number | null = null
  let retry: NodeJS.Timeout | null = null
  let heartbeat: NodeJS.Timeout | null = null
  let watchdog: NodeJS.Timeout | null = null
  let awaitingPong = false
  let lastTick = 0
  /** Throttle state for refused handshakes. See REFUSAL_LOG_INTERVAL_MS. */
  let refusalsSinceLog = 0
  let refusalLoggedAt = 0

  function state(): RelayState {
    return {
      url: options.url,
      hostId: identity.hostId,
      publicKey: identity.keys.publicKey.toString('base64url'),
      fingerprint: identity.fingerprint,
      connected: socket !== null,
      channels: channels.size,
      reason: socket === null ? reason : null,
      retryAt,
    }
  }

  /* ------------------------------------------------------------- the wire */

  function write(opcode: number, payload: Buffer): void {
    const live = socket
    if (!live) return
    try {
      live.write(encodeMaskedFrame(opcode, payload))
    } catch {
      drop('The link to the relay failed while sending.')
    }
  }

  function sendEnvelope(type: number, channel: Buffer, payload: Buffer): void {
    write(OPCODE.binary, encodeEnvelope(type, channel, payload))
  }

  /* ---------------------------------------------------------- the channels */

  /**
   * End one phone's channel.
   *
   * The close envelope is sent even when the relay is the party that closed it:
   * the relay has already forgotten the channel by then and drops the frame, and
   * the alternative is a flag threaded through every caller for the sake of one
   * unneeded 17-byte write.
   */
  function closeChannel(channel: Channel, why: string): void {
    if (channel.closed) return
    channel.closed = true
    channels.delete(channel.key)
    sendEnvelope(ENVELOPE.close, channel.id, Buffer.alloc(0))
    const handlers = channel.handlers
    channel.handlers = null
    if (!handlers) return
    try {
      handlers.closed()
    } catch (error) {
      // The endpoint's own bookkeeping threw. It has already lost the
      // connection; it must not also take the link down.
      console.error(`[relay] a channel closed badly (${why}):`, error)
    }
  }

  function wireFor(channel: Channel): RemoteWire {
    return {
      send(payload: string): void {
        const live = socket
        if (channel.closed || !channel.transport || !live) return
        if (live.writableLength > MAX_BUFFERED_BYTES) {
          closeChannel(channel, 'output backed up')
          return
        }
        let sealed: Buffer
        try {
          sealed = channel.transport.send(Buffer.from(payload, 'utf8'))
        } catch {
          // The only way this throws is the counter reaching its ceiling, which
          // is a channel that has to end rather than one that reuses a nonce.
          closeChannel(channel, 'the sealed channel is exhausted')
          return
        }
        sendEnvelope(ENVELOPE.data, channel.id, sealed)
      },
      // The close code and reason do not cross a relay: there is no WebSocket
      // close frame to put them in, only an envelope that says "gone". The
      // protocol's own `error` message carries the words, and it is sent before
      // this by every path that refuses a connection.
      close: () => closeChannel(channel, 'closed by the desktop'),
    }
  }

  /** A phone has arrived. Nothing is trusted yet; it has not said anything. */
  function openChannel(id: Buffer): void {
    const key = id.toString('hex')
    if (channels.has(key)) return
    if (channels.size >= MAX_CHANNELS) {
      sendEnvelope(ENVELOPE.close, id, Buffer.alloc(0))
      return
    }
    channels.set(key, { id, key, transport: null, handlers: null, closed: false })
  }

  /**
   * The Noise IK responder half, run once per channel on its first payload.
   *
   * Refusal is silent and uniform. An unpaired device, a device paired to
   * another Mac, a replayed handshake and a relay tampering with the bytes all
   * produce the same closed channel with nothing on the wire — telling them
   * apart out loud would hand the relay an oracle for which devices this Mac
   * knows.
   */
  function handshake(channel: Channel, payload: Buffer): void {
    const opened = readSealedHandshake(payload, HANDSHAKE_OPEN_BYTES)
    if (!opened.ok) {
      // Said here and nowhere else. Over the wire this is the same silent close
      // as every other refusal, but a version mismatch is the one cause a person
      // can act on — and without a line in the log it looks exactly like a phone
      // that was never paired.
      if (opened.reason === 'wrong-version') {
        console.error(
          '[relay] a device asked for a sealed channel this build does not speak; one of the two needs updating.',
        )
      }
      closeChannel(channel, `handshake ${opened.reason}`)
      return
    }

    let result
    try {
      result = respondToHandshake(identity.keys, opened.message, options.isKnownDevice)
    } catch (error) {
      // Nothing new goes on the wire — the channel closes exactly as it always
      // did, and a device still cannot tell "unpaired" from "tampered with".
      // The change is that the Mac now says something to its own console.
      //
      // This catch used to be bare. For a day it swallowed `Unknown cipher`
      // thrown by every single handshake, and the only visible symptom was a
      // channel that closed: no line in the log, no state in the panel, nothing
      // to search for. A total failure of the feature was indistinguishable
      // from a stranger knocking.
      if (error instanceof SealedRefusal) {
        // Routine. Throttled, because anything on the internet can cause one.
        refusalsSinceLog += 1
        const now = Date.now()
        if (now - refusalLoggedAt >= REFUSAL_LOG_INTERVAL_MS) {
          const also =
            refusalsSinceLog > 1 ? ` (${refusalsSinceLog} refused since the last line)` : ''
          console.warn(
            `[relay] refused a sealed handshake${also}: the device is not paired with this Mac, ` +
              'or it is paired with a different one. Pair it again if it should have access.',
          )
          refusalLoggedAt = now
          refusalsSinceLog = 0
        }
      } else {
        // Not routine, not the peer's doing, and never throttled: this machine
        // cannot do the crypto. Every relayed connection is failing right now.
        console.error(
          '[relay] the sealed handshake could not run on this machine — remote access is broken ' +
            'for every device, not just this one. This is a fault in the build, not a refusal:',
          error,
        )
      }
      closeChannel(channel, 'handshake failed authentication')
      return
    }

    channel.transport = result.transport
    // Attached before the reply goes out: if the endpoint is full, the phone
    // gets a closed channel rather than a working sealed channel it is about to
    // lose. `attach` only registers and starts a hello timer — it sends nothing,
    // so there is no ordering hazard in doing it first.
    const accepted = attach?.(
      addressFor(result.devicePublicKey),
      (handlers) => {
        channel.handlers = handlers
        return wireFor(channel)
      },
      result.devicePublicKey,
    )
    if (accepted !== true) {
      closeChannel(channel, 'too many connections')
      return
    }
    sendEnvelope(ENVELOPE.data, channel.id, withSealedVersion(result.reply))
  }

  function onEnvelope(frame: Buffer): void {
    const envelope = decodeEnvelope(frame)
    // A relay that cannot speak its own envelope is either broken or not the
    // relay; either way there is nothing useful to do with the frame.
    if (!envelope) return

    if (envelope.type === ENVELOPE.open) {
      openChannel(envelope.channel)
      return
    }

    const channel = channels.get(envelope.channel.toString('hex'))
    if (!channel) return

    if (envelope.type === ENVELOPE.close) {
      closeChannel(channel, 'the phone disconnected')
      return
    }

    if (!channel.transport) {
      handshake(channel, envelope.payload)
      return
    }

    let message: string
    try {
      message = channel.transport.receiveText(envelope.payload)
    } catch {
      // A frame that fails its tag is a forged or reordered one, and the
      // transport refuses to advance its counter past it. There is no way back
      // to a synchronised channel from here.
      closeChannel(channel, 'sealed frame failed authentication')
      return
    }

    const handlers = channel.handlers
    if (!handlers) return
    try {
      handlers.message(message)
    } catch (error) {
      // This runs on the link's `data` event, inside the main process. An
      // exception here would take the whole app down over one bad message.
      console.error('[relay] message handler threw:', error)
      closeChannel(channel, 'internal error')
    }
  }

  /* -------------------------------------------------------------- the link */

  function receive(chunk: Buffer): void {
    if (!socket) return
    const batch = reader.push(chunk)
    for (const frame of batch.frames) {
      if (!socket) return
      if (frame.opcode === OPCODE.close) return drop('The relay closed the connection.')
      if (frame.opcode === OPCODE.ping) {
        write(OPCODE.pong, frame.payload)
        continue
      }
      if (frame.opcode === OPCODE.pong) {
        awaitingPong = false
        continue
      }
      // Fragmentation is refused rather than reassembled: the relay does not
      // fragment, and buffering on behalf of one that started to would be a way
      // to make this process hold any amount of memory.
      if (!frame.fin) return drop('The relay sent a fragmented frame.')
      if (frame.opcode === OPCODE.binary) onEnvelope(frame.payload)
      // Text frames are ignored rather than fatal: nothing sends them, and a
      // probe poking the endpoint should not cost the user their sessions.
    }
    if (!batch.ok) drop(`The relay sent a frame this build cannot read: ${batch.error.detail}.`)
  }

  /** Tear the link down and, unless stopped, arrange to try again. */
  function drop(why: string): void {
    const live = socket
    socket = null
    if (heartbeat) clearInterval(heartbeat)
    heartbeat = null
    awaitingPong = false
    reader.reset()

    // Every channel dies with the link, and the endpoint has to hear about it
    // or a phone that is gone keeps its sessions attached forever. Cleared
    // before the socket is destroyed so the close envelopes are dropped rather
    // than queued on a socket nobody is reading.
    for (const channel of [...channels.values()]) closeChannel(channel, why)
    channels.clear()

    if (live) {
      live.removeAllListeners()
      try {
        // `end` rather than `destroy`: `stop()` has just queued a close frame,
        // and destroying in the same tick discards it — leaving the relay
        // holding this host id until its own heartbeat gives up, which is long
        // enough for a restart of the app to find its own name still claimed.
        // The timer is only for a peer that never answers.
        if (!live.destroyed) {
          live.end()
          const linger = setTimeout(() => live.destroy(), CLOSE_LINGER_MS)
          linger.unref?.()
        }
      } catch {
        /* already gone */
      }
    }

    const wasStable = connectedAt !== 0 && now() - connectedAt >= STABLE_MS
    connectedAt = 0
    reason = why
    if (stopped) {
      retryAt = null
      return
    }
    // A link that held for a minute failed for a new reason, not the old one.
    if (wasStable) attempts = 0
    schedule()
  }

  function schedule(): void {
    if (retry || stopped || dialling || socket) return
    const ceiling = Math.min(maxBackoffMs, baseBackoffMs * 2 ** Math.min(attempts, 6))
    // Full jitter across the top half of the window. Every Mac in the world
    // reconnects when the relay restarts, and without jitter they all come back
    // in the same millisecond and knock it over again.
    const delay = Math.round(ceiling / 2 + Math.random() * (ceiling / 2))
    attempts += 1
    retryAt = now() + delay
    retry = setTimeout(() => {
      retry = null
      retryAt = null
      void dial()
    }, delay)
    retry.unref?.()
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

  async function dial(): Promise<void> {
    if (stopped || dialling || socket) return
    const target = relayTarget(options.url)
    if (!target.ok) {
      // A URL that cannot be dialled will not become dialable by waiting, but
      // the reason has to reach the panel and the setting can change under us,
      // so this backs off like any other failure rather than giving up.
      reason = target.reason
      schedule()
      return
    }

    dialling = true
    const { url, secure } = target
    const port = url.port === '' ? (secure ? 443 : 80) : Number(url.port)
    // The configured value is the relay's base, not its endpoint — `/v1/host` is
    // part of the protocol, not part of the address. Anything the URL does carry
    // is kept as a prefix, which is what a relay behind a reverse proxy on a
    // sub-path needs, and what silently dropping it would break.
    const prefix = url.pathname.replace(/\/+$/, '')
    const path = `${prefix}${RELAY_HOST_PATH}${url.search}`
    const key = randomBytes(16).toString('base64')

    let live: Duplex
    try {
      live = secure
        ? // Certificate verification is on, which is the default and is what
          // makes `wss:` mean anything: without it the header below would go to
          // whoever answered the DNS query.
          tlsConnect({ host: url.hostname, port, servername: url.hostname, ALPNProtocols: ['http/1.1'] })
        : netConnect({ host: url.hostname, port })
    } catch (error) {
      dialling = false
      reason = `Could not dial the relay: ${error instanceof Error ? error.message : String(error)}.`
      schedule()
      return
    }

    // Keystrokes are one-byte writes; Nagle would hold each one waiting for an
    // ack and a relayed session would feel like a satellite link.
    if ('setNoDelay' in live && typeof live.setNoDelay === 'function') live.setNoDelay(true)

    const timer = setTimeout(() => live.destroy(new Error('timed out')), connectTimeoutMs)
    timer.unref?.()

    /**
     * One `data` listener for the whole life of this socket, switched by a flag.
     *
     * Removing a listener does not take a stream out of flowing mode, so a
     * handshake that reads the head with a temporary listener and then installs
     * the real one loses whatever arrived in between — which, on a busy relay,
     * is the first envelope. Bytes therefore only ever go two places: into the
     * response head, or into the framer.
     */
    let upgraded = false
    let pending = Buffer.alloc(0)
    let head: string | null = null
    let onHead: (() => void) | null = null
    let onHeadFailed: ((error: Error) => void) | null = null

    live.on('data', (chunk: Buffer) => {
      if (upgraded) return receive(chunk)
      pending = Buffer.concat([pending, chunk])
      if (head !== null) return
      const end = pending.indexOf('\r\n\r\n')
      if (end === -1) {
        if (pending.length > MAX_RESPONSE_HEAD_BYTES) {
          onHeadFailed?.(new Error('the relay sent a response head with no end to it'))
        }
        return
      }
      head = pending.subarray(0, end).toString('latin1')
      pending = Buffer.from(pending.subarray(end + 4))
      onHead?.()
    })

    const gone = (phrase: string): void => {
      // The same fact reads two ways: before the upgrade it is why the dial
      // failed, after it is why the link ended and what the panel shows.
      if (upgraded) return drop(`${phrase[0].toUpperCase()}${phrase.slice(1)}.`)
      onHeadFailed?.(new Error(phrase))
    }
    live.on('error', () => gone('the link to the relay failed'))
    live.on('close', () => gone('the relay closed the connection'))
    // A peer that vanishes delivers 'end' and then stays writable forever;
    // listening only for 'close' leaves the app holding a link that is gone.
    live.on('end', () => gone('the relay stopped answering'))

    try {
      await new Promise<void>((settle, fail) => {
        onHeadFailed = fail
        live.once(secure ? 'secureConnect' : 'connect', () => settle())
      })

      const host = url.port === '' ? url.hostname : `${url.hostname}:${url.port}`
      live.write(
        [
          `GET ${path} HTTP/1.1`,
          `Host: ${host}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${key}`,
          'Sec-WebSocket-Version: 13',
          `${RELAY_SECRET_HEADER}: ${identity.hostSecret.toString('base64url')}`,
          '',
          '',
        ].join('\r\n'),
      )

      await new Promise<void>((settle, fail) => {
        if (head !== null) return settle()
        onHead = settle
        onHeadFailed = fail
      })

      const answered = head ?? ''
      const status = Number(/^HTTP\/1\.1 (\d+)/.exec(answered)?.[1] ?? 0)
      if (status !== 101) {
        throw new Error(
          status === 401
            ? 'the relay would not accept this Mac’s host secret'
            : `the relay answered ${status || 'nothing'} instead of upgrading the connection`,
        )
      }
      // Checked rather than assumed: a `101` from something that did not
      // understand the request is a peer that is about to be fed WebSocket
      // frames it will read as HTTP.
      if (headerOf(answered, 'sec-websocket-accept') !== acceptKey(key)) {
        throw new Error('the relay answered an upgrade that does not match the request')
      }
    } catch (error) {
      clearTimeout(timer)
      dialling = false
      live.removeAllListeners()
      live.destroy()
      reason = `Could not reach the relay: ${error instanceof Error ? error.message : String(error)}.`
      schedule()
      return
    }

    clearTimeout(timer)
    onHead = null
    onHeadFailed = null
    dialling = false

    // Switched off while this was in the air. Without this the link would be
    // installed after `stop()` had already run and would then stay open for
    // good: nothing reconnects it, and nothing is left holding it to close.
    if (stopped) {
      live.removeAllListeners()
      live.destroy()
      return
    }

    connectedAt = now()
    reason = null
    retryAt = null
    reader = new FrameReader(MAX_PAYLOAD_BYTES + ENVELOPE_HEADER, 'client')
    socket = live
    upgraded = true

    // Whatever rode in behind the `101`. Fed after `socket` is set, or the
    // framer would drop it for want of a link to belong to.
    if (pending.length > 0) {
      const rest = pending
      pending = Buffer.alloc(0)
      receive(rest)
    }

    if (heartbeat) clearInterval(heartbeat)
    // Zero turns the heartbeat off, the same way `pingIntervalMs` does in
    // `server.ts`. Without this the option is a trap rather than a switch:
    // `setInterval(fn, 0)` fires on every tick, so the first pass sends a ping
    // and the second sees `awaitingPong` still set and declares a perfectly
    // healthy relay dead. Found exactly that way, against the live relay, by
    // someone who assumed the convention already held here.
    if (heartbeatMs > 0) {
      heartbeat = setInterval(() => {
        if (!socket) return
        if (awaitingPong) return drop('The relay stopped answering pings.')
        awaitingPong = true
        write(OPCODE.ping, Buffer.alloc(0))
      }, heartbeatMs)
      heartbeat.unref?.()
    }
  }

  /**
   * The machine woke up, or the clock moved.
   *
   * A socket that was open when the lid closed is dead and still looks writable,
   * and the ping above would take a full interval to notice. Reconnecting
   * outright costs one handshake and gets a phone back a great deal sooner; the
   * backoff is reset because a wake is not a failed attempt.
   */
  function wake(): void {
    attempts = 0
    if (socket) {
      drop('The Mac woke up, so the link was replaced.')
      return
    }
    if (retry) {
      clearTimeout(retry)
      retry = null
      retryAt = null
    }
    void dial()
  }

  return {
    start(next: AttachTransport): void {
      attach = next
      if (!stopped) return
      stopped = false
      attempts = 0
      lastTick = now()
      if (watchdogMs > 0) {
        watchdog = setInterval(() => {
          const at = now()
          const late = at - lastTick
          lastTick = at
          if (late > watchdogMs + SLEEP_SLACK_MS) wake()
        }, watchdogMs)
        watchdog.unref?.()
      }
      void dial()
    },

    wake(): void {
      if (stopped) return
      lastTick = now()
      wake()
    },

    stop(): void {
      stopped = true
      attach = null
      if (retry) clearTimeout(retry)
      retry = null
      retryAt = null
      if (watchdog) clearInterval(watchdog)
      watchdog = null
      // A close frame first, so the relay forgets this host id now rather than
      // when its own heartbeat gives up — otherwise a restart of the app finds
      // its own name still claimed.
      if (socket) write(OPCODE.close, Buffer.alloc(0))
      drop('Remote access is switched off.')
      reason = null
    },

    state,
  }
}
