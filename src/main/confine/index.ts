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
 * **Windows: not confined.** AppContainer, restricted tokens and job objects
 * are the mechanisms that exist, and none of them was measured — this
 * repository has no Windows machine and CI is macOS-only by policy. An
 * unmeasured boundary is worse than none, because the wording on the grant
 * screen would start claiming something nobody has ever watched hold. So
 * Windows sessions run exactly as they did, and the grant screen says so in its
 * own sentence rather than sharing one with the Mac.
 *
 * **Linux, including WSL: not confined.** Same answer and the same reason. User
 * namespaces, bind mounts and `bubblewrap` are all plausible and none of them
 * was run. WSL is the case that matters most here — it is where this app's
 * author keeps his own work — and it is also the one with the most unknowns:
 * whether unprivileged user namespaces are enabled in the distribution's
 * kernel, whether `bwrap` is installed, and what a bind-mount confinement does
 * to `/mnt/c`. Guessing at any of those from a Mac would be inventing an answer.
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
 * The consequence worth knowing about: a confined session's agent transcripts
 * land under that home, and the desktop looks for transcripts under the resolved
 * profile's config directory. Chat mode and the cost pane will therefore not
 * find a confined session's conversation. That is a real gap and it is named
 * here rather than discovered; closing it means teaching the transcript lookup
 * which home a session actually ran with.
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
import { mkdirSync, mkdtempSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { currentPlatform, type Platform } from '../platform/host'
import {
  confinedEnv,
  deviceHomeDir,
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
export type ConfinementKind = 'seatbelt' | 'none'

export function confinementKind(platform: Platform = currentPlatform()): ConfinementKind {
  return platform === 'darwin' ? 'seatbelt' : 'none'
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
    return 'Windows confinement (AppContainer, restricted tokens, job objects) has not been built or measured.'
  }
  if (platform === 'linux') {
    return 'Linux confinement (user namespaces, bind mounts, bubblewrap) has not been built or measured.'
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
  return home
}

/** The environment a confined session adds. Re-exported so callers need one import. */
export { confinedEnv }

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
 */
export async function proveConfinement(
  plan: ConfinementPlan,
  platform: Platform = currentPlatform(),
  runner: ProofRunner = realRunner,
): Promise<ConfinementProof> {
  if (confinementKind(platform) !== 'seatbelt') {
    return { ok: false, detail: unconfinedReason(platform) }
  }

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
 * Run one probe, treating a non-zero exit as data rather than as an exception.
 *
 * `cat` of a refused file exits 1, which is `execFile` rejecting — and that
 * rejection *is* the result the proof wants. Its `stdout` still has to be read,
 * because "it failed" and "it failed after printing the secret" are different
 * answers and only one of them is a boundary.
 */
async function attempt(
  runner: ProofRunner,
  profile: string,
  command: readonly string[],
): Promise<{ stdout: string; error: unknown }> {
  const [program, ...rest] = command
  if (program === undefined) return { stdout: '', error: null }
  try {
    const result = await runner(SANDBOX_EXEC, ['-p', profile, program, ...rest])
    return { stdout: result.stdout, error: null }
  } catch (error) {
    const stdout = typeof (error as { stdout?: unknown }).stdout === 'string'
      ? (error as { stdout: string }).stdout
      : ''
    return { stdout, error }
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function tail(error: unknown): string {
  const text = describe(error).trim()
  return text === '' || text === 'null' ? '' : `: ${text}`
}

/* --------------------------------------------------------------- the spawn -- */

/**
 * The command and arguments that start a confined session, or a throw.
 *
 * The throw is the design. A caller that wanted confinement and cannot have it
 * must not be handed something that runs anyway — see the header. The only
 * caller is the remote spawn path, and it turns this into a refusal the phone
 * can read.
 */
export async function confineSpawn(
  plan: ConfinementPlan,
  command: string,
  args: readonly string[],
  platform: Platform = currentPlatform(),
  runner: ProofRunner = realRunner,
): Promise<{ command: string; args: string[] }> {
  const proof = await proveConfinement(plan, platform, runner)
  if (!proof.ok) throw new ConfinementUnavailableError(proof.detail)
  return seatbeltCommand(seatbeltProfile(plan), command, args)
}
