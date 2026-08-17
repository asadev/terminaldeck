/**
 * The copilot, as a session — one of them, for the whole app.
 *
 * ## Why this is not a chat backend
 *
 * `COPILOT-DESIGN.md` decides it in one line: the copilot is *"a real session,
 * running the Claude CLI with a working directory of its own"*. Everything the
 * person asked for falls out of that choice rather than having to be built
 * twice. Its working directory is a folder they can open. Its startup reads are
 * a `CLAUDE.md` and a `memory/` directory they can read. Its conversation is an
 * ordinary transcript, so the transcript viewer, chat mode, the cost pane and
 * the alert watcher all work on it with no changes at all. Its account is the
 * account system already in the app.
 *
 * A bespoke agent loop would have had to re-implement all five, and every one of
 * them would have been a black box — which is the exact thing the feature exists
 * to escape.
 *
 * So this module is small on purpose. It decides *where* the copilot runs, *what
 * it may reach*, and *that there is only one of it*, and then hands the whole
 * spawn to `host-core.ts`'s `startSession`, which is the one place in this app
 * that starts a session.
 *
 * ## One copilot, not one per window
 *
 * A singleton held in module state, because "the copilot" is a thing a person
 * refers to in the singular. Two windows asking at the same moment must not
 * produce two agents with two transcripts and two bills, so the start is behind
 * a promise latch rather than a boolean — a boolean flips after the `await` and
 * the second caller sails past it.
 *
 * Liveness is *asked* rather than remembered: {@link CopilotRuntime.isAlive} is
 * consulted every time state is read, so a copilot whose process died — killed
 * from a terminal, crashed, quit by the CLI — reads as stopped without anything
 * having to deliver an event. This is the pattern the ledger avoids and it is
 * right here for the opposite reason: there is exactly one id to ask about.
 *
 * ## Its account is its own, and that is a security decision
 *
 * The design left this open and suggested pinned is safer. Pinned is what this
 * does, and it goes one step further: the copilot does not run as *any* of the
 * app's accounts. It runs with its own home directory, so its login lives inside
 * its own boundary and nowhere else.
 *
 * Three reasons, in order of how much they matter:
 *
 *  1. **Following the app's current account would move money and identity by
 *     accident.** The "current" account is a per-project or global default that
 *     a person changes for their own work. A copilot that followed it would
 *     start billing a different subscription, and answering as a different
 *     login, because somebody switched accounts in a project they happen to have
 *     open. Nobody decided that.
 *  2. **Borrowing a named account's directory would widen the boundary.** A
 *     confined session can only reach a config directory if that directory is
 *     added to its plan — and that directory holds the account's Claude state
 *     for every project. Giving the copilot its own home costs nothing and grants
 *     nothing.
 *  3. **Its conversation is its own.** The design is explicit that what the
 *     copilot remembers is its own conversation and not other sessions'. With a
 *     home of its own that is not a rule anybody has to follow — the other
 *     sessions' transcripts are outside the boundary and cannot be read at all.
 *
 * The cost is stated rather than hidden, and it is the first thing a person will
 * meet: **the copilot starts signed out, and signs itself in once.** The
 * account's Claude login lives in the macOS login keychain, and the keychain is
 * unreachable from inside the sandbox — measured, and the biggest single leak
 * `CONFINEMENT.md` closed. So the copilot's first launch is the CLI's own login
 * screen, in its own terminal; it prints a URL rather than opening a browser,
 * because LaunchServices is closed to it too, and the code is pasted back. From
 * then on its credential is a file inside its own home, which is a thing a
 * person can look at and delete.
 *
 * Making that possible took one non-obvious line, and the spawn below carries
 * the measurement: **which credential store the CLI uses depends on whether
 * `CLAUDE_CONFIG_DIR` is set.** Unset, it reads the keychain and there is no
 * login the copilot can ever complete; set, it reads a file it owns.
 *
 * {@link readCopilotSignIn} asks the CLI which of those two states it is in,
 * from inside the boundary and against the same store, so the answer is about
 * the copilot rather than about the machine.
 *
 * ## It can read your projects, and it can change none of them
 *
 * The first version of this file granted the copilot two directories: its own
 * folder and its own confined home. `device.writable` was `[]` and there was no
 * read grant at all, so its native `Read`, `Grep` and `Bash` reached nothing of
 * the person's. That was a defensible default for the general assistant the
 * copilot was originally scoped as, and it stopped being defensible the moment
 * the scope became *a developer's assistant, to help him get the developments
 * done*. An assistant that cannot see the code cannot triage a failing test,
 * review a diff, answer "what changed", or scope a prompt against what is
 * actually in the repository — which is the whole of what it is for.
 *
 * So it gets **read access to the projects the person has already added to this
 * app**, and **no write access to any of them**. Three properties, in the order
 * they matter:
 *
 *  1. **Read-only is enforced by the kernel, not by intent.** The project roots
 *     go into the plan's *read* list. There is no rule anywhere in the generated
 *     profile that permits a write into one, and `confine/copilot-projects.test.ts`
 *     proves it against a real `sandbox-exec` rather than against the profile
 *     text. Seeing your work is the mental model; changing it goes through a
 *     tool where a human confirms.
 *  2. **Credential-shaped files are carved back out**, by the kernel, in the
 *     same profile — `.env`, private keys, `.npmrc`, keystores, tfvars. The
 *     reasoning, the measurements and the honest limits are in
 *     `confine/secrets.ts`. It matters here because a confined session has an
 *     open network by design, so read access is exfiltration capability, and
 *     this is the one agent that also ingests other agents' transcripts, which
 *     is untrusted text.
 *  3. **The grant follows the project list**, as far as the operating system
 *     allows it to — which is not all the way, and the difference is written
 *     down rather than papered over. See below.
 *
 * ## What "follows the list" can and cannot mean
 *
 * A Seatbelt profile is an argument to `sandbox-exec` and is fixed for the life
 * of the process. It cannot be widened later — measured: `sandbox-exec` nested
 * inside itself fails with `sandbox_apply: Operation not permitted` — and there
 * is no reload. So the set of folders a *running* copilot can read is
 * necessarily the set that existed when its process started.
 *
 * What is genuinely live is the *derivation*: {@link copilotProjectRoots} reads
 * the store every time it is called, so nothing here holds a snapshot and every
 * start grants what is in the list at that moment. On top of that, the two
 * directions are handled differently because they are not the same risk:
 *
 *  - **A folder removed from the list is a grant the person has withdrawn**, and
 *    a running copilot holding it is the app enforcing something nobody wants.
 *    That is the direction that must not wait. `store.onProjectsChanged` fires
 *    the moment the set shrinks, {@link reconcileProjectGrant} sees that the
 *    live grant is no longer a subset of what is allowed, and it **stops the
 *    copilot** and records why. It is not restarted automatically: the next
 *    `ensure` from a window brings it back with the narrower plan, and an agent
 *    that quietly respawns after being stopped for a security reason is an agent
 *    nobody can reason about.
 *  - **A folder added to the list is a widening**, so nothing is stopped for it.
 *    The state reports it as {@link CopilotProjects.pending}, and a person
 *    applies it by stopping and starting the copilot — two channels that already
 *    exist. Restarting on its own would throw away a conversation in progress
 *    because somebody opened an unrelated folder.
 *
 * The alternative — not granting the folders at all and serving every project
 * read through a `deck-control` tool that re-checks the list per call — is live
 * in both directions and is the shape the tool surface already has. It is not
 * what was asked for here, and it is worth knowing that it remains true of the
 * tools: the aperture that *is* live is the tool aperture.
 *
 * ## It is confined, and it does not start if it cannot be
 *
 * A CLI session has Bash, and Bash is the whole machine. The copilot runs under
 * exactly the folder confinement a session from a paired device runs under —
 * `confine/index.ts`, Seatbelt on macOS — and it is not exempt because it is
 * ours. On a platform where that boundary cannot be proven, this refuses to
 * start it and says why, rather than starting an unconfined agent with the
 * app's name on it. That is the same "no silent downgrade" rule the remote spawn
 * path already follows, for the same reason: the side reporting success must be
 * the side doing the work.
 */

