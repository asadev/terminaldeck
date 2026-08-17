import { useState, type ReactElement } from 'react'
import { profileLoginLabel, useKnownSignIns } from '../accounts'
import { PageEmpty } from '../components/PageEmpty'
import { chordFor } from '../keymap'
import { useEvery } from '../schedule'
import { panelSpec } from '../shell/panels'
import { shortSessionId } from '../session-title'
import { sessionLabel } from '../shell/workspace-tabs'
import {
  attentionLabel,
  attentionOf,
  countBoard,
  folderOf,
  formatElapsed,
  providerLabel,
  sortBoard,
  stateSentence,
  summaryParts,
  wantsYou,
  type BoardSession,
} from './board'
import { FolderWorkLoader, useBoardSessions } from './useBoard'
import { formatTokens, plural } from './widgets'
import './SessionBoard.css'

/**
 * The Overview page: one card per running session, loudest first.
 *
 * ## What is deliberately not here
 *
 * **There is no progress bar and there is no "42% done".** Asad asked to "see
 * who is finished how much", and the honest answer is that the app cannot know
 * it: an agent does not report progress, nothing in a transcript or on a
 * terminal screen says how much of a task remains, and a bar drawn from a
 * request count or a token total would be a number this app invented, on the
 * one screen a person uses to decide where to spend the next hour. What it can
 * know is better than a fake bar anyway — a session has either *asked you a
 * question*, *finished its turn*, or is *still going* — and that is the whole of
 * the decision the page exists to support.
 *
 * **There is no "last line it said" either.** The obvious source is the PTY
 * stream, and it is the wrong one: agent CLIs are full-screen TUIs that repaint
 * with cursor moves, so the tail of the stream bears no relation to what is on
 * the screen — `session-activity.ts` says so and was written after that exact
 * mistake. The right source, the settled emulator viewport, already exists in
 * the main process as `PtyManager.screen(id)` and is simply not exposed over
 * IPC. Rather than print something plausible off the raw bytes, the card shows
 * the session's title, which `session-title.ts` derives from the conversation's
 * own `ai-title`/`custom-title` line or its first prompt — real evidence of what
 * the session is for.
 *
 * ## Where every figure comes from
 *
 * | On the card | Real signal |
 * |---|---|
 * | Needs you / Finished / Working / Ready | `SessionStatus`, from the classified screen (`session-activity.ts`) and the agents' own lifecycle hooks (`hooks.ts`) |
 * | "for 12m" | when this window observed that status begin (`Session.statusSince`) |
 * | Title | `SessionMeta.title`, derived in `session-title.ts` |
 * | Folder, agent, account | `SessionMeta.cwd` / `provider` / `profileName`, set at spawn |
 * | Started | `SessionMeta.createdAt` |
 * | Tokens, requests, context, last activity | this session's own transcript, matched by `pickSessionTranscript` and totalled by `transcript.ts` |
 */

export interface SessionBoardProps {
  /** Absolute path of the project the Overview page is open on. */
  projectPath: string
  /** Open a session. Without it the cards are not controls — see `Card`. */
  onOpenSession?: (id: string) => void
  /**
   * Cards, when the host has them. Omitted — the ordinary case — means the
   * board gathers them itself. Tests and the harness pass them.
   */
  sessions?: readonly BoardSession[]
  /** Clock, so the sentences can be asserted at a fixed instant. */
  now?: number
}

/**
 * How often the durations move.
 *
 * A second, because under a minute they are *in* seconds and a card that says
 * "Working for 12s" and stays there is a card nobody trusts. It costs nothing:
 * `schedule.ts` holds one timer for the whole renderer, coalesces everything
 * due within 200 ms of the same moment onto one wake-up, and disarms entirely
 * while the window is hidden.
 */
const TICK_MS = 1000

/**
 * The clock the sentences are measured against.
 *
 * A fixed `now` from the caller wins outright and registers no job at all —
 * that is how the tests read the wording at a known instant, and how a
 * screenshot stays reproducible.
 */
function useNow(fixed: number | undefined, live: boolean): number {
  const [now, setNow] = useState(() => Date.now())
  useEvery(fixed === undefined && live ? TICK_MS : null, () => setNow(Date.now()))
  return fixed ?? now
}

export function SessionBoard(props: SessionBoardProps): ReactElement {
  const gathered = useBoardSessions()
  const supplied = props.sessions
  const sessions = supplied ?? gathered.sessions
  // Nothing on an empty board moves, so an empty board holds no timer.
  const now = useNow(props.now, sessions.length > 0)

  return (
    <section className="board" aria-label="Running sessions">
      {/* Renders nothing. One per folder with a session in it, because the
          subscriptions behind the figures are per folder — see FolderWorkLoader. */}
      {supplied === undefined &&
        gathered.plan.map((folder) => (
          <FolderWorkLoader
            key={folder.cwd}
            cwd={folder.cwd}
            sessionKey={folder.sessionKey}
            awaiting={folder.awaiting}
            live={folder.live}
            onLoaded={gathered.onFolderLoaded}
          />
        ))}
      <BoardBody
        sessions={sessions}
        now={now}
        projectPath={props.projectPath}
        onOpenSession={props.onOpenSession}
      />
    </section>
  )
}

