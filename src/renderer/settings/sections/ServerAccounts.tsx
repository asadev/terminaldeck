import { useCallback, useEffect, useRef, useState } from 'react'
import { AGENT_CATALOG } from '../../../shared/agent-catalog'
import type { ProviderId } from '@shared/types'
import { ProviderBadge } from '../../components/ProviderBadge'
import { Notice } from '../controls'
import {
  AGENT_IDS,
  asView,
  type AgentOnServer,
  type Server,
  type ServerView,
} from '../../machines/servers/types'
import { useServers } from '../../machines/servers/useServers'
import { ServerSetup } from '../../machines/servers/ServerSetup'
/*
 * The setup panel's own styles, imported here as well as by `MachinesPanel`.
 *
 * Not belt and braces: Settings is a separate entry point, so a stylesheet that
 * is only ever imported by the machines panel is a stylesheet this window does
 * not necessarily load — and the failure mode is an unstyled install panel
 * rather than an error. The bundler dedupes the second import.
 */
import '../../machines/servers/servers.css'
import { RUN_TITLE, type AccountRun } from './AccountsSection'

/**
 * The servers, and the coding logins on each of them, inside Settings.
 *
 * ## What was here
 *
 * One line: `No servers yet.` — hardcoded, with no props, while the rail behind
 * the dialog was showing a connected server running a live session.
 *
 *   > *"But right now, if you can see, I have a server account connected, but
 *   > coding AI things pages, I don't have any kind of control of server. So
 *   > make sure we have that."*
 *
 * and, of the same panel:
 *
 *   > *"And server side also the same thing should be there."*
 *
 * The stub was written as a seam for another lane and it outlived the lane. The
 * list it should have been reading — `servers:list` — has been there the whole
 * time.
 *
 * ## Nothing is dialled until it is opened
 *
 * `useServers` states the rule this obeys: the stored list costs nothing to
 * draw, and **no server is connected to unless somebody is looking at it**.
 * Drawing a row is a name, an address and a username out of `servers.json`.
 * Opening one is a press, and a press is what buys the SSH round trip that says
 * which agents are on it and which of them are signed in. Closing the pane hangs
 * up again.
 *
 * So a closed row makes no claim at all about that server, which is the honest
 * state — the alternative is a page that either dials four machines because
 * somebody opened Settings, or prints "probably fine" beside a machine it has
 * not spoken to.
 *
 * ## Signing in happens here now, and how
 *
 * It used to not. This pane drew a notice saying *"Machines → the server → Set
 * up is where that is done"*, and the reason was real: `servers:setup:signin`
 * takes a **shell id**, because two of the three logins are interactive flows
 * that finish in a terminal — one shows a one-time code, one runs its whole
 * sign-in inside its own full-screen interface. A settings pane has no
 * terminal, so there was nothing honest to point a Sign in button at.
 *
 * The answer was not to build a second sign-in. It was to notice that the panel
 * which already does this — `ServerSetup` — needs a server, a bridge and a
 * connection, and this pane opens all three the moment somebody expands a row.
 * So the row draws that panel, terminal and all. One flow, one set of
 * sentences, one place to fix it, and *"login, logout, things, access… all of
 * this we can just manage from this"* is true of the pane rather than delegated
 * out of it.
 *
 * What is still genuinely absent is a **sign-out**: nothing in
 * `src/main/servers/` exposes one, and a server session runs as whatever login
 * that server's own home directory holds, so there is no per-session account to
 * switch either. That absence is a gap in the wiring, and this pane states it
 * rather than drawing a control for it.
 */
