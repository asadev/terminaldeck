/**
 * Keeping the usage figure fresh without being asked to, and without typing.
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
 * And then, three complaints later, on how this file used to satisfy that:
 *
 *   > *"find out some other way to keep the bar refresh otherwise we will remove
 *   > it completely if it will be heavy"*
 *
 * Both are honoured now, which they could not be before. Until 2026-08-18 the
 * only way to make Claude Code state its limits was to type `/usage` into one of
 * its terminals, so "appear on its own" and "stop interrupting me" were in
 * direct conflict and this file was where the conflict was managed — a debounce,
 * a floor, a bounded run of retries, a hard stop after any attempt that had
 * typed. Every one of those existed to ration something expensive.
 *
 * The fetch is not expensive any more. `usage:refresh` reads what Claude Code
 * already wrote into `.claude.json`, and only when that has gone stale does it
 * start a `claude` of this app's own — in the user's home directory, for about
 * four seconds, for no tokens. See `usage-probe.ts`, where the cost of both
 * paths is measured rather than asserted. So the rationing is gone and what is
 * left is the plain question: when is it worth looking?
 *
 * ## Why this is still not a timer
 *
 * The standing rule in this project is events over polling — his words, more
 * than once: crons and timers *"make the system heavier"*. Nothing pushes a
 * usage figure, so there is no event that says "the number moved". But there is
 * an event that means the number moved: **the session printed something**. An
 * agent that has produced output has spent tokens, and one that has been silent
 * has not. So the refresh is driven off `session:data` going quiet, which is the
 * same signal `useSessionControls` already re-reads the model and effort on, and
 * for the same reason.
 *
 * There are only one-shots in here, never an interval: the debounce that decides
 * output has stopped, and the single delayed first attempt for a session that
 * mounts already idle and may never print again.
 *
 * ## The other event, which is a person rather than a process
 *
 * Somebody bringing the window forward is as real an event as a byte of output,
 * and it is the one that covers the case output cannot: a session left alone
 * with a stale figure and come back to an hour later. `focus` and
 * `visibilitychange` therefore attempt as well, under exactly the same gates.
 *
 * A window with four panes on one login wakes four of these in the same tick.
 * That is deliberately not solved here: `refreshUsage` in the main process pools
 * by login, so the second, third and fourth get the first one's promise and one
 * process is started for the four of them. Solving it twice, in two places, is
 * how the two come to disagree about which login a bar is on.
 *
 * ## What is gone
 *
 * The run of retries after a refusal, the twenty-second floor between attempts,
 * and the hard stop after an attempt that typed. All three were about spending
 * somebody's terminal carefully. Nothing here spends a terminal, the main
 * process holds the only restraint that still matters — one probe per login per
 * minute, and none at all for a login already known to have no subscription
 * limits — and a second opinion about that in the renderer would be a second
 * thing to keep in step.
 */

import { useCallback, useEffect, useRef } from 'react'
import type { ProviderId } from '@shared/types'

/**
 * How long the session must be quiet before a refresh is attempted.
 *
 * `useSessionControls` waits 400ms for the same event, which is right for a read
 * of the screen. This one may start a process, so it waits longer — long enough
 * that a session printing in bursts settles once rather than four times.
 */
const QUIET_MS = 1400

/**
 * Whether a bar over this session may go and look without being asked to.
 *
 * ## The gate this replaces
 *
 * Until 2026-08-19 both effects below opened with `provider !== 'claude'`, and
 * the paragraph justifying it read:
 *
 *   > *Claude only, and this is a fact about the agents rather than a
 *   > preference. `usage:refresh` drives Claude Code. Codex needs no equivalent
 *   > — it writes its limits into its rollout as it works, so the figures arrive
 *   > on their own. Every other agent is in the same position as Codex from this
 *   > app's point of view: this build has not been shown what, if anything, to
 *   > ask them.*
 *
 * Every sentence of that is still true and none of it is why the gate was
 * wrong. The mistake is in what the word `provider` means *here*.
 *
 * ## What it actually means here
 *
 * Not the session record. `SessionControls` hands `UsageBar` the answer
 * `runningProvider` gives, and that function exists to turn `shell` into
 * `undefined` — "this app never saw which CLI was typed" — once the screen says
 * an agent is there. So the session shape Asad works in most, a `$SHELL -l`
 * with `claude` typed at its prompt (the thing the account chip's own Run
 * button types for you), arrives here as `undefined` and was turned away by a
 * gate that was only ever meant to turn away Codex and Gemini.
 *
 * The consequence was not subtle. That bar mounted, subscribed and never
 * initiated a single look of its own. It filled in when some *other* session on
 * the same login went and probed, or from whatever `.claude.json` already held;
 * on a machine whose only session is `claude` typed at a shell it sat at "Not
 * reported" indefinitely — which is *"usage should appear on its own, not need
 * a click"* not happening, on the exact case it was asked for.
 *
 * ## Why this set, and why written as an allowlist
 *
 * Because the far end already answers this question and its answer is the one
 * that decides what comes back. `mayShareClaude` in `src/main/usage-ipc.ts`
 * accepts a session it cannot describe, a `claude` and a `shell` — the argument
 * for the shell case is written out beside it — and `refreshUsage` turns
 * everything else away with *"This session runs a different agent"* before it
 * reads a byte. A renderer gate stricter than that suppresses a fetch the main
 * process would have served, which is precisely what this was doing; a looser
 * one spends a round trip to be told no. So: the same set, with `undefined`
 * standing where the main process has `session === null`, because the two mean
 * the same thing — nobody here knows which CLI is in there, and a session like
 * that runs under the machine's own Claude install, which is the account these
 * readings are of.
 *
 * An allowlist rather than "not Codex and not Gemini" for the reason the main
 * process uses one: `ProviderId` includes `custom:${string}`, so a build that
 * learns a new agent tomorrow must not have it fall through to the permissive
 * side of a gate written before it existed. Two places, one shape, and the
 * shape is the part that has to go on agreeing.
 *
 * Nothing this opens can type into anybody's terminal — that was the 2026-08-18
 * change, and `usage-probe.ts` measures what is left of the cost: a file read
 * and, at worst, one `claude` of this app's own in the user's home directory,
 * about four seconds, no tokens.
 */
