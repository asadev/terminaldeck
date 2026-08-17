/**
 * The machine, without a shell.
 *
 * ## What this file is
 *
 * Everything the app does *for the computer it is running on* — spawn a session
 * in a granted folder, keep the credential proxy that stops a guest inheriting
 * this machine's git login, remember which sessions were open so a restart can
 * put them back, decide which side of the WSL boundary a folder lives on. None
 * of it needs a window and none of it needs Electron.
 *
 * It lived inside `src/main/index.ts` until the headless build needed it, and
 * moving it out is the split `HEADLESS.md` asks for: **core** (sessions, remote
 * server, crypto, grants) and **shell** (Electron window, menus, renderer).
 * `index.ts` calls this and then adds a window; `src/headless/host.ts` calls the
 * same function and adds a control socket and a CLI.
 *
 * ## Why it is one function and not a folder of them
 *
 * Because the pieces genuinely reference each other and the order matters.
 * `PtyManager`'s callbacks feed the fanout, the fanout's `create` calls back into
 * the session starter, and the starter writes to the ledger that the exit
 * callback deletes from. Handing a shell four constructors and a page of
 * assembly instructions would be handing it four chances to assemble them
 * differently — and a second, subtly different arrangement is exactly what
 * "do not fork the code" means here. One `createHostCore` call, and the two
 * shells cannot disagree about what a session is.
 *
 * ## What is deliberately *not* here
 *
 * The window, the menus, the browser pane, notifications, the updater, the
 * settings file, and every `registerXIpc` that only a renderer calls. Those are
 * shell. So is the decision to *announce* anything: this file calls the hooks it
 * was given and has no opinion about whether they reach a React tree, a control
 * socket, or nothing at all.
 */

import { join } from 'node:path'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput, ProviderId, SessionMeta, SessionStatus } from '../shared/types'
import { PtyManager } from './pty-manager'
import {
  PROVIDERS,
  customProviderSpec,
  detectProviders,
  loginPath,
  providersFor,
  resolvedProvidersFor,
  withLaunchArgs,
} from './providers'
import { CustomAgentStore, lookupCommand } from './custom-agents'
import { isCustomProviderId } from '../shared/custom-agents'
import { currentPlatform, type Platform } from './platform/host'
import { homeDir } from './platform/paths'
import { getState as profilesState, resolveProfile, sessionEnv, supportsProfiles } from './profiles'
import {
  confineSpawn,
  confinedHomeEnv,
  confinementKind,
  deviceHomesRoot,
  installWindowsTools,
  planFor,
  prepareDeviceHome,
  windowsToolsFor,
  type DeviceConfinement,
} from './confine'
import { forgetBoundary, noteBoundary } from './session-boundary'
import { installDeviceHomes, installHomeScopes } from './transcript'
import { copilotHomeScope, isCopilotSession, type SpawnFence } from './copilot-session'
import { createCredentialProxy, deviceKey, type CredentialProxy } from './remote/credentials'
import { FolderGrants, foldersForDevice } from './remote/folder-grants'
import { guestGitDir, HELPER_FILE, type GuestGitEnv } from './remote/git-guest'
import { isHiddenSession } from './remote/hidden-sessions'
import { SessionFanout } from './remote/session-fanout'
import { remoteSessionStart } from './remote/session-create'
import type { SavedSession } from './session-restore'
import { store } from './store'
import {
  WslLink,
  isLinuxPath,
  wslEnvBridge,
  wslUncPath,
  type WslStore,
  type WslTarget,
} from './wsl'

/* ------------------------------------------------------------- the ledger -- */

/**
 * What each live session would need to be started again, keyed by session id.
 *
 * `ptys.list()` cannot answer this on its own: `SessionMeta` carries the
 * *resolved* provider and no profile at all, and neither of those is what a
 * relaunch should repeat. Insertion order is tab order, which is why the map is
 * a Map and not an object.
 *
 * It matters more to the headless build than it ever did to the desktop. WSL
 * shuts a distribution down when the last terminal closes, taking this process
 * and every session in it; the list on disk is what turns that from "the day's
 * work is gone" into "the sessions came back with `--continue`".
 */
export class OpenSessionLedger {
  private readonly records = new Map<string, SavedSession>()
  private frozen = false

  note(id: string, saved: SavedSession): void {
    this.records.set(id, saved)
    this.flush()
  }

  forget(id: string): void {
    this.records.delete(id)
    this.flush()
  }

  /**
   * Freshen "this is the one you were using", in memory only.
   *
   * Typing into a session is the only honest signal of the sort the core gets —
   * the active tab is renderer state and never crosses the bridge — and it
   * decides which tab in a folder gets to continue the conversation on the next
   * launch, because `--continue` is per folder and only one can. Memory only
   * because this runs per keystroke, and persisting on a keystroke would turn
   * typing into disk traffic for a field that is a tiebreak.
   */
  touch(id: string): void {
    const record = this.records.get(id)
    if (record) record.lastSeenAt = Date.now()
  }

