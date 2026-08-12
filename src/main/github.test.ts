import { execFile } from 'node:child_process'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import { beforeEach, describe, expect, it } from 'vitest'
import {
  cacheThrough,
  clampLimit,
  classifyGhError,
  clearGitHubCache,
  isGitHubHost,
  issueListArgs,
  mapIssue,
  mapPullRequest,
  MAX_CACHE_ENTRIES,
  notificationArgs,
  parseRemoteConfig,
  parseRemoteUrl,
  parseResolved,
  pickRepo,
  pullBadge,
  pullListArgs,
  redact,
  registerGitHubIpc,
  resolveRepo,
  sectionKey,
  summarizeNotifications,
  type GitHubFailure,
  type RemoteEntry,
  type RepoRef,
} from './github'

const run = promisify(execFile)

/**
 * Every string in this block was captured from `gh 2.87.3` and `git` on a real
 * machine rather than written from memory. That matters more here than
 * anywhere else in the module: the classifier is nothing but a bet on what
 * these tools actually print, and a fixture invented from recollection would
 * make the tests agree with the bet instead of checking it.
 */
const REAL = {
  notARepo: 'failed to run git: fatal: not a git repository (or any of the parent directories): .git',
  gitNotARepo: 'fatal: --local can only be used inside a git repository',
  noRemote: 'no git remotes found',
  notGitHub:
    'none of the git remotes configured for this repository point to a known GitHub host. To tell gh about a new GitHub host, please use `gh auth login`',
  neverLoggedIn:
    'To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.',
  authStatusLoggedOut: 'You are not logged into any GitHub hosts. To log in, run: gh auth login',
  badToken: 'HTTP 401: Bad credentials (https://api.github.com/graphql)\nTry authenticating with:  gh auth login',
  deadProxy:
    'Post "https://api.github.com/graphql": proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused',
  missingScope: 'gh: You need at least read:packages scope to list packages. (HTTP 403)',
  repoGone:
    "GraphQL: Could not resolve to a Repository with the name 'asadev/this-repo-does-not-exist-xyz'. (repository)",
} as const

/** Shape of a failed `execFile`, which is what the classifier is handed. */
function execError(stderr: string, extra: Record<string, unknown> = {}): unknown {
  return { stderr, stdout: '', message: `Command failed: gh …\n${stderr}`, ...extra }
}

/* ------------------------------------------------------------- redaction -- */

describe('redact', () => {
  /**
   * Not a hypothetical: clones provisioned by CI on this machine carry
   * `https://x-access-token:<token>@github.com/...` in their remote URL, and
   * git echoes the whole URL back in its error text.
   */
  it('removes userinfo from a remote URL', () => {
    expect(redact('https://x-access-token:ghp_secret123@github.com/o/r.git')).toBe(
      'https://***@github.com/o/r.git',
    )
  })

  it('removes a bare token used as the username', () => {
    expect(redact('https://ghp_secret123@github.com/o/r.git')).toBe('https://***@github.com/o/r.git')
  })

  it('redacts every occurrence in one blob of text', () => {
    const text = 'a https://u:p@github.com/o/r b https://x:y@github.com/o/s'
    expect(redact(text)).toBe('a https://***@github.com/o/r b https://***@github.com/o/s')
  })

  it('leaves the scp form alone — it carries a username, not a secret', () => {
    expect(redact('git@github.com:owner/repo.git')).toBe('git@github.com:owner/repo.git')
  })

  it('leaves a credential-free URL untouched', () => {
    expect(redact('https://github.com/owner/repo')).toBe('https://github.com/owner/repo')
  })

  /**
   * Regression: the pattern used to be `[a-z][a-z0-9+.-]*:\/\/` with an
   * unbounded userinfo run, which is quadratic — every position starts a
   * greedy run that unwinds one character at a time before failing. 80 kB of
   * ordinary letters took 10.4 seconds on this machine, 8 MB would have taken
   * hours, and `gh` is given an 8 MB buffer per stream. This runs on the
   * Electron main thread, so that is not a slow function, it is a frozen app.
   */
  it('stays linear on a large blob with no credentials in it', () => {
    const started = Date.now()
    const blob = `${'x'.repeat(400_000)}://${'y'.repeat(400_000)}`
    expect(redact(blob)).toBe(blob)
    expect(redact('z'.repeat(800_000)).length).toBe(800_000)
    expect(Date.now() - started).toBeLessThan(2_000)
  })

  it('still redacts once a real credential appears in a large blob', () => {
    const blob = `${'x '.repeat(50_000)}https://user:tok_secret@github.com/o/r`
    const out = redact(blob)
    expect(out).not.toContain('tok_secret')
    expect(out).toContain('https://***@github.com/o/r')
  })
})

/* -------------------------------------------------------- failure detail -- */

describe('failure detail', () => {
  /**
   * `gh` gets an 8 MB buffer per stream, and the detail crosses IPC into a
   * `<pre>` 140 pixels tall. Sixteen megabytes of it helps nobody.
   */
  it('caps the raw output it carries', () => {
    const failure = classifyGhError(execError('boom '.repeat(200_000)))
    expect(failure.detail.length).toBeLessThan(5_000)
    expect(failure.detail).toContain('more characters')
  })

  /**
   * Order matters and only one order is safe: truncating first can sever a
   * credential URL just before its `@`, which leaves the bare token as the
   * last thing in the string with nothing left to match on.
   */
  it('redacts before it truncates, so a cut cannot expose the token', () => {
    const url = 'https://x-access-token:ghp_leakme@github.com/o/r.git'
    // Land the credential right on the truncation boundary.
    const failure = classifyGhError(execError(`${'.'.repeat(3_980)}${url}`))
    expect(failure.detail).not.toContain('ghp_leakme')
  })
})

