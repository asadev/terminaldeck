import type { ProviderId, SessionStatus } from '@shared/types'

/**
 * The Overview board's model: every running session, ranked by whether it is
 * waiting on you.
 *
 * ## What this page is for
 *
 * Asad, walking the app: *"maybe we can have some kind of task lists of all of
 * the running clouds, running sessions … we can see who is finished how much
 * and we can get inside … and we can accordingly see which one we need to go
 * inside and take a review."* The question the board answers is the last
 * clause — **which one do I need to go into** — and everything here exists to
 * answer it and nothing else.
 *
 * ## The rule this file is written under
 *
 * Every value on a card comes from something the app genuinely observed. There
 * is no percentage of a task complete anywhere in this module, and there must
 * never be one: an agent does not report progress, so a bar would be a number
 * this app made up, drawn in the one place a person is deciding where to spend
 * their attention. What *can* be known truthfully is stronger than a fake bar
 * anyway — a session has either asked you a question, finished its turn, or is
 * still going, and that is the whole of the decision.
 *
 * Everything below is pure: no DOM, no bridge, no clock of its own. `now` is
 * always passed in, so the sentences can be tested at a fixed instant.
 */

/* ----------------------------------------------------------------- types -- */

/**
 * How much of your attention a session is asking for, in the order it asks.
 *
 * Derived from `SessionStatus`, which is itself derived two ways in the main
 * process and both are real: `session-activity.ts` classifies the session's
 * *rendered screen* (an `❯` prompt, an unanswered `(y/N)`, a spinner), and
 * `hooks.ts` maps the agent CLIs' own lifecycle hooks onto the same vocabulary
 * (`Stop` → completed, `PermissionRequest` → input).
 *
 * The split between `blocked` and `finished` is the one worth keeping: both are
 * your turn, but a session that asked a question has *stopped mid-task* and one
 * that finished its turn has not. The first is the more urgent of the two and
 * sorts above it.
 */
export type Attention = 'blocked' | 'finished' | 'working' | 'ready' | 'exited'

/** Rank for sorting. Lower is louder. */
const ATTENTION_RANK: Record<Attention, number> = {
  blocked: 0,
  finished: 1,
  working: 2,
  ready: 3,
  exited: 4,
}

/** The order the board groups its cards in. */
export const ATTENTION_ORDER: readonly Attention[] = ['blocked', 'finished', 'working', 'ready', 'exited']

export function attentionOf(status: SessionStatus): Attention {
  switch (status) {
    case 'input':
      return 'blocked'
    case 'completed':
      return 'finished'
    case 'working':
      return 'working'
    case 'exited':
      return 'exited'
    // `waiting` and `idle` are one state to a reader: the session is at a
    // prompt and nothing is happening. `StatusDot` already says "Ready" for
    // both and paints both the same hollow ring; splitting them here would put
    // two words on the board for a distinction nobody can act on.
    case 'waiting':
    case 'idle':
    default:
      return 'ready'
  }
}

/** Whether a card belongs in the "your turn" run at the top. */
export function wantsYou(attention: Attention): boolean {
  return attention === 'blocked' || attention === 'finished'
}

/**
 * Accounting for one session's own transcript.
 *
 * Only ever attached when the transcript could be *ruled in* as this session's
 * — see `pickSessionTranscript` in `renderer/session-transcript.ts`, which
 * exists because "the newest transcript in this folder" once put a stranger's
 * $18.49 under a tab that had done nothing. The board would rather show no
 * money than the wrong money.
 */
export interface SessionWork {
  transcriptPath: string
  /** Deduplicated API requests recorded for this session. */
  requests: number
  /** Every token class summed — input, output and both cache sides. */
  tokens: number
  /** Null when no model in the session had a published rate. Never 0, which reads as free. */
  costUsd: number | null
  /** Occupancy of the context window, or null before the first request. */
  contextPercent: number | null
  /** Epoch ms of the last line written to the transcript. 0 when unknown. */
  lastActivityAt: number
}

