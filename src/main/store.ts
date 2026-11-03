import { mkdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { writeFileAtomic } from './atomic-write'
import { userDataDir } from './platform/paths'
import type { ProviderId } from '../shared/types'
/**
 * What quitting does when sessions are still running.
 *
 * Declared here rather than beside the tray that acts on it, and the reason is
 * structural rather than tidiness: `resident.ts` imports Electron's `Menu`,
 * `Tray` and `nativeImage`, and the headless build has no Electron at all. A
 * bare `import type` from this file was enough to pull that module into the
 * headless graph and fail `headless/seam.test.ts` — a type import costs nothing
 * at runtime, but the seam scanner reads the edge, and it is right to: the
 * store is reachable from `host-core.ts`, which both shells assemble.
 *
 * The store persists this value, so the store owns its shape. `resident.ts`
 * re-exports the name so nothing that already reads it from there has to move.
 */
export type QuitBehavior = 'ask' | 'keep' | 'stop'
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

/**
 * What this app has established about one Claude login, keyed by its
 * configuration directory.
 *
 * A *fact about the account*, which is the whole reason it is written down at
 * all. Everything else this feature knows lives in a per-session tracker held
 * in memory, and that is right for a screen reading — a session's screen is the
 * session's — but wrong for the two things here. Whether a login is billed
 * through a subscription, and whether its `/usage` panel has any plan limits in
 * it, are true of the login and stay true of it across every session it ever
 * runs and across every launch of this app.
 *
 * That distinction is not academic. Before this existed, "this account has no
 * limits to read" was remembered against the *session*, so five open sessions
 * each typed `/usage` into somebody's terminal to learn the same thing, and
 * quitting the app threw all five answers away and made them learn it again.
 * See `src/main/account-limits.ts`, which owns the reading and writing, and
 * `refresh` in `src/main/plan-limit.ts`, which is the side that types.
 */
export interface AccountLimitFact {
  /**
   * What Claude Code's own welcome banner said this login is billed as.
   *
   * `api` is every billing arrangement that has no rolling subscription window
   * — an API key, console billing, Bedrock, Vertex — and it is the one worth
   * knowing in advance, because those accounts have no plan limits for the CLI
   * to draw and never will. Absent until a banner has actually been read.
   */
  billing?: 'subscription' | 'api'
  /**
   * A terminal answer that a `/usage` run established, or absent.
   *
   * Only `no-limits` is kept: the panel opened, settled, and had no plan-limit
   * section in it. That cannot change by being asked again, so it is the one
   * answer worth spending a person's terminal on exactly once. A reading is
   * never recorded here — a reading blocks nothing, by design.
   */
  answer?: 'no-limits'
  /** When this was last written, so a stale record can be reasoned about. */
  at: number
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
  /**
   * What is known about each Claude login, keyed by its configuration directory.
   *
   * Additive in exactly the way `openSessions` above is, and `version` is
   * untouched for the same reason: a `state.json` written by an older build
   * simply has no such key and loads as an empty map, which is the honest
   * starting state — nothing has been established about any account yet.
   *
   * Keyed by the configuration directory because that *is* the account
   * everywhere else in this app — `UsageAccountRef.configDir` in
   * `usage-window.ts`, `Profile.configDir` in `profiles.ts` — so a record
   * written under one name cannot fail to be found under another.
   */
  accountLimits?: Record<string, AccountLimitFact>
  /**
   * What quitting does to sessions that are still running.
   *
   * Additive and absent by default, exactly as `openSessions` above is, so a
   * `state.json` from an older build loads as `'ask'` and `version` is untouched
   * — there is nothing here a previous build could misread.
   *
   * Deliberately **not** in {@link Preferences}. That interface is copied in
   * four places — here, `src/shared/types.ts`, `src/renderer/preferences.ts` and
   * the settings schema — because every field of it is a control a person sets
   * in Settings. This is not one: it is the answer to a question the app asks at
   * the moment it matters, with the checkbox on that dialog as the only way to
   * set it. Putting it in `Preferences` would have meant a fifth copy and a
   * Settings row for something already decided in front of the person.
   */
  quitBehavior?: QuitBehavior
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
 * A parsed `accountLimits` map, or nothing.
 *
 * Deliberately shallow: it proves the container is an object of objects and
 * leaves the individual fields to be read defensively where they are used. A
 * deep validator here would be a second copy of the shape, which is how two
 * copies come to disagree.
 */
function isFactMap(raw: unknown): raw is Record<string, AccountLimitFact> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return false
  return Object.values(raw).every((value) => typeof value === 'object' && value !== null)
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
        // A hand-edited or half-written map must not take the launch down with
        // it, and must not be trusted into the gate that decides whether this
        // app types into somebody's terminal. Anything that is not a plain
        // object is read as "nothing established", which is the safe direction:
        // it costs one `/usage`, where trusting rubbish could cost the feature.
        accountLimits: isFactMap(raw.accountLimits) ? raw.accountLimits : {},
      }
    } catch {
      // Missing or corrupt — start clean rather than crash on launch.
      return structuredClone(DEFAULTS)
    }
  }

  private persist(): void {
    try {
      mkdirSync(dirname(this.file), { recursive: true })
      // `writeFileAtomic` rather than the temp-and-rename written out here,
      // for two reasons that only bite on Windows and that this file had both
      // of. The temp name was the fixed `${file}.tmp`, so two windows of this
      // app writing state at the same time wrote the *same* temp file and one
      // truncated the other's bytes. And `rename` over a destination another
      // process holds open fails on Windows with EPERM — Defender's real-time
      // scan opening the file we just closed is enough — where POSIX `rename`
      // always succeeds. The catch below turned that into a line in a log
      // nobody reads, so on Windows a user's project list, theme and window
      // bounds could simply stop being saved with nothing on screen.
      writeFileAtomic(this.file, JSON.stringify(this.state, null, 2))
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

  /**
   * What to do about running sessions when the app is quit.
   *
   * Anything that is not one of the three known answers reads as `'ask'`. A
   * hand-edited `state.json` — or one written by a build that spells this
   * differently later — must not be able to put the app into a mode where it
   * silently keeps agents running, or silently kills them, because a string did
   * not match. Asking is the one answer that is never a surprise.
   */
  getQuitBehavior(): QuitBehavior {
    const value = this.state.quitBehavior
    return value === 'keep' || value === 'stop' ? value : 'ask'
  }

  setQuitBehavior(behavior: QuitBehavior): void {
    this.state.quitBehavior = behavior
    this.persist()
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

  /**
   * What is known about one Claude login, or null.
   *
   * Null rather than an empty record, because "nothing has been established
   * about this account" and "this account was established to have nothing" are
   * opposite answers and only the second may stop this app asking.
   */
  getAccountLimit(configDir: string): AccountLimitFact | null {
    return this.state.accountLimits?.[configDir] ?? null
  }

  /**
   * Write what has been established, merging rather than replacing.
   *
   * Merging because the two fields are learned by different means at different
   * moments — the billing off a banner that happened to be on screen, the
   * answer off a `/usage` that ran — and a writer of one must not erase the
   * other's work.
   */
  setAccountLimit(configDir: string, patch: Omit<AccountLimitFact, 'at'>): AccountLimitFact {
    const map = this.state.accountLimits ?? {}
    const next: AccountLimitFact = { ...map[configDir], ...patch, at: Date.now() }
    map[configDir] = next
    this.state.accountLimits = map
    this.persist()
    return next
  }

  /** Forget an account's record entirely — what a person pressing Check means. */
  forgetAccountLimit(configDir: string): void {
    if (!this.state.accountLimits || !(configDir in this.state.accountLimits)) return
    delete this.state.accountLimits[configDir]
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
