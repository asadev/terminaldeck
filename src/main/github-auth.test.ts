import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { afterEach, describe, expect, it } from 'vitest'
import {
  apiUserUrl,
  deviceCodeUrl,
  GitHubAuthenticator,
  hasScope,
  missingScopes,
  parseScopes,
  probeEnv,
  registerGitHubAuthIpc,
  REQUESTED_SCOPES,
  scrubGitHubSecrets,
  type GitHubAuthState,
  type HttpFetch,
  type HttpResponse,
} from './github-auth'
import type { GitHubFailure, RepoRef } from './github'

/**
 * The six states this module exists to tell apart, plus the ways the device
 * flow ends. Every one of them has been hit on a real machine, and the point of
 * the assertions is not that a failure happened — it is that the *sentence* is
 * different, because six states with one sentence is the bug that started this.
 *
 * Every wire fixture below was captured from GitHub on 2026-08-15 rather than
 * written from memory. `github.test.ts` makes the same argument about `gh`'s
 * stderr and it is worth repeating: a fixture invented from recollection makes
 * the test agree with the implementation's guess instead of checking it.
 *
 *     $ curl -s -X POST https://github.com/login/device/code \
 *         -H 'Accept: application/json' \
 *         -d 'client_id=178c6fc778ccc68e1d6a&scope=repo%20read:org'
 *     {"device_code":"2fac…f1","user_code":"E874-5342",
 *      "verification_uri":"https://github.com/login/device",
 *      "expires_in":899,"interval":5}
 *
 *     $ curl -s -X POST https://github.com/login/oauth/access_token -d '…'
 *     {"error":"authorization_pending",
 *      "error_description":"The authorization request is still pending.",
 *      "error_uri":"https://docs.github.com/…#error-codes-for-the-device-flow"}
 *
 *     $ gh api -i /user | grep -i x-oauth-scopes
 *     X-Oauth-Scopes: admin:public_key, gist, read:org, repo
 *
 * That last line is also fixture number three for the scope tests: a real gh
 * login on this machine carries `read:org` and `repo` and does **not** carry
 * `notifications`, which is exactly the "signed in but the bell is dead" state.
 */

const DEVICE_CODE = '2fac6982365140b262ba16cd354dd8fbeb8b11f1'
const USER_CODE = 'E874-5342'
/** Shaped like a real one so the redaction assertions are not cheating. */
const TOKEN = 'gho_16C7e42F292c6912E7710c838347Ae178B4a'
const GH_TOKEN = 'gho_ZZZZe42F292c6912E7710c838347Ae178B4a'

const USER_JSON = JSON.stringify({
  login: 'asadev',
  name: 'Asad',
  html_url: 'https://github.com/asadev',
  avatar_url: 'https://avatars.githubusercontent.com/u/1?v=4',
})

const REPO: RepoRef = {
  host: 'github.com',
  owner: 'asadev',
  name: 'terminaldeck',
  nameWithOwner: 'asadev/terminaldeck',
  url: 'https://github.com/asadev/terminaldeck',
  remote: 'origin',
}

/* -------------------------------------------------------------- scaffolding -- */

const dirs: string[] = []

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-github-auth-'))
  dirs.push(dir)
  return dir
}

