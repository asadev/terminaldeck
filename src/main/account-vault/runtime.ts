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

import { mkdirSync } from 'node:fs'
import { delimiter, join } from 'node:path'
import type { ProviderId } from '../../shared/types'
import type { CodexAuthKeeper } from './codex-auth'
import { isLoginSlot, type ShimAnswer } from './keychain-requests'
import { VAULT_HOME_ENV, VAULT_SOCKET_ENV, VAULT_TICKET_ENV } from './keychain-shim'
import type { LoginSource, Seat, TicketBook } from './server'
import type { AccountVault, VaultSummary, VaultWrite } from './store'

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
  /**
   * The real `security`, for a lookup made on a seat's behalf — moving an
   * account in before a session is switched to it, or checking a login the
   * agent keeps exists before switching a session onto it. Absent where
   * nothing may be run (tests, and any build with no shim).
   */
  keychain?: (argv: readonly string[], stdin: string | null) => Promise<ShimAnswer>
  /**
   * Where a session started on a login the agent keeps is given its own
   * credential folder (`seatLaunch`) — inside this app's data, so nothing is
   * ever written into a folder the person's own terminal uses. Absent: such
   * sessions keep the agent's folder, and are never nudged.
   */
  storeBase?: string
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
 *  - `app`         the vault holds it (or will, the moment the agent writes one).
 *  - `adopting`    a Claude account made before this release: its login is still
 *                  in the keychain item the agent made for it, and the first time
 *                  the agent reads it, it is kept here instead. See
 *                  `server.ts` — `VaultServerDeps.adopting`.
 *  - `unavailable` the app keeps this login and cannot reach it right now — no
 *                  vault in this process (the headless host has no
 *                  `safeStorage`), or the vault would not unlock. **Not**
 *                  `agent`: falling back would have the agent read the keychain
 *                  item its directory hash names, which for an account the app
 *                  keeps is a stale login or none, and the session would run as
 *                  something nobody chose. Sessions on it are refused with
 *                  {@link UNAVAILABLE_SENTENCE} instead.
 *  - `agent`       the agent keeps it, as before. Every account the app has never
 *                  kept, and always the machine's own install.
 */
export type KeptBy = 'app' | 'adopting' | 'unavailable' | 'agent'

/** As much of an account as the rule reads. `profiles.ts`'s `Profile` fits. */
export interface VaultSubject {
  id: string
  provider: ProviderId
  system: boolean
  configDir: string
  /** `'app'` when the account was born in the vault — it never read the keychain. */
  loginStore?: 'app'
  /**
   * The vault slots of an account made before the vault that have moved in, one
   * by one. A slot listed here is the vault's to answer, held or empty.
   */
  keptSlots?: readonly string[]
}

/** The agents this app can hand a kept login to. */
export const KEPT_PROVIDERS: readonly ProviderId[] = ['claude', 'codex']

/** Why a session on an `unavailable` account is refused — one sentence, everywhere. */
export const UNAVAILABLE_SENTENCE =
  'This app keeps this account’s login, and its store is not open in this process, so nothing ' +
  'was started. Open the desktop app on this Mac, or sign the account in again there.'

/** Has the app ever kept anything for this account? Then it is the app's, vault or no vault. */
function promised(account: VaultSubject): boolean {
  return account.loginStore === 'app' || (account.keptSlots?.length ?? 0) > 0
}

/** Can this process answer this agent's logins at all? */
function usable(account: VaultSubject, runtime: AccountVaultRuntime | null): boolean {
  if (runtime === null || !runtime.vault.available() || runtime.vault.state() === 'locked') return false
  if (account.provider === 'claude') return runtime.shimDir !== null
  if (account.provider === 'codex') return runtime.codex !== null
  return false
}

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
  if (account.system || !managed) return 'agent'
  if (!KEPT_PROVIDERS.includes(account.provider)) return 'agent'
  if (!usable(account, runtime)) return promised(account) ? 'unavailable' : 'agent'
  if (account.provider === 'codex') return 'app'
  if (account.loginStore === 'app') return 'app'
  // Moved in once its login slot has; the API-key slot keeps moving on its own.
  return (account.keptSlots ?? []).some(isLoginSlot) ? 'app' : 'adopting'
}

/**
 * Is this one slot of a pre-vault account still to be moved in?
 *
 * Read per slot, independently of {@link keptBy}'s display answer, so an
 * account whose login has moved still moves its API-key slot when the agent
 * first asks for it — rather than that slot being stranded in the keychain.
 */