import { execFile } from 'node:child_process'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import type { CreateSessionInput, ProviderId, SessionMeta } from '../shared/types'
import {
  confineSpawn,
  confinedHomeEnv,
  confinementKind,
  deviceHomesRoot,
  planFor,
  prepareDeviceHome,
  realResolver,
  unconfinedReason,
  type DeviceConfinement,
} from './confine'
import type { ConfinementPlan } from './confine/plan'
import { projectRoots, within, type PlanGuards } from './confine/plan'
import { SECRET_SHAPES } from './confine/secrets'
import {
  appendCopilotAction,
  copilotHomeReport,
  copilotPaths,
  resetCopilotInstructions,
  scaffoldCopilotHome,
  type CopilotPaths,
  type InstructionsState,
  type StartupFile,
} from './copilot-home'
import { currentPlatform, withPath, type Platform } from './platform/host'
import { homeDir, userDataDir } from './platform/paths'
import { parseAuthStatus } from './profiles-signin'
import { detectProviders, loginPath, PROVIDERS } from './providers'
import { prepareGuestGit, type GuestGitEnv } from './remote/git-guest'
import type { HomeScope } from './transcript'
import { SYSTEM_PROFILE_ID } from './profiles'
import { store } from './store'

const run = promisify(execFile)

/* ------------------------------------------------------------------ model -- */

/**
 * The name of the copilot's home directory inside the confined-homes root.
 *
 * A literal word rather than a hash, and it cannot collide with a device's:
 * `deviceKey` in `remote/credentials.ts` produces sixteen hexadecimal
 * characters, and `copilot` is not one of those.
 *
 * It lives beside the device homes rather than inside `<userData>/copilot`, and
 * that placement is load-bearing rather than tidy. `transcript.ts` reads every
 * directory under this root when it is asked where a project's conversations
 * are, so putting the copilot's home here is what makes the transcript viewer,
 * chat mode, the cost pane and the alert watcher see the copilot's conversation
 * *with no change to any of them* — which is the entire argument for the copilot
 * being a session in the first place. A home somewhere prettier would have meant
 * teaching four readers about a fifth place to look.
 */
export const COPILOT_HOME_KEY = 'copilot'

export type CopilotStatus =
  /** Never started, or its process has gone. */
  | 'stopped'
  /** A start is in flight. */
  | 'starting'
  /** Its process is alive. */
  | 'running'
  /** This machine cannot run it, and {@link CopilotState.problem} says why. */
  | 'unavailable'

export type CopilotSignInState = 'signed-in' | 'signed-out' | 'unknown'

export interface CopilotSignIn {
  state: CopilotSignInState
  /** The account the CLI named, when it named one. */
  account: string | null
  /** Its plan or auth method, as the CLI reported it. */
  plan: string | null
  checkedAt: number
}

/**
 * What the copilot can see of the person's own work, and what it cannot yet.
 *
 * Four lists rather than one with a flag on each entry, because the difference
 * between them is the whole of what a person needs to be told and a flag hides
 * it: *this is what it can read right now*, *this is what the next start would
 * give it*, *this is the gap*, and *this is what is carved out of all of them*.
 */
export interface CopilotProjects {
  /**
   * What the **running** process can actually read, as its profile was written.
   * Empty whenever nothing is running, because nothing is then readable.
   */
  granted: readonly string[]
  /** What a start right now would grant — the live list, guarded. */
  available: readonly string[]
  /**
   * Available but not granted: added since the copilot started. Readable after
   * a stop and a start, and not before. See the header for why not before.
   */
  pending: readonly string[]
  /**
   * Whether this machine can hold a read-only project grant at all.
   *
   * False off macOS, and then `granted` and `available` are both empty. The
   * exclusions below are Seatbelt rules; the Linux and Windows backends would
   * grant the folder whole, which is not the same feature, so they are given
   * nothing rather than something that looks like it.
   */
  enforceable: boolean
  /** Why not, when `enforceable` is false. Null otherwise. */
  reason: string | null
  /**
   * The credential shapes refused inside every granted folder, by name.
   *
   * Carried so a settings pane can print what is carved out instead of a person
   * having to read a sandbox profile — and so the claim stays honest, because
   * the list is generated from the same constant the profile is.
   */
  excluded: readonly string[]
}

