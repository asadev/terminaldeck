/**
 * `demo.mjs` — one visitor, one container, one machine that ends itself.
 *
 * This is the third entry point in the headless build and the only one that can
 * turn on public-host mode. `daemon.ts` is the host somebody installs on their
 * own server; `main.ts` is the command they type at it; this is the process the
 * demo box starts inside a throwaway container when a stranger asks for a
 * machine, and it exists so that the switch in `public-host.ts` is reachable by
 * writing a different program rather than by setting a variable.
 *
 * That distinction is the security argument and it is worth stating flatly: an
 * environment variable can be inherited, set by a systemd drop-in, baked into a
 * base image or typed by mistake, and the thing it would switch on here is
 * "approve any device that redeems a code". A separate entry point cannot be
 * arrived at by accident. `public-host.test.ts` holds that line by asserting
 * that neither the desktop's `index.ts` nor `daemon.ts` reaches this file.
 *
 * ## What it does that `daemon.ts` does not
 *
 *  - Turns on public-host mode, with the config from the environment.
 *  - **Does not restore sessions.** A container that has just been created has
 *    no previous life, and restoring one would mean a stranger inheriting the
 *    last stranger's shell — which is precisely the persistence the one-container
 *    -per-visitor shape exists to make impossible.
 *  - Writes the motd where the container's login shell can read it, so the
 *    sentence a visitor sees comes out of the same object that decided the
 *    policy rather than out of a copy in a Dockerfile that can drift from it.
 *  - Exits when the visitor leaves. Under `docker run --rm` that is the reset:
 *    the filesystem, the trust store, the pairing state and anything they
 *    backgrounded go with the process.
 *
 * ## What it deliberately does not do
 *
 * It does not confine anything, and it does not claim to. `confinementKind()`
 * answers `'none'` on Linux and `CONFINEMENT.md` rule 1 forbids shipping an
 * unmeasured boundary to make a demo look good. The fence around a visitor is
 * the container, plus the bind-mount-and-`setpriv` login shell the *image*
 * installs as `$SHELL` — an ordinary mechanism, measured with `demo/escapes.sh`
 * against the escape table in that file, and living outside the product where it
 * cannot be mistaken for a product feature.
 */

import { mkdirSync, realpathSync, writeFileSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BRAND } from '../shared/brand'
import { logger } from '../main/app-log'
import { currentPlatform } from '../main/platform/host'
import { installPaths, nodePaths, userDataDir } from '../main/platform/paths'
import { serveControl, writeDaemonRecord, controlPaths, type ControlServer } from './control'
import { createHeadlessHost, type HeadlessHost } from './host'
import { PUBLIC_HOST_DEFAULTS, type PublicHostConfig } from './public-host'
import { hostVersion } from './version'

/** The same width as every other bearer secret this app writes. */
const TOKEN_BYTES = 32

/**
 * Where the login shell looks for the sentence to print.
 *
 * Under `/run`, which is a tmpfs the container throws away, because the motd is
 * a fact about this one visitor's machine and has no business surviving it.
 */
export const MOTD_PATH = '/run/terminaldeck-demo/motd'

/**
 * Read the knobs the broker sets, and refuse anything that is not a number.
 *
 * The environment is allowed to shorten these because the broker owns the slot
 * budget and this process owns nothing — but a malformed value silently becoming
 * `NaN` would arm a `setTimeout` that never fires, which is a container that
 * never gives its slot back. So a bad value is the default, loudly.
 */
export function configFromEnv(
  env: NodeJS.ProcessEnv,
  defaults: PublicHostConfig = PUBLIC_HOST_DEFAULTS,
): PublicHostConfig {
  const minutes = (name: string, fallback: number): number => {
    const raw = env[name]
    if (raw === undefined || raw === '') return fallback
    const value = Number(raw)
    if (!Number.isFinite(value) || value <= 0) {
      process.stderr.write(`${name}=${raw} is not a number of minutes; using the default.\n`)
      return fallback
    }
    return value * 60_000
  }
  const playground = env.TERMINALDECK_DEMO_PLAYGROUND
  return {
    playground: playground !== undefined && playground.startsWith('/') ? playground : defaults.playground,
    lifetimeMs: minutes('TERMINALDECK_DEMO_LIFETIME_MINUTES', defaults.lifetimeMs),
    arrivalMs: minutes('TERMINALDECK_DEMO_ARRIVAL_MINUTES', defaults.arrivalMs),
    graceMs: minutes('TERMINALDECK_DEMO_GRACE_MINUTES', defaults.graceMs),
  }
}

