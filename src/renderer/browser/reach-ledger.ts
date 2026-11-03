/**
 * The browser window's end of the one tunnel list.
 *
 * ## What this replaced
 *
 * `BrowserWorkspace` kept `const [opened, setOpened] = useState<ReachedPort[]>([])`
 * and treated it as the truth about which of another machine's ports this
 * computer is serving. One `BrowserWorkspace` is mounted **per browser window**
 * - App.tsx mounts the flat list keyed on `tab.id` and the split pane keyed on
 * `${paneId}:${pageTab.id}` - while the listener behind a row is a single thing
 * in the main process. So the array was one window's private memory of a
 * shared object, and every consequence he saw follows from that sentence:
 *
 *  - A second window reading the same page had no row, so `servedBy` answered
 *    null and its address bar drew no machine chip while the picker beside it
 *    named a machine. *"I don't know what to trust."*
 *  - One window moving its page home closed the listener under the other, whose
 *    next load died with nothing on its screen to explain it.
 *  - A displaced row was dropped from the array whether or not the hand-back
 *    that followed it succeeded, leaving a listener no control could see.
 *
 * The list now lives in `src/main/browser-reach.ts` with a count of the windows
 * holding each tunnel, and this file is how a window reads it and takes part in
 * it. Nothing here decides anything about a tunnel; it narrows what main sent
 * and writes the two sentences a window says out loud.
 *
 * ## Why `servedBy` and `moveFor` did not change
 *
 * They take the list as an argument and were always pure. What changed is where
 * the argument comes from - the same rows, from one place instead of six - so
 * the rules in `machines-bridge.ts` are untouched and their tests still hold
 * them.
 */

import { readReach, type ReachAnswer, type ReachedPort } from './machines-bridge'

/** Which bridge holds a machine's listeners. The same word `MachineChoice.kind` uses. */
export type ReachKind = 'device' | 'server'

/**
 * One tunnel, as the main process lists it.
 *
 * A superset of {@link ReachedPort} on purpose: every rule already written over
 * that shape - `servedBy`, `inTheWay`, `moveFor` - takes these rows unchanged.
 */
export interface ReachHold extends ReachedPort {
  kind: ReachKind
  /** Browser windows still holding it. Zero only for a row that would not close. */
  holders: number
  /** True when this desktop tried to hand the port back and the listener stayed up. */
  stranded: boolean
}

/** The answer to asking for a port. */
export interface ReachHeld {
  /**
   * Exactly what `machines:reach` always answered, narrowed by the same
   * `readReach` the direct verb used. A second narrowing rule for one shape
   * would have been a second thing to keep in step with the main process.
   */
  answer: ReachAnswer
  /** A tunnel displaced off this number that would not close, or null. */
  stranded: ReachHold | null
}

/** The answer to letting one go. */
export interface ReachReleased {
  /** True when this desktop is no longer serving that far port on a local address. */
  gone: boolean
  /** Windows still holding it after this one let go. */
  holders: number
  /** Why it did not go. Empty when it did. */
  message: string
}

/**
 * The four channels the tunnel list needs.
 *
 * Named `*Bridge*` for the reason `BrowserMachinesBridge` is: `src/preload/contract.test.ts`
 * reads every interface in the renderer whose name contains it and fails the
 * build when the preload has stopped exposing one of these.
 */
export interface BrowserReachBridge {
  listReach(): Promise<unknown>
  onReachState(cb: (holds: unknown) => void): () => void
  holdReach(
    holder: string,
    machine: { id: string; name: string; kind: string },
    port: number,
  ): Promise<unknown>
  releaseReach(holder: string, machineId: string, port: number): Promise<unknown>
}

const REACH_METHODS = ['listReach', 'onReachState', 'holdReach', 'releaseReach'] as const

/**
 * The bridge, or null when this build's preload predates the shared list.
 *
 * Null is a real state rather than a defensive habit, and the window acts on it
 * by drawing no machine picker at all. A picker that can name Office PC and
 * then cannot open anything on it is the control this project has a standing
 * rule against - and the rule matters more here than usual, because the
 * failure would land on the one screen he has already been shown lying to him.
 */