/**
 * The board without its subscriptions, so the whole of it can be rendered from
 * a fixed list in a test — which is the only way the ordering and the wording
 * are actually pinned.
 */
export function BoardBody({
  sessions,
  now,
  projectPath,
  onOpenSession,
}: {
  sessions: readonly BoardSession[]
  now: number
  projectPath: string
  onOpenSession?: (id: string) => void
}): ReactElement {
  if (sessions.length === 0) {
    const chord = chordFor('session.new')
    return (
      <PageEmpty icon={panelSpec('overview').icon} title="Nothing is running">
        Start an agent in a folder and it appears here — what it is doing, how long it has been
        doing it, and whether it is waiting on you.
        {chord ? ` Press ${chord}.` : ' Start one from the sidebar.'}
      </PageEmpty>
    )
  }

  const ordered = sortBoard(sessions)
  const counts = countBoard(sessions)

  /**
   * What each card is called, numbered the way the sidebar numbers it.
   *
   * A session starts out titled after the folder it runs in, and the card
   * printed that title raw — so eight sessions in one project gave eight cards
   * all headed `terminaldeck`, with the same word repeated as the folder chip
   * directly above each one. The page whose whole job is "which one do I need
   * to go into" could not tell you which one you were looking at.
   *
   * `sessionLabel` is the rule the rail already follows: the agent's title when
   * it has written one, and `Session N` until then. The number is counted over
   * the *unsorted* list, which is the order the store holds and therefore the
   * order the sidebar counts in — take it off `ordered` instead and a card
   * would be "Session 2" here while the rail called the same session
   * "Session 4", which is the class of defect this whole pass is closing.
   */
  const names = new Map<string, string>()
  const seen = new Map<string, number>()
  for (const session of sessions) {
    const nth = seen.get(session.projectPath) ?? 0
    seen.set(session.projectPath, nth + 1)
    names.set(session.id, sessionLabel(session.title, nth, folderOf(session.projectPath)))
  }

  /**
   * And the fact that separates two cards the name cannot.
   *
   * Everything else a card could be told apart by is already printed on it: the
   * folder is the chip in its top corner and the account is in its meta line.
   * So the only case left is the one the rail has too — two agents given the
   * same task in the same folder on the same login write the same sentence —
   * and the answer is the same as the rail's, in the same eight characters, so
   * a card and a row can be matched by eye.
   *
   * Empty for every card that does not need one. A card carrying an id when its
   * name is already unique is a card asking you to read a hex string for
   * nothing.
   */
  /*
   * The separator, spelled as an escape and never as the byte itself.
   *
   * NUL is the right character here — it cannot occur in a name, a POSIX path
   * or an account id, so no two different sessions can be made to collide by
   * the joining. What is not right is typing the raw byte, which is how this
   * line was first written: a single NUL makes `file`(1) report the source as
   * `data` and makes `grep`(1) treat it as binary and match it silently. A
   * search for any symbol in this file then comes back empty, and the only
   * honest reading of that is "it is declared somewhere else". That has
   * already cost real time on this project, in this file's siblings.
   *
   * `src/encoding.test.ts` fails the build on a NUL in any tracked source, and
   * it is what caught this one.
   */
  const KEY_SEP = '\u0000'
  const twins = new Map<string, number>()
  const keyOf = (session: BoardSession): string =>
    [names.get(session.id), session.projectPath, session.account?.id ?? ''].join(KEY_SEP)
  for (const session of sessions) twins.set(keyOf(session), (twins.get(keyOf(session)) ?? 0) + 1)

  return (
    <>
      <header className="board-head">
        <h2 className="board-heading">
          {counts.total} {plural(counts.total, 'session')}
        </h2>
        {/* The counts, not a decorative subtitle: each one is a real group in
            the list below it, and the run reads left to right in the same
            order the cards are sorted. Each group carries its own tone — a
            single-colour line painted "1 at a prompt" in the alarm colour
            alongside the one session that genuinely needed answering. */}
        <p className="board-summary">
          {summaryParts(counts).map((part, index) => (
            <span key={part.attention} className="board-summary-part" data-attention={part.attention}>
              {index > 0 && <span className="board-summary-sep"> · </span>}
              {part.text}
            </span>
          ))}
        </p>
      </header>

      <ul className="board-grid">
        {ordered.map((session) => (
          <li key={session.id}>
            <Card
              session={session}
              name={names.get(session.id) ?? session.title}
              twin={(twins.get(keyOf(session)) ?? 0) > 1}
              now={now}
              here={session.projectPath === projectPath}
              onOpen={onOpenSession}
            />
          </li>
        ))}
      </ul>
    </>
  )
}

