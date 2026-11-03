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
 *
 * ## What changed on 2026-08-19: the two readings were separated
 *
 * `auto-usage.ts` was deleted today. It held the quiet-timer that kept the plan
 * figure fresh off the session's own output, and it is gone in Asad's own
 * words — first the ultimatum, over a bar reading two hours old:
 *
 *   > *"this is two hours ago my update. So if it will be like this and if we
 *   > need a cron to keep it updated then we need to completely remove it, we
 *   > don't need it at all."*
 *
 * and then, once the costs below had been measured for him, the settlement:
 *
 *   > *"no lets keep it in the dropdown and keep context outside"* … *"And we
 *   > will give an icon for it instead of title."*
 *
 * So there are two readings on this bar now and they are refreshed by opposite
 * rules, because they cost opposite amounts. Both figures were measured on this
 * machine on 2026-08-19 rather than reasoned about, and they are the entire
 * justification for the asymmetry — without them the next reader merges the two
 * back together:
 *
 *  - **The context window is free.** It is a bounded tail read of the JSONL the
 *    agent is already writing: 2–17 ms across three real project folders, no
 *    process, no network, and current by construction. That is why it sits
 *    permanently on the bar and is re-read on events — see
 *    {@link useContextWindow}, which holds no timer of any kind.
 *  - **A plan figure boots a whole Claude Code.** The control request in
 *    `usage-probe.ts` measured **725 MB peak RSS and about 3 seconds**. A full
 *    `claude -p "hi"` turn measured 481 MB, so the control request is the
 *    *heavier* of the two — it loads the same runtime and does not stream a
 *    short answer back. Nothing that costs that may be on a schedule.
 *  - **And it cannot be made fresher by asking twice.** The CLI throttles its
 *    own usage fetch to once every five minutes — `CLI_CACHE_WRITE_THROTTLE_MS`
 *    in `usage-probe.ts` — so two opens inside five minutes cannot produce two
 *    different numbers. Which is why every plan figure this hook hands over
 *    carries when it was *read*, and nothing in the panel implies "now".
 *
 * The rule the timer was written under has not changed and is not lost with it:
 * events over polling, in his words, because crons and timers *"make the system
 * heavier"*. What is different is that the only event worth spending 725 MB on
 * turns out to be a person opening the dropdown to look — so {@link check} is
 * called from there, and from nowhere else that is not a press.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { refreshOutcomeMessage } from '../chat/usage/usage-model'
import type { UsageRefreshOutcome } from '../chat/usage/types'
import {
  readContextReading,
  readUsageReport,
  type ContextReading,
  type UsageReport,
} from './usage-bar-model'
import { usageReach, withheldReason } from './usage-reach'
// Which computer to ask, turned into something to ask. The hooks below are
// written for one bridge and stay written for one bridge; this is what makes the
// one they get be the far machine's when the session is on a far machine.
import { useUsageBridge } from './usage-target'

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
  /**
   * How full the model's context window is, read off the transcript on disk.
   *
   * Optional like the rest: a build whose preload predates the channel has no
   * method here, and the honest answer to that is a bar with no figure on it
   * rather than a bar drawn from nothing.
   */
  contextWindow?(sessionId: string): Promise<unknown>
  /**
   * The session's own output, which is the event a context re-read hangs off.
   *
   * Named here rather than reached for through `globalThis` at the call site,
   * so that a test can hand this hook a whole bridge and drive it.
   */
  onSessionData?(cb: (id: string, data: string) => void): () => void
}

export function resolveUsageBarBridge(): UsageBarBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: UsageBarBridge }).deck
  if (!host || typeof host.watchUsage !== 'function' || typeof host.onUsage !== 'function') {
    return null
  }
  return host
}

/**
 * How long a refresh may be waited on before the bar stops saying it is running.
 *
 * See {@link useUsageBar}'s `check`, where the eighteen seconds is argued
 * against the main process's own fifteen-second kill.
 */
export const REFRESH_WAIT_CAP_MS = 18_000