export interface CopilotState {
  status: CopilotStatus
  /** The live session's id, so a window can open the same tab everything else sees. */
  sessionId: string | null
  /** Its folder, its instructions, its memory, its log. */
  paths: CopilotPaths
  /** Its own home directory — its login, its caches, its transcripts. */
  home: string
  startedAt: number | null
  /** Why it is not running, or null. Always set when the status is `unavailable`. */
  problem: string | null
  confinement: {
    kind: ReturnType<typeof confinementKind>
    /** True only when the session actually ran inside a proven boundary. */
    enforced: boolean
    /** Why it is not enforced, or null. */
    reason: string | null
  }
  /**
   * True only when `CLAUDE.md` is *this build's* default, byte for byte.
   *
   * Kept as a boolean because that is what a pane asking "may I offer a reset"
   * wants, and narrowed by {@link instructions} for the case the boolean cannot
   * express: a file that is a default, but an older one.
   */
  instructionsAreDefault: boolean
  /** Whether `CLAUDE.md` is current, out of date, hand-edited, or missing. */
  instructions: InstructionsState
  /** What it can read of the person's projects, and what it cannot. */
  projects: CopilotProjects
  /** The files it reads at startup, in order. */
  startupFiles: StartupFile[]
}

/* ------------------------------------------------------------------- deps -- */

/**
 * Everything this module needs from the rest of the app.
 *
 * Injected rather than imported, for the reason `platform/paths.ts` argues at
 * length and one more of its own: `startSession` lives on the host core, which
 * the Electron shell and the headless shell each assemble once, and a module
 * that reached for a global copy of it would be a second answer to "what is a
 * session". Every field here is something the caller already holds.
 */
export interface CopilotRuntimeDeps {
  /** The one session starter, from `createHostCore`. */
  startSession(
    input: CreateSessionInput,
    guest?: GuestGitEnv,
    confine?: DeviceConfinement,
  ): Promise<SessionMeta>
  /** Is that session still alive? Asked on every state read; see the header. */
  isAlive(sessionId: string): boolean
  /** Stop it. */
  stop(sessionId: string): void
  /** `<userData>`. Defaults to this shell's answer. */
  userData?(): string
  /** Where remote and confinement storage lives — `<userData>/remote`. */
  storageDir?(): string
  /** The account's real home. Never inside the boundary; it is what is protected. */
  accountHome?(): string
  /** Which agent CLIs this machine has. Defaults to the real probe. */
  agents?(): Promise<Record<ProviderId, boolean>>
  /**
   * The folders the person has added to this app, right now.
   *
   * Defaults to the app's own store rather than being required, for the reason
   * `deck-control/live-surface.ts` gives about reaching for `store()` directly:
   * a second copy of the project list handed in from somewhere else is a place
   * for the copilot's grant and the sidebar to disagree, and they must not. It
   * is injectable only so the tests can pin what happens to a list they control.
   */
  projects?(): readonly string[]
  /**
   * Subscribe to the project list changing. Defaults to the store's own event.
   *
   * Injected for the same reason and used for one thing: a folder leaving the
   * list has to reach a running copilot, because the operating system fixed its
   * grant when the process started. See {@link reconcileProjectGrant}.
   */
  onProjectsChanged?(listener: (paths: readonly string[]) => void): () => void
  platform?: Platform
  /** Initial terminal size. The window resizes it the moment it attaches. */
  cols?: number
  rows?: number
}

interface Resolved {
  paths: CopilotPaths
  home: string
  userData: string
  storageDir: string
  accountHome: string
  platform: Platform
  cols: number
  rows: number
}

function resolve(deps: CopilotRuntimeDeps): Omit<Resolved, 'home'> {
  const userData = deps.userData?.() ?? userDataDir()
  return {
    paths: copilotPaths(userData),
    userData,
    storageDir: deps.storageDir?.() ?? join(userData, 'remote'),
    accountHome: deps.accountHome?.() ?? homeDir(),
    platform: deps.platform ?? currentPlatform(),
    // 120x30 is a readable first frame for an agent CLI that draws a box, and it
    // is replaced by the real size within a frame of a terminal attaching. It
    // matters at all because a session started with no window open — which this
    // one can be — would otherwise render its first output at 80x24 and reflow.
    cols: deps.cols ?? 120,
    rows: deps.rows ?? 30,
  }
}

/* ------------------------------------------------------------- the singleton -- */

interface Live {
  sessionId: string
  startedAt: number
  enforced: boolean
  /**
   * The project folders this process's Seatbelt profile actually names.
   *
   * Recorded rather than recomputed, and that is the point of the whole
   * reconcile: the profile is fixed at `exec`, so what the running copilot can
   * read is what was true then, and the only way to know whether that still
   * matches the person's intent is to have kept it.
   */
  projects: readonly string[]
}

let live: Live | null = null
/** A start in flight. See the header: a boolean would not hold across the await. */
let starting: Promise<CopilotState> | null = null
/** Why the last attempt did not produce a running copilot. */
let problem: string | null = null
/** Drops the project-list subscription. Held only while a copilot is running. */
let unwatchProjects: (() => void) | null = null

/** Forget everything. For tests, and for nothing else. */
export function resetCopilot(): void {
  live = null
  starting = null
  problem = null
  signIn = null
  unwatchProjects?.()
  unwatchProjects = null
}

/* ------------------------------------------------------ the project grant -- */

/**
 * The folders a copilot started right now would be able to read.
 *
 * Read from the store on every call — nothing here is captured — so this is the
 * live answer and not a snapshot. What it removes from that live answer is
 * `<userData>` and everything inside it, and that removal is this function's
 * whole reason to exist rather than the caller just handing the list to
 * `planFor`.
 *
 * `<userData>` is where this app keeps every session's transcript, the paired
 * devices' credentials, `state.json` and `settings.json` — and, inside it, the
 * copilot's own folder and its own home, which *are* granted, deliberately and
 * by name. A person can add any folder to this app as a project, `<userData>`
 * included, and `COPILOT-CAPABILITIES.md` §3.2 is explicit that the copilot
 * never reaches this app's own state except through a tool. `plan.ts` drops
 * anything containing a writable root, which catches `<userData>` itself; this
 * catches a sibling *inside* it, which that guard cannot see.
 *
 * Empty off macOS, and the reason is returned rather than left to be guessed.
 * The exclusions in `secrets.ts` are Seatbelt rules; the Linux backend turns
 * readable roots into whole read-only bind mounts and the Windows one ignores
 * them entirely, so either would grant a project folder including its `.env`.
 * A narrower feature would be defensible; a feature that silently loses its
 * safety half is not, and `sessionPlan` throws rather than build one.
 */
