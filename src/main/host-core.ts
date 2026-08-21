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

import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput, ProviderId, SessionMeta, SessionStatus } from '../shared/types'
import { argsForSpawn } from './one-conversation'
import { PtyManager, type RemovalReason } from './pty-manager'
// The controls a session's bar is drawn from, imported here so that a *remote*
// window reaches the same two functions this machine's own window does. See the
// `controls` seam on the `SessionFanout` below.
import { applyControl, readControls } from './agent-controls'
// And the three usage readings that bar is drawn from, for the same reason and
// through the same seam. See the `usage` entry on the `SessionFanout` below.
import { createUsageServe } from './remote/usage-serve'
import { accountFor } from './usage-ipc'
// And the conversation that bar sits above, through the same kind of seam. See
// the `chat` entry on the `SessionFanout` below.
import { createChatServe } from './remote/chat-serve'
// And the account chip beside them, through the same kind of seam. See the
// `account` entry on the `SessionFanout` below.
import { createAccountServe, createLoginsServe } from './remote/account-serve'
// The connectors chip's list, which is three files on *this* machine resolved
// for the session's own folder — the same read `mcp:list` performs for a window
// at this desk. It rides the `controls` reading; see that seam below.
import { loadServers } from './mcp-client'
import { storedAccountLimits } from './account-limits'
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
import { AGENT_CATALOG } from '../shared/agent-catalog'
import { isCustomProviderId, type CustomAgent } from '../shared/custom-agents'
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
import { forgetNoVerbs, noteNoVerbs, type NoVerbsReason } from './session-verbs'
import { forgetWindowOwner, noteWindowOwner } from './window-owner'
import { currentOpenShim, prependShim } from './open-shim'
import { currentAppContext } from './app-context'
import { installDeviceHomes, installHomeScopes } from './transcript'
import { copilotHomeScope, isCopilotSession, type SpawnFence } from './copilot-session'
import { createCredentialProxy, deviceKey, type CredentialProxy } from './remote/credentials'
import { FolderGrants } from './remote/folder-grants'
import { SessionGrants } from './remote/session-grants'
import { AccountGrants } from './remote/account-grants'
import { WindowGrants } from './remote/window-grants'
import { DeviceKinds } from './remote/device-kind'
import { reachFor, type DeviceReach } from './remote/device-reach'
import { guestGitDir, HELPER_FILE, type GuestGitEnv } from './remote/git-guest'
import { isHiddenSession } from './remote/hidden-sessions'
import { SessionFanout } from './remote/session-fanout'
import { remoteSessionStart } from './remote/session-create'
import { HeldSessions } from './session-held'
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

/* ------------------------------------------------ refusing, rather than -- */

/**
 * The agent that was asked for cannot be started on this machine.
 *
 * A class rather than a bare `Error` because three callers have to be able to
 * tell this apart from a spawn that blew up: the window (which draws the
 * sentence in the New Session dialog), a paired device (`remote/session-create.ts`
 * turns it into a refusal the phone can show) and the restore path (which has to
 * decide whether a session is worth keeping and offering again — it is; an agent
 * that is missing this minute is frequently installed the next).
 *
 * The message is written for a person and is the only thing most of them will
 * ever see, so it says the name they chose in the picker and where this app
 * looked. "inside the WSL distribution" and "on this machine" are genuinely
 * different problems with genuinely different fixes, and a machine whose work
 * lives in Ubuntu is exactly the machine that reads a message about `PATH` and
 * checks the wrong `PATH`.
 */
export class AgentUnavailableError extends Error {
  readonly provider: ProviderId

  constructor(provider: ProviderId, label: string, insideWsl: boolean) {
    super(
      `${label} could not be found ${insideWsl ? 'inside the WSL distribution' : 'on this machine'}, ` +
        `so this session was not started.`,
    )
    this.name = 'AgentUnavailableError'
    this.provider = provider
  }
}

/**
 * What to call an agent when telling somebody it is missing.
 *
 * The catalogue for the four this build ships, the person's own label for one
 * they added, and the raw id as the last resort — which is reached only by an id
 * that is in neither, i.e. an agent removed in another window or a session
 * restored from a machine that had it. Naming the id there is more useful than
 * a generic "the agent": it is the string they can search their settings for.
 */
function agentLabel(provider: ProviderId, added: CustomAgent | null): string {
  if (added !== null) return added.label
  return AGENT_CATALOG[provider]?.label ?? provider
}

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

  /**
   * The sessions that were open, could not be started again, and are being kept
   * anyway.
   *
   * On the ledger rather than beside it because they are written to the same
   * file, in the same list, by the same `flush`. Two writers of `openSessions`
   * is how one of them ends up overwriting the other's half — which is precisely
   * the bug this field exists to fix, in its original form: the live map was the
   * only writer, so anything that was not a running session was erased by the
   * first tab that opened. See `session-held.ts` for the whole account.
   */
  readonly held = new HeldSessions(() => this.flush())

  note(id: string, saved: SavedSession): void {
    this.records.set(id, saved)
    this.flush()
  }

  forget(id: string): void {
    this.records.delete(id)
    this.flush()
  }

  /**
   * What one live session would need to be started again, or null.
   *
   * Null is a real answer and a load-bearing one rather than a miss: this map
   * deliberately holds only the sessions that are somebody's *tab*, so a null
   * here means "the copilot's own session, or one held inside a device's folder
   * grant" — the two kinds that were left out because a `SavedSession` cannot
   * carry what makes them what they are. `session-switch.ts` reads it as exactly
   * that and refuses, rather than restarting one of them as an ordinary session
   * in the same tab, which is precisely the substitution the comment beside
   * `ledger.note` spends a page refusing to make.
   */
  get(id: string): SavedSession | null {
    return this.records.get(id) ?? null
  }

  /**
   * Every live session and its record, in tab order.
   *
   * Paired with the id, because the one caller outside this class needs to ask
   * "which *other* sessions are running" — `--continue` attaches to one
   * conversation per store, and a tab about to be started must not be pointed at
   * a conversation another tab is already showing. Without the id there is no
   * way to leave yourself out of that comparison.
   */
  entries(): { id: string; saved: SavedSession }[] {
    return [...this.records].map(([id, saved]) => ({ id, saved }))
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
    /*
     * Held first, then live.
     *
     * `openSessions` is read back in order and restored in order, and a held
     * entry is a tab from *before* this launch while every live record is one
     * from during it — so this is the order they were in, and putting the
     * survivors of a failed restore after the sessions that replaced them would
     * reshuffle somebody's tabs a little more every time the app could not start
     * one.
     */
    store().setOpenSessions([...this.held.saved(), ...this.records.values()])
  }

  /** Stop writing. Called once, immediately after the last honest flush. */
  freeze(): void {
    this.frozen = true
  }
}

/* ---------------------------------------------------------------- options -- */

/**
 * Where a launch's config file has to be *named* for the process that will read
 * it — the WSL case, and structurally the only one.
 *
 * Declared here rather than imported from `deck-control/` so that this file's
 * seam stays a shape and not a dependency; `deck-control/session-tools.ts`
 * declares the same shape as `LaunchPlacement` and `wsl-reach.ts` builds the one
 * implementation.
 */
