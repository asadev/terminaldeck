import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react'
import type { SessionStatus } from '@shared/types'
import { StatusDot } from '../components/StatusDot'
import { readFailure, withDeadline } from '../deadline'
// Type-only, so nothing of GitPanel's module — including its CSS import — is
// pulled into this bundle. Those mirrors of `src/main/git.ts` already exist
// there; re-declaring them a third time is how the three copies start to drift.
import type { GitChangeKind, GitRepoStatus, GitStatusResult } from '../components/GitPanel'
import type { PanelId } from '../shell/panels'
import { isRetiredWidget, WIDGET_TYPES, type WidgetType } from './layout'

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
  const api = (globalThis as { deck?: Record<string, unknown> }).deck
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
  if (err instanceof Error || typeof err === 'string') return readFailure(err)
  return 'Unknown error'
}

/**
 * How long a widget's read has to answer.
 *
 * Every tile on this page is a sentence until its data lands, and two of them —
 * "Reading transcripts…" and "Reading the repo…" — were caught in the recording
 * still saying it minutes later, on an Overview page the user had left open.
 * Nothing here had a deadline, so a bridge call that never settled left the
 * tile on its sentence for the life of the window with no error, no retry and
 * nothing in the console.
 *
 * Twelve seconds. The slowest honest read behind these tiles is the cost scan,
 * which totals a project's transcripts in the main process under its own
 * budget; past twelve it has not started rather than not finished.
 */
export const WIDGET_DEADLINE_MS = 12_000

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
  /**
   * `what` names the read in the sentence printed if it never answers, in the
   * widget's own words rather than a channel name — the person looking at a
   * tile did not ask for `listSessions`. It is the same phrase the widget hands
   * `renderState`, minus the ellipsis.
   */
  options: { enabled?: boolean; what?: string } = {},
): { state: AsyncState<T>; reload: () => void } {
  const [state, setState] = useState<AsyncState<T>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const enabled = options.enabled ?? true
  const what = options.what ?? 'This widget’s data'
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
    /*
     * The deadline is the whole reason this line changed.
     *
     * Every state below `loading` was reachable before — unavailable, error,
     * ready — and `loading` was not: nothing in this hook could ever leave it
     * if the promise did not settle. Two tiles on the Overview page were caught
     * exactly there. Now the read is guaranteed to end, and every ending has a
     * Retry beside it (see `renderState`).
     */
    withDeadline(runRef.current(call), what, WIDGET_DEADLINE_MS)
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
  }, [names, depKey, nonce, enabled, what])

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

/**
 * A label and a value — and, where there is somewhere to go, a door.
 *
 * Rule 1.2: a number you cannot click into is a dead end. Every count on this
 * dashboard is a count *of* something the app can already show, so the tile
 * says how many and the click says which. `onClick` is optional and the
 * affordance follows it exactly (rule 1.1): with a destination it is a button
 * that lifts under the pointer, without one it is text.
 *
 * A zero never gets a destination. "Untracked 0" that navigates to an empty
 * list is a worse answer than a number that sits still.
 */
function Stat({
  label,
  value,
  tone,
  onClick,
  goes,
}: {
  label: string
  value: string
  tone?: 'warn' | 'crit'
  onClick?: () => void
  /** Where the click lands, for the tooltip. Required whenever onClick is. */
  goes?: string
}) {
  const body = (
    <>
      <span className={`widget-stat-value${tone ? ` ${tone}` : ''}`}>{value}</span>
      <span className="widget-stat-label">{label}</span>
    </>
  )
  if (!onClick) return <div className="widget-stat">{body}</div>
  return (
    <button type="button" className="widget-stat is-link" title={goes} onClick={onClick}>
      {body}
    </button>
  )
}

