import { describe, expect, it } from 'vitest'
import {
  assessProgress,
  FAILURE_WARNING,
  progressSentence,
  REPEAT_CRITICAL,
  REPEAT_WARNING,
  WINDOW_CALLS,
} from './progress'
import type { ToolEvent, ToolTrail } from './surface'

/**
 * The judgement that decides whether the copilot interrupts somebody.
 *
 * These assertions are the thresholds themselves, tested at their exact
 * boundaries rather than approximately, because the whole value of this module
 * is that it fires when a session is genuinely stuck and stays quiet otherwise.
 * A detector that is a little too eager gets ignored within a day, and a
 * detector that is ignored is worse than none — it makes an unmonitored fleet
 * look monitored.
 */

let clock = 1_000_000

function trail(events: ToolEvent[], extra: Partial<ToolTrail> = {}): ToolTrail {
  return { events, compactions: [], fileBytes: 4096, fromByte: 0, partial: false, ...extra }
}

function calls(name: string, count: number, failed: boolean | null = false): ToolEvent[] {
  return Array.from({ length: count }, () => ({ at: (clock += 1_000), name, failed }))
}

describe('assessProgress', () => {
  it('says nothing about a session doing ordinary varied work', () => {
    const report = assessProgress(
      trail([...calls('Read', 4), ...calls('Edit', 3), ...calls('Bash', 2), ...calls('Grep', 1)]),
    )
    expect(report.verdict).toBe('ok')
    expect(report.findings).toEqual([])
    expect(report.writes).toBe(3)
  })

  it('calls a session looping when one tool dominates and nothing is written', () => {
    const report = assessProgress(trail(calls('Bash', REPEAT_WARNING)))
    expect(report.verdict).toBe('looping')
    expect(report.findings.map((finding) => finding.signal)).toEqual(['repeated-tool', 'no-writes'])
  })

  it('holds its tongue one call below the threshold', () => {
    // The boundary itself, not near it. A detector whose real threshold is one
    // off from its documented one is a detector nobody can reason about.
    expect(assessProgress(trail(calls('Bash', REPEAT_WARNING - 1))).verdict).toBe('ok')
  })

  /**
   * The distinction the verdict exists to make.
   *
   * Repetition with files landing is what a refactor looks like — the same
   * `Edit` tool, twenty times, and twenty changed files. Repetition with
   * nothing landing is what a stuck build looks like. Collapsing the two into
   * one alarm is how this feature would come to be switched off.
   */
  it('separates a session repeating itself productively from one that is stuck', () => {
    const productive = assessProgress(trail(calls('Edit', REPEAT_WARNING + 2)))
    expect(productive.verdict).toBe('suspect')
    expect(productive.writes).toBe(REPEAT_WARNING + 2)

    const stuck = assessProgress(trail(calls('Bash', REPEAT_WARNING + 2)))
    expect(stuck.verdict).toBe('looping')
    expect(stuck.writes).toBe(0)
  })

  it('reports repeated failures even when the call count is unremarkable', () => {
    const report = assessProgress(
      trail([...calls('Bash', FAILURE_WARNING, true), ...calls('Read', 2)]),
    )
    expect(report.findings[0].signal).toBe('repeated-failure')
    expect(report.findings[0].tool).toBe('Bash')
    expect(report.failures).toBe(FAILURE_WARNING)
  })

  it('leads with the failing tool when two of them cross a threshold', () => {
    const report = assessProgress(
      trail([...calls('Read', REPEAT_CRITICAL), ...calls('Bash', FAILURE_WARNING + 1, true)]),
    )
    expect(report.findings[0].tool).toBe('Bash')
    expect(report.findings[0].signal).toBe('repeated-failure')
  })

  it('only looks at the last thirty calls, so an old thrash stops being reported', () => {
    // Thirty clean calls after a burst of repetition: the burst has rolled out
    // of the window and the session is fine again.
    const report = assessProgress(
      trail([...calls('Bash', REPEAT_CRITICAL), ...calls('Edit', WINDOW_CALLS)]),
    )
    expect(report.examined).toBe(WINDOW_CALLS)
    expect(report.verdict).toBe('suspect')
    expect(report.findings.every((finding) => finding.tool !== 'Bash')).toBe(true)
  })

  it('names the compaction that was immediately undone', () => {
    const before = calls('Read', 12)
    const at = (clock += 1_000)
    const after = calls('Read', 2)
    const report = assessProgress(
      trail([...before, ...after], {
        compactions: [{ at, preTokens: 190_000, postTokens: 20_000, trigger: 'auto' }],
      }),
    )
    expect(report.findings.some((finding) => finding.signal === 'compaction-echo')).toBe(true)
  })

  it('does not call a compaction churn when the session moved on', () => {
    const before = calls('Read', 12)
    const at = (clock += 1_000)
    const after = calls('Edit', 3)
    const report = assessProgress(
      trail([...before, ...after], {
        compactions: [{ at, preTokens: 190_000, postTokens: 20_000, trigger: 'auto' }],
      }),
    )
    expect(report.findings.some((finding) => finding.signal === 'compaction-echo')).toBe(false)
  })

  /**
   * The one failure this module must not have.
   *
   * A plain shell writes no transcript, so there is nothing to read — and
   * answering "no problems found" for a session nobody can see would make an
   * unmonitored session look monitored. `unknown` is a fourth verdict for
   * exactly this, and it carries the reason so the copilot can say it out loud.
   */
  it('says it cannot tell, rather than saying everything is fine', () => {
    const none = assessProgress(null)
    expect(none.verdict).toBe('unknown')
    expect(none.unknownReason).toMatch(/keeps no transcript/)
    expect(progressSentence(none)).toMatch(/keeps no transcript/)

    const empty = assessProgress(trail([]))
    expect(empty.verdict).toBe('unknown')
    expect(empty.unknownReason).toMatch(/not called a tool/)
  })

  it('carries the partial flag through, so a tail is never read as a whole session', () => {
    const report = assessProgress(trail(calls('Read', 3), { partial: true, fromByte: 2048 }))
    expect(report.partial).toBe(true)
  })

  it('refuses to date a window whose lines carried no timestamps', () => {
    // `parseInsightLine` writes `at: 0` for a line with no usable timestamp,
    // and a span computed from a zero reads as "looping since 1970".
    const report = assessProgress(
      trail([
        { at: 0, name: 'Bash', failed: false },
        { at: 0, name: 'Bash', failed: false },
      ]),
    )
    expect(report.spanMs).toBeNull()
  })

  it('does not treat an unseen result as a success', () => {
    // `failed: null` is "the result was outside the window", which must not
    // count towards the failure signal in either direction.
    const report = assessProgress(trail(calls('Bash', FAILURE_WARNING + 2, null)))
    expect(report.failures).toBe(0)
    expect(report.findings.some((finding) => finding.signal === 'repeated-failure')).toBe(false)
  })
})
