import { execFile } from 'node:child_process'
import { stat } from 'node:fs/promises'
import { isAbsolute } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import {
  githubToolToken,
  registerGitHubAuthIpc,
  scrubGitHubSecrets,
  type GitHubAuthenticator,
} from './github-auth'
import { currentPlatform, withPath, type Platform } from './platform/host'
import { loginPath } from './providers'

const run = promisify(execFile)

/* ------------------------------------------------------------------ types -- */

/**
 * Why GitHub data is unavailable. Every one of these has a different fix, so
 * they are kept apart rather than collapsed into a single "failed" state — the
 * whole point of this module is that "you are not logged in" and "this folder
 * has no GitHub remote" never look the same to the user.
 */
/**
 * What a folder with no repository is told, on this page.
 *
 * It used to be *"This folder is not a git repository."* with `git init` as the
 * action, and the block that draws it heads every failure with a title — for
 * this kind, "Not a git repository". So the page printed the same sentence
 * twice, three lines apart, and then told the reader to go and type a command
 * in a terminal. Asad has now caught the duplicate-then-explain shape all over
 * the app: *"don't put any single statement in anywhere."*
 *
 * The title carries the fact. This line carries the one thing the title cannot:
 * where in this app the situation is fixed — Source control has a button for it
 * since 2026-08-20 (`main/git.ts`, `initRepository`), so the advice is no longer
 * "leave the app". It matches the sentence `git.ts` hands its own surfaces, so
 * the two pages describing one folder describe it the same way.
 */
const NOT_A_REPO = 'This folder is not a git repository. Source control can create one.'

export type GitHubErrorKind =
  | 'gh-missing'
  | 'not-authenticated'
  | 'auth-expired'
  /**
   * `gh` said a scope is missing, in its own stderr. Nothing in this app asks
   * GitHub for scopes any more — a GitHub App device request carries none — but
   * a `gh auth login` token reused from the CLI can still be short of one, and
   * `classifyGhError` recognises the sentence when `gh` prints it.
   */
  | 'missing-scope'
  /** The person said no on GitHub's consent screen, or cancelled here. */
  | 'auth-declined'
  /** A device-flow code was never entered and timed out. */
  | 'auth-code-expired'
  /**
   * GitHub would not start a sign-in at all: this build has no GitHub App
   * registered, or the one it has was deleted or had Device Flow unticked.
   */
  | 'auth-unavailable'
  | 'not-a-repo'
  | 'no-such-folder'
  | 'no-remote'
  | 'no-github-remote'
  | 'git-missing'
  | 'repo-not-found'
  | 'no-access'
  /**
   * The repository has its issue tracker switched off on GitHub. Not a failure:
   * nothing is broken, nothing can be retried, and there is no error to show.
   * `gh` reports it as an ordinary command failure — *"the 'o/n' repository has
   * disabled issues"* — which is how the panel came to dress a settings choice
   * as a red error with a Retry that could never succeed.
   */
  | 'issues-disabled'
  | 'rate-limited'
  | 'network-down'
  | 'timeout'
  | 'error'

export interface GitHubFailure {
  ok: false
  kind: GitHubErrorKind
  /** One sentence, plain language, describing what is wrong. */
  message: string
  /** The command that fixes it, or null when there is nothing to run. */
  action: string | null
  /** Raw tool output, credentials stripped. Shown behind a disclosure. */
  detail: string
}

export interface RepoRef {
  /** github.com, or an enterprise host taken from the remote URL. */
  host: string
  owner: string
  name: string
  nameWithOwner: string
  /** Canonical web URL, rebuilt from the parts — never the raw remote URL. */
  url: string
  /** Which git remote this came from, so the UI can say "upstream" not "origin". */
  remote: string
}

/**
 * The branch checked out in a project folder.
 *
 * Deliberately *not* a field on `RepoRef`. A `RepoRef` is a repository's
 * identity — the same three values whoever is looking and whatever they have
 * checked out — and folding a working-copy fact into it would mean two
 * worktrees of one repository produced two different "repositories", which is
 * precisely the confusion the cache keys in this module were written to avoid.
 *
 * `git.ts` has a much richer `GitBranch` (ahead, behind, upstream, oid) read
 * from `git status --porcelain=v2`. This is not that and must not become it:
 * `git status` refreshes the index and walks the worktree, which on a large
 * repository is tens of milliseconds and occasionally seconds, and this runs on
 * every GitHub sign-in status read. One `git symbolic-ref` answers the only
 * question this panel asks.
 */
export interface BranchRef {
  /** Null when HEAD is detached. */
  name: string | null
  detached: boolean
  /** Short commit id, filled in only when detached — otherwise null. */
  head: string | null
}

export interface GitHubLabel {
  name: string
  /** Six hex digits with no leading '#', exactly as GitHub reports it. */
  color: string
}

/** What the badge on a pull-request row says. */
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
  /** Null when GitHub has no decision — an unreviewed PR with no reviewers. */
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
  /** Why a closed issue closed; null while it is open or when unreported. */
  reason: 'completed' | 'not-planned' | null
  author: string | null
  authorIsBot: boolean
  createdAt: string
  updatedAt: string
  labels: GitHubLabel[]
  assignees: string[]
}

/**
 * One section of the panel. A list that fails must not blank out the one beside
 * it that loaded fine, so each section carries its own outcome.
 *
 * There were three sections until 2026-08-16. The third was the notifications
 * bell, and it is gone — not emptied, not left showing a permanent error.
 * GitHub's reference for its notifications endpoints carries the note,
 * verbatim: *"These endpoints only support authentication using a personal
 * access token (classic)."* Read off the live page rather than recalled, and
 * corroborated by GitHub's own OpenAPI description, where all ten operations in
 * the `notifications` subcategory are marked `"enabledForGitHubApps": false`.
 * This app signs in through a GitHub App and nothing else, so the credential it
 * holds can never call them, and there is no permission on any registration
 * that would change it. A feature that cannot work does not ship as an empty
 * list.
 */
