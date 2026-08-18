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
 * ## It is an ordinary session, and that reversal is the important part of this file
 *
 * It was not. Until this change the copilot ran inside the full folder
 * confinement a session from a *paired device* runs inside: `(deny default)`, a
 * granted folder, a home directory of its own, the person's projects read-only,
 * their `.env` files carved back out, and a flat refusal to start at all on a
 * platform where none of that could be proven. The reasoning is in
 * `COPILOT-DESIGN.md` and it was not arbitrary — a CLI session has Bash, Bash is
 * the whole machine, and this app ships to strangers.
 *
 * It was still wrong, and the way it was wrong is worth keeping written down,
 * because it is a trade that will look tempting again.
 *
 * **What the jail cost.** The copilot started **signed out**, every time, on
 * every machine — its login would live in the macOS login keychain and the
 * keychain is closed to a `(deny default)` process. It could not write a line of
 * anything. Off macOS it did not exist: `confinementKind` answers `'none'` on
 * Windows until a one-time grant nothing in the shipped UI performs, so the
 * start path refused outright. And a Seatbelt profile is fixed at `exec`, so
 * opening a new project meant stopping the copilot and losing the conversation.
 * The net of it is that the agent meant to *supervise* the others was less
 * capable than any of them, which is exactly backwards.
 *
 * **What the jail bought.** Protection against the copilot *reading* things —
 * secrets, other accounts, the keychain. Worth having, and narrower than it
 * sounds: the network is open to every confined session by design, because
 * closing it would stop `git push`, `npm install` and every agent CLI. So a
 * determined exfiltration was never blocked by the boundary; only the pool of
 * things to exfiltrate was smaller.
 *
 * **What actually controls a copilot** is the consent gate and the action log —
 * they govern what it *does*, which is where the risk is. A gate is also
 * legible: a person sees the prompt and decides. A jail is invisible, and its
 * failures look like the product being broken.
 *
 * So: the copilot now runs under the same policy as any other session started at
 * this keyboard. `startSession` is handed no `DeviceConfinement`, exactly as
 * `session:create` hands it none, which is the app's own way of saying "a person
 * at their own keyboard, with no grant to be held inside". It reads and writes
 * what they read and write. It signs in through the profile system like every
 * other session. It starts on every platform.
 *
 * ## Its account comes from the profile system, and the signed-out first run is gone
 *
 * `profileId` is left null and {@link resolveProfile} answers, which is what
 * every session started from a window does: a per-project pin if the person set
 * one for the copilot's folder, otherwise their global default, otherwise their
 * own install of Claude Code. That last case is the common one and it is the
 * whole win — their own install reads the login keychain, so a person who is
 * already signed into Claude Code has a copilot that is already signed in.
 *
 * Measured, because it is the assumption the change rests on: under
 * `(allow default)` — the records fence below — `claude auth status --json`
 * answers `{"loggedIn": true, …}`. Under the old `(deny default)` profile the
 * same command answers `Not logged in`. `confine/records.ts` carries the run.
 *
 * `CLAUDE_CONFIG_DIR` is no longer set here and must not come back. It existed
 * to force the CLI off the keychain and onto a file inside the sandbox, which
 * was the only way a jailed copilot could ever be signed in. Setting it now
 * would take the copilot back off the person's account and into a store of its
 * own that nothing signs in — reintroducing the exact cost this change removes,
 * through the same variable.
 *
 * {@link readCopilotSignIn} therefore asks the ordinary question about the
 * ordinary profile: `readSignIn(profile)`, the same call the accounts pane
 * makes, with the same cache. There is nothing copilot-specific left in it,
 * which is the point.
 *
 * ## What is kept: the records fence
 *
 * Two things had to survive the boundary going away, and one of them needed a
 * mechanism rather than a paragraph.
 *
 * **The forgery protections.** Routines and the action log stay out of the
 * copilot's writable reach — not because it is jailed, but because those three
 * paths, and only those three, are denied to its process. `confine/records.ts`
 * carries the whole argument, the profile and the measurements. It is a fence
 * around this app's own *records*, not around the machine: the copilot inside it
 * has the keychain, the person's home directory and every one of their
 * repositories, and cannot compose the log that says what it did.
 *
 * It **fails open, visibly**. Off macOS there is no fence and
 * {@link CopilotRecords.reason} says so, in a sentence the settings pane draws.
 * That is the opposite of what confinement does, and deliberately: the fence
 * protects the record rather than the disk, so a machine that cannot hold it has
 * worse auditing rather than an escaped agent — and refusing to start the
 * copilot over it would be refusing the whole feature on every platform but one,
 * which is the failure being corrected.
 *
 * **The transcript scope.** `installHomeScopes` narrows any copilot home *found
 * on disk* to answering for the copilot's own folder. The copilot no longer
 * writes there — its conversation goes into its profile's store like everybody
 * else's — but an install upgraded from a build that jailed it still has one,
 * with real history in it, and that store must keep being read for the copilot's
 * own folder and never for anybody else's. `copilot-transcript-forgery.test.ts`
 * is the proof, and {@link copilotHomeScope} is why this module still knows
 * where that home was.
 *
 * ## What is honestly *not* kept, said here rather than discovered later
 *
 * **Memory isolation is now a rule, not a wall.** The old header claimed the
 * copilot could not read other sessions' transcripts at all, because they sat
 * outside its boundary. That claim was already only half true — `deck-control`'s
 * `sessions.transcript` hands it their contents through the front door, by
 * design, because reading the fleet's transcripts is one of the capabilities the
 * copilot exists for. What the boundary actually prevented was reading them *as
 * files*, and the rule that matters was never about reading: it is
 * `COPILOT-CAPABILITIES.md` §4.1, *it may read another session's transcript to
 * answer a question; it may not copy that into `memory/`* — and no filesystem
 * rule ever enforced that, because both halves happen inside the copilot's own
 * boundary. It is stated as a rule in the copilot's `CLAUDE.md`, in those words,
 * and the settings pane says it is a rule. A check on the memory-write path is
 * the mechanism that would make it a wall; it does not exist yet and this file
 * does not pretend otherwise.
 *
 * **The credential carve-out is gone.** `confine/secrets.ts` refused `.env`,
 * private keys and `.npmrc` inside every folder the copilot could read. It was
 * good, and it was a *stricter* rule than any other session on this machine
 * obeys — which is the thing being removed. It belongs back as a product-wide
 * option over every session, not as a special case for this one.
 */

