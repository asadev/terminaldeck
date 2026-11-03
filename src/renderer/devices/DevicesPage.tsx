import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { elementAt, nodeName, plainRole, type DeviceNode, type NormRect } from '../../shared/device-tree'
import { AnnotateSurface, type Pick } from '../annotate/AnnotateSurface'
import { PageEmpty } from '../components/PageEmpty'
import { useAgentTarget } from '../browser/useAgentTarget'
import { DeviceScreen } from './DeviceScreen'
import { DeviceShotPopup } from './DeviceShotPopup'
import {
  groupDevices,
  kindWords,
  resolveDevicesBridge,
  stateLine,
  type DeviceDetails,
  type DeviceEntry,
  type DeviceList,
  type DeviceShot,
  type DevicesBridge,
  type FrozenScreen,
} from './devices-bridge'
import './devices.css'

/**
 * Simulators: the iOS Simulators and Android emulators and phones on this Mac,
 * live, inside the app, with Annotate.
 *
 * Asad, 2026-10-02: *"we will do it for apps as well, for simulators as well.
 * We have Xcode here, we have Android Studio as well. The way this application
 * [SimView] is doing, I think we need to bring exactly the same way."* So:
 * pick a device (starting it if it is off), see its screen, drive it with the
 * mouse and the keyboard, press its buttons, turn it, photograph it — and
 * Annotate it, which freezes the picture, lets him point at elements and write
 * one note about them, and sends all of it to a session in one message.
 *
 * ## A page, not a window
 *
 * It is a sidebar page like Files or Store rather than a pill in the window
 * strip like a browser page. A browser page has to be a window because it is a
 * native view with its own history that must survive being switched away from;
 * a device's screen is a picture of something that keeps running on its own,
 * and coming back to it is a reconnect that costs a keyframe. A page also
 * needed nothing from the window's shell to exist — one entry in the view list,
 * one case in `PanelView`. Putting a device beside a session in a split is the
 * thing this leaves for later, and it is said in the release notes rather than
 * discovered.
 *
 * ## The engine
 *
 * The screen, the input and the element tree come from SimView's open-source
 * engine, shipped as a dependency and spoken to by `src/main/devices/`. The
 * page, Annotate and the handoff are this app's own.
 */

const PHONE_ICON = 'M8.5 3h7A1.5 1.5 0 0 1 17 4.5v15a1.5 1.5 0 0 1-1.5 1.5h-7A1.5 1.5 0 0 1 7 19.5v-15A1.5 1.5 0 0 1 8.5 3zM11 18h2'

/** Remembered per window, so coming back to the page reopens what was open. Never trusted to still exist. */
const LAST_KEY = 'simulators.last'

function readLast(): string {
  try {
    return localStorage.getItem(LAST_KEY) ?? ''
  } catch {
    return ''
  }
}

/** How often the list is asked again while it is on screen: now and then, or soon while a row is changing. */
const RELIST_MS = 10_000
const RELIST_SOON_MS = 2_000

/** The hidden diagnostics readout over the live screen: on or off, remembered per window. */
const DIAGNOSTICS_KEY = 'simulators.diagnostics'

function readDiagnostics(): boolean {
  try {
    return localStorage.getItem(DIAGNOSTICS_KEY) === '1'
  } catch {
    return false
  }
}

function writeDiagnostics(on: boolean): void {
  try {
    if (on) localStorage.setItem(DIAGNOSTICS_KEY, '1')
    else localStorage.removeItem(DIAGNOSTICS_KEY)
  } catch {
    // Not remembered; it is still on for now.
  }
}

function writeLast(id: string): void {
  try {
    if (id) localStorage.setItem(LAST_KEY, id)
    else localStorage.removeItem(LAST_KEY)
  } catch {
    // A window that cannot remember simply opens on the list next time.
  }
}

