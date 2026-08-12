/** Shared contract between the main process and the renderer. */

/** Which agent CLI a session is running. */
export type ProviderId = 'claude' | 'codex' | 'gemini' | 'shell'

/**
 * Live state of a session, surfaced as the coloured dot on its tab.
 * Derived in the renderer from output patterns and process state.
 */
export type SessionStatus = 'idle' | 'working' | 'waiting' | 'input' | 'completed' | 'exited'

export interface SessionMeta {
  id: string
  /** Absolute path to the project folder this session runs in. */
  cwd: string
  /** Folder name, used as the tab label until a better title is derived. */
  title: string
  /** Which agent CLI this session is running. */
  provider: ProviderId
  /** Set once the underlying process exits. */
  exitCode: number | null
  createdAt: number
}

export interface CreateSessionInput {
  cwd: string
  cols: number
  rows: number
  /** Defaults to 'claude' when the CLI is installed, otherwise 'shell'. */
  provider?: ProviderId
  /** Continue the most recent session in this folder instead of starting fresh. */
  resume?: boolean
  /** Which agent profile (isolated login) to run as. Null uses the default. */
  profileId?: string | null
}

export interface BrandInfo {
  name: string
  tagline: string
}

/** Everything the renderer may call, exposed by the preload bridge. */
export interface Preferences {
  theme: 'dark' | 'light' | 'system'
  defaultProvider: ProviderId
  restoreSessions: boolean
  notifyOnComplete: boolean
}

export interface PersistedProject {
  path: string
  provider?: ProviderId
  lastOpenedAt: number
}

export interface PawlApi {
  getBrand(): Promise<BrandInfo>
  detectProviders(): Promise<Record<ProviderId, boolean>>
  listProjects(): Promise<PersistedProject[]>
  addProject(path: string): Promise<PersistedProject>
  removeProject(path: string): Promise<void>
  getPreferences(): Promise<Preferences>
  setPreferences(patch: Partial<Preferences>): Promise<Preferences>
  pickProjectFolder(): Promise<string | null>
  createSession(input: CreateSessionInput): Promise<SessionMeta>
  writeToSession(id: string, data: string): void
  resizeSession(id: string, cols: number, rows: number): void
  getScrollback(id: string): Promise<string>
  killSession(id: string): Promise<void>
  listSessions(): Promise<SessionMeta[]>
  /** Listeners all return an unsubscribe function. */
  onSessionData(cb: (id: string, data: string) => void): () => void
  onSessionExit(cb: (id: string, exitCode: number) => void): () => void
  onSessionStatus(cb: (id: string, status: SessionStatus) => void): () => void

  // Feature modules. These cross the bridge as `unknown` and each consumer
  // narrows to its own module's types — the main-process modules own those
  // definitions, and duplicating them here would let the two drift apart.
  getProjectCost(cwd: string): Promise<unknown>
  getSessionCost(transcriptPath: string): Promise<unknown>
  listSessionTranscripts(cwd: string): Promise<unknown>
  watchProjectCost(cwd: string): Promise<unknown>
  unwatchProjectCost(cwd: string): Promise<void>
  getModelPricing(model: string): Promise<unknown>
  formatCost(value: number): Promise<string>
  onCostUpdate(cb: (summary: unknown) => void): () => void

  gitStatus(cwd: string): Promise<unknown>
  gitDiff(cwd: string, path: string, options?: { staged?: boolean; untracked?: boolean }): Promise<string>
  watchGit(cwd: string): Promise<unknown>
  unwatchGit(cwd: string): void
  onGitStatus(cb: (cwd: string, status: unknown) => void): () => void

  listDir(root: string, relDir: string, options?: { showIgnored?: boolean }): Promise<unknown>
  readFile(root: string, relPath: string): Promise<unknown>
  searchProjectFiles(request: { root: string; refresh?: boolean; limit?: number }): Promise<unknown>
  cancelProjectFileSearch(): Promise<void>
  invalidateProjectFiles(root?: string): Promise<void>

  loadBoard(projectPath: string): Promise<unknown>
  saveBoard(projectPath: string, board: unknown): Promise<void>

  getSessionInsights(transcriptPath: string): Promise<unknown>
  getLatestSessionInsights(cwd: string): Promise<unknown>
  listSessionInsights(cwd: string): Promise<unknown>

  githubOverview(cwd: string): Promise<unknown>
  githubRefresh(cwd: string): Promise<unknown>
  githubRepo(cwd: string): Promise<unknown>
  clearGitHubCache(cwd?: string): Promise<void>

  scanReadiness(projectPath: string): Promise<unknown>
  applyReadinessFix(projectPath: string, checkId: string): Promise<unknown>

  checkPrerequisites(): Promise<unknown>


  getSettings(): Promise<unknown>
  setSettings(patch: Record<string, unknown>): Promise<unknown>
  resetSettings(): Promise<unknown>
  settingsPaths(): Promise<unknown>
  openSettingsPath(key: string): Promise<unknown>
  appAbout(): Promise<unknown>
  clearBrowserData(): Promise<unknown>
  browserSessionInfo(): Promise<unknown>
  browserCookies(filter?: unknown): Promise<unknown>
  clearBrowserCookies(): Promise<unknown>
  clearBrowserCache(): Promise<unknown>
  clearBrowserStorage(): Promise<unknown>
  browserViewClaim(request: unknown): Promise<unknown>
  browserViewRelease(id: string): Promise<unknown>
  browserViewReveal(request: unknown): Promise<unknown>
  browserViewZoom(id: string, factor: number): Promise<unknown>
  browserViewUserAgent(id: string, ua: string | null): Promise<unknown>
  browserViewDevtools(id: string): Promise<unknown>
  browserViewScreenshot(id: string): Promise<unknown>
  browserViewRecord(id: string, on: boolean): Promise<unknown>
  browserViewRecordClear(id: string): Promise<unknown>
  debugAbout(): Promise<unknown>
  debugDiagnostics(): Promise<unknown>
  debugDiagnosticsText(): Promise<unknown>
  debugIpcLog(): Promise<unknown>
  debugIpcClear(): Promise<unknown>
  debugSubscribe(): Promise<unknown>
  debugUnsubscribe(): Promise<unknown>
  logRecent(lines?: number): Promise<unknown>
  logStatus(): Promise<unknown>
  logClear(): Promise<unknown>
  openLogFolder(): Promise<unknown>

  loadDashboard(projectPath: string): Promise<unknown>
  saveDashboard(projectPath: string, layout: unknown): Promise<void>
  clearDashboard(projectPath: string): Promise<void>
}

declare global {
  interface Window {
    pawl: PawlApi
  }
}
