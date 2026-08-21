/**
 * Turning a folder grant into a boundary — or refusing to pretend it is one.
 *
 * ## What changed, and what did not
 *
 * A folder grant used to decide **where a session starts**. It still does. What
 * is new is that on a platform which can enforce it, the session is also *held*
 * there: `cd ..` finds nothing, an absolute path elsewhere is refused, a symlink
 * pointing out of the folder is refused, the owner's home is not listable and
 * the owner's stored logins are not readable. `remote/folder-grants.ts` and
 * `remote/session-create.ts` still decide *which* folder; this decides what the
 * folder means once the session is running.
 *
 * ## One model, for every device
 *
 * There is no owner tier and no guest tier. Every connected device is the same
 * kind of thing with the same grants, so confinement is not a mode switched on
 * for strangers — it is what a folder grant *is*. A session started from the
 * window on this machine is not confined, because that is a person sitting at
 * their own keyboard with no grant involved; a session started from a device is
 * confined, whoever owns the device.
 *
 * ## Where it holds, where it does not, and why the difference is loud
 *
 * **macOS: confined.** Seatbelt, through `sandbox-exec`. `seatbelt.ts` lists
 * every escape that was attempted and what happened, all of it measured on
 * macOS 27 rather than read.
 *
 * **Windows: confined once the machine has been set up, and not before.**
 * AppContainer, through a launcher this repository compiles, because the
 * container has to be applied inside the `CreateProcess` call and nothing
 * reachable from Node can make it. Restricted tokens and job objects were
 * measured on the same machine and are not boundaries on their own;
 * `appcontainer.ts` and `CONFINEMENT.md` say what each of them did.
 *
 * The "once the machine has been set up" is the part that is unlike the other
 * two platforms, and it is not a caveat that can be engineered away. An
 * AppContainer reaches a file only through an ACE, and the ACEs a session needs
 * on `C:\`, `C:\Users` and the directories holding node and git cannot be
 * written by an unprivileged process — measured with a real non-elevated token,
 * not inferred. Writing them per session would mean an administrator prompt per
 * session. So they are written **once**, to a capability SID rather than to a
 * per-device container SID, and `tools.ts` owns that. Until it has happened,
 * {@link confinementKind} answers `'none'` for Windows and the grant screen says
 * so in its own sentence — the same shape as a platform with no mechanism at
 * all, because from the user's side that is exactly what it is.
 *
 * **Linux, including WSL: confined.** A user namespace, a mount namespace, a
 * PID namespace, and every capability dropped before the shell starts.
 * `linux.ts` lists what was attempted and what happened, all of it run on a
 * real Ubuntu 24.04 under WSL2 (kernel `6.18.33.2-microsoft-standard-WSL2`)
 * rather than read. The two doors `CONFINEMENT.md` said were unmeasured are
 * measured and both are shut:
 *
 *  - **The `wsl.exe --cd` launch path** — the one the Windows build uses, which
 *    none of the earlier probing went through — was run. A session started that
 *    way through {@link linuxShellLine} refuses the owner's home, keeps its own
 *    folder, and runs `git`, `node` and the agent CLI.
 *  - **`WSL_INTEROP`** turned out to be worse than advertised and is now
 *    understood. Unsetting the variable is *not* enough: with the variable gone
 *    and `/run/WSL` left alone, a Windows `.exe` sitting inside the granted
 *    folder still executed — the interop handler finds its socket without it.
 *    Covering `/run/WSL` is the half that closes it. Both are done.
 *
 * Two escapes that the earlier probing did not look for were found here and
 * closed, and one of them is the reason this module does not trust a mechanism
 * until it has watched it: the working directory a launcher sets *before* the
 * namespace exists belongs to the tree that is about to be covered, so every
 * **relative** path in the session walked straight out of the boundary while
 * `pwd`, `/proc/self/cwd` and `cd .. && ls` all looked perfect. The other was
 * signals: without a PID namespace a confined session killed a process of the
 * account's outside the boundary, and `kill -TERM -1` from inside took down the
 * login session that had launched it.
 *
 * One box's kernel is also not "Linux". A distribution with AppArmor's
 * unprivileged-userns restriction switched on fails at the first step, which is
 * why {@link proveConfinement} asks the machine rather than the platform name —
 * and why, on this side, it reads its canary from *outside* the boundary first:
 * a canary that is unreadable everywhere would pass a test it could never fail.
 *
 * ## What it costs, stated where somebody will find it
 *
 * A confined session cannot read the account's home directory, and the account's
 * home directory is where the agent CLIs keep their configuration. So a confined
 * session is given a home of its own and starts **signed out** of them — the
 * same decision `remote/credentials.ts` already made for `gh`, applied to the
 * rest. Signing in from the device puts the login in that device's own home,
 * where the owner's is not.
 *
 * ### Where its transcripts go, and who now knows
 *
 * A confined session's agent transcripts land under that home rather than under
 * `~/.claude`, which used to mean chat mode, the cost pane, alerts and the agent
 * controls all showed nothing for a session that was talking — each of them
 * reading the right directory for the wrong home. That is closed, and closed the
 * only honest way: nothing is copied and nothing is symlinked, the session keeps
 * writing where it was always going to write, and the transcript layer is told
 * where the homes are. `host-core.ts` calls `installDeviceHomes` at assembly and
 * `transcript.ts` carries the measurement — with the real CLI, `HOME=<dir>`
 * alone puts the transcripts at `<dir>/.claude/projects/…`.
 *
 * ## No silent downgrade
 *
 * The rule that makes the screen's wording true: on a platform where
 * confinement is available, a session from a device either starts confined or
 * **does not start**. It never quietly falls back. That is why {@link
 * proveConfinement} runs before the spawn rather than after, and why its failure
 * is thrown rather than logged — a session that reports "connected" while
 * running outside its boundary is precisely the failure this project has been
 * bitten by before, in a different subsystem, for the same reason: the side that
 * reports success was not the side that had to do the work.
 *
 * ## Two things this does not cover, which nothing on screen may imply it does
 *
 * **Attaching is not starting.** A device may attach to a session that is
 * already running and type into it, and that path has never had a folder check
 * — it is the product's headline feature, driving the session on your desk from
 * your phone. So a device can reach an *unconfined* shell: any session the owner
 * started at the keyboard. The grant screen says this in its own sentence. The
 * decision of whether attach should be restricted to granted folders is a
 * product decision about that feature, not a gap in this module, and it belongs
 * to whoever owns the answer to "should my phone still be able to drive the
 * session I left open".
 *
 * **Restore would have lapsed the boundary, so confined sessions are not
 * restored.** A `SavedSession` records a folder and a provider and no device, so
 * a relaunch has nothing to rebuild a plan from; it would bring the session back
 * as an ordinary tab, and the same device could attach to it. `host-core.ts`
 * therefore does not write a confined session into the ledger, at the cost of
 * those sessions not surviving a restart. The real fix is for the ledger to
 * carry the device.
 *
 * ## The proof is not the profile
 *
 * A generated profile that *looks* right proves nothing, and a unit test that
 * asserts a string contains a path proves less. So before a session is spawned,
 * a file with random contents is written **outside** every directory in the
 * plan, and the real `sandbox-exec` is asked to read it with the real profile.
 * If those bytes come back, confinement is not working on this machine and the
 * session is refused. A second command, which must succeed, is run alongside it
 * — otherwise a profile so broken that nothing at all runs would pass the first
 * check by failing at everything.
 */