afterEach(() => {
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

interface Call {
  url: string
  method: string
  body: string | undefined
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

/** A transport that answers from a table and records what it was asked. */
function http(routes: Array<(call: Call) => HttpResponse | null>): {
  fetch: HttpFetch
  calls: Call[]
} {
  const calls: Call[] = []
  const fetch: HttpFetch = async (url, init) => {
    const call: Call = {
      url,
      method: init.method,
      body: init.body,
      authorization: init.headers.Authorization,
    }
    calls.push(call)
    for (const route of routes) {
      const answer = route(call)
      if (answer) return answer
    }
    throw new Error(`no fake route for ${init.method} ${url}`)
  }
  return { fetch, calls }
}

const userRoute =
  (scopes: string | null, status = 200, body = USER_JSON) =>
  (call: Call): HttpResponse | null =>
    call.url === apiUserUrl('github.com')
      ? response(status, body, scopes === null ? {} : { 'X-OAuth-Scopes': scopes })
      : null

/** `gh` is not installed: every spawn fails the way `execFile` reports it. */
const ghMissing = async (): Promise<never> => {
  throw Object.assign(new Error('spawn gh ENOENT'), { code: 'ENOENT' })
}

/** `gh` is installed; `token` is null when nobody has ever logged in. */
function ghWith(token: string | null) {
  return async (args: string[]): Promise<{ stdout: string; stderr: string }> => {
    if (args[0] === '--version') return { stdout: 'gh version 2.87.3\n', stderr: '' }
    if (args[0] === 'auth' && args[1] === 'token') {
      if (token === null) throw new Error('gh: not logged in to github.com')
      return { stdout: `${token}\n`, stderr: '' }
    }
    if (args[0] === 'auth' && args[1] === 'logout') return { stdout: '', stderr: '' }
    throw new Error(`unexpected gh ${args.join(' ')}`)
  }
}

function make(options: {
  dir?: string
  env?: NodeJS.ProcessEnv
  fetch?: HttpFetch
  gh?: (args: string[]) => Promise<{ stdout: string; stderr: string }>
  repo?: RepoRef | GitHubFailure
  now?: () => number
}): GitHubAuthenticator {
  return new GitHubAuthenticator({
    storageDir: options.dir ?? tempDir(),
    // `{}` rather than `process.env`: the machine running these tests may well
    // have a real GH_TOKEN exported, and it would silently win every
    // precedence test below.
    env: options.env ?? {},
    platform: 'darwin',
    http: options.fetch ?? http([userRoute('repo, read:org, notifications')]).fetch,
    gh: options.gh ?? ghMissing,
    now: options.now,
    // Instant, so the polling tests finish in milliseconds instead of the
    // fifteen minutes a device code really lives.
    sleep: async () => undefined,
    resolveRepo: async () => options.repo ?? REPO,
  })
}

/* ------------------------------------------------------------------ scopes -- */

describe('scopes', () => {
  it('splits the header GitHub actually sends', () => {
    expect(parseScopes('admin:public_key, gist, read:org, repo')).toEqual([
      'admin:public_key',
      'gist',
      'read:org',
      'repo',
    ])
  })

  /** No header at all is not the same fact as a header with nothing in it. */
  it('reports an absent header as no scopes, for the caller to interpret', () => {
    expect(parseScopes(null)).toEqual([])
    expect(parseScopes('')).toEqual([])
  })

  it('honours the scope hierarchy rather than matching strings', () => {
    expect(hasScope(['admin:org'], 'read:org')).toBe(true)
    expect(hasScope(['write:org'], 'read:org')).toBe(true)
    expect(hasScope(['public_repo'], 'repo')).toBe(false)
    expect(missingScopes(['repo', 'admin:org'])).toEqual(['notifications'])
    expect(missingScopes([])).toEqual([...REQUESTED_SCOPES])
  })
})

/* ----------------------------------------------------------- state machine -- */

describe('the six states', () => {
  it('1. no gh and no credential: connect here, and do not blame the CLI', async () => {
    const auth = make({ gh: ghMissing })
    const state = await auth.status()

    expect(state.connected).toBe(false)
    expect(state.ghInstalled).toBe(false)
    expect(state.failure?.kind).toBe('not-authenticated')
    // The whole point: the fix is a button in this window, and the app must not
    // print a command for a program that is not installed.
    expect(state.failure?.action).toBeNull()
    expect(state.failure?.message).toContain('not needed')
  })

  it('2. gh installed but logged out: both routes offered, neither hidden', async () => {
    const auth = make({ gh: ghWith(null) })
    const state = await auth.status()

    expect(state.connected).toBe(false)
    expect(state.ghInstalled).toBe(true)
    expect(state.failure?.kind).toBe('not-authenticated')
    expect(state.failure?.action).toBe('gh auth login')
  })

  it('3. signed in through gh without the notifications scope', async () => {
    const auth = make({
      gh: ghWith(GH_TOKEN),
      // The real header off this machine's own gh login.
      fetch: http([userRoute('admin:public_key, gist, read:org, repo')]).fetch,
    })
    const state = await auth.status()

    expect(state.connected).toBe(true)
    expect(state.source).toBe('gh-cli')
    expect(state.identity?.login).toBe('asadev')
    expect(state.scopesReported).toBe(true)
    expect(state.missingScopes).toEqual(['notifications'])
    // Being short a scope is not a failure — every list still works.
    expect(state.failure).toBeNull()
    expect(state.disconnect).toContain('terminal')
  })

  it('4. signed in with everything asked for', async () => {
    const auth = make({ gh: ghWith(GH_TOKEN) })
    const state = await auth.status('/tmp/project')

    expect(state.connected).toBe(true)
    expect(state.scopes).toEqual(['repo', 'read:org', 'notifications'])
    expect(state.missingScopes).toEqual([])
    expect(state.repo).toEqual(REPO)
  })

  it('5. the folder is not a repository, and that is not a sign-in problem', async () => {
    const notARepo: GitHubFailure = {
      ok: false,
      kind: 'not-a-repo',
      message: 'This folder is not a git repository.',
      action: 'git init',
      detail: '',
    }
    const auth = make({ gh: ghWith(GH_TOKEN), repo: notARepo })
    const state = await auth.status('/tmp/not-a-repo')

    // Connected *and* repo-less. Collapsing these was the original bug: a
    // signed-in user in a plain folder was told to sign in again.
    expect(state.connected).toBe(true)
    expect(state.failure).toBeNull()
    expect(state.repo).toEqual(notARepo)
  })

  it('6. the repository has no GitHub remote', async () => {
    const noRemote: GitHubFailure = {
      ok: false,
      kind: 'no-github-remote',
      message: 'None of this repository’s remotes point at GitHub.',
      action: 'git remote add github <url>',
      detail: '',
    }
    const auth = make({ gh: ghWith(GH_TOKEN), repo: noRemote })
    const state = await auth.status('/tmp/gitlab-project')

    expect(state.connected).toBe(true)
    expect(state.repo).toEqual(noRemote)
    expect((state.repo as GitHubFailure).kind).toBe('no-github-remote')
  })

  /**
   * The reason a "failed" bucket is forbidden: these are not shades of the same
   * problem, they are seven different things to do next.
   */
  it('gives every state its own sentence', async () => {
    const sentences = new Set<string>()
    const states: GitHubAuthState[] = [
      await make({ gh: ghMissing }).status(),
      await make({ gh: ghWith(null) }).status(),
      await make({
        gh: ghWith(GH_TOKEN),
        fetch: http([userRoute(null, 401, '{"message":"Bad credentials"}')]).fetch,
      }).status(),
      await make({
        gh: ghWith(GH_TOKEN),
        fetch: http([userRoute(null, 403, '{"message":"API rate limit exceeded"}')]).fetch,
      }).status(),
      await make({
        gh: ghWith(GH_TOKEN),
        fetch: http([userRoute(null, 500, 'upstream is sad')]).fetch,
      }).status(),
      await make({
        env: { GH_TOKEN },
        fetch: http([userRoute(null, 401, '{"message":"Bad credentials"}')]).fetch,
      }).status(),
    ]

    for (const state of states) {
      expect(state.connected).toBe(false)
      expect(state.failure).not.toBeNull()
      sentences.add(state.failure?.message ?? '')
    }
    expect(sentences.size).toBe(states.length)
    expect([...sentences].some((line) => /^failed/i.test(line))).toBe(false)
  })
})

/* --------------------------------------------------------------- precedence -- */

/* ----------------------------------------------------------------- caching -- */

/**
 * Only a working connection is cached, and the asymmetry is a UI fact rather
 * than an optimisation. A cached failure makes two buttons lie: Retry returns
 * the identical error instantly for the next minute, and somebody who reads
 * "run gh auth login in a terminal", does exactly that, and comes back to the
 * window is told by a stale entry that they are still signed out.
 */
describe('caching', () => {
  it('does not answer a second look from a cached failure', async () => {
    let loggedIn = false
    const auth = make({
      gh: async (args) => {
        if (args[0] === '--version') return { stdout: 'gh version 2.87.3\n', stderr: '' }
        if (args[0] === 'auth' && args[1] === 'token') {
          if (!loggedIn) throw new Error('gh: not logged in to github.com')
          return { stdout: `${GH_TOKEN}\n`, stderr: '' }
        }
        throw new Error(`unexpected gh ${args.join(' ')}`)
      },
    })

    const before = await auth.status()
    expect(before.connected).toBe(false)
    expect(before.failure?.kind).toBe('not-authenticated')

    // The user signs in elsewhere and comes back to the window. No `refresh`
    // flag, no clock advance — this is the ordinary re-read the panel does on
    // focus, and it has to see the new answer.
    loggedIn = true
    const after = await auth.status()
    expect(after.connected).toBe(true)
    expect(after.source).toBe('gh-cli')
  })

  it('serves a working connection from the cache rather than re-asking GitHub', async () => {
    const { fetch, calls } = http([userRoute('repo, read:org, notifications')])
    const auth = make({ fetch, gh: ghWith(GH_TOKEN) })

    expect((await auth.status()).connected).toBe(true)
    expect((await auth.status()).connected).toBe(true)

    // One `/user` call for two looks: opening the panel twice, or React
    // mounting it twice under StrictMode, must not cost two round trips.
    expect(calls.filter((call) => call.url === apiUserUrl('github.com'))).toHaveLength(1)
  })
})

describe('which credential wins', () => {
  /**
   * The environment first, because `gh` reads it first and `github.ts` runs
   * `gh`. If this card named the account from our stored token while the lists
   * underneath came from the user's `GH_TOKEN`, we would have rebuilt "half
   * connected and I cannot tell what it is doing" in a nicer font.
   */
  it('reports the environment token even when one is stored', async () => {
    const dir = tempDir()
    const seeded = make({ dir, fetch: http(flowRoutes({})).fetch })
    await seeded.connect()
    expect((await seeded.awaitConnect()).source).toBe('device-flow')

    const auth = make({ dir, env: { GH_TOKEN }, gh: ghWith(TOKEN) })
    const state = await auth.status()

    expect(state.source).toBe('environment')
    // Nothing to press: this app cannot unset a variable in the shell that
    // launched it, and a Disconnect that silently does nothing is worse than
    // no Disconnect at all.
    expect(state.disconnect).toBeNull()
  })

  it('reuses an existing gh login rather than asking for a second one', async () => {
    const auth = make({ gh: ghWith(GH_TOKEN) })
    const state = await auth.status()
    expect(state.source).toBe('gh-cli')
    expect(state.connected).toBe(true)
  })

  /**
   * `gh auth token` prints `GH_TOKEN` straight back when it is set. Probing
   * gh's own login without stripping it answers "yes" on a machine where
   * nobody has ever run `gh auth login` — the probe confirms whatever it is
   * asked to check, and the panel offers to reuse a login that is not there.
   */
  it('strips every token variable out of the environment gh is probed with', () => {
    const env = probeEnv(
      {
        GH_TOKEN,
        GITHUB_TOKEN: GH_TOKEN,
        GH_ENTERPRISE_TOKEN: GH_TOKEN,
        GITHUB_ENTERPRISE_TOKEN: GH_TOKEN,
        HOME: '/Users/asad',
        PATH: '/usr/bin',
      },
      '/opt/homebrew/bin:/usr/bin',
      'darwin',
    )

    expect(Object.values(env)).not.toContain(GH_TOKEN)
    expect(env.GH_TOKEN).toBeUndefined()
    expect(env.GITHUB_TOKEN).toBeUndefined()
    expect(env.GH_ENTERPRISE_TOKEN).toBeUndefined()
    expect(env.GITHUB_ENTERPRISE_TOKEN).toBeUndefined()
    // The rest of the environment still has to arrive, or gh cannot find its
    // own config directory.
    expect(env.HOME).toBe('/Users/asad')
    expect(env.PATH).toBe('/opt/homebrew/bin:/usr/bin')
    // Error text is pattern-matched upstream, so it must not be localised.
    expect(env.LC_ALL).toBe('C')
  })

  it('gives gh the token it stored, but never overrides one already in the env', async () => {
    const dir = tempDir()
    const fetch = http([
      (call) =>
        call.url === deviceCodeUrl('github.com')
          ? response(
              200,
              JSON.stringify({
                device_code: DEVICE_CODE,
                user_code: USER_CODE,
                verification_uri: 'https://github.com/login/device',
                expires_in: 899,
                interval: 5,
              }),
            )
          : null,
      (call) =>
        call.url.endsWith('/login/oauth/access_token')
          ? response(200, JSON.stringify({ access_token: TOKEN, scope: 'repo,read:org' }))
          : null,
      userRoute('repo, read:org'),
    ]).fetch

    const auth = make({ dir, fetch, gh: ghMissing })
    await auth.connect()
    await auth.awaitConnect()

    expect(auth.toolToken()).toBe(TOKEN)
    expect(make({ dir, env: { GH_TOKEN }, gh: ghMissing }).toolToken()).toBeNull()
  })
})

/* -------------------------------------------------------------- device flow -- */

/** Routes for a flow that answers `authorization_pending` `pending` times. */
function flowRoutes(options: {
  pending?: number
  final?: HttpResponse
  interval?: number
}): Array<(call: Call) => HttpResponse | null> {
  let seen = 0
  return [
    (call) =>
      call.url === deviceCodeUrl('github.com')
        ? response(
            200,
            JSON.stringify({
              device_code: DEVICE_CODE,
              user_code: USER_CODE,
              verification_uri: 'https://github.com/login/device',
              expires_in: 899,
              interval: options.interval ?? 5,
            }),
          )
        : null,
    (call) => {
      if (!call.url.endsWith('/login/oauth/access_token')) return null
      seen += 1
      if (seen <= (options.pending ?? 0)) {
        return response(
          200,
          JSON.stringify({
            error: 'authorization_pending',
            error_description: 'The authorization request is still pending.',
          }),
        )
      }
      return (
        options.final ?? response(200, JSON.stringify({ access_token: TOKEN, scope: 'repo' }))
      )
    },
    userRoute('repo, read:org, notifications'),
  ]
}

describe('the device-code flow', () => {
  it('hands back a code to show before anything is signed in', async () => {
    const auth = make({ fetch: http(flowRoutes({ pending: 1 })).fetch })
    const prompt = await auth.connect()

    expect(prompt).toMatchObject({
      userCode: USER_CODE,
      verificationUri: 'https://github.com/login/device',
      borrowedClient: true,
    })
    expect((await auth.status()).pending?.userCode).toBe(USER_CODE)
  })

  it('keeps polling through authorization_pending and stores the token', async () => {
    const dir = tempDir()
    const auth = make({ dir, fetch: http(flowRoutes({ pending: 3 })).fetch })
    await auth.connect()
    const state = await auth.awaitConnect('/tmp/project')

    expect(state.connected).toBe(true)
    expect(state.source).toBe('device-flow')
    expect(state.identity?.login).toBe('asadev')
    expect(state.pending).toBeNull()

    // 0600, not 0644. The file is a bearer credential; the mode is the only
    // thing between it and every other account on the machine.
    const file = join(dir, 'github', 'auth.json')
    expect(statSync(file).mode & 0o777).toBe(0o600)
    expect(JSON.parse(readFileSync(file, 'utf8')).login).toBe('asadev')
  })

  /**
   * `slow_down` is mandatory, not advisory: ignoring the new interval gets the
   * attempt rejected outright rather than merely throttled.
   */
  it('obeys slow_down instead of hammering', async () => {
    const waits: number[] = []
    let seen = 0
    const auth = new GitHubAuthenticator({
      storageDir: tempDir(),
      env: {},
      platform: 'darwin',
      gh: ghMissing,
      resolveRepo: async () => REPO,
      sleep: async (ms) => void waits.push(ms),
      http: http([
        (call) =>
          call.url === deviceCodeUrl('github.com')
            ? response(
                200,
                JSON.stringify({
                  device_code: DEVICE_CODE,
                  user_code: USER_CODE,
                  verification_uri: 'https://github.com/login/device',
                  expires_in: 899,
                  interval: 5,
                }),
              )
            : null,
        (call) => {
          if (!call.url.endsWith('/login/oauth/access_token')) return null
          seen += 1
          if (seen === 1) return response(200, JSON.stringify({ error: 'slow_down', interval: 10 }))
          return response(200, JSON.stringify({ access_token: TOKEN, scope: 'repo' }))
        },
        userRoute('repo'),
      ]).fetch,
    })

    await auth.connect()
    await auth.awaitConnect()
    expect(waits).toEqual([5000, 10000])
  })

  it('says the code expired, and says it differently from a refusal', async () => {
    const expired = make({
      fetch: http(flowRoutes({ final: response(200, JSON.stringify({ error: 'expired_token' })) }))
        .fetch,
    })
    await expired.connect()
    await expired.awaitConnect()
    const expiredFailure = expired.flowFailure()

    const denied = make({
      fetch: http(flowRoutes({ final: response(200, JSON.stringify({ error: 'access_denied' })) }))
        .fetch,
    })
    await denied.connect()
    await denied.awaitConnect()
    const deniedFailure = denied.flowFailure()

    expect(expiredFailure?.kind).toBe('auth-code-expired')
    expect(deniedFailure?.kind).toBe('auth-declined')
    expect(expiredFailure?.message).not.toBe(deniedFailure?.message)
  })

  /**
   * A wrong or revoked client id answers 404 `{"error":"Not Found"}` with
   * nothing pointing at the id, which is how "the OAuth app is gone" gets
   * reported for months as "GitHub said no".
   */
  it('names the OAuth client when GitHub will not start a flow at all', async () => {
    const auth = make({
      fetch: http([
        (call) =>
          call.url === deviceCodeUrl('github.com')
            ? response(404, JSON.stringify({ error: 'Not Found' }))
            : null,
      ]).fetch,
    })
    const result = await auth.connect()

    expect('ok' in result && result.ok === false).toBe(true)
    const failure = result as GitHubFailure
    expect(failure.kind).toBe('auth-unavailable')
    expect(failure.message).toContain('TERMINALDECK_GITHUB_CLIENT_ID')
  })

  it('cancelling leaves nothing behind and nothing signed in', async () => {
    const dir = tempDir()
    const auth = make({ dir, fetch: http(flowRoutes({ pending: 1_000_000 })).fetch })
    await auth.connect()
    const state = await auth.cancelConnect()

    expect(state.pending).toBeNull()
    expect(state.connected).toBe(false)
  })
})

/* -------------------------------------------------------------- disconnect -- */

describe('disconnect', () => {
  it('deletes the credential this app stored', async () => {
    const dir = tempDir()
    const auth = make({ dir, fetch: http(flowRoutes({})).fetch })
    await auth.connect()
    expect((await auth.awaitConnect()).connected).toBe(true)

    const after = await auth.disconnect()
    expect(after.connected).toBe(false)
    expect(auth.toolToken()).toBeNull()
    expect(() => statSync(join(dir, 'github', 'auth.json'))).toThrow()
  })

  it('signs the CLI out when the credential is the CLI’s, and says so first', async () => {
    const commands: string[][] = []
    let token: string | null = GH_TOKEN
    const auth = make({
      gh: async (args) => {
        commands.push(args)
        if (args[0] === 'auth' && args[1] === 'logout') {
          token = null
          return { stdout: '', stderr: '' }
        }
        return ghWith(token)(args)
      },
    })

    const before = await auth.status()
    expect(before.disconnect).toContain('terminal')

    const after = await auth.disconnect()
    expect(commands.some((args) => args[0] === 'auth' && args[1] === 'logout')).toBe(true)
    // `--user` as well as `--hostname`: gh refuses a non-interactive logout
    // when the host has more than one account stored.
    const logout = commands.find((args) => args[1] === 'logout') ?? []
    expect(logout).toContain('--user')
    expect(logout).toContain('asadev')
    expect(after.connected).toBe(false)
  })

  /**
   * A dead token of ours is deleted rather than reported forever: it cannot be
   * repaired, and it shadows a working `gh` login underneath it.
   */
  it('drops its own expired credential and falls through to gh', async () => {
    const dir = tempDir()
    let issued = 0
    const auth = make({
      dir,
      gh: ghWith(GH_TOKEN),
      fetch: http([
        (call) => {
          if (call.url !== apiUserUrl('github.com')) return null
          issued += 1
          return issued === 1
            ? response(401, '{"message":"Bad credentials"}')
            : response(200, USER_JSON, { 'X-OAuth-Scopes': 'repo, read:org' })
        },
      ]).fetch,
    })

    // Seed a stored credential by hand-running a flow that succeeds, then make
    // the next check reject it.
    const seeded = make({ dir, fetch: http(flowRoutes({})).fetch })
    await seeded.connect()
    await seeded.awaitConnect()

    const state = await auth.status()
    expect(state.expiredCredentialRemoved).toBe(true)
    expect(state.source).toBe('gh-cli')
    expect(state.connected).toBe(true)
  })
})

/* ----------------------------------------------------------------- secrets -- */

describe('no token ever leaves this module', () => {
  it('keeps the token out of every field of a rejected sign-in', async () => {
    const auth = make({
      env: { GH_TOKEN },
      fetch: http([
        userRoute(
          null,
          401,
          // GitHub does not echo the token, but a proxy in front of it might,
          // and a bare 40-character token is indistinguishable from a commit
          // SHA by shape. The literal pass is what catches it.
          `{"message":"Bad credentials for ${GH_TOKEN}"}`,
        ),
      ]).fetch,
    })

    const state = await auth.status('/tmp/project')
    expect(JSON.stringify(state)).not.toContain(GH_TOKEN)
    expect(state.failure?.detail).toContain('[redacted]')
  })

  it('keeps the stored token out of a status payload', async () => {
    const dir = tempDir()
    const auth = make({ dir, fetch: http(flowRoutes({})).fetch })
    await auth.connect()
    const state = await auth.awaitConnect('/tmp/project')

    expect(state.connected).toBe(true)
    expect(JSON.stringify(state)).not.toContain(TOKEN)
  })

  /**
   * `scrubGitHubSecrets` is what `github.ts` runs over `gh`'s stderr, now that
   * `toolEnv` hands `gh` a token of ours.
   */
  it('strips the live credential out of somebody else’s output', async () => {
    const { ipcMain } = fakeIpc()
    registerGitHubAuthIpc(ipcMain, {
      storageDir: tempDir(),
      env: { GH_TOKEN },
      platform: 'darwin',
      gh: ghMissing,
      http: http([userRoute('repo')]).fetch,
      resolveRepo: async () => REPO,
    })

    expect(scrubGitHubSecrets(`gh: HTTP 401 using ${GH_TOKEN}`)).toBe(
      'gh: HTTP 401 using [redacted]',
    )
    expect(scrubGitHubSecrets('nothing secret here')).toBe('nothing secret here')
  })
})

/* --------------------------------------------------------------------- ipc -- */

type IpcHandler = (...args: unknown[]) => unknown

function fakeIpc() {
  const invoke = new Map<string, IpcHandler>()
  const ipcMain = {
    handle: (channel: string, fn: IpcHandler) => void invoke.set(channel, fn),
    on: () => undefined,
  } as unknown as IpcMain
  return { ipcMain, invoke }
}

describe('registerGitHubAuthIpc', () => {
  it('registers every channel the preload bridge calls', () => {
    const { ipcMain, invoke } = fakeIpc()
    registerGitHubAuthIpc(ipcMain, {
      storageDir: tempDir(),
      env: {},
      platform: 'darwin',
      gh: ghMissing,
      http: http([userRoute('repo')]).fetch,
      resolveRepo: async () => REPO,
    })

    expect([...invoke.keys()].sort()).toEqual([
      'github:auth-await',
      'github:auth-cancel',
      'github:auth-connect',
      'github:auth-disconnect',
      'github:auth-status',
    ])
  })

  /**
   * Press Connect, refuse on GitHub, and the panel must say *that* rather than
   * going back to a generic "not signed in" — losing the one fact that
   * explains what just happened.
   */
  it('carries the reason a refused sign-in failed into the next status', async () => {
    const { ipcMain, invoke } = fakeIpc()
    registerGitHubAuthIpc(ipcMain, {
      storageDir: tempDir(),
      env: {},
      platform: 'darwin',
      gh: ghMissing,
      sleep: async () => undefined,
      http: http(flowRoutes({ final: response(200, JSON.stringify({ error: 'access_denied' })) }))
        .fetch,
      resolveRepo: async () => REPO,
    })

    await invoke.get('github:auth-connect')?.({})
    await invoke.get('github:auth-await')?.({}, '/tmp/project')
    const state = (await invoke.get('github:auth-status')?.({})) as GitHubAuthState

    expect(state.connected).toBe(false)
    expect(state.failure?.kind).toBe('auth-declined')
  })
})
