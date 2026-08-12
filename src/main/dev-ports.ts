import { execFile } from 'node:child_process'
import { createConnection } from 'node:net'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'

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

/**
 * Every port actually being listened on, with the process holding it.
 *
 * Enumerating beats probing a list of "common" ports: a fixed list is a guess
 * about someone else's setup and silently misses anyone serving on 4500 or
 * 9876. `lsof` reports what is actually running, whatever port it chose.
 */
async function listeningPorts(): Promise<DevPort[]> {
  const { stdout } = await run('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN'], { timeout: 5000 })
  const found = new Map<number, DevPort>()

  for (const line of stdout.split('\n').slice(1)) {
    const columns = line.split(/\s+/)
    const command = columns[0]
    const address = columns[8]
    if (!command || !address) continue

    // Only what a browser on this machine can reach: loopback or any-address.
    const match = /(?:^|:)(\d+)$/.exec(address)
    if (!match) continue
    const host = address.slice(0, address.lastIndexOf(':'))
    const local = host === '' || host === '*' || host === '127.0.0.1' || host === '[::1]' || host === '[::]'
    if (!local) continue

    const port = Number(match[1])
    if (!Number.isInteger(port) || port <= 0 || port > 65535) continue
    if (NOT_A_DEV_SERVER.has(command)) continue
    // One row per port: lsof lists IPv4 and IPv6 separately for the same server.
    if (!found.has(port)) found.set(port, { port, process: command, guessed: false })
  }

  return [...found.values()]
}

const FALLBACK_PORTS = [3000, 5173, 8080, 4200, 8000, 5174, 4321, 3001]

/** Used only when `lsof` is unavailable, so the page is never empty by default. */
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
 * A scan spawns `lsof` and measures ~43ms. That is cheap once and wasteful on
 * a loop, so: never polled on a timer, only run when a start page is actually
 * being looked at, answered from cache within CACHE_MS, and any calls that
 * arrive while a scan is in flight wait on that same scan rather than
 * spawning their own. Opening five tabs at once costs one `lsof`, not five.
 */
const CACHE_MS = 4000
let cached: { at: number; ports: DevPort[] } | null = null
let inFlight: Promise<DevPort[]> | null = null

export async function scanDevPorts(force = false): Promise<DevPort[]> {
  if (!force && cached && Date.now() - cached.at < CACHE_MS) return cached.ports
  if (inFlight) return inFlight

  inFlight = runScan()
    .then((ports) => {
      cached = { at: Date.now(), ports }
      return ports
    })
    .finally(() => {
      inFlight = null
    })
  return inFlight
}

async function runScan(): Promise<DevPort[]> {
  let ports: DevPort[]
  try {
    ports = await listeningPorts()
  } catch {
    // No lsof (or it was refused). Fall back to probing, which at least finds
    // a server on a conventional port.
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