import { execFile } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join, posix } from 'node:path'
import { promisify } from 'node:util'
import { currentPlatform, type Platform } from '../platform/host'
import {
  appContainerArgs,
  containerName,
  proveAppContainer,
  realFiles,
  WINDOWS_SETUP_NEEDED,
  WINDOWS_UNCONFINED_REASON,
  windowsConfinedEnv,
  type AppContainerLaunch,
  type LauncherRunner,
  type ProbeFiles,
} from './appcontainer'
import {
  readGrantRecord,
  toolProbe,
  windowsConfinementReady,
  windowsToolsInstall,
} from './tools'
import {
  LINUX_SHELL,
  linuxCommand,
  linuxProofArgs,
  linuxShellLine,
  readProofReport,
  realMachine,
  stagePath,
  type LinuxMachine,
} from './linux'
import {
  confinedEnv,
  deviceHomeDir,
  deviceHomesRoot,
  deviceKeyOf,
  sessionPlan,
  within,
  type ConfinementPlan,
  type PathResolver,
  type SessionPlanInput,
} from './plan'
import { SANDBOX_EXEC, seatbeltCommand, seatbeltProfile } from './seatbelt'

const run = promisify(execFile)

/**
 * How this platform confines a session, if it does.
 *
 * A string rather than a boolean because "not confined" has to be able to say
 * *why*, and because a second mechanism arriving later — a Linux one — should
 * be a new value here rather than a second boolean somewhere else.
 */
export type ConfinementKind = 'seatbelt' | 'namespace' | 'appcontainer' | 'none'

