/**
 * What the window knows about the copilot, and what it is therefore allowed to
 * draw.
 *
 * Everything here is a pure function over two answers the main process gives —
 * `copilot:state` and `copilot:signin` — and both cross the preload bridge as
 * `unknown`, deliberately: `CLAUDE.md` keeps feature types in their own module
 * rather than duplicating them into `shared/types.ts`, because two copies of a
 * shape are two shapes the day one of them changes. So this file is where the
 * `unknown` is narrowed, once, in code a test can run without Electron, a DOM
 * or a spawned agent anywhere near it.
 *
 * The narrowing is deliberately forgiving in one direction and strict in the
 * other. A field it cannot read becomes "not known" rather than a thrown error,
 * because a window that goes blank because an older build sent one field fewer
 * is a worse failure than a window that says less. But nothing is *invented*:
 * there is no default status, no assumed sign-in, and `unknown` never quietly
 * becomes `signed-out`. Those two send a person to completely different places
 * — one to a login, the other to a bug report — and `profiles-signin.ts` makes
 * the same distinction for the same reason.
 */

import type { SessionStatus } from '@shared/types'

/* ------------------------------------------------------------------ shapes -- */

/** Mirrors `CopilotStatus` in `src/main/copilot-session.ts`. */
export type CopilotStatus = 'stopped' | 'starting' | 'running'

/** Mirrors `CopilotSignInState`. `unknown` is never collapsed into signed-out. */
export type CopilotSignInState = 'signed-in' | 'signed-out' | 'unknown'

export interface CopilotPathsView {
  root: string
  instructions: string
  memory: string
  log: string
  actions: string
}

export interface CopilotStateView {
  status: CopilotStatus
  /** The live session's id — the same id the terminal and transcript use. */
  sessionId: string | null
  paths: CopilotPathsView | null
  startedAt: number | null
  /** Why the last start did not produce a running copilot, or null. */
  problem: string | null
  /**
   * True only when the running process was started inside a proven records
   * fence — this app's own routines and action log refused to it by the
   * operating system rather than by a rule in its instructions.
   *
   * Not "is it sandboxed". The copilot is not sandboxed; it is an ordinary
   * session with the person's own account. See `confine/records.ts`.
   */
  recordsHeld: boolean
}

export interface CopilotSignInView {
  state: CopilotSignInState
  account: string | null
  plan: string | null
}

/* --------------------------------------------------------------- narrowing -- */

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function str(source: Record<string, unknown> | null, key: string): string | null {
  const value = source?.[key]
  return typeof value === 'string' && value !== '' ? value : null
}

