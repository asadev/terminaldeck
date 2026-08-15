import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { app, BrowserWindow, dialog, ipcMain, powerMonitor, session, shell } from 'electron'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput, SessionMeta } from '../shared/types'
import { PtyManager } from './pty-manager'
import { detectProviders, loginPath, providersFor, PROVIDERS } from './providers'
import { currentPlatform } from './platform/host'
import {
  conversationOnDisk,
  folderExists,
  planRestore,
  restoreOpenSessions,
  type RestoreDecision,
  type SavedSession,
} from './session-restore'
import { store, type Preferences } from './store'
import { pinUserData } from './user-data'
import { registerCostIpc } from './cost-ipc'
import { registerGitIpc, stopAllGitWatches } from './git'
import { registerFsIpc } from './fs-tree'
import { registerSearchIpc } from './file-search'
import { registerInsightsIpc } from './session-insights'
import { registerChatIpc } from './chat-transcript'
import { registerDevPortsIpc } from './dev-ports'
import { autoUpdater } from 'electron-updater'
import { registerAgentControlsIpc } from './agent-controls'
import { registerUpdateIpc } from './updates/updater'
import { createManualStrategy } from './updates/manual-strategy'
import { registerTailnetIpc } from './remote/tailnet'
import { registerRemoteIpc } from './remote/server'
import { SessionFanout } from './remote/session-fanout'
import { remoteSessionStart } from './remote/session-create'
import { FolderGrants, foldersForDevice } from './remote/folder-grants'
import { createCredentialProxy, type CredentialProxy } from './remote/credentials'
import type { GuestGitEnv } from './remote/git-guest'
import {
  dropPlanSession,
  notePlanOutput,
  notePlanResize,
  registerPlanLimitIpc,
} from './plan-limit'
import { registerGitHubIpc } from './github'
import { registerReadinessIpc } from './readiness'
import { registerDashboardIpc } from './dashboard-store'
import { registerSessionSearchIpc } from './session-search'
import { registerAlertsIpc } from './alerts'
import { registerProfilesIpc, getState as profilesState, resolveProfile, sessionEnv } from './profiles'
import { registerDeckignoreIpc } from './deckignore'
import { registerHooksIpc } from './hooks'
import { registerHookServer, stopHookServer } from './hook-server'
import { registerMcpIpc } from './mcp-client'
import { registerBrowserIpc } from './browser-tab'
import { registerChromeImportIpc } from './chrome-import'
import { registerPrerequisitesIpc } from './prerequisites'
import {
  registerSettingsIpc,
  clearBrowserDataIfNotPersisting,
  patchStoredSettings,
  storedValue,
  REMOTE_ENABLED_KEY,
} from './settings-extra'
import { registerBrowserSessionIpc } from './browser-session'
import { registerBrowserViewIpc } from './browser-view'
import { registerDiagnosticsIpc } from './diagnostics'
import { registerNotificationIpc } from './os-notifications'
import { registerLidAwakeIpc } from './lid-awake'
import { registerLogIpc, logger } from './app-log'
import { traceIpc, TRACE_SETTING } from './ipc-trace'
import { buildMenu } from './menu'
import { registerSetupIpc } from './setup'
import { registerCookieImportIpc } from './cookie-import'
import { registerBrowserIsolationIpc } from './browser-isolation'
import {
  WslLink,
  isLinuxPath,
  linuxPathFromUnc,
  registerWslIpc,
  wslEnvBridge,
  wslUncPath,
  type WslTarget,
} from './wsl'
import type { SessionStatus } from '../shared/types'

const isDev = !!process.env.ELECTRON_RENDERER_URL

let mainWindow: BrowserWindow | null = null

/**
 * Content Security Policy, set here rather than in index.html.
 * Vite's dev server injects an inline module preamble that a strict
 * `script-src 'self'` blocks — which makes the React plugin throw and the
 * window render blank. Dev therefore permits inline/eval; production does not.
 */
function applySecurityPolicy(): void {
  const policy = isDev
    ? "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self' ws: http://localhost:*"
    : "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self'"

  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [policy],
      },
    })
  })
}

/**
 * True from the moment the app starts going away.
 *
 * Set before anything in `before-quit` does its work, because the first thing
 * that happens there is `ptys.killAll()` — and killing a PTY *generates*
 * traffic: the process flushes, `onData` fires, `onExit` fires, and
 * `markExited` pushes a status. All three of those want to talk to a renderer
 * that is already on its way out.
 */
let quitting = false

/**
 * Whether there is a render frame on the other end of `send`.
 *
 * Tracked from events rather than asked for on demand, and that is the whole
 * point — see `send` below for why nothing can be asked.
 */
let rendererAlive = false

/**
 * Broadcast to the renderer, if there is one.
 *
 * ## The bug
 *
 * A packaged v0.1.3 printed seven of these when it was stopped with a live
 * session — five from `PtyManager.onData`, one from `ActivityTracker.onChange`,
 * one from `onExit`:
 *
 *     Error sending from webFrameMain: Render frame was disposed before
 *     WebFrameMain could be accessed
 *
 * All seven came through this function, so the fix belongs here and not at
 * seven call sites. The PTYs are the cause: they keep producing output after
 * the render frame is gone, and killing them at quit *generates* a last burst
 * of exactly that traffic.
 *
 * ## Why the obvious guards do not work, all four of them
 *
 * This was measured rather than reasoned about. At the moment of a failing
 * send, with the frame already disposed, every question Electron will answer
 * says the renderer is healthy:
 *
 *     quitting=false winDestroyed=false wcDestroyed=false crashed=false
 *     mainFrame=obj detached=false
 *
 * And the send cannot be caught either: `webContents.send` and
 * `WebFrameMain.send` both swallow the failure and `console.error` it
 * themselves, so a `try`/`catch` around either one catches nothing and the
 * message is printed regardless. Reproduced both ways, still 32 errors.
 *
 * So there is no synchronous question worth asking. The only thing that knows
 * is Electron's own lifecycle, which is why liveness is a flag maintained by
 * `render-process-gone`, `destroyed` and the window's `close`/`closed` — set up
 * in `createWindow`, cleared before `killAll` in `before-quit`. With that in
 * place the same teardown that produced 32 errors produces none.
 *
 * The remaining checks below are not redundant with the flag: they cover the
 * ordinary case of a window that has gone while the app keeps running, which on
 * macOS is most of the time.
 */
