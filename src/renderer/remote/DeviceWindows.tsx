import { useCallback, useEffect, useState } from 'react'
import { Group } from '../settings/controls'
import { errorText } from '../settings/settings-bridge'
import './DeviceSessions.css'

/**
 * Which paired devices may act on the browser windows in **this** app.
 *
 * ## Why it is here and not on the machine card
 *
 * There is already a switch with this exact sentence on it — `DriveWindows` in
 * `machines/MachineLinks.tsx` — and it is a different switch. That one is about
 * a machine this desktop **dialled out to**; this one is about a device that
 * **dialled in**. They are two id spaces, two stores and two decisions, and the
 * screens they belong on say so: a machine has a card in Machines, a device has
 * a row in the roster above.
 *
 * The reason both exist is the return path added on 2026-08-21. Until then the
 * window conversation only ran one way — the computer with the pty asked, the
 * computer with the screen served — and which of those a given desktop was
 * depended entirely on who had dialled whom. Now it runs both ways, so *this*
 * app can be the one holding the window on a link it did not start, and a device
 * on the other end of it can have the session. That is a permission, and it is
 * this keyboard's to give.
 *
 * ## Why one checkbox and not All/Selected
 *
 * The three panels above narrow a *set* — folders, running sessions, logins.
 * There is no set here. A browser window is the browser on this screen, holding
 * this person's signed-in mail, bank and source control, and the only two
 * answers are yes and no. A mode row would be two buttons where one of them can
 * never mean anything.
 *
 * ## Where a device's default comes from: its kind
 *
 * T30: *"the connection IS the authorization."* A device approved as one of the
 * owner's **own** was vouched for by the person at this keyboard — the same act
 * that adding a server or pairing out to a machine is — so it drives by
 * default, and the tick here is its off-switch. A **guest** is the one peer
 * nobody here vouched for and stays off until ticked; so does a device whose
 * kind nobody recorded. `WindowGrants` in the main process holds the whole
 * argument, and what any allowed device reaches is still bounded window by
 * window by what the person attaches.
 *
 * ## What a change does to a device that is already connected
 *
 * It lands on the very next call, in both directions. Nothing about this grant
 * is baked into the capability list a device was told at `hello` —
 * `CAPABILITY.hostWindows` says only that this machine speaks the frames — and
 * `window-serve.ts` reads the grant per call. So ticking this reaches a device
 * that is connected now, and unticking it stops the next verb rather than the
 * next connection.
 *
 * ## No sentence on this panel
 *
 * *"Don't put any single statement in anywhere… We want simplicity."* A heading,
 * a name, a checkbox. What the tick means is on the checkbox.
 */

/* -------------------------------------------------------------------------- */
/* The bridge                                                                  */
/* -------------------------------------------------------------------------- */

export interface DeviceWindowsBridge {
  /** Every device that is allowed. Devices that are not are absent. */
  listWindowGrants(): Promise<unknown>
  /** Turn it on or off for one device; answers with the stored list. */
  setWindowGrant(deviceId: string, allowed: boolean): Promise<unknown>
}

const BRIDGE_METHODS: ReadonlyArray<keyof DeviceWindowsBridge> = [
  'listWindowGrants',
  'setWindowGrant',
]

