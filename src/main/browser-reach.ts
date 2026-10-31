/**
 * One list of the loopback tunnels this desktop is serving, and who is still
 * reading them.
 *
 * ## Why this file exists
 *
 * `localhost-reach.ts` opens the tunnels; this counts the readers. Until now
 * nothing counted them, and the count was kept in the wrong place entirely: a
 * `useState<ReachedPort[]>` inside `BrowserWorkspace`, of which **one is
 * mounted per browser window** (App.tsx mounts the flat list keyed on `tab.id`
 * and the split pane keyed on `${paneId}:${pageTab.id}`), while the tunnel
 * itself is a single listener in this process, on one port number, on one
 * machine.
 *
 * Three things followed from that, and he saw all three in one sitting:
 *
 *  1. A second window opening the same page had **no row for the tunnel**, so
 *     its address bar drew no machine chip - or the wrong one - while the
 *     picker beside it named a machine. *"I don't know what to trust."*
 *  2. One window moving its page home closed the tunnel **under the other
 *     window**, whose next load died with no explanation anywhere on its screen.
 *  3. `reachPort` dropped a displaced row unconditionally and handed the port
 *     back with a bare `void`. When the hand-back failed, the row was already
 *     gone: a listener no control could see, standing on a number the bar had
 *     stopped explaining.
 *
 * So the bookkeeping is here, in the process that owns the listeners, and every
 * window reads the same list off one push. The picker and the chip cannot
 * disagree because there is nothing left for them to disagree about.
 *
 * ## The reference count, and what "letting go" means
 *
 * A window holds a tunnel from the moment it asks for one until the window is
 * **closed** - not until it navigates away. That is deliberate and it is the
 * lifetime `localhost-reach.ts` already argues for at length: a tunnel lives as
 * long as the link does, because the alternative is a page that dies while
 * somebody is reading it, and because Back has to work. A window sitting on
 * `google.com` that opened `Office PC:3100` an hour ago can still press Back
 * into it, so it is still a reader.
 *
 * The last reader to let go closes the tunnel. A release that is not the last
 * one does **not** close it, and says so in a sentence - because the gesture
 * behind it (the machine picker moving a page home) cannot be honoured while
 * another window is still on that number, and a picker that took the new name
 * anyway would be the 0.9.0 defect back again.
 *
 * ## Why unmounting is not letting go
 *
 * Splitting or unsplitting the window remounts `BrowserWorkspace` under a
 * different React key - App.tsx says so at both mount sites - and an unmounted
 * workspace tears down its `WebContentsView` and builds a new one at the same
 * URL. If unmount released the tunnel, splitting a window with a remote page in
 * it would close the listener and the page would come back refused.
 *
 * So the event this listens for is `browser:window-closed`, which App.tsx sends
 * from `closeTabNow` and from nowhere else: the browser window is gone for
 * good, and its holds go with it.
 *
 * A **renderer reload** leaves holds behind, and that is the accepted cost of
 * the paragraph above. The rows stay true - the listeners really are up - but a
 * reader count can be one too high until the same tab id holds again, which
 * makes a move home refuse and name a window that is not there. Dropping every
 * hold whenever a renderer navigates would buy that back by closing a tunnel
 * under a page during an ordinary reload, which is the failure this file exists
 * to stop. The shipped app offers no reload gesture; a developer's does.
 *
 * ## Displacement is not a release, and is not refcounted
 *
 * Two machines cannot both own `localhost:3100` on this computer. When a second
 * machine is given that number the ladder in `localhost-reach.ts` hands it the
 * other loopback family rather than refusing, so both tunnels answer on one
 * number and Chromium picks one of them - which is a page assembled from the
 * wrong computer. That is a fact about the address, not about who is reading
 * it, so the displaced listener is closed however many windows were holding it,
 * and every one of them sees the row leave the list in the same breath.
 *
 * If the close **fails**, the row stays, flagged {@link ReachHold.stranded}, and
 * the badge keeps naming the machine that is still answering there. A row
 * deleted while its tunnel is still up is the one outcome this file exists to
 * make impossible.
 */

import type { ReachAnswer } from './localhost-reach'

/** Which of the two bridges holds a machine's listeners. Mirrors `MachineChoice.kind`. */
export type ReachKind = 'device' | 'server'

/** The push every browser window listens on. One list, one truth. */
export const REACH_STATE_CHANNEL = 'browser:reach:state'

/** One tunnel, as every browser window now reads it. */
export interface ReachHold {
  machineId: string
  machineName: string
  kind: ReachKind
  /** The port over there. */
  port: number
  /** The port here, which is what the address bar shows. */
  localPort: number
  /** False when the ladder had to take a different number. See `localhost-reach.ts`. */
  sameNumber: boolean
  /** How many browser windows are still holding it. Zero only for a stranded row. */
  holders: number
  /**
   * True when this desktop tried to give the port back and could not.
   *
   * The listener is still up, so the row stays and the badge keeps naming the
   * machine. This is the state that used to be deleted silently.
   */
  stranded: boolean
}

