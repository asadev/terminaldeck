import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react'
import type { SessionStatus } from '@shared/types'
import { StatusDot } from '../components/StatusDot'
import { cardsInColumn, COLUMN_IDS, COLUMN_TITLES, parseBoard } from '../board/board-state'
// Type-only, so nothing of GitPanel's module — including its CSS import — is
// pulled into this bundle. Those mirrors of `src/main/git.ts` already exist
// there; re-declaring them a third time is how the three copies start to drift.
import type { GitRepoStatus, GitStatusResult } from '../components/GitPanel'
import { WIDGET_TYPES, type WidgetType } from './layout'

/**
 * Widget registry for the project dashboard.
 *
 * Every widget here renders against a data source it does not own, and several
 * of those sources are being built in parallel with this file. So the contract
 * is: a widget must never assume its channel exists. It probes the preload
 * bridge by name, and a missing method is a first-class state — "not wired up
 * yet" — rather than a thrown error that takes the whole dashboard with it.
 *
 * The four states every widget can be in are loading, ready, empty and
 * unavailable/error. `WidgetMessage` renders the three that are not "ready", so
 * they look the same everywhere and no widget invents its own spinner.
 */

/* ------------------------------------------------------------- the bridge -- */

type BridgeFn = (...args: unknown[]) => unknown

/**
 * Look a method up on the preload bridge at call time.
 *
 * Resolved per call rather than cached because the bridge is installed before
 * the renderer runs but the *handlers* behind it are registered by whichever
 * main-process modules made it into this build. A widget that captured a
 * missing method at mount would stay broken for the life of the window.
 */
function bridgeMethod(name: string): BridgeFn | null {
  const api = (globalThis as { pawl?: Record<string, unknown> }).pawl
  if (!api) return null
  const fn = api[name]
  return typeof fn === 'function' ? (fn as BridgeFn) : null
}

export type AsyncState<T> =
  | { status: 'loading' }
  | { status: 'unavailable'; method: string }
  | { status: 'error'; message: string }
  | { status: 'ready'; data: T }

function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message
  return typeof err === 'string' ? err : 'Unknown error'
}

/**
 * Load a widget's data from the preload bridge.
 *
 * `method` may be a list of candidate names, first match wins. The main-process
 * modules own their channels but the orchestrator names the bridge methods, and
 * a widget that guessed `githubOverview` when the wiring said `getGitHubOverview`
 * would sit there claiming the feature does not exist. The first name is the
 * preferred one and the only one the "not wired up" message mentions.
 *
 * `depKey` is a plain string rather than a dependency array so the effect's
 * dependency list can never change length between renders; every widget here
 * depends on the project path and nothing else.
 */
export function useBridgeData<T>(
  method: string | readonly string[],
  depKey: string,
  run: (call: BridgeFn) => Promise<T>,
  options: { enabled?: boolean } = {},
): { state: AsyncState<T>; reload: () => void } {
  const [state, setState] = useState<AsyncState<T>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const enabled = options.enabled ?? true
  // Joined so the dependency is a primitive; the array itself is a fresh
  // literal on every render and would restart the effect forever.
  const names = typeof method === 'string' ? method : method.join(',')

  // The caller passes a fresh closure every render; holding the latest in a ref
  // keeps it out of the dependency list, which would otherwise refetch forever.
  const runRef = useRef(run)
  runRef.current = run

  useEffect(() => {
    // A widget whose host already handed it the data still has to call this
    // hook — hooks cannot be conditional — but it must not also go and fetch.
    if (!enabled) return

    const candidates = names.split(',')
    const call = candidates.reduce<BridgeFn | null>((found, name) => found ?? bridgeMethod(name), null)
    if (!call) {
      setState({ status: 'unavailable', method: candidates[0] })
      return
    }

    let stale = false
    setState({ status: 'loading' })
    runRef.current(call)
      .then((data) => {
        // A slow load for project A must not land after the user has moved to B.
        if (!stale) setState({ status: 'ready', data })
      })
      .catch((err: unknown) => {
        if (!stale) setState({ status: 'error', message: errorMessage(err) })
      })

    return () => {
      stale = true
    }
  }, [names, depKey, nonce, enabled])

  const reload = useCallback(() => setNonce((n) => n + 1), [])
  return { state, reload }
}

/* ------------------------------------------------------------ presentation -- */

