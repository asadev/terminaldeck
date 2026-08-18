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
 * There are only one-shots in here, never an interval: the debounce that decides
 * output has stopped, the single delayed first attempt for a session that mounts
 * already idle and may never print again, and — new on 2026-08-18 — a short,
 * bounded run of retries after an attempt is *refused*.
 *
 * ## What a refusal is, and what it is not
 *
 * This distinction is the whole of the second half of the 2026-08-18 fix, and
 * everything below it depends on getting it right.
 *
 * A **refusal** is the main process declining to type at all: the session is
 * mid-answer, or its prompt box has half a line in it. Nothing was spent, the
 * state clears itself in seconds, and trying again shortly is exactly right.
 *
 * A **failure** is an attempt that typed. `/usage` went into somebody's prompt
 * and Claude Code drew its panel over their conversation, and it came back with
 * nothing to show for it. That is not something to do again on a timer. Asad
 * sent fifteen seconds of his Windows screen doing precisely that — the panel
 * open over a live session, the CLI still scanning, `Usage Reading…` in the bar
 * — with one line: *"this is what keeps happening repeatedly."*
 *
 * So a failure ends it. `blocked` arrives with the sentence saying which failure
 * it was, this hook stops, the bar says so, and the only thing that starts it
 * again is a person pressing — which `refresh()` in the main process enforces
 * independently, so a window that reloaded cannot walk past it.
 *
 * ## The hole the run of retries closes
 *
 * Measured: a session can sit with an empty usage bar for a minute and a half
 * from a cold start, and in the worst case for ever. The sequence is ordinary
 * rather than exotic:
 *
 *  1. The bar mounts and the one delayed attempt fires 1.4 seconds later.
 *  2. The CLI is still printing its banner, so `refresh()` in
 *     `src/main/plan-limit.ts` refuses with `busy` — it will not type into a
 *     session that has not been quiet for a second.
 *  3. That attempt nonetheless stamped `lastAttempt`, so the {@link RETRY_MS}
 *     floor now suppresses everything for twenty seconds.
 *  4. Output stops three seconds in. The debounce fires at 4.4s, is inside the
 *     floor, and is dropped.
 *  5. **Nothing else ever happens.** An agent sitting at its prompt prints
 *     nothing, and `session:data` was the only thing that could have tried
 *     again.
 *
 * The correction is not a timer where there was none — it is that a refusal is
 * no longer treated as an attempt that was *spent*. `refusals` comes back from
 * `useUsageBar`, the floor is released, and one more attempt is armed a few
 * seconds out, up to three times. Every refusal this can see is a state that
 * clears itself in seconds — output stopping, a prompt being finished, a panel
 * arriving late — so three tries either finds one of those or has established
 * that something else is wrong, and there is no fourth. After that the bar waits
 * on real events again, and it says on its face that it is waiting.
 *
 * Three, and not "keep going": a retry that never gives up is a poll with extra
 * steps, and this one types into somebody's terminal.
 *
 * ## The other event, which is a person rather than a process
 *
 * Somebody bringing the window forward is as real an event as a byte of output,
 * and it is the one that covers the case output cannot: a session whose prompt
 * had half a sentence in it when the retries ran out, left alone, and come back
 * to an hour later. `focus` and `visibilitychange` therefore attempt as well,
 * under exactly the same gates — nothing happens if a reading is already live,
 * if one is in flight, or if the floor has not elapsed.
 *
 * ## Why it is safe to type into somebody's session unasked
 *
 * Because the main process refuses in every case where it would not be. See
 * `refresh()` in `src/main/plan-limit.ts`: it will not run unless the session
 * has been quiet for a second *and* its prompt box is empty, so it cannot
 * append `/usage` to half-typed text and it cannot interrupt a working agent.
 * When it does run, it closes the panel again with Escape — and, since
 * 2026-08-18, *reads the screen back to check that the panel went*, which is the
 * half that was missing and the half the whole complaint was about. A close it
 * cannot confirm is escalated once and then reported as residue, which stops
 * this hook for good.
 *
 * A refusal that typed nothing is still dropped on the floor here: a refusal of
 * something nobody pressed is not news, and the state it leaves behind is
 * already described in words on the bar. That is the difference between this and
 * the button — the button had to explain itself when it failed, because a person
 * had pressed it.
 *
 * A *failure* is not dropped, and that is the one place the old reasoning was
 * wrong. Nobody pressed it, but somebody can see it: `/usage` went into their
 * prompt and a panel went over their conversation. So it stops, and it says so.
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
 *
 * It applies to attempts that were *made*, and a refused one is released from it
 * the moment the refusal comes back — see the note at the top of this file for
 * the ninety seconds of empty bar that cost. Which is the right reading of what
 * this is for: it is a floor on how often this app types into somebody's
 * terminal, and a refusal means it did not.
 */
const RETRY_MS = 20_000