function send(channel: string, ...args: unknown[]): void {
  if (quitting || !rendererAlive) return
  const window = mainWindow
  if (!window || window.isDestroyed()) return
  const contents = window.webContents
  if (!contents || contents.isDestroyed()) return
  contents.send(channel, ...args)
}

/**
 * Latest status per live session. PtyManager only pushes status through its
 * callback, so anything that needs to *ask* (the alerts scanner) has nowhere
 * to read it from without this.
 */
const liveStatus = new Map<string, { status: SessionStatus; at: number }>()

/** Held so the recheck interval can be disarmed on quit. */
let updates: ReturnType<typeof registerUpdateIpc> | null = null

/**
 * Held so the wake lock and the battery watch can be let go of on quit.
 *
 * `stop()` releases what *this process* holds and deliberately leaves the
 * system's own lid setting alone — see the comment on `LidAwakeController.stop`
 * for why reverting it at quit would be worse than leaving it.
 */
let lidAwake: ReturnType<typeof registerLidAwakeIpc> | null = null

/**
 * Main → renderer: a session appeared that this window did not ask for.
 *
 * Today that means a phone started one. The window keeps its own list of tabs,
 * built from what it asked `session:create` for, so without this a session
 * started from the phone is running on the Mac and invisible in the app that
 * owns it — the user's own machine is the last to know.
 *
 * Deliberately *not* fired for a session the renderer asked for itself: it is
 * about to be handed the same `SessionMeta` as the return value of its own
 * call, and a consumer that adds a tab on both would show two.
 */
const SESSION_CREATED_CHANNEL = 'session:created'

/** Everything remote access keeps on disk: the trust store, this Mac's relay identity, the grants. */
const remoteStorageDir = (): string => join(app.getPath('userData'), 'remote')

/**
 * Which folders each paired device may start a session in.
 *
 * Lazy because its constructor reads a file and this module is evaluated before
 * the app is ready, and a singleton because two instances would be two in-memory
 * copies of one file — the panel writing to one while every `create` is checked
 * against the other. `registerRemoteIpc` is handed this same object.
 */
let grantStore: FolderGrants | null = null
function folderGrants(): FolderGrants {
  grantStore ??= new FolderGrants(remoteStorageDir())
  return grantStore
}

/**
 * The GitHub credential proxy: their account, from their device, never held here.
 *
 * A singleton and lazy for the same two reasons `folderGrants` is — it makes
 * directories and binds a loopback listener, neither of which may happen while
 * this module is being evaluated, and two of them would be two sets of session
 * keys with the sockets routed to one and the sessions keyed against the other.
 *
 * It is constructed **at launch** rather than by whatever asks for it first, and
 * that is deliberate: everything else about remote access is on unless the user
 * turned it off, and a proxy that only came into being when the first phone
 * pushed would be a feature whose first use is the one that fails. `whenReady`
 * calls this before `registerRemoteIpc`, so `credentialProxyIfMade` below can
 * stay honest about the case where nothing has been started at all.
 */
let credentialDesk: CredentialProxy | null = null
function credentialProxy(): CredentialProxy {
  credentialDesk ??= createCredentialProxy({ dir: join(remoteStorageDir(), 'guest-git') })
  return credentialDesk
}

/**
 * The proxy, but only if there already is one.
 *
 * Used from the paths that run for *every* session, remote or not — a pty
 * exiting, the app quitting. Reaching for `credentialProxy()` there would build
 * one, and binding a port because somebody closed a local terminal tab is the
 * opposite of what the laziness is for.
 */
function credentialProxyIfMade(): CredentialProxy | null {
  return credentialDesk
}

/**
 * Which key the machine's WSL distribution is stored under.
 *
 * `settings.json` rather than a file of its own: it is one string, it belongs to
 * this machine rather than to a project or a device, and that is exactly what
 * `settings-extra.ts` is. It is deliberately not in the renderer's settings
 * schema — the schema declares controls with fixed options, and the list of
 * installed distributions is discovered rather than declared.
 */
export const WSL_DISTRO_KEY = 'wsl.distro'

/**
 * WSL, as far as this app is concerned: what is installed, which distribution
 * is the machine's, and where its home directory is.
 *
 * Constructed at module scope with no I/O — the constructor only stores its
 * arguments — so it is safe here, before the app is ready. The reading happens
 * in `whenReady`, and the fact that it happens there rather than when a settings
 * pane asks is the whole point: a Windows machine whose projects live in Linux
 * has to be able to start a session at launch, from a restored tab or from a
 * phone, without anybody having opened a settings window first.
 */
const wsl = new WslLink({
  store: {
    read: () => {
      const stored = storedValue(WSL_DISTRO_KEY)
      return typeof stored === 'string' && stored !== '' ? stored : null
    },
    write: (distro) => {
      patchStoredSettings({ [WSL_DISTRO_KEY]: distro })
    },
  },
})

/**
 * The one place that decides whether a folder is a Linux folder.
 *
 * Everything downstream — the provider table, the pty's working directory,
 * which side gets asked whether Claude Code is installed — hangs off this
 * answer, so it is asked once per session, in one function, rather than
 * re-derived at each of those three points.
 */
