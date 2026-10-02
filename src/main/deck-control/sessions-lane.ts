/**
 * The sessions lane's tools, assembled from the app's real modules.
 *
 * The four tool files beside this one — `session-more-tools.ts`,
 * `project-tools.ts`, `files-tools.ts`, `copilot-admin-tools.ts`, and the
 * window bridge in `ui-tools.ts` — each take a narrow interface of plain
 * functions, so their rules can be tested with fakes. Something has to bind
 * those interfaces to the functions the IPC handlers already call, and it is
 * this file rather than `src/main/index.ts`, so the main process's wiring is one
 * spread in `extraTools` and every binding is in one place a person can check
 * against the handlers it mirrors.
 *
 * The rule each binding follows is the brief's: **call the function the
 * `ipcMain.handle` for that channel calls.** Where the handler's body was inline
 * in `index.ts` — the held-session retry, the deferred account switch — the
 * caller passes it in as a closure, because the objects it closes over
 * (`ledger`, `PendingSwitches`, the window) exist only there.
 */

import { stat } from 'node:fs/promises'
import type { ProviderId, SessionMeta } from '../../shared/types'
import { artifactHistory, listArtifacts } from '../artifacts'
import { bringOneIn } from '../attach-bring-in'
import { readComposedLayer, readLayerFile } from '../copilot-layer'
import {
  readCopilotInstructions,
  readFolderInstructions,
  resetCopilotInstructions,
  scaffoldCopilotHome,
  writeCopilotInstructions,
  writeFolderInstructions,
} from '../copilot-home'
import {
  deleteMemoryFact,
  pathsOf,
  readMemory,
  readMemoryFact,
  revealCopilotPlace,
  writeMemoryFact,
  type CopilotInspectDeps,
} from '../copilot-inspect'
import {
  copilotLayerPaths,
  copilotState,
  ensureCopilot,
  readCopilotSignIn,
  stopCopilot,
  type CopilotRuntimeDeps,
} from '../copilot-session'
import { clearDashboard, loadDashboard, saveDashboard } from '../dashboard-store'
import { explainPath, filterIgnoredFiles, ignoreFor, invalidateIgnoreCache } from '../deckignore'
import { scanDevPorts } from '../dev-ports'
import type { DevServers, SessionOpener } from '../dev-server'
import { invalidateFileList, listProjectFiles } from '../file-search'
import { listDirectory, readTextFile } from '../fs-tree'
import { initRepository } from '../git'
import { openSystemUrl } from '../link-open'
import { stageBytes } from '../local-stage'
import { notificationDelivery, notificationSupport, openNotificationSettings } from '../os-notifications'
import { planSnapshot } from '../plan-limit'
import { listProfiles } from '../profiles'
import { readSessionAccount } from '../session-account'
import { boundaryFor } from '../session-boundary'
import { readSessionInsights } from '../session-insights'
import { searchSessions } from '../session-search'
import type { SessionSwitch } from '../session-switch-run'
import { store } from '../store'
import type { ToolSpec } from './catalogue'
import { copilotAdminTools } from './copilot-admin-tools'
import { coverageTool } from './coverage-tool'
import { deckControlStatus } from './deck-status'
import { filesTools } from './files-tools'
import type { DeckControlHandle } from './index'
import { projectTools } from './project-tools'
import { SERVER_NAME } from './server'
import { sessionMoreTools, type HeldView } from './session-more-tools'
import { uiDoCall, uiTools } from './ui-tools'

