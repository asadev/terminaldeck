import { describe, expect, it } from 'vitest'
import { SCAN_HOLD_MS } from '../../src/shared/scan'
import {
  ANSWER_PROVENANCE,
  MAX_SCAN_STOPS,
  answerSummary,
  createScanRunner,
  noteOf,
  rankOf,
  scanAnswer,
  scanPlan,
  whyOf,
  type ScanClock,
} from './copilot-scan'
import type { CopilotActionRow, CopilotSessionRow, RemoteSession } from './protocol-client'

/**
 * What the scan may say, and what it must refuse to say.
 *
 * The rule this file exists to hold is the one the whole review turns on:
 * **nothing fake.** The desktop's scan quotes a session because the main process
 * has verified the quote is really in that session's scrollback; a tour does not
 * cross the wire, so this client has no such plan and must not manufacture one.
 * Every assertion below is a case where a plausible-looking sentence would have
 * been easy and would have been invented.
 *
 * The second half is the toggle. He asked for both modes and the promise
 * attached to them is that **the answer is identical either way** — so it is
 * asserted as an equality between two runs of the same plan rather than as two
 * screens that look similar.
 */

let counter = 0
const session = (over: Partial<RemoteSession> = {}): RemoteSession => {
  counter += 1
  return {
    id: `s${counter}`,
    title: `session ${counter}`,
    cwd: '/work',
    provider: 'shell',
    status: 'idle',
    exitCode: null,
    ...over,
  }
}

const NOW = 1_700_000_000_000

describe('what is worth looking at first', () => {
  it('puts a failure above everything, and a clean finish below everything', () => {
    /*
     * The one distinction the session list cannot make. `sortSessions` puts every
     * finished session together at the bottom, so a job that exited 1 sits beside
     * one that exited 0 — and a non-zero exit is the only thing on this screen
     * somebody would get out of bed for.
     */
    const failed = session({ exitCode: 1 })
    const done = session({ exitCode: 0 })
    const needs = session({ status: 'input' })
    const quiet = session({ status: 'idle' })
    expect(rankOf(failed)).toBeLessThan(rankOf(needs))
    expect(rankOf(needs)).toBeLessThan(rankOf(quiet))
    expect(rankOf(quiet)).toBeLessThan(rankOf(done))
  })

  it('uses the session list’s own word rather than a second vocabulary', () => {
    /*
     * This had five words of its own once, and three of them printed twice on a
     * real answer card — `Working · Working`, `Quiet · Idle`. Worse, *Quiet* was
     * a claim about a status this build has never heard of.
     */
    expect(whyOf(session({ status: 'input' }))).toBe('Needs input')
    expect(whyOf(session({ status: 'working' }))).toBe('Working')
    expect(whyOf(session({ exitCode: 0 }))).toBe('Finished')
    // The one distinction the label cannot make: `Exited (1)` reads like a
    // footnote, and it is the thing somebody would get out of bed for.
    expect(whyOf(session({ exitCode: 2 }))).toBe('Stopped with an error')
    // A status this build has never heard of is passed through, never narrated.
    expect(whyOf(session({ status: 'something-new' }))).toBe('something-new')
  })

  it('says only what the reason does not, and never invents a time', () => {
    const row = session({ status: 'working' })
    /*
     * The wire carries no activity timestamp for a session this browser has
     * never heard from, so there is nothing true to print — and an absence is
     * drawn as an absence rather than narrated.
     *
     * It used to answer "Nothing seen from this browser yet", which turned up
     * under a run that had just answered: busy on the machine, silent to *this*
     * client, which is the common case on a page that was opened a minute ago.
     * A sentence that is wrong on the row it appears on is worse than no line.
     */
    expect(noteOf(row, null, NOW)).toBe('')
    expect(noteOf(row, NOW - 4 * 60_000, NOW)).toBe('Last active 4m ago')
    expect(noteOf(session({ exitCode: 1 }), null, NOW)).toBe('Exit code 1')
  })
})

describe('the plan', () => {
  it('quotes the machine’s own line, joined through the row that started it', () => {
    const started = session({ status: 'working' })
    const rows: CopilotSessionRow[] = [
      {
        id: started.id,
        title: started.title,
        cwd: '/work',
        provider: 'claude',
        status: 'working',
        startedAt: NOW,
        originRunId: 'a3',
      },
    ]
    const tools: CopilotActionRow[] = [
      {
        id: 'a3',
        at: '2026-08-18T00:00:00.000Z',
        tool: 'sessions.start',
        tier: 'act',
        outcome: 'ok',
        detail: 'Started a session in ~/Projects/app',
        refusal: null,
        deviceId: null,
      },
    ]
    const [stop] = scanPlan({ sessions: [started], activity: new Map(), started: rows, tools, now: NOW })
    expect(stop.quote).toBe('Started a session in ~/Projects/app')
  })

  it('quotes nothing at all for a session it has no line about', () => {
    /*
     * The honest floor, asserted. There is no fallback quote and there must not
     * be one: substituting the folder, the title or the status would produce a
     * line that looks like evidence and is not, which is exactly what the
     * desktop's quote check exists to make impossible over there.
     */
    const plain = session({ status: 'working' })
    const [stop] = scanPlan({ sessions: [plain], activity: new Map(), started: [], tools: [], now: NOW })
    expect(stop.quote).toBe('')
  })

  it('quotes nothing when the copilot named a row this browser has not seen', () => {
    // The join is only as good as what has arrived. A missing action row is a
    // missing quote, never an invented one.
    const started = session()
    const rows: CopilotSessionRow[] = [
      { id: started.id, title: started.title, cwd: '/w', provider: 'claude', status: 'idle', startedAt: NOW, originRunId: 'gone' },
    ]
    const [stop] = scanPlan({ sessions: [started], activity: new Map(), started: rows, tools: [], now: NOW })
    expect(stop.quote).toBe('')
  })

  it('cuts the fleet to a briefing, keeping what matters most', () => {
    const many = [session({ exitCode: 1 }), ...Array.from({ length: 20 }, () => session())]
    const stops = scanPlan({ sessions: many, activity: new Map(), started: [], tools: [], now: NOW })
    expect(stops).toHaveLength(MAX_SCAN_STOPS)
    expect(stops[0].why).toBe('Stopped with an error')
  })
})

