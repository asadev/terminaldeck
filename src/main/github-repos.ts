/**
 * Which repositories the connected credential can actually reach.
 *
 * ## The complaint this answers
 *
 * "I connect and I see nothing." That was literally true: the panel resolved
 * the *open folder* to a repository and showed pull requests for it, so a
 * successful sign-in from a folder that is not a git repository — or is one
 * with no GitHub remote, or is a repository the account cannot see — produced a
 * connection bar over an error, and no evidence anywhere on screen that the
 * sign-in had bought anything at all.
 *
 * The proof a sign-in worked is the list of repositories it can see. That list
 * is a property of the *credential*, not of the folder, which is why it lives
 * here and rides on the sign-in status rather than on the per-folder overview.
 *
 * ## One page, and why not all of them
 *
 * An account with 500 repositories is five requests at `per_page=100`, and
 * every one of them is spent before the panel can paint. So this fetches page
 * one, sorted by `pushed`, and reads the `Link` header to learn whether there
 * are more.
 *
 * That header is why the count on screen can be honest without paying for it.
 * Captured from api.github.com on 2026-08-16 with `per_page=2` against a real
 * account:
 *
 *   Link: <https://api.github.com/user/repos?per_page=2&…&page=2>; rel="next",
 *         <https://api.github.com/user/repos?per_page=2&…&page=14>; rel="last"
 *
 * `rel="last"` gives the page count, so with a full first page and a last page
 * of 14 we know there are **at least** (14 − 1) × 2 + 1 = 27 repositories
 * without asking for any of them. `atLeast` carries that lower bound and
 * `truncated` says the list on screen is not the whole set — which is the
 * difference between "you have 100 repositories" (a specific wrong number) and
 * "100+, most recently pushed first".
 *
 * ## GitHub Apps list a different thing, from a different endpoint
 *
 * A classic token answers `GET /user/repos`, which is every repository the
 * account can reach. That covers three credentials this app still meets: a
 * `gh auth login` reused from the CLI, a PAT in `GH_TOKEN`, and any credential
 * left on disk by the OAuth sign-in that was deleted on 2026-08-16 — those keep
 * working until GitHub stops honouring them.
 *
 * A GitHub App user-to-server token, which is the only kind this app can mint
 * now, cannot use that endpoint at all: what it can see is the set of
 * installations the user has, and the repositories selected inside each —
 * `GET /user/installations` then `GET /user/installations/{id}/repositories`,
 * which is exactly the "only select repositories" choice made at install time,
 * read back.
 *
 * Those two endpoints are implemented from GitHub's REST reference and have
 * **still not been run against a live GitHub App installation.** A registration
 * exists as of 2026-08-16 and its device flow is verified (`github-app.ts` has
 * the recorded response), but verifying *these* needs a user-to-server token,
 * which needs somebody to approve a device code and install the app — neither
 * of which an automated check may do on its own. Every other fixture in this
 * feature was captured from the real API; these two were not, and the first
 * person to complete a GitHub App sign-in should check them rather than trust
 * them. The likeliest wrong guess is the shape of
 * `/user/installations/{id}/repositories`, since `total_count` there is read as
 * exact below.
 *
 * There is deliberately no fallback from the installation endpoints to
 * `/user/repos`: if the app path is in use and its listing fails, that failure
 * is the truth, and quietly answering with a whole-account listing instead
 * would show repositories the grant does not actually cover.
 */

import type { GitHubErrorKind, GitHubFailure } from './github'
// Type-only, and that is what keeps the runtime edge pointing one way:
// `github-auth.ts` imports this module for real, so a value import back would
// be a cycle. `import type` is erased before the bundler sees it.
import type { CredentialKind, HttpFetch } from './github-auth'
import { redact } from './redact'

/* ----------------------------------------------------------------- types -- */

/**
 * One row of the repository list.
 *
 * A deliberately small subset of what GitHub returns. A single `/user/repos`
 * entry is roughly seven kilobytes of URL templates; a hundred of them is most
 * of a megabyte, and all of it would otherwise be serialised across the IPC
 * boundary into a renderer that shows six fields.
 */
export interface RepoSummary {
  owner: string
  name: string
  nameWithOwner: string
  /** Canonical web URL, as GitHub reports it. */
  url: string
  private: boolean
  fork: boolean
  archived: boolean
  description: string | null
  language: string | null
  defaultBranch: string | null
  /** ISO timestamp of the last push, which is what the list is sorted by. */
  pushedAt: string | null
  /** True when the credential could push here — shown, never acted on. */
  canPush: boolean
}