/** What is said when the answer never came back at all. */
const GAVE_UP =
  'The check did not come back, so the figures below are the last ones that were read. Opening this again asks once more.'

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
   * True when the last refresh did not produce numbers.
   *
   * Separate from {@link blocked}, which is only set for the answers that will
   * not change for being asked again. This one covers the transient miss — a
   * probe that timed out, a reply that never came back — and it exists so the
   * panel can print {@link detail} for a failure without printing it for a
   * success. A sentence saying what the check did is worth reading when the
   * check failed; after a success it is a second way of saying what the numbers
   * beside it already say, which is the "one fact printed twice" this app's own
   * account chip was corrected for.
   *
   * The old figures stay on screen either way. A reading that was true twenty
   * minutes ago, labelled with its age, is worth more than a blank.
   */
  failed: boolean
  /**
   * Why this bar is not reading anything at all, when it is not.
   *
   * Set for a session that is **not on this computer**, and it is a different
   * claim from every other absence on this hook. {@link blocked} is a login that
   * has been asked and has settled; {@link failed} is a look that missed. This
   * one is the app declining to look, because what it would find is a reading of
   * a different machine's account — see `usage-reach.ts`, which holds the
   * decision and the wording.
   *
   * It suppresses the fetch as well as the figures. A bar that withheld its
   * numbers but still spent a 725 MB probe every time somebody opened the
   * dropdown would be paying the full cost of the feature for none of it.
   */
  withheld: string | null
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
 *
 * `target` is the third question the id alone cannot answer: **which computer**.
 * Absent means this one, as it does everywhere else in this cluster, and that is
 * why every caller written before remote sessions had controls keeps exactly the
 * behaviour it had. Where it is present the channel below is not opened at all —
 * `usage:watch` reaches this machine's tracker by this machine's session id, so
 * over a session on a paired PC it would answer with this laptop's own login's
 * limits under a bar drawn over somebody else's terminal.
 */
/**
 * What each session's bar last genuinely showed, so a switch does not blank it.
 *
 * ## The flicker this removes, measured rather than guessed
 *
 * Asad, 2026-08-20, clicking through his session list:
 *
 *   > *"when I switch … for one second here, something comes in the screen,
 *   > some third frame with some codes, and then it brings the new actual
 *   > session that I am clicking on … See, see, see, see, in all of them."*
 *
 * Part of that is the terminal and is not this file's. This half is: both hooks
 * below used to set their reading to `null` the instant `sessionId` changed and
 * then ask for it again, so every switch emptied the context bar and dropped the
 * ring to its "nothing reported" state for as long as the round trip took —
 * 100 ms for a local read, longer over the relay. A control that goes blank and
 * comes back is read as a control that broke, and it did it on *every* switch,
 * including switching back to a session whose figures this window had held two
 * seconds earlier.
 *
 * ## Why remembering is honest here, when it usually is not
 *
 * The rule this file keeps everywhere else — *"a settled answer belongs to the
 * login the old pty was running under"* — is about carrying one session's answer
 * onto **another** session. This does the opposite: it is keyed on the session,
 * so what comes back is that session's own last reading and nothing else's. And
 * these readings already say how old they are — every row on the panel carries
 * `read 8m ago`, and `usage-bar-model.ts` draws a window back once it has aged
 * past a twelfth of itself — so an old figure cannot pass itself off as a fresh
 * one. What replaces it is a live read, started in the same effect, exactly as
 * before.
 *
 * A session that is **withheld** is never seeded and never remembered: those
 * figures are not readings of what the bar is drawn over, which is the whole
 * argument in `usage-reach.ts`, and a cache of them would be that mistake with a
 * delay on it.
 *
 * ## Keyed on the computer as well as the session
 *
 * A session id is a pty on one machine. Two paired machines can hand out ids
 * from their own sequences, so the key carries which end it came from — the
 * same three cases `controls-target.ts` routes by.
 */
interface PlanMemo {
  report: UsageReport | null
  blocked: string | null
  noLimits: boolean
}

/**
 * Bounded, because a window that opens sessions all day would otherwise hold a
 * report for every one it has ever drawn. Insertion-ordered: re-remembering
 * moves an entry to the end, so what is dropped is the session nobody has
 * looked at for longest.
 */