describe('the toggle, and the promise attached to it', () => {
  it('gives the same answer with the driving off as with it on', () => {
    const fleet = [session({ status: 'input' }), session({ exitCode: 1 }), session()]
    const plan = () => scanPlan({ sessions: fleet, activity: new Map(), started: [], tools: [], now: NOW })

    // A visible scan that ran to the end: every stop was actually drawn.
    const watched = plan().map((stop) => ({ ...stop, shownAt: NOW }))
    // A background scan: nothing was drawn, because there was nothing to draw.
    const background = plan()

    expect(scanAnswer(background, false)).toEqual(scanAnswer(watched, true))
  })

  it('never marks a background finding as missed', () => {
    /*
     * The failure the shared model names: getting this backwards puts "Not
     * reached" against every line of a scan that found everything, which says
     * the work was not done when the work is exactly what is being shown.
     */
    const stops = scanPlan({ sessions: [session(), session()], activity: new Map(), started: [], tools: [], now: NOW })
    const answer = scanAnswer(stops, false)
    expect(answer.flatMap((row) => row.lines).every((line) => line.shown)).toBe(true)
    expect(answerSummary(answer)).toBe('2 things across 2 sessions.')
  })

  it('counts what was shown, never what was planned', () => {
    // Somebody pressed Stop after one stop. The one sentence in this feature
    // that must never be wrong.
    const stops = scanPlan({ sessions: [session(), session(), session()], activity: new Map(), started: [], tools: [], now: NOW })
    stops[0].shownAt = NOW
    expect(answerSummary(scanAnswer(stops, true))).toBe('1 thing across 1 session.')
  })

  it('says where the answer came from', () => {
    // It is not the copilot's reading of those sessions and must never be
    // mistaken for one — see the header of `copilot-scan.ts`.
    expect(ANSWER_PROVENANCE).toContain('machine reported')
  })
})

describe('the clock', () => {
  /** A frame loop driven by hand, so a hold is checked rather than waited for. */
  function fakeClock(): ScanClock & { advance(ms: number): void } {
    let at = 0
    let pending: Array<() => void> = []
    return {
      now: () => at,
      requestFrame(callback) {
        pending.push(callback)
        return pending.length
      },
      cancelFrame() {
        pending = []
      },
      advance(ms) {
        at += ms
        const due = pending
        pending = []
        for (const callback of due) callback()
      },
    }
  }

  it('holds each stop for the shared constant and then moves on', () => {
    const clock = fakeClock()
    const runner = createScanRunner(clock, () => undefined)
    runner.play(3)
    runner.dispatch({ kind: 'arrive', at: clock.now() })
    expect(runner.state().index).toBe(0)

    // One frame short of the hold, then one past it. The reducer owns the rule;
    // this asserts the loop actually feeds it time.
    clock.advance(SCAN_HOLD_MS - 20)
    expect(runner.state().index).toBe(0)
    clock.advance(40)
    expect(runner.state().index).toBe(1)
    runner.destroy()
  })

  it('holds rather than resuming when the tab was not running', () => {
    /*
     * A gap that large means the renderer was not running — a hidden tab, a shut
     * lid — and coming back to a screen that is already in motion is the worst
     * frame of the whole feature.
     */
    const clock = fakeClock()
    const runner = createScanRunner(clock, () => undefined)
    runner.play(4)
    runner.dispatch({ kind: 'arrive', at: clock.now() })
    clock.advance(30_000)
    expect(runner.state().status).toBe('paused')
    expect(runner.state().pausedBy).toBe('stalled')
    runner.destroy()
  })

  it('publishes only when something a person could see has changed', () => {
    const clock = fakeClock()
    let notices = 0
    const runner = createScanRunner(clock, () => {
      notices += 1
    })
    runner.play(2)
    const afterPlay = notices
    runner.dispatch({ kind: 'arrive', at: clock.now() })
    // Several frames inside one hold move `elapsedMs` and nothing else.
    clock.advance(16)
    clock.advance(16)
    clock.advance(16)
    expect(notices).toBe(afterPlay + 1)
    runner.destroy()
  })

  it('stops feeding the reducer once it is destroyed', () => {
    const clock = fakeClock()
    const runner = createScanRunner(clock, () => undefined)
    runner.play(2)
    runner.destroy()
    const frozen = runner.state()
    clock.advance(10_000)
    expect(runner.state()).toBe(frozen)
  })
})
