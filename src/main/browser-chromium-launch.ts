import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'
import type { Readable, Writable } from 'node:stream'
import { currentPlatform, type Platform } from './platform/host'

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
 * `node:*` and the `platform/host.ts` seam only — this module is in the headless
 * closure `seam.test.ts` walks. `spawn` is a seam so a test can model a child
 * without starting a process, and a spawn failure or an immediate exit comes
 * back as a named error rather than a crash, mirroring how `agent-binaries.ts`
 * refuses to open a session it cannot prove will run.
 *
 * ## What a real Linux server taught this file
 *
 * Everything above was unit-green against an injected `spawn` for a milestone
 * before anyone pointed it at a rented box. On the first real one — Ubuntu
 * 24.04, Hetzner, 2026-08-22 — it could not start a browser at all, and the two
 * reasons are now the two things this file does that it did not before.
 *
 *  1. **A pid is not a running browser.** `spawn` returns a child with a pid and
 *     a null `exitCode` even when the executable is about to die on its first
 *     instruction; the exit is delivered on a later tick. Measured: Chromium
 *     with a missing `libatk-1.0.so.0` was reported healthy — pid present, both
 *     pipe fds open — and was gone 30 ms later with exit 127. The caller then
 *     wrote a CDP command into a pipe with nothing on the other end and waited
 *     for an answer that could never come. So the handle now carries
 *     {@link ChromiumHandle.whenGone}, and `browser-headless-host.ts` races the
 *     first protocol command against it: the browser answers, or its death is
 *     the error, and neither outcome is a hang.
 *  2. **Stock Ubuntu cannot run the sandbox this asked for.** As root Chromium
 *     refuses outright (crbug.com/638180); as an ordinary user, 23.10 and newer
 *     set `apparmor_restrict_unprivileged_userns=1` and the namespace sandbox is
 *     unavailable, which is a `FATAL: No usable sandbox!` rather than a
 *     degrade. The SUID helper in the archive does not rescue it — measured, not
 *     assumed. See {@link sandboxDecision} for what is done about it and, more
 *     importantly, for the rule that it is never done silently.
 */

/* ------------------------------------------------------- system libraries -- */

/**
 * The Debian/Ubuntu packages a downloaded Chromium needs and a server image does
 * not have.
 *
 * A chrome-for-testing archive is not self-contained: it links the system's
 * graphics, font, accessibility and audio libraries dynamically, and a minimal
 * cloud image ships almost none of them. Measured on a stock Ubuntu 24.04
 * Hetzner box on 2026-08-22: of the twenty-three libraries the binary needs,
 * **thirteen were missing**, so the download verified, unpacked, reported
 * success and could not execute a single instruction.
 *
 * The list is the packages rather than the library filenames because a package
 * is what a person can act on. `t64` suffixes are the 64-bit-time_t transition
 * names Ubuntu 24.04 and Debian trixie use; on older releases apt resolves the
 * unsuffixed names, which is why the message says the release it was written
 * for rather than pretending to be universal.
 *
 * Exported so {@link describeExit} and `browser-chromium-install.ts` say the
 * same sentence — the alternative being two lists that drift, one of which is
 * wrong when somebody finally reads it.
 */
export const CHROMIUM_LINUX_PACKAGES: readonly string[] = [
  'libatk1.0-0t64',
  'libatk-bridge2.0-0t64',
  'libcups2t64',
  'libgbm1',
  'libasound2t64',
  'libatspi2.0-0t64',
  'libxcomposite1',
  'libxdamage1',
  'libxfixes3',
  'libxrandr2',
  'libpango-1.0-0',
  'libcairo2',
  'libnss3',
  'libxkbcommon0',
]

/** The one line that installs them, for a message a person can paste. */
export function chromiumLibraryHint(): string {
  return `sudo apt-get install -y ${CHROMIUM_LINUX_PACKAGES.join(' ')}`
}

/* --------------------------------------------------------------- sandbox -- */