/* ------------------------------------------------------------ remote URLs -- */

describe('parseRemoteUrl', () => {
  it('reads the https form, with and without .git', () => {
    expect(parseRemoteUrl('https://github.com/cli/cli.git')).toEqual({
      host: 'github.com',
      owner: 'cli',
      name: 'cli',
    })
    expect(parseRemoteUrl('https://github.com/cli/cli')).toEqual({
      host: 'github.com',
      owner: 'cli',
      name: 'cli',
    })
  })

  it('reads the scp form that new URL() cannot parse', () => {
    expect(parseRemoteUrl('git@github.com:owner/repo.git')).toEqual({
      host: 'github.com',
      owner: 'owner',
      name: 'repo',
    })
  })

  it('reads ssh:// and git:// schemes', () => {
    expect(parseRemoteUrl('ssh://git@github.com/owner/repo.git')?.name).toBe('repo')
    expect(parseRemoteUrl('git://github.com/owner/repo.git')?.owner).toBe('owner')
  })

  /** A token in the userinfo must not be mistaken for the hostname. */
  it('skips credentials when finding the host', () => {
    expect(parseRemoteUrl('https://x-access-token:ghp_abc@github.com/owner/repo.git')).toEqual({
      host: 'github.com',
      owner: 'owner',
      name: 'repo',
    })
  })

  it('drops the port, which is not part of the repository identity', () => {
    expect(parseRemoteUrl('ssh://git@ssh.github.com:443/owner/repo.git')?.host).toBe('ssh.github.com')
  })

  it('tolerates a trailing slash', () => {
    expect(parseRemoteUrl('https://github.com/owner/repo/')?.name).toBe('repo')
  })

  it('keeps a non-GitHub host rather than pretending it is GitHub', () => {
    expect(parseRemoteUrl('https://gitlab.com/group/proj.git')?.host).toBe('gitlab.com')
  })

  it('lowercases the host but not the repository name', () => {
    expect(parseRemoteUrl('https://GitHub.com/Owner/RePo.git')).toEqual({
      host: 'github.com',
      owner: 'Owner',
      name: 'RePo',
    })
  })

  /** Guessing here would mint a repo reference that 404s later on. */
  it('refuses paths that are not exactly owner/name', () => {
    expect(parseRemoteUrl('https://github.com/owner')).toBeNull()
    expect(parseRemoteUrl('https://github.com/owner/repo/extra')).toBeNull()
    expect(parseRemoteUrl('')).toBeNull()
    expect(parseRemoteUrl('   ')).toBeNull()
    expect(parseRemoteUrl('not a url at all')).toBeNull()
  })

  it('handles a local path remote without crashing', () => {
    expect(parseRemoteUrl('/srv/git/repo.git')).toBeNull()
  })

  /**
   * Regression: `..` used to parse straight through as an owner, so a remote
   * of `https://github.com/../repo` produced the ref `../repo` — which is then
   * interpolated into a `gh -R` argument and into a URL the panel renders.
   */
  it('refuses relative path segments as an owner or name', () => {
    expect(parseRemoteUrl('https://github.com/../repo')).toBeNull()
    expect(parseRemoteUrl('https://github.com/owner/..')).toBeNull()
    expect(parseRemoteUrl('https://github.com/./repo')).toBeNull()
  })

  /**
   * `gh -R <owner>/<repo>` is one argv element, so an owner beginning with a
   * hyphen turns the repository selector into a flag. execFile spawns no shell
   * — this is argument injection, not shell injection, and it needs the same
   * refusal. GitHub logins cannot start with a hyphen in any case.
   */
  it('refuses an owner that would read as a command-line flag', () => {
    expect(parseRemoteUrl('https://github.com/-oProxyCommand/repo')).toBeNull()
  })

  it('refuses segments carrying characters GitHub does not allow', () => {
    expect(parseRemoteUrl('https://github.com/owner/repo?x=1')).toBeNull()
    expect(parseRemoteUrl('https://github.com/own er/repo')).toBeNull()
    expect(parseRemoteUrl('https://github.com/owner/re;po')).toBeNull()
  })
})

describe('isGitHubHost', () => {
  const hosts = ['github.com']

  it('accepts github.com and its subdomains', () => {
    expect(isGitHubHost('github.com', hosts)).toBe(true)
    expect(isGitHubHost('ssh.github.com', hosts)).toBe(true)
  })

  /** `notgithub.com` ends with the string but is not the host. */
  it('rejects a lookalike host', () => {
    expect(isGitHubHost('notgithub.com', hosts)).toBe(false)
    expect(isGitHubHost('github.com.evil.example', hosts)).toBe(false)
    expect(isGitHubHost('gitlab.com', hosts)).toBe(false)
  })

  it('accepts an enterprise host when one is configured', () => {
    expect(isGitHubHost('git.acme.co', ['github.com', 'git.acme.co'])).toBe(true)
  })
})

/* ------------------------------------------------------- remote selection -- */