/** One card. */
export interface BoardSession {
  id: string
  /**
   * What it is doing, as far as the app can honestly tell.
   *
   * This is `SessionMeta.title`, which `session-title.ts` derives from the
   * conversation's own `custom-title` or `ai-title` line, else its first user
   * prompt, else the terminal's drawn heading, else the folder name. Every one
   * of those is evidence rather than a guess, and the module records which it
   * used.
   */
  title: string
  projectPath: string
  provider: ProviderId
  /** The resolved account, when one applies. A plain shell has no login. */
  account: string | null
  status: SessionStatus
  /** Epoch ms this window first saw this status. See `Session.statusSince`. */
  statusSince: number
  /** `SessionMeta.createdAt` — when the process started. */
  startedAt: number
  work: SessionWork | null
}

/* --------------------------------------------------------------- ranking -- */

/**
 * Board order: loudest first, and within a group the one that has been like
 * that longest.
 *
 * The tiebreak direction is the whole point of the sort. A blocked session that
 * has been ignored for forty minutes is more urgent than one that asked ten
 * seconds ago, so `blocked` and `finished` sort *oldest first*. `working` sorts
 * the other way — the one that has been grinding longest is the least likely to
 * want you — and so does `ready`, where the newest is the one you were last in.
 *
 * A session with no observed `statusSince` (nothing has changed since this
 * window learned about it) sorts as though it began then, which is the only
 * thing that is true about it.
 */
export function sortBoard(sessions: readonly BoardSession[]): BoardSession[] {
  return [...sessions].sort((a, b) => {
    const rank = ATTENTION_RANK[attentionOf(a.status)] - ATTENTION_RANK[attentionOf(b.status)]
    if (rank !== 0) return rank
    const oldestFirst = wantsYou(attentionOf(a.status))
    const at = a.statusSince || a.startedAt
    const bt = b.statusSince || b.startedAt
    if (at !== bt) return oldestFirst ? at - bt : bt - at
    // Stable, readable last resort — two sessions started in the same
    // millisecond happens on restore, where the whole list is rebuilt at once.
    return a.id.localeCompare(b.id)
  })
}

export interface BoardCounts {
  blocked: number
  finished: number
  working: number
  ready: number
  exited: number
  total: number
  /** blocked + finished — the number the summary line leads with. */
  wantsYou: number
}

export function countBoard(sessions: readonly BoardSession[]): BoardCounts {
  const counts: BoardCounts = {
    blocked: 0,
    finished: 0,
    working: 0,
    ready: 0,
    exited: 0,
    total: sessions.length,
    wantsYou: 0,
  }
  for (const session of sessions) {
    const attention = attentionOf(session.status)
    counts[attention] += 1
    if (wantsYou(attention)) counts.wantsYou += 1
  }
  return counts
}

/* --------------------------------------------------------------- wording -- */

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

/**
 * A duration at the coarseness a glance needs.
 *
 * Deliberately shorter-grained than `alerts.ts`'s `formatDuration`, which
 * writes "12 minutes" into a sentence. This one goes into a strip beside four
 * other figures and has to stay narrow, and it keeps seconds because the
 * difference between a session that started working two seconds ago and one
 * that started two minutes ago is visible on this page and matters.
 *
 * Never rounds down to "0s": a duration that has been measured happened.
 */
export function formatElapsed(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return ''
  if (ms < MINUTE) return `${Math.max(1, Math.round(ms / 1000))}s`
  if (ms < HOUR) return `${Math.floor(ms / MINUTE)}m`
  if (ms < DAY) {
    const hours = Math.floor(ms / HOUR)
    const minutes = Math.floor((ms % HOUR) / MINUTE)
    return minutes === 0 ? `${hours}h` : `${hours}h ${minutes}m`
  }
  const days = Math.floor(ms / DAY)
  const hours = Math.floor((ms % DAY) / HOUR)
  return hours === 0 ? `${days}d` : `${days}d ${hours}h`
}

