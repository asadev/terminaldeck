import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import type { SessionMeta, SessionStatus } from '@shared/types'
import { folderName } from '../session-title'

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
  /**
   * True once somebody has typed a name for this session themselves.
   *
   * It exists to make {@link withSessionTitle} stop doing something, and that
   * is the whole of the rename feature that is worth anything. `AutoTitler`
   * reads a title out of the session's own output and pushes it here on every
   * pause in that output — for the life of the session, not once at the start —
   * so without this flag a name the user typed would survive only until the
   * agent next printed its own heading, which is usually seconds. A rename that
   * is silently undone a moment later is worse than no rename at all: the app
   * then looks like it lost the name rather than like it never offered to keep
   * one.
   *
   * Optional, and absent means no. A session nobody has renamed does not carry
   * the field, so nothing else in the app has to know it exists.
   */
  namedByUser?: boolean
}

/**
 * The session list with one session retitled — or the same list, unchanged.
 *
 * Pulled out of the provider as a plain function because it is the only place
 * in this app where a *rule* about titles lives, and a rule buried in a
 * `useCallback` inside a context provider cannot be tested at all in a project
 * that deliberately has no DOM in its test setup. `store.test.ts` drives it
 * directly.
 *
 * Two callers, and they want opposite things when they disagree with what is
 * already on the session:
 *
 *   `fromUser: true`   somebody typed this into the rename field. It wins over
 *                      anything, and it latches: from here on the session is
 *                      named, and stays named.
 *
 *   `fromUser: false`  `AutoTitler` derived this from the session's own output.
 *                      It beats a folder name or an older derivation, and it
 *                      loses — completely, silently, every time — to a name the
 *                      user typed.
 *
 * Returning `sessions` unchanged rather than a rebuilt array is not a tidy-up
 * here, it is the contract with React: a derived title is offered on every
 * pause in the session's output, and mapping the array each time would rebuild
 * every consumer's memo for a no-op.
 */
export function withSessionTitle(
  sessions: Session[],
  id: string,
  title: string,
  fromUser = false,
): Session[] {
  const found = sessions.find((session) => session.id === id)
  if (!found) return sessions
  // The substance of the whole feature: an automatic title never touches a
  // session somebody has named.
  if (!fromUser && found.namedByUser) return sessions

  const named = fromUser || found.namedByUser === true
  // `=== true` on both sides, because absent and `false` are the same state and
  // a raw comparison reads them as different — which was enough on its own to
  // rebuild the whole list on every pause in a session's output, for a change
  // of `undefined` to `false` that nothing can see.
  if (found.title === title && named === (found.namedByUser === true)) return sessions

  // The flag is only ever written when it is true. A session nobody has renamed
  // keeps the shape it was created with, which is what lets the rest of the app
  // go on not knowing this field exists.
  const renamed: Session = named ? { ...found, title, namedByUser: true } : { ...found, title }
  return sessions.map((session) => (session.id === id ? renamed : session))
}

/**
 * The session list with one session standing in for another, in its place.
 *
 * Pulled out of the provider for the same reason {@link withSessionTitle} is:
 * it is a *rule*, it has edges worth driving directly, and a rule inside a
 * `useCallback` inside a context provider cannot be tested at all in a project
 * with no DOM in its test setup.
 *
 * Three edges, and all three have a wrong answer that looks reasonable:
 *
 *  - **The old id is not in the list.** Return the list unchanged rather than
 *    appending the replacement. A caller that has raced ahead of its own state
 *    would otherwise add a second row for a session the window is about to be
 *    told about anyway, and two rows for one pty is worse than a missing one.
 *  - **The new id is already in the list.** Same answer, same reason: this has
 *    already happened, and doing it twice would drop the row that is standing
 *    there correctly.
 *  - **The old session had a name somebody typed.** It carries over, flag and
 *    all. A derived name does not — see the interface note.
 *
 * `status` starts at `idle` and `statusSince` at now, exactly as {@link
 * StoreProvider}'s `addSession` does, because this genuinely is a new process
 * and carrying the old one's status would date a fresh session's clock to
 * whatever the last one was doing when it was stopped.
 */
