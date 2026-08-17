import { useCallback, useEffect, useState } from 'react'
import { Group, Notice } from '../settings/controls'
import { errorText } from '../settings/settings-bridge'
import { detectPlatform, thisMachine, type UiPlatform } from '../platform'
import { formatCode } from '../../shared/short-code'
import './DeviceCopilot.css'

/**
 * Which devices are connected to the copilot, and what each of them may do.
 *
 * ## Why this is a connection and not a checkbox
 *
 * It used to be a checkbox. Copilot access was a per-device grant riding the
 * session channel: pair a phone for terminals, tick a box beside its name, and
 * it had a Copilot tab. That is superseded, and the reason is worth having here
 * because this panel is where a person meets the decision.
 *
 * `copilot-grants.ts` argued — correctly, for what it knew — that the `alter`
 * tier could never be given to a device: *the tier's entire safety property is a
 * human at the machine says yes, and a dialog answered on the device that raised
 * the request is answered by the party being confirmed.* Asad, having read it:
 * *"Phones will have full control over copilot, same as the actual machine app.
 * But connecting copilot will be a separate connection than the sessions."*
 *
 * The second sentence dissolves the first argument rather than overruling it.
 * The old reasoning assumed the second factor behind `alter` was **geography** —
 * being at the desk. It was not: somebody who walks away from an unlocked Mac
 * has taken their geography with them. What made the desktop dialog meaningful
 * was that reaching it required an authorisation the requesting party did not
 * already hold. So the factor moves: connecting the copilot is now its own act,
 * with its own six-digit code minted here, its own credential and its own
 * record. A device paired to run terminals has no copilot reach whatsoever until
 * somebody performs it.
 *
 * Which is why this panel has a **Connect** button rather than a switch, and why
 * the tiers travel with the code: the person minting it is standing here,
 * looking at a screen that says what they are about to hand over.
 *
 * ## Why it sits on the same card as the folders
 *
 * Both answer *what may this device do here*, and somebody deciding about a
 * phone should see both answers at once rather than finding the second one under
 * a different heading a month later.
 *
 * ## Why the tiers are still three checkboxes
 *
 * Because the copilot's tools have the same names locally and remotely — on
 * purpose, so there is one model to understand — and a single boolean would
 * make *"my phone can ask which session is stuck"* and *"my phone can rewrite my
 * settings"* the same click. That is not a theoretical objection. OpenClaw
 * shipped exactly it: advisory GHSA-943q-mwmv-hhvh, where the HTTP gateway did
 * not deny session-orchestration tools by default.
 *
 * They are labelled in **outcomes**, never in tier names. "Read" and "act" are
 * words from this codebase's permission model and they mean nothing to a person
 * deciding whether to trust a device. What they can decide about is *watch it*,
 * *let it work* — which says that it spends money, because that is the fact that
 * changes the answer — and *let it change things*, which says that the phone
 * will be the thing asking and answering.
 *
 * ## Why the view is separate from the fetching
 *
 * `renderToStaticMarkup` never runs an effect, so a component that read its own
 * state would be testable in exactly one state — the empty one — and the states
 * worth pinning are the others. Same split, and the same reason, as
 * `DeviceFolders` and `RemoteSection`.
 */

/* -------------------------------------------------------------------------- */
/* The bridge                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Everything this panel needs from `window.deck`.
 *
 * The names are the preload's rather than this file's preference, for the reason
 * `DeviceFolders` gives: a near miss draws a panel that looks unimplemented
 * instead of failing loudly.
 */