describe('parseRemoteConfig', () => {
  it('pairs urls with their gh-resolved values', () => {
    const entries = parseRemoteConfig(
      [
        'remote.origin.url https://github.com/me/fork.git',
        'remote.origin.gh-resolved base',
        'remote.upstream.url https://github.com/them/orig.git',
      ].join('\n'),
    )
    expect(entries).toEqual([
      { name: 'origin', url: 'https://github.com/me/fork.git', resolved: 'base' },
      { name: 'upstream', url: 'https://github.com/them/orig.git', resolved: null },
    ])
  })

  /** git prints one line per url; the first is the one it fetches from. */
  it('keeps only the first url of a multi-url remote', () => {
    const entries = parseRemoteConfig(
      ['remote.all.url https://github.com/o/a.git', 'remote.all.url https://github.com/o/b.git'].join('\n'),
    )
    expect(entries).toHaveLength(1)
    expect(entries[0].url).toBe('https://github.com/o/a.git')
  })

  it('drops a remote that has only a gh-resolved value and no url', () => {
    expect(parseRemoteConfig('remote.ghost.gh-resolved base')).toEqual([])
  })

  it('ignores lines that are not remote url or gh-resolved keys', () => {
    const entries = parseRemoteConfig(
      ['remote.origin.fetch +refs/heads/*:refs/remotes/origin/*', 'core.bare false', ''].join('\n'),
    )
    expect(entries).toEqual([])
  })

  it('handles a remote name containing a dot', () => {
    const entries = parseRemoteConfig('remote.my.fork.url https://github.com/o/r.git')
    expect(entries[0].name).toBe('my.fork')
  })

  /**
   * Regression: the name capture was greedy, so it ran past the key and ate
   * the value — this line parsed as a remote named
   * `origin.url https://github.com/o/a` whose url was `b`.
   */
  it('does not run past the key when the value itself contains .url', () => {
    const entries = parseRemoteConfig('remote.origin.url https://github.com/o/a.url b')
    expect(entries).toEqual([
      { name: 'origin', url: 'https://github.com/o/a.url b', resolved: null },
    ])
  })
})

describe('parseResolved', () => {
  it('reads the plain owner/repo form gh writes by default', () => {
    expect(parseResolved('them/orig')).toEqual({ host: null, owner: 'them', name: 'orig' })
  })

  /** gh parses gh-resolved as `[HOST/]OWNER/REPO`, so all three parts occur. */
  it('reads the host-qualified form', () => {
    expect(parseResolved('git.acme.co/them/orig')).toEqual({
      host: 'git.acme.co',
      owner: 'them',
      name: 'orig',
    })
  })

  it('refuses anything it cannot read, rather than guessing', () => {
    expect(parseResolved('')).toBeNull()
    expect(parseResolved('lonely')).toBeNull()
    expect(parseResolved('a/b/c/d')).toBeNull()
    expect(parseResolved('../etc/passwd')).toBeNull()
  })
})

describe('pickRepo', () => {
  const entry = (name: string, url: string, resolved: string | null = null): RemoteEntry => ({
    name,
    url,
    resolved,
  })

  it('returns null when no remote points at GitHub', () => {
    expect(pickRepo([entry('origin', 'https://gitlab.com/g/p.git')])).toBeNull()
  })

  it('builds a canonical ref from the parts, not from the raw url', () => {
    const repo = pickRepo([entry('origin', 'https://x:y@github.com/cli/cli.git')]) as RepoRef
    // The credentials in the remote must not survive into anything renderable.
    expect(repo.url).toBe('https://github.com/cli/cli')
    expect(repo.nameWithOwner).toBe('cli/cli')
    expect(repo.remote).toBe('origin')
  })

  /**
   * `gh repo set-default` records the answer in gh-resolved. Honouring it is
   * what keeps this panel and the user's own `gh pr list` on the same repo.
   */
  it('obeys an explicit gh-resolved owner/repo over the remote url', () => {
    const repo = pickRepo([
      entry('origin', 'https://github.com/me/fork.git', 'them/orig'),
    ]) as RepoRef
    expect(repo.nameWithOwner).toBe('them/orig')
  })

  it('prefers the remote marked as base', () => {
    const repo = pickRepo([
      entry('origin', 'https://github.com/me/fork.git'),
      entry('other', 'https://github.com/them/orig.git', 'base'),
    ]) as RepoRef
    expect(repo.owner).toBe('them')
  })

  it('falls back to gh’s own remote order: upstream, github, origin', () => {
    const entries = [
      entry('origin', 'https://github.com/o/origin.git'),
      entry('github', 'https://github.com/o/github.git'),
      entry('upstream', 'https://github.com/o/upstream.git'),
    ]
    expect((pickRepo(entries) as RepoRef).name).toBe('upstream')
    expect((pickRepo(entries.slice(0, 2)) as RepoRef).name).toBe('github')
    expect((pickRepo(entries.slice(0, 1)) as RepoRef).name).toBe('origin')
  })

  it('skips non-GitHub remotes when ranking', () => {
    const repo = pickRepo([
      entry('upstream', 'https://gitlab.com/g/p.git'),
      entry('origin', 'https://github.com/o/r.git'),
    ]) as RepoRef
    expect(repo.remote).toBe('origin')
  })

  it('keeps an enterprise host in the ref', () => {
    const repo = pickRepo([entry('origin', 'git@git.acme.co:team/app.git')], [
      'github.com',
      'git.acme.co',
    ]) as RepoRef
    expect(repo.host).toBe('git.acme.co')
    expect(repo.url).toBe('https://git.acme.co/team/app')
  })

  /**
   * Regression: a host-qualified gh-resolved value was split blindly on `/`,
   * so `git.acme.co/them/orig` became owner `git.acme.co`, name `them`, and a
   * URL of `https://git.acme.co/git.acme.co/them`. Every later `gh -R` then
   * asked for a repository that does not exist, and the panel reported
   * "Repository not found" for a perfectly configured repo.
   */
  it('reads a host-qualified gh-resolved value without mangling it', () => {
    const repo = pickRepo(
      [entry('origin', 'https://git.acme.co/me/fork.git', 'git.acme.co/them/orig')],
      ['github.com', 'git.acme.co'],
    ) as RepoRef
    expect(repo.nameWithOwner).toBe('them/orig')
    expect(repo.host).toBe('git.acme.co')
    expect(repo.url).toBe('https://git.acme.co/them/orig')
  })

  /** An unreadable value must fall back to the ranking, not produce a guess. */
  it('ignores a gh-resolved value it cannot parse', () => {
    const repo = pickRepo([entry('origin', 'https://github.com/me/fork.git', 'nonsense')]) as RepoRef
    expect(repo.nameWithOwner).toBe('me/fork')
  })

  /**
   * gh-resolved is read out of the repository's own config, which travels with
   * a clone. A host in it is honoured only if it is one we would have accepted
   * from a remote URL — otherwise `gh -R` gets aimed wherever the file said.
   */
  it('refuses a gh-resolved host that is not a GitHub host', () => {
    const repo = pickRepo([
      entry('origin', 'https://github.com/me/fork.git', 'evil.example/them/orig'),
    ]) as RepoRef
    expect(repo.host).toBe('github.com')
    expect(repo.nameWithOwner).toBe('me/fork')
  })
})

