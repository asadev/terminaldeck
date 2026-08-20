/**
 * Which computer the usage bar's two figures are read from, and how to reach
 * one that is not this one.
 *
 * ## What this is beside
 *
 * `controls-target.ts` routes the *controls* on this bar to whichever machine
 * the session is actually on. This routes the *readings* beside them, and it is
 * a separate file for the same reason that one is a file rather than a branch in
 * each hook: two hooks read these values — the plan report and the context
 * window — and they must never disagree about which computer they are asking.
 * One place that knows how to reach a session is what stops that happening per
 * target instead of per component.
 *
 * ## Why it hands back a *bridge* rather than a fetch
 *
 * Because the shape of the application must not change between local and remote
 * — the rule argued at the top of `src/main/localhost-reach.ts` — and the
 * cheapest way to honour that is to leave the hooks written exactly as they were
 * for the local case and swap what they are talking to. `useUsageBar` still
 * subscribes, still refreshes, still gives up after its own deadline;
 * `useContextWindow` still re-reads on output, focus and mount. Neither knows
 * that anything crossed a relay. A second code path for remote would be a second
 * set of rules about when to look, and the rules about when to look are the
 * entire cost model of this feature.
 *
 * ## The cost model, which is the reason this file exists at all
 *
 * Measured on this machine on 2026-08-19, and the asymmetry decides the design
 * rather than decorating it:
 *
 *  - **A plan figure costs 725 MB and about three seconds** on the machine being
 *    asked, because getting a fresh one boots a whole Claude Code there. That is
 *    affordable exactly once — when a person opens the panel to read it, which
 *    is the same event that spends the same amount locally. So `refresh` is
 *    reached from {@link UsageBarBridge.refreshUsage} and from nowhere else, and
 *    `useUsageBar` calls that only from `check`, which `UsageBar.tsx` wires to
 *    opening the panel and to the retry button inside it. Nothing on a mount, an
 *    attach, a focus or a timer can reach it.
 *  - **What that machine already knows is free** — memory, plus one file for a
 *    Codex login — so a bar mounting asks for that, and gets a figure without
 *    starting anything.
 *  - **The context window is free**, 2–17 ms over there, so it rides the same
 *    events the local one rides: mount, the session printing, the window being
 *    focused.
 *
 * ## And the case that is not waiting on any of this
 *
 * A server. It does not run this app, so there is no account signed in there to
 * have limits and no transcript on this side to read a context window from. That
 * stays withheld with a sentence, permanently and correctly, and this module
 * hands those sessions the ordinary local bridge precisely so that
 * `useUsageBar`'s existing refusals — which are keyed on `withheld` — go on
 * refusing exactly as they did.
 */

import { useMemo } from 'react'
import type { ControlsTarget } from './controls-target'
import type { UsageBarBridge } from './useUsageBar'

/**
 * The bridge methods this router reaches for, as loosely as the rest of the
 * renderer reads the preload.
 *
 * Optional, because a build whose preload predates the channel must produce a
 * bar that says it has nothing rather than one that throws on mount — and
 * because the shell's components are rendered to a string in their own tests,
 * where there is no preload at all.
 */
interface MachineBridge {
  readMachineUsage?(machineId: string, sessionId: string, want: string, force: boolean): Promise<unknown>
  onMachineOutput?(cb: (chunk: unknown) => void): () => void
}

/**
 * `globalThis` rather than `window`, for the reason `controls-target.ts` gives:
 * this bar is rendered to a string by tests that have no `window` at all, and
 * reading it during render throws and takes the whole bar down.
 */
