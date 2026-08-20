import { useCallback, useEffect, useMemo, useState } from 'react'
import { Button } from '../../settings/controls'
import { ServerTerminal } from './ServerTerminal'
import { asSetupOffer, asSetupState, succeeded } from './types'
import type { AgentId, Server, ServersBridge, SetupOffer, SetupRow, SetupState } from './types'

/**
 * Setting an agent up on a server: three rows, no favourite, two presses each.
 *
 * ## Why it is three rows and not one
 *
 * Because it shipped as one on 2026-08-19 — Claude Code, and nothing else on
 * screen — and he overruled it the same night:
 *
 *   > *"where we can have an option between Claude, Codex, Gemini, in those
 *   > places don't name only Claude. Give all the options, so they don't feel
 *   > like it is all about Claude. Maybe some users are only using Codex, they
 *   > never use Claude."*
 *
 * So the heading is about the category — *"Coding agents"* — and the three names
 * appear only as the rows they belong to, which is the permitted case: a row
 * that *is* Claude Code says Claude Code, because neutralising it would delete
 * the only information on the row. What is deliberately absent is any ordering
 * by preference, any "recommended", and any wording that makes two of them read
 * as alternatives to the first.
 *
 * The probe has always found all three; it was this screen that threw two away.
 *
 * ## Why it is a section and not three cards
 *
 * Because each row is a fact about the machine rather than a thing running on
 * it. Zone two is *"the things they own"* — a site, an app, a database — and a
 * coding assistant is none of those; it is a property of the sign-in, like the
 * account name above it. Putting these in zone two would give each one a Restart
 * button it has no use for and file it beside somebody's website.
 *
 * ## What is drawn per row, and what is deliberately absent
 *
 * Four states and no fifth, and the fifth is the one that matters:
 *
 *  - not there, and this server could take it — the line, and **Set it up**;
 *  - there and signed in — the line, and no button at all;
 *  - there and not signed in — the line, and **Sign in**;
 *  - **we could not tell** — the reason, and *no button*.
 *
 * That last one is the whole of §3.1 in one control. The measured failure it
 * exists for: the way this app looks for an assistant has to widen the search
 * beyond what a plain command can see, because none of the three installs
 * somewhere a non-interactive sign-in can find by default. When the check itself
 * could not run, offering to install would be offering to write hundreds of
 * megabytes over somebody's working install. So a check that did not run draws
 * its own sentence and nothing else — §4.1, *"a control that cannot act is
 * removed, or disabled with a stated reason. Never drawn hopefully."*
 *
 * A row whose agent this *particular* server cannot take — no npm for the two
 * that need one — keeps its line and its reason and loses its button. It is
 * still on screen, because "this server has no npm" is a fact somebody can act
 * on, and a row that vanished would look like an app that only knows one agent.
 *
 * ## Why the terminal is here rather than in the rail
 *
 * The install types a real command into a real terminal and the person watches
 * the installer's own output go past. That is the honest progress bar, and it is
 * the same argument `connection.ts` makes about landing a session in a folder:
 * *"the line is echoed by the far end, so it is visible in the scrollback rather
 * than hidden."* A spinner over a hidden command would be this app claiming to
 * know how far along something is when all it knows is that it has not finished.
 *
 * It matters more here than it did with one agent, because two of the three
 * sign-ins **finish in that terminal**: one shows a one-time code to type on the
 * page this app opens, and one runs its whole sign-in inside its own screen. The
 * terminal is not a progress indicator for those — it is where the person works.
 *
 * There is one terminal for the whole section rather than one per row, which is
 * what makes "only one setup at a time" true rather than merely hoped for; the
 * far end keys its attempts the same way.
 *
 * ## Every sentence on screen was written on the other side
 *
 * `row.consequence`, `row.why`, `row.label` and `state.line` all come from
 * `servers/setup.ts`, beside the code that performs the work — §4.3. Nothing
 * here composes one, for the reason `types.ts` gives: a screen that wrote its
 * own would be describing work it does not do, and the two would drift. That
 * includes the agents' names: this file does not spell one anywhere.
 */