export interface WslPlacementSeam {
  argPath(file: string): string | null
}

export interface HostCoreOptions {
  /**
   * How a session is given this app's browser verbs, or absent in a build that
   * has no tool endpoint to give them from.
   *
   * A structural seam rather than an import: `deck-control` knows about loopback
   * sockets, bearer tokens and MCP, and this file knows how a pty is spawned.
   * Neither has any business importing the other, and the headless host — which
   * runs this same `startSession` with no window and no endpoint — passes
   * nothing and launches every session exactly as it did before.
   *
   * `prepare()` is called *before* the process exists and hands back the
   * arguments plus a way to bind the token to the session id once there is one.
   * A launch that never gets that far is disarmed by the seam's own deadline
   * rather than by an unwind here. See `deck-control/session-tools.ts`.
   */
  sessionTools?: {
    /**
     * Null when there is nothing to hand out — the tool endpoint has not come
     * up, or failed to. A session is then launched exactly as it was before,
     * with no argument added and nothing said about tools it does not have.
     */
    prepare(inside?: WslPlacementSeam): {
      args: readonly string[]
      /**
       * The config file the arguments name.
       *
       * Handed back so a **confined** launch can be given read access to it. It
       * lives under `<userData>`, which `confine/plan.ts` keeps out of every
       * read root on purpose, so without this line a device's session would be
       * launched with `--mcp-config <a path the sandbox refuses>` — flags that
       * are present, a file that is not readable, and an agent told it has six
       * verbs that answer nothing. The same door `git-guest.ts`'s credential
       * helper and the app's context documents already go through.
       */
      file: string
      started(sessionId: string, machineId?: string): void
    } | null
    /**
     * Can a session **this device** started act on the browser windows that
     * device holds?
     *
     * A seam rather than a constant because the answer is a fact about the
     * assembly: the desktop builds a `WindowAskDesk` and wires the forwarder
     * that `deck-control`'s browser tools use, and the headless host does
     * neither. Read at the gate below, where the reason a launch is given the
     * verbs and the reason it is not are decided in one place.
     *
     * ## Why it is asked about *this* device rather than about the build
     *
     * Because most devices cannot serve a browser verb and never will. A phone
     * is a client of this protocol like any other — it starts sessions here, it
     * is granted folders — and it holds no browser windows and its build has
     * never heard of `window.call`. Answering yes for the whole assembly handed
     * every phone session six verbs that each came back *"the computer holding
     * that browser window is not connected right now"*, about a phone that was
     * connected and was holding nothing. A session with no verbs and one true
     * sentence about why (`session-verbs.ts`) is the better of the two, and it
     * is what such a session had before.
     *
     * The device id is `undefined` for a launch that is confined for some other
     * reason — the copilot's — and that answers no, which is the conservative
     * direction and cannot be wrong: a launch with no device behind it has no
     * device's windows to reach.
     */
    reachesDeviceWindows?(deviceId: string | undefined): boolean
    /**
     * Can a Claude CLI **inside this distribution** reach the tool endpoint, and
     * what is the config file called over there?
     *
     * A seam for the same reason `reachesDeviceWindows` is one: the answer is a
     * fact about the assembly and about one machine's WSL, and this file has no
     * business knowing what an MCP endpoint is. `null` means the session is
     * launched exactly as it was before, with an honest sentence rather than
     * flags naming a file the CLI cannot open. The headless host passes no seam
     * at all and answers no by not being asked.
     *
     * Asked once per distribution and endpoint, not once per session:
     * `wsl-reach.ts` remembers a crossing that costs a `wsl.exe` run.
     */
    insideDistro?(target: WslTarget): Promise<WslPlacementSeam | null>
  }
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
   * A session is gone from this core altogether — not merely finished.
   *
   * Every shell that draws a list of sessions needs this and only the desktop
   * has one today. See `RemovalReason`: a process that ended on its own is
   * `onExit` and keeps its place, and this is the entry being dropped, after
   * which nothing here can answer for that id at all.
   */
  onSessionRemoved?(id: string, reason: RemovalReason): void
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
  /**
   * Run one of this machine's sessions as a different login, for a window on
   * another machine.
   *
   * **Optional, and its absence is the switch.** A shell that does not supply it
   * makes this core advertise no `account` capability at all, and the chip on
   * the far window is drawn with what it can read and no rows to press — which
   * is honest for the headless build, whose whole job is terminals and which has
   * no session-lifecycle operation to replace one through.
   *
   * Handed in rather than composed here because the operation belongs to the
   * shell that owns it: it starts a replacement, waits to see whether the agent
   * survived its first seconds, and only then ends the session it replaced. A
   * second arrangement of `startSession` and a kill, written in this file, is how
   * one of the two comes to drop the conversation guard — which is exactly the
   * defect *"it's not keeping the conversation history"* was.
   */
  switchAccount?(
    sessionId: string,
    accountId: string,
  ): Promise<{ ok: boolean; message: string; session: string | null }>
  /**
   * Start signing one of this machine's logins in, for a pane on another
   * machine.
   *
   * **Optional, and its absence is the switch**, exactly as {@link switchAccount}'s
   * is: a shell that does not supply it makes this core advertise no `logins`
   * capability, and the pane over there says the far build cannot manage its
   * logins rather than drawing a Sign in that would apologise.
   *
   * Handed in rather than composed here for the reason {@link switchAccount} is,
   * and there is a second one. The agent CLIs authenticate **interactively** —
   * they print a URL and wait — so signing in is not a command this core can run
   * and report on; it is a terminal somebody has to see. The shell that owns
   * sessions is the thing that can open one, and it is the same call its own
   * Accounts pane makes when it adds an account.
   */
  signInAccount?(accountId: string): Promise<{ ok: boolean; message: string; session: string | null }>
  platform?: Platform
}

export interface HostCore {
  ptys: PtyManager
  wsl: WslLink
  /** The `SessionAccess` the remote server serves, and the `PtySource` behind it. */
  sessions: SessionFanout
  grants: FolderGrants
  /**
   * Which of the running sessions each paired device may see.
   *
   * On the core beside `grants` and for the same reason: the settings panel
   * registers IPC against *this* instance, and a shell that built its own would
   * tick sessions in one copy of the file while every connection was checked
   * against another.
   */
  sessionGrants: SessionGrants
  /**
   * Which of this machine's coding logins each paired device may use.
   *
   * On the core beside `sessionGrants` and for the same reason: the approval
   * screen and the settings panel write through *this* instance, and a shell
   * that built its own would tick logins in one copy of the file while every
   * `account.read` was filtered against another.
   */
  accountGrants: AccountGrants
  /**
   * And which paired devices may act on the browser windows in this app.
   *
   * The fourth axis, on the core beside the other three and for the reason they
   * are here: one instance, because two would be two in-memory copies of one
   * file — the settings panel writing to one while every forwarded browser verb
   * is checked against the other. Built at assembly rather than by the Electron
   * shell so the headless daemon cannot be the build where the rule is missing.
   *
   * It is the mirror of `MachineStore.drivesWindows`, which answers the same
   * question about a machine this desktop dialled *out* to. Two stores, because
   * the two id spaces are different and so are the two decisions.
   */
  windowGrants: WindowGrants
  /**
   * Whether each paired device is one of the owner's own or a guest.
   *
   * On the core beside `grants` and for the same reason: the shell that draws
   * the approval screen registers IPC against *this* instance, and a shell that
   * built its own would decide kinds in one copy of the file while every
   * connection was checked against another.
   */
  kinds: DeviceKinds
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
   * And which of the running sessions each device may see.
   *
   * The second axis, beside the first and for the same reason it is here: two
   * instances would be two in-memory copies of one file, the settings panel
   * writing to one while every `list`, `attach` and keystroke is checked against
   * the other. Built at assembly rather than by the Electron shell so that the
   * headless daemon, which serves the same protocol from the same fanout, cannot
   * be the build where the rule is missing.
   */
  const sessionGrants = new SessionGrants(options.storageDir)

