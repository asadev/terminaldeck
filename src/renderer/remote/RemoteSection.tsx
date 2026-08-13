import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { Button, Group, Notice, Row, SectionHead, Switch } from '../settings/controls'
import { errorText } from '../settings/settings-bridge'
import { encodeQr, qrPath, qrViewBox, QR_QUIET_ZONE } from './qr'
import './RemoteSection.css'

/**
 * Remote access — the settings section that opens this Mac to a phone.
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
  /** What to type into the phone. Null when not running. */
  url: string | null
  /** The tailnet address, which is the thing that still works when MagicDNS does not. */
  address: string | null
  /** Why it is not running, in the main process's words. Null when it is. */
  reason: string | null
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
      },
    ]
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
      },
    ]
  })
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

/**
 * The address the phone opens, with the token in the fragment.
 *
 * The fragment is not an accident of formatting: everything after `#` stays in
 * the browser and is never sent to the server, never lands in an access log, and
 * never rides along in a `Referer` header. Any existing fragment on the base URL
 * is dropped rather than appended to — two hashes would make the token part of
 * the first one's value.
 */
export function pairingUrl(base: string, token: string): string {
  return `${base.replace(/#.*$/, '').replace(/\/+$/, '')}/#${token}`
}

/* -------------------------------------------------------------------------- */
/* Words for times                                                             */
/* -------------------------------------------------------------------------- */

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
  approve(device: RemoteDevice): void
  deny(device: RemoteDevice): void
  revoke(device: RemoteDevice): void
  disconnect(connection: RemoteConnection): void
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
  actions: RemoteActions
  now: number
}

const STATE_LABEL: Record<RemoteDeviceState, string> = {
  pending: 'Waiting for you',
  approved: 'Approved',
  revoked: 'Revoked',
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
  actions,
  now,
}: RemoteViewProps) {
  const ids = useId()
  const head = (
    <SectionHead title="Remote access" blurb="Drive this Mac from a phone on your own tailnet." />
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
  const code = pairing && state?.url ? pairingUrl(state.url, pairing.token) : null

  return (
    <>
      {head}

      <Group>
        <div className="settings-item">
          <Row
            label="Let approved devices in"
            help="Off by default. Nothing can reach this Mac while it is off."
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
          as if it were sitting at this keyboard. It reaches this Mac over your tailnet, so nothing
          is published to the internet, but everything on your tailnet is one approval away.
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
              Turn on remote access? Approved devices get a shell on this Mac until you turn it off.
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
        <Group title="Open this on the phone">
          {state?.url ? (
            <p className="remote-url">
              <code>{state.url}</code>
            </p>
          ) : (
            <Notice tone="warn">
              It is running, but the main process did not report an address for it — so there is
              nothing to type into a phone, and no code to scan.
            </Notice>
          )}
          <p className="settings-prose">
            Both devices have to be on the same tailnet. This address only resolves there; typed
            into a phone on mobile data it goes nowhere.
            {state?.address ? ` The tailnet address itself is ${state.address}.` : ''}
          </p>
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
              <Button tone="primary" onClick={actions.pair} disabled={busy !== null || !state?.url}>
                {busy === 'pair' ? 'Asking…' : 'Pair a device'}
              </Button>
            </>
          )}

          {pairing && (
            <div className="remote-pairing">
              {!code ? (
                // Reachable: the server can stop reporting an address while a
                // code is on screen. Saying "expired" here would be the wrong
                // reason, and the right one tells you what to do.
                <Notice tone="warn">
                  There is no address to point this code at any more — the server stopped reporting
                  one. Cancel it and make another once it is serving again.
                </Notice>
              ) : expired ? (
                <Notice tone="warn">
                  That code has expired. Nothing was let in, and it no longer works.
                </Notice>
              ) : (
                <QrFigure url={code} />
              )}

              <div className="remote-pairing-side">
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

                {!expired && code && (
                  <>
                    <p className="settings-prose">
                      Can’t scan it? Type this into the phone’s browser instead:
                    </p>
                    <p className="remote-url">
                      <code>{code}</code>
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
                </li>
              ))}
            </ul>
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
              let in. Approve only the one you are holding.
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
 * How often the panel re-reads.
 *
 * A backstop, not the mechanism: attachments arrive on `onRemoteConnections`
 * within milliseconds. This is for everything nothing pushes — a tailnet that
 * went away, a daemon that stopped — and it is slow enough not to matter and
 * fast enough that nobody stares at a stale screen.
 */
const POLL_MS = 4000

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
 * these nine functions is a shell on the machine. Pulled out here, the
 * dangerous ones are pinned: that turning it *on* takes two presses and turning
 * it *off* takes one, that Deny revokes rather than approves, and that a call
 * that never happened is never reported as one that did.
 */
export function remoteActions(deps: RemoteActionDeps): RemoteActions {
  const { bridge, pairing, setPairing, setConfirmEnable, run, isAlive } = deps

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
   * Three things start a read — the poll, the push from main, and the tail of
   * every action — so several are in flight routinely, and they do not resolve
   * in the order they were sent. Without this, a read issued *before* a revoke
   * can land *after* it and repaint the device as approved. It corrects itself
   * on the next poll, but "approved" on this screen is a claim about who has a
   * shell here, and it must never be a stale one.
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
        // The clock moves with the poll, so "last seen just now" stops being
        // true three minutes later without anything having been re-read.
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
    const timer = setInterval(() => void refresh(), POLL_MS)
    return () => clearInterval(timer)
  }, [wired, refresh])

  useEffect(() => {
    if (typeof bridge.onRemoteConnections !== 'function') return
    // The payload is ignored on purpose: one read is one source of truth, and
    // an event that only carries connections would leave the device list beside
    // it a poll behind.
    return bridge.onRemoteConnections(() => void refresh())
  }, [bridge, refresh])

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

  useEffect(() => {
    if (pairing?.expiresAt == null) return
    setNow(Date.now())
    // Wall clock, not a counter: a laptop that slept for two minutes has an
    // expired code, and a counter would cheerfully show it forty seconds left.
    const timer = setInterval(() => setNow(Date.now()), 500)
    return () => clearInterval(timer)
  }, [pairing])

  const secondsLeft =
    pairing?.expiresAt == null ? null : Math.max(0, Math.ceil((pairing.expiresAt - now) / 1000))

  const actions = remoteActions({
    bridge,
    pairing,
    setPairing,
    setConfirmEnable,
    run: (key, work, done) => void run(key, work, done),
    isAlive: () => alive.current,
  })

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
      confirmEnable={confirmEnable}
      actions={actions}
      now={now}
    />
  )
}
