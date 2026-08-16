/**
 * The Windows half of confinement: an AppContainer, applied by a launcher this
 * repository builds, because no API reachable from Node can apply it.
 *
 * ## Why this file exists next to `seatbelt.ts` and `linux.ts` rather than inside them
 *
 * The other two platforms hand the boundary to a program that is already on the
 * machine — `sandbox-exec` on macOS, `unshare` and `setpriv` on Linux — so the
 * whole of their implementation is "build the right command line". Windows has
 * no such program. An AppContainer is applied *at process creation*, in the
 * `CreateProcess` call itself, through
 * `UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES)`, and
 * neither Node nor `node-pty` can reach that. So the command line this file
 * builds is a command line for `native/win-confine/tdconfine.exe`, which this
 * repository compiles, and the security argument lives half here and half in C.
 *
 * ## What was measured, on a real Windows 11 machine, before any of this was written
 *
 * All of it on `DESKTOP-DDGMNCV`, Windows 11 Pro 10.0.26200 build 26200, against
 * a real `cmd.exe` driven through the same `node-pty` 1.1.0 the app ships.
 * `CONFINEMENT.md` carries the full account; the parts that shaped this file:
 *
 *  - **The boundary holds.** With one ACE on the granted folder and nothing
 *    else, a confined `cmd.exe` is refused the owner's home canary, `.gitconfig`,
 *    `.claude.json`, `.ssh`, another device's granted folder, the app's own
 *    install directory and the Windows event log; `mklink` and `mklink /J` out
 *    of the folder are refused; writing into an ancestor is refused; `icacls`
 *    rewriting the folder's own ACL is refused (the grant is Modify, which
 *    excludes `WRITE_DAC`); a grandchild process is refused identically; and a
 *    `Start-Process` from inside produced a process that was also confined and
 *    wrote nothing.
 *  - **The terminal is the part that works.** A real interactive `cmd.exe` ran
 *    on a real ConPTY through the launcher: typed input echoed with VT and
 *    cursor-positioning sequences, a live prompt, and the exit code came back.
 *    Nothing about the pty had to be reimplemented — the launcher inherits the
 *    pseudoconsole and passes it to the child.
 *  - **`node`, `git` and `claude` all run**, and are confined while they run:
 *    `fs.readFileSync` of the owner's canary is `EPERM` and of the session's own
 *    file is the file.
 *  - **The interactive desktop does not have to be handed over.** The earlier
 *    measurement concluded that granting the container `WinSta0` and the
 *    `Default` desktop was mandatory, and called it a genuine weakening. It is
 *    not mandatory: the launcher creates a window station and a desktop of its
 *    own and grants those, and `WinSta0`'s ACL is never touched.
 *
 * ## What it costs, stated here because somebody will look for it here
 *
 * **A confined Windows session can list the directories on the path from the
 * drive root down to its own folder — including the owner's home directory.**
 * Names, sizes and dates; it cannot open any of them. This is not a choice
 * anybody made for convenience: `git` resolves its own working directory with
 * `GetLongPathNameW`, which enumerates every component, and its fallback
 * (`GetFinalPathNameByHandleW` with `VOLUME_NAME_DOS`) cannot work in an
 * AppContainer at all because the DOS device namespace is not enumerable there
 * — measured with a probe run inside the container. Traverse-without-list was
 * tried first and every git command died at `fatal: unable to get current
 * working directory: Permission denied`. So the choice was git or the listing,
 * and this is the one place a Windows session is weaker than a macOS one, where
 * `ls ~` is refused outright. {@link WINDOWS_GRANT_NOTE} is the sentence the
 * grant screen owes the user about it.
 *
 * Two smaller costs, both measured rather than estimated:
 *
 *  - **Loopback.** An AppContainer cannot reach `127.0.0.1` without a
 *    machine-wide loopback exemption the launcher will not create. A confined
 *    session reaches the internet and cannot reach a dev server on the same
 *    machine.
 *  - **Session start pays for the ACL.** The granted folder's ACE is
 *    inheritable, so it has to be written onto the files that are already
 *    there. Measured at 0.57s for grant, run and revoke over a 5,000-file tree;
 *    it scales with the file count, so a very large repository will notice.
 *
 * ## What the second pass changed, and why the first one could not have known
 *
 * Everything above was measured from a shell that was **elevated**, because the
 * only way onto that machine from here is `ssh` into WSL and out through
 * interop, and that logon runs at High integrity with the Administrators group
 * enabled. Three of the conclusions were therefore about a process Terminal Deck
 * never is. Re-measured with a genuinely non-elevated token — medium integrity,
 * Administrators deny-only, in the user's own interactive session — they read
 * differently:
 *
 *  - **A normal user cannot create a window station.** `CreateWindowStationW`
 *    answers `ERROR_ACCESS_DENIED`, so {@link makeStation}'s "a station of its
 *    own, and `WinSta0` is never touched" was only ever true of an elevated
 *    host. The launcher now takes `--station shared`, which creates a private
 *    *desktop* on the station the app is already on. Measured, and better than
 *    expected: the confined session still cannot open the clipboard
 *    (`OpenClipboard` → `ERROR_ACCESS_DENIED`), which was the cost this was
 *    braced for.
 *  - **A normal user cannot write the ACL of `C:\` or `C:\Users`**, which every
 *    granted folder under a user profile needs as an ancestor. Per-session
 *    ancestor ACEs on those would have needed an administrator at every session
 *    start.
 *  - **Nobody can write the ACL of `C:\Program Files`** — its owner is
 *    `TrustedInstaller` and even an elevated run is refused. It turns out not to
 *    be needed: `SeChangeNotifyPrivilege` covers traverse, so the ACE on
 *    `C:\Program Files\nodejs` itself is enough to run `node.exe`.
 *
 * `tools.ts` is what those three add up to: a **one-time** grant, to a
 * capability SID rather than to a per-device container SID, covering the tool
 * directories and the ancestors an unprivileged process cannot reach. With it in
 * place, a confined session started by a non-elevated process on the real
 * machine ran `node -v`, `npm -v`, `git status`, `git commit` and
 * `claude --version`, read its own folder, and was refused the owner's home
 * canary — while the same session **without** the capability in its token
 * answered `'node' is not recognized as an internal or external command`.
 * That last line is the whole feature in one sentence.
 */