/**
 * The facts that decide whether Chromium's own sandbox can be left switched on.
 *
 * Every one is a parameter for the reason `platform/host.ts` gives at length: a
 * branch on the running machine can only be exercised on that machine, and the
 * machine this matters on is a Linux server this repository is never built on.
 * {@link readSandboxFacts} does the reading; {@link sandboxDecision} is pure over
 * the result, so `browser-chromium-launch.test.ts` pins every shape — root,
 * namespaces off, AppArmor-restricted, and the happy one — on a macOS run.
 */
export interface SandboxFacts {
  platform: Platform
  /** The effective uid, or `-1` on a platform that has none. */
  uid: number
  /** `/proc/sys/user/max_user_namespaces`, or `-1` when it could not be read. */
  maxUserNamespaces: number
  /** `/proc/sys/kernel/apparmor_restrict_unprivileged_userns` reads as 1. */
  apparmorRestrictsUserns: boolean
}

export interface SandboxDecision {
  /** Leave Chromium's own sandbox on. */
  sandbox: boolean
  /** One sentence naming why, for the log, for `status`, and for the drive check. */
  why: string
}

/**
 * Whether this machine can run Chromium with its sandbox on, and why not.
 *
 * ## Why this is a decision and not a flag
 *
 * `--no-sandbox` is a real reduction in a real security boundary: the sandbox is
 * what stands between a page this host was told to open and the host itself. The
 * temptation on a server is to pass it unconditionally and never think about it
 * again, and that is the wrong shape twice over — it drops the boundary on
 * machines that could have kept it, and it drops it *silently*, which is how a
 * person ends up believing they have a protection they do not.
 *
 * So this answers a narrower question — *is there a usable sandbox here at all?*
 * — and each `false` names a specific thing about this machine. When the answer
 * is `false` the boundary was never available: Chromium's own alternative is to
 * refuse to start, which is not a safer product, it is an absent one. The
 * `why` string exists so the reduction is stated wherever it happens, and
 * `terminaldeck status` prints it under the browser.
 *
 * ## The three ways a Linux box has no sandbox, all measured
 *
 *  - **Running as root.** Chromium refuses outright: *"Running as root without
 *    --no-sandbox is not supported"* (crbug.com/638180). This is not a
 *    preference — a rented server hands you root on day one and this host is
 *    ordinarily installed there, so it is the common case, not the odd one.
 *  - **User namespaces switched off** (`user.max_user_namespaces=0`), which some
 *    hardened kernels and container runtimes do.
 *  - **AppArmor restricting unprivileged user namespaces**, which Ubuntu 23.10
 *    and newer set by default. Measured on Ubuntu 24.04: an ordinary
 *    non-root user gets `FATAL: No usable sandbox!` and the process dies, and
 *    the SUID helper shipped inside the chrome-for-testing archive does *not*
 *    rescue it — that was tried, with the binary chowned root and mode 4755 and
 *    `CHROME_DEVEL_SANDBOX` set, and Chromium still refused.
 *
 * The two ways past those that this deliberately does **not** take are flipping
 * a sysctl and installing an AppArmor profile. Both are system-wide changes to
 * somebody's server, made by an app that was asked to open a web page.
 */
export function sandboxDecision(facts: SandboxFacts): SandboxDecision {
  if (facts.platform !== 'linux') {
    return { sandbox: true, why: "the platform's own sandbox is available" }
  }
  if (facts.uid === 0) {
    return {
      sandbox: false,
      why: 'this host runs as root, and Chromium will not start as root with its sandbox on (crbug.com/638180)',
    }
  }
  if (facts.maxUserNamespaces === 0) {
    return {
      sandbox: false,
      why: 'user namespaces are switched off on this machine (user.max_user_namespaces is 0), so Chromium has no sandbox to use',
    }
  }
  if (facts.apparmorRestrictsUserns) {
    return {
      sandbox: false,
      why: "this kernel restricts unprivileged user namespaces (Ubuntu 23.10+ sets apparmor_restrict_unprivileged_userns), so Chromium has no usable sandbox",
    }
  }
  return { sandbox: true, why: 'the namespace sandbox is available' }
}