export interface RepoAccessList {
  ok: true
  repos: RepoSummary[]
  /**
   * A lower bound on how many repositories the credential can reach. Equal to
   * `repos.length` when the whole set fitted in one page; otherwise derived
   * from the `Link` header's last-page number, so it is a number GitHub's own
   * pagination implies rather than a guess.
   */
  atLeast: number
  /** True when `repos` is a first page and more exist. */
  truncated: boolean
  /** `/user/repos`, or the installation endpoints a GitHub App uses. */
  source: 'account' | 'installation'
  /**
   * Whether the grant covers everything or a chosen subset. Null for a classic
   * token, where the question does not arise — its `repo` scope is
   * all-or-nothing, and saying "all repositories" there would read as a choice
   * somebody made.
   */
  selection: 'all' | 'selected' | null
  /** Requests left on the credential's hourly budget, when GitHub said. */
  rateRemaining: number | null
  fetchedAt: number
}

export type RepoAccess = RepoAccessList | GitHubFailure

/* -------------------------------------------------------------- plumbing -- */

/** Same ceiling and ordering as everywhere else that redacts before truncating. */
const MAX_DETAIL = 4_000

function fail(
  kind: GitHubErrorKind,
  message: string,
  action: string | null,
  detail = '',
  secrets: readonly string[] = [],
): GitHubFailure {
  const clean = detail ? redact(detail, { extraSecrets: secrets }) : ''
  return {
    ok: false,
    kind,
    message,
    action,
    detail:
      clean.length <= MAX_DETAIL
        ? clean
        : `${clean.slice(0, MAX_DETAIL)}\n… ${clean.length - MAX_DETAIL} more characters`,
  }
}

/** GitHub's maximum, and the fewest round trips for the most rows. */
export const REPO_PAGE_SIZE = 100

const HTTP_TIMEOUT_MS = 15_000

/**
 * The API root for a host. Enterprise puts it under `/api/v3` on the same host
 * while github.com puts it on `api.github.com`; getting it wrong 404s in a way
 * that reads as "your token is not valid here".
 */
export function apiRoot(host: string): string {
  return host === 'github.com' ? 'https://api.github.com' : `https://${host}/api/v3`
}

export function userReposUrl(host: string, perPage = REPO_PAGE_SIZE, page = 1): string {
  // `affiliation` is spelled out rather than left to the default so that
  // repositories owned by an organisation the user belongs to are included.
  // The default is the same three values today; naming them means a change to
  // GitHub's default cannot quietly shrink what the panel shows.
  return (
    `${apiRoot(host)}/user/repos?per_page=${perPage}&page=${page}` +
    `&sort=pushed&affiliation=owner,collaborator,organization_member`
  )
}

export function userInstallationsUrl(host: string): string {
  return `${apiRoot(host)}/user/installations?per_page=100`
}

export function installationReposUrl(host: string, installationId: number, perPage = REPO_PAGE_SIZE): string {
  return `${apiRoot(host)}/user/installations/${installationId}/repositories?per_page=${perPage}`
}

/* ---------------------------------------------------------------- parsing -- */

interface RawRepo {
  name?: string
  full_name?: string
  html_url?: string
  private?: boolean
  fork?: boolean
  archived?: boolean
  description?: string | null
  language?: string | null
  default_branch?: string | null
  pushed_at?: string | null
  owner?: { login?: string }
  permissions?: { push?: boolean }
}

/**
 * One repository, or null when the row is not one.
 *
 * `full_name` is the identity and it is required: a row without it cannot be
 * opened, cannot be matched against the folder's remote, and would render as a
 * blank line that looks like a rendering bug rather than a missing field.
 */
export function mapRepo(raw: RawRepo): RepoSummary | null {
  const full = typeof raw?.full_name === 'string' ? raw.full_name : ''
  const slash = full.indexOf('/')
  if (slash <= 0 || slash === full.length - 1) return null
  const owner = raw.owner?.login ?? full.slice(0, slash)
  const name = raw.name ?? full.slice(slash + 1)

  return {
    owner,
    name,
    nameWithOwner: full,
    // Rebuilt from the identity when GitHub does not send one, rather than
    // left empty: an empty href on a row that looks clickable is the
    // "looks clickable, does nothing" failure this codebase puts first.
    url: typeof raw.html_url === 'string' && raw.html_url !== '' ? raw.html_url : `https://github.com/${full}`,
    private: raw.private === true,
    fork: raw.fork === true,
    archived: raw.archived === true,
    description: typeof raw.description === 'string' && raw.description !== '' ? raw.description : null,
    language: typeof raw.language === 'string' && raw.language !== '' ? raw.language : null,
    defaultBranch: typeof raw.default_branch === 'string' && raw.default_branch !== '' ? raw.default_branch : null,
    pushedAt: typeof raw.pushed_at === 'string' && raw.pushed_at !== '' ? raw.pushed_at : null,
    canPush: raw.permissions?.push === true,
  }
}