export type Section<T> = { ok: true; value: T } | GitHubFailure

export interface GitHubOverview {
  ok: true
  cwd: string
  repo: RepoRef
  pulls: Section<PullRequest[]>
  issues: Section<Issue[]>
  /**
   * Rows asked for per list. The renderer needs it to tell "20 open pull
   * requests" apart from "the first 20 of however many there are" — a full
   * list is a truncated one, and a count that does not say so is wrong.
   */
  limit: number
  /** Epoch ms of the newest data in this payload. */
  fetchedAt: number
}

export type GitHubResult = GitHubOverview | GitHubFailure

export interface OverviewOptions {
  /** Skip the cache for this call. Wired to the panel's refresh button. */
  refresh?: boolean
  /** Rows per list, clamped to 1..100. */
  limit?: number
}

/* --------------------------------------------------------------- failures -- */

/**
 * Cap on the raw tool output kept in a failure. `gh` is given an 8 MB buffer
 * per stream, so an unbounded `detail` can carry sixteen megabytes across IPC
 * and into a `<pre>` that is 140 pixels tall. Truncation happens *after*
 * redaction, never before: cutting first could sever a credential URL just
 * ahead of its `@`, leaving the token itself as the last thing in the string.
 */
const MAX_DETAIL = 4_000

function truncateDetail(text: string): string {
  if (text.length <= MAX_DETAIL) return text
  return `${text.slice(0, MAX_DETAIL)}\n… ${text.length - MAX_DETAIL} more characters`
}

function fail(
  kind: GitHubErrorKind,
  message: string,
  action: string | null,
  detail = '',
): GitHubFailure {
  // Two passes, and the order is the same argument as truncation's. `redact`
  // below only knows how to find a credential sitting in a URL's userinfo,
  // which was the whole threat model while this module read `gh`'s own login
  // and never held a token itself. It does now: `toolEnv` hands `gh` a
  // `GH_TOKEN` when the user signed in through the app, so `gh`'s stderr is a
  // place *our* token can appear, bare and out of any URL. A classic GitHub
  // token is forty hex characters, which is indistinguishable from a commit
  // SHA by shape alone — so it is removed by exact match instead of by
  // pattern, which is what `scrubGitHubSecrets` does.
  return {
    ok: false,
    kind,
    message,
    action,
    detail: truncateDetail(redact(scrubGitHubSecrets(detail))),
  }
}

/**
 * Strip credentials out of any text before it leaves this module.
 *
 * Not hypothetical: remote URLs of the form
 * `https://x-access-token:<token>@github.com/owner/repo.git` are commonplace in
 * CI-provisioned clones, and git and gh both echo the full URL back in their
 * error text. Without this, one "no GitHub remote" message renders a live
 * access token into the UI — and into whatever the user pastes it into next.
 *
 * Both quantifiers are bounded, which is not cosmetic. Unbounded (`*`/`+`) the
 * pattern is quadratic: every position starts a greedy run that has to unwind
 * one character at a time before the match can fail, so a stream of ordinary
 * word characters with no `://` in it costs O(n²). Measured on this machine,
 * 80 kB took 10.4 seconds — and this runs on the Electron main thread, where a
 * single oversized `gh` stderr would freeze the whole app. No real scheme is 32
 * characters long and no real userinfo is 512, so the bounds cost nothing.
 */
export function redact(text: string): string {
  // Cheap linear reject: without a scheme there is nothing here to redact, and
  // this is what keeps the pathological "one long run of letters" case free.
  if (!text.includes('://')) return text
  // Userinfo in a URL is the only place a secret hides in git/gh output. The
  // scp form (git@host:owner/repo) carries a username only, so it is left be.
  return text.replace(/([a-z][a-z0-9+.-]{0,31}:\/\/)[^/\s@]{1,512}@/gi, '$1***@')
}

/* --------------------------------------------------- error classification -- */

interface ExecFailure {
  code?: string | number
  killed?: boolean
  signal?: string | null
  stderr?: string
  stdout?: string
  message?: string
}

/**
 * Text that means the network never got out of this machine. gh is a Go
 * program, so these are Go's transport errors rather than libc's errno names.
 */
const NETWORK_PATTERNS = [
  /dial tcp/i,
  /connection refused/i,
  /no such host/i,
  /network is unreachable/i,
  /host is down/i,
  /i\/o timeout/i,
  /tls handshake timeout/i,
  /proxyconnect/i,
  /connection reset by peer/i,
  /EAI_AGAIN/,
  /ENOTFOUND/,
  /certificate.*(expired|not valid|unknown authority)/i,
]

/**
 * Turn whatever `gh` or `git` did into one of the typed failures.
 *
 * Order matters. A spawn error has no stderr to match on, a killed process is
 * a timeout whatever it managed to print, and the transport errors have to be
 * checked before the HTTP-status ones because a proxy failure can carry both.
 */
