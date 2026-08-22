import { spawn } from 'node:child_process'
import type { Readable, Writable } from 'node:stream'

/**
 * Starting the standalone Chromium and handing back its two CDP pipe streams —
 * the process, and nothing above it.
 *
 * ## The launch, decided
 *
 * `chrome --headless=new --remote-debugging-pipe --user-data-dir=<profile>
 * --no-first-run --no-default-browser-check --disable-gpu`, plus
 * `--load-extension=<dirs> --disable-extensions-except=<dirs>` when a profile
 * carries extensions.
 *
 * Each of those flags is load-bearing:
 *
 *  - **`--headless=new`** is the full-Chromium headless mode, not the old
 *    `--headless` and not chrome-headless-shell. It is *mandatory* here because
 *    `--load-extension` is ignored under the old headless and under the shell —
 *    the whole reason `browser-chromium-install.ts` fetches the full `chrome`.
 *  - **`--remote-debugging-pipe`** makes the child inherit fd **3** (the host
 *    writes CDP commands) and fd **4** (the host reads results and events) as an
 *    anonymous inherited pipe pair. There is no port and no socket — nothing to
 *    scan, nothing a second local user can connect to. That preserves the
 *    no-socket invariant `DRIVABLE-BROWSER.md` §2.1 states in as many words:
 *    Chromium's DevTools endpoint has no authentication, so a listening port is
 *    a door this product may not open. A pipe is not a door.
 *  - **`--disable-extensions-except`** alongside `--load-extension` is what keeps
 *    a headless profile to exactly the extensions this app unpacked and verified
 *    — nothing carried over, nothing else loaded.
 *
 * ## What this file does *not* do
 *
 * It does not speak CDP. The wire framing on fds 3/4 is NUL-delimited JSON, and
 * the codec for it is Lane B's `browser-cdp-pipe.ts`. This file's whole job is to
 * spawn the process with the right stdio and hand the two raw streams out
 * cleanly, so it exposes `stdio[3]` as {@link ChromiumHandle.pipeWrite} and
 * `stdio[4]` as {@link ChromiumHandle.pipeRead} and stops there.
 *
 * `stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe']` is why those two fds are
 * the CDP channel: index 0 is closed, 1 and 2 are the browser's own logging, and
 * 3 and 4 are the pipe pair Chromium's `--remote-debugging-pipe` inherits.
 *
 * ## Nothing here reaches Electron
 *
 * `node:child_process` and `node:stream` only — this module is in the headless
 * closure `seam.test.ts` walks. `spawn` is a seam so a test can model a child
 * without starting a process, and a spawn failure or an immediate exit comes
 * back as a named error rather than a crash, mirroring how `agent-binaries.ts`
 * refuses to open a session it cannot prove will run.
 */

/* ----------------------------------------------------------------- flags -- */

export interface FlagOptions {
  /** The profile directory Chromium keeps its state in. */
  userDataDir: string
  /** Unpacked extension directories to load, or none. */
  extensionDirs?: readonly string[]
  /** Anything else the caller needs appended, verbatim. */
  extraFlags?: readonly string[]
}

/**
 * The exact flag list, in order.
 *
 * A pure function of its options so `browser-chromium-launch.test.ts` can pin the
 * composition — with extensions and without — on any machine, the same argument
 * `cli.ts` makes about output being a function of its input.
 */