export async function main(argv: readonly string[]): Promise<number> {
  installPaths(nodePaths({ appRoot: dirname(fileURLToPath(import.meta.url)) }))

  if (argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(
      `${BRAND.name} PUBLIC DEMO host.\n\n` +
        'This starts a host that approves any device redeeming a code it just minted,\n' +
        'grants it one folder, and ends itself when that device leaves. It is for a\n' +
        'throwaway container and nothing else. On a machine you care about, run\n' +
        `"${BRAND.id}-host" instead.\n`,
    )
    return 0
  }

  const platform = currentPlatform()
  if (platform !== 'linux') {
    // Not a portability gap to fix later. The whole safety argument is a
    // container that is destroyed afterwards, and this refusing to run anywhere
    // that is not one is the cheapest way to keep somebody from trying it on
    // their laptop "just to see".
    process.stderr.write(
      'The public demo host runs on Linux, inside a container that is thrown away\n' +
        'afterwards. There is no safe way to run it on a machine you own.\n',
    )
    return 1
  }

  const stateDir = userDataDir()
  mkdirSync(stateDir, { recursive: true, mode: 0o700 })

  const config = configFromEnv(process.env)

  /*
   * Both are `let` and both are read by a closure that runs later.
   *
   * The policy can decide to end this host before `openControl` has returned —
   * the arrival deadline is armed inside `createHeadlessHost`, and a container
   * that is being torn down while it starts is a real case on a box under load.
   * `null` is a value that closure can survive; a `const` declared further down
   * would be a ReferenceError instead.
   */
  let host: HeadlessHost | null = null
  let control: ControlServer | null = null

  /*
   * The readiness line, and why it waits for the relay rather than for itself.
   *
   * The broker reads this off the container's stdout and then asks it for a
   * pairing code. The first version printed as soon as the control socket was
   * listening, and the first real allocation over the public endpoint failed
   * with *"this host is not on the relay (no relay at all), so a code could not
   * be looked up"* — `machines:code` refuses when nothing is dialling, and it is
   * right to, because a code nobody can look up is a code that fails after
   * somebody has typed it.
   *
   * So the signal is the relay's own connect event. Not a loop asking whether it
   * is up yet: `onRelayState` fires once, when it happens, which is the rule this
   * repository keeps everywhere else.
   */
  let announced = false
  const announce = (): void => {
    if (announced) return
    announced = true
    process.stdout.write(
      `${BRAND.name} demo host ${hostVersion()} — pid ${process.pid}, on the relay\n` +
        `  ${host?.publicHost?.sentence() ?? ''}\n`,
    )
  }

  host = await createHeadlessHost({
    storageDir: stateDir,
    onRelayState: (relay) => {
      if (relay.connected) announce()
    },
    publicHost: {
      config,
      end: (reason) => {
        // Asked, not forced. `stop()` kills the sessions, drains their exits and
        // closes the relay link, and a `process.exit` here would cut all of that
        // off mid-write — on a container that is about to be deleted it would
        // not matter, and on the day somebody runs this somewhere else it would
        // matter a great deal.
        stopEverything(host, control, reason).then(
          () => {
            process.exitCode = 0
          },
          () => {
            process.exitCode = 1
          },
        )
      },
    },
  })

  /*
   * The motd, written by the thing that decided it.
   *
   * The image's login shell prints this file and then execs `bash`. Keeping the
   * text here rather than in the Dockerfile means the sentence a visitor reads
   * about auto-approval, the twenty-minute limit and the firewalled egress
   * cannot drift away from the policy that implements them: they are the same
   * object.
   */
  try {
    mkdirSync(dirname(MOTD_PATH), { recursive: true, mode: 0o755 })
    writeFileSync(MOTD_PATH, host.publicHost?.motd() ?? '', 'utf8')
  } catch (error) {
    // Not fatal. A visitor with no motd sees a working shell and misses a
    // paragraph; a demo that refused to start because it could not write a
    // greeting would be a rejection over a text file.
    logger.warn('public-host', 'could not write the motd', {
      error: error instanceof Error ? error.message : String(error),
    })
  }

  /*
   * `demo:link` — the six digits a reviewer types into a phone.
   *
   * It used to answer with a `terminaldeck://pair?…` link as well, built by
   * `relayPairingLink` so that the broker did not have to spell the format out a
   * second time. There is no link any more, and no QR: pairing everywhere is now
   * six digits from `shared/short-code.ts` typed into a numeric keypad, and the
   * address behind them is looked up at the rendezvous slot the code names.
   *
   * The command keeps its name. It is a control-socket verb the deployed broker
   * image already calls by that string, and renaming it would break a running
   * demo box to fix a word. The `link` field is simply gone; `code` was always
   * there beside it and is what the broker prints.
   *
   * Nothing is minted here that `terminaldeck pair` does not mint. `machines:code`
   * is the same channel, on the same desk, publishing the same rendezvous beacon
   * for the same sixty seconds — which matters more than it used to, because the
   * beacon is now the only way a typed code finds this container at all.
   */
  host.desk.handle('demo:link', async () => {
    const relay = (await host?.status())?.remote.relay ?? null
    if (relay === null || !relay.connected) {
      return { ok: false, message: `not on the relay: ${relay?.reason ?? 'no relay at all'}` }
    }
    const offer = (await host?.invoke('machines:code')) as
      | { ok: true; code: { token: string; expiresAt: number } }
      | { ok: false; message: string }
    if (!offer.ok) return { ok: false, message: offer.message }

    return {
      ok: true,
      code: offer.code.token,
      expiresAt: offer.code.expiresAt,
      relay: relay.url,
      hostId: relay.hostId,
      fingerprint: relay.fingerprint,
    }
  })

  control = await openControl(stateDir, host)

  logger.info('public-host', 'demo host started', { pid: process.pid, stateDir, config })
  // Nothing is printed to stdout here. The line the broker is waiting for is
  // written by `announce`, from the relay's connect event, because a container
  // that is running and unreachable is worse than one that has not started: the
  // broker would hand it to a visitor and the pairing could never complete.

  await new Promise<void>((done) => {
    process.once('SIGINT', () => {
      void stopEverything(host, control, 'SIGINT').then(done, done)
    })
    process.once('SIGTERM', () => {
      // The signal `docker stop` sends. A container that ignored it would be
      // killed nine seconds later with its sessions half-written.
      void stopEverything(host, control, 'SIGTERM').then(done, done)
    })
    process.once('beforeExit', () => done())
  })

  return 0
}

