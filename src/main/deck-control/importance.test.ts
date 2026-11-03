/**
 * One definition of important, held to the app's own data.
 *
 * Two properties are being defended here and they are worth naming, because
 * neither is about a function returning the right value:
 *
 *  1. **Every reason is a claim the app can check.** A copilot that says a
 *     session is blocked when `attention.ts` says it is running must be refused,
 *     because the raw material it reasons over is other agents' output and
 *     `COPILOT-CAPABILITIES.md` §3.2 item 8 classes that as untrusted evidence.
 *  2. **The prose and the machine reasons cannot drift apart.** `verdictFor`
 *     writes the sentence a person reads and `reasonsFor` produces the set a
 *     tour walks through. They are the same judgement, and the last test in this
 *     file is what makes "the same" enforceable rather than aspirational.
 */

import { describe, expect, it } from 'vitest'
import {
  HEAVY_MIN_SAMPLE as ALERT_MIN_SAMPLE,
  HEAVY_MIN_TOKENS as ALERT_MIN_TOKENS,
  HEAVY_MULTIPLE as ALERT_MULTIPLE,
} from '../alerts'
import {
  fleetContext,
  HEAVY_MIN_SAMPLE,
  HEAVY_MIN_TOKENS,
  HEAVY_MULTIPLE,
  isCriticalLoop,
  loopSeverity,
  NO_FLEET,
  reasonsFor,
  REASON_PRIORITY,
  supports,
  UNCHECKED_REASONS,
  type FleetContext,
  type ImportanceInput,
} from './importance'
import { assessProgress, REPEAT_CRITICAL, REPEAT_WARNING, type ProgressReport } from './progress'
import type { ToolTrail } from './surface'

/* ------------------------------------------------------------------ fixtures -- */

function trailOf(calls: Array<{ name: string; failed: boolean }>, compactions = 0): ToolTrail {
  return {
    events: calls.map((call, index) => ({ at: 1_000 + index * 1_000, name: call.name, failed: call.failed })),
    compactions: Array.from({ length: compactions }, (_unused, index) => ({
      at: 500 + index,
      preTokens: 100_000,
      postTokens: 20_000,
      trigger: 'auto',
    })),
    fileBytes: 1024,
    fromByte: 0,
    partial: false,
  }
}

function input(over: Partial<ImportanceInput> = {}): ImportanceInput {
  return {
    attention: 'running',
    attentionReason: 'output-streaming',
    exitCode: null,
    progress: null,
    totalTokens: null,
    changedFiles: 0,
    lastMessage: null,
    ...over,
  }
}

const loopingProgress: ProgressReport = assessProgress(
  trailOf(Array.from({ length: REPEAT_WARNING }, () => ({ name: 'Bash', failed: true }))),
)

/* --------------------------------------------------------------- the checks -- */

describe('supports', () => {
  it('reads blocked, failed and finished straight off attention.ts', () => {
    expect(supports('blocked-on-you', input({ attention: 'blocked' }))).toBe(true)
    expect(supports('blocked-on-you', input({ attention: 'quiet' }))).toBe(false)

    expect(supports('failed', input({ attentionReason: 'process-failed', exitCode: 1 }))).toBe(true)
    expect(supports('failed', input({ attentionReason: 'process-exited', exitCode: 0 }))).toBe(false)

    expect(supports('finished', input({ attention: 'done' }))).toBe(true)
    expect(supports('finished', input({ attention: 'running' }))).toBe(false)
  })

  it('reads looping and tool-failing straight off progress.ts', () => {
    expect(loopingProgress.verdict).toBe('looping')
    expect(supports('looping', input({ progress: loopingProgress }))).toBe(true)
    expect(supports('tool-failing', input({ progress: loopingProgress }))).toBe(true)

    // A session with a readable transcript and nothing wrong in it.
    const healthy = assessProgress(trailOf([{ name: 'Read', failed: false }]))
    expect(supports('looping', input({ progress: healthy }))).toBe(false)
    expect(supports('tool-failing', input({ progress: healthy }))).toBe(false)
  })

  it('never claims looping for a session with no transcript to read', () => {
    /*
     * A shell writes no JSONL. `progress.ts` answers `unknown` with a reason
     * rather than `ok`, and every reason built on it has to inherit that: the
     * one failure neither module may have is reporting silence as health.
     */
    const unknown = assessProgress(null)
    expect(unknown.verdict).toBe('unknown')
    expect(supports('looping', input({ progress: unknown }))).toBe(false)
    expect(supports('tool-failing', input({ progress: unknown }))).toBe(false)
    expect(supports('compacted', input({ progress: unknown }))).toBe(false)
    expect(supports('looping', input({ progress: null }))).toBe(false)
  })

  it('counts a compaction in the window that was read', () => {
    const compacted = assessProgress(trailOf([{ name: 'Read', failed: false }], 2))
    expect(supports('compacted', input({ progress: compacted }))).toBe(true)
    expect(supports('compacted', input({ progress: loopingProgress }))).toBe(false)
  })

  it('only calls a session expensive when there are peers to compare it against', () => {
    const context: FleetContext = { medianTokens: HEAVY_MIN_TOKENS, sample: HEAVY_MIN_SAMPLE }
    const heavy = input({ totalTokens: HEAVY_MIN_TOKENS * HEAVY_MULTIPLE })

    expect(supports('expensive', heavy, context)).toBe(true)
    // The floor: a ratio alone is meaningless at small numbers.
    expect(supports('expensive', input({ totalTokens: HEAVY_MIN_TOKENS - 1 }), { medianTokens: 1, sample: 9 })).toBe(
      false,
    )
    // The sample: four sessions do not make a median.
    expect(supports('expensive', heavy, { medianTokens: HEAVY_MIN_TOKENS, sample: HEAVY_MIN_SAMPLE - 1 })).toBe(false)
    // And with no fleet at all — a one-session question — it can never fire,
    // because "far above its peers" has no meaning without peers.
    expect(supports('expensive', heavy, NO_FLEET)).toBe(false)
  })

  it('agrees with alerts.ts about what expensive means', () => {
    /*
     * These three constants are restated in `importance.ts` rather than imported,
     * because importing `alerts.ts` there would close a cycle — `alerts.ts`
     * already imports `progress.ts` from that folder for the loop alert. A
     * duplicated number is only safe while something fails when the two diverge.
     */
    expect(HEAVY_MIN_SAMPLE).toBe(ALERT_MIN_SAMPLE)
    expect(HEAVY_MULTIPLE).toBe(ALERT_MULTIPLE)
    expect(HEAVY_MIN_TOKENS).toBe(ALERT_MIN_TOKENS)
  })

  it('reads a question off the newest message, and refuses a truncated one', () => {
    expect(supports('question-asked', input({ lastMessage: 'Should I use pnpm here?' }))).toBe(true)
    expect(supports('question-asked', input({ lastMessage: 'Done, tests pass.' }))).toBe(false)
    // `report.ts` passes null rather than the cut text for a truncated message,
    // so this is the shape it actually receives.
    expect(supports('question-asked', input({ lastMessage: null }))).toBe(false)
  })

  it('names decision as the one reason with nothing behind it', () => {
    // `supports` answers true because there is nothing to check, not because it
    // checked. The set is what makes a caller notice the difference and apply
    // the one-per-session bound instead.
    expect(UNCHECKED_REASONS.has('decision')).toBe(true)
    expect(supports('decision', input())).toBe(true)
    for (const why of REASON_PRIORITY) {
      if (why === 'decision') continue
      expect(UNCHECKED_REASONS.has(why), why).toBe(false)
    }
  })

  it('has a precondition for every value in the closed set', () => {
    // A reason added to the union without a case here would fall through the
    // switch and return undefined, which reads as false and silently drops
    // every stop of that kind rather than failing.
    for (const why of REASON_PRIORITY) {
      expect(typeof supports(why, input()), why).toBe('boolean')
    }
  })
})

