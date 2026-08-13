/**
 * Subscriptions behind the usage strip.
 *
 * Both feeds are push, not poll. Cost rides the transcript watcher that already
 * exists in the main process (`cost:watch` → `cost:update`), which tails only
 * the bytes a session appends; nothing here re-reads a transcript, and there is
 * no timer. Plan limits ride the session's terminal and arrive when the CLI
 * prints something about them.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import type { PlanLimitSnapshot, ProjectSummary, RefreshResult } from './types'
import { readPlanSnapshot, readProjectSummary, sameProject } from './usage-model'

/**
 * The preload methods this strip uses.
 *
 * The cost half is already exposed, so it is declared as required and the
 * preload-contract test holds it to that. The plan half is wired separately —
 * optional until it lands, and the strip says "not available" rather than
 * rendering a control that does nothing.
 */
export interface UsageBridge {
  watchProjectCost(cwd: string): Promise<unknown>
  unwatchProjectCost(cwd: string): Promise<void>
  onCostUpdate(cb: (summary: unknown) => void): () => void
  watchPlanLimits?(sessionId: string): Promise<unknown>
  unwatchPlanLimits?(sessionId: string): void
  onPlanLimits?(cb: (sessionId: string, snapshot: unknown) => void): () => void
  refreshPlanLimits?(sessionId: string): Promise<unknown>
}

/** Read defensively: this strip can mount before its half of the bridge exists. */
export function resolveUsageBridge(): UsageBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<UsageBridge> }).deck
  if (
    !host ||
    typeof host.watchProjectCost !== 'function' ||
    typeof host.unwatchProjectCost !== 'function' ||
    typeof host.onCostUpdate !== 'function'
  ) {
    return null
  }
  return host as UsageBridge
}

/**
 * Watchers are shared per project inside the main process and released per
 * *window*, not per caller — so two strips on one project would have the first
 * unmount cancel the second's updates. Counted here so the last one out turns
 * off the light.
 */
const watching = new Map<string, number>()

/**
 * Only the count is kept here. `cost:watch` both subscribes and answers with the
 * current totals, and the effect below calls it for the totals anyway — calling
 * it here as well made every mount ask the main process to scan twice.
 */
function retain(cwd: string): void {
  watching.set(cwd, (watching.get(cwd) ?? 0) + 1)
}

function release(bridge: UsageBridge, cwd: string): void {
  const count = watching.get(cwd) ?? 0
  if (count <= 1) {
    watching.delete(cwd)
    void bridge.unwatchProjectCost(cwd).catch(() => {})
    return
  }
  watching.set(cwd, count - 1)
}

/**
 * "A transcript in this project just changed", for anything that is not the
 * usage strip.
 *
 * `cost:watch` is named after what it was built for, but what it *is* is the
 * only real file watcher this app has over a project's transcripts: a
 * `fs.watch` on the transcript directory, debounced 300 ms, pushing on every
 * append. Anything in the renderer that used to ask "has the transcript grown?"
 * on a timer can subscribe to that instead and be both cheaper and faster — a
 * 2-second poll is 43,200 questions a day, nearly all of them answered "no",
 * and still up to two seconds behind when the answer is yes.
 *
 * It lives beside `useUsage` rather than in a module of its own because the
 * refcount above has to be *the* refcount: `cost:unwatch` is honoured per
 * window, not per caller, so a second tally over the same channel would have
 * the first unmount switch off the watcher the other subscriber is still using.
 *
 * Returns whether it is actually watching. False means the bridge has no cost
 * channel — an unwired build, or a harness stub — and the caller has to fall
 * back rather than sit silently on stale content.
 */
export function useTranscriptChanges(cwd: string | null, onChange: () => void): boolean {
  const [bridge] = useState<UsageBridge | null>(() => resolveUsageBridge())
  const latest = useRef(onChange)
  latest.current = onChange

  useEffect(() => {
    if (!bridge || !cwd) return
    let mounted = true

    const off = bridge.onCostUpdate((payload) => {
      // The push carries every watched project, so a second panel on another
      // folder must not make this one re-read.
      const next = readProjectSummary(payload)
      if (mounted && next && sameProject(next.cwd, cwd)) latest.current()
    })

    retain(cwd)
    void bridge.watchProjectCost(cwd).catch(() => {})

    return () => {
      mounted = false
      off()
      release(bridge, cwd)
    }
  }, [bridge, cwd])

  return bridge !== null && cwd !== null
}

