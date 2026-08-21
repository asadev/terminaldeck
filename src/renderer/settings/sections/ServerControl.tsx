import { useCallback, useEffect, useState } from 'react'
import { Button, Group, Notice, Row, SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'
import { ScopeSwitch, serverOfScope, serverScope, type AgentScope } from './AgentsSection'
import { ServerLogins, type ServerLook } from './ServerAccounts'
import {
  credentialLine,
  identityLine,
  ServerCopilotGrant,
  ServerDrivesWindows,
} from '../../machines/servers/ServerAdvanced'
import { ServerFolderPicker } from '../../machines/servers/ServerFolderPicker'
import { ServerHost } from '../../machines/servers/ServerHost'
import { ServerSetup } from '../../machines/servers/ServerSetup'
import { useServerRoom, useServers } from '../../machines/servers/useServers'
import { asGrant } from '../../machines/servers/types'
import type { GrantState, Server, ServerState, ServersBridge } from '../../machines/servers/types'
import { controlsIn, type ServerControlEntry, type ServerGroup } from './server-scope'
import { useAt } from '../../schedule'
/*
 * The servers area's own stylesheet, imported here as well as by `MachinesPanel`
 * and `ServerAccounts`. Settings is a separate entry point, so a stylesheet only
 * the machines panel imports is one this window does not necessarily load — and
 * the failure mode is an unstyled install panel rather than an error. The
 * bundler dedupes the second import.
 */
import '../../machines/servers/servers.css'

/**
 * One server, as a settings pane: a pill naming which, and under it the same
 * shape of settings this window holds for the machine it is running on.
 *
 * ## What was here
 *
 * Nothing. Servers reached Settings exactly once — as the `servers` scope on
 * Coding AI, which lists the coding logins on all of them — and everything else
 * a server is set to do lived behind an **Advanced** door on that server's own
 * page in the Machines panel. So the answer to *"what is this server set to
 * do"* was on a screen you get to by leaving Settings.
 *
 *   > *"build a proper version for scrapping and server control with switching
 *   > pill just like in coding ai page in settings but build proper settings
 *   > inside too exactly like local machine, exactly means exactly and all other
 *   > applicaple places too"*
 *
 * ## Exactly means exactly, and where it cannot, it says why
 *
 * The pane runs in the rail's own order — what runs your sessions, where they
 * start, the browser, the copilot, keeping it on, and the machine's own record.
 * Every control it draws is live and writes something. Where a server genuinely
 * cannot carry one of this machine's, the group says so in a sentence naming the
 * reason and draws no control at all: a control that is drawn and inert costs a
 * click to discover the lie, which is worse than an absence with a reason.
 *
 * The comparison in full — every control this window offers for this machine,
 * whether a server can carry it, and for each *cannot* the file that decides it
 * — is `SERVER_CONTROLS` in `server-scope.ts`. The three sentences on this pane
 * are that table's, not a second telling of it.
 *
 * ## Assembled, not rewritten
 *
 * Six of the controls here are the *same components* the server's own page
 * draws — the setup panel, the host panel, the two permissions, the folder
 * picker, the login list. That is the answer to the risk this reorganisation
 * always carries — *"when you reorganize you mostly miss the things and you drop
 * some stuff"* — because nothing was re-typed to be moved, so nothing could be
 * lost in the typing, and neither screen can drift from the other.
 *
 * ## Nothing is dialled until a server is on screen
 *
 * `useServerRoom` is the connection a server's own page opens: it dials when
 * this pane has that server selected and hangs up when the selection changes or
 * the window closes. Switching the pill closes one connection and opens another;
 * a settings window nobody opened holds none. The controls that write to *this*
 * computer's record — the two permissions, the default folder, the name,
 * forgetting it — do not wait for it, because none of them asks the server
 * anything.
 */
export function ServerControlSection({ supplied }: { supplied?: ServersBridge } = {}) {
  const { wired, missing, servers, bridge, reading, problem, reread } = useServers(supplied)

  const [scope, setScope] = useState<AgentScope>('this-machine')
  /*
   * Which server the pill is on, *derived* rather than stored.
   *
   * `AgentsSection` repairs a scope pointing at a machine that has gone with an
   * effect, and the effect below does the same job for the same reason — every
   * button reading `aria-pressed="false"` is a segmented control with nothing
   * selected. What is different here is that a server can be forgotten *from
   * this pane*, so the fallback has to be in hand for the very render that
   * follows the press. Deriving it means there is no frame in which this pane
   * draws nothing beneath a switch pointing at a machine that is gone.
   */
  const chosen = chosenServer(servers, scope)

  useEffect(() => {
    if (chosen === null) return
    if (scope === serverScope(chosen.id)) return
    setScope(serverScope(chosen.id))
  }, [chosen, scope])

  /*
   * What that server said, held here rather than inside a group so it survives
   * the panels below re-rendering.
   *
   * Checked against the selection before it is drawn: between the press that
   * moves the pill and the effect that dials the next server, this still holds
   * the previous one's answer, and drawing that under the new server's name
   * would be this pane attributing one machine's logins to another.
   */
  const [state, setState] = useState<ServerState | null>(null)
  useServerRoom(bridge, chosen?.id ?? null, setState)
  const room = state !== null && chosen !== null && state.id === chosen.id ? state : null

  /*
   * Now, moved when something on screen would start reading wrong, and never on
   * a timer. One thing here ages — the copilot's permission — and it has an
   * exact expiry, so this is a single scheduled wake at that moment. The same
   * arrangement `MachinesPanel` makes for the same fact.
   */
  const [now, setNow] = useState(() => Date.now())
  useAt(room?.grant?.expiresAt ?? null, () => setNow(Date.now()))

  const readGrant = useCallback(() => {
    if (!bridge || chosen === null) return
    const id = chosen.id
    setNow(Date.now())
    void bridge.serverGrantState(id).then(
      (raw) => {
        setState((before) =>
          before !== null && before.id === id ? { ...before, grant: asGrant(raw) } : before,
        )
      },
      // A permission that could not be read is left as it was rather than drawn
      // as absent: inventing "no grant" here would show a permission as off that
      // may well be on.
      () => undefined,
    )
  }, [bridge, chosen])

  return (
    <ServerControlView
      wired={wired}
      missing={missing}
      reading={reading}
      problem={problem}
      servers={servers}
      chosen={chosen}
      scope={scope}
      onScope={setScope}
      look={lookOf(chosen, room)}
      connected={room?.link === 'ready'}
      failure={room?.link === 'failed' ? (room.problem ?? `${chosen?.name} did not answer.`) : null}
      grant={room?.grant ?? null}
      now={now}
      bridge={bridge}
      onGrant={(forMs) => {
        if (!bridge || chosen === null) return
        void bridge.grantServerCopilot(chosen.id, forMs).then(readGrant, readGrant)
      }}
      onRevoke={() => {
        if (!bridge || chosen === null) return
        void bridge.revokeServerCopilot(chosen.id).then(readGrant, readGrant)
      }}
      onStored={reread}
    />
  )
}

/**
 * Which server the pill is on, given the list and the scope.
 *
 * Pure and exported for the reason `hostControls` is: it is the one *decision*
 * on this pane rather than a piece of layout, and the state that matters — a
 * scope naming a server that has just been forgotten — is a state a rendered
 * test cannot reach by pressing anything.
 *
 * Deriving rather than storing is what makes the repair free. `AgentsSection`
 * fixes the same situation with an effect, which is right there because a
 * device disappears from a push nobody on that pane caused; here the **Forget**
 * button is on this pane, so a stored selection would leave one render drawing
 * nothing under a switch pointing at a machine that is gone.
 */
export function chosenServer(servers: readonly Server[], scope: AgentScope): Server | null {
  const wanted = serverOfScope(scope)
  return servers.find((row) => row.id === wanted) ?? servers[0] ?? null
}

/**
 * What one server said, in the shape the login list already takes.
 *
 * A function rather than a branch inside the component so that the mapping from
 * *a connection* to *a list's four states* is one thing with one place to be
 * wrong. `ServerAccounts` produces the same shape from its own request; this
 * produces it from a `ServerState`, and both hand it to one component.
 */
export function lookOf(server: Server | null, room: ServerState | null): ServerLook | undefined {
  if (server === null || room === null) return undefined
  if (room.link === 'connecting') return { state: 'looking' }
  if (room.link === 'failed') {
    return { state: 'failed', problem: room.problem ?? `${server.name} did not answer.` }
  }
  return room.view === undefined ? undefined : { state: 'ready', view: room.view }
}

export interface ServerControlViewProps {
  /** False when this build's preload carries no server channels at all. */
  wired: boolean
  /** Which channels a half-wired build is missing, so a notice can name them. */
  missing: readonly string[]
  /** True until the first read of the stored list has settled. */
  reading: boolean
  /** Why the list could not be read, in a sentence. */
  problem: string | null
  servers: readonly Server[]
  /** The one the pill is on. Null only when there are none. */
  chosen: Server | null
  scope: AgentScope
  onScope(next: AgentScope): void
  /** What the chosen server said, or undefined before it has been asked. */
  look: ServerLook | undefined
  /** True once this pane has actually reached it. Panels ask nothing before it. */
  connected: boolean
  /** The sentence for a server that would not answer, or null. */
  failure: string | null
  grant: GrantState | null
  now: number
  bridge: ServersBridge | null
  onGrant(forMs: number): void
  onRevoke(): void
  /** Something was written to this computer's own record; re-read the list. */
  onStored(): void
}

/**
 * Everything this pane draws, taking everything it draws.
 *
 * Split from the fetching for the reason `PowerView` and `hostControls` are:
 * `renderToStaticMarkup` never runs an effect, so a component that read its own
 * answers would be testable in exactly one state — the empty one — and the
 * states that matter here are a server that has not answered, one that refused,
 * one with three logins, and one this build cannot reach at all.
 */
export function ServerControlView({
  wired,
  missing,
  reading,
  problem,
  servers,
  chosen,
  scope,
  onScope,
  look,
  connected,
  failure,
  grant,
  now,
  bridge,
  onGrant,
  onRevoke,
  onStored,
}: ServerControlViewProps) {
  const meta = sectionMeta('servers')

  if (!wired) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        {/* Half-wired is worse than unwired, because it looks like it works —
            so the missing channels are named when only some of them are. */}
        <Notice tone="warn">
          This window was opened without the server channels
          {missing.length > 0 ? ` (${missing.join(', ')})` : ''}, so there is nothing here to read.
        </Notice>
      </>
    )
  }

  if (chosen === null) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        {problem !== null && <Notice tone="error">{problem}</Notice>}
        <p className="settings-prose">
          {reading ? 'Reading your servers…' : 'No servers yet. Machines is where one is added.'}
        </p>
      </>
    )
  }

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />
      {problem !== null && <Notice tone="error">{problem}</Notice>}

      {/*
        The pill, naming the machines themselves — and no *This machine* button,
        because every control below it is a property of one server and there is
        nothing on this pane that a local machine could be asked.
      */}
      <ScopeSwitch
        scope={scope}
        fixed={[]}
        servers={servers.map((row) => ({ id: row.id, name: row.name }))}
        label="Which server these settings are for"
        onScope={onScope}
      />

      {failure !== null && <Notice tone="error">{failure}</Notice>}

      <Group title={`Accounts on ${chosen.name}`}>
        <ServerLogins name={chosen.name} look={look} />
      </Group>

      {/*
        The four Coding AI offers this machine that a server cannot take: the
        tool picker, the account picker, signing out, and a second account.

        Under the list rather than over it, which is the one place this pane does
        not mirror the local pane's order. There the two pickers come first
        because they are the controls; here they are four lines of *not here*,
        and opening a pane with them would be four apologies before a single
        fact. They are still directly beside the accounts they are about.
      */}
      <Group>
        <NotHere group="coding" />
      </Group>

      {/* The install and sign-in flows, terminal and all: the same panel the
          server's own page draws and the Coding AI pane's servers scope draws.
          Not a second copy of either. */}
      <ServerSetup server={chosen} bridge={bridge} connected={connected} />

      <Group title="Where sessions start">
        {/*
          The picker with no session behind it, which is what makes it a setting
          rather than a choice: the tick inside its window writes this server's
          default, and *Use this folder* is not drawn at all, because there is
          nothing on this pane for a one-off choice to be about.
        */}
        <ServerFolderPicker
          serverId={chosen.id}
          serverName={chosen.name}
          bridge={bridge}
          path={null}
        />
      </Group>

      <Group>
        <ServerDrivesWindows
          server={chosen}
          disabled={bridge === null}
          {...(bridge?.setServerDrivesWindows === undefined
            ? {}
            : {
                onChange: (allowed: boolean) => {
                  // The stored list is what this switch and the server's own
                  // page both read, so the answer is re-read rather than assumed
                  // from the press.
                  void bridge.setServerDrivesWindows?.(chosen.id, allowed).then(onStored, onStored)
                },
              })}
        />
        {/*
          After the control, which is this pane's rule everywhere except one
          place: the live control first, then the line naming what this machine
          has that a server does not. The exception is the copilot below, where
          the control could be *mistaken* for the missing one, so the sentence
          goes first and rules that reading out.
        */}
        <NotHere group="browser" />
      </Group>

      <Group>
        {/* Said above the control, because the control underneath is about
            *this* computer's copilot reaching over, and somebody looking for a
            Copilot pane for their server is entitled to know there is not one
            rather than to read this as the same thing. */}
        <NotHere group="copilot" />
        <ServerCopilotGrant
          grant={grant}
          now={now}
          disabled={bridge === null}
          onGrant={onGrant}
          onRevoke={onRevoke}
        />
      </Group>

      {/* The Power pane's question, asked of a machine with no lid: whether
          anything of ours is on it, and whether it survives a restart. Both
          lines are written in `main/servers/host.ts` beside the code that
          installs it — `hostLine` and `reachLine` — and rendered unchanged. */}
      <ServerHost server={chosen} bridge={bridge} connected={connected} />
      <Group>
        <NotHere group="power" />
      </Group>

      <ServerRecord server={chosen} bridge={bridge} onStored={onStored} />

      {/* Last, because these are the two nobody comes looking for and both are
          worth knowing once: a terminal on a server is not brought back, and
          nothing here is watching one closely enough to interrupt you about it. */}
      <Group title="What a session on a server does not get">
        <NotHere group="sessions" />
      </Group>
    </>
  )
}

