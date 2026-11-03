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
  /**
   * Which row is asking to be sure, and about what.
   *
   * Two kinds now. Both are two-press actions with a sentence in between, and
   * both sentences are written on the other side beside the work — so the only
   * thing this has to remember is which of the two the row is in the middle of.
   */
  const [asking, setAsking] = useState<{ agentId: AgentId; want: 'install' | 'sign-out' } | null>(null)
  const [running, setRunning] = useState<{
    agentId: AgentId
    want: 'install' | 'sign-in' | 'sign-out'
  } | null>(null)
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
          : running.want === 'sign-out'
            ? bridge.signOutOnServer?.(server.id, running.agentId, shellId)
            : bridge.signInOnServer?.(server.id, running.agentId, shellId)
      if (call === undefined) {
        /*
         * A preload older than the channel this press needs.
         *
         * It returned here silently, which is a button that opens a terminal
         * and then does nothing at all — the shape of failure this app has been
         * caught with most often. The rows guard their own buttons on the same
         * condition, so this is the belt to that pair of braces rather than the
         * ordinary path, and it says so rather than shrugging.
         */
        setRefusal('This build of the app cannot ask a server to do that.')
        return
      }
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
          asking={asking?.agentId === row.agentId ? asking.want : null}
          /* Both halves, and both are real: this build has to carry the channel
             and that agent has to have a command. Either missing means no
             button, and the second one puts its reason on the row. */
          canSignOut={bridge.signOutOnServer !== undefined && row.whyNoSignOut === null}
          onAsk={(want) => setAsking({ agentId: row.agentId, want })}
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
          onSignOut={() => {
            setAsking(null)
            setRefusal('')
            setRunning({ agentId: row.agentId, want: 'sign-out' })
          }}
          onRemove={() => {
            void bridge.removeServerSetup?.(server.id, row.agentId).then(look, look)
          }}
          onStop={stop}
        />
      ))}

      {refusal !== '' && <p className="servers-card-why">{refusal}</p>}

      {/*
        The one-time code, when the sign-in running below has printed one.

        Above the terminal rather than in it, because in it is where it already
        is and that was the problem: ten characters, painted in a colour, in the
        middle of a scrollback, to be retyped into a browser window that is by
        then covering the terminal. The sentence for it is `state.line`, written
        on the other side beside the flow that produced it; this draws the code
        and the one thing a person can do with it.
      */}
      {running !== null && (states[running.agentId]?.code ?? '') !== '' && (
        <OneTimeCode code={states[running.agentId]?.code ?? ''} />
      )}

      {running !== null && (
        <div className="servers-setup-terminal">
          <ServerTerminal serverId={server.id} bridge={bridge} onOpened={begin} onEnded={stop} />
        </div>
      )}
    </section>
  )
}

/**
 * The code a device sign-in is waiting for, and the one press that moves it.
 *
 * ## Why it is drawn at all
 *
 * Because the alternative is the thing that was there: *"enter the code it
 * shows below"*, over a terminal in which the code is one indented, coloured,
 * ten-character token somewhere in an installer's scrollback — and a browser
 * window has just opened on top of the app. Every part of that is a person
 * doing work this app could have done: finding it, reading it correctly, and
 * typing it into a field on another screen.
 *
 * ## Why Copy is only drawn when it can copy
 *
 * `navigator.clipboard` is not always there — an insecure context, a build
 * where it has been withheld — and a Copy that silently does nothing is exactly
 * the control this app has been caught drawing before. Where there is no
 * clipboard the code is still on screen, still in one piece, and still
 * selectable, which is the honest smaller version of the same help.
 *
 * The state is deliberately momentary and unlabelled beyond the word: nothing
 * here claims the code *was* accepted, only that it was copied. What happens
 * next is on the page the browser opened, and the terminal below says so.
 */
