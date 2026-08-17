import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { userDataDir } from './platform/paths'
import type { ProviderId } from '../shared/types'
import type { SavedSession } from './session-restore'

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
  /**
   * The sessions that were open, in tab order.
   *
   * Written as they open and close rather than on quit, and that is the whole
   * point: the case this exists for is "the PC restarted", where nothing gets a
   * chance to run at quit. A list that is only correct after a clean shutdown
   * is a list that is wrong exactly when it is needed.
   *
   * Additive, so an older `state.json` that has never heard of the field loads
   * as an empty list and needs no migration — which is why `version` is
   * untouched. There is nothing here a previous build could misread.
   */
  openSessions?: SavedSession[]
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
  openSessions: [],
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
    this.file = join(userDataDir(), 'state.json')
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
        openSessions: Array.isArray(raw.openSessions) ? raw.openSessions : [],
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

  /**
   * Tell me when the *set* of project folders changes.
   *
   * An event rather than something to poll, because the recorded preference on
   * this project is events over timers, and because there is nothing to poll
   * for: this class is the only writer of the list and knows exactly when it
   * moved.
   *
   * "The set", not "the list": re-opening a project already in it bumps
   * `lastOpenedAt` and reorders `getProjects()`, and that happens every time
   * somebody clicks a folder. A listener that fired on it would be a listener
   * that fires constantly and means nothing. It fires only when a folder is
   * added that was not there, or one that was there is gone.
   *
   * The one listener today is the copilot's, which holds a read grant over
   * these folders that the operating system fixed when its process started — so
   * a folder leaving this list has to reach it, and reach it *promptly*, or the
   * app would be enforcing a grant the person has already withdrawn. See
   * `copilot-session.ts`.
   *
   * Returns its own unsubscribe, the same shape every other listener in this
   * app uses, so a caller never has to hold the function it registered.
   */
  onProjectsChanged(listener: (paths: readonly string[]) => void): () => void {
    this.projectListeners.add(listener)
    return () => {
      this.projectListeners.delete(listener)
    }
  }

  private projectListeners = new Set<(paths: readonly string[]) => void>()

  /**
   * Never throws into the caller.
   *
   * The callers are `addProject` and `removeProject`, which are IPC handlers on
   * the path a person takes to open a folder. A listener that throws must not
   * turn that into a failure to open the project — the listener's job is a
   * consequence of the change, not part of it.
   */
  private announceProjects(): void {
    const paths = this.state.projects.map((project) => project.path)
    for (const listener of this.projectListeners) {
      try {
        listener(paths)
      } catch (err) {
        console.error('[store] a projects listener threw:', err)
      }
    }
  }

  addProject(path: string): PersistedProject {
    const existing = this.state.projects.find((p) => p.path === path)
    if (existing) {
      existing.lastOpenedAt = Date.now()
      this.persist()
      // Deliberately silent: the set did not change, only its order. See
      // `onProjectsChanged`.
      return existing
    }
    const project: PersistedProject = { path, lastOpenedAt: Date.now() }
    this.state.projects.push(project)
    this.persist()
    this.announceProjects()
    return project
  }

  removeProject(path: string): void {
    const before = this.state.projects.length
    this.state.projects = this.state.projects.filter((p) => p.path !== path)
    this.persist()
    if (this.state.projects.length !== before) this.announceProjects()
  }

  /**
   * The sessions that were open when this was last written, in tab order.
   *
   * A copy, because the caller is about to hand it to the restore planner and
   * a planner that could reorder the store's own array in place would change
   * what the next launch restores.
   */
  getOpenSessions(): SavedSession[] {
    return [...(this.state.openSessions ?? [])]
  }

  /**
   * Replace the remembered list wholesale.
   *
   * Whole-list rather than add/remove because the caller already holds the
   * truth — every live pty — and reconciling two copies of a list is how they
   * drift. It is a handful of small objects; rewriting all of them costs
   * nothing next to being wrong about one.
   */
  setOpenSessions(sessions: readonly SavedSession[]): void {
    this.state.openSessions = [...sessions]
    this.persist()
  }

  setWindowBounds(bounds: PersistedState['windowBounds']): void {
    this.state.windowBounds = bounds
    this.persist()
  }
}

let instance: Store | null = null

/**
 * Constructed lazily, because the directory is not known at import time in
 * either shell: Electron answers `getPath` only once the app is ready, and the
 * headless daemon installs its own answer at the top of `main()`. See
 * `platform/paths.ts`.
 */
export function store(): Store {
  if (!instance) instance = new Store()
  return instance
}
