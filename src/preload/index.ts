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

  /**
   * A session started somewhere other than this window — today, from a phone.
   *
   * Never fires for a session this window asked for: that one arrives as the
   * return value of `createSession`, and a consumer adding a tab on both would
   * show the session twice.
   */
  onSessionCreated: (cb: (meta: SessionMeta) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, meta: SessionMeta) => cb(meta)
    ipcRenderer.on('session:created', handler)
    return () => ipcRenderer.off('session:created', handler)
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

  /* ---------------------------------------------------------- updates -- */
  // Four requests and one push. `update:get` is deliberately a different string
  // from the push channel `update:state`: giving a request and an event the
  // same name is how the next handle/send mix-up gets written.
  updateStatus: (): Promise<unknown> => ipcRenderer.invoke('update:get'),
  checkForUpdate: (): Promise<unknown> => ipcRenderer.invoke('update:check'),
  downloadUpdate: (): Promise<unknown> => ipcRenderer.invoke('update:download'),
  installUpdate: (): Promise<unknown> => ipcRenderer.invoke('update:install'),
  onUpdateState: (cb: (state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, state: unknown) => cb(state)
    ipcRenderer.on('update:state', handler)
    return () => ipcRenderer.off('update:state', handler)
  },

  /* ----------------------------------------------------------- remote -- */
  // Every one of these is an ipcMain.handle, so every one is invoke(). The
  // remote module registers no send-channel at all, deliberately: each call
  // wants an answer, and a send that routes nowhere fails silently.
  remoteStatus: (): Promise<unknown> => ipcRenderer.invoke('remote:status'),
  startRemote: (): Promise<unknown> => ipcRenderer.invoke('remote:start'),
  stopRemote: (): Promise<unknown> => ipcRenderer.invoke('remote:stop'),
  listRemoteDevices: (): Promise<unknown> => ipcRenderer.invoke('remote:devices'),
  /**
   * The minted code, forwarded whole.
   *
   * Whole matters. The answer is `{ token, expiresAt, findable }`, and
   * `findable` is the field that says whether anything can look those digits up
   * at the rendezvous — the difference between a code a phone can type and six
   * digits only the tailnet-served browser client can redeem. It was computed in
   * the main process and dropped on the way out once already, and the result was
   * a panel that showed a working-looking code and a countdown for a pairing
   * that could not happen.
   *
   * So nothing here picks fields out of it. Everything on this bridge crosses as
   * `unknown` and is narrowed on the far side precisely so that a field added in
   * the main process reaches the renderer without a second edit here — a preload
   * that repacked this object would be the place the next one goes missing.
   */
  startRemotePairing: (): Promise<unknown> => ipcRenderer.invoke('remote:pair'),
  cancelRemotePairing: (): Promise<unknown> => ipcRenderer.invoke('remote:pair:cancel'),
  approveRemoteDevice: (deviceId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:device:approve', deviceId),
  revokeRemoteDevice: (deviceId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:device:revoke', deviceId),
  disconnectRemoteConnection: (connectionId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:connection:disconnect', connectionId),
  // Both ids, because a tunnel only exists inside the connection that opened
  // it: two phones can each have a page open on port 3000, and a stop that
  // named only the port would take down the wrong one.
  stopRemoteTunnel: (connectionId: string, tunnelId: string): Promise<unknown> =>
    ipcRenderer.invoke('remote:tunnel:stop', connectionId, tunnelId),
  /**
   * Which folders each device may start a session in, and the one write that
   * changes them.
   *
   * `setDeviceFolders` sends the **whole** list rather than an add or a remove,
   * and answers with what the main process stored. The panel then draws the
   * answer instead of what it asked for, which is the only version that cannot
   * show a folder that was dropped on the way in for being relative or a
   * duplicate of one already there.
   *
   * A device that has never been given a list does not appear in the reply at
   * all, and that absence is load-bearing: it is the difference between "nobody
   * has chosen for this phone, so it gets what this desktop has open" and
   * "somebody removed every folder, so it can start nothing". Flattening the two
   * would describe a phone that works as one that is dead, or the reverse.
   */
  listDeviceFolders: (): Promise<unknown> => ipcRenderer.invoke('remote:folders'),
  setDeviceFolders: (deviceId: string, folders: string[]): Promise<unknown> =>
    ipcRenderer.invoke('remote:folders:set', deviceId, folders),
  onRemoteConnections: (cb: (connections: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, connections: unknown) => cb(connections)
    ipcRenderer.on('remote:connections', handler)
    return () => ipcRenderer.off('remote:connections', handler)
  },
  /* --------------------------------------------------------- machines -- */
  /*
   * The guest half of remote access: the machines *this* desktop reaches out
   * to, rather than the devices that reach in. Same shape as the block above —
   * every one is an `ipcMain.handle`, so every one is `invoke()` — with two
   * pushed channels, because a session's output and a link coming and going are
   * events nobody asked a question to get.
   */
  listMachines: (): Promise<unknown> => ipcRenderer.invoke('machines:list'),
  startMachineCode: (): Promise<unknown> => ipcRenderer.invoke('machines:code'),
  cancelMachineCode: (): Promise<unknown> => ipcRenderer.invoke('machines:code:cancel'),
  pairMachine: (code: string): Promise<unknown> => ipcRenderer.invoke('machines:pair', code),
  forgetMachine: (id: string): Promise<unknown> => ipcRenderer.invoke('machines:forget', id),
  renameMachine: (id: string, name: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:rename', id, name),
  connectMachine: (id: string): Promise<unknown> => ipcRenderer.invoke('machines:connect', id),
  disconnectMachine: (id: string): Promise<unknown> => ipcRenderer.invoke('machines:disconnect', id),
  attachMachineSession: (id: string, sessionId: string, cols: number, rows: number): Promise<unknown> =>
    ipcRenderer.invoke('machines:attach', id, sessionId, cols, rows),
  detachMachineSession: (id: string, sessionId: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:detach', id, sessionId),
  writeToMachineSession: (id: string, sessionId: string, data: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:input', id, sessionId, data),
  resizeMachineSession: (id: string, sessionId: string, cols: number, rows: number): Promise<unknown> =>
    ipcRenderer.invoke('machines:resize', id, sessionId, cols, rows),
  createMachineSession: (id: string, cwd?: string, provider?: string): Promise<unknown> =>
    ipcRenderer.invoke('machines:create', id, cwd ?? '', provider ?? ''),
  onMachinesState: (cb: (view: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, view: unknown) => cb(view)
    ipcRenderer.on('machines:state', handler)
    return () => ipcRenderer.off('machines:state', handler)
  },
  onMachineOutput: (cb: (chunk: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, chunk: unknown) => cb(chunk)
    ipcRenderer.on('machines:output', handler)
    return () => ipcRenderer.off('machines:output', handler)
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

  /* ------------------------------------------------------ github sign-in -- */

  githubAuthStatus: (cwd?: string): Promise<unknown> =>
    ipcRenderer.invoke('github:auth-status', cwd),
  githubConnect: (): Promise<unknown> => ipcRenderer.invoke('github:auth-connect'),
  /**
   * Resolves when the sign-in the user is part-way through finishes — the code
   * being entered, refused, or expiring. It is deliberately a long-lived
   * `invoke` rather than the renderer asking "done yet?" on a timer: nothing
   * about a device-flow sign-in is knowable early, so a poll would be a second
   * clock stacked on top of the one the main process already has to run.
   */
  githubAwaitConnect: (cwd?: string): Promise<unknown> =>
    ipcRenderer.invoke('github:auth-await', cwd),
  githubCancelConnect: (cwd?: string): Promise<unknown> =>
    ipcRenderer.invoke('github:auth-cancel', cwd),
  githubDisconnect: (cwd?: string): Promise<unknown> =>
    ipcRenderer.invoke('github:auth-disconnect', cwd),

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

  /* ------------------------------------------------------ dev servers -- */
  //
  // Starting the dev server behind a localhost link, for the case Asad
  // described: the link is listed, you tap it, and nothing answers because the
  // dev environment is not running.
  //
  // `listDevServers` takes no folder and `startDevServer` takes one the main
  // process must already have open — the window cannot name an arbitrary path,
  // so this channel cannot be used to hunt for `package.json` files across the
  // disk. State arrives on a push rather than a poll: a boot takes as long as
  // it takes, and a timer asking "is it up yet" is the thing this app's own
  // rules say not to write.
  listDevServers: (): Promise<unknown> => ipcRenderer.invoke('dev:server:list'),
  startDevServer: (folder: string): Promise<unknown> =>
    ipcRenderer.invoke('dev:server:start', folder),
  onDevServerState: (cb: (state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, state: unknown) => cb(state)
    ipcRenderer.on('dev:server:state', handler)
    return () => ipcRenderer.off('dev:server:state', handler)
  },

  /* ------------------------------------------------------- artifacts -- */
  //
  // What the agents in a project actually wrote, read back out of the
  // transcripts' own `Write`/`Edit`/`NotebookEdit` tool calls.
  //
  // `scope` is not a convenience. A project's own transcripts can contain zero
  // file writes while hundreds of real writes *into that folder* sit under a
  // parent workspace's transcripts, because the agents were launched from the
  // parent and reached in — measured here as 0 artifacts under `scope: 'project'`
  // against 75 under `scope: 'all'` for this very repository. So the wider scope
  // has to be reachable, and the narrow one stays the default because it is the
  // cheap one (8ms against ~1.1s).
  listArtifacts: (request: { cwd: string; scope?: 'project' | 'all' }): Promise<unknown> =>
    ipcRenderer.invoke('artifacts:list', request),
  artifactChanges: (request: {
    cwd: string
    relPath: string
    scope?: 'project' | 'all'
  }): Promise<unknown> => ipcRenderer.invoke('artifacts:changes', request),
  projectAlerts: (projectPath: string): Promise<unknown> =>
    ipcRenderer.invoke('alerts:project', projectPath),

  /* --------------------------------------------------------- profiles -- */

  listProfiles: (): Promise<unknown> => ipcRenderer.invoke('profiles:list'),
  /**
   * Which agents an account can belong to, and the sentence for each one that
   * cannot hold a second login.
   *
   * `profiles:account-providers` was registered in the main process and called
   * by nobody, because there was no method here to call it with — so the Add an
   * account form had no way to ask the question and every account it made was a
   * Claude one. That is the whole of the bug reported as *"if I add any new
   * account it just redirects me to claude only"*: not a wrong answer, an
   * unasked question.
   */
  accountProviders: (): Promise<unknown> => ipcRenderer.invoke('profiles:account-providers'),
  /**
   * The options object is forwarded, exactly as `deleteProfile`'s is and for the
   * same reason it had to be fixed there: `profiles:create` reads `provider` off
   * it and defaults to Claude when it is absent. Dropping it here would not
   * fail — it would quietly make every account a Claude account, which is
   * indistinguishable from the app ignoring the choice the user just made.
   */
  createProfile: (
    name: string,
    options?: { provider?: string; configDir?: string },
  ): Promise<unknown> => ipcRenderer.invoke('profiles:create', name, options),
  renameProfile: (id: string, name: string): Promise<unknown> =>
    ipcRenderer.invoke('profiles:rename', id, name),
  // The options object is forwarded rather than dropped. It was not, and
  // `profiles:delete` reads `deleteFiles` off it — so a caller that asked for a
  // profile's files to be deleted got the profile removed from the list and the
  // directory left on disk, with a confirmation that said otherwise.
  deleteProfile: (id: string, options?: { deleteFiles?: boolean }): Promise<unknown> =>
    ipcRenderer.invoke('profiles:delete', id, options),
  /*
   * One argument, an object, because that is what `profiles:resolve` reads:
   * `{ sessionProfileId?, projectPath? }`. The signature here used to be
   * `(projectPath: string, sessionChoice?: string)`, which no caller ever used
   * and which would have resolved the *global* default for every project — the
   * handler takes anything that is not an object as no input at all.
   */
  resolveProfile: (input: {
    projectPath?: string | null
    sessionProfileId?: string | null
  }): Promise<unknown> => ipcRenderer.invoke('profiles:resolve', input),
  setDefaultProfile: (id: string | null): Promise<unknown> =>
    ipcRenderer.invoke('profiles:set-default', id),
  profileStatus: (id: string): Promise<unknown> => ipcRenderer.invoke('profiles:status', id),
  /**
   * Whether an account is signed in, read from the agent's own CLI under that
   * account's config directory. `refresh` skips the main process's short memo,
   * which is what a "Check again" button passes.
   */
  profileSignIn: (id: string, options?: { refresh?: boolean }): Promise<unknown> =>
    ipcRenderer.invoke('profiles:signin', id, options),

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

  // Notifications: what the OS will admit to, and the way out. A renderer's
  // own `Notification.permission` is always `granted` and tells you nothing.
  notificationSupport: (): Promise<unknown> => ipcRenderer.invoke('notifications:support'),
  openNotificationSettings: (): Promise<unknown> => ipcRenderer.invoke('notifications:open-settings'),
  notificationDelivery: (sinceMs: number): Promise<unknown> =>
    ipcRenderer.invoke('notifications:delivery', sinceMs),

  /* ------------------------------------------------------------- power -- */
  // Keeping the machine awake with the lid shut. Two invokes and one push, and
  // the push channel is a different string from the request channel on purpose
  // — an event and a request sharing a name is how the next handle/send mix-up
  // gets written.
  //
  // `setLidAwake` can put the operating system's own password dialog on screen,
  // so — like `importBrowserCookies` — nothing calls it except a control the
  // user pressed. It is also the slowest call in this file by a wide margin:
  // the clock runs while a person finds their password, so a caller must not
  // put a timeout on it.
  lidAwakeStatus: (): Promise<unknown> => ipcRenderer.invoke('power:lid-awake:get'),
  setLidAwake: (on: boolean): Promise<unknown> => ipcRenderer.invoke('power:lid-awake:set', on),
  onLidAwakeState: (cb: (state: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, state: unknown) => cb(state)
    ipcRenderer.on('power:lid-awake:state', handler)
    return () => ipcRenderer.off('power:lid-awake:state', handler)
  },

  /* --------------------------------------------------------------- wsl -- */
  // Which Linux distributions this PC has, and which one sessions in a Linux
  // folder run inside. Two invokes and no push: the set of installed
  // distributions changes when a person installs one, which is not an event
  // this app can hear and not one worth a timer.
  //
  // `wslStatus(true)` is the Refresh button and re-reads the machine; without
  // the flag the main process answers from the reading it already took at
  // launch, so opening the pane costs nothing.
  wslStatus: (force?: boolean): Promise<unknown> => ipcRenderer.invoke('wsl:status', force === true),
  chooseWslDistro: (distro: string | null): Promise<unknown> =>
    ipcRenderer.invoke('wsl:choose', distro),

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
  // The request carries its own project path rather than taking one alongside,
  // because two of the three MCP scopes are addressed by the working directory
  // the CLI runs in — so it is part of what is being asked for, not context.
  addMcpServer: (request: unknown): Promise<unknown> => ipcRenderer.invoke('mcp:add', request),
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

  /**
   * Which commands the application menu must stop offering.
   *
   * The other direction of `onMenuCommand`, and the reason it exists: the menu
   * is built in the main process and the feature store lives in the renderer,
   * so without this the menu bar is the one surface in the app that cannot ask
   * whether a feature is installed. Uninstall the split view and "Split the
   * Window ⌘D" stayed in View — a control that looks like the feature is still
   * there.
   *
   * The **whole** list every time, like `setDeviceFolders`, rather than a hide
   * and an unhide: the menu is rebuilt from it, so a message that went missing
   * costs one stale menu rather than a menu that drifts further from the truth
   * with every install. `send`, not `invoke` — nothing comes back, and the
   * window is telling rather than asking.
   */
  setHiddenMenuCommands: (commands: string[]): void => {
    ipcRenderer.send('menu:hidden-commands', commands)
  },

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
