/**
 * Servers, as the **browser panel** needs them — which is to say, as machines.
 *
 * ## The question this answers
 *
 *   > *"does it also cover to open sessions, and local browsers in server"*
 *
 * It did not. A paired laptop could be chosen beside the address bar and have
 * `localhost` mean it; a server could not, although a server is the computer
 * most likely to be serving something worth looking at. The rule that makes
 * that a defect rather than a missing extra is the one this whole panel was
 * arranged around:
 *
 *   > *"Keep the same one browser window for every device — remote device,
 *   > local device, all should have the same type of same browser window with
 *   > the same tabs, everything. **Shape of the application should not be
 *   > changing for local and remote devices.**"*
 *
 * ## So this file adds no screen, and no words
 *
 * It produces {@link MachineChoice} — the exact shape `machines-bridge.ts`
 * already produces for a paired laptop — and the workspace concatenates the two
 * lists. One picker, one row shape, one refusal sentence under a row that
 * cannot be chosen, one badge on the page that comes back, one `destinationFor`
 * deciding what `localhost` means. `MachinePicker.tsx` needed no change at all
 * to gain servers, and that is the test of whether this was done the right way
 * round.
 *
 * ## The one thing that genuinely differs, and why it is not hidden
 *
 * A paired laptop holds a live connection, so this desktop already knows what
 * it is serving and whether it can be reached. **A server holds no connection
 * until somebody wants something** — §5.4 of `SERVERS-DESIGN.md` is explicit
 * that a server nobody is looking at is not dialled at all, and asking every
 * stored server what it is serving when a browser tab opens would dial all of
 * them to fill in a dropdown nobody opened.
 *
 * So a server that has not been asked yet is a row with nothing under it, and
 * choosing it is what asks. The three answers that come back are the three
 * states this file models, and each of them lands somewhere a person reads:
 *
 *  - **it will not allow this** — the row carries the server's own sentence and
 *    stops being selectable, which is the picker saying why rather than a click
 *    that fails;
 *  - **here is what is listening** — the start page lists it, exactly as it
 *    lists this machine's own;
 *  - **it cannot tell what is listening** — the list is empty *and says so*,
 *    because "nothing is running here" is a different claim about somebody's
 *    server and a false one.
 */

import type { DevPort } from './StartPage'
import type { MachineChoice } from './machines-bridge'

/**
 * The three channels this panel calls for servers.
 *
 * Named `*Bridge*` on purpose: `src/preload/contract.test.ts` reads every
 * interface in the renderer whose name contains it and fails the build when the
 * preload has stopped exposing one. That guard is why a panel calling
 * `reachOnServer` against a preload exposing `serverReach` is caught here
 * rather than in a screenshot.
 */
export interface BrowserServersBridge {
  listServers(): Promise<unknown>
  /** What is listening over there, and whether any of it may be opened. */
  serverPorts(id: string): Promise<unknown>
  /** Give one of its ports an address on this machine, or say why not. */
  reachOnServer(id: string, port: number): Promise<unknown>
}

const SERVER_METHODS = ['listServers', 'serverPorts', 'reachOnServer'] as const

/**
 * The bridge, or null when this build's preload predates a server's localhost.
 *
 * Null is a real state rather than a defensive habit, and this panel has been
 * caught by it before: 0.4.0 shipped `machines:reach` in the main process with
 * nothing in the renderer calling it, so a window running against an older
 * preload is a thing that exists on somebody's disk. Servers are simply absent
 * from the picker then — never a row that is drawn and refuses.
 */
