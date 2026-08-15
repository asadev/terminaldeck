/**
 * Whether an account is actually signed in — asked of the CLI, never assumed.
 *
 * `profiles.ts` can say a profile exists and that its config directory has been
 * written to. It deliberately says nothing about being logged in, because on
 * macOS the credential is in the login Keychain rather than in the directory, so
 * no `stat` can answer the question. The Accounts screen has to answer it
 * anyway: a list of names with no indication of which ones can start a session
 * is the reason a person concludes the feature does not work.
 *
 * So the answer is read out of the agent's own CLI, under the profile's own
 * config directory. Verified on this machine against Claude Code 2.1.233:
 *
 *     $ claude auth status --json
 *     { "loggedIn": true, "authMethod": "claude.ai",
 *       "email": "…", "subscriptionType": "max" }
 *
 *     $ CLAUDE_CONFIG_DIR=<fresh dir> claude auth status --json
 *     { "loggedIn": false, "authMethod": "none", "apiProvider": "firstParty" }
 *
 * Two separate directories, two different answers, from the same binary, in
 * 0.27s. That is the isolation `profiles.ts` documents, observed from the
 * outside — and the email is the thing that makes the screen worth opening,
 * because "Work" and "Personal" are names the user typed and prove nothing.
 *
 * ## Why `--json`, when JSON is already the default
 *
 * It is a guard against the *old* CLI, not a preference about the output.
 * `claude config ls` — the command the header of `profiles.ts` was written
 * against — is no longer a subcommand in 2.1.233: it is now read as a *prompt*,
 * and running it starts a real agent turn that costs tokens and does not
 * return promptly. A status check must never be able to do that. An unknown
 * `--json` option is rejected by the argument parser before anything is
 * spawned, so a build of the CLI without `auth status` fails fast and loudly
 * instead of quietly asking Claude what "auth status" means.
 *
 * ## Nothing here ever claims more than it saw
 *
 * Three states, and the third one is the point: `unknown` is what a person gets
 * when the CLI could not be run, timed out, or answered something this module
 * cannot parse. A green tick is only ever drawn for `loggedIn: true` arriving as
 * JSON from a process that exited normally. Guessing "signed out" from a failed
 * probe would send someone to re-run a login they do not need.
 */

import { execFile } from 'node:child_process'
import { homedir } from 'node:os'
import { promisify } from 'node:util'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import type { ProviderId } from '../shared/types'
import { currentPlatform, withPath, type Platform } from './platform/host'
import { loginPath, PROVIDERS } from './providers'
import { launchSpec } from './tool-probe'
import { findProfile, getState, sessionEnv, supportsProfiles, type Profile } from './profiles'

const run = promisify(execFile)

/* --------------------------------------------------------------- model -- */

/**
 * `unknown` is a real answer and is never collapsed into `signed-out`. See the
 * module note: the two send a person to different places.
 */
export type SignInState = 'signed-in' | 'signed-out' | 'unknown' | 'unsupported'

export interface SignInReport {
  profileId: string
  provider: ProviderId
  state: SignInState
  /** The account the CLI named — an email, normally. Null when it named none. */
  account: string | null
  /** The plan or auth method, when the CLI said. */
  plan: string | null
  /** One sentence for the screen. Always present, in every state. */
  detail: string
  /**
   * Exactly what was run, so a person can paste it into their own terminal and
   * get the same answer. This is the whole reason the screen can be trusted.
   */
  command: string
  checkedAt: number
}

/* -------------------------------------------------------------- parsing -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

export interface AuthAnswer {
  loggedIn: boolean
  account: string | null
  plan: string | null
}

/**
 * The JSON the CLI printed, or null when it printed something else.
 *
 * The braces are found rather than the whole string parsed, because a CLI is
 * free to write a deprecation notice or an update nag to stdout above its own
 * output and has done exactly that before. Anything that is not an object with
 * a boolean `loggedIn` is *not* an answer — a shape this module does not
 * recognise becomes `unknown`, never `signed-out`.
 */
export function parseAuthStatus(raw: string): AuthAnswer | null {
  const open = raw.indexOf('{')
  const close = raw.lastIndexOf('}')
  if (open === -1 || close <= open) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(raw.slice(open, close + 1))
  } catch {
    return null
  }
  if (!isRecord(parsed) || typeof parsed.loggedIn !== 'boolean') return null

  return {
    loggedIn: parsed.loggedIn,
    // Email first because it is the thing a person recognises. `orgName` is the
    // fallback for a workspace login that reports no address of its own.
    account: text(parsed.email) ?? text(parsed.orgName),
    // `subscriptionType` for a subscription, `authMethod` for an API key or a
    // third-party provider — one of them says something useful in every case.
    plan: text(parsed.subscriptionType) ?? text(parsed.authMethod),
  }
}