export function ServerAccounts() {
  const { wired, missing, servers, bridge, reading, problem } = useServers()

  /** Which server rows have been opened, and what came back for each. */
  const [looks, setLooks] = useState<Record<string, ServerLook>>({})
  /*
   * The servers this pane dialled, so it can hang up on the way out.
   *
   * A ref rather than the state, because the cleanup runs after the last
   * render and would otherwise close whatever was open two renders ago.
   */
  const opened = useRef(new Set<string>())

  useEffect(() => {
    const open = opened.current
    const hangUp = bridge?.closeServer
    return () => {
      // Only the ones this pane opened. A server whose own page is on screen
      // behind the sheet is not ours to disconnect.
      for (const id of open) void hangUp?.(id).catch(() => undefined)
      open.clear()
    }
  }, [bridge])

  const look = useCallback(
    (server: Server) => {
      if (!bridge) return
      if (opened.current.has(server.id)) return
      opened.current.add(server.id)
      setLooks((current) => ({ ...current, [server.id]: { state: 'looking' } }))
      void bridge.lookAtServer(server.id).then(
        (raw) => {
          const view = asView(raw)
          setLooks((current) => ({
            ...current,
            [server.id]: view
              ? { state: 'ready', view }
              : { state: 'failed', problem: `${server.name} answered with something this build cannot read.` },
          }))
        },
        (cause: unknown) => {
          opened.current.delete(server.id)
          setLooks((current) => ({
            ...current,
            [server.id]: {
              state: 'failed',
              problem:
                cause instanceof Error && cause.message
                  ? cause.message
                  : `${server.name} did not answer.`,
            },
          }))
        },
      )
    },
    [bridge],
  )

  if (!wired) {
    return (
      <Notice tone="warn">
        This window was opened without the server channels{missing.length > 0 ? ` (${missing.join(', ')})` : ''}, so
        there is nothing here to read.
      </Notice>
    )
  }

  if (problem) return <Notice tone="error">{problem}</Notice>
  if (reading && servers.length === 0) {
    return <p className="settings-prose">Reading your servers…</p>
  }
  if (servers.length === 0) return <p className="settings-prose">No servers yet.</p>

  return (
    <>
      {/* Said once, at the top, about the one thing this pane genuinely cannot
          do — see the header. Never a dead button per row. */}
      <Notice tone="info">
        Opening a server here connects to it and reads what it has. Setting an agent up and signing
        it in both work from the row; signing one out does not, because nothing on this side can ask
        a server to forget a login it holds.
      </Notice>

      {servers.map((server) => (
        <details
          key={server.id}
          className="settings-server"
          /* The press that buys the round trip. `open` is read off the element
             rather than tracked here, because a `<details>` is the state — and
             `look` refuses a second call for a server already dialled, so
             opening and closing a row does not reconnect it. */
          onToggle={(event) => {
            if (event.currentTarget.open) look(server)
          }}
        >
          <summary>
            <span className="settings-server-name">{server.name}</span>
            {/* The address, because two servers can be called the same thing and
                the address is what tells them apart — the same argument the
                account rows make for printing a login rather than a slug. */}
            <span className="settings-server-where">
              {server.username} at {server.address}
            </span>
          </summary>
          <ServerLogins name={server.name} look={looks[server.id]} />
          {/*
            The same panel the server's own page draws, not a copy of it.
            `connected` is true only once this row's own round trip landed,
            which is exactly the condition that panel already means by it —
            nothing is asked of a server this pane has not reached.
          */}
          <ServerSetup
            server={server}
            bridge={bridge}
            connected={looks[server.id]?.state === 'ready'}
          />
        </details>
      ))}
    </>
  )
}

/**
 * Where one server's row has got to. Nothing at all until it is opened.
 *
 * Exported because {@link ServerLogins} is drawn by two panes now — this one,
 * where a row is opened by pressing it, and Settings → Servers, where the pill
 * decides — and the second of those composes this out of a `ServerState` rather
 * than out of its own request. A type both of them can name is what keeps the
 * list one component instead of two.
 */
export type ServerLook =
  | { state: 'looking' }
  | { state: 'ready'; view: ServerView }
  | { state: 'failed'; problem: string }

/**
 * One server's agents, split the way the account list on this machine is split.
 *
 * *"Whatever is not install or login should be separate, and all the login ones
 * should be separate."* The same three runs and the same words, because a
 * server's accounts and this machine's accounts are the same question asked of
 * two computers, and two vocabularies for it on one pane is the thing the
 * recording keeps catching.
 *
 * The third run is not padding. `probe.sh` can only ask Claude Code whether it
 * is signed in — the other two have no status command — so `unknown` is the
 * answer for most agents on most servers, and filing that under "not signed in"
 * would be this app inventing a state for somebody's machine.
 */