  /**
   * And which of this machine's logins each device may use.
   *
   * The third axis, beside the first two and here for the reason they are: one
   * instance, because two would be two in-memory copies of one file — the
   * approval screen writing to one while every account frame is filtered
   * against the other. Built at assembly rather than by the Electron shell so
   * that the headless daemon, which serves the same protocol from the same
   * fanout, cannot be the build where the rule is missing.
   */
  const accountGrants = new AccountGrants(options.storageDir)

  /**
   * And which devices may move the browser on this screen.
   *
   * The fourth axis, built here for the same reason as the third: one instance
   * of the file, and a rule the Electron shell cannot be the only build to
   * install. Unlike the three above it, this one **defaults closed** — see
   * `WindowGrants` for why the argument that makes the others fail open does not
   * apply to a capability nothing has ever had.
   */
  const windowGrants = new WindowGrants(options.storageDir)

  /**
   * Whether each paired device is one of the owner's own or a guest.
   *
   * Beside the folder grants and for the same reason — one instance, because two
   * would be two in-memory copies of one file, the approval screen writing to
   * one while every connection is checked against the other. It is built *here*
   * rather than by the Electron shell so that the headless daemon, which serves
   * the same protocol from the same fanout, cannot be the build where the rule
   * is missing. `session-fanout.ts` says the same thing about `hidden`: a rule a
   * shell has to remember to install is a rule the other shell forgets.
   */
  const kinds = new DeviceKinds(options.storageDir)