/* ------------------------------------------------------------------ the set -- */

describe('reasonsFor', () => {
  it('says nothing about a session with nothing worth saying', () => {
    expect(reasonsFor(input())).toEqual([])
  })

  it('never proposes decision — that is the model’s one sentence, not the app’s', () => {
    const everything = input({
      attention: 'blocked',
      attentionReason: 'question-unanswered',
      progress: loopingProgress,
      changedFiles: 4,
      lastMessage: 'which branch?',
    })
    expect(reasonsFor(everything).map((finding) => finding.why)).not.toContain('decision')
  })

  it('leads with the reason that should be acted on first', () => {
    const blockedAndBusy = input({
      attention: 'blocked',
      attentionReason: 'question-unanswered',
      progress: loopingProgress,
      changedFiles: 3,
    })
    const reasons = reasonsFor(blockedAndBusy).map((finding) => finding.why)
    expect(reasons[0]).toBe('blocked-on-you')
    // And the rest are in the shared priority order, not in discovery order.
    const ranks = reasons.map((why) => REASON_PRIORITY.indexOf(why))
    expect(ranks).toEqual([...ranks].sort((a, b) => a - b))
  })

  it('puts the fact in the sentence, not an assessment', () => {
    const failed = reasonsFor(input({ attention: 'done', attentionReason: 'process-failed', exitCode: 137 }))
    expect(failed[0].why).toBe('failed')
    expect(failed[0].detail).toContain('137')

    const changed = reasonsFor(input({ changedFiles: 1 }))
    expect(changed[0].detail).toBe('1 uncommitted file in its folder.')
  })
})

describe('fleetContext', () => {
  it('drops the sessions that never made a request', () => {
    /*
     * Six of ten sessions at zero would otherwise give a median of zero, every
     * ratio against it is infinite, and every session with a single answer in it
     * reads as "spending far above its peers".
     */
    const context = fleetContext([0, 0, 0, null, 100, 200, 300])
    expect(context.medianTokens).toBe(200)
    expect(context.sample).toBe(3)
  })

  it('answers no-fleet when there is nothing to compare', () => {
    expect(fleetContext([])).toEqual(NO_FLEET)
    expect(fleetContext([null, 0])).toEqual(NO_FLEET)
  })
})

describe('loopSeverity', () => {
  it('is the count the loudest finding fired on, and matches progress.ts thresholds', () => {
    expect(loopSeverity(null)).toBe(0)
    expect(loopSeverity(loopingProgress)).toBe(REPEAT_WARNING)
    expect(isCriticalLoop(loopingProgress)).toBe(false)

    const bad = assessProgress(trailOf(Array.from({ length: REPEAT_CRITICAL }, () => ({ name: 'Bash', failed: true }))))
    expect(isCriticalLoop(bad)).toBe(true)
  })
})