export function ServerLogins({ name, look }: { name: string; look: ServerLook | undefined }) {
  if (!look) return null
  if (look.state === 'looking') return <p className="settings-prose">Asking {name}…</p>
  if (look.state === 'failed') return <Notice tone="error">{look.problem}</Notice>

  const fact = look.view.facts.agents
  if (!fact) {
    return <p className="settings-prose">{name} was not asked about coding agents.</p>
  }
  if (fact.known === 'cannot') {
    return <p className="settings-prose">{fact.why}</p>
  }

  const found = fact.known === 'yes' ? fact.value : []
  const runs = serverAgentRuns(found)

  return (
    <>
      {runs.map((run) => (
        <div key={run.id} className="settings-account-run" data-run={run.id}>
          <h5 className="settings-account-run-title">{RUN_TITLE[run.id]}</h5>
          <ul className="settings-profiles">
            {run.agents.map((row) => (
              <li key={row.id} className="settings-profile">
                <span className="settings-profile-main">
                  <span className="settings-profile-name">
                    <ProviderBadge provider={row.id as ProviderId} />
                    {AGENT_CATALOG[row.id as ProviderId]?.label ?? row.id}
                    {row.version !== '' && (
                      <span className="settings-badge quiet">{row.version}</span>
                    )}
                  </span>
                  <span className="settings-account-state" data-state={row.state}>
                    <span className="settings-account-mark" aria-hidden="true" />
                    <span>{row.line}</span>
                  </span>
                </span>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </>
  )
}

/** One agent on one server, as a row. */
export interface ServerAgentRow {
  id: string
  version: string
  /** The same vocabulary the local rows use, for the same mark and colour. */
  state: 'signed-in' | 'signed-out' | 'unknown'
  line: string
}

/**
 * The agents of one server, gathered into the three runs.
 *
 * Every agent this app knows is listed, including the ones the server does not
 * have: *"whatever is not install"* is half of the sentence this splits on, and
 * an agent that is simply absent from the list is indistinguishable from one
 * the probe forgot to look for.
 *
 * A pure function, because the interesting rows — an agent installed and
 * broken, one whose sign-in cannot be asked about — are answers from a machine
 * nobody has in front of them.
 */
export function serverAgentRuns(
  found: readonly AgentOnServer[],
): { id: AccountRun['id']; agents: ServerAgentRow[] }[] {
  const rows = AGENT_IDS.map((id): ServerAgentRow => {
    const agent = found.find((entry) => entry.id === id)
    if (!agent) return { id, version: '', state: 'signed-out', line: 'Not installed' }
    // An empty version is not missing data: the binary is there and would not
    // answer, which is a different thing to be told than "not installed".
    const broken = agent.version === ''
    if (agent.signedIn === 'yes') {
      return {
        id,
        version: agent.version,
        state: 'signed-in',
        line: agent.account === null ? 'Signed in' : `Signed in as ${agent.account}`,
      }
    }
    if (agent.signedIn === 'no') {
      return {
        id,
        version: agent.version,
        state: 'signed-out',
        line: broken ? 'Installed, and would not start' : 'Not signed in',
      }
    }
    return {
      id,
      version: agent.version,
      state: 'unknown',
      line: broken
        ? 'Installed, and would not start'
        : 'Installed. This agent has no way to be asked whether it is signed in.',
    }
  })

  const runOf = (row: ServerAgentRow): AccountRun['id'] =>
    row.state === 'signed-in'
      ? 'signed-in'
      : row.state === 'unknown'
        ? 'not-answered'
        : 'not-signed-in'

  const order: AccountRun['id'][] = ['signed-in', 'not-signed-in', 'not-answered']
  return order.flatMap((id) => {
    const mine = rows.filter((row) => runOf(row) === id)
    return mine.length === 0 ? [] : [{ id, agents: mine }]
  })
}
