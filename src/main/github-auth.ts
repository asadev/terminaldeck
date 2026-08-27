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
 * installed. On Windows it read *half* connected — `gh` is there, a token is
 * there, something about it is wrong — and nothing on screen said which.
 *
 * So this module answers three questions the old code could not:
 *
 *   1. **Is there a credential at all, and where did it come from?** Three
 *      places can supply one and they do not agree, so the answer names the
 *      source rather than hiding it.
 *   2. **What is it allowed to do?** Whatever scopes GitHub reports for it,
 *      read back from GitHub itself rather than assumed. Reported as a fact
 *      and not as a score: this app asks for no scopes, so there is no list to
 *      measure a token against.
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
 * ## One way in: the GitHub App
 *
 * The device flow needs a registered client, and there is exactly one — the
 * GitHub App in `github-app.ts`, verified against the live device-code endpoint
 * through this class's own `connect()` with the response recorded there.
 *
 * It used to have company. A second, *OAuth* path borrowed the GitHub CLI's
 * public client id, and it was deleted on 2026-08-16 along with every branch
 * that chose between the two. What it cost was worth naming, because it is why
 * it is gone rather than demoted:
 *
 *  - **The consent screen said the wrong name.** Borrowing an id means
 *    borrowing an identity, so GitHub's page said "GitHub CLI" and the app had
 *    to print a sentence apologising for it.
 *  - **It asked for everything.** An OAuth app's `repo` scope is a single
 *    all-or-nothing grant over every private repository the account can reach,
 *    write included, and GitHub renders it as **"Full control of private
 *    repositories"** with no repository picker anywhere on the page. There is
 *    no narrower OAuth scope that can read a private repository; that is
 *    GitHub's design, not an oversight here.
 *  - **It was a second everything.** Two grant shapes, two device-request
 *    bodies, two repository-listing endpoints and a switch, kept alive for a
 *    path nobody would choose once the other one worked.
 *
 * A GitHub App answers all three: the consent screen names this app, the
 * permissions come from the registration, and the repositories come from what
 * the user ticked when they installed it. A build with no registration — a fork
 * before it registers its own — says so and points at `gh auth login`, rather
 * than silently signing somebody in as another application.
 *
 * The tests do not read the shipping constant to decide what to expect;
 * `appRegistration` on the options is the seam. Thirteen tests broke the hour a
 * real client id landed because they had been pinning "the constant is still
 * null" while believing they were pinning something about behaviour, and a
 * module whose tests depend on a shipping constant having a particular value is
 * a module that breaks the day it ships.
 *
 * ## Credentials from before the OAuth path was removed still work
 *
 * Deleting the path did not delete the tokens it minted. A stored OAuth
 * credential keeps being used until GitHub stops honouring it, at which point
 * the existing expiry handling deletes it and the panel says so. Clearing them
 * on upgrade was the alternative and it was rejected: the token still works,
 * GitHub has not revoked anything, and signing somebody out to tidy up our own
 * source tree is a destructive act taken for our convenience. `credentialKind`
 * is what keeps them working — it reads how the credential in hand was
 * obtained, so a legacy OAuth token is still listed through `/user/repos`
 * rather than through the installation endpoints it has no installation for.
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
import type { BranchRef, GitHubErrorKind, GitHubFailure, RepoRef } from './github'
import {
  appInstallUrl,
  githubAppRegistration,
  APP_UNCONFIGURED_REASON,
  GITHUB_APP,
  type GitHubAppRegistration,
} from './github-app'
import { readAccessibleRepos, type RepoAccess } from './github-repos'
import { currentPlatform, machineNoun, withPath, type Platform } from './platform/host'
import { loginPath } from './providers'
import { redact } from './redact'
import { protectSecretFile, writeSecretFile } from './remote/secret-file'

const run = promisify(execFile)

/* ------------------------------------------------------------- constants -- */

/**
 * There is no scope list here any more, and its absence is the point.
 *
 * A GitHub App device-code request carries no `scope` at all: the permissions
 * are fixed by the registration and the repositories are chosen at install
 * time, so there is nothing for a scope string to say and sending one asks
 * GitHub to reconcile two permission models in one request.
 *
 * What was here was `['repo', 'notifications']`, requested by the deleted OAuth
 * path. Both are gone for reasons worth keeping: `repo` is the grant GitHub
 * renders as "Full control of private repositories" with no repository picker,
 * which is the screen that started the move to a GitHub App; `notifications`
 * bought the unread bell, and that feature is gone too, because GitHub serves
 * its notifications endpoints to classic personal access tokens only and no
 * permission on any registration changes that.
 */