export function slotAdopting(
  account: VaultSubject,
  managed: boolean,
  slot: string,
  runtime: AccountVaultRuntime | null = current,
): boolean {
  const kept = keptBy(account, managed, runtime)
  if (kept !== 'app' && kept !== 'adopting') return false
  if (account.provider !== 'claude' || account.loginStore === 'app') return false
  return !(account.keptSlots ?? []).includes(slot)
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
  const kept = keptBy(account, managed, runtime)
  if (kept !== 'app' && kept !== 'adopting') return {}
  return {
    [VAULT_SOCKET_ENV]: runtime.socketPath,
    [VAULT_TICKET_ENV]: runtime.tickets.ticketFor(account.id),
  }
}

/* ----------------------------------------------------------------- seats -- */

/**
 * The config directory a Claude Code process started as this account names its
 * keychain items after: the account's own folder, or — for the machine's own
 * install — whatever `CLAUDE_CONFIG_DIR` the app itself inherited, and `null`
 * when it inherited none (the CLI's names then carry no hash at all).
 */
export function agentLaunchDir(account: VaultSubject, env: NodeJS.ProcessEnv = process.env): string | null {
  if (!account.system) return account.configDir
  const inherited = env.CLAUDE_CONFIG_DIR?.trim()
  return inherited !== undefined && inherited !== '' ? inherited : null
}

/**
 * Where a session switched to this account would be handed its login from, or
 * null when no session can be served it in place.
 *
 *  - A login the app keeps, or is moving in: the vault.
 *  - A login the agent keeps — the machine's own, or a folder the person chose:
 *    the keychain item the agent named after that folder, read and written
 *    there by the real `security` and never copied into the app.
 *  - A kept login out of reach in this process, or any agent but Claude Code:
 *    nothing — the switch then has to restart, or is refused.
 */
export function loginSource(
  account: VaultSubject,
  managed: boolean,
  runtime: AccountVaultRuntime | null = current,
): LoginSource | null {
  if (account.provider !== 'claude') return null
  const kept = keptBy(account, managed, runtime)
  if (kept === 'app' || kept === 'adopting') return { kind: 'vault' }
  if (kept === 'unavailable') return null
  return { kind: 'keychain', dir: agentLaunchDir(account) }
}

/** What a seated session is started with, beside its ticket. */
export interface SeatLaunch {
  /** Variables for the session's environment. */
  env: Record<string, string>
  /** The folder whose hash is on the keychain names the process will ask for; `null` for none. */
  launchDir: string | null
  /** The app-owned folder holding its credential files, or null when there is none to use. */
  storeDir: string | null
}

/** A folder name for an account id that is safe on every file system. */
function storeName(accountId: string): string {
  return accountId.replace(/[^A-Za-z0-9._-]/g, '_')
}

/**
 * Where a seated Claude Code session keeps its credential files.
 *
 * Claude Code keeps three things beside its login (`yb()` in 2.1.287): the
 * plaintext fallback store `.credentials.json`, its refresh lock, and its
 * storage-write lock. The first is also the switch's trigger — a running CLI
 * reads its login again on the next request after that file changes time
 * (`switch-in-place.ts`). For an account this app made, that folder is the
 * account's own folder in the app's data. For a login the agent keeps — the
 * Mac's own (`~/.claude`) or a folder the person chose — it is a folder his own
 * terminal `claude` uses, and the app must never write there.
 *
 * So such a session is started with `CLAUDE_SECURESTORAGE_CONFIG_DIR` pointed
 * at a folder of this app's own, one per account. That moves exactly those
 * three files and nothing else — the session's history, settings and its
 * `~/.claude.json` are where they always were — and it changes the names the
 * CLI asks the keychain for (they carry that folder's hash), which the seat
 * rewrites back to the real item. Measured: `switch-system-session.cli.test.ts`.
 *
 * The cost, stated: such a session's refresh lock is no longer the one the
 * person's own terminal takes, so the two could refresh the same login at the
 * same moment. Claude Code's save is a compare-and-swap against a fresh read
 * (`WQn`), and a refresh that loses re-reads before giving up, so the race ends
 * with both on the newest login — the same race any two folders already have.
 */
export function seatLaunch(home: VaultSubject, source: LoginSource, storeBase: string | null): SeatLaunch {
  if (source.kind === 'vault') return { env: {}, launchDir: home.configDir, storeDir: home.configDir }
  if (storeBase === null) return { env: {}, launchDir: source.dir, storeDir: null }
  const dir = join(storeBase, storeName(home.id))
  return { env: { CLAUDE_SECURESTORAGE_CONFIG_DIR: dir }, launchDir: dir, storeDir: dir }
}

/**
 * The environment that gives one Claude Code session a seat at the vault: the
 * socket, a ticket minted for this launch alone, and — for a session started on
 * a login the agent keeps — the flag that lets the shim fall back to the real
 * command if the app ever stops answering.
 *
 * Every Claude Code session this app starts gets one, whoever keeps its login,
 * because that is what lets it be switched in place later. Started on a login
 * the agent keeps, it is answered by the real `security` exactly as before
 * until somebody switches it. Empty when the shim is not running, or when the
 * account's kept login cannot be reached (such a session is refused anyway).
 *
 * `serving` is the account it is handed the login of — different from `home`
 * only for a session restored after being switched in place, which comes back
 * in its own folder and on the login it was switched to.
 */