/** The sentence for an account that answered. */
export function describeAnswer(answer: AuthAnswer): string {
  if (!answer.loggedIn) return 'Not signed in. Open a session with this account to log in.'
  if (answer.account && answer.plan) return `Signed in as ${answer.account} · ${answer.plan}`
  if (answer.account) return `Signed in as ${answer.account}`
  return 'Signed in.'
}

/**
 * Why an agent other than Claude gets no account of its own.
 *
 * Only `CLAUDE_CONFIG_DIR` has been verified to move a login on this machine.
 * Codex ships as a shim around a native binary that is not installed here — the
 * shim throws ENOENT before it reads any environment — and nothing in this
 * repository has ever watched a Gemini login move. Naming a variable that turns
 * out to be wrong does not fail loudly: it *shares* one login between two
 * accounts, silently, which is the exact failure separate accounts exist to
 * prevent. So this says so on screen instead.
 */
export function unsupportedReason(provider: ProviderId): string {
  if (provider === 'shell') return 'A plain shell has no account to sign in to.'
  return 'Separate accounts are Claude-only for now. This agent signs in its own way, and nothing here has verified a way to keep two of its logins apart — so a session on it uses whichever login this machine already has.'
}

/* --------------------------------------------------------------- probing -- */

/** Long enough for a cold start of the CLI, short enough that a screen paints. */
export const SIGNIN_TIMEOUT_MS = 10_000

/**
 * How long an answer is reused before the CLI is asked again.
 *
 * A probe is a process spawn, and the account menu in the toolbar asks for every
 * account each time it opens. Without this, opening a menu three times in ten
 * seconds spawns nine processes to learn the same thing. A login is not
 * something that changes while a menu is open; a person who has just signed in
 * presses Check again, which bypasses this entirely.
 */
export const SIGNIN_CACHE_MS = 30_000

/** What `execFile` hangs off its error when the command fails or is killed. */
interface ExecFailure {
  code?: number | string
  killed?: boolean
  signal?: string | null
  stdout?: string
  stderr?: string
}

export interface ProbeInput {
  stdout: string
  stderr: string
  /** Null when the process was killed or never started. */
  exitCode: number | null
  killed: boolean
}

/**
 * Turn a finished probe into the report the screen renders.
 *
 * Pure, so every branch is testable without spawning anything — which matters
 * more here than usual, since the interesting branches are the ones that only
 * happen on a machine where something is broken.
 */
export function toSignInReport(
  profileId: string,
  provider: ProviderId,
  command: string,
  probe: ProbeInput,
  now = Date.now(),
): SignInReport {
  const base = { profileId, provider, command, checkedAt: now }
  const answer = parseAuthStatus(`${probe.stdout}\n${probe.stderr}`)

  if (answer) {
    return {
      ...base,
      state: answer.loggedIn ? 'signed-in' : 'signed-out',
      account: answer.account,
      plan: answer.plan,
      detail: describeAnswer(answer),
    }
  }

  if (probe.killed) {
    return {
      ...base,
      state: 'unknown',
      account: null,
      plan: null,
      detail: `The agent did not answer within ${Math.round(SIGNIN_TIMEOUT_MS / 1000)} seconds, so this account's sign-in state is unread.`,
    }
  }

  // Everything else: the binary is missing, the subcommand is not in this
  // version, or the output was not the JSON documented above. All three are
  // "we could not tell", and the shell's own words are worth more than ours.
  const said = `${probe.stderr}\n${probe.stdout}`
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '')[0]
  return {
    ...base,
    state: 'unknown',
    account: null,
    plan: null,
    detail: said
      ? `Could not read this account's sign-in state. ${command} said: ${said.slice(0, 160)}`
      : `Could not read this account's sign-in state — ${command} answered nothing.`,
  }
}

/** Everything the probe needs that is not the profile. Injected for tests. */
export interface SignInOptions {
  provider?: ProviderId
  platform?: Platform
  /** Bypass the cache. What "Check again" passes. */
  refresh?: boolean
  /**
   * The PATH to run under. Production passes nothing and gets the user's login
   * PATH — a GUI app on macOS inherits a minimal one, so an agent installed by
   * nvm or Homebrew is otherwise invisible. Tests pass a literal, because
   * asking the machine's login shell for its PATH means spawning it.
   */
  path?: string
  /** The spawn itself. Replaced in tests; nothing else ever passes it. */
  exec?(command: string, args: string[], options: { env: Record<string, string | undefined>; cwd: string; timeout: number }): Promise<ProbeInput>
}