function wslTargetFor(cwd: string): WslTarget | null {
  return wsl.targetFor(cwd)
}

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
function statablePath(cwd: string): string {
  const distro = wsl.active()
  if (!isLinuxPath(cwd) || distro === null) return cwd
  return wslUncPath(distro, cwd)
}

/**
 * Fans each session's output out to the window and to any attached phone.
 * Declared before `ptys` because the PtyManager callbacks below feed it, and
 * pointed at `ptys` afterwards — the two genuinely reference each other.
 *
 * `create` is the same call the window's own New Session makes, with the same
 * PATH, the same profile and the same provider detection — see `startSession`.
 * A remote-only spawn path would be a second way to start a session, and the
 * two would drift the first time either changed.
 */
const remoteSessions = new SessionFanout({
  list: () => ptys.list(),
  write: (id, data) => ptys.write(id, data),
  resize: (id, cols, rows) => ptys.resize(id, cols, rows),
  scrollback: (id) => ptys.scrollback(id),
  // Both halves out of one starter, so the list the phone's picker is drawn from
  // is the list `create` checks against rather than a second computation of the
  // same idea. See `remoteSessionStart`.
  ...remoteSessionStart({
    // What a person chose for this device — and, only when nobody has chosen
    // anything for it, what this desktop is offering everyone: its projects
    // most-recently-opened first, then the folders sessions are running in. That
    // fallback is what every device got before grants existed, and it is kept so
    // that a phone paired before this feature is not locked out by it.
    //
    // Live sessions come after the projects: a session can be running in a
    // folder that was never added as a project, and the phone can see it in its
    // own list, so refusing to start a second one beside it would be arbitrary.
    folders: (deviceId) =>
      foldersForDevice(
        folderGrants(),
        deviceId,
        () => [
          ...store().getProjects().map((project) => project.path),
          ...ptys.list().map((session) => session.cwd),
        ],
        /*
         * The home directory a phone lands in when nothing has been chosen for
         * it — on the same side of the boundary as everything else.
         *
         * `app.getPath('home')` is `C:\Users\Asad` on Windows, and starting a
         * phone's session there on a machine whose work is all in Linux hands it
         * the one folder with nothing in it. The distro's own `$HOME` is the
         * right answer and is used when it is known; it is not always known,
         * because asking for it means starting a stopped distribution and this
         * app does not boot a virtual machine to fill in a default. The Windows
         * home is the fallback — a real folder, on the wrong side, which is
         * better than a path that resolves to nothing.
         */
        () => wsl.home() ?? app.getPath('home'),
      ),
    spawn: async (input) => {
      /*
       * A session started from somebody else's device does not get this
       * machine's git login.
       *
       * Without this the session is an ordinary child process of this app, which
       * means it inherits the owner's credential helper, their `gh` token and
       * their ssh agent — so anyone granted a folder can push as them. That is
       * not a subtle failure and it is not theoretical: `git credential fill` in
       * a granted folder answered with the owner's real GitHub token on the
       * machine this was written on.
       *
       * The guest gets its own git configuration instead, per device, and a
       * credential helper that asks *their* device for *their* login. See
       * `git-guest.ts` for the four doors that closes and the one it cannot.
       */
      const guest = await credentialProxy().openGuestSession(input.deviceId)
      let meta: SessionMeta
      try {
        meta = await startSession(
          {
            ...input,
            // The phone does not choose an agent — it has no honest way to know
            // which are installed. The desktop's own default is the answer, and it
            // falls back to a plain shell in `startSession` when that CLI is not
            // there, exactly as the window's button does.
            provider: store().getPreferences().defaultProvider,
          },
          guest.env,
        )
      } catch (error) {
        // The key was minted before the spawn, because it has to be in the
        // environment the spawn is handed. A spawn that then failed would leave
        // a live key belonging to no session, which is one more thing that can
        // ask a stranger's phone for a password.
        guest.close()
        throw error
      }
      guest.started(meta.id)
      // The window has to be told, or the session is running on this Mac and
      // only the phone knows about it.
      send(SESSION_CREATED_CHANNEL, meta)
      return meta
    },
  }),
})

/**
 * What each live session would need to be started again, keyed by session id.
 *
 * `ptys.list()` cannot answer this on its own: `SessionMeta` carries the
 * *resolved* provider and no profile at all, and neither of those is what a
 * relaunch should repeat. Insertion order is tab order, which is why this is a
 * Map and not an object.
 */
const openSessionRecords = new Map<string, SavedSession>()

/**
 * Write the open-session list to disk.
 *
 * ## The trap
 *
 * `before-quit` calls `ptys.killAll()`, and killing a pty fires `onExit` for
 * every session. Reconciling on those exits would empty the remembered list
 * during the last second of the app's life — so the app would faithfully
 * remember, on every clean quit, that nothing was open. The whole feature would
 * work only after a crash. `quitting` is set before `killAll` for exactly this
 * class of problem (see `send`), so it is the guard here too.
 *
 * Writes go straight through rather than being batched behind a timer. This
 * fires when a session opens or closes — a human-paced event, a handful of
 * times an hour — and the store already writes through a temp file and a
 * rename, so a write costs one small file and cannot leave a torn one. A timer
 * would buy nothing and could lose the last change to a power cut, which is the
 * exact event this list exists to survive.
 */
function rememberOpenSessions(): void {
  if (quitting) return
  store().setOpenSessions([...openSessionRecords.values()])
}