function num(source: Record<string, unknown> | null, key: string): number | null {
  const value = source?.[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

const STATUSES: readonly CopilotStatus[] = ['stopped', 'starting', 'running']

/**
 * The state, or null when what came back is not a state at all.
 *
 * Null rather than a made-up "stopped": those two look identical on screen and
 * are not the same thing. A copilot that is stopped has a Start button under it;
 * a bridge that answered with something unreadable has a sentence saying the
 * window could not ask, and no button pretending it can fix that.
 */
export function readCopilotState(value: unknown): CopilotStateView | null {
  const source = record(value)
  if (!source) return null
  const status = source.status
  if (typeof status !== 'string' || !STATUSES.includes(status as CopilotStatus)) return null

  const paths = record(source.paths)
  const root = str(paths, 'root')
  const records = record(source.records)

  return {
    status: status as CopilotStatus,
    sessionId: str(source, 'sessionId'),
    // All five or none. A partial paths object would let a pane offer to open a
    // folder it has half an address for.
    paths:
      root === null
        ? null
        : {
            root,
            instructions: str(paths, 'instructions') ?? '',
            memory: str(paths, 'memory') ?? '',
            log: str(paths, 'log') ?? '',
            actions: str(paths, 'actions') ?? '',
          },
    startedAt: num(source, 'startedAt'),
    problem: str(source, 'problem'),
    recordsHeld: records?.enforced === true,
  }
}

/** The sign-in answer, or null when nothing readable came back. */
export function readCopilotSignIn(value: unknown): CopilotSignInView | null {
  const source = record(value)
  if (!source) return null
  const state = source.state
  if (state !== 'signed-in' && state !== 'signed-out' && state !== 'unknown') return null
  return { state, account: str(source, 'account'), plan: str(source, 'plan') }
}

/* ------------------------------------------------------------------ stages -- */

/**
 * What the copilot view is showing, as one word.
 *
 * Five, and the two in the middle are the ones this component turns on.
 *
 * `first-run` is a copilot that is running and **signed out**. It used to be
 * every copilot's first launch, by design: the copilot was jailed, its login
 * lived inside its own sandbox, and the macOS keychain is closed to a sandboxed
 * process — so it could never borrow the account the person was already signed
 * in as. That is gone. The copilot runs as one of the app's accounts now, so a
 * person already signed into Claude Code has a copilot that is already signed
 * in, and this stage means what it says on any other session: *that account is
 * signed out*. Still worth a stage of its own, because the fix is a login and a
 * chat pane cannot show one.
 *
 * `unverified` is running with the sign-in probe unable to answer — the CLI
 * could not be run, was refused, or timed out. Not evidence of being signed
 * out, so it is not drawn as a login; it is the conversation, with one line
 * saying the window could not check.
 *
 * There is no `unavailable`. There used to be: a machine with no measured
 * confinement mechanism could not run the copilot at all, which was every
 * Windows machine. Nothing produces it now, and a stage nothing can reach is a
 * paragraph on screen that has stopped being true.
 */
export type CopilotStage =
  /** Never started, or stopped, or a start that gave up. */
  | 'stopped'
  /** A start is in flight. */
  | 'starting'
  /** Running; the sign-in answer has not arrived yet. */
  | 'checking'
  /** Running, and the account it runs as is signed out. */
  | 'first-run'
  /** Running; the window could not tell whether it is signed in. */
  | 'unverified'
  /** Running and signed in. */
  | 'ready'

export function copilotStage(
  state: CopilotStateView | null,
  signIn: CopilotSignInView | null,
): CopilotStage {
  if (!state) return 'stopped'
  if (state.status === 'starting') return 'starting'
  if (state.status !== 'running') return 'stopped'
  if (!signIn) return 'checking'
  if (signIn.state === 'signed-out') return 'first-run'
  if (signIn.state === 'unknown') return 'unverified'
  return 'ready'
}

/**
 * Which half of the copilot view a stage opens on.
 *
 * The terminal for `first-run`, and that is the entire reason the copilot view
 * has a terminal at all: the login prints a URL and reads a code back, and a
 * conversation pane can do neither. Everything else opens on the conversation,
 * because talking to it is the point.
 *
 * A person can still switch, in both directions, at every stage. This decides
 * what is in front of them before they have asked for anything.
 */
export type CopilotPane = 'chat' | 'terminal'

export function defaultPane(stage: CopilotStage): CopilotPane {
  return stage === 'first-run' ? 'terminal' : 'chat'
}

/**
 * The one line the pinned sidebar entry says about itself under the pointer.
 *
 * Written here rather than in the component so the sentence is a value a test
 * can assert, and because it is the same sentence in two places — the row's
 * `title` and its accessible name — and two hand-written copies of one sentence
 * drift.
 */
export function entryTooltip(stage: CopilotStage, state: CopilotStateView | null): string {
  switch (stage) {
    case 'stopped':
      // A refusal from the last attempt is far more useful than the word
      // "stopped", and it is the only place that sentence is ever shown.
      return state?.problem ?? 'Not running. Open it to start it.'
    case 'starting':
      return 'Starting…'
    case 'checking':
      return 'Running. Checking whether it is signed in…'
    case 'first-run':
      return 'Running — the account it runs as is signed out. Sign in on its terminal.'
    case 'unverified':
      return 'Running. This window could not check whether it is signed in.'
    case 'ready':
      return 'Running.'
  }
}

/**
 * The status dot's meaning, borrowed from the one the session rows already use.
 *
 * `SessionStatus` rather than a palette of its own, so the pinned entry reads
 * with the rows below it instead of introducing a second colour language two
 * pixels away from the first — and so the words on hover come from `StatusDot`'s
 * own table rather than from a second one written here that would drift.
 *
 * The mapping is the honest one. A copilot that is running and usable is `idle`
 * in exactly the sense a session sitting at its prompt is: alive, and waiting
 * on you. `working` while a start is in flight. `input` for the first run,
 * because "Needs input" is precisely what a login prompt is.
 *
 * **Null when nothing is running**, and that is the part worth the paragraph.
 * No member of `SessionStatus` means "there is no process", and the two nearest
 * both say something false: `idle` renders as **Ready**, which would put that
 * word beside a copilot that is not there, and `exited` renders as **Exited**,
 * which claims a process died when none was ever started. A dot is a claim
 * about something alive, so a stopped copilot gets none — like every other row
 * in this rail that is not a session — and the tooltip carries the reason,
 * including the sentence from the last refused start.
 *
 */
export function entryDot(stage: CopilotStage): SessionStatus | null {
  switch (stage) {
    case 'stopped':
      return null
    case 'starting':
      return 'working'
    case 'first-run':
      return 'input'
    default:
      return 'idle'
  }
}