import { execFile } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { rmSync, writeFileSync } from 'node:fs'
import { win32 } from 'node:path'
import { promisify } from 'node:util'
import { within, type ConfinementPlan } from './plan'
// A type, and only a type: `tools.ts` imports `ancestorsOf` from this file, so a
// value import in this direction would be a cycle. The two halves belong apart —
// this one builds a session's command line, that one owns the permission that
// outlives every session.
import type { ToolGrant } from './tools'

const run = promisify(execFile)

/* ------------------------------------------------------------- the launcher -- */

/**
 * The launcher's filename, in one place.
 *
 * Named here rather than spelled at each site for the reason `deviceHomesRoot`
 * gives about directory names: two spellings of one filename is how the side
 * that looks for it ends up looking somewhere the side that ships it never puts
 * it — and on this path the failure mode is a session that refuses to start
 * with "the launcher is missing" on a machine where it is right there.
 */
export const LAUNCHER_NAME = 'tdconfine.exe'

/**
 * Where the launcher is, given where the app's resources are.
 *
 * `extraResources` in `electron-builder.yml` puts it beside the asar rather
 * than inside it, which is not a packaging preference: it is an executable, and
 * `CreateProcess` cannot run a file that only exists inside an archive. In a
 * development checkout the same file is wherever `native/win-confine/build.ps1`
 * left it, and the caller passes that instead.
 */
export function launcherPath(resourcesDir: string): string {
  return win32.join(resourcesDir, LAUNCHER_NAME)
}

/* -------------------------------------------------------------- the container -- */

/**
 * The AppContainer name for one device.
 *
 * Per device rather than per session, and that is a security-relevant choice
 * rather than a tidiness one. The ACEs this places on the user's folders
 * outlive the process that placed them if that process is killed outright —
 * `TerminateProcess` gives the launcher no chance to revoke — and a per-session
 * name would mean every hard kill leaving a permanent, unresolvable SID on
 * somebody's directory, accumulating one per crash. A per-device name means the
 * litter is bounded at one SID per device, and the thing that inherits a
 * leftover ACE is the same device that was granted the folder in the first
 * place. {@link releaseArgs} is how it gets swept.
 *
 * Hashed rather than sanitised. An AppContainer name is limited to 64
 * characters and rejects most punctuation, and a device key is an opaque
 * identifier this module has no business making assumptions about; a hash is
 * always valid, always the same length, and cannot collide by truncation.
 */