import { join } from 'node:path'
import type { IpcMain } from 'electron'
import type { CreateSessionInput, ProviderId, SessionMeta } from '../shared/types'
import { deviceHomesRoot } from './confine'
import {
  buildRecordsFence,
  recordsFenceKind,
  recordsFenceList,
  recordsFencePaths,
  recordsFenceUnavailable,
  type RecordsFence,
  type RecordsFenceKind,
} from './confine/records'
import {
  appendCopilotAction,
  copilotHomeReport,
  copilotPaths,
  readCopilotInstructions,
  readFolderInstructions,
  resetCopilotInstructions,
  scaffoldCopilotHome,
  writeCopilotInstructions,
  writeFolderInstructions,
  type CopilotPaths,
  type InstructionsReadResult,
  type InstructionsState,
  type StartupFile,
} from './copilot-home'
import { copilotFolderReport, type CopilotFolderReport } from './copilot-folder'
import {
  copilotLayerArgs,
  readComposedLayer,
  readLayerFile,
  writeCopilotLayer,
  type LayerTool,
} from './copilot-layer'
import { currentPlatform, type Platform } from './platform/host'
import { userDataDir } from './platform/paths'
import { readSignIn } from './profiles-signin'
import { detectProviders, PROVIDERS } from './providers'
import type { HomeScope } from './transcript'
import { getState as profilesState, resolveProfile, type Profile } from './profiles'

/* ------------------------------------------------------------------ model -- */

/**
 * The name the copilot's home directory had, back when it had one.
 *
 * **Nothing creates this any more.** A jailed copilot needed a home of its own —
 * its login, its caches and its transcripts had to be inside the boundary — and
 * it was put in the confined-homes root so that `transcript.ts`, which walks
 * every directory under that root, would find its conversation with no change to
 * any reader. An unjailed copilot runs as an ordinary profile and writes where
 * every other session writes, so there is nothing left to place.
 *
 * The name survives for one reason, and it is not nostalgia: an install upgraded
 * from a build that jailed the copilot still has that directory on disk, with
 * real conversations in it, and it is still inside a root that four readers
 * scan. {@link copilotHomeScope} is what keeps it answering for the copilot's
 * own folder and for nobody else's, and this constant is how that pair is
 * spelled in one place. See `copilot-transcript-forgery.test.ts`.
 */
export const COPILOT_HOME_KEY = 'copilot'

export type CopilotStatus =
  /** Never started, or its process has gone. */
  | 'stopped'
  /** A start is in flight. */
  | 'starting'
  /** Its process is alive. */
  | 'running'

export type CopilotSignInState = 'signed-in' | 'signed-out' | 'unknown'

export interface CopilotSignIn {
  state: CopilotSignInState
  /** The account the CLI named, when it named one. */
  account: string | null
  /** Its plan or auth method, as the CLI reported it. */
  plan: string | null
  /** Which profile was asked — the account this copilot actually runs as. */
  profileId: string
  /** That profile's name, so a pane can say it without a second round trip. */
  profileName: string
  checkedAt: number
}

/**
 * The three of this app's own files the copilot is refused, and whether the
 * refusal is real on this machine.
 *
 * This is what replaced `confinement` on this type, and the swap is the whole
 * change in one field. The old one answered *which jail is this agent in*. This
 * one answers *can it rewrite the record of what it did* — a smaller question
 * with a much better answer, and the only one a person actually needs, because
 * the copilot is otherwise an ordinary session with their own account.
 */
export interface CopilotRecords {
  /** `seatbelt` where the fence is held, `none` where it is not. */
  kind: RecordsFenceKind
  /**
   * True only when a *running* process was actually started inside a proven
   * fence. False while nothing is running, for the same reason the old
   * `enforced` was: a claim about a process is worth nothing without one.
   */
  enforced: boolean
  /** Why the fence is not held, or null. Always set when `kind` is `none`. */
  reason: string | null
  /**
   * What is fenced, absolute, so a pane can list it rather than describing it.
   *
   * Generated from the same function the profile is, so the screen and the
   * kernel cannot come to disagree about which paths are meant.
   */
  paths: readonly string[]
}