/** Long enough that opening the panel twice costs one request, not two. */
export const IDENTITY_TTL_MS = 60_000

/**
 * Longer than the identity's, because the answer changes far more slowly.
 *
 * Somebody creates a repository perhaps weekly; the connection cache expires
 * every minute and would otherwise drag a fresh `/user/repos` page behind it
 * every time, which on an account with five hundred repositories is a megabyte
 * of JSON parsed on the main thread for a list that has not moved.
 */
export const ACCESS_TTL_MS = 5 * 60_000

const GH_TIMEOUT_MS = 10_000
const HTTP_TIMEOUT_MS = 15_000

/** Same reasoning as `github.ts`: redact first, then truncate. */
const MAX_DETAIL = 4_000

/* ----------------------------------------------------------------- types -- */

/**
 * What kind of grant a credential *is* — never which client a sign-in would
 * use, because there is only one of those now.
 *
 * It survived the removal of the OAuth sign-in path because credentials outlive
 * paths. Three kinds of token reach this app and only one of them is a GitHub
 * App user token:
 *
 *  - `github-app` — minted here, through the one device flow there is.
 *  - `oauth`      — anything else: a token stored before the OAuth path was
 *                   deleted, a `gh auth login` reused from the CLI, a classic
 *                   PAT in `GH_TOKEN`. They differ in provenance and not in
 *                   what they can do here, which is the only distinction this
 *                   type is asked to carry.
 *
 * It decides one thing: which endpoint lists repositories. A GitHub App user
 * token cannot use `/user/repos` and everything else cannot use
 * `/user/installations`, so getting this wrong empties the Repositories tab for
 * somebody whose sign-in is working perfectly.
 */
export type CredentialKind = 'oauth' | 'github-app'

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

/**
 * The code on screen while a device-flow sign-in is waiting on the user.
 *
 * There is no scope list on it, and there is no client kind: this attempt is a
 * GitHub App attempt because that is the only kind there is. Both fields were
 * here to let the card say two different things for two different sign-ins, and
 * the card now says one.
 */
export interface DeviceFlowPrompt {
  /** Typed into GitHub by hand. Shown, never logged. */
  userCode: string
  /** Where to type it. */
  verificationUri: string
  /** Epoch ms after which the code stops working. */
  expiresAt: number
  /** Where to choose repositories, when a GitHub App slug is configured. */
  installUrl: string | null
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
  /** Whether `gh` is on the login PATH at all. */
  ghInstalled: boolean
  /**
   * How the credential *in use* was obtained, or null while nothing is
   * connected. See `CredentialKind`.
   *
   * It is not a statement about what a *new* sign-in would do — that question
   * has one answer now and needs no field. It describes the token the panel in
   * front of the user is reading GitHub with, which is why a legacy OAuth
   * credential still reports `oauth` on a build that can only mint GitHub App
   * ones.
   */
  credentialKind: CredentialKind | null
  /**
   * True when a real GitHub App registration exists in this build, which since
   * 2026-08-16 is the shipping state.
   *
   * False is what a fork or an enterprise build reports before it registers its
   * own, and it is now the difference between a Connect button and a sentence:
   * with no registration there is nothing to send GitHub, so offering the
   * button would be the "looks clickable, does nothing" failure this codebase
   * puts first. The panel says what to do instead.
   */
  appConfigured: boolean
  /**
   * Where the user picks which repositories the GitHub App may see. Null
   * without a registration, and null with one that has no slug configured —
   * a link that cannot be built is not rendered.
   */
  installUrl: string | null
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
  /**
   * The branch checked out in that folder, or null when there is no repository
   * there to have one.
   *
   * It rides with the sign-in rather than with the pull-request payload because
   * it has to survive every state the payload does not reach: rate-limited,
   * offline, or a folder whose repository this account cannot see. "You are
   * connected as X, this folder is Y, on branch Z" is one sentence, and taking
   * a third of it from a call that fails independently is how it ends up
   * half-rendered.
   */
  branch: BranchRef | null
  /**
   * Every repository this credential can reach, or why that could not be
   * listed. Null while nothing is connected.
   *
   * This is the answer to "I connected and nothing happened": the panel used to
   * have nothing to show unless the open folder happened to be a GitHub
   * repository, so a successful sign-in from anywhere else looked exactly like
   * a failed one.
   */
  access: RepoAccess | null
}