export function containerName(deviceKey: string): string {
  const digest = createHash('sha256').update(deviceKey).digest('hex').slice(0, 32)
  return `terminaldeck-${digest}`
}

/* ------------------------------------------------------------- the ancestors -- */

/**
 * The directories on the path from the drive root down to `path`, not including
 * `path` itself.
 *
 * `C:\Users\Imza\Projects\app` produces `C:\`, `C:\Users`, `C:\Users\Imza` and
 * `C:\Users\Imza\Projects`.
 *
 * A UNC path produces **nothing**, and that is deliberate rather than an
 * omission: `\\server\share` has no ancestor an ACL can be written on from
 * here, and an AppContainer has no network-share capability unless one is
 * granted, so a plan pointing at a share is a plan this mechanism cannot honour
 * — {@link appContainerArgs} refuses it rather than quietly building a command
 * that would confine a session to a folder it cannot open.
 */
export function ancestorsOf(path: string): string[] {
  const normalized = win32.normalize(path)
  if (normalized.startsWith('\\\\')) return []
  const root = win32.parse(normalized).root
  if (root === '' || !win32.isAbsolute(normalized)) return []

  // A root has no ancestors, and the loop below cannot notice on its own:
  // `dirname('C:\\')` is `'C:\\'`, so it would push the root and then stop,
  // claiming the drive is its own ancestor.
  if (win32.dirname(normalized) === normalized) return []

  const chain: string[] = []
  let current = win32.dirname(normalized)
  // `dirname` of a root is the root, which is what stops this rather than a
  // count: `dirname('C:\\')` is `'C:\\'`.
  while (true) {
    chain.push(current)
    if (current === root) break
    const parent = win32.dirname(current)
    if (parent === current) break
    current = parent
  }
  return chain.reverse()
}

/**
 * Every ancestor this session's own grants need, once each, with the plan's own
 * directories removed.
 *
 * The writable directories and the individual files, and **not** `plan.readable`
 * — which is the difference between this and the obvious version, and it is not
 * a shortcut. On Windows `plan.readable` is `toolRoots()`'s walk of the
 * session's `PATH`: on the machine this was measured on that is eighteen
 * directories including the JDK, dotnet, two NVIDIA folders, VS Code and GitHub
 * Desktop. This mechanism does not grant those per session — `tools.ts` grants
 * the three that actually hold tools, once, with an administrator — so walking
 * their ancestors here would ask an unprivileged session to write an ACE on
 * `C:\Program Files`, which nobody can write, and refuse a session that is
 * otherwise perfectly confinable.
 *
 * Removing the plan's own directories matters because a plan directory already
 * has a stronger grant: leaving it in would put a second ACE for the same SID on
 * the same path, which is two things to revoke and one more way for a teardown
 * to be half-done.
 */
export function planAncestors(plan: ConfinementPlan): string[] {
  const covered = [...plan.writable, ...plan.readable]
  const seen = new Set<string>()
  const chain: string[] = []
  for (const path of [...plan.writable, ...plan.readableFiles]) {
    if (!driveRooted(path)) continue
    for (const ancestor of ancestorsOf(path)) {
      const key = ancestor.toLowerCase()
      if (seen.has(key)) continue
      seen.add(key)
      if (covered.some((root) => within(ancestor, root, 'win32'))) continue
      chain.push(ancestor)
    }
  }
  return chain
}

/* ------------------------------------------------------------ the command line -- */

/**
 * What the network capability question is being answered as, and why it is a
 * question at all.
 *
 * An AppContainer with no capability has no network whatsoever, which would
 * make an agent CLI useless — it cannot reach the API it exists to call. So
 * `internetClient` (`S-1-15-3-1`) is granted, and nothing else: not
 * `internetClientServer`, which would let the session accept inbound
 * connections, and not `privateNetworkClientServer`, which would let it reach
 * the rest of the house's network. Neither is needed to run an agent, and both
 * are the kind of thing that is easy to add and impossible to notice.
 */
