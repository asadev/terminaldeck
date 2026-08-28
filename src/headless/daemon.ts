/**
 * `terminaldeck-host` — the process that is the machine.
 *
 * Two bins rather than one, and the split is what each is for. `terminaldeck` is
 * the four commands a person types; this is the thing a service manager starts
 * and never types anything at. Putting the daemon behind a fifth CLI verb would
 * have made the systemd unit run a command that exists for humans, and would
 * have made `--help` list something no human should run.
 *
 * ## What starting this does, in order, and why the order is that
 *
 *  1. Say which shell this is (`installPaths`), because everything below asks
 *     where the files are and `platform/paths.ts` deliberately has no default.
 *  2. Be the only host for one state directory — taking it over from a host
 *     still running here if there is one. Two processes with one relay identity
 *     is two hosts claiming the same slot at the rendezvous, and they knock each
 *     other off it on every reconnect, so a phone attaches and drops every few
 *     seconds with no error anywhere. See `host-eviction.ts`.
 *  3. Build the core and the remote endpoint, which dials the relay on its own.
 *  4. **Restore the sessions that were open**, from launching rather than from a
 *     command. This is the bug class this repository cares most about, and it is
 *     not academic here: WSL shuts a distribution down when the last terminal
 *     closes, so "it came back and everything was gone" is the ordinary case for
 *     this build, not the crash case.
 *  5. Open the control socket and write the record, last. A record that existed
 *     before the host could answer would make `terminaldeck status` hang on a
 *     socket nobody is listening to.
 */

import { existsSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BRAND } from '../shared/brand'
import { logger } from '../main/app-log'
import { currentPlatform } from '../main/platform/host'
import { installPaths, nodePaths, userDataDir } from '../main/platform/paths'
import { describeReachability, readHostFacts, HOST_COMMAND, SERVICE_NAME } from '../main/reachability'
import {
  clearDaemonRecord,
  controlPaths,
  processAlive,
  readDaemonRecord,
  serveControl,
  writeDaemonRecord,
  type ControlServer,
} from './control'
import { createHeadlessHost, type HeadlessHost } from './host'
import { createHostLifecycle } from './host-lifecycle'
import { cmdlineIsOurHost, evictStaleHost } from './host-eviction'
import { hostVersion } from './version'

const platform = currentPlatform()

/**
 * How much of an argument the token is: 32 bytes, base64url.
 *
 * The same width as everything else this app treats as a bearer secret. It sits
 * in a 0600 file beside a Unix socket, so guessing it is already the second
 * barrier rather than the first — but a short one would make the second barrier
 * decorative, which is the kind of thing that is true for years before it is
 * noticed.
 */
const TOKEN_BYTES = 32