/** What only `src/main/index.ts` holds. Everything else is imported above. */
export interface SessionsLaneParts {
  /** `PtyManager` — the rename, and the list the rename reads its answer back from. */
  ptys: { rename(id: string, title: string): boolean; list(): SessionMeta[] }
  /** What `session:rename` does after the rename: `session:renamed` to the window, and the devices told. */
  announceRenamed(id: string, title: string): void
  /**
   * The three held-session handlers' bodies — `ledger.held.list()`, the
   * `session:held-retry` body, the `session:held-forget` body. They answer the
   * ledger's own rows; {@link heldView} cuts them down before a tool sees them.
   */
  held: {
    list(): readonly HeldView[]
    retry(key: string): Promise<readonly HeldView[]>
    forget(key: string): readonly HeldView[]
  }
  /** `sessionSwitch` at module scope in `index.ts`. */
  sessionSwitch: SessionSwitch
  /** The deferred switch's three handlers' bodies, over `PendingSwitches`. */
  laterSwitches: {
    later(sessionId: string, profileId: string): Promise<{ sessionId: string; profileId: string; note: string }>
    cancel(sessionId: string): boolean
    armed(): Array<{ sessionId: string; profileId: string; accountName: string; note: string }>
  }
  /** `send(SESSION_SWITCHED_CHANNEL, …)` — the window learns its tab now runs as somebody else. */
  tellSwitched(oldId: string, meta: SessionMeta, accountName: string): void
  /** The object `registerCopilotIpc` is handed. */
  copilotDeps: CopilotRuntimeDeps
  /** The object `registerCopilotInspectIpc` is handed. */
  copilotInspectDeps: CopilotInspectDeps
  /** The dev servers and the opener `registerDevServerIpc` is handed. */
  devServers: DevServers
  devServerOpener: SessionOpener
  /** `<downloads>/<brand>` — where `transfer:stage` writes. */
  stageDir(): string
  /** `wsl.home() ?? app.getPath('home')` — what `project:home` answers. */
  home(): string
  /** The app's own window, or null. The same one `isApprover` names. */
  window(): { isDestroyed(): boolean; webContents: { executeJavaScript(code: string, userGesture?: boolean): Promise<unknown> } } | null
  /** The live deck-control handle, once it exists. */
  deckControl(): DeckControlHandle | null
}

/**
 * A held session, as a tool may see it.
 *
 * The ledger's row carries more — the terminal size, the tab key, and for a
 * session a phone started, the id of the device it is confined for. That last
 * one is an opaque identifier `control.ts` keeps out of anything a model reads
 * (*"an opaque identifier in a log line is noise rather than information"*), and
 * the others answer nothing a caller asks. So the row is rebuilt field by field.
 */
function heldView(row: HeldView): HeldView {
  return {
    key: row.key,
    cwd: row.cwd,
    provider: row.provider,
    profileId: row.profileId,
    reason: row.reason,
    at: row.at,
    lastSeenAt: row.lastSeenAt,
  }
}

/** Run in the app's window, or answer null when there is none to run in. */
function evaluateIn(parts: SessionsLaneParts): (code: string) => Promise<unknown> {
  return async (code) => {
    const window = parts.window()
    if (window === null || window.isDestroyed()) return null
    return await window.webContents.executeJavaScript(code, true)
  }
}

async function isFolder(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory()
  } catch {
    return false
  }
}