const CAPABILITIES = ['internet-client'] as const

/**
 * Is this a path this mechanism can do anything with at all?
 *
 * Drive-rooted, and nothing else. Two different things arrive here that are
 * not, and they need opposite treatment, which is why this is a predicate
 * rather than a filter:
 *
 *  - **The macOS system roots.** `sessionPlan` in `plan.ts` puts
 *    `MACOS_SYSTEM_READ_ROOTS` - `/System`, `/usr`, `/bin`, `/Library` and the
 *    rest - into the readable list of *every* plan it builds, on every
 *    platform, because until now nothing on Windows read a plan. Passing those
 *    to the launcher would ask it to write an ACL on `/usr` on a Windows
 *    machine, `GetNamedSecurityInfoW` would fail, and the launcher would refuse
 *    the session with an error naming a directory that has never existed there.
 *    They are dropped.
 *  - **A WSL or UNC folder.** `\\server\share` and `/home/asad/work` are real
 *    places a session might be granted, and neither can be held by an
 *    AppContainer: a Linux folder is a Linux process behind `wsl.exe`, which is
 *    refused inside a container outright, and a share has no ancestor an ACL
 *    can be written on from here. Those are a refusal, not a drop.
 */
function driveRooted(path: string): boolean {
  return /^[A-Za-z]:[\\/]/.test(path)
}

export interface AppContainerLaunch {
  /** The AppContainer name; {@link containerName} of the device's key. */
  container: string
  /** The plan, already resolved to real Windows paths. */
  plan: ConfinementPlan
  /**
   * The tool capability this session's token carries, and the paths the
   * one-time grant has already written an ACE for.
   *
   * Both come from `tools.ts`. The capability is what makes the tool
   * directories reachable without this session touching a permission; the
   * granted list is what keeps it from *trying* to — an ancestor ACE on `C:\`
   * needs an administrator, and a session that asked for one every time it
   * started is the design that was rejected.
   */
  tools: ToolGrant & {
    /** The capability SID, from `capabilitySid()`. */
    capability: string
    /**
     * An executable inside the granted tool directories that the proof starts
     * from *inside* the container, or `null` when the grant names no tool at
     * all — a machine with neither node nor git installed, where there is
     * nothing to check and a session is a shell in a folder.
     */
    probe: string | null
  }
}

/**
 * The ancestors this session has to write for itself.
 *
 * Everything on the way to the granted folder, the device's home and the
 * individual files, minus everything the one-time grant already covers. On a
 * normal machine that leaves the directories *under* the user's home — which the
 * user owns, so no privilege is needed — and nothing else.
 *
 * A path left in this list that the app cannot write is not a security failure
 * and must not be dressed up as one: the launcher refuses the session, loudly,
 * naming the directory. That is what happens for a folder granted on a second
 * drive whose root has never been through the one-time grant, and the remedy is
 * to run the grant again with that folder — `grantShortfall` in `tools.ts`
 * computes exactly what is missing so the prompt can name it.
 */
export function sessionAncestors(launch: AppContainerLaunch): string[] {
  const covered = (path: string): boolean =>
    launch.tools.ancestors.some((entry) => entry.toLowerCase() === path.toLowerCase()) ||
    launch.tools.read.some((root) => within(path, root, 'win32'))
  return planAncestors(launch.plan).filter((ancestor) => !covered(ancestor))
}

/**
 * The launcher's argument vector for one session, or a throw.
 *
 * A throw rather than a best-effort command for the same reason `confineSpawn`
 * throws: a caller that asked for confinement and cannot have it must not be
 * handed something that runs anyway.
 */
export function appContainerArgs(
  launch: AppContainerLaunch,
  command: string,
  args: readonly string[],
): string[] {
  if (!driveRooted(launch.plan.folder)) {
    throw new Error(
      `${launch.plan.folder} is not on a Windows drive, so an AppContainer cannot hold a session in it; a folder inside WSL is held by the Linux mechanism and a network share is not held at all`,
    )
  }
  const argv: string[] = ['--container', launch.container, '--station', STATION]
  for (const capability of CAPABILITIES) argv.push('--capability', capability)
  argv.push('--capability-sid', launch.tools.capability)
  for (const dir of launch.plan.writable.filter(driveRooted)) argv.push('--write', dir)
  for (const file of launch.plan.readableFiles.filter(driveRooted)) argv.push('--file', file)
  for (const dir of sessionAncestors(launch)) argv.push('--ancestor', dir)
  argv.push('--cwd', launch.plan.folder)
  argv.push('--', command, ...args)
  return argv
}