export function resolveServersApi(host?: unknown): BrowserServersBridge | null {
  const source =
    host ??
    (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return null
  const record = source as Record<string, unknown>
  for (const method of SERVER_METHODS) {
    if (typeof record[method] !== 'function') return null
  }
  return source as BrowserServersBridge
}

/** One server, as the list gives it. Nothing else about it is this panel's business. */
export interface ServerRow {
  id: string
  name: string
}

/**
 * Read the server list off the bridge.
 *
 * Two named fields out of a record with several, deliberately: the list also
 * carries an address, a sign-in name and a fingerprint, and none of those
 * belong in a browser panel. A field that crossed because nobody stopped it is
 * how an address ends up in a screenshot.
 */
export function readServers(value: unknown): ServerRow[] {
  if (!Array.isArray(value)) return []
  const out: ServerRow[] = []
  for (const row of value) {
    if (typeof row !== 'object' || row === null) continue
    const record = row as Record<string, unknown>
    const id = typeof record.id === 'string' ? record.id : ''
    if (id === '') continue
    const name = typeof record.name === 'string' && record.name !== '' ? record.name : 'That server'
    out.push({ id, name })
  }
  return out
}

/** What this window last learned about one server. */
export type ServerPortsState =
  /** Chosen, and the answer has not come back. The start page says so. */
  | { state: 'asking' }
  | { state: 'ready'; ports: DevPort[]; cannot: string | null }
  /** It will not allow this, or it could not be reached. The row says why. */
  | { state: 'refused'; message: string }

/**
 * Narrow whatever came back from `servers:ports`.
 *
 * An answer this cannot read becomes a sentence rather than a silence, which is
 * the instruction for this whole feature — *a refusal is a sentence; show it*.
 * The alternative is a picker row that has been chosen, says nothing, lists
 * nothing and cannot be diagnosed from the screen.
 */
export function readServerPorts(value: unknown): ServerPortsState {
  if (typeof value !== 'object' || value === null) {
    return { state: 'refused', message: 'That server was asked what it is serving and gave no answer.' }
  }
  const record = value as Record<string, unknown>
  if (record.ok !== true) {
    const message = typeof record.message === 'string' ? record.message : ''
    return {
      state: 'refused',
      message: message || 'That server could not be asked what it is serving, and no reason came back.',
    }
  }
  const ports: DevPort[] = []
  if (Array.isArray(record.ports)) {
    for (const row of record.ports) {
      if (typeof row !== 'object' || row === null) continue
      const entry = row as Record<string, unknown>
      const port = typeof entry.port === 'number' ? entry.port : Number(entry.port)
      if (!Number.isFinite(port) || port <= 0) continue
      ports.push({
        port,
        process: typeof entry.process === 'string' ? entry.process : '',
        guessed: entry.guessed === true,
        // Never true, and read rather than assumed for the reason every `===
        // true` on this bridge exists: an older main process that does not send
        // the field must read as "not ours" instead of letting `undefined`
        // become a boolean prop.
        ours: entry.ours === true,
      })
    }
  }
  return {
    state: 'ready',
    ports: ports.sort((a, b) => Number(a.guessed) - Number(b.guessed) || a.port - b.port),
    cannot: typeof record.cannot === 'string' && record.cannot !== '' ? record.cannot : null,
  }
}

/**
 * Every server, in the same rows the picker draws a laptop in.
 *
 * A server with no answer yet is **selectable and says nothing**, which is the
 * only honest row for a machine nobody has asked. Not knowing whether a server
 * will allow this is not the same as knowing that it will not, and a row greyed
 * out on a maybe would hide a working feature behind a dropdown — the same
 * three-state discipline the server pages themselves follow, one screen over.
 *
 * `noun` is the word the sentences use for it, and it is `server` rather than
 * anything guessed from the machine: §1.1 settles that a server is a computer
 * nobody sits at, which is a fact about how it was added here rather than
 * something to be detected.
 */
export function serverChoices(
  servers: readonly ServerRow[],
  known: Readonly<Record<string, ServerPortsState>>,
): MachineChoice[] {
  return servers.map((server) => {
    const state = known[server.id]
    return {
      kind: 'server',
      id: server.id,
      name: server.name,
      noun: 'server',
      ports: state?.state === 'ready' ? state.ports : [],
      // A label, because a server writes its own refusal and this row cannot
      // know how long it will be. The server's sentence is kept as the row's
      // `title` — see `MachineChoice.detail` — so nothing is lost and nothing
      // arbitrary is printed into a 19rem menu.
      unreachable: state?.state === 'refused' ? 'Refused' : null,
      detail: state?.state === 'refused' ? state.message : null,
    }
  })
}

/**
 * What the start page should list for a chosen server, and what it should say
 * instead of a list.
 *
 * Null for `ports` is the page's own "still asking" state — it draws *"Asking
 * <name> what it is serving…"* rather than an empty list, and the difference
 * between a server with nothing running and a server that has not answered yet
 * is the difference between a sentence and a lie.
 */
export function portSourceFor(state: ServerPortsState | undefined): {
  ports: DevPort[] | null
  cannot: string | null
} {
  if (state === undefined || state.state === 'asking') return { ports: null, cannot: null }
  // A refusal is already on screen twice — under its row in the picker and in
  // the notice band — so the page shows the list it does have, which is none.
  if (state.state === 'refused') return { ports: [], cannot: state.message }
  return { ports: state.ports, cannot: state.cannot }
}
