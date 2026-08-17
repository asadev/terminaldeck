/**
 * The subscription behind the usage bar.
 *
 * One channel, `usage:*`, which is the whole point of it existing: the chrome
 * draws a bar and should not have to know that one of its two sources is a
 * terminal being watched and the other is a file on disk. `usage-ipc.ts` folds
 * Claude's screen reading and Codex's rollout together, tags each with the
 * account it belongs to, and pushes the result whenever either half moves.
 *
 * Push, not poll — the rule Asad has given more than once. There is no timer in
 * this file. Claude's half arrives when the CLI prints something about a limit;
 * Codex's arrives when `fs.watch` sees a turn end.
 *
 * The one *action* here comes from the other channel. `plan:refresh` types
 * `/usage` into a Claude session and reads the panel it draws, and it is kept
 * separate deliberately: it is a Claude-specific gesture with Claude-specific
 * refusals, and its result does not have to be threaded back through this hook
 * because a successful run changes the screen, which the tracker is already
 * watching, which pushes a new report the ordinary way. So all this keeps from a
 * refresh is whether it ran and, when it did not, the sentence saying why.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { refreshFailureMessage } from '../chat/usage/usage-model'
import type { RefreshReason } from '../chat/usage/types'
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
  refreshPlanLimits?(sessionId: string): Promise<unknown>
}

export function resolveUsageBarBridge(): UsageBarBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: UsageBarBridge }).deck
  if (!host || typeof host.watchUsage !== 'function' || typeof host.onUsage !== 'function') {
    return null
  }
  return host
}

export interface UsageBarState {
  /** Null until the first answer lands, and while the bridge has no channel. */
  report: UsageReport | null
  /** True when this build has no usage channel at all. */
  unwired: boolean
  /** Whether `/usage` can be typed into this session from here. */
  canCheck: boolean
  checking: boolean
  /** Why the last check did not run. Cleared when another one starts. */
  refusal: string | null
  check: () => void
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
  const [refusal, setRefusal] = useState<string | null>(null)
  const live = useRef(true)

  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
    }
  }, [])

  useEffect(() => {
    setReport(null)
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
    // next push — which for Claude might be never, since it prints its limits
    // only near one.
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

  const check = useCallback(() => {
    const ask = bridge?.refreshPlanLimits
    if (!ask || sessionId === '') return
    setChecking(true)
    setRefusal(null)
    void ask
      .call(bridge, sessionId)
      .then((payload) => {
        if (!live.current) return
        const result = payload as { ok?: unknown; reason?: unknown } | null
        if (result?.ok === true) return
        // The reasons are the main process's own — busy, prompt-busy, no-panel
        // — and the sentences are the ones the composer's strip already used, so
        // one refusal cannot come to be explained two ways in one app.
        setRefusal(refreshFailureMessage((result?.reason ?? 'no-panel') as RefreshReason))
      })
      .catch(() => {
        if (live.current) setRefusal(refreshFailureMessage('no-panel'))
      })
      .finally(() => {
        if (live.current) setChecking(false)
      })
  }, [bridge, sessionId])

  return {
    report,
    unwired: bridge === null,
    canCheck: typeof bridge?.refreshPlanLimits === 'function' && sessionId !== '',
    checking,
    refusal,
    check,
  }
}
