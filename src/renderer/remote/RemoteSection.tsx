import { useCallback, useEffect, useId, useMemo, useRef, useState, type ReactNode } from 'react'
import { Button, Group, Notice, Row, SectionHead, Switch } from '../settings/controls'
import { useAt, useEvery, useWhenActive } from '../schedule'
import { errorText } from '../settings/settings-bridge'
import { chooseRoute, pairingPaths, pairingRoutes, type PairPath } from './pairing-link'
import { detectPlatform, machineNoun, thisMachine, ThisMachine, type UiPlatform } from '../platform'
import { encodeQr, qrPath, qrViewBox, QR_QUIET_ZONE } from './qr'
import { DeviceFolders, type FolderDevice } from './DeviceFolders'
import './RemoteSection.css'

/**
 * Remote access — the settings section that opens this machine to a phone.
 *
 * What is behind the switch is a shell. A device that gets in can type into any
 * running session, which is the same as sitting at this keyboard: the files, the
 * keys, the git remotes, all of it. So the shape of this panel is set by that
 * one fact rather than by what is pleasant to build:
 *
 *   - It is off, and it stays off until somebody turns it on here. Nothing in
 *     this file starts the server on a timer, on first run, or as a side effect
 *     of the panel being looked at.
 *   - Turning it on takes a second press that says what is being exposed. The
 *     off direction is one press, because the safe direction must never be the
 *     slow one.
 *   - A device is a stranger until it is approved by hand, on this screen.
 *   - Every state is read back from the main process. This panel never says a
 *     device is connected because it just approved one.
 *
 * ## The switch says "is", not "should be"
 *
 * `remote:start` can succeed at being asked and fail at running — no Tailscale,
 * logged out, no certificate. So the switch is bound to whether the server is
 * *running*, and a start that did not take leaves the switch off with the main
 * process's own sentence underneath it. A switch that stayed on next to a dead
 * server would be the one lie this screen cannot afford.
 *
 * ## Two ways in, and they are drawn as two
 *
 * A phone reaches this machine either straight across the tailnet or through a
 * rendezvous relay, and the two fail independently. So they are two rows with
 * two states rather than one "remote access is up" light: a Mac that is signed
 * out of Tailscale still pairs and still works, and a panel that printed the
 * tailnet's complaint as *the* reason would tell that user their working feature
 * is broken. `directReason` exists in the status for exactly this, kept apart
 * from `reason`, and this file keeps them apart on screen.
 *
 * The corollary is the one thing this panel must never do: draw the relay as
 * connected when `relay.connected` is false. A code handed out for a path that
 * is down produces a phone that scans, waits, and fails — so a path that is not
 * up is not offered, and its own sentence says what to do about it.
 *
 * ## No spinner that never resolves
 *
 * Every "not working" case here is a sentence, quoted verbatim from the main
 * process, which is the only thing that knows what the tailnet is doing. Those
 * sentences are written to be actionable — `tailnet.ts` keeps them in one table
 * so that "every reason says what to do" is a property its own tests check — so
 * this panel prints them and adds nothing of its own.
 *
 * ## Why the rendering is split from the fetching
 *
 * `RemoteView` is a separate exported component that takes everything it draws.
 * `renderToStaticMarkup` never runs an effect, so a panel that fetched its own
 * status inside the component that renders it would be testable in exactly one
 * state — the empty one — and the states that matter here are the other five.
 */

/* -------------------------------------------------------------------------- */
/* The bridge                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Everything this panel needs from `window.deck`.
 *
 * The names are the preload's, not this file's preference: `contract.test.ts`
 * matches these strings against what the preload exposes, and a near miss
 * renders the "not in this build" fallback rather than failing loudly. Each one
 * maps to exactly one `remote:*` channel in `src/main/remote/server.ts`, and
 * every one of those is `handle`/`invoke` — there is no fire-and-forget call on
 * this screen, because every call here either changes who can reach this machine
 * or reports on it, and both need an answer.
 *
 * `onRemoteConnections` is the exception in shape but not in kind: the main
 * process pushes on every authenticate, attach, detach and leave, and this panel
 * uses it as a hint to re-read rather than as a source of truth.
 */