export function resolveDeviceWindowsBridge(host?: unknown): Partial<DeviceWindowsBridge> {
  const source =
    host ?? (typeof globalThis === 'undefined' ? undefined : (globalThis as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    // Called through the host object rather than detached, the same rule
    // `DeviceLogins` follows: a preload with methods on a prototype throws on
    // `this` the first time a button is pressed.
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<DeviceWindowsBridge>
}

/* -------------------------------------------------------------------------- */
/* Narrowing                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * What the main process sent, as a set, dropping anything unreadable.
 *
 * The channel answers the **effective** set — every paired device whose verbs
 * would actually land, whether by a tick or by its kind's default — so a device
 * missing from the answer is not allowed, and the ticks on this panel are the
 * truth rather than the raw file. An entry this side cannot read is dropped in
 * the fail-closed direction for the same reason the store reads its own file
 * that way.
 */
export function toWindowGrants(raw: unknown): Set<string> {
  const allowed = new Set<string>()
  if (!Array.isArray(raw)) return allowed
  for (const entry of raw) {
    if (typeof entry !== 'string' || entry === '') continue
    allowed.add(entry)
  }
  return allowed
}

/* -------------------------------------------------------------------------- */
/* The view                                                                    */
/* -------------------------------------------------------------------------- */

/** One paired device, as this panel needs it. */
export interface WindowDevice {
  id: string
  name: string
}

export interface DeviceWindowsViewProps {
  devices: WindowDevice[]
  /** The allowed ids. **Null until the first read lands.** */
  allowed: Set<string> | null
  /** True when the preload exposes the channels at all. */
  wired: boolean
  /** The last read or write failed; what is on screen may be stale. */
  problem: string | null
  /** The device currently being written, so its control stops. */
  busy: string | null
  onToggle(deviceId: string, on: boolean): void
}

export function DeviceWindowsView({
  devices,
  allowed,
  wired,
  problem,
  busy,
  onToggle,
}: DeviceWindowsViewProps) {
  // Nothing at all rather than a sentence about a build that cannot do this, or
  // about there being no approved devices — the same silence the three panels
  // above keep.
  if (!wired || devices.length === 0) return null

  return (
    <Group title="Devices that may act on browser windows here">
      {problem !== null && (
        <p className="settings-prose" role="alert">
          {problem}
        </p>
      )}
      <ul className="ds-list">
        {devices.map((device) => (
          <li className="ds-device" key={device.id}>
            <label className="ds-session">
              <input
                type="checkbox"
                /*
                 * Unticked until the first read lands — the fail-closed draw. A
                 * device of the owner's own ticks itself the moment the answer
                 * arrives; drawing the default before the main process confirms
                 * it would be this panel guessing a permission.
                 */
                checked={allowed?.has(device.id) === true}
                disabled={busy !== null}
                onChange={(event) => onToggle(device.id, event.target.checked)}
              />
              <span className="ds-session-text">
                <span className="ds-session-name">{device.name}</span>
              </span>
            </label>
          </li>
        ))}
      </ul>
    </Group>
  )
}

/* -------------------------------------------------------------------------- */
/* The section                                                                 */
/* -------------------------------------------------------------------------- */

export interface DeviceWindowsProps {
  devices: WindowDevice[]
  /** Injected by tests; production reads `window.deck`. */
  bridge?: Partial<DeviceWindowsBridge>
}

export function DeviceWindows({ devices, bridge: provided }: DeviceWindowsProps) {
  const [bridge] = useState(() => provided ?? resolveDeviceWindowsBridge())
  const [allowed, setAllowed] = useState<Set<string> | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const wired =
    typeof bridge.listWindowGrants === 'function' && typeof bridge.setWindowGrant === 'function'

  const read = useCallback(async () => {
    const list = bridge.listWindowGrants
    if (!list) return
    try {
      setAllowed(toWindowGrants(await list()))
      setProblem(null)
    } catch (error) {
      setProblem(errorText(error, 'Could not read which devices may act on browser windows here.'))
    }
  }, [bridge])

  useEffect(() => {
    void read()
  }, [read])

  const onToggle = useCallback(
    (deviceId: string, on: boolean) => {
      const save = bridge.setWindowGrant
      if (!save) return
      void (async () => {
        setBusy(deviceId)
        try {
          // What lands on screen is what the main process says it stored, not
          // what this component hoped for — the rule the three panels above
          // follow, and the one that matters most here: a tick that drew itself
          // on and was refused would be a permission somebody believes they gave.
          setAllowed(toWindowGrants(await save(deviceId, on)))
          setProblem(null)
        } catch (error) {
          setProblem(errorText(error, 'Could not save that. Nothing changed.'))
          void read()
        } finally {
          setBusy(null)
        }
      })()
    },
    [bridge, read],
  )

  return (
    <DeviceWindowsView
      devices={devices}
      allowed={allowed}
      wired={wired}
      problem={problem}
      busy={busy}
      onToggle={onToggle}
    />
  )
}