export function classifyGhError(error: unknown): GitHubFailure {
  const failure = error as ExecFailure
  const text = `${failure?.stderr ?? ''}\n${failure?.stdout ?? ''}\n${failure?.message ?? ''}`.trim()

  if (failure?.code === 'ENOENT') {
    return fail(
      'gh-missing',
      'The GitHub CLI is not installed, or is not on your login PATH.',
      'brew install gh',
      text,
    )
  }

  if (failure?.killed || failure?.signal === 'SIGTERM' || failure?.code === 'ETIMEDOUT') {
    return fail('timeout', 'GitHub did not answer in time.', null, text)
  }

  for (const pattern of NETWORK_PATTERNS) {
    if (pattern.test(text)) {
      return fail('network-down', 'Could not reach github.com — check your connection.', null, text)
    }
  }

  // Local git problems reach here when repo resolution shelled out to gh.
  if (/not a git repository/i.test(text)) {
    return fail('not-a-repo', NOT_A_REPO, null, text)
  }
  if (/no git remotes found/i.test(text)) {
    return fail('no-remote', 'This repository has no remotes.', 'git remote add origin <url>', text)
  }
  if (/point to a known GitHub host/i.test(text)) {
    return fail(
      'no-github-remote',
      'None of this repository’s remotes point at GitHub.',
      null,
      text,
    )
  }

  // gh prints this when there is no stored token at all, on any command.
  if (/To get started with GitHub CLI|not logged into any GitHub hosts/i.test(text)) {
    return fail('not-authenticated', 'You are not signed in to GitHub.', 'gh auth login', text)
  }

  // A stored token that the API rejected: expired, revoked, or hand-edited.
  if (/HTTP 401|Bad credentials/i.test(text)) {
    return fail(
      'auth-expired',
      'Your GitHub credentials were rejected — the token has expired or been revoked.',
      'gh auth login',
      text,
    )
  }

  // Checked before the generic 403 branch: a rate limit is also a 403.
  if (/rate limit|HTTP 429|submitted too quickly/i.test(text)) {
    return fail(
      'rate-limited',
      'GitHub’s API rate limit is exhausted. It resets within the hour.',
      'gh api rate_limit',
      text,
    )
  }

  const scope = /missing required scopes?\s*\[([^\]]+)\]|at least ([a-z:_]+) scope/i.exec(text)
  if (scope) {
    const needed = (scope[1] ?? scope[2] ?? '').trim()
    return fail(
      'missing-scope',
      `Your GitHub token is missing the ${needed || 'required'} scope.`,
      needed ? `gh auth refresh -h github.com -s ${needed.split(/[,\s]+/)[0]}` : 'gh auth refresh',
      text,
    )
  }

  // Before the 404 branch: `gh` sometimes wraps this one in a Not Found.
  if (/has disabled issues/i.test(text)) {
    return fail('issues-disabled', 'Issues are off for this repository.', null, text)
  }

  if (/Could not resolve to a Repository|HTTP 404|Not Found/i.test(text)) {
    return fail(
      'repo-not-found',
      'GitHub has no such repository — it may be private, renamed, or deleted.',
      null,
      text,
    )
  }

  if (/HTTP 403|Resource not accessible|must have (push|admin) access/i.test(text)) {
    return fail(
      'no-access',
      'Your GitHub account cannot read this repository.',
      'gh auth status',
      text,
    )
  }

  return fail('error', 'The GitHub CLI failed.', null, text || 'gh failed')
}

/* -------------------------------------------------------- remote resolving -- */

export interface RemoteEntry {
  name: string
  url: string
  /** `remote.<name>.gh-resolved`, written by `gh repo set-default`. */
  resolved: string | null
}

/**
 * Parse `git config --local --get-regexp '^remote\..*\.(url|gh-resolved)$'`.
 *
 * Config order is preserved because it is the tiebreak of last resort, and
 * `--local` is what makes the whole thing safe: it never picks up a `remote.*`
 * key that happens to live in the user's global config.
 */
export function parseRemoteConfig(output: string): RemoteEntry[] {
  const byName = new Map<string, RemoteEntry>()

  for (const line of output.split('\n')) {
    // The name capture is lazy on purpose. Greedy, it runs past the key and
    // eats the value too: `remote.origin.url https://host/o/a.url b` parses as
    // a remote named `origin.url https://host/o/a` whose url is `b`. Lazy, the
    // first `.url`/`.gh-resolved` that is actually followed by a value wins,
    // and a remote name containing a dot still resolves by backtracking.
    const match = /^remote\.(.+?)\.(url|gh-resolved)\s+(.*)$/.exec(line.trim())
    if (!match) continue
    const [, name, key, value] = match
    const entry = byName.get(name) ?? { name, url: '', resolved: null }
    if (key === 'url') {
      // Only the first url wins: a remote with several urls is a push fan-out,
      // and the first is the one git fetches from.
      if (!entry.url) entry.url = value.trim()
    } else {
      entry.resolved = value.trim()
    }
    byName.set(name, entry)
  }

  return [...byName.values()].filter((entry) => entry.url !== '')
}

export interface ParsedRemote {
  host: string
  owner: string
  name: string
}

/**
 * Pull host/owner/repo out of any remote URL git accepts.
 *
 * Both shapes have to be handled and they are not the same grammar:
 * `https://github.com/o/r.git` is a URL, `git@github.com:o/r.git` is scp
 * syntax that `new URL` rejects outright. Returns null rather than guessing.
 */
export function parseRemoteUrl(url: string): ParsedRemote | null {
  const trimmed = url.trim()
  if (!trimmed) return null

  let host: string
  let path: string

  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    const afterScheme = trimmed.slice(trimmed.indexOf('://') + 3)
    const slash = afterScheme.indexOf('/')
    const authority = slash === -1 ? afterScheme : afterScheme.slice(0, slash)
    // Userinfo may itself contain ':' and '.', so it is cut before the host is
    // read — otherwise a token in the URL parses as the hostname.
    const at = authority.lastIndexOf('@')
    host = at === -1 ? authority : authority.slice(at + 1)
    path = slash === -1 ? '' : afterScheme.slice(slash)
  } else {
    const match = /^(?:([^@/]+)@)?([^:/]+):(.+)$/.exec(trimmed)
    if (!match) return null
    host = match[2]
    path = match[3]
  }

  // A port is never part of the repository identity.
  host = host.replace(/:\d+$/, '').toLowerCase()
  if (!isHostName(host)) return null

  const segments = path.split('/').filter((segment) => segment !== '')
  // GitHub repositories are exactly owner/name. Anything longer is a gist, a
  // wiki or a path we do not understand, and guessing would produce a
  // plausible-looking repo reference that 404s later.
  if (segments.length !== 2) return null

  const owner = segments[0]
  const name = segments[1].replace(/\.git$/i, '')
  if (!isRepoSegment(owner) || !isRepoSegment(name)) return null
  // An owner starting with `-` becomes a flag once it is interpolated into
  // `gh -R <owner>/<repo>`, which is argument injection even though execFile
  // never involves a shell. GitHub logins cannot start with a hyphen anyway.
  if (owner.startsWith('-')) return null

  return { host, owner, name }
}

