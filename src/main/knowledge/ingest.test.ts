import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { TaskKnowledgeEvent } from '../../shared/agent-stack'
import { createKnowledge, type Knowledge } from './index'
import { taskSubject } from './ingest'

/**
 * Every event the task flow reports, kept as knowledge: history for the
 * hand-offs, a claim for a finished result, a verified result only from the
 * review, and a rejection that supersedes the claim with its reasons.
 */

let dir = ''
let api = ''
let knowledge: Knowledge
let errors: unknown[]
const T0 = Date.UTC(2026, 9, 1, 12)

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'td-knowledge-ingest-')))
  api = join(dir, 'api')
  mkdirSync(api)
  errors = []
  knowledge = createKnowledge({ userData: join(dir, 'userData'), now: () => T0 + 99_999, statMtime: () => null, onError: (error) => errors.push(error) })
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

const event = (kind: TaskKnowledgeEvent['kind'], at: number, extra: Partial<TaskKnowledgeEvent> = {}): TaskKnowledgeEvent => ({
  kind,
  project: api,
  taskId: 'local:7',
  title: 'Fix the flaky test',
  agentId: 'builder',
  sessionId: 's1',
  goalId: 'g1',
  at,
  ...extra,
})

const all = () => knowledge.list(api, { superseded: true })

describe('task events', () => {
  it('keeps delegated, reassigned and stalled as task history, at the event’s own time', async () => {
    await knowledge.noteTaskEvent(event('delegated', T0))
    await knowledge.noteTaskEvent(event('reassigned', T0 + 1, { agentId: 'fixer' }))
    await knowledge.noteTaskEvent(event('stalled', T0 + 2, { summary: 'Waiting on a CI runner.' }))
    const views = all().sort((a, b) => a.createdAt - b.createdAt)
    expect(views.map((view) => [view.kind, view.status, view.createdAt])).toEqual([
      ['task-history', 'claim', T0],
      ['task-history', 'claim', T0 + 1],
      ['task-history', 'claim', T0 + 2],
    ])
    expect(views.map((view) => view.statement)).toEqual([
      'Delegated “Fix the flaky test” to builder.',
      'Reassigned “Fix the flaky test” to fixer.',
      '“Fix the flaky test” stalled. Waiting on a CI runner.',
    ])
    expect(views[0].subject).toBe(taskSubject('local:7'))
    expect(views[0].provenance).toEqual({ source: 'task', taskId: 'local:7', goalId: 'g1', agentId: 'builder', sessionId: 's1' })
    expect(errors).toEqual([])
  })

  it('keeps a finished task’s summary as a claim, and a newer claim replaces an older one', async () => {
    await knowledge.noteTaskEvent(event('finished', T0, { summary: 'Retried the network call.' }))
    await knowledge.noteTaskEvent(event('finished', T0 + 5, { summary: 'Mocked the clock instead.' }))
    const live = knowledge.list(api)
    expect(live).toHaveLength(1)
    expect(live[0]).toMatchObject({ kind: 'result', status: 'claim', statement: 'Fix the flaky test: Mocked the clock instead.' })
    expect(live[0].provenance.source).toBe('task')
    expect(all().filter((view) => view.effective === 'superseded')).toHaveLength(1)
  })

  it('makes a verified result only from the review, with its evidence and time, superseding the claim', async () => {
    await knowledge.noteTaskEvent(event('finished', T0, { summary: 'Mocked the clock.' }))
    const [claim] = knowledge.list(api)
    await knowledge.noteTaskEvent(event('verified', T0 + 60_000, { summary: 'Mocked the clock; 40 runs green.', evidence: ['src/clock.test.ts', 'npm test'] }))
    const live = knowledge.list(api)
    expect(live).toHaveLength(1)
    expect(live[0]).toMatchObject({
      kind: 'result',
      status: 'verified',
      effective: 'verified',
      verifiedAt: T0 + 60_000,
      supersedes: claim.id,
      statement: 'Fix the flaky test: Mocked the clock; 40 runs green.',
    })
    expect(live[0].provenance).toMatchObject({ source: 'review', evidence: ['src/clock.test.ts', 'npm test'] })
    expect(knowledge.get(api, claim.id)?.effective).toBe('superseded')
    expect(knowledge.changes(api).at(-1)).toMatchObject({ action: 'supersede', id: claim.id, reason: 'verified by review', replacement: live[0].id })
  })

  it('does not make anything verified from a review that named no evidence', async () => {
    await knowledge.noteTaskEvent(event('finished', T0, { summary: 'Mocked the clock.' }))
    await knowledge.noteTaskEvent(event('verified', T0 + 1, { summary: 'Looks right.' }))
    const views = knowledge.list(api)
    expect(views.some((view) => view.status === 'verified')).toBe(false)
    expect(views.find((view) => view.kind === 'result')?.status).toBe('claim')
    expect(views.find((view) => view.kind === 'task-history')?.statement).toContain('without naming evidence')
  })

  it('supersedes a rejected claim with the review’s reasons, kept on the record and in the log', async () => {
    await knowledge.noteTaskEvent(event('finished', T0, { summary: 'Skipped the test.' }))
    const [claim] = knowledge.list(api)
    await knowledge.noteTaskEvent(event('rejected', T0 + 1, { summary: 'Skipping is not a fix; the race is still there.' }))
    expect(knowledge.get(api, claim.id)?.effective).toBe('superseded')
    const [rejection] = knowledge.list(api)
    expect(rejection).toMatchObject({
      kind: 'task-history',
      supersedes: claim.id,
      statement: 'Review rejected the result of “Fix the flaky test”: Skipping is not a fix; the race is still there.',
    })
    expect(rejection.provenance.source).toBe('review')
    expect(knowledge.changes(api).at(-1)?.reason).toBe('rejected by review: Skipping is not a fix; the race is still there.')
    expect(knowledge.history(api, rejection.id).map((view) => view.id)).toEqual([claim.id])
  })

  it('writes an event delivered twice once', async () => {
    await knowledge.noteTaskEvent(event('delegated', T0))
    await knowledge.noteTaskEvent(event('delegated', T0))
    await knowledge.noteTaskEvent(event('finished', T0 + 1, { summary: 'Done.' }))
    await knowledge.noteTaskEvent(event('finished', T0 + 1, { summary: 'Done.' }))
    expect(all()).toHaveLength(2)
  })

  it('never stops the task flow: a bad event is reported, not thrown', async () => {
    await expect(knowledge.noteTaskEvent(event('delegated', T0, { project: 'relative/path' }))).resolves.toBeUndefined()
    expect(errors).toHaveLength(1)
    await expect(knowledge.forBrief({ project: 'relative/path', query: 'x' })).resolves.toEqual({ text: '', records: [] })
    expect(errors).toHaveLength(2)
  })
})