/**
 * What the file on disk holds.
 *
 * `expiresAt` arrives with GitHub App credentials when the registration has
 * "Expire user authorization tokens" left on, and is absent for every OAuth
 * token, which never expires on its own. It is stored rather than ignored so
 * that a dead token produces "your sign-in expired, connect again" instead of a
 * 401 from whichever list happened to load first.
 *
 * **`clientKind` keeps its name on disk, and must.** The type it holds is now
 * called `CredentialKind`, but this is a key in a JSON file that was written by
 * earlier builds and is read by this one. Renaming it would make every existing
 * GitHub App credential read as `undefined` — which defaults to `oauth` — and
 * send its repository list to `/user/repos`, an endpoint a GitHub App user
 * token cannot use. A working sign-in would appear to lose its repositories on
 * upgrade, for a tidier field name.
 */
interface StoredCredential {
  version: 1
  host: string
  token: string
  login: string
  scopes: string[]
  obtainedAt: number
  /** Epoch ms, or absent/null for a credential that does not expire. */
  expiresAt?: number | null
  /** Which kind of grant issued it, so the right endpoints are asked later. */
  clientKind?: CredentialKind
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

/**
 * Split `X-OAuth-Scopes`, which GitHub sends comma-and-space separated.
 *
 * Still here with the OAuth sign-in gone, because the header is not: a `gh
 * auth login` token and a classic PAT in `GH_TOKEN` both report their scopes,
 * and the connection card shows them. What went with the OAuth path is the
 * *comparison* — `missingScopes` and the scope hierarchy behind it answered
 * "which of the scopes we asked for is absent", and this app asks for none.
 * Keeping that machinery over an empty request list would have produced a
 * "Missing 0 permissions" branch that can never render.
 */
export function parseScopes(header: string | null): string[] {
  if (header === null) return []
  return header
    .split(',')
    .map((scope) => scope.trim())
    .filter((scope) => scope !== '')
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
  /**
   * Seconds. Sent only by a GitHub App whose registration has "Expire user
   * authorization tokens" left on — an OAuth token has no expiry at all.
   */
  expires_in?: number
  /**
   * Sent alongside `expires_in`. **Deliberately unused.** Exchanging it needs a
   * client secret, which a desktop app cannot hold and the device flow does not
   * issue, so there is no honest way to refresh from here; the registration is
   * meant to have expiry switched off (`github-app.ts` step 5). It is named
   * here so that a later reader finds this note instead of assuming the field
   * was overlooked.
   */
  refresh_token?: string
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
   * The checked-out branch of a folder. Optional, and the default answers null:
   * every existing caller of this class predates it, and a required option
   * would have made "no branch reader wired" a compile error rather than the
   * honest empty answer it is.
   */
  resolveBranch?(cwd: string): Promise<BranchRef | null>
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
  /**
   * The GitHub App registration compiled into this build. Defaults to the real
   * one in `github-app.ts`, which is what the app itself gets.
   *
   * It is an option so that "what happens with no registration" — a fork before
   * it registers its own — is still askable now that one ships; pass
   * `NO_REGISTRATION` for it. Before this existed, every test that meant "no
   * registration" was really asserting "the module constant is still null", and
   * all of them turned red the hour a client id was pasted in.
   */
  appRegistration?: GitHubAppRegistration
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
  private readonly http: HttpFetch
  private readonly ghRun: GhRun
  private readonly now: () => number
  private readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>
  private readonly resolveRepo: (cwd: string) => Promise<RepoRef | GitHubFailure>
  private readonly resolveBranch: (cwd: string) => Promise<BranchRef | null>
  private readonly onAuthChanged: () => void
  /** The registration compiled into this build. See `appRegistration`. */
  private readonly built: GitHubAppRegistration
  /**
   * The client id the device flow sends, or null when this build has no
   * registration and therefore nothing to send.
   */
  private readonly clientId: string | null

  readonly host: string
  readonly appConfigured: boolean
  readonly installUrl: string | null

  /** `undefined` = not read yet, `null` = read and absent. */
  private stored: StoredCredential | null | undefined = undefined
  private ghPresent: boolean | null = null
  private cached: { at: number; state: GitHubAuthState } | null = null
  /** Keyed on the token as well as the clock, so a re-sign-in never reuses it. */
  private accessCache: { at: number; token: string; value: RepoAccess } | null = null
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

    /*
     * There is one client, resolved once.
     *
     * It used to be a getter over a three-way choice — an explicit id, an
     * environment variable, a stored preference — because the answer could
     * change while the process ran. It cannot now: a registration is compiled
     * in or supplied by `TERMINALDECK_GITHUB_APP_CLIENT_ID` at launch, and
     * nothing a user does inside the app moves it. A field says that, where a
     * getter would leave a reader looking for what makes it vary.
     */
    this.built = options.appRegistration ?? GITHUB_APP
    const registration = githubAppRegistration(this.env, this.built)
    this.clientId = registration.clientId
    this.appConfigured = registration.clientId !== null
    this.installUrl = appInstallUrl(registration.slug, this.host)

    this.http = options.http ?? globalFetch
    this.now = options.now ?? (() => Date.now())
    this.resolveRepo = options.resolveRepo
    this.resolveBranch = options.resolveBranch ?? (async () => null)
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

  /* ---------------------------------------------- what a credential is -- */

  /**
   * How the credential in hand was *obtained*.
   *
   * It decides one thing and it is not cosmetic: `readAccessibleRepos` picks
   * `/user/installations` or `/user/repos` off this value, and the two are not
   * interchangeable — a GitHub App user token is refused by the second and
   * everything else is refused by the first. Answering it from anything other
   * than the credential in hand empties the Repositories tab for a sign-in that
   * is working.
   *
   * Exact for a credential this app minted, because `connect()` records the
   * kind in the file beside the token. A file written before that field existed
   * is OAuth — the GitHub App path did not exist then — and that is a fact on
   * disk rather than a deduction: the credential in this machine's own
   * `userData/github/auth.json` on 2026-08-16 has no `clientKind` and a `gho_`
   * token, which is an OAuth-app token. Defaulting the missing field the other
   * way would send its repository list to `/user/installations`, where it has no
   * installation, and a sign-in that had worked for months would come back
   * empty the day it upgraded.
   *
   * That default is also what keeps every credential minted by the deleted
   * OAuth path working: they are on disk with `clientKind: 'oauth'` or with no
   * `clientKind` at all, and both read as `oauth` here.
   *
   * A token out of the environment or out of `gh`'s own login is `oauth` too,
   * and that is not a guess about provenance — it is what those tokens are.
   * `gh auth login` mints an OAuth-app token and `GH_TOKEN` normally holds a
   * classic PAT; both answer `/user/repos` and neither has an installation to
   * list. A GitHub App user token exported by hand into `GH_TOKEN` would be the
   * one exception, and it would report its refusal from GitHub rather than be
   * mislabelled here.
   */
  private credentialKind(source: AuthSource): CredentialKind {
    if (source !== 'device-flow') return 'oauth'
    return this.readStored()?.clientKind ?? 'oauth'
  }

  /**
   * Whether a stored credential has passed the expiry GitHub gave it.
   *
   * Only GitHub App tokens carry one, and only when the registration leaves
   * "Expire user authorization tokens" on. Checking it locally rather than
   * waiting for the 401 is worth the four lines: the 401 arrives from whichever
   * request happens to run first, so without this the user's first sign of an
   * expired token is a repository list that failed for no stated reason.
   */
  private storedExpired(credential: StoredCredential): boolean {
    return typeof credential.expiresAt === 'number' && this.now() >= credential.expiresAt
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
    // A repository list read under the previous credential is not this
    // credential's answer. It is keyed on the token as well, so this is belt
    // and braces — but a stale "you can see these 40 repositories" under a
    // freshly-connected account is exactly the half-connected display this
    // module exists to end.
    this.accessCache = null
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
    this.accessCache = null
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
   * `secrets()` plus the credential this call is using.
   *
   * The two are the same set for an environment token and for a stored one, and
   * they are *not* for a `gh auth login` reused from the CLI: that token is
   * never held by this process, so it is absent from `secrets()` and would have
   * survived redaction if GitHub — or, more realistically, a proxy in front of
   * it — echoed the Authorization header back in an error body.
   */
  private secretsWith(token: string): string[] {
    const all = this.secrets()
    return all.includes(token) ? all : [...all, token]
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

  /**
   * The host's own GitHub login, as a git credential — or null when the host
   * has none.
   *
   * This is the whole of the 2026-08-27 flip. Asad, verbatim: *"Every device
   * that is actually running the app is the one that owns the GitHub settings —
   * not the mobile application, because the mobile application is just driving
   * it. So the HOST owns everything, everywhere."* Until now git on the machine
   * asked a phone (`credentials.ts` → `credential.request`); now it is answered
   * here, in this process, from the login the machine itself connected — so a
   * push runs with no phone in the loop, awake or asleep.
   *
   * `username` follows the convention the phone clients used before the flip
   * (username = the GitHub login, password = the token): git over HTTPS
   * validates the *password* as the token and ignores the username for token
   * auth, so `x-access-token` stands in when the login is not known — which is
   * the case for a bare `GH_TOKEN` in the environment that was never signed in
   * through this app.
   *
   * Environment first, for the same reason `toolToken()` steps aside for it:
   * that is `gh`'s own precedence, and a machine launched with a `GH_TOKEN` is a
   * machine whose owner chose that token to be the one git uses. A stored
   * device-flow token answers only when the environment carries none.
   */
  gitCredential(): { username: string; password: string } | null {
    const fromEnv = this.envToken()
    if (fromEnv) return { username: this.readStored()?.login ?? 'x-access-token', password: fromEnv }
    const stored = this.readStored()
    if (stored?.token) return { username: stored.login || 'x-access-token', password: stored.token }
    return null
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
            this.secretsWith(token),
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
            this.secretsWith(token),
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
            this.secretsWith(token),
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
          failure: fail('error', 'GitHub returned an account it did not name.', null, body, this.secretsWith(token)),
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
              this.secretsWith(token),
            ),
      }
    } finally {
      clearTimeout(timer)
    }
  }

