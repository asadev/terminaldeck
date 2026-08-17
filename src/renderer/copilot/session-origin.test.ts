import { describe, expect, it } from 'vitest'
import { partitionByOrigin, sessionsFromTurn, startedByCopilot, turnOf } from './session-origin'

/**
 * The grouping, and the one property it has to have.
 *
 * A session the copilot started must be in exactly one of the two lists — never
 * in both, which draws a row twice, and never in neither, which loses a running
 * process from the only place it can be reached. That is a claim about a
 * function rather than an agreement between two filters, which is why the split
 * is one call.
 */

const mine = { id: 's1', kind: 'session' }
const theirs = { id: 's2', kind: 'session', origin: 'copilot', originRunId: 'turn-9' }
const restored = { id: 's3', kind: 'session', origin: 'copilot' }
const page = { id: 'b1', kind: 'browser' }

describe('whose session is whose', () => {
  it('asks for copilot rather than for "not user"', () => {
    // A third origin must land in the person's list until somebody decides
    // where it goes — not be swept into the copilot's by a negation.
    expect(startedByCopilot({ id: 'x', kind: 'session', origin: 'routine' })).toBe(false)
    expect(startedByCopilot(mine)).toBe(false)
    expect(startedByCopilot(theirs)).toBe(true)
  })

  it('never treats a browser page as a copilot session', () => {
    expect(startedByCopilot({ ...page, origin: 'copilot' })).toBe(false)
  })
})

describe('the split', () => {
  const { mine: ours, copilot } = partitionByOrigin([mine, theirs, restored, page])

  it('puts every tab in exactly one half', () => {
    expect(ours.map((tab) => tab.id)).toEqual(['s1', 'b1'])
    expect(copilot.map((tab) => tab.id)).toEqual(['s2', 's3'])
    expect(ours.length + copilot.length).toBe(4)
  })

  it('keeps the order it was given, so rows do not shuffle between renders', () => {
    const { copilot: order } = partitionByOrigin([restored, theirs])
    expect(order.map((tab) => tab.id)).toEqual(['s3', 's2'])
  })
})

describe('the link back to the turn that started it', () => {
  it('names the action-log row', () => {
    expect(turnOf(theirs)).toBe('turn-9')
  })

  it('is absent for a copilot session whose turn is not known', () => {
    // A session restored from a previous run: the origin survives on the
    // metadata and the log row is not loaded. The row then draws no button
    // rather than one that lands nowhere.
    expect(turnOf(restored)).toBeNull()
  })

  it('is absent for a session the person started', () => {
    expect(turnOf(mine)).toBeNull()
  })
})

describe('the link forward', () => {
  it('finds everything one turn started, not just the first', () => {
    const second = { id: 's4', kind: 'session', origin: 'copilot', originRunId: 'turn-9' }
    expect(sessionsFromTurn([mine, theirs, restored, second], 'turn-9').map((t) => t.id)).toEqual([
      's2',
      's4',
    ])
  })
})