export function chromiumFlags(options: FlagOptions): string[] {
  const flags = [
    '--headless=new',
    '--remote-debugging-pipe',
    `--user-data-dir=${options.userDataDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-gpu',
  ]
  const dirs = options.extensionDirs ?? []
  if (dirs.length > 0) {
    const joined = dirs.join(',')
    flags.push(`--load-extension=${joined}`)
    flags.push(`--disable-extensions-except=${joined}`)
  }
  if (options.extraFlags !== undefined) flags.push(...options.extraFlags)
  return flags
}

/* ----------------------------------------------------------------- spawn -- */

/**
 * The stdio shape that makes fds 3 and 4 the CDP pipe channel.
 *
 * 0 ignored, 1 and 2 the browser's logging, 3 the host's write pipe, 4 the
 * host's read pipe. Exported so a test can assert the shape the way production
 * spawns with it.
 */
export const CHROMIUM_STDIO = ['ignore', 'pipe', 'pipe', 'pipe', 'pipe'] as const

/** The slice of a spawned child this module uses. The real `ChildProcess` fits. */
export interface SpawnedChild {
  pid?: number
  exitCode: number | null
  stdio: ReadonlyArray<Readable | Writable | null | undefined>
  kill(signal?: NodeJS.Signals | number): boolean
}

export interface SpawnOptions {
  stdio: readonly ('ignore' | 'pipe')[]
  env?: NodeJS.ProcessEnv
  windowsHide?: boolean
}

export type SpawnFn = (command: string, args: readonly string[], options: SpawnOptions) => SpawnedChild

const defaultSpawn: SpawnFn = (command, args, options) =>
  spawn(command, [...args], {
    stdio: [...options.stdio],
    env: options.env,
    windowsHide: options.windowsHide,
  })

/* ---------------------------------------------------------------- handle -- */

export interface ChromiumHandle {
  pid: number
  /** fd 3 — the host writes CDP commands here. Raw; framing is Lane B's. */
  pipeWrite: Writable
  /** fd 4 — the host reads results and events here. Raw; framing is Lane B's. */
  pipeRead: Readable
  /** Stop the browser. */
  close(): void
}

export type LaunchResult = { ok: true; handle: ChromiumHandle } | { ok: false; why: string }

export interface LaunchOptions extends FlagOptions {
  /** The `chrome` executable, as returned by `installChromium`. */
  executablePath: string
  /** The environment to spawn under. Defaults to `process.env`. */
  env?: NodeJS.ProcessEnv
  /** Test seam. Production uses `node:child_process`'s `spawn`. */
  spawn?: SpawnFn
}

/**
 * Spawn Chromium with the CDP pipe stdio and return its two fd streams, or a
 * named error.
 *
 * Three failures are caught rather than left to surface later as an unhandled
 * event or a hang: a `spawn` that throws, a child that came back with no pid
 * (the ordinary "the executable is not there" case — `spawn` reports it
 * asynchronously, but a missing pid is synchronous), and a child that has
 * already exited before this function returned. A child that spawned but has no
 * pipe on fd 3 or fd 4 is also refused, because a CDP channel that is not there
 * is not a browser anyone can drive.
 */
export function launchChromium(options: LaunchOptions): LaunchResult {
  const spawnFn = options.spawn ?? defaultSpawn
  const args = chromiumFlags(options)

  let child: SpawnedChild
  try {
    child = spawnFn(options.executablePath, args, {
      stdio: [...CHROMIUM_STDIO],
      env: options.env ?? process.env,
      windowsHide: true,
    })
  } catch (error) {
    return {
      ok: false,
      why: `Chromium did not start: ${error instanceof Error ? error.message : 'spawn failed'}`,
    }
  }

  if (child.pid === undefined || child.pid === null) {
    return { ok: false, why: `Chromium did not start: ${options.executablePath} could not be spawned` }
  }
  if (child.exitCode !== null) {
    return { ok: false, why: `Chromium exited immediately with code ${child.exitCode}` }
  }

  const pipeWrite = child.stdio[3]
  const pipeRead = child.stdio[4]
  if (pipeWrite === null || pipeWrite === undefined || pipeRead === null || pipeRead === undefined) {
    return {
      ok: false,
      why: 'Chromium started without the fd 3/4 pipe channel; the stdio must be ignore,pipe,pipe,pipe,pipe',
    }
  }

  return {
    ok: true,
    handle: {
      pid: child.pid,
      pipeWrite: pipeWrite as Writable,
      pipeRead: pipeRead as Readable,
      close: () => {
        try {
          child.kill()
        } catch {
          /* Already gone; nothing to stop. */
        }
      },
    },
  }
}
