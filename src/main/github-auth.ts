/**
 * Signing in to GitHub, as something a person does on purpose.
 *
 * ## The bug this exists to kill
 *
 * `github.ts` shells out to `gh` and reads whatever login happens to be lying
 * around. That works beautifully on a machine where somebody once ran
 * `gh auth login` in a terminal, and it is indistinguishable from a broken app
 * on a machine where they did not: the panel says "not signed in", there is
 * nothing to press, and the fix is a command in a program that may not be
 * installed. On Windows it reads *half* connected — `gh` is there, a token is
 * there, the scope for notifications is not — and nothing on screen says which
 * of those three things is the one that is wrong.
 *
 * So this module answers three questions the old code could not:
 *
 *   1. **Is there a credential at all, and where did it come from?** Three
 *      places can supply one and they do not agree, so the answer names the
 *      source rather than hiding it.
 *   2. **What is it allowed to do?** Scopes, read from GitHub itself rather
 *      than assumed, with the ones we asked for and did not get named.
 *   3. **How do I get one without leaving the app?** The device-code flow,
 *      which needs no `gh`, no local web server and no redirect URI — a code
 *      on screen, a browser tab, and this process polling until it is entered.
 *
 * ## Source precedence, and why the environment wins
 *
 * `GH_TOKEN` / `GITHUB_TOKEN` → a token this app stored → `gh`'s own login.
 *
 * The environment is first because that is `gh`'s own order, and `github.ts`
 * runs `gh` to fetch the pull requests. If this card claimed "connected as A"
 * from a token we stored while every list underneath it came back from the
 * `GH_TOKEN` in the user's shell profile as B, we would have rebuilt the exact
 * "half-connected and I cannot tell what it is doing" complaint in a nicer
 * font. Whatever `gh` will actually use is what gets reported.
 *
 * `gh`'s own login is checked *last*, but it is checked — an existing login is
 * reused rather than forcing a second sign-in for an account that is already
 * there. Connecting is only ever offered when there is genuinely nothing.
 *
 * ## The OAuth client is borrowed, and the UI says so
 *
 * The device flow needs a registered OAuth application. This project does not
 * have one yet, so the default client id below is the GitHub CLI's — a public
 * identifier, printed in an open-source binary, with no client secret involved
 * (the device flow has none by design). It works: the constant was verified
 * against the live endpoint rather than copied from memory, and the fixtures in
 * the test file are that response.
 *
 * What it costs is honesty about identity: GitHub's consent screen will say
 * "GitHub CLI", not this app's name. That is not something to hide behind a
 * spinner, so `borrowedClient` is part of the status and the panel prints the
 * sentence. Registering an OAuth app and setting `TERMINALDECK_GITHUB_CLIENT_ID`
 * (or changing the constant) makes both the caveat and the sentence disappear
 * on their own.
 *
 * ## Nothing here prints a token
 *
 * Every string that can leave this module — a failure `detail`, anything a log
 * would swallow — goes through `redact.ts` with the live credentials passed in
 * as `extraSecrets`, so a token is removed by exact match rather than by
 * looking like one. `scrubGitHubSecrets` is exported for `github.ts` to run
 * over `gh`'s stderr for the same reason: we hand `gh` a `GH_TOKEN`, so its
 * output is now a place ours could appear.
 *
 * The one place a token is deliberately *not* redacted is the file it is
 * stored in, which is written 0600 through the same helper the relay's private
 * key uses.
 *
 * ## No Electron imports, on purpose
 *
 * The storage directory arrives as an option, exactly as it does in
 * `remote/device-auth.ts`. That is what lets the state machine below — six
 * states, every one of which a user has hit — be tested as pure functions with
 * a fake `fetch` and a fake `gh`, with no window and no network.
 */