/**
 * One session.
 *
 * A button when there is somewhere to go and a plain block when there is not.
 * The affordance follows the handler exactly: a card that lifts under the
 * pointer and then does nothing is worse than one that never invited the click.
 */
function Card({
  session,
  name,
  twin,
  now,
  here,
  onOpen,
}: {
  session: BoardSession
  /** What to call it — see the numbering in `BoardBody`, which owns the rule. */
  name: string
  /** Another card carries the same name, folder and account. See `BoardBody`. */
  twin: boolean
  now: number
  /** True when this session runs in the project the Overview page is open on. */
  here: boolean
  onOpen?: (id: string) => void
}): ReactElement {
  const attention = attentionOf(session.status)
  /*
   * Who it is running as, in the words the chip and the rail use.
   *
   * The card printed `session.account` raw — the profile key — so every card on
   * this page read `Claude Code · Default · started 25m ago` while the chip
   * inside that same session read the address. `useKnownSignIns` is a read of
   * the answers the chip has already paid for and never starts a probe of its
   * own: the board can hold a card per session, and a page that spawned an
   * agent CLI per card on mount would cost more to look at than to run.
   */
  const known = useKnownSignIns()
  const login =
    session.account === null
      ? null
      : profileLoginLabel(
          { ...session.account, provider: session.provider },
          known[session.account.id],
        )
  const body = (
    <>
      <div className="board-card-top">
        <span className="board-chip" data-attention={attention}>
          {/* The dot carries the colour, the word carries the meaning. Colour
              alone never says it — the same rule `StatusDot` follows. */}
          <span className="board-chip-dot" aria-hidden="true" />
          {attentionLabel(attention)}
        </span>
        <span className="board-folder" title={session.projectPath}>
          {folderOf(session.projectPath)}
          {/* Named only when it is *not* the folder this page is open on. Saying
              "this project" on every card in the common case is a label that
              costs a line and settles nothing. */}
          {!here && <span className="board-elsewhere"> · other project</span>}
        </span>
      </div>

      {/* The session, not the folder. The folder is the chip above this line
          and repeating it here left every card in a project headed with one
          word. `title` carries the derived title even when the heading is
          "Session 3", because that is the string a search would match. */}
      <h3 className="board-title" title={session.title}>
        {name}
        {twin && <span className="board-title-id">{shortSessionId(session.id)}</span>}
      </h3>
      <p className="board-state" data-attention={attention}>
        {stateSentence(session, now)}
      </p>

      <p className="board-meta">
        {providerLabel(session.provider)}
        {login ? ` · ${login}` : ''}
        {session.startedAt > 0 ? ` · started ${formatElapsed(now - session.startedAt)} ago` : ''}
      </p>

      <Figures session={session} now={now} />
    </>
  )

  const className = `board-card${wantsYou(attention) ? ' wants-you' : ''}`
  if (!onOpen) return <div className={className}>{body}</div>
  return (
    <button
      type="button"
      className={className}
      title={`Open ${name}`}
      onClick={() => onOpen(session.id)}
    >
      {body}
    </button>
  )
}

/**
 * The numbers, when this session's own transcript could be established.
 *
 * Absent entirely otherwise — a row of zeroes under a session that has done
 * real work is worse than no row, and the two cases are indistinguishable to a
 * reader once they are both printed as `0`.
 */
function Figures({ session, now }: { session: BoardSession; now: number }): ReactElement | null {
  const work = session.work
  if (!work || work.requests === 0) return null

  return (
    <dl className="board-figures">
      <div>
        <dt>Tokens</dt>
        <dd>{formatTokens(work.tokens)}</dd>
      </div>
      {/*
        Requests, where this card's "Spent" figure used to be.

        A token count on its own does not say whether it came from six long
        turns or four hundred short ones, and that is the difference a person
        scanning the board is looking for. The money it replaces is gone from
        the whole app — see the bottom of `src/main/cost.ts`.
      */}
      <div>
        <dt>Requests</dt>
        <dd>{work.requests}</dd>
      </div>
      {work.contextPercent !== null && (
        <div>
          <dt>Context</dt>
          {/* Can exceed 100: auto-compaction fires at the limit, so the last
              request before it tips over. The number is the truth; there is no
              bar here to clamp. */}
          <dd data-tone={work.contextPercent >= 90 ? 'crit' : work.contextPercent >= 70 ? 'warn' : undefined}>
            {Math.round(work.contextPercent)}%
          </dd>
        </div>
      )}
      {work.lastActivityAt > 0 && (
        <div>
          <dt>Last wrote</dt>
          <dd>{formatElapsed(Math.max(0, now - work.lastActivityAt))} ago</dd>
        </div>
      )}
    </dl>
  )
}
