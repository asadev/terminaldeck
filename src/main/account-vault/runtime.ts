/**
 * Which accounts this app keeps the login of, and what a session on one of them
 * is started with — asked from anywhere, answered from one place.
 *
 * ## Why module state
 *
 * For the reason `open-shim.ts` gives for `currentOpenShim`: the two ends are
 * decided in different places at different times. The vault, its socket and its
 * shim exist only once the desktop shell has started them (`wire.ts`), and a
 * session is started much later from `host-core.ts`, which must not know what a
 * socket is. So the shell installs a runtime here at boot and everything else
 * asks. Null until then — and null for ever in the headless build, which has no
 * `safeStorage` — which is exactly the state where every account behaves as it
 * did before this module existed.
 *
 * ## Who is kept, and who never is
 *
 * {@link keptBy} is the one rule:
 *
 *  - **Never the machine's own install.** Claude's own login is
 *    `Claude Code-credentials` with no suffix, and it is the same login the
 *    person's own terminal `claude` uses. Taking it into the app would leave the
 *    terminal holding a token the app had refreshed out from under it — the
 *    copy-someone-is-working-in rule, in its plainest form.
 *  - **Never a directory the person chose.** An account pointed at
 *    `~/.claude-work` may be used from a terminal too, for the same reason.
 *  - **Every account this app made its own folder for** — those are used by
 *    nothing but this app — for each agent this app can answer: Claude Code
 *    (through the `security` shim) and Codex (through its file).
 *
 * Gemini is not on that list, and `shared/agent-catalog.ts` says why in its own
 * words: its login is one keychain item for every directory, read by a native
 * module rather than a command, so there is nothing a session could be handed.
 */

import { delimiter } from 'node:path'
import type { ProviderId } from '../../shared/types'
import type { CodexAuthKeeper } from './codex-auth'
import { VAULT_SOCKET_ENV, VAULT_TICKET_ENV } from './keychain-shim'
import type { TicketBook } from './server'
import type { AccountVault, VaultSummary } from './store'

export interface AccountVaultRuntime {
  vault: AccountVault
  tickets: TicketBook
  socketPath: string
  /**
   * The `security` shim's directory, or null when it could not be written — in
   * which case Claude Code logins stay with the agent, as before.
   */
  shimDir: string | null
  /** Null when Codex logins are not kept (no watcher could be started). */
  codex: CodexAuthKeeper | null
}

let current: AccountVaultRuntime | null = null

/** Installed once by the desktop shell. See the header. */
export function installAccountVault(runtime: AccountVaultRuntime): void {
  current = runtime
}

/** Removed at shutdown, so a late caller sees "no vault" rather than a closed socket. */
export function uninstallAccountVault(): void {
  current = null
}

export function currentAccountVault(): AccountVaultRuntime | null {
  return current
}

/* ----------------------------------------------------------------- rule -- */

/**
 * Where an account's login lives.
 *
 *  - `app`       the vault holds it (or will, the moment the agent writes one).
 *  - `adopting`  a Claude account made before this release: its login is still
 *                in the keychain item the agent made for it, and the first time
 *                the agent reads it, it is kept here instead. See
 *                `server.ts` — `VaultServerDeps.adopting`.
 *  - `agent`     the agent keeps it, as before. Every account when no vault is
 *                installed, and always the machine's own install.
 */
export type KeptBy = 'app' | 'adopting' | 'agent'

/** As much of an account as the rule reads. `profiles.ts`'s `Profile` fits. */
export interface VaultSubject {
  id: string
  provider: ProviderId
  system: boolean
  configDir: string
  /** `'app'` once the vault holds — or has held — this account's login. */
  credentials?: 'app'
}

/** The agents this app can hand a kept login to. */
export const KEPT_PROVIDERS: readonly ProviderId[] = ['claude', 'codex']

/**
 * The rule. `managed` is whether the account's folder is one this app made —
 * the caller answers it, because `profiles.ts` owns that test and this module
 * must not import `profiles.ts` (it is imported *by* it).
 */