/** One `/proc` number, or `-1` when it is not there or is not a number. */
function procNumber(path: string, read: (path: string) => string): number {
  try {
    const value = Number(read(path).trim())
    return Number.isFinite(value) ? value : -1
  } catch {
    return -1
  }
}

/**
 * Read this machine's sandbox facts.
 *
 * The reads are a parameter so the pure decision above can be driven from a test
 * without a `/proc`, and production passes the real one.
 */
export function readSandboxFacts(
  read: (path: string) => string = (path) => readFileSync(path, 'utf8'),
): SandboxFacts {
  const platform = currentPlatform()
  if (platform !== 'linux') {
    return { platform, uid: -1, maxUserNamespaces: -1, apparmorRestrictsUserns: false }
  }
  return {
    platform,
    uid: typeof process.getuid === 'function' ? process.getuid() : -1,
    maxUserNamespaces: procNumber('/proc/sys/user/max_user_namespaces', read),
    apparmorRestrictsUserns: procNumber('/proc/sys/kernel/apparmor_restrict_unprivileged_userns', read) === 1,
  }
}

/* ----------------------------------------------------------------- flags -- */

export interface FlagOptions {
  /** The profile directory Chromium keeps its state in. */
  userDataDir: string
  /** Unpacked extension directories to load, or none. */
  extensionDirs?: readonly string[]
  /**
   * Leave Chromium's own sandbox on. Defaults to `true`.
   *
   * `false` appends `--no-sandbox`, and the only thing that should ever pass
   * `false` is {@link sandboxDecision} answering that this machine has no usable
   * sandbox to leave on. It is an option rather than something this function
   * works out for itself so that the flag list stays a pure function of its
   * input — the property `browser-chromium-launch.test.ts` relies on to pin the
   * composition on any machine.
   */
  sandbox?: boolean
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
  // Before the extension flags and before `extraFlags`, so a caller's verbatim
  // additions stay last — which the test pins, and which is what "verbatim"
  // has to mean if it is to be useful.
  if (options.sandbox === false) flags.push('--no-sandbox')
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
  /**
   * The child ended.
   *
   * Added because `exitCode` answers about the instant it is read and the
   * interesting exits happen a tick or two later — the whole subject of
   * {@link ChromiumHandle.whenGone}. `ChildProcess` satisfies it as written.
   */
  on(event: 'exit', listener: (code: number | null, signal: NodeJS.Signals | null) => void): unknown
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
  /**
   * Resolves, once, when the browser process ends — with a sentence saying how.
   * Never rejects, and never resolves while it is running.
   *
   * This is the answer to the failure the module header describes: a caller
   * holding a pipe onto a dead browser has no other way to find out, because a
   * CDP command sent into that pipe produces silence rather than an error. The
   * intended use is a race — `browser-headless-host.ts` runs the first
   * `Browser.getVersion` against this, so the browser either answers or its
   * death is reported, and there is no third outcome where the host waits.
   */
  whenGone: Promise<string>
  /** How it died, or `null` while it is still running. The synchronous read of the above. */
  exitReason(): string | null
  /** Stop the browser. */
  close(): void
}

export type LaunchResult =
  | {
      ok: true
      handle: ChromiumHandle
      /**
       * Whether the sandbox was left on, and why not when it was not.
       *
       * Returned rather than only acted on, because a security boundary that was
       * dropped has to be sayable by whatever is reporting to the person —
       * `terminaldeck status` prints it, and the drive check prints it.
       */
      sandbox: SandboxDecision
    }
  | { ok: false; why: string }