export function confinementKind(platform: Platform = currentPlatform()): ConfinementKind {
  if (platform === 'darwin') return 'seatbelt'
  // `linux` covers a Linux desktop, the headless host on a server, and a
  // session inside WSL — the last of which reports `win32` here, because the
  // *app* is a Windows process. Whoever launches into WSL has to ask for the
  // Linux answer explicitly; see {@link linuxShellLine} for the launch line
  // that path needs and `wsl.ts` for why it is a shell line rather than an
  // argument vector.
  if (platform === 'linux') return 'namespace'
  /*
   * Windows is the one platform whose answer is not a property of the platform.
   *
   * The other two mechanisms are there or not depending on the operating
   * system, and `sandbox-exec` and `unshare` ship with it. This one needs two
   * things that a Windows machine does not come with: a launcher this project
   * compiles, and a one-time permission on the folders holding node, git and
   * the agent CLIs that only an administrator can write. `tools.ts` explains why
   * the permission cannot be per session — measured, an unprivileged process
   * cannot write the ACL of `C:\` or `C:\Users`, and a confined session that
   * cannot list those cannot resolve an absolute path.
   *
   * Answering `'none'` until both are true is the honest reading of what this
   * function means. It is asked "does this machine have a boundary this
   * repository has measured", and on a Windows machine where the grant has never
   * been made the answer is no — not "yes, but every session will refuse to
   * start", which is what claiming the kind here would produce. When the grant
   * *is* there, this answers `'appcontainer'` and the per-session probe still
   * has to pass before anything claims to be confined; see
   * {@link proveConfinement}.
   */
  if (platform === 'win32') return windowsConfinementReady() ? 'appcontainer' : 'none'
  return 'none'
}

/**
 * Why a platform is not confined, in a sentence that names the mechanism it
 * would have used.
 *
 * Written here rather than in the renderer because it is a fact about the
 * engineering, not about the layout, and because the two must not drift: the
 * grant panel says the same thing in the user's words, and this is what it is
 * saying it about.
 */
export function unconfinedReason(platform: Platform): string {
  if (platform === 'win32') {
    /*
     * Two sentences, because there are two reasons and they have different
     * remedies — and neither is the sentence this used to carry, which said
     * these mechanisms "has not been built or measured". That was written when
     * it was true. It has not been true since the launcher was written and put
     * through a real Windows 11 machine: AppContainer holds, restricted tokens
     * and job objects were measured and written off, and the whole account is in
     * `CONFINEMENT.md`. A UI sentence that outlives its measurement is the same
     * kind of lie as a boundary that outlives its proof.
     *
     * Which of the two applies is a fact about this machine, so it is asked of
     * the machine: a build without the launcher cannot be fixed by the user, and
     * a machine without the one-time grant can be, in one prompt.
     */
    const install = windowsToolsInstall()
    const shipped = install !== null && existsSync(install.launcher)
    return shipped ? WINDOWS_SETUP_NEEDED : WINDOWS_UNCONFINED_REASON
  }
  return 'No confinement mechanism has been measured on this platform.'
}

/* ------------------------------------------------------------- the failure -- */

/**
 * Thrown when a session should have been confined and could not be.
 *
 * Its own class because the caller has to be able to tell it apart from "the
 * folder was deleted", which is the other reason a spawn fails and has a
 * completely different remedy. `remote/session-create.ts` turns it into a
 * sentence for the phone.
 */
export class ConfinementUnavailableError extends Error {
  constructor(readonly detail: string) {
    super(`This session could not be confined to its folder: ${detail}`)
    this.name = 'ConfinementUnavailableError'
  }
}

/* ---------------------------------------------------------------- the plan -- */

/** The filesystem, for real. Injected everywhere else so tests need none. */
export const realResolver: PathResolver = {
  real(path: string): string {
    try {
      return realpathSync(path)
    } catch {
      // A path that cannot be resolved is passed through unchanged rather than
      // dropped. It will simply match nothing, which is the safe direction — and
      // the alternative, silently removing it, would turn a typo in a grant into
      // a session with a *smaller* boundary than the person asked for, with
      // nothing on screen to say so.
      return path
    }
  },
  isDirectory(path: string): boolean {
    try {
      return statSync(path).isDirectory()
    } catch {
      return false
    }
  },
}

/**
 * What one device's sessions get on top of the granted folder.
 *
 * Built once per session by the caller, because two of the three values come
 * from parts of the app this module has no business knowing about: where the
 * credential proxy keeps a device's guest git directory, and where its helper
 * script lives.
 */
export interface DeviceConfinement {
  /** The device's own home directory, created if it is not there. */
  home: string
  /** Directories the session must be able to write, beyond the folder and home. */
  writable: readonly string[]
  /** Individual files it must be able to read and execute. */
  files: readonly string[]
  /**
   * Directories the session may **read and never write**.
   *
   * The copilot's grant over the projects a person has already added to this
   * app, and nothing else uses it — a session from a paired device is confined
   * to the one folder that was granted to it, and stays that way.
   *
   * It rides on this interface rather than being a separate argument to
   * {@link planFor} so that the copilot's spawn goes through `startSession`
   * exactly like every other session, carrying its wider grant in the same
   * envelope the narrower ones travel in. A second parameter would have meant a
   * second code path through the one function in this app that starts a
   * session, which is the thing the copilot's design is built on not doing.
   *
   * Optional, so every existing caller keeps meaning what it already meant.
   */
  projects?: readonly string[]
  /**
   * Which device this confinement was built for, when it was built for one.
   *
   * Nothing in `confine/` reads it and nothing here ever should: a boundary is
   * made of paths, and the day it starts varying by *who* is behind it is the
   * day two devices get two different sandboxes from one function. It rides here
   * because `host-core.ts`'s launch gate needs it and this is the only envelope
   * that already travels from the device path into `startSession` — the same
   * argument {@link projects} makes for itself one field up, which is that a
   * second parameter would mean a second code path through the one function in
   * this app that starts a session.
   *
   * Absent for the copilot's confinement, which belongs to no device.
   */
  deviceId?: string
}

