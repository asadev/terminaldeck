import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { localInstant } from '../../shared/crm/recurrence-rules'
import type { TaskActivityRow } from '../../shared/crm/task-activity'
import type { CommentMeta } from '../../shared/crm/task-comments'
import type { RoutineView } from '../../shared/crm/routine-actions'
import { TASK_CONFIG_FILE, TaskConfig } from './task-config'
import { LocalTaskDetail, REMINDER_ATTEMPTS, REMINDER_RETRY_MS, type ReminderDelivery, type ReminderNotice } from './task-detail-local'
import { LocalTasks } from './task-local'
import { TaskStore, type TaskRecord } from './task-store'

/**
 * What comes due on your own tasks with time, and what a finish brings: the
 * reference CRM's routine engine, its reminder delivery and its scheduled
 * comments, answered on this computer.
 *
 * Inert throughout: the clock is a number the test moves (no real timer), a
 * reminder's delivery is a recorded call (no notification is shown), and the
 * engine that would start an agent only marks the task idle (no agent runs).
 * Every moment is made with `localInstant`, so the test reads the same in any
 * time zone.
 */

let dir = ''
let clock = 0
let store: TaskStore
let local: LocalTasks
let detail: LocalTaskDetail
let notices: ReminderNotice[]
let answer: () => ReminderDelivery
let replies: Array<{ id: string; text: string }>

const now = (): number => clock
const at = (ymd: string, hm: string): number => localInstant(ymd, hm).getTime()