  /**
   * What one device may touch, computed once and read by three doors.
   *
   * Every consumer below goes through this — the folder list a device is sent,
   * the folder rule `create` enforces, and the per-session visibility check the
   * fanout applies to `list`, `attach` and every keystroke. That is the property
   * `device-reach.ts` exists for: the advertised set and the enforced set are
   * one call, so a picker cannot offer what the rule refuses and a list cannot
   * show what a keystroke would be denied.
   */
  const reach = (deviceId: string): DeviceReach =>
    reachFor({ kinds, grants }, deviceId, {
      // The open projects, most-recently-opened first, then the folders sessions
      // are running in. Suggestions only, and only for a device of the owner's
      // own: a guest's answer is its granted list and never touches this.
      //
      // Live sessions come after the projects because a session can be running
      // in a folder that was never added as a project, and the owner's own
      // laptop can see it in its own list.
      offered: () => [
        ...store().getProjects().map((project) => project.path),
        ...ptys.list().map((session) => session.cwd),
      ],
      /*
       * The home directory one of the owner's own machines lands in when it
       * names nothing — on the same side of the boundary as everything else.
       *
       * The platform home is `C:\Users\Asad` on Windows, and starting a session
       * there on a machine whose work is all in Linux hands it the one folder
       * with nothing in it. The distro's own `$HOME` is the right answer and is
       * used when it is known; it is not always known, because asking for it
       * means starting a stopped distribution and this app does not boot a
       * virtual machine to fill in a default. The platform home is the fallback
       * — a real folder, on the wrong side, which is better than a path that
       * resolves to nothing.
       */
      home: () => wsl.home() ?? homeDir(),
    })

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
    /*
     * The login shell's PATH, with this app's `open` in front of it.
     *
     * Here, on this one local, rather than in `PtyManager.environmentFor`, and
     * that placement is the whole of it: this string feeds `planFor({ … path … })`
     * below *and* `ptys.create(…, { path, … })` after it. Prepending after the
     * plan was built would hand a confined session a PATH entry its seatbelt
     * profile has no rule for, and the exec would be refused — a session that
     * simply does not start, for a feature it never asked about. Put here, the
     * directory becomes a read+exec root in the plan for free, because
     * `confine/plan.ts`'s `toolRoots()` turns PATH entries into exactly that,
     * so a confined session gets the shim with no change to confinement at all.
     *
     * Not inside WSL. `TERMINALDECK_SESSION_ID` crosses that boundary, but a
     * Linux process inside the distribution cannot open a Windows named pipe,
     * so the shim there would be a script that always falls through — and one
     * that always falls through is one more thing on a PATH doing nothing. A
     * WSL session keeps the PATH it has always had. `open-shim.ts` answers null
     * on Windows anyway, so this is the guard for a Windows host reaching in.
     */
    const shim = target === null ? currentOpenShim() : null
    const path = prependShim(await loginPath(), shim?.dir ?? null)
    // Asked of the side the session will actually run on. Asking Windows whether
    // `claude` exists, on a machine where it is installed inside Ubuntu, is the
    // bug this whole path exists to fix: every agent reported missing, and every
    // tab silently downgraded to a shell.
    const available = await detectProviders(platform, target)
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
    /*
     * What was asked for, or nothing at all. **Never something else.**
     *
     * This line used to read
     *
     *     const provider = addedRuns ? requested : available[requested] ? requested : 'shell'
     *
     * and that expression is the second half of the fault Asad reported on
     * 2026-08-17, which is the worse half. A session whose agent could not be
     * started opened as a plain terminal instead, wearing the same tab, in the
     * same folder — and then `ledger.note` wrote *that* down as what was open.
     * Every launch afterwards restored a shell, correctly reported that a shell
     * has no conversation to continue, and never attempted the real agent again.
     * A transient failure — a distro that was asleep, a probe that timed out,
     * the `wsl.exe` path bug in `wsl.ts` — had become permanent, and the
     * downgrade hid the failure that caused it.
     *
     * The two comments this function used to carry about that fallback both
     * described it as protection ("rather than spawning a binary that isn't
     * there, which would flash a dead tab with no explanation"). The premise is
     * right and the conclusion was wrong: the answer to "we cannot start what
     * you asked for" is to say so, not to start something else and let the
     * person work out for themselves why their agent is gone. `copilot-session.ts`
     * had already reached that conclusion and defended itself from this line by
     * hand, checking `meta.provider !== 'claude'` after the fact and killing the
     * session — a downstream check nobody else knew to write.
     *
     * A shell is still perfectly startable; it is simply never a *substitute*.
     * `available.shell` is always true, so asking for one cannot reach this
     * throw.
     */
    if (!addedRuns && !available[requested]) {
      throw new AgentUnavailableError(requested, agentLabel(requested, added), target !== null)
    }
    const provider = requested
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
    /*
     * This app's browser verbs, on this session's own command line.
     *
     * Asad, 2026-08-21: *"driving other browsers should be for all of the
     * sessions, regardless of even they are Commander, they are not Commander"*
     * — and, of a session that had none: *"if I currently ask the session which
     * is outside, it just don't know anything."*
     *
     * Five conditions, and each one rules out a case where this would be a claim
     * rather than a capability — or, in the first case, a capability nobody
     * meant to hand out:
     *
     *  - **A session a paired device asked for gets them only to reach that
     *    device's own windows**, and this condition used to be a flat refusal.
     *    The refusal's reasoning was right and is untouched: such a session runs
     *    on *this* machine, and giving it the verbs over the windows *here*
     *    would hand a phone, through its own session, the thing
     *    `browser-tools.ts` refuses it directly and says it always will — a way
     *    to make this Mac open a page, click through it and raise a banner
     *    saying "type your password" inside the owner's trusted app chrome. The
     *    caller kind on the token is `session` rather than `remote`, so that
     *    refusal would not fire, which is exactly how a boundary gets walked
     *    around rather than removed.
     *
     *    What changed is that there is now somewhere else for the verb to go.
     *    `window-owner.ts` records which device asked for this session, and
     *    `deck-control/browser-tools.ts`'s forwarder sends **every** verb from
     *    such a session to that device — never to a window on this machine, not
     *    even one attached here. So the boundary above holds word for word: the
     *    windows on this screen are as unreachable from a device's session as
     *    they were, and what the session gained is the ability to act on the
     *    window the person attached to it *in their own app*, which is the whole
     *    of what he asked for. `reachesDeviceWindows` is that forwarder saying it
     *    can actually reach **this** device — a phone cannot serve a browser
     *    verb and never could, so it keeps the flat refusal it always had, and
     *    with it the honest sentence `session-verbs.ts` prints.
     *  - **A caller that composed its own arguments owns the tool surface.**
     *    There is exactly one — the copilot, which passes `--mcp-config <its own
     *    file> --strict-mcp-config` — and adding a second `--mcp-config` beside
     *    a strict one would either be ignored or would replace the surface its
     *    whole permission model is built on.
     *  - **The shipped Claude CLI.** `--mcp-config` is Claude's flag. Codex and
     *    Gemini configure MCP servers in files of their own with no per-run
     *    override this app can compose, so they are launched exactly as before;
     *    see `session-tools.ts` for what is missing rather than pretended.
     *  - **Inside WSL, only once the distribution has said it can reach the
     *    endpoint.** This condition used to be a flat `target === null`, copied
     *    from the `open` shim's reasoning — and the copy was wrong. The shim is
     *    withheld there because this app's hook endpoint on Windows is a *named
     *    pipe*, which no Linux process can open. The verbs do not go through the
     *    pipe: `deck-control/server.ts` is plain HTTP on 127.0.0.1, and a socket
     *    is a thing a distribution can be given an address for. So the two real
     *    obstacles are mechanical — the config file has to be named `/mnt/c/…`
     *    from over there, and `127.0.0.1` reaches the host's loopback only under
     *    mirrored networking — and both are *measured*, by one command run
     *    inside the distribution, rather than assumed from a config file this
     *    side could read. `wsl-reach.ts` holds that and the security argument.
     *    A distribution that did not answer is told why, in one sentence, and
     *    launched exactly as it was before.
     *  - **The endpoint exists.** A build with no `deck-control` server — the
     *    headless host, a test harness — passes no seam and every session is
     *    launched the way it always was.
     */
    const forDevice = guest !== undefined || confine !== undefined
    /*
     * Asked of the distribution, once per distribution and port, and only for a
     * session that is actually in one. `null` on this Mac and on a Windows
     * folder, where there is no boundary to cross and nothing to ask.
     */
    const insideDistro =
      target === null ? null : ((await options.sessionTools?.insideDistro?.(target)) ?? null)
    const sessionTools =
      (!forDevice || options.sessionTools?.reachesDeviceWindows?.(confine?.deviceId) === true) &&
      (extraArgs ?? []).length === 0 &&
      provider === 'claude' &&
      !addedRuns &&
      (target === null || insideDistro !== null)
        ? (options.sessionTools?.prepare(insideDistro ?? undefined) ?? null)
        : null
    /*
     * Why this launch has no verbs, in the vocabulary a session can be told in.
     *
     * Computed here, beside the gate, rather than inferred later from the
     * session's provider and folder: an inference would be a second copy of the
     * conditions above, and the day one of them moved the app would start
     * telling somebody a reason that had stopped being true. `null` means the
     * verbs are on the command line — and a caller that composed its own tool
     * surface gets `null` too, because there is exactly one and it composes
     * these same verbs into it. See `session-verbs.ts`.
     */
    const noVerbs: NoVerbsReason | null =
      sessionTools !== null || (extraArgs ?? []).length > 0
        ? null
        : forDevice
          ? 'device'
          : provider !== 'claude' || addedRuns
            ? 'provider'
            : /*
               * A build with no seam at all and a run whose endpoint is not up
               * yet are two different sentences, and only one of them is a dead
               * end. The headless host passes no seam and never will
               * (`endpoint`); the desktop always passes one and answers null
               * only in the few hundred milliseconds before its control server
               * binds, which catches restored tabs (`early`). Telling a
               * restored tab there is no endpoint would be false a second later
               * and would leave him with a session that quietly cannot see —
               * which is the whole complaint.
               *
               * Both are asked **before** `wsl`, and the order was rearranged on
               * 2026-08-21 when `wsl` stopped meaning "inside a distribution"
               * and started meaning the narrow thing it says: the distribution
               * could not reach this endpoint. A headless host in a Linux folder
               * would otherwise be told to reconfigure WSL's networking for an
               * endpoint that does not exist in that build at all.
               */
              options.sessionTools === undefined
              ? 'endpoint'
              : target !== null
                ? 'wsl'
                : 'early'
    /*
     * Everything this app puts on the command line that the caller did not ask
     * for — one binding, because it is read **twice** and the second reader
     * forgot it.
     *
     * `wanted`, four hundred lines down, rebuilds the whole argument list from
     * `table` when a fresh Claude session is given `--session-id`, and it used
     * to rebuild it from `extraArgs` alone. So the copilot — whose flags *are*
     * `extraArgs` — kept its tools, and every ordinary session had
     * `--mcp-config` composed here, written to disk, registered against a live
     * token, and then dropped on the floor before the spawn. Measured on his Mac
     * an hour after 0.9.0 shipped: two files under `<userData>/session-tools`
     * with matching timestamps, and two live processes reading
     * `claude --session-id <uuid>` and nothing else.
     *
     * What he saw from the other end is the whole of the report — *"other
     * sessions still cant see inside the browser window they opened they can
     * just open"*. Opening never needed a tool: the `open` shim is on every
     * session's PATH and lands the page in a window here. Reading it is the tool
     * that was never there.
     *
     * A session that is quietly launched without the thing it was just given is
     * the exact shape of failure this file already carries two long warnings
     * about — the provider fallback that started a shell instead, and the
     * `--session-id` rebuild that threw away a resume. One name for the flags,
     * used everywhere they are needed, is what stops there being a third.
     */
    const composed: readonly string[] =
      sessionTools === null ? (extraArgs ?? []) : [...(extraArgs ?? []), ...sessionTools.args]
    const spec = withLaunchArgs(table, composed, platform, process.env, target)

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
      /*
       * `$BROWSER` as well as the PATH shim, not instead of it.
       *
       * The two catch different agents and neither is redundant. Claude Code
       * reads `$BROWSER` before any platform branch, so this is the direct and
       * explicit route for it. Gemini CLI 0.46.0 ignores `$BROWSER` entirely and
       * spawns a bare `open`, so the PATH entry is the only thing that catches
       * it. Setting one and not the other would leave one of the two agents he
       * actually runs opening pages in a browser somewhere else on the machine.
       */
      ...(shim?.browser ? { BROWSER: shim.browser } : {}),
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
    /*
     * `--continue` names no conversation — it means *the most recent one in
     * this folder*, resolved by the CLI at spawn — so two sessions started in
     * one folder resolve to the same transcript and both append to it, from the
     * same parent message, with no error and no warning. `one-conversation.ts`
     * carries the measured fork and the rule Asad settled: a second session in
     * a folder that already has a live one starts fresh instead of resuming.
     */
    /*
     * `--resume <id>`, when the caller can name the conversation.
     *
     * `--continue` means *the folder's most recent conversation*, which is a
     * guess that happens to be right nearly always and is not the claim the
     * account-switch sheet makes. A switch says the conversation **on screen**
     * follows, and it knows that conversation's id — this app put it on the
     * outgoing process's command line — so it names it rather than describing
     * it. `session-switch.ts` only passes one after checking the transcript is
     * readable from the account being switched *to*; anything it could not
     * prove falls through to `spec.spawn.resumeArgs` and the folder-newest
     * meaning, unchanged.
     *
     * Through `withLaunchArgs` for the reason spelled out below `namesConversation`
     * — inside WSL `spec.spawn.args` is a `wsl.exe` invocation whose last
     * element is a quoted command line, and appending to it hands the flag to
     * the login shell instead of to the CLI.
     *
     * No `--fork-session` beside it, deliberately. Forking would copy the
     * conversation into a new id, so switching account and back would leave two
     * transcripts holding one conversation; without it the CLI reuses the
     * original id, which is what "the same conversation, under the other
     * login" has to mean.
     */
    const named =
      provider === 'claude' &&
      input.resume === true &&
      typeof input.resumeConversationId === 'string' &&
      input.resumeConversationId !== ''
    const resumeArgs = named
      ? withLaunchArgs(
          spec,
          ['--resume', input.resumeConversationId as string],
          platform,
          process.env,
          target,
        ).spawn.args
      : spec.spawn.resumeArgs

