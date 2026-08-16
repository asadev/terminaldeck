import { execFile } from 'node:child_process'
import { createConnection } from 'node:net'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import { currentPlatform, isWindows, type Platform } from './platform/host'
import {
  LSOF,
  NETSTAT,
  TASKLIST,
  parseLsof,
  parseNetstat,
  parseTasklist,
  windowsOwners,
  type PortOwner,
} from './platform/ports'

const run = promisify(execFile)

export interface DevPort {
  port: number
  /** The process holding the port, e.g. 'node', 'python3', 'ruby'. */
  process: string
  /** True when we could not name the process and only know the port answers. */
  guessed: boolean
}

/**
 * Which loopbacks a port answers on. At least one is always true.
 *
 * Deliberately two booleans rather than one family: a dual-stack server is two
 * sockets and genuinely answers on both, and a caller that has to pick one
 * needs to know it has a choice. `tunnel.ts` is the only consumer.
 */
export interface PortFamilies {
  v4: boolean
  v6: boolean
}

/**
 * A {@link DevPort} plus the thing the wire deliberately does not carry.
 *
 * `LocalPort` in `remote/protocol.ts` is exactly {@link DevPort} — the phone has
 * no use for an address family, because it never dials the desktop's loopback;
 * it names a port and the desktop dials. So the family rides in this separate
 * type, which stays inside the main process, rather than being added to the
 * message and then having to be explained to three clients.
 */
export interface DevPortDetail extends DevPort {
  families: PortFamilies
}

/** Drop the fields the phone must not be sent. */
function toWire(detail: DevPortDetail): DevPort {
  return { port: detail.port, process: detail.process, guessed: detail.guessed }
}

/**
 * Processes that are almost never something you want to open in a browser.
 * Everything else is offered, because guessing which frameworks a person uses
 * is exactly the assumption this module exists to avoid.
 */
const NOT_A_DEV_SERVER = new Set([
  'rapportd',
  'sshd',
  'launchd',
  'ControlCe',
  'Spotify',
  'Dropbox',
  'iTunes',
  'AirPlay',
  'identityservicesd',
  'remoted',
  'Google',
  'Slack',
  'Postgres',
  'postgres',
  'mysqld',
  'redis-server',
  'mongod',
  'Docker',
  // Windows equivalents. Nothing above ever appears there and nothing here ever
  // appears on macOS, so one list serves both without either platform paying for
  // the other's noise. `System` is PID 4, which holds 135, 445 and 139 on a
  // stock install — three ports offered as dev servers on the very first launch.
  'System',
  'System Idle Process',
  'svchost',
  'services',
  'lsass',
  'wininit',
  'spoolsv',
  'sqlservr',
  'MsMpEng',
  'vmware-hostd',
  'com.docker.backend',
])

/** Runtimes that usually ARE serving a page, listed before anything else. */
const LIKELY_DEV = ['node', 'bun', 'deno', 'python', 'python3', 'ruby', 'php', 'java', 'dotnet', 'caddy', 'nginx']

function rank(entry: DevPort): number {
  const name = entry.process.toLowerCase()
  const likely = LIKELY_DEV.findIndex((candidate) => name.startsWith(candidate))
  // Known runtime first (in list order), then everything else, then unnamed.
  if (entry.guessed) return 1000
  return likely === -1 ? 500 : likely
}

const SCAN_TIMEOUT_MS = 5000

/**
 * Ask the operating system what is listening.
 *
 * `platform/ports.ts` holds the commands and the parsers; this only decides
 * which conversation to have. On Windows that is two calls rather than one:
 * `netstat` knows the ports and the owning PID, `tasklist` turns a PID into a
 * name, and they are issued together because neither depends on the other.
 *
 * A failing `tasklist` does not fail the scan. The ports it could not name are
 * still real, still answering, and still worth offering — they arrive without a
 * name and land on screen as guesses, which is what `guessed` is for.
 */