function build(withNotify: boolean): void {
  store = new TaskStore({ dir: null, now })
  const config = new TaskConfig({ dir })
  local = new LocalTasks({
    store,
    config,
    now,
    engine: {
      accept: async (task) => void store.update(task, { process: 'idle' }),
      reassign: async (task, assignee) => void store.update(task, { assignee, mainAssignee: assignee.identity }),
      reply: async (task, text) => void replies.push({ id: task.id, text }),
      cancel: async () => undefined,
    },
    onUpdated: (task, list, notes) => detail.noteUpdate(task, list, notes),
  })
  detail = new LocalTaskDetail({
    store,
    config,
    local,
    filesDir: null,
    chooseFiles: async () => [],
    chooseFolder: async () => null,
    openPath: async () => '',
    now,
    ...(withNotify
      ? {
          notify: async (notice: ReminderNotice) => {
            notices.push(notice)
            return answer()
          },
        }
      : {}),
  })
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-task-due-'))
  writeFileSync(join(dir, TASK_CONFIG_FILE), JSON.stringify({ v: 1, agents: [{ id: 'builder', name: 'Builder' }], connections: [] }))
  // A Wednesday morning, on this computer's clock.
  clock = at('2026-10-07', '09:00')
  notices = []
  answer = () => ({ delivered: true })
  replies = []
  build(true)
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

async function call<T = Record<string, unknown>>(fn: Parameters<LocalTaskDetail['call']>[0], ...args: unknown[]): Promise<T> {
  return (await detail.call(fn, args)) as T
}

const RULE = {
  frequency: 'weekly',
  interval: 1,
  unit: 'week',
  weekdays: [],
  monthly: null,
  trigger: 'status',
  triggerStatus: 'Done',
  timeOfDay: '08:00',
  ends: { type: 'never' },
  createNew: true,
  updateStatusTo: 'To-Do',
  syncToDue: true,
  skipWeekends: false,
  perAssignee: false,
  missedPolicy: 'leave_open',
  pausedAt: null,
  stoppedAt: null,
  rootTaskId: null,
  anchor: null,
}

async function repeating(title: string, rule: Record<string, unknown> = {}, extra: Record<string, unknown> = {}): Promise<TaskRecord> {
  const task = await local.create({ title, assignee: 'me', status: 'To-Do', startDate: '2026-10-08', dueDate: '2026-10-09', ...extra })
  const saved = await call('saveRoutine', task.id, { ...RULE, ...rule }, 0)
  expect(saved).toMatchObject({ ok: true })
  return task
}

async function setStatus(task: TaskRecord, status: string): Promise<void> {
  await local.update(task.id, { status })
  await detail.settled()
}

const copiesOf = (root: TaskRecord): TaskRecord[] => store.all().filter((t) => t.detail?.routine?.rootTaskId === root.id)
const routineOf = async (task: TaskRecord): Promise<RoutineView> => (await call<{ routine: RoutineView }>('fetchRoutine', task.id)).routine
const activity = async (task: TaskRecord): Promise<TaskActivityRow[]> => (await call<{ rows: TaskActivityRow[] }>('listTaskActivity', task.id)).rows

describe('a routine on status change', () => {
  it('a finish makes the next one — its date, its start lead, its parts with every tick cleared — once, however often it is finished', async () => {
    const root = await repeating('Weekly report')
    const sub = await call<{ id: string }>('addTaskSubtask', root.id, 'Gather numbers')
    await call('setTaskSubtaskDone', root.id, sub.id, true)
    const list = await call<{ id: string }>('addChecklist', root.id, 'Send')
    const item = await call<{ id: string }>('addChecklistItem', list.id, 'Email it')
    await call('setChecklistItemDone', item.id, true)

    await setStatus(root, 'Done')
    const [copy] = copiesOf(root)
    expect(copiesOf(root)).toHaveLength(1)
    expect(copy).toMatchObject({ title: 'Weekly report', crmStatus: 'To-Do', dueDate: '2026-10-16', startDate: '2026-10-15', recurrence: 'weekly', assignee: { identity: 'me' } })
    expect(copy.detail?.subtasks.map((s) => [s.title, s.done])).toEqual([['Gather numbers', false]])
    expect(copy.detail?.checklists[0].items.map((i) => [i.title, i.done])).toEqual([['Email it', false]])
    expect((await routineOf(copy)).isRoot).toBe(false)
    expect((await routineOf(copy)).rootTaskId).toBe(root.id)
    expect((await routineOf(root)).history).toEqual([expect.objectContaining({ occurrenceDate: '2026-10-16', spawnedTaskId: copy.id, status: 'open' })])

    // Undone and done again: no second copy — not even after its date moved, which would point at another week.
    await setStatus(root, 'To-Do')
    await local.update(root.id, { dueDate: '2026-10-17' })
    await setStatus(root, 'Done')
    expect(copiesOf(root)).toHaveLength(1)

    // The copy finished: its date is done in the history, and the one after it comes.
    await setStatus(copy, 'Done')
    expect(copiesOf(root).map((t) => t.dueDate).sort()).toEqual(['2026-10-16', '2026-10-23'])
    const history = (await routineOf(root)).history ?? []
    expect(history.map((r) => [r.occurrenceDate, r.status])).toEqual([
      ['2026-10-23', 'open'],
      ['2026-10-16', 'done'],
    ])
    expect((await routineOf(root)).datesSoFar).toBe(2)
  })

  it('with “Create new task” off, the task itself comes back with the next dates — and only on the trigger status', async () => {
    const root = await repeating('Water the plants', { createNew: false, triggerStatus: 'In Progress' })
    await setStatus(root, 'Stuck')
    expect(root.dueDate).toBe('2026-10-09')
    await setStatus(root, 'In Progress')
    expect(store.all()).toHaveLength(1)
    expect(root).toMatchObject({ crmStatus: 'To-Do', dueDate: '2026-10-16', startDate: '2026-10-15', completedAt: null })
    // Done finishes it whatever the trigger: its date is marked done, but only the trigger brings the next one.
    await setStatus(root, 'Done')
    expect((await routineOf(root)).history?.map((r) => [r.occurrenceDate, r.status])).toEqual([['2026-10-16', 'done']])
    expect(root.dueDate).toBe('2026-10-16')
  })

  it('its own bringing back is not a finish: a next one that starts in the trigger status comes back once, not forever', async () => {
    const root = await repeating('Escalate', { createNew: false, triggerStatus: 'Stuck', updateStatusTo: 'Stuck' })
    await setStatus(root, 'Stuck')
    expect(root).toMatchObject({ crmStatus: 'Stuck', dueDate: '2026-10-16' })
    expect((await routineOf(root)).history).toHaveLength(1)
  }, 10_000)

  it('“after N times” stops making them; paused, stopped or archived makes nothing; Restart picks up a stuck one', async () => {
    const counted = await repeating('Three times', { ends: { type: 'count', count: 2 } })
    await setStatus(counted, 'Done')
    await setStatus(copiesOf(counted)[0], 'Done')
    const second = copiesOf(counted).find((t) => t.dueDate === '2026-10-23')!
    await setStatus(second, 'Done')
    expect(copiesOf(counted)).toHaveLength(2)

    const paused = await repeating('Paused one')
    await call('pauseRoutine', paused.id, true)
    await setStatus(paused, 'Done')
    expect(copiesOf(paused)).toHaveLength(0)
    await call('pauseRoutine', paused.id, false)
    const view = await routineOf(paused)
    expect(view).toMatchObject({ canRestart: true, stuck: expect.stringContaining('Nothing more will come') })
    const restarted = await call<{ ok: true; taskId: string }>('restartRoutine', paused.id)
    expect(restarted.ok).toBe(true)
    // Never the date its finished task already stood for.
    expect(store.byId(restarted.taskId)).toMatchObject({ dueDate: '2026-10-16', crmStatus: 'To-Do' })
    expect(await call('restartRoutine', paused.id)).toEqual({ ok: false, error: 'This routine is not stuck: one of its tasks is still open.' })
    // Finishing the old one again brings no second copy: Restart pointed it at the new one.
    await setStatus(paused, 'To-Do')
    await setStatus(paused, 'Done')
    expect(copiesOf(paused)).toHaveLength(1)

    const stopped = await repeating('Stopped one')
    await call('stopRoutine', stopped.id)
    await setStatus(stopped, 'Done')
    expect(copiesOf(stopped)).toHaveLength(0)

    const archived = await repeating('Archived one')
    await setStatus(archived, 'Done')
    await call('setArchived', archived.id, true)
    await setStatus(copiesOf(archived)[0], 'Done')
    expect(copiesOf(archived)).toHaveLength(1)
  })

  it('each person gets their own; one that could not be made is said, and only it is made on the next finish', async () => {
    const root = await repeating('Stand-up notes', { perAssignee: true })
    await call('addTaskAssignee', root.id, 'builder')
    await setStatus(root, 'Done')
    // The agent's copy needs a project folder: refused, said on the routine, the other made.
    expect(copiesOf(root).map((t) => t.assignee.identity)).toEqual(['me'])
    expect((await routineOf(root)).lastError?.message).toMatch(/^Not every copy was made \(1 of 2\): Builder: Choose the project folder/)
    await local.update(root.id, { project: '/work/app' })
    await setStatus(root, 'To-Do')
    await setStatus(root, 'Done')
    expect(copiesOf(root).map((t) => t.assignee.identity).sort()).toEqual(['builder', 'me'])
    expect(copiesOf(root).every((t) => t.dueDate === '2026-10-16')).toBe(true)
    expect((await routineOf(root)).lastError).toBeNull()
  })

  it('an agent finishing it (the engine sets the status) brings the next one too', async () => {
    const root = await repeating('Nightly check')
    store.update(root, { crmStatus: 'Done', completedAt: clock })
    detail.noteStatus(root.id)
    await detail.settled()
    expect(copiesOf(root)).toHaveLength(1)
  })
})

describe('a routine on a schedule', () => {
  it('makes the date whose time has come, finished or not; after a long sleep only the latest, the ones between recorded as skipped and the open one marked missed', async () => {
    const root = await repeating('Weekly invoice', { trigger: 'schedule', timeOfDay: '08:00', missedPolicy: 'mark_missed' })
    expect(detail.nextDueAt()).toBe(at('2026-10-16', '08:00'))
    clock = at('2026-10-16', '07:59')
    await detail.runDue()
    expect(copiesOf(root)).toHaveLength(0)
    clock = at('2026-10-16', '08:00')
    await detail.runDue()
    const [first] = copiesOf(root)
    expect(first).toMatchObject({ dueDate: '2026-10-16', crmStatus: 'To-Do' })
    // A finish does not make the next one of a schedule.
    await setStatus(first, 'Done')
    expect(copiesOf(root)).toHaveLength(1)
    await setStatus(first, 'To-Do')

    clock = at('2026-11-06', '09:30')
    await detail.runDue()
    expect(copiesOf(root).map((t) => t.dueDate).sort()).toEqual(['2026-10-16', '2026-11-06'])
    expect((await routineOf(root)).history?.map((r) => [r.occurrenceDate, r.status])).toEqual([
      ['2026-11-06', 'open'],
      ['2026-10-30', 'skipped'],
      ['2026-10-23', 'skipped'],
      ['2026-10-16', 'missed'],
    ])
    expect(first.labels).toContain('Missed')
    expect((await routineOf(root)).datesSoFar).toBe(2)
    expect(detail.nextDueAt()).toBe(at('2026-11-13', '08:00'))
    await detail.runDue()
    expect(copiesOf(root)).toHaveLength(2)
  })

  it('with “Create new task” off, its own task comes back with the date at its time', async () => {
    const root = await repeating('Check the backups', { trigger: 'schedule', createNew: false, timeOfDay: '06:30' })
    clock = at('2026-10-16', '06:30')
    await detail.runDue()
    expect(store.all()).toHaveLength(1)
    expect(root).toMatchObject({ dueDate: '2026-10-16', startDate: '2026-10-15', crmStatus: 'To-Do' })
    expect(detail.nextDueAt()).toBe(at('2026-10-23', '06:30'))
  })
})

describe('reminders', () => {
  type More = { remindersLive: boolean; reminders: Array<{ id: string; note: string | null }> }
  const more = async (task: TaskRecord): Promise<More> => (await call<{ more: More }>('fetchTaskMore', task.id)).more

  it('goes once, at its time, with the task’s name and your note', async () => {
    const task = await local.create({ title: 'Call the bank\nabout the card', assignee: 'me' })
    expect((await more(task)).remindersLive).toBe(true)
    const when = clock + 3_600_000
    await call('setReminder', task.id, new Date(when).toISOString(), 'Before noon')
    expect(detail.nextDueAt()).toBe(when)
    clock = when - 1
    await detail.runDue()
    expect(notices).toEqual([])
    clock = when
    await detail.runDue()
    await detail.runDue()
    expect(notices).toEqual([{ taskId: task.id, title: 'Call the bank', body: 'Before noon' }])
    expect((await more(task)).reminders).toEqual([])
    expect(detail.nextDueAt()).toBeNull()
  })

  it('a failed one is tried again later, five times in all, then given up on; one that can never go, and one on an archived task, are settled', async () => {
    const task = await local.create({ title: 'Pay rent', assignee: 'me' })
    answer = () => ({ delivered: false, reason: 'the notification did not show', retry: true })
    const when = clock + 60_000
    await call('setReminder', task.id, new Date(when).toISOString(), null)
    clock = when
    await detail.runDue()
    expect(notices).toHaveLength(1)
    expect((await more(task)).reminders).toHaveLength(1)
    expect(detail.nextDueAt()).toBe(when + REMINDER_RETRY_MS)
    await detail.runDue()
    expect(notices).toHaveLength(1)
    for (let i = 0; i < 10; i++) {
      clock = detail.nextDueAt() ?? clock
      await detail.runDue()
    }
    expect(notices).toHaveLength(REMINDER_ATTEMPTS)
    expect((await more(task)).reminders).toEqual([])
    expect(notices[0].body).toBe('You asked to be reminded about this task.')

    notices = []
    answer = () => ({ delivered: false, reason: 'notifications are switched off for the app', retry: false })
    await call('setReminder', task.id, new Date(clock + 1_000).toISOString(), 'x')
    clock += 1_000
    await detail.runDue()
    await detail.runDue()
    expect(notices).toHaveLength(1)

    notices = []
    answer = () => ({ delivered: true })
    await call('setReminder', task.id, new Date(clock + 1_000).toISOString(), 'y')
    await call('setArchived', task.id, true)
    clock += 1_000
    await detail.runDue()
    expect(notices).toEqual([])
    expect(detail.nextDueAt()).toBeNull()
  })

  it('a reminder cleared before its time never goes', async () => {
    const task = await local.create({ title: 'Renew passport', assignee: 'me' })
    const set = await call<{ id: string }>('setReminder', task.id, new Date(clock + 1_000).toISOString(), null)
    expect(await call('clearReminder', task.id, set.id)).toEqual({ ok: true })
    clock += 2_000
    await detail.runDue()
    expect(notices).toEqual([])
  })
})

describe('a scheduled comment', () => {
  it('waits, unseen in Activity, then goes out at its time — told, and passed to the agent it names', async () => {
    const task = await local.create({ title: 'Fix the build', assignee: 'builder', project: '/work/app' })
    const when = clock + 30 * 60_000
    const posted = await call<{ ok: true; id: string }>('addTaskCommentWith', task.id, '@Builder check the logs first', { scheduledFor: new Date(when).toISOString() })
    const meta = async (): Promise<CommentMeta> => (await call<{ extras: { meta: Record<string, CommentMeta> } }>('fetchCommentExtras', task.id)).extras.meta[posted.id]
    expect(await meta()).toMatchObject({ scheduledFor: new Date(when).toISOString(), deliveredAt: null })
    expect((await activity(task)).some((r) => r.kind === 'comment')).toBe(false)
    expect(replies).toEqual([])
    expect(detail.nextDueAt()).toBe(when)

    clock = when
    await detail.runDue()
    expect((await meta()).deliveredAt).toEqual(expect.any(String))
    expect((await activity(task)).filter((r) => r.kind === 'comment')).toHaveLength(1)
    expect(replies).toEqual([{ id: task.id, text: '@Builder check the logs first' }])
    await detail.runDue()
    expect(replies).toHaveLength(1)
    expect(detail.nextDueAt()).toBeNull()
  })
})

describe('with nothing to deliver reminders', () => {
  it('does not offer them, refuses one in words, and the clock does not wait for any', async () => {
    build(false)
    const task = await local.create({ title: 'No reminders here', assignee: 'me' })
    expect((await call<{ more: { remindersLive: boolean } }>('fetchTaskMore', task.id)).more.remindersLive).toBe(false)
    expect(await call('setReminder', task.id, new Date(clock + 1_000).toISOString(), null)).toEqual({ ok: false, error: 'Nothing on this computer delivers reminders.' })
    expect(detail.nextDueAt()).toBeNull()
  })
})
