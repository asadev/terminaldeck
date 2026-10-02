import type { AnnotateWhere, AnnotationRound } from '../../shared/annotate'
import type { DeviceTree } from '../../shared/device-tree'

/**
 * The slice of the preload the Simulators page uses, feature-detected.
 *
 * Mirrors `src/main/devices/ipc.ts`. Types cross the bridge as plain shapes and
 * are restated here rather than imported from the main process, which is the
 * rule `CLAUDE.md` gives for every feature: a renderer importing main-process
 * modules would pull Node into the window.
 *
 * Feature-detected rather than assumed, for the same reason every other bridge
 * in `browser/` is: a build whose preload does not carry these channels — an
 * older main process, the harness before its stub learned them — must draw a
 * page that says it cannot, not throw on the first click.
 */

export interface DeviceEntry {
  id: string
  platform: 'ios' | 'android'
  kind: 'simulator' | 'emulator' | 'physical'
  state: 'ready' | 'booting' | 'offline' | 'unauthorized' | 'shutdown' | 'unknown'
  available: boolean
  name: string
  runtime: string
  canBoot: boolean
  canShutDown: boolean
  buttons: string[]
  keys: string[]
  text: string
  canRotate: boolean
  note: string
}

export interface DeviceList {
  available: boolean
  reason: string
  devices: DeviceEntry[]
}

export interface DeviceDetails {
  id: string
  name: string
  platform: 'ios' | 'android'
  kind: string
  pointWidth: number
  pointHeight: number
  buttons: string[]
  keys: string[]
  text: string
  canRotate: boolean
  rawTouch: boolean
}

export interface FrozenScreen {
  image: string
  width: number
  height: number
  tree: DeviceTree | null
  treeError: string
  where: AnnotateWhere
}

export interface DeviceShot {
  path: string
  width: number
  height: number
  preview: string
  url: string
}

export type Outcome = { ok: true; id?: string } | { ok: false; message: string }

export interface DevicesBridge {
  deviceList(): Promise<DeviceList>
  deviceBoot(id: string): Promise<Outcome>
  deviceShutDown(id: string): Promise<Outcome>
  deviceOpen(id: string): Promise<DeviceDetails>
  deviceWatch(id: string, on: boolean): Promise<void>
  deviceTap(id: string, x: number, y: number, holdMs?: number): Promise<void>
  deviceTouch(id: string, phase: 'down' | 'move' | 'up', x: number, y: number): Promise<void>
  deviceSwipe(id: string, from: { x: number; y: number }, to: { x: number; y: number }, ms?: number): Promise<void>
  deviceType(id: string, text: string): Promise<void>
  deviceKey(id: string, key: string, modifiers?: string[]): Promise<void>
  deviceButton(id: string, button: string): Promise<void>
  deviceRotate(id: string): Promise<string>
  deviceScreenshot(id: string): Promise<DeviceShot>
  deviceFreeze(id: string): Promise<FrozenScreen>
  annotateSave(png: string, round: AnnotationRound): Promise<{ path: string; width: number; height: number }>
  annotateSent(roundId: string, sentTo: { sessionId: string; label: string }): Promise<void>
  onDeviceFrame(listener: (id: string, jpeg: Uint8Array) => void): () => void
  onDeviceClosed(listener: (id: string, reason: string) => void): () => void
  /** The browser's own reveal: both kinds of picture land in one folder. */
  browserRevealScreenshot?(path: string): Promise<void>
}

const METHODS: readonly (keyof DevicesBridge)[] = [
  'deviceList',
  'deviceBoot',
  'deviceShutDown',
  'deviceOpen',
  'deviceWatch',
  'deviceTap',
  'deviceTouch',
  'deviceSwipe',
  'deviceType',
  'deviceKey',
  'deviceButton',
  'deviceRotate',
  'deviceScreenshot',
  'deviceFreeze',
  'annotateSave',
  'annotateSent',
  'onDeviceFrame',
  'onDeviceClosed',
]

/** The bridge, when every method the page needs is there; otherwise null. */
export function resolveDevicesBridge(host?: unknown): DevicesBridge | null {
  const deck =
    host !== undefined
      ? host
      : typeof window === 'undefined'
      ? undefined
      : (window as unknown as { deck?: unknown }).deck
  if (typeof deck !== 'object' || deck === null) return null
  const record = deck as Record<string, unknown>
  return METHODS.every((name) => typeof record[name] === 'function') ? (deck as DevicesBridge) : null
}

/** What sort of thing a row is, in the words a person uses. */
export function kindWords(entry: Pick<DeviceEntry, 'platform' | 'kind'>): string {
  if (entry.platform === 'ios') return 'iOS Simulator'
  return entry.kind === 'physical' ? 'Android phone' : 'Android emulator'
}

/** The state, in words, for the line under a name. */
export function stateLine(entry: DeviceEntry): string {
  if (entry.note) return entry.note
  switch (entry.state) {
    case 'ready':
      return 'Running'
    case 'booting':
      return 'Starting…'
    case 'shutdown':
      return 'Off'
    case 'offline':
      return 'Not answering'
    case 'unauthorized':
      return 'Waiting for permission on the phone'
    default:
      return ''
  }
}

/**
 * The rows in the order the page lists them: running first, then what can be
 * started, then what cannot be used at all. Within each, iOS before Android and
 * by name — the same order `inventory.ts` sorts in, restated because the page
 * groups by it.
 */
export function groupDevices(devices: readonly DeviceEntry[]): Array<{ title: string; rows: DeviceEntry[] }> {
  const running = devices.filter((d) => d.available)
  const off = devices.filter((d) => !d.available && d.canBoot)
  const other = devices.filter((d) => !d.available && !d.canBoot)
  return [
    { title: 'Running', rows: running },
    { title: 'Off', rows: off },
    { title: 'Not available', rows: other },
  ].filter((group) => group.rows.length > 0)
}