const MEMO_CAP = 64
const LAST_PLAN = new Map<string, PlanMemo>()
const LAST_CONTEXT = new Map<string, ContextReading>()

function memoKey(sessionId: string, target: Parameters<typeof usageReach>[0]): string {
  if (target === undefined) return `here\u0000${sessionId}`
  return target.kind === 'machine'
    ? `machine\u0000${target.machineId}\u0000${sessionId}`
    : `server\u0000${sessionId}`
}

function remember<T>(store: Map<string, T>, key: string, value: T): void {
  store.delete(key)
  store.set(key, value)
  if (store.size <= MEMO_CAP) return
  const oldest = store.keys().next()
  if (!oldest.done) store.delete(oldest.value)
}

/** Test seam: the memo is module state, and a test that seeds one must clear it. */
export function forgetUsageMemos(): void {
  LAST_PLAN.clear()
  LAST_CONTEXT.clear()
}

export function useUsageBar(
  sessionId: string,
  injected?: UsageBarBridge,
  target?: Parameters<typeof usageReach>[0],
): UsageBarState {
  const [local] = useState<UsageBarBridge | null>(() => injected ?? resolveUsageBarBridge())
  /*
   * Which computer's readings these are, and the bridge that reaches it.
   *
   * The router hands back this window's own bridge for a local session and for a
   * server — the latter deliberately, because nothing is ever *asked* of it: the
   * three refusals below are keyed on `withheld`, and a server session is still
   * withheld. For a session on one of his own machines it hands back one that
   * speaks to that machine, and everything under this line goes on working
   * exactly as written, which is the point of routing the bridge rather than
   * branching the hook.
   */
  const bridge = useUsageBridge(target, local)
  const withheld = withheldReason(usageReach(target))
  /** Which session on which computer, for {@link LAST_PLAN}. */
  const memo = memoKey(sessionId, target)
  const [report, setReport] = useState<UsageReport | null>(
    () => (withheld === null ? (LAST_PLAN.get(memoKey(sessionId, target))?.report ?? null) : null),
  )
  const [checking, setChecking] = useState(false)
  const [detail, setDetail] = useState<string | null>(null)
  const [blocked, setBlocked] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)
  const [noLimits, setNoLimits] = useState(false)
  const live = useRef(true)

  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
    }
  }, [])

  useEffect(() => {
    /*
     * What this session itself last showed, not what the bar was showing a
     * moment ago — those are different things and only the first may be kept.
     *
     * A settled answer belongs to the login *that* pty was running under, so it
     * travels with the session and never across one: `blocked` and `noLimits`
     * come back with the report they were established alongside. `detail` and
     * `failed` deliberately do not — they describe one attempt, not the
     * session, and a stale failure would put a ⓘ on a bar that is about to
     * succeed. See {@link LAST_PLAN}.
     */
    const kept = withheld === null ? LAST_PLAN.get(memo) : undefined
    setReport(kept?.report ?? null)
    setDetail(null)
    setBlocked(kept?.blocked ?? null)
    setNoLimits(kept?.noLimits ?? false)
    setFailed(false)
    if (!bridge?.watchUsage || !bridge.onUsage || sessionId === '') return
    /*
     * Nothing is subscribed for a session that is not on this computer, and the
     * refusal is here rather than in the view for a reason the view could not
     * have enforced: `usage:watch` answers immediately with whatever this
     * machine's tracker already knows about this login, and every later push on
     * the channel is broadcast to every bar watching it. A component that merely
     * declined to *draw* what arrived would still be holding a live reading of
     * the wrong account, one prop change away from putting it on screen.
     */
    if (withheld !== null) return
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
    // `withheld` is a dependency and not merely a guard read inside the body,
    // because a pane can be re-pointed from a local session to a remote one
    // without unmounting. Without it here the subscription taken for the local
    // session would outlive the switch and go on pushing this login's readings
    // onto a bar that is now drawn over another machine's terminal.
  }, [bridge, memo, sessionId, withheld])

  /*
   * And what it settled on, kept against this session so switching back to it
   * does not blank the bar for the length of a round trip.
   *
   * Written from the rendered values rather than from each setter, so there is
   * one place that decides what is remembered and it cannot drift from what was
   * on screen. Nothing is stored for a withheld session — see {@link LAST_PLAN}
   * — and nothing is stored before there is anything to store, so a session that
   * has never answered leaves no entry and the next mount starts blank exactly
   * as it does today.
   */
  useEffect(() => {
    if (withheld !== null || sessionId === '') return
    if (report === null && blocked === null && !noLimits) return
    remember(LAST_PLAN, memo, { report, blocked, noLimits })
  }, [memo, report, blocked, noLimits, sessionId, withheld])

  /*
   * Never an endless spinner.
   *
   * `checking` is cleared by the promise settling, which is what happens in
   * every ordinary case including a failure — `refreshUsage` in the main process
   * kills its own probe at `PROBE_TIMEOUT_MS` (15 s) and answers with a sentence
   * rather than hanging. This exists for the case that answer never arrives at
   * all: a main process wedged behind something else, or a reply lost when the
   * window reloaded mid-flight. Eighteen seconds is deliberately *longer* than
   * the main process's own kill, so a probe that is merely slow is allowed to
   * finish and report properly, and only a reply that is never coming is given
   * up on.
   *
   * Giving up says so. The previous figure stays on screen with its age beside
   * it, because a reading that was true twenty minutes ago is worth more than a
   * blank, provided it admits how old it is.
   */
  const waited = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(
    () => () => {
      if (waited.current !== null) clearTimeout(waited.current)
    },
    [],
  )

  /*
   * What this call actually is, written here because it is no longer written on
   * his screen.
   *
   * The panel used to end with a paragraph explaining it, and Asad asked for it
   * gone — *"i dont want this inside"* — quoting it back word for word. He is
   * right that it is not a thing a person reading their own usage needs; he is
   * also not the person who will next change this mechanism, and every clause of
   * it was expensive to establish. So it moves to the call it describes:
   *
   *  - **It is fetched by Claude Code in this app's own process, and
   *    no session is typed into.** That is the whole of the 0.6.0 change: the
   *    predecessor, `plan:refresh`, typed `/usage` into the reader's live
   *    conversation and read the panel the CLI drew over it. He reported that
   *    three times.
   *  - **Opening the panel is what asks, so there is nothing to press.** A fresh
   *    figure costs a 725 MB Claude Code boot, measured, which is why it cannot
   *    be on a timer and why the person opening the panel is the only trigger
   *    worth spending it on. Since 2026-08-19 there are two ways to open it —
   *    hover and press — and `opensPlan` in `UsageBar.tsx` makes both of them
   *    fire this exactly once.
   *  - **The CLI will not fetch its own figure more than once every five
   *    minutes** — `CLI_CACHE_WRITE_THROTTLE_MS` in `usage-probe.ts`, read out
   *    of the binary — which is why every row in the panel says when it was
   *    *read* rather than implying "now", and why `refreshUsage` in the main
   *    process declines to start anything inside that window. Getting that gate
   *    wrong is what made his rows read `12m ago` on a panel whose whole premise
   *    is that opening it is the fetch: it used to skip the probe whenever any
   *    reading was still *drawable*, and a weekly reading stays drawable for
   *    fourteen hours.
   */
  const check = useCallback(
    (force = false) => {
      const ask = bridge?.refreshUsage
      if (!ask || sessionId === '') return
      /*
       * And the fetch stops too, not just the drawing.
       *
       * `refreshUsage` asks *this* machine's login what it has spent, so over a
       * remote session it would boot an agent CLI here — 725 MB, about three
       * seconds — to produce a figure the bar has already decided it must not
       * show. Spending that on an answer that is thrown away is the worst of
       * both halves of this feature.
       */
      if (withheld !== null) return
      setChecking(true)
      if (waited.current !== null) clearTimeout(waited.current)
      waited.current = setTimeout(() => {
        waited.current = null
        if (!live.current) return
        setChecking(false)
        setDetail(GAVE_UP)
        setFailed(true)
      }, REFRESH_WAIT_CAP_MS)
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
          setFailed(!result.ok)
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
          if (!live.current) return
          setDetail(refreshOutcomeMessage('unreadable'))
          setFailed(true)
        })
        .finally(() => {
          if (waited.current !== null) {
            clearTimeout(waited.current)
            waited.current = null
          }
          if (live.current) setChecking(false)
        })
    },
    [bridge, sessionId, withheld],
  )

  return {
    report,
    unwired: bridge === null,
    // False while withholding, so the bar draws no refresh affordance for a
    // reading it has declined to take. `UsageBar` builds `onOpen` off this, and
    // an `onOpen` that fired here would be the fetch this hook just refused.
    canCheck: withheld === null && typeof bridge?.refreshUsage === 'function' && sessionId !== '',
    checking,
    blocked,
    noLimits,
    detail,
    failed,
    withheld,
    check,
  }
}