export function ServerSetup({
  server,
  bridge,
  connected,
}: {
  server: Server
  bridge: ServersBridge | null
  /** False while the page is still dialling. Nothing is asked of a server we have not reached. */
  connected: boolean
}) {
  const [offer, setOffer] = useState<SetupOffer | null>(null)
  const [states, setStates] = useState<Partial<Record<AgentId, SetupState>>>({})
  const [asking, setAsking] = useState<AgentId | null>(null)
  const [running, setRunning] = useState<{ agentId: AgentId; want: 'install' | 'sign-in' } | null>(null)
  const [refusal, setRefusal] = useState('')

  const look = useCallback(() => {
    if (!bridge?.serverSetup) return
    void bridge.serverSetup(server.id).then((raw) => {
      if (!succeeded(raw)) return
      const read = asSetupOffer(raw)
      if (read === null) return
      setOffer(read)
      // Seeded from the same answer rather than left empty, so a setup that was
      // already in flight when this panel opened shows its line immediately
      // instead of after the next push.
      setStates(Object.fromEntries(read.rows.map((row) => [row.agentId, row.state])))
    })
  }, [bridge, server.id])

  useEffect(() => {
    if (connected) look()
  }, [connected, look])

  /*
   * The push, not a timer. An install takes as long as it takes and a sign-in
   * waits on a person in a browser window, so neither of them ends at a moment
   * this side could have asked about — which is his standing rule paid in the
   * one place on this page where something genuinely changes while nobody
   * presses anything.
   *
   * Every push names its row. Three rows are on screen and any of them can be
   * the one that moved, so a push with no name on it would light up whichever
   * row happened to be drawn first.
   */
  useEffect(() => {
    if (!bridge?.onServerSetup) return
    return bridge.onServerSetup((raw) => {
      const read = asSetupState(raw)
      if (read === null || read.serverId !== server.id) return
      setStates((was) => ({ ...was, [read.agentId]: read }))
      // Done, or given up on: what is installed has changed, so the lines above
      // are now describing a server that no longer exists.
      if (read.step === 'done' || read.step === 'idle') look()
    })
  }, [bridge, server.id, look])

  const begin = useCallback(
    (shellId: string) => {
      if (!bridge || running === null) return
      const call =
        running.want === 'install'
          ? bridge.installOnServer?.(server.id, running.agentId, shellId)
          : bridge.signInOnServer?.(server.id, running.agentId, shellId)
      if (call === undefined) return
      void call.then((raw) => {
        if (succeeded(raw)) return
        setRefusal(readSentence(raw))
      })
    },
    [bridge, server.id, running],
  )

  const stop = useCallback(() => {
    setRunning(null)
    setRefusal('')
    void bridge?.cancelServerSetup?.(server.id)
  }, [bridge, server.id])

  const rows = useMemo(() => offer?.rows ?? [], [offer])

  if (bridge === null || bridge.serverSetup === undefined) return null
  if (offer === null || rows.length === 0) return null

  return (
    <section className="servers-setup">
      {/* The category, not one of its members. The names live on the rows. */}
      <h3 className="servers-setup-heading">Coding agents</h3>

      {rows.map((row) => (
        <AgentRow
          key={row.agentId}
          row={row}
          state={states[row.agentId] ?? row.state}
          busy={running !== null}
          mine={running?.agentId === row.agentId}
          asking={asking === row.agentId}
          onAsk={() => setAsking(row.agentId)}
          onCancelAsk={() => setAsking(null)}
          onInstall={() => {
            setAsking(null)
            setRefusal('')
            setRunning({ agentId: row.agentId, want: 'install' })
          }}
          onSignIn={() => {
            setRefusal('')
            setRunning({ agentId: row.agentId, want: 'sign-in' })
          }}
          onRemove={() => {
            void bridge.removeServerSetup?.(server.id, row.agentId).then(look, look)
          }}
          onStop={stop}
        />
      ))}

      {refusal !== '' && <p className="servers-card-why">{refusal}</p>}

      {running !== null && (
        <div className="servers-setup-terminal">
          <ServerTerminal serverId={server.id} bridge={bridge} onOpened={begin} onEnded={stop} />
        </div>
      )}
    </section>
  )
}