/** What a tree node is, as Annotate records it. */
export function elementOf(node: DeviceNode): Pick['element'] {
  const name = nodeName(node)
  const identifier = node.identifier || node.testID
  return {
    ...(plainRole(node.role) ? { role: plainRole(node.role) } : {}),
    ...(name && name !== identifier ? { name } : {}),
    ...(identifier ? { identifier } : {}),
    ...(node.component ? { component: node.component } : {}),
    ...(node.sourceLocation ? { source: node.sourceLocation } : {}),
  }
}

function rectOf(node: DeviceNode): NormRect | null {
  const rect = node.frame?.normalized
  return rect && rect.width > 0 && rect.height > 0 ? rect : null
}

/**
 * The line under a device's name: what it is and what runs on it, and its
 * state only where the group heading does not already say it.
 *
 * `Simulator · iOS 27.0` rather than `iOS Simulator · iOS 27.0`: the runtime
 * already names the platform, and the same word twice in nine characters is
 * the kind of line he reads as noise.
 */
export function subLine(entry: DeviceEntry): string {
  const kind = entry.runtime && entry.platform === 'ios' ? 'Simulator' : kindWords(entry)
  const state = entry.available || entry.canBoot ? '' : stateLine(entry)
  // Shown from the simulator's own record because the engine was slow: still
  // here, still usable, and being checked again.
  const checking = entry.checking ? 'checking…' : ''
  return [kind, entry.runtime, state, checking].filter(Boolean).join(' · ')
}

interface IconButtonProps {
  label: string
  onClick(): void
  pressed?: boolean
  disabled?: boolean
  children: ReactNode
}

function ToolButton({ label, onClick, pressed, disabled, children }: IconButtonProps) {
  return (
    <button
      type="button"
      className="dv-tool"
      aria-label={label}
      title={label}
      aria-pressed={pressed === undefined ? undefined : pressed}
      data-on={pressed || undefined}
      disabled={disabled}
      onClick={onClick}
    >
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {children}
      </svg>
    </button>
  )
}