  /**
   * Write the list out.
   *
   * ## The trap
   *
   * Shutting down kills every pty, and killing a pty fires `onExit` for every
   * session. Reconciling on those exits would empty the remembered list during
   * the last second of the process's life — so it would faithfully remember, on
   * every clean stop, that nothing was open, and the whole feature would work
   * only after a crash. {@link freeze} is called before the kill for exactly
   * this, and it is why this method has a guard rather than the callers having
   * one each.
   *
   * Writes go straight through rather than being batched behind a timer. This
   * fires when a session opens or closes — a human-paced event, a handful of
   * times an hour — and the store already writes through a temp file and a
   * rename, so a write costs one small file and cannot leave a torn one. A timer
   * would buy nothing and could lose the last change to a power cut, which is
   * the exact event this list exists to survive.
   */
  flush(): void {
    if (this.frozen) return
    store().setOpenSessions([...this.records.values()])
  }

  /** Stop writing. Called once, immediately after the last honest flush. */
  freeze(): void {
    this.frozen = true
  }
}

/* ---------------------------------------------------------------- options -- */

export interface HostCoreOptions {
  /** Everything remote access keeps on disk: the trust store, the identity, the grants. */
  storageDir: string
  /**
   * This install's own storage directory — `<userData>`.
   *
   * Named by the caller rather than derived from {@link storageDir}, even
   * though the second is the first's `remote/` subdirectory in both shells. The
   * headless build takes its state directory from a flag, so a `dirname` here
   * would be this file quietly assuming a layout that a command-line option can
   * change — and the thing it decides is which folder the copilot's transcript
   * store is allowed to answer for. A guess in that position is a security rule
   * that silently stops applying.
   */
  userData: string
  /**
   * Where the chosen WSL distribution is remembered.
   *
   * Optional, and absent is correct for any host that is not Windows: `WslLink`
   * never reads it there, because a Linux or macOS machine has no boundary to
   * cross. The Electron shell backs it with `settings.json`.
   */
  wslStore?: WslStore
  /** Raw session output, after the core has done its own bookkeeping. */
  onData?(id: string, data: string): void
  onExit?(id: string, exitCode: number): void
  onStatus?(id: string, status: SessionStatus): void
  /**
   * A session appeared that this shell did not ask for — today, one a paired
   * device started. The desktop turns it into a tab; the headless build has
   * nowhere to put it and passes nothing.
   */
  onSessionCreated?(meta: SessionMeta): void
  /**
   * **Every** session, the moment it exists — a window's, a phone's, a restored
   * one, a routine's.
   *
   * Not the same hook as `onSessionCreated` above, and the difference is the
   * whole reason this one exists. That one means "a session appeared that this
   * shell did not ask for", so it deliberately does not fire for the ordinary
   * case of somebody pressing New Session. Anything that needs to *know about
   * sessions* rather than to *draw a tab it is missing* needs the complete set.
   *
   * The routine engine is the first such caller: it keeps each session's folder
   * and its provenance so that, half an hour later when the process exits, it
   * can tell whether the routine about to be triggered is the one that started
   * it. A hook that missed the sessions started from the window would leave the
   * loop guard blind to exactly the sessions a person is most likely to build a
   * routine around.
   *
   * Called after the pty exists and after the ledger has been written, so a
   * listener that reads either sees the finished state.
   */
  onSessionStarted?(meta: SessionMeta): void
  platform?: Platform
}

export interface HostCore {
  ptys: PtyManager
  wsl: WslLink
  /** The `SessionAccess` the remote server serves, and the `PtySource` behind it. */
  sessions: SessionFanout
  grants: FolderGrants
  /**
   * The agents this machine has added.
   *
   * On the core rather than owned by a shell, because `startSession` reads it —
   * see the note where it is built. A shell that draws a UI registers the IPC
   * against this instance; a shell that does not still starts the same sessions.
   */
  agents: CustomAgentStore
  credentials: CredentialProxy
  ledger: OpenSessionLedger
  /**
   * Start a session. The one place that does, for a window and for a phone.
   *
   * `guest` is set for exactly one caller — a session a paired device asked for
   * — and it is what stops that session inheriting this machine's git login.
   *
   * `confine` is set by the same caller and for the same reason, one layer
   * further down: it is what stops the session leaving the folder it was granted
   * at all. Both are absent for a window, because a person sitting at their own
   * keyboard has no grant to be held inside — see `confine/index.ts`.
   *
   * `fence` is set by exactly one caller too — the copilot — and it is **not**
   * confinement, which is why it is a third argument rather than a field on the
   * second. A confined session is one that may only touch what it was granted. A
   * fenced session is an ordinary session that may touch everything *except* a
   * named few of this app's own files: the routines it could otherwise make fire
   * on their own, and the log of what it did. It arrives already measured — see
   * `confine/records.ts` — so all this function does with it is wrap the launch.
   *
   * `extraArgs` is the copilot's too, and it is what gives it any tools at all:
   * `--mcp-config <file> --strict-mcp-config`, the only way a Claude CLI process
   * can be told about the `deck-control` server. It is an argument here rather
   * than a field on {@link CreateSessionInput} because the input crosses the
   * preload bridge and a session's argv is not something page code should be
   * able to compose — the same reason the three above it are arguments.
   */
  startSession(
    input: CreateSessionInput,
    guest?: GuestGitEnv,
    confine?: DeviceConfinement,
    fence?: SpawnFence,
    extraArgs?: readonly string[],
  ): Promise<SessionMeta>
  /** A path a Windows API can stat, for a folder that may live inside a distro. */
  statablePath(cwd: string): string
  /**
   * Does this agent have a way to continue the last conversation in a folder?
   *
   * On the core because it is the one question about a provider that has to be
   * answered the same way for a shipped agent and an added one, and because
   * getting it wrong is not a wrong answer but a crash: both shells used to ask
   * `PROVIDERS[provider].resumeArgs`, which throws outright on an id the table
   * has never had — a restored session on an added agent taking the whole
   * restore down with it, and with it every other tab in the list.
   */
  canContinue(provider: ProviderId): boolean
}

