import { describe, expect, it } from 'vitest'
import {
  NO_FILTERS,
  createdLabel,
  dueBucket,
  filterTasks,
  groupTasks,
  nextStatus,
  relativeDue,
  reorderWithinSlots,
  summary,
  weekOf,
  ymdAddDays,
} from './list-view'
import type { TaskRow } from './tasks-model'

/** The CRM's My Work rules, ported: grouping, buckets, filters, the next step. */

const TODAY = '2026-10-07' // a Wednesday
let n = 0
function task(over: Partial<TaskRow> = {}): TaskRow {
  n += 1
  return {
    id: `local:${n}`, keyId: 'local', externalTaskId: String(n), title: `Task ${n}`, agent: 'Me', project: '', crmStatus: 'To-Do',
    process: 'idle', keepOpenUntil: null, verified: null, updatedAt: 0, local: true, assignee: 'me', instructions: '', handedFrom: null,
    notes: [], priority: null, startDate: null, dueDate: null, startTime: null, dueTime: null, labels: [], board: null, taskType: 'task',
    estimateMinutes: null, archivedAt: null, deletedAt: null, completedAt: null, position: null, recurrence: null, createdAt: 0,
    ...over,
  }
}
const names = (id: string): string => ({ me: 'Me', none: 'Unassigned', hoot: 'Hoot', builder: 'Builder' })[id] ?? id
const labels = (tasks: TaskRow[], by: Parameters<typeof groupTasks>[1], showClosed = false) =>
  groupTasks(tasks, by, TODAY, { showClosed, assigneeName: names }).map((group) => `${group.label}:${group.items.length}${group.folded ? ' folded' : ''}`)

describe('grouping, as My Work groups', () => {
  const tasks = [
    task({ crmStatus: 'To-Do', priority: 'High', labels: ['ops'], board: 'Launch', dueDate: '2026-10-06' }),
    task({ crmStatus: 'Working on it', priority: 'Critical', assignee: 'builder', board: 'Launch', dueDate: TODAY }),
    task({ crmStatus: 'Stuck', labels: ['ops', 'web'], project: '/work/app', taskType: 'milestone', dueDate: '2026-10-15' }),
    task({ crmStatus: 'Done', dueDate: '2026-10-01' }),
  ]
  it('by status: the five stages in the CRM order, Done folded', () => {
    expect(labels(tasks, 'status')).toEqual(['To-Do:1', 'Working on it:1', 'Stuck:1', 'Done:1 folded'])
    expect(groupTasks(tasks, 'status', TODAY, { showClosed: false, assigneeName: names })[0].defaults).toEqual({ status: 'To-Do' })
  })
  it('by due: Overdue, Today, Next, then Done folded — closed tasks pulled out', () => {
    expect(labels(tasks, 'due')).toEqual(['Overdue:1', 'Today:1', 'Next:1', 'Done:1 folded'])
    expect(labels(tasks, 'due', true)).toEqual(['Overdue:2', 'Today:1', 'Next:1'])
  })
  it('by priority, tags, assignee, type, board and project', () => {
    expect(labels(tasks, 'priority')).toEqual(['Critical:1', 'High:1', 'No priority:1', 'Done:1 folded'])
    expect(labels(tasks, 'tags')).toEqual(['ops:2', 'web:1', 'No tags:1', 'Done:1 folded'])
    expect(labels(tasks, 'assignee')).toEqual(['Builder:1', 'Me:2', 'Done:1 folded'])
    expect(labels(tasks, 'type')).toEqual(['Task:2', 'Milestone:1', 'Done:1 folded'])
    expect(labels(tasks, 'board')).toEqual(['Launch:2', 'No board:1', 'Done:1 folded'])
    expect(labels(tasks, 'project')).toEqual(['app:1', 'No project:2', 'Done:1 folded'])
    expect(labels(tasks, 'none')).toEqual(['3 Tasks:3', 'Done:1 folded'])
  })
})

