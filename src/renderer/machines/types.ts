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

/** One port listening on a remote machine, as that machine reported it. */
export interface RemotePort {
  port: number
  process: string
  /** True when the far machine could not name the process holding it. */
  guessed: boolean
}

/** What a machine's copilot may do for this desktop. Three booleans, always all three. */
export interface MachineCopilotGrant {
  read: boolean
  act: boolean
  alter: boolean
}

/**
 * That machine's copilot, as offered to **this** desktop.
 *
 * Three facts rather than one, because a surface has three different things to
 * draw and folding them together makes one of them wrong:
 *
 *  - `linked` — this desktop reaches that copilot at all. It is the far
 *    machine's own word for it, and it is worth carrying past the mere presence
 *    of this object for the one case nothing else reports: a push saying
 *    `false`, which takes the copilot away without a reconnect.
 *  - `open` — the link has said `copilot.hello` on the current socket. False
 *    on every fresh connection, true a round trip later, and false again the
 *    moment a laptop sleeps. Every copilot verb needs it, the read-only ones
 *    included.
 *  - `grant` — what it may do once open. Sent even while closed, so a page can
 *    show what it would get rather than discovering it a frame later.
 */
export interface MachineCopilotLink {
  linked: boolean
  open: boolean
  grant: MachineCopilotGrant
}