/**
 * The controls this window offers for **this** machine that a server cannot
 * take, said where somebody would look for them.
 *
 * ## Why a labelled list and not paragraphs, and not disabled rows
 *
 * Three shapes were available and two of them are already ruled out in this
 * window.
 *
 *  - **A disabled control with the reason underneath** is what Power shipped
 *    once and removed: *"a disabled control is still a description of a
 *    feature"*, and here it would be worse, because the feature it describes is
 *    one that cannot exist on this machine at all.
 *  - **A row whose value is a constant** is ruled out by
 *    `no-contradictions.test.tsx` — *"a row that can only ever state a constant
 *    is not a row"* — and four of them in a column would read as four settings
 *    somebody has to work out are not settings.
 *  - **Paragraphs** are what this window spent a whole pass deleting: *"we don't
 *    have to give this big descriptions… one liner or two liner"*.
 *
 * What is left is the shape that instruction actually describes: a name, and one
 * line beside it. Nothing here is hoverable, focusable or clickable, so nothing
 * about it invites a press — which is the whole difference between an absence
 * and a dead control.
 *
 * Every sentence comes from `SERVER_CONTROLS`, where it is traced to the file
 * that decides it, so a claim on this screen cannot outlive the code that made
 * it true.
 */
export function NotHere({ group }: { group: ServerGroup }) {
  const entries: ServerControlEntry[] = controlsIn(group)
  if (entries.length === 0) return null
  return (
    <ul className="settings-absent">
      {entries.map((entry) => (
        <li key={entry.local}>
          <span className="settings-absent-name">{entry.local}</span>
          <span className="settings-absent-why">{entry.say}</span>
        </li>
      ))}
    </ul>
  )
}