/** What a window gets back for asking. */
export interface ReachHeld {
  /** Exactly the shape `machines:reach` and `servers:reach` answer with. */
  answer: ReachAnswer
  /**
   * A tunnel that had to be displaced off this number and would not close.
   *
   * Null in the ordinary case. Non-null is a sentence the window prints: that
   * machine is still answering on the number the new page is now using too.
   */
  stranded: ReachHold | null
}

/** What a window gets back for letting go. */
export interface ReachReleased {
  /** True when this desktop is no longer serving that far port on a local address. */
  gone: boolean
  /** Windows still holding it, after this one let go. */
  holders: number
  /** Why it did not go, written for a reader. Empty when it did. */
  message: string
}

export interface ReachLedgerDeps {
  /**
   * Open - or join - the tunnel to that port. The one place the two kinds of
   * machine part company, and it is one line at the call site.
   */
  open(kind: ReachKind, machineId: string, port: number): Promise<ReachAnswer>
  /**
   * Close it for real. True when this desktop is no longer serving that far
   * port on a local address, which **includes never having been**.
   */
  close(kind: ReachKind, machineId: string, port: number): boolean
  /** Push a channel to every window. */
  broadcast(channel: string, payload: unknown): void
}

/** A machine, named by whoever is asking. See the note on `name` below. */
export interface ReachMachine {
  id: string
  /**
   * What to call it on screen.
   *
   * Supplied by the window rather than looked up here, because the two stores
   * that name machines are the two the window already concatenated into one
   * picker - a paired device's pairing-day hostname and a server's user-typed
   * label. Resolving it a second time in this process would be a second naming
   * rule to keep in step with `machineChoices` and `serverChoices`.
   */
  name: string
  kind: ReachKind
}

export interface ReachLedger {
  /** Take a hold on that machine's port, opening the tunnel if it is not up. */
  hold(holder: string, machine: ReachMachine, port: number): Promise<ReachHeld>
  /** Let one hold go. The last one out closes the tunnel. */
  release(holder: string, machineId: string, port: number): ReachReleased
  /** A browser window closed. Everything it was the last reader of goes with it. */
  dropHolder(holder: string): void
  /**
   * That machine's tunnels are already gone - its link dropped, or it was
   * forgotten. Nothing to close; the rows simply stop being true.
   */
  forget(machineId: string): void
  list(): ReachHold[]
}

interface Entry {
  machineId: string
  machineName: string
  kind: ReachKind
  port: number
  localPort: number
  sameNumber: boolean
  holders: Set<string>
  stranded: boolean
}

/**
 * Keyed on machine **and far port**, never on the local port.
 *
 * The local port is the one thing about a tunnel that can collide - that is
 * what the ladder is for - so a map keyed on it would merge two machines' rows
 * into one. Machine ids do not collide across the two stores: a device's is its
 * hostId and a server's is a `randomUUID`.
 */
function keyOf(machineId: string, port: number): string {
  return `${machineId} ${port}`
}

function view(entry: Entry): ReachHold {
  return {
    machineId: entry.machineId,
    machineName: entry.machineName,
    kind: entry.kind,
    port: entry.port,
    localPort: entry.localPort,
    sameNumber: entry.sameNumber,
    holders: entry.holders.size,
    stranded: entry.stranded,
  }
}

/** The sentence for a listener that would not go. Same shape the move home prints. */
function stillServing(entry: Entry): string {
  return `${entry.machineName} is still serving port ${entry.localPort} here.`
}

