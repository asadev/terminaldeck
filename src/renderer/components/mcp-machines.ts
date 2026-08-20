/**
 * The MCP servers on one of his *other* machines, read from this window.
 *
 * ## The report
 *
 * Asad, on the MCP servers page with a PC and a server both connected and
 * running sessions, 2026-08-21:
 *
 *   > *"Here also maybe we need to see which MCP servers or which machine
 *   > connected."*
 *
 * and, a sentence later, the general form of it:
 *
 *   > *"As soon, I think the model should be as soon as we connect to one
 *   > machine, that machine's things should come here and start showing here,
 *   > something like that, instead of the remote session."*
 *
 * The page said "No servers yet" with a folder chip and nothing else. It was
 * reading `~/.claude.json` on this Mac and saying so nowhere, while the
 * Machines page two rows down listed a connected PC whose own servers were
 * reachable — and the only place anything of that machine's appeared was inside
 * its own session.
 *
 * ## Why this needs no new wire, and what that costs
 *
 * A paired machine's connectors already cross: `ControlsReadingWire.connectors`
 * rides the `controls.reading` frame, and `SessionControls` has drawn them on a
 * remote session's bar since 2026-08-20. What did not exist was any reader of
 * them outside that bar. This is that reader, and it is deliberately the same
 * one — `readControlsAt` for the round trip, `readServers` for the parse — so a
 * server named on the chip and a server named on this page cannot be two
 * different ideas of what a server is.
 *
 * The cost is the shape of the frame, and it is stated on screen rather than
 * hidden: those connectors are resolved **for one session's folder**, because
 * two of the three MCP scopes are keyed on a working directory. So this reads
 * through a session that machine is running, names which one, and a machine
 * with no sessions is not offered at all — there is nothing on this wire that
 * asks a machine for its configuration in the abstract.
 *
 * What is *not* here for the same reason: adding, removing or connecting to a
 * server over there. `mcp-add.ts` runs the CLI in a directory on the machine
 * that owns the file, and dialling a server spawns a process; neither is a
 * thing this wire carries, and a button that looked like it did would be the
 * dead control this window is not allowed to have.
 */

import { useCallback, useEffect, useState } from 'react'
import { readServers, type McpRow } from '../chat/attach/McpServers'
import { readControlsAt } from '../shell/controls-target'
import type { MachineWithLink } from '../machines/useMachines'

/** A machine this page can genuinely report on, and the session it reads through. */
export interface MachineTarget {
  machineId: string
  /** What that machine calls itself — the name on the Machines page. */
  name: string
  sessionId: string
  /** The session's title, so the page can say what the answer was resolved for. */
  sessionTitle: string
  /** The folder that session runs in over there. Empty when it never said. */
  cwd: string
}

/**
 * Which connected machines this page can answer for, and through which session.
 *
 * Three conditions, and each one is a place a pill would otherwise lead to an
 * apology:
 *
 *  - **online.** An offline machine answers nothing.
 *  - **`controls`.** The capability the connectors ride on. A machine running a
 *    build older than 2026-08-20 never advertises it and never sends them.
 *  - **at least one session.** The connectors are resolved for a session's
 *    folder; with no session there is no folder to resolve for.
 *
 * Pure and exported so the rule is testable without a bridge, and so it is
 * stated once — the pills and the reader must agree about which machines exist
 * or the page offers something it cannot then read.
 */
export function reportableMachines(machines: readonly MachineWithLink[]): MachineTarget[] {
  const targets: MachineTarget[] = []
  for (const row of machines) {
    const link = row.link
    if (!link || link.state !== 'online') continue
    if (!link.capabilities.includes('controls')) continue
    const session = link.sessions[0]
    if (!session) continue
    targets.push({
      machineId: row.machine.id,
      name: row.machine.name,
      sessionId: session.id,
      sessionTitle: session.title === '' ? 'a session' : session.title,
      cwd: session.cwd,
    })
  }
  return targets
}

export type MachineServersStatus = 'loading' | 'ready' | 'unanswered'

export interface MachineServers {
  status: MachineServersStatus
  /** What that machine reported. Empty is an answer; `unanswered` is not. */
  rows: McpRow[]
  reload(): void
}

/**
 * Ask one machine what its sessions' folder resolves to, whenever the page is
 * pointed at it.
 *
 * `unanswered` and an empty list are different states and the page draws
 * different things for them, which is the same distinction `SessionControls`
 * makes about the same field: an empty list is *"that folder has none"*, no
 * answer is *"nobody said"*. Reporting the second as the first would be this
 * page telling somebody their PC has no MCP servers because a relay round trip
 * went missing.
 */
export function useMachineServers(target: MachineTarget | null): MachineServers {
  const [state, setState] = useState<{ status: MachineServersStatus; rows: McpRow[] }>({
    status: 'loading',
    rows: [],
  })
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (target === null) {
      setState({ status: 'ready', rows: [] })
      return
    }
    let live = true
    setState({ status: 'loading', rows: [] })
    void readControlsAt({ kind: 'machine', machineId: target.machineId }, { sessionId: target.sessionId })
      .then((answer) => {
        if (!live) return
        const value = answer as { connectors?: unknown } | undefined
        const rows = value && typeof value === 'object' ? readServers(value.connectors) : null
        setState(rows === null ? { status: 'unanswered', rows: [] } : { status: 'ready', rows })
      })
      .catch(() => {
        if (!live) return
        setState({ status: 'unanswered', rows: [] })
      })
    return () => {
      live = false
    }
    /*
     * The two ids rather than the object.
     *
     * `MachineTarget` is derived from the machine list on every render — the
     * list is pushed by `machines:state` whenever anything over there moves —
     * so a fresh object arrives constantly and a dependency on it would put a
     * relay round trip on every push. What the read is actually keyed on is
     * which machine and which session, and those change when somebody presses a
     * pill.
     */
  }, [target?.machineId, target?.sessionId, attempt])

  const reload = useCallback(() => setAttempt((n) => n + 1), [])
  return { status: state.status, rows: state.rows, reload }
}