import { execFile } from 'node:child_process'
import { readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
// Types only. `github.ts` imports this module at run time, so anything but a
// type import here would be a real cycle; `import type` is erased before the
// bundler ever sees it, which keeps the runtime edge pointing one way.
import type { GitHubErrorKind, GitHubFailure, RepoRef } from './github'
import { currentPlatform, machineNoun, withPath, type Platform } from './platform/host'
import { loginPath } from './providers'
import { redact } from './redact'
import { protectSecretFile, writeSecretFile } from './remote/secret-file'

const run = promisify(execFile)

/* ------------------------------------------------------------- constants -- */

/**
 * The GitHub CLI's public device-flow client id. See the header for why this
 * is borrowed rather than ours, and what the user is told about it.
 *
 * Verified against the live endpoint on 2026-08-15:
 *
 *   $ curl -s -X POST https://github.com/login/device/code \
 *       -H 'Accept: application/json' \
 *       -d 'client_id=178c6fc778ccc68e1d6a&scope=repo%20read:org'
 *   {"device_code":"…","user_code":"E874-5342",
 *    "verification_uri":"https://github.com/login/device",
 *    "expires_in":899,"interval":5}
 *
 * A wrong client id does not fail loudly, which is why this was checked rather
 * than trusted: GitHub answers `{"error":"Not Found"}` with HTTP 404 and no
 * hint that the id is the problem.
 */
const GH_CLI_CLIENT_ID = '178c6fc778ccc68e1d6a'

/** Override for anyone who registers a real OAuth app for this product. */
const CLIENT_ID_ENV = 'TERMINALDECK_GITHUB_CLIENT_ID'

/**
 * What this app asks for, and why each one is here. Nothing is requested "just
 * in case": every extra scope is something the user has to agree to hand over,
 * and an unexplained one is how a consent screen starts looking like a trap.
 *
 *  - `repo`          — pull requests and issues on private repositories. The
 *                      panel is useless on a work machine without it.
 *  - `read:org`      — repositories owned by an organisation, and the SAML
 *                      handshake that some orgs put in front of them.
 *  - `notifications` — the unread bell. This one is genuinely optional, and a
 *                      token without it still shows every list.
 */
export const REQUESTED_SCOPES = ['repo', 'read:org', 'notifications'] as const

/**
 * Which scopes satisfy which. GitHub's scopes nest, so a token holding
 * `admin:org` has `read:org` without the string appearing anywhere, and
 * reporting that as missing would send a user to re-authorise a token that is
 * already sufficient.
 */
const SCOPE_IMPLIES: Record<string, readonly string[]> = {
  'read:org': ['read:org', 'write:org', 'admin:org'],
  repo: ['repo'],
  notifications: ['notifications'],
}

/** Long enough that opening the panel twice costs one request, not two. */
export const IDENTITY_TTL_MS = 60_000

const GH_TIMEOUT_MS = 10_000
const HTTP_TIMEOUT_MS = 15_000

/** Same reasoning as `github.ts`: redact first, then truncate. */
const MAX_DETAIL = 4_000

/* ----------------------------------------------------------------- types -- */

/** Where the credential in use came from. */
export type AuthSource =
  /** `GH_TOKEN` or `GITHUB_TOKEN` in the environment this app was launched with. */
  | 'environment'
  /** The device-code flow, run from this app and stored by it. */
  | 'device-flow'
  /** An existing `gh auth login`, reused rather than duplicated. */
  | 'gh-cli'

export interface GitHubIdentity {
  login: string
  /** The display name, when the account has one. */
  name: string | null
  htmlUrl: string
  avatarUrl: string | null
}

/** The code on screen while a device-flow sign-in is waiting on the user. */
export interface DeviceFlowPrompt {
  /** Typed into GitHub by hand. Shown, never logged. */
  userCode: string
  /** Where to type it. */
  verificationUri: string
  /** Epoch ms after which the code stops working. */
  expiresAt: number
  /** Scopes this attempt asked for. */
  scopes: string[]
  /** True while the consent screen names the GitHub CLI rather than this app. */
  borrowedClient: boolean
}

export interface GitHubAuthState {
  connected: boolean
  /** Null when nothing is connected. */
  source: AuthSource | null
  host: string
  identity: GitHubIdentity | null
  /**
   * Scopes GitHub reports for this token, in the order it reports them.
   * Empty *and* `scopesReported: false` means GitHub said nothing at all —
   * a fine-grained token carries no scope header — which is not the same
   * fact as a token with no scopes, and must not be shown as one.
   */
  scopes: string[]
  scopesReported: boolean
  /** Requested scopes this token does not carry. Empty when unknowable. */
  missingScopes: string[]
  /** Whether `gh` is on the login PATH at all. */
  ghInstalled: boolean
  /** True when the OAuth client is the GitHub CLI's rather than this app's. */
  borrowedClient: boolean
  /**
   * What pressing Disconnect will do, in one sentence, or null when there is
   * nothing this app can revoke. A button that cannot act is not rendered.
   */
  disconnect: string | null
  /** A sign-in waiting on the user right now, so a reloaded window re-attaches. */
  pending: DeviceFlowPrompt | null
  /** Why there is no usable credential. Null while connected. */
  failure: GitHubFailure | null
  /**
   * Set when a stored sign-in was found dead and deleted during this check.
   * Without it the user sees "not connected" one launch after connecting and
   * has no idea the app did anything.
   */
  expiredCredentialRemoved: boolean
  /** The GitHub repository of the folder asked about, or why there is none. */
  repo: RepoRef | GitHubFailure | null
}

/** What the file on disk holds. */
interface StoredCredential {
  version: 1
  host: string
  token: string
  login: string
  scopes: string[]
  obtainedAt: number
}

/* ---------------------------------------------------------- http plumbing -- */

export interface HttpResponse {
  ok: boolean
  status: number
  header(name: string): string | null
  text(): Promise<string>
}

export type HttpFetch = (
  url: string,
  init: { method: string; headers: Record<string, string>; body?: string; signal: AbortSignal },
) => Promise<HttpResponse>

/**
 * The default transport, wrapped rather than passed through.
 *
 * A hand-written shape is worth the six lines: a test fake then satisfies four
 * members instead of the whole `Response` interface, and nothing in this file
 * can accidentally start depending on a corner of `fetch` that the fakes do
 * not model — which is how a test suite ends up green against a transport the
 * product does not have.
 */
const globalFetch: HttpFetch = async (url, init) => {
  const response = await fetch(url, init)
  return {
    ok: response.ok,
    status: response.status,
    header: (name) => response.headers.get(name),
    text: () => response.text(),
  }
}

export type GhRun = (args: string[]) => Promise<{ stdout: string; stderr: string }>

/**
 * The environment `gh` is probed with: the app's own, minus every token
 * variable.
 *
 * Stripping them is the whole reason this module does not reuse `github.ts`'s
 * runner. `gh auth token` prints `GH_TOKEN` straight back when it is set, so
 * asking "does gh have a login of its own?" with a token of ours in the
 * environment answers yes every single time — including on a machine where
 * nobody has ever run `gh auth login`. The probe would confirm whatever it was
 * asked to check, and the panel would offer to reuse a login that does not
 * exist.
 *
 * All four spellings go, not just `GH_TOKEN`: `gh` reads `GITHUB_TOKEN` as a
 * fallback and the two `*_ENTERPRISE_TOKEN` variables for any other host, and
 * a probe that leaves one of them behind is a probe with a hole in it.
 *
 * Exported so that the stripping is checkable without spawning anything.
 */
export function probeEnv(
  env: NodeJS.ProcessEnv,
  pathValue: string,
  platform: Platform,
): NodeJS.ProcessEnv {
  const base = withPath(env, pathValue, platform)
  delete base.GH_TOKEN
  delete base.GITHUB_TOKEN
  delete base.GH_ENTERPRISE_TOKEN
  delete base.GITHUB_ENTERPRISE_TOKEN
  return {
    ...base,
    LC_ALL: 'C',
    GH_PROMPT_DISABLED: '1',
    GH_NO_UPDATE_NOTIFIER: '1',
    GH_PAGER: 'cat',
    NO_COLOR: '1',
    CLICOLOR: '0',
  }
}

async function runGh(
  args: string[],
  env: NodeJS.ProcessEnv,
  platform: Platform,
): Promise<{ stdout: string; stderr: string }> {
  const { stdout, stderr } = await run('gh', args, {
    timeout: GH_TIMEOUT_MS,
    maxBuffer: 1024 * 1024,
    windowsHide: true,
    env: probeEnv(env, await loginPath(), platform),
  })
  return { stdout, stderr }
}

/* -------------------------------------------------------------- failures -- */

function fail(
  kind: GitHubErrorKind,
  message: string,
  action: string | null,
  detail = '',
  secrets: readonly string[] = [],
): GitHubFailure {
  // Redaction first, truncation second — the same ordering `github.ts` argues
  // for, and for the same reason: cutting a credential URL just before its `@`
  // leaves the token itself as the last thing in the string.
  const clean = detail ? redact(detail, { extraSecrets: secrets }) : ''
  const detailText =
    clean.length <= MAX_DETAIL
      ? clean
      : `${clean.slice(0, MAX_DETAIL)}\n… ${clean.length - MAX_DETAIL} more characters`
  return { ok: false, kind, message, action, detail: detailText }
}

/** Text of whatever `execFile` threw, without assuming it threw an `Error`. */
function errorText(error: unknown): string {
  const failure = error as { stderr?: string; stdout?: string; message?: string }
  return `${failure?.stderr ?? ''}\n${failure?.stdout ?? ''}\n${failure?.message ?? ''}`.trim()
}

function isEnoent(error: unknown): boolean {
  return (error as { code?: string | number })?.code === 'ENOENT'
}

/* ---------------------------------------------------------------- scopes -- */

/** Split `X-OAuth-Scopes`, which GitHub sends comma-and-space separated. */
export function parseScopes(header: string | null): string[] {
  if (header === null) return []
  return header
    .split(',')
    .map((scope) => scope.trim())
    .filter((scope) => scope !== '')
}

/** Whether `granted` satisfies `want`, honouring GitHub's scope hierarchy. */
export function hasScope(granted: readonly string[], want: string): boolean {
  const accepted = SCOPE_IMPLIES[want] ?? [want]
  return accepted.some((scope) => granted.includes(scope))
}

/** Which of the scopes we asked for this token does not carry. */
export function missingScopes(granted: readonly string[]): string[] {
  return REQUESTED_SCOPES.filter((scope) => !hasScope(granted, scope))
}

/* -------------------------------------------------------------- endpoints -- */

/**
 * GitHub Enterprise puts the API under `/api/v3` on the same host, while
 * github.com puts it on `api.github.com`. Getting this wrong is silent: the
 * request 404s and reads as "your token is not valid for this host".
 */
export function apiUserUrl(host: string): string {
  return host === 'github.com' ? 'https://api.github.com/user' : `https://${host}/api/v3/user`
}

export function deviceCodeUrl(host: string): string {
  return `https://${host}/login/device/code`
}

export function accessTokenUrl(host: string): string {
  return `https://${host}/login/oauth/access_token`
}

/* -------------------------------------------------------- device-flow wire -- */

interface DeviceCodeResponse {
  device_code?: string
  user_code?: string
  verification_uri?: string
  expires_in?: number
  interval?: number
  error?: string
  error_description?: string
}

interface AccessTokenResponse {
  access_token?: string
  scope?: string
  interval?: number
  error?: string
  error_description?: string
}

function parseJson<T>(text: string): T | null {
  try {
    return JSON.parse(text) as T
  } catch {
    return null
  }
}

function form(fields: Record<string, string>): string {
  return Object.entries(fields)
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join('&')
}

/* ------------------------------------------------------------- the module -- */

export interface GitHubAuthOptions {
  /** Where the credential file lives. `app.getPath('userData')` in the app. */
  storageDir: string
  /** Injected so this module never imports `github.ts` at run time. */
  resolveRepo(cwd: string): Promise<RepoRef | GitHubFailure>
  /**
   * Called whenever the credential in use changes. `github.ts` drops its
   * overview cache on it: that cache holds up to a minute of answers taken
   * under the previous credential, so without this the panel repaints with a
   * cached "you are not signed in" seconds after a successful sign-in.
   */
  onAuthChanged?: () => void
  env?: NodeJS.ProcessEnv
  platform?: Platform
  host?: string
  clientId?: string
  http?: HttpFetch
  gh?: GhRun
  now?: () => number
  /** Cancellable wait, so the polling tests do not take a quarter of an hour. */
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>
}

interface FlowRun {
  prompt: DeviceFlowPrompt
  controller: AbortController
  /** Everyone awaiting this attempt joins the one promise. */
  settled: Promise<void>
}

export class GitHubAuthenticator {
  private readonly dir: string
  private readonly file: string
  private readonly env: NodeJS.ProcessEnv
  private readonly platform: Platform
  private readonly clientId: string
  private readonly http: HttpFetch
  private readonly ghRun: GhRun
  private readonly now: () => number
  private readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>
  private readonly resolveRepo: (cwd: string) => Promise<RepoRef | GitHubFailure>
  private readonly onAuthChanged: () => void

  readonly host: string

  /** `undefined` = not read yet, `null` = read and absent. */
  private stored: StoredCredential | null | undefined = undefined
  private ghPresent: boolean | null = null
  private cached: { at: number; state: GitHubAuthState } | null = null
  private flow: FlowRun | null = null

  /**
   * Why the last device-flow attempt ended without a credential.
   *
   * Carried on the instance rather than thrown, because the attempt outlives
   * the call that started it: whoever eventually asks for the status is a
   * different call from the one that pressed Connect, and the reason has to
   * survive the gap. Cleared by the next successful sign-in.
   */
  private lastFlowFailure: GitHubFailure | null = null

  constructor(options: GitHubAuthOptions) {
    this.dir = join(options.storageDir, 'github')
    this.file = join(this.dir, 'auth.json')
    this.env = options.env ?? process.env
    this.platform = options.platform ?? currentPlatform()
    this.host = (options.host ?? this.env.GH_HOST ?? 'github.com').trim().toLowerCase() || 'github.com'
    this.clientId =
      (options.clientId ?? '').trim() || (this.env[CLIENT_ID_ENV] ?? '').trim() || GH_CLI_CLIENT_ID
    this.http = options.http ?? globalFetch
    this.now = options.now ?? (() => Date.now())
    this.resolveRepo = options.resolveRepo
    this.onAuthChanged = options.onAuthChanged ?? (() => undefined)
    this.sleep =
      options.sleep ??
      ((ms, signal) =>
        new Promise<void>((resolve) => {
          const timer = setTimeout(resolve, ms)
          signal.addEventListener(
            'abort',
            () => {
              clearTimeout(timer)
              resolve()
            },
            { once: true },
          )
        }))
    this.ghRun = options.gh ?? ((args) => runGh(args, this.env, this.platform))
  }

  /** True while the consent screen will name the GitHub CLI, not this app. */
  get borrowedClient(): boolean {
    return this.clientId === GH_CLI_CLIENT_ID
  }

  /* --------------------------------------------------------- credentials -- */

  /**
   * The token from the environment, if any.
   *
   * Read every time rather than cached: `github.ts` builds a child environment
   * from `process.env` on every spawn, so a stale answer here and a fresh one
   * there is precisely the disagreement this module exists to prevent.
   */
  private envToken(): string | null {
    for (const name of ['GH_TOKEN', 'GITHUB_TOKEN']) {
      const value = (this.env[name] ?? '').trim()
      if (value) return value
    }
    return null
  }

  private readStored(): StoredCredential | null {
    if (this.stored !== undefined) return this.stored
    // A credential written by an older version of this app is on disk under
    // whatever ACL it inherited, and a GitHub token can sit there for months
    // without ever being rewritten — the write path alone would never reach it.
    // This is the first thing that opens the file, so it is where the repair
    // goes. It costs nothing off Windows and does not throw; `secret-file.ts`
    // says why a read is the one place that reports rather than refuses.
    protectSecretFile(this.dir, this.file, { platform: this.platform, env: this.env })
    try {
      const parsed = parseJson<StoredCredential>(readFileSync(this.file, 'utf8'))
      // A file that parses but carries no token is not a credential. Treating
      // it as one produces a "connected" card whose every request 401s.
      this.stored =
        parsed && typeof parsed.token === 'string' && parsed.token !== '' ? parsed : null
    } catch {
      this.stored = null
    }
    return this.stored
  }

  /**
   * Throws when the credential could not be stored *safely*, which on Windows
   * includes "could not be locked down to this account".
   *
   * The platform and environment are handed down rather than read again inside
   * the writer, for the reason `platform/host.ts` gives: this class already
   * takes an injected platform so its `gh` calls can be pinned from a Mac, and
   * two reads of the platform in one call path are two answers waiting to
   * disagree.
   */
  private writeStored(credential: StoredCredential): void {
    writeSecretFile(this.dir, this.file, JSON.stringify(credential, null, 2), {
      platform: this.platform,
      env: this.env,
    })
    this.stored = credential
    this.cached = null
    this.onAuthChanged()
  }

  private clearStored(): void {
    try {
      rmSync(this.file, { force: true })
    } catch {
      /* Already gone, or a directory that never existed. Either way there is
         no stored credential afterwards, which is the whole promise. */
    }
    this.stored = null
    this.cached = null
    this.onAuthChanged()
  }

  /**
   * Every credential this process is currently holding.
   *
   * Handed to `redact` as `extraSecrets` so a token is removed by exact match
   * rather than by looking token-shaped — `gh` prints things we did not write,
   * and a classic 40-hex GitHub token looks exactly like a commit SHA.
   */
  secrets(): string[] {
    const out: string[] = []
    const fromEnv = this.envToken()
    if (fromEnv) out.push(fromEnv)
    const stored = this.readStored()
    if (stored) out.push(stored.token)
    return out
  }

  /**
   * The token `github.ts` should hand its `gh` child processes, or null.
   *
   * Null when the environment already carries one: `gh` will find that itself,
   * and overriding it would make the lists come from a different account than
   * the card above them names.
   */
  toolToken(): string | null {
    if (this.envToken()) return null
    return this.readStored()?.token ?? null
  }

  /* ------------------------------------------------------------- probing -- */

  /** Whether `gh` can be run at all. Cached: the answer needs one spawn. */
  async ghInstalled(): Promise<boolean> {
    if (this.ghPresent !== null) return this.ghPresent
    try {
      await this.ghRun(['--version'])
      this.ghPresent = true
    } catch (error) {
      // Anything other than "no such binary" means gh is *there* and unhappy —
      // a broken config, a plugin that throws. Reporting that as "not
      // installed" sends the user to `brew install gh` for a program they
      // already have, which is the least useful sentence available.
      this.ghPresent = !isEnoent(error)
    }
    return this.ghPresent
  }

  /** `gh`'s own stored token, or null when it has none. */
  private async ghToken(): Promise<string | null> {
    try {
      const { stdout } = await this.ghRun(['auth', 'token', '--hostname', this.host])
      const token = stdout.trim()
      return token === '' ? null : token
    } catch {
      // `gh auth token` exits non-zero when there is no login for the host.
      // That is an ordinary answer, not an error worth a sentence of its own —
      // the sentence comes from the state machine below, which knows whether
      // gh is even installed.
      return null
    }
  }

  /**
   * Ask GitHub who a token belongs to and what it may do.
   *
   * This is the only call that proves a credential is alive. `gh auth status`
   * is not a substitute: it reports the token it has stored, not whether that
   * token still works, which is exactly how a revoked login keeps looking fine
   * until the first list fails.
   */
  private async identify(
    token: string,
  ): Promise<
    | { ok: true; identity: GitHubIdentity; scopes: string[]; scopesReported: boolean }
    | { ok: false; failure: GitHubFailure }
  > {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), HTTP_TIMEOUT_MS)
    try {
      const response = await this.http(apiUserUrl(this.host), {
        method: 'GET',
        headers: {
          Accept: 'application/vnd.github+json',
          Authorization: `Bearer ${token}`,
          'User-Agent': 'terminaldeck',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        signal: controller.signal,
      })
      const body = await response.text()

      if (response.status === 401) {
        return {
          ok: false,
          failure: fail(
            'auth-expired',
            'GitHub rejected this sign-in — the token has expired or been revoked.',
            null,
            body,
            this.secrets(),
          ),
        }
      }
      if (response.status === 403 && /rate limit/i.test(body)) {
        return {
          ok: false,
          failure: fail(
            'rate-limited',
            'GitHub’s API rate limit is exhausted, so the sign-in could not be checked. It resets within the hour.',
            null,
            body,
            this.secrets(),
          ),
        }
      }
      if (!response.ok) {
        return {
          ok: false,
          failure: fail(
            'error',
            `GitHub answered HTTP ${response.status} when asked who this sign-in belongs to.`,
            null,
            body,
            this.secrets(),
          ),
        }
      }

      const raw = parseJson<{
        login?: string
        name?: string | null
        html_url?: string
        avatar_url?: string | null
      }>(body)
      if (!raw || typeof raw.login !== 'string') {
        return {
          ok: false,
          failure: fail('error', 'GitHub returned an account it did not name.', null, body, this.secrets()),
        }
      }

      // A missing header and an empty one are different facts. Fine-grained
      // tokens and GitHub App installations send no `X-OAuth-Scopes` at all,
      // and rendering that as "no permissions granted" would tell a user their
      // working token is broken.
      const header = response.header('x-oauth-scopes')
      return {
        ok: true,
        identity: {
          login: raw.login,
          name: typeof raw.name === 'string' && raw.name !== '' ? raw.name : null,
          htmlUrl: typeof raw.html_url === 'string' ? raw.html_url : `https://${this.host}/${raw.login}`,
          avatarUrl: typeof raw.avatar_url === 'string' ? raw.avatar_url : null,
        },
        scopes: parseScopes(header),
        scopesReported: header !== null,
      }
    } catch (error) {
      const aborted = controller.signal.aborted
      return {
        ok: false,
        failure: aborted
          ? fail('timeout', 'GitHub did not answer in time.', null)
          : fail(
              'network-down',
              `Could not reach ${this.host} — check your connection.`,
              null,
              errorText(error),
              this.secrets(),
            ),
      }
    } finally {
      clearTimeout(timer)
    }
  }

  /* ------------------------------------------------------- state machine -- */

  /**
   * The whole answer, for one project folder.
   *
   * Six states have all been hit on a real machine and each gets its own
   * sentence, because they have six different fixes and "GitHub failed" is a
   * fix for none of them:
   *
   *   1. no `gh`, no token          — Connect. Installing gh is *not* the fix.
   *   2. `gh` present, logged out   — Connect, or `gh auth login`; both work.
   *   3. connected, scope missing   — one named permission, and what it costs.
   *   4. connected                  — account, scopes, and the folder's repo.
   *   5. folder is not a repository — nothing to do with the sign-in at all.
   *   6. repository has no GitHub remote — likewise.
   *
   * 5 and 6 arrive through `resolveRepo` and are carried beside the connection
   * rather than instead of it: a signed-in user standing in a folder that is
   * not a repository is connected, and telling them otherwise is a lie that
   * sends them to re-authorise for no reason.
   */
  async status(cwd?: string, options: { refresh?: boolean } = {}): Promise<GitHubAuthState> {
    const fresh =
      !options.refresh && this.cached && this.now() - this.cached.at < IDENTITY_TTL_MS
        ? this.cached.state
        : null

    const connection = fresh ?? (await this.readConnection())
    /**
     * Only a *working* connection is worth caching, and the asymmetry is not
     * an optimisation — it is what keeps the panel's buttons honest.
     *
     * Cached failures made two controls lie. The Retry offered for a network
     * outage returned the identical error instantly for the next minute, so it
     * looked broken rather than unlucky. And somebody who read "run gh auth
     * login in a terminal", did exactly that, and came back to the window was
     * told they were still signed out — by a cache, for up to a minute, with a
     * button that appeared to do nothing about it. A failed read is cheap (one
     * `gh auth token` spawn at worst, and `ghPresent` is cached separately), so
     * it is simply taken again every time it is asked for.
     */
    if (!fresh && connection.connected) this.cached = { at: this.now(), state: connection }

    return {
      ...connection,
      pending: this.flow?.prompt ?? null,
      repo: cwd ? await this.resolveRepo(cwd) : null,
    }
  }

  /** Everything except the folder-specific parts, so it can be cached. */
  private async readConnection(): Promise<GitHubAuthState> {
    const ghInstalled = await this.ghInstalled()
    const base: GitHubAuthState = {
      connected: false,
      source: null,
      host: this.host,
      identity: null,
      scopes: [],
      scopesReported: false,
      missingScopes: [],
      ghInstalled,
      borrowedClient: this.borrowedClient,
      disconnect: null,
      pending: null,
      failure: null,
      expiredCredentialRemoved: false,
      repo: null,
    }

    let expiredCredentialRemoved = false

    const fromEnv = this.envToken()
    if (fromEnv) {
      const checked = await this.identify(fromEnv)
      if (checked.ok) {
        return {
          ...base,
          connected: true,
          source: 'environment',
          identity: checked.identity,
          scopes: checked.scopes,
          scopesReported: checked.scopesReported,
          missingScopes: checked.scopesReported ? missingScopes(checked.scopes) : [],
          // Deliberately not offering a button. This app cannot unset a
          // variable in the shell that launched it, and a Disconnect that
          // silently does nothing is worse than no Disconnect at all.
          disconnect: null,
        }
      }
      return {
        ...base,
        failure: {
          ...checked.failure,
          message: `${checked.failure.message} It came from the GH_TOKEN environment variable.`,
          action: null,
        },
      }
    }

    const stored = this.readStored()
    if (stored) {
      const checked = await this.identify(stored.token)
      if (checked.ok) {
        return {
          ...base,
          connected: true,
          source: 'device-flow',
          identity: checked.identity,
          scopes: checked.scopes,
          scopesReported: checked.scopesReported,
          missingScopes: checked.scopesReported ? missingScopes(checked.scopes) : [],
          disconnect: ghInstalled
            ? 'Deletes the sign-in this app stored. The GitHub CLI in your terminal keeps its own.'
            : 'Deletes the sign-in this app stored.',
        }
      }
      // A dead token of ours is deleted rather than reported forever. It
      // cannot be repaired, it shadows a working `gh` login underneath it, and
      // leaving it there means every launch shows the same error with no way
      // out but a Connect that writes over it anyway.
      if (checked.failure.kind === 'auth-expired') {
        this.clearStored()
        expiredCredentialRemoved = true
      } else {
        return { ...base, failure: checked.failure }
      }
    }

    const fromGh = ghInstalled ? await this.ghToken() : null
    if (fromGh) {
      const checked = await this.identify(fromGh)
      if (checked.ok) {
        return {
          ...base,
          connected: true,
          source: 'gh-cli',
          identity: checked.identity,
          scopes: checked.scopes,
          scopesReported: checked.scopesReported,
          missingScopes: checked.scopesReported ? missingScopes(checked.scopes) : [],
          disconnect:
            'Signs the GitHub CLI out on this machine, so your terminal is signed out too.',
          expiredCredentialRemoved,
        }
      }
      return { ...base, failure: checked.failure, expiredCredentialRemoved }
    }

    return {
      ...base,
      expiredCredentialRemoved,
      failure: fail(
        'not-authenticated',
        // No "Not signed in to GitHub." lead-in: the panel prints that as the
        // headline directly above this sentence, and rendered together they
        // said it twice in two consecutive lines. A message is the *next step*,
        // never a restatement of the title over it.
        ghInstalled
          ? 'Connect here, or run gh auth login in a terminal — either one works.'
          : 'Connect here; the GitHub CLI is not needed to sign in.',
        // Only offered when the program exists. Printing a command for a
        // binary that is not installed is the sentence this whole module was
        // written to stop the app producing.
        ghInstalled ? 'gh auth login' : null,
      ),
    }
  }

  /* --------------------------------------------------------- device flow -- */

  /**
   * Ask GitHub for a code, and start polling in the background.
   *
   * Returns as soon as the code exists so it can be on screen while the user
   * walks to their browser; `awaitConnect` is what resolves when they are
   * done. Splitting it this way rather than one long call is what lets a
   * window reload mid-sign-in re-attach to the attempt already running instead
   * of stranding it.
   */
  async connect(): Promise<DeviceFlowPrompt | GitHubFailure> {
    if (this.flow) return this.flow.prompt

    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), HTTP_TIMEOUT_MS)
    let body: string
    let response: HttpResponse
    try {
      response = await this.http(deviceCodeUrl(this.host), {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': 'terminaldeck',
        },
        body: form({ client_id: this.clientId, scope: REQUESTED_SCOPES.join(' ') }),
        signal: controller.signal,
      })
      body = await response.text()
    } catch (error) {
      return controller.signal.aborted
        ? fail('timeout', 'GitHub did not answer in time.', null)
        : fail(
            'network-down',
            `Could not reach ${this.host} — check your connection.`,
            null,
            errorText(error),
          )
    } finally {
      clearTimeout(timer)
    }

    const parsed = parseJson<DeviceCodeResponse>(body)
    if (!response.ok || !parsed?.device_code || !parsed.user_code) {
      // A wrong or unregistered client id answers 404 `{"error":"Not Found"}`
      // with nothing pointing at the id, so it is named here rather than left
      // as "GitHub said no".
      return fail(
        'auth-unavailable',
        this.borrowedClient
          ? 'GitHub would not start a sign-in for this app. Its OAuth client may have been revoked; set ' +
            `${CLIENT_ID_ENV} to a client id you control.`
          : `GitHub would not start a sign-in for client ${this.clientId}. Check the OAuth app still exists and has device flow enabled.`,
        null,
        body,
      )
    }

    const intervalMs = Math.max(1, parsed.interval ?? 5) * 1000
    const prompt: DeviceFlowPrompt = {
      userCode: parsed.user_code,
      verificationUri: parsed.verification_uri ?? `https://${this.host}/login/device`,
      expiresAt: this.now() + Math.max(60, parsed.expires_in ?? 900) * 1000,
      scopes: [...REQUESTED_SCOPES],
      borrowedClient: this.borrowedClient,
    }

    const flowController = new AbortController()
    const flow: FlowRun = {
      prompt,
      controller: flowController,
      settled: this.poll(parsed.device_code, prompt, intervalMs, flowController.signal).finally(
        () => {
          if (this.flow === flow) this.flow = null
        },
      ),
    }
    this.flow = flow
    // The rejection path is owned by whoever awaits `settled`; without this the
    // background promise is unhandled the moment nobody has called
    // `awaitConnect` yet, which in Electron logs a warning at launch.
    flow.settled.catch(() => undefined)
    return prompt
  }

  /** Resolves when the sign-in in flight settles, or immediately if none is. */
  async awaitConnect(cwd?: string): Promise<GitHubAuthState> {
    const flow = this.flow
    if (!flow) return this.status(cwd, { refresh: true })
    await flow.settled
    return this.status(cwd, { refresh: true })
  }

  /** Stop waiting. The code on GitHub's side simply expires unused. */
  async cancelConnect(cwd?: string): Promise<GitHubAuthState> {
    this.flow?.controller.abort()
    this.flow = null
    return this.status(cwd, { refresh: true })
  }

  /**
   * Poll GitHub until the user finishes, refuses, or the code expires.
   *
   * The two rules that are easy to get wrong, both from the OAuth device-flow
   * spec and both observed live:
   *
   *  - **Wait before the first poll.** Asking immediately earns a `slow_down`
   *    before the user has even seen the code.
   *  - **`slow_down` carries a new interval and it is mandatory.** Ignoring it
   *    gets the attempt rejected outright rather than merely throttled.
   */
  private async poll(
    deviceCode: string,
    prompt: DeviceFlowPrompt,
    intervalMs: number,
    signal: AbortSignal,
  ): Promise<void> {
    let wait = intervalMs

    while (!signal.aborted) {
      await this.sleep(wait, signal)
      if (signal.aborted) return
      if (this.now() >= prompt.expiresAt) {
        this.lastFlowFailure = fail(
          'auth-code-expired',
          'The sign-in code expired before it was entered. Press Connect to get a new one.',
          null,
        )
        return
      }

      let body: string
      let ok: boolean
      try {
        const response = await this.http(accessTokenUrl(this.host), {
          method: 'POST',
          headers: {
            Accept: 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'terminaldeck',
          },
          body: form({
            client_id: this.clientId,
            device_code: deviceCode,
            grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
          }),
          signal,
        })
        body = await response.text()
        ok = response.ok
      } catch (error) {
        if (signal.aborted) return
        // A single failed poll is not a failed sign-in: the user is standing at
        // a browser and the laptop's wifi flapped. Keep waiting; the code's own
        // expiry is what ends this loop.
        this.lastFlowFailure = fail(
          'network-down',
          `Could not reach ${this.host} — check your connection.`,
          null,
          errorText(error),
        )
        continue
      }

      const parsed = parseJson<AccessTokenResponse>(body)
      if (ok && parsed?.access_token) {
        const token = parsed.access_token
        const checked = await this.identify(token)
        if (!checked.ok) {
          this.lastFlowFailure = checked.failure
          return
        }
        try {
          this.writeStored({
            version: 1,
            host: this.host,
            token,
            login: checked.identity.login,
            scopes: checked.scopes,
            obtainedAt: this.now(),
          })
        } catch (error) {
          /*
           * The sign-in worked and the credential could not be stored, which is
           * a real outcome and used to be an invisible one: this runs on a
           * background promise whose rejection `connect` deliberately swallows,
           * so the only thing the user saw was a panel that never became
           * connected and never said why.
           *
           * On Windows the realistic cause is now the one this module cares
           * about — the file could not be restricted to this account, so it was
           * not written at all rather than being left for every account on the
           * PC to read. A full disk and a read-only profile land here too, and
           * all three want the same sentence: you are not signed in, here is
           * what stopped it.
           *
           * `not-authenticated` rather than `error`, because it is the truthful
           * end state and the one the panel already has a headline for. The
           * token is passed as a secret so that nothing quoted out of the
           * failure can carry it into the detail box.
           */
          this.lastFlowFailure = fail(
            'not-authenticated',
            `GitHub signed you in, but this ${machineNoun(this.platform)} would not store the credential safely, so it was not saved.`,
            null,
            errorText(error) || String(error),
            [token],
          )
          return
        }
        this.lastFlowFailure = null
        return
      }

      switch (parsed?.error) {
        case 'authorization_pending':
          continue
        case 'slow_down':
          wait = Math.max(1, parsed.interval ?? Math.ceil(wait / 1000) + 5) * 1000
          continue
        case 'expired_token':
          this.lastFlowFailure = fail(
            'auth-code-expired',
            'The sign-in code expired before it was entered. Press Connect to get a new one.',
            null,
          )
          return
        case 'access_denied':
          this.lastFlowFailure = fail(
            'auth-declined',
            'The sign-in was refused on GitHub. Nothing was changed.',
            null,
          )
          return
        default:
          this.lastFlowFailure = fail(
            'error',
            parsed?.error_description ?? 'GitHub refused the sign-in and did not say why.',
            null,
            body,
          )
          return
      }
    }
  }

  /** The failure from the last attempt, folded into a disconnected status. */
  flowFailure(): GitHubFailure | null {
    return this.lastFlowFailure
  }

  /* --------------------------------------------------------- disconnect -- */

  /**
   * Give up whatever credential is in use, on this machine.
   *
   * "Locally" is load-bearing and is said on screen too. Revoking an OAuth
   * grant for real needs `DELETE /applications/{client_id}/token`, which is
   * authenticated with the client *secret* — and the device flow has no client
   * secret, by design. So no desktop app can do it, and claiming otherwise
   * would be the most dangerous kind of lie this app could tell: a user who
   * believes a stolen laptop's token is dead when it is not. The panel links to
   * GitHub's own authorised-apps page, which is where the real revoke lives.
   */
  async disconnect(cwd?: string): Promise<GitHubAuthState> {
    const before = await this.status(undefined, { refresh: true })

    if (before.source === 'device-flow') {
      this.clearStored()
    } else if (before.source === 'gh-cli') {
      try {
        // `--user` as well as `--hostname`: gh refuses a non-interactive
        // logout when the host has more than one account stored, and the login
        // is the one thing we always know by this point.
        const args = ['auth', 'logout', '--hostname', this.host]
        if (before.identity) args.push('--user', before.identity.login)
        await this.ghRun(args)
      } catch (error) {
        return {
          ...(await this.status(cwd, { refresh: true })),
          failure: fail(
            'error',
            'The GitHub CLI would not sign out. Run gh auth logout in a terminal to finish it.',
            'gh auth logout',
            errorText(error),
            this.secrets(),
          ),
        }
      }
    }

    this.cached = null
    this.ghPresent = null
    this.lastFlowFailure = null
    // `clearStored` already fired this for a device-flow credential; a gh
    // logout has not, and its cached pull requests are just as stale.
    if (before.source !== 'device-flow') this.onAuthChanged()
    return this.status(cwd, { refresh: true })
  }
}

