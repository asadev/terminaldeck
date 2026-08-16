import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import type { SessionMeta, SessionStatus } from '@shared/types'

export interface Project {
  /** Absolute path — also the identity of the project. */
  path: string
  name: string
}

export interface Session extends SessionMeta {
  projectPath: string
  status: SessionStatus
  /**
   * Epoch ms this window first saw the session in its current status.
   *
   * Added for the Overview board, which has to answer "how long has this one
   * been waiting on you?" — the question the whole page exists for. Nothing
   * else in the app can answer it: the main process broadcasts `session:status`
   * on *change* and carries no timestamp, so the moment a status began is only
   * ever observable at the instant it arrives, and it has to be written down
   * then or it is gone.
   *
   * It is honest about what it is: the moment *this window* observed the state,
   * not the moment the agent entered it. For a session that changed status
   * while the app was running those are the same. For one restored at launch,
   * or one a phone started before this window opened, this is the launch or
   * arrival time and the board says "started" rather than claiming a duration
   * it cannot know. See `statusObserved` in `dashboard/board.ts`.
   */
  statusSince: number
}

interface StoreValue {
  projects: Project[]
  sessions: Session[]
  activeSessionId: string | null
  addProject(path: string): Project
  removeProject(path: string): void
  /**
   * Add a session to the list.
   *
   * `focus` defaults to true because the usual caller is the click that just
   * created it. A session this window did not ask for — one started from a
   * phone — passes false: it must appear, but it must not pull the user out of
   * whatever they were typing into.
   */
  addSession(meta: SessionMeta, options?: { focus?: boolean }): void
  removeSession(id: string): void
  setActiveSession(id: string | null): void
  setSessionStatus(id: string, status: SessionStatus): void
  /**
   * Rename a session, when something better than the folder name turns up.
   *
   * Ignored when the name has not actually changed, so a title derived on
   * every chunk of output does not re-render the sidebar on every chunk.
   */
  setSessionTitle(id: string, title: string): void
  sessionsForProject(path: string): Session[]
}

const StoreContext = createContext<StoreValue | null>(null)

function folderName(path: string): string {
  const parts = path.split('/').filter(Boolean)
  return parts[parts.length - 1] ?? path
}

export function StoreProvider({ children }: { children: ReactNode }) {
  const [projects, setProjects] = useState<Project[]>([])
  const [sessions, setSessions] = useState<Session[]>([])
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)

  const addProject = useCallback((path: string): Project => {
    const project: Project = { path, name: folderName(path) }
    setProjects((prev) => (prev.some((p) => p.path === path) ? prev : [...prev, project]))
    return project
  }, [])

  const removeProject = useCallback((path: string) => {
    setProjects((prev) => prev.filter((p) => p.path !== path))
    setSessions((prev) => {
      // Kill the processes too, or they linger with no way to reach them.
      for (const s of prev.filter((x) => x.projectPath === path)) void window.deck.killSession(s.id)
      return prev.filter((s) => s.projectPath !== path)
    })
    void window.deck.removeProject(path)
  }, [])

  const addSession = useCallback((meta: SessionMeta, options?: { focus?: boolean }) => {
    // `statusSince` starts now rather than at `meta.createdAt`: the status is
    // this window's own assumption of `idle`, not something the session
    // reported, and dating an assumption back to a process that may have
    // started hours ago on another device would invent a duration.
    const session: Session = { ...meta, projectPath: meta.cwd, status: 'idle', statusSince: Date.now() }
    // Idempotent: `session:created` and this window's own `createSession` can
    // both name the same session if the main process ever broadcasts more
    // widely, and two rows for one pty is worse than a missed one.
    setSessions((prev) => (prev.some((s) => s.id === meta.id) ? prev : [...prev, session]))
    if (options?.focus !== false) setActiveSessionId(meta.id)
  }, [])

  const removeSession = useCallback((id: string) => {
    setSessions((prev) => {
      const next = prev.filter((s) => s.id !== id)
      setActiveSessionId((current) => {
        if (current !== id) return current
        // Fall back to the neighbouring tab, mirroring editor behaviour.
        const idx = prev.findIndex((s) => s.id === id)
        return next[idx]?.id ?? next[idx - 1]?.id ?? null
      })
      return next
    })
  }, [])

  /**
   * Record a status, and when it started.
   *
   * Guarded on a real change, the way `setSessionTitle` below already is, for
   * two reasons rather than one. The cheap reason is renders: the main process
   * re-broadcasts a status whenever a tracker settles on the same answer twice,
   * and mapping unconditionally rebuilt the array — and every consumer's memo —
   * for a no-op. The load-bearing reason is `statusSince`: a re-broadcast of
   * the state a session is *already* in must not restart its clock, or a
   * session that has been blocked on you for forty minutes reads as one that
   * has been blocked for four seconds, which is the exact number the Overview
   * board is there to show.
   */
  const setSessionStatus = useCallback((id: string, status: SessionStatus) => {
    setSessions((prev) =>
      prev.some((s) => s.id === id && s.status !== status)
        ? prev.map((s) => (s.id === id ? { ...s, status, statusSince: Date.now() } : s))
        : prev,
    )
  }, [])

  const setSessionTitle = useCallback((id: string, title: string) => {
    setSessions((prev) =>
      prev.some((s) => s.id === id && s.title !== title)
        ? prev.map((s) => (s.id === id ? { ...s, title } : s))
        : prev,
    )
  }, [])

  const sessionsForProject = useCallback(
    (path: string) => sessions.filter((s) => s.projectPath === path),
    [sessions],
  )

  const value = useMemo<StoreValue>(
    () => ({
      projects,
      sessions,
      activeSessionId,
      addProject,
      removeProject,
      addSession,
      removeSession,
      setActiveSession: setActiveSessionId,
      setSessionStatus,
      setSessionTitle,
      sessionsForProject,
    }),
    [
      projects,
      sessions,
      activeSessionId,
      addProject,
      removeProject,
      addSession,
      removeSession,
      setSessionStatus,
      setSessionTitle,
      sessionsForProject,
    ],
  )

  return <StoreContext.Provider value={value}>{children}</StoreContext.Provider>
}

export function useStore(): StoreValue {
  const ctx = useContext(StoreContext)
  if (!ctx) throw new Error('useStore must be used inside <StoreProvider>')
  return ctx
}

/**
 * The store when there is one, `null` when there is not.
 *
 * `useStore` throws, which is right for the shell: a tab bar outside the
 * provider is a wiring bug and should fail loudly. It is wrong for a component
 * that is *also* mounted on its own — the Overview board renders in
 * `renderToStaticMarkup` tests and in `.harness/`, where there is no provider
 * and no window, and a throw there is a page that will not render rather than
 * a page with less on it.
 *
 * Deliberately not `useStore()` wrapped in a try: hooks cannot be called
 * conditionally and a caught throw from a hook leaves React's hook cursor out
 * of step for the rest of the render.
 */
export function useOptionalStore(): StoreValue | null {
  return useContext(StoreContext)
}
