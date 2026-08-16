import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useWhenActive } from '../schedule'
import { panelSpec } from '../shell/panels'
import { PageEmpty, PageNote } from './PageEmpty'
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
  | 'auth-declined'
  | 'auth-code-expired'
  | 'auth-unavailable'
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

/** Mirrors `BranchRef` in `src/main/github.ts`. */
export interface BranchRef {
  name: string | null
  detached: boolean
  head: string | null
}

/** Mirrors `RepoSummary` in `src/main/github-repos.ts`. */
export interface RepoSummary {
  owner: string
  name: string
  nameWithOwner: string
  url: string
  private: boolean
  fork: boolean
  archived: boolean
  description: string | null
  language: string | null
  defaultBranch: string | null
  pushedAt: string | null
  canPush: boolean
}

/** Mirrors `RepoAccessList` in `src/main/github-repos.ts`. */
export interface RepoAccessList {
  ok: true
  repos: RepoSummary[]
  atLeast: number
  truncated: boolean
  source: 'account' | 'installation'
  selection: 'all' | 'selected' | null
  rateRemaining: number | null
  fetchedAt: number
}

export type RepoAccess = RepoAccessList | GitHubFailure

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

export type Section<T> = { ok: true; value: T } | GitHubFailure

export interface GitHubOverview {
  ok: true
  cwd: string
  repo: RepoRef
  pulls: Section<PullRequest[]>
  issues: Section<Issue[]>
  limit: number
  fetchedAt: number
}

export type GitHubResult = GitHubOverview | GitHubFailure

/* -------------------------------------------------------------- sign-in -- */

/** Mirrors `src/main/github-auth.ts`, for the same reason as the block above. */
export type AuthSource = 'environment' | 'device-flow' | 'gh-cli'

export interface GitHubIdentity {
  login: string
  name: string | null
  htmlUrl: string
  avatarUrl: string | null
}

/**
 * What kind of grant a credential is. Mirrors `CredentialKind` in
 * `src/main/github-auth.ts` — never a statement about which client a sign-in
 * would use, because there is only one of those.
 */
export type CredentialKind = 'oauth' | 'github-app'

export interface DeviceFlowPrompt {
  userCode: string
  verificationUri: string
  expiresAt: number
  installUrl: string | null
}

export interface GitHubAuthState {
  connected: boolean
  source: AuthSource | null
  host: string
  identity: GitHubIdentity | null
  scopes: string[]
  scopesReported: boolean
  ghInstalled: boolean
  /** How the credential in use was obtained, null while nothing is connected. */
  credentialKind: CredentialKind | null
  /** False in a build with no GitHub App registered, where Connect cannot work. */
  appConfigured: boolean
  installUrl: string | null
  disconnect: string | null
  pending: DeviceFlowPrompt | null
  failure: GitHubFailure | null
  expiredCredentialRemoved: boolean
  repo: RepoRef | GitHubFailure | null
  branch: BranchRef | null
  access: RepoAccess | null
}