/**
 * How long to wait after a refusal before trying once more, in order.
 *
 * Three, then stop. Every refusal reachable from here is a state that clears
 * itself in seconds — `busy` is output that has not stopped, `prompt-busy` is a
 * half-typed line, `no-panel` is a CLI that did not draw its panel inside eight
 * — so a couple of seconds is usually enough and eighteen is generous. What
 * happens after the third is deliberate and is the whole reason this is a list
 * and not a formula: nothing. The bar goes back to waiting on real events, and
 * says so.
 */
const AFTER_REFUSAL_MS = [2_000, 6_000, 12_000] as const

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
  /**
   * How many attempts have been refused in a row, from {@link UsageBarState}.
   *
   * Read as an *event* rather than as a number: every increment is one refusal
   * arriving, and what this hook does with it is release the retry floor and arm
   * one more try. A counter is what makes that possible — two refusals in a row
   * carry the same sentence, so a string would look unchanged, and a boolean
   * would already be true.
   */
  refusals: number
  /**
   * Set once this session has had an attempt that typed and found nothing.
   *
   * The stop. Not a delay and not a longer floor — while this is set, nothing
   * here types into the session again for the life of the session, whatever
   * events arrive. See the note at the top of this file for why a failure and a
   * refusal are different things, and `useUsageBar`, which decides which one
   * happened from whether the main process got as far as typing.
   */
  blocked: string | null
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
  refusals,
  blocked,
}: AutoUsageOptions): void {
  const lastAttempt = useRef(0)
  /**
   * How many of the refusal-driven retries have been armed for this session.
   *
   * A ref and not state, because arming one must not re-render a toolbar. It
   * indexes {@link AFTER_REFUSAL_MS}, and running past the end of that list is
   * how this stops: three tries, then the bar waits on real events again.
   */
  const retries = useRef(0)
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
  const state = useRef({ canFetch, fetching, fresh, fetch, blocked })
  state.current = { canFetch, fetching, fresh, fetch, blocked }

  const attempt = useCallback((): void => {
    const now = Date.now()
    const current = state.current
    // First, and unconditional: a session that has already been typed into for
    // nothing is not typed into again by anything except a person. Every other
    // gate below is about *when*; this one is about *whether*.
    if (current.blocked !== null) return
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
    retries.current = 0

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

  /*
   * A refusal, and what it leaves behind.
   *
   * Two things, and the first matters more than the second. The floor is
   * released, so the *next* real event — the session printing a byte, somebody
   * bringing the window forward — can try immediately rather than being dropped
   * for the remainder of twenty seconds. That alone fixes the ordinary cold
   * start, where output is still flowing when the first attempt lands and stops
   * a moment later.
   *
   * The second is for the session that goes silent and stays silent, which is
   * most of them: one more attempt, armed a few seconds out, up to three times.
   * The bound is the point — see {@link AFTER_REFUSAL_MS}. It is a retry of a
   * failed operation, not a schedule, and it ends.
   *
   * `refusals === 0` is the ordinary state and also the state after a check that
   * ran, so nothing is armed then.
   */
  useEffect(() => {
    if (provider !== 'claude' || sessionId === '' || refusals === 0) return
    // A refusal that arrived alongside a stop is a failure wearing a refusal's
    // clothes — the count goes up for both — and arming a retry off it would put
    // the panel back on somebody's screen a few seconds after this app had
    // finally taken it off.
    if (blocked !== null) return
    // A refused attempt was not an attempt. Whatever else happens below, the
    // next event is allowed to try.
    lastAttempt.current = 0
    if (retries.current >= AFTER_REFUSAL_MS.length) return
    const wait = AFTER_REFUSAL_MS[retries.current] ?? 0
    retries.current += 1
    const timer = setTimeout(attempt, wait)
    return () => clearTimeout(timer)
  }, [attempt, blocked, provider, refusals, sessionId])

  /*
   * Somebody looking at the window is an event too.
   *
   * The one case the session's own output cannot cover: the retries above ran
   * out while the prompt had half a line in it, the window was left alone, and
   * it is being looked at again now. A person returning to a window is exactly
   * when a stale or missing reading is worth spending a `/usage` on, and it is
   * the cheapest honest trigger there is — no timer, no subscription, no cost
   * while nobody is there.
   *
   * `attempt` carries every gate with it, so this cannot become a way to spam a
   * terminal: it does nothing when the reading is already live, when one is in
   * flight, when the feature is off, or inside the retry floor. Both events are
   * listened for because they answer different questions — `focus` is this
   * window coming forward, `visibilitychange` is the app being shown at all —
   * and either one arriving is the same news.
   */
  useEffect(() => {
    if (provider !== 'claude' || sessionId === '' || typeof window === 'undefined') return
    const wake = (): void => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
      attempt()
    }
    window.addEventListener('focus', wake)
    document.addEventListener('visibilitychange', wake)
    return () => {
      window.removeEventListener('focus', wake)
      document.removeEventListener('visibilitychange', wake)
    }
  }, [attempt, provider, sessionId])
}
