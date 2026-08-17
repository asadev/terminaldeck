import { useCallback, useEffect, useState } from 'react'
import { Group, Notice } from '../settings/controls'
import { errorText } from '../settings/settings-bridge'
import { detectPlatform, thisMachine, type UiPlatform } from '../platform'
import './DeviceCopilot.css'

/**
 * Which paired devices may reach the copilot, and how far.
 *
 * ## Why this sits on the same card as the folders
 *
 * Both answer *what may this device do here*, and somebody deciding about a
 * phone should see both answers at once rather than finding the second one under
 * a different heading a month later. It is directly under the folder list, on the
 * same device card, deliberately.
 *
 * ## Why it is two checkboxes and not one switch
 *
 * Because the copilot's tools have the same names locally and remotely — on
 * purpose, so there is one model to understand — and a single boolean would
 * therefore make *"my phone can ask the copilot which session is stuck"* and
 * *"my phone can start and steer sessions"* the same click. That is not a
 * theoretical objection. OpenClaw shipped exactly it: advisory
 * GHSA-943q-mwmv-hhvh, where the HTTP gateway did not deny session-orchestration
 * tools by default, so anyone holding gateway auth could call `sessions_spawn`.
 *
 * The two boxes are labelled in **outcomes**, never in tier names. "Read" and
 * "act" are words from this codebase's permission model and they mean nothing to
 * a person deciding whether to trust a device. What they can decide about is
 * *watch it* versus *let it work*, and the second one says that it spends money,
 * because that is the fact that changes the answer.
 *
 * ## Why there is a third row that cannot be ticked
 *
 * So that the absence of the alter tier is **visible**. `copilot-grants.ts`
 * keeps the `alter` field in its type for the analogous reason — a refusal that
 * can be pointed at is checkable, an absence is not — and a person who cannot
 * see that the tier exists will assume the two boxes are everything there is,
 * and will hand a device out believing it can do more than it can, or less.
 *
 * It is disabled and it is not a "coming soon". The alter tier's entire safety
 * property is that a human at the machine says yes, and the party holding the
 * phone is by definition not that human. A dialog answered on the device that
 * raised the request is a permission the device already holds, and the grant
 * that withheld it was a ceremony.
 *
 * ## Why the view is separate from the fetching
 *
 * `renderToStaticMarkup` never runs an effect, so a component that read its own
 * grants would be testable in exactly one state — the empty one — and the states
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
}

const BRIDGE_METHODS: ReadonlyArray<keyof DeviceCopilotBridge> = [
  'listDeviceCopilot',
  'setDeviceCopilot',
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

/** What one device may do. Mirrors the grantable half of `TierGrant`. */
export interface CopilotAccess {
  read: boolean
  act: boolean
}

export const NO_ACCESS: CopilotAccess = { read: false, act: false }

/**
 * What the main process sent, as a map, dropping anything unreadable.
 *
 * A device missing from the answer means **nothing granted**, which is also what
 * an all-false row means — so unlike `toDeviceFolders`, the two states are
 * deliberately collapsed. That file has to keep them apart because "not chosen"
 * there means *the device gets the desktop's own folders*, a real third
 * behaviour. Here there is no third behaviour: nobody has ever had remote
 * copilot access, so absence and refusal are the same fact and drawing them
 * differently would invent a distinction the store does not have.
 *
 * `alter` is not read even if it appears. The store scrubs it, `set()` clamps
 * it, and a panel that displayed one would be showing a permission that does not
 * exist — the worst thing a permission screen can do.
 */
export function toDeviceCopilot(raw: unknown): Map<string, CopilotAccess> {
  const grants = new Map<string, CopilotAccess>()
  if (!Array.isArray(raw)) return grants
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    const deviceId = record.deviceId
    if (typeof deviceId !== 'string' || deviceId === '') continue
    const tiers = typeof record.tiers === 'object' && record.tiers !== null ? (record.tiers as Record<string, unknown>) : {}
    // Only a literal `true` grants. Anything else — a string, a 1, an absent
    // field — is no access, which is the same rule the store applies when it
    // reads a file somebody has edited by hand.
    grants.set(deviceId, { read: tiers.read === true, act: tiers.act === true })
  }
  return grants
}

/** True when this device has been given nothing at all. */
export function grantsNothing(access: CopilotAccess): boolean {
  return !access.read && !access.act
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
   * copilot grant would be a switch with nothing behind it — the exact defect
   * this whole panel was warned about landing before its transport. The row is
   * drawn, and it says why it cannot be ticked, rather than the device silently
   * going missing from a list it is on two headings above.
   */
  sealed: boolean
}