describe('dates', () => {
  it('reads a due date the CRM way, and buckets it', () => {
    expect([relativeDue(TODAY, TODAY), relativeDue('2026-10-08', TODAY), relativeDue('2026-10-06', TODAY), relativeDue('2026-11-15', TODAY), relativeDue('2027-01-02', TODAY)]).toEqual([
      'Today', 'Tomorrow', 'Yesterday', '15 Nov', '2 Jan 2027',
    ])
    expect(dueBucket('2026-10-18', TODAY)).toBe('Next') // Sunday, the end of next week
    expect(dueBucket('2026-10-19', TODAY)).toBe('Later')
    expect(dueBucket(null, TODAY)).toBe('Unscheduled')
    expect(dueBucket(TODAY, TODAY, { dueTime: '09:00', nowHm: '10:00' })).toBe('Overdue')
    expect(createdLabel(new Date(2026, 9, 7, 12).getTime(), TODAY)).toBe('Today')
    expect(weekOf(TODAY)).toEqual(['2026-10-05', '2026-10-06', TODAY, '2026-10-08', '2026-10-09', '2026-10-10', '2026-10-11'])
    expect(ymdAddDays('2026-12-31', 1)).toBe('2027-01-01')
  })
})

describe('filters, tiles and the next step', () => {
  const tasks = [
    task({ assignee: 'me', priority: 'Low', board: 'Home', dueDate: '2026-10-01' }),
    task({ assignee: 'builder', dueDate: TODAY, title: 'Fix the login' }),
    task({ assignee: 'none', crmStatus: 'Done' }),
    task({ assignee: 'me', archivedAt: 5 }),
  ]
  it('filters by pile, status, priority, board, due, search and the archive', () => {
    const ids = (filters: Partial<typeof NO_FILTERS>) => filterTasks(tasks, { ...NO_FILTERS, ...filters }, TODAY, null).map((one) => one.title)
    expect(ids({})).toHaveLength(3)
    expect(ids({ pile: 'mine' })).toEqual([tasks[0].title])
    expect(ids({ pile: 'agents' })).toEqual(['Fix the login'])
    expect(ids({ pile: 'unassigned' })).toEqual([tasks[2].title])
    expect(ids({ statuses: ['Done'] })).toEqual([tasks[2].title])
    expect(ids({ priorities: ['none'] })).toHaveLength(2)
    expect(ids({ boards: ['Home'] })).toEqual([tasks[0].title])
    expect(ids({ due: 'overdue' })).toEqual([tasks[0].title])
    expect(ids({ due: 'today' })).toEqual(['Fix the login'])
    expect(ids({ search: 'LOGIN' })).toEqual(['Fix the login'])
    expect(ids({ archived: true })).toEqual([tasks[3].title])
  })
  it('the Favorites pile holds the tasks you starred, and nothing when you starred none', () => {
    const titles = (favorites: string[]) => filterTasks(tasks, { ...NO_FILTERS, pile: 'favorites' }, TODAY, null, new Set(favorites)).map((one) => one.title)
    expect(titles([])).toEqual([])
    expect(titles([tasks[1].id, 'gone'])).toEqual(['Fix the login'])
    // A starred task in the archive stays with the archive.
    expect(titles([tasks[3].id])).toEqual([])
  })
  it('counts open, overdue, today and done, leaving the archive out', () => {
    expect(summary(tasks, TODAY, null)).toEqual({ open: 2, overdue: 1, today: 1, done: 1 })
  })
  it('moves to the next stage the CRM way', () => {
    expect(['To-Do', 'Working on it', 'In Progress', 'Stuck', 'Done'].map(nextStatus)).toEqual(['Working on it', 'In Progress', 'Done', 'In Progress', null])
  })
  it('reorders only what is visible, among the slots it held', () => {
    expect(reorderWithinSlots(['a', 'b', 'c', 'd'], ['c', 'a'])).toEqual(['c', 'b', 'a', 'd'])
  })
})