export interface LaunchOptions extends FlagOptions {
  /** The `chrome` executable, as returned by `installChromium`. */
  executablePath: string
  /** The environment to spawn under. Defaults to `process.env`. */
  env?: NodeJS.ProcessEnv
  /** Test seam. Production uses `node:child_process`'s `spawn`. */
  spawn?: SpawnFn
  /**
   * The sandbox facts to decide from. Defaults to this machine's, read from
   * `/proc`. A test supplies them; production never does.
   */
  sandboxFacts?: SandboxFacts
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
  const sandbox =
    options.sandbox === undefined
      ? sandboxDecision(options.sandboxFacts ?? readSandboxFacts())
      : { sandbox: options.sandbox, why: 'the caller said so' }
  const args = chromiumFlags({ ...options, sandbox: sandbox.sandbox })

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

  /*
   * Watch for the death this function cannot see.
   *
   * Chromium says why it is quitting on stderr and then quits, and the two are
   * separate events, so the tail is kept as it arrives rather than read after
   * the fact from a stream nobody is draining — an undrained `pipe` stdio also
   * fills its buffer and can wedge the child, which is a second reason to
   * consume it. Two kilobytes is far more than the one line that matters and far
   * less than a browser's debug chatter over a long session.
   */
  let stderrTail = ''
  const stderr = child.stdio[2]
  if (stderr !== null && stderr !== undefined && typeof (stderr as Readable).on === 'function') {
    ;(stderr as Readable).on('data', (chunk: Buffer | string) => {
      stderrTail = `${stderrTail}${String(chunk)}`.slice(-2048)
    })
  }

  let exitReason: string | null = null
  let announce: (reason: string) => void = () => {}
  const whenGone = new Promise<string>((resolve) => {
    announce = resolve
  })
  child.on('exit', (code, signal) => {
    exitReason = describeExit(code, signal, stderrTail)
    announce(exitReason)
  })

  return {
    ok: true,
    sandbox,
    handle: {
      pid: child.pid,
      pipeWrite: pipeWrite as Writable,
      pipeRead: pipeRead as Readable,
      whenGone,
      exitReason: () => exitReason,
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

/* ------------------------------------------------------------ the reason -- */

/**
 * Turn an exit into a sentence somebody can act on.
 *
 * The generic form is the code and the last thing the browser said. The two
 * special cases are the two that were actually hit on the first real server, and
 * both are situations where the raw stderr line is true but not useful unless
 * you already know what it means:
 *
 *  - a missing shared library, where the fix is installing a package and the
 *    message should say which library is missing rather than leave a person
 *    reading a linker error;
 *  - the sandbox refusals, where the message should name the machine's setting
 *    rather than the code path inside Chromium that noticed it.
 *
 * Exported for `browser-chromium-launch.test.ts`, which pins both against the
 * exact stderr the real binary produced.
 */
export function describeExit(
  code: number | null,
  signal: NodeJS.Signals | null,
  stderrTail: string,
): string {
  const how = signal !== null ? `on signal ${signal}` : `with code ${code ?? 'unknown'}`

  const missingLibrary = /error while loading shared libraries: ([^:]+):/.exec(stderrTail)
  if (missingLibrary !== null) {
    return (
      `Chromium could not start: it needs ${missingLibrary[1]}, which is not installed on this machine. ` +
      'A downloaded Chromium links the system graphics and accessibility libraries, and a minimal server ' +
      `image has none of them. On Debian or Ubuntu: ${chromiumLibraryHint()}`
    )
  }

  if (stderrTail.includes('Running as root without --no-sandbox')) {
    return (
      'Chromium will not run as root with its sandbox on, and this host is running as root. ' +
      'That case is meant to be handled before launch — see sandboxDecision — so reaching this means the ' +
      'sandbox facts were read as something other than root.'
    )
  }
  if (stderrTail.includes('No usable sandbox')) {
    return (
      'Chromium found no usable sandbox on this machine, which on Ubuntu 23.10 and newer is ' +
      'apparmor_restrict_unprivileged_userns being set. That case is meant to be handled before launch — ' +
      'see sandboxDecision.'
    )
  }

  const said = stderrTail
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '')
    .pop()
  return said === undefined
    ? `Chromium exited ${how}`
    : `Chromium exited ${how}: ${said.slice(0, 300)}`
}
