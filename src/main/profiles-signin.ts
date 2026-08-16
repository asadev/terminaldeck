/**
 * Whether an account is actually signed in — asked of the CLI, never assumed.
 *
 * ## One probe per agent, because they do not answer the same way
 *
 * Claude Code has `claude auth status --json` and prints JSON. Codex has
 * `codex login status` and prints one English sentence — there is no `--json`
 * on it (`error: unexpected argument '--json' found`, checked against
 * `codex-cli 0.146.0-alpha.3.1`). So the arguments and the parser both come out
 * of `provider-accounts.ts`, per provider, and neither is guessed: an agent with
 * no entry there is reported `unsupported` rather than probed with somebody
 * else's flags.
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
import {
  ACCOUNT_STRATEGIES,
  signInCommandLine,
  supportsAccounts,
  unsupportedAccountReason,
  type AccountStatusFormat,
} from './provider-accounts'
import { loginPath, PROVIDERS } from './providers'
import { launchSpec } from './tool-probe'
import { findProfile, getState, sessionEnv, type Profile } from './profiles'

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

/**
 * What `codex login status` said, or null when it said something else.
 *
 * Read from the real binary rather than guessed. `codex-cli 0.146.0-alpha.3.1`
 * on this machine answers `Not logged in` for a fresh `CODEX_HOME` and
 * `Logged in using ChatGPT` for the real one; the other three phrasings it can
 * emit are in its own strings and are matched by the same prefix:
 *
 *     Logged in using ChatGPT
 *     Logged in using an API key - <name>
 *     Logged in using personal access token
 *     Logged in using Amazon Bedrock API key
 *
 * The prefix is what is matched, and the remainder becomes `plan` — which is
 * the honest thing to show, because "using an API key" and "using ChatGPT" are
 * two different accounts to a person and the CLI is the only thing that knows
 * which. No email: `login status` does not print one, and the only place an
 * address exists is inside `auth.json`'s id token. Reading a user's credential
 * file to decorate a row is not a trade this app makes — `profiles.ts` never
 * holds a credential, and that is the property that keeps it uninteresting to
 * an attacker.
 *
 * Anything else is `null`, i.e. `unknown`. A CLI that has been renamed, is not
 * installed, or answered a localised string must not be read as "signed out".
 */
export function parseCodexLoginStatus(raw: string): AuthAnswer | null {
  for (const line of raw.split('\n')) {
    const text = line.trim()
    if (text === '') continue
    if (text.startsWith('Not logged in')) return { loggedIn: false, account: null, plan: null }
    if (text.startsWith('Logged in using')) {
      // "Logged in using an API key - openai-work" → plan "an API key - openai-work".
      const plan = text.slice('Logged in using'.length).trim()
      return { loggedIn: true, account: null, plan: plan === '' ? null : plan }
    }
  }
  return null
}

/** Route the probe's output to the parser its agent needs. */
export function parseAuthOutput(format: AccountStatusFormat, raw: string): AuthAnswer | null {
  return format === 'claude-json' ? parseAuthStatus(raw) : parseCodexLoginStatus(raw)
}

/**
 * The sentence for an account that answered.
 *
 * The signed-out half names the agent's own login command, because "open a
 * session with this account to log in" is true but slow, and a person who is
 * already in a terminal would rather be told the four words to type. The
 * command comes from the strategy table, so a Codex account is never told to
 * run `claude auth login`.
 */
export function describeAnswer(answer: AuthAnswer, signInCommand: string | null = null): string {
  if (!answer.loggedIn) {
    return signInCommand === null
      ? 'Not signed in. Open a session with this account to log in.'
      : `Not signed in. Open a session with this account to log in, or run \`${signInCommand}\`.`
  }
  if (answer.account && answer.plan) return `Signed in as ${answer.account} · ${answer.plan}`
  if (answer.account) return `Signed in as ${answer.account}`
  if (answer.plan) return `Signed in using ${answer.plan}`
  return 'Signed in.'
}

/**
 * Why this agent gets no account of its own.
 *
 * A thin forward to `provider-accounts.ts`, kept because callers already import
 * it from here. The sentence it used to hold — "Separate accounts are
 * Claude-only for now" — is now wrong about Codex, and was never an explanation
 * for Gemini: a person reading a reason that does not match their agent has no
 * way to tell whether the app looked or gave up.
 */
export function unsupportedReason(provider: ProviderId): string {
  return unsupportedAccountReason(provider)
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
  const strategy = ACCOUNT_STRATEGIES[provider]
  // Falls back to Claude's reader rather than refusing, because `readSignIn`
  // has already turned an agent with no strategy into `unsupported` and never
  // reaches here — and a defensive `null` would silently downgrade a real
  // answer to "unknown" if that ever stopped being true.
  const answer = parseAuthOutput(
    strategy?.statusFormat ?? 'claude-json',
    `${probe.stdout}\n${probe.stderr}`,
  )

  if (answer) {
    return {
      ...base,
      state: answer.loggedIn ? 'signed-in' : 'signed-out',
      account: answer.account,
      plan: answer.plan,
      detail: describeAnswer(
        answer,
        // The bin, not the whole launch line: what a person types is `codex
        // login`, not the `cmd /c` wrapper the app happens to spawn through.
        signInCommandLine(provider, PROVIDERS[provider]?.bin ?? provider),
      ),
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
  /*
   * The account's own agent, not the caller's guess.
   *
   * `options.provider` used to default to `'claude'`, which was right while an
   * account could only be a Claude one. Now it would probe a Codex account with
   * `claude auth status --json` under `CLAUDE_CONFIG_DIR=<a codex home>` — a
   * command that answers "not signed in" about a perfectly good ChatGPT login,
   * and creates a `.claude.json` inside the Codex directory on its way past.
   * The profile knows what it is; the option is only still honoured so a caller
   * that genuinely means "check this directory as Claude" can say so.
   */
  const provider = options.provider ?? profile.provider
  const platform = options.platform ?? currentPlatform()
  const strategy = ACCOUNT_STRATEGIES[provider]

  if (!supportsAccounts(provider) || !strategy?.statusArgs) {
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
  const args = [...strategy.statusArgs]
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
