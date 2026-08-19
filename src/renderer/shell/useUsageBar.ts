/**
 * The subscription behind the usage bar.
 *
 * One channel, `usage:*`, which is the whole point of it existing: the chrome
 * draws a bar and should not have to know that one of its sources is a terminal
 * being watched, another is a file on disk and a third is a short-lived process.
 * `usage-ipc.ts` folds them together, tags each reading with the account it
 * belongs to, and pushes the result whenever any of them moves.
 *
 * Push, not poll — the rule Asad has given more than once. There is no timer in
 * this file. Claude's readings arrive when the CLI prints something about a
 * limit, when a refresh lands, or when another session on the same login has one
 * pushed to it; Codex's arrive when `fs.watch` sees a turn end.
 *
 * ## What changed on 2026-08-18, and why this hook got smaller
 *
 * The action used to be `plan:refresh`, which typed `/usage` into the session
 * and read the panel Claude Code drew over whatever was in it. Asad reported
 * that three times, the last with a recording of the panel sitting on a live
 * conversation, and then closed the question:
 *
 *   > *"find out some other way to keep the bar refresh otherwise we will remove
 *   > it completely if it will be heavy"*
 *
 * There is another way, and `usage-probe.ts` measures it. The action here is now
 * `usage:refresh`, which reads what Claude Code already wrote into
 * `.claude.json` and, only when that has gone stale, starts a `claude` of this
 * app's own for about four seconds. It costs no tokens and touches no session.
 *
 * Most of what this hook used to carry existed because the old action was
 * *expensive to fail*. An attempt that typed had spent something of the user's —
 * a command at their prompt, a panel over their work — so a failure had to be
 * final, a refusal had to be counted, and a panel left behind had to be
 * confessed. None of that is true of a file read and a process in the user's
 * home directory, so `residue`, `refusals` and the run-of-refusals machinery are
 * gone rather than left inert. What is left is: is it running, what did it last
 * say, and is there a settled answer that means it will not say anything else.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { refreshOutcomeMessage } from '../chat/usage/usage-model'
import type { UsageRefreshOutcome } from '../chat/usage/types'
import { readUsageReport, type UsageReport } from './usage-bar-model'

/**
 * The preload methods this bar uses.
 *
 * All optional, and read one at a time rather than as a block, because this
 * component can be mounted by a build whose preload predates either channel —
 * and the honest answer there is "not wired into this build", not a bar drawn
 * from nothing. The harness stub answers the same shapes; see `.harness/stub.ts`.
 */
export interface UsageBarBridge {
  watchUsage?(sessionId: string): Promise<unknown>
  unwatchUsage?(sessionId: string): void
  onUsage?(cb: (sessionId: string, payload: unknown) => void): () => void
  /**
   * Bring this login's figure up to date without touching a session.
   *
   * `force` is a person pressing rather than this app deciding to look. Optional
   * on the wire as well as here: a build whose preload predates it sends one
   * argument, and the main process reads a missing `force` as `false`, which is
   * the safe direction — it can only ever mean "do less".
   */
  refreshUsage?(sessionId: string, force?: boolean): Promise<unknown>
}

export function resolveUsageBarBridge(): UsageBarBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: UsageBarBridge }).deck
  if (!host || typeof host.watchUsage !== 'function' || typeof host.onUsage !== 'function') {
    return null
  }
  return host
}

/** The outcomes that mean nothing more is coming for this login. */
const SETTLED: ReadonlySet<string> = new Set<UsageRefreshOutcome>(['no-limits', 'settled', 'signed-out', 'no-binary'])

/** Read defensively: an older main process may answer a shape this predates. */
function readOutcome(payload: unknown): { outcome: UsageRefreshOutcome; detail: string; ok: boolean } {
  const record = payload as { ok?: unknown; outcome?: unknown; detail?: unknown } | null
  const outcome = (typeof record?.outcome === 'string' ? record.outcome : 'unreadable') as UsageRefreshOutcome
  const detail = typeof record?.detail === 'string' && record.detail !== '' ? record.detail : refreshOutcomeMessage(outcome)
  return { outcome, detail, ok: record?.ok === true }
}