/**
 * Stop once, whatever asked — a signal, a deadline, or the visitor leaving.
 *
 * Three things can race here and two of them are ordinary: the twenty-minute cap
 * and `docker stop` regularly arrive together, because the broker reaps the
 * container the moment it decides the slot is over. A second teardown would kill
 * ptys that are already dead and close a socket that is already closed.
 */
let stopping: Promise<void> | null = null
async function stopEverything(
  host: HeadlessHost | null,
  control: ControlServer | null,
  reason: string,
): Promise<void> {
  if (stopping !== null) return await stopping
  stopping = (async (): Promise<void> => {
    logger.info('public-host', 'stopping', { reason })
    await host?.stop().catch(() => undefined)
    await control?.close().catch(() => undefined)
  })()
  return await stopping
}

/**
 * The control socket, which on this box has exactly one caller: the broker.
 *
 * It is the same socket `terminaldeck status` talks to, with the same 0600 token
 * beside it, and the broker reaches it by being the process that started the
 * container and can therefore read the record. A visitor inside the container
 * cannot: they are a different uid, in a home the login shell has bound a tmpfs
 * over, and `demo/escapes.sh` is the measurement of that claim rather than the
 * assertion of it.
 */
async function openControl(stateDir: string, host: HeadlessHost): Promise<ControlServer> {
  const { socket } = controlPaths(stateDir, 'linux')
  const token = randomBytes(TOKEN_BYTES).toString('base64url')

  const control = await serveControl({
    socket,
    token,
    platform: 'linux',
    handle: async (cmd, args) => {
      const decoded = args.map((arg): unknown => JSON.parse(arg))
      if (cmd === 'status') return await host.status()
      return await host.invoke(cmd, ...decoded)
    },
  })

  writeDaemonRecord(stateDir, {
    pid: process.pid,
    socket,
    token,
    startedAt: Date.now(),
    version: hostVersion(),
  })

  return control
}

/** Same guard, same reason, as `daemon.ts` and `main.ts`. */
function invokedDirectly(): boolean {
  const argv = process.argv[1]
  if (argv === undefined) return false
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(argv)
  } catch {
    return false
  }
}

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