/* --------------------------------------------------------------- assembly -- */

export function createHostCore(options: HostCoreOptions): HostCore {
  const platform = options.platform ?? currentPlatform()
  const ledger = new OpenSessionLedger()

  /**
   * WSL, as far as this app is concerned: what is installed, which distribution
   * is the machine's, and where its home directory is.
   *
   * The constructor does no I/O — it only stores its arguments — so building it
   * here is safe however early this runs. The reading happens when a shell calls
   * `refresh()` at boot, and the fact that it happens there rather than when a
   * settings pane asks is the whole point: a Windows machine whose projects live
   * in Linux has to be able to start a session at launch, from a restored tab or
   * from a phone, without anybody having opened a settings window first.
   */
  const wsl = new WslLink({
    // A store is optional because it is meaningless off Windows. `null` reads as
    // "nothing chosen", which is what an unconfigured machine also reads as, so
    // the two cannot be told apart and do not need to be.
    store: options.wslStore ?? { read: () => null, write: () => undefined },
  })

  /**
   * The one place that decides whether a folder is a Linux folder.
   *
   * Everything downstream — the provider table, the pty's working directory,
   * which side gets asked whether Claude Code is installed — hangs off this
   * answer, so it is asked once per session, in one function, rather than
   * re-derived at each of those three points.
   */
  const wslTargetFor = (cwd: string): WslTarget | null => wsl.targetFor(cwd)

  /**
   * A path a Windows API can stat, for a folder that may live inside a distro.
   *
   * `existsSync('/home/asad/proj')` on Windows is false however real the folder
   * is, so restore-on-launch would decide every WSL session's folder had been
   * deleted and quietly drop the lot — the app losing a day's tabs and saying
   * nothing. `\\wsl.localhost\Ubuntu\home\asad\proj` is the same directory as
   * Windows can see it, and reading a directory entry is the one crossing of the
   * boundary that costs nothing: it is a stat, not a build.
   */
  const statablePath = (cwd: string): string => {
    const distro = wsl.active()
    if (!isLinuxPath(cwd) || distro === null) return cwd
    return wslUncPath(distro, cwd)
  }

  /**
   * Which folders each paired device may start a session in.
   *
   * One instance, because two would be two in-memory copies of one file — the
   * settings panel writing to one while every `create` is checked against the
   * other. The same object is handed to `registerRemoteIpc` by whichever shell
   * is wiring it.
   */
  const grants = new FolderGrants(options.storageDir)

  /**
   * The agents this machine has added, beyond the four this build ships.
   *
   * Built here rather than beside the IPC that lists them, for the reason this
   * file exists: `startSession` is the one place a session starts, and it has to
   * be able to answer "what is `custom:my-agent`" whether the request came from
   * the window, from a paired phone, from the headless daemon or from a restored
   * tab. A store owned by the Electron shell would make an added agent a
   * desktop-only row that every other entry point silently downgraded to a plain
   * shell.
   */
  const agents = new CustomAgentStore(options.userData)

  /**
   * The GitHub credential proxy: their account, from their device, never held
   * here.
   *
   * Built **here, at assembly**, rather than by whatever asks for it first, and
   * that is deliberate: everything else about remote access is on unless the
   * user turned it off, and a proxy that only came into being when the first
   * phone pushed would be a feature whose first use is the one that fails.
   */
  const credentials = createCredentialProxy({ dir: join(options.storageDir, 'guest-git') })

  /*
   * Tell the transcript layer where confined sessions keep their homes.
   *
   * A confined session is given a home of its own — it cannot read the account's
   * — and the agent CLI follows `HOME`, so its conversation is written under
   * that home and not under `~/.claude` at all. Chat mode, the cost pane, alerts
   * and the agent controls all read transcripts, and all of them were reading
   * the owner's store and finding an empty conversation for a session that was
   * talking. Nothing is copied and nothing is symlinked; the readers are simply
   * told where to look. `transcript.ts` has the measurement behind it.
   *
   * Here, at assembly, and not in `index.ts`, for the reason this whole file
   * exists: the headless build calls the same function and its sessions are
   * confined the same way, so a shell that had to remember this line would be a
   * shell that could forget it.
   */
  installDeviceHomes(deviceHomesRoot(options.storageDir))

  /*
   * And tell it that one of those homes is not a paired device's.
   *
   * The copilot's home sits in that same root on purpose — that placement is
   * what makes its conversation visible to every transcript reader with no
   * change to any of them — but the copilot is an agent this app runs, not a
   * device a person paired. It can write inside its own home and nowhere else,
   * and without this line that one writable directory was a way to publish a
   * fabricated conversation under *any* project's name, to four readers that
   * had no way to tell. Scoping its store to its own working directory keeps
   * the real transcript and drops the forged one.
   *
   * Here rather than beside the copilot's own wiring, and for the same reason
   * the line above it is here: the headless build reads transcripts too, a
   * copilot home left on disk by the desktop is still in that root when it
   * does, and a shell that had to remember this line would be a shell that
   * could forget it.
   */
  installHomeScopes([copilotHomeScope(options.userData, options.storageDir)])

  /*
   * Tell the confinement layer where the Windows launcher and the one-time
   * grant are.
   *
   * Here, at assembly, and for the same two reasons the line above it is: the
   * headless build calls this function and its sessions are confined the same
   * way, and `confine/` has no way to learn either path for itself — one is
   * wherever Electron unpacked its resources, the other is inside this install's
   * storage directory.
   *
   * It runs on every platform on purpose. `confinementKind` is what decides
   * whether any of it matters, and a call site that only ran this on Windows
   * would be a second place that has to know which platforms have which
   * mechanism — which is exactly the split that left Linux confinement built,
   * tested and switched off.
   */
  installWindowsTools(windowsToolsFor(options.storageDir))

  /**
   * Start a session. The one place that does, for the window and for a phone.
   *
   * Everything here is load-bearing and none of it is obvious from the outside —
   * the login shell's PATH, the fallback when the requested CLI is not
   * installed, the profile's redirected config directory — so a second copy for
   * the remote path, or for the headless build, would be a session that is
   * subtly not the same kind of session: no agent CLI on PATH, or two "separate"
   * logins quietly sharing one config directory.
   */
  async function startSession(
    input: CreateSessionInput,
    guest?: GuestGitEnv,
    confine?: DeviceConfinement,
    fence?: SpawnFence,
    extraArgs?: readonly string[],
  ): Promise<SessionMeta> {
    const path = await loginPath()
    /*
     * Which side of the WSL boundary this session lives on, decided by its
     * folder and by nothing else.
     *
     * A Linux path cannot be opened by cmd.exe under any circumstance, so this
     * is not a preference being consulted — it is the only way that folder can
     * run. `targetFor` answers without waiting for the distro probe for exactly
     * that reason; see its comment.
     */
    const target = wslTargetFor(input.cwd)
    // Asked of the side the session will actually run on. Asking Windows whether
    // `claude` exists, on a machine where it is installed inside Ubuntu, is the
    // bug this whole path exists to fix: every agent reported missing, and every
    // tab silently downgraded to a shell.
    const available = await detectProviders(platform, target)
    // Fall back to a plain shell rather than spawning a binary that isn't there,
    // which would flash a dead tab with no explanation.
    const requested = input.provider ?? 'claude'
    /*
     * An agent the person added, if that is what was asked for.
     *
     * Looked up rather than detected, because `detectProviders` answers about
     * the agents in the catalogue and nothing else — that is what keeps a
     * *shipped* agent from being silently skipped, and it means
     * `available['custom:my-agent']` is `undefined`. Without this branch every
     * custom session would take the fallback on the next line, and a person who
     * added an agent and pressed Start would get a plain shell with nothing
     * said: the silent downgrade this function warns about twice, arriving
     * through the one kind of provider it had never been asked about.
     */
    const added = isCustomProviderId(requested) ? (agents.get(requested) ?? null) : null
    /*
     * Whether that agent can still be started, asked only where it can be asked
     * honestly.
     *
     * On this machine the command is re-resolved, for the same reason the
     * shipped agents are probed: it resolved on the day it was added and an
     * agent can be uninstalled afterwards. One `which` against a call that is
     * about to open a pty is not a cost worth avoiding.
     *
     * Inside a distribution it is not asked at all, and the session goes ahead.
     * The question there is about Ubuntu's PATH, and this side cannot answer it
     * — `detectInsideDistro` exists precisely because a Windows lookup answers
     * about the wrong machine. Given a choice between refusing on an answer
     * about the wrong PATH and launching on none, launching is the one that
     * fails legibly: the distro's own login shell prints `command not found` in
     * the tab. `session-create.ts` makes the same argument in the same words —
     * a name this desktop cannot start is something a person can act on the
     * moment they are told, and cannot act on at all when the machine quietly
     * picks something else.
     */
    const addedRuns =
      added !== null && (target !== null || (await lookupCommand(added.command, platform)) !== null)
    const provider = addedRuns ? requested : available[requested] ? requested : 'shell'
    /*
     * The table for this machine, with each agent pointed at a copy that runs.
     *
     * `resolvedProvidersFor` rather than `PROVIDERS`, and the difference is one
     * field on one machine in one situation — which happens to be the situation
     * in the 2026-08-16 recording. The npm `@openai/codex` launcher on PATH
     * fails to spawn its own missing native binary, and a complete copy of the
     * same CLI sits in Codex's plugin directory; without this the session opens
     * on the broken one and the user reads a Node stack trace. It costs nothing
     * when nothing is wrong: the probe behind it was already run by
     * `detectProviders` on the line above and is memoised, and the command it
     * returns is the bare name unless that name will not execute.
     *
     * A WSL session still needs the table for this machine *and this folder*,
     * because `wsl.exe --cd` is part of the launch — and it is left unresolved,
     * since the payload of that command line is resolved by the distribution's
     * own login shell and a host path would name a file that side cannot see.
     */
    const table =
      added !== null && addedRuns
        ? customProviderSpec(added, platform, process.env, target)
        : target === null
          ? (await resolvedProvidersFor(platform, process.env))[provider]
          : providersFor(platform, process.env, target)[provider]

    /*
     * Flags this particular launch needs, folded in where the launch shape is
     * still known.
     *
     * One caller, the copilot, and one purpose: `--mcp-config <file>
     * --strict-mcp-config`, which is the only way a Claude CLI process can be
     * given the `deck-control` tools. `withLaunchArgs` is what knows that a
     * WSL launch has to be rebuilt rather than appended to; see its comment.
     *
     * Deliberately a parameter of *this* function and not a field on
     * `CreateSessionInput`. The input crosses the preload bridge — a renderer
     * calls `session:create` with it — and a session's argv is not a thing page
     * code should be able to compose. Everything else on the spawn path that
     * only a main-process caller may set (`guest`, `confine`, `fence`) is a
     * positional argument for exactly this reason, and this joins them.
     */
    const spec = withLaunchArgs(table, extraArgs ?? [], platform, process.env, target)

    // Resolve the profile the session should run as and hand the PTY its
    // config-dir override. Without this the picker records a choice that never
    // reaches the process, and two "separate" logins quietly share one.
    const profile = resolveProfile(profilesState(), {
      sessionProfileId: input.profileId ?? undefined,
      projectPath: input.cwd,
    })

    /*
     * The profile's config-dir override, plus — inside WSL — the one variable
     * that lets any of it cross the boundary.
     *
     * WSL does not inherit the Windows environment: a variable arrives only if
     * `WSLENV` names it. Without this the session marker never reaches the agent
     * (so the app cannot tell its own sessions apart from a nested one) and a
     * profile's config directory never reaches it either, which is the "two
     * separate logins quietly sharing one directory" failure this function warns
     * about two comments up — reappearing on Windows only, and only inside
     * Linux.
     */
    /*
     * Whether this session is held inside the folder it was granted.
     *
     * Three conditions, and each rules out a case where confining would be a
     * claim rather than a fact. There has to be a device — a window is a person
     * at their own keyboard with no grant to be held inside. The platform has to
     * have a mechanism this repository has actually measured; `confine/index.ts`
     * names the ones it has not. And the session must not be running inside WSL,
     * where the process is a Linux one launched through `wsl.exe` and a
     * Windows-side sandbox could not reach it even if one existed here.
     *
     * `!== 'none'` rather than naming a mechanism, and the change is deliberate.
     * It used to read `=== 'seatbelt'`, which was correct while macOS was the
     * only platform with a measured boundary — and became the reason Linux
     * confinement sat built, tested and switched off: the mechanism existed,
     * `confinementKind` returned it, and this line quietly declined to use it.
     * A gate that names one implementation has to be edited every time another
     * is proved, and it is edited in a file nobody thinks to look in.
     *
     * `confinementKind` is the single place that decides whether a platform has
     * a boundary this repository has actually measured; anything it does not
     * name answers `'none'` and is refused here. So this asks the question that
     * matters — is there a real boundary — instead of asking which one.
     */
    const confined =
      confine !== undefined && confinementKind(platform) !== 'none' && target === null

    /*
     * `HOME` and `TMPDIR` are part of the environment rather than an afterthought
     * because a confined session needs them *before* anything runs. The account's
     * home is outside the boundary, so a session left pointing at it cannot read
     * its own shell startup files, cannot write an npm cache, and cannot store
     * the agent login the person has just completed — each of which reads as a
     * broken session rather than as a boundary. `confine/plan.ts` says why the
     * `PATH` is deliberately not touched in the same breath.
     */
    /*
     * `confinedEnv` on macOS and Linux, `windowsConfinedEnv` on Windows, and the
     * difference is not the path separator.
     *
     * `confinedEnv` sets `HOME` and `TMPDIR`, which is the POSIX spelling of
     * this idea and is read by almost nothing on Windows: `node`'s
     * `os.homedir()` reads `USERPROFILE`, git-for-windows tries `HOME` then
     * `HOMEDRIVE`+`HOMEPATH` then `USERPROFILE`, and `TEMP`/`TMP` are what
     * everything uses for scratch space. Measured inside a real confined session
     * on the Windows machine: with only `HOME` set, git printed `warning: unable
     * to access 'C:/Users/<user>/.gitconfig': Permission denied` three times and
     * then `fatal: unknown error occurred while reading the configuration
     * files`. The boundary was working perfectly and the session was unusable.
     * With `windowsConfinedEnv`, the same session ran `git status`, `git log`
     * and `git commit`.
     *
     * The choice itself moved into `confine/index.ts` as `confinedHomeEnv`
     * because it was made correctly here and then not made at all in
     * `copilot-session.ts`, whose sign-in probe called `confinedEnv` directly
     * and would have run with the owner's `USERPROFILE`. A branch written in
     * one file and needed in two is a branch that will be half-updated by
     * whoever adds the third caller.
     */
    const profileEnv = {
      ...sessionEnv(profile, provider),
      ...(guest?.set ?? {}),
      ...(confined && confine ? confinedHomeEnv(confine.home, platform) : {}),
    }
    /*
     * The guest's git variables have to cross the WSL boundary too, and they are
     * split the same way everything else here is: a path is translated, a plain
     * value is copied. `git-guest.ts` says which of its own variables are paths
     * rather than this end guessing from the value.
     *
     * The one part of it that does not survive the crossing is the helper's path
     * *inside* the `credential.helper` value, which is a shell command and not a
     * variable, so `WSLENV` has nothing to translate. That fails in the safe
     * direction — the entry that clears every other helper still applies, so a
     * guest session inside WSL has no credential helper at all and a push is
     * refused rather than answered with the owner's login. It is a real gap, and
     * it is a gap in the *proxy*, not in the isolation.
     */
    const guestPaths = guest?.paths ?? []
    const env =
      target === null
        ? profileEnv
        : {
            ...profileEnv,
            WSLENV: wslEnvBridge(process.env, {
              plain: [
                BRAND.sessionEnvVar,
                'TERM',
                'COLORTERM',
                ...Object.keys(guest?.set ?? {}).filter((name) => !guestPaths.includes(name)),
              ],
              paths: [...Object.keys(sessionEnv(profile, provider)), ...guestPaths],
            }),
          }

    // `spec.spawn`, not `spec.bin`. They are the same thing on macOS and are not
    // on Windows, where the name that answers a PATH lookup for an npm-installed
    // agent CLI is a `.cmd` shim and `CreateProcess` will not run a batch file.
    // Spawning `bin` there failed with a bare "File not found:" and a tab that
    // died with no message — observed on Windows 11. `providers.ts` has carried
    // the launchable form in `spawn` the whole time, unread. Inside WSL they
    // diverge further still: `spawn` is a whole `wsl.exe` invocation and `bin`
    // is the CLI's own name, which is what the far side looks up.
    const wanted =
      input.resume && spec.spawn.resumeArgs.length > 0 ? spec.spawn.resumeArgs : spec.spawn.args

    /*
     * The last thing between deciding what to run and running it.
     *
     * `confineSpawn` **throws** rather than handing back the unwrapped command
     * when the boundary cannot be proven on this machine, at this moment, for
     * this exact folder. That throw is the feature, not a rough edge: the grant
     * screen tells a person that a session from a device is held inside the
     * folder, and the only thing that keeps that sentence true is a session
     * which cannot be held not starting. A silent fall-through to an unconfined
     * shell would be the same failure this project has already shipped once in
     * another subsystem — the side reporting success was not the side doing the
     * work. `remote/session-create.ts` turns the throw into a sentence a phone
     * can act on.
     *
     * The proof is a real `sandbox-exec` run against a file written outside the
     * plan, not an inspection of the generated profile. See `confine/index.ts`.
     */
    /*
     * The plan is held rather than built inline, and the reason is downstream of
     * this file.
     *
     * It used to be an argument expression inside the `confineSpawn` call, which
     * meant the only thing that ever knew what this session was allowed to read
     * was the sandbox. That was enough while nothing else needed the answer. It
     * stopped being enough when a message could carry a path from outside the
     * project: a confined session is an ordinary tab in the window, and a
     * composer offering it a file the OS will refuse produces a chip, a mention
     * and an agent that says it cannot read the file — three steps that look
     * like they worked, and one that did not. `session-boundary.ts` carries the
     * whole argument; this line is where the answer is captured.
     */
    const plan =
      confined && confine
        ? planFor({
            folder: input.cwd,
            device: confine,
            accountHome: homeDir(),
            path,
            // Absent for the system profile on purpose. `sessionEnv` returns
            // nothing for it — `profiles.ts` explains why — so the CLI finds
            // its own default, which with `HOME` redirected is inside the
            // device's own home, which is exactly where a confined session's
            // login belongs. A *named* profile is a deliberate choice of which
            // login this session runs as, kept in a directory the app owns, and
            // the boundary honours that choice instead of overriding it.
            ...(profile.system ? {} : { agentConfigDir: profile.configDir }),
            platform,
          })
        : null

    /*
     * Confinement first, then the fence, and they are mutually exclusive by
     * construction rather than by a check.
     *
     * A confined session already cannot reach `<userData>` at all — the fenced
     * paths are inside it — so applying both would be one sandbox nested inside
     * another, which macOS refuses outright (`sandbox_apply: Operation not
     * permitted`, measured in `seatbelt.ts`) and would turn a working session
     * into one that will not start. The only caller that passes `fence` passes
     * no `confine`, and the branch below is what makes that impossible to get
     * wrong by accident rather than merely unlikely.
     */
    const launch =
      plan !== null
        ? await confineSpawn(plan, spec.spawn.command, wanted, platform)
        : fence !== undefined && target === null
          ? fence.apply(spec.spawn.command, wanted)
          : { command: spec.spawn.command, args: [...wanted] }

    const meta = ptys.create(input, {
      provider,
      command: launch.command,
      args: launch.args,
      path,
      env,
      ...(guest ? { removeEnv: guest.remove } : {}),
      /*
       * The account this session runs as, recorded on the session itself.
       *
       * `provider`, not `requested`: an agent that is not installed falls back
       * to a plain shell above, and a shell has no login to be isolated. It is
       * gated on `supportsProfiles` for the same reason — for an agent whose
       * config directory this app cannot redirect, `sessionEnv` returns nothing
       * and the session runs under whatever login the machine already has.
       * Labelling that session with an account name would be a claim about
       * isolation that this app did not make happen.
       */
      ...(supportsProfiles(provider)
        ? { profile: { id: profile.id, name: profile.name } }
        : {}),
      // Set only for a WSL launch, where the session's own folder is a Linux
      // path that node-pty would resolve into a Windows directory that does not
      // exist.
      hostCwd: spec.spawn.hostCwd,
    })

    /*
     * Write down what this session is held inside, now that it has an id.
     *
     * Only for a confined one — an unnoted session is one that can read whatever
     * the account can, which is the truth for every session started at this
     * keyboard, and inventing an entry saying "unconfined" would mean two ways
     * of spelling the same fact. Dropped again on exit, where the ledger drops
     * its own record.
     */
    if (plan !== null) noteBoundary(meta.id, plan, platform)

    /*
     * Remember the session, so a relaunch can put it back.
     *
     * `requested`, not `provider`: the two differ when the chosen CLI is not
     * installed and the fallback above turns the session into a plain shell.
     * Writing the fallback down would make the downgrade permanent — install
     * Claude Code tomorrow and every restored session would still be a shell,
     * with nothing on screen explaining why.
     *
     * `input.profileId`, not the resolved `profile`: a null here means "whatever
     * this project's default profile is", and that is a question worth asking
     * again next launch rather than freezing today's answer.
     *
     * ## Confined sessions are deliberately not remembered
     *
     * A `SavedSession` carries a folder and a provider and no device, so a
     * restore has nothing to rebuild a boundary from — it would start the
     * session again as an ordinary tab. That is not a smaller version of the
     * feature, it is the boundary silently lapsing at the next launch, and a
     * device can attach to a running session without naming a folder, so the
     * lapsed session is reachable by the same device that started the confined
     * one. A security property that survives until the app restarts is the kind
     * of thing that is worse than not having it, because nobody is watching for
     * the moment it stops being true.
     *
     * So it is not written down, and the cost is stated rather than hidden: a
     * session a device started does not come back after the app is restarted,
     * and the device starts a new one. The honest fix is for the ledger to carry
     * the device and for the restore path to rebuild the confinement — worth
     * doing, and a change to the stored shape rather than to this line.
     */
    if (!confined) {
      ledger.note(meta.id, {
        cwd: input.cwd,
        provider: requested,
        profileId: input.profileId ?? null,
        cols: input.cols,
        rows: input.rows,
        lastSeenAt: Date.now(),
      })
    }

    // Last, so that anything listening sees a session that is fully built: the
    // pty is running and the ledger already knows about it. A listener that
    // throws must not turn a started session into a failed `session:create`,
    // which the caller would report as "the session did not start" about a
    // session that is running.
    try {
      options.onSessionStarted?.(meta)
    } catch (error) {
      console.error('[host-core] a session listener threw:', error)
    }

    return meta
  }

  /**
   * Fans each session's output out to every watcher: a window, if there is one,
   * and any attached device.
   *
   * Declared before `ptys` in the original arrangement because the PtyManager
   * callbacks feed it; here the order is the same and the mutual reference is
   * closed by `ptys` being a `const` in the enclosing scope that the arrow
   * functions below only read when called.
   */
  const sessions = new SessionFanout({
    list: () => ptys.list(),
    write: (id, data) => ptys.write(id, data),
    resize: (id, cols, rows) => ptys.resize(id, cols, rows),
    scrollback: (id) => ptys.scrollback(id),
    /*
     * The copilot's own terminal is not the network's business.
     *
     * `SessionFanout` grew the predicate for this and then nothing answered it,
     * which is the same failure as not having built it: a phone could `list`,
     * see the row whose folder is `<userData>/copilot`, `attach`, and type into
     * the Claude CLI that holds `deck-control` — past the per-device copilot
     * grant, past every tier, past every budget and past the confirmation
     * dialog, because none of those sit between a pty and its keyboard.
     *
     * Here, at assembly, and for the same reason `installHomeScopes` above is
     * here rather than beside the copilot's own wiring: the headless build
     * serves the same remote protocol from the same fanout, and a rule a shell
     * had to remember to install is a rule the other shell forgets. It costs
     * nothing on a host with no copilot — `isCopilotSession` reads one module
     * variable that is null there and always will be.
     *
     * The predicate rather than a snapshot of ids because the answer changes
     * while the app runs: the copilot restarts with a new id whenever it is
     * stopped and started, and under `COPILOT-REMOTE.md` §1 every per-device
     * copilot run joins the same answer.
     *
     * And it now does. `isCopilotSession` answers for the copilot at the desk,
     * which is a singleton and lives in `copilot-session.ts`; `isHiddenSession`
     * answers for every per-device run, which are not, and which belong to the
     * relay rather than to that module. Two sources rather than one because the
     * two features deploy separately — the headless host has runs and no pinned
     * copilot — and an `||` here is what keeps a shell from having to remember
     * to install either.
     */
    hidden: (id) => isCopilotSession(id) || isHiddenSession(id),
    // Both halves out of one starter, so the list a phone's picker is drawn from
    // is the list `create` checks against rather than a second computation of
    // the same idea. See `remoteSessionStart`.
    ...remoteSessionStart(
      {
        // What a person chose for this device — and, only when nobody has chosen
        // anything for it, what this host is offering everyone: its projects
        // most-recently-opened first, then the folders sessions are running in.
        // That fallback is what every device got before grants existed, and it
        // is kept so that a phone paired before the feature is not locked out by
        // it.
        //
        // Live sessions come after the projects: a session can be running in a
        // folder that was never added as a project, and the phone can see it in
        // its own list, so refusing to start a second one beside it would be
        // arbitrary.
        folders: (deviceId) =>
          foldersForDevice(
            grants,
            deviceId,
            () => [
              ...store().getProjects().map((project) => project.path),
              ...ptys.list().map((session) => session.cwd),
            ],
            /*
             * The home directory a phone lands in when nothing has been chosen
             * for it — on the same side of the boundary as everything else.
             *
             * The platform home is `C:\Users\Asad` on Windows, and starting a
             * phone's session there on a machine whose work is all in Linux
             * hands it the one folder with nothing in it. The distro's own
             * `$HOME` is the right answer and is used when it is known; it is
             * not always known, because asking for it means starting a stopped
             * distribution and this app does not boot a virtual machine to fill
             * in a default. The platform home is the fallback — a real folder,
             * on the wrong side, which is better than a path that resolves to
             * nothing.
             */
            () => wsl.home() ?? homeDir(),
          ),
        spawn: async (input) => {
          /*
           * A session started from somebody else's device does not get this
           * machine's git login.
           *
           * Without this the session is an ordinary child process of this app,
           * which means it inherits the owner's credential helper, their `gh`
           * token and their ssh agent — so anyone granted a folder can push as
           * them. That is not a subtle failure and it is not theoretical: `git
           * credential fill` in a granted folder answered with the owner's real
           * GitHub token on the machine this was written on.
           *
           * The guest gets its own git configuration instead, per device, and a
           * credential helper that asks *their* device for *their* login. See
           * `git-guest.ts` for the four doors that closes and the one it cannot.
           */
          const guest = await credentials.openGuestSession(input.deviceId)
          /*
           * And the folder it was granted is where it stays.
           *
           * Everything above this line was about *whose login* the session runs
           * with. This is about *where it can reach*, which until now was
           * nowhere at all: the grant chose a starting directory and the shell
           * could type `cd ..`. Every sentence in the product said exactly that,
           * on purpose, and this is the change that lets one of them stop.
           *
           * The three directories handed over are the ones this module knows
           * about and `confine/` deliberately does not. The device's guest git
           * directory has to be writable or `git config --global` inside the
           * session writes to a file it cannot open. The helper is granted as a
           * *file*: it sits one level above the per-device directories, so
           * granting its folder would hand this device every other device's git
           * identity.
           */
          const key = deviceKey(input.deviceId)
          const guestRoot = join(options.storageDir, 'guest-git')
          const confine: DeviceConfinement = {
            home: prepareDeviceHome(deviceHomesRoot(options.storageDir), key),
            writable: [guestGitDir(guestRoot, key)],
            files: [join(guestRoot, HELPER_FILE)],
          }
          let meta: SessionMeta
          try {
            meta = await startSession(
              {
                ...input,
                /*
                 * The agent the device asked for, or this desktop's own default.
                 *
                 * The comment that used to be here said the phone does not
                 * choose an agent, and it was written when that was true. It
                 * stopped being true the day the desktop-to-desktop client grew
                 * a chooser, and nothing here noticed, because the field was
                 * being dropped four layers up in `parseClientMessage` — a
                 * request for `shell` arrived as a request for nothing and this
                 * line filled the hole with `claude`. Measured on a real Windows
                 * PC; see `remote/session-create.ts`.
                 *
                 * `input.provider` has already been checked against the provider
                 * table by the time it reaches here — a name this desktop does
                 * not have was refused with a sentence rather than travelling
                 * this far. Absent still means the desktop's default, which is
                 * what a client that names nothing gets and what the window's own
                 * button does; and `startSession` still falls back to a plain
                 * shell when the chosen CLI is not installed, reporting the
                 * fallback in the `SessionMeta` it returns rather than pretending.
                 */
                provider: input.provider ?? store().getPreferences().defaultProvider,
              },
              guest.env,
              confine,
            )
          } catch (error) {
            // The key was minted before the spawn, because it has to be in the
            // environment the spawn is handed. A spawn that then failed would
            // leave a live key belonging to no session, which is one more thing
            // that can ask a stranger's phone for a password.
            guest.close()
            throw error
          }
          guest.started(meta.id)
          // Whoever owns a screen has to be told, or the session is running on
          // this machine and only the phone knows about it.
          options.onSessionCreated?.(meta)
          return meta
        },
      },
      platform,
    ),
  })

  const ptys = new PtyManager(
    (id, data) => {
      sessions.noteData(id, data)
      options.onData?.(id, data)
    },
    (id, exitCode) => {
      ledger.forget(id)
      // The boundary outlives nothing. A dead session cannot be attached to, and
      // an entry left behind would answer a question about an id that will never
      // be asked again — see `session-boundary.ts`.
      forgetBoundary(id)
      sessions.noteExit(id, exitCode)
      // The key that let this session ask a phone for a GitHub login stops
      // working the moment the session does. A key that outlived its session
      // would be a credential request with nothing behind it — and every other
      // process on this machine runs as the same account, so "nothing behind it"
      // is not a theoretical caller.
      credentials.sessionEnded(id)
      options.onExit?.(id, exitCode)
    },
    (id, status) => {
      sessions.noteStatus(id, status)
      options.onStatus?.(id, status)
    },
  )

  /**
   * Whether a provider can continue a conversation. See {@link HostCore.canContinue}.
   *
   * `?.` on the table and not on the store, because the two absences are
   * different: an added agent that has been removed is `undefined` here and
   * false is the right answer, and a *builtin* id the table does not have is a
   * saved session naming an agent this build no longer ships — also false, and
   * previously a `TypeError` in the middle of restoring somebody's tabs.
   */
  const canContinue = (provider: ProviderId): boolean => {
    const added = isCustomProviderId(provider) ? agents.get(provider) : undefined
    if (added !== undefined) return added.resumeArgs.length > 0
    return (PROVIDERS[provider]?.resumeArgs.length ?? 0) > 0
  }

  return {
    ptys,
    wsl,
    sessions,
    grants,
    agents,
    credentials,
    ledger,
    startSession,
    statablePath,
    canContinue,
  }
}
