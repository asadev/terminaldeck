/**
 * What an "account" means for each agent — one strategy per provider.
 *
 * An account in this app is not a login this process holds. It is a directory
 * handed to somebody else's CLI through an environment variable, so that the
 * CLI signs in twice and keeps the two apart itself. That works exactly as far
 * as the CLI cooperates, and it cooperates differently for each of them. So the
 * answer cannot be one variable name with three spellings; it has to be a
 * per-provider statement of what was found and, more importantly, of what was
 * *measured*.
 *
 * The rule this module exists to enforce is the one from `profiles.ts`, made
 * general: **a variable that relocates an agent's configuration is not the same
 * thing as a variable that relocates its login.** Getting that wrong does not
 * fail loudly. It produces two account names sharing one credential, which
 * looks like the feature working right up until somebody commits from the wrong
 * account — and, for one of the three agents below, it would silently *destroy*
 * the first login rather than merely share it.
 *
 * Every claim here was checked on this machine, against the real CLIs, on
 * 2026-08-16. The commands and their output are recorded next to each entry so
 * the next person can re-run them rather than trust this paragraph.
 *
 * ## Claude Code — `CLAUDE_CONFIG_DIR`, verified
 *
 *     $ claude auth status --json
 *     { "loggedIn": true, "authMethod": "claude.ai", "email": "…" }
 *     $ CLAUDE_CONFIG_DIR=/tmp/fresh claude auth status --json
 *     { "loggedIn": false, "authMethod": "none", "apiProvider": "firstParty" }
 *
 * Same binary (2.1.233), two directories, two answers. On macOS the credential
 * itself lives in the login Keychain under a service name derived from the
 * config directory — `Claude Code-credentials` for the default install and
 * `Claude Code-credentials-<hex>` for a redirected one, and this machine's
 * keychain holds one of each plus two suffixed ones. So a second login cannot
 * overwrite the first. `platform/credential-store.ts` carries the platform
 * caveats.
 *
 * ## Codex CLI — `CODEX_HOME`, verified
 *
 *     $ codex login status                      → Logged in using ChatGPT
 *     $ CODEX_HOME=/tmp/a codex login status    → Not logged in
 *     $ CODEX_HOME=/tmp/b codex login status    → Not logged in
 *
 * Same binary (`codex-cli 0.146.0-alpha.3.1`), three homes, and only the real
 * one is signed in. The credential is a file — `$CODEX_HOME/auth.json`, mode
 * 0600, holding `tokens` and `auth_mode` — so it moves with the directory by
 * construction rather than by a platform's keychain policy. That makes Codex
 * the *simplest* of the three to isolate, and it is the one the previous
 * version of this feature refused, on the strength of a broken install: the
 * npm package on this Mac ships a launcher whose native binary is missing
 * (`vendor/aarch64-apple-darwin/path/` contains `rg` and nothing else), so
 * `codex --version` throws ENOENT and every probe through it reported nothing.
 * A working copy of the same CLI is on this machine and answers all three
 * questions above. "The binary on PATH is broken" was read as "the mechanism
 * does not exist", which is a different sentence.
 *
 * ## Gemini CLI — `GEMINI_CLI_HOME` exists, and it does **not** move the login
 *
 * This is the one that must be refused, and the reason is worth stating in
 * full because the variable looks like the answer.
 *
 * `GEMINI_CLI_HOME` is real and documented (`docs/reference/configuration.md`
 * in the shipped package: "Specifies the root directory for Gemini CLI's
 * user-level configuration and storage"). It is a *home*, not a config
 * directory — the CLI creates `.gemini` inside it — and it genuinely moves the
 * settings, the history, the project registry and the chosen auth *method*.
 * Measured: pointing it at an empty directory makes the CLI ask for an auth
 * method it can find in `$GEMINI_CLI_HOME/.gemini/settings.json`.
 *
 * What it does not move is the OAuth token. `OAuthCredentialStorage` in
 * `@google/gemini-cli-core` writes through `HybridTokenStorage`, which prefers
 * the OS keychain, and the keychain coordinates are two constants:
 *
 *     KEYCHAIN_SERVICE_NAME = 'gemini-cli-oauth'
 *     MAIN_ACCOUNT_KEY      = 'main-account'
 *
 * Neither reads the home. Instantiating the shipped `KeychainTokenStorage`
 * under two different `GEMINI_CLI_HOME` values returns the identical service
 * and account both times — measured, not read. So on any machine where the
 * keychain is reachable, two Gemini "accounts" address one keychain item, and
 * signing into the second one does not share the first login: `setPassword`
 * **overwrites** it. Offering the switcher there would delete a login the user
 * still needs, which is a worse failure than the one this module is built to
 * avoid.
 *
 * There is exactly one lever that changes the answer, and it is not one to
 * build a feature on. `GEMINI_FORCE_FILE_STORAGE=true` makes the hybrid fall
 * back to `FileTokenStorage`, whose path *is* derived from the home
 * (`$GEMINI_CLI_HOME/.gemini/mcp-oauth-tokens-v2.json`) — verified end to end
 * by driving the shipped classes: a token saved under home A is readable under
 * home A and comes back `null` under home B. But that flag appears nowhere in
 * Gemini's own documentation; it exists only in the implementation and its unit
 * test. An undocumented flag that is renamed or dropped in a later release
 * produces no error at all — it silently reverts to the shared keychain slot,
 * and the next sign-in overwrites the other account. That is precisely the
 * silent-sharing failure mode, with data loss attached, and it would arrive
 * through an upgrade nobody in this codebase performed.
 *
 * It also *downgrades* the credential: the file is AES-256-GCM under a key
 * `scryptSync('gemini-cli-oauth', hostname + username + '-gemini-cli')` — a key
 * anybody who can read the file can derive. Trading the OS keychain for
 * obfuscation, in order to get a feature the user did not ask to pay for that
 * way, is not a trade this app gets to make on their behalf.
 *
 * So: **Gemini is a first-class provider for sessions and is not offered
 * multi-account.** `unsupportedAccountReason` says so in one sentence, and the
 * Add-account picker refuses it rather than listing it and quietly doing
 * nothing. A user who wants a second Gemini login can still run Gemini here —
 * it just runs under the login the machine already has, which is the truth.
 *
 * ## Shell
 *
 * No login, so nothing to isolate. Listed rather than omitted so the record is
 * total and a fifth provider added to `ProviderId` fails to compile here.
 */

