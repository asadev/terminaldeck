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
}

declare global {
  interface Window {
    pawl: PawlApi
  }
}