/**
 * Make and return a device's confined home.
 *
 * Created here rather than at the spawn, and eagerly rather than on first write,
 * because `HOME` pointing at a directory that does not exist is a different and
 * much more confusing failure than one that is simply empty: `zsh` prints
 * nothing, `npm` reports a permissions error about a path the person cannot see,
 * and none of it says "the app did not make this".
 *
 * `0700` for the same reason every other per-device directory in this app is:
 * one account owns the machine, but nothing here needs to be readable by
 * another one.
 */
export function prepareDeviceHome(root: string, deviceKey: string): string {
  const home = deviceHomeDir(root, deviceKey)
  mkdirSync(join(home, 'tmp'), { recursive: true, mode: 0o700 })
  /*
   * The agent's store, made now rather than left to the CLI.
   *
   * The CLI creates it the moment it writes its first line, so this changes
   * nothing about where anything lands — it changes *when the directory exists*,
   * and that turns out to matter to the thing reading it. The cost pane watches
   * these stores for a session's conversation, and a file watcher aimed at a
   * tree that is being created underneath it is unreliable in a way that is easy
   * to mistake for slowness: measured here, a burst that made
   * `<home>/.claude/projects/<project>/<session>.jsonl` in one go was still
   * undelivered eight seconds later, while the same file created inside a
   * directory that already existed arrived immediately.
   *
   * So the two levels the app can know in advance are made in advance, and only
   * the project directory — a direct child of a watched one, which is the case
   * that was measured as reliable — appears while anybody is watching.
   */
  mkdirSync(join(home, '.claude', 'projects'), { recursive: true, mode: 0o700 })
  /*
   * The file that stops a login shell greeting a session that nobody is reading
   * a greeting in.
   *
   * Measured on Ubuntu 24.04 under WSL, in a confined session started through
   * the real `wsl.exe --cd` launch: the first session of the day opened with
   * the distribution's whole message of the day, and one of its scripts failed
   * while printing it — `ERROR: Permission denied, try: sudo
   * /usr/sbin/update-motd` — and then told the person to create exactly this
   * file, naming a directory only this app knows about. A device connecting to
   * a folder does not need Canonical's Kubernetes advertisement, and it
   * certainly does not need a permission error at the top of its first tab.
   *
   * `bash` and `zsh` both honour it, so this is also what stops the "Last
   * login:" line on macOS. Empty, because its existence is the whole signal.
   */
  writeFileSync(join(home, '.hushlogin'), '', { mode: 0o600 })
  return home
}

/** The device-homes root, re-exported so callers need one import. */
export { deviceHomesRoot }

/**
 * The Windows pieces `host-core.ts` has to hand over at assembly, re-exported
 * here so that the one file wiring this feature imports from one place.
 *
 * `installWindowsTools` is the same shape as `installDeviceHomes` and is there
 * for the same reason: where Electron unpacked its resources and where this
 * install keeps its storage are facts about the app, and `confine/` has no way
 * to learn either without being told.
 */
export { installWindowsTools, windowsToolsFor } from './tools'

/**
 * The environment a confined *Windows* session needs, which is not the one
 * `confinedEnv` builds. Re-exported for the same reason.
 */
export { windowsConfinedEnv }

/** The environment a confined session adds. Re-exported so callers need one import. */
export { confinedEnv }

/**
 * The environment a confined session adds **on this platform**, chosen once.
 *
 * ## Why this is a function rather than two exports and a ternary
 *
 * Because it was two exports and a ternary, and the ternary was written twice —
 * correctly in `host-core.ts`, where the session is spawned, and not at all in
 * `copilot-session.ts`, where the sign-in probe was added later and called
 * `confinedEnv` directly. That is not a typo anybody could have caught by
 * reading either file: each one is locally sensible, and the platform that
 * takes the missing branch is not the platform either of them was written on.
 *
 * What it cost, concretely. The probe runs `claude auth status --json` with the
 * copilot's own home so that it reports the *copilot's* login rather than the
 * machine's, and `confinedEnv` expresses "its own home" as `HOME` and `TMPDIR`.
 * On Windows almost nothing reads either: `os.homedir()` reads `USERPROFILE`,
 * git reads `HOMEDRIVE`+`HOMEPATH`, and scratch space is `TEMP`/`TMP`. So the
 * probe would have run with the copilot's `HOME` and the *owner's* everything
 * else — the exact failure the comment above the probe's `CLAUDE_CONFIG_DIR`
 * warns about, arriving through the variable beside it.
 *
 * `confinementKind` rather than a bare `platform === 'win32'`, because the
 * question is which mechanism is holding this session, and on Windows that is
 * not a property of the platform: before the one-time AppContainer grant the
 * answer is `'none'`, and a session that is not confined at all has no
 * redirected home to describe. Callers gate on `confinementKind` before asking
 * for this, and this asks the same question again rather than a different one
 * that happens to agree today.
 */
