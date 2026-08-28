/**
 * The one real {@link HostLifecycle} — the headless daemon managing *itself*
 * from a phone, over the relay.
 *
 * ## "The relay is the network." — Asad's rule, pinned
 *
 * A headless server has no screen. The things a person does to it — see that it
 * is up, restart it when it is heavy with tabs and sessions, stop it — used to
 * be reachable only over the SSH address the server was added with. That address
 * is, on Asad's own box, a Tailscale name that drops on its own, and when it
 * drops the server page says the machine "did not answer" while every session on
 * it is still running over the public relay. So the daemon answers `host.status`,
 * `host.restart` and `host.stop` here, in its own process, over the relay it is
 * already on — and SSH is the fallback for the case the relay cannot cover,
 * which is a host that is *not connected as a machine* (there is nothing to ask)
 * and the install/update that replaces this very binary.
 *
 * ## Why restart and stop only *schedule*
 *
 * Both drop the connection the answer travels on. So each returns the sentence
 * to show and hands the act to {@link HostLifecycleDeps.schedule}/`shutdown`,
 * the same shape the local control socket's `stop` uses (`daemon.ts`): the
 * `host.state` frame flushes, *then* the process goes. A blocking restart would
 * kill the socket before the phone heard why.
 *
 * ## The two shapes of restart
 *
 *  - **Under a systemd user unit** — the common case, and Asad's own: hand the
 *    restart to the *user manager*, which lives outside this unit's cgroup, with
 *    `systemctl --user restart --no-block`. `--no-block` enqueues the job and
 *    returns before the manager SIGTERMs us, so this call finishes and the reply
 *    flushes; the fresh instance is a restart *job*, so it starts regardless of
 *    `Restart=on-failure`. We do not call `shutdown` ourselves — systemd owns
 *    the stop.
 *  - **Started directly (no unit)** — a container, or a host started by hand.
 *    Nothing supervises it, so it re-launches itself: a detached shell waits for
 *    this process to let go of the pid lock (a new host refuses to be the second
 *    one, `daemon.ts`) and then `nohup`s a fresh one, and we schedule our own
 *    clean stop. This is the same race `ServerScripts.restart` steps past on the
 *    SSH side, moved in-process.
 */

import type { HostControlFacts, HostLifecycle } from '../main/remote/host-lifecycle'
import type { HostManagedBy } from '../main/remote/protocol'

export interface HostLifecycleDeps {
  /** Trigger the daemon's own graceful shutdown (its module-level `shutdown`). */
  shutdown: (reason: string) => void
  /** Wall clock, injectable so a test can pin uptime. */
  now: () => number
  /** When this host process started, epoch milliseconds. */
  startedAt: number
  /** This process's id. */
  pid: number
  /** The build this host is on, e.g. `0.14.0`. */
  version: string
  /**
   * The relay server address the host prints, when it has one. Optional and
   * empty by default: a phone reading this is already connected over the relay
   * and does not need an address to dial.
   */
  address?: () => string
  /** The systemd user unit name, e.g. `terminaldeck.service`. */
  serviceName: string
  /** True when the systemd user unit file for this host exists on disk. */
  serviceUnitExists: () => boolean
  /** The node binary that runs the daemon (`process.execPath`). */
  execPath: string
  /** The daemon entry module, re-run to re-launch a directly-started host. */
  entryPath: string
  /** Where a re-launched host appends its stderr, so a person can read why. */
  logPath: string
  /** Spawn a detached, unref'd child. The seam a test replaces. */
  spawnDetached: (command: string, args: readonly string[]) => void
  /**
   * Schedule the act that drops this process, *after* the reply frame flushes.
   * The daemon passes a small `setTimeout`; a test passes something it can run
   * on demand.
   */
  schedule: (fn: () => void) => void
}

/**
 * One argument, safe inside single quotes — the same quoting `ServerScripts`
 * uses on the SSH side, so a home directory with a space in it does not break
 * the re-launch.
 */
function quote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`
}

/**
 * The detached shell that re-launches a directly-started host once this one has
 * let go. It waits on the pid rather than sleeping a fixed time, because the
 * thing it is waiting for — the pid lock being released — is exactly what a new
 * host checks before it agrees to start.
 */
function relaunchScript(deps: HostLifecycleDeps): string {
  return (
    `while kill -0 ${deps.pid} 2>/dev/null; do sleep 0.3; done; ` +
    `nohup ${quote(deps.execPath)} ${quote(deps.entryPath)} >> ${quote(deps.logPath)} 2>&1 &`
  )
}

/**
 * Build the daemon's own lifecycle seam. See the file header for the reasoning.
 */
export function createHostLifecycle(deps: HostLifecycleDeps): HostLifecycle {
  const managedBy = (): HostManagedBy => (deps.serviceUnitExists() ? 'systemd' : 'direct')

  const status = (): HostControlFacts => ({
    version: deps.version,
    address: deps.address?.() ?? '',
    pid: deps.pid,
    startedAt: deps.startedAt,
    // Never negative, even if a clock moved: a negative uptime is a lie a phone
    // would render as a number.
    uptimeSeconds: Math.max(0, Math.round((deps.now() - deps.startedAt) / 1000)),
    managed: managedBy(),
  })

  const restart = (): string => {
    if (managedBy() === 'systemd') {
      deps.spawnDetached('systemctl', ['--user', 'restart', '--no-block', deps.serviceName])
      return 'Restarting over the relay — systemd stops it and starts it fresh. It drops for a moment and comes back on its own.'
    }
    deps.spawnDetached('sh', ['-c', relaunchScript(deps)])
    deps.schedule(() => deps.shutdown('a restart from the relay'))
    return 'Restarting over the relay. It drops for a moment and comes back on its own.'
  }

  const stop = (): string => {
    // The same clean stop the control socket runs: resolve the shutdown, exit 0.
    // Under a systemd unit with `Restart=on-failure`, a clean exit is not a
    // failure, so it stays down until it is started again — which start does not
    // exist on this wire (a stopped host is not on the relay), so that is over
    // SSH, and the sentence says as much.
    deps.schedule(() => deps.shutdown('a stop from the relay'))
    return 'Stopping over the relay. It will not come back until it is started again from its server page over SSH.'
  }

  return { status, restart, stop }
}