export function withReplacedSession(
  sessions: Session[],
  oldId: string,
  meta: SessionMeta,
): Session[] {
  const at = sessions.findIndex((session) => session.id === oldId)
  if (at < 0) return sessions
  if (sessions.some((session) => session.id === meta.id)) return sessions

  const previous = sessions[at]
  const replacement: Session = {
    ...meta,
    projectPath: meta.cwd,
    status: 'idle',
    statusSince: Date.now(),
    ...(previous.namedByUser === true ? { title: previous.title, namedByUser: true } : {}),
  }
  return sessions.map((session, index) => (index === at ? replacement : session))
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
  /**
   * One session has been replaced by another, and to the person it is the same
   * tab.
   *
   * The only thing that does this is switching the account a running session is
   * on: a CLI is authenticated at spawn, so the account cannot change under a
   * live process — the process is stopped and another is started in its place,
   * which means a new id for what the person is still calling "this session".
   *
   * Deliberately not `removeSession` followed by `addSession`. That pair is
   * correct about the *contents* of the list and wrong about everything else a
   * person can see: the row moves to the bottom of its project, the active
   * session falls through to a neighbour on the way past, and a name somebody
   * typed is thrown away. Each of those is somebody's arrangement being rebuilt
   * because a process restarted, which is the mechanism showing through the
   * product.
   *
   * A name a person typed survives; a name the app derived does not. `AutoTitler`
   * will read a new one out of the new session's own output within a second or
   * two, and carrying the old derivation across would leave a title describing
   * output that is no longer on screen. {@link withSessionTitle} holds the same
   * rule for the same reason.
   */
  replaceSession(oldId: string, meta: SessionMeta): void
  removeSession(id: string): void
  setActiveSession(id: string | null): void
  setSessionStatus(id: string, status: SessionStatus): void
  /**
   * The process in a session ended, and the record has to say so.
   *
   * ## Why this did not exist, and what it cost
   *
   * `SessionMeta.exitCode` is read at every launch — `listSessions()` answers
   * with it — and then **never written again for the life of the window**. The
   * main process broadcasts `session:exit` with the code; the renderer had
   * three subscribers to that channel (the alerts feed, the Overview board and
   * the copilot's naming) and not one of them put it back on the session.
   *
   * `session:status` arrives at the same moment carrying `'exited'`, so the
   * rail's dot was right — which is what made this invisible. Everything that
   * asks the *record* was wrong: `App.tsx`'s `controlsFor` answers
   * `exited: local.exitCode !== null`, and it therefore answered `false` about
   * every dead session in the window. The bar over a killed agent went on
   * drawing a live model chip, a live effort chip and a live connectors chip —
   * seen on a real screen: `Opus 5 1M ⌄ · Ultracode ⌄ · Connectors ⌄` above a
   * terminal whose last line reads `[process exited]` — and pressing one typed
   * a slash command at a pty that no longer exists.
   *
   * ## Why the status is not enough on its own
   *
   * `'exited'` is a `SessionStatus`, and every other member of that type is a
   * *classification of output* produced by a heuristic in `session-activity.ts`.
   * An exit code is the operating system's own answer, it is the field
   * `SessionMeta` already has for it, and it is what `endOfLocalSession` reads.
   * Two facts, both true, and the record is the one that has to be right.
   */
  setSessionExit(id: string, exitCode: number): void
  /**
   * Rename a session, when something better than the folder name turns up.
   *
   * Ignored when the name has not actually changed, so a title derived on
   * every chunk of output does not re-render the sidebar on every chunk.
   *
   * `fromUser` marks a name somebody typed rather than one the app worked out,
   * and it is not a hint — it decides which of the two wins from then on. See
   * {@link withSessionTitle}, which holds the rule.
   */
  setSessionTitle(id: string, title: string, options?: { fromUser?: boolean }): void
  sessionsForProject(path: string): Session[]
}

const StoreContext = createContext<StoreValue | null>(null)

/*
 * Imported rather than declared here, and it used to be declared here — a
 * character-for-character copy of the one in `session-title.ts`.
 *
 * Which is how it stayed POSIX-only after the shared one learned about
 * backslashes: two identical functions are one function that will be fixed once.
 * A project on a Windows path was named with its whole path in the rail, while a
 * tab in that same project — which asks `session-title.ts` — was named with its
 * last segment. The same folder, two names, in one window.
 */

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

  const replaceSession = useCallback((oldId: string, meta: SessionMeta) => {
    setSessions((prev) => withReplacedSession(prev, oldId, meta))
    // The tab you were looking at is still the tab you are looking at. Guarded
    // on it actually having been the active one, so switching the account on a
    // session in the background does not pull the window onto it.
    setActiveSessionId((current) => (current === oldId ? meta.id : current))
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

  /**
   * Written once. A second `session:exit` for one session is not a thing the
   * main process does, but a re-broadcast on reconnect is — and overwriting a
   * code that is already there would be a status change with no change in it,
   * rebuilding the array and every memo hanging off it for nothing. The guard
   * is the same one `setSessionStatus` above states, for the same reason.
   */
  const setSessionExit = useCallback((id: string, exitCode: number) => {
    setSessions((prev) =>
      prev.some((s) => s.id === id && s.exitCode === null)
        ? prev.map((s) => (s.id === id ? { ...s, exitCode } : s))
        : prev,
    )
  }, [])

  const setSessionTitle = useCallback(
    (id: string, title: string, options?: { fromUser?: boolean }) => {
      setSessions((prev) => withSessionTitle(prev, id, title, options?.fromUser === true))
    },
    [],
  )

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
      replaceSession,
      removeSession,
      setActiveSession: setActiveSessionId,
      setSessionStatus,
      setSessionExit,
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
      replaceSession,
      removeSession,
      setSessionStatus,
      setSessionExit,
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
