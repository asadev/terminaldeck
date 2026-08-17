import { useCallback, useEffect, useMemo, useState } from 'react'
import { ChatView } from '../components/ChatView'
import { PageEmpty } from '../components/PageEmpty'
import { StatusDot } from '../components/StatusDot'
import { TerminalView } from '../components/TerminalView'
import { panelSpec } from '../shell/panels'
import { defaultPane, entryDot, type CopilotPane } from './copilot-model'
import type { Copilot } from './useCopilot'
import './copilot.css'

/**
 * Where you talk to the copilot.
 *
 * ## It is a session, so this is not a second chat implementation
 *
 * The copilot is a Claude CLI session with a working directory of its own —
 * `COPILOT-DESIGN.md` settles that, and everything below falls out of it. Its
 * conversation is an ordinary transcript in an ordinary folder, so the pane
 * showing it is `ChatView`, unchanged, with the copilot's folder as `cwd` and
 * the copilot's session as its scope. Its pty is an ordinary pty, so the other
 * pane is `TerminalView`, unchanged. Nothing about the transcript reader, the
 * composer, the agent controls or the usage strip had to learn that the copilot
 * exists.
 *
 * The one thing this file adds is *which of the two you are looking at*, and
 * that exists for a single reason worth the whole component:
 *
 * ## A signed-out account, which is a login and looks like a bug
 *
 * This used to be *every* first run, and it was the largest single cost of the
 * copilot being jailed: it kept its credential inside its own sandbox, which
 * cannot reach the macOS login keychain, so it could never borrow the account
 * the person was already signed in as. It started signed out on every machine,
 * every time, and could not read a line of their code until they had pasted a
 * code back into a terminal.
 *
 * That is gone. The copilot runs as one of the app's own accounts, so somebody
 * already signed into Claude Code has a copilot that is already signed in.
 * `confine/records.ts` carries the argument for the change.
 *
 * The stage survives because the state it names still happens — an account can
 * be signed out, the same as any other session's — and because a chat pane
 * cannot show a URL to copy or take a code back. So a signed-out copilot opens
 * on the terminal, with two lines above it saying which account and what to do.
 * The alternative — the conversation pane, empty, over a session quietly waiting
 * on a login nobody can see — is the exact shape of failure this app has shipped
 * before: something that looks broken while working correctly.
 *
 * ## What it is for, and what the empty state must not promise
 *
 * A **developer's** assistant. *"Not to do the marketing for him, not to do the
 * emails for him."* So there is no inbox here, no calendar and no digest; the
 * suggestions are the things this app can do that a CLI agent cannot, because
 * it is the only thing on the machine that owns every session's pty, transcript
 * and git state at once: triage the fleet, review a diff before it lands, scope
 * a vague ask into a real prompt for a sub-session.
 */

/** Props the page needs from the window. See `App.tsx` for where each is from. */
interface Props {
  copilot: Copilot
  /**
   * An action-log row id, when the page was opened *from* something — a session
   * row asking why it exists. Lands the reader on that turn.
   *
   * The same `focus` mechanism every other panel uses, for the same reason: a
   * count on a dashboard is a door, and a door has to open onto the thing it
   * counted rather than onto the page in general.
   */
  focus?: string | null
  /** Sessions the copilot started, for the link the other way. */
  startedSessions?: readonly { id: string; label: string; runId: string | null }[]
  onOpenSession?(id: string): void
  /** Terminal appearance, from the same settings the session terminals read. */
  fontSize?: number
  fontFamily?: string
  copyOnSelect?: boolean
  /** Injectable for tests and the harness; defaults to the preload bridge. */
  activity?: ActivityBridge
}

export interface ActivityBridge {
  deckControlActivity(count?: number): Promise<unknown>
}

/** One row of the action log, as much of it as this page draws. */
interface Turn {
  id: string
  at: string
  detail: string
}

function readTurns(value: unknown): Turn[] {
  if (!Array.isArray(value)) return []
  const rows: Turn[] = []
  for (const entry of value) {
    if (typeof entry !== 'object' || entry === null) continue
    const row = entry as Record<string, unknown>
    if (typeof row.id !== 'string' || typeof row.detail !== 'string') continue
    rows.push({ id: row.id, at: typeof row.at === 'string' ? row.at : '', detail: row.detail })
  }
  return rows
}

function activityBridge(): ActivityBridge | null {
  const deck = (globalThis as { deck?: Partial<ActivityBridge> }).deck
  return deck && typeof deck.deckControlActivity === 'function' ? (deck as ActivityBridge) : null
}

/** A log row's ISO timestamp as a local time, or the raw string if unparseable. */
function when(at: string): string {
  const ms = Date.parse(at)
  if (!Number.isFinite(ms)) return at
  return new Date(ms).toLocaleString()
}