async function listeningOwners(platform: Platform): Promise<PortOwner[]> {
  const options = { timeout: SCAN_TIMEOUT_MS, windowsHide: true } as const

  if (isWindows(platform)) {
    const [connections, processes] = await Promise.all([
      run(NETSTAT.command, NETSTAT.args, options),
      run(TASKLIST.command, TASKLIST.args, options).catch(() => ({ stdout: '' })),
    ])
    return windowsOwners(parseNetstat(connections.stdout), parseTasklist(processes.stdout))
  }

  const { stdout } = await run(LSOF.command, LSOF.args, options)
  return parseLsof(stdout)
}

/**
 * Every port actually being listened on, with the process holding it.
 *
 * Enumerating beats probing a list of "common" ports: a fixed list is a guess
 * about someone else's setup and silently misses anyone serving on 4500 or
 * 9876. The OS reports what is actually running, whatever port it chose.
 *
 * The filter runs before the de-duplication, and that order is deliberate. Both
 * tools list one row per socket, so the same port appears twice (IPv4 and IPv6);
 * skipping excluded processes first means a port that a background service and a
 * dev server both touch is credited to the dev server rather than dropped.
 *
 * The *name* is taken from the first row that survives the filter and the
 * *families* are the union of every row that does — which is not the same rule
 * twice over, on purpose. There is only one honest answer to "what is holding
 * this port" and picking is unavoidable; there are two honest answers to "where
 * does it answer", and dropping the second one is what left an IPv6-only dev
 * server listed and unreachable on Windows.
 */
async function listeningPorts(platform: Platform): Promise<DevPortDetail[]> {
  const found = new Map<number, DevPortDetail>()

  for (const owner of await listeningOwners(platform)) {
    if (owner.process !== null && NOT_A_DEV_SERVER.has(owner.process)) continue
    const already = found.get(owner.port)
    if (already) {
      if (owner.family === 4) already.families.v4 = true
      else already.families.v6 = true
      continue
    }
    found.set(owner.port, {
      port: owner.port,
      // A port whose owner could not be named still answers; saying "unknown"
      // and flagging it beats either inventing a name or hiding the port.
      process: owner.process ?? 'unknown',
      guessed: owner.process === null,
      families: { v4: owner.family === 4, v6: owner.family === 6 },
    })
  }

  return [...found.values()]
}

const FALLBACK_PORTS = [3000, 5173, 8080, 4200, 8000, 5174, 4321, 3001]

/**
 * How long the fallback probe below waits for a loopback to answer.
 *
 * A quarter of a second is a very long time for a connection that never leaves
 * the machine: a listening socket is accepted by the kernel's backlog with no
 * process involved, and a port nobody holds is refused in microseconds. What
 * the budget is really covering is a loaded machine, not a slow network.
 */
const PROBE_TIMEOUT_MS = 250

/**
 * Connect, then hang up. True when something accepted.
 *
 * ## Why this is exported rather than copied
 *
 * There are two questions about a port and only one of them a scan can answer.
 * `lsof` and `netstat` say a socket is *bound*; they do not say it will *accept*,
 * and `remote/tunnel.ts` documents the measured Windows case where those two
 * answers differed — a port listed as listening that refused every dial. Every
 * feature that has to know a port is genuinely usable therefore ends in a real
 * TCP connection, and there should be exactly one of those in the app.
 *
 * `dev-server.ts` is the second caller. It could not reuse the dial inside
 * `tunnel.ts` because that one is a closure over the hub's injected `connect`
 * seam and cannot leave `createTunnelHub` without rearranging it; this function
 * was already here, doing the identical thing, and exporting it is strictly
 * better than a third socket. It pairs with `loopbackCandidates` from
 * `tunnel.ts`, which is the *other* half of that module's dial and already
 * exported: candidates decide where, this decides whether.
 *
 * `(port, host)` and not `(host, port)` — the order `tunnel.ts` uses for the
 * same pair, because two functions that take the same two values in opposite
 * orders is a bug waiting for the day someone reads one and calls the other.
 *
 * `timeoutMs` is a parameter because the two callers are asking under different
 * pressure. The scan fallback below fires eight of these at once and wants them
 * over quickly; a readiness watcher polls one at a time behind a spinner and can
 * afford to wait a little longer for a machine that is busy building.
 */
