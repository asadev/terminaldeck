/**
 * Switching a running Claude Code session to another account without touching
 * the session: same process, same terminal, same scrollback, same conversation.
 * Only the login it is handed changes.
 *
 * ## The complaint
 *
 * Asad, on 0.16.0: *"when we switch it, a new conversation comes. It does not
 * stay in the same session… sometimes it brings new, sometimes it removes and
 * starts from the beginning. Session should not be changed. Session should not
 * be touched. Only account should be changing."*
 *
 * Every switch before this one restarted the agent, because the login was tied
 * to the process: a per-account ticket at the vault, chosen at spawn. A seat
 * (`server.ts`) unties it, and this is the switch that uses it.
 *
 * ## When a running Claude Code reads its login — measured
 *
 * Claude Code 2.1.287, one long-lived process, real binary, the vault answering
 * its keychain lookups (`measure-reread.cli.test.ts`, and the proof in
 * `switch-in-place.cli.test.ts`):
 *
 *  - It reads the login at start, then caches it for **30 seconds** (`ASt`).
 *    A request made inside that window reuses the cached login; the first one
 *    after it reads again. Switching the seat alone therefore takes effect on
 *    the first request 30 s after the last read — measured: turns at +0 s and
 *    +5 s after the switch still went out as the old account, the turn at
 *    +32 s went out as the new one.
 *  - On a **401** it drops the cache, reads again and retries with whatever it
 *    reads — no refresh call — so a refused request picks the new login up at
 *    once.
 *  - **Before every request** it checks the modification time of
 *    `<config dir>/.credentials.json` (`Kk` → `Uk`), and when that has changed
 *    it drops everything it holds and reads the login again. This is how one
 *    Claude Code process notices another one signing in or refreshing. Measured:
 *    switch, touch the file, and the very next request carries the new
 *    account's token; switch back, touch, the next one carries the old one;
 *    switch without touching and it does not.
 *
 * So the switch here is: retarget the seat, then change that file's time. The
 * next request — whenever the person or the agent makes it — goes out as the
 * new account. Nothing is stopped and nothing is typed into the terminal.
 *
 * ## The file, and why touching it is safe
 *
 * `.credentials.json` is the agent's plaintext fallback store, read only when
 * the keychain has nothing — and the keychain is what the seat answers. When it
 * exists only its time is changed. When it does not, it is created holding
 * `{}`, which reads exactly like no file (`x()` in 2.1.287 turns a missing
 * fallback into `{}` anyway), and removed again once the session has read its
 * new login, if it still holds exactly that.
 *
 * ## A refresh in progress is waited out
 *
 * Claude Code refreshes a login under a lock it keeps in the same folder
 * (`.oauth_refresh.lock`, a directory, stale after 60 s, kept fresh every 5 s).
 * Switching in the middle of one would not put the refreshed token in the
 * wrong account — the save is a compare-and-swap against a fresh read, which
 * the seat answers with the new account, so the swap declines — but it would
 * throw that refresh away, and the old account would be left holding a refresh
 * token its server has already replaced. So a switch waits, briefly, for any
 * refresh in that folder to finish first.
 */

