import { contextBridge, ipcRenderer, type IpcRendererEvent } from 'electron'
import type { CreateSessionInput, SessionMeta } from '../shared/types'

/**
 * The renderer's only route to the main process. Everything is an explicit
 * method — no raw ipcRenderer is ever exposed to page code.
 */
const api = {
  getBrand: (): Promise<{ name: string; tagline: string }> => ipcRenderer.invoke('brand:get'),

  detectProviders: (): Promise<Record<string, boolean>> => ipcRenderer.invoke('providers:detect'),

  listProjects: (): Promise<Array<{ path: string; lastOpenedAt: number }>> =>
    ipcRenderer.invoke('projects:list'),
  addProject: (path: string): Promise<unknown> => ipcRenderer.invoke('projects:add', path),
  removeProject: (path: string): Promise<void> => ipcRenderer.invoke('projects:remove', path),
  getPreferences: (): Promise<Record<string, unknown>> => ipcRenderer.invoke('prefs:get'),
  setPreferences: (patch: Record<string, unknown>): Promise<Record<string, unknown>> =>
    ipcRenderer.invoke('prefs:set', patch),

  pickProjectFolder: (): Promise<string | null> => ipcRenderer.invoke('project:pick'),

  createSession: (input: CreateSessionInput): Promise<SessionMeta> =>
    ipcRenderer.invoke('session:create', input),

  writeToSession: (id: string, data: string): void => {
    ipcRenderer.send('session:write', id, data)
  },

  resizeSession: (id: string, cols: number, rows: number): void => {
    ipcRenderer.send('session:resize', id, cols, rows)
  },

  getScrollback: (id: string): Promise<string> => ipcRenderer.invoke('session:scrollback', id),

  killSession: (id: string): Promise<void> => ipcRenderer.invoke('session:kill', id),

  listSessions: (): Promise<SessionMeta[]> => ipcRenderer.invoke('session:list'),

  /** Returns an unsubscribe function so React effects can clean up properly. */
  onSessionData: (cb: (id: string, data: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, data: string) => cb(id, data)
    ipcRenderer.on('session:data', handler)
    return () => ipcRenderer.off('session:data', handler)
  },

  onSessionExit: (cb: (id: string, exitCode: number) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, code: number) => cb(id, code)
    ipcRenderer.on('session:exit', handler)
    return () => ipcRenderer.off('session:exit', handler)
  },

  onSessionStatus: (cb: (id: string, status: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, status: string) => cb(id, status)
    ipcRenderer.on('session:status', handler)
    return () => ipcRenderer.off('session:status', handler)
  },

  /* ------------------------------------------------------------ cost -- */

  getProjectCost: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:project', cwd),
  getSessionCost: (transcriptPath: string): Promise<unknown> =>
    ipcRenderer.invoke('cost:session', transcriptPath),
  listSessionTranscripts: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:sessions', cwd),
  watchProjectCost: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:watch', cwd),
  unwatchProjectCost: (cwd: string): Promise<void> => ipcRenderer.invoke('cost:unwatch', cwd),
  getModelPricing: (model: string): Promise<unknown> => ipcRenderer.invoke('cost:pricing', model),
  formatCost: (value: number): Promise<string> => ipcRenderer.invoke('cost:format', value),
  onCostUpdate: (cb: (summary: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, summary: unknown) => cb(summary)
    ipcRenderer.on('cost:update', handler)
    return () => ipcRenderer.off('cost:update', handler)
  },

  /* ------------------------------------------------------------- git -- */

  gitStatus: (cwd: string): Promise<unknown> => ipcRenderer.invoke('git:status', cwd),
  gitDiff: (cwd: string, path: string, options?: { staged?: boolean; untracked?: boolean }): Promise<string> =>
    ipcRenderer.invoke('git:diff', cwd, path, options ?? {}),
  watchGit: (cwd: string): Promise<unknown> => ipcRenderer.invoke('git:watch', cwd),
  unwatchGit: (cwd: string): void => {
    ipcRenderer.send('git:unwatch', cwd)
  },
  onGitStatus: (cb: (cwd: string, status: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, cwd: string, status: unknown) => cb(cwd, status)
    ipcRenderer.on('git:status-changed', handler)
    return () => ipcRenderer.off('git:status-changed', handler)
  },

  /* -------------------------------------------------------- files -- */

  listDir: (root: string, relDir: string, options?: { showIgnored?: boolean }): Promise<unknown> =>
    ipcRenderer.invoke('fs:list', root, relDir, options ?? {}),
  readFile: (root: string, relPath: string): Promise<unknown> =>
    ipcRenderer.invoke('fs:read', root, relPath),

  searchProjectFiles: (request: { root: string; refresh?: boolean; limit?: number }): Promise<unknown> =>
    ipcRenderer.invoke('search:files', request),
  cancelProjectFileSearch: (): Promise<void> => ipcRenderer.invoke('search:cancel'),
  invalidateProjectFiles: (root?: string): Promise<void> =>
    ipcRenderer.invoke('search:invalidate', root),

  /* ------------------------------------------------------------ board -- */

  loadBoard: (projectPath: string): Promise<unknown> => ipcRenderer.invoke('board:load', projectPath),
  saveBoard: (projectPath: string, board: unknown): Promise<void> =>
    ipcRenderer.invoke('board:save', projectPath, board),

  /* -------------------------------------------------------- inspector -- */

  getSessionInsights: (transcriptPath: string): Promise<unknown> =>
    ipcRenderer.invoke('insights:session', transcriptPath),
  getLatestSessionInsights: (cwd: string): Promise<unknown> =>
    ipcRenderer.invoke('insights:latest', cwd),
  listSessionInsights: (cwd: string): Promise<unknown> => ipcRenderer.invoke('insights:list', cwd),

  /* ----------------------------------------------------------- github -- */

  githubOverview: (cwd: string): Promise<unknown> => ipcRenderer.invoke('github:overview', cwd),
  githubRefresh: (cwd: string): Promise<unknown> => ipcRenderer.invoke('github:refresh', cwd),
  githubRepo: (cwd: string): Promise<unknown> => ipcRenderer.invoke('github:repo', cwd),
  clearGitHubCache: (cwd?: string): Promise<void> => ipcRenderer.invoke('github:clear-cache', cwd),

  /* -------------------------------------------------------- readiness -- */

  scanReadiness: (projectPath: string): Promise<unknown> =>
    ipcRenderer.invoke('readiness:scan', projectPath),
  applyReadinessFix: (projectPath: string, checkId: string): Promise<unknown> =>
    ipcRenderer.invoke('readiness:fix', projectPath, checkId),

  /* -------------------------------------------------------- dashboard -- */

  loadDashboard: (projectPath: string): Promise<unknown> =>
    ipcRenderer.invoke('dashboard:load', projectPath),
  saveDashboard: (projectPath: string, layout: unknown): Promise<void> =>
    ipcRenderer.invoke('dashboard:save', projectPath, layout),
  clearDashboard: (projectPath: string): Promise<void> =>
    ipcRenderer.invoke('dashboard:clear', projectPath),

  /* ------------------------------------------------- search & alerts -- */

  searchSessions: (request: {
    cwd: string
    query: string
    scope?: 'project' | 'all'
    roles?: string[]
    caseSensitive?: boolean
    regex?: boolean
    maxHits?: number
  }): Promise<unknown> => ipcRenderer.invoke('session-search:run', request),
  cancelSessionSearch: (): Promise<void> => ipcRenderer.invoke('session-search:cancel'),
  projectAlerts: (projectPath: string): Promise<unknown> =>
    ipcRenderer.invoke('alerts:project', projectPath),

  /* --------------------------------------------------------- profiles -- */

  listProfiles: (): Promise<unknown> => ipcRenderer.invoke('profiles:list'),
  createProfile: (name: string): Promise<unknown> => ipcRenderer.invoke('profiles:create', name),
  renameProfile: (id: string, name: string): Promise<unknown> =>
    ipcRenderer.invoke('profiles:rename', id, name),
  deleteProfile: (id: string): Promise<void> => ipcRenderer.invoke('profiles:delete', id),
  resolveProfile: (projectPath: string, sessionChoice?: string): Promise<unknown> =>
    ipcRenderer.invoke('profiles:resolve', projectPath, sessionChoice),
  setDefaultProfile: (id: string): Promise<void> => ipcRenderer.invoke('profiles:set-default', id),
  setProjectProfile: (projectPath: string, id: string | null): Promise<void> =>
    ipcRenderer.invoke('profiles:set-project-default', projectPath, id),
  profileStatus: (id: string): Promise<unknown> => ipcRenderer.invoke('profiles:status', id),

  /* ------------------------------------------------------ pawlignore -- */

  ignoreOverview: (root: string): Promise<unknown> =>
    ipcRenderer.invoke('pawlignore:overview', root),
  ignoreFilter: (root: string, paths: string[]): Promise<unknown> =>
    ipcRenderer.invoke('pawlignore:filter', root, paths),
  ignoreExplain: (root: string, path: string): Promise<unknown> =>
    ipcRenderer.invoke('pawlignore:explain', root, path),
  invalidateIgnore: (root: string): Promise<void> =>
    ipcRenderer.invoke('pawlignore:invalidate', root),

  /* ----------------------------------------------------------- hooks -- */

  hooksStatus: (): Promise<unknown> => ipcRenderer.invoke('hooks:status'),
  installHooks: (provider: string): Promise<unknown> =>
    ipcRenderer.invoke('hooks:install', provider),
  removeHooks: (provider: string): Promise<unknown> => ipcRenderer.invoke('hooks:remove', provider),
  syncHooks: (): Promise<unknown> => ipcRenderer.invoke('hooks:sync'),

  /* ------------------------------------------------------------- mcp -- */

  mcpList: (): Promise<unknown> => ipcRenderer.invoke('mcp:list'),
  mcpConnect: (serverId: string): Promise<unknown> => ipcRenderer.invoke('mcp:connect', serverId),
  mcpDisconnect: (serverId: string): Promise<void> =>
    ipcRenderer.invoke('mcp:disconnect', serverId),
  mcpInventory: (serverId: string): Promise<unknown> =>
    ipcRenderer.invoke('mcp:inventory', serverId),
  mcpCall: (serverId: string, tool: string, args: unknown): Promise<unknown> =>
    ipcRenderer.invoke('mcp:call', serverId, tool, args),
  mcpReadResource: (serverId: string, uri: string): Promise<unknown> =>
    ipcRenderer.invoke('mcp:read-resource', serverId, uri),
  mcpGetPrompt: (serverId: string, name: string, args?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('mcp:get-prompt', serverId, name, args),

  /* --------------------------------------------------------- browser -- */

  browserCreate: (url: string): Promise<unknown> => ipcRenderer.invoke('browser:create', url),
  browserNavigate: (id: string, url: string): Promise<unknown> =>
    ipcRenderer.invoke('browser:navigate', id, url),
  browserBack: (id: string): Promise<void> => ipcRenderer.invoke('browser:back', id),
  browserForward: (id: string): Promise<void> => ipcRenderer.invoke('browser:forward', id),
  browserReload: (id: string): Promise<void> => ipcRenderer.invoke('browser:reload', id),
  browserStop: (id: string): Promise<void> => ipcRenderer.invoke('browser:stop', id),
  browserClose: (id: string): Promise<void> => ipcRenderer.invoke('browser:close', id),
  browserBounds: (id: string, bounds: unknown): Promise<void> =>
    ipcRenderer.invoke('browser:bounds', id, bounds),
  browserVisible: (id: string, visible: boolean): Promise<void> =>
    ipcRenderer.invoke('browser:visible', id, visible),
  browserInspect: (id: string, on: boolean): Promise<void> =>
    ipcRenderer.invoke('browser:inspect', id, on),
  browserState: (id: string): Promise<unknown> => ipcRenderer.invoke('browser:state', id),
  onBrowserState: (cb: (id: string, state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, state: unknown) => cb(id, state)
    ipcRenderer.on('browser:state-changed', handler)
    return () => ipcRenderer.off('browser:state-changed', handler)
  },
  onBrowserElement: (cb: (id: string, element: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, element: unknown) => cb(id, element)
    ipcRenderer.on('browser:element', handler)
    return () => ipcRenderer.off('browser:element', handler)
  },

  /* --------------------------------------------------- chrome import -- */

  checkPrerequisites: (): Promise<unknown> => ipcRenderer.invoke('prereq:check'),

  /* ------------------------------------------------ settings & debug -- */

  getSettings: (): Promise<unknown> => ipcRenderer.invoke('settings:get'),
  setSettings: (patch: Record<string, unknown>): Promise<unknown> => ipcRenderer.invoke('settings:set', patch),
  resetSettings: (): Promise<unknown> => ipcRenderer.invoke('settings:reset'),
  settingsPaths: (): Promise<unknown> => ipcRenderer.invoke('settings:paths'),
  openSettingsPath: (key: string): Promise<unknown> => ipcRenderer.invoke('settings:open-path', key),
  appAbout: (): Promise<unknown> => ipcRenderer.invoke('settings:about'),
  clearBrowserData: (): Promise<unknown> => ipcRenderer.invoke('settings:clear-browser-data'),
  browserSessionInfo: (): Promise<unknown> => ipcRenderer.invoke('browser-session:info'),
  browserCookies: (filter?: unknown): Promise<unknown> => ipcRenderer.invoke('browser-session:cookies', filter),
  clearBrowserCookies: (): Promise<unknown> => ipcRenderer.invoke('browser-session:clear-cookies'),
  clearBrowserCache: (): Promise<unknown> => ipcRenderer.invoke('browser-session:clear-cache'),
  clearBrowserStorage: (): Promise<unknown> => ipcRenderer.invoke('browser-session:clear-storage'),
  browserViewClaim: (request: unknown): Promise<unknown> => ipcRenderer.invoke('browser-view:claim', request),
  browserViewRelease: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:release', id),
  browserViewReveal: (request: unknown): Promise<unknown> => ipcRenderer.invoke('browser-view:reveal', request),
  browserViewZoom: (id: string, factor: number): Promise<unknown> => ipcRenderer.invoke('browser-view:zoom', id, factor),
  browserViewUserAgent: (id: string, ua: string | null): Promise<unknown> => ipcRenderer.invoke('browser-view:user-agent', id, ua),
  browserViewDevtools: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:devtools', id),
  browserViewScreenshot: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:screenshot', id),
  browserViewRecord: (id: string, on: boolean): Promise<unknown> => ipcRenderer.invoke('browser-view:record', id, on),
  browserViewRecordClear: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:record-clear', id),
  debugAbout: (): Promise<unknown> => ipcRenderer.invoke('debug:about'),
  debugDiagnostics: (): Promise<unknown> => ipcRenderer.invoke('debug:diagnostics'),
  debugDiagnosticsText: (): Promise<unknown> => ipcRenderer.invoke('debug:diagnostics-text'),
  debugIpcLog: (): Promise<unknown> => ipcRenderer.invoke('debug:ipc-log'),
  debugIpcClear: (): Promise<unknown> => ipcRenderer.invoke('debug:ipc-clear'),
  debugSubscribe: (): Promise<unknown> => ipcRenderer.invoke('debug:subscribe'),
  debugUnsubscribe: (): Promise<unknown> => ipcRenderer.invoke('debug:unsubscribe'),
  logRecent: (lines?: number): Promise<unknown> => ipcRenderer.invoke('log:recent', lines),
  logStatus: (): Promise<unknown> => ipcRenderer.invoke('log:status'),
  logClear: (): Promise<unknown> => ipcRenderer.invoke('log:clear'),
  openLogFolder: (): Promise<unknown> => ipcRenderer.invoke('log:open-folder'),

  listBrowsers: (): Promise<unknown> => ipcRenderer.invoke('chrome-import:browsers'),
  scanBrowserTabs: (browserId?: string): Promise<unknown> =>
    ipcRenderer.invoke('chrome-import:scan', browserId),
}

contextBridge.exposeInMainWorld('pawl', api)

export type PawlBridge = typeof api