function deck(): MachineBridge | undefined {
  return (globalThis as unknown as { deck?: MachineBridge }).deck
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * What is said when this build cannot reach another machine's usage at all.
 *
 * A sentence rather than a null, because the bar has no previous figure to keep
 * the way the control chips beside it do: an element that is simply absent, with
 * the account of why one press away, has already been read as a broken feature
 * on this exact bar.
 */
const UNREACHABLE = 'This build has no way to read that machine’s usage.'

/**
 * A reading with no figure in it, carrying the sentence that says why.
 *
 * The renderer's own copy of `emptyUsageReading` in `src/main/remote/protocol.ts`
 * and deliberately a small one: the only case that reaches here is a preload
 * with no such method, which the main process cannot answer for because it was
 * never asked. Every other absence — a link that is down, a machine too old for
 * the capability, a host that refused — is composed on the main side, where the
 * sentence can say something specific about *which* machine.
 */
function unreachable(want: 'plan' | 'refresh' | 'context'): Record<string, unknown> {
  if (want === 'context') {
    return { provider: null, state: 'not-reported', detail: UNREACHABLE, observedAt: Date.now() }
  }
  const report = { sessionId: null, readings: [], reason: UNREACHABLE, account: null, assembledAt: Date.now() }
  return want === 'plan' ? report : { ok: false, outcome: 'unwatched', detail: UNREACHABLE, report }
}

/**
 * A usage bridge that reads one paired machine instead of this computer.
 *
 * Built per machine rather than per session, exactly like the local bridge it
 * stands in for: one window can have several bars on one machine's sessions, and
 * each is told which session it is about on every call.
 *
 * The `onUsage` half is a local emitter rather than a wire subscription, and
 * that is the honest shape of what is available. There is no push on this wire —
 * the far machine has no idea when another window's bar cares, and a desktop
 * that volunteered readings would be sending frames about an account nobody is
 * looking at. So the only thing that ever arrives is the report that comes back
 * *with* a refresh, and this hands it to the same listener the local push would
 * have gone to.
 */
function machineUsageBridge(machineId: string): UsageBarBridge {
  const listeners = new Set<(sessionId: string, payload: unknown) => void>()

  const read = async (
    sessionId: string,
    want: 'plan' | 'refresh' | 'context',
    force: boolean,
  ): Promise<unknown> => {
    const ask = deck()?.readMachineUsage
    if (typeof ask !== 'function') return unreachable(want)
    return await ask(machineId, sessionId, want, force)
  }

  return {
    /*
     * Mounting asks for what that machine already knows, and nothing more.
     *
     * This is the call that would have ruined the feature if it had been wired
     * to `refresh`: it runs on every bar that mounts and again whenever a pane
     * is re-pointed, so a 725 MB boot behind it would mean a tab costing three
     * quarters of a gigabyte on somebody else's computer to open. What comes
     * back instead is that machine's own current figure for the login — which is
     * the same number its own window is showing — read out of memory.
     */
    watchUsage: (sessionId) => read(sessionId, 'plan', false),
    // Nothing was subscribed over there, so there is nothing to release.
    unwatchUsage: () => {},
    onUsage: (cb) => {
      listeners.add(cb)
      return () => {
        listeners.delete(cb)
      }
    },
    /**
     * The one call that spends anything, and it is reached only from
     * `useUsageBar`'s `check` — which `UsageBar.tsx` wires to a person opening
     * the panel and to the retry button inside it.
     *
     * `force` travels rather than being assumed. It is what reaches past the far
     * machine's own five-minute throttle and past a login that has settled on
     * "no subscription limits", and assuming it would turn every ordinary open
     * into a spawn on that machine.
     */
    refreshUsage: async (sessionId, force) => {
      const answer = await read(sessionId, 'refresh', force === true)
      /*
       * The report rides back with the outcome, so it is unwrapped here and
       * handed to the listeners the local push would have reached. One round
       * trip carries both halves because a second one would be a second chance
       * for the half with the numbers in it to go missing — and the hook would
       * then show a successful check with nothing to show for it.
       */
      const report = isRecord(answer) && isRecord(answer.report) ? answer.report : null
      if (report !== null) {
        for (const listener of [...listeners]) listener(sessionId, report)
      }
      return answer
    },
    contextWindow: (sessionId) => read(sessionId, 'context', false),
    /**
     * The far session's own output, which is the event a context re-read hangs
     * off — the same event the local figure hangs off, so the two surfaces cost
     * the same and are equally current.
     *
     * Filtered by machine here and by session in the hook, which is the split
     * `watchSessionOutput` in `controls-target.ts` makes for the same channel:
     * one machine's chunks and another's arrive together, and two machines can
     * be showing sessions whose ids this window has never had reason to keep
     * apart. The session id is passed on rather than compared, because this
     * bridge stands in for one that is session-agnostic and the caller already
     * knows which session it asked about.
     */
    onSessionData: (cb) => {
      const on = deck()?.onMachineOutput
      if (typeof on !== 'function') return () => {}
      return on((chunk) => {
        if (!isRecord(chunk)) return
        if (chunk.machineId !== machineId) return
        /*
         * Replayed scrollback is skipped. It arrives in a burst on every attach
         * — the whole of the far session's buffer — and each chunk of it would
         * arm another read of a transcript that has not moved since the last
         * one. The read that matters is the one after the *live* bytes, which is
         * exactly what the burst is followed by.
         */
        if (chunk.replay === true) return
        const sessionId = typeof chunk.sessionId === 'string' ? chunk.sessionId : null
        if (sessionId === null) return
        cb(sessionId, '')
      })
    },
  }
}

/**
 * The bridge the usage hooks should talk to for this session.
 *
 * `undefined` — the target absent — means this computer, which is what every
 * caller written before remote sessions had controls meant, so the local path is
 * untouched by construction rather than by care. A server gets the local bridge
 * too, and deliberately: nothing on it is ever *asked*, because
 * `useUsageBar`'s refusals are keyed on `withheld` and a server session is still
 * withheld. Handing it a null bridge instead would make the bar report itself
 * unwired, which is a different and false claim — a build with no usage channel
 * at all rather than one declining to look.
 *
 * Memoised on the machine's id so that the adapter — which holds the listener
 * set the refresh answers are delivered through — survives a re-render. A fresh
 * object each render would re-run the subscription effect keyed on it every
 * time, which is a re-subscribe loop rather than an optimisation problem.
 */
export function useUsageBridge(
  target: ControlsTarget | undefined,
  base: UsageBarBridge | null,
): UsageBarBridge | null {
  const machineId = target?.kind === 'machine' ? target.machineId : null
  return useMemo(
    () => (machineId === null ? base : machineUsageBridge(machineId)),
    [machineId, base],
  )
}