/**
 * Characters GitHub actually allows in an owner or repository name.
 *
 * The rejection of `.` and `..` is the point of the whole check: a remote URL
 * of `https://github.com/../repo` otherwise parses to an owner of `..`, which
 * then rides into a `gh -R` argument and into a URL rendered in the panel.
 */
const REPO_SEGMENT = /^[A-Za-z0-9._-]+$/

function isRepoSegment(segment: string): boolean {
  if (!segment || segment === '.' || segment === '..') return false
  return REPO_SEGMENT.test(segment)
}

/** A hostname has to start with a letter or digit, which rules out `..`. */
const HOST_NAME = /^[a-z0-9][a-z0-9.-]*$/i

function isHostName(host: string): boolean {
  return HOST_NAME.test(host)
}

/** Enterprise hosts are opt-in through gh's own env var, not guessed. */
function gitHubHosts(): string[] {
  const extra = (process.env.GH_HOST ?? '').trim().toLowerCase()
  return extra ? ['github.com', extra] : ['github.com']
}

export function isGitHubHost(host: string, hosts = gitHubHosts()): boolean {
  const lower = host.toLowerCase()
  return hosts.some((known) => lower === known || lower.endsWith(`.${known}`))
}

/**
 * gh's own remote preference order, so this panel and `gh pr list` in a
 * terminal never disagree about which repository they are showing.
 */
const REMOTE_RANK = ['upstream', 'github', 'origin']

function rank(name: string): number {
  const index = REMOTE_RANK.indexOf(name)
  return index === -1 ? REMOTE_RANK.length : index
}

/**
 * Read a `gh-resolved` value, which gh parses as `[HOST/]OWNER/REPO`.
 *
 * The host-qualified form is the one that bites: split blindly on `/` and
 * `git.acme.co/them/orig` yields an owner of `git.acme.co` and a name of
 * `them`, so every later `gh -R git.acme.co/them` asks for a repository that
 * does not exist and the panel reports "Repository not found" for a repo that
 * is configured perfectly. Returns null for anything else, which drops the
 * caller back onto the remote ranking rather than onto a guess.
 */
export interface ResolvedRepo {
  /** Null when the value carried no host, meaning "the remote's own host". */
  host: string | null
  owner: string
  name: string
}

export function parseResolved(value: string): ResolvedRepo | null {
  const parts = value.split('/').filter((part) => part !== '')
  const [host, owner, name] =
    parts.length === 3 ? parts : parts.length === 2 ? [null, parts[0], parts[1]] : []
  if (!owner || !name) return null
  if (!isRepoSegment(owner) || !isRepoSegment(name)) return null
  if (host !== null && !isHostName(host)) return null
  return { host: host ? host.toLowerCase() : null, owner, name }
}

/**
 * Choose the repository to show. `gh repo set-default` wins outright — the
 * user has already answered this question for the CLI, and a fork's panel
 * pointing at a different repo than their `gh pr list` would be maddening.
 */
export function pickRepo(entries: RemoteEntry[], hosts = gitHubHosts()): RepoRef | null {
  const candidates = entries
    .map((entry) => ({ entry, parsed: parseRemoteUrl(entry.url) }))
    .filter(
      (item): item is { entry: RemoteEntry; parsed: ParsedRemote } =>
        item.parsed !== null && isGitHubHost(item.parsed.host, hosts),
    )
  if (candidates.length === 0) return null

  const explicit = candidates.find(
    (item) => item.entry.resolved && item.entry.resolved !== 'base',
  )
  if (explicit && explicit.entry.resolved) {
    const resolved = parseResolved(explicit.entry.resolved)
    // A host written into gh-resolved is only honoured if it is a GitHub host
    // we would have accepted from a remote URL. Anything else falls through to
    // the ranking rather than pointing `gh -R` at an arbitrary hostname.
    if (resolved && (resolved.host === null || isGitHubHost(resolved.host, hosts))) {
      return makeRef(
        resolved.host ?? explicit.parsed.host,
        resolved.owner,
        resolved.name,
        explicit.entry.name,
      )
    }
  }

  const base = candidates.find((item) => item.entry.resolved === 'base')
  const chosen =
    base ?? [...candidates].sort((a, b) => rank(a.entry.name) - rank(b.entry.name))[0]

  return makeRef(chosen.parsed.host, chosen.parsed.owner, chosen.parsed.name, chosen.entry.name)
}

function makeRef(host: string, owner: string, name: string, remote: string): RepoRef {
  return {
    host,
    owner,
    name,
    nameWithOwner: `${owner}/${name}`,
    url: `https://${host}/${owner}/${name}`,
    remote,
  }
}

/* ----------------------------------------------------------- gh invocation -- */

const GH_TIMEOUT_MS = 15_000
const GIT_TIMEOUT_MS = 5_000
/** A hundred PRs with labels and titles stays well inside this. */
const MAX_BUFFER = 8 * 1024 * 1024

