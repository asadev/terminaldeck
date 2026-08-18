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
  /**
   * `force` is a person pressing rather than this app deciding to ask. Optional
   * on the wire as well as here: a build whose preload predates it sends one
   * argument, and the main process reads a missing `force` as `false`, which is
   * the safe direction — it can only ever mean "do not type into this session".
   */
  refreshPlanLimits?(sessionId: string, force?: boolean): Promise<unknown>
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
  /**
   * Why this session has stopped asking, when it has.
   *
   * Set the first time an attempt gets as far as typing into the session and
   * comes back with nothing — no plan limits on this account, no panel at all,
   * or a panel that would not close. All three were paid for out of somebody's
   * terminal, so none may be retried on a timer or on the next keystroke: see
   * `useAutoUsage`, which stops entirely on this, and `refresh` in
   * `src/main/plan-limit.ts`, which refuses to type again even if asked.
   *
   * It is a sentence rather than a flag because it has to be *said*. A reading
   * that is missing with nothing anywhere explaining it is the dead end this
   * whole feature was reviewed for; and where this sentence is drawn, so is the
   * one control that can override it.
   *
   * Null is the ordinary state, including while the app is still trying, and
   * including after a check that succeeded.
   */
  blocked: string | null
  /**
   * True when this app has left Claude Code's usage panel on the screen.
   *
   * Kept apart from {@link blocked} even though today it always arrives with
   * one, because it is a statement about the *session*, not about this feature:
   * there is something on the person's terminal that they did not put there,
   * and that outranks anything the bar has to say about percentages.
   */
  residue: boolean
  /**
   * How many checks have been refused, in a row, since the last one that ran.
   *
   * A counter and not a flag, because the thing downstream needs to know is that
   * *another* refusal has happened — and two refusals in a row usually carry the
   * identical sentence, so a string would look unchanged and a boolean would
   * already be true. `useAutoUsage` re-arms on this changing; without it, a
   * refused first attempt on a session that then goes silent for good left the
   * bar empty with nothing anywhere that would ever try again.
   *
   * Reset to zero when a check runs, so it counts a *run* of refusals rather
   * than the lifetime total. That is what makes "give up after three" mean three
   * failures in a row rather than three since the window opened.
   */
  refusals: number
  /**
   * Run `/usage` in the session.
   *
   * `force` is what a press passes and what nothing else passes. It is the only
   * thing that reaches past a settled answer, which is what keeps the control in
   * the detail panel from being a control that does nothing — and what keeps the
   * automatic path from being able to use it.
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
  const [refusal, setRefusal] = useState<string | null>(null)
  const [refusals, setRefusals] = useState(0)
  const [blocked, setBlocked] = useState<string | null>(null)
  const [residue, setResidue] = useState(false)
  const live = useRef(true)

  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
    }
  }, [])

  useEffect(() => {
    setReport(null)
    // A run of refusals belongs to the session it happened in. A bar moved from
    // one pty to another is looking at a different account's window, and
    // carrying the old session's failures over would have it give up on the new
    // one before it had asked it anything.
    setRefusals(0)
    setRefusal(null)
    // And so does a settled answer: "this account has no plan limits" is a fact
    // about the login the *old* pty was running under, and carrying it to a new
    // one would have this give up on a session it has never asked anything.
    setBlocked(null)
    setResidue(false)
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

  const check = useCallback(
    (force = false) => {
      const ask = bridge?.refreshPlanLimits
      if (!ask || sessionId === '') return
      setChecking(true)
      setRefusal(null)
      // A press is a person saying "ask anyway", so it clears what a previous
      // attempt settled on before it asks. Without this the sentence from the
      // last failure would still be on the bar while the new attempt ran.
      if (force) {
        setBlocked(null)
        setResidue(false)
      }
      void ask
        .call(bridge, sessionId, force)
        .then((payload) => {
          if (!live.current) return
          const result = payload as { ok?: unknown; reason?: unknown; residue?: unknown; typed?: unknown } | null
          // Said before anything else, because it is the only one of these the
          // person can already see: something this app opened is still on their
          // screen.
          if (result?.residue === true) setResidue(true)
          if (result?.ok === true) {
            // It ran. Whatever it found, the run of failures is over — see
            // `refusals`, and `useAutoUsage`.
            setRefusals(0)
            return
          }
          const reason = (result?.reason ?? 'no-panel') as RefreshReason
          // The reasons are the main process's own and the sentences are the
          // ones the composer's strip already used, so one refusal cannot come
          // to be explained two ways in one app.
          const sentence = refreshFailureMessage(reason)
          setRefusal(sentence)
          /*
           * Whether this is the end of the conversation, decided by what the
           * attempt *cost* rather than by which sentence it carries.
           *
           * `typed` is the main process saying it got as far as putting
           * characters into the session. A refusal that typed nothing — the
           * session was working, the prompt had half a line in it — is a state
           * that clears itself in seconds and is worth trying again. One that
           * typed has already spent something of the person's: a command at
           * their prompt, a panel over their conversation. It stops here and
           * says why, and only a press starts it again.
           *
           * The second clause is for a bar that was mounted after the fact. The
           * main process keeps its own record of a settled session and refuses
           * without typing, so a window that reloaded — or a second window that
           * never saw the first attempt — gets `typed: false` carrying an answer
           * that is nonetheless final. Without this it would show the refusal as
           * a passing hiccup and go back to saying `Reading…` about a figure
           * that is never coming.
           */
          if (result?.typed === true || reason === 'no-limits' || reason === 'panel-open') {
            setBlocked(sentence)
          }
          setRefusals((count) => count + 1)
        })
        .catch(() => {
          if (!live.current) return
          setRefusal(refreshFailureMessage('no-panel'))
          setRefusals((count) => count + 1)
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
    canCheck: typeof bridge?.refreshPlanLimits === 'function' && sessionId !== '',
    checking,
    refusal,
    blocked,
    residue,
    refusals,
    check,
  }
}