  /* ------------------------------------------------------ repository list -- */

  /**
   * Which repositories a credential can reach.
   *
   * Cached separately from the connection, and **only when it succeeded**. The
   * asymmetry is the same one the connection cache makes and for the same
   * reason: a rate limit or a flapping network must not be frozen on screen for
   * the life of a cache entry, while a good answer is worth keeping so that
   * opening the panel twice does not cost two round trips.
   *
   * `kind` is the *credential's* — see `credentialKind`. It is never a
   * statement about what this build would mint if Connect were pressed, which
   * is how a legacy OAuth token would end up asked for an installation it does
   * not have.
   */
  private async readAccess(token: string, kind: CredentialKind): Promise<RepoAccess> {
    const cached = this.accessCache
    if (cached && this.now() - cached.at < ACCESS_TTL_MS && cached.token === token) {
      return cached.value
    }
    const value = await readAccessibleRepos({
      token,
      host: this.host,
      http: this.http,
      secrets: this.secretsWith(token),
      now: this.now,
      kind,
    })
    if (value.ok) this.accessCache = { at: this.now(), token, value }
    return value
  }

  /**
   * Prove a credential is alive and find out what it can see, in one round
   * trip's worth of latency rather than two.
   *
   * The two calls are independent — both take the same bearer token, neither
   * needs the other's answer — so they are issued together and the repository
   * list is thrown away if the identity call turns out to have failed. That
   * wastes one request against a dead token, which is rare and costs nothing
   * anybody notices; running them in sequence instead would put a second
   * network round trip in front of every first paint of the panel, which
   * everybody notices.
   */
  private async check(
    token: string,
    source: AuthSource,
  ): Promise<
    | { ok: true; identity: GitHubIdentity; scopes: string[]; scopesReported: boolean; access: RepoAccess }
    | { ok: false; failure: GitHubFailure }
  > {
    const [checked, access] = await Promise.all([
      this.identify(token),
      this.readAccess(token, this.credentialKind(source)),
    ])
    if (!checked.ok) return checked
    return { ...checked, access }
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
    /*
     * A *fully* working connection is what gets cached, and the repository list
     * is part of "fully".
     *
     * The original rule — cache when connected — was written before the status
     * carried anything that could fail on its own. It can now: the repository
     * list has its own rate limit, its own network failure and its own Retry
     * button, and caching a connected-but-failed-list state froze that button
     * for a minute. That is the same defect the failure path was written to
     * avoid, one field along: a control that appears to do nothing.
     *
     * Re-reading costs one `/user` call, and the successful half of the answer
     * is still held by the access cache, so the retry is cheap as well as real.
     */
    const worthCaching = connection.connected && connection.access?.ok !== false
    if (!fresh && worthCaching) this.cached = { at: this.now(), state: connection }

    // Together rather than one after the other: both are local `git` reads of
    // the same folder, and sequencing them puts a second process spawn in the
    // path of every status call for no gain.
    const [repo, branch] = cwd
      ? await Promise.all([this.resolveRepo(cwd), this.resolveBranch(cwd)])
      : [null, null]

    return { ...connection, pending: this.flow?.prompt ?? null, repo, branch }
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
      ghInstalled,
      credentialKind: null,
      appConfigured: this.appConfigured,
      installUrl: this.installUrl,
      disconnect: null,
      pending: null,
      failure: null,
      expiredCredentialRemoved: false,
      repo: null,
      branch: null,
      access: null,
    }