export interface CopilotState {
  status: CopilotStatus
  /** The live session's id, so a window can open the same tab everything else sees. */
  sessionId: string | null
  /** Its folder, its instructions, its memory, its log. */
  paths: CopilotPaths
  /**
   * Which folder it works in, whether that folder was chosen, and whether the
   * running copilot is still in the old one.
   *
   * On the state rather than fetched separately because every sentence the pane
   * writes about the folder needs two of these fields at once — "you chose X,
   * it is running in Y, restart it" is three — and two round trips is how a
   * pane ends up drawing a contradiction for one frame.
   */
  folder: CopilotFolderReport
  /**
   * Where a jailed copilot kept its login and its transcripts.
   *
   * Still reported, and still on disk on an upgraded install, because that is
   * where its conversations from before this change are. Nothing writes here
   * now. See {@link COPILOT_HOME_KEY}.
   */
  home: string
  startedAt: number | null
  /** Why the last start did not produce a running copilot, or null. */
  problem: string | null
  /** Whether this app's own routines and action log are held against it. */
  records: CopilotRecords
  /**
   * The account it runs as, resolved the way any other session's is.
   *
   * Null before anything has asked. A pane draws this rather than a sentence
   * about a login inside a sandbox, because there is no longer such a thing:
   * the copilot uses one of the profiles in the accounts list.
   */
  profile: { id: string; name: string } | null
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
  /** The files it reads at startup, in order. */
  startupFiles: StartupFile[]
  /** The three app-side files: yours, the generated one, and the composition. */
  layerFiles: StartupFile[]
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
  /**
   * The one session starter, from `createHostCore`.
   *
   * The copilot passes neither `guest` nor `confine`, which is exactly what
   * `session:create` passes for a tab a person opened — that absence *is* the
   * policy. `fence` is the one thing it does pass, and it is not confinement: it
   * wraps the launch so three of this app's own files stay out of reach. See
   * `confine/records.ts`.
   */
  startSession(
    input: CreateSessionInput,
    guest?: undefined,
    confine?: undefined,
    fence?: SpawnFence,
    extraArgs?: readonly string[],
  ): Promise<SessionMeta>
  /** Is that session still alive? Asked on every state read; see the header. */
  isAlive(sessionId: string): boolean
  /** Stop it. */
  stop(sessionId: string): void
  /**
   * Where the `deck-control` MCP config is, or null when there is no server.
   *
   * This is what gives the copilot **any** tools. Without it the session is a
   * Claude CLI with the native tools and nothing of this app's — it cannot list
   * a session, read a transcript, look at a screen or ask for a confirmation,
   * and every sentence in the product about the copilot being "bounded by the
   * tool tiers and the consent gate" describes a gate that is not in the path,
   * because there is nothing to gate.
   *
   * Injected rather than imported, and the reason is the one this whole
   * interface exists for: `deck-control` is started by the Electron shell at
   * boot, asynchronously, and it can fail to start — a loopback port that will
   * not bind, a token file that cannot be made owner-only. Importing
   * `mcpConfigPath()` here would produce a *path* in all three of those cases,
   * which is worse than none: `claude --mcp-config` on a file that is missing,
   * stale or holds a dead token is a session that starts and then cannot reach
   * the tools it was told it has. Asking the shell means the answer is "the
   * config of the server that is actually listening", or null.
   *
   * Null is honest and is not a failure to start: the copilot runs, with no
   * tools, and says so — its `CLAUDE.md` tells it to read its own tool list and
   * state plainly when a capability is not there.
   */
  mcpConfig?(): string | null
  /** `<userData>`. Defaults to this shell's answer. */
  userData?(): string
  /**
   * The folder the person chose, as the setting holds it, or null.
   *
   * Asked on every read rather than captured, because a person can change it in
   * Settings while the app is running and the pane's next frame has to show the
   * new answer — even though the *running* copilot is still in the old folder,
   * which is exactly the state {@link CopilotFolderReport.restartNeeded} is for.
   *
   * A dep rather than a read of `settings-extra.ts`, for the reason every other
   * field here is one: this module is imported by tests that never boot a shell,
   * and by a headless build whose settings live somewhere else.
   */
  home?(): string | null
  /**
   * The live tool catalogue, for the generated half of the layer.
   *
   * `DeckControl.tools()`, handed in by whichever shell built the server, so the
   * file the copilot is told about its tools in is composed from **the tools
   * that exist** rather than from a list somebody maintained. Absent, or empty,
   * means no `deck-control` server is running — a real state, said plainly in
   * the generated file rather than papered over with a stale list.
   */
  tools?(): readonly LayerTool[]
  /** Where remote and confinement storage lives — `<userData>/remote`. */
  storageDir?(): string
  /** Which agent CLIs this machine has. Defaults to the real probe. */
  agents?(): Promise<Record<ProviderId, boolean>>
  /**
   * Measure the records fence and hand back something to wrap the spawn with.
   *
   * Injected only so a test can drive both answers without a machine on which
   * each is true. Defaults to the real measurement, which runs `sandbox-exec`.
   */
  fence?(userData: string, platform: Platform): Promise<{ fence: RecordsFence | null; reason: string | null }>
  /**
   * Which account the copilot runs as, resolved the way any session's is.
   *
   * Defaults to the profile system, which is the whole point: a copilot that
   * resolved its account any other way would be the special case this change
   * removed. Injectable so tests need no `profiles.json`.
   */
  profile?(projectPath: string): Profile
  /** Its sign-in state, asked of the same profile. Defaults to `readSignIn`. */
  signInOf?(profile: Profile): Promise<{
    state: CopilotSignInState | 'unsupported'
    account: string | null
    plan: string | null
  }>
  platform?: Platform
  /** Initial terminal size. The window resizes it the moment it attaches. */
  cols?: number
  rows?: number
}

/**
 * What `startSession` needs in order to wrap a launch.
 *
 * Structurally the same shape `confine/records.ts` produces, restated here so
 * that `host-core.ts` can take one without importing a confinement module — the
 * host core knows how to start a session and deliberately does not know what a
 * fence is for.
 */
export interface SpawnFence {
  apply(command: string, args: readonly string[]): { command: string; args: string[] }
}