export async function main(argv: readonly string[]): Promise<number> {
  installPaths(nodePaths({ appRoot: dirname(fileURLToPath(import.meta.url)) }))

  if (argv.includes('--install-service')) return installService()
  if (argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(
      `${BRAND.name} host — the background process. Start it with no arguments.\n\n` +
        `  ${HOST_COMMAND}                     run in the foreground\n` +
        `  ${HOST_COMMAND} --install-service   write a systemd user unit for it\n\n` +
        `Everything a person does to a running host is done with "${BRAND.id}".\n`,
    )
    return 0
  }

  /*
   * Windows is not a supported host for this build, and saying so is better than
   * half-running.
   *
   * The headless build exists for WSL and for Linux servers. Inside WSL this
   * process is Linux and everything here applies; on Windows itself the desktop
   * build is already the host, and it does the two things this cannot — hold a
   * wake lock, and route a session across the WSL boundary using a distribution
   * the user picked in a window. A host that started here anyway would be a
   * second machine on the relay with the same name and half the abilities.
   */
  if (platform === 'win32') {
    process.stderr.write(
      `The ${BRAND.name} host has no Windows build. On Windows, run the desktop app — it is\n` +
        'the host, and it can start sessions inside WSL for you. Inside a WSL distribution,\n' +
        'run this from the Linux side instead.\n',
    )
    return 1
  }

  const stateDir = userDataDir()
  const existing = readDaemonRecord(stateDir)
  if (existing !== null && existing.pid !== process.pid && processAlive(existing.pid)) {
    // A host is recorded here and still alive. The restart and update paths end
    // the old host before this one starts, so normally the record names a dead
    // pid and this is skipped; reaching it means a host is running that this
    // start was not coordinated with. The one that bites is a host started
    // outside systemd that reparented to init — it keeps this machine's relay
    // identity, and two hosts on one identity knock each other off the relay's
    // single slot, so a phone connects and drops every few seconds forever.
    // Refusing (the old behaviour) left that host running with no way for a
    // restart to clear it, so take the directory over instead. See
    // `host-eviction.ts` for why SIGTERM here is safe even for a systemd host.
    const outcome = await evictStaleHost(existing.pid, {
      alive: processAlive,
      isOurHost: cmdlineIsOurHost,
      signal: (pid, sig) => process.kill(pid, sig),
      wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref()),
    })
    if (outcome === 'not-ours') {
      logger.info('headless', 'stale host record names a reused pid; leaving it', {
        pid: existing.pid,
      })
    } else {
      logger.info('headless', 'took over a running host', { pid: existing.pid, outcome })
      process.stderr.write(
        `Took over from a ${BRAND.name} host that was still running as pid ${existing.pid}.\n`,
      )
    }
  }
  // Nothing live holds this directory now — safe to take the socket file from a
  // host that died (or that we just ended) without cleaning up.
  clearDaemonRecord(stateDir, platform)

  mkdirSync(stateDir, { recursive: true, mode: 0o700 })

  /*
   * The host's own lifecycle, over the relay — "the relay is the network".
   *
   * Built here, in the one process that owns this host's `shutdown` and knows
   * how it is supervised, and handed to the endpoint the same way `hostGitHub`
   * is. Its mere presence advertises the `host.control` capability, so a phone
   * whose SSH address is an offline Tailscale name still sees the host's status
   * and can restart/stop it as long as the machine is on the relay. See
   * `host-lifecycle.ts`.
   */
  const daemonStartedAt = Date.now()
  const hostLifecycle = createHostLifecycle({
    shutdown,
    now: Date.now,
    startedAt: daemonStartedAt,
    pid: process.pid,
    version: hostVersion(),
    serviceName: SERVICE_NAME,
    serviceUnitExists: () => existsSync(join(configHome(), 'systemd', 'user', SERVICE_NAME)),
    execPath: process.execPath,
    entryPath: fileURLToPath(import.meta.url),
    logPath: join(stateDir, 'host-stderr.log'),
    spawnDetached,
    // A small delay so the `host.state` reply flushes before the restart/stop
    // drops the connection it travelled on.
    schedule: (fn) => {
      setTimeout(fn, 50).unref()
    },
  })

  const host = await createHeadlessHost({
    storageDir: stateDir,
    webRoot: webRootBesideBundle(),
    hostLifecycle,
  })
  await host.restore()

  /*
   * A host nobody can talk to is not a host, so a control socket that will not
   * open takes the whole process down with it.
   *
   * Without this the first real run stayed alive with one line of syscall on
   * stderr: the endpoint was dialling, the sessions were restored, and there was
   * no way to pair, ask its status or stop it. Half-running is the worst of the
   * three outcomes — a service manager sees a healthy process and a person sees
   * a machine that cannot be reached and cannot be fixed.
   */
  let control: ControlServer
  try {
    control = await openControl(stateDir, host)
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    await host.stop()
    clearDaemonRecord(stateDir, platform)
    return 1
  }

  logger.info('headless', 'host started', {
    pid: process.pid,
    stateDir,
    version: hostVersion(),
  })
  announce(stateDir)

  await waitForShutdown(host, control, stateDir)
  return 0
}

/* ---------------------------------------------------------------- control -- */