/**
 * Whether the status clock is worth printing.
 *
 * `statusSince` is when *this window* first saw the state, so for a session
 * restored at launch it is the launch, not the moment the agent got stuck. A
 * duration measured from an arrival tells you how long you have had the app
 * open, which is not what the label claims. The rule: only print the clock once
 * the observation is old enough to be about the session rather than about the
 * page — and always print it for a status that arrived as a genuine change,
 * which is every status other than the `idle` a session is added with.
 */
export function statusObserved(session: BoardSession): boolean {
  return session.statusSince > 0 && session.status !== 'idle'
}

/**
 * The line under the title: what it is doing, and for how long.
 *
 * Written as a sentence a person would say. "Waiting on you" is the wording
 * `alerts.ts` already uses for the same state, so the two surfaces agree.
 */
export function stateSentence(session: BoardSession, now: number): string {
  const attention = attentionOf(session.status)
  const elapsed = statusObserved(session) ? formatElapsed(now - session.statusSince) : ''
  const since = elapsed ? ` for ${elapsed}` : ''
  switch (attention) {
    case 'blocked':
      return `Waiting on you${since}`
    case 'finished':
      return `Finished its turn${since}`
    case 'working':
      return `Working${since}`
    case 'exited':
      // Not "Exited" — the chip two lines above already says that word, and a
      // card that says one thing twice has wasted the line it could have used
      // to say *when*. Exiting is always a transition this window observed, so
      // the clock here is real.
      return elapsed ? `Exited ${elapsed} ago` : 'Exited'
    case 'ready':
    default:
      // No clock: `ready` is the state a session is *added* in, so its
      // `statusSince` is usually this window's arrival rather than anything the
      // session did, and "At a prompt for 3 hours" would be reporting how long
      // the app has been open.
      return 'At a prompt'
  }
}

/** The chip on the card. Short, because it sits beside the folder name. */
export function attentionLabel(attention: Attention): string {
  switch (attention) {
    case 'blocked':
      return 'Needs you'
    case 'finished':
      return 'Finished'
    case 'working':
      return 'Working'
    case 'exited':
      return 'Exited'
    case 'ready':
    default:
      return 'Ready'
  }
}

export interface SummaryPart {
  attention: Attention
  text: string
}

/**
 * The summary above the cards, as its parts: "2 need you · 3 working · 1 exited".
 *
 * Parts rather than one string, and that is not a rendering detail. Written as
 * a single string the whole line had to take one colour, so a board with one
 * blocked session painted "1 needs you · 1 working · 1 at a prompt" *entirely*
 * in the alarm colour — which says three things need you when one does, on the
 * one line whose job is to say how many. Each group carries its own tone now,
 * and only the group that means "stop what you are doing" is coloured.
 *
 * Only non-zero groups appear. A strip of five figures where three of them are
 * "0" is four things to read for one fact, and the zeros are the ones the eye
 * has to discard.
 */
export function summaryParts(counts: BoardCounts): SummaryPart[] {
  const parts: SummaryPart[] = []
  if (counts.blocked > 0) {
    parts.push({ attention: 'blocked', text: `${counts.blocked} need${counts.blocked === 1 ? 's' : ''} you` })
  }
  if (counts.finished > 0) parts.push({ attention: 'finished', text: `${counts.finished} finished` })
  if (counts.working > 0) parts.push({ attention: 'working', text: `${counts.working} working` })
  if (counts.ready > 0) parts.push({ attention: 'ready', text: `${counts.ready} at a prompt` })
  if (counts.exited > 0) parts.push({ attention: 'exited', text: `${counts.exited} exited` })
  return parts
}

/** The same summary as one string — for a title attribute, and for the tests. */
export function summaryLine(counts: BoardCounts): string {
  return summaryParts(counts)
    .map((part) => part.text)
    .join(' · ')
}

/** Last path segment. Mirrors `folderName` in `session-title.ts` for Windows too. */
export function folderOf(path: string): string {
  const parts = path.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] ?? path
}

