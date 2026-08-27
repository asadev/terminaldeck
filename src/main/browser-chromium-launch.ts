import { spawn } from 'node:child_process'
import { accessSync, constants, readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { Readable, Writable } from 'node:stream'
import { CdpPipe } from './browser-cdp-pipe'
import { currentPlatform, type Platform } from './platform/host'

/**
 * Starting the standalone Chromium and handing back its two CDP pipe streams —
 * the process, and nothing above it.
 *
 * ## The launch, decided
 *
 * `chrome --headless=new --remote-debugging-pipe --user-data-dir=<profile>
 * --no-first-run --no-default-browser-check --disable-gpu
 * --disable-blink-features=AutomationControlled`, plus `--user-agent=<ua>` when
 * the caller supplies one and `--load-extension=<dirs>
 * --disable-extensions-except=<dirs>` when a profile carries extensions.
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
 *  - **`--disable-blink-features=AutomationControlled`** is the pair to the
 *    de-headlessed `--user-agent` the host passes: `--headless=new` plus the
 *    debugging pipe together make Google see an automated, headless browser and
 *    refuse a new sign-in — *"this browser or app may not be secure"* — and this
 *    flag turns off `navigator.webdriver`, which was measured reading `true`
 *    here without it and `false` with it (2026-08-27). `--headless=new` itself
 *    must stay — the architecture needs it — so the other tells are suppressed
 *    instead. `--enable-automation` is never added; it would do the reverse.
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
 * The package manager a Linux box has, in the order `install-headless.sh` asks.
 *
 * `musl` is not a package manager and is deliberately in the same union: an
 * Alpine box's answer to "which packages do I install" is *none of them*, and a
 * type that could not say so would force this file to print an `apk add` line
 * that cannot work. See {@link chromiumLibraryHint}.
 */
export type PackageFamily = 'apt' | 'dnf' | 'yum' | 'pacman' | 'zypper' | 'musl'

/** Is this command on PATH? The seam every family check goes through. */
export type HaveCommand = (command: string) => boolean

const defaultHave: HaveCommand = (command) => {
  const path = process.env.PATH ?? ''
  const sep = process.platform === 'win32' ? ';' : ':'
  for (const dir of path.split(sep)) {
    if (dir === '') continue
    try {
      accessSync(join(dir, command), constants.X_OK)
      return true
    } catch {
      /* Not here; try the next entry. */
    }
  }
  return false
}

/**
 * Which family this machine is, decided the way `install-headless.sh` decides it.
 *
 * That script's `check_native_toolchain` walks `apk`, `dnf`, `yum`, `pacman`,
 * `zypper` and falls back to `apt-get`, and this walks the same list in the same
 * order so the two never disagree about a box. `apk` first is not arbitrary —
 * it is the one answer that changes the *advice* rather than only the command,
 * so it has to be asked before anything else can claim the machine.
 *
 * The default is `apt` rather than "unknown" for the reason the shell script
 * has: the overwhelming majority of rented Linux servers are Debian or Ubuntu,
 * and a person on the exception has a package manager in front of them and can
 * translate one line. A refusal to guess would help nobody.
 */
export function detectPackageFamily(have: HaveCommand = defaultHave): PackageFamily {
  if (have('apk')) return 'musl'
  if (have('dnf')) return 'dnf'
  if (have('yum')) return 'yum'
  if (have('pacman')) return 'pacman'
  if (have('zypper')) return 'zypper'
  return 'apt'
}

/**
 * The Debian/Ubuntu packages a downloaded Chromium needs and a server image does
 * not have.
 *
 * A chrome-for-testing archive is not self-contained: it links the system's
 * graphics, font, accessibility and audio libraries dynamically, and a minimal
 * cloud image ships almost none of them. Measured on a stock Ubuntu 24.04
 * Hetzner box on 2026-08-22: of the fifty-three entries `ldd` prints for the
 * binary, **thirteen resolved to nothing** —
 *
 *     libasound.so.2  libatk-1.0.so.0  libatk-bridge-2.0.so.0  libatspi.so.0
 *     libcairo.so.2   libcups.so.2     libgbm.so.1             libpango-1.0.so.0
 *     libXcomposite.so.1  libXdamage.so.1  libXext.so.6  libXfixes.so.3
 *     libXrandr.so.2
 *
 * — so the download verified, unpacked, reported success and could not execute a
 * single instruction. Installing exactly this list and re-running `ldd` left
 * nothing unresolved and `chrome --version` answered, on that same box, the same
 * day. That is the whole claim this constant makes, and it was measured rather
 * than assembled from a wiki page.
 *
 * `libxext6` is in the list even though apt pulls it in behind `libxrandr2`,
 * because a list that depends on somebody else's dependency graph is a list that
 * breaks when that graph changes and gives no clue why. `libnss3` and
 * `libxkbcommon0` were already present on that image and are named anyway —
 * Chromium links both, and an image that lacks them would otherwise get a
 * "install these" line that leaves it still broken.
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
  'libxext6',
  'libxfixes3',
  'libxrandr2',
  'libpango-1.0-0',
  'libcairo2',
  'libnss3',
  'libxkbcommon0',
]

/**
 * The same libraries under each family's own package names.
 *
 * Only the `apt` row is measured — on the Ubuntu 24.04 box described above. The
 * others are the same fourteen libraries spelled the way each distribution
 * spells them, and they are here because the alternative that shipped was an
 * `apt-get` line printed at a person holding `dnf`, which is not a hint, it is
 * a puzzle. Where one of these is wrong it is wrong by a package name that
 * `dnf`/`pacman`/`zypper` will say it cannot find — a failure that names itself
 * — rather than by claiming a machine is ready when it is not.
 *
 * `musl` has no row on purpose. See {@link chromiumLibraryHint}.
 */
const PACKAGES_BY_FAMILY: Record<Exclude<PackageFamily, 'musl'>, readonly string[]> = {
  apt: CHROMIUM_LINUX_PACKAGES,
  dnf: [
    'atk', 'at-spi2-atk', 'cups-libs', 'mesa-libgbm', 'alsa-lib', 'at-spi2-core',
    'libXcomposite', 'libXdamage', 'libXext', 'libXfixes', 'libXrandr',
    'pango', 'cairo', 'nss', 'libxkbcommon',
  ],
  yum: [
    'atk', 'at-spi2-atk', 'cups-libs', 'mesa-libgbm', 'alsa-lib', 'at-spi2-core',
    'libXcomposite', 'libXdamage', 'libXext', 'libXfixes', 'libXrandr',
    'pango', 'cairo', 'nss', 'libxkbcommon',
  ],
  pacman: [
    'atk', 'at-spi2-atk', 'libcups', 'mesa', 'alsa-lib', 'at-spi2-core',
    'libxcomposite', 'libxdamage', 'libxext', 'libxfixes', 'libxrandr',
    'pango', 'cairo', 'nss', 'libxkbcommon',
  ],
  zypper: [
    'libatk-1_0-0', 'libatk-bridge-2_0-0', 'libcups2', 'libgbm1', 'libasound2',
    'libatspi0', 'libXcomposite1', 'libXdamage1', 'libXext6', 'libXfixes3',
    'libXrandr2', 'libpango-1_0-0', 'libcairo2', 'mozilla-nss', 'libxkbcommon0',
  ],
}

/** The install verb each family spells differently, with its non-interactive flag. */
const INSTALL_VERB: Record<Exclude<PackageFamily, 'musl'>, string> = {
  apt: 'apt-get install -y',
  dnf: 'dnf install -y',
  yum: 'yum install -y',
  pacman: 'pacman -S --needed --noconfirm',
  zypper: 'zypper install -y',
}

/**
 * The one command that installs the libraries, for this machine's package
 * manager — or, on musl, the honest statement that no such command exists.
 *
 * ## Why Alpine gets a different sentence rather than an `apk add` line
 *
 * chrome-for-testing publishes **glibc** builds and nothing else. On a musl box
 * the binary's interpreter — `/lib64/ld-linux-x86-64.so.2` — is not there, so
 * the failure is not a missing feature library that `apk add` could supply; the
 * loader itself is absent and every package in the world leaves it absent. An
 * `apk add` line here would send somebody to install fourteen packages and land
 * them back at exactly the same error, which is the "no resistance" rule broken
 * twice: once by the original wrong success, once by the wrong fix.
 *
 * What *does* work on Alpine is the distribution's own `chromium` package, built
 * against musl — and this app already has the door for it, because
 * `CHROMIUM_PATH_ENV` exists for exactly the operator who wants to supply their
 * own binary. So that is what the sentence says.
 */
export function chromiumLibraryHint(family: PackageFamily = detectPackageFamily()): string {
  if (family === 'musl') {
    return (
      'apk add chromium && TERMINALDECK_CHROMIUM_PATH=/usr/bin/chromium ' +
      '(chrome-for-testing publishes glibc builds only, so no package makes the downloaded one run here)'
    )
  }
  return `sudo ${INSTALL_VERB[family]} ${PACKAGES_BY_FAMILY[family].join(' ')}`
}

/**
 * The command {@link chromiumLibraryHint} describes, split for `spawn`, or
 * `null` where there is nothing to run.
 *
 * Separate from the hint string because the two have different jobs and only one
 * of them may ever be executed: the hint is prose a person reads, this is an
 * argv a machine runs — and only when someone passed `--with-deps`. `null` for
 * musl keeps that promise mechanically rather than by remembering to check.
 */
export function chromiumLibraryCommand(
  family: PackageFamily = detectPackageFamily(),
): { command: string; args: string[] } | null {
  if (family === 'musl') return null
  const [command, ...verbArgs] = INSTALL_VERB[family].split(' ')
  return { command, args: [...verbArgs, ...PACKAGES_BY_FAMILY[family]] }
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
   * The user agent this browser presents, or none to keep Chromium's own.
   *
   * The one it keeps by default is the problem: `--headless=new` names itself
   * `HeadlessChrome`, which is the loudest thing a browser can say to Google's
   * *"this browser or app may not be secure"* check. The caller
   * (`browser-headless-host.ts`) passes the same engine's honest, de-headlessed
   * string from {@link machineBrowserUserAgent}; when it is empty — a side-loaded
   * binary of unknown version — no `--user-agent` is added and the browser keeps
   * whatever it presents. A pure option so the flag list stays a function of its
   * input, the property the test below relies on.
   */
  userAgent?: string
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
    /*
     * Present as an ordinary Chromium, not an automated one.
     *
     * Measured on this machine on 2026-08-27, against this exact launch: with
     * nothing here `navigator.webdriver` read `true`, and with this one flag it
     * reads `false`. That property is the other half of Google's *"this browser
     * or app may not be secure"* refusal — the half the de-headlessed user agent
     * (`--user-agent`, below) does not touch. It is the `AutomationControlled`
     * blink feature that `--remote-debugging-pipe` would otherwise leave on;
     * disabling it is exactly what a person driving Chrome by hand has, and it
     * carries no capability — it only stops the browser advertising that a
     * debugger is attached. `--enable-automation`, which would turn the tell
     * back on and raise an automation infobar besides, is deliberately never
     * added anywhere in this file.
     */
    '--disable-blink-features=AutomationControlled',
  ]
  // The honest, de-headlessed user agent, when the caller supplied one. Before
  // the extension flags and `extraFlags` for the same reason the sandbox flag
  // is: a caller's verbatim additions stay last. See {@link FlagOptions.userAgent}.
  if (options.userAgent !== undefined && options.userAgent !== '') {
    flags.push(`--user-agent=${options.userAgent}`)
  }
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

/**
 * A spawned browser and the sandbox decision it was spawned under — what is
 * knowable the instant the process exists, and no more. {@link launchChromium}
 * is the one that also knows whether it *works*.
 */
export type SpawnResult =
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

/** A browser that has answered, with the pipe it answered on. */
export type LaunchResult =
  | {
      ok: true
      handle: ChromiumHandle
      /**
       * The framed CDP channel, already used for the handshake.
       *
       * Handed back rather than rebuilt by the caller because it is the *same*
       * pipe: a second `CdpPipe` over the same fds would race the first for
       * every byte. It structurally satisfies `browser-driven-cdp.ts`'s
       * `CdpTransport`, which is what the host drives through.
       */
      transport: CdpPipe
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
  /**
   * How long the browser gets to answer its first command before the launch is
   * called a failure. Defaults to {@link FIRST_COMMAND_TIMEOUT_MS}.
   *
   * A parameter because a test proving the timeout arm would otherwise have to
   * wait the production thirty seconds, which means it would not be written.
   */
  readyTimeoutMs?: number
}

/**
 * Spawn Chromium with the CDP pipe stdio and return its two fd streams, or a
 * named error.
 *
 * Four failures are caught rather than left to surface later as an unhandled
 * event or a hang: a `spawn` that throws, a child that came back with no pid
 * (the ordinary "the executable is not there" case — `spawn` reports it
 * asynchronously, but a missing pid is synchronous), a child that has already
 * exited before this function returned, and a child with no pipe on fd 3 or
 * fd 4, because a CDP channel that is not there is not a browser anyone can
 * drive.
 *
 * **None of those four is proof that the browser works**, and that is the whole
 * reason this is not the exported entry point any more. See
 * {@link launchChromium}.
 */
export function spawnChromium(options: LaunchOptions): SpawnResult {
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
   *
   * The *diagnostic* is kept separately, and that is not belt-and-braces. A
   * Chromium that aborts prints its reason first and then twenty stack frames
   * and a register dump — measured on Ubuntu 24.04, 2026-08-22: the `FATAL:`
   * line naming a missing crashpad handler was 1.6 kB above the end of the
   * output, so a two-kilobyte tail held the register dump and had thrown the
   * only useful line away. {@link describeExit} was then handing a person
   * `Chromium exited on signal SIGABRT: [end of stack trace]`. So the line is
   * caught as it goes past instead of dug for afterwards.
   */
  let stderrTail = ''
  let diagnostic = ''
  let stderrLine = ''
  const stderr = child.stdio[2]
  if (stderr !== null && stderr !== undefined && typeof (stderr as Readable).on === 'function') {
    ;(stderr as Readable).on('data', (chunk: Buffer | string) => {
      const text = String(chunk)
      stderrTail = `${stderrTail}${text}`.slice(-2048)
      // Line-buffered, because a chunk boundary lands mid-sentence often enough
      // that matching per chunk would miss the one line that matters.
      stderrLine += text
      let newline = stderrLine.indexOf('\n')
      while (newline !== -1) {
        const line = stderrLine.slice(0, newline)
        if (isDiagnostic(line)) diagnostic = line.trim()
        stderrLine = stderrLine.slice(newline + 1)
        newline = stderrLine.indexOf('\n')
      }
      // A final line with no trailing newline still counts — a process that dies
      // mid-line is exactly the case here.
      if (stderrLine.length > 0 && isDiagnostic(stderrLine)) diagnostic = stderrLine.trim()
      if (stderrLine.length > 4096) stderrLine = stderrLine.slice(-4096)
    })
  }

  let exitReason: string | null = null
  let announce: (reason: string) => void = () => {}
  const whenGone = new Promise<string>((resolve) => {
    announce = resolve
  })
  child.on('exit', (code, signal) => {
    exitReason = describeExit(code, signal, stderrTail, diagnostic)
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

/* --------------------------------------------------------- is it awake yet -- */

/** How long a launched Chromium gets to answer its first command. */
export const FIRST_COMMAND_TIMEOUT_MS = 30_000

/**
 * How long a lost pipe waits for the exit that explains it.
 *
 * Not a guess: with a *real* process the fd closing and the `'exit'` event are
 * two separate deliveries and the pipe wins, so the first thing this function
 * learns about a browser that died at startup is `the debugger pipe closed` —
 * true, and useless. The exit that says `it needs libatk-1.0.so.0, install
 * these packages` arrives a tick or two later. Half a second is far longer than
 * that gap and short enough that a pipe which closed for some other reason is
 * still reported promptly.
 *
 * The fakes in `browser-chromium-launch.test.ts` never showed this, because a
 * modelled child delivers both from the same tick. The test that spawns a real
 * `/bin/sh` did, on the first run.
 */
export const EXIT_GRACE_MS = 500

/**
 * `null` when the browser answered, or the sentence saying why it never will.
 *
 * Exported, and taking the transport structurally rather than as a `CdpPipe`, so
 * `browser-chromium-launch.test.ts` can drive all four arms — the answer, the
 * death, the refusal and the wedge — with no process and no real pipe. The
 * timeout is a parameter for the same reason: a test that had to wait the
 * production thirty seconds to prove the wedge would simply not be written.
 *
 * The arms are not equal. A refusal is reported *last*, after {@link
 * EXIT_GRACE_MS}, because a pipe error and a process death are the same event
 * seen from two places and only one of them knows what happened.
 */
export async function confirmReady(
  transport: { command(command: { method: string; params?: unknown }): Promise<unknown> },
  whenGone: Promise<string>,
  timeoutMs: number = FIRST_COMMAND_TIMEOUT_MS,
  graceMs: number = EXIT_GRACE_MS,
): Promise<string | null> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<{ why: string }>((resolve) => {
    timer = setTimeout(
      () => resolve({ why: `Chromium started but did not answer its first command within ${Math.round(timeoutMs / 1000)} s` }),
      timeoutMs,
    )
  })
  try {
    const outcome = await Promise.race<{ why: string } | { refused: string } | null>([
      transport.command({ method: 'Browser.getVersion', params: {} }).then(
        () => null,
        (error: unknown) => ({
          refused: `Chromium refused its first command: ${error instanceof Error ? error.message : 'no answer'}`,
        }),
      ),
      whenGone.then((why) => ({ why })),
      timeout,
    ])
    if (outcome === null) return null
    if ('why' in outcome) return outcome.why

    // The pipe went first. Give the exit its moment; it carries the reason.
    let graceTimer: ReturnType<typeof setTimeout> | undefined
    const grace = new Promise<null>((resolve) => {
      graceTimer = setTimeout(() => resolve(null), graceMs)
    })
    try {
      return (await Promise.race([whenGone, grace])) ?? outcome.refused
    } finally {
      if (graceTimer !== undefined) clearTimeout(graceTimer)
    }
  } finally {
    // The timer would otherwise hold the event loop open for its full duration
    // after a launch that succeeded in milliseconds.
    if (timer !== undefined) clearTimeout(timer)
  }
}

/**
 * Start Chromium and hand back a browser that has **answered**, or the sentence
 * saying why there is none.
 *
 * ## Why this is async, and why the synchronous one is not the door any more
 *
 * `spawnChromium` can only report what is knowable in the instant it returns: a
 * pid, a null `exitCode`, two open fds. A Chromium that is about to die on its
 * first instruction has all three. Measured on a stock Ubuntu 24.04 Hetzner box
 * on 2026-08-22: a binary missing `libatk-1.0.so.0` was reported healthy, and
 * was gone thirty milliseconds later with exit 127. Every caller that believed
 * that answer then wrote a CDP command into a pipe with a corpse on the far end
 * and waited for a reply that could not come — and a hang is the worst failure
 * available, because nothing is logged, nothing times out, and the phone that
 * asked for a page simply never hears back.
 *
 * So a launch is not finished until the browser has said something. The
 * handshake is the proof: `Browser.getVersion` is the cheapest command in the
 * protocol, one round-trip has to happen anyway, and it costs 285 ms against a
 * live browser — measured on that same box, against the same pinned build. The
 * race has three arms and no fourth outcome: the browser answers, the process
 * dies and its death is the error, or the bounded timeout fires because it
 * started and wedged without exiting.
 *
 * A failed confirmation kills the child before returning. A browser that is
 * alive but unusable is still a browser holding a profile lock, and leaving one
 * behind is how the next launch fails for a reason that has nothing to do with
 * what went wrong.
 */
export async function launchChromium(options: LaunchOptions): Promise<LaunchResult> {
  const spawned = spawnChromium(options)
  if (!spawned.ok) return spawned

  const transport = new CdpPipe(spawned.handle.pipeWrite, spawned.handle.pipeRead)
  const why = await confirmReady(
    transport,
    spawned.handle.whenGone,
    options.readyTimeoutMs ?? FIRST_COMMAND_TIMEOUT_MS,
  )
  if (why !== null) {
    transport.close()
    spawned.handle.close()
    return { ok: false, why }
  }
  return { ok: true, handle: spawned.handle, transport, sandbox: spawned.sandbox }
}

/* ------------------------------------------------------------ the reason -- */

/**
 * Chromium's own log-line shape: `[pid:tid:MMDD/HHMMSS.uuuuuu:FATAL:file.cc:12]`.
 *
 * Matched rather than merely searched for `FATAL`, because the prefix is also
 * the thing that gets stripped: what a person needs is the message, not the
 * source file inside Chromium that noticed it.
 */
const CHROMIUM_LOG_LINE = /^\[[^\]]*:(FATAL|ERROR|WARNING):[^\]]*\]\s*(.*)$/

/**
 * Lines that are a crash dump rather than a reason.
 *
 * A Chromium abort prints `Received signal 6`, twenty-odd `#12 0x...` frames, a
 * register dump and `[end of stack trace]`. The *last* line of that — which is
 * what the previous version of {@link describeExit} handed to a person — is
 * `[end of stack trace]`, which tells them nothing at all and is exactly the
 * "a stack trace, not a sentence" failure this file is meant not to have.
 */
function isNoise(line: string): boolean {
  return (
    line === '[end of stack trace]' ||
    /^Received signal\b/.test(line) ||
    /^#\d+\s/.test(line) ||
    // A register dump row: two-to-four short names each followed by a hex word.
    /^\s*[a-z0-9]{2,3}:\s+[0-9a-f]{8,16}\b/.test(line) ||
    /^\[end of/.test(line)
  )
}

/**
 * Is this line worth remembering as *the* reason?
 *
 * Used while stderr is streaming — see {@link spawnChromium} — so the one useful
 * line survives the crash dump that follows it and pushes it out of the tail.
 */
export function isDiagnostic(line: string): boolean {
  const trimmed = line.trim()
  if (trimmed === '' || isNoise(trimmed)) return false
  if (trimmed.includes('error while loading shared libraries')) return true
  const match = CHROMIUM_LOG_LINE.exec(trimmed)
  if (match === null) return false
  // A warning is not why a browser died; an error or a fatal might be.
  return match[1] !== 'WARNING'
}

/** A Chromium log line reduced to its message, or the line unchanged. */
function withoutLogPrefix(line: string): string {
  const match = CHROMIUM_LOG_LINE.exec(line.trim())
  return match === null ? line.trim() : match[2].trim()
}

/**
 * Turn an exit into a sentence somebody can act on.
 *
 * The generic form is the code and the last *meaningful* thing the browser said.
 * The three special cases are the ones actually hit on real servers, and all
 * three are situations where the raw stderr line is true but not useful unless
 * you already know what it means:
 *
 *  - a missing shared library, where the fix is installing packages and the
 *    message should name the library and the command rather than leave a person
 *    reading a linker error;
 *  - the sandbox refusals, where the message should name the machine's setting
 *    rather than the code path inside Chromium that noticed it;
 *  - an abort, where Chromium prints the reason and then buries it under a
 *    stack trace and a register dump — hence `diagnostic`, captured as the
 *    output streamed, and the noise filter over whatever is left.
 *
 * Exported for `browser-chromium-launch.test.ts`, which pins all of them against
 * the exact stderr the real binary produced.
 */
export function describeExit(
  code: number | null,
  signal: NodeJS.Signals | null,
  stderrTail: string,
  /**
   * The last `FATAL:`/`ERROR:` line seen while stderr streamed, if any.
   *
   * Separate from the tail because on an abort it is no longer *in* the tail:
   * measured on Ubuntu 24.04, the FATAL line naming the real cause was 1.6 kB
   * above the end of the output.
   */
  diagnostic = '',
): string {
  const how = signal !== null ? `on signal ${signal}` : `with code ${code ?? 'unknown'}`
  const haystack = `${diagnostic}\n${stderrTail}`

  const missingLibrary = /error while loading shared libraries: ([^:]+):/.exec(haystack)
  if (missingLibrary !== null) {
    return (
      `Chromium could not start: it needs ${missingLibrary[1]}, which is not installed on this machine. ` +
      'A downloaded Chromium links the system graphics and accessibility libraries, and a minimal server ' +
      `image has none of them. Install them with: ${chromiumLibraryHint()}`
    )
  }

  if (haystack.includes('Running as root without --no-sandbox')) {
    return (
      'Chromium will not run as root with its sandbox on, and this host is running as root. ' +
      'That case is meant to be handled before launch — see sandboxDecision — so reaching this means the ' +
      'sandbox facts were read as something other than root.'
    )
  }
  if (haystack.includes('No usable sandbox')) {
    return (
      'Chromium found no usable sandbox on this machine, which on Ubuntu 23.10 and newer is ' +
      'apparmor_restrict_unprivileged_userns being set. That case is meant to be handled before launch — ' +
      'see sandboxDecision.'
    )
  }

  const said =
    diagnostic.trim() !== ''
      ? withoutLogPrefix(diagnostic)
      : stderrTail
          .split('\n')
          .map((line) => line.trim())
          .filter((line) => line !== '' && !isNoise(line))
          .map(withoutLogPrefix)
          .pop()
  return said === undefined || said === ''
    ? `Chromium exited ${how}`
    : `Chromium exited ${how}: ${said.slice(0, 300)}`
}