async function openControl(stateDir: string, host: HeadlessHost): Promise<ControlServer> {
  const { socket } = controlPaths(stateDir, platform)
  const token = randomBytes(TOKEN_BYTES).toString('base64url')

  const control = await serveControl({
    socket,
    token,
    platform,
    handle: async (cmd, args) => {
      /*
       * Every argument arrives as JSON, including the plainly-string ones. The
       * client encodes them all the same way for the same reason this decodes
       * them all the same way: a rule that told strings from structures by
       * looking at the value would be wrong for a folder named `null`.
       */
      const decoded = args.map((arg): unknown => JSON.parse(arg))

      if (cmd === 'status') return await host.status()
      if (cmd === 'stop') {
        // Answered before the shutdown runs, not after. Stopping closes this
        // socket, so a reply written afterwards would never arrive and the
        // caller would report a host that "did not answer" for a stop that
        // worked perfectly.
        queueMicrotask(() => {
          shutdown('a stop command')
        })
        return { stopping: true }
      }
      // Everything else is a channel — the same handler the desktop's renderer
      // would have invoked, called in-process. See `desk.ts`.
      return await host.invoke(cmd, ...decoded)
    },
  })

  // Written last, and only once the socket is listening: a record that named a
  // host before it could answer would make every command hang.
  writeDaemonRecord(stateDir, {
    pid: process.pid,
    socket,
    token,
    startedAt: Date.now(),
    version: hostVersion(),
  })

  return control
}

/* --------------------------------------------------------------- shutdown -- */

let shuttingDown: ((reason: string) => void) | null = null

function shutdown(reason: string): void {
  shuttingDown?.(reason)
}

/**
 * Hold the process open until something asks it to stop, then stop once.
 *
 * `once` on each signal rather than `on`, and a single resolve, because a second
 * Ctrl-C while the first teardown is running would otherwise start a second one
 * — killing the ptys twice and closing a socket that is already closed, which
 * turns a clean stop into a stack trace on the way out.
 */
async function waitForShutdown(
  host: HeadlessHost,
  control: ControlServer,
  stateDir: string,
): Promise<void> {
  const reason = await new Promise<string>((resolve) => {
    let done = false
    const once = (value: string): void => {
      if (done) return
      done = true
      resolve(value)
    }
    shuttingDown = once
    process.once('SIGINT', () => once('SIGINT'))
    process.once('SIGTERM', () => once('SIGTERM'))
    // systemd sends SIGHUP to a user service when the session it belongs to
    // ends. Without linger that is exactly the case this build warns about, so
    // it is treated as a stop rather than ignored — a host half-killed by a
    // signal it did not handle is a host whose sessions are gone and whose
    // record still says it is running.
    process.once('SIGHUP', () => once('SIGHUP'))
  })

  logger.info('headless', 'stopping', { reason })
  await host.stop()
  await control.close()
  clearDaemonRecord(stateDir, platform)
}

/* ---------------------------------------------------------------- service -- */

/**
 * Write a systemd **user** unit, and then say what to run.
 *
 * User rather than system, deliberately. This host starts sessions as the person
 * who owns the code, reads their agent CLI's login out of their home directory
 * and answers git as them; a system unit would either run as root or need a
 * `User=` line that makes all of that a lie in a subtler way. The cost is
 * `loginctl enable-linger`, which is named in the steps and in `status`.
 *
 * It writes the unit and stops. Enabling a service on somebody's behalf is a
 * decision about their machine, and the two commands that follow are printed so
 * they are made rather than discovered.
 */
function installService(): number {
  if (platform !== 'linux') {
    const advice = describeReachability(readHostFacts(platform))
    process.stderr.write(
      `There is no systemd on this ${platform === 'darwin' ? 'Mac' : 'machine'}.\n${advice.headline}\n`,
    )
    return 1
  }

  const dir = join(configHome(), 'systemd', 'user')
  const unitPath = join(dir, SERVICE_NAME)
  const entry = fileURLToPath(import.meta.url)

  const unit = [
    '[Unit]',
    `Description=${BRAND.name} host`,
    'Documentation=https://terminaldeck.dev',
    // Not `network.target`: that is up before an address exists, and a relay
    // dial at that moment fails and then waits out its own backoff — a host that
    // is unreachable for the first minute of every boot for no reason.
    'After=network-online.target',
    'Wants=network-online.target',
    '',
    '[Service]',
    'Type=simple',
    `ExecStart=${process.execPath} ${entry}`,
    // The host stops cleanly on SIGTERM and takes its sessions with it. Ten
    // seconds is longer than that ever needs and short enough that a wedged one
    // does not hold up a reboot.
    'TimeoutStopSec=10',
    'Restart=on-failure',
    'RestartSec=5',
    `Environment=TERMINALDECK_VERSION=${hostVersion()}`,
    '',
    '[Install]',
    'WantedBy=default.target',
    '',
  ].join('\n')

  try {
    mkdirSync(dir, { recursive: true })
    writeFileSync(unitPath, unit, 'utf8')
  } catch (error) {
    process.stderr.write(
      `Could not write ${unitPath}: ${error instanceof Error ? error.message : String(error)}\n`,
    )
    return 1
  }

  const facts = readHostFacts(platform)
  process.stdout.write(
    `Wrote ${unitPath}\n\n` +
      'Now run:\n' +
      `  systemctl --user daemon-reload\n` +
      `  systemctl --user enable --now ${SERVICE_NAME}\n` +
      `  sudo loginctl enable-linger ${facts.user ?? '<your user>'}\n\n` +
      'The last one is what keeps it running when you are not logged in. Without it\n' +
      'the host stops with your last shell, which looks exactly like the app being\n' +
      `broken from a phone. "${BRAND.id} status" says what else this machine needs.\n`,
  )
  return 0
}

