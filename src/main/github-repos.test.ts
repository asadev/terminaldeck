import { describe, expect, it } from 'vitest'
import type { HttpFetch, HttpResponse } from './github-auth'
import {
  apiRoot,
  atLeastFrom,
  installationReposUrl,
  lastPage,
  mapRepo,
  readAccessibleRepos,
  readAccountRepos,
  readInstallationRepos,
  REPO_PAGE_SIZE,
  userInstallationsUrl,
  userReposUrl,
  type RepoAccessList,
} from './github-repos'
import type { GitHubFailure } from './github'

/**
 * The repository list, against the wire GitHub actually sends.
 *
 * The `Link` header and the repository fields below were captured from
 * api.github.com on 2026-08-16 with a real account, not written from memory:
 *
 *   $ gh api -i '/user/repos?per_page=2&sort=pushed&affiliation=owner,collaborator,organization_member'
 *   HTTP/2.0 200 OK
 *   Link: <https://api.github.com/user/repos?per_page=2&…&page=2>; rel="next",
 *         <https://api.github.com/user/repos?per_page=2&…&page=14>; rel="last"
 *   X-Ratelimit-Remaining: 4993
 *   X-Ratelimit-Reset: 1786845175
 *   [{"name":"commander","full_name":"asadev/commander","private":true, …}]
 *
 * That header is the whole basis of the "100+" count, and it is also the one
 * piece of this module a hand-written fixture would have got wrong: the URLs
 * inside it contain commas of their own (`affiliation=owner,collaborator,…`),
 * so the obvious "split the header on commas" parse fails on real data and
 * passes on anything invented.
 *
 * The two GitHub App fixtures further down are the exception, and they are
 * marked as such where they appear: no registration exists yet, so those
 * shapes come from GitHub's REST reference rather than from a captured
 * response.
 */

const REAL_LINK =
  '<https://api.github.com/user/repos?per_page=2&sort=pushed&affiliation=owner%2Ccollaborator%2Corganization_member&page=2>; rel="next", ' +
  '<https://api.github.com/user/repos?per_page=2&sort=pushed&affiliation=owner%2Ccollaborator%2Corganization_member&page=14>; rel="last"'

/** Trimmed from the captured response — every field this module reads. */
const REAL_REPO = {
  name: 'commander',
  full_name: 'asadev/commander',
  private: true,
  owner: { login: 'asadev' },
  html_url: 'https://github.com/asadev/commander',
  description: 'Imza Commander workspace — Claude Code orchestrator.',
  fork: false,
  language: 'PLpgSQL',
  archived: false,
  pushed_at: '2026-08-16T01:30:03Z',
  default_branch: 'main',
  visibility: 'private',
  permissions: { admin: true, maintain: true, push: true, triage: true, pull: true },
}

const TOKEN = 'gho_16C7e42F292c6912E7710c838347Ae178B4a'
const NOW = Date.parse('2026-08-16T02:00:00Z')

interface Call {
  url: string
  authorization: string | undefined
}

function response(status: number, body: string, headers: Record<string, string> = {}): HttpResponse {
  const lower = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]))
  return {
    ok: status >= 200 && status < 300,
    status,
    header: (name) => lower.get(name.toLowerCase()) ?? null,
    text: async () => body,
  }
}

function http(answer: (call: Call) => HttpResponse | Promise<HttpResponse>): {
  fetch: HttpFetch
  calls: Call[]
} {
  const calls: Call[] = []
  const fetch: HttpFetch = async (url, init) => {
    calls.push({ url, authorization: init.headers.Authorization })
    return answer({ url, authorization: init.headers.Authorization })
  }
  return { fetch, calls }
}

function options(fetch: HttpFetch, kind: 'oauth' | 'github-app' = 'oauth') {
  return { token: TOKEN, host: 'github.com', http: fetch, secrets: [TOKEN], now: () => NOW, kind }
}

/* ---------------------------------------------------------------- parsing -- */

describe('the Link header, which is where the count comes from', () => {
  it('finds the last page in a real header whose URLs contain commas', () => {
    expect(lastPage(REAL_LINK)).toBe(14)
  })

  it('answers null when there is no pagination at all', () => {
    expect(lastPage(null)).toBeNull()
    expect(lastPage('<https://api.github.com/user/repos?page=2>; rel="next"')).toBeNull()
  })

  /**
   * "You have 100 repositories" is a specific wrong number and looks exactly
   * like a right one. The bound below is the largest number the pagination
   * proves: page 14 of 2 holds at least one row, so at least 27 exist.
   */
  it('turns a page count into a lower bound, never into a total', () => {
    expect(atLeastFrom(2, 2, 14)).toBe(27)
    expect(atLeastFrom(40, REPO_PAGE_SIZE, null)).toBe(40)
    expect(atLeastFrom(40, REPO_PAGE_SIZE, 1)).toBe(40)
  })
})