export function copilotProjectRoots(deps: CopilotRuntimeDeps): {
  roots: readonly string[]
  enforceable: boolean
  reason: string | null
} {
  const { userData, storageDir, accountHome, paths, platform } = resolve(deps)
  if (confinementKind(platform) !== 'seatbelt') {
    return {
      roots: [],
      enforceable: false,
      reason:
        'Reading your projects is granted only where the credential exclusions can be enforced, which today is macOS.',
    }
  }
  const listed = deps.projects?.() ?? store().getProjects().map((project) => project.path)
  /*
   * The same guards the plan will apply, applied here too — not instead.
   *
   * `projectRoots` is the function `sessionPlan` calls, run with the two
   * writable roots the copilot's plan will have, so what this returns is what
   * the profile would actually name: resolved, de-duplicated, and with `~`,
   * `/` and anything containing the copilot's own directories already dropped.
   * Answering with the raw list instead would put folders in `pending` that no
   * start will ever grant, and would compare an unresolved path against a
   * resolved one in {@link reconcileProjectGrant} — which, for a project
   * reached through a symlink, reads as a folder that has been removed and
   * would stop a perfectly good copilot.
   */
  const guards: PlanGuards = {
    home: realResolver.real(accountHome),
    protect: [paths.root, copilotHome(storageDir)].map((path) => realResolver.real(path)),
  }
  const guarded = projectRoots(listed, realResolver, guards, platform)
  return {
    roots: guarded.filter((path) => !within(path, realResolver.real(userData), platform)),
    enforceable: true,
    reason: null,
  }
}

/**
 * Stop a copilot whose grant is wider than the person's current intent.
 *
 * Called from two places and from nowhere else: the store's change event, which
 * is what makes a removal prompt, and `ensureCopilot`, which is what makes it
 * certain — a listener that was never attached, or a change made by a shell
 * that does not emit, still gets caught the next time a window asks for the
 * copilot.
 *
 * It only ever *narrows*. A folder added to the list leaves a running copilot
 * alone; see the header for why a widening is not worth a conversation.
 *
 * Stopping rather than restarting is deliberate. The copilot costs money per
 * turn and its transcript is a product feature; a process that dies and silently
 * comes back is one whose conversation vanished with no sentence to explain it.
 * `problem` carries that sentence, and the pane's existing start button is the
 * way back.
 */
export function reconcileProjectGrant(deps: CopilotRuntimeDeps): void {
  if (live === null) return
  const { paths, platform } = resolve(deps)
  const { roots } = copilotProjectRoots(deps)
  const revoked = live.projects.filter(
    (granted) => !roots.some((root) => within(granted, root, platform)),
  )
  if (revoked.length === 0) return

  const sessionId = live.sessionId
  deps.stop(sessionId)
  live = null
  unwatchProjects?.()
  unwatchProjects = null
  problem =
    revoked.length === 1
      ? `The copilot was stopped because ${revoked[0]} was removed from your projects and it could still read it. Start it again to carry on without that folder.`
      : `The copilot was stopped because ${revoked.length} folders were removed from your projects and it could still read them. Start it again to carry on without them.`
  appendCopilotAction(paths, {
    action: 'projects.revoked',
    sessionId,
    detail: `stopped; no longer granted: ${revoked.join(', ')}`,
  })
}

/** What a pane draws about the project grant, running or not. */
function projectState(deps: CopilotRuntimeDeps): CopilotProjects {
  const { platform } = resolve(deps)
  const { roots, enforceable, reason } = copilotProjectRoots(deps)
  const granted = live?.projects ?? []
  return {
    granted,
    available: roots,
    pending: roots.filter((root) => !granted.some((have) => within(root, have, platform))),
    enforceable,
    reason,
    excluded: SECRET_SHAPES.map((shape) => shape.name),
  }
}

/**
 * The copilot's state, computed rather than cached.
 *
 * Reads the filesystem every time, which is a handful of `stat` calls on a
 * directory holding a few small Markdown files. The alternative would be a cache
 * that is wrong exactly when somebody has just edited `CLAUDE.md` and opened the
 * pane to check that their edit landed, which is the one moment this is looked
 * at.
 *
 * It reports the project grant and never changes it. Reconciling from a state
 * read would mean a pane refreshing could kill a session, which is the kind of
 * action-at-a-distance nobody can debug; {@link reconcileProjectGrant} is called
 * from the event and from `ensureCopilot`, both of which are things that
 * happened rather than things that were looked at.
 */
export function copilotState(deps: CopilotRuntimeDeps): CopilotState {
  const { paths, storageDir, platform } = resolve(deps)
  const report = copilotHomeReport(paths)
  const kind = confinementKind(platform)
  const alive = live !== null && deps.isAlive(live.sessionId)
  if (live !== null && !alive) live = null

  /*
   * Order matters, and `problem` beating `starting` is the load-bearing part.
   *
   * A refusal is reported from *inside* the start, before the latch that is
   * holding `starting` has settled — so a status computed from the latch first
   * would answer "starting" to the very call that just gave up, and a pane
   * would spin forever on a copilot that is never coming. `problem` is cleared
   * at the top of each attempt, so a genuine start in flight still reads as one.
   */
  const status: CopilotStatus = alive
    ? 'running'
    : kind === 'none'
      ? 'unavailable'
      : problem !== null
        ? 'stopped'
        : starting !== null
          ? 'starting'
          : 'stopped'

  return {
    status,
    sessionId: alive && live !== null ? live.sessionId : null,
    paths,
    home: copilotHome(storageDir),
    startedAt: alive && live !== null ? live.startedAt : null,
    problem: kind === 'none' ? unconfinedReason(platform) : problem,
    confinement: {
      kind,
      enforced: alive && live !== null ? live.enforced : false,
      reason: kind === 'none' ? unconfinedReason(platform) : null,
    },
    instructionsAreDefault: report.instructionsAreDefault,
    instructions: report.instructions,
    projects: projectState(deps),
    startupFiles: report.startupFiles,
  }
}

