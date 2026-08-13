import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useWhenActive } from '../schedule'
import './GitHubPanel.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/github.ts`. Duplicated rather than
 * imported because the renderer tsconfig does not include `src/main` — when
 * the orchestrator lifts them into `src/shared/types.ts` this block goes away
 * and the imports point there instead.
 */
export type GitHubErrorKind =
  | 'gh-missing'
  | 'not-authenticated'
  | 'auth-expired'
  | 'missing-scope'
  | 'not-a-repo'
  | 'no-such-folder'
  | 'no-remote'
  | 'no-github-remote'
  | 'git-missing'
  | 'repo-not-found'
  | 'no-access'
  | 'rate-limited'
  | 'network-down'
  | 'timeout'
  | 'error'

export interface GitHubFailure {
  ok: false
  kind: GitHubErrorKind
  message: string
  action: string | null
  detail: string
}

export interface RepoRef {
  host: string
  owner: string
  name: string
  nameWithOwner: string
  url: string
  remote: string
}

export interface GitHubLabel {
  name: string
  color: string
}

export type PullBadge = 'draft' | 'open' | 'merged' | 'closed'

export type ReviewStatus = 'approved' | 'changes-requested' | 'review-required' | null

export interface PullRequest {
  number: number
  title: string
  url: string
  badge: PullBadge
  draft: boolean
  author: string | null
  authorIsBot: boolean
  createdAt: string
  updatedAt: string
  review: ReviewStatus
  labels: GitHubLabel[]
  branch: string | null
  fromFork: boolean
  additions: number | null
  deletions: number | null
}

export interface Issue {
  number: number
  title: string
  url: string
  state: 'open' | 'closed'
  reason: 'completed' | 'not-planned' | null
  author: string | null
  authorIsBot: boolean
  createdAt: string
  updatedAt: string
  labels: GitHubLabel[]
  assignees: string[]
}

export interface NotificationSummary {
  total: number
  repo: number
  capped: boolean
  reasons: Record<string, number>
}

export type Section<T> = { ok: true; value: T } | GitHubFailure

export interface GitHubOverview {
  ok: true
  cwd: string
  repo: RepoRef
  pulls: Section<PullRequest[]>
  issues: Section<Issue[]>
  notifications: Section<NotificationSummary>
  limit: number
  fetchedAt: number
}

export type GitHubResult = GitHubOverview | GitHubFailure

/** The slice of the preload bridge this panel needs. */
export interface GitHubBridge {
  githubOverview(cwd: string, options?: { limit?: number }): Promise<GitHubResult>
  githubRefresh(cwd: string, options?: { limit?: number }): Promise<GitHubResult>
}

export interface GitHubPanelProps {
  /** Absolute path of the project folder to report on. */
  cwd: string
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: GitHubBridge
  /** Injectable for tests, so rendered ages do not drift with the clock. */
  now?: number
  /** Which list opens first. */
  initialTab?: Tab
}

export type Tab = 'pulls' | 'issues'

/* ---------------------------------------------------------------- helpers -- */

function resolveBridge(): GitHubBridge | null {
  const host = (window as unknown as { deck?: Partial<GitHubBridge> }).deck
  if (!host || typeof host.githubOverview !== 'function' || typeof host.githubRefresh !== 'function') {
    return null
  }
  return host as GitHubBridge
}

/**
 * Hand a URL to the real browser. The main process denies every in-app window
 * and calls `shell.openExternal` instead, so this is the whole mechanism.
 *
 * The scheme is checked here rather than trusted: these URLs arrive from a
 * network response, and `javascript:` reaching `window.open` is a scripting
 * hole no amount of upstream trust is worth betting on.
 */
