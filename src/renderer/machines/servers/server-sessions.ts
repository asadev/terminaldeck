import type { SessionStatus } from '@shared/types'
import { serverTabId, type WorkspaceTab } from '../../shell/workspace-tabs'

/**
 * The shells this window has open on servers, and the rules for the list.
 *
 * ## Why this is a list in the window and not a read of the far end
 *
 * There is nothing at the far end to read. A paired desktop runs this app, keeps
 * its own sessions, and pushes a roster of them — which is why
 * `machines/types.ts` can describe a remote session as a *record that arrived*
 * and why closing this window and opening it again finds the same sessions still
 * there. A server runs no such thing. What exists over there is a shell that
 * this app opened, on a connection this app holds, and the moment nothing here
 * is holding it there is nothing there either.
 *
 * So the list is authoritative rather than reflective, and two consequences
 * follow that are worth writing down before somebody reads them as bugs:
 *
 *  - **Nothing survives a relaunch.** These are not restored, because there is
 *    nothing to restore them from and a row drawn on the way in would be a claim
 *    about a shell nobody is holding.
 *  - **The window is the owner.** Taking a tab off the list *is* the close. See
 *    `ServerSessionPane`, which closes its shell when it goes away, and the note
 *    in `App.tsx` about why these panes stay mounted while their tab exists.
 *
 * ## Why the whole model is pure, in a file with no React in it
 *
 * Because every one of the decisions below is a rule about a list — which
 * heading a row belongs under, what a row is called, what closing one takes with
 * it — and rules about lists are the part of a feature that is worth pinning
 * exactly. The hook that holds the state is in `session-context.tsx`, and it does
 * nothing except call these.
 */

/** One shell this window has open on one server. */
export interface ServerSession {
  /**
   * The id the strip, the rail and every route into "show me this" use.
   *
   * Minted by `serverTabId` from the server and the key below, so that the one
   * function that knows how the two handles join is the only code that knows it.
   */
  tabId: string
  serverId: string
  /**
   * What the server was called when this was opened, kept in step with the
   * stored list by {@link renameServersIn}.
   *
   * Carried rather than looked up because four surfaces print it — the rail
   * heading, the pill's tooltip, the window bar and the close confirmation — and
   * none of them can reach the servers list, which lives inside a panel that is
   * usually not the thing on screen.
   */
  serverName: string
  /**
   * This window's own handle for the shell, minted before it is opened.
   *
   * Not the far end's id. See {@link serverTabId} for why the tab cannot wait
   * for that one to come back.
   */
  shellKey: string
  /**
   * What the row's dot says, and it only ever says one of two things.
   *
   * `idle` while the shell is up, which is what the dot means for a local shell
   * with nothing recognisable on screen — the honest reading, because nothing on
   * this side classifies what a server shell is doing. `exited` once the far end
   * has gone, which is the one transition this window genuinely observes: the
   * connection closes and `servers:shell:closed` says so.
   *
   * There is deliberately no `working` here. Every other status in this window
   * is produced by `session-activity.ts` reading a local pty's output, and
   * inventing one from a byte count would be a dot that means something
   * different on this row than on the row above it.
   */
  status: SessionStatus
  /**
   * The folder the shell was told to start in, or null for wherever the
   * sign-in lands.
   *
   * Carried on the row because the pane that opens the shell is mounted from
   * this list and there is nowhere else to put it — and read exactly once, when
   * the shell is opened. It is deliberately **not** kept in step with where the
   * person has since `cd`'d to: nothing on this side watches a server shell's
   * working directory, and a field claiming to know it would be a claim this
   * window cannot make.
   */
  startIn: string | null
}

/** A server that has at least one shell open, and the shells under it. */
export interface ServerSessionGroup {
  serverId: string
  name: string
  sessions: readonly ServerSession[]
}

/**
 * A fresh handle for a shell that has not been opened yet.
 *
 * `crypto.randomUUID` where it exists, which is every renderer this app runs in,
 * and a counter-free fallback for the harness and for tests running in an
 * environment that predates it. Uniqueness is the whole requirement: this value
 * ends up in a tab id, and two tabs with one id is a strip where closing one
 * closes the other.
 */
export function newShellKey(): string {
  const web: { randomUUID?: () => string } | undefined = globalThis.crypto
  if (typeof web?.randomUUID === 'function') return web.randomUUID()
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
}

/** The list with one more shell on it, newest last. */
export function withServerSession(
  open: readonly ServerSession[],
  serverId: string,
  serverName: string,
  shellKey: string = newShellKey(),
  /** Where on the server it starts. Null — the default — is where SSH lands. */
  startIn: string | null = null,
): ServerSession[] {
  return [
    ...open,
    {
      tabId: serverTabId(serverId, shellKey),
      serverId,
      serverName,
      shellKey,
      status: 'idle',
      startIn,
    },
  ]
}