export function CopilotView({
  copilot,
  focus = null,
  startedSessions = [],
  onOpenSession,
  fontSize,
  fontFamily,
  copyOnSelect,
  activity,
}: Props) {
  const { state, stage } = copilot

  /*
   * Opening the page is what starts the copilot.
   *
   * Not app launch: the copilot is an agent CLI and an agent CLI bills for what
   * it does, so a standing charge for opening the app would be a cost nobody
   * agreed to. Opening this page is the moment somebody has said they want to
   * talk to it. `ensureCopilot` is idempotent by contract, so coming back to
   * this page does not produce a second one.
   *
   */
  const { ensure } = copilot
  useEffect(() => {
    ensure()
    // Once per mount. Re-running on every stage change would re-ask while a
    // start is already in flight, which `ensureCopilot` handles but which would
    // also mean this effect fires on its own result.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  /**
   * Which pane is in front, and who decided.
   *
   * Null means nobody has: the stage decides, so the first run opens on the
   * terminal and everything else on the conversation. Once somebody presses one
   * of the two it stays where they put it — an app that kept moving the pane
   * under them because a background probe changed its mind would be worse than
   * one that opened on the wrong half.
   */
  const [chosen, setChosen] = useState<CopilotPane | null>(null)
  const pane: CopilotPane = chosen ?? defaultPane(stage)

  const [turns, setTurns] = useState<Turn[]>([])
  const bridge = useMemo(() => activity ?? activityBridge(), [activity])

  /*
   * The action log, read only when there is something in the page pointing at
   * it — a `focus` from a session row, or sessions to link forward from.
   *
   * A page that read the whole log on every open would be doing file I/O for a
   * panel most visits never scroll to, and the log grows for the life of the
   * install.
   */
  const wantsTurns = focus !== null || startedSessions.length > 0
  useEffect(() => {
    if (!bridge || !wantsTurns) return
    let live = true
    void bridge
      .deckControlActivity(200)
      .then((value) => {
        if (live) setTurns(readTurns(value))
      })
      .catch(() => {
        // No tool surface in this build, or the log could not be read. The links
        // below simply do not appear; nothing claims a turn it cannot show.
      })
    return () => {
      live = false
    }
  }, [bridge, wantsTurns])

  const focused = focus === null ? null : turns.find((turn) => turn.id === focus) ?? null
  const fromFocusedTurn = focus === null ? [] : startedSessions.filter((s) => s.runId === focus)

  const send = useCallback(
    (text: string) => {
      const id = state?.sessionId
      if (!id) return
      // Typed into the copilot's own terminal, exactly as chat mode does for any
      // other session: this is a second view of one session, not a second
      // channel into it, so what is said here also appears in the terminal.
      window.deck.writeToSession(id, `${text}\r`)
    },
    [state?.sessionId],
  )

  const root = state?.paths?.root ?? null
  const sessionId = state?.sessionId ?? null
  const dot = entryDot(stage)

  return (
    <div className="copilot-page">
      <div className="cp-bar">
        <span className="cp-identity">
          {/* Absent while nothing is running — see `entryDot`. The sentence
              beside it says what is true either way, which is why the dot can
              afford to say nothing rather than say the wrong word. */}
          {dot !== null && <StatusDot status={dot} />}
          <span className="cp-state">{stateLine(copilot)}</span>
        </span>

        <div className="cp-controls">
          {/* Two views of one session, exactly like the session bar's
              Terminal/Chat pair — the same idea in the same words, so nobody has
              to learn a second one. Drawn whatever the stage is: the terminal is
              how a person completes the login, and hiding it once signed in
              would take away the only place its startup output can be read. */}
          <div className="cp-switch" role="group" aria-label="How to show the copilot">
            <button
              type="button"
              className="cp-switch-btn"
              aria-pressed={pane === 'chat'}
              onClick={() => setChosen('chat')}
            >
              Chat
            </button>
            <button
              type="button"
              className="cp-switch-btn"
              aria-pressed={pane === 'terminal'}
              onClick={() => setChosen('terminal')}
            >
              Terminal
            </button>
          </div>

          {state?.status === 'running' && (
            <button type="button" className="cp-btn" onClick={copilot.stop}>
              Stop
            </button>
          )}
          {stage === 'stopped' && (
            <button type="button" className="cp-btn primary" onClick={copilot.ensure}>
              Start
            </button>
          )}
        </div>
      </div>

      {/*
        Why this page was opened, when something opened it.

        The other half of "why does this exist" — a copilot session's row asks
        the question and lands here, on the turn that answers it. The turn is a
        row of the action log, which is the only durable record of what the
        copilot did, so this is the record itself rather than a retelling of it.
      */}
      {focus !== null && (
        <div className="cp-turn">
          {focused ? (
            <>
              <p className="cp-turn-detail">{focused.detail}</p>
              <p className="cp-turn-when">{when(focused.at)}</p>
            </>
          ) : (
            <p className="cp-turn-detail">
              The turn that started that session is not in the recent action log.
            </p>
          )}
          {fromFocusedTurn.length > 0 && onOpenSession && (
            <div className="cp-turn-links">
              {fromFocusedTurn.map((session) => (
                <button
                  key={session.id}
                  type="button"
                  className="cp-link"
                  onClick={() => onOpenSession(session.id)}
                >
                  Open {session.label}
                </button>
              ))}
            </div>
          )}
        </div>
      )}

      {stage === 'first-run' && (
        <div className="cp-notice" data-kind="first-run">
          <h2>The account it runs as is signed out</h2>
          <p>
            The copilot runs as one of your accounts, the same as any other session — it has no
            login of its own. This one is not signed in yet. Signing it in here signs it in
            everywhere that account is used, and you can do it under Settings → Accounts instead.
          </p>
          {/*
            Where the login actually is, said accurately for whichever pane is
            in front. The terminal is only "below" while the terminal is the one
            being drawn — this pane is switchable, and a sentence pointing at
            something that is not on the screen is the kind of small lie that
            makes a person doubt the rest of the paragraph.
          */}
          <p>
            {pane === 'terminal'
              ? 'Its terminal is below. Run /login there: it prints a URL, and you paste the code back here.'
              : 'The login is on its terminal — press Terminal above, and run /login there.'}
          </p>
        </div>
      )}

      {stage === 'unverified' && (
        <div className="cp-notice" data-kind="unverified">
          <p>
            This window could not check whether the copilot is signed in — asking timed out or was
            refused. It is running, so the conversation below is live; if it answers with a login
            prompt, open the terminal.
          </p>
        </div>
      )}

      {stage === 'stopped' && state?.problem && (
        <div className="cp-notice" data-kind="problem">
          <p>{state.problem}</p>
        </div>
      )}

      <div className="cp-body">
        {sessionId === null || root === null ? (
          <PageEmpty
            // The rail's own glyph, asked of the one table that defines it, so
            // the empty page and the row that opened it cannot draw two marks.
            icon={panelSpec('copilot').icon}
            title={stage === 'starting' ? 'Starting the copilot…' : 'The copilot is not running'}
            action={{ label: 'Start it', onClick: copilot.ensure, primary: true }}
          >
            It runs in a folder of its own, with its own memory, as one of your accounts. Ask it
            which of your sessions needs you, to review a diff before it lands, or to turn a rough
            ask into a prompt worth giving a sub-session.
          </PageEmpty>
        ) : (
          <>
            {/* Both stay mounted; only one is shown. The terminal keeps its
                scrollback and the login prompt in it across a trip through
                Chat, which is the whole reason the session views do the same. */}
            <div className="cp-pane" data-shown={pane === 'terminal' ? 'true' : undefined}>
              <TerminalView
                sessionId={sessionId}
                visible={pane === 'terminal'}
                {...(fontSize === undefined ? {} : { fontSize })}
                {...(fontFamily === undefined ? {} : { fontFamily })}
                {...(copyOnSelect === undefined ? {} : { copyOnSelect })}
              />
            </div>
            {pane === 'chat' && (
              <ChatView
                cwd={root}
                // Which conversation this is a view of. Without it the pane
                // reads the folder's newest transcript, which for the copilot's
                // folder would be a previous copilot run's.
                session={{ startedAt: state?.startedAt ?? 0, resumed: false }}
                // Without this the controls row and the usage strip render in
                // their "no session focused" state.
                sessionId={sessionId}
                // It is a Claude CLI session. Saying so is what stops the pane
                // writing shell copy over an agent.
                provider="claude"
                onSend={send}
              />
            )}
          </>
        )}
      </div>

      {/*
        Forward: the sessions this copilot started, from the copilot's own page.

        The sidebar groups them and this lists them, and both are needed —
        the rail answers "what is open", and this answers "what has it done",
        which is the question somebody has when they are standing in front of
        the thing that did it.
      */}
      {startedSessions.length > 0 && onOpenSession && (
        <div className="cp-started">
          <h2 className="cp-started-label">Sessions it started</h2>
          <ul className="cp-started-list">
            {startedSessions.map((session) => (
              <li key={session.id}>
                <button type="button" className="cp-link" onClick={() => onOpenSession(session.id)}>
                  {session.label}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

/**
 * The one line the bar says about the copilot's condition.
 *
 * It names the account when the CLI named one, because "signed in" without a
 * login is the kind of half-fact this app keeps having to take back out. Every
 * other branch says what is true and nothing more.
 */
export function stateLine(copilot: Copilot): string {
  const { state, signIn, stage } = copilot
  switch (stage) {
    case 'starting':
      return 'Starting…'
    case 'stopped':
      return copilot.loading ? 'Checking…' : 'Not running'
    case 'checking':
      return 'Running · checking sign-in'
    case 'first-run':
      return 'Running · signed out'
    case 'unverified':
      return 'Running · sign-in unknown'
    case 'ready':
      return signIn?.account
        ? `Running · ${signIn.account}`
        : state?.recordsHeld
          ? 'Running · signed in, its log held'
          : 'Running · signed in'
  }
}
