import { useCallback, useEffect, useId, useMemo, useRef, useState, type ReactNode } from 'react'
import { Button, Group, Info, MoreBody, Notice, Row, Switch } from '../settings/controls'
import { useAt, useEvery, useWhenActive } from '../schedule'
import { withDeadline } from '../deadline'
import { errorText } from '../settings/settings-bridge'
import { detectPlatform, machineNoun, thisMachine, type UiPlatform } from '../platform'
import { CODE_LENGTH, normaliseCode } from '../../shared/short-code'
import { CodeEntry } from '../machines/CodeEntry'
import {
  MachineLinks,
  MachineSessionPane,
  machineActions,
  type MachinesHalf,
} from '../machines/MachineLinks'
import { asView, resolveBridge, type MachinesBridge, type MachinesView } from '../machines/types'
import { DeviceFolders, type FolderDevice } from './DeviceFolders'
import {
  DeviceApproval,
  nextStep,
  type ApprovalStep,
  type DeviceKind,
} from './DeviceApproval'
import { DeviceCopilot, type CopilotDevice } from './DeviceCopilot'
import './RemoteSection.css'

/**
 * Remote — every device paired with this machine, and the machines it can reach.
 *
 * ## One section, because it was one subject drawn twice
 *
 * There were two: a **Machines** page in the sidebar and this **Remote**
 * section in Settings. Both listed paired devices. Both showed a pairing code —
 * the *same* code, minted by one desk in the main process, so only one of them
 * could ever honestly be showing it. Both decided for themselves when pairing
 * was possible, and disagreed. Asad, looking at the two rows: they "should be
 * one".
 *
 * The organising idea that made them one is that a phone and a second laptop
 * are the same thing: a device somebody paired with this machine. So there is
 * one roster, one code, one countdown, and one place that says what a paired
 * device may do here. What the machines page had that this did not is the
 * *other* direction — reaching out to a machine and opening a session on it —
 * and that is kept whole, at the bottom, in `machines/MachineLinks.tsx`. It is
 * a different capability rather than a different screen.
 *
 * ## The code is six digits, and nothing else
 *
 * There was a QR code here, and a `terminaldeck://pair?…` link beside it to
 * copy. Both are gone. The QR could only be photographed by a phone, which left
 * a second desktop with nothing, and the link was two hundred characters with a
 * live bearer token in it whose only route between two machines was a messaging
 * app — a pairing token somebody else's server keeps. What replaced them is what
 * `shared/short-code.ts` mints: six digits a person reads off one screen and
 * types into another, which any device can find because the code names a slot at
 * the rendezvous rather than carrying an address.
 *
 * That last clause is a claim about a *dial that has to succeed*, not a property
 * of the digits, and this file used to state it as though it were the latter.
 * The machine has to be sitting in the slot its code names before anything can
 * look the code up, and it can fail to get there — no address to publish, a
 * beacon that would not build, a slot that did not come up in six seconds. So
 * the main process answers `remote:pair` with `findable` alongside the code, and
 * this panel draws the two states differently. A code that nothing can look up
 * must never be drawn like one that anything can: they are the same six digits,
 * and the failure lands a minute later on a different device, which has no way
 * to say which end was at fault.
 *
 * This file never states the format. `CODE_LENGTH` and `normaliseCode` come
 * from that module, because the format has already changed once — eight
 * Crockford characters with a hyphen — and every screen that had written its own
 * copy of it was wrong for a release.
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
 * `remote:start` can succeed at being asked and fail at running — a port in
 * use, a relay that will not answer. So the switch is bound to whether the
 * server is *running*, and a start that did not take leaves the switch off with
 * the main process's own sentence underneath it. A switch that stayed on next to
 * a dead server would be the one lie this screen cannot afford.
 *
 * ## The relay is the network. The direct path is an optimisation.
 *
 * A device reaches this machine through a rendezvous relay this machine dials
 * out to — no install, no account, works from a hotel wifi. That is the product's
 * network and it is what this panel leads with, and it is also what makes a
 * six-digit code enough: the code names a slot at the relay, and whatever types
 * it finds this machine there.
 *
 * There is a second, faster route for the small number of people who already run
 * a mesh VPN: one hop, no third party. It is drawn **only when it genuinely
 * exists on this machine**, and its absence is reported nowhere. That is not
 * politeness, it is the correction of a real defect. The panel used to print the
 * VPN's own complaint — "Tailscale is installed but this Mac is logged out of
 * the tailnet" — under a connected relay, beside a working phone. Asad, on
 * finding it: *"a lot of users will not even know about Tailscale."* To a reader
 * who has never heard of it that sentence is a fault in *this* product, and it
 * sends someone to fix a machine that is not broken.
 *
 * So `directReason` is not part of this panel's world. It is in the main
 * process's status and it is deliberately not read here — see `toRemoteState`.
 *
 * The corollary is the one thing this panel must never do: draw the relay as
 * connected when `relay.connected` is false. A code handed out for a path that
 * is down produces a phone that scans, waits, and fails — so a path that is not
 * up is not offered, and its own sentence says what to do about it.
 *
 * ## No spinner that never resolves
 *
 * Every "not working" case here is a sentence, quoted verbatim from the main
 * process, which is the only thing that knows why. Those sentences are written
 * to be actionable, so this panel prints them and adds nothing of its own.
 *
 * ## Why the rendering is split from the fetching
 *
 * `RemoteView` is a separate exported component that takes everything it draws.
 * `renderToStaticMarkup` never runs an effect, so a panel that fetched its own
 * status inside the component that renders it would be testable in exactly one
 * state — the empty one — and the states that matter here are the other five.
 *
 * That now covers the machines half as well: it arrives as {@link MachinesHalf},
 * so one static render holds the whole merged section and a test can ask
 * whether every capability the two old screens had is still reachable. The only
 * thing that cannot come through that door is the terminal, which builds an
 * xterm against a real DOM — so it is passed in as a node.
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
  /**
   * Let a device in — and, in the same call, decide what it is and what it may
   * reach.
   *
   * Three arguments rather than one, and that is the security fix rather than a
   * convenience. It used to take an id: approval admitted the device and the
   * folder choice was a separate block further down this page that nobody had to
   * visit, so the ordinary path let a phone in with every open project reachable.
   * The main process now writes the kind and the folders *before* it approves,
   * so a caller that cannot answer both cannot let anything in.
   */
  approveRemoteDevice(deviceId: string, kind: string, folders: string[]): Promise<unknown>
  /** Which devices are yours and which are guests. Read-only; a kind never changes. */
  listRemoteDeviceKinds(): Promise<unknown>
  /** The app's own native folder chooser, the one Open Project uses. */
  pickProjectFolder(): Promise<string | null>
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
  'listRemoteDeviceKinds',
  'pickProjectFolder',
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
   * cosmetic: no key means no sealed channel, so that device cannot come in
   * through the relay at all. It is said on the row rather than discovered the
   * first time it fails from a coffee shop.
   */
  fingerprint: string | null
}

/**
 * The approval flow, as the panel holds it.
 *
 * One at a time, and deliberately: two phones pairing at once is a real thing
 * that happens, and two flows on screen with two fingerprints to compare is the
 * arrangement in which somebody approves the wrong one. The second device stays
 * on the list with its own button, waiting.
 */
export interface ApprovalState {
  device: RemoteDevice
  step: ApprovalStep
  kind: DeviceKind | null
  /** Chosen so far. Empty is the starting state and a real answer. */
  folders: string[]
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
   * is the ordinary state of nearly every machine — not an error, not a
   * degraded mode, and not a reason to refuse to pair. Most people will never
   * see a value here and must never learn that the field exists.
   */
  url: string | null
  /** The raw address behind it, which is what still works when MagicDNS does not. */
  address: string | null
  /** Why nothing at all is running, in the main process's words. Null when it is. */
  reason: string | null
  relay: RemoteRelay | null
  devices: RemoteDevice[]
  connections: RemoteConnection[]
}