/* -------------------------------------------------------------------------- */
/* The context window                                                          */
/* -------------------------------------------------------------------------- */

/**
 * The shortest gap between two reads of the transcript.
 *
 * A leading-edge throttle rather than a debounce, and the distinction is the
 * whole reason there is no `setTimeout` in the hook below. A debounce schedules
 * a callback for later — which is the shape `auto-usage.ts` had, and the shape
 * that was deleted today. A throttle asks "has it been long enough" when an
 * event arrives and then either reads or does not; nothing is ever queued, so
 * there is nothing to cancel, nothing to fire after unmount, and no timer in the
 * window at all.
 *
 * One second because the read is cheap but not free: measured at 2–17 ms per
 * folder on this machine, against an agent that can print several hundred times
 * a second. At one read a second a figure is at most one second behind the last
 * byte the agent wrote, and it costs about two thousandths of one core.
 */
export const CONTEXT_REREAD_MS = 1000

/**
 * `globalThis` rather than `window`: this hook's component is rendered to a
 * string by tests that have no `window` at all.
 */
function deckBridge(): UsageBarBridge | null {
  const host = (globalThis as unknown as { deck?: UsageBarBridge }).deck
  return host ?? null
}

/**
 * How full this session's context window is, kept current without a timer.
 *
 * ## Why this one may sit on the bar permanently
 *
 * Because it is a file read. The agent writes its own token counts into the
 * transcript as it works, so this app has only to look — 2–17 ms, no process,
 * no network, nothing to authenticate against, and no way for the figure to be
 * stale for a reason the reader cannot see. That is the opposite of the plan
 * figure beside it, which costs a 725 MB Claude Code boot to refresh, and the
 * asymmetry is why Asad put one outside the dropdown and one inside it. The
 * measurements are in this module's header.
 *
 * ## The three events, and why none of them is a clock
 *
 * The standing rule is events over polling — crons and timers *"make the system
 * heavier"*. Every read below is caused by something that actually happened:
 *
 *  1. **The bar mounted**, or moved to a different session. There is no figure
 *     yet and one look answers it.
 *  2. **The session printed.** An agent that has produced output has spent
 *     tokens; one that has been silent has not. Throttled by elapsed time rather
 *     than by a scheduled callback — see {@link CONTEXT_REREAD_MS}.
 *  3. **Somebody looked at the window.** `focus` and `visibilitychange` cover
 *     the case output cannot: a window left alone and come back to, whose
 *     session finished its last turn while nobody was watching.
 *
 * What this deliberately does not do is chase the last byte of a burst. The
 * throttle reads on the leading edge, so after output stops the figure can be up
 * to one read-interval behind what the transcript now says. That is a second of
 * lag on a number that moves once per agent turn, and it is corrected by the
 * next output, by the window being focused, or by the dropdown being opened. The
 * alternative is a trailing timer, and a trailing timer is the thing that was
 * removed today.
 *
 * ## And the one session it will not read at all
 *
 * The file it looks in is on **this** disk, found by a transcript id that this
 * machine's own agent wrote into a folder this machine can see. A session on a
 * paired PC or in a terminal on a server has neither, so the read either finds
 * nothing or — worse, and this is the case that made it a defect rather than a
 * gap — finds a *different* conversation that happens to share the id or the
 * folder, and puts its token count under somebody else's terminal. `target` is
 * how the bar says which computer, and `usage-reach.ts` is what it means.
 */
