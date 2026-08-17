import { useCallback, useEffect, useMemo, useState } from 'react'
import { ChatView } from '../components/ChatView'
import { PageEmpty } from '../components/PageEmpty'
import { TerminalView } from '../components/TerminalView'
import { TourRecap } from './driving/TourRecap'
import { COPILOT_ICON } from './identity'
import type { CopilotPane } from './copilot-model'
import type { Copilot } from './useCopilot'
import './copilot.css'

/**
 * The copilot's **window** — what fills the pane when its tab is the one in
 * front.
 *
 * ## It is a session, so this is not a second chat implementation
 *
 * The copilot is a Claude CLI session with a working directory of its own —
 * `COPILOT-DESIGN.md` settles that, and everything below falls out of it. Its
 * conversation is an ordinary transcript in an ordinary folder, so the pane
 * showing it is `ChatView`, unchanged, with the copilot's folder as `cwd` and
 * the copilot's session as its scope. Its pty is an ordinary pty, so the other
 * pane is `TerminalView`, unchanged.
 *
 * ## What left this file on 2026-08-17, and why that is the whole change
 *
 * A bar of its own. It carried a state line, a Chat/Terminal switch of its own
 * spelling, and Stop — sitting on a *page*, under a toolbar that was headed with
 * the word "Copilot" and nothing else. Asad:
 *
 *   > *"Give the copilot a full window like the other windows. It is not that
 *   > much of a big window, it is like a small box inside the copilot page. Let
 *   > it have a proper window like others — proper dropdowns on the top, like
 *   > changing the counts, efforts, models, all those things should be there,
 *   > exactly like the other sessions. It should have all of those things,
 *   > nothing should be less than that."*
 *
 * Every one of those three had a first-class equivalent one row up that the
 * copilot was not being given: the status dot and the account chip say what the
 * state line said, the window's mode switch says what the private switch said,
 * and the strip's pill names it. So they are gone from here and the copilot gets
 * the real ones — plus the model, effort, fast-mode, connectors and usage
 * cluster it never had at all, because those hang off `headingSession` in
 * `App.tsx` and the copilot was being filtered out of the list that feeds it.
 *
 * `mode` is now a prop for the same reason: it is the window's `sessionView` for
 * this session, driven by the same segmented control every other session's is,
 * so there is one answer to "how is this drawn" instead of two that could
 * disagree. `defaultPane` still decides where a first run opens — on the
 * terminal, because a login prints a URL and reads a code back and a
 * conversation pane can do neither — but `App.tsx` seeds it, once, into that
 * shared state.
 *
 * ## What stayed, and why each one earned it
 *
 * Everything here is drawn **only when it has something to say**, above the
 * pane, in a strip that is absent the rest of the time — which is the whole
 * difference between this and the page it replaces. With the copilot running,
 * signed in and nothing else going on, this component renders a terminal (or a
 * conversation) and literally nothing else.
 *
 *  - **The sign-in explanation.** An account can be signed out, the same as any
 *    other session's, and a chat pane cannot show a URL to copy or take a code
 *    back. Without these two paragraphs a signed-out copilot is something that
 *    looks broken while working correctly, which is a failure this app has
 *    shipped before.
 *  - **A start that failed**, in the CLI's own sentence, with the button that
 *    retries it.
 *  - **The turn that started a session**, when a copilot-started row asked "why
 *    does this exist". That link used to open a page at a `focus`; it opens this
 *    window at the same row now, so the answer arrives where the thing that gave
 *    it is.
 *  - **The tours**, which are the app's record of what it showed under the
 *    copilot's name — *"it keeps those parts inside its own chat also, so we can
 *    just read from there instead of the other sessions."* This window is that
 *    chat.
 *  - **The sessions it started**, which the rail also groups; the rail answers
 *    "what is open" and this answers "what has it done", standing in front of
 *    the thing that did it.
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

/** Props the window needs. See `App.tsx` for where each is from. */
interface Props {
  copilot: Copilot
  /**
   * Whether this is the tab in front.
   *
   * Mounted either way, hidden with `display: none`, exactly like every other
   * session's terminal: the pty keeps running whatever is on screen, and a
   * remount would throw away the scrollback the login prompt is sitting in.
   */
  visible?: boolean
  /**
   * Terminal or conversation — the window's own `sessionView` for this session,
   * set by the same mode switch every other session uses.
   */
  mode?: CopilotPane
  /**
   * An action-log row id, when the window was opened *from* something — a
   * session row asking why it exists. Lands the reader on that turn.
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

/** One row of the action log, as much of it as this window draws. */
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
  visible = true,
  mode = 'chat',
  focus = null,
  startedSessions = [],
  onOpenSession,
  fontSize,
  fontFamily,
  copyOnSelect,
  activity,
}: Props) {
  const { state, stage } = copilot

  const [turns, setTurns] = useState<Turn[]>([])
  const bridge = useMemo(() => activity ?? activityBridge(), [activity])

  /*
   * The action log, read only when there is something in the window pointing at
   * it — a `focus` from a session row, or sessions to link forward from.
   *
   * A window that read the whole log on every open would be doing file I/O for
   * a strip most visits never see, and the log grows for the life of the
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

  return (
    <div className="copilot-page" data-visible={visible}>
      {/*
        The record strip: the things this window has to say that are not the
        conversation.

        Capped and scrolling rather than allowed to grow, because two of its
        four contents are unbounded — a tour has as many stops as it visited —
        and the pane below it is the thing somebody came here to use. This is
        the one place the old page's shape survives, and it survives *bounded*.

        Every child of it is conditional, and each one that is absent renders no
        element at all — so with a running, signed-in copilot and no tour behind
        it this `div` is genuinely childless, and `.cp-strip:empty` takes it out
        of the layout. That is what makes the ordinary case a terminal filling
        the window rather than a terminal with a band of padding over it, which
        would be a smaller copy of the complaint this rewrite answers.
      */}
      <div className="cp-strip scroll-fade">
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
              in front. The terminal is only "below" while the terminal is the
              one being drawn — this window is switchable from its own toolbar,
              and a sentence pointing at something that is not on the screen is
              the kind of small lie that makes a person doubt the rest of the
              paragraph.
            */}
            <p>
              {mode === 'terminal'
                ? 'Its terminal is below. Run /login there: it prints a URL, and you paste the code back here.'
                : 'The login is on its terminal — press Terminal in the bar above, and run /login there.'}
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

        {/*
          Why this window was opened, when something opened it.

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

        {/*
          What the tours showed, as the app recorded them.

          Here rather than in the conversation, and the split is `DRIVING-MODE.md`
          §6's: the copilot's own answer is already in the chat below, because the
          copilot wrote it and the CLI put it in its transcript — the app must
          never inject into that file. What the app owns is the account of what it
          *showed*, which is a different artefact with a different author, kept
          outside the folder the copilot can write to. Labelling it as the app's is
          the whole value of writing it there.
        */}
        <TourRecap />

        {/*
          Forward: the sessions this copilot started, from the copilot's own
          window.

          The sidebar groups them and this lists them, and both are needed — the
          rail answers "what is open", and this answers "what has it done", which
          is the question somebody has when they are standing in front of the
          thing that did it.
        */}
        {startedSessions.length > 0 && onOpenSession && (
          <div className="cp-started">
            <h2 className="cp-started-label">Sessions it started</h2>
            <ul className="cp-started-list">
              {startedSessions.map((session) => (
                <li key={session.id}>
                  <button
                    type="button"
                    className="cp-link"
                    onClick={() => onOpenSession(session.id)}
                  >
                    {session.label}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>

      <div className="cp-body">
        {sessionId === null || root === null ? (
          <PageEmpty
            // The copilot's own glyph, from the one constant that defines it, so
            // this window and the row that opened it cannot draw two marks.
            icon={COPILOT_ICON}
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
            <div className="cp-pane" data-shown={mode === 'terminal' ? 'true' : undefined}>
              <TerminalView
                sessionId={sessionId}
                visible={visible && mode === 'terminal'}
                {...(fontSize === undefined ? {} : { fontSize })}
                {...(fontFamily === undefined ? {} : { fontFamily })}
                {...(copyOnSelect === undefined ? {} : { copyOnSelect })}
              />
            </div>
            {mode === 'chat' && (
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
    </div>
  )
}

