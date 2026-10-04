import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { TaskAttachment } from '../../shared/crm/collab-types'
import type { TaskActivityRow } from '../../shared/crm/task-activity'
import type { CommentMeta } from '../../shared/crm/task-comments'
import type { TaskComment } from '../../shared/crm/tasks-data'
import { TASK_CONFIG_FILE, TaskConfig } from './task-config'
import { LocalTaskDetail, type ReminderNotice } from './task-detail-local'
import { LocalTasks, newLocalTask } from './task-local'
import { MAX_TASKS, TaskStore, type TaskRecord } from './task-store'

/**
 * The Trash: a local task deleted, merged into another or made a subtask is
 * kept whole — its notes, Activity, comments and files — until restored, and
 * nothing empties it. Every fixture here is disposable: made in this test, in a
 * temporary folder or in memory; nothing permanent is ever deleted.
 */

let dir = ''
let clock = 0
let store: TaskStore
let local: LocalTasks
let detail: LocalTaskDetail
let cancelled: string[]
let accepted: string[]
let notices: ReminderNotice[]

const now = (): number => (clock += 1_000)

function build(storeDir: string | null = join(dir, 'remote')): void {
  store = new TaskStore({ dir: storeDir, now })
  const config = new TaskConfig({ dir })
  local = new LocalTasks({
    store,
    config,
    now,
    engine: {
      accept: async (task) => {
        accepted.push(task.id)
        store.update(task, { process: 'idle' })
      },
      reassign: async (task, assignee) => void store.update(task, { assignee, mainAssignee: assignee.identity }),
      reply: async () => undefined,
      cancel: async (task) => {
        cancelled.push(task.id)
        store.update(task, { sessionId: null, process: 'exited' })
      },
    },
    onUpdated: (task, list, notes) => detail.noteUpdate(task, list, notes),
  })
  detail = new LocalTaskDetail({
    store,
    config,
    local,
    filesDir: join(dir, 'remote', 'task-files'),
    chooseFiles: async () => [],
    chooseFolder: async () => null,
    openPath: async () => '',
    now,
    notify: async (notice) => {
      notices.push(notice)
      return { delivered: true }
    },
  })
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-task-trash-'))
  writeFileSync(join(dir, TASK_CONFIG_FILE), JSON.stringify({ v: 1, agents: [{ id: 'builder', name: 'Builder' }], connections: [] }))
  clock = Date.UTC(2026, 9, 7, 9, 0, 0)
  cancelled = []
  accepted = []
  notices = []
  build()
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

async function call<T = Record<string, unknown>>(fn: Parameters<LocalTaskDetail['call']>[0], ...args: unknown[]): Promise<T> {
  return (await detail.call(fn, args)) as T
}

const activity = async (task: TaskRecord): Promise<TaskActivityRow[]> => (await call<{ rows: TaskActivityRow[] }>('listTaskActivity', task.id)).rows
const comments = async (task: TaskRecord): Promise<string[]> => (await call<{ comments: TaskComment[] }>('listTaskComments', task.id)).comments.map((c) => c.body)

describe('deleting a task', () => {
  it('moves it to the Trash whole, out of every list, and Restore brings it back as it was — kept across a restart', async () => {
    const task = await local.create({ title: 'Disposable draft', assignee: 'me', labels: ['temp'] })
    await call('addTaskComment', task.id, 'A note to keep')
    const up = await call<{ attachment: TaskAttachment }>('uploadTaskFile', task.id, { name: 'n.txt', type: 'text/plain', bytes: new Uint8Array([1, 2, 3]) })
    const file = join(dir, 'remote', 'task-files', up.attachment.storagePath as string)
    const before = (await activity(task)).length

    await local.remove(task.id)
    expect(store.byId(task.id)).toBeNull()
    expect(store.all().some((t) => t.id === task.id)).toBe(false)
    expect(store.inTrash().map((t) => t.id)).toEqual([task.id])
    expect(task.deletedAt).toEqual(expect.any(Number))
    expect(existsSync(file)).toBe(true)
    expect(await call('fetchTaskDetailBundle', task.id)).toEqual({ ok: false, error: 'That task no longer exists.' })

    // Kept across a restart: a fresh store reads the Trash back.
    store.flush()
    build()
    expect(store.byId(task.id)).toBeNull()
    expect(store.inTrash().map((t) => t.title)).toEqual(['Disposable draft'])

    const back = await local.restore(task.id)
    expect(back).toMatchObject({ title: 'Disposable draft', labels: ['temp'], deletedAt: null })
    expect(store.byId(task.id)).not.toBeNull()
    expect(store.inTrash()).toEqual([])
    expect(await comments(back)).toEqual(['A note to keep'])
    expect((await activity(back)).length).toBeGreaterThanOrEqual(before)
    expect(back.notes?.slice(-2).map((n) => n.text)).toEqual(['Moved to Trash.', 'Restored from Trash.'])
    const bundle = await call<{ bundle: { attachments: TaskAttachment[] } }>('fetchTaskDetailBundle', back.id)
    expect(bundle.bundle.attachments.map((a) => a.fileName)).toEqual(['n.txt'])

    store.flush()
    build()
    expect(store.byId(task.id)?.title).toBe('Disposable draft')
    expect(await local.restore(task.id).catch((error: Error) => error.message)).toBe('That task is not in the Trash.')
  })

  it('stops an agent working on it first, and Restore starts no agent', async () => {
    const task = await local.create({ title: 'Agent job', assignee: 'builder', project: '/work/app' })
    accepted = []
    store.update(task, { sessionId: 's-1', process: 'running' })
    await local.remove(task.id)
    expect(cancelled).toEqual([task.id])
    await local.restore(task.id)
    expect(accepted).toEqual([])
    expect(store.byId(task.id)).toMatchObject({ sessionId: null, assignee: { identity: 'builder' } })
  })
})

describe('merging and making a subtask', () => {
  it('a merged task goes to the Trash with its own history; what moved stays on the other; Restore brings the source back', async () => {
    const source = await local.create({ title: 'Duplicate report', assignee: 'me' })
    const target = await local.create({ title: 'Report', assignee: 'me' })
    await call('addTaskComment', source.id, 'From the duplicate')
    await call('addTaskSubtask', source.id, 'Check the totals')
    const up = await call<{ attachment: TaskAttachment }>('uploadTaskFile', source.id, { name: 'figures.csv', type: 'text/csv', bytes: new Uint8Array([9]) })
    const file = join(dir, 'remote', 'task-files', up.attachment.storagePath as string)
    const sourceLines = (await activity(source)).length

    expect(await call('mergeTaskInto', source.id, target.id)).toEqual({ ok: true })
    expect(store.byId(source.id)).toBeNull()
    expect(store.inTrash().map((t) => t.id)).toEqual([source.id])
    expect(await comments(target)).toContain('From the duplicate')
    const onTarget = await call<{ bundle: { attachments: TaskAttachment[]; subtasks: Array<{ title: string }> } }>('fetchTaskDetailBundle', target.id)
    expect(onTarget.bundle.attachments.map((a) => a.fileName)).toEqual(['figures.csv'])
    expect(onTarget.bundle.subtasks.map((s) => s.title)).toEqual(['Check the totals'])
    expect(existsSync(file)).toBe(true)

    const back = await local.restore(source.id)
    expect((await activity(back)).length).toBeGreaterThanOrEqual(sourceLines)
    expect(await comments(back)).toContain('From the duplicate')
    // The file moved to the task it was merged into, and is still there.
    expect(existsSync(file)).toBe(true)
  })

  it('a task made a subtask goes to the Trash, and Restore brings it back beside its subtask line', async () => {
    const child = await local.create({ title: 'Book the venue', assignee: 'me' })
    const parent = await local.create({ title: 'Plan the launch', assignee: 'me' })
    expect(await call('convertToSubtask', child.id, parent.id)).toEqual({ ok: true })
    expect(store.byId(child.id)).toBeNull()
    expect(store.inTrash().map((t) => t.title)).toEqual(['Book the venue'])
    await local.restore(child.id)
    expect(store.byId(child.id)?.title).toBe('Book the venue')
    expect(parent.detail?.subtasks.map((s) => s.title)).toEqual(['Book the venue'])
  })
})

describe('what comes due on a task in the Trash', () => {
  it('a reminder is settled at its time, never sent; a scheduled comment waits and goes out once restored', async () => {
    clock = Date.UTC(2026, 9, 7, 9, 0, 0)
    const task = await local.create({ title: 'Trashed with plans', assignee: 'me' })
    await call('setReminder', task.id, new Date(clock + 60_000).toISOString(), 'Ping')
    const later = await call<{ id: string }>('addTaskCommentWith', task.id, 'Later on', { scheduledFor: new Date(clock + 120_000).toISOString() })
    await local.remove(task.id)
    clock += 180_000
    await detail.runDue()
    expect(notices).toEqual([])
    expect(task.detail?.reminders[0]).toMatchObject({ lastError: 'skipped: the task was deleted' })
    expect(task.detail?.commentMeta[later.id]).toMatchObject({ deliveredAt: null })
    await local.restore(task.id)
    await detail.runDue()
    expect(notices).toEqual([])
    const meta = (await call<{ extras: { meta: Record<string, CommentMeta> } }>('fetchCommentExtras', task.id)).extras.meta[later.id]
    expect(meta.deliveredAt).toEqual(expect.any(String))
  })

  it('a routine whose own task is in the Trash makes nothing more; restored, it goes on', async () => {
    const root = await local.create({ title: 'Weekly', assignee: 'me', dueDate: '2026-10-09' })
    await call('saveRoutine', root.id, { frequency: 'weekly', interval: 1, unit: 'week', weekdays: [], monthly: null, trigger: 'status', triggerStatus: 'Done', timeOfDay: '08:00', ends: { type: 'never' }, createNew: true, updateStatusTo: 'To-Do', syncToDue: true, skipWeekends: false, perAssignee: false, missedPolicy: 'leave_open', pausedAt: null, stoppedAt: null, rootTaskId: null, anchor: null }, 0)
    await local.update(root.id, { status: 'Done' })
    await detail.settled()
    const copy = store.all().find((t) => t.detail?.routine?.rootTaskId === root.id)!
    await local.remove(root.id)
    await local.update(copy.id, { status: 'Done' })
    await detail.settled()
    expect(store.all().filter((t) => t.detail?.routine?.rootTaskId === root.id)).toHaveLength(1)
    await local.restore(root.id)
    await local.update(copy.id, { status: 'To-Do' })
    await local.update(copy.id, { status: 'Done' })
    await detail.settled()
    expect(store.all().filter((t) => t.detail?.routine?.rootTaskId === root.id).map((t) => t.dueDate).sort()).toEqual(['2026-10-16', '2026-10-23'])
  })
})

describe('nothing is purged by itself', () => {
  it('the record cap drops only old CRM records — never your own tasks, never the Trash (in memory)', () => {
    const memory = new TaskStore({ dir: null, now })
    for (let i = 0; i < MAX_TASKS + 5; i++) memory.put({ ...newLocalTask({ title: `Mine ${i}`, instructions: '', project: '', assignee: { kind: 'human', agentId: 'me', identity: 'me' }, status: 'To-Do' }, clock), local: true })
    const trashed = memory.all()[0].id
    memory.trash(trashed)
    for (let i = 0; i < MAX_TASKS + 5; i++) {
      memory.put({ ...newLocalTask({ title: `CRM ${i}`, instructions: '', project: '', assignee: { kind: 'human', agentId: 'me', identity: 'me' }, status: 'To-Do' }, clock), keyId: 'k1', id: `k1:${i}`, externalTaskId: String(i), local: false })
    }
    expect(memory.all().filter((t) => t.local === true)).toHaveLength(MAX_TASKS + 4)
    expect(memory.all().filter((t) => t.local !== true)).toHaveLength(MAX_TASKS)
    expect(memory.inTrash().map((t) => t.id)).toEqual([trashed])
  })
})
