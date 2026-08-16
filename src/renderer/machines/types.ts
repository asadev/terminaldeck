/**
 * What the window knows about other machines.
 *
 * Mirrors of the types in `src/main/remote/machines/`, restated rather than
 * imported because the renderer tsconfig cannot see `src/main` — the same
 * arrangement `HooksPanel` and `ReadinessPanel` already live with. The bridge
 * carries them as `unknown` and this file is where they become typed.
 *
 * Note what is *not* here. `MachineStore` holds a bearer credential and a
 * private key for every machine, and neither crosses the bridge: the window has
 * no use for either, and a screen that held one would be a screenshot away from
 * publishing it. What arrives instead is a fingerprint — the same six groups
 * the other machine prints — which is the one thing a person may actually want
 * to check.
 */

import type { DeckApi } from '../../shared/types'

/** One machine this desktop has paired to. */
export interface Machine {
  id: string
  name: string
  hostId: string
  fingerprint: string
  /** `darwin`, `win32`, `linux`, or empty when it has never said. */
  platform: string
  pairedAt: number
  lastConnectedAt: number | null
}

export interface RemoteSession {
  id: string
  title: string
  cwd: string
  provider: string
  status: string
  exitCode: number | null
}

export type MachineState = 'offline' | 'connecting' | 'awaiting-approval' | 'online' | 'error'

export interface MachineLinkState {
  id: string
  state: MachineState
  reason: string | null
  sessions: RemoteSession[]
  folders: string[] | null
  capabilities: string[]
  hostPlatform: string
  retryAt: number | null
}

export interface MachinesView {
  machines: Machine[]
  links: MachineLinkState[]
  blocked: string | null
}

export type PairResult =
  | { ok: true }
  | { ok: false; reason: string; message: string }

export interface MachineOutput {
  machineId: string
  sessionId: string
  data: string
  replay: boolean
}

/**
 * The slice of the preload bridge this area needs.
 *
 * Named `*Bridge` on purpose: `src/preload/contract.test.ts` reads every
 * interface with that in its name and fails the build if the preload has
 * stopped exposing one of these methods. That check exists because this seam
 * has broken three times without a single type error — a panel calling
 * `browserClaim` against a preload exposing `browserViewClaim` renders its
 * "not wired into this build" state and looks like an unfinished feature.
 */
export interface MachinesBridge {
  listMachines(): Promise<unknown>
  startMachineCode(): Promise<unknown>
  cancelMachineCode(): Promise<unknown>
  pairMachine(code: string): Promise<unknown>
  forgetMachine(id: string): Promise<unknown>
  renameMachine(id: string, name: string): Promise<unknown>
  connectMachine(id: string): Promise<unknown>
  disconnectMachine(id: string): Promise<unknown>
  attachMachineSession(id: string, sessionId: string, cols: number, rows: number): Promise<unknown>
  detachMachineSession(id: string, sessionId: string): Promise<unknown>
  writeToMachineSession(id: string, sessionId: string, data: string): Promise<unknown>
  resizeMachineSession(id: string, sessionId: string, cols: number, rows: number): Promise<unknown>
  createMachineSession(id: string, cwd?: string, provider?: string): Promise<unknown>
  onMachinesState(cb: (view: unknown) => void): () => void
  onMachineOutput(cb: (chunk: unknown) => void): () => void
}

const BRIDGE_METHODS = [
  'listMachines',
  'startMachineCode',
  'cancelMachineCode',
  'pairMachine',
  'forgetMachine',
  'renameMachine',
  'connectMachine',
  'disconnectMachine',
  'attachMachineSession',
  'detachMachineSession',
  'writeToMachineSession',
  'resizeMachineSession',
  'createMachineSession',
  'onMachinesState',
  'onMachineOutput',
] as const

/**
 * The bridge, or null when this build does not carry it.
 *
 * Read defensively rather than assumed, so an app whose preload is older than
 * this panel says "not in this build" once instead of throwing inside an effect
 * and leaving a blank page with a stack trace in a console nobody opens.
 */
export function resolveBridge(supplied?: MachinesBridge): MachinesBridge | null {
  if (supplied) return supplied
  // Annotated as possibly absent rather than cast. `DeckApi` says every method
  // is there and an older preload says otherwise, and the honest way to hold
  // both is a union the compiler will make us narrow — not an `as` that asserts
  // the answer this function exists to check.
  const deck: DeckApi | undefined = typeof window === 'undefined' ? undefined : window.deck
  if (deck === undefined) return null
  for (const method of BRIDGE_METHODS) {
    if (typeof deck[method] !== 'function') return null
  }
  return deck
}