import type { ProviderId } from '../shared/types'

/* --------------------------------------------------------------- strategy -- */

/** How the sign-in probe's output has to be read. See `profiles-signin.ts`. */
export type AccountStatusFormat = 'claude-json' | 'codex-text'

export interface AccountStrategy {
  provider: ProviderId
  /**
   * What to call this agent in a sentence about its account.
   *
   * Duplicated from `providers.ts` rather than imported, and the duplication is
   * the point: `providers.ts` imports `node:child_process` at module scope, and
   * this module is reached from `profiles.ts`, which the headless host and the
   * session-restore path both import. Pulling a spawn dependency into those for
   * the sake of four words is the trade `profiles-signin.ts` already refused in
   * the other direction. `provider-accounts.test.ts` pins the two lists agreeing.
   */
  label: string
  /**
   * The variable that relocates this agent's configuration, or null when it has
   * none this repository has found.
   *
   * Present does **not** imply usable — see `movesLogin`, which is the field
   * that actually decides.
   */
  configEnv: string | null
  /**
   * Whether that variable moves the *login* along with the configuration.
   *
   * This is the whole feature in one boolean. `configEnv` being non-null and
   * this being false is not a half-answer, it is a refusal: Gemini is exactly
   * that case, and the module header explains what happens if it is ignored.
   */
  movesLogin: boolean
  /**
   * Where, relative to the account's directory, the CLI puts the credential —
   * or null when it puts it somewhere outside the directory (a keychain).
   *
   * Used to *observe* isolation rather than assert it: a file that is there is
   * proof this account's login is its own and that deleting the directory signs
   * it out. `profiles.ts` already reports that for Claude; this generalises it.
   */
  credentialFile: string | null
  /** Args that ask the CLI whether this directory is signed in. */
  statusArgs: readonly string[] | null
  statusFormat: AccountStatusFormat | null
  /**
   * Args that start an interactive sign-in.
   *
   * Both of these were read from the installed CLI's own `--help`:
   * `claude auth login` ("Sign in to your Anthropic account") and `codex login`
   * ("Manage login"). They are quoted to the user in the "not signed in"
   * sentence so there is something to type; nothing in this app runs them
   * behind the user's back. The wired path is the other one — start a session
   * under the account and the CLI shows its own login screen, which is how a
   * fresh Claude account has always been signed in here.
   */
  signInArgs: readonly string[] | null
  /** One sentence for the screen when `movesLogin` is false. Never generic. */
  reason: string | null
}

/**
 * The table. A record rather than an array so a provider added to `ProviderId`
 * fails to compile here instead of silently having no strategy — the same
 * reason `detectProviders` names its three agents rather than deriving them.
 */