export function openExternal(url: string): void {
  if (!/^https?:\/\//i.test(url)) return
  window.open(url, '_blank', 'noopener,noreferrer')
}

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR
const WEEK = 7 * DAY
const YEAR = 365 * DAY

/**
 * Compact relative age — "3h", "2d". Lists are scanned, not read, so the unit
 * is one character and the row does not reflow as ages grow.
 */
export function formatAge(iso: string, now: number): string {
  const then = Date.parse(iso)
  if (Number.isNaN(then)) return ''
  // Clock skew between this machine and GitHub can put a timestamp slightly in
  // the future; "in 4s" would be nonsense, so it clamps to "now".
  const elapsed = Math.max(0, now - then)
  if (elapsed < MINUTE) return 'now'
  if (elapsed < HOUR) return `${Math.floor(elapsed / MINUTE)}m`
  if (elapsed < DAY) return `${Math.floor(elapsed / HOUR)}h`
  if (elapsed < WEEK) return `${Math.floor(elapsed / DAY)}d`
  if (elapsed < YEAR) return `${Math.floor(elapsed / WEEK)}w`
  return `${Math.floor(elapsed / YEAR)}y`
}

const REVIEW_LABEL: Record<Exclude<ReviewStatus, null>, string> = {
  approved: 'Approved',
  'changes-requested': 'Changes requested',
  'review-required': 'Review required',
}

export function reviewLabel(status: ReviewStatus): string | null {
  return status ? REVIEW_LABEL[status] : null
}

/**
 * A headline for each failure, distinct from the message underneath it. The
 * point of the pair is that the user knows which of "sign in", "add a remote"
 * and "wait for the rate limit" they are being asked to do without reading the
 * detail.
 */
const FAILURE_TITLE: Record<GitHubErrorKind, string> = {
  'gh-missing': 'GitHub CLI not installed',
  'not-authenticated': 'Not signed in to GitHub',
  'auth-expired': 'GitHub sign-in expired',
  'missing-scope': 'Token is missing a permission',
  'not-a-repo': 'Not a git repository',
  'no-such-folder': 'Folder is gone',
  'no-remote': 'No git remote',
  'no-github-remote': 'No GitHub remote',
  'git-missing': 'git not installed',
  'repo-not-found': 'Repository not found',
  'no-access': 'No access to this repository',
  'rate-limited': 'GitHub rate limit reached',
  'network-down': 'Cannot reach GitHub',
  timeout: 'GitHub timed out',
  error: 'GitHub request failed',
}

/** Failures the user can do nothing about right now, so Retry is the only move. */
const RETRYABLE = new Set<GitHubErrorKind>(['network-down', 'timeout', 'rate-limited', 'error'])

/**
 * Narrows either a section or the whole overview, both of which discriminate
 * on the same `ok` flag.
 */
export function isFailure<T extends { ok: boolean }>(value: T): value is T & GitHubFailure {
  return value.ok === false
}

const MAX_LABELS = 3

/**
 * The number on a tab.
 *
 * A list that came back exactly as long as the row limit was almost certainly
 * cut off there, so it is reported as "20+". Printing a bare "20" for a repo
 * with two hundred open pull requests is not a rounding error — it is a
 * specific wrong number, and it looks exactly like a right one.
 */
export function countLabel(rows: number | null, limit: number): string | null {
  if (rows === null) return null
  return rows >= limit ? `${rows}+` : String(rows)
}

/* ------------------------------------------------------------ sub-renders -- */

function Labels({ labels }: { labels: GitHubLabel[] }) {
  if (labels.length === 0) return null
  return (
    <span className="gh-labels">
      {labels.slice(0, MAX_LABELS).map((label) => (
        <span key={label.name} className="gh-label" title={label.name}>
          <span className="gh-label-dot" style={{ background: `#${label.color}` }} aria-hidden="true" />
          {label.name}
        </span>
      ))}
      {labels.length > MAX_LABELS && (
        <span className="gh-label gh-label-more">+{labels.length - MAX_LABELS}</span>
      )}
    </span>
  )
}

export function FailureBlock({ failure, onRetry }: { failure: GitHubFailure; onRetry(): void }) {
  return (
    <div className="gh-failure" role="status">
      <p className="gh-failure-title">{FAILURE_TITLE[failure.kind] ?? FAILURE_TITLE.error}</p>
      <p className="gh-failure-message">{failure.message}</p>
      {failure.action && (
        <p className="gh-failure-action">
          Run <code>{failure.action}</code> in a terminal, then refresh.
        </p>
      )}
      {failure.detail && (
        <details className="gh-failure-detail">
          <summary>Details</summary>
          <pre>{failure.detail}</pre>
        </details>
      )}
      {(RETRYABLE.has(failure.kind) || failure.action) && (
        <button type="button" className="gh-retry" onClick={onRetry}>
          Retry
        </button>
      )}
    </div>
  )
}

export function PullRow({ pull, now }: { pull: PullRequest; now: number }) {
  const review = reviewLabel(pull.review)
  return (
    <li>
      <button
        type="button"
        className="gh-row"
        onClick={() => openExternal(pull.url)}
        title={`${pull.title} — open on GitHub`}
      >
        <span className="gh-badge" data-badge={pull.badge}>
          {pull.badge}
        </span>
        <span className="gh-body">
          <span className="gh-title">{pull.title}</span>
          <span className="gh-meta">
            <span className="gh-number">#{pull.number}</span>
            {pull.author && (
              <span className="gh-author" data-bot={pull.authorIsBot}>
                {pull.author}
              </span>
            )}
            <span className="gh-age" title={pull.updatedAt}>
              {formatAge(pull.updatedAt, now)}
            </span>
            {review && (
              <span className="gh-review" data-review={pull.review}>
                {review}
              </span>
            )}
            {pull.fromFork && <span className="gh-fork">fork</span>}
            <Labels labels={pull.labels} />
          </span>
        </span>
        {pull.additions !== null && pull.deletions !== null && (
          <span className="gh-diffstat">
            <span className="gh-plus">+{pull.additions}</span>
            <span className="gh-minus">−{pull.deletions}</span>
          </span>
        )}
      </button>
    </li>
  )
}

export function IssueRow({ issue, now }: { issue: Issue; now: number }) {
  return (
    <li>
      <button
        type="button"
        className="gh-row"
        onClick={() => openExternal(issue.url)}
        title={`${issue.title} — open on GitHub`}
      >
        <span className="gh-badge" data-badge={issue.state === 'closed' ? 'closed' : 'open'}>
          {issue.state}
        </span>
        <span className="gh-body">
          <span className="gh-title">{issue.title}</span>
          <span className="gh-meta">
            <span className="gh-number">#{issue.number}</span>
            {issue.author && (
              <span className="gh-author" data-bot={issue.authorIsBot}>
                {issue.author}
              </span>
            )}
            <span className="gh-age" title={issue.updatedAt}>
              {formatAge(issue.updatedAt, now)}
            </span>
            {issue.assignees.length > 0 && (
              <span className="gh-assignees">→ {issue.assignees.join(', ')}</span>
            )}
            <Labels labels={issue.labels} />
          </span>
        </span>
      </button>
    </li>
  )
}

/* -------------------------------------------------------------- component -- */

export function GitHubPanel({ cwd, bridge, now, initialTab = 'pulls' }: GitHubPanelProps) {
  const api = useMemo(() => bridge ?? resolveBridge(), [bridge])
  const [result, setResult] = useState<GitHubResult | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [tab, setTab] = useState<Tab>(initialTab)
  /** The folder on screen, so a slow reply for a previous one is discarded. */
  const shown = useRef<string | null>(null)

  const load = useCallback(
    async (refresh: boolean) => {
      if (!api) return
      const asked = cwd
      if (refresh) setBusy(true)
      try {
        const next = refresh ? await api.githubRefresh(asked) : await api.githubOverview(asked)
        // A project switch mid-flight must not paint one repo over another.
        if (shown.current === asked) setResult(next)
      } catch {
        if (shown.current === asked) {
          setResult({
            ok: false,
            kind: 'error',
            message: 'The GitHub bridge did not answer.',
            action: null,
            detail: '',
          })
        }
      } finally {
        if (shown.current === asked) {
          setLoading(false)
          setBusy(false)
        }
      }
    },
    [api, cwd],
  )

  useEffect(() => {
    if (!api) {
      setLoading(false)
      return
    }
    shown.current = cwd
    setLoading(true)
    setResult(null)
    // A refresh that was still in flight for the previous folder will never
    // reach its own cleanup — the guard below discards it — so the button it
    // disabled has to be released here or it stays greyed out.
    setBusy(false)
    void load(false)

    return () => {
      shown.current = null
    }
  }, [api, cwd, load])

  /**
   * Re-ask when the user comes back to the window, not every minute.
   *
   * Nothing on this panel changes because of anything that happened on this
   * Mac: a pull request is opened, a review is left and a notification arrives
   * on somebody else's machine, and there is no local event to subscribe to. So
   * the honest trigger is the moment the answer starts to matter — the user
   * looking at the window again — which is a platform event rather than a
   * guess. The old 60-second interval asked 1,440 times a day, spent the user's
   * GitHub rate limit doing it, and was still a minute stale at the moment they
   * turned back to it. Anyone who wants it fresher has Refresh, which forces
   * past the main process cache.
   */
  useWhenActive(() => {
    if (api && shown.current === cwd) void load(false)
  })

  const refresh = useCallback(() => void load(true), [load])
  const clock = now ?? Date.now()

  if (!api) {
    return (
      <section className="gh-panel" aria-label="GitHub">
        <p className="gh-message">GitHub is not available in this build.</p>
      </section>
    )
  }

  if (loading && !result) {
    return (
      <section className="gh-panel" aria-label="GitHub" aria-busy="true">
        <p className="gh-message">Reading GitHub…</p>
      </section>
    )
  }

  if (!result || isFailure(result)) {
    return (
      <section className="gh-panel" aria-label="GitHub">
        <FailureBlock
          failure={
            result ?? {
              ok: false,
              kind: 'error',
              message: 'No answer from the GitHub bridge.',
              action: null,
              detail: '',
            }
          }
          onRetry={refresh}
        />
      </section>
    )
  }

  const { repo, pulls, issues, notifications } = result
  const pullCount = countLabel(pulls.ok ? pulls.value.length : null, result.limit)
  const issueCount = countLabel(issues.ok ? issues.value.length : null, result.limit)
  const unread = notifications.ok ? notifications.value : null

  return (
    <section className="gh-panel" aria-label="GitHub">
      <header className="gh-head">
        <svg
          className="gh-head-icon"
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          aria-hidden="true"
        >
          <path d="M9 20.5c-4.6 1.4-4.6-2.4-6.4-2.9M21 20.5v-3.3a3 3 0 0 0-.8-2.2c2.7-.3 5-1.4 5-5.9a4.6 4.6 0 0 0-1.2-3.1 4.3 4.3 0 0 0-.1-3.1s-1-.3-3.3 1.2a11.4 11.4 0 0 0-6 0C12.3 2.6 11.3 2.9 11.3 2.9a4.3 4.3 0 0 0-.1 3.1A4.6 4.6 0 0 0 10 9.1c0 4.4 2.3 5.6 5 5.9a3 3 0 0 0-.8 2.1v3.4" />
        </svg>

        <button
          type="button"
          className="gh-repo"
          onClick={() => openExternal(repo.url)}
          title={`${repo.nameWithOwner} — open on GitHub (remote: ${repo.remote})`}
        >
          {repo.nameWithOwner}
        </button>

        <span className="gh-head-spacer" />

        {unread && unread.total > 0 && (
          <span
            className="gh-bell"
            data-mine={unread.repo > 0}
            title={
              unread.repo > 0
                ? `${unread.repo} unread in this repository, ${unread.capped ? '50+' : unread.total} on your account`
                : `${unread.capped ? '50+' : unread.total} unread notifications on your account`
            }
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
              <path d="M18 8a6 6 0 1 0-12 0c0 7-3 8-3 8h18s-3-1-3-8M13.7 21a2 2 0 0 1-3.4 0" />
            </svg>
            {unread.repo > 0 ? unread.repo : unread.capped ? '50+' : unread.total}
          </span>
        )}

        <button
          type="button"
          className="gh-refresh"
          onClick={refresh}
          disabled={busy}
          title="Refresh"
          aria-label="Refresh GitHub data"
        >
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="M20 12a8 8 0 1 1-2.6-5.9" />
            <path d="M20 4v4.4h-4.4" />
          </svg>
        </button>
      </header>

      <div className="gh-tabs" role="tablist" aria-label="GitHub lists">
        <button
          type="button"
          role="tab"
          id="gh-tab-pulls"
          aria-selected={tab === 'pulls'}
          aria-controls="gh-panel-pulls"
          className="gh-tab"
          onClick={() => setTab('pulls')}
        >
          Pull requests
          {pullCount !== null && <span className="gh-tab-count">{pullCount}</span>}
        </button>
        <button
          type="button"
          role="tab"
          id="gh-tab-issues"
          aria-selected={tab === 'issues'}
          aria-controls="gh-panel-issues"
          className="gh-tab"
          onClick={() => setTab('issues')}
        >
          Issues
          {issueCount !== null && <span className="gh-tab-count">{issueCount}</span>}
        </button>
      </div>

      {tab === 'pulls' ? (
        <div className="gh-list-wrap" role="tabpanel" id="gh-panel-pulls" aria-labelledby="gh-tab-pulls">
          {isFailure(pulls) ? (
            <FailureBlock failure={pulls} onRetry={refresh} />
          ) : pulls.value.length === 0 ? (
            <p className="gh-message">No open pull requests.</p>
          ) : (
            <ul className="gh-list">
              {pulls.value.map((pull) => (
                <PullRow key={pull.number} pull={pull} now={clock} />
              ))}
            </ul>
          )}
        </div>
      ) : (
        <div className="gh-list-wrap" role="tabpanel" id="gh-panel-issues" aria-labelledby="gh-tab-issues">
          {isFailure(issues) ? (
            <FailureBlock failure={issues} onRetry={refresh} />
          ) : issues.value.length === 0 ? (
            <p className="gh-message">No open issues.</p>
          ) : (
            <ul className="gh-list">
              {issues.value.map((issue) => (
                <IssueRow key={issue.number} issue={issue} now={clock} />
              ))}
            </ul>
          )}
        </div>
      )}

      {isFailure(notifications) && notifications.kind === 'missing-scope' && (
        // Worth one quiet line rather than a full failure block: the lists
        // above loaded fine, and the only thing missing is the bell.
        <p className="gh-note">Notifications need the <code>notifications</code> token scope.</p>
      )}
    </section>
  )
}