/* --------------------------------------------------- error classification -- */

describe('classifyGhError', () => {
  it('reports a missing gh binary from the spawn errno', () => {
    const failure = classifyGhError({ code: 'ENOENT', message: 'spawn gh ENOENT' })
    expect(failure.kind).toBe('gh-missing')
    expect(failure.action).toContain('install')
  })

  it('reports a killed process as a timeout, not a generic failure', () => {
    expect(classifyGhError(execError('', { killed: true, signal: 'SIGTERM' })).kind).toBe('timeout')
    expect(classifyGhError(execError('', { code: 'ETIMEDOUT' })).kind).toBe('timeout')
  })

  it('recognises Go’s transport errors as the network being down', () => {
    expect(classifyGhError(execError(REAL.deadProxy)).kind).toBe('network-down')
    expect(classifyGhError(execError('dial tcp: lookup api.github.com: no such host')).kind).toBe(
      'network-down',
    )
    expect(classifyGhError(execError('Get "https://api.github.com": net/http: TLS handshake timeout')).kind).toBe(
      'network-down',
    )
  })

  it('separates never-signed-in from an expired token', () => {
    expect(classifyGhError(execError(REAL.neverLoggedIn)).kind).toBe('not-authenticated')
    expect(classifyGhError(execError(REAL.authStatusLoggedOut)).kind).toBe('not-authenticated')
    expect(classifyGhError(execError(REAL.badToken)).kind).toBe('auth-expired')
  })

  /**
   * The whole reason this module exists. Two failures that a single "GitHub
   * unavailable" message would flatten need opposite actions from the user:
   * one is a sign-in, the other is a git remote.
   */
  it('gives "not authenticated" and "no GitHub remote" different, actionable text', () => {
    const auth = classifyGhError(execError(REAL.neverLoggedIn))
    const remote = classifyGhError(execError(REAL.notGitHub))

    expect(auth.kind).not.toBe(remote.kind)
    expect(auth.message).not.toBe(remote.message)
    expect(auth.action).toBe('gh auth login')
    expect(remote.message.toLowerCase()).toContain('remote')
    expect(remote.message.toLowerCase()).not.toContain('sign')
  })

  it('separates the three local git problems', () => {
    expect(classifyGhError(execError(REAL.notARepo)).kind).toBe('not-a-repo')
    expect(classifyGhError(execError(REAL.noRemote)).kind).toBe('no-remote')
    expect(classifyGhError(execError(REAL.notGitHub)).kind).toBe('no-github-remote')
  })

  /** A rate limit is also a 403, so it has to be tested before the 403 branch. */
  it('reports a rate limit rather than a permission problem', () => {
    expect(classifyGhError(execError('HTTP 403: API rate limit exceeded for user ID 1.')).kind).toBe(
      'rate-limited',
    )
    expect(classifyGhError(execError('You have exceeded a secondary rate limit')).kind).toBe(
      'rate-limited',
    )
    expect(classifyGhError(execError('HTTP 429: Too Many Requests')).kind).toBe('rate-limited')
  })

  it('names the scope the token is missing, and the command that adds it', () => {
    const failure = classifyGhError(execError(REAL.missingScope))
    expect(failure.kind).toBe('missing-scope')
    expect(failure.message).toContain('read:packages')
    expect(failure.action).toContain('gh auth refresh')

    const bracketed = classifyGhError(
      execError('error: your authentication token is missing required scopes [read:org]'),
    )
    expect(bracketed.kind).toBe('missing-scope')
    expect(bracketed.action).toContain('read:org')
  })

  it('reports a vanished or private repository distinctly from a permission error', () => {
    expect(classifyGhError(execError(REAL.repoGone)).kind).toBe('repo-not-found')
    expect(classifyGhError(execError('HTTP 403: Resource not accessible by integration')).kind).toBe(
      'no-access',
    )
  })

  it('falls back to a plain failure it does not pretend to understand', () => {
    const failure = classifyGhError(execError('gh: something entirely new went wrong'))
    expect(failure.kind).toBe('error')
    expect(failure.action).toBeNull()
    expect(failure.detail).toContain('something entirely new')
  })

  /** Error text is one of the places a remote URL — and its token — surfaces. */
  it('redacts credentials out of the detail it keeps', () => {
    const failure = classifyGhError(
      execError('fatal: could not read from https://x-access-token:ghp_leak@github.com/o/r.git'),
    )
    expect(failure.detail).not.toContain('ghp_leak')
    expect(failure.detail).toContain('***@github.com')
  })
})