/**
 * Which desktop the session gets, and why it is not the stronger one.
 *
 * `own` makes the launcher create a window station and a desktop of its own,
 * which is the better isolation and needs an administrator: measured,
 * `CreateWindowStationW` answers `ERROR_ACCESS_DENIED` for a non-elevated token
 * in the user's own session. Terminal Deck is never elevated, so asking for it
 * would mean every session refusing to start.
 *
 * `shared` creates a private *desktop* on the station the app is already on. The
 * confined process still has no window of the user's on its desktop, and the
 * cost this was braced for did not materialise: `OpenClipboard` from inside the
 * container answers `ERROR_ACCESS_DENIED` even though the station is shared.
 *
 * A constant rather than an option because there is no caller who should be
 * choosing: the flag exists in the launcher so that the two are named and
 * measured separately, not so that a session picks one at runtime.
 */
const STATION = 'shared'

/**
 * The same paths, as the arguments that take the ACEs away again.
 *
 * For the case the launcher itself cannot cover: it revokes on every exit route
 * it controls, and being killed outright is not one of them. Run this after a
 * session that ended badly, or when a folder grant is withdrawn — the ACE from
 * a device that is no longer granted a folder is exactly the thing nobody would
 * think to look for.
 */
export function releaseArgs(launch: AppContainerLaunch): string[] {
  const argv: string[] = ['--container', launch.container, '--release']
  for (const dir of launch.plan.writable.filter(driveRooted)) argv.push('--write', dir)
  for (const file of launch.plan.readableFiles.filter(driveRooted)) argv.push('--file', file)
  for (const dir of sessionAncestors(launch)) argv.push('--ancestor', dir)
  return argv
}

/* ---------------------------------------------------------------- the environment -- */

/**
 * The environment a confined Windows session adds, which is not the one
 * `confinedEnv` builds.
 *
 * `plan.ts`'s version sets `HOME` and `TMPDIR` with `posix.join`, and says in
 * its own comment that it is allowed to because confinement exists on macOS and
 * Linux and nowhere else. That stops being true the moment this module is
 * wired, and the difference is not only the separator:
 *
 *  - **`USERPROFILE`, `HOMEDRIVE` and `HOMEPATH`** are where Windows programs
 *    actually look. `node`'s `os.homedir()` reads `USERPROFILE`;
 *    git-for-windows tries `HOME`, then `HOMEDRIVE` + `HOMEPATH`, then
 *    `USERPROFILE`. Setting only `HOME` leaves most of a session pointed at the
 *    owner's home directory, which is outside the boundary — measured: `git`
 *    reported `warning: unable to access 'C:/Users/…/.gitconfig': Permission
 *    denied` three times and then `fatal: unknown error occurred while reading
 *    the configuration files`. The boundary was working perfectly; the session
 *    was unusable.
 *  - **`APPDATA` and `LOCALAPPDATA`** are where almost everything on Windows
 *    keeps its state, and both are under the owner's home.
 *  - **`TEMP` and `TMP`**, not `TMPDIR`, are what Windows programs read. The
 *    default is a directory under the owner's home, so a session without them
 *    redirected has no writable temp at all.
 */
export function windowsConfinedEnv(home: string): Record<string, string> {
  const parsed = win32.parse(home)
  return {
    HOME: home,
    USERPROFILE: home,
    HOMEDRIVE: parsed.root.replace(/\\+$/, ''),
    HOMEPATH: home.slice(parsed.root.length - 1),
    APPDATA: win32.join(home, 'AppData', 'Roaming'),
    LOCALAPPDATA: win32.join(home, 'AppData', 'Local'),
    TEMP: win32.join(home, 'tmp'),
    TMP: win32.join(home, 'tmp'),
  }
}

/* ---------------------------------------------------------------------- the proof -- */

export interface AppContainerProof {
  ok: boolean
  /** What was measured. Empty when it held. */
  detail: string
}