/**
 * One agent's row.
 *
 * `busy` and `mine` are separate on purpose. While anything is running there is
 * one terminal in use, so the other two rows must not offer a button that would
 * take it — but they still show their own line, because a person watching an
 * install wants to see that the other two are still there and still theirs to
 * set up next.
 */
function AgentRow({
  row,
  state,
  busy,
  mine,
  asking,
  onAsk,
  onCancelAsk,
  onInstall,
  onSignIn,
  onRemove,
  onStop,
}: {
  row: SetupRow
  state: SetupState
  busy: boolean
  mine: boolean
  asking: boolean
  onAsk: () => void
  onCancelAsk: () => void
  onInstall: () => void
  onSignIn: () => void
  onRemove: () => void
  onStop: () => void
}) {
  const agent = row.installed
  const idle = !busy

  return (
    <div className="servers-setup-row">
      <div className="servers-setup-top">
        <p className="servers-setup-say">{lineFor(row, state)}</p>
        <div className="servers-setup-ask">
          {idle && agent === null && row.canInstall && (
            <Button tone="primary" onClick={onAsk}>
              Set it up
            </Button>
          )}
          {idle && agent !== null && agent.version !== '' && agent.signedIn !== 'yes' && (
            <Button tone="primary" onClick={onSignIn}>
              Sign in
            </Button>
          )}
          {idle && agent !== null && agent.version === '' && row.canInstall && (
            /*
             * Found, and it will not start. A different offer from a first
             * install and it has to be: this person has something broken rather
             * than nothing, and "Set it up" would read as though the app had not
             * noticed what is already there.
             */
            <Button onClick={onAsk}>Install it again</Button>
          )}
          {mine && <Button onClick={onStop}>Stop</Button>}
          {idle && state.weInstalled && agent !== null && (
            <Button tone="danger" onClick={onRemove}>
              Remove what was installed
            </Button>
          )}
        </div>
      </div>

      {/* The reason there is no button, in the server's own terms. Never a
          greyed control with nothing to say for itself. */}
      {idle && agent === null && row.why !== null && <p className="servers-card-why">{row.why}</p>}
      {state.detail !== '' && <p className="servers-card-why">{state.detail}</p>}

      {asking && (
        <div className="servers-setup-ask-first">
          {/* Written where the work is implemented, and rendered here unchanged. */}
          <p className="settings-prose">{row.consequence}</p>
          <div className="servers-card-actions">
            <Button tone="primary" onClick={onInstall}>
              Install
            </Button>
            <Button onClick={onCancelAsk}>Cancel</Button>
          </div>
        </div>
      )}
    </div>
  )
}

/**
 * The one line for a row, and which of the two sources it comes from.
 *
 * While something is happening the flow's own line wins, because it is the more
 * specific of the two and it is the one that changes. Between attempts the
 * standing description wins, because *"Installing…"* left on screen after an
 * install finished is the page describing work that has stopped.
 *
 * The name in every branch is `row.label`, which came off the far end. This file
 * spells no agent's name, so a fourth row is a change in one table rather than a
 * change here.
 */
function lineFor(row: SetupRow, state: SetupState): string {
  if (state.step !== 'idle' && state.line !== '') return state.line
  const agent = row.installed
  if (agent === null) return `${row.label} isn’t set up on this server yet.`
  if (agent.version === '') return `${row.label} is on this server but won’t start.`
  if (agent.signedIn === 'yes') {
    return agent.account === null
      ? `${row.label} ${agent.version}, signed in.`
      : `${row.label} ${agent.version}, signed in as ${agent.account}.`
  }
  if (agent.signedIn === 'no') return `${row.label} ${agent.version} — not signed in.`
  return `${row.label} ${agent.version} is here.`
}

/** The refusal's own sentence, which is the one written where the refusal happened. */
function readSentence(raw: unknown): string {
  if (typeof raw !== 'object' || raw === null) return 'That did not work.'
  const said = (raw as { sentence?: unknown }).sentence
  return typeof said === 'string' && said !== '' ? said : 'That did not work.'
}
