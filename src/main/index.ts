import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { app, BrowserWindow, dialog, ipcMain, powerMonitor, session, shell } from 'electron'
import { BRAND } from '../shared/brand'
import type { CreateSessionInput } from '../shared/types'
import { createHostCore } from './host-core'
import { detectProviders, PROVIDERS } from './providers'
import { currentPlatform } from './platform/host'
import { electronPaths, installPaths } from './platform/paths'
import {
  conversationOnDisk,
  folderExists,
  planRestore,
  restoreOpenSessions,
  type RestoreDecision,
} from './session-restore'
import { store, type Preferences } from './store'
import { pinUserData } from './user-data'
import { refreshCostWatchers, registerCostIpc } from './cost-ipc'
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
import { registerMachinesIpc } from './remote/machines/ipc'
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
import { registerProfilesIpc, getState as profilesState, resolveProfile } from './profiles'
import { registerSignInIpc } from './profiles-signin'
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
import { logger } from './app-log'
import { registerLogIpc } from './app-log-ipc'
import { traceIpc, TRACE_SETTING } from './ipc-trace'
import { buildMenu } from './menu'
import { registerSetupIpc } from './setup'
import { registerCookieImportIpc } from './cookie-import'
import { registerBrowserIsolationIpc } from './browser-isolation'
import { linuxPathFromUnc, registerWslIpc } from './wsl'
import type { SessionStatus } from '../shared/types'

/*
 * Say which shell this is, and pin the directory — both before any other line of
 * this module runs.
 *
 * These sat at the bottom of the file while everything that reads a path was
 * lazy. They cannot stay there now: `createHostCore` below is constructed at
 * module scope and its `FolderGrants` reads its file in its constructor, so a
 * pin that happened afterwards would have the grants loaded from the *unpinned*
 * directory — the "renaming the app silently moved everyone's data" failure that
 * `user-data.ts` exists to close, arriving through a different door.
 *
 * The store, the profiles, the log and the trust store all reach for
 * `platform/paths.ts`, which has no default and throws if nothing installed one
 * — see the header there for why a default would be worse than a crash. This is
 * the Electron answer; `src/headless/daemon.ts` installs the plain-Node one.
 *
 * `electronPaths` forwards on every call rather than capturing, which is what
 * lets `pinUserData` move the directory on the next line and still be obeyed.
 * Both are safe before `whenReady`: `getPath('userData')` and `setPath` do not
 * need a ready app.
 */
installPaths(electronPaths(app))
pinUserData(app)

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

/** Which key the machine's WSL distribution is stored under. See `core` below. */
export const WSL_DISTRO_KEY = 'wsl.distro'

/**
 * The machine itself: sessions, the folder grants, the credential proxy, the WSL
 * boundary.
 *
 * All of it used to be written out here. It moved to `host-core.ts` when the
 * headless build arrived, because every line of it is about the computer this
 * process is running on and none of it is about a window — and a second copy for
 * a shell with no window would be a session that is subtly not the same kind of
 * session. `src/headless/host.ts` calls this same function. What stays here is
 * the wiring that only a window needs: the broadcasts below, and the plan-limit
 * and alert bookkeeping that only a renderer reads.
 *
 * Constructed at module scope, as its pieces were, and safe there for the same
 * reason: nothing in the constructor reads a file or binds a socket.
 */
const core = createHostCore({
  storageDir: remoteStorageDir(),
  /*
   * Where the machine's WSL distribution is remembered.
   *
   * `settings.json` rather than a file of its own: it is one string, it belongs
   * to this machine rather than to a project or a device, and that is exactly
   * what `settings-extra.ts` is. It is deliberately not in the renderer's
   * settings schema — the schema declares controls with fixed options, and the
   * list of installed distributions is discovered rather than declared.
   */
  wslStore: {
    read: () => {
      const stored = storedValue(WSL_DISTRO_KEY)
      return typeof stored === 'string' && stored !== '' ? stored : null
    },
    write: (distro) => {
      patchStoredSettings({ [WSL_DISTRO_KEY]: distro })
    },
  },
  onData: (id, data) => {
    // Plan limits are read off the same bytes the terminal draws — the CLI
    // reports them in its own output, so there is nothing else to ask.
    notePlanOutput(id, data)
    send('session:data', id, data)
  },
  onExit: (id, exitCode) => {
    liveStatus.delete(id)
    dropPlanSession(id)
    send('session:exit', id, exitCode)
  },
  onStatus: (id, status) => {
    liveStatus.set(id, { status, at: Date.now() })
    send('session:status', id, status)
  },
  // The window has to be told, or a session a phone started is running on this
  // Mac and only the phone knows about it.
  onSessionCreated: (meta) => {
    send(SESSION_CREATED_CHANNEL, meta)
    /*
     * And the cost pane has to be told where to look.
     *
     * A session a device started runs confined, with a home of its own, so its
     * transcript is written under that home rather than under `~/.claude`. The
     * first session a *new* device starts creates a store that every open cost
     * pane has already finished looking for — and this is the moment the app
     * knows it exists, because the app is what made it.
     *
     * Wired here, at the hook that already fires for exactly these sessions,
     * rather than behind a timer that re-reads the disk hoping to find one. See
     * `refreshCostWatchers`.
     */
    refreshCostWatchers()
  },
})