export function sessionsLaneTools(parts: SessionsLaneParts): ToolSpec[] {
  const evaluate = evaluateIn(parts)
  const accounts = (): Array<{ id: string; name: string; provider: ProviderId }> =>
    listProfiles().map((profile) => ({ id: profile.id, name: profile.name, provider: profile.provider }))
  const copilotPaths = () => copilotLayerPaths(parts.copilotDeps)
  const memoryPaths = () => pathsOf(parts.copilotInspectDeps).paths

  return [
    ...sessionMoreTools({
      rename: (id, title) => {
        if (!parts.ptys.rename(id, title)) return null
        const resolved = parts.ptys.list().find((meta) => meta.id === id)?.title ?? title
        parts.announceRenamed(id, resolved)
        return resolved
      },
      held: {
        list: () => parts.held.list().map(heldView),
        retry: async (key) => (await parts.held.retry(key)).map(heldView),
        forget: (key) => parts.held.forget(key).map(heldView),
      },
      account: {
        show: (sessionId) => readSessionAccount(sessionId),
        limits: (sessionId) => planSnapshot(sessionId),
        plan: async (sessionId, profileId) => (await parts.sessionSwitch.subject(sessionId, profileId)).plan,
        switchNow: async (sessionId, profileId) => {
          const meta = await parts.sessionSwitch.perform(sessionId, profileId)
          parts.tellSwitched(sessionId, meta, accounts().find((account) => account.id === profileId)?.name ?? profileId)
          return meta
        },
        later: (sessionId, profileId) => parts.laterSwitches.later(sessionId, profileId),
        cancel: (sessionId) => parts.laterSwitches.cancel(sessionId),
        armed: () => parts.laterSwitches.armed(),
        accounts,
      },
      search: async (request) => {
        const result = await searchSessions(request.cwd, request.query, {
          scope: request.scope,
          ...(request.roles === undefined ? {} : { roles: request.roles }),
          caseSensitive: request.caseSensitive,
          regex: request.regex,
          maxHits: request.maxHits,
          ...(request.maxSessions === undefined ? {} : { maxSessions: request.maxSessions }),
        })
        return 'error' in result ? { ok: false, error: result.error, message: result.message } : { ok: true, ...result }
      },
      insights: (path) => readSessionInsights(path),
    }),

    ...projectTools({
      home: () => parts.home(),
      listFolder: async (path) => {
        const listing = await listDirectory(path, '', { showIgnored: true })
        return { entries: listing.entries, truncated: listing.truncated }
      },
      isFolder,
      addProject: (path) => {
        store().addProject(path)
      },
      removeProject: (path) => store().removeProject(path),
      showInWindow: async (path) => {
        const answer = await evaluate(uiDoCall({ kind: 'project', target: path }))
        return typeof answer === 'object' && answer !== null && (answer as { ok?: unknown }).ok === true
      },
      initRepo: (cwd) => initRepository(cwd),
      devServers: {
        // The same list `dev:server:list` answers: one row per open project.
        list: () => store().getProjects().map((project) => parts.devServers.status(project.path)),
        start: (folder) => parts.devServers.start(folder, parts.devServerOpener),
        ports: (force) => scanDevPorts(force),
      },
      dashboard: { load: loadDashboard, save: saveDashboard, clear: clearDashboard },
      artifacts: {
        list: (cwd, options) => listArtifacts(cwd, options),
        history: (cwd, relPath, options) => artifactHistory(cwd, relPath, options),
      },
    }),

    ...filesTools({
      listDir: async (root, relDir, options) => listDirectory(root, relDir, options),
      readFile: (root, relPath) => readTextFile(root, relPath),
      listFiles: async (root, options) => {
        if (options.refresh) invalidateFileList(root)
        const list = await listProjectFiles(root)
        return { files: list.files, truncated: list.truncated, source: list.source }
      },
      ignore: {
        overview: async (root) => {
          const ignore = await ignoreFor(root)
          return { root: ignore.root, sources: ignore.sources, ruleCount: ignore.rules.length }
        },
        explain: async (root, relPath, isDir) => explainPath(await ignoreFor(root), relPath, isDir),
        filter: (root, paths) => filterIgnoredFiles(root, paths),
        invalidate: (root) => invalidateIgnoreCache(root),
      },
      stage: (name, bytes) => stageBytes({ dir: parts.stageDir }, name, bytes),
      boundaryOf: (sessionId) => boundaryFor(sessionId),
      bringIn: (source, folder) => bringOneIn(source, folder),
      isDirectory: async (path) => {
        try {
          return (await stat(path)).isDirectory()
        } catch {
          return null
        }
      },
    }),

    ...copilotAdminTools({
      copilot: {
        state: () => copilotState(parts.copilotDeps),
        signIn: () => readCopilotSignIn(parts.copilotDeps),
        start: () => ensureCopilot(parts.copilotDeps),
        stop: () => stopCopilot(parts.copilotDeps),
        scaffold: () => scaffoldCopilotHome(copilotPaths()),
        reveal: (place) => revealCopilotPlace(parts.copilotInspectDeps, place),
        instructions: {
          read: (which) => {
            const paths = copilotPaths()
            if (which === 'folder') return readFolderInstructions(paths)
            if (which === 'contract') return readLayerFile(paths.layer.contract)
            if (which === 'composed') return readComposedLayer(paths.layer)
            return readCopilotInstructions(paths)
          },
          write: (which, text) => {
            const paths = copilotPaths()
            const result = which === 'folder' ? writeFolderInstructions(paths, text) : writeCopilotInstructions(paths, text)
            return { ...result, state: copilotState(parts.copilotDeps) }
          },
          reset: () => ({ ...resetCopilotInstructions(copilotPaths()), state: copilotState(parts.copilotDeps) }),
        },
        memory: {
          list: () => readMemory(memoryPaths()),
          read: (name) => readMemoryFact(memoryPaths(), name),
          write: (name, text) => writeMemoryFact(memoryPaths(), name, text),
          delete: (name) => deleteMemoryFact(memoryPaths(), name),
        },
      },
      status: () => {
        const handle = parts.deckControl()
        return handle === null
          ? null
          : deckControlStatus({
              port: handle.endpoint.port,
              server: SERVER_NAME,
              control: handle.control,
              consent: handle.consent,
              log: handle.log,
            })
      },
      notifications: {
        support: () => notificationSupport(),
        delivery: (sinceMs) => notificationDelivery(sinceMs),
        openSettings: () => openNotificationSettings(),
      },
      openUrl: (url) => openSystemUrl(url),
    }),

    ...uiTools({ evaluate }),

    // The table of what every tool covers, and why the rest is not a tool.
    coverageTool(),
  ]
}
