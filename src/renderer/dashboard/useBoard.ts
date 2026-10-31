import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react'
import type { ProviderId, SessionStatus } from '@shared/types'
import { useOptionalStore } from '../state/store'
import {
  asTranscriptFiles,
  pickSessionTranscript,
  type TranscriptFileView,
} from '../session-transcript'
// Imported from the module rather than from `chat/usage/index`, which also
// exports the usage strip and would pull its stylesheet into this bundle —
// the same reason `widgets.tsx` takes its git types type-only from GitPanel.
import { useTranscriptChanges } from '../chat/usage/useUsage'
import { asSessionMeta, folderOf, workFromSummary, type BoardSession, type SessionWork } from './board'

/**
 * Where the Overview board's facts come from.
 *
 * Every hook here is a subscription to something the app already knows. There
 * is no timer that asks "has anything changed?" — the main process pushes
 * `session:status` when a tracker settles, `session:created`/`session:exit`
 * when the set changes, and `cost:update` when a transcript grows. The one
 * interval in the file is the four-second retry for a session that has not
 * written a transcript *yet*, and it stops the moment it has one.
 */

/* ------------------------------------------------------------- live list -- */

/** A session before its transcript accounting is attached. */
export interface LiveSession {
  id: string
  title: string
  projectPath: string
  provider: ProviderId
  /** The account it runs as — id and name together. See `BoardSession`. */
  account: { id: string; name: string } | null
  status: SessionStatus
  statusSince: number
  startedAt: number
  /** Started with "continue the last conversation" — changes which transcript is its own. */
  resumed: boolean
}

type BridgeFn = (...args: unknown[]) => unknown

function bridgeMethod(name: string): BridgeFn | null {
  if (typeof window === 'undefined') return null
  const api = (globalThis as { deck?: Record<string, unknown> }).deck
  const fn = api?.[name]
  return typeof fn === 'function' ? (fn as BridgeFn) : null
}

/**
 * Every session this app has open, in every project.
 *
 * **The store first.** It is the window's own record, maintained since launch
 * by the one `session:status` subscription in `App.tsx`, so it is both
 * consistent with the sidebar's dots and the only place that knows *when* each
 * status began — a fact `session:status` carries no timestamp for and which is
 * therefore unrecoverable after the fact. A board built from a fresh
 * `session:list` would have to date every session from the moment the page was
 * opened, which is precisely the number a person reading "waiting on you for
 * 12 minutes" must not be shown.
 *
 * **The bridge as the fallback**, for a board mounted outside the provider —
 * the harness, a test, a future window that does not carry the store. It is
 * genuinely weaker and says so by leaving `statusSince` at the moment it heard
 * the status, which `statusObserved` then refuses to print a clock for.
 */
export function useLiveSessions(): LiveSession[] {
  const store = useOptionalStore()

  const fromStore = useMemo<LiveSession[] | null>(() => {
    if (!store) return null
    return store.sessions.map((session) => ({
      id: session.id,
      title: session.title || folderOf(session.projectPath),
      projectPath: session.projectPath,
      provider: session.provider,
      // Both halves or neither: the card's label has to know whether the name
      // is one somebody chose, and only the id says so.
      account:
        session.profileId && session.profileName
          ? { id: session.profileId, name: session.profileName }
          : null,
      status: session.status,
      statusSince: session.statusSince,
      startedAt: session.createdAt,
      resumed: session.resumed === true,
    }))
  }, [store])

  const fromBridge = useBridgeSessions(fromStore === null)
  return fromStore ?? fromBridge
}

/**
 * The fallback list, assembled from the preload bridge.
 *
 * `enabled` rather than an early return because hooks cannot be conditional,
 * and because a component that has a store must not also hold four IPC
 * listeners doing the same job worse.
 */