/** Mirrors `ShownPairingCode`. The token is shown once and never stored by this panel. */
export interface RemotePairing {
  token: string
  /** Epoch ms. Null when the main process did not say, and then nothing counts down. */
  expiresAt: number | null
  /**
   * Can anything look this code up, or is it six digits with nothing behind them?
   *
   * A code only reaches a phone, a tablet or a second desktop if this machine is
   * sitting in the rendezvous slot the code names, answering with its address.
   * The main process claims that slot as it mints, and this is what it says
   * about the attempt — false when it had no address to publish, when the
   * beacon could not be built, or when the slot did not come up in time.
   *
   * Null is "the main process did not say", the same convention `expiresAt`
   * uses: an older main process against a newer window. Nothing is invented
   * from it — the panel falls back to what it can see for itself, which is
   * whether the relay row is connected.
   *
   * This is the field the panel exists to be honest about. False and drawn like
   * success is a person typing six digits into a phone that will never find
   * anything, and being told so a minute later by the device that is not the one
   * at fault.
   */
  findable: boolean | null
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
/**
 * A device's name, as a person would recognise it.
 *
 * The name comes off the wire from whatever the client reports about itself,
 * and Android reports its *build target*: a real paired device showed up here
 * as "Google sdk_gphone64_arm64", which is the emulator's system-image name and
 * is not something anybody would recognise as their phone. It sat as the title
 * of a card whose entire job is answering "which of your devices is this".
 *
 * Two rules, and nothing invented beyond them. The Android emulator's model
 * string is a known constant, so it is called what it is. Everything else keeps
 * its own name with underscores read as the spaces they stand in for — a build
 * identifier is written `SM_G991B`, a name is written with spaces.
 *
 * Nothing here is identity: a device is identified by its id everywhere it
 * matters, and this is only what the row prints.
 */
export function deviceLabel(raw: string): string {
  const name = raw.trim()
  if (name === '') return 'Unnamed device'
  if (/^(google\s+)?sdk_gphone/i.test(name)) return 'Android emulator'
  return name.replace(/_/g, ' ').replace(/\s+/g, ' ').trim()
}

/**
 * Device id → its kind, dropping anything unreadable.
 *
 * A row that cannot be read is left out rather than defaulted to `guest`, and
 * the difference matters on screen: a device that is absent from this map draws
 * the "paired before folder approval existed" line, which is the true thing to
 * say about a device the store has no record for. Defaulting would print
 * "Guest — only the folders you chose" over a device nobody has chosen for.
 *
 * Nothing here can produce `mine` from a value that is not the literal string,
 * which is the same rule the store's own parser follows for the same reason.
 */
export function toDeviceKinds(raw: unknown): Map<string, DeviceKind> {
  const kinds = new Map<string, DeviceKind>()
  if (!Array.isArray(raw)) return kinds
  for (const entry of raw) {
    const record = asRecord(entry)
    if (!record) continue
    const id = record.deviceId
    if (typeof id !== 'string' || id === '') continue
    if (record.kind !== 'mine' && record.kind !== 'guest') continue
    kinds.set(id, record.kind)
  }
  return kinds
}

export function toRemoteDevices(raw: unknown): RemoteDevice[] {
  return (Array.isArray(raw) ? raw : []).flatMap((entry): RemoteDevice[] => {
    const device = asRecord(entry)
    if (!device || typeof device.id !== 'string') return []
    const state = asString(device.status)
    return [
      {
        id: device.id,
        name: deviceLabel(asString(device.name, device.id)),
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
        deviceName: deviceLabel(
          asString(
            connection.deviceName,
            devices.find((device) => device.id === deviceId)?.name ?? 'Unnamed device',
          ),
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
    // `record.directReason` is in the answer and is deliberately dropped here.
    // It is the main process's account of why the *optional* direct route is
    // not up — "Tailscale is installed but this Mac is logged out of the
    // tailnet" — and there is no state of this panel in which showing it is
    // right. With the relay carrying the session it reports a fault in a working
    // feature; with the relay down it invites somebody who has never installed a
    // mesh VPN to go and install one instead of reading the relay's own sentence
    // two lines below. Narrowing it into `RemoteState` would leave a field on
    // this side that nothing may draw, which is how it would creep back.
    relay: toRemoteRelay(record.relay),
    devices,
    connections: toRemoteConnections(record.connections, devices),
  }
}

/**
 * Narrow a minted pairing code. Null without a token, which is the whole code.
 *
 * `findable` is read as three states rather than coerced to a boolean, and the
 * difference is the whole point of narrowing it here. `Boolean(undefined)` is
 * `false`, which would have a build whose main process never sends the field
 * printing "nothing can find this code" over a code that is perfectly findable;
 * `record.findable !== false` goes the other way and calls a dead code live.
 * Absent is its own answer and the panel says nothing it cannot support.
 */
export function toRemotePairing(raw: unknown): RemotePairing | null {
  const record = asRecord(raw)
  const token = asString(record?.token)
  if (token === '') return null
  return {
    token,
    expiresAt: asTime(record?.expiresAt),
    findable: typeof record?.findable === 'boolean' ? record.findable : null,
  }
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

/**
 * "just now", "5 minutes ago", "3 days ago", "12 Aug" — enough to tell a stale
 * device from a live one.
 *
 * The days step was added for the device list rather than for this function.
 * "paired 12 Aug" is a date a reader has to subtract today from before it means
 * anything, and the question being asked of that row is *how long has this thing
 * been able to get in* — which matters most for the pairing somebody left in a
 * browser on a computer they do not own. "paired 3 days ago" answers it without
 * arithmetic. Past a month the elapsed count stops being easier than the date
 * ("paired 74 days ago"), so the date comes back.
 */
export function whenSeen(at: number | null, now: number): string {
  if (at === null) return 'never'
  const minutes = Math.round((now - at) / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`
  const days = Math.round(hours / 24)
  if (days <= 30) return `${days} day${days === 1 ? '' : 's'} ago`
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

/**
 * When {@link whenSeen} would print something else, or null once it is a date.
 *
 * Three steps now rather than two, because the label counts days as well as
 * hours. A daily wake-up for a settings panel somebody left open is nothing —
 * and without it a window open across a weekend would keep saying "paired 1 day
 * ago" about a pairing that is three days old, on the one row whose whole job is
 * to tell you how long something has been able to get in.
 *
 * Null past the point the label becomes a fixed date, which is the only reason
 * this may ever stop: a returning null while the text still moves is a label
 * frozen with nothing to unfreeze it.
 */
function nextWhenSeenStep(at: number | null, now: number): number | null {
  if (at === null) return null
  const elapsed = now - at
  if (elapsed >= 31 * DAY) return null
  return nextRoundStep(at, now, elapsed >= DAY ? DAY : elapsed >= HOUR ? HOUR : MINUTE)
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
/* The code on screen                                                          */
/* -------------------------------------------------------------------------- */

/**
 * Whole seconds left on a code, floored at zero.
 *
 * Floored because a timer showing a negative number has outlived the thing it
 * was counting: the code is dead on the main process at that instant
 * (`PAIRING_TTL_MS` in `device-auth.ts`) and the screen is only catching up.
 * Rounded *up*, so a code with 59.4 seconds left says 60 rather than starting a
 * second short of the truth.
 *
 * Pure and exported so the countdown is checkable without a clock — and so that
 * one function answers it. The machines page had a second copy of this beside
 * a second countdown, which is exactly the kind of duplication the merge was
 * for.
 */
export function codeSecondsLeft(expiresAt: number, now: number): number {
  return Math.max(0, Math.ceil((expiresAt - now) / 1000))
}

/**
 * The code as a person should read it off the screen.
 *
 * `normaliseCode` is the canonical form — it is what the machine on the other
 * end will compare against — and it is idempotent, so putting the minted token
 * through it costs nothing and guarantees the digits on screen are the digits
 * that work.
 *
 * A token this module cannot recognise as a code is printed exactly as it
 * arrived. That is the honest answer to a main process older or newer than this
 * window: the code it minted is the code that will be accepted, and reformatting
 * something we do not understand would put a string on screen that nothing would
 * take.
 */
export function codeShown(token: string): string {
  return normaliseCode(token) ?? token
}

/**
 * Whether a code minted right now would reach anything.
 *
 * The relay carries every device that is not on this machine's own tailnet, and
 * the direct route carries the ones that are — so either is enough, and neither
 * is a code worth handing out. This used to be `pairingPaths(state).length > 0`
 * in a module that also built `terminaldeck://` links; the links are gone and
 * the question is not, so it is asked here in the two facts it was ever about.
 *
 * Null state — nothing read yet — is false. A button that mints before this
 * screen knows whether anything is listening is a code somebody photographs and
 * then cannot use.
 */
export function canMintCode(state: RemoteState | null): boolean {
  if (state === null || !state.running) return false
  return state.relay?.connected === true || state.url !== null
}

/**
 * Copy the code, and say so for a moment.
 *
 * The clipboard is not the point of a six-digit code — it is read aloud across a
 * desk far more often than it is pasted — but it is the whole point when the
 * other device is a phone in the same room as a Mac, where the system clipboard
 * is shared. It costs one button and it was on the machines page, so it stays.
 *
 * Its own component because "Copied" is about the *press*, not about the code:
 * it clears itself after a moment rather than waiting for the next thing to
 * happen. That is one piece of state and one timer, and putting either in
 * `RemoteView` would make the whole view stateful for a label.
 */
function CopyCode({ code, disabled }: { code: string; disabled: boolean }) {
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(timer)
  }, [copied])

  return (
    <Button
      disabled={disabled}
      onClick={() => {
        void navigator.clipboard
          ?.writeText(code)
          .then(() => setCopied(true))
          // Nothing is lost — the code is still on screen to be read, which is
          // what it was there for.
          .catch(() => setCopied(false))
      }}
    >
      {copied ? 'Copied' : 'Copy'}
    </Button>
  )
}

/* -------------------------------------------------------------------------- */
/* The view                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * An ⓘ that keeps its own open state, and the paragraph it opens.
 *
 * `Info` is deliberately controlled — a settings *row* owns whether its
 * disclosure is open, because only the row knows where the opened text belongs
 * relative to its own help line. Nothing on this panel is a settings row: the
 * four disclosures here hang off a path card, a prose line and two headings,
 * and each one wants the paragraph immediately after itself. So the state lives
 * with the button, in the one place where that is the right answer.
 */
function Note({ label, children }: { label: string; children: string }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <Info label={label} open={open} onToggle={() => setOpen((was) => !was)}>
        {children}
      </Info>
      {open && <MoreBody>{children}</MoreBody>}
    </>
  )
}

/** Which control is mid-call, so only that one goes busy. */
export type RemoteBusy = string | null

export interface RemoteActions {
  /**
   * Turn it on, or off, in one press either way.
   *
   * There was a second press. `enable(true)` armed a confirmation, and only
   * `confirmEnable()` started the server — the argument being that what is
   * behind the switch is a shell and the dangerous direction should be the slow
   * one. Asad took it out himself, twice over: *"don't give two step of this
   * like turn on. If I close, then if I open, then I need to click again, turn
   * it on. Only this one is good enough… and if I click on that, it turns on."*
   *
   * He is right that the confirmation was in the wrong place, and the reason is
   * that it was not the gate. **Turning this on lets nothing in.** A device
   * still has to be handed a code that lives sixty seconds, and then approved
   * by hand, on this screen, against a fingerprint it shows first. That is two
   * deliberate acts by the person sitting at the machine, and neither of them
   * can be reached by pressing the switch. The confirmation was a third press
   * guarding a door that opens onto another door.
   *
   * What the second press *said* has not been dropped, because that part was
   * doing work: the word `shell` and what a device may do is now the switch's
   * own help line, which is read before the press rather than after it.
   */
  enable(next: boolean): void
  /** Re-read the state, for the "Try again" beside a failed read. */
  reread(): void
  pair(): void
  closePairing(): void
  /**
   * Let a device in as `kind`, reaching `folders` and nothing else.
   *
   * The two extra arguments are not optional and there is no overload that omits
   * them. That is the whole shape of the fix: the old `approve(device)` admitted
   * a device and left the folder question to a block further down the page, and
   * an unanswered folder question defaulted to every project this desktop had
   * open. A signature that cannot be called without an answer is the only
   * version of this that cannot regress.
   *
   * `folders` is ignored by the main process for a `mine` device and is passed
   * as empty by the flow, rather than being made conditional here — a caller
   * assembling a different argument list per kind is a caller that can assemble
   * the wrong one.
   */
  approve(device: RemoteDevice, kind: DeviceKind, folders: string[]): void
  /** Open the step-by-step flow for one pending device. */
  beginApproval(device: RemoteDevice): void
  /** Close it without letting anything in. The device stays pending. */
  cancelApproval(): void
  /** Move the flow to a step, pick a kind, or add and remove a folder. */
  approvalStep(step: ApprovalStep): void
  approvalKind(kind: DeviceKind): void
  approvalAddFolder(): void
  approvalRemoveFolder(folder: string): void
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
  /**
   * Device id → what it is. **Null until the first read lands**, so a row can
   * stay quiet rather than claiming a device is a guest before anybody knows.
   */
  kinds?: Map<string, DeviceKind> | null
  /** The device whose approval flow is open, and where it has got to. */
  approving?: ApprovalState | null
  /**
   * The outward half: the machines this desktop can reach, and the field a code
   * from one of them is typed into.
   *
   * Required rather than optional. It is not an add-on to this screen, it is the
   * other half of it — and an optional prop is how a merged section quietly goes
   * back to being one panel with a gap where the other used to be.
   */
  machines: MachinesHalf
  /**
   * The per-device folder chooser, which reads its own grants and so cannot be
   * built here. Null before anything has been read — see where it is passed.
   */
  folders?: ReactNode
  /**
   * The per-device copilot grants, which read their own store and so cannot be
   * built here either.
   *
   * A second node rather than a field on the folder chooser, because they are
   * two different permissions over two different stores — losing a folder list
   * costs a preference, losing this costs a permission — and the main process
   * keeps them in two files for exactly that reason.
   */
  copilot?: ReactNode
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
  more,
  children,
}: {
  name: string
  tone: 'ok' | 'down' | 'off'
  pill: string
  /** One line. Anything longer belongs in `more`. */
  blurb: string
  /** The rest of the explanation, behind an ⓘ beside the row's name. */
  more?: string
  children?: ReactNode
}) {
  const [openMore, setOpenMore] = useState(false)
  return (
    <li className="remote-path" data-state={tone}>
      <div className="remote-path-head">
        <span className="settings-label-line">
          <span className="remote-path-name">{name}</span>
          {more && (
            <Info label={name} open={openMore} onToggle={() => setOpenMore((was) => !was)}>
              {more}
            </Info>
          )}
        </span>
        <span className="remote-pill" data-state={tone}>
          {pill}
        </span>
      </div>
      <p className="remote-path-blurb">{blurb}</p>
      {/* Under the blurb rather than beside the ⓘ: a disclosure has to appear
          below everything it is adding to, and here that is the one-line blurb
          the paragraph is expanding. */}
      {more && openMore && <MoreBody>{more}</MoreBody>}
      {children}
    </li>
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
  kinds = null,
  approving = null,
  machines,
  folders = null,
  copilot = null,
  actions,
  now,
  platform = detectPlatform(),
}: RemoteViewProps) {
  const ids = useId()
  // "this Mac" on a Mac, "this PC" on Windows. Every sentence on this screen is
  // about the machine the reader is sitting at, so the noun has to be the one
  // they would use for it.
  const machine = thisMachine(platform)

  /*
   * There is no heading here, and that is the fix rather than an omission.
   *
   * This section was a Settings pane before it became a page in the rail, and
   * it brought its own `SectionHead` with it. The window toolbar already prints
   * the page's name and `panels.ts` already prints a line under it, so the
   * screen opened with **Remote** twice, forty pixels apart, under two
   * different one-line descriptions of the same feature. Two subtitles is worse
   * than two titles: a reader has to work out whether they are describing the
   * same thing.
   *
   * The toolbar's copy wins because it is the one that is there on every page
   * and cannot be missed. Nothing is lost — what this head used to say about
   * driving the machine from a phone is now the switch's own help line, which
   * is where somebody deciding whether to press it is already looking.
   */

  if (!wired) {
    return (
      <>
        <Notice tone="warn">
          Remote access is not wired into this build. Nothing is listening, and nothing on this
          screen would turn anything on.
        </Notice>
        {/*
          Still drawn, because it is a different feature of the main process.
          `registerRemoteIpc` is what lets a device *in*; `registerMachinesIpc`
          is what dials *out*, and a build missing the first can perfectly well
          have the second. Hiding the machines here would take a working half of
          the section away on the strength of the other half being absent.
        */}
        <MachineLinks half={machines} platform={platform} />
      </>
    )
  }

  const running = state?.running === true
  const expired = secondsLeft !== null && secondsLeft <= 0
  const pending = state?.devices.filter((device) => device.state === 'pending') ?? []
  const devices = state?.devices ?? []
  // What `grantableDevices` will hand the folder picker. Computed here as well
  // so the block is withheld rather than drawn empty — see the note above it.
  const approved = devices.filter((device) => device.state === 'approved')
  const connections = state?.connections ?? []

  const relay = state?.relay ?? null
  const relayLive = relay?.connected === true
  const direct = state?.url ?? null

  // Whether a code minted this second would reach anything, derived rather than
  // remembered: a path that goes away while a code is on screen has to stop
  // being offered, not stay drawn until something re-renders.
  const canPair = canMintCode(state)
  /*
   * Whether the code on screen can be looked up, and what to say when it cannot.
   *
   * Two different facts feed one sentence, and they are different on purpose.
   * `pairing.findable` is what the main process learned while it was claiming
   * the rendezvous slot for *this* code — the only thing that knows whether the
   * claim landed. `relayLive` is what the status read a moment ago says about
   * the relay, which is fresher but coarser: it can go down after a code was
   * published, and then a code that was findable when it was minted is not any
   * more. Either is enough to stop calling a code generally usable.
   *
   * A code that cannot be looked up is not automatically dead. On a machine with
   * a direct address a device already on that tailnet can still reach it and
   * redeem the code there, so that case keeps the digits and narrows the claim.
   * With no direct route there is nothing left to point them at, and the digits
   * come off the screen — six digits nothing can use are worse than no digits,
   * because somebody types them and waits.
   */
  const lookupDown = pairing?.findable === false || !relayLive
  const tailnetOnly = lookupDown && direct !== null
  const reachesNothing = pairing?.findable === false && direct === null

  return (
    <>
      <Group>
        <div className="settings-item">
          <Row
            label="Let approved devices in"
            // One line, and it is the line somebody deciding whether to press
            // the switch needs: what it is for, and the word `shell`.
            //
            // It used to read "Off by default", which was true and is not any
            // more: this machine dials out on launch so a paired phone has
            // something to attach to without anyone opening this panel first.
            // Leaving the old sentence there would have the switch describing
            // the opposite of its own position.
            help={`Drive ${machine} from a phone or another computer, from any network — a device you approve gets a shell here. Nothing to install and no account.`}
            /*
              The paragraph that used to run under this row, moved behind the ⓘ.
              Nothing was cut: this is every clause of it.

              It was six lines of grey type across the full width of the column,
              first of five such paragraphs on one screen, and Asad's note is
              about the screen rather than about any one of them: *"we don't
              need to give this big descriptions… let's give only one liner or
              two liner descriptions and one eye buttons next to them so they
              can click or hover over there and they can read the full
              description."* The one word that decides whether to press the
              switch — `shell` — is in the line above, where it is read.
            */
            /*
              Rewritten because it had stopped being true, which is the failure
              mode `neutral-naming.test.ts` writes a page about: a string that is
              merely *untrue* type-checks perfectly.

              It said every approved device can type into any session running
              here. That was exactly right when approving was one button and a
              device with no folder record got whatever the desktop had open. It
              is now the description of one of the two kinds and a lie about the
              other, and it is read by somebody deciding whether to hand a phone
              to a colleague.
            */
            more={`Letting a device in asks you two things: whose it is, and what it may open. One of your own gets everything — every folder, every session, the copilot. A guest gets the folders you choose and nothing else: not your other projects, not the sessions running in them, and never the copilot. Nothing is published to the internet either way — everything is sealed end to end, so the relay that carries it routes bytes it holds no key for. That seal lets nothing in on its own; a code you mint here and an approval you give here do.`}
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

        {state === null && problem === null && (
          // Said once, and it now genuinely resolves — into a state, or into
          // the error below. The read is raced against a deadline in
          // `refresh`, because this line stood on screen for the length of a
          // recording with nothing behind it and nothing to press. See
          // `withDeadline`.
          <p className="settings-prose">Reading the current state…</p>
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
            {problem} Anything below was read before that and may be out of date.{' '}
            {/* A failure with nothing to press is the loading line again, one
                sentence longer. Every terminal state on this screen has a way
                out of it. */}
            <Button onClick={actions.reread} disabled={busy !== null}>
              Try again
            </Button>
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
        /*
         * How a device gets here — one row, because there is one way in.
         *
         * There were two, and the second one was the tailnet. It has now been
         * taken off this screen four separate times and come back, so the
         * reason is written down here rather than left to the next person to
         * rediscover: *"then direct your tail scale thing is again here back,
         * which I discussed before with you… if it is something that we were
         * people knows only, then it is just like jargon for them."*
         *
         * It is jargon for almost everybody, and worse than jargon: on his
         * machine it drew a card with a green **Ready** badge, which reads as
         * the recommended route. It is not the route. The relay is the network
         * — it is what carries every session and what a pairing code is looked
         * up through — and the direct hop is an optimisation for the handful of
         * people already running a mesh VPN, who need no card to tell them they
         * have one. Nothing is lost by removing it: when a direct address
         * exists the server still prefers it, silently, which is what an
         * optimisation should do.
         *
         * `state.url` and `state.address` are still in the state and still
         * unread here. That is deliberate, and it is the same rule the header
         * states about `directReason`: this panel does not report on a path the
         * reader did not ask about.
         */
        <Group title="How a device gets here">
          <ul className="remote-paths">
            <PathRow
              name="Through the relay"
              tone={relay === null ? 'off' : relayLive ? 'ok' : 'down'}
              pill={relay === null ? 'Off' : relayLive ? 'Connected' : 'Not connected'}
              // One line. The three clauses that used to follow it — what a
              // rendezvous is, that it cannot read what it carries, that a
              // pairing code is looked up through it — are true, and they are
              // behind the ⓘ, which is where a standing explanation belongs.
              // "this Mac" is a mid-sentence noun, so the sentence has to be
              // built around it rather than started with it — `thisMachine`
              // returns a lowercase phrase and a capitalised copy of it would
              // be a second string to keep in step with the platform.
              blurb={`Reachable from any network: ${machine} dials out to it, so nothing has to be installed on the device.`}
              more={`A rendezvous service. It staples two sockets together and carries sealed bytes it cannot read, so nothing on the way can see the session. It is also what a pairing code is looked up through: the code names a slot at the relay, and whatever types it finds ${machine} there.`}
            >
              {relay === null ? (
                <p className="remote-path-note">
                  {/* `relaying` is only false here when no relay was built at
                      all, which `relayEnabled` decides from the environment or
                      from how the app was assembled. Naming both is honest;
                      naming one would be a guess.

                      A build with no relay and no direct address never reaches
                      this row: `createRemoteServer` fails the start outright, so
                      the panel is showing "Not serving" instead. That is what
                      lets the sentence below point at the row underneath and be
                      sure it is there. */}
                  This build is not dialling a relay — either TERMINALDECK_RELAY is off, or it was
                  assembled without one.
                </p>
              ) : relayLive ? (
                /*
                 * No host id and no fingerprint on the resting card.
                 *
                 * The fingerprint was printed twice on one screen — once here,
                 * permanently, and once beside a live pairing code where it is
                 * the check a person actually makes against the device in their
                 * other hand. Two copies of a 24-character string make neither
                 * of them mean anything, and *this* copy is the one with no job:
                 * there is nothing to compare it to until a device is pairing.
                 * It stays where the comparison happens. The host id went with
                 * it — it is this machine's name at the rendezvous, and nothing
                 * a person can do anything with. Both remain in the state, and
                 * the pairing block below still shows the fingerprint.
                 */
                <p className="remote-path-note">
                  {relay.channels > 0
                    ? `Carrying ${relay.channels} connection${relay.channels === 1 ? '' : 's'} right now.`
                    : 'Nothing is coming through it right now.'}
                </p>
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
          {/*
            Both halves of pairing, side by side, in the order somebody does
            them — and that arrangement is inherited from the machines page
            rather than invented here. Pairing has two ends and the person doing
            it is standing at both: one screen shows a code, the other is typed
            into. Splitting them across two screens means explaining which screen
            to open on which machine before anything can happen, inside a code
            that lasts a minute.
          */}
          {/* One line, with the rest behind the eye. Three paragraphs stood
              between the heading and the button that mints the code. */}
          <p className="settings-prose">
            <span className="settings-label-line">
              A code is good for one device and lasts {PAIRING_WINDOW_SECONDS} seconds.
              <Note label="pairing codes">
                {`Typing the code asks to be let in; it lets nothing in on its own — you still approve the device below, by hand, on this screen. Pairing has two ends and you are standing at both: one screen shows a code and the other is typed into, which is why both halves are here rather than on two screens.`}
              </Note>
            </span>
          </p>

          <div className="remote-pair">
            <div className="remote-pair-half">
              <h5 className="remote-pair-title">Let a device in</h5>
              <p className="settings-prose">
                Show a code here, then type it into the phone or computer you are adding.
              </p>

              {!pairing && (
                <>
                  <Button tone="primary" onClick={actions.pair} disabled={busy !== null || !canPair}>
                    {busy === 'pair' ? 'Asking…' : 'Show a code'}
                  </Button>
                  {!canPair && (
                    // The button is dead on purpose, and a dead button with no
                    // sentence beside it is the panel refusing to say why.
                    //
                    // It no longer says "neither way in is up". On a machine with
                    // no direct route there is only ever one row above this, and
                    // "neither" told the reader to go looking for a second one
                    // that was never drawn.
                    <Notice tone="warn">
                      Nothing above is up, so a code would reach nothing. The rows above say what is
                      wrong; fix that and this will mint.
                    </Notice>
                  )}
                </>
              )}

              {pairing && !canPair && (
                // Reachable: the tailnet can go away and the relay can drop
                // while a code is on screen. Saying "expired" here would be the
                // wrong reason, and the right one tells you what to do.
                <Notice tone="warn">
                  There is nowhere to point this code any more — every way in went away while it was
                  on screen. Cancel it and show another once one of them is back.
                </Notice>
              )}

              {pairing && canPair && expired && (
                // His words, from the screenshot, kept exactly: it says what
                // happened and what to do about it in one line. The button under
                // it is the "another one", and it mints — see `actions.pair`.
                <Notice tone="warn">That code has expired. Show another one.</Notice>
              )}

              {pairing && canPair && !expired && reachesNothing && (
                /*
                 * The code was minted and its slot was not claimed, on a machine
                 * with no direct route — so there is no client anywhere that
                 * could use these six digits.
                 *
                 * The digits are withheld rather than dimmed, and that is the
                 * whole correction. This state used to be drawn exactly like
                 * success: the code, the countdown, a Copy button. Somebody
                 * reads them onto a phone, the phone derives the slot, finds
                 * nobody in it, and says "no machine is showing that code" —
                 * which is true, unhelpful, and arrives on the one device that
                 * cannot know why. Nothing on this screen is allowed to invite
                 * that.
                 *
                 * It is deliberately not a claim about the relay's health. The
                 * relay row above says whatever the link is doing; what failed
                 * here is this code's own dial, which can fail with the link up.
                 */
                <Notice tone="warn">
                  This machine could not take its place at the rendezvous, so nothing can look this
                  code up — and there is no direct route here to fall back on. The digits are not
                  shown, because nothing could use them. Try again below.
                </Notice>
              )}

              {pairing && canPair && !expired && !reachesNothing && (
                <>
                  {/*
                    The code itself, and the largest thing in the section.

                    It is read off this screen by somebody looking at it from a
                    step back and typed into a device held in the other hand, so
                    it is set the way a terminal sets things: mono, tracked out,
                    tabular. `aria-label` because a screen reader saying the six
                    digits as one number — "four hundred and eighty-two thousand"
                    — is not a code anybody can type.
                  */}
                  <p className="remote-code" aria-label="Pairing code">
                    {codeShown(pairing.token)}
                  </p>

                  {tailnetOnly && (
                    /*
                     * True and narrow: nothing can look this code up, but a
                     * device already on the tailnet can still reach the direct
                     * address and redeem it there.
                     *
                     * The address is printed *here* and nowhere else, and that
                     * is the whole of what is left of the tailnet on this
                     * screen. It used to be a permanent card with a green
                     * **Ready** badge, which advertised a route almost nobody
                     * has as the recommended one. This is the single state
                     * where it is the only way in and therefore the only thing
                     * the reader can act on — so it appears exactly then, in a
                     * warning, rather than standing on the page being jargon.
                     *
                     * It no longer names the relay as the cause. Two different
                     * things land here — the relay being down, and this code's
                     * own rendezvous dial failing under a relay that is up —
                     * and the old sentence asserted the first, which sent
                     * somebody to stare at a row that said Connected.
                     */
                    <Notice tone="warn">
                      Nothing can look this code up, so only a device already on your tailnet can use
                      it{direct === null ? '' : ` — at ${direct}`}.
                    </Notice>
                  )}
                </>
              )}

              {pairing && (
                <>
                  {/*
                    No countdown on a code nothing can use.

                    A timer is a promise that something will happen before it
                    runs out. On the unfindable-and-no-direct-route state there
                    is nothing to wait for, and a minute of ticking beside a
                    withheld code reads as "keep waiting" — which is the one
                    thing that will not help.
                  */}
                  {reachesNothing ? null : secondsLeft !== null ? (
                    <p
                      className={
                        expired ? 'remote-countdown remote-countdown-done' : 'remote-countdown'
                      }
                      // A screen reader announcing every second of a minute is
                      // worse than the silence it replaces.
                      aria-live="off"
                    >
                      {expired ? 'Expired' : `Expires in ${secondsLeft}s`}
                    </p>
                  ) : (
                    <p className="remote-countdown remote-countdown-done">
                      The main process did not say when this expires.
                    </p>
                  )}

                  {relay !== null && relay.fingerprint !== '' && !expired && canPair && !reachesNothing && (
                    // The one check a person can actually make. The device shows
                    // these same six groups before it sends anything, because it
                    // learned the key from the offer this code names — so a
                    // mismatch means something else answered to the code.
                    <div className="remote-check">
                      <span className="remote-check-label">{`This ${machineNoun(platform)}’s fingerprint`}</span>
                      <code className="remote-fingerprint">{relay.fingerprint}</code>
                      <span className="remote-check-note">
                        The device shows the same six groups before it connects. If they do not
                        match, something else answered to {machine}’s name — cancel, do not approve.
                      </span>
                    </div>
                  )}

                  <div className="settings-chips">
                    {expired || reachesNothing ? (
                      // Enabled on the same condition the first press was, and
                      // that is the fix for the dead end he hit: an expired code
                      // beside a button that could not mint another one is a
                      // screen telling you to do something it will not let you
                      // do. When nothing can mint, the notice above says so
                      // instead.
                      //
                      // A code nothing can look up gets the same treatment for
                      // the same reason, and the *other* half of that matters
                      // more: there is no Copy button in this state. Copying six
                      // digits that reach nothing is the panel handing somebody
                      // the failure to carry to another device.
                      <Button
                        tone="primary"
                        onClick={actions.pair}
                        disabled={busy !== null || !canPair}
                      >
                        {busy === 'pair' ? 'Asking…' : expired ? 'Show another one' : 'Try again'}
                      </Button>
                    ) : (
                      <CopyCode code={codeShown(pairing.token)} disabled={busy !== null} />
                    )}
                    {/* "Done" read as "the pairing is finished", which is the one
                        thing it does not mean: it takes the code off screen and
                        cancels it. */}
                    <Button onClick={actions.closePairing} disabled={busy !== null}>
                      {expired || reachesNothing ? 'Done' : 'Hide the code'}
                    </Button>
                  </div>
                </>
              )}
            </div>

            <div className="remote-pair-half">
              <h5 className="remote-pair-title">Add another computer</h5>
              <p className="settings-prose">
                Type the {CODE_LENGTH} digits the other machine is showing. You will then approve
                this one over there, once.
              </p>
              <CodeEntry
                state={machines.entry}
                wired={machines.wired}
                onDigits={machines.actions.type}
                onSubmit={machines.actions.pair}
              />
            </div>
          </div>
        </Group>
      )}

      {/*
        Only when something is attached.

        An empty "Attached now — Nothing is attached." group is a heading and a
        sentence saying the heading has nothing under it, on a page whose whole
        complaint was that it says too much before anything has happened. The
        list appears when there is a list.
      */}
      {running && connections.length > 0 && (
        <Group title={`Attached now — ${connections.length}`}>
          {(
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
            // worth knowing is that Stop is cheap — a person who has to guess
            // whether "Stop" kills their session will leave a page open on this
            // Mac rather than risk it — and that fits on one line.
            <p className="settings-prose">
              <span className="settings-label-line">
                <strong>Stop closes the page, and nothing else.</strong>
                <Note label="open ports">
                  {`A port listed above is being served from ${machine} to that phone’s browser, over the same connection. Stopping it leaves the session running and the device approved, and the phone can tap the port again.`}
                </Note>
              </span>
            </p>
          )}
        </Group>
      )}

      {/*
        Only once there is a device.

        Two gates, and they answer two different objections. The first is the
        old one: before the first answer lands, "no device has been paired" is a
        claim nothing supports. The second is his — *"until there is nothing
        activated or something or no device is connected… this only text doesn't
        make any sense"* — and it is about a page that opened with four headings
        and five paragraphs describing devices that did not exist. An empty
        roster under a heading is not information; the way to get one is the
        pairing block above, which is where somebody with no devices should be
        looking.
      */}
      {state !== null && devices.length > 0 && (
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

          {/*
            The flow, above the roster and not in a dialog.

            A modal would cover the list somebody is comparing against, and the
            list is where the *other* pending device is — which is exactly the
            moment they need to see both. It sits directly under the sentence
            that says a device is waiting, so the words and the choice they are
            about arrive together.
          */}
          {approving !== null && (
            <DeviceApproval
              device={approving.device}
              platform={platform}
              folders={approving.folders}
              step={approving.step}
              kind={approving.kind}
              busy={busy !== null}
              problem={problem}
              onStep={actions.approvalStep}
              onKind={actions.approvalKind}
              onAddFolder={actions.approvalAddFolder}
              onRemoveFolder={actions.approvalRemoveFolder}
              onApprove={() =>
                actions.approve(approving.device, approving.kind ?? 'guest', approving.folders)
              }
              onCancel={actions.cancelApproval}
            />
          )}

          {(
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
                    {/*
                      What this device is, stated on the row and not editable
                      there.

                      Three states and not two: `mine`, `guest`, and a device
                      approved by a build older than the choice — which is read
                      as a guest with no folders, and deserves a sentence saying
                      why a phone that worked yesterday does not today. There is
                      deliberately no control here; changing a kind means
                      revoking and pairing again. See `device-kind.ts`.
                    */}
                    {device.state === 'approved' && kinds !== null && (
                      <span className="remote-row-note">
                        {kinds.get(device.id) === 'mine' ? (
                          <>Your device — full access.</>
                        ) : kinds.get(device.id) === 'guest' ? (
                          <>Guest — only the folders you chose. No copilot.</>
                        ) : (
                          <>
                            Paired before folder approval existed, so it is treated as a guest and
                            can open nothing. Revoke it and pair it again to choose.
                          </>
                        )}
                      </span>
                    )}
                    {device.state !== 'revoked' &&
                      (device.fingerprint === null ? (
                        // Not a cosmetic gap. No key means no sealed channel,
                        // so this device cannot come in through the relay at
                        // all — said here rather than discovered the first time
                        // it is tried from a hotel.
                        <span className="remote-row-note">
                          No key stored — this one paired before there were keys, so it cannot come
                          in through the relay. Pair it again to fix that.
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
                        {/*
                          "Let it in…" rather than "Approve", and the ellipsis is
                          doing work: this opens the flow that asks whose device
                          it is and what it may open, and the old one-word button
                          is exactly what made people believe the decision had
                          been made when it had not.
                        */}
                        <Button
                          tone="primary"
                          onClick={() => actions.beginApproval(device)}
                          disabled={busy !== null || approving?.device.id === device.id}
                        >
                          Let it in…
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
            <span className="settings-label-line">
              <strong>Revoking is immediate.</strong>
              <Note label="revoking">
                {`The device is dropped where it stands — mid command, mid session — not at its next connection. Disconnecting is the gentler one: it only closes what is open now, and an approved device can attach again straight away.`}
              </Note>
            </span>
          </p>
        </Group>
      )}

      {/*
        Folders, only once there is a device to choose them for.

        It rendered on every visit, three paragraphs of it, ending in "No device
        has been approved yet, so there is nothing to choose for." — an
        explanation of a decision the reader cannot make yet, on a page they
        opened to pair their first phone. `grantableDevices` already filters to
        approved devices; the caller now withholds the whole block on the same
        condition, so the words arrive with the choice they are about.
      */}
      {approved.length > 0 && folders}

      {/*
        Directly under the folders, on the same card, and withheld on the same
        condition.

        Both answer *what may this device do here*, and somebody deciding about a
        phone should see both answers at once rather than finding the second one
        under a different heading a month later. The order is the argument the
        screen makes, continued: pair a device, approve it, choose what it may
        open — and then, separately and off by default, whether it may reach the
        copilot at all.
      */}
      {approved.length > 0 && copilot}

      {/*
        The outward half, last — and only when there is one.

        The order is the argument the section makes, and it runs one way:
        this machine, then what may reach it, then how to pair another, then
        what it can reach. Everything above this line is about something
        arriving here and is governed by the switch at the top; the machines
        below are dialled out to and keep working with that switch off, which
        is exactly why they come after rather than being mixed into the device
        roster.

        With no machine paired this was a heading, two lines of prose about
        pairing going both ways, and a sentence saying the list was empty —
        three more paragraphs on a page that already had too many, describing a
        capability whose entry point ("Add another computer") is in the pairing
        block above. It is drawn once there is a machine to draw, while the read
        that would find one is still running or has failed, and — always — when
        the build cannot reach the machine channels at all, because that is a
        broken build rather than an empty list and has to be said.
      */}
      {(!machines.wired ||
        machines.reading ||
        machines.error != null ||
        machines.view.machines.length > 0) && (
        <MachineLinks half={machines} platform={platform} />
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
 * How long a read on this panel may take before it stops waiting and says so.
 *
 * Two lines here — *"Reading the current state…"* and *"Reading the machines
 * this desktop knows…"* — stood on screen for the whole of a 47-minute
 * recording. Both were written as though they resolve, and both do resolve if
 * the main process answers; neither had anything to say if it did not. See
 * `renderer/deadline.ts` for why an `invoke` that never settles never rejects
 * either, which is what makes a spinner with no timer behind it permanent.
 *
 * Shorter than the shared default, on purpose. That default has to cover the
 * artifact scan, which walks every transcript in a project. The two reads here
 * are a status object and a device list, both already in memory in the main
 * process; the one slow thing either of them touches is a mesh-VPN CLI, which
 * `tailnet.ts` caps at five seconds. Eight sits above that cap, so a slow probe
 * still lands and a probe that never returns hits the deadline.
 */
export const READ_DEADLINE_MS = 8000

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
  /** Re-read `remote:status` and `remote:devices` now. */
  reread(): void
  /** Runs the work, reports it in the main process's words, then re-reads. */
  run(key: string, work: () => Promise<unknown>, done: string | null): void
  /** The approval flow on screen, and the one thing that moves it. */
  approving: ApprovalState | null
  setApproving(next: ApprovalState | null): void
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
 * dangerous ones are pinned: that Deny revokes rather than approves, that the
 * switch believes the status it reads back rather than the call returning, and
 * that a call that never happened is never reported as one that did.
 */
export function remoteActions(deps: RemoteActionDeps): RemoteActions {
  const { bridge, pairing, setPairing, run, isAlive, approving, setApproving } = deps

  /**
   * Edit the flow that is open, and do nothing when none is.
   *
   * Every step action goes through here rather than reading `approving` itself,
   * because the null case is the same in all five and writing it five times is
   * how the fifth one ends up creating a flow out of nothing — a folder picker
   * opening for a device nobody is approving.
   */
  const edit = (change: (state: ApprovalState) => ApprovalState): void => {
    if (approving === null) return
    setApproving(change(approving))
  }

  /** Approve/Deny/Revoke: do it, then believe the list that comes back, not the ask. */
  const settle = (
    key: string,
    method: ((id: string) => Promise<unknown>) | undefined,
    channel: string,
    device: RemoteDevice,
    want: RemoteDeviceState,
    done: string,
    /**
     * Run only when the roster came back saying the change took.
     *
     * The one caller is the approval flow closing itself. Closing it on the
     * press would hide the failure the throw below is about to report, and leave
     * somebody looking at a device that is still waiting with no flow to finish.
     */
    settled?: () => void,
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
        settled?.()
      },
      done,
    )

  return {
    /**
     * One press, each way. See {@link RemoteActions.enable} for why the
     * confirmation that used to sit in front of the on direction is gone, and
     * what still stands between this switch and a device having a shell here.
     */
    enable: (next) => {
      if (next) {
        void run(
          'toggle',
          async () => {
            const answer = toRemoteState(await invoke(bridge.startRemote, 'start'), [])
            // `remote:start` resolves with a status rather than throwing, so a
            // start that did not take arrives here looking like a success. Its
            // own sentence is the failure message; inventing one would bury it.
            if (answer && !answer.running) {
              throw new Error(answer.reason ?? 'It did not start, and did not say why.')
            }
          },
          'Remote access is on. Nothing can connect until you pair and approve a device.',
        )
        return
      }
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
    reread: () => deps.reread(),
    /**
     * Mint the one code, and put it on screen.
     *
     * The same function behind "Show a code" and behind "Show another one" on
     * an expired one, deliberately: an expired code is a code that is gone, and
     * asking for another is asking for a first. Anything that remembered the old
     * one — a retry that re-showed it, a guard that refused while `pairing` was
     * set — is how that button came to dead-end.
     *
     * `setPairing` before anything else clears whatever was on screen, so a mint
     * that fails leaves no stale code behind claiming to work; the failure
     * arrives as a notice from `run`.
     */
    pair: () =>
      void run(
        'pair',
        async () => {
          setPairing(null)
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
    beginApproval: (device) =>
      setApproving({ device, step: 'check', kind: null, folders: [] }),
    // The device stays pending. Cancelling is *not* denying — the person may
    // have walked away to read the fingerprint off the phone — and a cancel that
    // quietly revoked would be unrecoverable, because a revoked device can never
    // be approved later.
    cancelApproval: () => setApproving(null),
    approvalStep: (step) => edit((state) => ({ ...state, step })),
    approvalKind: (kind) =>
      edit((state) => ({
        ...state,
        kind,
        // Answering the question moves on. A card that leaves you looking at the
        // same screen wondering whether it registered is what this flow exists
        // not to be, and Back is right there.
        step: nextStep('kind', kind),
        // Folders chosen for a guest are dropped on switching to `mine`: they
        // would be a list nothing reads, and one that reappeared on switching
        // back would be the screen remembering a choice that was withdrawn.
        folders: kind === 'mine' ? [] : state.folders,
      })),
    approvalAddFolder: () =>
      void run(
        'approval:folder',
        async () => {
          // The app's own native chooser, the one Open Project uses. A text
          // field would let somebody type a path that does not exist, and the
          // first they would hear of it is a refusal on a phone in another room.
          const picked = await invoke(bridge.pickProjectFolder, 'choose a folder')
          if (typeof picked !== 'string' || picked === '') return
          if (!isAlive()) return
          // Read through `deps` rather than the destructured `approving`: the
          // picker is a native dialog and the person may have pressed Back while
          // it was open, so the state this lands in is not the one it left.
          const open = deps.approving
          if (open === null || open.folders.includes(picked)) return
          setApproving({ ...open, folders: [...open.folders, picked] })
        },
        null,
      ),
    approvalRemoveFolder: (folder) =>
      edit((state) => ({ ...state, folders: state.folders.filter((one) => one !== folder) })),
    approve: (device, kind, folders) =>
      settle(
        `device:${device.id}`,
        // Bound here rather than widening `settle`, which every other action on
        // this panel calls with a bare id. One action needs three arguments; the
        // helper that reads the roster back afterwards needs none of them.
        bridge.approveRemoteDevice === undefined
          ? undefined
          : (id: string) => bridge.approveRemoteDevice!(id, kind, folders),
        'approve device',
        device,
        'approved',
        kind === 'mine'
          ? `${device.name} has full access.`
          : folders.length === 0
            ? `${device.name} is in, and can open nothing until you choose a folder for it.`
            : `${device.name} can open ${folders.length === 1 ? 'one folder' : `${folders.length} folders`}.`,
        () => setApproving(null),
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
  /**
   * The machine channels, likewise.
   *
   * A second bridge rather than one widened interface, because they are two
   * features of the main process — `registerRemoteIpc` is the host and
   * `registerMachinesIpc` is the guest — and either can be absent from a build
   * without the other. `contract.test.ts` reads both interfaces by name; merging
   * them would hide which half a missing channel belongs to.
   */
  machines?: MachinesBridge
}

export function RemoteSection({ bridge: provided, machines: providedMachines }: Props) {
  // Resolved once. `resolveRemoteBridge` builds a new object every call, and an
  // unstable bridge would restart the poll — and the unmount cleanup that kills
  // a live pairing code — on every render.
  const bridge = useMemo(() => provided ?? resolveRemoteBridge(), [provided])
  const wired = typeof bridge.remoteStatus === 'function'
  const missing = useMemo(() => (wired ? missingRemoteMethods(bridge) : []), [bridge, wired])
  const machineBridge = useMemo(
    () => resolveBridge(providedMachines) ?? null,
    [providedMachines],
  )

  const [state, setState] = useState<RemoteState | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null)
  const [pairing, setPairing] = useState<RemotePairing | null>(null)
  const [busy, setBusy] = useState<RemoteBusy>(null)
  const [now, setNow] = useState(() => Date.now())
  /** The approval flow on screen, or null. One at a time — see `ApprovalState`. */
  const [approving, setApproving] = useState<ApprovalState | null>(null)
  /**
   * Device id → what it is, or null before the first read.
   *
   * Read alongside the roster rather than folded into it, because it comes from
   * a different file in the main process with a different failure direction: a
   * roster that cannot be read means the panel says so, and a kind that cannot
   * be read means every device is a guest, which is the safe answer and not one
   * to draw as a fact.
   */
  const [kinds, setKinds] = useState<Map<string, DeviceKind> | null>(null)

  /* ------------------------------------------------- the machines half -- */

  const [machineView, setMachineView] = useState<MachinesView>({
    machines: [],
    links: [],
    blocked: null,
  })
  const [machinesReading, setMachinesReading] = useState(machineBridge !== null)
  /** Why the machines read failed, in a sentence. Null while it has not. */
  const [machinesProblem, setMachinesProblem] = useState<string | null>(null)
  const [typed, setTyped] = useState('')
  const [pairingMachine, setPairingMachine] = useState(false)
  const [pairError, setPairError] = useState<string | null>(null)
  const [openSession, setOpenSession] = useState<{
    machineId: string
    sessionId: string
  } | null>(null)

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
      // never from two different moments — and under a deadline, so the pair of
      // them cannot leave "Reading the current state…" on screen for ever. See
      // `withDeadline`.
      const [status, devices, deviceKinds] = await withDeadline(
        Promise.all([
          bridge.remoteStatus(),
          bridge.listRemoteDevices?.() ?? Promise.resolve([]),
          // In the same read, so a row never shows a device as approved while
          // the line under it is still guessing what kind it is. A build whose
          // preload predates the channel resolves to an empty list, which reads
          // as "nobody has decided" — the same answer the store gives, and the
          // safe one.
          bridge.listRemoteDeviceKinds?.() ?? Promise.resolve([]),
        ]),
        'The remote access state',
        READ_DEADLINE_MS,
      )
      if (!alive.current || seq !== readSeq.current) return
      setKinds(toDeviceKinds(deviceKinds))
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

  /**
   * The machines this desktop can reach, read once and then pushed.
   *
   * `machines:state` is announced whenever a *link* changes — a machine coming
   * up, going away, being paired — so there is no poll here either.
   */
  const rereadMachines = useCallback(async (): Promise<void> => {
    if (machineBridge === null) return
    try {
      // Under the same deadline as the status read, and for the same reason:
      // "Reading the machines this desktop knows…" was the other line that
      // never resolved. A failure here is a sentence in the machines block, not
      // an empty list — "no other machine yet" is a claim, and a read that did
      // not come back is no evidence for it.
      const view = asView(
        await withDeadline(
          machineBridge.listMachines(),
          'The machines this desktop knows',
          READ_DEADLINE_MS,
        ),
      )
      if (!alive.current) return
      setMachineView(view)
      setMachinesProblem(null)
    } catch (error) {
      if (alive.current) {
        setMachinesProblem(errorText(error, 'Could not read the machines this desktop knows.'))
      }
    }
  }, [machineBridge])

  useEffect(() => {
    if (machineBridge === null) {
      setMachinesReading(false)
      return
    }
    setMachinesReading(true)
    void rereadMachines().finally(() => {
      if (alive.current) setMachinesReading(false)
    })
    return machineBridge.onMachinesState((value) => {
      if (alive.current) {
        setMachineView(asView(value))
        // A push is a working channel, so whatever the last read failed at is
        // no longer the state of the world.
        setMachinesProblem(null)
      }
    })
  }, [machineBridge, rereadMachines])

  // Coming back to the window is the moment a stale answer starts to matter,
  // and it is also the moment the things nothing pushes are most likely to have
  // changed — a laptop that closed its lid in one place and opened it in
  // another has a different tailnet than the one this panel last read.
  //
  // Both halves, for the same reason and one of them for a second: `blocked` is
  // not a link, it is this desktop's own relay, and nothing announces that
  // connecting or dropping. Without this it was decided once, when the section
  // was opened, and then stood there being wrong in whichever direction the
  // relay moved next.
  useWhenActive(() => {
    if (wired) void refresh()
    void rereadMachines()
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

  const secondsLeft = pairing?.expiresAt == null ? null : codeSecondsLeft(pairing.expiresAt, now)

  const actions = remoteActions({
    bridge,
    pairing,
    setPairing,
    reread: () => void refresh(),
    run: (key, work, done) => void run(key, work, done),
    isAlive: () => alive.current,
    approving,
    setApproving,
  })

  const machinesHalf: MachinesHalf = {
    wired: machineBridge !== null,
    view: machineView,
    reading: machinesReading,
    error: machinesProblem,
    retry: () => void rereadMachines(),
    entry: {
      digits: typed,
      busy: pairingMachine,
      error: pairError,
      blocked: machineView.blocked,
    },
    open: openSession,
    pane:
      machineBridge !== null && openSession !== null ? (
        <MachineSessionPane
          // Keyed, so switching sessions builds a new terminal rather than
          // writing the next session's bytes into the last one's scrollback.
          key={`${openSession.machineId}\u0000${openSession.sessionId}`}
          machineId={openSession.machineId}
          sessionId={openSession.sessionId}
          bridge={machineBridge}
        />
      ) : undefined,
    actions: machineActions({
      bridge: machineBridge,
      digits: typed,
      setDigits: setTyped,
      setView: setMachineView,
      setPairing: setPairingMachine,
      setError: setPairError,
      setOpen: setOpenSession,
      isAlive: () => alive.current,
    }),
  }

  return (
    <RemoteView
      state={state}
      wired={wired}
      missing={missing}
      problem={problem}
      notice={notice}
      pairing={pairing}
      secondsLeft={secondsLeft}
      busy={busy}
      kinds={kinds}
      approving={approving}
      machines={machinesHalf}
      actions={actions}
      now={now}
      /*
        Passed in as a node rather than rendered by the view.

        `RemoteView` is pure on purpose — every state this section can be in is
        pinned by handing it props and calling `renderToStaticMarkup`, which
        never runs an effect. `DeviceFolders` reads its own grants in an effect,
        so building it inside the view would put a component that fetches inside
        the one thing here that is provably a function of its arguments, and
        every view test would start rendering a child that reports "not
        available in this build" because there is no `window.deck` under the
        test renderer.

        It goes below the device roster and above the machines, and that order
        is the argument the screen makes: pair a device, approve it, then choose
        what it may open. Choosing folders for a device nobody has approved is a
        setting with no subject.
      */
      folders={
        wired && state !== null ? (
          <DeviceFolders devices={grantableDevices(state.devices, kinds)} />
        ) : null
      }
      copilot={
        wired && state !== null ? (
          <DeviceCopilot devices={copilotDevices(state.devices, kinds)} />
        ) : null
      }
    />
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
export function grantableDevices(
  devices: readonly RemoteDevice[],
  /**
   * What each device is. Null before the read lands, and then every approved
   * device is listed — a moment of showing one row too many is better than a
   * panel that appears empty and then fills.
   */
  kinds: ReadonlyMap<string, DeviceKind> | null = null,
): FolderDevice[] {
  return devices
    .filter((device) => device.state === 'approved')
    // One of the owner's own machines has no folder list and never consults one,
    // so a row for it here would be a control that changes nothing — which is
    // the "a control that cannot act" this product is removing everywhere else.
    // A device with no recorded kind is left in: it is read as a guest with
    // nothing, and this panel is where somebody fixes that.
    .filter((device) => kinds === null || kinds.get(device.id) !== 'mine')
    .map((device) => ({ id: device.id, name: device.name }))
}

/**
 * The devices worth showing copilot grants for.
 *
 * The same approved-only filter, and one extra fact carried rather than one
 * extra filter: whether the device has a key.
 *
 * A device that paired before sealed channels has no static key, so it cannot
 * open a sealed channel at all — and `copilot.*` frames ride inside that channel
 * like every other frame. Offering it a grant would be a switch with nothing
 * behind it, which is precisely the defect this whole panel was warned about
 * shipping.
 *
 * It is **carried, not filtered**, and that is the decision worth defending. A
 * device silently missing from this list while sitting in the roster two
 * headings above would read as a bug in the panel, and the person would go
 * looking for the row rather than learning why it is not there. So the row is
 * drawn, and it says what is wrong and what fixes it.
 */
export function copilotDevices(
  devices: readonly RemoteDevice[],
  kinds: ReadonlyMap<string, DeviceKind> | null = null,
): CopilotDevice[] {
  return devices
    .filter((device) => device.state === 'approved')
    /*
     * A guest is **filtered**, not carried, and it is the opposite decision from
     * the one two paragraphs up — so it is worth saying why they differ.
     *
     * A device with no key is carried because the thing standing in its way is
     * fixable and the row is how somebody learns to fix it: pair it again. A
     * guest is not in that position. His rule is *"the copilot is never
     * shared"*, so there is no state in which this row would become available,
     * and drawing a row that can never act is the "unchecked box still
     * advertises the feature and invites the ask" this rule exists to prevent.
     *
     * Before the kinds read lands nothing is filtered, for the reason above: a
     * list that shrinks is worse than one that briefly showed a row too many.
     */
    .filter((device) => kinds === null || kinds.get(device.id) === 'mine')
    .map((device) => ({ id: device.id, name: device.name, sealed: device.fingerprint !== null }))
}