/**
 * How the agent is named on the card.
 *
 * Sentence case rather than the raw `ProviderId`, which is a key, not a word.
 */
const PROVIDER_LABELS: Record<string, string> = {
  claude: 'Claude Code',
  codex: 'Codex',
  gemini: 'Gemini',
  shell: 'Shell',
}

export function providerLabel(provider: string): string {
  return PROVIDER_LABELS[provider] ?? provider
}

/* ------------------------------------------------------------- narrowing -- */

/*
 * Everything below reads answers that crossed the preload bridge as `unknown`.
 * The main-process modules own those types and the renderer tsconfig cannot see
 * `src/main`, so each field is read defensively rather than cast wholesale —
 * the arrangement `widgets.tsx`, `GitPanel.tsx` and `SessionInspector.tsx`
 * already use.
 */

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function numberAt(value: unknown, ...path: string[]): number {
  let cursor: unknown = value
  for (const key of path) {
    if (!isRecord(cursor)) return 0
    cursor = cursor[key]
  }
  return typeof cursor === 'number' && Number.isFinite(cursor) ? cursor : 0
}

/**
 * Pull one session's row out of a `ProjectSummary`.
 *
 * `sessionId` is the *transcript's* id — the name Claude Code gave the
 * conversation — never this window's tab id. They are different namespaces and
 * matching the wrong one silently yields nothing, which reads on screen as "this
 * session has spent nothing" rather than as "we could not tell".
 */
export function workFromSummary(summary: unknown, sessionId: string, transcriptPath: string): SessionWork | null {
  if (!isRecord(summary) || !Array.isArray(summary.sessions)) return null
  const row = summary.sessions.filter(isRecord).find((entry) => entry.sessionId === sessionId)
  if (!row) return null

  const tokens =
    numberAt(row, 'usage', 'input') +
    numberAt(row, 'usage', 'output') +
    numberAt(row, 'usage', 'cacheWrite5m') +
    numberAt(row, 'usage', 'cacheWrite1h') +
    numberAt(row, 'usage', 'cacheRead')

  // `cost.byModel` is empty when nothing in the session had a published rate.
  // The total is then 0, and a `$0.00` beside 40k tokens is a claim that the
  // work was free rather than an admission that it could not be priced.
  const priced = isRecord(row.cost) && isRecord(row.cost.byModel) && Object.keys(row.cost.byModel).length > 0

  // Null before the first request, and it has to stay null: reading a percent
  // off a missing context block yields 0, and "0% of the window" is a reading,
  // not an absence.
  const context = isRecord(row.context) ? row.context : null

  return {
    transcriptPath,
    requests: numberAt(row, 'requests'),
    tokens,
    costUsd: priced ? numberAt(row, 'cost', 'cost', 'total') : null,
    contextPercent: context ? numberAt(context, 'percent') : null,
    lastActivityAt: numberAt(row, 'lastActivityAt'),
  }
}

/**
 * Narrow one live session off `session:list`.
 *
 * Returns null for anything without an id or a folder — a row the board could
 * not open or place is worse than a row that is not there.
 */
export function asSessionMeta(value: unknown): {
  id: string
  cwd: string
  title: string
  provider: ProviderId
  createdAt: number
  exitCode: number | null
  resumed: boolean
  profileName: string | null
} | null {
  if (!isRecord(value)) return null
  const id = typeof value.id === 'string' ? value.id : ''
  const cwd = typeof value.cwd === 'string' ? value.cwd : ''
  if (!id || !cwd) return null
  return {
    id,
    cwd,
    title: typeof value.title === 'string' && value.title ? value.title : folderOf(cwd),
    provider: typeof value.provider === 'string' ? (value.provider as ProviderId) : 'shell',
    createdAt: numberAt(value, 'createdAt'),
    exitCode: typeof value.exitCode === 'number' ? value.exitCode : null,
    resumed: value.resumed === true,
    profileName: typeof value.profileName === 'string' && value.profileName ? value.profileName : null,
  }
}