export function DevicesPage({ bridge: given }: { bridge?: DevicesBridge | null }) {
  const bridge = useMemo(() => (given !== undefined ? given : resolveDevicesBridge()), [given])
  const agent = useAgentTarget()
  const [list, setList] = useState<DeviceList | null>(null)
  const [busy, setBusy] = useState<Record<string, string>>({})
  const [problem, setProblem] = useState('')
  const [device, setDevice] = useState<DeviceDetails | null>(null)
  const [opening, setOpening] = useState('')
  const [frozen, setFrozen] = useState<FrozenScreen | null>(null)
  const [freezing, setFreezing] = useState(false)
  const [shot, setShot] = useState<DeviceShot | null>(null)
  // Option-click the device's name. For measuring, not for everyday use, so it
  // has no button of its own.
  const [diagnostics, setDiagnostics] = useState(readDiagnostics)
  const toggleDiagnostics = (): void => {
    setDiagnostics((on) => {
      writeDiagnostics(!on)
      return !on
    })
  }
  /*
   * What just happened, said once. The surface closes the moment a round is
   * sent — the person is done with it — so without this line the only sign
   * the notes went anywhere would be in another window.
   */
  const [said, setSaid] = useState('')
  useEffect(() => {
    if (said === '') return
    const timer = setTimeout(() => setSaid(''), 6_000)
    return () => clearTimeout(timer)
  }, [said])
  const toolbarRef = useRef<HTMLDivElement | null>(null)

  const refresh = useCallback(async (): Promise<DeviceList | null> => {
    if (!bridge) return null
    try {
      const next = await bridge.deviceList()
      setList(next)
      return next
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
      return null
    }
  }, [bridge])

  const open = useCallback(
    async (id: string): Promise<void> => {
      if (!bridge) return
      setOpening(id)
      setProblem('')
      try {
        const details = await bridge.deviceOpen(id)
        setDevice(details)
        writeLast(id)
      } catch (error) {
        setProblem(error instanceof Error ? error.message : String(error))
      } finally {
        setOpening('')
      }
    },
    [bridge],
  )

  // The list on arrival and whenever the window comes back to the front — a
  // simulator started from Xcode in the meantime should simply be there.
  useEffect(() => {
    void refresh().then((next) => {
      const last = readLast()
      if (last && next?.devices.some((d) => d.id === last && d.available)) void open(last)
    })
    const onFocus = (): void => void refresh()
    window.addEventListener('focus', onFocus)
    return () => window.removeEventListener('focus', onFocus)
  }, [refresh, open])

  // And on a light schedule while the list is on screen and the window can be
  // seen. Focus alone was not enough: under heavy load the engine left every
  // iOS Simulator out of its answer, and the page showed none until he clicked
  // back into the window. Nothing tells this page when a simulator is started
  // from Xcode either. So it asks again every few seconds while a row is
  // starting, stopping or being checked, now and then otherwise, never while
  // the window is hidden, and never with a device open — the list is not on
  // screen then. The main process never runs two engine listings at once
  // (`inventory.ts`), so a slow one is not stacked up.
  const changing =
    Object.keys(busy).length > 0 || (list?.devices.some((d) => d.checking === true || d.state === 'booting') ?? false)
  useEffect(() => {
    if (device) return
    let timer: ReturnType<typeof setTimeout> | null = null
    let stopped = false
    const visible = (): boolean => document.visibilityState !== 'hidden'
    const schedule = (): void => {
      if (timer) clearTimeout(timer)
      timer = null
      if (stopped || !visible()) return
      timer = setTimeout(
        () => {
          timer = null
          void refresh().finally(schedule)
        },
        changing ? RELIST_SOON_MS : RELIST_MS,
      )
    }
    const onVisibility = (): void => {
      if (visible()) void refresh().finally(schedule)
      else if (timer) {
        clearTimeout(timer)
        timer = null
      }
    }
    document.addEventListener('visibilitychange', onVisibility)
    schedule()
    return () => {
      stopped = true
      if (timer) clearTimeout(timer)
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [device, refresh, changing])

  useEffect(() => {
    if (!bridge) return
    return bridge.onDeviceClosed((id, reason) => {
      if (id !== device?.id) return
      setDevice(null)
      setFrozen(null)
      setProblem(reason || 'The device stopped.')
      void refresh()
    })
  }, [bridge, device?.id, refresh])

  const start = async (entry: DeviceEntry): Promise<void> => {
    if (!bridge) return
    setBusy((prev) => ({ ...prev, [entry.id]: 'Starting…' }))
    setProblem('')
    const outcome = await bridge.deviceBoot(entry.id).catch((error: unknown) => ({
      ok: false as const,
      message: error instanceof Error ? error.message : String(error),
    }))
    setBusy((prev) => {
      const next = { ...prev }
      delete next[entry.id]
      return next
    })
    if (!outcome.ok) {
      setProblem(outcome.message)
      return
    }
    await refresh()
    await open(outcome.id ?? entry.id)
  }

  const shutDown = async (): Promise<void> => {
    if (!bridge || !device) return
    const id = device.id
    setDevice(null)
    setFrozen(null)
    writeLast('')
    setBusy((prev) => ({ ...prev, [id]: 'Shutting down…' }))
    const outcome = await bridge.deviceShutDown(id).catch(() => ({ ok: false as const, message: 'It would not shut down.' }))
    setBusy((prev) => {
      const next = { ...prev }
      delete next[id]
      return next
    })
    if (!outcome.ok) setProblem(outcome.message)
    await refresh()
  }

  const annotate = async (): Promise<void> => {
    if (!bridge || !device) return
    if (frozen) {
      setFrozen(null)
      return
    }
    setFreezing(true)
    setProblem('')
    setSaid('')
    try {
      setFrozen(await bridge.deviceFreeze(device.id))
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      setFreezing(false)
    }
  }

  const screenshot = async (): Promise<void> => {
    if (!bridge || !device) return
    try {
      setShot(await bridge.deviceScreenshot(device.id))
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    }
  }

  if (!bridge) {
    return <PageEmpty icon={PHONE_ICON} title="Simulators are not available in this build" />
  }
  if (list && !list.available) {
    return <PageEmpty icon={PHONE_ICON} title="Simulators are not available here">{list.reason}</PageEmpty>
  }

  /* ------------------------------------------------------- one device open -- */

  if (device) {
    const tree = frozen?.tree?.root ?? null
    const pickAt = async (x: number, y: number): Promise<Pick | null> => {
      if (!tree) return null
      const node = elementAt(tree, x, y)
      const rect = node ? rectOf(node) : null
      return node && rect ? { rect, element: elementOf(node) } : null
    }
    const hoverAt = (x: number, y: number): NormRect | null => {
      if (!tree) return null
      const node = elementAt(tree, x, y)
      return node ? rectOf(node) : null
    }
    const has = (button: string): boolean => device.buttons.includes(button)
    return (
      <div className="dv-page" data-open="" data-annotating={frozen !== null || undefined}>
        <div className="dv-bar" ref={toolbarRef}>
          <button type="button" className="dv-back" onClick={() => {
            setDevice(null)
            setFrozen(null)
            writeLast('')
            void refresh()
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d="M15 5l-7 7 7 7" />
            </svg>
            Devices
          </button>
          <span
            className="dv-name"
            title={diagnostics ? 'Option-click to hide the diagnostics' : undefined}
            onClick={(event) => {
              if (event.altKey) toggleDiagnostics()
            }}
          >
            {device.name}
          </span>
          <span className="dv-tools">
            {has('home') && (
              <ToolButton label="Home" onClick={() => void bridge.deviceButton(device.id, 'home')} disabled={frozen !== null}>
                <path d="M4 11l8-6.5 8 6.5M6.5 9.5V19h11V9.5" />
              </ToolButton>
            )}
            {has('back') && (
              <ToolButton label="Back" onClick={() => void bridge.deviceButton(device.id, 'back')} disabled={frozen !== null}>
                <path d="M10 6l-6 6 6 6M4 12h16" />
              </ToolButton>
            )}
            {has('overview') && (
              <ToolButton label="Recent apps" onClick={() => void bridge.deviceButton(device.id, 'overview')} disabled={frozen !== null}>
                <rect x="5" y="5" width="14" height="14" rx="2" />
              </ToolButton>
            )}
            {has('lock') && (
              <ToolButton label="Lock" onClick={() => void bridge.deviceButton(device.id, 'lock')} disabled={frozen !== null}>
                <rect x="6" y="11" width="12" height="9" rx="2" />
                <path d="M8.5 11V8a3.5 3.5 0 0 1 7 0v3" />
              </ToolButton>
            )}
            {has('volume-up') && (
              <ToolButton label="Volume up" onClick={() => void bridge.deviceButton(device.id, 'volume-up')} disabled={frozen !== null}>
                <path d="M4 10v4h4l5 4V6L8 10zM17 9v6M14 12h6" />
              </ToolButton>
            )}
            {has('volume-down') && (
              <ToolButton label="Volume down" onClick={() => void bridge.deviceButton(device.id, 'volume-down')} disabled={frozen !== null}>
                <path d="M4 10v4h4l5 4V6L8 10zM15 12h5" />
              </ToolButton>
            )}
            {device.canRotate && (
              <ToolButton label="Rotate" onClick={() => void bridge.deviceRotate(device.id)} disabled={frozen !== null}>
                <path d="M7 4h6a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zM18.5 8.5A6 6 0 0 1 20 13l-2-1.5M20 13l1.5-2" />
              </ToolButton>
            )}
            <ToolButton label="Screenshot" onClick={() => void screenshot()} disabled={frozen !== null}>
              <path d="M4 8h3l1.5-2h7L17 8h3v11H4z" />
              <circle cx="12" cy="13" r="3.2" />
            </ToolButton>
            {/* The same name and glyph as the browser's: one Annotate. */}
            <ToolButton label="Annotate" pressed={frozen !== null} disabled={freezing} onClick={() => void annotate()}>
              <path d="M5 5.5h14v10H10l-4.5 3.5v-3.5H5z" />
              <path d="M9 10.5h6" />
            </ToolButton>
            {device.kind !== 'physical' && (
              <ToolButton label="Shut down" onClick={() => void shutDown()} disabled={frozen !== null}>
                <path d="M12 4v7M7.5 6.8a7 7 0 1 0 9 0" />
              </ToolButton>
            )}
          </span>
        </div>

        {problem && (
          <p className="dv-problem" role="status">
            {problem}
          </p>
        )}
        {said && !problem && (
          <p className="dv-said" role="status">
            {said}
          </p>
        )}

        {frozen ? (
          <AnnotateSurface
            key={frozen.image.length}
            frame={{ image: frozen.image, width: frozen.width, height: frozen.height }}
            where={frozen.where}
            pick={pickAt}
            hover={hoverAt}
            agent={agent}
            noun="screen"
            notice={tree ? '' : 'This screen did not describe its elements, so markers are placed by position.'}
            save={async (png, round) => await bridge.annotateSave(png, round).catch(() => null)}
            onSent={(roundId, sentTo) => {
              void bridge.annotateSent(roundId, sentTo).catch(() => undefined)
              setSaid(`Sent to ${sentTo.label}.`)
            }}
            onClose={() => setFrozen(null)}
          />
        ) : (
          <div className="dv-stage">
            <DeviceScreen bridge={bridge} device={device} live={!freezing} diagnostics={diagnostics} />
            {freezing && <p className="dv-freezing">Freezing the screen…</p>}
          </div>
        )}

        {shot && (
          <DeviceShotPopup
            shot={shot}
            deviceName={device.name}
            kind={kindWords({ platform: device.platform, kind: device.kind === 'physical' ? 'physical' : 'simulator' })}
            anchor={toolbarRef.current?.getBoundingClientRect() ?? null}
            agent={agent}
            onReveal={(path) => void bridge.browserRevealScreenshot?.(path)}
            onClose={() => setShot(null)}
          />
        )}
      </div>
    )
  }

  /* ----------------------------------------------------------- the list -- */

  if (list === null) {
    return <div className="dv-page dv-loading" aria-busy="true" />
  }
  if (list.devices.length === 0) {
    return (
      <PageEmpty icon={PHONE_ICON} title="No simulators or phones yet">
        Create a simulator in Xcode or an emulator in Android Studio, or plug in an Android phone, and it appears here.
      </PageEmpty>
    )
  }

  return (
    <div className="dv-page">
      {problem && (
        <p className="dv-problem" role="status">
          {problem}
        </p>
      )}
      <div className="dv-list">
        {groupDevices(list.devices).map((group) => (
          <section key={group.title} className="dv-group" aria-label={group.title}>
            <h3 className="dv-group-title">{group.title}</h3>
            <ul className="dv-rows">
              {group.rows.map((entry) => {
                const working = busy[entry.id] ?? (opening === entry.id ? 'Opening…' : '')
                return (
                  <li key={entry.id} className="dv-row" data-ready={entry.available || undefined}>
                    <svg className="dv-row-icon" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                      <path d={PHONE_ICON} />
                    </svg>
                    <span className="dv-row-text">
                      <span className="dv-row-name">{entry.name}</span>
                      <span className="dv-row-sub">
                        {subLine(entry)}
                      </span>
                    </span>
                    {working ? (
                      <span className="dv-row-busy">{working}</span>
                    ) : entry.available ? (
                      <button type="button" className="dv-secondary" onClick={() => void open(entry.id)}>
                        Open
                      </button>
                    ) : entry.canBoot ? (
                      <button type="button" className="dv-secondary" onClick={() => void start(entry)}>
                        Start
                      </button>
                    ) : null}
                  </li>
                )
              })}
            </ul>
          </section>
        ))}
      </div>
    </div>
  )
}
