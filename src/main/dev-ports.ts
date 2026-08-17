import { execFile } from 'node:child_process'
import { createConnection } from 'node:net'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import { BRAND } from '../shared/brand'
import { currentPlatform, isWindows, type Platform } from './platform/host'
import {
  LSOF,
  LSOF_FIELDS,
  NETSTAT,
  TASKLIST,
  parseLsof,
  parseLsofFields,
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
  /**
   * This port is Terminal Deck's own, so it is not a page anybody can open.
   *
   * The recording of 2026-08-16 is the whole reason this field exists. Eight of
   * the nine ports the start page offered were this app's — every one of them
   * labelled `Terminal`, because `lsof`'s column output clamps COMMAND to nine
   * characters and `Terminal Deck` does not fit. Clicking one loaded the
   * pairing server's refusal for a plain GET: a black page reading
   * *"that is not how to ask"*, shown to a user who had done nothing wrong.
   *
   * Marked rather than dropped, because a port that is listening is a true fact
   * about the machine and silently removing rows makes a list nobody can
   * reconcile with `lsof`. What must not happen is *offering it as a page*, and
   * that is the start page's job — see `StartPage.tsx`.
   */
  ours: boolean
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

/**
 * Is this process Terminal Deck?
 *
 * Two independent tests, because they catch different things and neither
 * catches both.
 *
 * The **pid test** is exact and answers for the process actually running this
 * code: `pid` is our own, or `ppid` is — Electron's renderer, GPU and utility
 * processes are direct children of the main process, and any of them can hold a
 * socket. It is the only test that works in development, where the executable
 * is called `Electron` and matching that name would claim every Electron app on
 * the machine.
 *
 * The **name test** catches a *second copy* of Terminal Deck, which the pid test
 * cannot see and which produces exactly the same dead click. `lsof`'s field mode
 * prints the untruncated command, so this compares against the real product
 * name rather than the nine characters the column output would have left. The
 * ` ` suffix case is the packaged helpers, which macOS names
 * `Terminal Deck Helper (Renderer)` and friends.
 */
function isOurs(owner: { process: string | null; pid?: number; ppid?: number }): boolean {
  if (owner.pid === process.pid || owner.ppid === process.pid) return true
  const name = owner.process
  if (name === null) return false
  return name === BRAND.name || name.startsWith(`${BRAND.name} `)
}

/** Drop the fields the phone must not be sent. */
function toWire(detail: DevPortDetail): DevPort {
  return {
    port: detail.port,
    process: detail.process,
    guessed: detail.guessed,
    ours: detail.ours,
  }
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

/**
 * Does the exclusion list above cover this process, under any of the spellings
 * the operating system might have printed?
 *
 * Three, and every one of them is a real spelling seen on this machine:
 *
 *  - the name as printed — `sshd`, `node`;
 *  - the first word of it — field-mode `lsof` prints `Google Chrome` where the
 *    column output printed `Google`, and the list was written against the
 *    column output;
 *  - the first nine characters — the column output's own clamp, which is how
 *    `ControlCenter` came to be listed as `ControlCe`.
 *
 * Checking all three means switching `lsof` to field mode cannot quietly
 * *un-exclude* half the list. It did on the first attempt: Chrome's port 9333
 * reappeared as a suggested dev server the moment the names stopped being
 * truncated.
 */
function isExcluded(name: string): boolean {
  if (NOT_A_DEV_SERVER.has(name)) return true
  const firstWord = name.split(' ')[0]
  if (firstWord !== name && NOT_A_DEV_SERVER.has(firstWord)) return true
  return name.length > 9 && NOT_A_DEV_SERVER.has(name.slice(0, 9))
}

/** Runtimes that usually ARE serving a page, listed before anything else. */
const LIKELY_DEV = ['node', 'bun', 'deno', 'python', 'python3', 'ruby', 'php', 'java', 'dotnet', 'caddy', 'nginx']

function rank(entry: DevPort): number {
  const name = entry.process.toLowerCase()
  const likely = LIKELY_DEV.findIndex((candidate) => name.startsWith(candidate))
  // Our own ports below everything, including the ones nobody could name: they
  // are the only rows on the list that are guaranteed not to be a page.
  if (entry.ours) return 2000
  // Known runtime first (in list order), then everything else, then unnamed.
  if (entry.guessed) return 1000
  return likely === -1 ? 500 : likely
}

const SCAN_TIMEOUT_MS = 5000

/**
 * One listening socket, from whichever form of the scan produced it.
 *
 * `pid` and `ppid` are optional because only two of the three code paths below
 * carry them: field-mode `lsof` has both, `netstat` has the pid, and the
 * column-mode `lsof` fallback has neither. A row with neither simply fails the
 * pid half of {@link isOurs} and is judged by its name, which is the same
 * answer this module gave before the field existed.
 */
type ScannedOwner = PortOwner & { pid?: number; ppid?: number }

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
async function listeningOwners(platform: Platform): Promise<ScannedOwner[]> {
  const options = { timeout: SCAN_TIMEOUT_MS, windowsHide: true } as const

  if (isWindows(platform)) {
    const [connections, processes] = await Promise.all([
      run(NETSTAT.command, NETSTAT.args, options),
      run(TASKLIST.command, TASKLIST.args, options).catch(() => ({ stdout: '' })),
    ])
    const rows = parseNetstat(connections.stdout)
    const names = parseTasklist(processes.stdout)
    // `netstat -ano` already knows the owning pid, so the exact half of the
    // ownership test is free here; there is no parent pid, which is why the
    // name test in `isOurs` matters more on Windows than it does on macOS.
    return windowsOwners(rows, names).map((owner, index) => ({ ...owner, pid: rows[index].pid }))
  }

  // Field mode first — it is the only form that prints the untruncated command
  // and the parent pid, and both are load-bearing. The column form stays as the
  // fallback rather than being deleted: `-F` is old and universal, but this is a
  // spawn of somebody else's binary, and a build of `lsof` that refuses these
  // fields should cost the *names* rather than the whole list.
  const fielded = await run(LSOF_FIELDS.command, LSOF_FIELDS.args, options).catch(() => null)
  if (fielded) {
    const owners = parseLsofFields(fielded.stdout)
    if (owners.length > 0) return owners
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
    // Ours is decided before the exclusion, and survives it. A port this app is
    // holding is worth *saying so about* even when the process behind it would
    // otherwise be filtered out — the alternative is a row that vanishes with no
    // explanation, which is how "why is nothing listening on 8443?" starts.
    const ours = isOurs(owner)
    if (!ours && owner.process !== null && isExcluded(owner.process)) continue
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
      ours,
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
      .map((entry) => ({
        port: entry.port,
        process: 'unknown',
        guessed: true,
        // A probe learns that something answered and nothing else. Claiming a
        // port is ours on that evidence would hide a real dev server, so this
        // path always says no and the row stays offered.
        ours: false,
        families: entry.families,
      }))
  }

  return ports.sort((a, b) => rank(a) - rank(b) || a.port - b.port)
}

export function registerDevPortsIpc(ipcMain: IpcMain): void {
  // `force` is the Refresh button. Everything else takes the cache.
  ipcMain.handle('dev:ports', (_event, force?: unknown) => scanDevPorts(force === true))
}
