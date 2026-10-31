/**
 * Subscriptions behind the usage strip.
 *
 * Both feeds are push, not poll. Cost rides the transcript watcher that already
 * exists in the main process (`cost:watch` → `cost:update`), which tails only
 * the bytes a session appends; nothing here re-reads a transcript, and there is
 * no timer. Plan limits ride the session's terminal and arrive when the CLI
 * prints something about them.
 */

import { useEffect, useRef, useState } from 'react'
import type { ProjectSummary } from './types'
import { readProjectSummary, sameProject } from './usage-model'

/**
 * The preload methods this strip uses.
 *
 * Three, and all required: the transcript watcher is the whole of this strip's
 * source now. The plan-limit channels used to be here as well, optional, for a
 * "Plan" item that has since moved to the session's chrome — see the note at
 * the top of `UsageStrip.tsx`. They are gone from this interface rather than
 * left unused, because an optional method nobody calls is how a bridge comes to
 * describe a feature that no longer exists.
 */
export interface UsageBridge {
  watchProjectCost(cwd: string): Promise<unknown>
  unwatchProjectCost(cwd: string): Promise<void>
  onCostUpdate(cb: (summary: unknown) => void): () => void
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
 * Returns whether this folder's push has **actually delivered something**, and
 * that is a deliberate change from what it used to answer.
 *
 * It used to return `bridge !== null && cwd !== null` — "a subscription was set
 * up" — and every caller reads it as "you can switch your fallback off". Those
 * are not the same sentence, and the gap between them was measured costing the
 * whole feature: a watcher established on a transcript directory that does not
 * exist yet reports the directory appearing and then never another thing (see
 * `TranscriptWatcher.adoptDirectory`), so the subscription was real, the answer
 * was `true`, the fallback was switched off, and the pane sat on a conversation
 * that had moved three messages on. A dead feed that says it is live is worse
 * than no feed, because nothing downstream can tell.
 *
 * So it answers from evidence, and there are two kinds of it. The main process
 * says whether a watch is established over a transcript directory that exists
 * ({@link ProjectSummary.watching}); and a push that has actually arrived for
 * this folder settles the question outright. Either is enough. Neither means
 * the pane is stale in the meantime — the caller re-reads on its own timer
 * until one of them lands, which on a healthy project is the first answer
 * `cost:watch` gives.
 *
 * False also still covers the case it always covered: a bridge with no cost
 * channel at all, an unwired build or a harness stub.
 */
export function useTranscriptChanges(cwd: string | null, onChange: () => void): boolean {
  const [bridge] = useState<UsageBridge | null>(() => resolveUsageBridge())
  const latest = useRef(onChange)
  latest.current = onChange
  /**
   * Whether this folder's push can be relied on. Reset when the folder changes,
   * because it is an answer about a directory and not about the bridge.
   */
  const [live, setLive] = useState(false)

  useEffect(() => {
    if (!bridge || !cwd) {
      setLive(false)
      return
    }
    let mounted = true
    setLive(false)

    const off = bridge.onCostUpdate((payload) => {
      // The push carries every watched project, so a second panel on another
      // folder must not make this one re-read.
      const next = readProjectSummary(payload)
      if (!mounted || !next || !sameProject(next.cwd, cwd)) return
      // A push that arrived is the strongest possible evidence that pushes
      // arrive, whatever the flag on it says.
      setLive(true)
      latest.current()
    })

    retain(cwd)
    void bridge
      .watchProjectCost(cwd)
      .then((summary) => {
        const next = readProjectSummary(summary)
        if (mounted && next?.watching === true) setLive(true)
      })
      .catch(() => {})

    return () => {
      mounted = false
      off()
      release(bridge, cwd)
    }
  }, [bridge, cwd])

  return live
}

export interface UsageState {
  summary: ProjectSummary | null
  /** True when the preload has no cost methods at all. */
  unwired: boolean
}

export function useUsage(cwd: string | null, injected?: UsageBridge): UsageState {
  const [bridge] = useState<UsageBridge | null>(() => injected ?? resolveUsageBridge())
  const [summary, setSummary] = useState<ProjectSummary | null>(null)

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

  return { summary, unwired: bridge === null }
}