async function toolEnv(platform: Platform = currentPlatform()): Promise<NodeJS.ProcessEnv> {
  /**
   * The sign-in the user made *in this app*, handed to `gh`.
   *
   * Without this, connecting through the panel achieved nothing visible: the
   * card would say "connected as asadev" while every list under it still came
   * back "you are not signed in", because `gh` reads its own config and knows
   * nothing about a token this process is holding. Which is the original
   * complaint — half connected, no way to tell what it is doing — rebuilt one
   * layer down.
   *
   * `githubToolToken` returns null when the environment already carries a
   * token, so a `GH_TOKEN` the user set in their shell profile is never
   * overridden: whatever `gh` would have used on its own is what it uses, and
   * the panel above reports that same credential. The two cannot disagree.
   */
  const token = githubToolToken()

  // `withPath` rather than a literal `PATH:` key in the spread: on Windows the
  // inherited variable is spelled `Path`, and an object literal would carry
  // both spellings — leaving it to `CreateProcess` which one `gh` and `git`
  // are actually looked up on. See `platform/host.ts`.
  return {
    ...withPath(process.env, await loginPath(), platform),
    ...(token ? { GH_TOKEN: token } : {}),
    // Error text is matched on below, so it must not be localised.
    LC_ALL: 'C',
    // gh will happily block on an interactive prompt (auth, repo selection)
    // forever. In a GUI there is no terminal to answer it, so the call would
    // hang until the timeout with no clue why.
    GH_PROMPT_DISABLED: '1',
    GH_NO_UPDATE_NOTIFIER: '1',
    GH_PAGER: 'cat',
    // Same reasoning for git's credential prompts during remote resolution.
    GIT_TERMINAL_PROMPT: '0',
    NO_COLOR: '1',
    CLICOLOR: '0',
  }
}

async function gh(args: string[]): Promise<string> {
  const { stdout } = await run('gh', args, {
    timeout: GH_TIMEOUT_MS,
    maxBuffer: MAX_BUFFER,
    windowsHide: true,
    env: await toolEnv(),
  })
  return stdout
}

async function git(cwd: string, args: string[]): Promise<string> {
  const { stdout } = await run('git', args, {
    cwd,
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: MAX_BUFFER,
    windowsHide: true,
    env: await toolEnv(),
  })
  return stdout
}

/** `gh -R` takes `[HOST/]OWNER/REPO`; the host is only needed off github.com. */
function repoArg(repo: RepoRef): string {
  return repo.host === 'github.com' ? repo.nameWithOwner : `${repo.host}/${repo.nameWithOwner}`
}

function parseJson<T>(text: string): T {
  return JSON.parse(text) as T
}

/* -------------------------------------------------------------- resolving -- */

/**
 * Work out which GitHub repository a folder belongs to, using git alone.
 *
 * Deliberately not `gh repo view`: that costs a GraphQL round trip, and it
 * folds "not a repo", "no remote" and "remote is not GitHub" into error text
 * that then has to be pattern-matched back apart. Reading the local config
 * answers all three offline and exactly, and leaves the API budget for data.
 */
export async function resolveRepo(cwd: string): Promise<RepoRef | GitHubFailure> {
  if (typeof cwd !== 'string' || !isAbsolute(cwd)) {
    return fail('error', 'Project path must be absolute.', null, String(cwd))
  }

  // Checked before spawning anything. Node reports a missing `cwd` as an
  // ENOENT on the spawn itself, which is byte-for-byte the error a missing
  // binary produces — without this, a deleted project folder reads as
  // "git is not installed" and sends the user off to fix the wrong thing.
  try {
    const info = await stat(cwd)
    if (!info.isDirectory()) return fail('no-such-folder', 'That project path is not a folder.', null)
  } catch {
    return fail('no-such-folder', 'This project folder no longer exists.', null)
  }

  let config: string
  try {
    // --local is what makes this a repository test: outside a repo git refuses
    // the flag outright instead of quietly answering from the global config.
    config = await git(cwd, ['config', '--local', '--get-regexp', '^remote\\..*\\.(url|gh-resolved)$'])
  } catch (error) {
    const failure = error as ExecFailure
    // Exit 1 with no stderr is git's "the regexp matched nothing" — a real
    // repository that simply has no remotes yet.
    if (failure?.code === 1 && !(failure?.stderr ?? '').trim()) {
      return fail(
        'no-remote',
        'This repository has no remotes yet.',
        'git remote add origin <url>',
      )
    }
    if (failure?.code === 'ENOENT') {
      return fail('git-missing', 'git is not installed, or not on your login PATH.', null)
    }
    const text = failure?.stderr ?? ''
    if (/--local can only be used inside a git repository|not a git repository/i.test(text)) {
      return fail('not-a-repo', NOT_A_REPO, null, text)
    }
    return classifyGhError(error)
  }

  const entries = parseRemoteConfig(config)
  if (entries.length === 0) {
    return fail('no-remote', 'This repository has no remotes yet.', 'git remote add origin <url>')
  }

  const repo = pickRepo(entries)
  if (!repo) {
    const names = entries.map((entry) => `${entry.name} → ${redact(entry.url)}`).join(', ')
    return fail(
      'no-github-remote',
      'None of this repository’s remotes point at GitHub.',
      'git remote add github <url>',
      names,
    )
  }

  return repo
}

/**
 * Which branch is checked out, or null when the question does not apply.
 *
 * `git symbolic-ref --quiet --short HEAD` rather than `git rev-parse
 * --abbrev-ref HEAD`, and the difference only shows up in the two states that
 * matter here:
 *
 *  - On a repository with **no commits yet** (`git init`, nothing committed)
 *    `rev-parse` fails outright with "ambiguous argument 'HEAD'", so a brand
 *    new repository would report no branch at all. `symbolic-ref` answers
 *    `main`, which is true — the branch exists, it just has nothing on it.
 *  - When HEAD is **detached**, `symbolic-ref` exits 1 with no output, which is
 *    an unambiguous signal. `rev-parse` prints the literal string `HEAD`, which
 *    is indistinguishable from a branch somebody actually named `HEAD`.
 *
 * The second `rev-parse` only runs in the detached case, so the common path is
 * one process. Every failure is null rather than a thrown error: the caller is
 * a status card that already has a repository to show, and "this folder has no
 * branch to name" is a line that simply does not render.
 */