const ptys = new PtyManager(
  (id, data) => {
    // Plan limits are read off the same bytes the terminal draws — the CLI
    // reports them in its own output, so there is nothing else to ask.
    notePlanOutput(id, data)
    remoteSessions.noteData(id, data)
    send('session:data', id, data)
  },
  (id, exitCode) => {
    liveStatus.delete(id)
    dropPlanSession(id)
    openSessionRecords.delete(id)
    rememberOpenSessions()
    remoteSessions.noteExit(id, exitCode)
    // The key that let this session ask a phone for a GitHub login stops working
    // the moment the session does. A key that outlived its session would be a
    // credential request with nothing behind it — and every other process on this
    // machine runs as the same account, so "nothing behind it" is not a
    // theoretical caller.
    credentialProxyIfMade()?.sessionEnded(id)
    send('session:exit', id, exitCode)
  },
  (id, status) => {
    liveStatus.set(id, { status, at: Date.now() })
    remoteSessions.noteStatus(id, status)
    send('session:status', id, status)
  },
)

function createWindow(): void {
  const saved = store().getState().windowBounds
  mainWindow = new BrowserWindow({
    width: saved?.width ?? 1440,
    height: saved?.height ?? 900,
    x: saved?.x,
    y: saved?.y,
    minWidth: 720,
    minHeight: 480,
    show: false,
    title: BRAND.name,
    /*
     * What Chromium paints before the renderer has produced a first frame, and
     * again in the gap while a resize outruns compositing. It has to be the
     * dark theme's --bg-primary, because index.html ships data-theme="dark" so
     * that is what the app will paint a moment later. It was #0e0f13 — a blue
     * black left over from a palette two revisions old — against a canvas that
     * was #1c1b19 at the time, so every launch and every fast drag of the
     * window edge flashed a different dark than the app itself. There is no way
     * to read tokens.css from the main process, so this is a copy by hand: if
     * --bg-primary in the dark theme changes, change this with it.
     */
    backgroundColor: '#191919',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    trafficLightPosition: { x: 14, y: 12 },
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  })

  // Liveness, from the events rather than by asking. `render-process-gone` is
  // the one that matters when the renderer dies under the app; `close` is the
  // ordinary path, and fires before the frame goes rather than after.
  rendererAlive = true
  const rendererGone = (): void => {
    rendererAlive = false
  }
  mainWindow.webContents.on('render-process-gone', rendererGone)
  mainWindow.webContents.on('destroyed', rendererGone)
  mainWindow.on('close', rendererGone)
  mainWindow.on('ready-to-show', () => mainWindow?.show())

  // The sessions you had open, put back — and, on any later reload, the ones
  // still running re-announced. This is the *only* trigger: a restore wired to
  // a button and not to launch is the bug class this repository has paid for
  // most, and `src/reachable.test.ts` opens by naming restore-on-launch as one
  // of five features that shipped with no way in.
  mainWindow.webContents.on('did-finish-load', () => {
    void hydrateRenderer()
  })
  mainWindow.on('closed', () => {
    rendererGone()
    mainWindow = null
  })

  // Remember size and position. Debounced so a drag doesn't hammer the disk.
  let boundsTimer: NodeJS.Timeout | undefined
  const rememberBounds = () => {
    clearTimeout(boundsTimer)
    boundsTimer = setTimeout(() => {
      if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.isMaximized()) {
        store().setWindowBounds(mainWindow.getNormalBounds())
      }
    }, 400)
  }
  mainWindow.on('resize', rememberBounds)
  mainWindow.on('move', rememberBounds)

  // Surface renderer errors in the terminal — without this a blank window
  // gives no clue what failed.
  if (isDev) {
    mainWindow.webContents.on('console-message', (event) => {
      if (event.level === 'error' || event.level === 'warning') {
        console.error(`[renderer] ${event.message}  (${event.sourceId}:${event.lineNumber})`)
      }
    })
    mainWindow.webContents.on('did-fail-load', (_e, code, desc) =>
      console.error(`[renderer] failed to load: ${desc} (${code})`),
    )
  }

  // External links open in the real browser, never inside the app shell.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url)
    return { action: 'deny' }
  })

  if (process.env.ELECTRON_RENDERER_URL) {
    void mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    void mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

/**
 * Start a session. The one place that does, for the window and for a phone.
 *
 * Was inline in the `session:create` handler until a phone needed to start one
 * too. Everything here is load-bearing and none of it is obvious from the
 * outside — the login shell's PATH, the fallback when the requested CLI is not
 * installed, the profile's redirected config directory — so a second copy for
 * the remote path would be a session that is subtly not the same kind of
 * session: no agent CLI on PATH, or two "separate" logins quietly sharing one
 * config directory.
 *
 * `guest` is set for exactly one caller — a session a paired device asked for —
 * and it is what stops that session inheriting this machine's git login. It is a
 * parameter rather than something resolved in here because whose session this is
 * is not a fact this function has: the window's own New Session and a restored
 * tab both belong to the person at the keyboard, and giving *those* an isolated
 * git would break the app for its owner to protect them from themselves.
 */
async function startSession(input: CreateSessionInput, guest?: GuestGitEnv): Promise<SessionMeta> {
  const path = await loginPath()
  /*
   * Which side of the WSL boundary this session lives on, decided by its folder
   * and by nothing else.
   *
   * A Linux path cannot be opened by cmd.exe under any circumstance, so this is
   * not a preference being consulted — it is the only way that folder can run.
   * `targetFor` answers without waiting for the distro probe for exactly that
   * reason; see its comment.
   */
  const target = wslTargetFor(input.cwd)
  // Asked of the side the session will actually run on. Asking Windows whether
  // `claude` exists, on a machine where it is installed inside Ubuntu, is the
  // bug this whole path exists to fix: every agent reported missing, and every
  // tab silently downgraded to a shell.
  const available = await detectProviders(currentPlatform(), target)
  // Fall back to a plain shell rather than spawning a binary that isn't there,
  // which would flash a dead tab with no explanation.
  const requested = input.provider ?? 'claude'
  const provider = available[requested] ? requested : 'shell'
  // `PROVIDERS` is the table for this machine; a WSL session needs the table for
  // this machine *and this folder*, because `wsl.exe --cd` is part of the launch.
  const spec = target === null ? PROVIDERS[provider] : providersFor(currentPlatform(), process.env, target)[provider]

  // Resolve the profile the session should run as and hand the PTY its
  // config-dir override. Without this the picker records a choice that never
  // reaches the process, and two "separate" logins quietly share one.
  const profile = resolveProfile(profilesState(), {
    sessionProfileId: input.profileId ?? undefined,
    projectPath: input.cwd,
  })

  /*
   * The profile's config-dir override, plus — inside WSL — the one variable that
   * lets any of it cross the boundary.
   *
   * WSL does not inherit the Windows environment: a variable arrives only if
   * `WSLENV` names it. Without this the session marker never reaches the agent
   * (so the app cannot tell its own sessions apart from a nested one) and a
   * profile's config directory never reaches it either, which is the "two
   * separate logins quietly sharing one directory" failure this function warns
   * about two comments up — reappearing on Windows only, and only inside Linux.
   *
   * The profile's directory is a real `C:\Users\…` folder, so it is listed as a
   * path and WSL rewrites it to `/mnt/c/…` on the way in. That is the one thing
   * this feature deliberately leaves on the Windows side of the boundary: it is
   * small, read once, and the alternative is a login that silently is not the
   * one the user picked.
   */
  const profileEnv = { ...sessionEnv(profile, provider), ...(guest?.set ?? {}) }
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
  // died with no message — observed on Windows 11, which is what this comment
  // is replacing a guess with. `providers.ts` has carried the launchable form
  // in `spawn` the whole time, unread. Inside WSL they diverge further still:
  // `spawn` is a whole `wsl.exe` invocation and `bin` is the CLI's own name,
  // which is what the far side looks up.
  const meta = ptys.create(input, {
    provider,
    command: spec.spawn.command,
    args:
      input.resume && spec.spawn.resumeArgs.length > 0 ? spec.spawn.resumeArgs : spec.spawn.args,
    path,
    env,
    ...(guest ? { removeEnv: guest.remove } : {}),
    // Set only for a WSL launch, where the session's own folder is a Linux path
    // that node-pty would resolve into a Windows directory that does not exist.
    hostCwd: spec.spawn.hostCwd,
  })

  /*
   * Remember the tab, so a relaunch can put it back.
   *
   * `requested`, not `provider`: the two differ when the chosen CLI is not
   * installed and the fallback above turns the tab into a plain shell. Writing
   * the fallback down would make the downgrade permanent — install Claude Code
   * tomorrow and every restored tab would still be a shell, with nothing on
   * screen explaining why.
   *
   * `input.profileId`, not the resolved `profile`: a null here means "whatever
   * this project's default profile is", and that is a question worth asking
   * again next launch rather than freezing today's answer.
   */
  openSessionRecords.set(meta.id, {
    cwd: input.cwd,
    provider: requested,
    profileId: input.profileId ?? null,
    cols: input.cols,
    rows: input.rows,
    lastSeenAt: Date.now(),
  })
  rememberOpenSessions()

  return meta
}

/** True once the sessions from the previous run have been dealt with, win or lose. */
let restored = false

/**
 * Bring the window level with the main process: every live session, announced.
 *
 * ## Why this is not simply called at launch
 *
 * `send` reaches a render *frame*; `onSessionCreated` is registered by a React
 * effect inside that frame. Broadcasting before the effect runs is a message
 * with no listener — it is not queued, it is dropped — and the session would be
 * running on this Mac with no tab. `did-finish-load` fires after the page's
 * scripts have run, which is the earliest point at which there is anything to
 * hear it.
 *
 * ## Why it announces every session and not just the new ones
 *
 * Re-announcing is free and fixes a second thing. The renderer's `addSession`
 * is idempotent by id — it says so at its own definition — so a session that is
 * already a tab is ignored. That makes this safe to run on *every*
 * `did-finish-load`, which is what a renderer reload is: today a reload leaves
 * every pty running and every tab gone, with no way back to a session that is
 * still alive. After this, the tabs come back with it.
 */
async function hydrateRenderer(): Promise<void> {
  if (!restored) {
    // Set before the await, not after. `did-finish-load` can fire again while
    // the first restore is still spawning — a reload in dev does it routinely —
    // and a second pass would start a second copy of every session.
    restored = true
    const saved = store().getOpenSessions()

    /*
     * Every restored folder has to be a known project before the window asks
     * for the list, or the tab arrives with nowhere to live.
     *
     * The sidebar groups sessions under projects, so a session in a folder that
     * was never added as a project — one started from a phone, most obviously —
     * comes back as a running pty with no row anywhere.
     *
     * Synchronous, and before the first `await`, on purpose. The renderer asks
     * for its projects from a React effect that is itself waiting on a settings
     * round trip, so in practice it asks long after this; but "in practice"
     * is how a losing race gets written, and the whole pass is a handful of
     * `existsSync` calls against folders on a path the user opens by hand.
     * Behind an `await` it would be genuinely racy for no gain.
     *
     * `existsSync` rather than the planner's async check because a folder that
     * is gone must not be added: the planner will skip that session anyway, and
     * a project row pointing at a deleted directory would outlive this launch.
     *
     * Existing projects are left alone rather than re-added — `addProject`
     * bumps `lastOpenedAt`, and that is what orders the sidebar, so restoring
     * would otherwise reshuffle it on every launch.
     */
    if (store().getPreferences().restoreSessions) {
      const known = new Set(store().getProjects().map((project) => project.path))
      for (const session of saved) {
        // `statablePath`, not the folder itself: a Linux path is invisible to
        // `existsSync` on Windows however real it is, and every restored WSL
        // session would come back as a tab with no project row to sit under.
        if (!known.has(session.cwd) && existsSync(statablePath(session.cwd))) {
          store().addProject(session.cwd)
          known.add(session.cwd)
        }
      }
    }

    try {
      await restoreOpenSessions({
        saved: () => saved,
        // Read now rather than captured at import: the switch can have been
        // turned off since the last launch.
        enabled: () => store().getPreferences().restoreSessions,
        plan: (sessions) =>
          planRestore(sessions, {
            // Asked about the folder as Windows can see it. Without the
            // translation every session that was running inside a distro is
            // planned as "its folder is gone" and dropped, which is the app
            // losing a day's tabs and explaining it with a sentence that is not
            // true.
            folderExists: (cwd) => folderExists(statablePath(cwd)),
            canContinue: (provider) => PROVIDERS[provider].resumeArgs.length > 0,
            /*
             * Resolved exactly the way `startSession` resolves it, and that is
             * the point: the directory searched for a conversation has to be the
             * directory the restored session will then write to, or the answer is
             * about a different login than the one coming back.
             *
             * Passing `conversationOnDisk` by reference used to be enough — it
             * took an optional config directory and fell back to the app's own.
             * That fallback is `~/.claude`, so every session that ran as a
             * profile was asked about the wrong store, answered "no conversation"
             * and came back blank with its transcript sitting untouched on disk.
             * The profile is the whole reason the transcripts moved.
             */
            configDir: (session) =>
              resolveProfile(profilesState(), {
                sessionProfileId: session.profileId ?? undefined,
                projectPath: session.cwd,
              }).configDir,
            conversation: conversationOnDisk,
          }),
        // The same `startSession` the window's own button and a paired phone
        // use. A restore path with its own spawn would be a second kind of
        // session — different PATH, different profile handling — that only
        // appears after a restart, which is the hardest kind of difference to
        // ever notice.
        spawn: startSession,
        announce: (meta) => send(SESSION_CREATED_CHANNEL, meta),
        report: reportRestore,
      })
    } catch (err) {
      // A restore that throws must not take the window's session list with it.
      logger.error('restore', 'restoring the previous sessions failed outright', {
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  for (const meta of ptys.list()) send(SESSION_CREATED_CHANNEL, meta)
}

/**
 * Say what happened, but only where saying it is not noise.
 *
 * Nothing is announced for a session that came back — that is the entire point
 * of the feature, and a banner reading "3 sessions resumed" is the app
 * narrating its own plumbing at someone who just wanted their work back. What
 * *is* recorded is every session that did not come back and why, in the app log
 * the user can open from Settings, because a tab quietly missing with no
 * explanation anywhere is the version of this that lies.
 */
function reportRestore(decisions: readonly RestoreDecision[]): void {
  for (const decision of decisions) {
    if (decision.outcome === 'resume') continue
    const detail = { folder: decision.session.cwd, agent: decision.session.provider }
    if (decision.outcome === 'fresh') {
      logger.info('restore', `started clean: ${decision.reason}`, detail)
    } else {
      logger.warn('restore', `did not come back: ${decision.reason}`, detail)
    }
  }
}

function registerIpc(): void {
  // Installed first so it wraps every handler registered below.
  // Off unless the user turned Debug mode on. Consulted per call rather than
  // captured, so toggling the setting takes effect without a relaunch.
  traceIpc(ipcMain, { enabled: () => storedValue(TRACE_SETTING) === true })

  ipcMain.handle('brand:get', () => ({ name: BRAND.name, tagline: BRAND.tagline }))

  ipcMain.handle('project:pick', async () => {
    if (!mainWindow) return null
    const { canceled, filePaths } = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory', 'createDirectory'],
      title: 'Open project',
      buttonLabel: 'Open',
    })
    if (canceled || filePaths.length === 0) return null
    /*
     * A folder picked inside a distro is stored as the Linux path it really is.
     *
     * Explorer lists the installed distributions in its sidebar, so the ordinary
     * folder dialog is already how a person browses to a project inside Ubuntu —
     * and it hands back `\\wsl.localhost\Ubuntu\home\asad\proj`. Storing that is
     * storing a path nothing can run in: cmd.exe refuses a UNC working directory
     * outright, and the folder rule that decides where a session runs would see
     * a Windows path and start the session on the wrong side of the boundary.
     *
     * Translated here, at the one point the path enters the app, so that every
     * copy of it downstream — the project list, a session's `cwd`, a folder
     * granted to a phone — is already the Linux path.
     */
    const picked = filePaths[0]
    return linuxPathFromUnc(picked)?.path ?? picked
  })

  /*
   * Which machine is being asked about.
   *
   * The renderer asks this to decide which agents to offer, with no folder in
   * hand, and on a machine with a usable distribution the honest answer is the
   * distribution's: that is where the folders are and where the sessions run,
   * so answering about the Windows PATH would grey out an agent that is
   * installed and working. `defaultTarget` is null everywhere else, which is
   * the Windows and macOS behaviour unchanged.
   *
   * `startSession` does not come through here. It knows the folder, so it asks
   * about that folder's own side — see the comment there.
   */
  ipcMain.handle('providers:detect', () =>
    detectProviders(currentPlatform(), wsl.defaultTarget()),
  )

  ipcMain.handle('projects:list', () => store().getProjects())
  ipcMain.handle('projects:add', (_e, path: string) => store().addProject(path))
  ipcMain.handle('projects:remove', (_e, path: string) => store().removeProject(path))
  ipcMain.handle('prefs:get', () => store().getPreferences())
  ipcMain.handle('prefs:set', (_e, patch: Partial<Preferences>) => store().setPreferences(patch))

  // Feature modules own their own channels; each registers in one line.
  registerCostIpc(ipcMain)
  registerGitIpc(ipcMain)
  registerFsIpc(ipcMain)
  // Restricting search to known projects stops any folder that merely looks
  // like a project from being enumerated over IPC.
  registerSearchIpc(ipcMain, {
    isAllowedRoot: (root) => store().getProjects().some((p) => p.path === root),
  })
  registerInsightsIpc(ipcMain)
  registerChatIpc(ipcMain)
  registerDevPortsIpc(ipcMain)
  // PtyManager is the SessionAccess: controls are read off the rendered
  // screen and applied by typing, exactly as a person would.
  registerAgentControlsIpc(ipcMain, ptys)
  // `write` is what lets plan:refresh run /usage in the session; without it the
  // module reports 'unwired' and the strip hides the control rather than
  // offering a button that does nothing.
  registerPlanLimitIpc(ipcMain, { write: (id, data) => ptys.write(id, data) })
  // Checks on a delay after launch and then occasionally; never installs on its
  // own. An unsigned build reports that it cannot self-update rather than
  // checking forever — see updates/updater.ts.
  updates = registerUpdateIpc(ipcMain, {
    updater: autoUpdater,
    // Squirrel refuses an unsigned bundle, which is this build. The manual
    // path does the same job without it: read the public feed, verify the
    // archive's sha512, swap the bundle. Supplied on macOS only.
    manual:
      process.platform === 'darwin'
        ? createManualStrategy({
            feedUrl: 'https://github.com/asadev/terminaldeck/releases/latest/download/latest-mac.yml',
            userDataPath: app.getPath('userData'),
            currentVersion: app.getVersion(),
            platform: process.platform,
            exePath: app.getPath('exe'),
          })
        : undefined,
    environment: {
      platform: process.platform,
      isPackaged: app.isPackaged,
      execPath: process.execPath,
      feedConfigPath: app.isPackaged
        ? join(process.resourcesPath, 'app-update.yml')
        : join(app.getAppPath(), 'dev-app-update.yml'),
      // Set by electron-builder's portable launcher and by nothing else. The
      // portable exe and the installed one are the same build carrying the same
      // feed, so this is the only thing that tells them apart at runtime — and
      // an update on Windows is an installer, which is the one thing a portable
      // app must not run. See PORTABLE_REASON.
      portableExecutable: process.env.PORTABLE_EXECUTABLE_FILE ?? null,
    },
    broadcast: (channel, state) => send(channel, state),
  })
  registerTailnetIpc(ipcMain, { certDir: join(app.getPath('userData'), 'tailnet-certs') })
  // On unless this Mac has been told otherwise.
  //
  // It used to be off until someone pressed a button, and nothing pressed it
  // again on the next launch — so a Mac that had been restarted held no relay
  // connection at all, and every phone paired to it was attaching to a host
  // that was not there. That is not a missing feature to a person holding a
  // phone; it is the app not working. Measured on this machine: the identity
  // and two paired devices on disk, and not one socket to the relay.
  //
  // The comment that used to sit here — "this serves a shell", "binds only to
  // the tailnet address" — was written before the relay existed, when starting
  // meant opening a listener. Dialling out opens nothing, and a phone still
  // has to be paired and approved before a byte moves.
  const remote = registerRemoteIpc(ipcMain, {
    sessions: remoteSessions,
    autoStart: storedValue(REMOTE_ENABLED_KEY) !== false,
    onEnabledChange: (on) => {
      patchStoredSettings({ [REMOTE_ENABLED_KEY]: on })
    },
    onStartFailure: (reason) => {
      // Nobody is waiting on a reply to the launch dial, so this is the only
      // place it can surface. Loud on purpose.
      logger.error('remote', 'remote access did not come up at launch', { reason })
    },
    webRoot: join(app.getAppPath(), 'pwa', 'dist'),
    storageDir: remoteStorageDir(),
    // The same object the folder rule above closes over, never a second one:
    // the panel edits what `create` is checked against, or it edits a copy and
    // the phone keeps the folders the user just removed until the next launch.
    folders: folderGrants(),
    // Likewise the same proxy the spawn path above hands each guest session a
    // key from. This is also where it is brought into being: the endpoint binds
    // at launch, with nobody pressing anything, so the first push a phone makes
    // is not the one that discovers the feature had never been started.
    credentials: credentialProxy(),
    // Where a photo or a file sent from a phone lands. The user's downloads
    // folder, in a folder named after the app — somewhere a person already looks,
    // rather than application support, which they never do and which an
    // uninstall takes with it. Passing it is also what advertises the capability;
    // see `RemoteEndpointOptions.uploadsDir`.
    uploadsDir: join(app.getPath('downloads'), BRAND.name),
    broadcast: (channel, payload) => send(channel, payload),
  })
  // Re-dial the relay the instant the machine wakes, rather than polling the
  // clock to work out that it did. A socket that slept through a suspend is
  // usually dead and TCP will not admit it for minutes — minutes in which a
  // phone cannot reach this Mac. `powerMonitor` already knows; asking it is
  // free, and it is exactly one event instead of a timer that runs forever.
  powerMonitor.on('resume', () => remote.server.wake())
  // The GitHub sign-in stores a token of its own when the user connects from
  // inside the app, so this registration is the one that needs to know where
  // this build keeps its data. `registerGitHubIpc` wires the auth channels too.
  registerGitHubIpc(ipcMain, { userDataDir: app.getPath('userData') })
  registerReadinessIpc(ipcMain)
  registerDashboardIpc(ipcMain)
  registerSessionSearchIpc(ipcMain)
  registerProfilesIpc(ipcMain)
  registerDeckignoreIpc(ipcMain)
  registerHooksIpc(ipcMain)
  registerMcpIpc(ipcMain)
  registerBrowserIpc(ipcMain)
  registerChromeImportIpc(ipcMain)
  registerPrerequisitesIpc(ipcMain)
  registerSetupIpc(ipcMain)
  registerCookieImportIpc(ipcMain)
  registerBrowserIsolationIpc(ipcMain)
  registerSettingsIpc(ipcMain)
  // registerBrowserSessionIpc installs the recorder preload itself.
  registerBrowserSessionIpc(ipcMain)
  registerBrowserViewIpc(ipcMain)
  registerDiagnosticsIpc(ipcMain)
  registerLogIpc(ipcMain)
  registerNotificationIpc(ipcMain)
  // Attached at launch rather than when its settings pane is first opened, and
  // the difference is not academic: `disablesleep` is a *system* setting that
  // survives a restart, so the ordinary case is this app starting on a machine
  // that is already being held awake. If nothing ran until somebody went looking
  // for the switch, the app would be sitting on top of a battery drain it had no
  // opinion about — nothing holding the idle-sleep blocker, nothing watching the
  // battery, and a switch that had never read the machine it is describing.
  lidAwake = registerLidAwakeIpc(ipcMain, { broadcast: (channel, payload) => send(channel, payload) })

  registerWslIpc(ipcMain, wsl)

  registerAlertsIpc(ipcMain, {
    liveSessions: (projectPath) =>
      ptys
        .list()
        .filter((meta) => meta.cwd === projectPath)
        .map((meta) => ({
          sessionId: meta.id,
          cwd: meta.cwd,
          status: liveStatus.get(meta.id)?.status ?? 'idle',
          statusSince: liveStatus.get(meta.id)?.at,
          provider: meta.provider,
        })),
    defaultProvider: () => store().getPreferences().defaultProvider,
  })

  ipcMain.handle('session:create', (_e, input: CreateSessionInput) => startSession(input))

  ipcMain.on('session:write', (_e, id: string, data: string) => {
    // Typing into a session is the only honest "you were using this one"
    // signal the main process gets — the active tab is renderer state and
    // never crosses the bridge. It decides which tab in a folder gets to
    // continue the conversation on the next launch, because `--continue` is
    // per folder and only one can (see `session-restore.ts`).
    //
    // Memory only. This runs per keystroke, and persisting on a keystroke
    // would turn typing into disk traffic for a field that is a tiebreak. The
    // freshened value reaches the file on the next open or close, and on
    // `before-quit` — which is where a clean shutdown makes it exact.
    const record = openSessionRecords.get(id)
    if (record) record.lastSeenAt = Date.now()
    ptys.write(id, data)
  })
  ipcMain.on('session:resize', (_e, id: string, cols: number, rows: number) => {
    // The tracker parses a rendered screen, so it has to be the same size.
    notePlanResize(id, cols, rows)
    ptys.resize(id, cols, rows)
  })
  ipcMain.handle('session:scrollback', (_e, id: string) => ptys.scrollback(id))
  ipcMain.handle('session:kill', (_e, id: string) => {
    // Forgotten here as well as on exit. `onExit` does arrive after a kill and
    // would clean up on its own, but it arrives *later*: a closed tab would
    // stay in the remembered list for that gap, and a crash inside it would
    // reopen a session the user had just closed.
    openSessionRecords.delete(id)
    rememberOpenSessions()
    return ptys.kill(id)
  })
  ipcMain.handle('session:list', () => ptys.list())
}

// Before anything reads userData — the store, the trace log and Chromium's own
// profile all resolve their paths from it.
pinUserData(app)

app.whenReady().then(() => {
  if (process.platform === 'darwin') app.setName(BRAND.name)
  applySecurityPolicy()
  registerIpc()
  /*
   * Read the installed distributions at launch, not when a settings pane asks.
   *
   * This is the failure this repository cares most about — a feature wired to a
   * button and never wired to boot — and it has three concrete consequences
   * here. Restore-on-launch runs before any window has painted and has to know
   * which side each remembered folder is on. A phone can ask for a folder list
   * seconds after the app starts, and that list has to be the Linux one. And a
   * stored distribution that has since been unregistered has to be noticed and
   * fallen back on, rather than producing "there is no distribution with the
   * supplied name" in a terminal the first time somebody starts a session.
   *
   * Nothing is started by this: `wsl.exe -l -v` reads a registry list, so a
   * stopped distribution stays stopped. It is a no-op off Windows.
   */
  void wsl.refresh().then(() => wsl.resolveHome().catch(() => null))
  // Bound to 127.0.0.1 with a per-run token. Started early so hooks installed
  // into a provider's config have somewhere to report to; failure is not fatal
  // because everything except hook callbacks still works without it.
  void registerHookServer(ipcMain).catch((err) =>
    console.error('[hook-server] failed to start, hook callbacks disabled:', err),
  )
  createWindow()
  buildMenu(() => mainWindow)

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', () => {
  // Before `quitting`, deliberately. Every session is still live at this
  // instant, which makes this the most accurate the remembered list ever gets —
  // and one line further down `quitting` closes `rememberOpenSessions` for the
  // rest of the run, because `killAll` fires an exit per session and reconciling
  // on those would write down that nothing was open. A crash never reaches this
  // line, which is fine: the list is already correct from the last open or
  // close, and that is the case this whole feature is for.
  rememberOpenSessions()

  // First, and before `killAll`. Killing a PTY makes it flush, exit and push a
  // status, and all three of those broadcast — into a render frame that is
  // already being torn down. See `send`.
  quitting = true
  rendererAlive = false
  ptys.killAll()
  stopAllGitWatches()
  updates?.stop()
  lidAwake?.stop()
  void stopHookServer()
  // Nothing of anybody's account is written down, so there is nothing here to
  // clean up — this only closes the loopback listener and answers anything a git
  // is still waiting on, rather than leaving it to time out against an app that
  // has gone.
  void credentialProxyIfMade()?.stop()
  void clearBrowserDataIfNotPersisting()
})
