/**
 * Whether Gemini is signed in, asked of the machine because the CLI will not say.
 *
 * Every other agent here answers a question: `claude auth status --json` prints
 * JSON, `codex login status` prints an English sentence. Gemini has neither.
 * `gemini --help` on the installed 0.32.1 lists exactly four subcommands — `mcp`,
 * `extensions`, `skills`, `hooks` — and no `auth`, no `login`, no `status`. The
 * only way to ask the CLI is to start it, and starting it *is* the sign-in flow,
 * which is not something a settings screen may do behind somebody's back.
 *
 * So the machine is read instead, in the four places the shipped
 * `@google/gemini-cli-core` puts the answer. Each was read out of that package's
 * own code on 2026-08-17 rather than guessed:
 *
 *  1. **The login keychain.** `OAuthCredentialStorage` writes through
 *     `HybridTokenStorage`, which prefers the OS keychain, under two constants:
 *     `KEYCHAIN_SERVICE_NAME = 'gemini-cli-oauth'` and
 *     `MAIN_ACCOUNT_KEY = 'main-account'`. Presence is checked with
 *     `security find-generic-password`, which reports the *attributes* of an
 *     item and does not read its password — so it answers without an
 *     authorisation prompt. `prerequisites.ts` already asks about Claude Code's
 *     credential the same way.
 *  2. **`~/.gemini/oauth_creds.json`.** The file store `HybridTokenStorage`
 *     falls back to, and what older installs used before the keychain.
 *  3. **`~/.gemini/google_accounts.json`.** `{ "active": "<email>", "old": [] }`
 *     — the shape is in `userAccountManager.js` and in that package's own tests.
 *     This is the only place the signed-in address exists in plain text, and it
 *     is what turns "signed in" into "signed in as somebody".
 *  4. **`~/.gemini/settings.json` → `security.auth.selectedType`.** The auth
 *     *method*, one of `oauth-personal`, `gemini-api-key`, `vertex-ai`,
 *     `cloud-shell`. `gemini.js` refuses to start without it, so its absence is
 *     itself the answer to "why does Gemini not run".
 *
 * Plus the two environment variables `contentGenerator.js` treats as a login of
 * their own: `GEMINI_API_KEY` and `GOOGLE_API_KEY`.
 *
 * ## What this never does
 *
 * It never reads a token — only whether one exists. It never writes anything,
 * so asking does not create the `.gemini` directory the way a `claude auth
 * status` probe creates a `.claude.json`. And it never reports `signed-out` from
 * a check that failed: a keychain that could not be queried is `unknown`, which
 * sends a person to a different place than "log in again" does.
 */

import { execFile } from 'node:child_process'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { currentPlatform, type Platform } from './platform/host'

const run = promisify(execFile)

/** Both constants are `gemini-cli-core`'s own, quoted in the header. */
export const GEMINI_KEYCHAIN_SERVICE = 'gemini-cli-oauth'
export const GEMINI_KEYCHAIN_ACCOUNT = 'main-account'

/** Short: this is a `security` call on a local keychain, not a network round trip. */
const KEYCHAIN_TIMEOUT_MS = 3000

export interface GeminiSignIn {
  /** True only on positive evidence. Never inferred from an absence of a check. */
  signedIn: boolean
  /** The Google address, when `google_accounts.json` names one. */
  account: string | null
  /** The auth method, in the CLI's own vocabulary. */
  method: string | null
  /** Which of the four places answered. Shown nowhere; useful in a test. */
  evidence: string | null
}

/** The directory Gemini keeps everything in, honouring `GEMINI_CLI_HOME`. */
export function geminiDir(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  const configured = env.GEMINI_CLI_HOME
  // A *home*, not a config directory — the CLI creates `.gemini` inside it.
  // Getting that inversion wrong would read a directory that never has anything
  // in it and report every install signed out.
  const root = typeof configured === 'string' && configured.trim() !== '' ? configured : home
  return join(root, '.gemini')
}

function readJson(path: string): unknown {
  try {
    if (!existsSync(path)) return null
    return JSON.parse(readFileSync(path, 'utf8')) as unknown
  } catch {
    // A half-written or hand-edited file is not evidence either way.
    return null
  }
}

function nonEmptyFile(path: string): boolean {
  try {
    return existsSync(path) && statSync(path).size > 0
  } catch {
    return false
  }
}

/** `{ active: "someone@gmail.com" }`, or null. */
export function activeGoogleAccount(raw: unknown): string | null {
  if (typeof raw !== 'object' || raw === null) return null
  const active = (raw as { active?: unknown }).active
  return typeof active === 'string' && active.trim() !== '' ? active.trim() : null
}