export async function readBranch(cwd: string): Promise<BranchRef | null> {
  if (typeof cwd !== 'string' || !isAbsolute(cwd)) return null
  try {
    const name = (await git(cwd, ['symbolic-ref', '--quiet', '--short', 'HEAD'])).trim()
    if (name) return { name, detached: false, head: null }
  } catch (error) {
    /*
     * Exit 1 with nothing on stderr is "HEAD is not a symbolic ref", i.e.
     * detached, and the second call below resolves it. Anything with stderr is
     * a folder that is not a repository, a missing git, or a folder that is
     * gone — all of which `resolveRepo` reports properly, so this returns null
     * rather than saying it a second time in a different voice, and returns it
     * *without* spawning git again. On a folder that is not a repository this
     * status runs on every panel open, and one wasted spawn per open is one
     * more than nothing.
     */
    const failure = error as ExecFailure
    if ((failure?.stderr ?? '').trim() !== '' || failure?.code === 'ENOENT') return null
  }

  try {
    const head = (await git(cwd, ['rev-parse', '--short', 'HEAD'])).trim()
    return head ? { name: null, detached: true, head } : null
  } catch {
    return null
  }
}

/* ---------------------------------------------------------------- mapping -- */

interface RawAuthor {
  login?: string
  name?: string
  is_bot?: boolean
}

interface RawLabel {
  name?: string
  color?: string
}

interface RawPull {
  number?: number
  title?: string
  url?: string
  state?: string
  isDraft?: boolean
  mergedAt?: string | null
  author?: RawAuthor | null
  createdAt?: string
  updatedAt?: string
  reviewDecision?: string
  labels?: RawLabel[]
  headRefName?: string
  isCrossRepository?: boolean
  additions?: number
  deletions?: number
}

interface RawIssue {
  number?: number
  title?: string
  url?: string
  state?: string
  stateReason?: string
  author?: RawAuthor | null
  createdAt?: string
  updatedAt?: string
  labels?: RawLabel[]
  assignees?: RawAuthor[]
}

function mapLabels(labels: RawLabel[] | undefined): GitHubLabel[] {
  if (!Array.isArray(labels)) return []
  return labels
    .filter((label): label is RawLabel & { name: string } => typeof label?.name === 'string')
    .map((label) => ({
      name: label.name,
      // Six hex digits or nothing — the value is interpolated into CSS, so a
      // stray `;` from a hand-crafted API response cannot reach the stylesheet.
      color: /^[0-9a-f]{6}$/i.test(label.color ?? '') ? (label.color as string) : '8b949e',
    }))
}

/**
 * Roll `state`, `isDraft` and `mergedAt` into the one word the badge shows.
 *
 * GitHub reports a merged PR as `state: "MERGED"` from the CLI but as
 * `state: "closed"` with a `merged_at` from the REST API, so both are checked
 * rather than trusting either alone.
 */
export function pullBadge(raw: Pick<RawPull, 'state' | 'isDraft' | 'mergedAt'>): PullBadge {
  const state = (raw.state ?? '').toUpperCase()
  if (state === 'MERGED' || raw.mergedAt) return 'merged'
  if (state === 'CLOSED') return 'closed'
  return raw.isDraft ? 'draft' : 'open'
}

const REVIEW_BY_DECISION: Record<string, ReviewStatus> = {
  APPROVED: 'approved',
  CHANGES_REQUESTED: 'changes-requested',
  REVIEW_REQUIRED: 'review-required',
}

export function mapPullRequest(raw: RawPull): PullRequest | null {
  if (typeof raw?.number !== 'number' || typeof raw.url !== 'string') return null
  return {
    number: raw.number,
    title: raw.title ?? '(untitled)',
    url: raw.url,
    badge: pullBadge(raw),
    draft: raw.isDraft === true,
    author: raw.author?.login ?? null,
    authorIsBot: raw.author?.is_bot === true,
    createdAt: raw.createdAt ?? '',
    updatedAt: raw.updatedAt ?? raw.createdAt ?? '',
    review: REVIEW_BY_DECISION[(raw.reviewDecision ?? '').toUpperCase()] ?? null,
    labels: mapLabels(raw.labels),
    branch: raw.headRefName ?? null,
    fromFork: raw.isCrossRepository === true,
    additions: typeof raw.additions === 'number' ? raw.additions : null,
    deletions: typeof raw.deletions === 'number' ? raw.deletions : null,
  }
}

export function mapIssue(raw: RawIssue): Issue | null {
  if (typeof raw?.number !== 'number' || typeof raw.url !== 'string') return null
  const reason = (raw.stateReason ?? '').toUpperCase()
  return {
    number: raw.number,
    title: raw.title ?? '(untitled)',
    url: raw.url,
    state: (raw.state ?? '').toUpperCase() === 'CLOSED' ? 'closed' : 'open',
    reason: reason === 'COMPLETED' ? 'completed' : reason === 'NOT_PLANNED' ? 'not-planned' : null,
    author: raw.author?.login ?? null,
    authorIsBot: raw.author?.is_bot === true,
    createdAt: raw.createdAt ?? '',
    updatedAt: raw.updatedAt ?? raw.createdAt ?? '',
    labels: mapLabels(raw.labels),
    assignees: Array.isArray(raw.assignees)
      ? raw.assignees
          .map((assignee) => assignee?.login)
          .filter((login): login is string => typeof login === 'string')
      : [],
  }
}

/* ------------------------------------------------------------------ cache -- */

/** Long enough that scrolling or re-rendering the panel costs nothing. */
export const OK_TTL_MS = 60_000
/** Shorter, so a user who fixes their auth is not stuck looking at the error. */
export const ERROR_TTL_MS = 15_000