/** Where the copilot's own home directory is, given this install's storage. */
export function copilotHome(storageDir: string): string {
  return join(deviceHomesRoot(storageDir), COPILOT_HOME_KEY)
}

/**
 * The copilot's home, paired with the one folder its conversations belong to.
 *
 * `transcript.ts` walks every directory under the device-homes root when it is
 * asked where a project's transcripts are, and {@link COPILOT_HOME_KEY} above
 * explains why the copilot's home is deliberately one of them: it is what makes
 * the viewer, chat mode, the cost pane and the alert watcher see the copilot's
 * own conversation without any of them being taught about a fifth place to look.
 *
 * The cost of sitting in that root is that the copilot — which *can* write
 * inside its own home, and can write nowhere else — could create
 * `<home>/.claude/projects/<encode(somebody's repo)>/x.jsonl` and have those
 * same four readers render it as a conversation belonging to that repo. Nothing
 * about the boundary is wrong there; the file is inside it. What was wrong is
 * that a store belonging to one folder was being consulted for every folder.
 *
 * So the pair is registered as a scope: the copilot's store answers for
 * {@link CopilotPaths.root}, which is the only directory its sessions ever run
 * in, and for nothing else. Nothing legitimate is lost — its own transcript is
 * found exactly as before — and a fabricated one is never looked for.
 *
 * `storageDir` defaults the same way {@link resolve} does, because the two must
 * not disagree about where the homes are.
 */
export function copilotHomeScope(userData: string, storageDir = join(userData, 'remote')): HomeScope {
  return { home: copilotHome(storageDir), folder: copilotPaths(userData).root }
}

/**
 * The copilot's own agent configuration directory — its login, its history.
 *
 * One spelling, because three things depend on it agreeing with itself: the
 * spawn sets `CLAUDE_CONFIG_DIR` to it, the sign-in probe has to ask about the
 * same store or it answers about the machine's, and `transcript.ts` looks for
 * this exact name under each confined home when it goes looking for
 * conversations.
 */
export function copilotConfigDir(home: string): string {
  return join(home, '.claude')
}

/**
 * Start the copilot if it is not already running, and answer with its state.
 *
 * Idempotent by design and by contract — a window calls this when it opens, when
 * a person clicks the pinned entry, and after a reconnect, and none of those may
 * produce a second agent. Every early return below is one of those cases.
 *
 * It does not throw for an ordinary refusal. A copilot that will not start
 * because the CLI is missing, or because this machine has no boundary to hold
 * it, is a state a pane has to *draw*, and turning it into a rejected promise
 * would push that job onto every caller and lose the reason on the way.
 */
export async function ensureCopilot(deps: CopilotRuntimeDeps): Promise<CopilotState> {
  /*
   * The certain half of the project reconcile. See `reconcileProjectGrant`.
   *
   * Before anything is reported as running, check that what it can read is
   * still what the person allows. The event is what makes a removal prompt;
   * this is what makes it *hold* — through a listener that was never attached,
   * a shell that does not emit, a `state.json` edited by hand while the app was
   * closed. It runs before the liveness check below, because the point is to
   * catch a copilot that is alive and should not be.
   */
  reconcileProjectGrant(deps)
  if (live !== null && deps.isAlive(live.sessionId)) return copilotState(deps)
  if (starting !== null) return starting

  const attempt = startCopilot(deps).finally(() => {
    starting = null
  })
  starting = attempt
  return attempt
}