    let expiredCredentialRemoved = false

    const fromEnv = this.envToken()
    if (fromEnv) {
      const checked = await this.check(fromEnv, 'environment')
      if (checked.ok) {
        return {
          ...base,
          connected: true,
          source: 'environment',
          credentialKind: this.credentialKind('environment'),
          identity: checked.identity,
          scopes: checked.scopes,
          scopesReported: checked.scopesReported,
          access: checked.access,
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
      // Expiry is read off the credential before the network is touched. A
      // GitHub App token that GitHub already considers dead is dead whatever
      // the API says next, and asking anyway spends a request to be told so.
      const checked = this.storedExpired(stored)
        ? ({
            ok: false,
            failure: fail(
              'auth-expired',
              'The GitHub sign-in this app stored has expired.',
              null,
            ),
          } as const)
        : await this.check(stored.token, 'device-flow')
      if (checked.ok) {
        return {
          ...base,
          connected: true,
          source: 'device-flow',
          credentialKind: this.credentialKind('device-flow'),
          identity: checked.identity,
          scopes: checked.scopes,
          scopesReported: checked.scopesReported,
          access: checked.access,
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
      const checked = await this.check(fromGh, 'gh-cli')
      if (checked.ok) {
        return {
          ...base,
          connected: true,
          source: 'gh-cli',
          credentialKind: this.credentialKind('gh-cli'),
          identity: checked.identity,
          scopes: checked.scopes,
          scopesReported: checked.scopesReported,
          access: checked.access,
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
        //
        // A build with no registration has no next step *here* — Connect would
        // have nothing to send — so it gets its own sentence rather than an
        // invitation to press a button that cannot work. That case used to be
        // covered by the OAuth fallback, which signed the user in as the GitHub
        // CLI instead of saying anything.
        !this.appConfigured
          ? APP_UNCONFIGURED_REASON
          : ghInstalled
            ? 'Connect here, or run gh auth login in a terminal — either one works.'
            : 'Connect here; the GitHub CLI is not needed to sign in.',
        // Only offered when the program exists. Printing a command for a
        // binary that is not installed is the sentence this whole module was
        // written to stop the app producing. The unconfigured sentence names
        // the command inside itself, and `showsAction` in the panel drops a
        // duplicate rather than printing it twice.
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

    /*
     * Refused before a request is spent, and this is the branch the deleted
     * OAuth fallback used to hide.
     *
     * With no registration there is no client id to send, and GitHub answers a
     * device-code request with a missing or unknown `client_id` with HTTP 404
     * `{"error":"Not Found"}` — a reply that names nothing and reads exactly
     * like an outage. Saying it here, before the network, is the only version
     * of this the user can act on. The panel does not draw the button at all
     * when `appConfigured` is false; this is the second door, for a caller that
     * reaches the channel directly.
     */
    const clientId = this.clientId
    if (clientId === null) {
      return fail('auth-unavailable', APP_UNCONFIGURED_REASON, null)
    }

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
        /*
         * No `scope`, and that is not an omission to tidy up later. A GitHub
         * App's permissions are fixed by its registration and its repositories
         * are chosen at install time, so there is nothing for a scope string to
         * say; sending one asks GitHub to reconcile two different permission
         * models in the same request. The recorded live response in
         * `github-app.ts` is the reply to exactly this body.
         */
        body: form({ client_id: clientId }),
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
      // as "GitHub said no". The single most likely cause is invisible from the
      // response: a GitHub App with "Enable Device Flow" left unticked answers
      // exactly like one that does not exist.
      return fail(
        'auth-unavailable',
        `GitHub would not start a sign-in for GitHub App client ${clientId}. Check the app still exists and has Enable Device Flow ticked.`,
        null,
        body,
      )
    }

    const intervalMs = Math.max(1, parsed.interval ?? 5) * 1000
    const prompt: DeviceFlowPrompt = {
      userCode: parsed.user_code,
      verificationUri: parsed.verification_uri ?? `https://${this.host}/login/device`,
      expiresAt: this.now() + Math.max(60, parsed.expires_in ?? 900) * 1000,
      installUrl: this.installUrl,
    }

    const flowController = new AbortController()
    const flow: FlowRun = {
      prompt,
      controller: flowController,
      settled: this.poll(
        parsed.device_code,
        prompt,
        clientId,
        intervalMs,
        flowController.signal,
      ).finally(
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
    /**
     * The client this attempt was *started* with, passed down rather than read
     * again. Polling a different `client_id` than the device code was issued
     * for is refused outright, and this loop runs for up to fifteen minutes
     * while somebody types a code into a browser — long enough that "read it
     * again at the bottom" is a habit worth not having.
     */
    clientId: string,
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
            client_id: clientId,
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
            expiresAt:
              typeof parsed.expires_in === 'number' && parsed.expires_in > 0
                ? this.now() + parsed.expires_in * 1000
                : null,
            // The only kind this app can mint. Written explicitly rather than
            // left to a default, because the default on read is `oauth` — for
            // the credentials the deleted path left on disk — and a GitHub App
            // token that arrived without this field would be listed through
            // `/user/repos`, which refuses it.
            clientKind: 'github-app',
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
   * "Locally" is load-bearing and is said on screen too. Revoking a grant for
   * real needs `DELETE /applications/{client_id}/token`, which is authenticated
   * with the client *secret* — and the device flow has no client secret, by
   * design. So no desktop app can do it, and claiming otherwise would be the
   * most dangerous kind of lie this app could tell: a user who believes a
   * stolen laptop's token is dead when it is not. Revoking a GitHub App's
   * access for real is done on GitHub, on the app's own installation page.
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
    this.accessCache = null
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

/**
 * Name the process-wide authenticator, so `githubToolToken` and
 * `scrubGitHubSecrets` have something to read.
 *
 * It used to be set only inside `registerGitHubAuthIpc`, which meant it existed
 * only in the windowed build: a headless host registers no Electron IPC, so its
 * `gh` child processes ran with no token and `githubToolToken()` was null on the
 * one build that most needs its own login. Since the host owns GitHub now
 * (2026-08-27), `host-core.ts` builds one authenticator at assembly — the same
 * on a desktop and a server — and calls this, and the desktop's IPC binds to
 * that same instance rather than making a second one.
 */
export function useAuthenticator(auth: GitHubAuthenticator): void {
  active = auth
}

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
  optionsOrAuth: GitHubAuthOptions | GitHubAuthenticator,
): GitHubAuthenticator {
  /*
   * Bind to the authenticator the host already built, or make one.
   *
   * The desktop now hands in the shared instance from `host-core.ts` — the same
   * object the credential proxy answers git from and the wire exposes to a phone
   * — so the panel, `gh`, git and the phone all read one login rather than four
   * that can disagree. The construct-your-own branch is kept for the tests that
   * predate the shared instance and drive this function with plain options; a
   * caller passing options still gets a working, registered authenticator.
   */
  const auth =
    optionsOrAuth instanceof GitHubAuthenticator ? optionsOrAuth : new GitHubAuthenticator(optionsOrAuth)
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
