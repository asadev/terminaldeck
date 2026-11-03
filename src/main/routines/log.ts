/**
 * What a routine did, in the copilot's own action log.
 *
 * There is no second file here, and that is the whole content of this module.
 * Asad's framing for the feature was one system rather than two — *"routines run
 * through the copilot, not beside it"* — and `COPILOT-DESIGN.md` names exactly
 * one place the answer to "what did my machine do overnight" is kept:
 * `<userData>/copilot/log/actions.jsonl`. A routines log beside it would
 * immediately raise the question of which one to read first, and a person
 * chasing a session they did not start would have to read both and interleave
 * them by timestamp.
 *
 * So the writing is `copilot-home.ts`'s `appendCopilotAction`, unchanged. That
 * matters for a duller reason too: that file is rolled at four megabytes by
 * both of its writers, and a third writer with a rotation scheme of its own
 * would produce an `actions.jsonl.1` written by one scheme and read by another.
 *
 * ## The extra keys
 *
 * `CopilotAction` carries `action`, `detail` and `sessionId`, and its own
 * documentation says the rest gets its own key: *"Anything that needs structure
 * gets its own key alongside these two, which JSONL tolerates without a
 * migration."* A routine row needs three of those — which routine, which run,
 * and how it went — because the Activity pane groups by routine and a run has
 * to be linkable to the sessions it started. They are added here rather than by
 * widening the shared interface, so nothing about the shared writer changes.
 */

import { appendCopilotAction, copilotPaths, type CopilotPaths } from '../copilot-home'
import { userDataDir } from '../platform/paths'

/** How a routine row ended. Narrower than a tool call's, because a run has fewer ways to end. */
export type RoutineLogOutcome = 'started' | 'ok' | 'failed' | 'refused'

export interface RoutineLogEntry {
  /**
   * Dotted, so it sorts and greps beside `home.created` and `tool.sessions.start`.
   *
   * `routine.refused` is *not* the same row as `routine.skip`. Skip means the
   * engine declined to start a run — a ceiling, a quiet period, a loop guard.
   * Refused means a run started, did work, and was stopped at the tool boundary
   * partway through: the routine did something, it just could not finish. A
   * person scanning this file for "why did nothing happen" needs those to look
   * different, because the fixes are different — one is a budget, the other is a
   * decision they have to make themselves.
   */
  action:
    | 'routine.run'
    | 'routine.skip'
    | 'routine.cancel'
    | 'routine.pause'
    | 'routine.refused'
    /**
     * A run that had something to say — the finding, not the record.
     *
     * Written by `runner.ts` and by nothing else, and only when a run's reply
     * survives the silence threshold. It is a separate action rather than a
     * longer `detail` on `routine.run` because the two answer different
     * questions: `routine.run` says *this fired and here is how it ended*, and
     * every run writes one; `routine.report` says *and here is what it found*,
     * and most runs do not have one. Filtering the log for this action is how a
     * person reads a night's worth of findings without reading a night's worth
     * of heartbeats.
     */
    | 'routine.report'
  routine: string
  runId?: string
  outcome: RoutineLogOutcome
  /** One line a person can read. Never a stack trace. */
  detail?: string
  /** Small, flat, and never the prompt: the log is read, not replayed. */
  data?: Record<string, unknown>
}

export type RoutineLogger = (entry: RoutineLogEntry) => void

/**
 * A logger writing into one copilot folder.
 *
 * Takes the paths rather than reaching for `userDataDir()`, for the reason
 * `copilot-home.ts` gives about itself: the tests never boot a shell, and the
 * runtime already holds the answer.
 */
export function routineLogger(paths: CopilotPaths): RoutineLogger {
  return (entry) => {
    // Built as a variable rather than passed as a literal on purpose. The
    // shared `CopilotAction` type declares the three fields every writer of
    // this file shares; the rest are this writer's own columns, which JSONL
    // carries and the pane reads when they are there.
    const row = {
      action: entry.action,
      ...(entry.detail === undefined ? {} : { detail: entry.detail }),
      routine: entry.routine,
      ...(entry.runId === undefined ? {} : { runId: entry.runId }),
      outcome: entry.outcome,
      ...(entry.data === undefined ? {} : { data: entry.data }),
    }
    appendCopilotAction(paths, row)
  }
}

/** The live one, for a shell that has already installed its platform paths. */
export function defaultRoutineLogger(): RoutineLogger {
  return routineLogger(copilotPaths(userDataDir()))
}