export const ACCOUNT_STRATEGIES: Record<ProviderId, AccountStrategy> = {
  claude: {
    provider: 'claude',
    label: 'Claude Code',
    configEnv: 'CLAUDE_CONFIG_DIR',
    movesLogin: true,
    // Present on Windows and on installs that keep credentials in the tree; on
    // macOS the Keychain holds it instead and its absence proves nothing. See
    // `platform/credential-store.ts`, which is why this is an observation and
    // not the isolation claim itself.
    credentialFile: '.credentials.json',
    statusArgs: ['auth', 'status', '--json'],
    statusFormat: 'claude-json',
    signInArgs: ['auth', 'login'],
    reason: null,
  },
  codex: {
    provider: 'codex',
    label: 'Codex CLI',
    configEnv: 'CODEX_HOME',
    movesLogin: true,
    // Measured: a fresh `CODEX_HOME` reports "Not logged in"; the real one
    // holds `auth.json` (0600, `tokens` + `auth_mode`) and reports "Logged in
    // using ChatGPT". The credential is in the directory, so deleting the
    // directory does sign this account out — which `deleteProfile` already
    // reports through `credentialsRetained`.
    credentialFile: 'auth.json',
    statusArgs: ['login', 'status'],
    // `codex login status` has no `--json`; the parser reads its sentences.
    statusFormat: 'codex-text',
    signInArgs: ['login'],
    reason: null,
  },
  gemini: {
    provider: 'gemini',
    label: 'Gemini CLI',
    // Named rather than nulled, because "there is no variable" would be false
    // and the next person would go looking for one. The variable exists; what
    // it does not do is the point.
    configEnv: 'GEMINI_CLI_HOME',
    movesLogin: false,
    credentialFile: null,
    statusArgs: null,
    statusFormat: null,
    signInArgs: null,
    reason:
      'Gemini keeps its login in one system keychain entry that is the same for every configuration directory, so a second Gemini account here would not be a second login — signing into it would replace the first one. Gemini sessions run under the Google account this machine is already signed into.',
  },
  shell: {
    provider: 'shell',
    label: 'Shell',
    configEnv: null,
    movesLogin: false,
    credentialFile: null,
    statusArgs: null,
    statusFormat: null,
    signInArgs: null,
    reason: 'A plain shell has no account to sign in to.',
  },
}

/* ---------------------------------------------------------------- queries -- */

/** True only when two logins of this agent are genuinely two logins. */
export function supportsAccounts(provider: ProviderId): boolean {
  const strategy = ACCOUNT_STRATEGIES[provider]
  return strategy !== undefined && strategy.configEnv !== null && strategy.movesLogin
}

/**
 * The providers an account can belong to, in the order they should be offered.
 *
 * Derived from the table rather than restated, so refusing or admitting a
 * provider is a one-field edit above and every screen follows.
 */
export const ACCOUNT_PROVIDERS: readonly ProviderId[] = (
  Object.values(ACCOUNT_STRATEGIES) as AccountStrategy[]
)
  .filter((strategy) => supportsAccounts(strategy.provider))
  .map((strategy) => strategy.provider)

/**
 * Why this agent is not offered multiple accounts.
 *
 * Always a specific sentence about that agent. The old copy said "Separate
 * accounts are Claude-only for now" against every other provider, which is now
 * wrong about Codex and was never an explanation for Gemini — and a person
 * reading a reason that does not match their agent has no way to tell whether
 * the app looked or gave up.
 */
export function unsupportedAccountReason(provider: ProviderId): string {
  const strategy = ACCOUNT_STRATEGIES[provider]
  if (strategy?.reason) return strategy.reason
  return 'This agent signs in its own way, and nothing here has verified a way to keep two of its logins apart — so a session on it uses whichever login this machine already has.'
}

/**
 * The environment overrides a session must spawn with to run as this account.
 *
 * Empty in three cases, and each of them is a decision rather than a gap:
 *
 *  1. The agent has no verified mechanism. Setting a variable we have not
 *     watched move a login is the failure the header is about.
 *  2. The account belongs to a *different* agent. An account is now a login of
 *     one specific CLI, so a Codex account applied to a Claude session would
 *     export `CLAUDE_CONFIG_DIR=<a codex home>` and hand Claude Code a
 *     directory full of somebody else's `auth.json`. That is enforced here, at
 *     the env layer, rather than only in whatever resolved the account —
 *     because this is the last place before the spawn and it is the only one
 *     that cannot be bypassed.
 *  3. There is no directory, i.e. the user's own install. Not a no-op:
 *     `CLAUDE_CONFIG_DIR=$HOME/.claude` makes the CLI look for
 *     `~/.claude/.claude.json` while a default install keeps its config at
 *     `~/.claude.json`, one level up, so the user's normal login reads as
 *     unconfigured. `profiles.ts` has carried that warning since it was
 *     written; it applies to `CODEX_HOME` for the same reason and is applied
 *     the same way — by leaving the variable unset.
 */
export function accountEnv(
  provider: ProviderId,
  account: { provider: ProviderId; configDir: string } | null,
): Record<string, string> {
  if (account === null) return {}
  if (!supportsAccounts(provider)) return {}
  if (account.provider !== provider) return {}
  const key = ACCOUNT_STRATEGIES[provider].configEnv
  if (key === null || account.configDir === '') return {}
  return { [key]: account.configDir }
}

/**
 * The command a person could type to sign this account in, as one string.
 *
 * Shown, not run. It is the second half of the "not signed in" sentence, and
 * the reason it is worth carrying at all is that the answer is different per
 * agent — telling a Codex user to run `claude auth login` is worse than telling
 * them nothing.
 */
export function signInCommandLine(provider: ProviderId, bin: string): string | null {
  const args = ACCOUNT_STRATEGIES[provider]?.signInArgs
  if (!args) return null
  return [bin, ...args].join(' ')
}
