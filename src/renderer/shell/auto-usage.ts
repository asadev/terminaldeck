/**
 * Fetching the usage figures without being asked to.
 *
 * ## What this is answering
 *
 * Asad, on the "Check now" button that used to sit in the usage panel:
 *
 *   > *"Claude Code has it, it should automatically do it and bring it here."*
 *
 * and, in the same breath about the bar itself: *"usage should appear on its
 * own, not need a click."*
 *
 * Both halves of that had to be done together, and doing only the first would
 * have been worse than doing neither. Claude Code prints its plan limits in two
 * situations and no others: when it is near one, and when somebody runs
 * `/usage`. The button was the only thing in this app that produced the second.
 * Delete it on its own and the bar is not simplified, it is emptied — it would
 * spend every session saying "not reported" with nothing on screen that could
 * ever change that, which is the dead-end the whole review is about.
 *
 * ## Why this is not a timer, and what it is instead
 *
 * The standing rule in this project is events over polling — his words, more
 * than once: crons and timers *"make the system heavier"*. Nothing pushes a
 * usage figure, so there is no event that says "the number moved". But there is
 * an event that means the number moved: **the session printed something**. An
 * agent that has produced output has spent tokens, and one that has been silent
 * has not. So the fetch is driven off `session:data` going quiet, which is the
 * same signal `useSessionControls` already re-reads the model and effort on, and
 * for the same reason.
 *
 * There are exactly two timers in here and both are one-shots, not intervals:
 * the debounce that decides output has stopped, and the single delayed first
 * attempt for a session that mounts already idle and may never print again.
 *
 * ## Why it is safe to type into somebody's session unasked
 *
 * Because the main process refuses in every case where it would not be. See
 * `refresh()` in `src/main/plan-limit.ts`: it will not run unless the session
 * has been quiet for a second *and* its prompt box is empty, so it cannot
 * append `/usage` to half-typed text and it cannot interrupt a working agent.
 * When it does run it closes the panel again with Escape, which is what a person
 * does. Every refusal comes back as a reason and is dropped on the floor here —
 * a refusal of something nobody pressed is not news, and the state it leaves
 * behind is already described in words on the bar.
 *
 * That last point is the difference between this and the button. The button had
 * to explain itself when it failed, because a person had pressed it. Nothing
 * here was pressed, so nothing here reports.
 */

import { useCallback, useEffect, useRef } from 'react'
import type { ProviderId } from '@shared/types'

/**
 * How long the session must be quiet before a fetch is attempted.
 *
 * A little longer than the second of quiet the main process itself insists on,
 * so the ordinary case is an attempt that runs rather than one that is refused
 * and has to come back. `useSessionControls` waits 400ms for the same event and
 * that is right for a *read* of the screen; this one writes to it.
 */
const QUIET_MS = 1400

/**
 * The floor between two attempts on one session.
 *
 * Not a rate at which anything happens — nothing happens at all while the
 * session is silent. This exists for the case the event stream cannot rule out:
 * a session printing in bursts, settling every few seconds, each settle finding
 * the reading still absent because the previous attempt was refused for a reason
 * that has not changed. Twenty seconds turns that into three attempts a minute
 * at the very worst, against a gate that costs nothing to refuse.
 */
const RETRY_MS = 20_000

export interface AutoUsageOptions {
  sessionId: string
  provider?: ProviderId
  /**
   * Whether this build can run the fetch at all.
   *
   * False in a build whose preload has no `plan:refresh`, in which case there is
   * nothing to attempt and the bar says so in words instead.
   */
  canFetch: boolean
  /** A fetch is already in flight. */
  fetching: boolean
  /**
   * True when the leading window already has a reading worth leaving alone.
   *
   * Supplied rather than computed here because the answer is a judgement about
   * what may be *drawn*, and that judgement lives in `usage-stack.ts` beside
   * every other one — see `leadIsLive`. A second opinion about freshness is how
   * a bar comes to chase a figure it is already showing.
   */
  fresh: boolean
  /** Runs `/usage` in the session. The action `useUsageBar` already exposes. */
  fetch: () => void
}

/** The one preload method this needs beyond the ones the bar already holds. */
interface DataBridge {
  onSessionData?(cb: (id: string, data: string) => void): () => void
}

/**
 * `globalThis` rather than `window`: the shell's components are rendered to a
 * string by their own tests, where there is no `window` to read at all.
 */
function dataBridge(): DataBridge | undefined {
  return (globalThis as unknown as { deck?: DataBridge }).deck
}

export function useAutoUsage({
  sessionId,
  provider,
  canFetch,
  fetching,
  fresh,
  fetch,
}: AutoUsageOptions): void {
  const lastAttempt = useRef(0)
  /*
   * Everything the attempt reads, kept in a ref rather than in the effect's
   * dependencies.
   *
   * The subscription below must survive a report landing, a percentage moving
   * and a fetch starting — all of which change these values several times a
   * minute. Listed as dependencies they would tear down and re-establish the
   * `session:data` listener each time, and a listener that is re-installed
   * during the very burst of output it is waiting to see is a listener whose
   * debounce never completes.
   */
  const state = useRef({ canFetch, fetching, fresh, fetch })
  state.current = { canFetch, fetching, fresh, fetch }

  const attempt = useCallback((): void => {
    const now = Date.now()
    const current = state.current
    if (!current.canFetch || current.fetching || current.fresh) return
    if (now - lastAttempt.current < RETRY_MS) return
    lastAttempt.current = now
    current.fetch()
  }, [])

  useEffect(() => {
    /*
     * Claude only, and this is a fact about the agents rather than a preference.
     *
     * `/usage` is a Claude Code command. Codex needs no equivalent — it writes
     * its limits into its rollout as it works, so the figures arrive on their
     * own and asking it for them would just be an unknown command at its prompt.
     * Every other agent is in the same position as Codex from this app's point
     * of view: this build has not been shown what, if anything, to ask them.
     */
    if (provider !== 'claude' || sessionId === '') return
    // A session's attempts do not carry over to the next session in the same
    // component: a bar moved from one pty to another is looking at a different
    // account's window and starts from nothing.
    lastAttempt.current = 0

    // A session that mounts already idle may never print again — a finished
    // agent sitting at its prompt is the commonest thing on this screen — so
    // the event stream alone would leave that bar empty for ever. One delayed
    // attempt, once, and then the events take over.
    let quiet: ReturnType<typeof setTimeout> | null = setTimeout(attempt, QUIET_MS)

    const bridge = dataBridge()
    const off =
      typeof bridge?.onSessionData === 'function'
        ? bridge.onSessionData((id) => {
            if (id !== sessionId) return
            if (quiet !== null) clearTimeout(quiet)
            quiet = setTimeout(attempt, QUIET_MS)
          })
        : null

    return () => {
      if (quiet !== null) clearTimeout(quiet)
      quiet = null
      off?.()
    }
  }, [attempt, provider, sessionId])
}