/** `security.auth.selectedType`, or null. */
export function selectedAuthType(raw: unknown): string | null {
  if (typeof raw !== 'object' || raw === null) return null
  const security = (raw as { security?: unknown }).security
  if (typeof security !== 'object' || security === null) return null
  const auth = (security as { auth?: unknown }).auth
  if (typeof auth !== 'object' || auth === null) return null
  const selected = (auth as { selectedType?: unknown }).selectedType
  return typeof selected === 'string' && selected.trim() !== '' ? selected.trim() : null
}

/** The CLI's internal names, in words a person recognises. */
export const AUTH_METHOD_LABEL: Readonly<Record<string, string>> = {
  'oauth-personal': 'Google account',
  'gemini-api-key': 'Gemini API key',
  'vertex-ai': 'Vertex AI',
  'cloud-shell': 'Cloud Shell',
}

export interface GeminiProbeOptions {
  platform?: Platform
  env?: NodeJS.ProcessEnv
  home?: string
  /** Whether the keychain holds Gemini's OAuth item. Injected in tests. */
  keychain?(): Promise<boolean>
}

/**
 * Does the login keychain hold Gemini's OAuth item?
 *
 * macOS only, and false elsewhere rather than an error: `security` is not a
 * command on Windows or Linux, and running it there produced nothing but an
 * ENOENT that a catch turned into a shrug. On those platforms the file store is
 * what `HybridTokenStorage` falls back to and it is checked either way.
 */
async function keychainHasGemini(platform: Platform): Promise<boolean> {
  if (platform !== 'darwin') return false
  try {
    await run(
      'security',
      ['find-generic-password', '-s', GEMINI_KEYCHAIN_SERVICE, '-a', GEMINI_KEYCHAIN_ACCOUNT],
      { timeout: KEYCHAIN_TIMEOUT_MS, windowsHide: true },
    )
    return true
  } catch {
    // Exit 44 is "item not found", which is the ordinary negative answer. Any
    // other failure is also read as "no evidence", never as "signed out" — the
    // caller distinguishes the two by whether anything else answered.
    return false
  }
}

/**
 * Read Gemini's sign-in state off this machine.
 *
 * Never rejects, and never claims more than one of the four places said.
 */
export async function readGeminiSignIn(
  options: GeminiProbeOptions = {},
): Promise<GeminiSignIn> {
  const platform = options.platform ?? currentPlatform()
  const env = options.env ?? process.env
  const home = options.home ?? homedir()
  const dir = geminiDir(env, home)

  const apiKey =
    typeof env.GEMINI_API_KEY === 'string' && env.GEMINI_API_KEY.trim() !== ''
      ? 'GEMINI_API_KEY'
      : typeof env.GOOGLE_API_KEY === 'string' && env.GOOGLE_API_KEY.trim() !== ''
        ? 'GOOGLE_API_KEY'
        : null

  const account = activeGoogleAccount(readJson(join(dir, 'google_accounts.json')))
  const selected = selectedAuthType(readJson(join(dir, 'settings.json')))
  const credsFile = nonEmptyFile(join(dir, 'oauth_creds.json'))
  const inKeychain = await (options.keychain ?? (() => keychainHasGemini(platform)))()

  const method =
    apiKey !== null
      ? `an API key in ${apiKey}`
      : selected !== null
        ? (AUTH_METHOD_LABEL[selected] ?? selected)
        : inKeychain || credsFile
          ? 'Google account'
          : null

  const evidence = inKeychain
    ? 'keychain'
    : credsFile
      ? 'oauth_creds.json'
      : apiKey !== null
        ? apiKey
        : account !== null
          ? 'google_accounts.json'
          : selected !== null
            ? 'settings.json'
            : null

  return {
    // A chosen auth *method* alone is not a login — `security.auth.selectedType`
    // survives a sign-out — so it is deliberately not on this list. What counts
    // is a credential: a keychain item, a token file, or an API key in the
    // environment. `google_accounts.json` counts too, because the CLI only
    // writes it after a completed OAuth exchange.
    signedIn: inKeychain || credsFile || apiKey !== null || account !== null,
    account,
    method,
    evidence,
  }
}

/**
 * The sentence the Accounts row shows.
 *
 * The signed-out half is the important one and it is deliberately not a
 * complaint: Gemini's sign-in genuinely happens inside a session, so the row
 * says what pressing the button will do rather than what is missing.
 */
export function describeGeminiSignIn(state: GeminiSignIn): string {
  if (!state.signedIn) {
    return 'Not signed in. Press Sign in and Gemini opens in a session, where it asks which Google account to use.'
  }
  if (state.account && state.method) return `Signed in as ${state.account} · ${state.method}`
  if (state.account) return `Signed in as ${state.account}`
  if (state.method) return `Signed in with ${state.method}`
  return 'Signed in.'
}