/** How the proof runs the launcher. Injected so a test needs no Windows. */
export interface LauncherRunner {
  (
    command: string,
    args: readonly string[],
  ): Promise<{ stdout: string; stderr: string; code: number | null }>
}

/**
 * The real one: run the launcher and treat a non-zero exit as data.
 *
 * `type` of a refused file exits 1, which is `execFile` rejecting, and that
 * rejection *is* the result the proof wants. Its `stdout` still has to be read,
 * because "it failed" and "it failed after printing the secret" are different
 * answers and only one of them is a boundary.
 */
const realRunner: LauncherRunner = async (command, args) => {
  try {
    const result = await run(command, [...args], {
      timeout: 30_000,
      maxBuffer: 1024 * 1024,
      encoding: 'utf8',
      windowsHide: true,
    })
    return { stdout: result.stdout, stderr: result.stderr, code: 0 }
  } catch (error) {
    const wrapped = error as { stdout?: string; stderr?: string; code?: number | null }
    return {
      stdout: typeof wrapped.stdout === 'string' ? wrapped.stdout : '',
      stderr: typeof wrapped.stderr === 'string' ? wrapped.stderr : String(error),
      code: typeof wrapped.code === 'number' ? wrapped.code : null,
    }
  }
}

/**
 * How the proof writes and removes its two canaries.
 *
 * A seam for exactly one reason, and it is the same reason `platform/host.ts`
 * takes the platform as an argument at length: this is Windows-only code and
 * the machine it is developed on is not Windows, so a test that cannot reach it
 * is a test that never runs. Every path in a Windows plan begins with a drive
 * letter, which no macOS filesystem will accept, so without this the two
 * failure shapes that matter most - a canary that lands inside the boundary,
 * and a launcher that runs nothing - could only be checked by reading the code.
 */
export interface ProbeFiles {
  write(path: string, contents: string): void
  remove(path: string): void
}

const realFiles: ProbeFiles = {
  write(path, contents) {
    writeFileSync(path, contents)
  },
  remove(path) {
    rmSync(path, { force: true })
  },
}

/**
 * Ask the machine, not the platform name, whether this plan confines anything.
 *
 * One run of the launcher, and it carries both halves of the test — which is
 * the whole design of it. `cmd /c type <inside> <outside>` prints two files:
 *
 *  1. `<inside>` is a file of random bytes in a directory the plan makes
 *     writable. Its contents **must** come back. If they do not, either the
 *     launcher would not start anything or the boundary is so tight that
 *     nothing runs, and a plan under which nothing runs would otherwise pass
 *     the second check by failing at everything — the exact shape of false
 *     confidence `seatbelt.ts` guards against, and the reason this is not a
 *     single negative check.
 *  2. `<outside>` is a file of random bytes written where a leak would matter,
 *     in the account's own home. Its contents **must not** come back.
 *
 * One process rather than two because the launcher writes the plan's ACEs on
 * the way in and takes them off on the way out, and that costs a walk of the
 * granted folder each time — 0.57s over a 5,000-file tree, measured, and more
 * on a large repository. Halving the number of walks is worth the one shell
 * builtin that takes two filenames.
 *
 * Run per session rather than cached, for the reason the other two platforms
 * give: caching would answer a question about *this* plan with a measurement of
 * a different one. On Windows it also matters that the answer genuinely varies
 * — the window station a session is granted belongs to the logon session it was
 * created in, and a folder two levels under `C:\` and one twelve levels under a
 * redirected profile are not the same test.
 */