/** The list without one shell. Unchanged when the id is not on it. */
export function withoutServerSession(
  open: readonly ServerSession[],
  tabId: string,
): ServerSession[] {
  return open.filter((entry) => entry.tabId !== tabId)
}

/** The list without every shell on one server. */
export function withoutServer(
  open: readonly ServerSession[],
  serverId: string,
): ServerSession[] {
  return open.filter((entry) => entry.serverId !== serverId)
}

/** The list with one shell marked as having ended over there. */
export function serverSessionEnded(
  open: readonly ServerSession[],
  tabId: string,
): ServerSession[] {
  let changed = false
  const next = open.map((entry) => {
    if (entry.tabId !== tabId || entry.status === 'exited') return entry
    changed = true
    return { ...entry, status: 'exited' as SessionStatus }
  })
  return changed ? next : [...open]
}

/**
 * The same list, with every name brought back into step with the stored one.
 *
 * A server can be renamed on its own page while a shell is open on it, and four
 * surfaces print the name off the row rather than off the list. Without this the
 * rail heading would keep the old name until the last shell was closed, which is
 * the app disagreeing with itself about what a machine is called.
 *
 * The identity of the array is preserved when nothing moved, so a caller can put
 * this straight into a state setter without a render per keystroke of the rename
 * field.
 */
export function renameServersIn(
  open: readonly ServerSession[],
  servers: readonly { id: string; name: string }[],
): readonly ServerSession[] {
  let changed = false
  const next = open.map((entry) => {
    const found = servers.find((server) => server.id === entry.serverId)
    if (found === undefined || found.name === entry.serverName) return entry
    changed = true
    return { ...entry, serverName: found.name }
  })
  return changed ? next : open
}

/**
 * The rail's headings, one per server that has something open on it.
 *
 * ## Why a heading appears only when something is open there
 *
 * This is the one place the servers rail is deliberately *not* shaped like the
 * machines rail above it, so it is worth stating the reason rather than leaving
 * it to be discovered and "fixed".
 *
 * A machine's heading is drawn whenever that machine is reachable, with
 * *"Nothing running there."* underneath when it is empty, and that is right for a
 * machine: a paired desktop is a small set of computers somebody deliberately
 * paired, it is either up or it is not, and being up is a live fact worth a row.
 * A server has no equivalent state. It is a stored address, it is always
 * nominally there, and this app never dials one to find out — that is the whole
 * of the events-not-polling arrangement in `useServers.ts`. So a heading per
 * stored server would be a permanent row per address, saying nothing, in the
 * list whose entire job is to answer *what do I have open*.
 *
 * The door is therefore where it already was: the Machines panel, the server's
 * own page, and the control that opens a terminal on it. Once one is open the
 * heading is there with the ＋ on it, and starting a second is the same press it
 * is on a machine.
 *
 * The order is the order the shells were opened in, and the group takes its name
 * from its first row. Sorting by name was tried and is worse: a heading that
 * moves while you are reading it, because a shell you opened somewhere else has
 * just appeared above it, is the list rearranging itself under the pointer.
 */
export function serverSessionGroups(
  open: readonly ServerSession[],
): ServerSessionGroup[] {
  const groups: ServerSessionGroup[] = []
  for (const entry of open) {
    const found = groups.find((group) => group.serverId === entry.serverId)
    if (found === undefined) {
      groups.push({ serverId: entry.serverId, name: entry.serverName, sessions: [entry] })
      continue
    }
    found.sessions = [...found.sessions, entry]
  }
  return groups
}

/**
 * The list as tabs, for the two surfaces that list everything you have open.
 *
 * Built here rather than in `App.tsx` so that the strip, the rail and the
 * routing all read one shape, and so that what a server tab is can be asserted
 * without a window around it.
 *
 * `label` is deliberately empty. `sessionLabel` turns an empty title into
 * *Session N*, numbered among its siblings — which for these is the other shells
 * on the same server, per the sibling rule in `tabLabel` — so a shell on a
 * server is named exactly the way a shell on this computer is. Putting a word
 * like *Terminal* here instead would give every row on the server the same name
 * and take the numbering away with it.
 *
 * `closable` is unconditionally true, and unlike a machine's it needs no
 * capability behind it: the ✕ closes a shell this window opened on a connection
 * this window holds, so there is no version of the far end that can refuse it.
 * There is nothing over there to refuse.
 */
export function serverTabs(open: readonly ServerSession[]): WorkspaceTab[] {
  return open.map((entry) => ({
    id: entry.tabId,
    kind: 'session' as const,
    label: '',
    status: entry.status,
    server: { id: entry.serverId, name: entry.serverName },
    closable: true,
  }))
}