export interface DeviceCopilotBridge {
  listDeviceCopilot(): Promise<unknown>
  setDeviceCopilot(deviceId: string, tiers: Record<string, boolean>): Promise<unknown>
  copilotConnectCode(tiers: Record<string, boolean>): Promise<unknown>
  disconnectDeviceCopilot(deviceId: string): Promise<unknown>
  /**
   * A device redeemed a code. Returns the unsubscribe.
   *
   * The one change to this list that does not arrive as the answer to something
   * this panel asked for — somebody reads a code out and it is typed into a
   * phone in the next room. Without it the code would sit on screen until it
   * expired and then fall back to a Connect button, having never noticed the
   * connection it had just authorised.
   */
  onDeviceCopilotChanged(cb: (links: unknown) => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof DeviceCopilotBridge> = [
  'listDeviceCopilot',
  'setDeviceCopilot',
  'copilotConnectCode',
  'disconnectDeviceCopilot',
  'onDeviceCopilotChanged',
]

export function resolveDeviceCopilotBridge(host?: unknown): Partial<DeviceCopilotBridge> {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    // Called through the host object rather than detached, so a preload that
    // exposes methods on a prototype does not throw on `this` the first time
    // somebody ticks a box.
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<DeviceCopilotBridge>
}

/* -------------------------------------------------------------------------- */
/* Narrowing                                                                   */
/* -------------------------------------------------------------------------- */

/** What one connected device may do. Mirrors the store's `TierGrant`. */
export interface CopilotAccess {
  read: boolean
  act: boolean
  alter: boolean
}

export const NO_ACCESS: CopilotAccess = { read: false, act: false, alter: false }

/**
 * What the main process sent, as a map, dropping anything unreadable.
 *
 * A device missing from the answer means **no connection**, which is a different
 * fact from a connection with nothing ticked — and unlike the panel this
 * replaced, the two are no longer collapsed. A device with an all-false row
 * still holds a credential and can still open a copilot connection; it simply
 * cannot do anything through it. Drawing them the same would hide the thing a
 * person would want to revoke.
 *
 * `alter` **is** read now. The store no longer scrubs it, because a copilot
 * connection is its own authorisation — see the header.
 */
export function toDeviceCopilot(raw: unknown): Map<string, CopilotAccess> {
  const links = new Map<string, CopilotAccess>()
  if (!Array.isArray(raw)) return links
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const deviceId = record.deviceId
    if (typeof deviceId !== 'string' || deviceId === '') continue
    const tiers =
      typeof record.tiers === 'object' && record.tiers !== null
        ? (record.tiers as Record<string, unknown>)
        : {}
    // Only a literal `true` grants. Anything else — a string, a 1, an absent
    // field — is no access, which is the same rule the store applies when it
    // reads a file somebody has edited by hand.
    links.set(deviceId, {
      read: tiers.read === true,
      act: tiers.act === true,
      alter: tiers.alter === true,
    })
  }
  return links
}

/** True when this connection has been left able to do nothing. */
export function grantsNothing(access: CopilotAccess): boolean {
  return !access.read && !access.act && !access.alter
}

/* -------------------------------------------------------------------------- */
/* The view                                                                    */
/* -------------------------------------------------------------------------- */

export interface CopilotDevice {
  id: string
  name: string
  /**
   * Whether this device can open a sealed channel at all.
   *
   * A device paired before sealed channels has no static key, so offering it a
   * copilot connection would be a button with nothing behind it — the exact
   * defect this whole panel was warned about landing before its transport. The
   * row is drawn, and it says why it cannot be connected, rather than the device
   * silently going missing from a list it is on two headings above.
   */
  sealed: boolean
}

/** A connect code that has been minted and is on screen right now. */
export interface CopilotOffer {
  deviceId: string
  code: string
  expiresAt: number
}

export interface DeviceCopilotViewProps {
  devices: CopilotDevice[]
  /** Device id → what its connection may do. **Null until the first read lands.** */
  links: Map<string, CopilotAccess> | null
  /** True when the preload exposes the channels at all. */
  wired: boolean
  problem: string | null
  /** The device currently being written, so its controls stop. */
  busy: string | null
  /** The code on screen, if one has been minted. */
  offer: CopilotOffer | null
  onChange(deviceId: string, next: CopilotAccess): void
  onConnect(deviceId: string): void
  onDisconnect(deviceId: string): void
  platform?: UiPlatform
}

export function DeviceCopilotView({
  devices,
  links,
  wired,
  problem,
  busy,
  offer,
  onChange,
  onConnect,
  onDisconnect,
  platform = detectPlatform(),
}: DeviceCopilotViewProps) {
  const machine = thisMachine(platform)

  if (!wired) {
    return (
      <Group title="Copilot">
        <p className="settings-prose">
          Reaching the copilot from a device is not available in this build. No device can see it
          or talk to it.
        </p>
      </Group>
    )
  }

  return (
    <Group title="Copilot">
      {/* Off by default, said first, and said as what it now is: a separate
          connection rather than a switch. Nobody has ever had this, so nobody
          can lose it by the default being off — and a person opening this screen
          should learn that before they learn anything else about it. */}
      <p className="settings-prose">
        Your copilot is <strong>not connected to any device</strong> until you connect one here, one
        at a time, with a code you read off this screen. Pairing a device for terminals gives it no
        copilot access at all. A device you connect gets a copilot of its own — the same folder, the
        same instructions, the same memory and the same tools as the one on {machine}, but its own
        conversation. It is never typing into the copilot you are talking to.
      </p>

      {problem && <Notice tone="error">{problem} What is below may be out of date.</Notice>}

      {devices.length === 0 ? (
        <p className="settings-prose">No device has been approved yet, so there is nothing to connect.</p>
      ) : (
        <ul className="dc-list">
          {devices.map((device) => {
            const access = links?.get(device.id) ?? NO_ACCESS
            const reading = links === null
            const connected = links?.has(device.id) === true
            const locked = busy === device.id || reading || !device.sealed
            return (
              <li className="dc-device" key={device.id}>
                <div className="dc-head">
                  <span className="dc-name">{device.name}</span>
                  <span className="dc-note">{summaryFor(device, access, reading, connected)}</span>
                </div>

                {!device.sealed ? (
                  <p className="dc-unsealed">
                    This device paired before encrypted channels and has no key, so it cannot reach
                    the copilot at all. Pair it again to change that.
                  </p>
                ) : !connected ? (
                  <div className="dc-connect">
                    {offer?.deviceId === device.id ? (
                      /* The code, once, big enough to read out loud. It lives
                         sixty seconds, works once, and dies after five wrong
                         answers — the same ceremony as pairing, one layer up. */
                      <>
                        <p className="dc-code">{formatCode(offer.code)}</p>
                        <p className="dc-code-note">
                          Type this on {device.name} within a minute. It works once. Until it is
                          used, this device has no copilot access.
                        </p>
                      </>
                    ) : (
                      <>
                        <button
                          type="button"
                          className="dc-button"
                          disabled={locked}
                          onClick={() => onConnect(device.id)}
                        >
                          Connect the copilot…
                        </button>
                        <p className="dc-code-note">
                          Shows a code to type on {device.name}. It will be able to watch the
                          copilot, ask it to work, and confirm changes on the device itself — you can
                          narrow that here afterwards.
                        </p>
                      </>
                    )}
                  </div>
                ) : (
                  <>
                    <ul className="dc-tiers">
                      <li className="dc-tier">
                        <label className="dc-label">
                          <input
                            type="checkbox"
                            className="dc-box"
                            checked={access.read}
                            disabled={locked}
                            onChange={(event) =>
                              onChange(device.id, { ...access, read: event.target.checked })
                            }
                          />
                          <span className="dc-text">
                            <span className="dc-title">Watch the copilot</span>
                            <span className="dc-blurb">
                              See what it is doing, what it started, and what it was refused. It
                              cannot make it do anything.
                            </span>
                          </span>
                        </label>
                      </li>

                      <li className="dc-tier">
                        <label className="dc-label">
                          <input
                            type="checkbox"
                            className="dc-box"
                            checked={access.act}
                            disabled={locked}
                            onChange={(event) =>
                              onChange(device.id, { ...access, act: event.target.checked })
                            }
                          />
                          <span className="dc-text">
                            <span className="dc-title">Ask it to work</span>
                            <span className="dc-blurb">
                              Talk to it, and let it start and steer sessions on your behalf.{' '}
                              <strong>This spends money.</strong>
                            </span>
                          </span>
                        </label>
                      </li>

                      {/* The third box, and it is a real one now. It used to be
                          drawn disabled so that the absence of the tier was
                          visible; the tier is grantable since connecting the
                          copilot became its own authorisation, and the blurb
                          says plainly where the confirmation will appear —
                          because that is the whole of what ticking it changes. */}
                      <li className="dc-tier">
                        <label className="dc-label">
                          <input
                            type="checkbox"
                            className="dc-box"
                            checked={access.alter}
                            disabled={locked}
                            onChange={(event) =>
                              onChange(device.id, { ...access, alter: event.target.checked })
                            }
                          />
                          <span className="dc-text">
                            <span className="dc-title">Change settings and stop your sessions</span>
                            <span className="dc-blurb">
                              Every change is still confirmed one at a time — but the confirmation
                              appears on {device.name}, and whoever is holding it answers. Leave this
                              off to keep those confirmations at this {machine.replace(/^this /i, '')}.
                            </span>
                          </span>
                        </label>
                      </li>
                    </ul>

                    <div className="dc-actions">
                      <button
                        type="button"
                        className="dc-button dc-button-quiet"
                        disabled={busy === device.id || reading}
                        onClick={() => onDisconnect(device.id)}
                      >
                        Disconnect the copilot
                      </button>
                      <span className="dc-code-note">
                        Ends this device&rsquo;s copilot connection immediately and destroys its
                        credential. It keeps its terminals.
                      </span>
                    </div>
                  </>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </Group>
  )
}

/**
 * The one line beside a device's name.
 *
 * "Reading…" rather than "Not connected" before the first answer lands, because
 * a pane that says a device has nothing and then changes its mind is a pane that
 * has told somebody something false about a permission.
 */
export function summaryFor(
  device: CopilotDevice,
  access: CopilotAccess,
  reading: boolean,
  connected = true,
): string {
  if (!device.sealed) return 'Cannot be connected'
  if (reading) return 'Reading…'
  if (!connected) return 'Not connected'
  if (access.alter) return 'Connected — can watch, work and confirm changes'
  if (access.act) return 'Connected — can watch and ask it to work'
  if (access.read) return 'Connected — can watch'
  return 'Connected — allowed nothing'
}

/* -------------------------------------------------------------------------- */
/* The section                                                                 */
/* -------------------------------------------------------------------------- */

export interface DeviceCopilotProps {
  devices: CopilotDevice[]
  /** Injected by tests; production reads `window.deck`. */
  bridge?: Partial<DeviceCopilotBridge>
  platform?: UiPlatform
}

export function DeviceCopilot({ devices, bridge: provided, platform }: DeviceCopilotProps) {
  const [bridge] = useState(() => provided ?? resolveDeviceCopilotBridge())
  const [links, setLinks] = useState<Map<string, CopilotAccess> | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [offer, setOffer] = useState<CopilotOffer | null>(null)

  const wired =
    typeof bridge.listDeviceCopilot === 'function' &&
    typeof bridge.setDeviceCopilot === 'function' &&
    typeof bridge.copilotConnectCode === 'function' &&
    typeof bridge.disconnectDeviceCopilot === 'function' &&
    typeof bridge.onDeviceCopilotChanged === 'function'

  const read = useCallback(async () => {
    const list = bridge.listDeviceCopilot
    if (!list) return
    try {
      setLinks(toDeviceCopilot(await list()))
      setProblem(null)
    } catch (error) {
      setProblem(errorText(error, 'Could not read which devices are connected to the copilot.'))
    }
  }, [bridge])

  useEffect(() => {
    void read()
  }, [read])

  /*
   * The device connecting, told rather than discovered.
   *
   * Subscribed even when no code is on screen: a second window, or a code minted
   * a moment before this pane opened, is the same event and the panel has no
   * business knowing which. The push carries the whole list, so this draws what
   * the main process says rather than merging.
   */
  useEffect(() => {
    const subscribe = bridge.onDeviceCopilotChanged
    if (!subscribe) return
    return subscribe((next) => {
      setLinks(toDeviceCopilot(next))
      // The code is spent. Leaving it on screen would have somebody typing it
      // into a second device and being told it did not work.
      setOffer(null)
    })
  }, [bridge])

  /*
   * The code disappears when it expires, without anybody pressing anything.
   *
   * A timer, and one of the very few in this app, because there is nothing to
   * subscribe to: the code's death is the passage of sixty seconds and nothing
   * emits an event for it. Leaving a dead code on screen would have somebody
   * typing it into a phone and being told it did not work, with no way to tell
   * that from having typed it wrong.
   */
  useEffect(() => {
    if (offer === null) return
    const left = offer.expiresAt - Date.now()
    if (left <= 0) {
      setOffer(null)
      return
    }
    const timer = setTimeout(() => setOffer(null), left)
    return () => clearTimeout(timer)
  }, [offer])

  /**
   * Write the tiers, and draw whatever the main process says it stored.
   *
   * Never what was asked for. `CopilotLinks.set` genuinely does not store
   * everything it is handed — most importantly it **refuses to create a record**
   * for a device with no copilot connection, which is what keeps this panel from
   * being a second door onto copilot access — so a panel that believed its own
   * ask would show a permission that is not on disk. That is the one mistake a
   * permission screen must not make, and it is why the channel answers with the
   * whole list rather than with an acknowledgement.
   */
  const onChange = useCallback(
    (deviceId: string, next: CopilotAccess) => {
      const save = bridge.setDeviceCopilot
      if (!save) return
      void (async () => {
        setBusy(deviceId)
        try {
          setLinks(
            toDeviceCopilot(
              await save(deviceId, { read: next.read, act: next.act, alter: next.alter }),
            ),
          )
          setProblem(null)
        } catch (error) {
          setProblem(errorText(error, 'Could not save that. The copilot access is unchanged.'))
          // After a failed write the only honest thing on screen is whatever the
          // main process says is there.
          void read()
        } finally {
          setBusy(null)
        }
      })()
    },
    [bridge, read],
  )

  /**
   * Mint a connect code for one device.
   *
   * The tiers are decided here, at the moment the code is minted, and they are
   * all three — which is what *"full control over copilot, same as the actual
   * machine app"* means. Narrowing afterwards is one click on the boxes that
   * appear once it is connected; the alternative, connecting with nothing and
   * making somebody tick three things, splits one intention into two moments and
   * the second one is the one people skip.
   */
  const onConnect = useCallback(
    (deviceId: string) => {
      const mint = bridge.copilotConnectCode
      if (!mint) return
      void (async () => {
        setBusy(deviceId)
        try {
          const answer = await mint({ read: true, act: true, alter: true })
          const record = typeof answer === 'object' && answer !== null ? (answer as Record<string, unknown>) : null
          const code = record?.code
          const expiresAt = record?.expiresAt
          if (typeof code !== 'string' || typeof expiresAt !== 'number') {
            setProblem('This machine could not make a connect code.')
            return
          }
          setOffer({ deviceId, code, expiresAt })
          setProblem(null)
        } catch (error) {
          setProblem(errorText(error, 'Could not make a connect code.'))
        } finally {
          setBusy(null)
        }
      })()
    },
    [bridge],
  )

  const onDisconnect = useCallback(
    (deviceId: string) => {
      const drop = bridge.disconnectDeviceCopilot
      if (!drop) return
      void (async () => {
        setBusy(deviceId)
        try {
          setLinks(toDeviceCopilot(await drop(deviceId)))
          setProblem(null)
        } catch (error) {
          setProblem(errorText(error, 'Could not disconnect that. The copilot access is unchanged.'))
          void read()
        } finally {
          setBusy(null)
        }
      })()
    },
    [bridge, read],
  )

  return (
    <DeviceCopilotView
      devices={devices}
      links={links}
      wired={wired}
      problem={problem}
      busy={busy}
      offer={offer}
      onChange={onChange}
      onConnect={onConnect}
      onDisconnect={onDisconnect}
      {...(platform ? { platform } : {})}
    />
  )
}

export default DeviceCopilot