/* --------------------------------------------------------------- singleton -- */

/**
 * The instance the IPC handlers use.
 *
 * A module-level reference rather than a parameter because `github.ts` needs
 * two things from it on a code path that has no way to be handed one: the
 * token to give `gh` child processes, and the secrets to strip out of `gh`'s
 * stderr. Both are called from deep inside a spawn helper. Null until
 * `registerGitHubAuthIpc` runs, and every reader below copes with that rather
 * than assuming boot order.
 */
let active: GitHubAuthenticator | null = null

/** The token `gh` child processes should be given, or null. */
export function githubToolToken(): string | null {
  return active?.toolToken() ?? null
}

/**
 * Remove every credential this process holds from a string, by exact match.
 *
 * Exported for `github.ts`: once we hand `gh` a `GH_TOKEN`, its output is a
 * place our token could appear, and the URL-userinfo redaction that module
 * already does would not catch a bare one.
 */
export function scrubGitHubSecrets(text: string): string {
  const secrets = active?.secrets() ?? []
  if (secrets.length === 0 || !text) return text
  let out = text
  for (const secret of secrets) {
    if (secret.length < 8) continue
    out = out.split(secret).join('[redacted]')
  }
  return out
}

/* --------------------------------------------------------------------- ipc -- */

/**
 * Wire the sign-in channels. Called from `registerGitHubIpc`.
 *
 * Channels:
 *  - `github:auth-status`     (invoke, cwd?) → GitHubAuthState
 *  - `github:auth-connect`    (invoke)       → DeviceFlowPrompt | GitHubFailure
 *  - `github:auth-await`      (invoke, cwd?) → GitHubAuthState, when it settles
 *  - `github:auth-cancel`     (invoke, cwd?) → GitHubAuthState
 *  - `github:auth-disconnect` (invoke, cwd?) → GitHubAuthState
 *
 * Nothing throws across the boundary: every failure is a typed value the panel
 * renders, which is what keeps "you are not signed in" and "this folder is not
 * a repository" from arriving as the same red box.
 */
