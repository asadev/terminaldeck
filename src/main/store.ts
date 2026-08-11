import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { app } from 'electron'
import type { ProviderId } from '../shared/types'

export interface PersistedProject {
  path: string
  /** Provider chosen for this project, overriding the global default. */
  provider?: ProviderId
  lastOpenedAt: number
}

export interface Preferences {
  theme: 'dark' | 'light' | 'system'
  defaultProvider: ProviderId
  /** Restore the previous session layout when the app starts. */
  restoreSessions: boolean
  notifyOnComplete: boolean
}

export interface PersistedState {
  version: number
  projects: PersistedProject[]
  preferences: Preferences
  windowBounds?: { width: number; height: number; x?: number; y?: number }
}

const DEFAULTS: PersistedState = {
  version: 1,
  projects: [],
  preferences: {
    theme: 'dark',
    defaultProvider: 'claude',
    restoreSessions: true,
    notifyOnComplete: true,
  },
}

/**
 * Small JSON-backed store for app state. Writes go to a temp file and are
 * renamed into place, so a crash mid-write cannot leave a truncated file
 * that would wipe the user's projects on next launch.
 */
class Store {
  private file: string
  private state: PersistedState

  constructor() {
    this.file = join(app.getPath('userData'), 'state.json')
    this.state = this.load()
  }

  private load(): PersistedState {
    try {
      const raw = JSON.parse(readFileSync(this.file, 'utf8')) as Partial<PersistedState>
      return {
        ...DEFAULTS,
        ...raw,
        preferences: { ...DEFAULTS.preferences, ...raw.preferences },
        projects: Array.isArray(raw.projects) ? raw.projects : [],
      }
    } catch {
      // Missing or corrupt — start clean rather than crash on launch.
      return structuredClone(DEFAULTS)
    }
  }

  private persist(): void {
    try {
      mkdirSync(dirname(this.file), { recursive: true })
      const tmp = `${this.file}.tmp`
      writeFileSync(tmp, JSON.stringify(this.state, null, 2), 'utf8')
      renameSync(tmp, this.file)
    } catch (err) {
      console.error('[store] failed to persist state:', err)
    }
  }

  getState(): PersistedState {
    return this.state
  }

  getPreferences(): Preferences {
    return this.state.preferences
  }

  setPreferences(patch: Partial<Preferences>): Preferences {
    this.state.preferences = { ...this.state.preferences, ...patch }
    this.persist()
    return this.state.preferences
  }

  getProjects(): PersistedProject[] {
    return [...this.state.projects].sort((a, b) => b.lastOpenedAt - a.lastOpenedAt)
  }

  addProject(path: string): PersistedProject {
    const existing = this.state.projects.find((p) => p.path === path)
    if (existing) {
      existing.lastOpenedAt = Date.now()
      this.persist()
      return existing
    }
    const project: PersistedProject = { path, lastOpenedAt: Date.now() }
    this.state.projects.push(project)
    this.persist()
    return project
  }

  removeProject(path: string): void {
    this.state.projects = this.state.projects.filter((p) => p.path !== path)
    this.persist()
  }

  setWindowBounds(bounds: PersistedState['windowBounds']): void {
    this.state.windowBounds = bounds
    this.persist()
  }
}

let instance: Store | null = null

/** Constructed lazily — app.getPath() is only valid after the app is ready. */
export function store(): Store {
  if (!instance) instance = new Store()
  return instance
}