export interface DeviceCopilotViewProps {
  devices: CopilotDevice[]
  /** Device id → what it may do. **Null until the first read lands.** */
  grants: Map<string, CopilotAccess> | null
  /** True when the preload exposes the channels at all. */
  wired: boolean
  problem: string | null
  /** The device currently being written, so its boxes stop. */
  busy: string | null
  onChange(deviceId: string, next: CopilotAccess): void
  platform?: UiPlatform
}

export function DeviceCopilotView({
  devices,
  grants,
  wired,
  problem,
  busy,
  onChange,
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
      {/* Off by default, said first. Nobody has ever had this, so nobody can
          lose it by the default being off — and a person opening this screen
          should learn that before they learn anything else about it. */}
      <p className="settings-prose">
        Your copilot is <strong>off for every device</strong> until you turn it on here, one device
        at a time. A device you let in gets a copilot of its own — the same folder, the same
        instructions, the same memory and the same tools as the one on {machine}, but its own
        conversation. It is never typing into the copilot you are talking to.
      </p>

      {problem && <Notice tone="error">{problem} What is below may be out of date.</Notice>}

      {devices.length === 0 ? (
        <p className="settings-prose">No device has been approved yet, so there is nothing to allow.</p>
      ) : (
        <ul className="dc-list">
          {devices.map((device) => {
            const access = grants?.get(device.id) ?? NO_ACCESS
            const reading = grants === null
            const locked = busy === device.id || reading || !device.sealed
            return (
              <li className="dc-device" key={device.id}>
                <div className="dc-head">
                  <span className="dc-name">{device.name}</span>
                  <span className="dc-note">{summaryFor(device, access, reading)}</span>
                </div>

                {device.sealed ? (
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

                    {/* Present, disabled, and never a "coming soon". See the
                        header: this row exists so that the absence of the tier
                        is something a person can point at. */}
                    <li className="dc-tier dc-tier-off">
                      <label className="dc-label">
                        <input type="checkbox" className="dc-box" checked={false} disabled readOnly />
                        <span className="dc-text">
                          <span className="dc-title">Change settings and stop your sessions</span>
                          <span className="dc-blurb">
                            Only at this {machine.replace(/^this /i, '')}. Whoever is holding the
                            device cannot be the one who confirms it.
                          </span>
                        </span>
                      </label>
                    </li>
                  </ul>
                ) : (
                  <p className="dc-unsealed">
                    This device paired before encrypted channels and has no key, so it cannot reach
                    the copilot at all. Pair it again to change that.
                  </p>
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
 * "Reading…" rather than "No access" before the first answer lands, because a
 * pane that says a device has nothing and then changes its mind is a pane that
 * has told somebody something false about a permission.
 */
export function summaryFor(device: CopilotDevice, access: CopilotAccess, reading: boolean): string {
  if (!device.sealed) return 'Cannot be given access'
  if (reading) return 'Reading…'
  if (access.act) return 'Can watch and ask it to work'
  if (access.read) return 'Can watch'
  return 'No access'
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
  const [grants, setGrants] = useState<Map<string, CopilotAccess> | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const wired =
    typeof bridge.listDeviceCopilot === 'function' && typeof bridge.setDeviceCopilot === 'function'

  const read = useCallback(async () => {
    const list = bridge.listDeviceCopilot
    if (!list) return
    try {
      setGrants(toDeviceCopilot(await list()))
      setProblem(null)
    } catch (error) {
      setProblem(errorText(error, 'Could not read which devices may reach the copilot.'))
    }
  }, [bridge])

  useEffect(() => {
    void read()
  }, [read])

  /**
   * Write both tiers, and draw whatever the main process says it stored.
   *
   * Never what was asked for. `CopilotGrants.set` genuinely does not store
   * everything it is handed — `alter` is dropped whatever arrives, and a device
   * past the ceiling is refused outright — so a panel that believed its own ask
   * would show a permission that is not on disk. That is the one mistake a
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
          setGrants(toDeviceCopilot(await save(deviceId, { read: next.read, act: next.act })))
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

  return (
    <DeviceCopilotView
      devices={devices}
      grants={grants}
      wired={wired}
      problem={problem}
      busy={busy}
      onChange={onChange}
      {...(platform ? { platform } : {})}
    />
  )
}

export default DeviceCopilot