/** A count that only becomes a door when there is something behind it. */
function doorIf(open: boolean, run: () => void): (() => void) | undefined {
  return open ? run : undefined
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * Token formatting mirroring `formatTokens` in `src/main/cost.ts`. Duplicated
 * for the same reason GitPanel duplicates the git types: the renderer tsconfig
 * cannot see `src/main`. The `cost:format` channel exists for the exact
 * strings, but a round trip to the main process per number is not worth it for
 * a tile that redraws on every git change.
 *
 * A `formatUsd` lived here too, one of three hand copies in the renderer. It is
 * gone with every other dollar figure in the app — the argument is at the
 * bottom of `src/main/cost.ts`, and `widgets.test.tsx` fails if a `$` comes
 * back to this tile.
 */
export function formatTokens(tokens: number): string {
  const abs = Math.abs(tokens)
  // The M tier used to be the last one, so a project with four billion cached
  // tokens read "4622.27M" — a number nobody can size at a glance, in a tile
  // whose whole job is being read at a glance. Each threshold is just under its
  // unit so the tier below never rounds up into a "1000k".
  if (abs >= 999_999_500) return `${(tokens / 1_000_000_000).toFixed(2).replace(/\.?0+$/, '')}B`
  if (abs >= 999_950) return `${(tokens / 1_000_000).toFixed(2).replace(/\.?0+$/, '')}M`
  if (abs >= 1000) return `${(tokens / 1000).toFixed(1).replace(/\.0$/, '')}k`
  return String(Math.round(tokens))
}

/** "1 session", not "1 sessions". */
export function plural(count: number, singular: string, pluralForm = `${singular}s`): string {
  return count === 1 ? singular : pluralForm
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
  /**
   * Open one of the sidebar's views, optionally deep-linked to a section of it
   * — `('git', 'staged')`, `('github', 'issues')`. Widened from a three-value
   * union: the dashboard counts things that live on six different pages, and
   * the ones it could not name were the ones whose counts did nothing.
   */
  onNavigate?: (panel: PanelId, focus?: string) => void
  /** Every session at once — swarm view, which is where a session count goes. */
  onShowSessions?: () => void
  /** Session details, which is the page behind a context-window reading. */
  onOpenInspector?: () => void
  /** Open a project-relative path on the Files page. */
  onOpenFile?: (relPath: string) => void
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
  const { projectPath, sessions, onOpenSession, onShowSessions } = context
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
    { enabled: !hostSupplied, what: 'Looking for sessions' },
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
          <Stat
            label={plural(rows.length, 'session')}
            value={String(rows.length)}
            goes="Show them all at once"
            onClick={doorIf(rows.length > 0 && Boolean(onShowSessions), () => onShowSessions?.())}
          />
          <Stat
            label="running"
            value={String(live.length)}
            // The first one that is actually doing something, which is what
            // someone reading "running 2" wants to look at.
            goes={live[0] ? `Go to ${live[0].title}` : undefined}
            onClick={doorIf(live.length > 0 && Boolean(onOpenSession), () =>
              onOpenSession?.(live[0].id),
            )}
          />
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

/* ------------------------------------------------------------------ usage -- */

/*
 * This tile used to be the Cost tile and it showed money. It does not any more,
 * and this is where all of it was deleted. Read this before putting one back.
 *
 * It carried two figures at once — `$100–200 on plan` beside `$2 on API` — and
 * then, after the plan half was deleted for being the subscription's own
 * package price, a single `$4558 at API rates`. Asad, on the survivor: *"people
 * are using subscription and we are showing API price. So if we cannot show the
 * both, let's not show any of them completely."*
 *
 * He is right, and the reason is not that the arithmetic was wrong. The API
 * figure was correct — it just describes a bill nobody on a subscription
 * received. The subscription figure cannot be computed at all, because
 * Anthropic publishes no token allowance and no per-token value for any plan.
 * One number misleads and the other is unknowable, so there is no honest pair
 * and no honest single. The full argument, with the sources and what would have
 * to change, is at the bottom of `src/main/cost.ts`.
 *
 * Deleted from this file with it: `formatUsd`, `RATES_VERIFIED_ON`,
 * `PLAN_LABELS`, `planKey`, `planName`, `usePlan`, `CostParts`'s money twin,
 * `CostLine`, `costLines`, `formatRate`, and the `legacyModels` / `legacySpend`
 * / `unpriced` caveats, every one of which existed to qualify a price. Before
 * them went `PLAN_PRICES`, `planFee`, `billingMonths`, `MS_PER_BILLING_MONTH`
 * and `formatUsdRange`.
 *
 * What is left is what was always true underneath: tokens, the cache hit rate
 * that explains their shape, the request and session counts, and the context
 * meter. The tile lost a stat and kept its four, so nothing on it is a gap.
 */

/*
   `UsageSessionRow` was here — one transcript's id, model, requests and tokens.
   It fed a thirty-five-row list under the breakdown, which is deleted; see the
   note where it was rendered in `UsageReadout`.
*/

/** Which session the context reading belongs to, and what it is measured against. */
interface ContextOwner {
  /** Transcript session id. Shown truncated, the way the breakdown rows are. */
  id: string
  model: string
  percent: number
  /** Prompt size of that session's latest request. */
  tokens: number
  /** The window the percent is a percent *of*. 200k and 1M are not the same denominator. */
  window: number
}

/** The four ways the API reports a token. */
interface TokenParts {
  input: number
  output: number
  cacheWrite: number
  cacheRead: number
}

/** Everything the usage tile draws. Exported so `UsageReadout` can be rendered in a test. */
export interface UsageView {
  /** The project's tokens, split the way the API reports them. */
  tokens: TokenParts
  requests: number
  sessions: number
  /** Null until a session in this folder has made its first request. */
  context: ContextOwner | null
  /** Models these transcripts name, heaviest first. */
  models: string[]
  scanning: boolean
}

/** Prompt tokens: everything that was not output. */
function promptOf(tokens: TokenParts): number {
  return tokens.input + tokens.cacheWrite + tokens.cacheRead
}

/** Every token the project has moved, prompt and output. */
function totalOf(tokens: TokenParts): number {
  return promptOf(tokens) + tokens.output
}

/**
 * Share of the prompt that was served from cache, 0–1. Mirrors `cacheHitRate`.
 *
 * It is on the tile rather than buried because it is the entire explanation for
 * the shape of the numbers beside it: a warm agent session running at ~90% hits
 * is re-reading the same prefix every turn, which is why a folder can show
 * millions of prompt tokens across a few hundred requests.
 */
export function cacheHitRate(tokens: TokenParts): number {
  const prompt = promptOf(tokens)
  return prompt === 0 ? 0 : tokens.cacheRead / prompt
}

/** One itemised line of the total: what it was, how many tokens, what share. */
export interface UsageLine {
  label: string
  tokens: number
  /** Share of every token the project moved, 0–1. Zero when there are none. */
  share: number
}

/**
 * The total, itemised so a reader can add it back up.
 *
 * Order is fixed rather than sorted by size: this is a statement, and one that
 * reorders itself between two viewings is one nobody can compare. It runs the
 * way a request is recorded — what was sent fresh, what was written to cache,
 * what was read back from it, what came out.
 */
export function usageLines(tokens: TokenParts): UsageLine[] {
  const total = totalOf(tokens)
  const line = (label: string, count: number): UsageLine => ({
    label,
    tokens: count,
    share: total > 0 ? count / total : 0,
  })
  return [
    line('Fresh input', tokens.input),
    line('Cache writes', tokens.cacheWrite),
    line('Cache reads', tokens.cacheRead),
    line('Output', tokens.output),
  ]
}

/** `91%`, and never `0%` for a session that did hit cache. */
export function formatPercent(fraction: number): string {
  const percent = fraction * 100
  if (percent > 0 && percent < 1) return '<1%'
  return `${Math.round(percent)}%`
}

function UsageWidget({ context }: { context: WidgetContext }): ReactElement {
  const { projectPath, onOpenInspector } = context
  /**
   * Whether the totals are showing what they are made of.
   *
   * Usage is the one number on this dashboard with no page of its own to open —
   * so the drill-in happens here, on the tile, which rule 1.2 allows in as many
   * words ("switch to the relevant section on the same page"). The rows come
   * from the same `cost:project` answer the totals do, so opening this costs
   * nothing and cannot disagree with the number above it.
   */
  const [breakdown, setBreakdown] = useState(false)
  const { state, reload } = useBridgeData<UsageView>(
    'getProjectCost',
    projectPath,
    useCallback(async (call) => {
      // `cost:project` hands back a ProjectSummary as `unknown` — the main
      // process owns that type and the renderer cannot import it, so every
      // field is read defensively rather than cast wholesale.
      const raw = (await call(projectPath)) as unknown
      const sessions = isRecord(raw) && Array.isArray(raw.sessions) ? raw.sessions : []
      const usage = isRecord(raw) ? raw.usage : undefined
      /*
       * Four categories, not one number.
       *
       * A bare token total hides the only thing that makes a folder's numbers
       * legible: almost all of them are usually cache reads. The five-way
       * `TokenUsage` collapses to four here because a five-minute and a
       * one-hour cache write are two TTLs but one line item to a person.
       */
      const tokenParts: TokenParts = {
        input: numberAt(usage, 'input'),
        output: numberAt(usage, 'output'),
        cacheWrite: numberAt(usage, 'cacheWrite5m') + numberAt(usage, 'cacheWrite1h'),
        cacheRead: numberAt(usage, 'cacheRead'),
      }

      const activeId = isRecord(raw) && typeof raw.activeSessionId === 'string' ? raw.activeSessionId : null
      const active = sessions.filter(isRecord).find((s) => s.sessionId === activeId)
      // `context` is null until a session has made its first request. Reading a
      // percent off that yields 0, and a meter reading "0% of the context
      // window" is a claim, not an absence — so it has to stay null.
      const contextRecord = active && isRecord(active.context) ? active.context : null
      /*
       * Whose context window this is.
       *
       * The meter used to read "Context window 84%" under a tile that had just
       * said "39 sessions recorded", and Asad asked the only question that
       * leaves: *"which one's context window is this one? We don't know."* It
       * is one session's — the most recently active transcript in this folder,
       * which is what `activeSessionId` names. A percent that cannot name its
       * session is withheld rather than drawn anonymously, because 84% of an
       * unnamed window is not a fact anybody can act on.
       *
       * The window itself comes across too, and it is the half that was
       * missing. A percentage is a ratio and both halves have to be on screen:
       * 3% of 200k and 3% of a million are the same reading of two different
       * situations, and PLAN-LOCAL-FIRST §G asks for exactly this — "context
       * window must say whose".
       */
      const activeModels = active && Array.isArray(active.models) ? active.models : []
      const context: ContextOwner | null =
        contextRecord && activeId
          ? {
              id: activeId,
              model: typeof activeModels[0] === 'string' ? activeModels[0] : '',
              percent: numberAt(contextRecord, 'percent'),
              tokens: numberAt(contextRecord, 'tokens'),
              window: numberAt(contextRecord, 'window'),
            }
          : null

      /*
       * Which models did this folder's work, heaviest first.
       *
       * `usageByModel` is summed in the main process alongside `usage`, so this
       * names exactly the buckets the totals above are made of. It used to be
       * read off the cost aggregate's `byModel` and sorted by money; the
       * aggregate is gone and tokens are the only weight left, which is also
       * the one a reader can check against the breakdown underneath.
       */
      const byModel = isRecord(raw) && isRecord(raw.usageByModel) ? raw.usageByModel : {}
      const modelTokens = (model: string): number =>
        numberAt(byModel[model], 'input') +
        numberAt(byModel[model], 'output') +
        numberAt(byModel[model], 'cacheWrite5m') +
        numberAt(byModel[model], 'cacheWrite1h') +
        numberAt(byModel[model], 'cacheRead')
      const models = Object.keys(byModel).sort((a, b) => modelTokens(b) - modelTokens(a))

      return {
        tokens: tokenParts,
        requests: numberAt(raw, 'requests'),
        sessions: sessions.length,
        context,
        models,
        scanning: isRecord(raw) && raw.scanning === true,
      }
    }, [projectPath]),
    { what: 'Reading this project’s transcripts' },
  )

  return renderState(state, reload, 'Reading transcripts…', (data) => (
    <UsageReadout
      data={data}
      expanded={breakdown}
      onToggle={() => setBreakdown((on) => !on)}
      onOpenInspector={onOpenInspector}
    />
  ))
}

/**
 * The usage tile once its numbers have landed.
 *
 * Split out of `UsageWidget` because it is the part with the judgement in it —
 * the wording, the order, what is withheld — and none of that was reachable
 * from a test while it lived inside a hook. There is no DOM in this project's
 * suite and effects do not run under `renderToStaticMarkup`, so a component
 * that fetches can only ever be rendered in its loading state. This one takes
 * its data as a prop and is therefore rendered, in full, by `widgets.test.tsx`.
 */
export function UsageReadout({
  data,
  expanded,
  onToggle,
  onOpenInspector,
}: {
  data: UsageView
  expanded: boolean
  onToggle: () => void
  onOpenInspector?: () => void
}): ReactElement {
  if (data.requests === 0) {
    return (
      <WidgetMessage
        tone="muted"
        title={data.scanning ? 'Still scanning…' : 'Nothing recorded yet'}
        /* No tool named — same rule as the note below the totals. */
        detail="Usage appears once an agent session in this folder has recorded its first request."
      />
    )
  }

  // Percent can exceed 100 — auto-compaction fires at the limit, so the last
  // request before it tips slightly over. Clamp the bar, not the number.
  const percent = data.context?.percent ?? null
  const tone = percent === null ? undefined : percent >= 90 ? 'crit' : percent >= 70 ? 'warn' : undefined

  const tokenTotalForDoor = totalOf(data.tokens)
  // All four totals are the same body of work seen from four sides, so all four
  // open the same breakdown rather than pretending to be four destinations.
  //
  // Gated on there being tokens to itemise rather than on there being sessions
  // to list: the breakdown is the four-line itemisation now, and it is what
  // makes the headline checkable. It used to be gated on `perSession.length`,
  // which is gone with the list it counted.
  const open = doorIf(tokenTotalForDoor > 0, onToggle)
  const goes = expanded ? 'Hide the breakdown' : 'Show what the figures are made of'

  const tokenTotal = totalOf(data.tokens)
  const hitRate = cacheHitRate(data.tokens)

  return (
    <>
      <div className="widget-stats">
        {/*
          Tokens lead, because tokens are now the headline of this tile.

          The slot that used to be first held `$4558 at API rates`. Nothing
          takes its place and nothing is left blank: the row simply has four
          stats where it had five, and the grid closes up.
        */}
        <Stat label="tokens" value={formatTokens(tokenTotal)} onClick={open} goes={goes} />
        {/*
          The hit rate earns a slot of its own rather than a footnote.

          It is not a curiosity — it is the reason the figure beside it is the
          size it is, and it is the single fact that turns "a million tokens
          across two hundred requests, this app is broken" into arithmetic
          anybody can follow.
        */}
        <Stat
          label="from cache"
          value={formatPercent(hitRate)}
          onClick={open}
          goes={goes}
        />
        <Stat
          label={plural(data.requests, 'request')}
          value={String(data.requests)}
          onClick={open}
          goes={goes}
        />
        {/*
          "sessions recorded", not "sessions".

          This counts transcripts in the folder — every session that has ever
          written one, including yesterday's and ones this app did not start.
          The Sessions tile 350 pixels away counts the sessions that are open
          right now. Both said "sessions", one said 7 and the other said 4,
          on the same screen, with nothing to say which was which. Two numbers
          that disagree in public need different words, and the word has to be
          the one that explains where the number came from.
        */}
        <Stat
          label={`${plural(data.sessions, 'session')} recorded`}
          value={String(data.sessions)}
          onClick={open}
          goes={goes}
        />
      </div>

      {/*
        What the numbers are, in the one sentence somebody reads before deciding
        whether to trust the tile. The sentence this replaces began "Not a
        bill." and went on to explain what a dollar figure did and did not mean;
        with no dollar figure there is nothing to disclaim, only to source.
      */}
      {/*
        Where the number came from, and it is the sentence that has to be exact
        — Asad, on the headline: *"3.2 billion tokens. I don't know if it is
        true or not."*

        Two things changed in it. It named a specific tool, which is the rule he
        stated for the whole product: *"you should not mention in any settings
        or any pop-up a specific tool or LLM, because they can use some other
        also."* And "counted" was doing a lot of quiet work: each request is
        counted **once**, which is the whole difficulty — one API request writes
        many lines into a transcript, and a resumed conversation writes the same
        request into a second transcript. Saying so is what makes the figure
        checkable rather than something to be taken on trust. The arithmetic
        behind it is in `src/main/transcript.ts`.
      */}
      <p className="widget-note">
        {formatTokens(tokenTotal)} tokens across {data.requests}{' '}
        {plural(data.requests, 'request')} — every request your agents made in this folder,
        counted once, from their own session records.
      </p>

      {expanded && (
        <>
          {/*
            The itemised total.

            Four lines, in the order a request is recorded, each with its share
            of the whole — so the total can be reconstructed rather than taken
            on faith. This table had a money column and a per-million rate
            column between the tokens and the share; both are gone.
          */}
          <p className="widget-breakdown-label">
            How {formatTokens(tokenTotal)} tokens is made up
          </p>
          <ul className="widget-list">
            {usageLines(data.tokens).map((line) => (
              <li key={line.label}>
                <span className="widget-row static">
                  <span className="widget-row-main">{line.label}</span>
                  <span className="widget-row-side num">{formatTokens(line.tokens)}</span>
                  <span className="widget-row-side num">{formatPercent(line.share)}</span>
                </span>
              </li>
            ))}
            <li>
              <span className="widget-row static">
                <span className="widget-row-main">Total</span>
                <span className="widget-row-side num">{formatTokens(tokenTotal)}</span>
                <span className="widget-row-side num" />
              </span>
            </li>
          </ul>

          {/*
            The per-session list was here, and it is gone.

            It printed one row per transcript in the folder — thirty-five of
            them, `e79f7c36 · claude-opus-4-8 · 3071 · 1.61B` — under the
            heading "The same total across 35 sessions, heaviest first". Asad,
            finding it: a long list of old sessions that is nowhere in the
            sidebar, where every row opens the same session. *"They make no
            sense to be here, I think, in that case."*

            He is right on both counts, and the second one was the argument for
            deleting rather than repairing. A row identified by eight hex
            characters names nothing a person can recognise — `cost:project`
            carries no session *title*, only the transcript's id — so even a
            working row would land you somewhere you could not have chosen on
            purpose. And it could not be made to work from here: opening one
            would mean handing a transcript path up through `onOpenInspector`,
            which takes no argument and is wired in `App.tsx` to open the
            **most recently active** transcript, whichever row was pressed.
            Every row opening the same session was not a bug in the list; it
            was the only thing the list could do.

            What the breakdown is *for* survives intact above: the four-line
            itemisation adds back up to the headline, which is what makes the
            headline checkable. The session list added no arithmetic to that —
            it was the same total, split by a key nobody can read.
          */}
        </>
      )}

      {data.context !== null && percent !== null && (
        <div className="widget-meter">
          <div className="widget-meter-head">
            {/*
              Named, or gone.

              A window belongs to one conversation, and this folder can hold
              forty of them. The label carries the session the reading came
              from — the most recently active transcript here — and its model,
              because the same percent means something different against 200k
              than against a million.
            */}
            {onOpenInspector ? (
              <button
                type="button"
                className="widget-meter-link"
                title="Open the session inspector"
                onClick={onOpenInspector}
              >
                Context window · session {data.context.id.slice(0, 8)}
              </button>
            ) : (
              <span>Context window · session {data.context.id.slice(0, 8)}</span>
            )}
            <span className={tone ? `widget-stat-value ${tone}` : undefined}>
              {Math.round(percent)}%
            </span>
          </div>
          {/*
            Whose window, and how big.

            A percentage is a ratio and both halves have to be on screen. "3%"
            against a 200k window and "3%" against a million are the same
            reading of two very different situations, and until now the tile
            printed the numerator's session but never the denominator at all —
            so the reading could not be checked and could not be acted on.
            PLAN-LOCAL-FIRST §G, in three words: "must say whose".

            Written as one clause rather than two so it stays one line: the
            model when the transcript named one, the window always, because
            the window is the half that makes the percent mean anything and it
            is known even when the model id is missing.
          */}
          <p className="widget-meter-note">
            Most recent session here
            {data.context.model !== '' && `, on ${data.context.model}`} —{' '}
            {formatTokens(data.context.tokens)} of{' '}
            {data.context.window > 0
              ? `${data.context.model !== '' ? 'its ' : 'a '}${formatTokens(data.context.window)} window`
              : 'an unknown window'}
            .
          </p>

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

      {/*
        Provenance. This line used to date the rate card the money came off —
        "verified 2026-08-17" — because a price with no date is a price with no
        shelf life. A token count has no shelf life at all: the transcript said
        it, and it will say the same thing next year. What is worth naming is
        which models did the work, since that is what makes the context window
        above mean anything.
      */}
      <p className="widget-note quiet">
        {hitRate > 0 &&
          `${formatPercent(hitRate)} of the prompt came from cache, re-read each turn rather than sent again. `}
        {data.models.length > 0 && `Models seen: ${data.models.join(', ')}.`}
      </p>
    </>
  )
}

/* -------------------------------------------------------------------- git -- */

/**
 * What git's status letter means, in a word.
 *
 * The status column on both the tile and Source control printed the letter git
 * prints — `M`, `A`, `D`, and for an untracked file a bare `?`. Asad, looking at
 * a column of question marks: *"what are these question marks? Is this normal?
 * Is this like for all of the other tools are also doing like this?"* It is
 * porcelain's code for untracked, and the answer to his question is that no, a
 * question mark is not what a person should have to decode. `git.ts` already
 * resolves every code into a `kind` for exactly this reason and nothing was
 * reading it.
 *
 * `unknown` keeps the raw letter rather than inventing a word for it: a code
 * this app has not seen is a fact worth showing as it arrived, and it is the one
 * case where the letter is more honest than any English for it.
 */
export const CHANGE_WORD: Record<GitChangeKind, string> = {
  added: 'Added',
  modified: 'Modified',
  deleted: 'Deleted',
  renamed: 'Renamed',
  copied: 'Copied',
  typechange: 'Type',
  untracked: 'Untracked',
  conflicted: 'Conflict',
  unknown: '',
}

/** The word for a change, falling back to git's own letter when there is none. */
export function changeLabel(kind: GitChangeKind, code: string): string {
  return CHANGE_WORD[kind] || code.trim() || '?'
}

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
  const { projectPath, onNavigate, onOpenFile } = context
  const { state, reload } = useBridgeData<GitStatusResult>(
    'gitStatus',
    projectPath,
    useCallback(async (call) => (await call(projectPath)) as GitStatusResult, [projectPath]),
    { what: 'Reading the repo' },
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
          /*
            The same headings Source control uses for the same four situations,
            so the tile and the page it links to do not describe one folder two
            ways. `detail` is now a written sentence in every case `git.ts`
            recognises — it used to be git's own stderr, and this tile printed
            "fatal: not a git repository (or any of the parent directories):
            .git" at a person, which is a command's error text rather than
            anything addressed to a reader.
          */
          title={
            status.reason === 'not-a-repo'
              ? 'Nothing to track here'
              : status.reason === 'git-missing'
                ? 'git is not installed'
                : status.reason === 'no-such-folder'
                  ? 'That folder is gone'
                  : 'Source control is unavailable'
          }
          detail={status.message}
        />
      )
    }

    const { shown, hidden } = visibleGitFiles(status)
    return (
      <>
        <div className="widget-branch">
          {(() => {
            const name = status.branch.detached
              ? `detached at ${status.branch.oid?.slice(0, 7) ?? '—'}`
              : (status.branch.name ?? 'no branch yet')
            // The branch is the tile's heading, so it is also its way in — a
            // button at the foot saying "Open git panel" repeated a door the
            // sidebar already has two rows above it.
            return onNavigate ? (
              <button
                type="button"
                className="widget-branch-name is-link"
                title="Open Source control"
                onClick={() => onNavigate('git')}
              >
                {name}
              </button>
            ) : (
              <span className="widget-branch-name">{name}</span>
            )
          })()}
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
              {/* Each count lands on its own run of files in Source control,
                  not on the top of the page — see PanelView's `focus`. */}
              <Stat
                label="staged"
                value={String(status.staged.length)}
                goes="Open the staged files"
                onClick={doorIf(status.staged.length > 0 && Boolean(onNavigate), () =>
                  onNavigate?.('git', 'staged'),
                )}
              />
              <Stat
                label="changed"
                value={String(status.unstaged.length)}
                goes="Open the changed files"
                onClick={doorIf(status.unstaged.length > 0 && Boolean(onNavigate), () =>
                  onNavigate?.('git', 'unstaged'),
                )}
              />
              <Stat
                label="untracked"
                value={String(status.untracked.length)}
                goes="Open the untracked files"
                onClick={doorIf(status.untracked.length > 0 && Boolean(onNavigate), () =>
                  onNavigate?.('git', 'untracked'),
                )}
              />
              {status.conflicted.length > 0 && (
                <Stat
                  label={plural(status.conflicted.length, 'conflict')}
                  value={String(status.conflicted.length)}
                  tone="crit"
                  goes="Open the conflicts"
                  onClick={doorIf(Boolean(onNavigate), () => onNavigate?.('git', 'conflicted'))}
                />
              )}
            </div>
            <ul className="widget-list">
              {shown.map((file) => (
                <li key={`${file.group}:${file.path}`}>
                  {/* A path is a door too (rule 1.4) — the Files page can show
                      any file in the project, so a row that named one and did
                      nothing was the only dead thing left on this tile. */}
                  {onOpenFile ? (
                    <button
                      type="button"
                      className="widget-row"
                      title={`Open ${file.path}`}
                      onClick={() => onOpenFile(file.path)}
                    >
                      <span className={`widget-code ${file.group}`}>
                        {changeLabel(file.kind, file.code)}
                      </span>
                      <span className="widget-row-main mono">{file.path}</span>
                    </button>
                  ) : (
                    <span className="widget-row static">
                      <span className={`widget-code ${file.group}`}>
                        {changeLabel(file.kind, file.code)}
                      </span>
                      <span className="widget-row-main mono">{file.path}</span>
                    </span>
                  )}
                </li>
              ))}
            </ul>
            {hidden > 0 && (
              <p className="widget-note">
                …and {hidden} more.{' '}
                {onNavigate && (
                  <button
                    type="button"
                    className="widget-inline-link"
                    onClick={() => onNavigate('git')}
                  >
                    See them all
                  </button>
                )}
              </p>
            )}
          </>
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
  const { projectPath, onNavigate } = context
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
    { what: 'Scoring the project' },
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
          <Stat
            label={data.band || 'readiness'}
            value={`${data.score}%`}
            tone={tone}
            goes="Open AI readiness"
            onClick={doorIf(Boolean(onNavigate), () => onNavigate?.('readiness'))}
          />
          <Stat
            label="passing"
            value={`${passing.length}/${applicable.length}`}
            goes="Open AI readiness"
            onClick={doorIf(Boolean(onNavigate), () => onNavigate?.('readiness'))}
          />
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
  const { projectPath, onNavigate } = context
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
    { what: 'Asking gh' },
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
              {/* The GitHub page opens on the list you counted, not on whichever
                  of its two tabs happens to be first. */}
              <Stat
                label={plural(prs.length, 'pull request')}
                value={String(prs.length)}
                goes="Open the pull requests"
                onClick={doorIf(prs.length > 0 && Boolean(onNavigate), () =>
                  onNavigate?.('github', 'pulls'),
                )}
              />
              <Stat
                label={plural(issues.length, 'issue')}
                value={String(issues.length)}
                goes="Open the issues"
                onClick={doorIf(issues.length > 0 && Boolean(onNavigate), () =>
                  onNavigate?.('github', 'issues'),
                )}
              />
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
  /*
   * The key is still `cost`. The tile is called Usage and shows no money.
   *
   * `WidgetType` is the id a saved layout stores, so renaming it would drop the
   * tile out of every dashboard anybody has already arranged — a migration's
   * worth of risk to change a string no user ever sees. The title and the
   * description are the parts that are read, and those are honest now.
   */
  cost: {
    type: 'cost',
    title: 'Usage',
    description: 'Tokens, cache hit rate and context-window pressure, read from your agents’ own session records.',
    Component: UsageWidget,
  },
  git: {
    type: 'git',
    title: 'Git',
    description: 'Branch, ahead/behind, and every file the working tree has touched.',
    Component: GitWidget,
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

/**
 * Every definition the picker offers, in order.
 *
 * Retired types are filtered rather than deleted — a tile already in somebody's
 * saved layout keeps rendering, it just stops being offered again. See
 * `RETIRED_WIDGETS` in `layout.ts` for why Sessions is one.
 */
export function listWidgetDefinitions(): WidgetDefinition[] {
  return WIDGET_TYPES.flatMap((type) => {
    if (isRetiredWidget(type)) return []
    const definition = getWidgetDefinition(type)
    return definition ? [definition] : []
  })
}