/* --------------------------------------------------------------- mapping -- */

describe('pullBadge', () => {
  it('reads draft, open and closed from the CLI’s uppercase states', () => {
    expect(pullBadge({ state: 'OPEN', isDraft: true })).toBe('draft')
    expect(pullBadge({ state: 'OPEN', isDraft: false })).toBe('open')
    expect(pullBadge({ state: 'CLOSED' })).toBe('closed')
    expect(pullBadge({ state: 'MERGED' })).toBe('merged')
  })

  /**
   * The REST API calls a merged PR "closed" and only distinguishes it by
   * merged_at, so a badge that trusted `state` alone would call every merge a
   * rejection.
   */
  it('treats a closed PR with a merge timestamp as merged', () => {
    expect(pullBadge({ state: 'closed', mergedAt: '2026-08-01T00:00:00Z' })).toBe('merged')
  })

  it('defaults to open when gh reports no state at all', () => {
    expect(pullBadge({})).toBe('open')
  })
})

describe('mapPullRequest', () => {
  const raw = {
    number: 14130,
    title: 'Add support for reading issue field values',
    url: 'https://github.com/cli/cli/pull/14130',
    state: 'OPEN',
    isDraft: true,
    mergedAt: null,
    author: { login: 'iulia-b', is_bot: false },
    createdAt: '2026-08-11T11:46:52Z',
    updatedAt: '2026-08-11T14:00:32Z',
    reviewDecision: 'REVIEW_REQUIRED',
    labels: [{ name: 'needs-triage', color: 'D6393F' }],
    headRefName: 'issue-fields/read-field-values',
    isCrossRepository: true,
    additions: 744,
    deletions: 17,
  }

  it('maps a real gh pr list row', () => {
    expect(mapPullRequest(raw)).toEqual({
      number: 14130,
      title: 'Add support for reading issue field values',
      url: 'https://github.com/cli/cli/pull/14130',
      badge: 'draft',
      draft: true,
      author: 'iulia-b',
      authorIsBot: false,
      createdAt: '2026-08-11T11:46:52Z',
      updatedAt: '2026-08-11T14:00:32Z',
      review: 'review-required',
      labels: [{ name: 'needs-triage', color: 'D6393F' }],
      branch: 'issue-fields/read-field-values',
      fromFork: true,
      additions: 744,
      deletions: 17,
    })
  })

  it('flags a bot author, as gh reports app/dependabot', () => {
    const pull = mapPullRequest({ ...raw, author: { login: 'app/dependabot', is_bot: true } })
    expect(pull?.authorIsBot).toBe(true)
    expect(pull?.author).toBe('app/dependabot')
  })

  it('maps every review decision, and null when there is none', () => {
    expect(mapPullRequest({ ...raw, reviewDecision: 'APPROVED' })?.review).toBe('approved')
    expect(mapPullRequest({ ...raw, reviewDecision: 'CHANGES_REQUESTED' })?.review).toBe(
      'changes-requested',
    )
    expect(mapPullRequest({ ...raw, reviewDecision: '' })?.review).toBeNull()
  })

  it('survives a row with a deleted author account', () => {
    expect(mapPullRequest({ ...raw, author: null })?.author).toBeNull()
  })

  /**
   * Label colours are interpolated into a style attribute, so anything that is
   * not six hex digits is replaced rather than passed through.
   */
  it('refuses a label colour that is not six hex digits', () => {
    const pull = mapPullRequest({
      ...raw,
      labels: [{ name: 'x', color: 'red; background: url(evil)' }, { name: 'y', color: '0366d6' }],
    })
    expect(pull?.labels[0].color).toBe('8b949e')
    expect(pull?.labels[1].color).toBe('0366d6')
  })

  it('drops a row with no number or url instead of rendering a dead link', () => {
    expect(mapPullRequest({ title: 'orphan' })).toBeNull()
    expect(mapPullRequest({ number: 1 })).toBeNull()
  })
})

describe('mapIssue', () => {
  const raw = {
    number: 14134,
    title: 'gh skill publish fails',
    url: 'https://github.com/cli/cli/issues/14134',
    state: 'OPEN',
    stateReason: '',
    author: { login: 'totwo2', is_bot: false },
    createdAt: '2026-08-12T03:17:42Z',
    updatedAt: '2026-08-12T03:21:27Z',
    labels: [{ name: 'needs-triage', color: 'D6393F' }],
    assignees: [{ login: 'someone' }],
  }

  it('maps a real gh issue list row', () => {
    const issue = mapIssue(raw)
    expect(issue?.state).toBe('open')
    expect(issue?.reason).toBeNull()
    expect(issue?.assignees).toEqual(['someone'])
  })

  it('reads why a closed issue closed', () => {
    expect(mapIssue({ ...raw, state: 'CLOSED', stateReason: 'NOT_PLANNED' })?.reason).toBe(
      'not-planned',
    )
    expect(mapIssue({ ...raw, state: 'CLOSED', stateReason: 'COMPLETED' })?.reason).toBe('completed')
  })

  it('ignores assignees with no login rather than rendering blanks', () => {
    expect(mapIssue({ ...raw, assignees: [{ name: 'no login' }] })?.assignees).toEqual([])
  })
})