/**
 * The last-page number out of a `Link` header, or null.
 *
 * Written as a scan for `rel="last"` rather than a single regular expression
 * over the whole header because the header is a comma-separated list whose URLs
 * contain commas of their own (`affiliation=owner,collaborator,…`), so
 * splitting on commas is wrong and a greedy pattern spanning entries is worse.
 */
export function lastPage(header: string | null): number | null {
  if (!header) return null
  for (const match of header.matchAll(/<([^>]+)>\s*;\s*rel="?([a-z]+)"?/gi)) {
    if (match[2].toLowerCase() !== 'last') continue
    const page = /[?&]page=(\d+)/.exec(match[1])
    if (!page) return null
    const value = Number(page[1])
    return Number.isFinite(value) && value > 0 ? value : null
  }
  return null
}

/**
 * The lower bound the pagination implies.
 *
 * With a known last page P and page size S, page P holds between 1 and S rows,
 * so the total is at least (P − 1) × S + 1. Without a last page the list on
 * screen is the whole set and the bound is exact.
 */
export function atLeastFrom(rows: number, perPage: number, last: number | null): number {
  if (last === null || last <= 1) return rows
  return (last - 1) * perPage + 1
}

function parseJson<T>(text: string): T | null {
  try {
    return JSON.parse(text) as T
  } catch {
    return null
  }
}