describe('mapRepo', () => {
  it('keeps the six fields the panel shows and drops the kilobyte of URLs', () => {
    expect(mapRepo(REAL_REPO)).toEqual({
      owner: 'asadev',
      name: 'commander',
      nameWithOwner: 'asadev/commander',
      url: 'https://github.com/asadev/commander',
      private: true,
      fork: false,
      archived: false,
      description: 'Imza Commander workspace — Claude Code orchestrator.',
      language: 'PLpgSQL',
      defaultBranch: 'main',
      pushedAt: '2026-08-16T01:30:03Z',
      canPush: true,
    })
  })

  /** A row with no identity cannot be opened, matched or labelled. */
  it('refuses a row without a usable owner/name', () => {
    expect(mapRepo({})).toBeNull()
    expect(mapRepo({ full_name: 'noslash' })).toBeNull()
    expect(mapRepo({ full_name: '/leading' })).toBeNull()
    expect(mapRepo({ full_name: 'trailing/' })).toBeNull()
  })

  it('rebuilds a missing web URL rather than rendering a dead row', () => {
    expect(mapRepo({ full_name: 'a/b' })?.url).toBe('https://github.com/a/b')
  })
})

describe('endpoints', () => {
  it('puts an enterprise API under /api/v3 and github.com on api.github.com', () => {
    expect(apiRoot('github.com')).toBe('https://api.github.com')
    expect(apiRoot('git.acme.co')).toBe('https://git.acme.co/api/v3')
    expect(userReposUrl('git.acme.co')).toContain('https://git.acme.co/api/v3/user/repos')
  })

  /** Organisation-owned repositories are the ones a work machine cares about. */
  it('asks for organisation repositories explicitly rather than trusting the default', () => {
    expect(userReposUrl('github.com')).toContain('affiliation=owner,collaborator,organization_member')
    expect(userReposUrl('github.com')).toContain('sort=pushed')
    expect(userReposUrl('github.com')).toContain(`per_page=${REPO_PAGE_SIZE}`)
  })
})

/* ------------------------------------------------------------ the account -- */

describe('readAccountRepos', () => {
  it('reports one full page as truncated with an honest lower bound', async () => {
    const { fetch, calls } = http(() =>
      response(200, JSON.stringify([REAL_REPO]), {
        Link: REAL_LINK,
        'X-RateLimit-Remaining': '4993',
      }),
    )
    const access = (await readAccountRepos(options(fetch))) as RepoAccessList

    expect(access.ok).toBe(true)
    expect(access.repos.map((repo) => repo.nameWithOwner)).toEqual(['asadev/commander'])
    expect(access.truncated).toBe(true)
    expect(access.atLeast).toBe(atLeastFrom(1, REPO_PAGE_SIZE, 14))
    expect(access.source).toBe('account')
    // `selection` is a GitHub App idea. Claiming "all repositories" for an
    // OAuth token would read as a choice somebody made, when in fact `repo`
    // leaves no choice to make.
    expect(access.selection).toBeNull()
    expect(access.rateRemaining).toBe(4993)
    expect(calls[0].authorization).toBe(`Bearer ${TOKEN}`)
  })

  it('reports a single short page as the whole list', async () => {
    const { fetch } = http(() => response(200, JSON.stringify([REAL_REPO])))
    const access = (await readAccountRepos(options(fetch))) as RepoAccessList
    expect(access.truncated).toBe(false)
    expect(access.atLeast).toBe(1)
  })

  it('reads a revoked token as an expired sign-in, not as a broken list', async () => {
    const { fetch } = http(() => response(401, '{"message":"Bad credentials"}'))
    const failure = (await readAccountRepos(options(fetch))) as GitHubFailure
    expect(failure.ok).toBe(false)
    expect(failure.kind).toBe('auth-expired')
  })

  /**
   * A rate limit arrives as 403 with no remaining budget, not as 429. Reading
   * it as a permission problem sends the user to change settings that were
   * never wrong.
   */
  it('names the rate limit and when it lifts', async () => {
    const reset = Math.floor(NOW / 1000) + 25 * 60
    const { fetch } = http(() =>
      response(403, '{"message":"API rate limit exceeded"}', {
        'X-RateLimit-Remaining': '0',
        'X-RateLimit-Reset': String(reset),
      }),
    )
    const failure = (await readAccountRepos(options(fetch))) as GitHubFailure
    expect(failure.kind).toBe('rate-limited')
    expect(failure.message).toContain('25 minutes')
  })

  it('tells a rate limit apart from a plain refusal', async () => {
    const { fetch } = http(() => response(403, '{"message":"Resource not accessible"}'))
    const failure = (await readAccountRepos(options(fetch))) as GitHubFailure
    expect(failure.kind).toBe('no-access')
  })

  it('reports an unreachable host rather than throwing across the boundary', async () => {
    const { fetch } = http(() => {
      throw new Error('getaddrinfo ENOTFOUND api.github.com')
    })
    const failure = (await readAccountRepos(options(fetch))) as GitHubFailure
    expect(failure.kind).toBe('network-down')
    expect(failure.message).toContain('github.com')
  })

  it('survives a body that is not the array it promised', async () => {
    const { fetch } = http(() => response(200, '{"message":"nope"}'))
    const failure = (await readAccountRepos(options(fetch))) as GitHubFailure
    expect(failure.kind).toBe('error')
  })

  /**
   * The body of a failed request is kept for the details disclosure, and a
   * proxy in front of GitHub can echo the credential into it. A bare GitHub
   * token is indistinguishable from a commit SHA by shape, so it is removed by
   * exact match rather than by pattern.
   */
  it('never carries the token into the failure it hands back', async () => {
    const { fetch } = http(() => response(500, `{"message":"upstream said ${TOKEN}"}`))
    const failure = (await readAccountRepos(options(fetch))) as GitHubFailure
    expect(JSON.stringify(failure)).not.toContain(TOKEN)
  })
})

