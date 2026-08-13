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
 */
async function listeningPorts(platform: Platform): Promise<DevPort[]> {
  const found = new Map<number, DevPort>()

  for (const owner of await listeningOwners(platform)) {
    if (owner.process !== null && NOT_A_DEV_SERVER.has(owner.process)) continue
    if (found.has(owner.port)) continue
    found.set(owner.port, {
      port: owner.port,
      // A port whose owner could not be named still answers; saying "unknown"
      // and flagging it beats either inventing a name or hiding the port.
      process: owner.process ?? 'unknown',
      guessed: owner.process === null,
    })
  }

  return [...found.values()]
}

const FALLBACK_PORTS = [3000, 5173, 8080, 4200, 8000, 5174, 4321, 3001]

/** Used only when the OS scan is unavailable, so the page is never empty by default. */
function probe(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host: '127.0.0.1', port })
    let settled = false
    const done = (live: boolean) => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(live)
    }
    socket.setTimeout(250)
    socket.once('connect', () => done(true))
    socket.once('timeout', () => done(false))
    socket.once('error', () => done(false))
  })
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
let cached: { at: number; ports: DevPort[] } | null = null
let inFlight: Promise<DevPort[]> | null = null

export async function scanDevPorts(force = false, platform: Platform = currentPlatform()): Promise<DevPort[]> {
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

/** Drops the memo. Exported for tests, which pin one platform per case. */
export function resetDevPortsCache(): void {
  cached = null
}

async function runScan(platform: Platform): Promise<DevPort[]> {
  let ports: DevPort[]
  try {
    ports = await listeningPorts(platform)
  } catch {
    // The scan command is missing or was refused — no `lsof` on a stripped-down
    // Unix, no `netstat.exe` on a locked-down Windows. Fall back to probing,
    // which at least finds a server on a conventional port.
    const probed = await Promise.all(
      FALLBACK_PORTS.map(async (port) => ({ port, live: await probe(port) })),
    )
    ports = probed
      .filter((entry) => entry.live)
      .map((entry) => ({ port: entry.port, process: 'unknown', guessed: true }))
  }

  return ports.sort((a, b) => rank(a) - rank(b) || a.port - b.port)
}

export function registerDevPortsIpc(ipcMain: IpcMain): void {
  // `force` is the Refresh button. Everything else takes the cache.
  ipcMain.handle('dev:ports', (_event, force?: unknown) => scanDevPorts(force === true))
}