export interface WidgetMessageProps {
  tone: 'muted' | 'error'
  title: string
  detail?: string
  action?: { label: string; onClick: () => void }
}

/** The shared not-ready state: loading, empty, unavailable and error all land here. */
export function WidgetMessage({ tone, title, detail, action }: WidgetMessageProps): ReactElement {
  return (
    <div className={`widget-message ${tone}`}>
      <p className="widget-message-title">{title}</p>
      {detail && <p className="widget-message-detail">{detail}</p>}
      {action && (
        <button type="button" className="widget-message-action" onClick={action.onClick}>
          {action.label}
        </button>
      )}
    </div>
  )
}

/**
 * Render the three not-ready states, or hand the data to `children`.
 *
 * Written as a function rather than a component so the `data` handed to
 * `children` is narrowed by TypeScript at the call site.
 */
function renderState<T>(
  state: AsyncState<T>,
  reload: () => void,
  pending: string,
  children: (data: T) => ReactElement,
): ReactElement {
  if (state.status === 'loading') return <WidgetMessage tone="muted" title={pending} />
  if (state.status === 'unavailable') {
    return (
      <WidgetMessage
        tone="muted"
        title="Not wired up yet"
        detail={`This widget needs \`${state.method}\` on the preload bridge.`}
      />
    )
  }
  if (state.status === 'error') {
    return (
      <WidgetMessage
        tone="error"
        title="Could not load"
        detail={state.message}
        action={{ label: 'Retry', onClick: reload }}
      />
    )
  }
  return children(state.data)
}