import { readFileSync, statSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { serviceFor } from './keychain-requests'
import type { LoginSource, Seat } from './server'

/** The file whose modification time makes a running Claude Code read its login again. */
export const NUDGE_FILE = '.credentials.json'

/** What a nudge file this app created holds — read exactly like no file. */
export const NUDGE_BODY = '{}\n'

/** Claude Code's refresh lock, in the same folder. */
export const REFRESH_LOCK = '.oauth_refresh.lock'

/** The CLI's own staleness rule for that lock (`stale: 60000` in 2.1.287). */
export const REFRESH_LOCK_STALE_MS = 60_000

/** How long a switch waits for a refresh in progress before going ahead anyway. */
export const REFRESH_WAIT_MS = 10_000

const REFRESH_POLL_MS = 100

/** The login slot, the one a switch has to be able to serve. */
export const LOGIN_SLOT = 'keychain:Claude Code-credentials'

export interface InPlaceAccount {
  id: string
  name: string
  /** The account's own config directory — where its keychain item's name comes from. */
  configDir: string
}

export interface InPlaceDeps {
  seat(sessionId: string): Readonly<Seat> | null
  source(accountId: string): LoginSource | null
  /** True while this slot of this account is still on its pre-vault keychain item. */
  adopting(accountId: string, slot: string): boolean
  /** Whether the vault holds this account's login now. */
  held(accountId: string): boolean
  /** Keep what was read from an account's own keychain item; settle the slot. */
  keep(accountId: string, slot: string, value: string | null): boolean
  /** The real `security`. Absent: nothing can be read from the keychain here. */
  keychain?(argv: readonly string[], stdin: string | null): Promise<{ code: number; stdout: string; stderr: string }>
  /** The keychain account name the CLI files its items under. */
  user: string
  retarget(sessionId: string, accountId: string): boolean
  /** The config directory the session's process keeps its files in. */
  launchDir(seat: Readonly<Seat>): string
  sha256(text: string): string
  now?(): number
  wait?(ms: number): Promise<void>
}

export type InPlaceResult =
  | { ok: true; nudged: 'touched' | 'created' | 'none'; nudgeFile: string; waitedForRefreshMs: number }
  | { ok: false; why: string }

/** Is a refresh holding the lock in this folder right now? */
export function refreshInProgress(dir: string, now: number = Date.now()): boolean {
  try {
    const lock = statSync(join(dir, REFRESH_LOCK))
    return now - lock.mtimeMs < REFRESH_LOCK_STALE_MS
  } catch {
    return false
  }
}

/**
 * Change `.credentials.json`'s time in this folder, creating it as `{}` when it
 * is not there. Answers what it did; `none` when neither worked, in which case
 * the switch still takes, within the 30 seconds the CLI caches a login for.
 */
export function nudge(dir: string, at: Date = new Date()): 'touched' | 'created' | 'none' {
  const file = join(dir, NUDGE_FILE)
  try {
    utimesSync(file, at, at)
    return 'touched'
  } catch {
    // Not there (or not ours to touch): try to make it.
  }
  try {
    writeFileSync(file, NUDGE_BODY, { flag: 'wx', mode: 0o600 })
    return 'created'
  } catch {
    return 'none'
  }
}

/**
 * Take back a nudge file this app created, once it has done its job — only if
 * it still holds exactly what was put there. A login written into it since is
 * the agent's, and stays.
 */
export function clearNudge(file: string): boolean {
  try {
    if (readFileSync(file, 'utf8') !== NUDGE_BODY) return false
    unlinkSync(file)
    return true
  } catch {
    return false
  }
}

/**
 * Before a session is switched onto an account, make sure its login can
 * actually be handed over — and for an account made before the vault, move it
 * in first, from the keychain item the agent made for it, so the session never
 * has to.
 *
 * Answers a sentence when the switch has to be refused, null when it can go.
 */
export async function readyToServe(account: InPlaceAccount, deps: InPlaceDeps): Promise<string | null> {
  const source = deps.source(account.id)
  if (source === null) {
    return `${account.name}’s login cannot be reached from here right now, so this session was left as it is.`
  }
  if (source.kind === 'keychain') {
    // A login the agent keeps: there has to be one. Asked without `-w`, so the
    // answer is whether the item exists and never the secret itself.
    if (deps.keychain === undefined) return null
    const service = serviceFor(LOGIN_SLOT, source.dir, deps.sha256)
    const asked = await deps.keychain(['find-generic-password', '-a', deps.user, '-s', service], null)
    if (asked.code === 0) return null
    return asked.code === 44
      ? `${account.name} is not signed in yet, so this session was left as it is. Sign in to it first, then switch.`
      : `The keychain would not say whether ${account.name} is signed in, so this session was left as it is.`
  }
  // The vault's. Moved in first if it is still on its old keychain item.
  if (deps.held(account.id) || !deps.adopting(account.id, LOGIN_SLOT)) return null
  if (deps.keychain === undefined) return null
  const service = serviceFor(LOGIN_SLOT, account.configDir, deps.sha256)
  const read = await deps.keychain(['find-generic-password', '-a', deps.user, '-w', '-s', service], null)
  const value = read.stdout.trim()
  if (read.code === 0 && value !== '') return deps.keep(account.id, LOGIN_SLOT, value) ? null : `${account.name}’s login could not be saved here, so this session was left as it is.`
  if (read.code === 44) {
    deps.keep(account.id, LOGIN_SLOT, null)
    return `${account.name} is not signed in yet, so this session was left as it is. Sign in to it first, then switch.`
  }
  return `The keychain would not hand over ${account.name}’s login, so this session was left as it is.`
}

/**
 * Switch one session to `account`, in place.
 *
 * In order: refuse anything that cannot be served; move a pre-vault account in;
 * wait out a refresh in the session's folder; retarget its seat; nudge the CLI
 * to read its login again. Nothing touches the process.
 */
export async function switchInPlace(
  sessionId: string,
  account: InPlaceAccount,
  deps: InPlaceDeps,
): Promise<InPlaceResult> {
  const seat = deps.seat(sessionId)
  if (seat === null) {
    return { ok: false, why: 'This session was started before accounts could be switched in place.' }
  }
  const refused = await readyToServe(account, deps)
  if (refused !== null) return { ok: false, why: refused }

  const dir = deps.launchDir(seat)
  const now = deps.now ?? (() => Date.now())
  const wait = deps.wait ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)))
  const started = now()
  while (refreshInProgress(dir, now()) && now() - started < REFRESH_WAIT_MS) await wait(REFRESH_POLL_MS)
  const waitedForRefreshMs = now() - started

  if (!deps.retarget(sessionId, account.id)) {
    return { ok: false, why: 'This session ended before it could be switched.' }
  }
  return { ok: true, nudged: nudge(dir), nudgeFile: join(dir, NUDGE_FILE), waitedForRefreshMs }
}

/* ------------------------------------------------- nudge files to take back -- */

/** Nudge files this app created, by the session they were created for. */
const created = new Map<string, string>()

/** Remember a nudge file this app created for a session's switch. */
export function noteCreatedNudge(sessionId: string, file: string): void {
  created.set(sessionId, file)
}

/**
 * The session has read the login it was switched to: the file has done its
 * job, and is taken back if it still holds only what this app put there.
 */
export function settleNudge(sessionId: string): void {
  const file = created.get(sessionId)
  if (file === undefined) return
  created.delete(sessionId)
  clearNudge(file)
}