function configHome(): string {
  const xdg = process.env.XDG_CONFIG_HOME
  return xdg !== undefined && xdg.startsWith('/') ? xdg : join(homedir(), '.config')
}

/**
 * Spawn a detached, unref'd child and forget it — the seam the relay lifecycle
 * uses to hand a restart to `systemctl` or a re-launch to `sh`.
 *
 * Detached and `unref`'d so it outlives the restart that is about to end this
 * process; `stdio: 'ignore'` because nothing here reads it, and its own output
 * (for the re-launch) is redirected to a log inside the shell command. A spawn
 * that cannot even start is logged rather than thrown — this runs on the data
 * path of a relay frame, and a throw there would take the connection down.
 */
function spawnDetached(command: string, args: readonly string[]): void {
  try {
    const child = spawn(command, [...args], { detached: true, stdio: 'ignore' })
    child.on('error', (error) => {
      logger.error('headless', 'a lifecycle command could not be spawned', {
        command,
        error: error instanceof Error ? error.message : String(error),
      })
    })
    child.unref()
  } catch (error) {
    logger.error('headless', 'a lifecycle command threw on spawn', {
      command,
      error: error instanceof Error ? error.message : String(error),
    })
  }
}

/* ---------------------------------------------------------------- startup -- */

/**
 * The one thing printed on a successful start, for somebody watching it in a
 * terminal — and the reachability warning, which is the whole reason this is
 * printed rather than only logged.
 */
function announce(stateDir: string): void {
  const advice = describeReachability(readHostFacts(platform))
  const lines = [`${BRAND.name} host ${hostVersion()} — running as pid ${process.pid}`, `  state  ${stateDir}`]
  if (advice.atRisk) {
    lines.push('')
    lines.push(`  ${advice.headline}`)
    lines.push(`  Run "${BRAND.id} status" for what to do about it.`)
  }
  lines.push('')
  process.stdout.write(`${lines.join('\n')}\n`)
}

/**
 * The web client, if this install shipped one.
 *
 * A server install usually will not: the native clients come in through the
 * relay and never ask for a file, so `pwa/dist` is worth its size only on a
 * machine somebody browses to over a tailnet. An empty answer is not a failure —
 * `server.ts` simply serves no static files.
 */
function webRootBesideBundle(): string {
  const here = dirname(fileURLToPath(import.meta.url))
  for (const candidate of [join(here, 'pwa'), join(here, '..', 'pwa', 'dist')]) {
    if (existsSync(candidate)) return candidate
  }
  return ''
}

/**
 * True when this file is the program rather than something a test imported.
 *
 * `realpathSync` on both sides, and it is not belt-and-braces: npm installs a
 * bin as a **symlink** into `node_modules/.bin` (or `~/.local/bin`), so
 * `process.argv[1]` is the link and `import.meta.url` is the file it points at.
 * Comparing them raw meant the CLI silently did nothing when it was installed —
 * exactly the way a person first runs it — while working perfectly from a
 * checkout.
 */
function invokedDirectly(): boolean {
  const argv = process.argv[1]
  if (argv === undefined) return false
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(argv)
  } catch {
    return false
  }
}

/*
 * Run when this file is the program, and not when a test imports it. Same guard
 * and same reason as `main.ts`.
 */
if (invokedDirectly()) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code
    },
    (error: unknown) => {
      process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
      process.exitCode = 1
    },
  )
}
