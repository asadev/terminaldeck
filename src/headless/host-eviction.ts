/**
 * Taking a state directory over from a host that is still running.
 *
 * `daemon.ts` starts exactly one host per state directory. The restart and
 * update paths hand the directory over cleanly — systemd (or `stop`) ends the
 * old host before the new one starts, so the record names a dead pid and nothing
 * here runs. What this file is for is the case that does not come through that
 * door: a host started outside systemd — a bare `terminaldeck-host` in an SSH
 * session that then closed and left it reparented to init — keeps running, and
 * it keeps this machine's relay identity. Two hosts on one identity claim the
 * same single slot at the rendezvous, so they knock each other off it every time
 * either reconnects: a phone attaches and drops every few seconds and never
 * stays, with no error anywhere.
 *
 * Refusing to start (the old behaviour) could not clear such a host — a restart
 * left it alive because nothing was allowed to end it. So the new host takes the
 * directory over instead. SIGTERM first, which the host catches and exits 0 on
 * (see `waitForShutdown`), so evicting even a systemd-run host cannot trip its
 * `Restart=on-failure` into a fight; SIGKILL only if it will not leave.
 */

import { readFileSync } from 'node:fs'
import { BRAND } from '../shared/brand'

/** Poll granularity while waiting for an evicted host to actually exit. */
export const EVICT_POLL_MS = 100
/** How long the polite SIGTERM is given before the impolite one. */
export const EVICT_TERM_BUDGET_MS = 5_000
/** How long SIGKILL is given before we give up and let the socket bind decide. */
export const EVICT_KILL_BUDGET_MS = 2_000

export type EvictionOutcome =
  /** The pid was already gone by the time we looked. */
  | 'gone'
  /**
   * The pid is alive but is not one of our hosts: our host died and its number
   * was reused. Signalling it would be the app harming an unrelated process to
   * tidy its own bookkeeping, so it is left alone — the caller takes the
   * directory regardless, since the stale record and socket are cleared anyway.
   */
  | 'not-ours'
  /** It left on SIGTERM. */
  | 'terminated'
  /** It needed SIGKILL. */
  | 'killed'
  /**
   * Still there after SIGKILL's window — a zombie or an uninterruptible sleep.
   * The caller falls through to clearing the record and rebinding the socket,
   * which is its remaining defence; nothing more can be done from here without
   * risking a process this cannot identify.
   */
  | 'stuck'

export interface EvictionDeps {
  /** `kill(pid, 0)` — is the process there at all (see `processAlive`). */
  alive(pid: number): boolean
  /** Confirm the pid is genuinely one of our hosts, not a reused number. */
  isOurHost(pid: number): boolean
  /** Send a signal. A throw (the process raced us to exit) is swallowed here. */
  signal(pid: number, sig: NodeJS.Signals): void
  /** Sleep, injectable so a test does not wait real seconds. */
  wait(ms: number): Promise<void>
}

/**
 * End the host recorded at `pid` so the caller can claim the directory, and
 * report what it took. Never throws: a signal that races the process to exit is
 * caught, and a pid this cannot identify as ours is left untouched.
 */
export async function evictStaleHost(pid: number, deps: EvictionDeps): Promise<EvictionOutcome> {
  if (!deps.alive(pid)) return 'gone'
  if (!deps.isOurHost(pid)) return 'not-ours'

  send(deps, pid, 'SIGTERM')
  if (await waitGone(deps, pid, EVICT_TERM_BUDGET_MS)) return 'terminated'

  send(deps, pid, 'SIGKILL')
  if (await waitGone(deps, pid, EVICT_KILL_BUDGET_MS)) return 'killed'
  return 'stuck'
}

function send(deps: EvictionDeps, pid: number, sig: NodeJS.Signals): void {
  try {
    deps.signal(pid, sig)
  } catch {
    /* ESRCH: it exited between the alive check and the signal. The wait confirms. */
  }
}

async function waitGone(deps: EvictionDeps, pid: number, budgetMs: number): Promise<boolean> {
  const tries = Math.max(1, Math.round(budgetMs / EVICT_POLL_MS))
  for (let i = 0; i < tries; i++) {
    if (!deps.alive(pid)) return true
    await deps.wait(EVICT_POLL_MS)
  }
  return !deps.alive(pid)
}

/**
 * The real `isOurHost`: the process's own command line still names this app.
 *
 * `/proc/<pid>/cmdline` is the honest test, and the headless host has no
 * platform but Linux and WSL, so there is always a `/proc` to read. It is what
 * tells "the host we recorded is still there" from "that number belongs to
 * something else now" — and the second must never be signalled. NUL-separated
 * argv is a plain string to `includes`.
 */
export function cmdlineIsOurHost(pid: number): boolean {
  try {
    return readFileSync(`/proc/${pid}/cmdline`, 'utf8').includes(BRAND.id)
  } catch {
    // No /proc entry (it just exited, or this is not Linux): cannot confirm it
    // is ours, so treat it as not ours and leave it be.
    return false
  }
}
