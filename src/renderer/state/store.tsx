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
    const session: Session = { ...meta, projectPath: meta.cwd, status: 'idle' }
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

  const setSessionStatus = useCallback((id: string, status: SessionStatus) => {
    setSessions((prev) => prev.map((s) => (s.id === id ? { ...s, status } : s)))
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