export function keptBy(
  account: VaultSubject,
  managed: boolean,
  runtime: AccountVaultRuntime | null = current,
): KeptBy {
  if (runtime === null || account.system || !managed) return 'agent'
  if (!runtime.vault.available()) return 'agent'
  if (account.provider === 'claude') {
    if (runtime.shimDir === null) return 'agent'
    return account.credentials === 'app' ? 'app' : 'adopting'
  }
  if (account.provider === 'codex') return runtime.codex === null ? 'agent' : 'app'
  return 'agent'
}

/**
 * What a session on this account is started with, on top of its config
 * directory: the vault's address and this account's ticket.
 *
 * Only for Claude Code. Codex reads its file, which is already in place; a
 * variable it does not read would be one more thing in its environment saying
 * something untrue about how it is signed in.
 *
 * Empty when the session is not this account's own agent — an account belongs
 * to one agent, and `accountEnv` refuses the mismatch for the same reason.
 */
export function vaultEnv(
  account: VaultSubject,
  provider: ProviderId,
  managed: boolean,
  runtime: AccountVaultRuntime | null = current,
): Record<string, string> {
  if (runtime === null || provider !== 'claude' || account.provider !== 'claude') return {}
  if (keptBy(account, managed, runtime) === 'agent') return {}
  return {
    [VAULT_SOCKET_ENV]: runtime.socketPath,
    [VAULT_TICKET_ENV]: runtime.tickets.ticketFor(account.id),
  }
}

/**
 * A PATH with the shim in front, for a session that {@link vaultEnv} gave a
 * ticket to — and the PATH unchanged for every other session.
 *
 * Asked with the env rather than the account so the two cannot disagree: a
 * shim on the PATH of a session with no ticket passes everything through
 * anyway, but it is one more thing on a PATH doing nothing.
 */
export function vaultPath(path: string, env: Record<string, string>, runtime: AccountVaultRuntime | null = current): string {
  if (runtime === null || runtime.shimDir === null) return path
  if (env[VAULT_TICKET_ENV] === undefined) return path
  const parts = path.split(delimiter).filter((part) => part !== '' && part !== runtime.shimDir)
  return [runtime.shimDir, ...parts].join(delimiter)
}

/** What the vault holds for one account, safe to show anywhere. */
export function vaultSummary(accountId: string, runtime: AccountVaultRuntime | null = current): VaultSummary | null {
  return runtime?.vault.summary(accountId) ?? null
}

/**
 * Is this account signed in, as far as the vault can say?
 *
 *  - `true`  the vault holds a login for it.
 *  - `false` it is kept by the app and the vault holds nothing: it is signed out,
 *            definitively — there is nowhere else its login could be.
 *  - `null`  the vault cannot say: the agent keeps this login, or it is still
 *            moving across and its old login may be in the keychain.
 */
export function vaultSignedIn(
  account: VaultSubject,
  managed: boolean,
  runtime: AccountVaultRuntime | null = current,
): boolean | null {
  const kept = keptBy(account, managed, runtime)
  if (kept === 'agent' || runtime === null) return null
  if (runtime.vault.has(account.id)) return true
  return kept === 'app' ? false : null
}

/** Delete everything kept for an account, and stop answering for it. */
export function forgetKeptLogin(
  account: { id: string; configDir: string; provider: ProviderId },
  runtime: AccountVaultRuntime | null = current,
): void {
  if (runtime === null) return
  runtime.tickets.revoke(account.id)
  if (account.provider === 'codex') runtime.codex?.forget(account)
  runtime.vault.forget(account.id)
}

/** A new account this app keeps: start following it. Claude needs nothing. */
export function followNewAccount(
  account: VaultSubject,
  managed: boolean,
  runtime: AccountVaultRuntime | null = current,
): void {
  if (runtime === null || keptBy(account, managed, runtime) === 'agent') return
  if (account.provider === 'codex') runtime.codex?.settle(account)
}

/**
 * Read a kept login's current state from where the agent keeps it in use, now
 * rather than on the watcher's next tick. A no-op for anything but a Codex
 * account the app keeps — Claude Code's writes reach the vault as they happen.
 */
export function recheckKeptLogin(
  account: VaultSubject,
  managed: boolean,
  runtime: AccountVaultRuntime | null = current,
): void {
  if (runtime === null || account.provider !== 'codex') return
  if (keptBy(account, managed, runtime) !== 'app') return
  runtime.codex?.capture(account)
}