export function seatEnv(
  home: VaultSubject,
  homeManaged: boolean,
  provider: ProviderId,
  serving: string = home.id,
  runtime: AccountVaultRuntime | null = current,
): Record<string, string> {
  if (runtime === null || runtime.shimDir === null) return {}
  if (provider !== 'claude' || home.provider !== 'claude') return {}
  const source = loginSource(home, homeManaged, runtime)
  if (source === null) return {}
  const launch = seatLaunch(home, source, runtime.storeBase ?? null)
  if (launch.storeDir !== null && source.kind === 'keychain') {
    try {
      mkdirSync(launch.storeDir, { recursive: true, mode: 0o700 })
    } catch {
      // The CLI makes it too; a folder that cannot be made here is one the
      // switch simply does not nudge through.
    }
  }
  return {
    ...launch.env,
    [VAULT_SOCKET_ENV]: runtime.socketPath,
    [VAULT_TICKET_ENV]: runtime.tickets.seat(home.id, launch.launchDir, serving, launch.storeDir),
    // Only where the session still asks under the agent's own names: then the
    // real command answers it if this app ever stops answering, as it did
    // before the app kept anything. Under this app's own folder's names the
    // real command would find nothing, so it fails closed like any kept login.
    ...(source.kind === 'keychain' && launch.storeDir === null ? { [VAULT_HOME_ENV]: 'agent' } : {}),
  }
}

/** Tie the seat in a session's environment to the session, now that it has an id. */
export function bindSeat(env: Record<string, string>, sessionId: string, runtime: AccountVaultRuntime | null = current): void {
  const ticket = env[VAULT_TICKET_ENV]
  if (runtime === null || ticket === undefined) return
  runtime.tickets.bind(ticket, sessionId)
}

/** The seat a running session holds, or null — a session with none can only be switched by a restart. */
export function sessionSeat(sessionId: string, runtime: AccountVaultRuntime | null = current): Readonly<Seat> | null {
  return runtime?.tickets.sessionSeat(sessionId) ?? null
}

/** Hand a running session another account's login from its next lookup on. */
export function retargetSeat(sessionId: string, accountId: string, runtime: AccountVaultRuntime | null = current): boolean {
  return runtime?.tickets.retarget(sessionId, accountId) ?? false
}

/** The session's process has ended. */
export function releaseSeat(sessionId: string, runtime: AccountVaultRuntime | null = current): void {
  runtime?.tickets.release(sessionId)
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
  if ((kept !== 'app' && kept !== 'adopting') || runtime === null) return null
  if (runtime.vault.has(account.id)) return true
  if (kept !== 'app') return null
  /*
   * Codex is only "signed out" once something has actually been kept for it.
   * A Codex account whose own `config.toml` stores its login in the keyring
   * never writes the file this app follows, so an empty vault there says
   * nothing about whether it is signed in — and "not signed in" would send
   * somebody to redo a login that is perfectly fine.
   */
  if (account.provider === 'codex') return (account.keptSlots ?? []).length > 0 ? false : null
  return false
}

/**
 * Delete everything kept for an account, and stop answering for it.
 *
 * The Codex file is only ever taken away for an account the app keeps — or one
 * whose file it is following — never for an account pointed at a folder the
 * person chose: that `auth.json` is theirs and is the only copy. Answers the
 * vault's own result, so a delete that could not be saved is reported rather
 * than claimed.
 */
export function forgetKeptLogin(
  account: VaultSubject,
  managed: boolean,
  runtime: AccountVaultRuntime | null = current,
): VaultWrite {
  if (runtime === null) return { ok: true, changed: false, message: '' }
  runtime.tickets.revoke(account.id)
  const kept = keptBy(account, managed, runtime)
  if (
    account.provider === 'codex' &&
    (kept === 'app' || (runtime.codex?.following().includes(account.id) ?? false))
  ) {
    runtime.codex?.forget(account)
  }
  return runtime.vault.forget(account.id)
}

/** A new account this app keeps: start following it. Claude needs nothing. */
export function followNewAccount(
  account: VaultSubject,
  managed: boolean,
  runtime: AccountVaultRuntime | null = current,
): void {
  if (runtime === null || keptBy(account, managed, runtime) !== 'app') return
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

/**
 * Clear whatever the vault holds under an id that is about to be reused. See
 * `createProfile` — a failed delete must not hand its login to the next account
 * made under the same name.
 */
export function clearStaleLogin(accountId: string, runtime: AccountVaultRuntime | null = current): void {
  if (runtime === null) return
  runtime.tickets.revoke(accountId)
  if (runtime.vault.has(accountId)) runtime.vault.forget(accountId)
}
