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

  /* ----------------------------------------------------------- remote -- */
  // Every one of these is an ipcMain.handle, so every one is invoke(). The
  // remote module registers no send-channel at all, deliberately: each call
  // wants an answer, and a send that routes nowhere fails silently.
  remoteStatus: (): Promise<unknown> => ipcRenderer.invoke('remote:status'),
  startRemote: (): Promise<unknown> => ipcRenderer.invoke('remote:start'),
  stopRemote: (): Promise<unknown> => ipcRenderer.invoke('remote:stop'),
  listRemoteDevices: (): Promise<unknown> => ipcRenderer.invoke('remote:devices'),
  startRemotePairing: (): Promise<unknown> => ipcRenderer.invoke('remote:pair'),
  cancelRemotePairing: (): Promise<unknown> => ipcRenderer.invoke('remote:pair:cancel'),
  approveRemoteDevice: (deviceId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:device:approve', deviceId),
  revokeRemoteDevice: (deviceId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:device:revoke', deviceId),
  disconnectRemoteConnection: (connectionId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:connection:disconnect', connectionId),
  onRemoteConnections: (cb: (connections: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, connections: unknown) => cb(connections)
    ipcRenderer.on('remote:connections', handler)
    return () => ipcRenderer.off('remote:connections', handler)
  },
  tailnetStatus: (force?: boolean): Promise<unknown> =>
    ipcRenderer.invoke('tailnet:status', force === true),
  tailnetCert: (dnsName: string): Promise<unknown> => ipcRenderer.invoke('tailnet:cert', dnsName),

  /* ------------------------------------------------------ plan limits -- */
  // Read off the session's own screen, so these are keyed on a session id
  // rather than a project. `plan:unwatch` is a send, not an invoke — there is
  // nothing to return and nothing to await.
  watchPlanLimits: (sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('plan:watch', sessionId),
  refreshPlanLimits: (sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('plan:refresh', sessionId),
  unwatchPlanLimits: (sessionId: string): void => ipcRenderer.send('plan:unwatch', sessionId),
  onPlanLimits: (cb: (sessionId: string, payload: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, sessionId: string, payload: unknown) =>
      cb(sessionId, payload)
    ipcRenderer.on('plan:update', handler)
    return () => ipcRenderer.off('plan:update', handler)
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
  clearGitHubCache: (cwd?: string): void => {
    ipcRenderer.send('github:clear-cache', cwd)
  },

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
  profileStatus: (id: string): Promise<unknown> => ipcRenderer.invoke('profiles:status', id),

  /* ------------------------------------------------------ deckignore -- */

  ignoreOverview: (root: string): Promise<unknown> =>
    ipcRenderer.invoke('deckignore:overview', root),
  ignoreFilter: (root: string, paths: string[]): Promise<unknown> =>
    ipcRenderer.invoke('deckignore:filter', root, paths),
  ignoreExplain: (root: string, path: string): Promise<unknown> =>
    ipcRenderer.invoke('deckignore:explain', root, path),
  invalidateIgnore: (root: string): Promise<void> =>
    ipcRenderer.invoke('deckignore:invalidate', root),

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
  // send(), not invoke(): main registers these with ipcMain.on. An invoke
  // against an .on channel rejects with "no handler registered" — which is
  // why the browser view was created and loaded pages but was never
  // positioned or shown, so nothing ever appeared.
  browserBounds: (id: string, bounds: unknown): void => {
    ipcRenderer.send('browser:bounds', id, bounds)
  },
  browserVisible: (id: string, visible: boolean): void => {
    ipcRenderer.send('browser:visible', id, visible)
  },
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
  clearBrowserCache: (): Promise<unknown> => ipcRenderer.invoke('browser-session:clear-cache'),
  browserViewRelease: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:release', id),
  browserViewZoom: (id: string, factor: number): Promise<unknown> => ipcRenderer.invoke('browser-view:zoom', id, factor),
  browserViewDevtools: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:devtools', id),
  browserViewRecord: (id: string, on: boolean): Promise<unknown> => ipcRenderer.invoke('browser-view:record', id, on),
  debugDiagnostics: (): Promise<unknown> => ipcRenderer.invoke('debug:diagnostics'),
  debugIpcLog: (): Promise<unknown> => ipcRenderer.invoke('debug:ipc-log'),
  debugSubscribe: (): Promise<unknown> => ipcRenderer.invoke('debug:subscribe'),
  logStatus: (): Promise<unknown> => ipcRenderer.invoke('log:status'),
  openLogFolder: (): Promise<unknown> => ipcRenderer.invoke('log:open-folder'),

  /* ---------------------------------------------- browser (real names) -- */

  browserClaim: (id: string): Promise<unknown> => ipcRenderer.invoke('browser-view:claim', id),
  browserRelease: (id: string): Promise<void> => ipcRenderer.invoke('browser-view:release', id),
  browserZoom: (id: string, factor: number | null): Promise<number> =>
    ipcRenderer.invoke('browser-view:zoom', id, factor),
  browserDevtools: (id: string): Promise<void> => ipcRenderer.invoke('browser-view:devtools', id),
  browserScreenshot: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:screenshot', id),
  browserRevealScreenshot: (path: string): Promise<void> =>
    ipcRenderer.invoke('browser-view:reveal', path),
  browserUserAgent: (id: string, ua: string | null): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:user-agent', id, ua),
  browserRecord: (id: string, on: boolean): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:record', id, on),
  browserRecordClear: (id: string): Promise<unknown> =>
    ipcRenderer.invoke('browser-view:record-clear', id),
  browserClearCookies: (): Promise<unknown> => ipcRenderer.invoke('browser-session:clear-cookies'),
  browserClearStorage: (): Promise<unknown> => ipcRenderer.invoke('browser-session:clear-storage'),
  browserClearCache: (): Promise<unknown> => ipcRenderer.invoke('browser-session:clear-cache'),

  // No main-process emitter exists for these two yet, so they never fire. They
  // are still real subscriptions returning a real unsubscribe: the workspace
  // calls them on mount, and returning undefined crashed the whole panel.
  onBrowserProgress: (cb: (id: string, progress: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, p: unknown) => cb(id, p)
    ipcRenderer.on('browser:progress', handler)
    return () => ipcRenderer.off('browser:progress', handler)
  },
  onBrowserRecording: (cb: (id: string, state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, st: unknown) => cb(id, st)
    ipcRenderer.on('browser:recording', handler)
    return () => ipcRenderer.off('browser:recording', handler)
  },

  /* -------------------------------------------------- mcp (real names) -- */

  listMcpServers: (projectPath?: string | null): Promise<unknown> =>
    ipcRenderer.invoke('mcp:list', projectPath),
  connectMcpServer: (id: string): Promise<unknown> => ipcRenderer.invoke('mcp:connect', id),
  disconnectMcpServer: (id: string): Promise<unknown> => ipcRenderer.invoke('mcp:disconnect', id),
  mcpInventory: (id: string): Promise<unknown> => ipcRenderer.invoke('mcp:inventory', id),
  callMcpTool: (id: string, tool: string, args: unknown): Promise<unknown> =>
    ipcRenderer.invoke('mcp:call', id, tool, args),
  onMcpState: (cb: (status: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, status: unknown) => cb(status)
    ipcRenderer.on('mcp:state', handler)
    return () => ipcRenderer.off('mcp:state', handler)
  },

  /* ------------------------------------------- debug, help, hooks, profiles -- */

  about: (): Promise<unknown> => ipcRenderer.invoke('settings:about'),
  hookServerInfo: (): Promise<unknown> => ipcRenderer.invoke('hooks:server'),
  setProjectDefaultProfile: (projectPath: string, id: string | null): Promise<unknown> =>
    ipcRenderer.invoke('profiles:set-project-default', projectPath, id),

  ipcLog: (): Promise<unknown> => ipcRenderer.invoke('debug:ipc-log'),
  clearIpcLog: (): Promise<unknown> => ipcRenderer.invoke('debug:ipc-clear'),
  diagnostics: (): Promise<unknown> => ipcRenderer.invoke('debug:diagnostics'),
  diagnosticsText: (): Promise<unknown> => ipcRenderer.invoke('debug:diagnostics-text'),
  subscribeDebug: (): Promise<unknown> => ipcRenderer.invoke('debug:subscribe'),
  unsubscribeDebug: (): Promise<unknown> => ipcRenderer.invoke('debug:unsubscribe'),
  recentLog: (lines?: number): Promise<unknown> => ipcRenderer.invoke('log:recent', lines),
  clearLog: (): Promise<unknown> => ipcRenderer.invoke('log:clear'),
  onIpcCall: (cb: (entry: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, entry: unknown) => cb(entry)
    ipcRenderer.on('debug:ipc-call', handler)
    return () => ipcRenderer.off('debug:ipc-call', handler)
  },

  /* ------------------------------------------ setup & browser cookies -- */

  setupStatus: (): Promise<unknown> => ipcRenderer.invoke('setup:status'),

  browserCookieSources: (): Promise<unknown> => ipcRenderer.invoke('cookie-import:sources'),
  browserCookieImportStatus: (): Promise<unknown> => ipcRenderer.invoke('cookie-import:status'),
  importBrowserCookies: (request?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('cookie-import:run', request),
  clearImportedCookies: (): Promise<unknown> => ipcRenderer.invoke('cookie-import:clear'),

  browserIsolationKey: (tabKey?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-isolation:key', tabKey),
  browserIsolationDispose: (partition?: unknown): Promise<unknown> =>
    ipcRenderer.invoke('browser-isolation:dispose', partition),
  browserIsolationCount: (): Promise<unknown> => ipcRenderer.invoke('browser-isolation:count'),

  /** Menu items are commands; App maps them to the same handlers as the keys. */
  onMenuCommand: (cb: (command: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, command: string) => cb(command)
    ipcRenderer.on('menu:command', handler)
    return () => ipcRenderer.off('menu:command', handler)
  },

  /* ------------------------------------------------------------ chat -- */

  loadChat: (request: { cwd?: string; transcriptPath?: string }): Promise<unknown> =>
    ipcRenderer.invoke('chat:load', request),
  tailChat: (request: { cwd?: string; transcriptPath?: string }): Promise<unknown> =>
    ipcRenderer.invoke('chat:tail', request),
  // send(), not invoke(): 'chat:close' is an ipcMain.on channel. An invoke here
  // would reject and leak a file reader per session.
  closeChat: (transcriptPath: string): void => {
    ipcRenderer.send('chat:close', transcriptPath)
  },

  /** Ports actually listening on this machine, for the browser start page. */
  devPorts: (force?: boolean): Promise<unknown> => ipcRenderer.invoke('dev:ports', force === true),
  readAgentControls: (request: { sessionId?: string; cwd?: string }): Promise<unknown> =>
    ipcRenderer.invoke('agent:controls:read', request),
  applyAgentControl: (request: {
    sessionId: string
    cwd?: string
    control: string
    value: string
  }): Promise<unknown> => ipcRenderer.invoke('agent:controls:apply', request),

  listBrowsers: (): Promise<unknown> => ipcRenderer.invoke('chrome-import:browsers'),
  scanBrowserTabs: (browserId?: string): Promise<unknown> =>
    ipcRenderer.invoke('chrome-import:scan', browserId),
}

contextBridge.exposeInMainWorld('deck', api)

export type DeckBridge = typeof api