export interface UsageState {
  summary: ProjectSummary | null
  plan: PlanLimitSnapshot | null
  /** Null until a refresh has failed; the words the user is shown. */
  refreshReason: RefreshResult['reason']
  refreshing: boolean
  /** True when the preload has no cost methods at all. */
  unwired: boolean
  canRefreshPlan: boolean
  refreshPlan: () => void
}

export function useUsage(
  cwd: string | null,
  sessionId: string | undefined,
  injected?: UsageBridge,
): UsageState {
  const [bridge] = useState<UsageBridge | null>(() => injected ?? resolveUsageBridge())
  const [summary, setSummary] = useState<ProjectSummary | null>(null)
  const [plan, setPlan] = useState<PlanLimitSnapshot | null>(null)
  const [refreshReason, setRefreshReason] = useState<RefreshResult['reason']>(null)
  const [refreshing, setRefreshing] = useState(false)
  const live = useRef(true)

  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
    }
  }, [])

  /* ------------------------------------------------------------- cost -- */

  useEffect(() => {
    if (!bridge || !cwd) {
      setSummary(null)
      return
    }
    let mounted = true
    setSummary(null)

    // The push channel carries every watched project, so a second panel
    // watching a different folder must not overwrite this one's numbers.
    const off = bridge.onCostUpdate((payload) => {
      const next = readProjectSummary(payload)
      if (mounted && next && sameProject(next.cwd, cwd)) setSummary(next)
    })

    retain(cwd)
    // `cost:watch` answers with the current totals, so the strip has numbers
    // before the first change lands.
    void bridge
      .watchProjectCost(cwd)
      .then((payload) => {
        const next = readProjectSummary(payload)
        if (mounted && next) setSummary(next)
      })
      .catch(() => {})

    return () => {
      mounted = false
      off()
      release(bridge, cwd)
    }
  }, [bridge, cwd])

  /* ------------------------------------------------------- plan limits -- */

  useEffect(() => {
    setPlan(null)
    setRefreshReason(null)
    if (!bridge || !sessionId || typeof bridge.watchPlanLimits !== 'function') return
    let mounted = true

    const off = bridge.onPlanLimits?.((id, payload) => {
      if (!mounted || id !== sessionId) return
      const next = readPlanSnapshot(payload)
      if (next) setPlan(next)
    })

    void bridge
      .watchPlanLimits(sessionId)
      .then((payload) => {
        const next = readPlanSnapshot(payload)
        if (mounted && next) setPlan(next)
      })
      .catch(() => {})

    return () => {
      mounted = false
      off?.()
      bridge.unwatchPlanLimits?.(sessionId)
    }
  }, [bridge, sessionId])

  const refreshPlan = useCallback(() => {
    if (!bridge || !sessionId || typeof bridge.refreshPlanLimits !== 'function') return
    setRefreshing(true)
    setRefreshReason(null)
    void bridge
      .refreshPlanLimits(sessionId)
      .then((payload) => {
        if (!live.current) return
        const result = payload as Partial<RefreshResult> | null
        const snapshot = readPlanSnapshot(result?.snapshot)
        if (snapshot) setPlan(snapshot)
        setRefreshReason(result?.ok === true ? null : (result?.reason ?? 'no-panel'))
      })
      .catch(() => {
        if (live.current) setRefreshReason('no-panel')
      })
      .finally(() => {
        if (live.current) setRefreshing(false)
      })
  }, [bridge, sessionId])

  return {
    summary,
    plan,
    refreshReason,
    refreshing,
    unwired: bridge === null,
    canRefreshPlan:
      bridge !== null && typeof bridge.refreshPlanLimits === 'function' && Boolean(sessionId),
    refreshPlan,
  }
}