export function mayFetchFor(provider: ProviderId | undefined): boolean {
  return provider === undefined || provider === 'claude' || provider === 'shell'
}

export interface AutoUsageOptions {
  sessionId: string
  /**
   * What the bar is *treating* this session as, which is not the same thing as
   * what the app spawned. `undefined` is a real answer and on Asad's machine it
   * is the commonest one — see {@link mayFetchFor}, which is the only thing in
   * here that reads it.
   */
  provider?: ProviderId
  /**
   * Whether this build can refresh at all.
   *
   * False in a build whose preload has no `usage:refresh`, in which case there
   * is nothing to attempt and the bar says so in words instead.
   */
  canFetch: boolean
  /** A refresh is already in flight. */
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
  /** Runs `usage:refresh`. The action `useUsageBar` already exposes. */
  fetch: () => void
  /**
   * Set once this login has given an answer that will not change.
   *
   * No subscription limits, not signed in, no `claude` on the machine. Not a
   * restraint — the main process holds that, and holds it against the *account*
   * rather than the session, which is where it belongs — but there is no reason
   * to keep asking a question that has been answered, and the bar is already
   * saying so on its face.
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
  blocked,
}: AutoUsageOptions): void {
  /*
   * Everything the attempt reads, kept in a ref rather than in the effect's
   * dependencies.
   *
   * The subscription below must survive a report landing, a percentage moving
   * and a refresh starting — all of which change these values several times a
   * minute. Listed as dependencies they would tear down and re-establish the
   * `session:data` listener each time, and a listener that is re-installed
   * during the very burst of output it is waiting to see is a listener whose
   * debounce never completes.
   */
  const state = useRef({ canFetch, fetching, fresh, fetch, blocked })
  state.current = { canFetch, fetching, fresh, fetch, blocked }

  const attempt = useCallback((): void => {
    const current = state.current
    if (current.blocked !== null) return
    if (!current.canFetch || current.fetching || current.fresh) return
    current.fetch()
  }, [])

  useEffect(() => {
    // Which sessions look for themselves, and why this is no longer the
    // `provider === 'claude'` it was written as: {@link mayFetchFor}, which
    // holds the whole argument and the main-process answer it now matches.
    if (!mayFetchFor(provider) || sessionId === '') return

    // A session that mounts already idle may never print again — a finished
    // agent sitting at its prompt is the commonest thing on this screen — so
    // the event stream alone would leave that bar empty for ever. One delayed
    // attempt, once, and then the events take over. It is also what makes the
    // free path pay: the first thing `usage:refresh` does is read the file, so
    // a bar over a login another session already read fills in from disk
    // without anything being started at all.
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
   * Somebody looking at the window is an event too.
   *
   * The one case the session's own output cannot cover: a window left alone
   * while its figure went stale, and looked at again now. A person returning to
   * a window is exactly when a missing figure is worth a few hundred
   * milliseconds, and it is the cheapest honest trigger there is — no timer, no
   * subscription, no cost while nobody is there.
   *
   * `attempt` carries every gate with it, so this cannot become a way to spam
   * anything: it does nothing when the reading is already live, when one is in
   * flight, or when the feature is off. Both events are listened for because
   * they answer different questions — `focus` is this window coming forward,
   * `visibilitychange` is the app being shown at all — and either one arriving
   * is the same news.
   */
  useEffect(() => {
    if (!mayFetchFor(provider) || sessionId === '' || typeof window === 'undefined') return
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