export interface RemoteBridge {
  remoteStatus(): Promise<unknown>
  listRemoteDevices(): Promise<unknown>
  startRemote(): Promise<unknown>
  stopRemote(): Promise<unknown>
  startRemotePairing(): Promise<unknown>
  cancelRemotePairing(): Promise<unknown>
  approveRemoteDevice(deviceId: string): Promise<unknown>
  revokeRemoteDevice(deviceId: string): Promise<unknown>
  disconnectRemoteConnection(connectionId: string): Promise<unknown>
  stopRemoteTunnel(connectionId: string, tunnelId: string): Promise<unknown>
  onRemoteConnections(callback: (connections: unknown) => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof RemoteBridge> = [
  'remoteStatus',
  'listRemoteDevices',
  'startRemote',
  'stopRemote',
  'startRemotePairing',
  'cancelRemotePairing',
  'approveRemoteDevice',
  'revokeRemoteDevice',
  'disconnectRemoteConnection',
  'stopRemoteTunnel',
  'onRemoteConnections',
]

/**
 * The channels this build does not have.
 *
 * A partly wired preload is the dangerous middle. `remoteStatus` alone is enough
 * to draw this whole panel, and every button whose channel is missing would then
 * report a cheerful success for a call that was never made — "Disconnected your
 * iPhone" for a phone that is still typing. So the gaps are named on screen, and
 * the actions below reject rather than resolve.
 */
export function missingRemoteMethods(bridge: Partial<RemoteBridge>): Array<keyof RemoteBridge> {
  return BRIDGE_METHODS.filter((name) => typeof bridge[name] !== 'function')
}

/**
 * The bridge as it actually exists, with each method called through its host.
 *
 * `globalThis` rather than `window` because this file is rendered to a string in
 * its own tests, where there is no `window` to read. Methods are wrapped rather
 * than copied for the reason `settings-bridge.ts` gives: a preload that puts its
 * functions on a prototype throws on `this` the first time a button is pressed,
 * and that failure only ever shows up in a packaged build.
 */
export function resolveRemoteBridge(host?: unknown): Partial<RemoteBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<RemoteBridge>
}

/* -------------------------------------------------------------------------- */
/* What comes back                                                             */
/* -------------------------------------------------------------------------- */

/** How long a pairing code lives, per `device-auth.ts`. Repeated here as prose only. */
export const PAIRING_WINDOW_SECONDS = 60

export type RemoteDeviceState = 'pending' | 'approved' | 'revoked'

/** Mirrors `Device` in `src/main/remote/device-auth.ts`. */
export interface RemoteDevice {
  id: string
  name: string
  state: RemoteDeviceState
  addedAt: number | null
  /** Null until the device has attached successfully at least once. */
  lastSeenAt: number | null
  /**
   * The device's own key, in the short form a person compares with the phone.
   *
   * Null for a device that paired before there were keys, and that is not
   * cosmetic: no key means no sealed channel, so that device can only ever come
   * in across the tailnet. It is said on the row rather than discovered the
   * first time it fails from a coffee shop.
   */
  fingerprint: string | null
}

/**
 * Mirrors `TunnelInfo` in `src/main/remote/tunnel.ts`. One page open on a port.
 *
 * Declared here rather than imported for the reason CLAUDE.md gives about
 * feature types: it crosses the bridge as `unknown` and is narrowed on arrival,
 * so a renderer that imported the main-process type would be trusting a shape
 * nothing on this side had checked.
 */
export interface RemoteTunnel {
  id: string
  /** The port on *this Mac* the phone's browser is reading. Never a remote one. */
  port: number
  /** Byte streams open inside it — roughly, the browser connections it carries. */
  streams: number
  /** Null only when the answer was unreadable, and then no age is printed. */
  openedAt: number | null
}

/** Mirrors `RemoteConnection` in `src/main/remote/server.ts`. One live phone. */
export interface RemoteConnection {
  id: string
  deviceId: string
  deviceName: string
  platform: string
  address: string
  connectedAt: number | null
  /** Sessions this phone is watching right now. */
  sessionIds: string[]
  /**
   * Ports on this Mac this phone has a page open on. Empty for most phones.
   *
   * Same reason the sessions are listed: while one of these is live, a browser
   * somewhere else is reading a server on this machine, and the person sitting
   * at the machine has to be able to see it and end it.
   */
  tunnels: RemoteTunnel[]
}

/**
 * The outbound link to the rendezvous relay. Mirrors `RelayState`.
 *
 * Null in the status while the server is stopped, and also when the build has
 * the relay switched off — which are different facts, so the panel only calls it
 * "off" when the server is up and there is still no link.
 */
export interface RemoteRelay {
  /** The service being dialled. Not a secret; the host secret rides a header. */
  url: string
  /** This Mac's public name at the relay, 26 characters. Goes in the QR. */
  hostId: string
  /** This Mac's X25519 static public key, base64url. The other half of the QR. */
  publicKey: string
  /** The same key in the form a person compares against their phone. */
  fingerprint: string
  connected: boolean
  /** Phones attached through the relay right now. */
  channels: number
  /** Why it is not connected, in a sentence. Null while it is. */
  reason: string | null
  /** When the next dial is due, epoch ms, or null when none is scheduled. */
  retryAt: number | null
}

/**
 * The panel's whole world, assembled from `remote:status` and `remote:devices`.
 *
 * Two calls rather than one because the main process keeps them apart: the
 * server knows what is running and attached, the device registry knows who is
 * allowed. Merging them here keeps that split out of the JSX.
 */
export interface RemoteState {
  running: boolean
  /**
   * The address for the *direct* path. Null when there is no direct path, which
   * is the ordinary state of a Mac that is reachable only through the relay —
   * not an error, and not a reason to refuse to pair.
   */
  url: string | null
  /** The tailnet address, which is the thing that still works when MagicDNS does not. */
  address: string | null
  /** Why nothing at all is running, in the main process's words. Null when it is. */
  reason: string | null
  /**
   * Why the *direct* path is not up, while something else may well be.
   *
   * Deliberately not merged into `reason`: with the relay carrying the session,
   * "this Mac is signed out of Tailscale" is a note about a faster route, not a
   * failure, and printing it as one teaches people to ignore it.
   */
  directReason: string | null
  relay: RemoteRelay | null
  devices: RemoteDevice[]
  connections: RemoteConnection[]
}

/** Mirrors `PairingToken`. The token is shown once and never stored by this panel. */
export interface RemotePairing {
  token: string
  /** Epoch ms. Null when the main process did not say, and then nothing counts down. */
  expiresAt: number | null
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

function asTime(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function asText(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

/** A count or a port: a whole number that is not negative, or null. */
function asWhole(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : null
}

const DEVICE_STATES = new Set<string>(['pending', 'approved', 'revoked'])

/**
 * Narrow the device list.
 *
 * A device whose state cannot be read is `pending`, never `approved`. Guessing
 * wrong in one direction leaves an Approve button on a row; in the other it
 * lists a stranger as trusted, which is the same mistake as letting them in.
 */
export function toRemoteDevices(raw: unknown): RemoteDevice[] {
  return (Array.isArray(raw) ? raw : []).flatMap((entry): RemoteDevice[] => {
    const device = asRecord(entry)
    if (!device || typeof device.id !== 'string') return []
    const state = asString(device.status)
    return [
      {
        id: device.id,
        name: asString(device.name, device.id),
        state: DEVICE_STATES.has(state)
          ? (state as RemoteDeviceState)
          : // The flags are the same fact written twice; revocation outranks
            // approval there too, so it does here.
            device.revoked === true
            ? 'revoked'
            : device.approved === true
              ? 'approved'
              : 'pending',
        addedAt: asTime(device.addedAt),
        lastSeenAt: asTime(device.lastSeenAt),
        fingerprint: asText(device.fingerprint),
      },
    ]
  })
}

/**
 * Narrow the tunnels hanging off one connection.
 *
 * A tunnel with no id or no readable port is dropped rather than drawn. The
 * port is the entire sentence the row says and the id is the only thing Stop
 * can name, so a row reading "localhost:NaN" over a button that stops nothing
 * would be this panel claiming a page is open somewhere it cannot point at —
 * worse than one fewer row, because the whole reason these are listed is that
 * they can be ended from here.
 */
export function toRemoteTunnels(raw: unknown): RemoteTunnel[] {
  return (Array.isArray(raw) ? raw : []).flatMap((entry): RemoteTunnel[] => {
    const tunnel = asRecord(entry)
    if (!tunnel || typeof tunnel.id !== 'string') return []
    const port = asWhole(tunnel.port)
    if (port === null) return []
    return [{ id: tunnel.id, port, streams: asWhole(tunnel.streams) ?? 0, openedAt: asTime(tunnel.openedAt) }]
  })
}

export function toRemoteConnections(raw: unknown, devices: readonly RemoteDevice[]): RemoteConnection[] {
  return (Array.isArray(raw) ? raw : []).flatMap((entry): RemoteConnection[] => {
    const connection = asRecord(entry)
    if (!connection || typeof connection.id !== 'string') return []
    const deviceId = asString(connection.deviceId)
    return [
      {
        id: connection.id,
        deviceId,
        deviceName: asString(
          connection.deviceName,
          devices.find((device) => device.id === deviceId)?.name ?? 'Unnamed device',
        ),
        platform: asString(connection.platform),
        address: asString(connection.address),
        connectedAt: asTime(connection.connectedAt),
        sessionIds: (Array.isArray(connection.sessionIds) ? connection.sessionIds : []).filter(
          (id): id is string => typeof id === 'string',
        ),
        tunnels: toRemoteTunnels(connection.tunnels),
      },
    ]
  })
}

/**
 * Narrow the relay half of the status. Null when there is no link at all.
 *
 * `connected` defaults to false for the same reason `running` does: an answer
 * this panel cannot read must never be drawn as a live connection, and a QR code
 * offered on the strength of one would send a phone somewhere nothing is
 * listening.
 */
export function toRemoteRelay(raw: unknown): RemoteRelay | null {
  const record = asRecord(raw)
  if (!record) return null
  return {
    url: asString(record.url),
    hostId: asString(record.hostId),
    publicKey: asString(record.publicKey),
    fingerprint: asString(record.fingerprint),
    connected: record.connected === true,
    channels: typeof record.channels === 'number' && Number.isFinite(record.channels) ? record.channels : 0,
    reason: asText(record.reason),
    retryAt: asTime(record.retryAt),
  }
}

/** Narrow `remote:status` and `remote:devices` into one state. */
export function toRemoteState(status: unknown, deviceList: unknown): RemoteState | null {
  const record = asRecord(status)
  if (!record) return null
  const devices = toRemoteDevices(deviceList)
  return {
    // Defaults to not running: an unreadable answer must never draw a QR code
    // pointing at a host that is serving nothing.
    running: record.running === true,
    url: asText(record.url),
    address: asText(record.address),
    reason: asText(record.reason),
    directReason: asText(record.directReason),
    relay: toRemoteRelay(record.relay),
    devices,
    connections: toRemoteConnections(record.connections, devices),
  }
}

/** Narrow a minted pairing code. Null without a token, which is the whole code. */
export function toRemotePairing(raw: unknown): RemotePairing | null {
  const record = asRecord(raw)
  const token = asString(record?.token)
  if (token === '') return null
  return { token, expiresAt: asTime(record?.expiresAt) }
}

/* -------------------------------------------------------------------------- */
/* Words for times                                                             */
/* -------------------------------------------------------------------------- */

/**
 * When the relay will try again, or null when nothing is scheduled.
 *
 * A reconnect that is coming is the difference between "wait ten seconds" and
 * "go and fix something", and the relay is the only thing that knows which. The
 * clock behind this only wakes when this sentence would read differently, so the
 * number is approximate by a second or so — which is why it is a sentence and
 * not a countdown.
 */
export function retryNote(retryAt: number | null, now: number): string | null {
  if (retryAt === null) return null
  const seconds = Math.round((retryAt - now) / 1000)
  if (seconds <= 0) return 'Trying again now.'
  if (seconds < 60) return `Trying again in ${seconds}s.`
  const minutes = Math.round(seconds / 60)
  return `Trying again in ${minutes} minute${minutes === 1 ? '' : 's'}.`
}

/** "just now", "5 minutes ago", "12 Aug" — enough to tell a stale device from a live one. */
export function whenSeen(at: number | null, now: number): string {
  if (at === null) return 'never'
  const minutes = Math.round((now - at) / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`
  return new Date(at).toLocaleDateString(undefined, { day: 'numeric', month: 'short' })
}

/** How long something has been attached: "less than a minute", "12 minutes", "3 hours". */
export function attachedFor(since: number, now: number): string {
  const minutes = Math.floor((now - since) / 60_000)
  if (minutes < 1) return 'less than a minute'
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'}`
  const hours = Math.round(minutes / 60)
  return `${hours} hour${hours === 1 ? '' : 's'}`
}

/** The second line of an attached row: how long, from where, watching what. */
export function connectionNote(connection: RemoteConnection, now: number): string {
  const parts = [
    connection.connectedAt === null
      ? 'attached'
      : `attached for ${attachedFor(connection.connectedAt, now)}`,
  ]
  if (connection.platform !== '') parts.push(connection.platform)
  if (connection.address !== '') parts.push(connection.address)
  // The count is the part that matters: this is how many of your sessions
  // something else is typing into right now.
  parts.push(
    connection.sessionIds.length === 0
      ? 'no session open'
      : `${connection.sessionIds.length} session${connection.sessionIds.length === 1 ? '' : 's'} open`,
  )
  return parts.join(' · ')
}

/**
 * The second line of a tunnel row: how long the page has been open, and how
 * much is moving through it.
 *
 * `attachedFor` rather than a second age function, because a tunnel's age and a
 * connection's age are the same question asked about a different timestamp, and
 * two functions rounding minutes slightly differently on one screen is the kind
 * of thing nobody notices until the two rows disagree about "1 hour".
 *
 * The socket count is left out at zero on purpose. Zero is the resting state of
 * every page that has finished loading — the browser closed its keep-alives and
 * nothing is in flight — so "0 sockets" beside a page that is plainly working
 * would read as a fault. Above zero it is a real number: that many browser
 * connections are being carried through this Mac right now.
 */
export function tunnelNote(tunnel: RemoteTunnel, now: number): string {
  const parts = [tunnel.openedAt === null ? 'open' : `open for ${attachedFor(tunnel.openedAt, now)}`]
  if (tunnel.streams > 0) {
    parts.push(`carrying ${tunnel.streams} socket${tunnel.streams === 1 ? '' : 's'}`)
  }
  return parts.join(' · ')
}

/* -------------------------------------------------------------------------- */
/* When the words above next change                                            */
/* -------------------------------------------------------------------------- */

const SECOND = 1000
const MINUTE = 60_000
const HOUR = 3_600_000
const DAY = 86_400_000

/**
 * Never schedule a wake-up closer than this.
 *
 * `now` is what these functions are asked about and also what a tick changes,
 * so a moment computed as "already past" would re-arm instantly and spin. The
 * floor is the one thing standing between this panel and a busy loop.
 */
const MIN_STEP_MS = 250

/** When a `Math.floor(elapsed / step)` display next moves. */
function nextFloorStep(since: number, now: number, step: number): number {
  return since + step * (Math.floor((now - since) / step) + 1)
}

/** When a `Math.round(elapsed / step)` display next moves — half a step later. */
function nextRoundStep(since: number, now: number, step: number): number {
  return since + Math.round((Math.floor((now - since) / step + 0.5) + 0.5) * step)
}

/** When {@link whenSeen} would print something else, or null once it is a date. */
function nextWhenSeenStep(at: number | null, now: number): number | null {
  if (at === null) return null
  const elapsed = now - at
  if (elapsed >= DAY) return null
  return nextRoundStep(at, now, elapsed >= HOUR ? HOUR : MINUTE)
}

/**
 * When {@link retryNote} would print something else.
 *
 * Harder than the others because the note changes shape as well as value: it
 * counts seconds under a minute and whole minutes above, so a countdown coming
 * down from 90 seconds changes at 89 ("1 minute"), then not again until 59
 * ("59s") — and waking every second through that gap would be thirty wake-ups
 * to redraw the same four words. Both boundaries are computed, and the nearer
 * one wins.
 */
function nextRetryNoteStep(retryAt: number, now: number): number | null {
  const remaining = retryAt - now
  if (remaining <= 0) return null
  const seconds = Math.round(remaining / SECOND)
  if (seconds <= 0) return null
  // `Math.round` moves half a step early, so the wake-up is a millisecond past
  // the boundary rather than on it — on it, the old value is still showing.
  const target = seconds < 60 ? seconds - 1 : Math.max(59, 60 * Math.round(seconds / 60) - 31)
  return retryAt - Math.round((target + 0.5) * SECOND) + 1
}

/**
 * The next moment anything on this panel would read differently.
 *
 * The panel used to keep its clock honest with a 500 ms interval, which is
 * 172,800 wake-ups a day to move labels that mostly change once a minute. Every
 * one of those labels is a pure function of `now` and one timestamp, so the
 * moment it changes is *computable* — and one wake-up scheduled for exactly
 * that moment does the same job as 172,800 that mostly find nothing to do.
 *
 * Null means nothing on screen depends on the clock, and then there is no timer
 * at all: no code counting down, no device with a "last seen" younger than a
 * day, no relay retry pending.
 *
 * Exported for its own tests. The caller re-runs it after every tick, so it
 * only has to be right about the *first* thing that changes, never about the
 * whole future.
 */
export function nextClockChange(
  state: RemoteState | null,
  pairing: RemotePairing | null,
  now: number,
): number | null {
  let soonest = Number.POSITIVE_INFINITY
  const consider = (when: number | null): void => {
    if (when !== null && when < soonest) soonest = when
  }

  // The pairing countdown, which is the only per-second thing here — and it
  // stops the instant the code expires, because `secondsLeft` clamps at zero.
  if (pairing?.expiresAt != null) {
    const left = Math.ceil((pairing.expiresAt - now) / SECOND)
    if (left > 0) consider(pairing.expiresAt - (left - 1) * SECOND)
  }

  const relay = state?.relay ?? null
  if (relay?.retryAt != null) consider(nextRetryNoteStep(relay.retryAt, now))

  for (const device of state?.devices ?? []) {
    consider(nextWhenSeenStep(device.lastSeenAt, now))
    consider(nextWhenSeenStep(device.addedAt, now))
  }

  for (const connection of state?.connections ?? []) {
    // `attachedFor` floors rather than rounds, so its steps land elsewhere.
    if (connection.connectedAt !== null) {
      const elapsed = now - connection.connectedAt
      consider(nextFloorStep(connection.connectedAt, now, elapsed >= HOUR ? HOUR : MINUTE))
    }
    // A tunnel is opened whenever the phone taps a port, which is almost never
    // the moment it attached — so its minute boundary is its own, and leaving
    // it out would freeze "open for 3 minutes" on a page that had been up for
    // twenty whenever the connection above it had nothing left to tick for.
    for (const tunnel of connection.tunnels) {
      if (tunnel.openedAt === null) continue
      const since = now - tunnel.openedAt
      consider(nextFloorStep(tunnel.openedAt, now, since >= HOUR ? HOUR : MINUTE))
    }
  }

  if (!Number.isFinite(soonest)) return null
  return Math.max(soonest, now + MIN_STEP_MS)
}

/**
 * Whether the next thing to happen here is something nothing will announce.
 *
 * Two states, both bounded, both with a person watching:
 *
 *  - **A code is on screen.** A phone that scans it authenticates, is found to
 *    be unapproved, and is refused — and `hello()` in `server.ts` returns from
 *    that path *without* calling `announce()`, because a refused socket is not
 *    a connection. So the "Approve this device?" row is the one thing on this
 *    panel that no push channel ever brings, and the pairing window is the only
 *    time it can appear. It lasts {@link PAIRING_WINDOW_SECONDS}.
 *  - **The relay is mid-dial.** `retryAt` is null while a socket is actually
 *    being opened, and neither the success nor the failure is pushed. A dial
 *    always ends — connected, or disconnected with a retry scheduled — and the
 *    scheduled retry is a moment this panel can wake for exactly.
 *
 * Everything else on this screen arrives on `remote:connections` or is read
 * when the user comes back to the window.
 */
export function unsettled(state: RemoteState | null, pairing: RemotePairing | null): boolean {
  if (pairing !== null) return true
  const relay = state?.relay ?? null
  return state?.running === true && relay !== null && !relay.connected && relay.retryAt === null
}

/* -------------------------------------------------------------------------- */
/* The QR code                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * The pairing URL as a QR code.
 *
 * Black on white whatever the app's theme is. A camera needs the quiet zone
 * lighter than the modules, and while some scanners cope with an inverted code,
 * "some" is not good enough for the one surface in this app whose entire job is
 * to be photographed. The URL is printed beside it as well, because a phone with
 * a locked-down camera still has a keyboard.
 */
function QrFigure({ url }: { url: string }) {
  const drawn = useMemo(() => {
    try {
      return { matrix: encodeQr(url), failure: null as string | null }
    } catch (error) {
      return {
        matrix: null,
        failure:
          error instanceof Error ? error.message : 'That address could not be drawn as a QR code.',
      }
    }
  }, [url])

  if (!drawn.matrix) {
    // Never a truncated code: a QR carrying half a token is a URL that goes
    // somewhere else, silently.
    return <Notice tone="warn">{drawn.failure}</Notice>
  }

  const side = drawn.matrix.size + QR_QUIET_ZONE * 2
  return (
    <svg
      className="remote-qr"
      viewBox={qrViewBox(drawn.matrix)}
      role="img"
      aria-label="QR code for the pairing address"
      shapeRendering="crispEdges"
    >
      <rect className="remote-qr-paper" x="0" y="0" width={side} height={side} />
      <path className="remote-qr-ink" d={qrPath(drawn.matrix)} />
    </svg>
  )
}

/* -------------------------------------------------------------------------- */
/* The view                                                                    */
/* -------------------------------------------------------------------------- */

/** Which control is mid-call, so only that one goes busy. */
export type RemoteBusy = string | null

export interface RemoteActions {
  enable(next: boolean): void
  confirmEnable(): void
  dismissEnable(): void
  pair(): void
  closePairing(): void
  /** Which way the code on screen should send the phone. Nothing is re-minted. */
  choosePath(path: PairPath): void
  approve(device: RemoteDevice): void
  deny(device: RemoteDevice): void
  revoke(device: RemoteDevice): void
  disconnect(connection: RemoteConnection): void
  /**
   * Close one page a phone has open on a port of this Mac.
   *
   * Takes the connection as well as the tunnel because the id is only unique
   * inside its own hub — and because the notice this prints names the device.
   */
  stopTunnel(connection: RemoteConnection, tunnel: RemoteTunnel): void
}

export interface RemoteViewProps {
  /** Null until the first read lands, or when the bridge is missing. */
  state: RemoteState | null
  /** True when the preload exposes the channels at all. */
  wired: boolean
  /**
   * Channels this build is missing while still exposing enough to draw the
   * panel. Named on screen, because a button whose channel is absent must not
   * look like a button that works.
   */
  missing?: ReadonlyArray<keyof RemoteBridge>

  /** The last read failed; what is on screen may be stale. */
  problem: string | null
  /** The outcome of the last thing the user pressed. */
  notice: { ok: boolean; text: string } | null
  pairing: RemotePairing | null
  /** Seconds left on the code, or null when there is no code or no stated expiry. */
  secondsLeft: number | null
  busy: RemoteBusy
  confirmEnable: boolean
  /**
   * Which way the person chose to send the phone, or null for "whichever is
   * best". Never the last word: a path that has gone away falls back rather than
   * leaving a dead link on screen — see `chooseRoute`.
   */
  pairPath: PairPath | null
  actions: RemoteActions
  now: number
  /**
   * What to call the machine this window is on.
   *
   * Passed rather than sniffed at each use site for the reason
   * `src/main/platform/host.ts` gives about `process.platform`: a branch on the
   * platform written inline can only be exercised on the platform it was
   * written on, and everything here is written on a Mac. As a prop, a test can
   * pin the Windows answer and the macOS answer side by side in one run —
   * which is how the sentences below are checked at all.
   */
  platform?: UiPlatform
}

const STATE_LABEL: Record<RemoteDeviceState, string> = {
  pending: 'Waiting for you',
  approved: 'Approved',
  revoked: 'Revoked',
}

/* ------------------------------------------------------------- the paths -- */

/**
 * One way in, with its own state.
 *
 * Two of these rather than one combined verdict, because the two fail
 * independently and a phone only needs one of them to work. The pill is the
 * first thing read and it is the thing most likely to be a lie, so it is drawn
 * from `connected` and from nothing else — never from "we asked it to start".
 */
function PathRow({
  name,
  tone,
  pill,
  blurb,
  children,
}: {
  name: string
  tone: 'ok' | 'down' | 'off'
  pill: string
  blurb: string
  children?: ReactNode
}) {
  return (
    <li className="remote-path" data-state={tone}>
      <div className="remote-path-head">
        <span className="remote-path-name">{name}</span>
        <span className="remote-pill" data-state={tone}>
          {pill}
        </span>
      </div>
      <p className="remote-path-blurb">{blurb}</p>
      {children}
    </li>
  )
}

/** A labelled value: an address, a host id, a fingerprint. Aligned in a column. */
function Fact({ label, value }: { label: string; value: string }) {
  return (
    <p className="remote-fact">
      <span className="remote-fact-label">{label}</span>
      <code className="remote-fact-value">{value}</code>
    </p>
  )
}

export function RemoteView({
  state,
  wired,
  missing = [],
  problem,
  notice,
  pairing,
  secondsLeft,
  busy,
  confirmEnable,
  pairPath,
  actions,
  now,
  platform = detectPlatform(),
}: RemoteViewProps) {
  const ids = useId()
  // "this Mac" on a Mac, "this PC" on Windows. Every sentence on this screen is
  // about the machine the reader is sitting at, so the noun has to be the one
  // they would use for it.
  const machine = thisMachine(platform)
  const Machine = ThisMachine(platform)
  const head = (
    <SectionHead
      title="Remote access"
      blurb={`Drive ${machine} from a phone — across your tailnet, or through the relay from anywhere.`}
    />
  )

  if (!wired) {
    return (
      <>
        {head}
        <Notice tone="warn">
          Remote access is not wired into this build. Nothing is listening, and nothing on this
          screen would turn anything on.
        </Notice>
      </>
    )
  }

  const running = state?.running === true
  const expired = secondsLeft !== null && secondsLeft <= 0
  const pending = state?.devices.filter((device) => device.state === 'pending') ?? []
  const devices = state?.devices ?? []
  const connections = state?.connections ?? []

  const relay = state?.relay ?? null
  const relayLive = relay?.connected === true
  const direct = state?.url ?? null

  // Every route that would work this second, and the one on screen. Both are
  // derived rather than remembered: a path that goes away while a code is up has
  // to stop being offered, not stay drawn until something re-renders.
  const routes = state && pairing ? pairingRoutes(state, pairing.token, platform) : []
  const route = chooseRoute(routes, pairPath)
  // Asked without a token, because the button exists before the code does.
  const canPair = state ? pairingPaths(state).length > 0 : false

  return (
    <>
      {head}

      <Group>
        <div className="settings-item">
          <Row
            label="Let approved devices in"
            // It used to read "Off by default", which was true and is not any
            // more: this machine dials out on launch so a paired phone has
            // something to attach to without anyone opening this panel first.
            // Leaving the old sentence there would have the switch describing
            // the opposite of its own position.
            help={`On, so a paired phone can always reach ${machine}. Turn it off and nothing can, until you turn it back on.`}
            labelId={`${ids}-label`}
            helpId={`${ids}-help`}
            control={
              // A switch is an input with no text of its own; without these it
              // is announced as an unlabelled checkbox.
              <Switch
                checked={running}
                disabled={state === null || busy !== null}
                labelledBy={`${ids}-label`}
                describedBy={`${ids}-help`}
                onChange={actions.enable}
              />
            }
          />
        </div>

        <p className="settings-prose">
          What is on the other side of this switch is a <strong>shell</strong>. A device you approve
          can type into any session running here — your files, your keys, your git remotes — exactly
          as if it were sitting at this keyboard. Nothing is published to the internet: on your
          tailnet the traffic never leaves your own network, and through the relay it is sealed end
          to end, so the service in the middle routes bytes it holds no key for. Neither path lets
          anything in on its own — a code you mint here and an approval you give here do.
        </p>

        {state === null && problem === null && (
          // Said once, and it resolves into a state or into the error below.
          // There is no branch here that leaves this on screen for good.
          <p className="settings-prose">Reading the current state…</p>
        )}

        {confirmEnable && (
          // Inline rather than a dialog, for the reason BrowserSection gives:
          // two modals both listen for Escape, and the inner one closes the
          // window behind it.
          <div className="settings-confirm">
            <span>
              Turn on remote access? Approved devices get a shell on {machine} until you turn it
              off.
            </span>
            <Button tone="primary" onClick={actions.confirmEnable}>
              Turn it on
            </Button>
            <Button onClick={actions.dismissEnable}>Leave it off</Button>
          </div>
        )}

        {missing.length > 0 && (
          // Half-wired is worse than unwired, because it looks like it works.
          <Notice tone="error">
            This build is missing {missing.length} of the remote channels ({missing.join(', ')}).
            Anything that needs one will say so rather than appear to have worked.
          </Notice>
        )}

        {problem && (
          <Notice tone="error">
            {problem} Anything below was read before that and may be out of date.
          </Notice>
        )}

        {notice && <Notice tone={notice.ok ? 'info' : 'warn'}>{notice.text}</Notice>}
      </Group>

      {!running && state?.reason && (
        <Group title="Not serving">
          {/* Verbatim. `tailnet.ts` keeps these sentences in one table precisely
              so each of them says what to do, and a paraphrase written here
              would go stale the first time one of them changed. */}
          <Notice tone="warn">{state.reason}</Notice>
          <p className="settings-prose">
            The switch shows whether it is actually serving, not whether it was asked to. Fix the
            above and turn it on again.
          </p>
        </Group>
      )}

      {running && (
        <Group title="How a phone gets here">
          <ul className="remote-paths">
            <PathRow
              name="Direct on your tailnet"
              tone={direct === null ? 'off' : 'ok'}
              pill={direct === null ? 'Unavailable' : 'Ready'}
              blurb="One hop over WireGuard with nothing in the middle. Both devices have to be on the same tailnet."
            >
              {direct === null ? (
                <p className="remote-path-note">
                  {/* Verbatim, and separate from `reason`: this is why the
                      faster route is missing, not why remote access is down. */}
                  {state?.directReason ??
                    `${Machine} is not serving a tailnet address, and did not say why.`}{' '}
                  {relayLive
                    ? 'Remote access is still up — everything below is going through the relay.'
                    : ''}
                </p>
              ) : (
                <>
                  <Fact label="Address" value={direct} />
                  {state?.address && <Fact label="Tailnet IP" value={state.address} />}
                </>
              )}
            </PathRow>

            <PathRow
              name="Through the relay"
              tone={relay === null ? 'off' : relayLive ? 'ok' : 'down'}
              pill={relay === null ? 'Off' : relayLive ? 'Connected' : 'Not connected'}
              blurb={`A rendezvous service ${machine} dials out to. It staples two sockets together and carries sealed bytes it cannot read, so a phone on any network can reach this one.`}
            >
              {relay === null ? (
                <p className="remote-path-note">
                  {/* `relaying` is only false here when no relay was built at
                      all, which `relayEnabled` decides from the environment or
                      from how the app was assembled. Naming both is honest;
                      naming one would be a guess. */}
                  This build is not dialling a relay, so the tailnet is the only way in — either
                  TERMINALDECK_RELAY is off, or it was assembled without one.
                </p>
              ) : relayLive ? (
                <>
                  <Fact label="Host id" value={relay.hostId} />
                  {/* Empty only if the identity is half-published, and an empty
                      row under "Fingerprint" reads as "this machine has none". */}
                  {relay.fingerprint !== '' && (
                    <Fact label="Fingerprint" value={relay.fingerprint} />
                  )}
                  <p className="remote-path-note">
                    Dialled out to {relay.url}.{' '}
                    {relay.channels > 0
                      ? `Carrying ${relay.channels} connection${relay.channels === 1 ? '' : 's'} right now.`
                      : 'Nothing is coming through it right now.'}
                  </p>
                </>
              ) : (
                <p className="remote-path-note">
                  {relay.reason ?? 'It is not connected, and did not say why.'}{' '}
                  {retryNote(relay.retryAt, now) ?? ''}
                </p>
              )}
            </PathRow>
          </ul>
        </Group>
      )}

      {running && (
        <Group title="Pair a device">
          {!pairing && (
            <>
              <p className="settings-prose">
                A code is good for one device and expires in {PAIRING_WINDOW_SECONDS} seconds.
                Scanning it asks to be let in; it does not let anything in — you still approve the
                device below.
              </p>
              <Button tone="primary" onClick={actions.pair} disabled={busy !== null || !canPair}>
                {busy === 'pair' ? 'Asking…' : 'Pair a device'}
              </Button>
              {!canPair && (
                // The button is dead on purpose, and a dead button with no
                // sentence beside it is the panel refusing to say why.
                <Notice tone="warn">
                  Neither way in is up, so a code would point at nothing. The two rows above say
                  what is wrong with each; fix one and this will mint.
                </Notice>
              )}
            </>
          )}

          {pairing && (
            <div className="remote-pairing">
              {route === null ? (
                // Reachable: the tailnet can go away and the relay can drop
                // while a code is on screen. Saying "expired" here would be the
                // wrong reason, and the right one tells you what to do.
                <Notice tone="warn">
                  There is nowhere to point this code any more — every way in went away while it
                  was on screen. Cancel it and make another once one of them is back.
                </Notice>
              ) : expired ? (
                <Notice tone="warn">
                  That code has expired. Nothing was let in, and it no longer works.
                </Notice>
              ) : (
                <QrFigure url={route.link} />
              )}

              <div className="remote-pairing-side">
                {routes.length > 1 && !expired && (
                  // Both paths carry the same one-shot token, so this re-points
                  // the code rather than minting another. What it decides is the
                  // endpoint the phone keeps, which is why it is a choice and
                  // not a silent preference.
                  <div
                    className="remote-choice"
                    role="group"
                    aria-label={`How this phone should reach ${machine}`}
                  >
                    {routes.map((option) => (
                      <button
                        key={option.kind}
                        type="button"
                        className="remote-choice-btn"
                        aria-pressed={option.kind === route?.kind}
                        onClick={() => actions.choosePath(option.kind)}
                      >
                        {option.label}
                      </button>
                    ))}
                  </div>
                )}

                {route !== null && !expired && <p className="remote-path-note">{route.note}</p>}

                {secondsLeft !== null ? (
                  <p
                    className={expired ? 'remote-countdown remote-countdown-done' : 'remote-countdown'}
                  >
                    {expired ? 'Expired' : `Expires in ${secondsLeft}s`}
                  </p>
                ) : (
                  <p className="remote-countdown remote-countdown-done">
                    The main process did not say when this expires.
                  </p>
                )}

                {route?.kind === 'relay' && relay !== null && relay.fingerprint !== '' && !expired && (
                  // The one check a person can actually make. The phone shows
                  // these same six groups before it sends anything, because it
                  // learned the key from this code — so a mismatch means the
                  // code being scanned is not the one on this screen.
                  <div className="remote-check">
                    <span className="remote-check-label">{`This ${machineNoun(platform)}’s fingerprint`}</span>
                    <code className="remote-fingerprint">{relay.fingerprint}</code>
                    <span className="remote-check-note">
                      The phone shows the same six groups before it connects. If they do not match,
                      something else answered to {machine}’s name — cancel, do not approve.
                    </span>
                  </div>
                )}

                {!expired && route !== null && (
                  <>
                    <p className="settings-prose">Can’t scan it? Type this into the phone instead:</p>
                    <p className="remote-url">
                      <code>{route.link}</code>
                    </p>
                  </>
                )}

                <div className="settings-chips">
                  <Button onClick={actions.closePairing} disabled={busy !== null}>
                    {expired ? 'Done' : 'Cancel this code'}
                  </Button>
                  {expired && (
                    <Button tone="primary" onClick={actions.pair} disabled={busy !== null}>
                      New code
                    </Button>
                  )}
                </div>
              </div>
            </div>
          )}
        </Group>
      )}

      {running && (
        <Group
          title={connections.length > 0 ? `Attached now — ${connections.length}` : 'Attached now'}
        >
          {connections.length === 0 ? (
            <p className="settings-prose">Nothing is attached.</p>
          ) : (
            <ul className="remote-list">
              {connections.map((connection) => (
                <li className="remote-row remote-row-live" key={connection.id}>
                  <span className="remote-live" role="status">
                    <span className="remote-live-dot" aria-hidden="true" />
                    Attached
                  </span>
                  <span className="remote-row-text">
                    <span className="remote-row-name">{connection.deviceName}</span>
                    <span className="remote-row-note">{connectionNote(connection, now)}</span>
                  </span>
                  <Button
                    tone="danger"
                    onClick={() => actions.disconnect(connection)}
                    disabled={busy !== null}
                  >
                    {busy === `connection:${connection.id}` ? 'Closing…' : 'Disconnect'}
                  </Button>

                  {/* Only when there is one. Most phones never tap a port, and
                      a "no pages open" line under every row would be noise
                      about the ordinary case. */}
                  {connection.tunnels.length > 0 && (
                    <ul className="remote-tunnels">
                      {connection.tunnels.map((tunnel) => (
                        <li className="remote-tunnel" key={tunnel.id}>
                          <span className="remote-tunnel-text">
                            <span className="remote-tunnel-name">
                              <code className="remote-tunnel-port">localhost:{tunnel.port}</code>
                              <span className="remote-tunnel-what">
                                open in a browser on this phone
                              </span>
                            </span>
                            <span className="remote-row-note">{tunnelNote(tunnel, now)}</span>
                          </span>
                          <Button
                            onClick={() => actions.stopTunnel(connection, tunnel)}
                            disabled={busy !== null}
                          >
                            {busy === `tunnel:${tunnel.id}` ? 'Stopping…' : 'Stop'}
                          </Button>
                        </li>
                      ))}
                    </ul>
                  )}
                </li>
              ))}
            </ul>
          )}

          {connections.some((connection) => connection.tunnels.length > 0) && (
            // Said once, under the list, rather than on every row. The thing
            // worth knowing is what these are and that Stop is cheap — a
            // person who has to guess whether "Stop" kills their session will
            // leave a page open on this Mac rather than risk it.
            <p className="settings-prose">
              A port listed above is being served from {machine} to that phone’s browser, over the
              same connection. <strong>Stop closes the page, and nothing else.</strong> The session
              keeps running, the device stays approved, and the phone can tap the port again.
            </p>
          )}
        </Group>
      )}

      {/* Only once something has been read: "no device has been paired" is a
          claim, and before the first answer lands it is an unfounded one. */}
      {state !== null && (
        <Group title="Devices">
          {pending.length > 0 && (
            <p className="settings-prose">
              {pending.length === 1 ? 'A device is' : `${pending.length} devices are`} waiting to be
              let in. Approve only the one you are holding —{' '}
              {pending.some((device) => device.fingerprint !== null)
                ? `the phone shows its own fingerprint, and the row below shows what ${machine} received.`
                : 'this one paired without a key, so there is no fingerprint to compare.'}
            </p>
          )}

          {devices.length === 0 ? (
            <p className="settings-prose">
              No device has been paired. Nothing can connect until one is.
            </p>
          ) : (
            <ul className="remote-list">
              {devices.map((device) => (
                <li className={`remote-row remote-row-${device.state}`} key={device.id}>
                  <span className="remote-state">{STATE_LABEL[device.state]}</span>
                  <span className="remote-row-text">
                    <span className="remote-row-name">{device.name}</span>
                    <span className="remote-row-note">
                      Last seen {whenSeen(device.lastSeenAt, now)}
                      {device.addedAt === null ? '' : ` · paired ${whenSeen(device.addedAt, now)}`}
                    </span>
                    {device.state !== 'revoked' &&
                      (device.fingerprint === null ? (
                        // Not a cosmetic gap. No key means no sealed channel,
                        // so this device cannot come in through the relay at
                        // all — said here rather than discovered the first time
                        // it is tried from a hotel.
                        <span className="remote-row-note">
                          No key stored — tailnet only, and it cannot use the relay.
                        </span>
                      ) : (
                        <span className="remote-row-note">
                          <code className="remote-fingerprint">{device.fingerprint}</code>
                        </span>
                      ))}
                  </span>
                  <span className="settings-chips">
                    {device.state === 'pending' && (
                      <>
                        <Button
                          tone="primary"
                          onClick={() => actions.approve(device)}
                          disabled={busy !== null}
                        >
                          Approve
                        </Button>
                        <Button onClick={() => actions.deny(device)} disabled={busy !== null}>
                          Deny
                        </Button>
                      </>
                    )}
                    {device.state === 'approved' && (
                      <Button
                        tone="danger"
                        onClick={() => actions.revoke(device)}
                        disabled={busy !== null}
                      >
                        {busy === `device:${device.id}` ? 'Revoking…' : 'Revoke'}
                      </Button>
                    )}
                  </span>
                </li>
              ))}
            </ul>
          )}

          <p className="settings-prose">
            <strong>Revoking is immediate.</strong> The device is dropped where it stands — mid
            command, mid session — not at its next connection. Disconnecting only closes what is
            open now; an approved device can attach again straight away.
          </p>
        </Group>
      )}
    </>
  )
}

/* -------------------------------------------------------------------------- */
/* The section                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * How often the panel re-reads *while something is genuinely in flux*.
 *
 * There is no steady-state poll. Attachments, detachments and departures arrive
 * on `onRemoteConnections` within milliseconds, and a read that costs two IPC
 * round trips every four seconds forever to hear the same answer is strictly
 * worse than subscribing: more CPU, more IPC, and staler than the push it was
 * duplicating. See {@link unsettled} for the two bounded windows where this is
 * the only thing that can notice a change, and how each of them ends.
 */
const UNSETTLED_MS = 1000

/**
 * How long after a scheduled relay retry to look.
 *
 * The dial starts at `retryAt`; reading at exactly that instant catches the
 * moment before it, which is the same picture the panel is already showing.
 */
const RETRY_GRACE_MS = 750

/* -------------------------------------------------------------------------- */
/* Calling the main process                                                    */
/* -------------------------------------------------------------------------- */

function missingChannel(name: string): Error {
  return new Error(
    `This build has no ${name} channel, so nothing happened. Remote access is only half wired into it.`,
  )
}

/**
 * Call a bridge method, or reject.
 *
 * The obvious shorthand — `bridge.stopRemote?.() ?? Promise.resolve()` — turns a
 * channel that does not exist into a resolved promise, and `run` then prints the
 * success sentence for it. On this panel that reads "Remote access is off." over
 * a server that is still serving. A missing channel is a broken build, and it
 * has to arrive as a failure.
 */
function invoke(method: (() => Promise<unknown>) | undefined, name: string): Promise<unknown> {
  return typeof method === 'function' ? method() : Promise.reject(missingChannel(name))
}

function invokeWith(
  method: ((id: string) => Promise<unknown>) | undefined,
  name: string,
  id: string,
): Promise<unknown> {
  return typeof method === 'function' ? method(id) : Promise.reject(missingChannel(name))
}

/** As above, for the one channel that needs two ids to say what it means. */
function invokeWithPair(
  method: ((first: string, second: string) => Promise<unknown>) | undefined,
  name: string,
  first: string,
  second: string,
): Promise<unknown> {
  return typeof method === 'function' ? method(first, second) : Promise.reject(missingChannel(name))
}

/**
 * What the registry says about one device in the list an action answered with.
 *
 * `undefined` when the answer was not a readable device list, or did not mention
 * this device — and then the caller says what it asked for rather than inventing
 * an outcome. The point is the case where it *is* readable and disagrees:
 * `approveDevice` returns false for a device that was revoked or has since gone,
 * and the IPC handler answers with the list either way, so "can connect" would
 * otherwise be printed over a row that still says Revoked.
 */
export function deviceStateAfter(answer: unknown, id: string): RemoteDeviceState | undefined {
  return toRemoteDevices(answer).find((device) => device.id === id)?.state
}

/* -------------------------------------------------------------------------- */
/* The actions                                                                 */
/* -------------------------------------------------------------------------- */

export interface RemoteActionDeps {
  bridge: Partial<RemoteBridge>
  /** The code on screen right now, so turning the switch off can kill it too. */
  pairing: RemotePairing | null
  setPairing(next: RemotePairing | null): void
  setConfirmEnable(next: boolean): void
  /** Which way the code on screen points. A view preference, not a call. */
  setPairPath(next: PairPath): void
  /** Runs the work, reports it in the main process's words, then re-reads. */
  run(key: string, work: () => Promise<unknown>, done: string | null): void
  /** False once the panel has gone, so nothing writes to a dead component. */
  isAlive(): boolean
}

/**
 * Every button on this panel, as a plain function of its dependencies.
 *
 * Split out of the component on purpose. There is no DOM in this repo's test
 * environment, so anything left inside a `useState` closure is reachable by
 * nothing but a person clicking it in a packaged build — and what is behind
 * these functions is a shell on the machine. Pulled out here, the
 * dangerous ones are pinned: that turning it *on* takes two presses and turning
 * it *off* takes one, that Deny revokes rather than approves, and that a call
 * that never happened is never reported as one that did.
 */
export function remoteActions(deps: RemoteActionDeps): RemoteActions {
  const { bridge, pairing, setPairing, setConfirmEnable, setPairPath, run, isAlive } = deps

  /** Approve/Deny/Revoke: do it, then believe the list that comes back, not the ask. */
  const settle = (
    key: string,
    method: ((id: string) => Promise<unknown>) | undefined,
    channel: string,
    device: RemoteDevice,
    want: RemoteDeviceState,
    done: string,
  ): void =>
    void run(
      key,
      async () => {
        const after = deviceStateAfter(await invokeWith(method, channel, device.id), device.id)
        if (after !== undefined && after !== want) {
          throw new Error(
            `${device.name} is still listed as ${STATE_LABEL[after].toLowerCase()}, so that did not take.`,
          )
        }
      },
      done,
    )

  return {
    enable: (next) => {
      if (next) {
        // On needs the second press. Off does not.
        setConfirmEnable(true)
        return
      }
      setConfirmEnable(false)
      const live = pairing
      setPairing(null)
      void run(
        'toggle',
        async () => {
          // A code minted a moment ago outlives the switch otherwise: the main
          // process holds it for the rest of its minute, so turning remote
          // access back on inside that window would still let a photographed QR
          // redeem. Its failure must not stop the switch, which is the part
          // that actually closes the door.
          if (live && typeof bridge.cancelRemotePairing === 'function') {
            await bridge.cancelRemotePairing().catch(() => undefined)
          }
          await invoke(bridge.stopRemote, 'stop')
        },
        'Remote access is off.',
      )
    },
    confirmEnable: () => {
      setConfirmEnable(false)
      void run(
        'toggle',
        async () => {
          const answer = toRemoteState(await invoke(bridge.startRemote, 'start'), [])
          // `remote:start` resolves with a status rather than throwing, so a
          // start that did not take arrives here looking like a success. Its own
          // sentence is the failure message; inventing one would bury it.
          if (answer && !answer.running) {
            throw new Error(answer.reason ?? 'It did not start, and did not say why.')
          }
        },
        'Remote access is on. Nothing can connect until you pair and approve a device.',
      )
    },
    dismissEnable: () => setConfirmEnable(false),
    pair: () =>
      void run(
        'pair',
        async () => {
          const minted = toRemotePairing(await invoke(bridge.startRemotePairing, 'pair'))
          if (!minted) throw new Error('The main process did not return a pairing code.')
          if (isAlive()) setPairing(minted)
        },
        null,
      ),
    closePairing: () => {
      setPairing(null)
      void run('pair', () => invoke(bridge.cancelRemotePairing, 'cancel pairing'), null)
    },
    // The only control on this panel that calls nothing. Both paths carry the
    // same one-shot token, so re-pointing the code is a local decision — and
    // minting a second one here would burn the first without saying so.
    choosePath: (path) => setPairPath(path),
    approve: (device) =>
      settle(
        `device:${device.id}`,
        bridge.approveRemoteDevice,
        'approve device',
        device,
        'approved',
        `${device.name} can connect.`,
      ),
    // Deny is a revoke of something that was never approved. The registry has
    // three states and `revoked` is the one that means "not allowed in", so
    // there is no fourth channel for this — only a different sentence, because
    // "revoked" is the wrong word for a device that never had anything.
    deny: (device) =>
      settle(
        `device:${device.id}`,
        bridge.revokeRemoteDevice,
        'revoke device',
        device,
        'revoked',
        `${device.name} was refused, and cannot be approved later — pair it again if that was a slip.`,
      ),
    revoke: (device) =>
      settle(
        `device:${device.id}`,
        bridge.revokeRemoteDevice,
        'revoke device',
        device,
        'revoked',
        `Revoked ${device.name}.`,
      ),
    disconnect: (connection) =>
      void run(
        `connection:${connection.id}`,
        () => invokeWith(bridge.disconnectRemoteConnection, 'disconnect connection', connection.id),
        `Disconnected ${connection.deviceName}. It can attach again unless you revoke it.`,
      ),
    // One press, no second one. Everything else destructive on this panel asks
    // twice or says "immediate", and this deliberately does neither: it closes
    // a web page. Nothing is lost, nothing is revoked, and the phone can tap
    // the port again — so a confirmation here would be friction bought with
    // nothing, and would teach people to click through the ones that matter.
    stopTunnel: (connection, tunnel) =>
      void run(
        `tunnel:${tunnel.id}`,
        () => invokeWithPair(bridge.stopRemoteTunnel, 'stop tunnel', connection.id, tunnel.id),
        `Closed the page on port ${tunnel.port}. ${connection.deviceName} can open it again.`,
      ),
  }
}

interface Props {
  /** Defaults to `window.deck`. Passed in by tests, and by nothing else. */
  bridge?: Partial<RemoteBridge>
}

export function RemoteSection({ bridge: provided }: Props) {
  // Resolved once. `resolveRemoteBridge` builds a new object every call, and an
  // unstable bridge would restart the poll — and the unmount cleanup that kills
  // a live pairing code — on every render.
  const bridge = useMemo(() => provided ?? resolveRemoteBridge(), [provided])
  const wired = typeof bridge.remoteStatus === 'function'
  const missing = useMemo(() => (wired ? missingRemoteMethods(bridge) : []), [bridge, wired])

  const [state, setState] = useState<RemoteState | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null)
  const [pairing, setPairing] = useState<RemotePairing | null>(null)
  const [busy, setBusy] = useState<RemoteBusy>(null)
  const [confirmEnable, setConfirmEnable] = useState(false)
  // Null means "whichever path is best", which is what somebody who has never
  // touched this control wants. It outlives one code on purpose: a person who
  // chose the tailnet for their first phone means it for the second.
  const [pairPath, setPairPath] = useState<PairPath | null>(null)
  const [now, setNow] = useState(() => Date.now())

  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  /**
   * The read that is allowed to win.
   *
   * Several things start a read — the push from main, the user coming back to
   * the window, the tail of every action — so more than one is in flight
   * routinely, and they do not resolve in the order they were sent. Without
   * this, a read issued *before* a revoke can land *after* it and repaint the
   * device as approved. Something else would correct it later, but "approved"
   * on this screen is a claim about who has a shell here, and it must never be
   * a stale one.
   */
  const readSeq = useRef(0)

  const refresh = useCallback(async (): Promise<void> => {
    if (typeof bridge.remoteStatus !== 'function') return
    const seq = ++readSeq.current
    try {
      // Together, so the device list and the connection list on screen are
      // never from two different moments.
      const [status, devices] = await Promise.all([
        bridge.remoteStatus(),
        bridge.listRemoteDevices?.() ?? Promise.resolve([]),
      ])
      if (!alive.current || seq !== readSeq.current) return
      const parsed = toRemoteState(status, devices)
      if (parsed) {
        setState(parsed)
        setProblem(null)
        // A read is also the freshest the clock ever gets, and the new state
        // may put different timestamps on screen — so the tick below is
        // recomputed against this moment rather than the last one.
        setNow(Date.now())
      } else {
        setProblem('The main process answered with something this panel could not read.')
      }
    } catch (error) {
      if (alive.current && seq === readSeq.current) {
        setProblem(errorText(error, 'Could not read the remote access state.'))
      }
    }
  }, [bridge])

  useEffect(() => {
    if (!wired) return
    void refresh()
  }, [wired, refresh])

  useEffect(() => {
    if (typeof bridge.onRemoteConnections !== 'function') return
    // The mechanism, not a hint. The main process pushes here on every
    // authenticate, attach, detach and leave, which is every change this panel
    // draws in its two busiest sections. The payload is ignored on purpose: one
    // read is one source of truth, and an event that only carried connections
    // would leave the device list beside it a step behind.
    return bridge.onRemoteConnections(() => void refresh())
  }, [bridge, refresh])

  // Coming back to the window is the moment a stale answer starts to matter,
  // and it is also the moment the things nothing pushes are most likely to have
  // changed — a laptop that closed its lid in one place and opened it in
  // another has a different tailnet than the one this panel last read.
  useWhenActive(() => {
    if (wired) void refresh()
  })

  /** Run one action, say what happened in the main process's words, then re-read. */
  const run = useCallback(
    async (key: string, work: () => Promise<unknown>, done: string | null): Promise<void> => {
      setBusy(key)
      setNotice(null)
      try {
        await work()
        if (alive.current && done) setNotice({ ok: true, text: done })
      } catch (error) {
        if (alive.current) {
          setNotice({ ok: false, text: errorText(error, 'That did not go through.') })
        }
      } finally {
        if (alive.current) setBusy(null)
        // Always, including after a failure: what this panel claims about the
        // world comes from a read, never from the fact that a call returned.
        void refresh()
      }
    },
    [refresh],
  )

  const pairingRef = useRef<RemotePairing | null>(null)
  pairingRef.current = pairing

  useEffect(() => {
    return () => {
      // A code left alive when this panel closes is a key nobody is watching.
      if (pairingRef.current && typeof bridge.cancelRemotePairing === 'function') {
        void bridge.cancelRemotePairing()
      }
    }
  }, [bridge])

  // One wake-up, scheduled for the exact moment a label on this panel would
  // read differently — and none at all when nothing on it depends on the clock.
  // Wall clock rather than a counter, still: a laptop that slept for two
  // minutes has an expired code, and a counter would show it forty seconds
  // left. `nextClockChange` is recomputed from the `now` each tick sets, so the
  // chain re-arms itself for as long as there is anything left to move.
  useAt(nextClockChange(state, pairing, now), () => setNow(Date.now()))

  // The two windows where the next change is not announced by anything. Both
  // are bounded and both have somebody watching — see `unsettled`.
  useEvery(unsettled(state, pairing) && wired ? UNSETTLED_MS : null, () => {
    setNow(Date.now())
    void refresh()
  })

  // A retry the relay has already scheduled is a change with a known time on
  // it, so it gets a wake-up of its own rather than a cadence around it.
  useAt(
    state?.relay?.retryAt != null && wired ? state.relay.retryAt + RETRY_GRACE_MS : null,
    () => void refresh(),
  )

  const secondsLeft =
    pairing?.expiresAt == null ? null : Math.max(0, Math.ceil((pairing.expiresAt - now) / 1000))

  const actions = remoteActions({
    bridge,
    pairing,
    setPairing,
    setConfirmEnable,
    setPairPath,
    run: (key, work, done) => void run(key, work, done),
    isAlive: () => alive.current,
  })

  return (
    <>
      <RemoteView
        state={state}
        wired={wired}
        missing={missing}
        problem={problem}
        notice={notice}
        pairing={pairing}
        secondsLeft={secondsLeft}
        busy={busy}
        confirmEnable={confirmEnable}
        pairPath={pairPath}
        actions={actions}
        now={now}
      />
      {/*
        Rendered here, beside `RemoteView`, rather than inside it.

        `RemoteView` is pure on purpose — every state this panel can be in is
        pinned by handing it props and calling `renderToStaticMarkup`, which
        never runs an effect. `DeviceFolders` reads its own grants in an effect,
        so nesting it would put a component that fetches inside the one thing
        here that is provably a function of its arguments, and every existing
        view test would start rendering a child that reports "not available in
        this build" because there is no `window.deck` under the test renderer.

        Below the device roster, and that order is the argument the screen
        makes: pair a device, approve it, then choose what it may open. Choosing
        folders for a device nobody has approved is a setting with no subject.
      */}
      {wired && state !== null && <DeviceFolders devices={grantableDevices(state.devices)} />}
    </>
  )
}

/**
 * The devices worth choosing folders for.
 *
 * Approved only, and the two it drops are dropped for different reasons.
 *
 * A **pending** device cannot open anything at all — it has not been let in —
 * so a folder list for it would be a decision made about a device before the
 * only decision that matters. Approve it first; its row appears the moment you
 * do, which is also the moment the choice starts meaning something.
 *
 * A **revoked** one is gone for good. The trust store never un-revokes, so a
 * phone that comes back pairs again and is issued a *new* device id — the old
 * row could never be reached by anything again, and `FolderGrants.forget` has
 * already dropped whatever it had. Listing it would offer an edit to a record
 * the main process deleted while this panel was open.
 */
export function grantableDevices(devices: readonly RemoteDevice[]): FolderDevice[] {
  return devices
    .filter((device) => device.state === 'approved')
    .map((device) => ({ id: device.id, name: device.name }))
}