async function startCopilot(deps: CopilotRuntimeDeps): Promise<CopilotState> {
  const { paths, storageDir, platform, cols, rows } = resolve(deps)
  problem = null

  const scaffolded = scaffoldCopilotHome(paths)
  if (scaffolded.error !== null) {
    return refuse(deps, `The copilot's folder could not be created: ${scaffolded.error}`)
  }
  if (scaffolded.created.length > 0) {
    appendCopilotAction(paths, {
      action: 'home.created',
      detail: scaffolded.created.join(', '),
    })
  }

  /*
   * No boundary, no copilot.
   *
   * `startSession` decides whether to confine by asking `confinementKind`, and
   * on a platform that answers `'none'` it starts the session *unconfined* — the
   * right answer for a person at their own keyboard, and the wrong one for an
   * agent the app itself is running with an open network and a shell. Checking
   * here rather than relying on the spawn to refuse is what makes the refusal a
   * sentence instead of a session nobody meant to start.
   */
  const kind = confinementKind(platform)
  if (kind === 'none') return refuse(deps, unconfinedReason(platform))

  /*
   * The CLI has to be there. `startSession` falls back to a plain shell when the
   * requested agent is missing — correct for a tab, and a lie for this: a shell
   * pinned in the sidebar as your assistant is a feature that does not exist.
   */
  const available = await (deps.agents?.() ?? detectProviders(platform, null))
  if (!available.claude) {
    return refuse(
      deps,
      `The copilot runs on ${PROVIDERS.claude.label}, which is not installed on this machine.`,
    )
  }

  const home = prepareDeviceHome(deviceHomesRoot(storageDir), COPILOT_HOME_KEY)
  /*
   * Its git, isolated the same way a guest device's is.
   *
   * The confinement already stops it reading `~/.ssh` and `~/.gitconfig`, but a
   * boundary is about files and this is about *environment*: a `GH_TOKEN` or an
   * `SSH_AUTH_SOCK` inherited from whatever launched this app is inside the
   * process, not on the disk, and the sandbox has nothing to say about it. The
   * copilot has a shell and an open network, so an inherited token is a token it
   * can spend. `guestGitEnv` already names every variable that hands a process
   * somebody's account and why; reusing it is what stops this file growing a
   * second, shorter, staler copy of that list.
   */
  const git = prepareGuestGit({ dir: join(home, 'git'), platform })
  /*
   * And its Claude configuration directory, named explicitly.
   *
   * This looks redundant — `HOME` already points at the copilot's own home, so
   * the CLI's default store is `<home>/.claude` either way — and it is not.
   * Measured against Claude Code 2.1.233: **which credential store the CLI uses
   * depends on whether this variable is set.** With it unset the CLI reads the
   * macOS login keychain, which is closed to a sandboxed process, so a confined
   * copilot walks straight into the login screen no matter what is on its disk.
   * With it set the CLI reads `<configDir>/.credentials.json` — a file, inside
   * the boundary, that the copilot can both read and write.
   *
   * That is the difference between a copilot that can be signed in once and one
   * that can never be signed in at all, and it was invisible until a real
   * sandboxed run was watched: the first attempt printed
   * `Not logged in · Please run /login`, and the same binary with the same home
   * and this variable set read the credential and answered.
   *
   * `.claude` inside the home rather than a directory of its own, and that name
   * is load-bearing too: `transcript.ts` looks for exactly `<home>/.claude` when
   * it walks the confined homes, so this is what keeps the copilot's transcript
   * visible to the viewer, chat mode, the cost pane and the alert watcher.
   *
   * Carried on the environment bundle rather than through a profile, because a
   * profile would mean a directory in the app's shared profile storage — outside
   * the boundary, and shared with the person's own sessions. `paths` names it as
   * a path so it survives the WSL crossing; that crossing cannot happen for the
   * copilot today, and naming it costs nothing and is one less thing to remember
   * if it ever can.
   */
  const configDir = copilotConfigDir(home)
  const environment: GuestGitEnv = {
    ...git,
    set: { ...git.set, CLAUDE_CONFIG_DIR: configDir },
    paths: [...git.paths, 'CLAUDE_CONFIG_DIR'],
  }

  /*
   * The folders it will be able to read, decided here and recorded below.
   *
   * Read at the last possible moment before the spawn, because this is the
   * moment the operating system freezes the answer: everything after `exec` is
   * fixed for the life of the process, so a list read any earlier would be a
   * list that could already be wrong by the time it became a profile.
   */
  const { roots: projects } = copilotProjectRoots(deps)

  let meta: SessionMeta
  try {
    meta = await deps.startSession(
      {
        cwd: paths.root,
        cols,
        rows,
        provider: 'claude',
        /*
         * Fresh, not continued.
         *
         * `--continue` would make the copilot one conversation that never ends,
         * and the cost of a turn grows with the conversation it is appended to —
         * an assistant that gets more expensive every day it is not restarted is
         * a bill nobody agreed to. Continuity is `memory/`, which is the
         * mechanism the design chose for it and the one a person can read and
         * edit.
         */
        resume: false,
        /*
         * Its own account, pinned. Naming the system profile is how this asks
         * the resolution chain *not* to apply a project or global default — and
         * with `HOME` redirected into the copilot's own directory, the CLI's
         * default store is inside the boundary rather than the machine's. See
         * the header for why that is the safer of the two answers.
         */
        profileId: SYSTEM_PROFILE_ID,
      },
      environment,
      /*
       * `writable` stays empty and must stay empty.
       *
       * The projects ride in on `projects`, which `planFor` puts in the plan's
       * *read* list and nowhere else, so there is no arrangement of these three
       * fields that makes one of somebody's repositories writable by the
       * copilot. That is the boundary being widened here, and the one half of
       * it that is not being widened at all.
       */
      { home, writable: [], files: [], projects },
    )
  } catch (error) {
    // The interesting one is `ConfinementUnavailableError`, which is thrown when
    // the boundary could not be *proven* on this machine at this moment. It
    // arrives as a sentence and is passed through as one.
    return refuse(deps, error instanceof Error ? error.message : String(error))
  }

  /*
   * Belt and braces on the fallback checked above.
   *
   * The provider check happens before the spawn because refusing early gives a
   * better sentence, and it is repeated here because the fallback in
   * `startSession` is silent and a race between the probe and the spawn — an
   * upgrade removing the binary, a PATH change — would otherwise leave a shell
   * running under the copilot's name.
   */
  if (meta.provider !== 'claude') {
    deps.stop(meta.id)
    return refuse(deps, `The copilot started as a ${meta.provider} session rather than an agent.`)
  }

  live = { sessionId: meta.id, startedAt: meta.createdAt, enforced: true, projects }
  /*
   * Watch the list from the moment there is a grant to withdraw.
   *
   * Subscribed here rather than at module load so that nothing is listening
   * while nothing is running, and dropped in `stopCopilot` and in the reconcile
   * so a copilot that has been stopped four times does not leave four listeners
   * behind. The previous one is dropped first for the same reason — `ensure`
   * can start a second process after the first died on its own, and that path
   * does not go through `stopCopilot`.
   */
  unwatchProjects?.()
  const watch = deps.onProjectsChanged ?? ((listener) => store().onProjectsChanged(listener))
  unwatchProjects = watch(() => {
    reconcileProjectGrant(deps)
  })
  appendCopilotAction(paths, {
    action: 'session.started',
    sessionId: meta.id,
    detail:
      projects.length === 0
        ? `${kind} confinement, cwd ${paths.root}, no project folders readable`
        : `${kind} confinement, cwd ${paths.root}, read-only: ${projects.join(', ')}`,
  })
  return copilotState(deps)
}

/** Record a refusal, in the log and in the state, and answer with the state. */
function refuse(deps: CopilotRuntimeDeps, reason: string): CopilotState {
  const { paths } = resolve(deps)
  problem = reason
  appendCopilotAction(paths, { action: 'session.refused', detail: reason })
  return copilotState(deps)
}

/**
 * Stop the copilot.
 *
 * Worth having even though nothing in the design asks for it: the copilot is a
 * process that costs money and holds a pty, and a singleton a person cannot
 * switch off is a fault rather than a simplification. Stopping is also the
 * honest way to change something it read at startup — edit `CLAUDE.md`, stop it,
 * start it again — and it is now also how a project folder added since it
 * started becomes readable, because a Seatbelt profile cannot be widened after
 * `exec`. See the header.
 */
export function stopCopilot(deps: CopilotRuntimeDeps): CopilotState {
  const { paths } = resolve(deps)
  if (live !== null) {
    deps.stop(live.sessionId)
    appendCopilotAction(paths, { action: 'session.stopped', sessionId: live.sessionId })
    live = null
  }
  unwatchProjects?.()
  unwatchProjects = null
  return copilotState(deps)
}