export function registerGitHubAuthIpc(
  ipcMain: IpcMain,
  options: GitHubAuthOptions,
): GitHubAuthenticator {
  const auth = new GitHubAuthenticator(options)
  active = auth

  /** IPC arguments are untrusted; a folder that is not one is simply absent. */
  const asPath = (value: unknown): string | undefined =>
    typeof value === 'string' && value.length > 0 ? value : undefined

  /**
   * Fold the reason the last sign-in attempt failed into a disconnected state.
   *
   * Without this the user presses Connect, refuses the consent screen, and the
   * panel goes back to a generic "not signed in" — losing the one fact that
   * explains what just happened.
   */
  const withFlowReason = (state: GitHubAuthState): GitHubAuthState => {
    const reason = auth.flowFailure()
    if (state.connected || !reason) return state
    return { ...state, failure: reason }
  }

  ipcMain.handle('github:auth-status', async (_event, cwd: unknown) =>
    withFlowReason(await auth.status(asPath(cwd))),
  )

  ipcMain.handle('github:auth-connect', () => auth.connect())

  ipcMain.handle('github:auth-await', async (_event, cwd: unknown) =>
    withFlowReason(await auth.awaitConnect(asPath(cwd))),
  )

  ipcMain.handle('github:auth-cancel', async (_event, cwd: unknown) =>
    withFlowReason(await auth.cancelConnect(asPath(cwd))),
  )

  ipcMain.handle('github:auth-disconnect', async (_event, cwd: unknown) =>
    auth.disconnect(asPath(cwd)),
  )

  return auth
}