export function OneTimeCode({ code }: { code: string }) {
  const [copied, setCopied] = useState(false)
  const canCopy = typeof navigator !== 'undefined' && navigator.clipboard !== undefined

  useEffect(() => {
    if (!copied) return
    const clear = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(clear)
  }, [copied])

  return (
    <div className="servers-setup-code">
      {/* `aria-label` rather than the bare text: read out, `519G-KS0UC` is a
          string of letters, and a screen reader saying it as a word is a code
          nobody can transcribe. */}
      <code className="servers-setup-code-value" aria-label={code.split('').join(' ')}>
        {code}
      </code>
      {canCopy && (
        <Button
          onClick={() => {
            void navigator.clipboard.writeText(code).then(
              () => setCopied(true),
              () => setCopied(false),
            )
          }}
        >
          {copied ? 'Copied' : 'Copy'}
        </Button>
      )}
    </div>
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
export function AgentRow({
  row,
  state,
  busy,
  mine,
  asking,
  canSignOut,
  onAsk,
  onCancelAsk,
  onInstall,
  onSignIn,
  onSignOut,
  onRemove,
  onStop,
}: {
  row: SetupRow
  state: SetupState
  busy: boolean
  mine: boolean
  /** Which of the two two-press actions this row is in the middle of, if either. */
  asking: 'install' | 'sign-out' | null
  /** Whether a sign-out can actually be performed from here. Never drawn hopefully. */
  canSignOut: boolean
  onAsk: (want: 'install' | 'sign-out') => void
  onCancelAsk: () => void
  onInstall: () => void
  onSignIn: () => void
  onSignOut: () => void
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
            <Button tone="primary" onClick={() => onAsk('install')}>
              Set it up
            </Button>
          )}
          {idle && agent !== null && agent.version !== '' && agent.signedIn !== 'yes' && (
            <Button tone="primary" onClick={onSignIn}>
              Sign in
            </Button>
          )}
          {/*
            And out again, on a row that has a login to let go of.

            The pane above this one used to say in a notice that this could not
            be done — *"nothing on this side can ask a server to forget a login
            it holds"* — and that was a stated limitation rather than a measured
            one. Two of the three have a command for exactly this. The third
            carries its reason on the row instead, below, and gets no button:
            §4.1, a control that cannot act is removed.
          */}
          {idle && agent !== null && agent.signedIn === 'yes' && canSignOut && (
            <Button onClick={() => onAsk('sign-out')}>Sign out</Button>
          )}
          {idle && agent !== null && agent.version === '' && row.canInstall && (
            /*
             * Found, and it will not start. A different offer from a first
             * install and it has to be: this person has something broken rather
             * than nothing, and "Set it up" would read as though the app had not
             * noticed what is already there.
             */
            <Button onClick={() => onAsk('install')}>Install it again</Button>
          )}
          {/*
            One button, two words, and which word is a fact about the route.

            On the two routes this app cannot watch to the end — a sign-in
            finished at a prompt, and one that happens inside the agent's own
            full-screen interface — nothing on this side is ever told that it
            worked, and the row sat on *"signing in…"* for ever. `state.byHand`
            is exactly those two, so the button says what the press means there:
            the person has finished, and the far end is read again. Everywhere
            else the flow ends by itself and the only thing a press can mean is
            stopping it.
          */}
          {mine && <Button onClick={onStop}>{state.byHand ? 'I’m done' : 'Stop'}</Button>}
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
      {/* The reason a signed-in row has no Sign out, in that agent's own terms,
          and only where it would otherwise be the missing control. */}
      {idle && agent !== null && agent.signedIn === 'yes' && row.whyNoSignOut !== null && (
        <p className="servers-card-why">{row.whyNoSignOut}</p>
      )}
      {state.detail !== '' && <p className="servers-card-why">{state.detail}</p>}

      {asking !== null && (
        <div className="servers-setup-ask-first">
          {/* Written where the work is implemented, and rendered here unchanged. */}
          <p className="settings-prose">
            {asking === 'install' ? row.consequence : row.signOutConsequence}
          </p>
          <div className="servers-card-actions">
            {asking === 'install' ? (
              <Button tone="primary" onClick={onInstall}>
                Install
              </Button>
            ) : (
              <Button tone="primary" onClick={onSignOut}>
                Sign out
              </Button>
            )}
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