/* ---------------------------------------------------------------- sign-in -- */

let signIn: CopilotSignIn | null = null

/**
 * How long a sign-in answer is trusted before it is asked again.
 *
 * A minute, because the thing that changes it is a person completing a login in
 * front of the pane — so the answer has to refresh on a human timescale — and
 * because asking costs a `sandbox-exec` proof plus a CLI spawn, which is not
 * something to do on every render.
 */
const SIGN_IN_TTL_MS = 60_000

/**
 * Is the copilot signed in? Asked of the CLI, **from inside the boundary**.
 *
 * The distinction is the whole point. Running `claude auth status` as the app
 * would answer a question about the machine's own login, which the copilot
 * cannot reach: the macOS keychain is closed to a sandboxed process — measured,
 * and the leak `CONFINEMENT.md` cared about most — so the machine can be signed
 * in while the copilot is not. Asking through the same confinement the copilot
 * runs under is the only way to get an answer that is about the copilot.
 *
 * Three states, and `unknown` is never collapsed into `signed-out`, for the
 * reason `profiles-signin.ts` gives: they send a person to different places.
 */
export async function readCopilotSignIn(
  deps: CopilotRuntimeDeps,
  now = Date.now(),
): Promise<CopilotSignIn> {
  if (signIn !== null && now - signIn.checkedAt < SIGN_IN_TTL_MS) return signIn
  const answer = await probeSignIn(deps)
  signIn = { ...answer, checkedAt: now }
  return signIn
}

/**
 * What a command printed, whether or not it thought it had succeeded.
 *
 * `execFile` rejects on any non-zero exit and on a timeout, and in both cases
 * hangs whatever the process managed to write off the rejection rather than
 * returning it. A caller that only reads the resolved value therefore loses the
 * output of every command that answers a question by exiting non-zero — which
 * `claude auth status --json` does, every time it is not logged in. See
 * {@link probeSignIn} for the measurement and for what that cost.
 *
 * Exported for the test that pins it: the interesting case is a rejection that
 * carries a complete answer, and that cannot be exercised without being able to
 * hand this function one.
 */
export async function outputOf(
  running: Promise<{ stdout: string; stderr: string }>,
): Promise<{ stdout: string; stderr: string }> {
  try {
    return await running
  } catch (error) {
    const failure = error as { stdout?: unknown; stderr?: unknown }
    return {
      stdout: typeof failure.stdout === 'string' ? failure.stdout : '',
      stderr: typeof failure.stderr === 'string' ? failure.stderr : '',
    }
  }
}

async function probeSignIn(
  deps: CopilotRuntimeDeps,
): Promise<Omit<CopilotSignIn, 'checkedAt'>> {
  const { paths, storageDir, accountHome, platform } = resolve(deps)
  const unknown = { state: 'unknown' as const, account: null, plan: null }
  /*
   * No boundary, nothing to ask about — and on Windows this is the ordinary
   * state, not an exotic one.
   *
   * `startCopilot` refuses on the same condition, so a machine that answers
   * `'none'` has no copilot, no home of its own and no credential file to read;
   * probing anyway would spawn the CLI with the *machine's* store and report
   * the person's own login as the copilot's. Returning `unknown` is right, and
   * it is not what the pane draws: `copilotState` sets the status to
   * `unavailable` and carries `unconfinedReason(platform)`, and `CopilotView`
   * shows that sentence rather than the "could not check" one, which is only
   * reachable while the copilot is *running*.
   *
   * Windows reaches this on every machine today, because the one-time
   * AppContainer grant is built in `confine/tools.ts` and nothing in the app
   * calls it — see `windows-setup-reachable.test.ts`, which holds the sentence
   * the user reads honest about that. Whoever wires the grant makes this branch
   * stop being taken on Windows, and nothing here needs to change when they do:
   * the question asked is "is there a boundary", and the answer simply becomes
   * yes.
   */
  if (confinementKind(platform) === 'none') return unknown

  try {
    const path = await loginPath(platform)
    const home = prepareDeviceHome(deviceHomesRoot(storageDir), COPILOT_HOME_KEY)
    const plan = copilotPlan({ folder: paths.root, home, accountHome, path, platform })
    // `--json` is a guard rather than a preference: an older CLI reads an unknown
    // subcommand as a *prompt* and starts a paid turn. `profiles-signin.ts` has
    // the measurement. An unknown option is rejected by the argument parser
    // before anything is spawned.
    const launch = await confineSpawn(plan, PROVIDERS.claude.spawn.command, [
      'auth',
      'status',
      '--json',
    ])
    /*
     * The answer is read off the *output*, whatever the exit status was.
     *
     * `claude auth status --json` **exits 1 when it is not logged in** —
     * measured against 2.1.233, with `{"loggedIn": false, "authMethod":
     * "none"}` on stdout and nothing on stderr. `promisify(execFile)` rejects
     * on any non-zero exit and hangs the output off the *error object*, so
     * awaiting it directly threw away a perfectly good answer and reported
     * `unknown`.
     *
     * That is not a cosmetic loss. `unknown` is the one sign-in state that is
     * drawn as "this window could not check", so a signed-out copilot — which
     * is *every* copilot on its first run, by design, because its login lives
     * inside a sandbox that cannot reach the keychain — could never reach the
     * first-run explanation. The one state a person most needs explained was
     * the one state this could not report. Seen on screen, not reasoned about.
     *
     * `profiles-signin.ts` already learned this for the account probes and
     * takes stdout off the failure the same way; this is that lesson, applied
     * to the one prober that had not had it. A killed or timed-out process
     * still yields nothing parseable and still answers `unknown`, which is
     * correct — that genuinely is "could not check".
     */
    const output = await outputOf(
      run(launch.command, launch.args, {
        cwd: paths.root,
        /*
         * `confinedHomeEnv`, not a hand-spelled `HOME`: the probe has to run in
         * the same environment the session runs in, or it answers a question
         * about a different store than the one the copilot will read.
         *
         * And `confinedHomeEnv` rather than `confinedEnv`, which is what this
         * line said first and is the reason that function exists. `confinedEnv`
         * spells "its own home" as `HOME` and `TMPDIR`, which is the POSIX
         * spelling; on Windows `os.homedir()` reads `USERPROFILE`, the CLI's
         * own state lives under `APPDATA`/`LOCALAPPDATA`, and scratch space is
         * `TEMP`/`TMP`. Calling the POSIX one on Windows would have left this
         * probe running with the copilot's `HOME` and the owner's everything
         * else — reporting the *machine's* login for a copilot that has none,
         * which is the same failure the `CLAUDE_CONFIG_DIR` note below is here
         * to prevent, arriving through the variable beside it.
         *
         * The platform is passed rather than defaulted so that this reads the
         * same in a test as it does at run time; `confinementKind` inside it
         * still decides, and on a Windows machine that has not been set up it
         * answers `'none'` — but that case never reaches here, because the
         * guard at the top of this function has already returned.
         */
        env: withPath(
          // `CLAUDE_CONFIG_DIR` is not optional here and not cosmetic: with it
          // unset the CLI answers out of the macOS keychain, which the copilot
          // cannot reach — so the probe would report the *machine's* login and
          // call a signed-out copilot signed in. See the spawn for the
          // measurement.
          {
            ...process.env,
            ...confinedHomeEnv(home, platform),
            CLAUDE_CONFIG_DIR: copilotConfigDir(home),
          },
          path,
          platform,
        ),
        timeout: 15_000,
        encoding: 'utf8',
        windowsHide: true,
      }),
    )
    // stdout and stderr together, because a CLI free to print a deprecation
    // notice above its JSON is equally free to print the JSON to either — the
    // same joined read `profiles-signin.ts` makes, and `parseAuthStatus` finds
    // the object inside whatever surrounds it.
    const parsed = parseAuthStatus(`${output.stdout}\n${output.stderr}`)
    if (parsed === null) return unknown
    return {
      state: parsed.loggedIn ? 'signed-in' : 'signed-out',
      account: parsed.account,
      plan: parsed.plan,
    }
  } catch (error) {
    /*
     * The CLI could not be run, was refused, or timed out. None of those is
     * evidence of being signed out, so the answer stays `unknown`.
     *
     * It is *logged*, though, and that is not decoration. `unknown` is drawn as
     * a sentence saying this window could not check — which is honest and gives
     * nobody anything to act on — and the failure is otherwise completely
     * silent, so an install where this always fails looks exactly like one where
     * the probe is merely slow. The first symptom would be that the first-run
     * explanation never appears for a copilot that genuinely is signed out,
     * which is the one state a person most needs explained.
     */
    console.error('[copilot] could not read the sign-in state:', error)
    return unknown
  }
}