export interface UsageBarState {
  /** Null until the first answer lands, and while the bridge has no channel. */
  report: UsageReport | null
  /** True when this build has no usage channel at all. */
  unwired: boolean
  /** Whether a refresh can be run from here at all. */
  canCheck: boolean
  checking: boolean
  /**
   * Why this login has stopped having anything to say, when it has.
   *
   * Set when a refresh comes back with an answer that will not change for being
   * asked again: the login has no subscription limits, it is not signed in, or
   * there is no `claude` on this machine to ask. A sentence rather than a flag
   * because it has to be *said* — a figure that is missing with nothing anywhere
   * explaining it is the dead end this whole feature was reviewed for.
   *
   * It no longer stops anything happening. The old `blocked` had to: every one
   * of its states had been paid for out of somebody's terminal. This one is a
   * statement, and the main process holds the actual restraint — see
   * `refreshUsage` in `src/main/usage-ipc.ts`, which remembers `no-limits`
   * against the account so nothing is started for it again.
   */
  blocked: string | null
  /**
   * True when the settled answer is "this login has no subscription limits".
   *
   * A flag beside {@link blocked} rather than a re-reading of the sentence,
   * because the bar has one more thing to do with it than print it: the figure
   * column says `Not reported` in every other absent state, and that is the
   * wrong word here. `Not reported` describes a number that has not arrived;
   * this is a number that does not exist. See `UsageBarView`.
   */
  noLimits: boolean
  /** What the last refresh said, whatever it said. Null before the first one. */
  detail: string | null
  /**
   * Bring the figure up to date.
   *
   * `force` is what a press passes and what nothing else passes. It is the only
   * thing that reaches past a remembered "this login has no subscription
   * limits", which is what keeps the control in the detail panel from being a
   * control that does nothing.
   */
  check: (force?: boolean) => void
}

/**
 * Watch one session's usage windows.
 *
 * `sessionId` is the pty, exactly as for every other control in this cluster —
 * which is what makes "whose usage is this" have the same answer as "which
 * terminal is this bar drawn over". A cluster that moves between bars when a
 * split opens re-subscribes, because the effect is keyed on the id and not on
 * where the component happens to be mounted.
 */
export function useUsageBar(sessionId: string, injected?: UsageBarBridge): UsageBarState {
  const [bridge] = useState<UsageBarBridge | null>(() => injected ?? resolveUsageBarBridge())
  const [report, setReport] = useState<UsageReport | null>(null)
  const [checking, setChecking] = useState(false)
  const [detail, setDetail] = useState<string | null>(null)
  const [blocked, setBlocked] = useState<string | null>(null)
  const [noLimits, setNoLimits] = useState(false)
  const live = useRef(true)

  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
    }
  }, [])

  useEffect(() => {
    setReport(null)
    // A settled answer belongs to the login the *old* pty was running under.
    // Carrying it to a new one would have this give up on a session it has
    // never asked anything.
    setDetail(null)
    setBlocked(null)
    setNoLimits(false)
    if (!bridge?.watchUsage || !bridge.onUsage || sessionId === '') return
    let mounted = true

    // The push carries the session it is about, because one window watches
    // several: a split has two of these mounted at once, and each must ignore
    // the other's numbers rather than briefly showing them.
    const off = bridge.onUsage((id, payload) => {
      if (!mounted || id !== sessionId) return
      const next = readUsageReport(payload)
      if (next) setReport(next)
    })

    // `usage:watch` answers with what is already known, so a bar that mounts
    // onto a session which has been running for an hour is not blank until the
    // next push — which for Claude might otherwise be a while.
    void bridge
      .watchUsage(sessionId)
      .then((payload) => {
        const next = readUsageReport(payload)
        if (mounted && next) setReport(next)
      })
      .catch(() => {})

    return () => {
      mounted = false
      off()
      bridge.unwatchUsage?.(sessionId)
    }
  }, [bridge, sessionId])

  const check = useCallback(
    (force = false) => {
      const ask = bridge?.refreshUsage
      if (!ask || sessionId === '') return
      setChecking(true)
      // A press is a person saying "look anyway", so it clears what a previous
      // attempt settled on before it asks. Without this the sentence from the
      // last failure would still be on the bar while the new attempt ran.
      if (force) {
        setBlocked(null)
        setNoLimits(false)
      }
      void ask
        .call(bridge, sessionId, force)
        .then((payload) => {
          if (!live.current) return
          const result = readOutcome(payload)
          setDetail(result.detail)
          if (result.ok) {
            /*
             * Numbers arrived, which is proof this login has windows to read. A
             * settled answer remembered from an earlier session — a different
             * login in the same directory, or a plan bought since — must not
             * outlive that. The readings themselves come in over `usage:update`
             * rather than through this promise, because they belong to the
             * account and every bar on it is owed them.
             */
            setBlocked(null)
            setNoLimits(false)
            return
          }
          if (SETTLED.has(result.outcome)) setBlocked(result.detail)
          if (result.outcome === 'no-limits' || result.outcome === 'settled') setNoLimits(true)
        })
        .catch(() => {
          if (live.current) setDetail(refreshOutcomeMessage('unreadable'))
        })
        .finally(() => {
          if (live.current) setChecking(false)
        })
    },
    [bridge, sessionId],
  )

  return {
    report,
    unwired: bridge === null,
    canCheck: typeof bridge?.refreshUsage === 'function' && sessionId !== '',
    checking,
    blocked,
    noLimits,
    detail,
    check,
  }
}