/** A label and a value, the unit every widget's summary row is built from. */
function Stat({ label, value, tone }: { label: string; value: string; tone?: 'warn' | 'crit' }) {
  return (
    <div className="widget-stat">
      <span className={`widget-stat-value${tone ? ` ${tone}` : ''}`}>{value}</span>
      <span className="widget-stat-label">{label}</span>
    </div>
  )
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * Money and token formatting mirroring `formatUsd`/`formatTokens` in
 * `src/main/cost.ts`. Duplicated for the same reason GitPanel duplicates the
 * git types: the renderer tsconfig cannot see `src/main`. The `cost:format`
 * channel exists for the exact strings, but a round trip to the main process
 * per number is not worth it for a tile that redraws on every git change.
 */
function formatUsd(usd: number): string {
  const abs = Math.abs(usd)
  if (abs === 0) return '$0.00'
  if (abs < 0.01) return `$${usd.toFixed(4)}`
  if (abs < 10) return `$${usd.toFixed(3)}`
  return `$${usd.toFixed(2)}`
}

function formatTokens(tokens: number): string {
  const abs = Math.abs(tokens)
  // Below this the `k` form rounds to `1000.0` and renders as "1000k".
  if (abs >= 999_950) return `${(tokens / 1_000_000).toFixed(2).replace(/\.?0+$/, '')}M`
  if (abs >= 1000) return `${(tokens / 1000).toFixed(1).replace(/\.0$/, '')}k`
  return String(Math.round(tokens))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Row caps. A widget is a summary, and a repo mid-rebase or a monorepo with a
 * stale `.gitignore` can put tens of thousands of entries in one list. Whatever
 * is cut has to be *said*, though — a list that silently stops is a list the
 * reader trusts to be complete.
 */
const MAX_FILE_ROWS = 40
const MAX_GITHUB_ROWS = 30

function numberAt(value: unknown, ...path: string[]): number {
  let cursor: unknown = value
  for (const key of path) {
    if (!isRecord(cursor)) return 0
    cursor = cursor[key]
  }
  return typeof cursor === 'number' && Number.isFinite(cursor) ? cursor : 0
}

/* ---------------------------------------------------------------- context -- */

/** One session as the dashboard needs it — a subset of the renderer store's. */
export interface DashboardSession {
  id: string
  title: string
  provider: string
  status: SessionStatus
}

export interface WidgetContext {
  /** Absolute path of the project this dashboard belongs to. */
  projectPath: string
  /**
   * Live sessions for this project, when the host has them. Omitted rather
   * than empty means "the host did not supply any", and the widget falls back
   * to asking the main process.
   */
  sessions?: readonly DashboardSession[]
  onOpenSession?: (id: string) => void
  /** Jump to the project's full board, git panel, and so on. */
  onNavigate?: (target: 'board' | 'git' | 'sessions') => void
}

export interface WidgetDefinition {
  type: WidgetType
  title: string
  /** One line for the widget picker. */
  description: string
  Component: (props: { context: WidgetContext }) => ReactElement
}

/* --------------------------------------------------------------- sessions -- */

function SessionsWidget({ context }: { context: WidgetContext }): ReactElement {
  const { projectPath, sessions, onOpenSession } = context
  const hostSupplied = sessions !== undefined

  const { state, reload } = useBridgeData<DashboardSession[]>(
    'listSessions',
    projectPath,
    useCallback(
      async (call) => {
        const raw = (await call()) as unknown
        if (!Array.isArray(raw)) return []
        return raw.filter(isRecord).flatMap((entry): DashboardSession[] => {
          if (entry.cwd !== projectPath) return []
          const id = typeof entry.id === 'string' ? entry.id : ''
          if (!id) return []
          return [
            {
              id,
              title: typeof entry.title === 'string' ? entry.title : id,
              provider: typeof entry.provider === 'string' ? entry.provider : 'shell',
              // `listSessions` returns persisted metadata, which carries no live
              // status; the host's copy has it, this fallback cannot.
              status: entry.exitCode === null ? 'idle' : 'exited',
            },
          ]
        })
      },
      [projectPath],
    ),
    { enabled: !hostSupplied },
  )

  const list = hostSupplied ? sessions : state.status === 'ready' ? state.data : []
  const body = (rows: readonly DashboardSession[]): ReactElement => {
    if (rows.length === 0) {
      return (
        <WidgetMessage
          tone="muted"
          title="No sessions yet"
          detail="Start one from the sidebar to see it here."
        />
      )
    }
    const live = rows.filter((s) => s.status === 'working' || s.status === 'waiting' || s.status === 'input')
    return (
      <>
        <div className="widget-stats">
          <Stat label="sessions" value={String(rows.length)} />
          <Stat label="running" value={String(live.length)} />
        </div>
        <ul className="widget-list">
          {rows.map((session) => (
            <li key={session.id}>
              <button
                type="button"
                className="widget-row"
                // Without a handler the row is not a control; a button that
                // does nothing is worse than plain text.
                disabled={!onOpenSession}
                onClick={() => onOpenSession?.(session.id)}
              >
                <StatusDot status={session.status} />
                <span className="widget-row-main">{session.title}</span>
                <span className="widget-row-side">{session.provider}</span>
              </button>
            </li>
          ))}
        </ul>
      </>
    )
  }

  if (hostSupplied) return body(list)
  return renderState(state, reload, 'Looking for sessions…', body)
}

/* ------------------------------------------------------------------- cost -- */

interface CostView {
  total: number
  requests: number
  tokens: number
  sessions: number
  contextPercent: number | null
  unpriced: string[]
  scanning: boolean
}

function CostWidget({ context }: { context: WidgetContext }): ReactElement {
  const { projectPath } = context
  const { state, reload } = useBridgeData<CostView>(
    'getProjectCost',
    projectPath,
    useCallback(async (call) => {
      // `cost:project` hands back a ProjectSummary as `unknown` — the main
      // process owns that type and the renderer cannot import it, so every
      // field is read defensively rather than cast wholesale.
      const raw = (await call(projectPath)) as unknown
      const sessions = isRecord(raw) && Array.isArray(raw.sessions) ? raw.sessions : []
      const usage = isRecord(raw) ? raw.usage : undefined
      const tokens =
        numberAt(usage, 'input') +
        numberAt(usage, 'output') +
        numberAt(usage, 'cacheWrite5m') +
        numberAt(usage, 'cacheWrite1h') +
        numberAt(usage, 'cacheRead')

      const activeId = isRecord(raw) && typeof raw.activeSessionId === 'string' ? raw.activeSessionId : null
      const active = sessions.filter(isRecord).find((s) => s.sessionId === activeId)
      // `context` is null until a session has made its first request. Reading a
      // percent off that yields 0, and a meter reading "0% of the context
      // window" is a claim, not an absence — so it has to stay null.
      const context = active && isRecord(active.context) ? active.context : null

      const unpriced =
        isRecord(raw) && isRecord(raw.cost) && Array.isArray(raw.cost.unpricedModels)
          ? raw.cost.unpricedModels.filter((m): m is string => typeof m === 'string')
          : []

      return {
        total: numberAt(raw, 'cost', 'cost', 'total'),
        requests: numberAt(raw, 'requests'),
        tokens,
        sessions: sessions.length,
        contextPercent: context ? numberAt(context, 'percent') : null,
        unpriced,
        scanning: isRecord(raw) && raw.scanning === true,
      }
    }, [projectPath]),
  )

  return renderState(state, reload, 'Reading transcripts…', (data) => {
    if (data.requests === 0) {
      return (
        <WidgetMessage
          tone="muted"
          title={data.scanning ? 'Still scanning…' : 'Nothing recorded yet'}
          detail="Cost appears once a Claude Code session has written a transcript for this folder."
        />
      )
    }

    // Percent can exceed 100 — auto-compaction fires at the limit, so the last
    // request before it tips slightly over. Clamp the bar, not the number.
    const percent = data.contextPercent
    const tone = percent === null ? undefined : percent >= 90 ? 'crit' : percent >= 70 ? 'warn' : undefined

    return (
      <>
        <div className="widget-stats">
          <Stat label="spent" value={formatUsd(data.total)} />
          <Stat label="tokens" value={formatTokens(data.tokens)} />
          <Stat label="requests" value={String(data.requests)} />
          <Stat label="sessions" value={String(data.sessions)} />
        </div>

        {percent !== null && (
          <div className="widget-meter">
            <div className="widget-meter-head">
              <span>Context window</span>
              <span className={tone ? `widget-stat-value ${tone}` : undefined}>
                {Math.round(percent)}%
              </span>
            </div>
            <div
              className="widget-meter-track"
              role="progressbar"
              aria-valuenow={Math.round(percent)}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-label="Context window in use"
            >
              <div
                className={`widget-meter-fill${tone ? ` ${tone}` : ''}`}
                style={{ width: `${Math.min(100, Math.max(0, percent))}%` }}
              />
            </div>
          </div>
        )}

        {data.unpriced.length > 0 && (
          <p className="widget-note">
            {data.unpriced.length} model{data.unpriced.length === 1 ? '' : 's'} had no rate — this
            total is a floor.
          </p>
        )}
      </>
    )
  })
}

/* -------------------------------------------------------------------- git -- */

/**
 * The rows a git widget shows, and how many it is not showing.
 *
 * Pulled out of the component because the count and the list have to be two
 * views of one array. When they were computed separately the sum left out
 * `conflicted`, so a repo mid-merge showed a truncated list under a note that
 * said nothing had been left out.
 */
export function visibleGitFiles(
  status: Pick<GitRepoStatus, 'conflicted' | 'staged' | 'unstaged' | 'untracked'>,
  limit = MAX_FILE_ROWS,
): { shown: GitRepoStatus['staged']; hidden: number } {
  const files = [...status.conflicted, ...status.staged, ...status.unstaged, ...status.untracked]
  const shown = files.slice(0, Math.max(0, limit))
  return { shown, hidden: files.length - shown.length }
}

function GitWidget({ context }: { context: WidgetContext }): ReactElement {
  const { projectPath, onNavigate } = context
  const { state, reload } = useBridgeData<GitStatusResult>(
    'gitStatus',
    projectPath,
    useCallback(async (call) => (await call(projectPath)) as GitStatusResult, [projectPath]),
  )

  // Live updates when the git watcher is running. Subscribing is optional —
  // the widget is correct without it, just staler.
  const [live, setLive] = useState<GitRepoStatus | null>(null)
  useEffect(() => {
    setLive(null)
    const subscribe = bridgeMethod('onGitStatus')
    const watch = bridgeMethod('watchGit')
    if (!subscribe) return
    void watch?.(projectPath)

    const off = subscribe((cwd: unknown, status: unknown) => {
      if (cwd !== projectPath || !isRecord(status) || status.repo !== true) return
      setLive(status as unknown as GitRepoStatus)
    })

    return () => {
      if (typeof off === 'function') (off as () => void)()
      const unwatch = bridgeMethod('unwatchGit')
      unwatch?.(projectPath)
    }
  }, [projectPath])

  return renderState(state, reload, 'Reading the repo…', (loaded) => {
    const status = live ?? loaded
    if (!status.repo) {
      return (
        <WidgetMessage
          tone="muted"
          title={status.reason === 'not-a-repo' ? 'Not a git repository' : 'Git unavailable'}
          detail={status.message}
        />
      )
    }

    const { shown, hidden } = visibleGitFiles(status)
    return (
      <>
        <div className="widget-branch">
          <span className="widget-branch-name">
            {status.branch.detached
              ? `detached at ${status.branch.oid?.slice(0, 7) ?? '—'}`
              : (status.branch.name ?? 'no branch yet')}
          </span>
          {(status.branch.ahead > 0 || status.branch.behind > 0) && (
            <span className="widget-branch-sync">
              {status.branch.ahead > 0 && <span title="Commits to push">↑{status.branch.ahead}</span>}
              {status.branch.behind > 0 && <span title="Commits to pull">↓{status.branch.behind}</span>}
            </span>
          )}
        </div>

        {status.clean ? (
          <WidgetMessage tone="muted" title="Working tree clean" />
        ) : (
          <>
            <div className="widget-stats">
              <Stat label="staged" value={String(status.staged.length)} />
              <Stat label="changed" value={String(status.unstaged.length)} />
              <Stat label="untracked" value={String(status.untracked.length)} />
              {status.conflicted.length > 0 && (
                <Stat label="conflicts" value={String(status.conflicted.length)} tone="crit" />
              )}
            </div>
            <ul className="widget-list">
              {shown.map((file) => (
                <li key={`${file.group}:${file.path}`}>
                  <span className="widget-row static">
                    <span className={`widget-code ${file.group}`}>{file.code.trim() || '?'}</span>
                    <span className="widget-row-main mono">{file.path}</span>
                  </span>
                </li>
              ))}
            </ul>
            {hidden > 0 && <p className="widget-note">…and {hidden} more.</p>}
          </>
        )}

        {onNavigate && (
          <button type="button" className="widget-message-action" onClick={() => onNavigate('git')}>
            Open git panel
          </button>
        )}
      </>
    )
  })
}

/* ----------------------------------------------------------------- kanban -- */

function KanbanWidget({ context }: { context: WidgetContext }): ReactElement {
  const { projectPath, onNavigate } = context
  const { state, reload } = useBridgeData(
    'loadBoard',
    projectPath,
    useCallback(
      async (call) => parseBoard((await call(projectPath)) as unknown, projectPath),
      [projectPath],
    ),
  )

  return renderState(state, reload, 'Opening the board…', (board) => {
    const columns = COLUMN_IDS.map((id) => ({ id, cards: cardsInColumn(board, id) }))
    const total = columns.reduce((n, column) => n + column.cards.length, 0)
    if (total === 0) {
      return (
        <WidgetMessage
          tone="muted"
          title="Board is empty"
          detail="Cards you add on the board show up here."
          action={onNavigate ? { label: 'Open board', onClick: () => onNavigate('board') } : undefined}
        />
      )
    }

    const next = columns.find((column) => column.id === 'todo')?.cards ?? []
    return (
      <>
        <div className="widget-stats">
          {columns.map((column) => (
            <Stat key={column.id} label={COLUMN_TITLES[column.id]} value={String(column.cards.length)} />
          ))}
        </div>
        {next.length > 0 && (
          <ul className="widget-list">
            {next.slice(0, 12).map((card) => (
              <li key={card.id}>
                <span className="widget-row static">
                  <span className="widget-row-main">{card.title}</span>
                  {card.tags.length > 0 && <span className="widget-row-side">{card.tags[0]}</span>}
                </span>
              </li>
            ))}
          </ul>
        )}
        {onNavigate && (
          <button type="button" className="widget-message-action" onClick={() => onNavigate('board')}>
            Open board
          </button>
        )}
      </>
    )
  })
}

/* -------------------------------------------------------------- readiness -- */

/** Mirrors `ReadinessStatus` in `src/main/readiness.ts`. */
type ReadinessStatus = 'pass' | 'warn' | 'fail' | 'skip'

interface ReadinessView {
  score: number
  band: string
  cappedBy: string | null
  checks: Array<{ id: string; title: string; status: ReadinessStatus; gate: boolean }>
}

function isReadinessStatus(value: unknown): value is ReadinessStatus {
  return value === 'pass' || value === 'warn' || value === 'fail' || value === 'skip'
}

function ReadinessWidget({ context }: { context: WidgetContext }): ReactElement {
  const { projectPath } = context
  const { state, reload } = useBridgeData<ReadinessView>(
    ['scanReadiness', 'getReadiness', 'readinessScan'],
    projectPath,
    useCallback(async (call) => {
      // `readiness:scan` returns a ReadinessReport, owned by the main process
      // and unreachable from the renderer tsconfig, so it is read defensively.
      const raw = (await call(projectPath)) as unknown
      const checks = isRecord(raw) && Array.isArray(raw.checks) ? raw.checks : []
      return {
        score: Math.round(numberAt(raw, 'score')),
        band: isRecord(raw) && typeof raw.band === 'string' ? raw.band : '',
        cappedBy: isRecord(raw) && typeof raw.cappedBy === 'string' ? raw.cappedBy : null,
        checks: checks.filter(isRecord).map((check, i) => ({
          id: typeof check.id === 'string' ? check.id : String(i),
          title: typeof check.title === 'string' ? check.title : 'Check',
          status: isReadinessStatus(check.status) ? check.status : 'skip',
          gate: check.gate === true,
        })),
      }
    }, [projectPath]),
  )

  return renderState(state, reload, 'Scoring the project…', (data) => {
    const tone = data.score >= 80 ? undefined : data.score >= 50 ? 'warn' : 'crit'
    // Skipped checks are out of the denominator — a Rust project is not marked
    // down for having no npm test script, so it must not read as 8/10 either.
    const applicable = data.checks.filter((check) => check.status !== 'skip')
    const passing = applicable.filter((check) => check.status === 'pass')
    // Failures first, then warnings: the top of a short list is the only part
    // a half-height widget shows, and it should be the part that needs work.
    const order: Record<ReadinessStatus, number> = { fail: 0, warn: 1, pass: 2, skip: 3 }
    const sorted = [...data.checks].sort((a, b) => order[a.status] - order[b.status])

    return (
      <>
        <div className="widget-stats">
          <Stat label={data.band || 'readiness'} value={`${data.score}%`} tone={tone} />
          <Stat label="passing" value={`${passing.length}/${applicable.length}`} />
        </div>
        {data.cappedBy && <p className="widget-note">Held back by: {data.cappedBy}</p>}
        <ul className="widget-list">
          {sorted.map((check) => (
            <li key={check.id}>
              <span className="widget-row static">
                <span
                  className={`widget-check ${check.status}`}
                  title={check.gate ? 'Caps the whole score until it passes' : undefined}
                  aria-hidden="true"
                />
                <span className="widget-row-main">{check.title}</span>
                <span className="widget-row-side">{check.status}</span>
              </span>
            </li>
          ))}
        </ul>
      </>
    )
  })
}

/* ----------------------------------------------------------------- github -- */

interface GithubItem {
  key: string
  number: number
  title: string
  kind: 'pr' | 'issue'
}

interface GithubView {
  /** Null when the whole overview failed rather than an individual section. */
  repo: string | null
  failure: string | null
  /** Per-section failures — `gh` can answer for pulls and not for issues. */
  partial: string[]
  items: GithubItem[]
}

/**
 * Read one `Section<T[]>` off the overview. A section carries its own outcome,
 * so a widget that only checked the top-level `ok` would render "nothing open"
 * over an auth error that lost half the payload.
 */
export function readSection(
  source: Record<string, unknown>,
  key: string,
  kind: 'pr' | 'issue',
): { items: GithubItem[]; error: string | null } {
  const section = source[key]
  if (!isRecord(section)) return { items: [], error: null }
  if (section.ok !== true) {
    return { items: [], error: typeof section.message === 'string' ? section.message : `${key} unavailable` }
  }
  const value = Array.isArray(section.value) ? section.value : []
  return {
    // Keyed on the position, with the number only as a readable suffix. Keying
    // on `number || i` collides the moment an entry arrives without one: a
    // numberless item at index 1 and a real `#1` produce the same key, and
    // React then reuses one row's state for the other.
    items: value.filter(isRecord).map((item, i) => ({
      key: `${kind}-${i}-${numberAt(item, 'number')}`,
      number: numberAt(item, 'number'),
      title: typeof item.title === 'string' ? item.title : 'Untitled',
      kind,
    })),
    error: null,
  }
}

function GithubWidget({ context }: { context: WidgetContext }): ReactElement {
  const { projectPath } = context
  const { state, reload } = useBridgeData<GithubView>(
    ['githubOverview', 'getGitHubOverview', 'githubSummary'],
    projectPath,
    useCallback(async (call) => {
      // `github:overview` returns GitHubOverview | GitHubFailure and never
      // throws — every failure is a value this widget has to render.
      const raw = (await call(projectPath)) as unknown
      if (!isRecord(raw)) return { repo: null, failure: 'No answer from gh.', partial: [], items: [] }
      if (raw.ok !== true) {
        return {
          repo: null,
          failure: typeof raw.message === 'string' ? raw.message : 'GitHub is unavailable.',
          partial: [],
          items: [],
        }
      }

      const pulls = readSection(raw, 'pulls', 'pr')
      const issues = readSection(raw, 'issues', 'issue')
      return {
        repo: isRecord(raw.repo) && typeof raw.repo.nameWithOwner === 'string' ? raw.repo.nameWithOwner : null,
        failure: null,
        partial: [pulls.error, issues.error].filter((e): e is string => e !== null),
        items: [...pulls.items, ...issues.items],
      }
    }, [projectPath]),
  )

  return renderState(state, reload, 'Asking gh…', (data) => {
    if (data.failure) {
      return (
        <WidgetMessage
          tone="muted"
          title="GitHub unavailable"
          detail={data.failure}
          action={{ label: 'Retry', onClick: reload }}
        />
      )
    }

    const prs = data.items.filter((item) => item.kind === 'pr')
    const issues = data.items.filter((item) => item.kind === 'issue')

    return (
      <>
        {data.repo && <p className="widget-note mono">{data.repo}</p>}
        {data.items.length === 0 && data.partial.length === 0 ? (
          <WidgetMessage tone="muted" title="Nothing open" detail="No open pull requests or issues." />
        ) : (
          <>
            <div className="widget-stats">
              <Stat label="pull requests" value={String(prs.length)} />
              <Stat label="issues" value={String(issues.length)} />
            </div>
            <ul className="widget-list">
              {data.items.slice(0, MAX_GITHUB_ROWS).map((item) => (
                <li key={item.key}>
                  <span className="widget-row static">
                    <span className="widget-row-side mono">#{item.number}</span>
                    <span className="widget-row-main">{item.title}</span>
                    <span className="widget-row-side">{item.kind === 'pr' ? 'PR' : 'issue'}</span>
                  </span>
                </li>
              ))}
            </ul>
            {data.items.length > MAX_GITHUB_ROWS && (
              <p className="widget-note">…and {data.items.length - MAX_GITHUB_ROWS} more.</p>
            )}
          </>
        )}
        {data.partial.map((message) => (
          <p key={message} className="widget-note">
            {message}
          </p>
        ))}
      </>
    )
  })
}

/* --------------------------------------------------------------- registry -- */

export const WIDGET_DEFINITIONS: Readonly<Record<WidgetType, WidgetDefinition>> = {
  sessions: {
    type: 'sessions',
    title: 'Sessions',
    description: 'Agent sessions running in this project, and what each one is doing.',
    Component: SessionsWidget,
  },
  cost: {
    type: 'cost',
    title: 'Cost',
    description: 'Spend, tokens and context-window pressure, read from Claude Code transcripts.',
    Component: CostWidget,
  },
  git: {
    type: 'git',
    title: 'Git',
    description: 'Branch, ahead/behind, and every file the working tree has touched.',
    Component: GitWidget,
  },
  kanban: {
    type: 'kanban',
    title: 'Board',
    description: 'Card counts per column and what is next up on the project board.',
    Component: KanbanWidget,
  },
  readiness: {
    type: 'readiness',
    title: 'AI Readiness',
    description: 'Whether this project gives an agent what it needs: docs, tests, lint, clean tree.',
    Component: ReadinessWidget,
  },
  github: {
    type: 'github',
    title: 'GitHub',
    description: 'Open pull requests and issues for the repo, via the local gh CLI.',
    Component: GithubWidget,
  },
}

export function getWidgetDefinition(type: WidgetType): WidgetDefinition | undefined {
  return Object.prototype.hasOwnProperty.call(WIDGET_DEFINITIONS, type)
    ? WIDGET_DEFINITIONS[type]
    : undefined
}

/** Every definition, in the order the picker offers them. */
export function listWidgetDefinitions(): WidgetDefinition[] {
  return WIDGET_TYPES.flatMap((type) => {
    const definition = getWidgetDefinition(type)
    return definition ? [definition] : []
  })
}