/* --------------------------------------------------------- notifications -- */

describe('summarizeNotifications', () => {
  const item = (fullName: string, reason: string) => ({
    unread: true,
    reason,
    repository: { full_name: fullName },
  })

  it('counts the account total and the project’s own share', () => {
    const summary = summarizeNotifications(
      [item('cli/cli', 'mention'), item('cli/cli', 'review_requested'), item('other/repo', 'subscribed')],
      'cli/cli',
    )
    expect(summary.total).toBe(3)
    expect(summary.repo).toBe(2)
    expect(summary.reasons).toEqual({ mention: 1, review_requested: 1, subscribed: 1 })
  })

  /** GitHub is case-insensitive about owner and repo names; the filter must be too. */
  it('matches the repository regardless of case', () => {
    expect(summarizeNotifications([item('CLI/CLI', 'mention')], 'cli/cli').repo).toBe(1)
  })

  it('ignores threads that are already read', () => {
    expect(summarizeNotifications([{ unread: false, reason: 'mention' }], 'cli/cli').total).toBe(0)
  })

  /**
   * The endpoint pages at 50 and reports no grand total, so a full page has to
   * be reported as "at least 50" rather than as exactly 50.
   */
  it('flags a full page as capped', () => {
    const full = Array.from({ length: 50 }, () => item('cli/cli', 'ci_activity'))
    expect(summarizeNotifications(full, 'cli/cli').capped).toBe(true)
    expect(summarizeNotifications(full.slice(0, 49), 'cli/cli').capped).toBe(false)
  })

  it('returns an empty summary for anything that is not an array', () => {
    expect(summarizeNotifications(null, 'cli/cli')).toEqual({
      total: 0,
      repo: 0,
      capped: false,
      reasons: {},
    })
    expect(summarizeNotifications({ message: 'Not Found' }, 'cli/cli').total).toBe(0)
  })

  it('buckets a notification with no reason rather than dropping it', () => {
    expect(summarizeNotifications([{ unread: true }], 'cli/cli').reasons).toEqual({ other: 1 })
  })
})

/* ---------------------------------------------------------------- limits -- */

describe('clampLimit', () => {
  it('defaults, floors and clamps whatever arrives over IPC', () => {
    expect(clampLimit(undefined)).toBe(20)
    expect(clampLimit('40')).toBe(20)
    expect(clampLimit(Number.NaN)).toBe(20)
    expect(clampLimit(0)).toBe(1)
    expect(clampLimit(-5)).toBe(1)
    expect(clampLimit(1e6)).toBe(100)
    expect(clampLimit(7.9)).toBe(7)
  })
})

/* ----------------------------------------------------------------- cache -- */