function useBridgeSessions(enabled: boolean): LiveSession[] {
  const [sessions, setSessions] = useState<LiveSession[]>([])

  useEffect(() => {
    if (!enabled) return
    let live = true

    const adopt = (raw: unknown): LiveSession | null => {
      const meta = asSessionMeta(raw)
      if (!meta) return null
      return {
        id: meta.id,
        title: meta.title,
        projectPath: meta.cwd,
        provider: meta.provider,
        account: meta.account,
        status: meta.exitCode === null ? 'idle' : 'exited',
        // Zero, not `Date.now()`: nothing has been observed about this
        // session's state, and a timestamp here would be read as one that had.
        statusSince: 0,
        startedAt: meta.createdAt,
        resumed: meta.resumed,
      }
    }

    const list = bridgeMethod('listSessions')
    if (list) {
      void Promise.resolve(list())
        .then((raw) => {
          if (!live || !Array.isArray(raw)) return
          setSessions(raw.flatMap((entry) => {
            const session = adopt(entry)
            return session ? [session] : []
          }))
        })
        .catch(() => {
          // A build without the session channel simply has no board. The empty
          // state below says how to start one, which is the right thing to show.
        })
    }

    const offCreated = bridgeMethod('onSessionCreated')?.((raw: unknown) => {
      const session = adopt(raw)
      if (!session) return
      setSessions((current) =>
        current.some((entry) => entry.id === session.id) ? current : [...current, session],
      )
    })

    const offStatus = bridgeMethod('onSessionStatus')?.((id: unknown, status: unknown) => {
      if (typeof id !== 'string' || typeof status !== 'string') return
      setSessions((current) =>
        current.map((entry) =>
          entry.id === id && entry.status !== status
            ? { ...entry, status: status as SessionStatus, statusSince: Date.now() }
            : entry,
        ),
      )
    })

    const offExit = bridgeMethod('onSessionExit')?.((id: unknown) => {
      if (typeof id !== 'string') return
      setSessions((current) =>
        current.map((entry) =>
          entry.id === id && entry.status !== 'exited'
            ? { ...entry, status: 'exited', statusSince: Date.now() }
            : entry,
        ),
      )
    })

    return () => {
      live = false
      if (typeof offCreated === 'function') (offCreated as () => void)()
      if (typeof offStatus === 'function') (offStatus as () => void)()
      if (typeof offExit === 'function') (offExit as () => void)()
    }
  }, [enabled])

  return sessions
}

/* ------------------------------------------------------------ folder work -- */

/** What one project folder can tell the board about its sessions. */
export interface FolderWork {
  /** Transcripts on disk for this folder, newest write first. */
  files: TranscriptFileView[]
  /** The `ProjectSummary` behind them, as it crossed the bridge. */
  summary: unknown
}

export type FolderWorkMap = ReadonlyMap<string, FolderWork>

/** How often to look again for a transcript a freshly started session has not written yet. */
const AWAIT_TRANSCRIPT_MS = 4000

/**
 * Load one folder's transcript index and cost totals, and keep them current.
 *
 * Renders nothing. It exists as a component because the two subscriptions it
 * needs are per folder, and a board showing four projects cannot call a hook
 * four times from one function — one instance per folder, keyed by path, is the
 * only way React allows the effect to be scoped to the thing it is about.
 *
 * The two halves refresh on different signals on purpose:
 *
 *  - **Totals** ride `cost:watch`, which is a real `fs.watch` on the transcript
 *    directory debounced 300 ms in the main process. Re-reading them is nearly
 *    free while it is watched, because `cost:project` hands back the live
 *    watcher's own numbers rather than rescanning.
 *  - **The file index** is a `readdir` and a `stat` per transcript, and it only
 *    changes when a *new conversation* starts. So it is read on mount, again
 *    whenever the set of sessions in this folder changes, and then on a slow
 *    retry only while some session here still has no transcript of its own —
 *    a session writes its first line when its first prompt is answered, not
 *    when its tab opens.
 */
export function FolderWorkLoader({
  cwd,
  sessionKey,
  awaiting,
  live,
  onLoaded,
}: {
  cwd: string
  /** Ids of the sessions in this folder, joined — changes when the set does. */
  sessionKey: string
  /** True while at least one session here is still unmatched to a transcript. */
  awaiting: boolean
  /** True while at least one session here has not exited. */
  live: boolean
  onLoaded: (cwd: string, work: FolderWork) => void
}): null {
  const [indexNonce, bumpIndex] = useReducer((n: number) => n + 1, 0)
  const [totalsNonce, bumpTotals] = useReducer((n: number) => n + 1, 0)

  // Held in a ref so a fresh callback on every parent render does not restart
  // the reads — the classic way a subscription turns into a request per frame.
  const report = useRef(onLoaded)
  report.current = onLoaded

  // Only a folder with something still running is watched. `cost:watch` puts an
  // `fs.watch` on the transcript directory and scans it once to prime the
  // totals, and a folder whose sessions have all exited will never append
  // another byte — its card keeps the figures it already read.
  useTranscriptChanges(live ? cwd : null, bumpTotals)

  // The slow retry, and only while it can still learn something.
  useEffect(() => {
    if (!awaiting) return
    const timer = setInterval(bumpIndex, AWAIT_TRANSCRIPT_MS)
    return () => clearInterval(timer)
  }, [awaiting])

  const latest = useRef<FolderWork>({ files: [], summary: null })

  useEffect(() => {
    const list = bridgeMethod('listSessionInsights')
    if (!list) return
    let live = true
    void Promise.resolve(list(cwd))
      .then((raw) => {
        if (!live) return
        latest.current = { ...latest.current, files: asTranscriptFiles(raw) }
        report.current(cwd, latest.current)
      })
      .catch(() => {
        // A folder Claude Code has never opened has no transcripts, which is
        // not an error and not worth a message on a card.
      })
    return () => {
      live = false
    }
  }, [cwd, sessionKey, indexNonce])

  useEffect(() => {
    const cost = bridgeMethod('getProjectCost')
    if (!cost) return
    let live = true
    void Promise.resolve(cost(cwd))
      .then((raw) => {
        if (!live) return
        latest.current = { ...latest.current, summary: raw }
        report.current(cwd, latest.current)
      })
      .catch(() => {
        // Same: no transcripts, or a build without the cost channel. The cards
        // then carry no figures rather than zeroes, which would be a claim.
      })
    return () => {
      live = false
    }
  }, [cwd, totalsNonce])

  return null
}