export async function proveAppContainer(
  launch: AppContainerLaunch,
  launcher: string,
  probeDir: string,
  runner: LauncherRunner = realRunner,
  files: ProbeFiles = realFiles,
): Promise<AppContainerProof> {
  const stamp = randomBytes(9).toString('hex')
  const insideSecret = randomBytes(24).toString('hex')
  const outsideSecret = randomBytes(24).toString('hex')
  const token = randomBytes(12).toString('hex')
  const inside = win32.join(probeDir, `.terminaldeck-confine-probe-${stamp}`)
  const outside = win32.join(launch.plan.accountHome, `.terminaldeck-confine-probe-${stamp}`)

  if (!launch.plan.writable.some((root) => within(inside, root, 'win32'))) {
    return {
      ok: false,
      detail: `the file used to test that anything runs (${inside}) is not inside the boundary, so the test could not pass`,
    }
  }
  if ([...launch.plan.writable, ...launch.plan.readable].some((root) => within(outside, root, 'win32'))) {
    // Reached when the grant covers the account's home directory. Refusing is
    // the honest answer: there would be nothing left for the session to be held
    // inside, and the check that was supposed to notice cannot.
    return {
      ok: false,
      detail: `the file used to test the boundary (${outside}) is inside it, so the test could not fail`,
    }
  }

  try {
    files.write(inside, insideSecret)
    files.write(outside, outsideSecret)
  } catch (error) {
    return { ok: false, detail: `could not write a canary to test it: ${describe(error)}` }
  }

  try {
    const args = appContainerArgs(launch, cmdExe(), [
      '/d',
      '/c',
      probeScript({ inside, outside, tool: launch.tools.probe, token }),
    ])
    const ran = await runner(launcher, args)
    if (!ran.stdout.includes(insideSecret)) {
      return {
        ok: false,
        detail: `the launcher would not run a command inside the container${why(ran)}`,
      }
    }
    if (ran.stdout.includes(outsideSecret)) {
      return { ok: false, detail: 'a file outside the folder was readable from inside the container' }
    }
    if (launch.tools.probe !== null && !ran.stdout.includes(token)) {
      return {
        ok: false,
        detail:
          `a session in the container could not start ${launch.tools.probe}, so it would be a ` +
          'terminal with no tools in it; the one-time permission for the tool folders is missing ' +
          'or has been removed',
      }
    }
    return { ok: true, detail: '' }
  } catch (error) {
    return { ok: false, detail: describe(error) }
  } finally {
    // Best effort on purpose, on both. A canary left behind is a file of random
    // hex; a throw here would turn a boundary that held into a session that
    // would not start.
    files.remove(inside)
    files.remove(outside)
  }
}

/**
 * The one command line the proof runs, with all three questions in it.
 *
 * `&` between the parts rather than `&&`, so a refusal does not stop the rest —
 * every question has to be answered on the same run, because each run pays for
 * the granted folder's ACL walk.
 *
 * The tool check is the third part and its shape is deliberate. `<tool> -v`
 * writes its version somewhere nobody reads, and the **token is echoed only if
 * that exited zero**. Matching on the tool's output would mean parsing a version
 * string, and matching on an error message would mean matching `Access is
 * denied` — which on the machine this was measured on is printed in Russian,
 * because the account's display language is. An exit code is the same in every
 * language.
 *
 * `-v` rather than `--version` because the tools this can be pointed at are
 * `node.exe` and `git.exe`, and `-v` is the flag both of them answer.
 */
function probeScript(input: {
  inside: string
  outside: string
  tool: string | null
  token: string
}): string {
  const read = `type ${quoted(input.inside)} ${quoted(input.outside)}`
  if (input.tool === null) return read
  return `${read} & ${quoted(input.tool)} -v >nul 2>&1 && echo ${input.token}`
}

/**
 * One argument for a `cmd /c` line, quoted if it needs it.
 *
 * `cmd` splits on spaces and a path like `C:\Program Files\nodejs\node.exe` is
 * the case that matters — it is where node is on a default Windows install, so
 * the unquoted version is not an edge case, it is the normal one.
 */
function quoted(value: string): string {
  return value.includes(' ') ? `"${value}"` : value
}

/**
 * `cmd.exe` by absolute path, from `ComSpec` when it is set.
 *
 * Not by name. The launcher builds a command line for `CreateProcessW` with a
 * null `lpApplicationName`, so a bare `cmd.exe` would be resolved against the
 * `PATH` *the confined process inherits* — and a session that resolved its own
 * proof's shell through an attacker-controlled `PATH` entry is a proof that
 * proves nothing.
 */