export function resolveReachApi(host?: unknown): BrowserReachBridge | null {
  const source =
    host ??
    (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return null
  const record = source as Record<string, unknown>
  for (const method of REACH_METHODS) {
    if (typeof record[method] !== 'function') return null
  }
  return source as BrowserReachBridge
}

/**
 * Whether this window can hold a tunnel at all.
 *
 * Two ways it cannot: a preload with no ledger, and no shell tab id - a hold is
 * filed under that id and a hold nobody can be charged with is a listener
 * nothing would ever close. The window acts on a `false` by offering no
 * machines, so the picker is not drawn rather than drawn and refusing. A
 * dropdown that can name Office PC and then cannot open a single port on it is
 * the exact shape of control this project has a standing rule against, and the
 * rule matters more on this bar than anywhere: it is the one he has already
 * been shown lying to him.
 */
export function canHoldTunnels(
  reach: BrowserReachBridge | null,
  holder: string | undefined,
): boolean {
  return reach !== null && typeof holder === 'string' && holder !== ''
}

function asKind(value: unknown): ReachKind {
  return value === 'server' ? 'server' : 'device'
}

function readHold(value: unknown): ReachHold | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  if (typeof row.machineId !== 'string' || row.machineId === '') return null
  if (typeof row.port !== 'number' || typeof row.localPort !== 'number') return null
  return {
    machineId: row.machineId,
    machineName: typeof row.machineName === 'string' ? row.machineName : '',
    kind: asKind(row.kind),
    port: row.port,
    localPort: row.localPort,
    sameNumber: row.sameNumber !== false,
    holders: typeof row.holders === 'number' ? row.holders : 0,
    stranded: row.stranded === true,
  }
}

/**
 * The pushed list, narrowed.
 *
 * A row that cannot be read is dropped rather than defaulted into existence: a
 * badge is a claim about where a page comes from, and half a row is not a
 * claim anybody should be shown.
 */
export function readHolds(value: unknown): ReachHold[] {
  if (!Array.isArray(value)) return []
  const rows: ReachHold[] = []
  for (const entry of value) {
    const row = readHold(entry)
    if (row !== null) rows.push(row)
  }
  return rows
}

/** The answer to a hold, narrowed. A shape that cannot be read is a refusal. */
export function readHeld(value: unknown): ReachHeld {
  if (typeof value !== 'object' || value === null) {
    return { answer: readReach(value), stranded: null }
  }
  const row = value as { answer?: unknown; stranded?: unknown }
  return { answer: readReach(row.answer), stranded: readHold(row.stranded) }
}

/**
 * The answer to a release, narrowed. Anything unreadable is "it did not go".
 *
 * The direction of that default is the point. A release this cannot read
 * becoming `gone: true` would let the picker take this computer's name over a
 * page still being served from the machine it is leaving, which is the 0.9.0
 * defect with a narrowing bug in place of the missing verb.
 */
export function readReleased(value: unknown): ReachReleased {
  if (typeof value !== 'object' || value === null) {
    return { gone: false, holders: 0, message: '' }
  }
  const row = value as { gone?: unknown; holders?: unknown; message?: unknown }
  const gone = row.gone === true
  return {
    gone,
    holders: typeof row.holders === 'number' ? row.holders : 0,
    message: gone || typeof row.message !== 'string' ? '' : row.message,
  }
}

/**
 * What a window says when a tunnel it displaced would not close.
 *
 * The page it just opened loaded; this is the other listener, still answering
 * on the same number. Said out loud rather than logged, because the number in
 * the address bar now has two computers behind it and only one of them is in
 * the chip.
 */
export function strandedNote(hold: ReachHold): string {
  return `${hold.machineName} is still serving port ${hold.localPort} here.`
}

/**
 * What to do once a hand-back came back - or did not.
 *
 * The branch the machine picker turns on when it moves a page home, lifted out
 * of the panel so it can be tested by running it. It used to be four lines
 * inside a `.then` and the only thing holding it was a test that read the
 * panel's source for the string `setMachineId(held.machineId)`, which would
 * have gone on passing after the behaviour moved.
 *
 * `go: false` is not an error state to be swallowed: the port is still that
 * machine's, so the picker goes back to naming it. A picker that took this
 * machine's name over a page still coming from the PC is exactly the untruth
 * the whole hand-back exists to prevent.
 */
export function afterHandBack(
  released: ReachReleased,
  held: ReachedPort,
): { go: true } | { go: false; machineId: string; notice: string } {
  if (released.gone) return { go: true }
  return {
    go: false,
    machineId: held.machineId,
    notice:
      released.message === ''
        ? `${held.machineName} is still serving port ${held.localPort} here.`
        : released.message,
  }
}