/**
 * Ceiling on cached entries. Nothing here ever expired *out* of the map before
 * — entries were only ever overwritten or cleared wholesale — so an app left
 * open for a week, switching between project folders, accumulated a dead
 * `repo <path>` entry per folder plus three per repository, for ever. Each
 * holds a full pull-request and issue payload. Twenty-odd projects fit inside
 * this cap comfortably; past it, the oldest goes.
 */
export const MAX_CACHE_ENTRIES = 200

interface CacheEntry {
  value: unknown
  expiresAt: number
}

const cache = new Map<string, CacheEntry>()
const inflight = new Map<string, Promise<unknown>>()

/**
 * Store one entry, dropping anything already expired and then the oldest
 * survivor if the map is still at its ceiling. Re-inserting deletes first so
 * that Map iteration order stays youngest-last and eviction stays honest.
 */
function remember(key: string, value: unknown, ttl: number): void {
  const now = Date.now()
  for (const [existing, entry] of cache) {
    if (entry.expiresAt <= now) cache.delete(existing)
  }
  cache.delete(key)
  while (cache.size >= MAX_CACHE_ENTRIES) {
    const oldest = cache.keys().next().value
    if (oldest === undefined) break
    cache.delete(oldest)
  }
  cache.set(key, { value, expiresAt: now + ttl })
}

/**
 * Cache by key, and — just as importantly — collapse concurrent calls for the
 * same key onto one process. A panel that mounts three widgets in the same
 * frame would otherwise spawn three `gh` processes for identical data; under
 * React StrictMode's double-mount, six.
 *
 * Exported so the cache behaviour itself can be tested without a network.
 */
export async function cacheThrough<T>(
  key: string,
  refresh: boolean,
  load: () => Promise<T>,
  ttl: (value: T) => number,
): Promise<T> {
  if (!refresh) {
    const hit = cache.get(key)
    if (hit && hit.expiresAt > Date.now()) return hit.value as T
    const joined = inflight.get(key)
    if (joined) return joined as Promise<T>
  }

  let pending: Promise<T>
  const release = (): void => {
    if (inflight.get(key) === pending) inflight.delete(key)
  }
  pending = load()
    .then((value) => {
      // Only the loader that is still the registered one for this key may
      // write. Without this a superseded load still lands: a refresh started
      // while a poll was in flight, or a cache clear that disowned the work
      // already running, and whichever finishes *last* wins — so a slow stale
      // answer quietly overwrites the newer one it was meant to replace.
      if (inflight.get(key) === pending) remember(key, value, ttl(value))
      return value
    })
    .finally(release)

  inflight.set(key, pending as Promise<unknown>)
  return pending
}

/** Drop cached data — for the whole app, or for one folder's entries. */
export function clearGitHubCache(prefix?: string): void {
  if (!prefix) {
    cache.clear()
    inflight.clear()
    return
  }
  for (const key of [...cache.keys()]) {
    if (key.startsWith(prefix)) cache.delete(key)
  }
  // The in-flight map has to go too. Left behind, a request that was already
  // running when the clear happened is still joinable, so the very next caller
  // is handed — and then re-caches — exactly the stale value the clear was
  // asked to get rid of.
  for (const key of [...inflight.keys()]) {
    if (key.startsWith(prefix)) inflight.delete(key)
  }
}

function sectionTtl(section: Section<unknown>): number {
  return section.ok ? OK_TTL_MS : ERROR_TTL_MS
}

/**
 * Cache key for one section of one repository.
 *
 * The host belongs in the key. Keyed on `owner/repo` alone, a company's
 * `git.acme.co/acme/app` and the public `github.com/acme/app` are the same
 * entry, so opening one project shows the other project's pull requests —
 * against the wrong host entirely, and within the TTL there is no way to tell.
 */
export function sectionKey(kind: string, repo: RepoRef, limit?: number): string {
  const scope = `${kind} ${repo.host}/${repo.nameWithOwner}`
  return limit === undefined ? scope : `${scope} ${limit}`
}

/* ------------------------------------------------------------------ fetch -- */

const DEFAULT_LIMIT = 20
const MAX_LIMIT = 100

export function clampLimit(value: unknown): number {
  const n = typeof value === 'number' && Number.isFinite(value) ? Math.floor(value) : DEFAULT_LIMIT
  return Math.min(Math.max(n, 1), MAX_LIMIT)
}

const PULL_FIELDS = [
  'number',
  'title',
  'url',
  'state',
  'isDraft',
  'mergedAt',
  'author',
  'createdAt',
  'updatedAt',
  'reviewDecision',
  'labels',
  'headRefName',
  'isCrossRepository',
  'additions',
  'deletions',
].join(',')

// `comments` is deliberately absent from both field lists: gh returns the full
// body of every comment for it, which turns a twenty-row list into megabytes.
const ISSUE_FIELDS = [
  'number',
  'title',
  'url',
  'state',
  'stateReason',
  'author',
  'createdAt',
  'updatedAt',
  'labels',
  'assignees',
].join(',')

/**
 * Argument lists are built by their own exported functions so the pieces that
 * decide *which* repository on *which* host gets asked are checkable without a
 * network or a gh binary. They are the part most likely to be silently wrong.
 */
export function pullListArgs(repo: RepoRef, limit: number): string[] {
  return [
    'pr',
    'list',
    '-R',
    repoArg(repo),
    '--state',
    'open',
    '--limit',
    String(limit),
    '--json',
    PULL_FIELDS,
  ]
}

export function issueListArgs(repo: RepoRef, limit: number): string[] {
  return [
    'issue',
    'list',
    '-R',
    repoArg(repo),
    '--state',
    'open',
    '--limit',
    String(limit),
    '--json',
    ISSUE_FIELDS,
  ]
}