function cmdExe(env: NodeJS.ProcessEnv = process.env): string {
  const spelled = env.ComSpec ?? env.COMSPEC
  if (spelled !== undefined && spelled !== '') return spelled
  const root = env.SystemRoot ?? env.SYSTEMROOT ?? 'C:\\Windows'
  return win32.join(root, 'System32', 'cmd.exe')
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Why a probe did not answer, in the launcher's own words where there are any.
 *
 * The launcher prints a line beginning `tdconfine:` for every failure it
 * produces itself, and that line is the whole diagnosis — "could not create a
 * window station (0x00000005)" says what to do, where "Command failed with exit
 * code 123" does not.
 */
function why(ran: { stderr: string; code: number | null }): string {
  const printed = ran.stderr
    .split('\n')
    .map((line) => line.trim())
    .find((line) => line.startsWith('tdconfine:'))
  if (printed !== undefined) return `: ${printed}`
  const first = ran.stderr.trim().split('\n')[0]
  if (first !== undefined && first !== '') return `: ${first}`
  return ran.code === null ? '' : ` (exit ${ran.code})`
}

/* ------------------------------------------------------------------ the wording -- */

/**
 * Why Windows still answers `'none'`, in a sentence that names the mechanism
 * and does not overstate what is missing.
 *
 * The sentence `unconfinedReason('win32')` carries today says these mechanisms
 * "has not been built or measured". Measured is no longer true — every one of
 * them has been, on a real machine, and two of them are written off rather than
 * open. So this replaces it, and the shape of the replacement matters: it says
 * what *is* the mechanism, what is missing before it can be switched on, and
 * keeps the WSL caveat in its own sentence because a session inside WSL cannot
 * be covered by any Windows mechanism at all.
 */
export const WINDOWS_UNCONFINED_REASON =
  'Windows confinement is built on AppContainer and needs a launcher this build does not ship; ' +
  'restricted tokens and job objects were measured and are not boundaries on their own. ' +
  'A session in a WSL folder is a Linux process and is held by the Linux mechanism instead, not by this one.'

/**
 * The other reason Windows can be unconfined, and it is a different sentence
 * because it has a different remedy.
 *
 * The launcher shipping and the machine being set up are two facts, and running
 * them together would produce the worst kind of message: one that tells somebody
 * a feature is missing from their copy of the app when it is one click away.
 * This is the one a user can act on.
 */
export const WINDOWS_SETUP_NEEDED =
  'Windows confinement is built on AppContainer and needs a one-time permission, granted once ' +
  'with an administrator prompt, on the folders holding node, git and the agent CLIs. Until that ' +
  'is done a session from a device runs the way it always has. ' +
  'A session in a WSL folder is a Linux process and is held by the Linux mechanism instead, not by this one.'

/**
 * The sentence the grant screen owes a Windows user, and it is not the macOS one.
 *
 * Kept here rather than in the renderer because it is a fact about the
 * engineering — see `unconfinedReason`'s comment for the same argument — and
 * because the difference it describes is the one thing about the Windows
 * boundary that a person choosing who to hand a device to would want to know
 * and would not guess.
 */
export const WINDOWS_GRANT_NOTE =
  'On Windows a session started from a device can see the names of the folders on the way down ' +
  'to its own folder, including your home folder, the way a directory listing shows them. It ' +
  'cannot open any of them, and it cannot see anything else on the disk.'

/**
 * What the one-time permission actually does, in the words the prompt for it
 * owes the person clicking Yes.
 *
 * This used to be a value stating two options and refusing to choose between
 * them, because the choice looked like a product decision: keep the app
 * launching the tools, or grant the tool trees. It was not one. On Windows every
 * session is `cmd.exe /c <cli>` — `providers.ts` has always built it that way,
 * because the agent CLIs are npm shims and `CreateProcess` will not run a batch
 * file — so the shell *is* what starts the tools, in an agent session as much as
 * in a terminal. Without the grant there is no working Windows session of any
 * kind, which makes it a requirement rather than a preference.
 *
 * It is smaller than the earlier estimate as well: the grant names the
 * directories that actually hold tools, not every directory on the `PATH`, and
 * it touches nothing in `C:\Program Files` itself.
 */
export const WINDOWS_TOOL_LAUNCH =
  'A confined session can only run a program it has been given permission to read. This grants ' +
  'read and run — never write — on the folders holding node, git and the agent CLIs, and the ' +
  'right to list (not open) the folders on the way to them, including your home folder. It is ' +
  'asked for once. Sessions from a device get it; nothing else on the machine does.'