export function createReachLedger(deps: ReachLedgerDeps): ReachLedger {
  const entries = new Map<string, Entry>()

  function list(): ReachHold[] {
    return [...entries.values()]
      .sort((a, b) => a.machineName.localeCompare(b.machineName) || a.port - b.port)
      .map(view)
  }

  function changed(): void {
    deps.broadcast(REACH_STATE_CHANNEL, list())
  }

  /**
   * Close a listener and take its row out - but only if it really closed.
   *
   * The one rule this module is here to enforce. Returns true when the row is
   * gone, false when the listener outlived the attempt and the row was kept so
   * that somebody can still see it.
   */
  function shutDown(key: string, entry: Entry): boolean {
    if (deps.close(entry.kind, entry.machineId, entry.port)) {
      entries.delete(key)
      return true
    }
    entry.stranded = true
    return false
  }

  return {
    async hold(holder: string, machine: ReachMachine, port: number): Promise<ReachHeld> {
      const answer = await deps.open(machine.kind, machine.id, port)
      if (!answer.ok) return { answer, stranded: null }
      const key = keyOf(machine.id, port)
      const existing = entries.get(key)
      const entry: Entry = existing ?? {
        machineId: machine.id,
        machineName: machine.name,
        kind: machine.kind,
        port: answer.port,
        localPort: answer.localPort,
        sameNumber: answer.sameNumber,
        holders: new Set<string>(),
        stranded: false,
      }
      // The answer is the current fact about the listener even when the row is
      // not new: `open` is idempotent per port, so a second window joining an
      // existing tunnel is told the same address - and a tunnel that came back
      // on a different rung after a reconnect would otherwise leave a stale
      // number in the badge.
      entry.machineName = machine.name
      entry.localPort = answer.localPort
      entry.sameNumber = answer.sameNumber
      entry.stranded = false
      entry.holders.add(holder)
      entries.set(key, entry)

      /*
       * Whose listener was standing on this number here?
       *
       * Asked of the whole list rather than of this window's own - which is the
       * entire point of the list being here. Two windows reaching two different
       * machines' `3100` used to leave the second one blind to the first, so
       * nothing was ever handed back and the first listener stayed up forever,
       * unnamed, with `localhost:3100` answering from whichever of the two
       * loopback families Chromium happened to prefer.
       */
      let stranded: ReachHold | null = null
      for (const [otherKey, other] of [...entries]) {
        if (other.machineId === machine.id) continue
        if (other.localPort !== answer.localPort) continue
        if (!shutDown(otherKey, other)) stranded = view(other)
      }
      changed()
      return { answer, stranded }
    },

    release(holder: string, machineId: string, port: number): ReachReleased {
      const key = keyOf(machineId, port)
      const entry = entries.get(key)
      // Nothing of this desktop's is standing on that number, which is the
      // question being asked rather than a failure to act.
      if (!entry) return { gone: true, holders: 0, message: '' }
      entry.holders.delete(holder)
      if (entry.holders.size > 0) {
        changed()
        return {
          gone: false,
          holders: entry.holders.size,
          // Named as a window rather than as a fault, because it is not one:
          // somebody else is reading that page, and that is why the number
          // cannot mean this computer yet.
          message: `Another browser window is still reading ${entry.machineName}:${entry.port} here.`,
        }
      }
      const gone = shutDown(key, entry)
      changed()
      return { gone, holders: 0, message: gone ? '' : stillServing(entry) }
    },

    dropHolder(holder: string): void {
      let touched = false
      for (const [key, entry] of [...entries]) {
        if (!entry.holders.delete(holder)) continue
        touched = true
        if (entry.holders.size === 0) shutDown(key, entry)
      }
      if (touched) changed()
    },

    forget(machineId: string): void {
      let touched = false
      for (const [key, entry] of [...entries]) {
        if (entry.machineId !== machineId) continue
        entries.delete(key)
        touched = true
      }
      if (touched) changed()
    },

    list,
  }
}

/* --------------------------------------------------------------- the IPC -- */

/** The two shapes of registration this module needs. `handle` for the verbs, `on` for the window. */
export interface ReachRegistrar {
  handle(channel: string, listener: (event: unknown, ...args: unknown[]) => unknown): void
  on(channel: string, listener: (event: unknown, ...args: unknown[]) => void): void
}

function asKind(value: unknown): ReachKind {
  return value === 'server' ? 'server' : 'device'
}

function asMachine(value: unknown): ReachMachine | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as { id?: unknown; name?: unknown; kind?: unknown }
  if (typeof row.id !== 'string' || row.id === '') return null
  return {
    id: row.id,
    name: typeof row.name === 'string' ? row.name : '',
    kind: asKind(row.kind),
  }
}

/**
 * Register the ledger's channels.
 *
 * `browser:window-closed` is listened to here as well as in
 * `browser-binding-ipc.ts`, and that is on purpose rather than a duplicate:
 * they are two different subjects reacting to one fact. Binding owns which
 * session a window belongs to and its `B` number; this owns the tunnels that
 * window was reading. Routing one through the other would put a browser's
 * numbering scheme in charge of closing network listeners.
 */
export function registerBrowserReachIpc(
  ipcMain: ReachRegistrar,
  deps: ReachLedgerDeps,
): ReachLedger {
  const ledger = createReachLedger(deps)

  ipcMain.handle('browser:reach:list', (): ReachHold[] => ledger.list())

  ipcMain.handle(
    'browser:reach:hold',
    async (_event, holder: unknown, machine: unknown, port: unknown): Promise<ReachHeld> => {
      const who = asMachine(machine)
      if (typeof holder !== 'string' || who === null || typeof port !== 'number') {
        return {
          answer: { ok: false, message: 'That is not a window, a machine and a port.' },
          stranded: null,
        }
      }
      return ledger.hold(holder, who, port)
    },
  )

  ipcMain.handle(
    'browser:reach:release',
    (_event, holder: unknown, machineId: unknown, port: unknown): ReachReleased => {
      if (typeof holder !== 'string' || typeof machineId !== 'string' || typeof port !== 'number') {
        return { gone: false, holders: 0, message: 'That is not a window, a machine and a port.' }
      }
      return ledger.release(holder, machineId, port)
    },
  )

  ipcMain.on('browser:window-closed', (_event, tabId: unknown) => {
    if (typeof tabId === 'string') ledger.dropHolder(tabId)
  })

  return ledger
}
