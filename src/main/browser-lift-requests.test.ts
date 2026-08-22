/**
 * The lift-request desk: the rules that price an agent's retry loop at zero.
 *
 * `worker-tools.ts` refused a request tool for years on one argument — "a
 * request an agent can make in a retry loop" — and the desk exists to make
 * that argument false in mechanism rather than in a comment. So the mechanism
 * is what this file pins: an identical ask re-finds the waiting row instead of
 * filing a second, the inbox refuses past its cap, targets can only ever be
 * workers, and answering — the only way a row leaves — is a function no agent
 * surface reaches (that half is pinned in `browser-workers-ipc.test.ts` and
 * `lift-ask-tool.test.ts`, on the callers).
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  MAX_OPEN_REQUESTS,
  configureLiftRequests,
  fileLiftRequest,
  listLiftRequests,
  peekLiftRequest,
  resetLiftRequestsForTests,
  takeLiftRequest,
} from './browser-lift-requests'

let notified = 0

function wire(): void {
  configureLiftRequests({
    profiles: () => [
      { id: 'p-default', name: 'Default' },
      { id: 'p-work', name: 'Work' },
      { id: 'p-w1', name: 'Worker 1' },
      { id: 'p-w2', name: 'Worker 2' },
    ],
    workers: () => [
      { id: 'p-w1', name: 'Worker 1' },
      { id: 'p-w2', name: 'Worker 2' },
    ],
    notify: () => {
      notified += 1
    },
  })
}

beforeEach(() => {
  resetLiftRequestsForTests()
  notified = 0
  wire()
})

afterEach(() => resetLiftRequestsForTests())

describe('filing an ask', () => {
  it('resolves names the way the panel says them, and stores ids', () => {
    const answer = fileLiftRequest({
      askedBy: 'The session driving B1',
      from: 'default',
      into: ['worker 1'],
      reason: 'Marina listings need a signed-in session.',
    })
    expect(answer.ok).toBe(true)
    if (!answer.ok) return
    expect(answer.request.fromProfileId).toBe('p-default')
    expect(answer.request.intoProfileIds).toEqual(['p-w1'])
    expect(answer.fromName).toBe('Default')
    expect(answer.intoNames).toEqual(['Worker 1'])
    expect(notified).toBe(1)
  })

  it('reads naming nothing as every worker, and never the source itself', () => {
    const answer = fileLiftRequest({ askedBy: 'x', from: 'Worker 1', into: [] })
    expect(answer.ok).toBe(true)
    if (!answer.ok) return
    // Worker 1 is the source, so only Worker 2 is a target.
    expect(answer.request.intoProfileIds).toEqual(['p-w2'])
  })

  it('refuses a target that is not a worker, by name', () => {
    // `Work` is a real profile and still not a legal destination: a lift only
    // ever lands in workers, and widening that here would widen it everywhere.
    const answer = fileLiftRequest({ askedBy: 'x', from: 'Default', into: ['Work'] })
    expect(answer.ok).toBe(false)
    if (answer.ok) return
    expect(answer.reason).toContain('not a worker profile')
  })

  it('refuses an unknown source profile with the panel’s vocabulary', () => {
    const answer = fileLiftRequest({ askedBy: 'x', from: 'Nope', into: [] })
    expect(answer.ok).toBe(false)
    if (answer.ok) return
    expect(answer.reason).toContain('no profile called "Nope"')
  })

  it('keeps the reason to one clean line, because it renders in a panel row', () => {
    const answer = fileLiftRequest({
      askedBy: 'x',
      from: 'Default',
      into: [],
      reason: '  two\n  lines\tand   spaces  ' + 'x'.repeat(400),
    })
    expect(answer.ok).toBe(true)
    if (!answer.ok) return
    expect(answer.request.reason).not.toContain('\n')
    expect(answer.request.reason.length).toBeLessThanOrEqual(200)
    expect(answer.request.reason.startsWith('two lines and spaces')).toBe(true)
  })

  it('answers when nothing is wired, instead of pretending an inbox exists', () => {
    configureLiftRequests(null)
    const answer = fileLiftRequest({ askedBy: 'x', from: 'Default', into: [] })
    expect(answer.ok).toBe(false)
    if (answer.ok) return
    expect(answer.reason).toContain('nothing in this build')
  })
})

describe('the retry loop, priced at zero', () => {
  it('re-finds an identical open ask rather than filing a second row', () => {
    const first = fileLiftRequest({ askedBy: 'same', from: 'Default', into: ['Worker 1'] })
    const again = fileLiftRequest({ askedBy: 'same', from: 'Default', into: ['Worker 1'] })
    expect(first.ok && again.ok).toBe(true)
    if (!first.ok || !again.ok) return
    expect(again.repeated).toBe(true)
    expect(again.request.id).toBe(first.request.id)
    expect(listLiftRequests()).toHaveLength(1)
    // And no second notification: nothing on screen changed.
    expect(notified).toBe(1)
  })

  it('treats a different asker, source or target set as a different ask', () => {
    fileLiftRequest({ askedBy: 'a', from: 'Default', into: ['Worker 1'] })
    const other = fileLiftRequest({ askedBy: 'b', from: 'Default', into: ['Worker 1'] })
    expect(other.ok && !other.repeated).toBe(true)
    expect(listLiftRequests()).toHaveLength(2)
  })

  it('refuses past the cap with the cap in the sentence', () => {
    for (let n = 0; n < MAX_OPEN_REQUESTS; n++) {
      const filed = fileLiftRequest({ askedBy: `asker-${n}`, from: 'Default', into: ['Worker 1'] })
      expect(filed.ok).toBe(true)
    }
    const ninth = fileLiftRequest({ askedBy: 'one-too-many', from: 'Default', into: ['Worker 1'] })
    expect(ninth.ok).toBe(false)
    if (ninth.ok) return
    expect(ninth.reason).toContain(String(MAX_OPEN_REQUESTS))
    expect(ninth.reason).toContain('Do not retry')
  })
})

describe('answering', () => {
  it('takes a row out exactly once, and tells the windows', () => {
    const filed = fileLiftRequest({ askedBy: 'x', from: 'Default', into: [] })
    expect(filed.ok).toBe(true)
    if (!filed.ok) return
    expect(notified).toBe(1)
    const taken = takeLiftRequest(filed.request.id)
    expect(taken?.id).toBe(filed.request.id)
    expect(notified).toBe(2)
    expect(peekLiftRequest(filed.request.id)).toBeNull()
    // A second take is a no-op that announces nothing.
    expect(takeLiftRequest(filed.request.id)).toBeNull()
    expect(notified).toBe(2)
  })

  it('lists oldest first — the order a person answers a queue in', () => {
    const a = fileLiftRequest({ askedBy: 'a', from: 'Default', into: ['Worker 1'] })
    const b = fileLiftRequest({ askedBy: 'b', from: 'Default', into: ['Worker 2'] })
    expect(a.ok && b.ok).toBe(true)
    if (!a.ok || !b.ok) return
    const ids = listLiftRequests().map((row) => row.id)
    expect(ids).toEqual([a.request.id, b.request.id])
  })
})