function numberHeader(value: string | null): number | null {
  if (value === null) return null
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

/* ------------------------------------------------------------- the fetch -- */

export interface RepoFetchOptions {
  token: string
  host: string
  http: HttpFetch
  /** Credentials to strip out of any raw body kept in a failure. */
  secrets?: readonly string[]
  now?: () => number
  /** How the credential was obtained, which decides which endpoints answer. */
  kind?: CredentialKind
}

interface Fetched {
  status: number
  ok: boolean
  body: string
  link: string | null
  rateRemaining: number | null
  rateReset: number | null
}

async function get(url: string, options: RepoFetchOptions): Promise<Fetched | GitHubFailure> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), HTTP_TIMEOUT_MS)
  try {
    const response = await options.http(url, {
      method: 'GET',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${options.token}`,
        'User-Agent': 'terminaldeck',
        'X-GitHub-Api-Version': '2022-11-28',
      },
      signal: controller.signal,
    })
    return {
      status: response.status,
      ok: response.ok,
      body: await response.text(),
      link: response.header('link'),
      rateRemaining: numberHeader(response.header('x-ratelimit-remaining')),
      rateReset: numberHeader(response.header('x-ratelimit-reset')),
    }
  } catch (error) {
    return controller.signal.aborted
      ? fail('timeout', 'GitHub did not answer in time, so the repository list is not loaded.', null)
      : fail(
          'network-down',
          `Could not reach ${options.host}, so the repository list is not loaded.`,
          null,
          error instanceof Error ? error.message : String(error),
          options.secrets ?? [],
        )
  } finally {
    clearTimeout(timer)
  }
}

/**
 * Turn a non-2xx answer into the right sentence.
 *
 * The three that matter are the three the user can tell apart from the outside:
 * a credential GitHub no longer honours, a rate limit that fixes itself, and
 * everything else. A rate limit arrives as 403 — not 429 — with the remaining
 * count at zero, so the status alone cannot distinguish it from a permission
 * problem, and reporting "your account cannot do this" for an exhausted budget
 * sends the user to change settings that were never wrong.
 */
function classify(answer: Fetched, options: RepoFetchOptions): GitHubFailure {
  const secrets = options.secrets ?? []
  if (answer.status === 401) {
    return fail(
      'auth-expired',
      'GitHub rejected this sign-in when asked for your repositories — the token has expired or been revoked.',
      null,
      answer.body,
      secrets,
    )
  }
  if (answer.status === 403 && (answer.rateRemaining === 0 || /rate limit/i.test(answer.body))) {
    const now = (options.now ?? Date.now)()
    const minutes =
      answer.rateReset === null ? null : Math.max(1, Math.ceil((answer.rateReset * 1000 - now) / 60_000))
    return fail(
      'rate-limited',
      minutes === null
        ? 'GitHub’s API rate limit is exhausted, so the repository list is not loaded. It resets within the hour.'
        : `GitHub’s API rate limit is exhausted, so the repository list is not loaded. It resets in about ${minutes} ${minutes === 1 ? 'minute' : 'minutes'}.`,
      null,
      answer.body,
      secrets,
    )
  }
  if (answer.status === 403) {
    return fail(
      'no-access',
      'GitHub refused to list repositories for this sign-in.',
      null,
      answer.body,
      secrets,
    )
  }
  return fail(
    'error',
    `GitHub answered HTTP ${answer.status} when asked for your repositories.`,
    null,
    answer.body,
    secrets,
  )
}

/**
 * Page one of everything the credential can reach.
 *
 * Returns a typed failure rather than throwing, for the reason the whole
 * feature is built on: "you are not signed in", "this folder is not a
 * repository" and "GitHub is rate limiting you" must never arrive as the same
 * red box.
 */
export async function readAccountRepos(options: RepoFetchOptions): Promise<RepoAccess> {
  const answer = await get(userReposUrl(options.host), options)
  // `kind` is the discriminator, not `ok`: a `Fetched` carries an `ok` of its
  // own for the HTTP status, so testing that field would narrow a perfectly
  // good 404 response into the failure arm and lose its body.
  if ('kind' in answer) return answer
  const fetched = answer
  if (!fetched.ok) return classify(fetched, options)

  const rows = parseJson<RawRepo[]>(fetched.body)
  if (!Array.isArray(rows)) {
    return fail('error', 'GitHub returned a repository list that could not be read.', null, fetched.body, options.secrets ?? [])
  }

  const repos = rows.map(mapRepo).filter((repo): repo is RepoSummary => repo !== null)
  const last = lastPage(fetched.link)
  return {
    ok: true,
    repos,
    atLeast: atLeastFrom(repos.length, REPO_PAGE_SIZE, last),
    truncated: last !== null && last > 1,
    source: 'account',
    selection: null,
    rateRemaining: fetched.rateRemaining,
    fetchedAt: (options.now ?? Date.now)(),
  }
}

interface RawInstallations {
  total_count?: number
  installations?: Array<{ id?: number; repository_selection?: string }>
}

interface RawInstallationRepos {
  total_count?: number
  repositories?: RawRepo[]
}

/**
 * The repositories a GitHub App installation actually covers.
 *
 * Two round trips, because GitHub models it in two: which installations the
 * user has, and what was selected inside one. Only the first installation is
 * read. That is not laziness — an installation is per account (the user's own,
 * or an organisation's), and paging through several of them multiplies requests
 * on the call that gates the panel's first paint. `truncated` says so when
 * there is more than one, which is the honest version of the shortcut.
 *
 * UNVERIFIED against a live registration; see the module header.
 */
export async function readInstallationRepos(options: RepoFetchOptions): Promise<RepoAccess> {
  const listed = await get(userInstallationsUrl(options.host), options)
  if ('kind' in listed) return listed
  const installations = listed
  if (!installations.ok) return classify(installations, options)

  const parsed = parseJson<RawInstallations>(installations.body)
  const first = parsed?.installations?.[0]
  if (!first || typeof first.id !== 'number') {
    return fail(
      'no-access',
      'This sign-in has no GitHub App installation, so there are no repositories it can reach yet. Install the app and choose which repositories it may see.',
      null,
    )
  }

  const answer = await get(installationReposUrl(options.host, first.id), options)
  if ('kind' in answer) return answer
  const fetched = answer
  if (!fetched.ok) return classify(fetched, options)

  const body = parseJson<RawInstallationRepos>(fetched.body)
  if (!body || !Array.isArray(body.repositories)) {
    return fail('error', 'GitHub returned an installation list that could not be read.', null, fetched.body, options.secrets ?? [])
  }

  const repos = body.repositories.map(mapRepo).filter((repo): repo is RepoSummary => repo !== null)
  const total = typeof body.total_count === 'number' ? body.total_count : repos.length
  const more = (parsed?.installations?.length ?? 1) > 1
  return {
    ok: true,
    repos,
    // `total_count` here is exact, unlike the `Link`-derived bound on the
    // account endpoint, so it is used as-is when it is larger than the page.
    atLeast: Math.max(total, repos.length),
    truncated: more || total > repos.length,
    source: 'installation',
    selection: first.repository_selection === 'all' ? 'all' : 'selected',
    rateRemaining: fetched.rateRemaining,
    fetchedAt: (options.now ?? Date.now)(),
  }
}

/** Whichever listing matches how the credential was obtained. */
export function readAccessibleRepos(options: RepoFetchOptions): Promise<RepoAccess> {
  return options.kind === 'github-app' ? readInstallationRepos(options) : readAccountRepos(options)
}
