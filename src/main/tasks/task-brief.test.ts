import { describe, expect, it } from 'vitest'
import type { Goal } from '../../shared/agent-stack'
import { blockersOf, goalProgress, linksOf } from './goal-progress'
import { BRIEF_CONTEXT_CHARS, contextSection, goalSection, retrySection } from './task-brief'
import type { LocalTaskDetailData } from './task-detail-local'
import { newLocalTask } from './task-local'
import { TO_ME, type TaskRecord } from './task-store'

/** What a worker's brief carries from around its task, and how a goal's progress is read. Pure, so no store. */

let n = 0
function task(over: Partial<TaskRecord> = {}, detail: Partial<LocalTaskDetailData> = {}): TaskRecord {
  n += 1
  const made = newLocalTask({ title: `Task ${n}`, instructions: '', project: '/work/app', assignee: TO_ME, status: 'To-Do' }, 1_000 + n)
  return {
    ...made,
    ...over,
    detail: { subtasks: [], checklists: [], dependencies: [], comments: [], ...detail } as unknown as LocalTaskDetailData,
  }
}

function goal(id: string, over: Partial<Goal> = {}): Goal {
  return { id, title: id, description: '', status: 'active', parentId: null, project: null, createdAt: 0, updatedAt: 0, ...over }
}

describe('links between tasks', () => {
  it('reads a link from either side, and counts a blocker cleared once it is Done', () => {
    const first = task({ title: 'Build the API' })
    const second = task({ title: 'Build the page' }, { dependencies: [{ kind: 'blocked_by', otherTaskId: first.id, at: 1 }] })
    const third = task({ title: 'Ship' })
    // Written on the blocker's side: "first blocks third".
    first.detail = { ...first.detail, dependencies: [{ kind: 'blocks', otherTaskId: third.id, at: 2 }] } as LocalTaskDetailData
    const all = [first, second, third]
    expect(linksOf(first, all).map((link) => `${link.kind}:${link.other.title}`)).toEqual(['blocks:Ship', 'blocks:Build the page'])
    expect(blockersOf(second, all).map((one) => one.title)).toEqual(['Build the API'])
    expect(blockersOf(third, all).map((one) => one.title)).toEqual(['Build the API'])
    first.crmStatus = 'Done'
    expect(blockersOf(second, all)).toEqual([])
    expect(blockersOf(third, all)).toEqual([])
  })
})

describe('a goal’s progress', () => {
  it('counts its own tasks and its sub-goals’, by status, verified against claimed, stalled and waiting', () => {
    const goals = [goal('g-root'), goal('g-child', { parentId: 'g-root' }), goal('g-other')]
    const verified = task({ goalId: 'g-root', crmStatus: 'Done', result: { at: 1, verified: true, answer: 'ok', check: null } })
    const claimed = task({ goalId: 'g-child', crmStatus: 'Working on it', result: { at: 1, verified: false, answer: 'done?', check: null } })
    const stalled = task({ goalId: 'g-child', crmStatus: 'Stuck', process: 'running', stalled: { at: 5, reason: 'quiet', text: 'No sign of work.' } })
    const waiting = task({ goalId: 'g-root', process: 'queued' }, { dependencies: [{ kind: 'blocked_by', otherTaskId: stalled.id, at: 1 }] })
    const elsewhere = task({ goalId: 'g-other' })
    const archived = task({ goalId: 'g-root', archivedAt: 9 })
    const report = goalProgress(goals[0], goals, [verified, claimed, stalled, waiting, elsewhere, archived])
    expect(report).toMatchObject({ total: 4, done: 1, verified: 1, unverified: 1, stalled: 1, blocked: 1 })
    expect(report.byStatus).toMatchObject({ Done: 1, 'Working on it': 1, Stuck: 1, 'To-Do': 1 })
    expect(report.byProcess).toMatchObject({ running: 1, queued: 1, idle: 2 })
    expect(report.children).toEqual([{ goal: 'g-child', title: 'g-child', status: 'active' }])
    const line = report.tasks.find((one) => one.task === waiting.id)
    expect(line?.blockedBy).toEqual([{ task: stalled.id, title: stalled.title }])
    expect(report.tasks.find((one) => one.task === stalled.id)?.stalled?.reason).toBe('quiet')
  })
})

describe('the brief around a task', () => {
  it('carries the goal chain broadest first, each description cut short', () => {
    const chain = [goal('Ship 0.18', { description: 'Mac only.' }), goal('Fortnightly releases', { description: 'x'.repeat(2_000) })]
    const text = goalSection(chain)
    expect(text).toContain('## The goal this serves')
    expect(text.indexOf('Fortnightly releases')).toBeLessThan(text.indexOf('Ship 0.18'))
    expect(text).toContain('  - **Ship 0.18** (active) — Mac only.')
    expect(text.length).toBeLessThan(1_000)
    expect(goalSection([])).toBe('')
  })

  it('carries subtasks, links, the latest comments and the notes that matter — bounded', () => {
    const blocker = task({ title: 'Write the migration', crmStatus: 'In Progress' })
    const subject = task(
      {
        notes: [
          { at: 1, by: 'me', kind: 'edited', text: 'Changed the title.' },
          { at: 2, by: 'builder', kind: 'blocker', text: 'The test database is down.' },
          { at: 3, by: 'me', kind: 'reply', text: 'Use the local one.' },
        ],
      },
      {
        subtasks: [
          { id: 's1', title: 'Add the column', done: true, sortOrder: 0, assigneeUserId: null, priority: null, dueDate: null },
          { id: 's2', title: 'Backfill', done: false, sortOrder: 1, assigneeUserId: null, priority: null, dueDate: null },
        ],
        dependencies: [{ kind: 'blocked_by', otherTaskId: blocker.id, at: 1 }],
        comments: [{ id: 'c1', authorUserId: 'me', body: 'Keep the old column for a week.', at: 5 }],
      },
    )
    const names = (id: string): string => ({ me: 'You', builder: 'Builder' })[id] ?? id
    const text = contextSection(subject, [subject, blocker], names)
    expect(text).toContain('## Already on this task')
    expect(text).toContain('- [x] Add the column')
    expect(text).toContain('- [ ] Backfill')
    expect(text).toContain('- Waits for: Write the migration (In Progress)')
    expect(text).toContain('- You: Keep the old column for a week.')
    expect(text).toContain('- Builder (blocker): The test database is down.')
    expect(text).toContain('- You (reply): Use the local one.')
    expect(text).not.toContain('Changed the title.')

    const noisy = task({}, { comments: Array.from({ length: 50 }, (_, i) => ({ id: `c${i}`, authorUserId: 'me', body: `${i} ${'word '.repeat(200)}`, at: i })) })
    const bounded = contextSection(noisy, [noisy], names)
    expect(bounded).toContain('- You: 49 ')
    expect(bounded).not.toContain('- You: 41 ')
    expect(bounded.length).toBeLessThan(BRIEF_CONTEXT_CHARS + 400)
    expect(contextSection(task(), [], names)).toBe('')
  })

  it('says when it is a try after one that did not finish', () => {
    expect(retrySection(task())).toBe('')
    expect(retrySection(task({ retry: { note: 'Run the migration first.', at: 1, count: 1 } }))).toBe(
      '\n\n## Tried again\n\nThis task was started before and did not finish (try 2).\n\nRun the migration first.',
    )
  })
})