/**
 * Attach each session's own transcript accounting, where it can be established.
 *
 * `pickSessionTranscript` is the arbiter, and the reason this is not simply
 * "the newest transcript in the folder": that answer once put a stranger's 143
 * requests and $18.49 under a tab that had run nothing, because a `claude`
 * outside the app had written more recently in the same directory. It rules a
 * transcript *out* when it began before the tab did, and reports how it decided.
 *
 * A session it cannot match carries no figures at all. A card with no money on
 * it is honest; a card with somebody else's money on it is not.
 *
 * The `project` attribution is refused explicitly even though a call that passes
 * a scope — which is every call here — cannot produce one today. It means "no
 * session in play, this is just the folder's newest file", which is precisely
 * the guess that caused the bug, and the guard is what stops a later widening
 * of `pickSessionTranscript` from quietly reintroducing it on this page.
 */
export function attachWork(sessions: readonly LiveSession[], folders: FolderWorkMap): BoardSession[] {
  return sessions.map((session) => {
    const folder = folders.get(session.projectPath)
    const choice = folder
      ? pickSessionTranscript(folder.files, {
          startedAt: session.startedAt,
          resumed: session.resumed,
        })
      : null

    const work: SessionWork | null =
      choice && choice.attribution !== 'project' && folder
        ? workFromSummary(folder.summary, choice.sessionId, choice.path)
        : null

    return {
      id: session.id,
      title: session.title,
      projectPath: session.projectPath,
      provider: session.provider,
      account: session.account,
      status: session.status,
      statusSince: session.statusSince,
      startedAt: session.startedAt,
      work,
    }
  })
}

/**
 * The folders the board has to load, and which of them are still waiting on a
 * transcript to appear.
 *
 * Both answers come out of one pass because they are the same question asked at
 * two levels, and computing them apart is how the retry ends up running for a
 * folder whose sessions all matched twenty minutes ago.
 */
export function folderPlan(
  sessions: readonly LiveSession[],
  folders: FolderWorkMap,
): Array<{ cwd: string; sessionKey: string; awaiting: boolean; live: boolean }> {
  const byFolder = new Map<string, LiveSession[]>()
  for (const session of sessions) {
    const list = byFolder.get(session.projectPath)
    if (list) list.push(session)
    else byFolder.set(session.projectPath, [session])
  }

  return [...byFolder.entries()].map(([cwd, list]) => {
    const work = folders.get(cwd)
    const awaiting = list.some((session) => {
      // An exited session is never going to write anything else, so a folder
      // full of them must not keep the retry alive forever.
      if (session.status === 'exited') return false
      if (!work) return true
      const choice = pickSessionTranscript(work.files, {
        startedAt: session.startedAt,
        resumed: session.resumed,
      })
      return choice === null || choice.attribution === 'project'
    })
    return {
      cwd,
      sessionKey: list.map((session) => session.id).sort().join(','),
      awaiting,
      live: list.some((session) => session.status !== 'exited'),
    }
  })
}

/**
 * The board's data, assembled.
 *
 * Returns the cards plus the loaders that have to be rendered for them to stay
 * current — the caller mounts those, because a hook cannot render.
 */
export function useBoardSessions(): {
  sessions: BoardSession[]
  plan: Array<{ cwd: string; sessionKey: string; awaiting: boolean; live: boolean }>
  onFolderLoaded: (cwd: string, work: FolderWork) => void
} {
  const live = useLiveSessions()
  const [folders, setFolders] = useState<FolderWorkMap>(() => new Map())

  const onFolderLoaded = useCallback((cwd: string, work: FolderWork) => {
    setFolders((current) => {
      const next = new Map(current)
      next.set(cwd, work)
      return next
    })
  }, [])

  const plan = useMemo(() => folderPlan(live, folders), [live, folders])
  const sessions = useMemo(() => attachWork(live, folders), [live, folders])

  return { sessions, plan, onFolderLoaded }
}