export async function fetchPulls(repo: RepoRef, limit: number): Promise<Section<PullRequest[]>> {
  try {
    const out = await gh(pullListArgs(repo, limit))
    const rows = parseJson<RawPull[]>(out)
    if (!Array.isArray(rows)) return fail('error', 'gh returned an unexpected pull-request payload.', null)
    return {
      ok: true,
      value: rows
        .map(mapPullRequest)
        .filter((pull): pull is PullRequest => pull !== null),
    }
  } catch (error) {
    return error instanceof SyntaxError
      ? fail('error', 'gh returned output that could not be parsed.', null, error.message)
      : classifyGhError(error)
  }
}

export async function fetchIssues(repo: RepoRef, limit: number): Promise<Section<Issue[]>> {
  try {
    const out = await gh(issueListArgs(repo, limit))
    const rows = parseJson<RawIssue[]>(out)
    if (!Array.isArray(rows)) return fail('error', 'gh returned an unexpected issue payload.', null)
    return { ok: true, value: rows.map(mapIssue).filter((issue): issue is Issue => issue !== null) }
  } catch (error) {
    return error instanceof SyntaxError
      ? fail('error', 'gh returned output that could not be parsed.', null, error.message)
      : classifyGhError(error)
  }
}

/**
 * Everything the panel needs for one project folder.
 *
 * The two sections are fetched in parallel and cached independently, so a
 * repository whose issues are disabled still shows its pull requests rather
 * than an error over the whole panel.
 */
export async function readGitHubOverview(
  cwd: string,
  options: OverviewOptions = {},
): Promise<GitHubResult> {
  const refresh = options.refresh === true
  const limit = clampLimit(options.limit)

  const repo = await cacheThrough(
    `repo ${cwd}`,
    refresh,
    () => resolveRepo(cwd),
    // `ok` exists only on the failure arm — a RepoRef carries no such field.
    (value) => ('ok' in value ? ERROR_TTL_MS : OK_TTL_MS),
  )
  if ('ok' in repo) return repo

  const ref = repo
  const [pulls, issues] = await Promise.all([
    cacheThrough(sectionKey('pulls', ref, limit), refresh, () => fetchPulls(ref, limit), sectionTtl),
    cacheThrough(
      sectionKey('issues', ref, limit),
      refresh,
      () => fetchIssues(ref, limit),
      sectionTtl,
    ),
  ])

  return { ok: true, cwd, repo: ref, pulls, issues, limit, fetchedAt: Date.now() }
}

/* --------------------------------------------------------------------- ipc -- */

function asPath(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 && isAbsolute(value) ? value : null
}

function asOptions(value: unknown): OverviewOptions {
  if (typeof value !== 'object' || value === null) return {}
  const raw = value as { refresh?: unknown; limit?: unknown }
  return { refresh: raw.refresh === true, limit: clampLimit(raw.limit) }
}

export interface GitHubIpcOptions {
  /**
   * `app.getPath('userData')`. Passed in rather than read here so this module
   * keeps its property of importing nothing from Electron but a type — which
   * is what lets the whole of it be tested without a window.
   */
  userDataDir: string
}

/**
 * Wire the GitHub channels. One call from the main process:
 *
 *   import { registerGitHubIpc } from './github'
 *   registerGitHubIpc(ipcMain, { userDataDir: app.getPath('userData') })
 *
 * Channels:
 *  - `github:overview` (invoke, cwd, options) → GitHubResult
 *  - `github:repo`     (invoke, cwd)          → RepoRef | GitHubFailure
 *  - `github:refresh`  (invoke, cwd)          → GitHubResult, cache bypassed
 *  - `github:clear-cache` (send)              → drops every cached entry
 *
 * plus the sign-in channels, registered by `github-auth.ts` from here rather
 * than from `index.ts`. They belong to the same feature and the same panel, and
 * one registration point means there is no way to ship a build where the data
 * channels answer and the connect button has nothing behind it.
 *
 * `resolveRepo` is handed over as a function so the dependency runs one way:
 * this module imports the auth module at run time, the auth module imports
 * nothing back but types.
 *
 * Nothing here throws: every failure is a typed value the renderer renders.
 */
export function registerGitHubIpc(
  ipcMain: IpcMain,
  options: GitHubIpcOptions,
): GitHubAuthenticator {
  const badPath = (value: unknown): GitHubFailure =>
    fail('error', 'Project path must be absolute.', null, String(value))

  ipcMain.handle('github:overview', (_event, cwd: unknown, options: unknown) => {
    const path = asPath(cwd)
    return path ? readGitHubOverview(path, asOptions(options)) : Promise.resolve(badPath(cwd))
  })

  ipcMain.handle('github:refresh', (_event, cwd: unknown, options: unknown) => {
    const path = asPath(cwd)
    if (!path) return Promise.resolve(badPath(cwd))
    return readGitHubOverview(path, { ...asOptions(options), refresh: true })
  })

  ipcMain.handle('github:repo', (_event, cwd: unknown) => {
    const path = asPath(cwd)
    return path ? resolveRepo(path) : Promise.resolve(badPath(cwd))
  })

  // Takes no folder: pull and issue entries are keyed by repository, not by
  // path, and two project folders can be two worktrees of the same repo. A
  // per-folder clear would leave behind the entries it was meant to drop.
  ipcMain.on('github:clear-cache', () => {
    clearGitHubCache()
  })

  return registerGitHubAuthIpc(ipcMain, {
    storageDir: options.userDataDir,
    resolveRepo: (cwd) => resolveRepo(cwd),
    // Handed over the same way and for the same reason as `resolveRepo`: the
    // auth module must not import this one at run time, or the two of them
    // become a cycle. It is what puts "on branch main" beside the repository
    // name in every state of the panel, including the ones where no GitHub
    // request succeeded.
    resolveBranch: (cwd) => readBranch(cwd),
    // Signing in or out changes what every list is allowed to see, and the
    // overview cache holds up to a minute of answers taken under the *old*
    // credential. Dropping it here is why pressing Connect repaints the panel
    // with real data instead of the "not signed in" it cached a moment ago.
    onAuthChanged: () => clearGitHubCache(),
  })
}