/** The slice of the preload bridge this panel needs. */
export interface GitHubBridge {
  githubOverview(cwd: string, options?: { limit?: number }): Promise<GitHubResult>
  githubRefresh(cwd: string, options?: { limit?: number }): Promise<GitHubResult>
  githubAuthStatus(cwd?: string): Promise<GitHubAuthState>
  githubConnect(): Promise<DeviceFlowPrompt | GitHubFailure>
  githubAwaitConnect(cwd?: string): Promise<GitHubAuthState>
  githubCancelConnect(cwd?: string): Promise<GitHubAuthState>
  githubDisconnect(cwd?: string): Promise<GitHubAuthState>
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

/**
 * `repos` is the third tab, and the only one that has anything to show when the
 * open folder is not a GitHub repository — which is the state that made a
 * successful sign-in look like a failed one.
 */
export type Tab = 'pulls' | 'issues' | 'repos'

/* ---------------------------------------------------------------- helpers -- */

/**
 * The methods that have to be present for this page to be anything other than
 * a fallback. Listed rather than spot-checked because the failure mode is
 * silent: a preload that exposes four of the seven renders a Connect button
 * that throws on click, which is the "looks clickable, does nothing" bug the
 * house rules put first.
 */
const BRIDGE_METHODS: ReadonlyArray<keyof GitHubBridge> = [
  'githubOverview',
  'githubRefresh',
  'githubAuthStatus',
  'githubConnect',
  'githubAwaitConnect',
  'githubCancelConnect',
  'githubDisconnect',
]

function resolveBridge(): GitHubBridge | null {
  const host = (window as unknown as { deck?: Partial<GitHubBridge> }).deck
  if (!host) return null
  for (const method of BRIDGE_METHODS) {
    if (typeof host[method] !== 'function') return null
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
  'auth-declined': 'Sign-in refused',
  'auth-code-expired': 'The sign-in code expired',
  'auth-unavailable': 'GitHub would not start a sign-in',
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
 * Whether the "run this command" line is worth printing.
 *
 * Several failures name their own fix inside the message — "Connect here, or
 * run gh auth login in a terminal" — and appending the command line to those
 * produced the same instruction twice in two consecutive sentences, which is
 * how a screen starts reading like it was generated rather than written. The
 * `action` field stays on the failure either way; this only decides whether it
 * gets a second airing.
 */
export function showsAction(failure: GitHubFailure): boolean {
  return failure.action !== null && !failure.message.includes(failure.action)
}

/**
 * Narrows either a section or the whole overview, both of which discriminate
 * on the same `ok` flag.
 */
export function isFailure<T extends { ok: boolean }>(value: T): value is T & GitHubFailure {
  return value.ok === false
}

/**
 * The repository arm of the sign-in state, which does *not* discriminate the
 * way everything else in this file does: a `RepoRef` carries no `ok` field at
 * all, so the presence of the key is the test — exactly the check `github.ts`
 * makes on the same value before it returns one. Passing it to `isFailure`
 * compiles nowhere and would read as a near-miss if it did.
 */
export function repoFailed(repo: RepoRef | GitHubFailure): repo is GitHubFailure {
  return 'ok' in repo
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

/**
 * A GitHub failure, at either scale.
 *
 * `page` means this block *is* the view — nothing loaded at all — and then it
 * is the same `PageEmpty` every other empty page in the app wears, rather than
 * a second thing that looks nearly like it. This one used to hand-roll the
 * glyph, the title and the button, and drifted: its title was a `<p>` where
 * everywhere else has an `<h2>`, and its retry a differently-sized button.
 *
 * Without `page` it is one section of a loaded page — a tab whose list failed
 * while the other tab is fine — and stays the compact left-aligned notice,
 * because the full centred block inside a populated page reads as the page
 * having crashed.
 */
export function FailureBlock({
  failure,
  onRetry,
  page,
}: {
  failure: GitHubFailure
  onRetry(): void
  page?: boolean
}) {
  const title = FAILURE_TITLE[failure.kind] ?? FAILURE_TITLE.error
  const retry = RETRYABLE.has(failure.kind) || failure.action
  const details = failure.detail ? (
    <details className="gh-failure-detail">
      <summary>Details</summary>
      <pre>{failure.detail}</pre>
    </details>
  ) : null

  if (page) {
    return (
      <PageEmpty
        icon={panelSpec('github').icon}
        title={title}
        action={retry ? { label: 'Retry', onClick: onRetry } : undefined}
        extra={details}
      >
        {failure.message}
        {showsAction(failure) && (
          <>
            {' '}
            Run <code>{failure.action}</code> in a terminal, then refresh.
          </>
        )}
      </PageEmpty>
    )
  }

  return (
    <div className="gh-failure" role="status">
      <p className="gh-failure-title">{title}</p>
      <p className="gh-failure-message">{failure.message}</p>
      {showsAction(failure) && (
        <p className="gh-failure-action">
          Run <code>{failure.action}</code> in a terminal, then refresh.
        </p>
      )}
      {details}
      {retry && (
        <button type="button" className="gh-retry" onClick={onRetry}>
          Retry
        </button>
      )}
    </div>
  )
}

/* ------------------------------------------------------------- connection -- */

/**
 * Where the credential in use came from, as a sentence rather than a word.
 *
 * The three sources are not interchangeable, and the difference only shows up
 * at the worst moment — when someone wants to get rid of one. A token set in a
 * shell profile looks exactly like a sign-in until Disconnect does nothing to
 * it, which is the Windows complaint this whole feature exists to answer. So
 * the source is spelled out on screen at all times, never left as an enum the
 * user has to infer.
 */
export function sourceSentence(source: AuthSource | null, host: string): string {
  switch (source) {
    case 'device-flow':
      return `Signed in here, in this app, on ${host}.`
    case 'gh-cli':
      return `Reusing the GitHub CLI’s own sign-in on ${host} — you were already signed in there.`
    case 'environment':
      return `Using the GH_TOKEN set in the environment this app was launched with, on ${host}.`
    default:
      return `Not signed in to ${host}.`
  }
}

/**
 * Which repository and branch the open folder is, in one line.
 *
 * It is built from the *sign-in* payload rather than from the pull-request
 * payload, and that is the whole reason it can be trusted to be on screen. The
 * repository name used to come from the overview, so the moment GitHub was
 * rate-limiting or the network was down — exactly when a user most wants to
 * know what the app thinks it is looking at — the line vanished along with the
 * lists. Both halves of this are local `git` reads that cannot fail for a
 * network reason.
 */
export function folderLine(repo: RepoRef | GitHubFailure | null, branch: BranchRef | null): string | null {
  if (repo === null) return null
  if (repoFailed(repo)) return repo.message
  if (!branch) return repo.nameWithOwner
  if (branch.detached) {
    return branch.head
      ? `${repo.nameWithOwner} · detached at ${branch.head}`
      : `${repo.nameWithOwner} · detached HEAD`
  }
  return branch.name ? `${repo.nameWithOwner} · ${branch.name}` : repo.nameWithOwner
}

/**
 * What pressing Connect is about to ask GitHub for, said before it is pressed.
 *
 * This block exists because of a screenshot. GitHub's authorisation page said
 * "Full control of private repositories" with no repository picker anywhere on
 * it, and the app had given no warning that it was going to. That screen was
 * the OAuth sign-in's, and the sign-in itself is gone now — so this says what
 * the one remaining path actually shows, which is a repository picker.
 *
 * It still renders before the button rather than after it. The point was never
 * the wording; it was that nobody arrives at GitHub's consent screen surprised.
 */
export function AccessNotice({ state }: { state: GitHubAuthState }) {
  return (
    <div className="gh-asks">
      <p className="gh-asks-title">What this asks for</p>
      <p className="gh-asks-body">
        Signing in installs a GitHub App, so GitHub will ask you to choose{' '}
        <strong>all repositories</strong> or <strong>only select repositories</strong>, and the app
        gets read-only access to what you pick — repository metadata, pull requests and issues.
      </p>
      {state.installUrl && (
        <button
          type="button"
          className="gh-asks-link"
          onClick={() => state.installUrl && openExternal(state.installUrl)}
        >
          Choose repositories on GitHub
        </button>
      )}
    </div>
  )
}

/**
 * The account circle.
 *
 * Deliberately the initial rather than `identity.avatarUrl`, and that is not a
 * style preference. This window runs under a Content-Security-Policy of
 * `img-src 'self' data:` (see `src/main/index.ts`), so an `<img>` pointing at
 * avatars.githubusercontent.com is blocked before it is fetched and renders as
 * a broken-image glyph next to the words "Connected as". A broken picture in
 * the one place the app is claiming to be working is worse than no picture.
 */
function AccountMark({ login }: { login: string }) {
  return (
    <span className="gh-avatar" aria-hidden="true">
      {login.slice(0, 1).toUpperCase()}
    </span>
  )
}

/**
 * The strip that answers "what am I connected as, and what may it do?".
 *
 * Everything on it is a fact read back from GitHub a moment ago rather than
 * something this app believes: the login and the scopes both come from the
 * `/user` response, which is the only call that proves the credential is alive
 * at all. `gh auth status` reports the token it has stored, not whether that
 * token still works, which is exactly how a revoked login keeps looking fine
 * until the first list fails.
 *
 * Disconnect asks first. It is one press from signing the user's *terminal*
 * out when the credential is the CLI's, and the sentence that says so is on
 * screen before the second press, not after it.
 */
export function ConnectionBar({
  state,
  busy,
  confirming,
  onAskDisconnect,
  onDisconnect,
  onKeep,
}: {
  state: GitHubAuthState
  busy?: boolean
  confirming?: boolean
  onAskDisconnect(): void
  onDisconnect(): void
  onKeep(): void
}) {
  const login = state.identity?.login ?? 'unknown account'

  return (
    <div className="gh-conn" data-confirming={confirming || undefined}>
      <AccountMark login={login} />

      <div className="gh-conn-body">
        <p className="gh-conn-title">
          Connected as{' '}
          <button
            type="button"
            className="gh-conn-login"
            onClick={() => state.identity && openExternal(state.identity.htmlUrl)}
            title={`Open ${login} on ${state.host}`}
          >
            {login}
          </button>
          {state.identity?.name && <span className="gh-conn-name">{state.identity.name}</span>}
        </p>
        <p className="gh-conn-source">{sourceSentence(state.source, state.host)}</p>

        {state.scopesReported ? (
          /*
            One labelled run, not two.

            It used to be split into "Used here" and "Also granted", because
            this app asked GitHub for a named list of scopes and the split said
            which of a token's scopes were on it. It asks for none now — a
            GitHub App device request carries no `scope` at all — so every chip
            would land in "Also granted", and a label that says "also" with
            nothing before it is worse than no label. What is left is the honest
            fact: GitHub reports these on this credential.
          */
          <p className="gh-conn-scopes">
            <span className="gh-conn-scopes-label">Granted</span>
            {state.scopes.length === 0 ? (
              <span className="gh-scope" data-empty="true">
                nothing
              </span>
            ) : (
              state.scopes.map((scope) => (
                <span key={scope} className="gh-scope">
                  {scope}
                </span>
              ))
            )}
          </p>
        ) : (
          /* A fine-grained token or a GitHub App installation sends no
             `X-OAuth-Scopes` header at all — which is what a sign-in from this
             app now always produces. That is not the same fact as a token with
             no permissions, and printing "Granted: nothing" for a credential
             that works perfectly would send the user to fix something that is
             not broken. */
          <p className="gh-conn-source">
            GitHub did not report a permission list for this credential, which is normal for a
            GitHub App sign-in. Whether a list loads is the real test.
          </p>
        )}
      </div>

      {confirming ? (
        <div className="gh-conn-confirm">
          <p className="gh-conn-confirm-text">{state.disconnect}</p>
          <div className="gh-conn-confirm-row">
            <button type="button" className="gh-conn-danger" onClick={onDisconnect} disabled={busy}>
              Disconnect
            </button>
            <button type="button" className="gh-conn-keep" onClick={onKeep} disabled={busy}>
              Keep it
            </button>
          </div>
        </div>
      ) : state.disconnect ? (
        <button
          type="button"
          className="gh-conn-action"
          onClick={onAskDisconnect}
          disabled={busy}
          title={state.disconnect}
        >
          Disconnect
        </button>
      ) : (
        /* `disconnect` is null only for the environment source, where there is
           genuinely nothing this process can revoke — it cannot unset a
           variable in the shell that launched it. A button that silently did
           nothing would be worse than this sentence. */
        <p className="gh-conn-note">
          Nothing to disconnect — unset <code>GH_TOKEN</code> and restart.
        </p>
      )}
    </div>
  )
}

/**
 * What the sign-in card shows when the bridge itself never answered.
 *
 * A disconnected state rather than a blank one, because every field below has
 * to be a fact: claiming `ghInstalled` or `appConfigured` when nothing has been
 * probed would put a sentence on screen that was never checked. The failure is
 * the honest one — the app could not ask, which is different from GitHub saying
 * no.
 */
export function bridgeSilentState(): GitHubAuthState {
  return {
    connected: false,
    source: null,
    host: 'github.com',
    identity: null,
    scopes: [],
    scopesReported: false,
    ghInstalled: false,
    // Nothing is connected in this state, and null is what "no credential" is
    // spelled as everywhere else. A kind here would describe a sign-in that
    // does not exist.
    credentialKind: null,
    appConfigured: false,
    installUrl: null,
    disconnect: null,
    pending: null,
    failure: {
      ok: false,
      kind: 'error',
      message: 'The GitHub bridge did not answer, so your sign-in could not be checked.',
      action: null,
      detail: '',
    },
    expiredCredentialRemoved: false,
    repo: null,
    branch: null,
    access: null,
  }
}

/** Whole minutes left on a device code, floored, never negative. */
export function minutesLeft(expiresAt: number, now: number): number {
  return Math.max(0, Math.floor((expiresAt - now) / MINUTE))
}

/**
 * The code, while GitHub waits for it to be typed.
 *
 * The user code is not a credential — it is meant to be read aloud across a
 * desk — so it is the largest thing on the page. The access token that arrives
 * at the end of this exchange never crosses into the renderer at all: the main
 * process stores it and hands the panel a login and a scope list, which is why
 * there is nothing here that could print one by accident.
 */
export function DeviceCodeCard({
  prompt,
  now,
  copied,
  busy,
  onCopy,
  onOpen,
  onCancel,
}: {
  prompt: DeviceFlowPrompt
  now: number
  copied?: boolean
  busy?: boolean
  /** Absent where the clipboard is unavailable — see the panel's `copyCode`. */
  onCopy?: () => void
  onOpen(): void
  onCancel(): void
}) {
  const minutes = minutesLeft(prompt.expiresAt, now)
  /**
   * Screen readers run the code together as a word otherwise, and this one is
   * read out loud to nobody but the person typing it.
   */
  const spelled = prompt.userCode.split('').join(' ')

  return (
    <div className="gh-device" role="status">
      <h2 className="gh-device-title">Type this code on GitHub</h2>
      <p className="gh-device-body">
        Your browser should already be open at <code>{prompt.verificationUri}</code>. Enter the code
        below and approve the permissions; this window finishes on its own.
      </p>

      {onCopy ? (
        <button
          type="button"
          className="gh-device-code"
          onClick={onCopy}
          title="Copy this code"
          aria-label={`Sign-in code ${spelled}. Click to copy.`}
        >
          {prompt.userCode}
          <span className="gh-device-copy">{copied ? 'Copied' : 'Copy'}</span>
        </button>
      ) : (
        <p className="gh-device-code" data-static="true" aria-label={`Sign-in code ${spelled}`}>
          {prompt.userCode}
        </p>
      )}

      <p className="gh-device-expiry">
        {minutes > 0
          ? `The code works for about ${minutes} more ${minutes === 1 ? 'minute' : 'minutes'}.`
          : 'This code has expired — press Connect again for a new one.'}
      </p>

      {/* One sentence, because there is one sign-in. This used to branch on the
          prompt's client kind and print a scope list for the other arm; that
          arm is gone, and with it the "GitHub's page will say GitHub CLI"
          apology the borrowed client id needed. */}
      <p className="gh-device-asks">
        GitHub will ask which repositories this app may see — all of them, or only the ones you
        pick.
      </p>

      <div className="gh-device-row">
        <button type="button" className="btn-primary gh-device-open" onClick={onOpen}>
          Open GitHub again
        </button>
        <button type="button" className="gh-device-cancel" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
      </div>
    </div>
  )
}

/**
 * The page when there is no usable credential.
 *
 * It is a `PageEmpty` and not a hand-rolled block because it is the same
 * "nothing here yet" shape as every other panel's, and because the one thing
 * worth pressing belongs in the one place every other page puts it. The title
 * and the body come straight from the typed failure, so "the GitHub CLI is not
 * installed", "you refused on GitHub" and "your token expired" arrive as three
 * different screens rather than three copies of "GitHub failed".
 */
export function ConnectPage({
  state,
  busy,
  onConnect,
  onRetry,
}: {
  state: GitHubAuthState
  busy?: boolean
  onConnect(): void
  onRetry(): void
}) {
  const failure = state.failure
  const title = failure ? (FAILURE_TITLE[failure.kind] ?? FAILURE_TITLE.error) : 'Not signed in to GitHub'
  /**
   * Connecting is offered for anything that a sign-in could actually fix. A
   * rate limit or a dead network is not one of those: pressing Connect during
   * an outage produces a second, identical error, so those get Retry instead.
   */
  const retryOnly = failure !== null && RETRYABLE.has(failure.kind)
  /**
   * No registration, no button.
   *
   * Connect sends a `client_id` to GitHub's device endpoint, and a build with
   * no GitHub App registered has none to send — the request would come back as
   * a 404 that names nothing, every time, for ever. This used to fall through
   * to the OAuth client and sign the user in as the GitHub CLI, which is the
   * fallback that was deleted. What is left is the honest shape: the failure's
   * own sentence, which names `gh auth login` and the environment variable a
   * fork sets, and no control that cannot work.
   */
  const canConnect = state.appConfigured

  return (
    <>
      <PageEmpty
        icon={panelSpec('github').icon}
        title={title}
        action={
          retryOnly
            ? { label: 'Try again', onClick: onRetry, busy }
            : canConnect
              ? { label: busy ? 'Connecting…' : 'Connect to GitHub', onClick: onConnect, busy, primary: true }
              : { label: 'Check again', onClick: onRetry, busy }
        }
        hint={
          state.ghInstalled && !retryOnly ? (
            <>
              An existing <code>gh auth login</code> is reused automatically, so nothing here signs
              you in twice.
            </>
          ) : null
        }
        extra={
          <>
            {/* Before the button, not after it. The point of this block is that
                nobody arrives at GitHub's consent screen surprised by what it
                says — which is what happened, and is what this whole change is
                about. It is withheld for a rate limit or a dead network, where
                the next press is Retry and the permissions are not the story,
                and for a build that cannot start a sign-in at all. */}
            {!retryOnly && canConnect && <AccessNotice state={state} />}
            {failure?.detail && (
              <details className="gh-failure-detail">
                <summary>Details</summary>
                <pre>{failure.detail}</pre>
              </details>
            )}
          </>
        }
      >
        {failure?.message ?? 'Connect an account to see this project’s pull requests and issues.'}
        {failure && showsAction(failure) && (
          <>
            {' '}
            You can also run <code>{failure.action}</code> in a terminal.
          </>
        )}
      </PageEmpty>

      {/* `PageNote` inherits its container's alignment by design, and this
          container is the page. Without a centred wrapper these two lines sat
          hard against the left edge while the block they belong to was in the
          middle of the window, reading as two stray sentences from some other
          screen. Same width as `.page-blank` so they wrap on the same column. */}
      {(state.expiredCredentialRemoved || state.repo !== null) && (
        <div className="gh-connect-notes">
          {state.expiredCredentialRemoved && (
            <PageNote>
              The sign-in this app had stored was rejected by GitHub, so it was deleted. Nothing
              else was changed.
            </PageNote>
          )}

          {state.repo !== null && (
            <PageNote>
              {repoFailed(state.repo)
                ? state.repo.message
                : `This folder is ${folderLine(state.repo, state.branch)}, and it will load as soon as you are signed in.`}
            </PageNote>
          )}
        </div>
      )}
    </>
  )
}

/* ---------------------------------------------------------- repositories -- */

/**
 * Narrow the list as somebody types.
 *
 * Client-side, over the page already in memory, and the summary line above it
 * says so — the alternative is a search box that quietly searches a hundred of
 * five hundred repositories and returns "no matches" for one that exists. Owner
 * and description are searched as well as the name because "the acme one" and
 * "the deploy scripts" are how people actually remember repositories.
 */
export function filterRepos(repos: RepoSummary[], query: string): RepoSummary[] {
  const needle = query.trim().toLowerCase()
  if (!needle) return repos
  return repos.filter(
    (repo) =>
      repo.nameWithOwner.toLowerCase().includes(needle) ||
      (repo.description ?? '').toLowerCase().includes(needle),
  )
}

/**
 * How many repositories this credential can reach, in the most honest form the
 * data supports.
 *
 * A truncated list must never render a bare count. "100 repositories" for an
 * account with five hundred is a specific wrong number and looks exactly like a
 * right one; `atLeast` is the bound GitHub's own pagination implies, so "500+"
 * is a fact rather than an estimate.
 */
export function accessSummary(access: RepoAccessList): string {
  const shown = access.repos.length
  if (!access.truncated) {
    return shown === 1 ? '1 repository' : `${shown} repositories`
  }
  return `${access.atLeast}+ repositories · showing the ${shown} most recently pushed`
}

/**
 * Where a GitHub App grant came from, when that is a thing the user chose.
 *
 * Only said for an installation: an OAuth token's `repo` scope leaves no choice
 * to make, so printing "all repositories" there would describe a decision
 * nobody took.
 */
export function selectionSentence(access: RepoAccessList): string | null {
  if (access.source !== 'installation') return null
  return access.selection === 'all'
    ? 'This GitHub App is installed on all your repositories.'
    : 'These are the repositories you selected when installing the app. Change them on GitHub at any time.'
}

export function RepoRow({
  repo,
  now,
  current,
}: {
  repo: RepoSummary
  now: number
  /** True for the repository of the folder currently open. */
  current?: boolean
}) {
  return (
    <li>
      <button
        type="button"
        className="gh-row"
        data-kind="repo"
        data-current={current || undefined}
        onClick={() => openExternal(repo.url)}
        title={`${repo.nameWithOwner} — open on GitHub`}
      >
        {/*
          `private`/`public` rather than one of the four pull-request states.
          Reusing `data-badge="open"` for a public repository borrowed the green
          that means "this pull request is open and waiting on somebody", which
          is a status; visibility is not one. The CSS paints these two neutral.
        */}
        <span className="gh-badge" data-badge={repo.private ? 'private' : 'public'}>
          {repo.private ? 'private' : 'public'}
        </span>
        <span className="gh-body">
          <span className="gh-title">
            {repo.nameWithOwner}
            {current && <span className="gh-here">this folder</span>}
          </span>
          <span className="gh-meta">
            {repo.description && <span className="gh-repo-desc">{repo.description}</span>}
            {repo.language && <span className="gh-repo-lang">{repo.language}</span>}
            {repo.fork && <span className="gh-fork">fork</span>}
            {repo.archived && <span className="gh-fork">archived</span>}
            {repo.pushedAt && (
              <span className="gh-age" title={repo.pushedAt}>
                {formatAge(repo.pushedAt, now)}
              </span>
            )}
          </span>
        </span>
      </button>
    </li>
  )
}

/**
 * The repositories this sign-in can reach.
 *
 * This tab is the answer to "I connected and I saw nothing". It depends on the
 * credential and nothing else, so it has something to show from a folder that
 * is not a repository, a folder with no GitHub remote, and a folder whose
 * repository this account cannot see — every case where the rest of the page
 * has, correctly, nothing.
 */
export function RepositoryList({
  access,
  query,
  onQuery,
  current,
  installUrl,
  onRetry,
  now,
}: {
  access: RepoAccess | null
  query: string
  onQuery(value: string): void
  /** `owner/name` of the open folder's repository, marked in the list. */
  current: string | null
  installUrl: string | null
  onRetry(): void
  now: number
}) {
  if (access === null) {
    return <PageNote busy>Reading your repositories…</PageNote>
  }

  if (isFailure(access)) {
    return <FailureBlock failure={access} onRetry={onRetry} />
  }

  const shown = filterRepos(access.repos, query)
  const selection = selectionSentence(access)

  return (
    <div className="gh-repos">
      <div className="gh-repos-head">
        <p className="gh-repos-count">{accessSummary(access)}</p>
        {access.repos.length > 5 && (
          <input
            type="search"
            className="gh-repos-filter"
            placeholder="Filter"
            aria-label="Filter repositories"
            value={query}
            onChange={(event) => onQuery(event.target.value)}
          />
        )}
      </div>

      {selection && <p className="gh-note">{selection}</p>}

      {access.repos.length === 0 ? (
        <PageNote>
          This sign-in cannot reach any repositories.
          {installUrl ? ' Install the app on the repositories you want it to see.' : ''}
        </PageNote>
      ) : shown.length === 0 ? (
        <PageNote>
          Nothing matches “{query}”
          {access.truncated ? ' in the page loaded here — the full list is on GitHub.' : '.'}
        </PageNote>
      ) : (
        <ul className="gh-list">
          {shown.map((repo) => (
            <RepoRow
              key={repo.nameWithOwner}
              repo={repo}
              now={now}
              current={current !== null && repo.nameWithOwner === current}
            />
          ))}
        </ul>
      )}

      {installUrl && (
        <button type="button" className="gh-asks-link" onClick={() => openExternal(installUrl)}>
          Change which repositories this app can see
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
  /**
   * The sign-in, which is now read *before* anything else and gates the rest.
   *
   * Null means "not asked yet". It has to be its own state rather than being
   * inferred from a failed overview, because the two answer different
   * questions: an overview can fail because this folder is not a repository
   * while the account is connected perfectly, and the old panel rendered both
   * of those as the same red block with no way to tell them apart.
   */
  const [auth, setAuth] = useState<GitHubAuthState | null>(null)
  const [authLoading, setAuthLoading] = useState(true)
  const [authBusy, setAuthBusy] = useState(false)
  const [confirmingDisconnect, setConfirmingDisconnect] = useState(false)
  const [copied, setCopied] = useState(false)
  /**
   * The repository filter. Renderer-side state rather than a query sent to
   * GitHub, and the list says so — a search box that silently searches the
   * hundred repositories loaded rather than all five hundred would answer "no
   * matches" for a repository that exists.
   */
  const [repoQuery, setRepoQuery] = useState('')
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

  /**
   * Read the sign-in. Nothing else on this page runs until this answers.
   *
   * Sequential rather than parallel with the lists, and that is a deliberate
   * cost trade: one list refresh is three `gh` child processes, and while
   * nobody is signed in all three of them spawn, fail, and produce an error the
   * panel then discards in favour of the connect screen. Asking the cheap
   * question first — one HTTP call, cached in the main process — means the
   * signed-out case costs nothing and paints immediately.
   */
  const loadAuth = useCallback(async (): Promise<GitHubAuthState | null> => {
    if (!api) return null
    const asked = cwd
    try {
      const next = await api.githubAuthStatus(asked)
      if (shown.current !== asked) return null
      setAuth(next)
      return next
    } catch {
      if (shown.current === asked) setAuth(bridgeSilentState())
      return null
    } finally {
      if (shown.current === asked) setAuthLoading(false)
    }
  }, [api, cwd])

  useEffect(() => {
    if (!api) {
      setLoading(false)
      setAuthLoading(false)
      return
    }
    shown.current = cwd
    setLoading(true)
    setAuthLoading(true)
    setResult(null)
    setAuth(null)
    setConfirmingDisconnect(false)
    setCopied(false)
    setRepoQuery('')
    setTab(initialTab)
    // A refresh that was still in flight for the previous folder will never
    // reach its own cleanup — the guard below discards it — so the button it
    // disabled has to be released here or it stays greyed out.
    setBusy(false)
    setAuthBusy(false)
    void loadAuth().then((state) => {
      if (state?.connected) void load(false)
      // Not signed in, or the bridge went quiet: there is no list to wait for,
      // so the "Reading GitHub…" line must be taken down or it sits under the
      // connect screen for ever.
      else if (shown.current === cwd) setLoading(false)

      /*
       * Land on the tab that has something in it.
       *
       * Pull requests is the right first tab for a project folder and the wrong
       * one for a folder that is not a GitHub repository, where it can only ever
       * show the same "not a repository" notice the header already carries.
       * Done here — on mount and on a folder change — rather than on every
       * status read, because the focus poll runs the same call and would drag
       * the user off whichever tab they had chosen.
       */
      if (state?.connected && state.repo !== null && repoFailed(state.repo)) setTab('repos')
    })

    return () => {
      shown.current = null
    }
  }, [api, cwd, initialTab, load, loadAuth])

  /**
   * Start a device-flow sign-in, and see it through.
   *
   * Two awaits rather than one because they are two different waits: the first
   * returns the moment GitHub issues a code, which is what puts something on
   * screen for the user to act on, and the second is the long one that resolves
   * when they finish, refuse, or let the code expire. Collapsing them into a
   * single call would leave the window blank for the whole minute somebody
   * spends walking to their browser.
   */
  const connect = useCallback(async () => {
    if (!api || authBusy) return
    const asked = cwd
    setAuthBusy(true)
    setCopied(false)
    setConfirmingDisconnect(false)
    try {
      const started = await api.githubConnect()
      if (shown.current !== asked) return

      // `ok` exists only on the failure arm — a prompt carries no such field,
      // the same discrimination `github.ts` uses for a resolved repository.
      if ('ok' in started) {
        setAuth((current) => ({ ...(current ?? bridgeSilentState()), pending: null, failure: started }))
        return
      }

      // The browser is opened for them rather than left as an instruction. A
      // code on screen beside a URL somebody has to retype by hand is the
      // "connect it yourself" flow this was meant to replace, not a version of
      // it — and the card keeps an "Open GitHub again" button for the tab that
      // gets closed by accident.
      openExternal(started.verificationUri)
      setAuth((current) => ({ ...(current ?? bridgeSilentState()), pending: started, failure: null }))

      const settled = await api.githubAwaitConnect(asked)
      if (shown.current !== asked) return
      setAuth(settled)
      if (settled.connected) {
        setLoading(true)
        void load(false)
      }
    } catch {
      if (shown.current === asked) setAuth(bridgeSilentState())
    } finally {
      if (shown.current === asked) setAuthBusy(false)
    }
  }, [api, authBusy, cwd, load])

  const cancelConnect = useCallback(async () => {
    if (!api) return
    const asked = cwd
    try {
      const next = await api.githubCancelConnect(asked)
      if (shown.current === asked) setAuth(next)
    } catch {
      if (shown.current === asked) setAuth(bridgeSilentState())
    }
  }, [api, cwd])

  const disconnect = useCallback(async () => {
    if (!api) return
    const asked = cwd
    setAuthBusy(true)
    try {
      const next = await api.githubDisconnect(asked)
      if (shown.current !== asked) return
      setAuth(next)
      setConfirmingDisconnect(false)
      // The lists on screen were loaded under the credential that has just
      // gone. Leaving them up behind a "not signed in" card is exactly the
      // half-connected display this feature exists to end.
      setResult(null)
      setLoading(false)
    } catch {
      if (shown.current === asked) setAuth(bridgeSilentState())
    } finally {
      if (shown.current === asked) setAuthBusy(false)
    }
  }, [api, cwd])

  /**
   * Copy the code, but only where copying can actually happen.
   *
   * `navigator.clipboard` is absent outside a secure context and in the test
   * environment, and a Copy button that silently does nothing is the promise
   * this codebase's house rules put first. So the affordance is handed to the
   * card only when the API exists; without it the code renders as selectable
   * text instead.
   */
  const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
  const copyCode = useCallback(
    (code: string) => {
      if (!clipboard) return
      void clipboard.writeText(code).then(
        () => setCopied(true),
        () => setCopied(false),
      )
    },
    [clipboard],
  )

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
    if (!api || shown.current !== cwd) return
    // A sign-in in flight owns the panel until it settles. Re-reading the
    // status underneath it would be harmless — the pending code is carried
    // through every status reply — but the second `void load` it triggers
    // would not be.
    if (authBusy) return
    void loadAuth().then((state) => {
      if (state?.connected) void load(false)
    })
  })

  const refresh = useCallback(() => void load(true), [load])
  const clock = now ?? Date.now()

  if (!api) {
    return (
      <section className="gh-panel" aria-label="GitHub">
        <PageEmpty icon={panelSpec('github').icon} title="GitHub is not available here">
          This window was opened without the GitHub bridge, so there is nothing for this page to
          read.
        </PageEmpty>
      </section>
    )
  }

  if (authLoading) {
    return (
      <section className="gh-panel" aria-label="GitHub" aria-busy="true">
        <PageNote page busy>
          Checking your GitHub sign-in…
        </PageNote>
      </section>
    )
  }

  /**
   * `auth` is only null when the bridge threw before the first status landed,
   * and that is a state with its own sentence rather than a blank page.
   */
  const state = auth ?? bridgeSilentState()
  const pending = state.pending

  if (pending) {
    return (
      <section className="gh-panel" aria-label="GitHub">
        <DeviceCodeCard
          prompt={pending}
          now={clock}
          copied={copied}
          busy={authBusy}
          onCopy={clipboard ? () => copyCode(pending.userCode) : undefined}
          onOpen={() => openExternal(pending.verificationUri)}
          onCancel={() => void cancelConnect()}
        />
      </section>
    )
  }

  if (!state.connected) {
    return (
      <section className="gh-panel" aria-label="GitHub">
        <ConnectPage
          state={state}
          busy={authBusy}
          onConnect={() => void connect()}
          onRetry={() => void loadAuth()}
        />
      </section>
    )
  }

  /**
   * Rendered above every other branch below, so who you are connected as is on
   * screen whether the lists loaded, failed, or are still coming. That is the
   * whole complaint answered: there is no state of this page where the app is
   * doing something with a GitHub account and not saying which one.
   */
  const connection = (
    <ConnectionBar
      state={state}
      busy={authBusy}
      confirming={confirmingDisconnect}
      onAskDisconnect={() => setConfirmingDisconnect(true)}
      onDisconnect={() => void disconnect()}
      onKeep={() => setConfirmingDisconnect(false)}
    />
  )

  /**
   * One page from here down, rather than three early returns.
   *
   * The old shape bailed out to a full-page error whenever the *overview*
   * failed, which meant a signed-in user standing in a folder that is not a
   * GitHub repository saw a connection bar over an error and nothing else — no
   * evidence anywhere that signing in had bought them anything. The failure is
   * still shown, in the tab it belongs to, with the repository list beside it.
   */
  const overview = result && !isFailure(result) ? result : null
  const overviewFailure =
    result && isFailure(result)
      ? result
      : !loading && !result
        ? ({
            ok: false,
            kind: 'error',
            message: 'No answer from the GitHub bridge.',
            action: null,
            detail: '',
          } as GitHubFailure)
        : null

  const folderRepo = state.repo !== null && !repoFailed(state.repo) ? state.repo : null
  const folder = folderLine(state.repo, state.branch)
  const access = state.access
  const pulls = overview?.pulls ?? null
  const issues = overview?.issues ?? null
  const limit = overview?.limit ?? 0
  const pullCount = countLabel(pulls?.ok ? pulls.value.length : null, limit)
  const issueCount = countLabel(issues?.ok ? issues.value.length : null, limit)
  const repoCount = access && access.ok ? (access.truncated ? `${access.atLeast}+` : String(access.repos.length)) : null

  /**
   * What a list tab shows when the folder has no repository behind it.
   *
   * The sentence comes from the repository resolution — "this folder is not a
   * git repository", "none of this repository's remotes point at GitHub" — so
   * the three causes stay three different screens, which is what the whole
   * failure vocabulary in `github.ts` exists for.
   */
  const listBody = (
    kind: 'pulls' | 'issues',
    section: Section<PullRequest[]> | Section<Issue[]> | null,
  ) => {
    if (state.repo !== null && repoFailed(state.repo)) {
      return <FailureBlock failure={state.repo} onRetry={() => void loadAuth()} />
    }
    if (loading && !section) return <PageNote busy>Reading GitHub…</PageNote>
    if (overviewFailure) return <FailureBlock failure={overviewFailure} onRetry={refresh} />
    if (!section) return <PageNote busy>Reading GitHub…</PageNote>
    if (isFailure(section)) return <FailureBlock failure={section} onRetry={refresh} />
    if (section.value.length === 0) {
      return <PageNote>{kind === 'pulls' ? 'No open pull requests.' : 'No open issues.'}</PageNote>
    }
    return (
      <ul className="gh-list">
        {kind === 'pulls'
          ? (section.value as PullRequest[]).map((pull) => (
              <PullRow key={pull.number} pull={pull} now={clock} />
            ))
          : (section.value as Issue[]).map((issue) => (
              <IssueRow key={issue.number} issue={issue} now={clock} />
            ))}
      </ul>
    )
  }

  return (
    <section className="gh-panel" aria-label="GitHub">
      {connection}

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

        {/*
          Built from the sign-in payload, not from the pull-request payload.
          Both halves are local `git` reads, so the one line that says what the
          app thinks it is looking at survives a rate limit, an outage and a
          repository this account cannot see — which are exactly the moments
          somebody needs it. When the folder has no repository at all, the
          resolution's own sentence stands in for the name.
        */}
        {folderRepo ? (
          <button
            type="button"
            className="gh-repo"
            onClick={() => openExternal(folderRepo.url)}
            title={`${folderRepo.nameWithOwner} — open on GitHub (remote: ${folderRepo.remote})`}
          >
            {folder}
          </button>
        ) : (
          <p className="gh-repo-none">{folder ?? 'No folder open'}</p>
        )}

        <span className="gh-head-spacer" />

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
        {/*
          The third tab, and the one that answers "I connected and saw nothing".
          It reads the credential rather than the folder, so it has something to
          show in every state where the two above them correctly have nothing.
        */}
        <button
          type="button"
          role="tab"
          id="gh-tab-repos"
          aria-selected={tab === 'repos'}
          aria-controls="gh-panel-repos"
          className="gh-tab"
          onClick={() => setTab('repos')}
        >
          Repositories
          {repoCount !== null && <span className="gh-tab-count">{repoCount}</span>}
        </button>
      </div>

      {tab === 'pulls' && (
        <div className="gh-list-wrap" role="tabpanel" id="gh-panel-pulls" aria-labelledby="gh-tab-pulls">
          {listBody('pulls', pulls)}
        </div>
      )}
      {tab === 'issues' && (
        <div className="gh-list-wrap" role="tabpanel" id="gh-panel-issues" aria-labelledby="gh-tab-issues">
          {listBody('issues', issues)}
        </div>
      )}
      {tab === 'repos' && (
        <div className="gh-list-wrap" role="tabpanel" id="gh-panel-repos" aria-labelledby="gh-tab-repos">
          <RepositoryList
            access={access}
            query={repoQuery}
            onQuery={setRepoQuery}
            current={folderRepo?.nameWithOwner ?? null}
            // The *credential's* kind, and it still has to be checked even
            // though this build only ever mints GitHub App credentials. Three
            // classic ones still reach this panel — a `gh auth login` reused
            // from the CLI, a `GH_TOKEN` in the environment, and anything left
            // on disk by the OAuth sign-in deleted on 2026-08-16 — and none of
            // them has an installation to change. Offering "choose which
            // repositories this app can see" to those is a link to a screen
            // that has nothing to do with the list above it.
            installUrl={state.credentialKind === 'github-app' ? state.installUrl : null}
            onRetry={() => void loadAuth()}
            now={clock}
          />
        </div>
      )}
    </section>
  )
}