export function confinedHomeEnv(
  home: string,
  platform: Platform = currentPlatform(),
): Record<string, string> {
  return confinementKind(platform) === 'appcontainer' ? windowsConfinedEnv(home) : confinedEnv(home)
}

/**
 * The plan for one session, from the pieces the spawn path holds.
 *
 * `agentConfigDir` is the one argument that is not obviously needed. A session
 * running under a named profile is told, through `CLAUDE_CONFIG_DIR`, to keep
 * its agent login in a directory the app owns — and that directory is outside
 * the granted folder, so without a rule for it the CLI is pointed at somewhere
 * it cannot open and reports being unable to start rather than being logged
 * out. It is absent for the system profile, where the CLI is left to find its
 * own default inside the device's home, which is exactly where a confined
 * session's login should live.
 */
export function planFor(input: {
  folder: string
  device: DeviceConfinement
  accountHome: string
  path: string
  agentConfigDir?: string | undefined
  platform: Platform
  resolver?: PathResolver
}): ConfinementPlan {
  const spec: SessionPlanInput = {
    folder: input.folder,
    home: input.device.home,
    accountHome: input.accountHome,
    path: input.path,
    writable: [
      ...input.device.writable,
      ...(input.agentConfigDir === undefined ? [] : [input.agentConfigDir]),
    ],
    files: input.device.files,
    projects: input.device.projects ?? [],
    resolver: input.resolver ?? realResolver,
    platform: input.platform,
  }
  return sessionPlan(spec)
}

/* --------------------------------------------------------------- the proof -- */

export interface ConfinementProof {
  ok: boolean
  /** What was measured. Empty when it held. */
  detail: string
}

/**
 * How the proof runs a command. Injected only so a test can pin the two failure
 * shapes — a leak, and a sandbox that refuses everything — without needing a
 * machine on which either is true.
 */
export interface ProofRunner {
  (command: string, args: readonly string[]): Promise<{ stdout: string; stderr: string }>
}

const realRunner: ProofRunner = async (command, args) => {
  const result = await run(command, [...args], {
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
    encoding: 'utf8',
  })
  return { stdout: result.stdout, stderr: result.stderr }
}

/**
 * Ask the machine, not the code, whether this plan confines anything.
 *
 * Two commands, and the second is the one that makes the first mean something:
 *
 *  1. Read a file full of random bytes that was just written **outside** every
 *     directory in the plan. If those bytes come back, there is no boundary.
 *  2. Print a token. If that does not come back, the profile is broken rather
 *     than strict — and a profile under which nothing runs would have passed
 *     check 1 by failing at everything, which is the exact shape of false
 *     confidence this project has shipped before.
 *
 * Run per session rather than cached. It costs two short-lived processes on a
 * path that already waits for the login shell's `PATH` and a probe of which
 * agent CLIs are installed, and caching it would mean answering a question about
 * *this* plan with a measurement of a different one.
 *
 * A canary that lands inside the plan is treated as a failed proof rather than
 * as a pass. It would be readable by design, so the check could not tell a
 * working boundary from a broken one, and answering "confined" on the strength
 * of a test that cannot fail is worse than answering "unknown".
 *
 * ## Why `files` is a parameter, and what it cost not to have one
 *
 * `appcontainer.ts` grew a {@link ProbeFiles} seam for its canaries, and gave
 * the reason in its own comment: every path in a Windows plan begins with a
 * drive letter, no macOS filesystem will accept one, so a proof that writes its
 * canaries through `fs` directly is a proof no test on this machine can drive.
 * That seam stopped one level short — it existed on `proveAppContainer` and was
 * unreachable from here — which made the whole Windows branch of this function,
 * and of {@link confineSpawn}, untestable through its real entry point.
 *
 * The workaround the test settled on is the reason this is now threaded through.
 * It let the *real* `fs` write `C:\Users\Imza\AppData\…\.terminaldeck-confine-probe`,
 * which on macOS is not a path at all: backslashes are ordinary characters here,
 * so it is one long filename in the working directory, and the write succeeds.
 * On Windows it is a real absolute path to a directory that has never existed on
 * the runner, the write is `ENOENT`, and the proof correctly reports that it
 * could not plant a canary — so the one test asserting that Windows spawns the
 * launcher failed on the one platform where it is not hypothetical. Passing the
 * files in makes both machines run the identical code path.
 */