/*
 * The names the rest of this file already used, pointed at the core.
 *
 * Aliases rather than a rewrite on purpose: everything below reads `ptys`,
 * `startSession` and the rest exactly as it did, so the move is a move and not
 * seven hundred lines of incidental churn.
 */
const { ptys, wsl, sessions: remoteSessions, ledger, startSession, statablePath } = core

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
        /*
         * No picture is painted here, and that is a measured decision rather
         * than an omission.
         *
         * A restored session was briefly seeded with its own transcript so the
         * screen would not be empty. It was built, it worked, and it is
         * invisible: Claude Code switches to the ALTERNATE SCREEN
         * (`ESC[?1049h` then `ESC[2J`) the moment its interface starts, about
         * half a second after the spawn, so anything seeded into the normal
         * buffer is underneath it and unreachable for the life of the session.
         * There is no ordering that fixes that — the CLI owns the screen.
         *
         * And it is not needed: `--continue` re-reads the whole transcript and
         * the CLI repaints the conversation itself, which is what a user
         * actually sees. Proved by watching identical turns come back in the
         * CLI's own styling with fresh spinner verbs.
         *
         * A plain shell has no transcript to replay either — nothing records
         * what it printed, and its scrollback lives only in memory. Persisting
         * every terminal's output to disk was considered and rejected: no
         * terminal on any platform does it, the shell already saves the
         * COMMANDS, and a file holding everything a terminal ever printed is
         * the same liability as the three secret files this app just spent an
         * afternoon locking down.
         */
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
    folders: core.grants,
    // Likewise the same proxy the spawn path above hands each guest session a
    // key from. This is also where it is brought into being: the endpoint binds
    // at launch, with nobody pressing anything, so the first push a phone makes
    // is not the one that discovers the feature had never been started.
    credentials: core.credentials,
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
  // The other half of remote access, and the half this app did not have: every
  // machine *this* one has paired to. Registering it dials each of them, which
  // is deliberate and is asserted by `machines/boot.test.ts` — a link that only
  // came up when somebody opened the Machines page would be a page that reports
  // its own screen as the state of the world.
  //
  // It shares the pairing desk with the host half above, because there is one
  // code on screen at a time whether a phone or a second desktop is about to
  // read it.
  const machines = registerMachinesIpc(ipcMain, {
    storageDir: remoteStorageDir(),
    desk: remote.desk,
    status: () => remote.server.status(),
    broadcast: (channel, payload) => send(channel, payload),
  })
  powerMonitor.on('resume', () => {
    remote.server.wake()
    // A guest link that slept through a suspend is as dead as a host one, and
    // for the same reason: TCP will not admit it for minutes. One event, both
    // halves.
    machines.wake()
  })
  // The GitHub sign-in stores a token of its own when the user connects from
  // inside the app, so this registration is the one that needs to know where
  // this build keeps its data. `registerGitHubIpc` wires the auth channels too.
  registerGitHubIpc(ipcMain, { userDataDir: app.getPath('userData') })
  registerReadinessIpc(ipcMain)
  registerDashboardIpc(ipcMain)
  registerSessionSearchIpc(ipcMain)
  registerProfilesIpc(ipcMain)
  // The one profile question that cannot be answered by reading a directory:
  // whether an account is signed in. See `profiles-signin.ts`.
  registerSignInIpc(ipcMain)
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
    ledger.touch(id)
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
    ledger.forget(id)
    return ptys.kill(id)
  })
  ipcMain.handle('session:list', () => ptys.list())
}


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
  // and one line further down `ledger.freeze()` closes the list for the rest of
  // the run, because `killAll` fires an exit per session and reconciling on
  // those would write down that nothing was open. A crash never reaches this
  // line, which is fine: the list is already correct from the last open or
  // close, and that is the case this whole feature is for.
  ledger.flush()
  ledger.freeze()

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
  void core.credentials.stop()
  void clearBrowserDataIfNotPersisting()
})