interface Resolved {
  paths: CopilotPaths
  folder: CopilotFolderReport
  userData: string
  storageDir: string
  platform: Platform
  cols: number
  rows: number
}

function resolve(deps: CopilotRuntimeDeps): Resolved {
  const userData = deps.userData?.() ?? userDataDir()
  /*
   * The folder decision, made here and nowhere else.
   *
   * `copilotFolderReport` is what turns a stored string into a usable one: a
   * chosen folder that has since been unmounted, deleted or pointed inside this
   * app's own storage falls back to the default and reports why, rather than
   * refusing to start. An assistant that will not run because an external drive
   * is missing is worse than one that runs in its own folder and says so — and
   * `folder.problem` is drawn in the pane, so nothing about the fallback is
   * quiet.
   */
  const folder = copilotFolderReport({
    stored: deps.home?.() ?? null,
    userData,
    runningIn: live?.root ?? null,
  })
  return {
    folder,
    paths: copilotPaths(userData, folder.home),
    userData,
    storageDir: deps.storageDir?.() ?? join(userData, 'remote'),
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
  /**
   * The folder it was actually started in.
   *
   * Recorded rather than recomputed, and for the same reason `fenced` is: a
   * working directory is fixed at `exec`. Somebody who changes the folder in
   * Settings changes what the *next* start will use, and a pane that read the
   * setting and called it "where it is running" would be stating something
   * false about a live process. This is the field that lets it say the true
   * thing instead — "it is still working in X" — and offer a restart.
   */
  root: string
  /**
   * Whether *this* process was started inside a proven records fence.
   *
   * Recorded rather than recomputed, for the reason the old project grant was:
   * a Seatbelt profile is fixed at `exec`, so what is true of the running
   * process is what was measured when it started, and asking again later would
   * answer about a process that does not exist.
   */
  fenced: boolean
  /** The account it was started as, so the state can name it without re-resolving. */
  profile: { id: string; name: string }
}

let live: Live | null = null
/** A start in flight. See the header: a boolean would not hold across the await. */
let starting: Promise<CopilotState> | null = null
/** Why the last attempt did not produce a running copilot. */
let problem: string | null = null
/** Why the records fence is not held, when it is not. Null when it is. */
let fenceProblem: string | null = null

/**
 * Is this session the copilot's own terminal?
 *
 * The one question the *network* has to be able to ask about a session, and the
 * reason it takes no dependencies: it is answered from a socket's read path,
 * inside `SessionFanout`, for every `list`, `attach`, `input` and `resize` a
 * paired device sends. `copilotState` would answer the same thing and cannot be
 * used — it wants the whole `CopilotRuntimeDeps`, it stats the copilot's folder
 * on every call, and neither is a thing to do per keystroke.
 *
 * ## What it is for, which is not a tidy grouping
 *
 * The copilot is an ordinary session, and that is the whole design: it means
 * the transcript viewer, chat mode, the cost pane and the sidebar work on it
 * with no changes. It also meant, in 0.3.0 as shipped, that a paired phone
 * could `list`, find the row whose folder is `<userData>/copilot`, `attach` to
 * it and type straight into the Claude CLI that holds `deck-control` — past
 * every tier check, every budget and every confirmation dialog, because none of
 * those sit between a pty and its keyboard. `remote/session-fanout.ts` is where
 * this answer is used and carries the rest of that argument.
 *
 * ## Why the reading is deliberately narrow
 *
 * True for exactly the session id this module started and is still holding, and
 * false for everything else — including a session the person opens *in the
 * copilot's folder themselves*, which is theirs and is not this. A rule written
 * against the folder rather than the id would have been the wider, sloppier
 * version of the same idea and would have hidden a tab the person opened
 * deliberately.
 *
 * A stale `live` — the copilot's process has exited but nothing has recomputed
 * the state yet — answers `true` for a dead id, which is the safe direction: an
 * attach to a dead session is refused anyway, and ids are not reused.
 */
export function isCopilotSession(sessionId: string): boolean {
  return live !== null && live.sessionId === sessionId
}

/** Forget everything. For tests, and for nothing else. */
export function resetCopilot(): void {
  live = null
  starting = null
  problem = null
  fenceProblem = null
  signIn = null
}

/* ------------------------------------------------------ the records fence -- */

/**
 * What a pane draws about the records fence, running or not.
 *
 * `enforced` is deliberately a fact about a *process* rather than about the
 * machine, exactly as the old `confinement.enforced` was: a fence is a thing a
 * running thing is inside, and reporting one where nothing is running would be
 * the app claiming a property of something that does not exist.
 *
 * `reason` is filled from two different places and both matter. Before anything
 * has started it is the platform's own sentence, so a Windows user opening
 * Settings learns what is and is not true there without starting anything. After
 * a start it is whatever the measurement actually said, which can be more
 * specific — `sandbox-exec` missing, a profile that would not run.
 */
function recordsState(deps: CopilotRuntimeDeps, alive: boolean): CopilotRecords {
  const { userData, platform } = resolve(deps)
  const kind = recordsFenceKind(platform)
  return {
    kind,
    enforced: alive && live !== null && live.fenced,
    reason: kind === 'none' ? recordsFenceUnavailable(platform) : fenceProblem,
    paths: recordsFenceList(recordsFencePaths(userData)),
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
 * ## `unavailable` is gone, and its absence is the change
 *
 * This used to answer `unavailable` — a dead end with a sentence — on every
 * platform where `confinementKind` said `'none'`, which is every Windows machine
 * and every Linux one where the namespace mechanism cannot be proven. The
 * copilot did not exist there. It does now: no boundary is required to run it,
 * because it is an ordinary session, so the only reasons it will not start are
 * the ordinary ones (no Claude Code on this machine, the folder could not be
 * made) and those are already `stopped` with a `problem`.
 */
export function copilotState(deps: CopilotRuntimeDeps): CopilotState {
  const { paths, folder, storageDir } = resolve(deps)
  const report = copilotHomeReport(paths)
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
    : problem !== null
      ? 'stopped'
      : starting !== null
        ? 'starting'
        : 'stopped'

  return {
    status,
    sessionId: alive && live !== null ? live.sessionId : null,
    paths,
    /*
     * Recomputed against the *live* session rather than reusing the one
     * `resolve` made, because `resolve` ran before the liveness check above and
     * a copilot that has since exited must not still be reported as "running in
     * the old folder" — that is the sentence that puts a Restart button in front
     * of somebody with nothing to restart.
     */
    folder: { ...folder, runningIn: alive && live !== null ? live.root : null,
      restartNeeded: alive && live !== null && live.root !== folder.home },
    home: copilotHome(storageDir),
    startedAt: alive && live !== null ? live.startedAt : null,
    problem,
    records: recordsState(deps, alive),
    profile: alive && live !== null ? live.profile : null,
    instructionsAreDefault: report.instructionsAreDefault,
    instructions: report.instructions,
    startupFiles: report.startupFiles,
    layerFiles: report.layerFiles,
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
 * The cost of sitting in that root was that the copilot — which could write
 * inside its own home, and could write nowhere else — could create
 * `<home>/.claude/projects/<encode(somebody's repo)>/x.jsonl` and have those
 * same four readers render it as a conversation belonging to that repo. Nothing
 * about the boundary was wrong there; the file was inside it. What was wrong is
 * that a store belonging to one folder was being consulted for every folder.
 *
 * So the pair is registered as a scope: the copilot's store answers for
 * {@link CopilotPaths.root}, which is the only directory its sessions ever ran
 * in, and for nothing else. Nothing legitimate is lost — its own transcript is
 * found exactly as before — and a fabricated one is never looked for.
 *
 * **This survives the copilot no longer having a home**, and that is why it is
 * still installed at boot. Nothing writes into that directory any more; an
 * install upgraded from a build that jailed the copilot still *has* one, holding
 * its conversations from before the change, and that store is still inside a
 * root four readers scan. Removing the scope would put every one of those old
 * files back in front of every project. Keeping it costs one entry.
 *
 * `storageDir` defaults the same way {@link resolve} does, because the two must
 * not disagree about where the homes are.
 */
export function copilotHomeScope(userData: string, storageDir = join(userData, 'remote')): HomeScope {
  return { home: copilotHome(storageDir), folder: copilotPaths(userData).root }
}

/**
 * Start the copilot if it is not already running, and answer with its state.
 *
 * Idempotent by design and by contract — a window calls this when it opens, when
 * a person clicks the pinned entry, and after a reconnect, and none of those may
 * produce a second agent. Every early return below is one of those cases.
 *
 * It does not throw for an ordinary refusal. A copilot that will not start
 * because the CLI is missing is a state a pane has to *draw*, and turning it into
 * a rejected promise would push that job onto every caller and lose the reason on
 * the way.
 */
export async function ensureCopilot(deps: CopilotRuntimeDeps): Promise<CopilotState> {
  if (live !== null && deps.isAlive(live.sessionId)) return copilotState(deps)
  if (starting !== null) return starting

  const attempt = startCopilot(deps).finally(() => {
    starting = null
  })
  starting = attempt
  return attempt
}

async function startCopilot(deps: CopilotRuntimeDeps): Promise<CopilotState> {
  const { paths, folder, userData, platform, cols, rows } = resolve(deps)
  problem = null

  /*
   * A chosen folder that could not be used, recorded before anything else runs.
   *
   * The start does not fail for this — see `copilotFolderReport` — so without a
   * row here the only evidence would be a sentence in a settings pane nobody has
   * open. "Why is my assistant suddenly not remembering anything" has an answer,
   * and this is where it is kept.
   */
  if (folder.problem !== null) {
    appendCopilotAction(paths, {
      action: 'folder.unusable',
      detail: `${folder.chosen ?? 'the chosen folder'} — ${folder.problem} Starting in ${paths.root} instead.`,
    })
  }

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
   * The CLI has to be there. `startSession` falls back to a plain shell when the
   * requested agent is missing — correct for a tab, and a lie for this: a shell
   * pinned in the sidebar as your assistant is a feature that does not exist.
   *
   * This is now the *only* thing that can stop the copilot existing, and that is
   * the change. There used to be a check above it refusing to start at all where
   * `confinementKind` answered `'none'` — every Windows machine, and every Linux
   * one where the namespace mechanism could not be proven. It was right while the
   * copilot was an agent the app ran inside a jail; it is wrong for a session the
   * person runs as themselves, and it was the reason the copilot did not exist on
   * two of three platforms.
   */
  const available = await (deps.agents?.() ?? detectProviders(platform, null))
  if (!available.claude) {
    return refuse(
      deps,
      `The copilot runs on ${PROVIDERS.claude.label}, which is not installed on this machine.`,
    )
  }

  /*
   * The records fence, measured now rather than assumed.
   *
   * Before the spawn because it wraps the spawn, and every start rather than
   * once because a machine can change its mind — `sandbox-exec` is deprecated,
   * and a proof cached from this morning is a claim about a process that has
   * already exited.
   *
   * A failure here does **not** stop the copilot. See the header: this fence
   * protects the record of what the copilot did, not the person's disk, so a
   * machine that cannot hold it has worse auditing rather than an escaped agent
   * — and refusing the whole feature over it is precisely the mistake being
   * corrected. The reason is kept, reported in the state, and drawn in Settings.
   */
  const measured = await (deps.fence ?? defaultFence)(userData, platform)
  fenceProblem = measured.reason

  /*
   * Its account, resolved exactly the way any other session's is.
   *
   * `resolveProfile` with the copilot's own folder as the project path, which is
   * the same call `host-core.ts` makes for a tab: a per-project pin if the
   * person set one for this folder, otherwise their global default, otherwise
   * their own install of Claude Code. The id is then handed to `startSession`
   * rather than left null, so that what the state reports and what the session
   * actually runs as cannot come apart — the resolution happens once, here.
   */
  const profile = (deps.profile ?? defaultProfile)(paths.root)

  /*
   * Its tools, which until now it did not have.
   *
   * `deck-control` wrote this config file on every start, the loopback server
   * listened behind a bearer token, the routine runner passed it — and nothing
   * passed it to the copilot. So the agent a person talks to in the sidebar had
   * the native Claude Code tools and none of this app's, and every claim that it
   * was "bounded by the tool tiers and the consent gate" described a gate that
   * was not in the path. It was honest about it, because its `CLAUDE.md` tells
   * it to read its own tool list and say plainly when a capability is missing.
   * Honest is not the same as finished.
   *
   * The invocation was measured against the real CLI on this machine (Claude
   * Code 2.1.233) pointed at a live server: it connects with no approval prompt
   * and answers `sessions_list` with the real fleet.
   *
   * `--strict-mcp-config` is not decoration. Without it the copilot *also*
   * inherits whatever MCP servers happen to be configured in the person's own
   * `~/.claude.json` — so its powers, and the action log that is supposed to
   * account for them, would depend on something nobody thought of as part of
   * this feature. With it, the copilot's tool surface is exactly the native
   * Claude Code tools plus these.
   */
  const config = deps.mcpConfig?.() ?? null
  const mcpArgs = config === null ? [] : ['--mcp-config', config, '--strict-mcp-config']

  /*
   * Its identity, composed now and handed over on the command line.
   *
   * This is the change the whole folder feature turns on. The copilot used to be
   * told what it was by a `CLAUDE.md` in its working directory, which is fine
   * while that directory belongs to nobody and wrong the moment a person can
   * choose it: their folder already has instructions, and — the worse half — a
   * `CLAUDE.md` on disk is read by *every* session started there, so an ordinary
   * terminal in the same folder would come up believing it was the copilot.
   *
   * So the layer is regenerated here, on every start, and handed to exactly this
   * process. Regenerated rather than cached because all three of its inputs can
   * have changed since the last start: the tool catalogue between builds, the
   * fence between machines, and the working directory ten seconds ago in
   * Settings.
   *
   * The tool list comes from the live server rather than from `buildCatalogue()`
   * — the same array `tools/list` answers with — so the file that tells the
   * copilot what it can do and the surface it actually has cannot disagree. With
   * no server, both `config` and this are empty, and the generated file says so
   * in words rather than listing tools that are not there.
   */
  const layer = writeCopilotLayer(paths.layer, {
    root: paths.root,
    actionsLog: paths.actions,
    chosenFolder: !paths.ownFolder,
    userData,
    tools: deps.tools?.() ?? [],
    toolsAttached: config !== null,
    platform,
  })
  if (layer.composed === null) {
    /*
     * Refused rather than started without it, and this is the one place in this
     * function that trades availability for correctness.
     *
     * A copilot spawned with no layer is not a diminished copilot. It is a plain
     * Claude Code session in somebody's workspace, wearing this app's name in
     * the sidebar, with this app's tools attached and none of the instructions
     * that say what to confirm before using them. A refusal a person can read is
     * better than that.
     */
    return refuse(deps, `The copilot's instructions could not be prepared: ${layer.error}`)
  }

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
        profileId: profile.id,
      },
      /*
       * No guest git environment and no confinement, and both absences are the
       * policy rather than an omission.
       *
       * `prepareGuestGit` used to strip `GH_TOKEN`, `GITHUB_TOKEN` and
       * `SSH_AUTH_SOCK` and point the copilot at a git identity of its own. That
       * belongs to a *guest* — a paired device whose owner is not the person at
       * this keyboard — and applying it here made the copilot the one agent in
       * the app that could not push a branch or read the person's git config.
       * The copilot is not a guest. It is them.
       *
       * `undefined` is spelled out rather than the arguments being left off,
       * because the fence is the fourth one and skipping to it needs them named.
       */
      undefined,
      undefined,
      measured.fence ?? undefined,
      [...mcpArgs, ...copilotLayerArgs(layer.composed)],
    )
  } catch (error) {
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

  live = {
    sessionId: meta.id,
    startedAt: meta.createdAt,
    root: paths.root,
    fenced: measured.fence !== null,
    profile: { id: profile.id, name: profile.name },
  }
  appendCopilotAction(paths, {
    action: 'session.started',
    sessionId: meta.id,
    /*
     * The row says what is true, including when what is true is worse.
     *
     * A person reading the Activity pane after the fact has to be able to tell a
     * session whose actions were held against it from one whose were not, and
     * the log is the only place that distinction is durable — the state is
     * recomputed and forgets. This is the same discipline `host-core.ts` applies
     * when it declines to write "unconfined" as a boundary note: say the fact,
     * once, in the place that keeps it.
     */
    detail:
      /*
       * Whose folder it started in, on the same row and before anything else.
       *
       * A person reading the Activity pane after the fact needs to be able to
       * tell a copilot that ran in this app's own directory from one that ran
       * inside a workspace of theirs, because the second one had their notes,
       * their context and whatever else is in that folder in front of it. The
       * state is recomputed and forgets which folder a past session used; the
       * log is the only place that is durable, which is the same argument the
       * fence note below is written for.
       */
      `cwd ${paths.root}${paths.ownFolder ? '' : ' (your folder — nothing of this app’s was written into it)'}` +
      (measured.fence === null
        ? `, as ${profile.name}, routines and this log NOT held against it${
            measured.reason === null ? '' : ` — ${measured.reason}`
          }`
        : `, as ${profile.name}, routines and this log held against it (${measured.fence.kind})`) +
      /*
       * And whether it has this app's tools at all, on the same row.
       *
       * A copilot with no `deck-control` server behind it looks exactly like one
       * whose every tool call is being refused — right up until somebody reads
       * the log. This is the only place that difference is durable, for the same
       * reason the fence note above is: the state is recomputed and forgets.
       *
       * The config's *path* is written, never its contents: the file holds a
       * bearer token for a server that can start sessions on this machine, and
       * this log is read in a settings pane.
       */
      (config === null
        ? ', with none of this app’s tools — no deck-control server is running'
        : `, with this app’s tools from ${config}`),
  })
  return copilotState(deps)
}

/** The real measurement. Named so the deps default reads as one thing. */
async function defaultFence(
  userData: string,
  platform: Platform,
): Promise<{ fence: RecordsFence | null; reason: string | null }> {
  return buildRecordsFence({ userData, platform })
}

/** The real resolution, through the app's own profile system. */
function defaultProfile(projectPath: string): Profile {
  return resolveProfile(profilesState(), { projectPath })
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
 * start it again — and it is how a change of account takes effect, because the
 * profile is resolved once, at the spawn.
 */
export function stopCopilot(deps: CopilotRuntimeDeps): CopilotState {
  const { paths } = resolve(deps)
  if (live !== null) {
    deps.stop(live.sessionId)
    appendCopilotAction(paths, { action: 'session.stopped', sessionId: live.sessionId })
    live = null
  }
  return copilotState(deps)
}

/* ---------------------------------------------------------------- sign-in -- */

let signIn: CopilotSignIn | null = null

/**
 * How long a sign-in answer is trusted before it is asked again.
 *
 * A minute, because the thing that changes it is a person completing a login in
 * front of the pane — so the answer has to refresh on a human timescale. It is
 * kept even though `readSignIn` has a cache of its own: that one is keyed on the
 * profile and shared with the accounts pane, and this one exists so the copilot
 * pane polling its state does not fan out into a spawn per render.
 */
const SIGN_IN_TTL_MS = 60_000

/**
 * Is the copilot signed in? Asked the ordinary way, about an ordinary account.
 *
 * This function used to be the most copilot-specific thing in the module: it
 * built the copilot's confinement plan, ran `claude auth status --json` *inside*
 * it against a `CLAUDE_CONFIG_DIR` no other session used, and unpicked the exit
 * status by hand — all of it because the copilot's login lived in a sandbox and
 * the machine could be signed in while the copilot was not.
 *
 * None of that is true now. The copilot runs as one of the profiles in the
 * accounts list, so the question "is the copilot signed in" is the question
 * "is that profile signed in", and `profiles-signin.ts` has answered that for
 * every account in the app since before the copilot existed — including the
 * measurement that mattered here, that `claude auth status --json` **exits 1
 * when it is not logged in** and the answer has to be read off the output rather
 * than the exit code.
 *
 * Three states, and `unknown` is never collapsed into `signed-out`, for the
 * reason `profiles-signin.ts` gives: they send a person to different places.
 */
export async function readCopilotSignIn(
  deps: CopilotRuntimeDeps,
  now = Date.now(),
): Promise<CopilotSignIn> {
  const profile = (deps.profile ?? defaultProfile)(resolve(deps).paths.root)
  /*
   * The cached answer is only reused for the *same* profile.
   *
   * Without the id check, changing which account the copilot runs as would keep
   * showing the previous account's state for up to a minute — and the moment a
   * person is most likely to look at this pane is straight after changing it.
   */
  if (signIn !== null && signIn.profileId === profile.id && now - signIn.checkedAt < SIGN_IN_TTL_MS) {
    return signIn
  }

  const answer = await (deps.signInOf ?? defaultSignIn)(profile)
  signIn = {
    // `unsupported` is an agent that cannot be signed in at all, which Claude
    // is not — but the type allows it, and folding it into `unknown` rather
    // than widening this one is right: a pane drawing the copilot has nothing
    // useful to do with a fourth state that cannot occur.
    state: answer.state === 'unsupported' ? 'unknown' : answer.state,
    account: answer.account,
    plan: answer.plan,
    profileId: profile.id,
    profileName: profile.name,
    checkedAt: now,
  }
  return signIn
}

/** The real probe, through the same reader the accounts pane uses. */
async function defaultSignIn(profile: Profile): Promise<{
  state: CopilotSignInState | 'unsupported'
  account: string | null
  plan: string | null
}> {
  const report = await readSignIn(profile)
  return { state: report.state, account: report.account, plan: report.plan }
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * The renderer's questions, and deliberately not one more.
 *
 * **Every handler but one takes no arguments.** That was the whole validation
 * here: there is no path to sanitise, no id to check and no way for page code to
 * ask for a copilot somewhere else, because nothing about where it runs comes
 * from the renderer. A window can start it, stop it, ask how it is, ask what it
 * read, read and write its instructions, and put the shipped ones back — which
 * is the whole of what the settings pane and the pinned sidebar entry need.
 *
 * `copilot:write-instructions` is the exception and the only argument any of
 * these takes: the text of `CLAUDE.md`. It is still true that *which* file is
 * decided in this process — the renderer names no path and cannot — so the
 * argument is content rather than a target, and the checks it needs are a type,
 * a floor and a ceiling rather than a containment proof. `writeCopilotInstructions`
 * holds all three, and copies what was there aside before writing, for the same
 * reason the reset does: a person who saves over their own wording by accident
 * should be able to get it back.
 *
 * `copilot:reset-instructions` takes nothing and puts *this build's* wording
 * back. It stays alongside the write rather than being subsumed by it, because
 * "restore the default" must not depend on a window having the default text to
 * send — the shipped instructions live in this process and a renderer that had
 * to hold a copy would be a second copy that can go stale.
 *
 * ## What a changed `CLAUDE.md` does, and when
 *
 * Nothing, until the copilot next starts. The CLI reads it as the session spawns
 * and never re-reads it, so there is no handler here that "applies" an edit and
 * there deliberately is not one — a running copilot has the old text in its
 * context and no message can replace it. A window that wants the edit live calls
 * `copilot:stop` and then `copilot:ensure`, which is what the settings pane
 * offers in those words.
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
  ipcMain.handle(
    'copilot:read-instructions',
    (): InstructionsReadResult => readCopilotInstructions(resolve(deps).paths),
  )
  /*
   * The app's half, and the composed whole, both read-only.
   *
   * There is no `write-contract` channel and there is not going to be one. The
   * contract describes what is wired — the tools that exist, their tiers, the
   * paths the kernel refuses — and a hand-edited copy of that drifts from the
   * thing it describes. This project has shipped exactly that defect twice: an
   * instruction file claiming a jail that had been removed, and one denying
   * powers the copilot had. Generated and unwritable is the fix, and the pane
   * says so beside the box rather than greying out a Save nobody can explain.
   *
   * They are read off disk rather than recomposed for the pane, because the
   * question a person is asking is *what was my assistant told*, and that is a
   * fact about the file the last start wrote — not about what a start would
   * write now, which differs the moment somebody edits their half.
   */
  ipcMain.handle('copilot:read-contract', () => {
    const { paths } = resolve(deps)
    return readLayerFile(paths.layer.contract)
  })
  ipcMain.handle('copilot:read-composed', () => {
    const { paths } = resolve(deps)
    return readComposedLayer(paths.layer)
  })
  ipcMain.handle('copilot:write-instructions', (_event, text: unknown) => {
    const { paths } = resolve(deps)
    const result = writeCopilotInstructions(paths, text)
    if (result.saved && result.backup !== null) {
      /*
       * Logged, and logged as the person's doing.
       *
       * The instruction file *is* the agent, so a copilot that answers
       * differently next week is a thing somebody will try to explain, and the
       * explanation is usually an edit made here and forgotten. The row names
       * the actor and points at the backup, because "what did it used to say"
       * is the second question and it has an answer on disk.
       *
       * Only when something was replaced: a first save into a file that did not
       * exist has no previous version to point at, and `backup === null` also
       * covers a save whose text matched what was already there — neither is a
       * change worth a row.
       */
      appendCopilotAction(paths, {
        action: 'instructions.edited',
        detail: `you edited its instructions from Settings; the previous file is at ${result.backup}`,
      })
    }
    // The state travels with the result for the reason the reset gives below:
    // the pane needs the new `instructions` value and the new file size in the
    // same round trip, or it draws the old ones until something else refreshes.
    return { ...result, state: copilotState(deps) }
  })
  /*
   * The folder's own instruction file — read here, and written only when a
   * person presses Save on text they are looking at.
   *
   * These two are the answer to the one row on the settings pane that still sent
   * somebody to Finder, and `copilot-home.ts` carries the argument in full. What
   * belongs *here* is the same sentence every other handler in this function is
   * an instance of: **the renderer names no path.** A window says "save this
   * text as the folder's instructions"; which folder that is was decided in this
   * process, from the chosen-folder setting, and a page that wanted to write
   * somewhere else has no way to say so. That is why the argument is content and
   * the checks it needs are a type, a floor and a ceiling rather than a
   * containment proof.
   *
   * Logged as the person's doing, like the layer's editor, and for a stronger
   * reason: this file is in a folder of theirs that other tools read, so "when
   * did this change and who changed it" is a question with consequences outside
   * this app. The row names where the replaced copy went.
   */
  ipcMain.handle('copilot:read-folder-instructions', () =>
    readFolderInstructions(resolve(deps).paths),
  )
  ipcMain.handle('copilot:write-folder-instructions', (_event, text: unknown) => {
    const { paths } = resolve(deps)
    const result = writeFolderInstructions(paths, text)
    if (result.saved) {
      appendCopilotAction(paths, {
        action: 'folder-instructions.edited',
        detail: result.created
          ? `you created the folder’s own instructions from Settings at ${paths.root}`
          : result.backup === null
            ? 'you saved the folder’s own instructions from Settings; nothing changed'
            : `you edited the folder’s own instructions from Settings; the previous file is at ${result.backup}`,
      })
    }
    // The state travels back for the reason the two writers above give: the row
    // draws its own "not there" badge off `startupFiles`, and a save that
    // created the file has just made that badge wrong.
    return { ...result, state: copilotState(deps) }
  })
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