/**
 * The confinement plan for the copilot, in one place.
 *
 * Two callers need the identical plan and they are on different paths — the
 * spawn goes through `startSession`, the sign-in probe runs a command directly —
 * so a second spelling of it would be a probe that measured a boundary the
 * session does not actually run inside.
 *
 * `projects` is optional and the sign-in probe leaves it out, which is not an
 * inconsistency: the probe runs `claude auth status` and needs to be inside the
 * same *boundary* the session runs in — the same home, the same config
 * directory, the same refusals — and giving it read access to somebody's
 * repositories to ask whether a token file exists would be a grant with no
 * purpose. Narrower is always allowed; the rule this file obeys is that the
 * probe may never be *wider* than the session it is measuring.
 */
export function copilotPlan(input: {
  folder: string
  home: string
  accountHome: string
  path: string
  platform: Platform
  projects?: readonly string[]
}): ConfinementPlan {
  return planFor({
    folder: input.folder,
    // Its git directory is inside its home, which is already writable, so there
    // is nothing extra to grant. Listed as nothing rather than listed
    // redundantly: `collapse` would drop it, and a plan that names a path it
    // does not need reads as if that path were the point.
    //
    // `projects` is the one thing this device confinement carries that a paired
    // device's never does, and it goes into the plan's *read* list. `writable`
    // stays empty.
    device: { home: input.home, writable: [], files: [], projects: input.projects ?? [] },
    accountHome: input.accountHome,
    path: input.path,
    platform: input.platform,
  })
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * The renderer's questions, and deliberately not one more.
 *
 * **Every handler takes no arguments.** That is the validation: there is no path
 * to sanitise, no id to check and no way for page code to ask for a copilot
 * somewhere else, because nothing about where it runs comes from the renderer.
 * A window can start it, stop it, ask how it is, ask what it read, and put its
 * instructions back — which is the whole of what the settings pane and the
 * pinned sidebar entry need.
 *
 * `copilot:reset-instructions` is the newest and the only one that writes.
 * It still takes nothing: *which* file and *what* goes in it are both decided in
 * this process, so the page can ask for the shipped instructions to be restored
 * and cannot ask for anything else to be written anywhere. What was there is
 * copied aside first — see `resetCopilotInstructions` — because a person who
 * clicks it having forgotten they hand-edited the file should be able to get
 * their words back.
 *
 * Nothing here returns a credential. The sign-in channel answers with a state, an
 * account name and a plan, which is what a pane draws; the token itself is in a
 * directory this process does not read.
 */
export function registerCopilotIpc(ipcMain: IpcMain, deps: CopilotRuntimeDeps): void {
  ipcMain.handle('copilot:ensure', () => ensureCopilot(deps))
  ipcMain.handle('copilot:state', () => copilotState(deps))
  ipcMain.handle('copilot:files', () => copilotState(deps).startupFiles)
  ipcMain.handle('copilot:stop', () => stopCopilot(deps))
  ipcMain.handle('copilot:signin', () => readCopilotSignIn(deps))
  ipcMain.handle('copilot:reset-instructions', () => {
    const { paths } = resolve(deps)
    const result = resetCopilotInstructions(paths)
    if (result.error === null) {
      appendCopilotAction(paths, {
        action: 'instructions.reset',
        detail:
          result.backup === null
            ? 'restored the instructions this build ships'
            : `restored the instructions this build ships; the previous file is at ${result.backup}`,
      })
    }
    // The state, not the result on its own: a pane that has just reset the file
    // needs the new `instructions` value and the new startup-file sizes in the
    // same round trip, or it draws the old ones until something else refreshes.
    return { ...result, state: copilotState(deps) }
  })
}