    const chosen = argsForSpawn({
      resume: input.resume === true,
      resumeArgs,
      args: spec.spawn.args,
      live: ptys.list(),
      cwd: input.cwd,
      /*
       * The session this one replaces, when it replaces one.
       *
       * Only an account switch passes it, and without it the switch could never
       * resume: `performSwitch` starts the replacement before it stops the
       * outgoing process, so the guard saw a live session of the same provider
       * in the same folder and dropped `--continue` every single time.
       * `one-conversation.ts` carries the argument.
       */
      replaces: typeof input.replaces === 'string' ? input.replaces : null,
      // `provider`, the same value handed to `ptys.create` below and therefore
      // the same one `SessionMeta.provider` carries — so the comparison is
      // like for like. The *requested* provider is not: an agent that is not
      // installed falls back, and a fallback session in this folder holds the
      // transcript under the name it actually runs as.
      provider,
    })

    /*
     * Name the conversation, so its transcript can be found rather than guessed.
     *
     * `claude --session-id <uuid>` makes the CLI file this session at
     * `<configDir>/projects/<encoded cwd>/<uuid>.jsonl` instead of at a name only
     * it knows. Verified against Claude Code 2.1.235 on this machine: a run with
     * a generated id produced exactly that one file and no other. Everything
     * downstream — `context-window.ts` above all — then reads *this* session's
     * transcript rather than the folder's most recent one, which is the whole of
     * the "every session shows the same context window" defect.
     *
     * ## Only on the fresh path, and that is the CLI's rule rather than caution
     *
     *     $ claude --continue --session-id <uuid> -p '…'
     *     Error: --session-id can only be used with --continue or --resume if
     *            --fork-session is also specified.
     *
     * Forking is not a workaround for it. `--fork-session` copies the
     * conversation into a *new* id, which would leave two transcripts holding
     * one conversation every time somebody continued a session — a real change
     * to a person's history, made to make a number on a bar easier to read. So a
     * resumed session keeps no id and keeps the inference, which is exactly the
     * case the inference is honest about: it is continuing a conversation this
     * app did not name.
     *
     * ## Why the flag goes through `withLaunchArgs`
     *
     * Because `spec.spawn.args` is not always the agent's own argument list —
     * inside WSL it is a `wsl.exe` invocation whose last element is a quoted
     * command *line*, and appending there hands the flag to the login shell as a
     * positional parameter where the CLI never sees it. That trap is argued in
     * full where `withLaunchArgs` is declared; this calls it rather than
     * repeating the mistake it exists to prevent.
     */
    const namesConversation = provider === 'claude' && chosen !== resumeArgs
    /*
     * Which conversation this session is on, when that is known rather than
     * inferred — and there are now two ways to know it. A fresh session is
     * given a new id; a resume that named one is on the id it named, because
     * the CLI reuses it when `--fork-session` is absent. Both are facts this
     * process put on the command line itself, which is the standard
     * `SessionMeta.agentSessionId` is held to.
     */
    /*
     * The id **this** spawn declares, which is only ever a new one.
     *
     * Held apart from `agentSessionId` below because the two answer different
     * questions and conflating them is what broke every account switch that
     * named a conversation. `--session-id` *declares* an id; `--resume` *joins*
     * one; the CLI refuses the first against a transcript that already exists —
     * `Error: Session ID <uuid> is already in use` — and that is precisely the
     * transcript a switch is resuming. So the flag belongs to the fresh path
     * alone, and the argument list built for it must not be reachable from the
     * resume path. A `string | null` typed here rather than re-derived below is
     * what makes that unreachable rather than merely unintended.
     */
    const declaredId = namesConversation ? randomUUID() : null
    const agentSessionId =
      declaredId ?? (named && chosen === resumeArgs ? (input.resumeConversationId as string) : null)
    /**
     * Did the agent actually get a continue flag?
     *
     * Read off the arguments rather than off the request, because those are two
     * different questions and the switch already shipped a log line that
     * answered the wrong one: it recorded `continued: true` from the plan while
     * the guard above was quietly dropping the flag. What a caller asked for is
     * not evidence of what ran.
     */
    const resumed = resumeArgs.length > 0 && chosen === resumeArgs
    /*
     * `declaredId`, never `agentSessionId`.
     *
     * This read `agentSessionId === null ? chosen : …--session-id…`, and on the
     * one path where the two differ — a switch resuming the conversation on
     * screen by name — it threw `chosen` away and rebuilt the command line
     * with `--session-id <the id being resumed>`. Measured on 2026-08-20: the
     * terminal printed `Error: Session ID … is already in use`, the agent
     * exited, and the tab was left empty. That is the whole of *"it's not
     * keeping the conversation history"* on the path that was supposed to fix
     * it. A resume keeps the arguments that were chosen for it.
     *
     * ## And `composed`, never `extraArgs`
     *
     * This rebuild starts from `table` — the untouched provider spec — so every
     * flag this app composes has to be handed to it again, and this line used to
     * hand it `extraArgs` alone. `extraArgs` is one caller's flags, the
     * copilot's; the browser verbs every ordinary session is given are the
     * *other* half of what was folded into `spec` above. So the copilot kept its
     * tools and every ordinary Claude session lost its `--mcp-config` on the one
     * path that always runs for a fresh session, which is every session a person
     * starts. `composed` is both halves under one name; see where it is built.
     */
    const wanted =
      declaredId === null
        ? chosen
        : withLaunchArgs(
            table,
            [...composed, '--session-id', declaredId],
            platform,
            process.env,
            target,
          ).spawn.args

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
    /*
     * The confinement, plus the one file this launch was just handed.
     *
     * `confine/plan.ts` keeps `<userData>` out of every read root deliberately —
     * it also holds transcripts, pairing credentials and `state.json` — and the
     * session's MCP config lives inside it. Without this the flags would name a
     * file the sandbox refuses to open, which is the worst of the three
     * outcomes: not a session that fails to start and not a session with no
     * tools, but a session holding six verbs that answer nothing, with the
     * reason visible only in a seatbelt denial nobody is reading.
     *
     * Granted as a *file* rather than as its folder, exactly like the credential
     * helper and the context documents a few hundred lines up, and for the
     * stronger version of the same reason: the folder is `<userData>/session-tools`
     * and it holds one bearer token per live session, including other devices'.
     */
    const held =
      confine !== undefined && sessionTools !== null
        ? { ...confine, files: [...confine.files, sessionTools.file] }
        : confine
    const plan =
      confined && held
        ? planFor({
            folder: input.cwd,
            device: held,
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
       * The conversation id handed to the CLI a moment ago, kept so that
       * everything which later wants *this session's* transcript can name it.
       *
       * Spread conditionally, like `profile` below and for the same reason: a
       * session with no id must carry no key, because `agentSessionId:
       * undefined` and "this app did not name this conversation" have to be the
       * same thing to every reader, and only one of the two survives JSON.
       */
      ...(agentSessionId !== null ? { agentSessionId } : {}),
      /*
       * What went on the command line, not what was asked for — and passed
       * unconditionally, which is the whole point of it. Spread conditionally
       * like the two fields above, a `false` would be an *absent* key, and
       * `PtyManager.create` reads an absent key as "the caller did not say" and
       * falls back to `input.resume` — the request, which is exactly the
       * untruth this exists to replace.
       */
      resumed,
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
     * The token minted for this launch, now that the launch has an id to be.
     *
     * Nothing undoes it on the failure path and nothing needs to: a launch that
     * throws before this line never reaches it, and the seam disarms an
     * unclaimed one on a deadline of its own — see `CLAIM_TTL_MS` in
     * `deck-control/session-tools.ts`. One mechanism rather than two, because
     * the second one is the one that gets forgotten on the path nobody exercises.
     */
    sessionTools?.started(meta.id)

    /*
     * Or, when there was none, the sentence this session may explain itself
     * with.
     *
     * Written down here because this is the only place that knows *why*, and
     * read at the top of every one of that session's turns by the hook answer —
     * `browser-binding.ts` already tells it which windows are its own, and a
     * session told it owns `B1` with no verb for it goes looking for another way
     * in rather than concluding there is none. `session-verbs.ts` carries the
     * measurement and the sentence.
     */
    if (noVerbs !== null) noteNoVerbs(meta.id, noVerbs)

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
     * `requested`, and `requested` is now the only thing it can be: the
     * substitution that used to make the two differ is gone, because writing a
     * fallback down is what made a downgrade permanent. That happened, on
     * `DESKTOP-DDGMNCV`, and the state file still had the wreckage in it on
     * 2026-08-17 — two folders that had been `"provider":"claude"` in the log
     * that morning were `"provider":"shell"` on disk that afternoon, and every
     * relaunch afterwards restored a bare terminal that then reported, quite
     * correctly, that it had no conversation to continue.
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
     *
     * ## Nor is a session this app started for itself
     *
     * The same argument, one step further. A `SavedSession` is a folder, an
     * agent and an account — everything a person's tab is made of, and nothing
     * else. A launch that also carried a `fence` or `extraArgs` is a launch this
     * *app* composed for its own purposes, and neither of those survives into a
     * `SavedSession`, so restoring one produces something that is not the
     * session that was written down.
     *
     * Concretely, and this was on Asad's machine: the copilot's own session is
     * spawned with `--append-system-prompt-file <layer>` and `--mcp-config`, and
     * it was being written into `openSessions` like any tab — twice, because it
     * had been restarted. The next launch would restore two ordinary Claude
     * sessions in `<userData>/copilot`, with no instruction layer, no
     * `deck-control` tools and no fence, hidden from the sidebar because the
     * window filters that folder out. Two invisible agent processes, billing,
     * every time the app opens. `startCopilot` already refuses to start a
     * copilot without its layer — *"A copilot spawned with no layer is not a
     * diminished copilot. It is a plain Claude Code session in somebody's
     * workspace, wearing this app's name"* — and this is that same refusal,
     * enforced at the one place that could otherwise arrange it behind
     * everybody's back.
     *
     * Keyed on the arguments rather than on a flag the caller sets, because the
     * arguments *are* the fact: they are main-process-only by construction (a
     * renderer cannot compose argv — see the note where `extraArgs` is
     * declared), so "was this launch composed by the app" and "did it carry
     * these" are the same question. The copilot is the only caller of either
     * today, and `host-core.copilot.test.ts` pins that a launch carrying them is
     * not remembered.
     */
    const appComposed = fence !== undefined || (extraArgs !== undefined && extraArgs.length > 0)
    if (!confined && !appComposed) {
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
     * The model, the effort and fast mode, for a window on another machine.
     *
     * Asad, three times, the last on 2026-08-18: *"why it is all the options are
     * not available with the connected ones from other devices. We should have
     * all the options up on the same identical options for the remote sessions
     * too."* The reason they were not is that `agent-controls.ts` speaks to a
     * *local* pty by *local* session id — it sets a model by typing `/model` at
     * the session and reading the reply off that session's screen — and nothing
     * on the wire named any of it. `CAPABILITY.controls` is the frame pair that
     * carries the question there and the answer back.
     *
     * Note what is delegated and what is not: this is the same `readControls`
     * and the same `applyControl` the window at this desk calls for its own bar,
     * against the same `PtyManager`. There is no second implementation and no
     * remote dialect — the far end asks, and this machine answers exactly as it
     * would have answered itself. That is also why a machine one version ahead
     * behaves like its own build rather than like the asking one's memory of it.
     *
     * Here at assembly, for the reason `hidden` below is: the headless build
     * serves the same remote protocol from the same fanout, and a capability a
     * shell had to remember to install is one the other shell forgets.
     *
     * `cwd` and `provider` are looked up per call rather than captured, because
     * both are properties of a session that may not have existed when this was
     * built. `provider` is what this app *launched*, which is the right input:
     * `refuseByProvider` treats `shell` as a refusal and `undefined` as "ask the
     * screen", and a session started as a shell with an agent typed into it is
     * exactly the case the screen has to settle.
     */
    controls: {
      read: async (id) => {
        const row = ptys.list().find((session) => session.id === id)
        const reading = await readControls(ptys, id, row?.cwd, row?.provider)
        /*
         * And the connectors, on the same answer.
         *
         * They ride this frame rather than one of their own because they are
         * read on the same schedule and drawn by the same cluster — the chip is
         * one of the four on that bar, and giving it a capability of its own
         * would be a second round trip per output pause for a list that is three
         * file reads. `loadServers` is the same function `mcp:list` calls for a
         * window at this desk, resolved for *this* session's folder, which is
         * what makes the chip over a remote session name the servers that
         * session can actually reach rather than the asking machine's own.
         *
         * `statusFor` is deliberately not applied. That decorates each row with
         * this machine's *connection* state, which is about an inspector process
         * over here and means nothing to a chip a thousand kilometres away; what
         * travels is the configuration, which is what the chip draws.
         *
         * A read that throws leaves the field absent rather than empty, and the
         * two mean opposite things to a chip that exists only when there are
         * connectors — see `ControlsReadingWire.connectors`.
         */
        let connectors
        try {
          connectors = loadServers(row?.cwd ?? null).map((server) => ({
            id: server.id,
            name: server.name,
            scope: server.scope,
            transport: server.transport,
            enabled: server.enabled,
            disabledReason: server.disabledReason,
          }))
        } catch {
          connectors = undefined
        }
        return connectors === undefined ? reading : { ...reading, connectors }
      },
      apply: (id, control, value) => {
        const row = ptys.list().find((session) => session.id === id)
        return applyControl(ptys, { sessionId: id, cwd: row?.cwd, control, value, provider: row?.provider })
      },
    },
    /*
     * The plan limits and the context window, for a bar on another machine.
     *
     * The same defect `controls` above closes, one element to the left. Both
     * figures on that bar were read *here* — the plan limits are the
     * subscription of the login signed in on this computer, and the context
     * window is a transcript on this disk found by an id this machine's own
     * agent wrote — so over a session running on a paired PC the first was a
     * different account's spending and the second was a lookup for a
     * conversation this disk has never seen. `usage-reach.ts` withheld both
     * rather than show them; `CAPABILITY.usage` is what makes them true.
     *
     * Delegated exactly as `controls` is: `createUsageServe` reaches the same
     * `readUsage`, `refreshUsage` and `readContextWindow` the window at this
     * desk reaches for its own bar. There is no remote dialect and no second
     * implementation, so a machine one version ahead reports what its own build
     * reports.
     *
     * `describeSession` is the same lookup `registerUsageIpc` is given in
     * `index.ts` — deliberately the same question asked the same way, because
     * "whose login is this session on" having two answers on one machine is how
     * one account's figure lands on another account's bar. `accounts` is the
     * shared "this login has no subscription limits" memory, so a remote open
     * declines to spawn for exactly the logins a local open declines for.
     *
     * Here at assembly, for the reason the `controls` seam above is: the
     * headless build serves the same remote protocol from the same fanout, and
     * a capability a shell had to remember to install is one the other shell
     * forgets.
     */
    usage: createUsageServe({
      describeSession: (id) => ptys.list().find((session) => session.id === id) ?? null,
      accounts: storedAccountLimits(),
    }),
    /*
     * The conversation, for a chat view that is not on this machine.
     *
     * The fourth seam, and the one that had nothing at all: `controls`, `usage`
     * and `account` each closed a chip that was drawn-but-wrong over a remote
     * session, and this closes a whole *view* that only ever existed at the
     * desk. The chat view reads a transcript on this disk through
     * `chat:load`/`chat:tail`, so a phone — which has neither the file nor a
     * filesystem to find it in — could see a terminal and nothing else. Asad,
     * about the phone client: *"app needs enrichment"*.
     *
     * Delegated exactly as the three above are: `createChatServe` uses the same
     * `ChatReader` and the same `ChatCollapser` the window at this desk uses, so
     * the bubbles are the same bubbles rather than a second reading of the same
     * file that can disagree with it.
     *
     * `configDirFor` is the same question `usage` asks one line up and is asked
     * the same way. An account is a config directory, so a session running as a
     * second login files its conversation under that login's `projects/` — and
     * without this a phone would be shown the *default* account's conversation
     * in the same folder, which is words rather than a number and therefore the
     * worse version of the mistake `usage-serve.ts` names.
     *
     * Here at assembly for the reason the others are: the headless build serves
     * the same protocol from the same fanout, and a capability a shell had to
     * remember to install is one the other shell forgets.
     */
    chat: createChatServe({
      describeSession: (id) => ptys.list().find((session) => session.id === id) ?? null,
      configDirFor: (session) =>
        session.provider === 'codex' ? null : accountFor('claude', session).configDir,
    }),
    /*
     * Whose login a session is on, and running it as another one, for a chip on
     * another machine.
     *
     * The third of the three seams that make a remote session's bar the same bar
     * as a local one, and the last one missing. Asad, on a session running on his
     * PC: *"I want it exactly like the local ones"*, and *"bring the account
     * selection here for the remote sessions too"*. The account chip was withheld
     * because no frame carried the fact; this is the fact travelling.
     *
     * Spread rather than assigned, because its absence is what stops this machine
     * advertising the capability — see `SessionAccess.account`. The headless build
     * passes no `switchAccount` and therefore offers no chip, rather than offering
     * one whose every row is refused after the press.
     */
    ...(options.switchAccount === undefined
      ? {}
      : {
          account: createAccountServe({
            describeSession: (id) => ptys.list().find((session) => session.id === id) ?? null,
            switchAccount: options.switchAccount,
          }),
        }),
    /*
     * This machine's logins with no session in the question, for a settings pane
     * on another machine — and starting a sign-in here from one.
     *
     * The fourth seam, and the one that closes the gap the third could not: an
     * account list was readable only *through* a running session, because
     * `account.read` carries a session id, so a machine with nothing open had no
     * logins as far as any other machine was concerned. Asad, of the Coding AI
     * pane: *"So we can click and manage what accounts are there… All of this we
     * can just manage from this."*
     *
     * Spread rather than assigned for the reason `account` above is: its absence
     * is what stops this machine advertising `CAPABILITY.logins`, so the headless
     * build — which has an account store and no way to open a terminal for a
     * person to finish a login in — offers nothing rather than a control that is
     * refused after the press.
     */
    ...(options.signInAccount === undefined
      ? {}
      : { logins: createLoginsServe({ signIn: options.signInAccount }) }),
    /*
     * Ending a session from a device, which until tonight nothing could do.
     *
     * A session could be started from a phone and never stopped from one, so the
     * swipe he asked for — *"close the session (with a confirmation)"* — had no
     * verb behind it and the iOS client refused to draw a button that would have
     * had to fake it. `SessionAccess.close` is the verb; this is the only place
     * that answers it, and its presence here is what makes the desktop advertise
     * the capability at all.
     *
     * `PtyManager.kill` is exactly what the ✕ in this app's own window calls, so
     * a session closed from a phone ends the same way as one closed at the desk —
     * one behaviour rather than two that can drift — and the `session:removed`
     * announcement that fix rides on takes the row out of the window with no
     * reload. The membership test is here rather than in the manager because
     * `kill` returns void: an id that is not running has to come back as `false`
     * so the device is told "no session <id> is running" instead of a silent
     * success over a session that had already exited.
     */
    close: (id) => {
      if (!ptys.list().some((session) => session.id === id)) return false
      ptys.kill(id)
      return true
    },
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
    /*
     * And which sessions belong to *this* device, which is the same question one
     * step out.
     *
     * `hidden` above answers "is this anybody's business"; this answers "whose".
     * Until it existed, `list` took no device id at all, so a guest paired to one
     * shared folder was sent every session on the machine and could attach to any
     * of them — starting a shell in an ungranted folder was refused while typing
     * into an agent already running in one was not.
     *
     * The same `reach` the folder rule below uses, deliberately: one call behind
     * what a device is offered and what it may touch, so the two cannot drift.
     */
    reach,
    /*
     * And the second axis, which the folder rule cannot express.
     *
     * `reach` above answers by folder, and this file's own comment on it admits
     * what that costs: sharing a project shares whatever else is running in it.
     * Asad, 2026-08-20: *"when we give remote access we should be able to choose
     * between running sessions which ones to give and which ones not, i mean
     * select vs all type of options"*. The two sessions he wants told apart are
     * usually in the same folder.
     *
     * Handed to the fanout rather than folded into `reach`, because the two are
     * genuinely different questions with different stores and different empty
     * states — `reach` for a guest with nothing chosen is *nothing*, while a
     * device nobody has narrowed here keeps everything. `SessionFanout.visible`
     * ANDs them, which is the one predicate `server.ts` already funnels the
     * listing and every verb through.
     */
    shared: (deviceId, sessionId) => sessionGrants.shares(deviceId, sessionId),
    /*
     * A session a device started itself is ticked for that device.
     *
     * Only for a device already on *Selected* — the store makes it a no-op
     * otherwise — and it is not a hole in "a session started after the choice is
     * not shared". That rule is about sessions somebody *else* started. This one
     * passed the folder rule to be spawned at all and the device named it; the
     * alternative is `create` handing back an id its caller may not attach to.
     */
    noteStarted: (deviceId, sessionId) => {
      sessionGrants.include(deviceId, sessionId)
    },
    // Both halves out of one starter, so the list a phone's picker is drawn from
    // is the list `create` checks against rather than a second computation of
    // the same idea. See `remoteSessionStart`.
    ...remoteSessionStart(
      {
        // What this device may start a session in: a guest's chosen folders, or
        // — for one of the owner's own machines — the projects and running
        // sessions offered as suggestions, with anything else still startable.
        // `device-reach.ts` holds the rule and the argument for it, including
        // why a device nobody has chosen for now reaches nothing rather than
        // everything.
        folders: (deviceId) => reach(deviceId).folders,
        unrestricted: (deviceId) => reach(deviceId).unrestricted,
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
            /*
             * The credential helper, and the app's own context documents.
             *
             * The second entry is here because of where the first one taught us
             * to put things. `confine/plan.ts` keeps `<userData>` out of every
             * read root on purpose — it also holds transcripts, pairing
             * credentials and `state.json` — and the context documents live
             * inside it. Without this line the map handed to a remote session at
             * boot would name a directory that session cannot open, which is
             * precisely the session type Asad was filming when he asked for the
             * map in the first place.
             *
             * Granted as *files* rather than as their folder, exactly like the
             * helper above and for a weaker version of the same reason: the
             * folder is inside `<userData>`, so opening it would be one small
             * step towards opening the thing this boundary exists to keep shut.
             * They are read-only, they are regenerated from code at every start,
             * and they contain nothing this session was not already told.
             */
            files: [join(guestRoot, HELPER_FILE), ...(currentAppContext()?.files ?? [])],
            /*
             * And which device this is all for, carried to the one gate that
             * needs it.
             *
             * `startSession` decides whether this launch gets the browser verbs,
             * and that decision now depends on whether *this* device can serve
             * one — a paired desktop can, a phone cannot. The device id is right
             * here and nowhere downstream of this line, and it rides on the
             * confinement rather than on `CreateSessionInput` for the reason
             * `guest`, `confine` and `fence` are arguments rather than fields:
             * the input crosses the preload bridge, and which device a session
             * belongs to is not something page code may claim.
             */
            deviceId: input.deviceId,
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
          /*
           * And which device this session belongs to, which is the fact that
           * decides where its browser verbs go.
           *
           * Written here because this is the only line in the app that has both
           * the device id and the session id in scope: `input.deviceId` came
           * from the authenticated socket and `meta.id` was minted a moment ago.
           * `window-owner.ts` says why it cannot be inferred later from anything
           * on the pty.
           */
          noteWindowOwner(meta.id, input.deviceId)
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
      // And why it had no browser verbs, for the same reason and on the same
      // terms: ids are minted once, so an entry left behind answers a question
      // nothing will ever ask again. See `session-verbs.ts`.
      forgetNoVerbs(id)
      // And which device it belonged to. Same terms again, and one more reason
      // here: the entry is what sends a browser verb across a relay, and an
      // entry outliving its session would be an id that could be asked about
      // for as long as this app runs.
      forgetWindowOwner(id)
      sessions.noteExit(id, exitCode)
      // The key that let this session ask a phone for a GitHub login stops
      // working the moment the session does. A key that outlived its session
      // would be a credential request with nothing behind it — and every other
      // process on this machine runs as the same account, so "nothing behind it"
      // is not a theoretical caller.
      credentials.sessionEnded(id)
      // A tick naming a session that has exited can never mean anything again —
      // ids are minted once — so it is dropped rather than left to grow the
      // file. It cannot widen anything: the id it removes names nothing.
      sessionGrants.dropSession(id)
      options.onExit?.(id, exitCode)
    },
    (id, status) => {
      sessions.noteStatus(id, status)
      options.onStatus?.(id, status)
    },
    /*
     * Forwarded rather than acted on here.
     *
     * Everything this core has to forget about a dead session is already
     * forgotten in the exit callback above, and a kill produces that exit a
     * moment later — `kill` signals and returns, and node-pty reports the death
     * when the OS gets round to it. What the *shell* cannot wait for is the row
     * on screen: between the kill and the exit the session is already out of
     * `list()`, so a window still drawing it is drawing something this process
     * can no longer answer for.
     */
    (id, reason) => options.onSessionRemoved?.(id, reason),
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
    sessionGrants,
    accountGrants,
    windowGrants,
    kinds,
    agents,
    credentials,
    ledger,
    startSession,
    statablePath,
    canContinue,
  }
}