describe('cacheThrough', () => {
  beforeEach(() => clearGitHubCache())

  it('serves the second call from cache instead of running the loader again', async () => {
    let calls = 0
    const load = async () => {
      calls += 1
      return calls
    }
    expect(await cacheThrough('k', false, load, () => 60_000)).toBe(1)
    expect(await cacheThrough('k', false, load, () => 60_000)).toBe(1)
    expect(calls).toBe(1)
  })

  /**
   * The case that actually matters: a panel mounting several widgets in one
   * frame — doubled again by StrictMode — must not spawn one `gh` per widget.
   */
  it('collapses concurrent calls for the same key onto one loader', async () => {
    let calls = 0
    let release: (value: number) => void = () => {}
    const load = () => {
      calls += 1
      return new Promise<number>((resolve) => {
        release = resolve
      })
    }

    const all = Promise.all([
      cacheThrough('k', false, load, () => 60_000),
      cacheThrough('k', false, load, () => 60_000),
      cacheThrough('k', false, load, () => 60_000),
    ])
    release(7)

    expect(await all).toEqual([7, 7, 7])
    expect(calls).toBe(1)
  })

  it('re-runs the loader once the entry has expired', async () => {
    let calls = 0
    const load = async () => ++calls
    await cacheThrough('k', false, load, () => 0)
    await cacheThrough('k', false, load, () => 0)
    expect(calls).toBe(2)
  })

  it('bypasses a live entry when refresh is asked for', async () => {
    let calls = 0
    const load = async () => ++calls
    await cacheThrough('k', false, load, () => 60_000)
    expect(await cacheThrough('k', true, load, () => 60_000)).toBe(2)
  })

  it('lets a failing loader reject without poisoning the key', async () => {
    await expect(
      cacheThrough('k', false, () => Promise.reject(new Error('boom')), () => 60_000),
    ).rejects.toThrow('boom')
    expect(await cacheThrough('k', false, async () => 'fine', () => 60_000)).toBe('fine')
  })

  it('drops entries on clear', async () => {
    let calls = 0
    const load = async () => ++calls
    await cacheThrough('k', false, load, () => 60_000)
    clearGitHubCache()
    await cacheThrough('k', false, load, () => 60_000)
    expect(calls).toBe(2)
  })

  it('clears only the keys under a prefix when one is given', async () => {
    const load = async (value: string) => value
    await cacheThrough('repo /a', false, () => load('a'), () => 60_000)
    await cacheThrough('repo /b', false, () => load('b'), () => 60_000)
    clearGitHubCache('repo /a')
    expect(await cacheThrough('repo /b', false, () => load('changed'), () => 60_000)).toBe('b')
    expect(await cacheThrough('repo /a', false, () => load('changed'), () => 60_000)).toBe('changed')
  })

  /**
   * Regression: a prefix clear dropped the cached value but left the in-flight
   * promise joinable, so the very next caller was handed — and then re-cached
   * — the exact stale answer the clear was asked to get rid of.
   */
  it('drops in-flight work under the prefix too, not just cached values', async () => {
    let stale: (value: string) => void = () => {}
    const slow = () => new Promise<string>((resolve) => (stale = resolve))

    const first = cacheThrough('repo /a', false, slow, () => 60_000)
    clearGitHubCache('repo /a')
    const second = cacheThrough('repo /a', false, async () => 'fresh', () => 60_000)
    stale('stale')

    await first
    expect(await second).toBe('fresh')
    // And the fresh value, not the stale one, is what stayed behind.
    expect(await cacheThrough('repo /a', false, async () => 'unused', () => 60_000)).toBe('fresh')
  })

  /**
   * Regression: every loader wrote its result when it settled, so the *last*
   * one to finish won. Hit refresh while the sixty-second poll is still in
   * flight and the poll's older answer lands on top of the refreshed one, and
   * stays there for the rest of the TTL.
   */
  it('lets the newest loader win, not the slowest', async () => {
    let finishOld: (value: string) => void = () => {}
    const slowOld = () => new Promise<string>((resolve) => (finishOld = resolve))

    const older = cacheThrough('k', false, slowOld, () => 60_000)
    const newer = cacheThrough('k', true, async () => 'refreshed', () => 60_000)
    await newer
    finishOld('older')
    await older

    expect(await cacheThrough('k', false, async () => 'unused', () => 60_000)).toBe('refreshed')
  })

  /**
   * Regression: nothing ever removed an entry. An app left open for a week,
   * switching between project folders, kept a dead entry per folder plus three
   * per repository for ever — each holding a full pull-request payload.
   */
  it('evicts the oldest entries instead of growing without bound', async () => {
    const ttl = () => 60_000
    await cacheThrough('oldest', false, async () => 'first', ttl)
    for (let i = 0; i < MAX_CACHE_ENTRIES; i += 1) {
      await cacheThrough(`filler ${i}`, false, async () => i, ttl)
    }

    // The first key is gone, so its loader has to run again...
    let reran = false
    await cacheThrough('oldest', false, async () => ((reran = true), 'again'), ttl)
    expect(reran).toBe(true)
    // ...while a recent one is still served from cache.
    const recent = `filler ${MAX_CACHE_ENTRIES - 1}`
    expect(await cacheThrough(recent, false, async () => 'should not run', ttl)).toBe(
      MAX_CACHE_ENTRIES - 1,
    )
  })

  it('reclaims entries that have expired rather than keeping the corpses', async () => {
    for (let i = 0; i < MAX_CACHE_ENTRIES * 2; i += 1) {
      await cacheThrough(`dead ${i}`, false, async () => i, () => 0)
    }
    // Everything above expired instantly, so a live entry written afterwards
    // must survive — it cannot have been evicted to make room for corpses.
    await cacheThrough('alive', false, async () => 'kept', () => 60_000)
    expect(await cacheThrough('alive', false, async () => 'reloaded', () => 60_000)).toBe('kept')
  })
})

/* ------------------------------------------------------------ cache keys -- */

describe('sectionKey', () => {
  const ref = (host: string): RepoRef => ({
    host,
    owner: 'acme',
    name: 'app',
    nameWithOwner: 'acme/app',
    url: `https://${host}/acme/app`,
    remote: 'origin',
  })

  /**
   * Regression: keys were `pulls <owner>/<repo>`, so a company's
   * `git.acme.co/acme/app` and the public `github.com/acme/app` shared one
   * entry. Opening one project then showed the other project's pull requests,
   * from the wrong host, with nothing on screen to say so.
   */
  it('separates two repositories with the same name on different hosts', () => {
    expect(sectionKey('pulls', ref('github.com'), 20)).not.toBe(
      sectionKey('pulls', ref('git.acme.co'), 20),
    )
  })

  it('separates sections, and lists fetched at different limits', () => {
    expect(sectionKey('pulls', ref('github.com'), 20)).not.toBe(
      sectionKey('issues', ref('github.com'), 20),
    )
    expect(sectionKey('pulls', ref('github.com'), 20)).not.toBe(
      sectionKey('pulls', ref('github.com'), 50),
    )
  })
})

/* --------------------------------------------------------- gh invocation -- */

describe('gh arguments', () => {
  const dotCom: RepoRef = {
    host: 'github.com',
    owner: 'cli',
    name: 'cli',
    nameWithOwner: 'cli/cli',
    url: 'https://github.com/cli/cli',
    remote: 'origin',
  }
  const enterprise: RepoRef = { ...dotCom, host: 'git.acme.co' }

  it('passes the repository as one argv element, so no shell is involved', () => {
    const args = pullListArgs(dotCom, 20)
    expect(args[args.indexOf('-R') + 1]).toBe('cli/cli')
    expect(args[args.indexOf('--limit') + 1]).toBe('20')
    // No field list may ask for comment bodies: gh returns every comment in
    // full, which turns a twenty-row list into megabytes.
    expect(args.join(' ')).not.toContain('comments')
    expect(issueListArgs(dotCom, 5).join(' ')).not.toContain('comments')
  })

  it('qualifies the repository with its host off github.com', () => {
    expect(pullListArgs(enterprise, 20)).toContain('git.acme.co/cli/cli')
    expect(issueListArgs(enterprise, 20)).toContain('git.acme.co/cli/cli')
  })

  /**
   * Regression: `gh api` defaults to github.com. Without --hostname, an
   * enterprise project's bell counted the user's *github.com* notifications
   * and then filtered them by `owner/repo` — which matches a same-named
   * repository on the wrong host.
   */
  it('asks the repository’s own host for notifications', () => {
    const args = notificationArgs(enterprise)
    expect(args[args.indexOf('--hostname') + 1]).toBe('git.acme.co')
    expect(notificationArgs(dotCom)).toContain('github.com')
    expect(args.some((arg) => arg.includes('per_page=50'))).toBe(true)
  })
})