/**
 * What this computer keeps about one server: the four facts, the name it is
 * filed under here, and the way to forget it.
 *
 * ## Why the facts are rows and their paragraphs are not here
 *
 * Every value on these rows is *data* — an address, a login name, which kind of
 * secret is sealed, the identity the server answered with — so each is a row
 * with something in it rather than a constant with a label. What does not come
 * with them is the two paragraphs the server's own page prints above them,
 * arguing why an identity cannot be waved past: that argument is read by
 * somebody who is looking at an identity **because something went wrong**, and
 * ninety words of it on a settings pane would be the wall this window spent a
 * whole pass removing. It is behind the ⓘ on the row it belongs to, which is
 * this window's own answer to exactly that trade.
 *
 * `credentialLine` and `identityLine` are the page's own composers, imported
 * rather than re-typed, so two screens cannot come to describe one sealed key
 * differently.
 */
export function ServerRecord({
  server,
  bridge,
  onStored,
}: {
  server: Server
  /** Null when this build has no server channels; then nothing here can act. */
  bridge: ServersBridge | null
  onStored(): void
}) {
  const [name, setName] = useState(server.name)
  const [confirm, setConfirm] = useState(false)

  /*
   * The box follows the pill. Without this, moving to another server leaves the
   * previous one's name in a field labelled with the new one's — and a press
   * would then rename the wrong machine.
   */
  useEffect(() => {
    setName(server.name)
    setConfirm(false)
  }, [server.id, server.name])

  const rename = (): void => {
    const wanted = name.trim()
    if (bridge === null || wanted === '' || wanted === server.name) return
    // Re-read either way: a rename the store refused has to put the stored name
    // back in the box rather than leave the typed one standing as if it took.
    void bridge.renameServer(server.id, wanted).then(onStored, onStored)
  }

  const forget = (): void => {
    if (bridge === null) return
    void bridge.forgetServer(server.id).then(onStored, onStored)
  }

  return (
    <Group title="This server">
      <Row label="Address" control={<span className="settings-value">{server.address}</span>} />
      <Row
        label="Name you sign in with"
        control={<span className="settings-value">{server.username}</span>}
      />
      <Row
        label="Kept on this computer"
        more="To sign in a different way, forget this server below and add it again. Nothing on the server changes either way."
        control={<span className="settings-value">{credentialLine(server)}</span>}
      />
      <Row
        label="Identity"
        more="Every server has one and it does not change. If it ever does, this app stops and says so rather than signing in. Every other tool prints the same string, so it can be compared against the server itself."
        control={<span className="settings-value">{identityLine(server)}</span>}
      />

      <Row
        label="What to call it here"
        htmlFor="settings-server-name"
        control={
          <span className="servers-card-actions">
            <input
              id="settings-server-name"
              className="settings-input"
              value={name}
              onChange={(event) => setName(event.target.value)}
            />
            <Button onClick={rename} disabled={bridge === null || name.trim() === ''}>
              Save
            </Button>
          </span>
        }
      />

      {confirm ? (
        <div className="servers-card-ask">
          <p className="servers-card-ask-text">
            {/* Not a consequence sentence about the server, because this changes
                nothing out there — it is this app forgetting a row, and beside a
                list of somebody's machines "forget" reads as "delete". */}
            This removes {server.name} from this list and forgets the sign-in kept on this computer.
            Nothing on the server changes, and you can add it again with the same details.
          </p>
          <div className="servers-card-actions">
            <Button tone="danger" onClick={forget}>
              Forget it
            </Button>
            <Button onClick={() => setConfirm(false)}>Cancel</Button>
          </div>
        </div>
      ) : (
        <Row
          label="Forget this server"
          control={
            <Button onClick={() => setConfirm(true)} disabled={bridge === null}>
              Forget it
            </Button>
          }
        />
      )}
    </Group>
  )
}