/* ------------------------------------------------------------- narrowing -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function whole(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

const STATES: MachineState[] = ['offline', 'connecting', 'awaiting-approval', 'online', 'error']

function asSession(value: unknown): RemoteSession | null {
  if (!isRecord(value)) return null
  const id = text(value.id)
  if (id === '') return null
  return {
    id,
    title: text(value.title),
    cwd: text(value.cwd),
    provider: text(value.provider),
    status: text(value.status),
    exitCode: whole(value.exitCode),
  }
}

function asLink(value: unknown): MachineLinkState | null {
  if (!isRecord(value)) return null
  const id = text(value.id)
  if (id === '') return null
  const state = STATES.find((known) => known === value.state) ?? 'offline'
  const sessions = Array.isArray(value.sessions)
    ? value.sessions.map(asSession).filter((session): session is RemoteSession => session !== null)
    : []
  return {
    id,
    state,
    reason: typeof value.reason === 'string' && value.reason !== '' ? value.reason : null,
    sessions,
    // Null and `[]` are different answers all the way up to the screen. Null is
    // "that machine never mentioned folders", `[]` is "somebody chose none for
    // this device" — one is a build to update and the other is a person to ask.
    folders: Array.isArray(value.folders) ? value.folders.map(text).filter((folder) => folder !== '') : null,
    capabilities: Array.isArray(value.capabilities)
      ? value.capabilities.map(text).filter((name) => name !== '')
      : [],
    hostPlatform: text(value.hostPlatform),
    retryAt: whole(value.retryAt),
  }
}

function asMachine(value: unknown): Machine | null {
  if (!isRecord(value)) return null
  const id = text(value.id)
  if (id === '') return null
  return {
    id,
    name: text(value.name),
    hostId: text(value.hostId),
    fingerprint: text(value.fingerprint),
    platform: text(value.platform),
    pairedAt: whole(value.pairedAt) ?? 0,
    lastConnectedAt: whole(value.lastConnectedAt),
  }
}

/** The whole screen's state, narrowed. An unreadable reply is an empty one. */
export function asView(value: unknown): MachinesView {
  if (!isRecord(value)) return { machines: [], links: [], blocked: null }
  return {
    machines: Array.isArray(value.machines)
      ? value.machines.map(asMachine).filter((machine): machine is Machine => machine !== null)
      : [],
    links: Array.isArray(value.links)
      ? value.links.map(asLink).filter((link): link is MachineLinkState => link !== null)
      : [],
    blocked: typeof value.blocked === 'string' && value.blocked !== '' ? value.blocked : null,
  }
}

/*
 * There is no `asCodeResult` here any more, and its absence is the merge.
 *
 * This module used to narrow `machines:code` — the channel the Machines page
 * called to put a code on screen. The main process mints from **one pairing
 * desk** shared by `registerRemoteIpc` and `registerMachinesIpc`, so there is
 * one code at a time whatever asks for it, and the merged Remote section asks
 * through `remote:pair` for every device. Two screens minting the same code was
 * the thing that made them two screens; narrowing an answer nothing on this side
 * asks for would keep the second one half-alive.
 *
 * `startMachineCode` and `cancelMachineCode` stay in {@link MachinesBridge}
 * because that interface is a mirror of the preload — `contract.test.ts` reads
 * it — and the channels are still registered and still tested in
 * `src/main/remote/machines/ipc.test.ts`. Nothing in the renderer calls them.
 */

export function asPairResult(value: unknown): PairResult {
  if (!isRecord(value)) return { ok: false, reason: 'unreachable', message: 'This machine gave no answer.' }
  if (value.ok === true) return { ok: true }
  return {
    ok: false,
    reason: text(value.reason) || 'unreachable',
    message: text(value.message) || 'That did not work, and this machine did not say why.',
  }
}

export function asOutput(value: unknown): MachineOutput | null {
  if (!isRecord(value)) return null
  const machineId = text(value.machineId)
  const sessionId = text(value.sessionId)
  if (machineId === '' || sessionId === '') return null
  return { machineId, sessionId, data: text(value.data), replay: value.replay === true }
}

/* ----------------------------------------------------------------- words -- */

/**
 * What to call a machine, from what it said about itself.
 *
 * The same mapping all four clients make, and the same refusal: `unknown` is
 * never guessed as a Mac. A phone paired to a Windows PC once read "Running on
 * the Mac" because the only place a machine's kind appeared was a constant
 * compiled into the phone, and the noun below is the fix on this side of that.
 */
export function machineNoun(platform: string): string {
  if (platform === 'darwin') return 'Mac'
  if (platform === 'win32') return 'PC'
  if (platform === 'linux') return 'machine'
  return 'desktop'
}

export const STATE_LABEL: Record<MachineState, string> = {
  offline: 'Not connected',
  connecting: 'Connecting',
  'awaiting-approval': 'Waiting to be approved',
  online: 'Connected',
  error: 'Cannot connect',
}