export async function proveConfinement(
  plan: ConfinementPlan,
  platform: Platform = currentPlatform(),
  runner: ProofRunner = realRunner,
  machine: LinuxMachine = realMachine,
  files: ProbeFiles = realFiles,
): Promise<ConfinementProof> {
  const kind = confinementKind(platform)
  if (kind === 'namespace') return proveNamespace(plan, runner, machine)
  if (kind === 'appcontainer') return proveWindows(plan, runner, files)
  if (kind !== 'seatbelt') return { ok: false, detail: unconfinedReason(platform) }

  const profile = seatbeltProfile(plan)
  const token = randomBytes(16).toString('hex')
  const secret = randomBytes(24).toString('hex')

  let dir: string
  try {
    dir = mkdtempSync(join(realResolver.real(tmpdir()), 'confine-proof-'))
  } catch (error) {
    return { ok: false, detail: `could not write a canary to test it: ${describe(error)}` }
  }
  const canary = join(dir, 'canary')

  try {
    const inside = [...plan.writable, ...plan.readable].some((root) => within(canary, root, platform))
    if (inside) {
      return {
        ok: false,
        detail: 'the temporary directory used to test the boundary is inside it, so the test could not fail',
      }
    }

    writeFileSync(canary, secret, { mode: 0o600 })

    // The positive half first: if the sandbox cannot run anything, saying so is
    // more useful than reporting a leak that did not happen.
    const positive = await attempt(runner, profile, ['/bin/echo', token])
    if (!positive.stdout.includes(token)) {
      return {
        ok: false,
        detail: `${SANDBOX_EXEC} would not run a command with this profile${tail(positive.error)}`,
      }
    }

    const negative = await attempt(runner, profile, ['/bin/cat', canary])
    if (negative.stdout.includes(secret)) {
      return { ok: false, detail: 'a file outside the folder was readable from inside the sandbox' }
    }

    return { ok: true, detail: '' }
  } catch (error) {
    return { ok: false, detail: describe(error) }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/**
 * Ask the machine, not the kernel version, whether these namespaces confine
 * anything.
 *
 * Three runs, and the first is the one that makes the other two mean something.
 *
 *  1. **Outside the boundary**, a canary with random contents is written into
 *     the account's home and another into `/tmp`, and both are read straight
 *     back. If they do not come back, this test cannot fail and is therefore
 *     worth nothing — which is not a hypothetical: on a Windows machine
 *     launching into WSL, a canary path computed on the Windows side names a
 *     file the Linux session could never have read, and every check below would
 *     have "passed".
 *  2. **Inside it**, the same script. The token has to come back (a namespace
 *     that will not start anything would otherwise pass by failing at
 *     everything, exactly as `seatbelt.ts` guards against), neither secret may,
 *     and the two WSL doors have to be shut — an inherited `WSL_INTEROP` and a
 *     reachable `/run/WSL` are each a way to ask Windows to run a process with
 *     the account's full privileges, measured, from inside a confined session.
 *  3. The canaries are removed. Through the runner rather than through `fs`,
 *     because on the WSL path they are not on this filesystem.
 *
 * Run per session rather than cached, for the reason the Seatbelt half gives:
 * caching would answer a question about *this* plan with a measurement of a
 * different one. On this side it also matters that the machine can change its
 * mind — `/proc/sys/kernel/apparmor_restrict_unprivileged_userns` is a sysctl,
 * and a box that confined a session this morning can refuse this afternoon.
 */
async function proveNamespace(
  plan: ConfinementPlan,
  runner: ProofRunner,
  machine: LinuxMachine,
): Promise<ConfinementProof> {
  const token = randomBytes(16).toString('hex')
  const homeSecret = randomBytes(24).toString('hex')
  const tmpSecret = randomBytes(24).toString('hex')
  const stamp = randomBytes(9).toString('hex')

  const homeCanary = posix.join(plan.accountHome, `.terminaldeck-confine-probe-${stamp}`)
  const tmpCanary = `/tmp/.terminaldeck-confine-probe-${stamp}`
  const args = (mode: 'plant' | 'read' | 'clean'): string[] =>
    linuxProofArgs({ mode, token, homeCanary, tmpCanary, homeSecret, tmpSecret })

  for (const canary of [homeCanary, tmpCanary]) {
    const inside = [...plan.writable, ...plan.readable].some((root) =>
      within(canary, root, 'linux'),
    )
    if (!inside) continue
    // Reached when the grant covers the account's home directory, and refusing
    // is the honest answer rather than a smaller boundary: there would be
    // nothing left for the session to be held inside, and the test that was
    // supposed to notice cannot.
    return {
      ok: false,
      detail: `the file used to test the boundary (${canary}) is inside it, so the test could not fail`,
    }
  }

  try {
    const outside = await capture(runner, LINUX_SHELL, args('plant'))
    const before = readProofReport(outside.stdout)
    if (before.token !== token) {
      return { ok: false, detail: `could not run a command to test this machine${why(outside)}` }
    }
    if (before.home !== homeSecret || before.tmp !== tmpSecret) {
      return {
        ok: false,
        detail:
          'the file used to test the boundary could not be read from outside it either, so the test could not fail',
      }
    }

    const launch = linuxCommand(plan, LINUX_SHELL, args('read'), machine, stagePath(stamp))
    const inside = await capture(runner, launch.command, launch.args)
    const after = readProofReport(inside.stdout)
    if (after.token !== token) {
      return { ok: false, detail: `this machine would not start the namespace${why(inside)}` }
    }
    if (after.home === homeSecret || after.tmp === tmpSecret) {
      return { ok: false, detail: 'a file outside the folder was readable from inside the namespace' }
    }
    if (after.interop !== 'none') {
      return {
        ok: false,
        detail: 'the session still had WSL_INTEROP, which starts Windows processes as the owner',
      }
    }
    if (after.runwsl !== '') {
      return { ok: false, detail: 'the WSL interop sockets under /run/WSL were still reachable' }
    }
    return { ok: true, detail: '' }
  } catch (error) {
    return { ok: false, detail: describe(error) }
  } finally {
    // Best effort on purpose. A canary left behind is two files of random hex
    // in a home directory; a throw here would turn a boundary that held into a
    // session that would not start.
    await capture(runner, LINUX_SHELL, args('clean'))
  }
}

/**
 * Everything the Windows launcher needs for one session, or the sentence saying
 * why this machine cannot produce it.
 *
 * Built here rather than by the caller because two of the four pieces come from
 * state this module owns — the installed launcher and the one-time grant — and
 * the other two are derived from the plan. The caller would have to be told
 * about `tools.ts` to assemble it, and then there would be two places that know
 * how a container is named.
 */
function windowsLaunch(
  plan: ConfinementPlan,
): { launcher: string; launch: AppContainerLaunch } | { detail: string } {
  const install = windowsToolsInstall()
  if (install === null) return { detail: WINDOWS_UNCONFINED_REASON }
  const record = readGrantRecord(install.recordFile)
  // Reachable only if the grant is withdrawn between `confinementKind` and here
  // — a repair install, or somebody undoing it by hand while a session starts.
  // It is not a race worth locking against; it is a session that refuses.
  if (record === null) return { detail: WINDOWS_SETUP_NEEDED }
  return {
    launcher: install.launcher,
    launch: {
      container: containerName(deviceKeyOf(plan.home)),
      plan,
      tools: {
        capability: record.capability,
        read: record.read,
        ancestors: record.ancestors,
        probe: toolProbe(record.read),
      },
    },
  }
}

/**
 * The Windows proof, run through the same runner seam as the other two.
 *
 * The adapter in the middle is doing real work rather than shuffling types.
 * `proveAppContainer` needs the *output* of a run that exited non-zero — the
 * probe reads a file it must be refused, so a non-zero exit is the expected
 * case — and this module's runner rejects on one. {@link capture} is what turns
 * that rejection back into data, and it is the same function the Linux proof
 * leans on for the same reason.
 */
async function proveWindows(
  plan: ConfinementPlan,
  runner: ProofRunner,
  files: ProbeFiles,
): Promise<ConfinementProof> {
  const built = windowsLaunch(plan)
  if ('detail' in built) return { ok: false, detail: built.detail }
  const launcherRunner: LauncherRunner = async (command, args) => {
    const ran = await capture(runner, command, args)
    const code = (ran.error as { code?: unknown } | null)?.code
    return { stdout: ran.stdout, stderr: ran.stderr, code: typeof code === 'number' ? code : null }
  }
  return proveAppContainer(built.launch, built.launcher, plan.home, launcherRunner, files)
}

/**
 * Run one probe, treating a non-zero exit as data rather than as an exception.
 *
 * `cat` of a refused file exits 1, which is `execFile` rejecting — and that
 * rejection *is* the result the proof wants. Its `stdout` still has to be read,
 * because "it failed" and "it failed after printing the secret" are different
 * answers and only one of them is a boundary. `stderr` is kept for the other
 * half of the job: when the answer is "this machine will not do it", the
 * kernel's own sentence is the only useful thing anybody will have.
 */
async function capture(
  runner: ProofRunner,
  command: string,
  args: readonly string[],
): Promise<{ stdout: string; stderr: string; error: unknown }> {
  try {
    const result = await runner(command, [...args])
    return { stdout: result.stdout, stderr: result.stderr, error: null }
  } catch (error) {
    return { stdout: streamOf(error, 'stdout'), stderr: streamOf(error, 'stderr'), error }
  }
}

/** One of the two streams off a rejected `execFile`, when it carried them. */
function streamOf(error: unknown, name: 'stdout' | 'stderr'): string {
  const value = (error as Record<string, unknown>)[name]
  return typeof value === 'string' ? value : ''
}

async function attempt(
  runner: ProofRunner,
  profile: string,
  command: readonly string[],
): Promise<{ stdout: string; error: unknown }> {
  const [program, ...rest] = command
  if (program === undefined) return { stdout: '', error: null }
  const ran = await capture(runner, SANDBOX_EXEC, ['-p', profile, program, ...rest])
  return { stdout: ran.stdout, error: ran.error }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function tail(error: unknown): string {
  const text = describe(error).trim()
  return text === '' || text === 'null' ? '' : `: ${text}`
}

/**
 * Why a probe did not answer, in the machine's own words where there are any.
 *
 * `stderr` first and the exception second. `unshare` writing "Operation not
 * permitted" is the whole diagnosis on a box with the AppArmor restriction
 * switched on; the `Command failed with exit code 1` that Node wraps it in is
 * not.
 */
function why(ran: { stderr: string; error: unknown }): string {
  const printed = ran.stderr.trim()
  if (printed !== '') return `: ${printed.split('\n')[0]}`
  return tail(ran.error)
}

/* --------------------------------------------------------------- the spawn -- */

/**
 * The command and arguments that start a confined session, or a throw.
 *
 * The throw is the design. A caller that wanted confinement and cannot have it
 * must not be handed something that runs anyway — see the header. The only
 * caller is the remote spawn path, and it turns this into a refusal the phone
 * can read.
 *
 * `files` is here only so that the Windows branch can be exercised from a Mac;
 * {@link proveConfinement} carries the argument for why it has to be. Nothing in
 * the app passes it, and the default is the real filesystem.
 */
export async function confineSpawn(
  plan: ConfinementPlan,
  command: string,
  args: readonly string[],
  platform: Platform = currentPlatform(),
  runner: ProofRunner = realRunner,
  machine: LinuxMachine = realMachine,
  files: ProbeFiles = realFiles,
): Promise<{ command: string; args: string[] }> {
  const proof = await proveConfinement(plan, platform, runner, machine, files)
  if (!proof.ok) throw new ConfinementUnavailableError(proof.detail)
  if (confinementKind(platform) === 'appcontainer') {
    const built = windowsLaunch(plan)
    // Unreachable in practice — the proof above went through the same function
    // and would have refused — and a throw rather than a fall-through anyway,
    // because the alternative is handing back an unconfined command line, which
    // is the one thing this function must never do.
    if ('detail' in built) throw new ConfinementUnavailableError(built.detail)
    return {
      command: built.launcher,
      args: appContainerArgs(built.launch, command, args),
    }
  }
  if (confinementKind(platform) === 'namespace') {
    // A staging directory of its own, not the proof's: that one was made and
    // taken apart inside a namespace that has already exited, and reusing the
    // name would mean a session refusing to start because a directory it is
    // about to make is somehow still there.
    return linuxCommand(plan, command, args, machine, stagePath(randomBytes(9).toString('hex')))
  }
  return seatbeltCommand(seatbeltProfile(plan), command, args)
}

/**
 * The same boundary, as a line for the login shell inside a WSL distribution.
 *
 * Separate from {@link confineSpawn} because the Windows build does not spawn
 * the session at all: it spawns `wsl.exe`, which carries a *command line* to a
 * login shell on the other side (`wsl.ts` explains why it has to be a login
 * shell). So there is no argument vector to wrap — there is text to prefix, and
 * this is where it is built, from the same script and the same plan as every
 * other Linux session so the two cannot drift.
 *
 * The proof is the caller's to run, with a runner that goes through `wsl.exe`,
 * because only the caller knows which distribution. That is not an oversight
 * being waved past: until it is wired, this function is how a WSL session gets
 * confined and nothing checks the machine first, which is exactly what
 * `confineSpawn` refuses to allow on the paths it owns.
 *
 * **The plan handed here must be built from Linux paths.** The folder already
 * is one — that is how `wsl.ts` decides to launch this way at all — but the
 * device's home, its guest git directory and any profile config directory are
 * app storage on the *Windows* side today, and a plan carrying those confines a
 * session to directories that do not exist where it is running.
 */
export function confineWslLine(
  plan: ConfinementPlan,
  command: string,
  args: readonly string[],
  machine: LinuxMachine = realMachine,
): string {
  return linuxShellLine(plan, command, args, machine, stagePath(randomBytes(9).toString('hex')))
}
