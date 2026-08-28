/**
 * The machine's own host lifecycle, as a phone drives and reads it **over the
 * relay** — status, restart, stop.
 *
 * ## "The relay is the network." — Asad's rule, pinned
 *
 * A phone's server page reaches one box by two roads: an SSH address it was
 * added with, and the relay it is paired over. Asad's own SSH address is a
 * Tailscale name (`imza-pc-wsl`) that goes offline on its own — and when it
 * does, the server page reports the box as unreachable *even though every
 * session on it is still working over the public relay*. That is the exact
 * shape of defect this seam removes: a machine whose sessions run is a machine
 * whose host is plainly alive, so the status it has no screen to show and the
 * restart/stop it has no screen to press are answered here, in the host's own
 * process, over the relay — and the SSH path is the fallback, not the floor.
 *
 * ## What is NOT here, and why
 *
 * There is no `start`: a stopped host is not connected over the relay, so there
 * is nothing on this wire to start — bringing a stopped host up stays on SSH.
 * There is no install or update: those replace the very binary that would
 * answer this, so they too stay on SSH. This seam is only *is the host alive,
 * and manage the one that is*. The fuller survey of the box underneath it —
 * disk, CPU, services — is a different question the SSH probe answers.
 *
 * It is the same shape as {@link GitHubHostAccess}: an optional dependency a
 * host passes into the remote endpoint, whose mere presence is the switch that
 * advertises the `host.control` capability. A build without it — a desktop,
 * which is its own screen, or the public demo box — advertises nothing and a
 * phone draws no relay controls.
 */

import type { HostControlWire, HostManagedBy } from './protocol'

/**
 * What the host knows about *itself*, gathered in its own process. The wire adds
 * only `running: true` (it answered) and the restart/stop `note` on top of this.
 */
export interface HostControlFacts {
  version: string
  address: string
  pid: number
  startedAt: number
  uptimeSeconds: number
  managed: HostManagedBy
}

/**
 * The seam a host passes into the remote endpoint to answer `host.*` verbs.
 *
 * `restart` and `stop` return the sentence to show and **schedule** the act
 * rather than blocking on it — the frame carrying that sentence has to reach the
 * phone before the process the act tears down goes away. See
 * `src/headless/host-lifecycle.ts` for the one real implementation.
 */
export interface HostLifecycle {
  /** A snapshot of the running host. Never throws; `running` is implied true. */
  status(): HostControlFacts | Promise<HostControlFacts>
  /**
   * Restart the host process, and return the sentence a phone shows. Schedules
   * the restart; does not wait for it — the reply must flush first.
   */
  restart(): string | Promise<string>
  /**
   * Stop the host process, and return the sentence a phone shows. Schedules the
   * stop; does not wait for it.
   */
  stop(): string | Promise<string>
}

/**
 * Fold {@link HostControlFacts} (plus a restart/stop note) up to the wire shape.
 *
 * A pure function so the mapping is a thing a test can pin directly rather than
 * a step hidden inside the server handler — the same reason `githubHostWire` is
 * exported. `note` is null for a plain status and a sentence for the verbs.
 */
export function hostControlWire(facts: HostControlFacts, note: string | null): HostControlWire {
  return {
    running: true,
    version: facts.version,
    address: facts.address,
    pid: facts.pid,
    startedAt: facts.startedAt,
    uptimeSeconds: facts.uptimeSeconds,
    managed: facts.managed,
    note,
  }
}