export function useContextWindow(
  sessionId: string,
  injected?: UsageBarBridge,
  target?: Parameters<typeof usageReach>[0],
): ContextReading | null {
  const [local] = useState<UsageBarBridge | null>(() => injected ?? deckBridge())
  // The same routing the plan half above does, and it has to be the same: two
  // hooks reading one session must never disagree about which computer they are
  // asking. `usage-target.ts` is the one place that knows.
  const bridge = useUsageBridge(target, local)
  const withheld = withheldReason(usageReach(target))
  /** Which session on which computer, for {@link LAST_CONTEXT}. */
  const memo = memoKey(sessionId, target)
  const [reading, setReading] = useState<ContextReading | null>(
    () => (withheld === null ? (LAST_CONTEXT.get(memoKey(sessionId, target)) ?? null) : null),
  )
  const live = useRef(true)
  /** When the last read was *started*, so a burst of output cannot stack them. */
  const lastAt = useRef(0)

  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
    }
  }, [])

  const read = useCallback(
    (force: boolean): void => {
      const ask = bridge?.contextWindow
      if (typeof ask !== 'function' || sessionId === '') return
      // Nothing is asked for a session on another computer. The figure that
      // would come back is about a transcript on this disk, and this bar is not
      // drawn over anything on this disk.
      if (withheld !== null) return
      const at = Date.now()
      if (!force && at - lastAt.current < CONTEXT_REREAD_MS) return
      lastAt.current = at
      void ask
        .call(bridge, sessionId)
        .then((payload) => {
          const next = readContextReading(payload)
          /*
           * A payload that does not parse leaves the previous figure alone
           * rather than blanking the bar. The two are different claims: an
           * unreadable reply is this app failing to understand an answer, and a
           * blank bar is this app saying the agent reports no context. Only one
           * of those is true when a build's main process predates the channel.
           */
          if (live.current && next) setReading(next)
        })
        .catch(() => {
          /*
           * Swallowed on purpose, and it is the same argument. The channel
           * throws for a session that is not running here and for a build that
           * has no handler, and neither is news the bar can act on — the reading
           * it already has, or the nothing it already shows, is the honest
           * answer in both cases. The main process's own failures come back as
           * a reading with a sentence in it, not as a rejection.
           */
        })
    },
    // `withheld` among the dependencies, so a pane re-pointed from a local
    // session to a remote one rebuilds this and the effect below clears the
    // figure it had. Left out, the last local reading would sit on the bar over
    // the remote session for as long as nothing else changed.
    [bridge, sessionId, withheld],
  )

  /*
   * A new session is a different conversation, so the *previous* session's
   * figure has to go — it is about somebody else. What replaces it is not a
   * blank but this session's own last figure, if this window has one: keyed on
   * the session, so nothing crosses between them, and superseded by the read
   * started on the next line. Before this, every switch emptied the context bar
   * for the length of a round trip and put it back, which is the flicker he
   * filmed. See {@link LAST_CONTEXT}.
   *
   * For a withheld session the clearing is still the whole of what happens:
   * `read` returns without asking and nothing was ever remembered, so the bar
   * keeps no figure at all rather than the one it had before the switch.
   */
  useEffect(() => {
    setReading(withheld === null ? (LAST_CONTEXT.get(memo) ?? null) : null)
    lastAt.current = 0
    read(true)
  }, [memo, read, withheld])

  /* And this session's own figure, kept for the next time it is looked at. */
  useEffect(() => {
    if (withheld !== null || reading === null) return
    remember(LAST_CONTEXT, memo, reading)
  }, [memo, reading, withheld])

  useEffect(() => {
    const off = bridge?.onSessionData?.((id) => {
      if (id === sessionId) read(false)
    })
    return () => off?.()
  }, [bridge, read, sessionId])

  useEffect(() => {
    if (typeof window === 'undefined') return
    const wake = (): void => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
      read(false)
    }
    window.addEventListener('focus', wake)
    document.addEventListener('visibilitychange', wake)
    return () => {
      window.removeEventListener('focus', wake)
      document.removeEventListener('visibilitychange', wake)
    }
  }, [read])

  return reading
}