/* ------------------------------------------------------- GitHub App path -- */

/**
 * UNVERIFIED SHAPES. Everything above came off the live API; the two payloads
 * below come from GitHub's REST reference, because creating a GitHub App needs
 * a human on github.com and there is no registration yet. They are pinned so
 * that the code and the documented shape cannot drift apart silently, but the
 * first person to configure a real app should check them against a real
 * response rather than trusting these tests.
 */
const INSTALLATIONS = JSON.stringify({
  total_count: 1,
  installations: [{ id: 42, repository_selection: 'selected', account: { login: 'asadev' } }],
})

const INSTALLATION_REPOS = JSON.stringify({ total_count: 2, repositories: [REAL_REPO] })

describe('readInstallationRepos', () => {
  it('reads the repositories chosen at install time, and says they were chosen', async () => {
    const { fetch, calls } = http((call) =>
      call.url === userInstallationsUrl('github.com')
        ? response(200, INSTALLATIONS)
        : response(200, INSTALLATION_REPOS),
    )
    const access = (await readInstallationRepos(options(fetch, 'github-app'))) as RepoAccessList

    expect(access.ok).toBe(true)
    expect(access.source).toBe('installation')
    expect(access.selection).toBe('selected')
    // `total_count` on this endpoint is exact, unlike the Link-derived bound.
    expect(access.atLeast).toBe(2)
    expect(access.truncated).toBe(true)
    expect(calls[1].url).toBe(installationReposUrl('github.com', 42))
  })

  /**
   * Signed in, nothing installed. This is a real and confusing state — the
   * account is connected and there is genuinely nothing to see — so it gets the
   * sentence that names the fix rather than an empty list.
   */
  it('explains an account with no installation instead of showing nothing', async () => {
    const { fetch } = http(() => response(200, JSON.stringify({ total_count: 0, installations: [] })))
    const failure = (await readInstallationRepos(options(fetch, 'github-app'))) as GitHubFailure
    expect(failure.ok).toBe(false)
    expect(failure.message).toContain('Install the app')
  })

  /**
   * The fallback that must not exist. Answering a failed installation listing
   * with the whole-account listing would show repositories the grant does not
   * cover — a security property degrading quietly, which is the one kind of
   * fallback this codebase refuses outright.
   */
  it('never falls back to the whole-account listing when the app listing fails', async () => {
    const { fetch, calls } = http(() => response(403, '{"message":"Resource not accessible"}'))
    const failure = (await readAccessibleRepos(options(fetch, 'github-app'))) as GitHubFailure
    expect(failure.ok).toBe(false)
    expect(calls).toHaveLength(1)
    expect(calls[0].url).toBe(userInstallationsUrl('github.com'))
  })

  it('routes an OAuth credential to the account endpoint instead', async () => {
    const { fetch, calls } = http(() => response(200, JSON.stringify([REAL_REPO])))
    await readAccessibleRepos(options(fetch, 'oauth'))
    expect(calls[0].url).toBe(userReposUrl('github.com'))
  })
})