/* ------------------------------------------------- resolving, against git -- */

/**
 * These drive the real `git` binary against throwaway repositories. No network
 * is involved: the point is that the three local failure states come back
 * distinct, which is exactly what a mocked git could be made to say regardless
 * of whether the real one agrees.
 */
describe('resolveRepo', () => {
  async function repoWith(remotes: Array<[string, string]>): Promise<string> {
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-gh-'))
    await run('git', ['init', '-q'], { cwd: dir })
    for (const [name, url] of remotes) {
      await run('git', ['remote', 'add', name, url], { cwd: dir })
    }
    return dir
  }

  beforeEach(() => clearGitHubCache())

  it('rejects a relative path before spawning anything', async () => {
    const result = (await resolveRepo('relative/path')) as GitHubFailure
    expect(result.ok).toBe(false)
  })

  it('reports a folder that no longer exists as such, not as a missing git', async () => {
    const result = (await resolveRepo(join(tmpdir(), 'terminaldeck-gone-0000'))) as GitHubFailure
    expect(result.kind).toBe('no-such-folder')
  })

  it('reports a plain folder as not a repository', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-plain-'))
    try {
      const result = (await resolveRepo(dir)) as GitHubFailure
      expect(result.kind).toBe('not-a-repo')
      expect(result.action).toBe('git init')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  }, 20_000)

  it('reports a repository with no remotes distinctly from one with no GitHub remote', async () => {
    const bare = await repoWith([])
    const gitlab = await repoWith([['origin', 'https://gitlab.com/g/p.git']])
    try {
      const noRemote = (await resolveRepo(bare)) as GitHubFailure
      const noGitHub = (await resolveRepo(gitlab)) as GitHubFailure

      expect(noRemote.kind).toBe('no-remote')
      expect(noGitHub.kind).toBe('no-github-remote')
      expect(noRemote.message).not.toBe(noGitHub.message)
      expect(noRemote.action).toContain('git remote add')
    } finally {
      await rm(bare, { recursive: true, force: true })
      await rm(gitlab, { recursive: true, force: true })
    }
  }, 20_000)

  it('resolves a GitHub remote to a canonical ref', async () => {
    const dir = await repoWith([['origin', 'git@github.com:cli/cli.git']])
    try {
      const repo = (await resolveRepo(dir)) as RepoRef
      expect(repo.nameWithOwner).toBe('cli/cli')
      expect(repo.url).toBe('https://github.com/cli/cli')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  }, 20_000)

  /**
   * Clones provisioned by CI really do carry a token in the remote URL, and
   * this failure path prints the remote list back to the user.
   */
  it('never leaks a token embedded in a remote URL', async () => {
    const dir = await repoWith([['origin', 'https://x-access-token:ghp_leakme@gitlab.com/g/p.git']])
    try {
      const result = (await resolveRepo(dir)) as GitHubFailure
      expect(result.kind).toBe('no-github-remote')
      expect(JSON.stringify(result)).not.toContain('ghp_leakme')
      expect(result.detail).toContain('***@gitlab.com')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  }, 20_000)
})

/* ------------------------------------------------------------------- ipc -- */

type IpcHandler = (...args: unknown[]) => unknown

function fakeIpc() {
  const invoke = new Map<string, IpcHandler>()
  const sent = new Map<string, IpcHandler>()
  const ipcMain = {
    handle: (channel: string, fn: IpcHandler) => void invoke.set(channel, fn),
    on: (channel: string, fn: IpcHandler) => void sent.set(channel, fn),
  } as unknown as IpcMain
  return { ipcMain, invoke, sent }
}

describe('registerGitHubIpc', () => {
  it('registers every channel the preload bridge calls', () => {
    const { ipcMain, invoke, sent } = fakeIpc()
    registerGitHubIpc(ipcMain)
    expect([...invoke.keys()].sort()).toEqual(['github:overview', 'github:refresh', 'github:repo'])
    expect([...sent.keys()]).toEqual(['github:clear-cache'])
  })

  /** IPC arguments are untrusted, so a bad path is a value, never a throw. */
  it('answers a non-absolute path with a typed failure', async () => {
    const { ipcMain, invoke } = fakeIpc()
    registerGitHubIpc(ipcMain)

    for (const channel of ['github:overview', 'github:refresh', 'github:repo']) {
      const result = (await invoke.get(channel)?.({}, '../etc')) as GitHubFailure
      expect(result.ok).toBe(false)
      expect(result.kind).toBe('error')
    }
    const nonString = (await invoke.get('github:overview')?.({}, 42)) as GitHubFailure
    expect(nonString.ok).toBe(false)
  })

  it('clears the cache without a folder argument', async () => {
    const { ipcMain, sent } = fakeIpc()
    registerGitHubIpc(ipcMain)
    let calls = 0
    await cacheThrough('probe', false, async () => ++calls, () => 60_000)

    sent.get('github:clear-cache')?.({})

    await cacheThrough('probe', false, async () => ++calls, () => 60_000)
    expect(calls).toBe(2)
  })
})