async function spawnProbe(
  command: string,
  args: string[],
  options: { env: Record<string, string | undefined>; cwd: string; timeout: number },
  shell: boolean,
): Promise<ProbeInput> {
  try {
    const { stdout, stderr } = await run(command, args, {
      env: options.env,
      cwd: options.cwd,
      timeout: options.timeout,
      encoding: 'utf8',
      shell,
      // A status check happens behind a menu; it must never flash a console
      // window over whatever the user is doing.
      windowsHide: true,
      // A status line is a few hundred bytes. Anything approaching this is not
      // the answer we asked for.
      maxBuffer: 256 * 1024,
    })
    return { stdout, stderr, exitCode: 0, killed: false }
  } catch (error) {
    const failure = error as ExecFailure
    return {
      stdout: failure.stdout ?? '',
      stderr: failure.stderr ?? '',
      exitCode: typeof failure.code === 'number' ? failure.code : null,
      killed: failure.killed === true || failure.signal != null,
    }
  }
}

/** Answers still worth reusing, by profile id. See `SIGNIN_CACHE_MS`. */
const cache = new Map<string, SignInReport>()

/** Drop the memo. Exported for tests and for anything that changes a login. */
export function resetSignInCache(): void {
  cache.clear()
}

/**
 * Ask whether this profile is signed in.
 *
 * Never rejects. Every failure is a `SignInReport` with `state: 'unknown'` and a
 * sentence naming what happened, because a screen that shows nothing when a
 * probe fails is a screen that looks broken for a reason the user cannot see.
 */
export async function readSignIn(
  profile: Profile,
  options: SignInOptions = {},
): Promise<SignInReport> {
  const provider = options.provider ?? 'claude'
  const platform = options.platform ?? currentPlatform()

  if (!supportsProfiles(provider)) {
    return {
      profileId: profile.id,
      provider,
      state: 'unsupported',
      account: null,
      plan: null,
      detail: unsupportedReason(provider),
      command: '',
      checkedAt: Date.now(),
    }
  }

  // The config directory is part of the key, not decoration: deleting a profile
  // and making another with the same name gives the same id, and an answer read
  // against the old directory would be presented as the new one's.
  const key = `${provider}:${profile.id}:${profile.configDir}`
  if (options.refresh !== true) {
    const cached = cache.get(key)
    if (cached && Date.now() - cached.checkedAt < SIGNIN_CACHE_MS) return cached
  }

  const bin = PROVIDERS[provider].bin
  const launch = launchSpec(bin, null, platform)
  const args = ['auth', 'status', '--json']
  const command = `${bin} ${args.join(' ')}`

  const PATH = options.path ?? (await loginPath(platform))
  const env = {
    ...withPath(process.env, PATH, platform),
    // The whole point: the same binary, pointed at this account's directory.
    // Empty for the user's own install, which is what makes it the user's own
    // install — see `sessionEnv`.
    ...sessionEnv(profile, provider),
  }

  // `homedir()`, not a project folder. A status check must not be attributable
  // to any repository the user has open, and some agent CLIs treat the current
  // directory as a workspace to be trusted before they will run at all.
  const probe = options.exec
    ? await options.exec(launch.command, args, { env, cwd: homedir(), timeout: SIGNIN_TIMEOUT_MS })
    : await spawnProbe(
        launch.command,
        args,
        { env, cwd: homedir(), timeout: SIGNIN_TIMEOUT_MS },
        launch.shell,
      )

  const report = toSignInReport(profile.id, provider, command, probe)
  cache.set(key, report)
  return report
}

/* ------------------------------------------------------------------- ipc -- */

/**
 * Wire the sign-in channel. Called next to `registerProfilesIpc(ipcMain)`.
 *
 * Registered here rather than in `profiles.ts` so the dependency runs one way:
 * this module knows about profiles, profiles knows nothing about spawning
 * processes. `profiles.ts` is imported by the headless host and by the restore
 * path, and neither of those should acquire a child-process dependency for a
 * screen only a window draws.
 *
 * - `profiles:signin` (id, { refresh?, provider? }) → {@link SignInReport}
 *
 * Rejects only when the id names no profile, which the renderer treats as a
 * list that has moved on under it. Every other failure — including "the CLI is
 * not installed" — comes back as a report saying so.
 */
export function registerSignInIpc(ipcMain: IpcMain): void {
  ipcMain.handle('profiles:signin', async (_e: IpcMainInvokeEvent, id: unknown, options: unknown) => {
    if (typeof id !== 'string') throw new Error('a profile id is required')
    const profile = findProfile(getState(), id)
    if (!profile) throw new Error(`no profile with id ${id}`)

    const asked = typeof options === 'object' && options !== null ? (options as SignInOptions) : {}
    const provider = asked.provider
    return readSignIn(profile, {
      refresh: asked.refresh === true,
      // Narrowed rather than passed through: this value crosses from the
      // renderer, and `PROVIDERS[provider]` with an unknown key would throw
      // inside a probe whose whole contract is that it does not.
      ...(provider !== undefined && provider in PROVIDERS ? { provider } : {}),
    })
  })
}