export interface MachineLinkState {
  id: string
  state: MachineState
  reason: string | null
  sessions: RemoteSession[]
  folders: string[] | null
  capabilities: string[]
  /**
   * That machine's copilot, or **null for "there is none here for us"**.
   *
   * This is what the switcher at the top of the copilot page reads to decide
   * whether a machine belongs in it. Null is not "not connected" — a machine
   * that is offline has null here and `state: 'offline'` beside it, and the
   * panel already reads the state — it is the far machine having offered no
   * copilot at all, which it does in exactly two cases and deliberately does
   * not distinguish between them: it has none, or it paired this desktop as a
   * guest. `remote/copilot-access.ts` on the far side is why they look the
   * same; the short form is that a guest is sent no key rather than one saying
   * no, because an advertised thing a device may not use invites the ask.
   *
   * So the absence has to survive all the way here rather than being folded
   * into `capabilities`. A machine list drawn off the capability would be
   * reading *what that machine can do* as *what this desktop may do there*,
   * which is a control that is always refused.
   */
  copilot: MachineCopilotLink | null
  /**
   * What is listening on that machine, as it last answered.
   *
   * Pushed with the rest of the link's state rather than fetched by the panel:
   * the link asks once per connection and publishes the answer, so a panel that
   * has just mounted already has a list instead of being empty for a round trip.
   */
  ports: RemotePort[]
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
  /**
   * Type into a session over there without attaching to it. Refused unless that
   * machine advertised `send`, and the refusal arrives as a sentence.
   */
  sendToMachineSession(machineId: string, sessionId: string, data: string): Promise<unknown>
  resizeMachineSession(id: string, sessionId: string, cols: number, rows: number): Promise<unknown>
  createMachineSession(id: string, cwd?: string, provider?: string): Promise<unknown>
  /** End one session over there. Refused unless that machine advertised `close`. */
  closeMachineSession(id: string, sessionId: string): Promise<unknown>
  refreshMachinePorts(id: string): Promise<unknown>
  openOnMachine(id: string, url: string): Promise<unknown>
  /**
   * The copilot on that machine — the pipe under the switcher at the top of the
   * copilot page.
   *
   * Nothing here opens the connection: the link sends `copilot.hello` on every
   * welcome that carried a copilot, because that machine refuses every copilot
   * verb until this socket has said it and the socket is new after every
   * reconnect. Each of the four resolves `{ ok, message }`, where `ok` is *the
   * frame left this machine* — there is no request id on the copilot wire, so
   * it cannot honestly mean more. What the far end made of it arrives on the
   * two subscriptions.
   */
  attachMachineCopilot(machineId: string): Promise<unknown>
  startMachineCopilot(machineId: string): Promise<unknown>
  sayToMachineCopilot(machineId: string, text: string): Promise<unknown>
  refreshMachineCopilot(machineId: string): Promise<unknown>
  onMachineCopilotState(cb: (machineId: string, state: unknown) => void): () => void
  onMachineCopilotChat(cb: (machineId: string, bubble: unknown) => void): () => void
  onMachinesState(cb: (view: unknown) => void): () => void
  onMachineOutput(cb: (chunk: unknown) => void): () => void
  /**
   * Send a file from this machine into a session running on that one.
   *
   * The verb behind dropping a photo on a remote session's pane. A **path**, not
   * the bytes — `pathForDroppedFile` has already turned the dropped `File` into
   * one, and streaming it in the main process is what keeps a 200 MB video out
   * of this window's heap.
   *
   * Resolves `{ ok: true, path }` with the path the file landed at over there,
   * which is what the pane then types at the prompt. It may not be the name the
   * file left with: a second `photo.jpg` lands beside the first rather than over
   * it. Every failure resolves `{ ok: false, message }` instead — a sentence, and
   * never silence.
   */
  uploadToMachine(machineId: string, filePath: string): Promise<unknown>
  /** Stop the transfer to that machine. The far end deletes its half-written file. */
  cancelMachineUpload(machineId: string): Promise<unknown>
  /** Slice-by-slice progress, so a pane can draw one line about a file in flight. */
  onMachineUpload(cb: (progress: unknown) => void): () => void
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
  'sendToMachineSession',
  'resizeMachineSession',
  'createMachineSession',
  'closeMachineSession',
  'refreshMachinePorts',
  'openOnMachine',
  'attachMachineCopilot',
  'startMachineCopilot',
  'sayToMachineCopilot',
  'refreshMachineCopilot',
  'onMachineCopilotState',
  'onMachineCopilotChat',
  'onMachinesState',
  'onMachineOutput',
  'uploadToMachine',
  'cancelMachineUpload',
  'onMachineUpload',
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

function asPort(value: unknown): RemotePort | null {
  if (!isRecord(value)) return null
  const port = whole(value.port)
  // A port number that is not a whole number in range is a row that cannot be
  // opened, so it is dropped rather than drawn — the same rule `asSession`
  // applies to a row with no id.
  if (port === null || !Number.isInteger(port) || port < 1 || port > 65535) return null
  const process = text(value.process)
  return { port, process, guessed: value.guessed === true }
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
    // One unreadable row does not discard the list, for the reason the sessions
    // above do not: a panel showing nine of ten ports is useful and one showing
    // none because the tenth had a null process name is not.
    ports: Array.isArray(value.ports)
      ? value.ports.map(asPort).filter((port): port is RemotePort => port !== null)
      : [],
    copilot: asCopilotLink(value.copilot),
    hostPlatform: text(value.hostPlatform),
    retryAt: whole(value.retryAt),
  }
}

/**
 * The copilot link, or null, and **null is the safe direction**.
 *
 * Refused whole when any of it is unreadable rather than filled in with
 * plausible defaults, because both halves of a half-read one are wrong in the
 * same direction: a link invented out of a malformed frame draws a copilot
 * surface for a machine that never offered one, and every press on it comes
 * back refused with a sentence about guests. The same rule the wire parser
 * applies to this object one layer down.
 */
function asCopilotLink(value: unknown): MachineCopilotLink | null {
  if (!isRecord(value)) return null
  const grant = value.grant
  if (!isRecord(grant)) return null
  if (typeof grant.read !== 'boolean' || typeof grant.act !== 'boolean' || typeof grant.alter !== 'boolean') {
    return null
  }
  if (typeof value.linked !== 'boolean' || typeof value.open !== 'boolean') return null
  return {
    linked: value.linked,
    open: value.open,
    grant: { read: grant.read, act: grant.act, alter: grant.alter },
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