export function dialPort(port: number, host: string, timeoutMs = PROBE_TIMEOUT_MS): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host, port })
    let settled = false
    const done = (live: boolean) => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(live)
    }
    socket.setTimeout(timeoutMs)
    socket.once('connect', () => done(true))
    socket.once('timeout', () => done(false))
    socket.once('error', () => done(false))
  })
}

/**
 * Used only when the OS scan is unavailable, so the page is never empty by
 * default.
 *
 * Both loopbacks, not just `127.0.0.1`. This path is reached on a machine with
 * no `lsof` or a locked-down `netstat.exe`, and on Windows that is exactly the
 * machine where the dev server is on `::1` and nowhere else — probing one
 * family would report "nothing is running" to someone whose server is running.
 * The two dials go out together: they are 250 ms apart at worst and there are
 * eight ports in the list.
 */
function probe(host: string, port: number): Promise<boolean> {
  return dialPort(port, host, PROBE_TIMEOUT_MS)
}

async function probeFamilies(port: number): Promise<PortFamilies> {
  const [v4, v6] = await Promise.all([probe('127.0.0.1', port), probe('::1', port)])
  return { v4, v6 }
}

/**
 * Cached, and shared between concurrent callers.
 *
 * A scan spawns `lsof` and measures ~43ms on macOS, and spawns two commands on
 * Windows. That is cheap once and wasteful on a loop, so: never polled on a
 * timer, only run when a start page is actually being looked at, answered from
 * cache within CACHE_MS, and any calls that arrive while a scan is in flight
 * wait on that same scan rather than spawning their own. Opening five tabs at
 * once costs one scan, not five.
 */
const CACHE_MS = 4000
let cached: { at: number; ports: DevPortDetail[] } | null = null
let inFlight: Promise<DevPortDetail[]> | null = null

/**
 * The scan, with the address families the tunnel needs.
 *
 * One cache serves this and {@link scanDevPorts}: they are the same scan asked
 * for at different widths, and running two would mean the list a phone was
 * shown and the list a `tunnel.open` is checked against could disagree.
 */
export async function scanDevPortsDetailed(
  force = false,
  platform: Platform = currentPlatform(),
): Promise<DevPortDetail[]> {
  if (!force && cached && Date.now() - cached.at < CACHE_MS) return cached.ports
  if (inFlight) return inFlight

  inFlight = runScan(platform)
    .then((ports) => {
      cached = { at: Date.now(), ports }
      return ports
    })
    .finally(() => {
      inFlight = null
    })
  return inFlight
}

export async function scanDevPorts(force = false, platform: Platform = currentPlatform()): Promise<DevPort[]> {
  return (await scanDevPortsDetailed(force, platform)).map(toWire)
}

/** Drops the memo. Exported for tests, which pin one platform per case. */
export function resetDevPortsCache(): void {
  cached = null
}

async function runScan(platform: Platform): Promise<DevPortDetail[]> {
  let ports: DevPortDetail[]
  try {
    ports = await listeningPorts(platform)
  } catch {
    // The scan command is missing or was refused — no `lsof` on a stripped-down
    // Unix, no `netstat.exe` on a locked-down Windows. Fall back to probing,
    // which at least finds a server on a conventional port.
    const probed = await Promise.all(
      FALLBACK_PORTS.map(async (port) => ({ port, families: await probeFamilies(port) })),
    )
    ports = probed
      .filter((entry) => entry.families.v4 || entry.families.v6)
      .map((entry) => ({ port: entry.port, process: 'unknown', guessed: true, families: entry.families }))
  }

  return ports.sort((a, b) => rank(a) - rank(b) || a.port - b.port)
}

export function registerDevPortsIpc(ipcMain: IpcMain): void {
  // `force` is the Refresh button. Everything else takes the cache.
  ipcMain.handle('dev:ports', (_event, force?: unknown) => scanDevPorts(force === true))
}
