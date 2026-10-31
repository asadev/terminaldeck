import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { parseDuration } from '../../shared/crm/task-page'
import type { TaskActivityRow } from '../../shared/crm/task-activity'
import type { TaskAttachment, TaskDependency } from '../../shared/crm/collab-types'
import type { TaskComment } from '../../shared/crm/tasks-data'
import type { TaskField } from '../../shared/crm/task-fields'
import { TASK_CONFIG_FILE, TaskConfig } from './task-config'
import { LocalTaskDetail } from './task-detail-local'
import { LocalTasks } from './task-local'
import { TaskStore, type TaskRecord } from './task-store'

/**
 * The task popup's calls, answered locally: every family of the reference
 * CRM's task page against real LocalTasks and a real store, with the engine,
 * the Mac's choosers and "open in the app for it" faked, and files in a
 * temporary folder.
 */

const PNG = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4])

let dir = ''
let clock = 0
let store: TaskStore
let local: LocalTasks
let detail: LocalTaskDetail
let replies: Array<{ id: string; text: string }>
let reassigned: Array<{ id: string; to: string }>
let opened: string[]
let openAnswer = ''
let chosenFiles: string[]
let chosenFolder: string | null
let changes = 0

/** A fixed clock that moves a second per read, so every line has its own moment. */
const now = (): number => (clock += 1_000)

function build(): void {
  store = new TaskStore({ dir: null, now })
  const config = new TaskConfig({ dir })
  local = new LocalTasks({
    store,
    config,
    now,
    engine: {
      accept: async (task) => void store.update(task, { process: 'idle' }),
      reassign: async (task, assignee) => {
        reassigned.push({ id: task.id, to: assignee.identity })
        store.update(task, { assignee, mainAssignee: assignee.identity })
      },
      reply: async (task, text) => void replies.push({ id: task.id, text }),
      cancel: async () => undefined,
    },
    onUpdated: (task, list, notes) => detail.noteUpdate(task, list, notes),
  })
  detail = new LocalTaskDetail({
    store,
    config,
    local,
    filesDir: join(dir, 'remote', 'task-files'),
    chooseFiles: async () => chosenFiles,
    chooseFolder: async () => chosenFolder,
    openPath: async (path) => {
      opened.push(path)
      return openAnswer
    },
    now,
    onChange: () => void (changes += 1),
  })
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-task-detail-'))
  writeFileSync(join(dir, TASK_CONFIG_FILE), JSON.stringify({ v: 1, agents: [{ id: 'builder', name: 'Builder' }, { id: 'tester', name: 'Tester' }], connections: [] }))
  clock = Date.UTC(2026, 9, 7, 9, 0, 0)
  replies = []
  reassigned = []
  opened = []
  openAnswer = ''
  chosenFiles = []
  chosenFolder = null
  changes = 0
  build()
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

/** One popup call; its result as the window reads it. */
async function call<T = Record<string, unknown>>(fn: Parameters<LocalTaskDetail['call']>[0], ...args: unknown[]): Promise<T> {
  return (await detail.call(fn, args)) as T
}

async function make(title: string, extra: Record<string, unknown> = {}): Promise<TaskRecord> {
  return local.create({ title, assignee: 'me', status: 'To-Do', ...extra })
}

async function activity(task: TaskRecord): Promise<TaskActivityRow[]> {
  return (await call<{ rows: TaskActivityRow[] }>('listTaskActivity', task.id)).rows
}

describe('people and the task row', () => {
  it('the main assignee is the local task’s own: an agent needs a folder, starts through the engine, and others are only kept', async () => {
    const task = await make('Ship the docs')
    expect(await call('assignTask', task.id, 'builder')).toEqual({ ok: false, error: 'Choose the project folder the agent should work in.' })
    expect(await call('setTaskProject', task.id, '/work/app')).toEqual({ ok: true, project: '/work/app' })
    expect(await call('assignTask', task.id, 'builder')).toEqual({ ok: true })
    expect(reassigned).toEqual([{ id: task.id, to: 'builder' }])
    expect(await call('addTaskAssignee', task.id, 'hoot')).toEqual({ ok: true })
    expect(await call('addTaskAssignee', task.id, 'stranger')).toMatchObject({ ok: false })
    const bundle = await call<{ bundle: { people: { primary: { id: string; name: string }; others: Array<{ id: string }> } } }>('fetchTaskDetailBundle', task.id)
    expect(bundle.bundle.people.primary).toMatchObject({ id: 'builder', name: 'Builder' })
    expect(bundle.bundle.people.others.map((p) => p.id)).toEqual(['hoot'])
    expect(await call('removeTaskAssignee', task.id, 'hoot')).toEqual({ ok: true })
    const rows = await activity(task)
    expect(rows.map((r) => r.kind)).toEqual(expect.arrayContaining(['assigned', 'unassigned', 'field']))
    expect(rows.find((r) => r.kind === 'assigned' && r.payload.primary === true)?.payload).toMatchObject({ user_id: 'builder', name: 'Builder' })
    expect(rows.find((r) => r.kind === 'field')?.payload).toMatchObject({ label: 'Project folder', to: '/work/app' })
  })

  it('updates title, description, priority and dates through LocalTasks, and tells each from → to once', async () => {
    const task = await make('First line', { instructions: 'Old details' })
    expect(await call('updateTask', task.id, { title: 'Better line', description: 'New details', priority: 'High', startDate: '2026-10-08', dueDate: '2026-10-09' })).toEqual({ ok: true })
    expect(task).toMatchObject({ title: 'Better line', instructions: 'New details', priority: 'High', startDate: '2026-10-08', dueDate: '2026-10-09' })
    expect(await call('setTaskStatus', task.id, 'In Progress')).toEqual({ ok: true })
    expect(await call('setTaskStatus', task.id, 'Cancelled')).toMatchObject({ ok: false })
    expect(await call('updateTask', task.id, {})).toEqual({ ok: false, error: 'Nothing to update' })
    const rows = await activity(task)
    const kinds = rows.map((r) => r.kind)
    expect(kinds.filter((k) => k === 'status')).toHaveLength(1)
    expect(kinds.filter((k) => k === 'title')).toHaveLength(1)
    expect(rows.find((r) => r.kind === 'status')?.payload).toEqual({ from: 'To-Do', to: 'In Progress' })
    expect(rows.find((r) => r.kind === 'priority')?.payload).toEqual({ from: null, to: 'High' })
    expect(rows.find((r) => r.kind === 'dates')?.payload).toMatchObject({ start_to: '2026-10-08', due_to: '2026-10-09' })
    expect(rows.find((r) => r.kind === 'created')).toBeDefined()
    expect(rows[0].actor).toMatchObject({ id: 'me', name: 'You' })
    const history = await call<{ versions: Array<{ from: string | null; to: string | null; by: string }> }>('fetchDescriptionHistory', task.id)
    expect(history.versions).toEqual([expect.objectContaining({ from: 'Old details', to: 'New details', by: 'me' })])
    // Clearing a date takes its time with it.
    await call('setTaskTimes', task.id, { dueTime: '17:00' })
    await call('updateTask', task.id, { dueDate: '' })
    expect(task).toMatchObject({ dueDate: null, dueTime: null })
  })
})

describe('subtasks and checklists', () => {
  it('adds, ticks, assigns (joining the task), dates and removes subtasks', async () => {
    const task = await make('Parent')
    const added = await call<{ ok: true; id: string }>('addTaskSubtask', task.id, '  Write tests ')
    expect(added.ok).toBe(true)
    expect(await call('addTaskSubtask', task.id, 'x'.repeat(301))).toEqual({ ok: false, error: 'Subtask title is required (max 300 chars)' })
    expect(await call('setTaskSubtaskDone', task.id, added.id, true)).toEqual({ ok: true })
    expect(await call('setTaskSubtaskAssignee', task.id, added.id, 'tester')).toEqual({ ok: true })
    expect(await call('setSubtaskMeta', task.id, added.id, { priority: 'Critical', dueDate: '2026-10-20' })).toEqual({ ok: true })
    expect(await call('setSubtaskMeta', task.id, added.id, { priority: 'Huge' })).toEqual({ ok: false, error: 'Invalid priority' })
    const bundle = await call<{ bundle: { subtasks: unknown[]; people: { others: Array<{ id: string }> } } }>('fetchTaskDetailBundle', task.id)
    expect(bundle.bundle.subtasks).toEqual([{ id: added.id, title: 'Write tests', done: true, sortOrder: 0, assigneeUserId: 'tester' }])
    expect(bundle.bundle.people.others.map((p) => p.id)).toEqual(['tester'])
    const extras = await call<{ extras: { subtaskMeta: Record<string, unknown> } }>('fetchTaskPageExtras', task.id)
    expect(extras.extras.subtaskMeta[added.id]).toEqual({ priority: 'Critical', dueDate: '2026-10-20' })
    const rows = await activity(task)
    expect(rows.find((r) => r.kind === 'subtask_added')?.payload).toEqual({ subtask_id: added.id, title: 'Write tests' })
    expect(rows.find((r) => r.kind === 'subtask_done')?.payload).toEqual({ subtask_id: added.id, title: 'Write tests', done: true })
    expect(await call('deleteTaskSubtask', task.id, added.id)).toEqual({ ok: true })
    expect(await call('deleteTaskSubtask', task.id, added.id)).toEqual({ ok: false, error: 'Subtask not found' })
  })

  it('keeps checklists and their items, found by their own ids', async () => {
    const task = await make('Checklist host')
    const list = await call<{ id: string }>('addChecklist', task.id, null)
    const item = await call<{ id: string }>('addChecklistItem', list.id, 'Buy milk')
    expect(await call('addChecklistItem', list.id, '')).toEqual({ ok: false, error: 'Item is required (max 300 chars)' })
    expect(await call('setChecklistItemDone', item.id, true)).toEqual({ ok: true })
    expect(await call('setChecklistItemAssignee', item.id, 'hoot')).toEqual({ ok: true })
    expect(await call('renameChecklist', list.id, 'Errands')).toEqual({ ok: true })
    let bundle = await call<{ bundle: { checklists: Array<{ title: string; items: Array<{ title: string; done: boolean; assigneeUserId: string | null }> }> } }>('fetchTaskDetailBundle', task.id)
    expect(bundle.bundle.checklists).toEqual([expect.objectContaining({ title: 'Errands', items: [expect.objectContaining({ title: 'Buy milk', done: true, assigneeUserId: 'hoot' })] })])
    const rows = await activity(task)
    expect(rows.find((r) => r.kind === 'checklist_added')?.payload).toMatchObject({ title: 'Checklist' })
    expect(rows.filter((r) => r.kind === 'checklist_item').map((r) => r.payload.done)).toEqual([true, null])
    expect(await call('deleteChecklistItem', item.id)).toEqual({ ok: true })
    expect(await call('deleteChecklist', list.id)).toEqual({ ok: true })
    expect(await call('renameChecklist', list.id, 'Gone')).toEqual({ ok: false, error: 'Checklist not found' })
    bundle = await call('fetchTaskDetailBundle', task.id)
    expect(bundle.bundle.checklists).toEqual([])
  })
})

describe('dependencies', () => {
  it('links local tasks only, never a task to itself, and shows each link from both sides', async () => {
    const a = await make('A')
    const b = await make('B')
    expect(await call('addTaskDependency', a.id, a.id, 'blocks')).toEqual({ ok: false, error: 'A task cannot depend on itself' })
    expect(await call('addTaskDependency', a.id, 'k1:crm-task', 'blocks')).toEqual({ ok: false, error: 'Other task not found or not yours' })
    expect(await call('addTaskDependency', a.id, b.id, 'sideways')).toEqual({ ok: false, error: 'Invalid dependency kind' })
    expect(await call('addTaskDependency', a.id, b.id, 'blocks')).toEqual({ ok: true })
    expect(await call('addTaskDependency', a.id, b.id, 'blocks')).toEqual({ ok: true })
    const deps = async (task: TaskRecord) => (await call<{ bundle: { dependencies: TaskDependency[] } }>('fetchTaskDetailBundle', task.id)).bundle.dependencies
    expect(await deps(a)).toEqual([{ kind: 'blocks', otherTaskId: b.id, otherTitle: 'B', otherDone: false }])
    await call('setTaskStatus', a.id, 'Done')
    expect(await deps(b)).toEqual([{ kind: 'blocked_by', otherTaskId: a.id, otherTitle: 'A', otherDone: true }])
    // Taken off from the other side, the link made on A goes.
    expect(await call('removeTaskDependency', b.id, a.id, 'blocked_by')).toEqual({ ok: true })
    expect(await deps(a)).toEqual([])
    expect(await call('removeTaskDependency', b.id, a.id, 'blocked_by')).toEqual({ ok: false, error: 'Dependency not found' })
    expect((await activity(a)).find((r) => r.kind === 'dependency')?.payload).toMatchObject({ kind: 'blocks', title: 'B', removed: false })
  })
})

describe('attachments', () => {
  it('keeps uploads and chosen files in the task’s folder, by the CRM’s rules, and opens them', async () => {
    const task = await make('Files')
    const up = await call<{ ok: true; attachment: TaskAttachment }>('uploadTaskFile', task.id, { name: 'shot.png', type: 'image/png', bytes: PNG })
    expect(up.ok).toBe(true)
    expect(up.attachment).toMatchObject({ kind: 'upload', fileName: 'shot.png', mimeType: 'image/png', sizeBytes: PNG.byteLength })
    expect(up.attachment.previewUrl).toBe(`data:image/png;base64,${Buffer.from(PNG).toString('base64')}`)
    const onDisk = join(dir, 'remote', 'task-files', up.attachment.storagePath as string)
    expect(readFileSync(onDisk)).toEqual(Buffer.from(PNG))
    expect(await call('uploadTaskFile', task.id, { name: 'tool.exe', type: '', bytes: PNG })).toMatchObject({ ok: false, error: expect.stringMatching(/cannot be attached/) })

    const picked = join(dir, 'notes.txt')
    writeFileSync(picked, 'hello')
    const empty = join(dir, 'empty.txt')
    writeFileSync(empty, '')
    chosenFiles = [picked, empty]
    const chose = await call<{ ok: true; attachments: TaskAttachment[]; errors: string[] }>('chooseTaskFiles', task.id)
    expect(chose.attachments.map((a) => [a.fileName, a.mimeType, a.previewUrl])).toEqual([['notes.txt', 'text/plain', null]])
    expect(chose.errors).toEqual(['The file is empty.'])

    expect(await call('openTaskFile', task.id, chose.attachments[0].id)).toEqual({ ok: true })
    expect(opened[0]).toMatch(/notes\.txt$/)
    openAnswer = 'No application knows how to open it'
    expect(await call('openTaskFile', task.id, chose.attachments[0].id)).toMatchObject({ ok: false, error: expect.stringContaining('No application') })
    expect((await activity(task)).filter((r) => r.kind === 'attachment').map((r) => r.payload.file_name)).toEqual(['notes.txt', 'shot.png'])
  })

  it('links a file from another task as a pointer, and deletes a file once nothing points at it', async () => {
    const owner = await make('Owner')
    const other = await make('Other')
    const up = await call<{ attachment: TaskAttachment }>('uploadTaskFile', owner.id, { name: 'plan.pdf', type: '', bytes: PNG })
    const found = await call<{ hits: Array<{ id: string; label: string; secondary: string }> }>('searchTags', 'file', 'pla')
    expect(found.hits).toEqual([expect.objectContaining({ id: `${owner.id}/${up.attachment.id}`, label: 'plan.pdf', secondary: 'Owner' })])
    expect(await call('attachExistingDocument', other.id, found.hits[0].id)).toMatchObject({ ok: true })
    const linked = (await call<{ bundle: { attachments: TaskAttachment[] } }>('fetchTaskDetailBundle', other.id)).bundle.attachments
    expect(linked).toEqual([expect.objectContaining({ kind: 'document', fileName: 'plan.pdf', documentId: found.hits[0].id, mimeType: 'application/pdf' })])
    const file = join(dir, 'remote', 'task-files', up.attachment.storagePath as string)
    expect(await call('detachTaskAttachment', up.attachment.id)).toEqual({ ok: true })
    expect(existsSync(file)).toBe(true)
    expect(await call('openTaskFile', other.id, linked[0].id)).toEqual({ ok: true })
    expect(await call('detachTaskAttachment', linked[0].id)).toEqual({ ok: true })
    expect(existsSync(file)).toBe(false)
  })

  it('keeps a deleted task’s files in the Trash with it — even when the only other task pointing at one lets go — and they open again once it is restored', async () => {
    const task = await make('Disposable')
    const other = await make('Points at it')
    const up = await call<{ attachment: TaskAttachment }>('uploadTaskFile', task.id, { name: 'a.txt', type: 'text/plain', bytes: PNG })
    const file = join(dir, 'remote', 'task-files', up.attachment.storagePath as string)
    const linked = await call<{ id: string }>('attachExistingDocument', other.id, `${task.id}/${up.attachment.id}`)
    await local.remove(task.id)
    expect(existsSync(file)).toBe(true)
    expect(await call('fetchTaskDetailBundle', task.id)).toEqual({ ok: false, error: 'That task no longer exists.' })
    // The pointer let go: the file is still the trashed task's, so it stays.
    expect(await call('detachTaskAttachment', linked.id)).toEqual({ ok: true })
    expect(existsSync(file)).toBe(true)
    await local.restore(task.id)
    const bundle = await call<{ bundle: { attachments: TaskAttachment[] } }>('fetchTaskDetailBundle', task.id)
    expect(bundle.bundle.attachments.map((a) => a.fileName)).toEqual(['a.txt'])
    expect(await call('openTaskFile', task.id, up.attachment.id)).toEqual({ ok: true })
    expect(opened).toEqual([file])
  })
})

describe('custom fields', () => {
  it('creates, values, renames, votes, presses and reorders fields with the CRM’s rules', async () => {
    const task = await make('Fields')
    const other = await make('Linked task')
    const price = await call<{ ok: true; field: TaskField }>('createTaskField', task.id, { label: 'Price', kind: 'number', value: 12.345 })
    expect(price.field).toMatchObject({ label: 'Price', kind: 'number', value: 12.35, taskId: task.id })
    expect(await call('createTaskField', task.id, { label: 'price', kind: 'text' })).toEqual({ ok: false, error: 'This task already has a field called “price”' })
    const qty = await call<{ field: TaskField }>('createTaskField', task.id, { label: 'Qty', kind: 'number' })
    const total = await call<{ field: TaskField }>('createTaskField', task.id, { label: 'Total', kind: 'formula', config: { expression: '{Price} * {Qty}' } })
    expect(await call('updateTaskFieldValue', qty.field.id, 3)).toMatchObject({ ok: true, field: { value: 3 } })
    expect(await call('updateTaskFieldValue', total.field.id, 1)).toMatchObject({ ok: false })
    const renamed = await call<{ ok: true; formulas: TaskField[] }>('renameTaskField', qty.field.id, 'Count')
    expect(renamed.formulas[0].config.expression).toBe('{Price} * {Count}')

    const who = await call<{ field: TaskField }>('createTaskField', task.id, { label: 'Owners', kind: 'people' })
    expect(await call('updateTaskFieldValue', who.field.id, ['builder', 'me'])).toMatchObject({ ok: true, field: { value: ['builder', 'me'] } })
    expect(await call('updateTaskFieldValue', who.field.id, ['ghost'])).toMatchObject({ ok: false })
    const links = await call<{ field: TaskField }>('createTaskField', task.id, { label: 'See also', kind: 'tasks' })
    expect(await call('updateTaskFieldValue', links.field.id, [{ id: other.id, label: 'x' }])).toMatchObject({ ok: true, field: { value: [{ id: other.id, label: 'Linked task' }] } })
    expect(await call('updateTaskFieldValue', links.field.id, [{ id: task.id, label: 'me' }])).toEqual({ ok: false, error: 'A task cannot link to itself' })

    const vote = await call<{ field: TaskField }>('createTaskField', task.id, { label: 'Votes', kind: 'voting' })
    expect(await call('toggleTaskFieldVote', vote.field.id)).toMatchObject({ field: { value: { votes: { me: true } } } })
    expect(await call('toggleTaskFieldVote', vote.field.id)).toMatchObject({ field: { value: null } })

    const progress = await call<{ field: TaskField }>('createTaskField', task.id, { label: 'Progress', kind: 'progress_auto' })
    expect(progress.field.kind).toBe('progress_auto')
    const sub = await call<{ id: string }>('addTaskSubtask', task.id, 'One')
    await call('addTaskSubtask', task.id, 'Two')
    await call('setTaskSubtaskDone', task.id, sub.id, true)
    const listed = await call<{ fields: TaskField[]; people: Record<string, { name: string }>; auto: unknown; viewerId: string }>('listTaskFields', task.id)
    expect(listed.auto).toEqual({ subtasks: { done: 1, total: 2 }, checklists: { done: 0, total: 0 } })
    expect(listed.people.builder.name).toBe('Builder')
    expect(listed.viewerId).toBe('me')
    expect(listed.fields.map((f) => f.label)).toEqual(['Price', 'Count', 'Total', 'Owners', 'See also', 'Votes', 'Progress'])

    const button = await call<{ field: TaskField }>('createTaskField', task.id, { label: 'Finish', kind: 'button', config: { action: { type: 'status', status: 'Done' } } })
    expect(await call('pressTaskFieldButton', button.field.id)).toMatchObject({ ok: true, status: 'Done', field: { value: { count: 1, lastBy: 'me' } } })
    expect(task.crmStatus).toBe('Done')

    const ids = listed.fields.map((f) => f.id).reverse()
    expect(await call('reorderTaskFields', task.id, ids)).toEqual({ ok: false, error: 'The fields changed — reload and try again' })
    expect(await call('reorderTaskFields', task.id, [button.field.id, ...ids])).toEqual({ ok: true })
    expect(await call('deleteTaskField', price.field.id)).toEqual({ ok: true })
    const lines = (await activity(task)).filter((r) => r.kind === 'field').map((r) => r.payload.action)
    expect(lines).toEqual(expect.arrayContaining(['added', 'changed', 'renamed', 'voted', 'pressed', 'removed']))
  })
})

describe('comments', () => {
  it('threads one level, reacts, resolves, assigns and schedules', async () => {
    const task = await make('Talk')
    const first = await call<{ ok: true; id: string }>('addTaskComment', task.id, 'Hello there')
    const reply = await call<{ id: string }>('addTaskCommentWith', task.id, 'A reply', { parentId: first.id })
    const deeper = await call<{ id: string }>('addTaskCommentWith', task.id, 'Deeper', { parentId: reply.id })
    expect(await call('addTaskComment', task.id, '   ')).toEqual({ ok: false, error: 'Comment is required (max 2000 chars)' })
    expect(await call('toggleCommentReaction', task.id, first.id, '👍')).toEqual({ ok: true, on: true })
    expect(await call('toggleCommentReaction', task.id, first.id, '🦄')).toEqual({ ok: false, error: 'That reaction is not offered' })
    expect(await call('setCommentResolved', task.id, first.id, true)).toEqual({ ok: true })
    let extras = await call<{ extras: { meta: Record<string, { parentId: string | null; resolvedBy: string | null; assigneeUserId: string | null }>; reactions: Record<string, unknown> } }>('fetchCommentExtras', task.id)
    expect(extras.extras.meta[deeper.id].parentId).toBe(first.id)
    expect(extras.extras.meta[first.id].resolvedBy).toBe('me')
    expect(extras.extras.reactions[first.id]).toEqual([{ emoji: '👍', userIds: ['me'] }])
    expect(await call('toggleCommentReaction', task.id, first.id, '👍')).toEqual({ ok: true, on: false })
    // A new assignment reopens it.
    expect(await call('assignComment', task.id, first.id, 'tester')).toEqual({ ok: true })
    extras = await call('fetchCommentExtras', task.id)
    expect(extras.extras.meta[first.id]).toMatchObject({ assigneeUserId: 'tester', resolvedBy: null })
    expect(extras.extras.reactions[first.id]).toBeUndefined()

    expect(await call('addTaskCommentWith', task.id, 'Too late', { scheduledFor: new Date(clock - 60_000).toISOString() })).toEqual({ ok: false, error: 'Pick a time in the future' })
    const later = await call<{ id: string }>('addTaskCommentWith', task.id, 'Later', { scheduledFor: new Date(clock + 3_600_000).toISOString() })
    expect(await call('sendScheduledNow', task.id, later.id)).toEqual({ ok: true })
    expect(await call('sendScheduledNow', task.id, later.id)).toEqual({ ok: true, alreadySent: true })
    extras = await call('fetchCommentExtras', task.id)
    expect(extras.extras.meta[later.id]).toMatchObject({ deliveredAt: expect.any(String) })
    const comments = (await call<{ comments: TaskComment[] }>('listTaskComments', task.id)).comments
    expect(comments.map((c) => c.body)).toEqual(['Hello there', 'A reply', 'Deeper', 'Later'])
    expect(comments[0]).toMatchObject({ authorUserId: 'me', authorName: 'You' })
  })

  it('an agent’s notes are its comments, and a mention or a reply to it reaches the agent that holds or handed back the task', async () => {
    const task = await make('Agent work', { project: '/work/app' })
    await call('assignTask', task.id, 'builder')
    store.note(task, { by: 'builder', kind: 'question', text: 'Which port?' })
    store.note(task, { by: 'builder', kind: 'progress', text: 'Started.' })
    let comments = (await call<{ comments: TaskComment[] }>('listTaskComments', task.id)).comments
    const question = comments.find((c) => c.body === 'Which port?') as TaskComment
    expect(question).toMatchObject({ authorUserId: 'builder', authorName: 'Builder' })

    // Not named: kept as a comment, not sent.
    await call('addTaskComment', task.id, 'Note to self')
    expect(replies).toEqual([])
    // Named: sent to the agent in its conversation.
    expect(await call('addTaskComment', task.id, '@Builder use 8080')).toMatchObject({ ok: true })
    expect(replies).toEqual([{ id: task.id, text: '@Builder use 8080' }])
    // A reply in the agent's thread reaches it too.
    await call('addTaskCommentWith', task.id, 'And restart it', { parentId: question.id })
    expect(replies.map((r) => r.text)).toEqual(['@Builder use 8080', 'And restart it'])
    // A name that is not the task's agent reaches nobody.
    await call('addTaskComment', task.id, '@Tester look')
    expect(replies).toHaveLength(2)

    // The engine's own record of a reply does not show it twice.
    store.note(task, { by: 'me', kind: 'reply', text: '@Builder use 8080' })
    store.note(task, { by: 'me', kind: 'reply', text: 'An older reply' })
    comments = (await call<{ comments: TaskComment[] }>('listTaskComments', task.id)).comments
    expect(comments.filter((c) => c.body === '@Builder use 8080')).toHaveLength(1)
    expect(comments.some((c) => c.body === 'An older reply')).toBe(true)
    // Reactions work on an agent's comment as on any other.
    expect(await call('toggleCommentReaction', task.id, question.id, '✅')).toEqual({ ok: true, on: true })
  })

  it('a task handed back to you still reaches the agent that handed it, and says so when it cannot', async () => {
    const task = await make('Handed back')
    store.update(task, { handedFrom: 'tester' })
    await call('addTaskComment', task.id, '@tester done, carry on')
    expect(replies).toEqual([{ id: task.id, text: '@tester done, carry on' }])
    store.update(task, { handedFrom: 'gone-agent' })
    const r = await call<{ ok: true }>('addTaskComment', task.id, 'nobody named')
    expect(r).toMatchObject({ ok: true })
  })
})

describe('activity from the task’s own record', () => {
  it('reads the notes a CRM would have been told, without telling a change twice', async () => {
    const task = await make('Old style')
    // What the engine does when an agent gets stuck on a local task: the status, and its line.
    store.update(task, { crmStatus: 'Stuck' })
    store.note(task, { by: 'builder', kind: 'status', text: 'Status: Stuck' })
    store.note(task, { by: 'builder', kind: 'assigned', text: 'Handed to you.' })
    store.note(task, { by: 'me', kind: 'edited', text: 'Changed the title, details.' })
    const rows = await activity(task)
    expect(rows.map((r) => r.kind)).toEqual(['title', 'description', 'assigned', 'status', 'created'])
    expect(rows.find((r) => r.kind === 'status')).toMatchObject({ actorUserId: 'builder', payload: { from: null, to: 'Stuck' } })
    expect(rows.find((r) => r.kind === 'assigned')?.payload).toMatchObject({ user_id: 'me' })
    // A change made now is told once, in the CRM's own words.
    await call('setTaskStatus', task.id, 'Done')
    const after = await activity(task)
    expect(after.filter((r) => r.kind === 'status').map((r) => r.payload)).toEqual([{ from: 'Stuck', to: 'Done' }, { from: null, to: 'Stuck' }])
  })
})

describe('time', () => {
  it('runs one timer across every task, adds manual entries by the CRM’s rules, and keeps entry tags', async () => {
    const a = await make('A')
    const b = await make('B')
    const started = await call<{ ok: true; entry: { id: string; endedAt: string | null } }>('startTaskTimer', a.id)
    expect(started.entry.endedAt).toBeNull()
    await call('startTaskTimer', b.id)
    const aTime = (await call<{ extras: { timeEntries: Array<{ endedAt: string | null; seconds: number | null }> } }>('fetchTaskPageExtras', a.id)).extras.timeEntries
    expect(aTime[0].endedAt).not.toBeNull()
    expect(aTime[0].seconds).toBeGreaterThan(0)
    expect((await activity(a)).find((r) => r.kind === 'time_tracked')).toBeDefined()
    const stopped = await call<{ entry: { seconds: number } | null }>('stopTaskTimer', b.id)
    expect(stopped.entry?.seconds).toBeGreaterThan(0)
    expect(await call('stopTaskTimer', b.id)).toEqual({ ok: true, entry: null })

    const seconds = parseDuration('1h 30m')
    expect(seconds).toBe(5_400)
    const manual = await call<{ ok: true; entry: { id: string; seconds: number } }>('addTaskTimeEntry', a.id, { seconds, date: '2026-10-05', note: 'review' })
    expect(manual.entry.seconds).toBe(5_400)
    expect(await call('addTaskTimeEntry', a.id, { seconds: 60, date: '2099-01-01' })).toEqual({ ok: false, error: 'That day has not happened yet' })
    expect(await call('addTaskTimeEntry', a.id, { seconds: 25 * 3600 })).toEqual({ ok: false, error: 'Enter a time between 1 minute and 24 hours' })
    expect(await call('setTimeEntryTags', a.id, manual.entry.id, ['billing', 'Billing', ' ops '])).toEqual({ ok: true, tags: ['billing', 'ops'] })
    expect((await call<{ more: { entryTags: Record<string, string[]> } }>('fetchTaskMore', a.id)).more.entryTags[manual.entry.id]).toEqual(['billing', 'ops'])
    expect(await call('setTimeEstimate', a.id, 90)).toEqual({ ok: true })
    expect(a.estimateMinutes).toBe(90)
    expect(await call('deleteTaskTimeEntry', a.id, manual.entry.id)).toEqual({ ok: true })
    expect(await call('deleteTaskTimeEntry', a.id, manual.entry.id)).toEqual({ ok: false, error: 'Time entry not found or not yours' })
  })
})

describe('the ⋯ menu and the rest of the row', () => {
  it('duplicates, archives, moves, types, tags and times a task', async () => {
    const task = await make('Original', { project: '/work/app', labels: ['web'] })
    await call('assignTask', task.id, 'builder')
    await call('addTaskSubtask', task.id, 'Sub')
    const copy = await call<{ ok: true; id: string }>('duplicateTask', task.id)
    const made = store.byId(copy.id) as TaskRecord
    expect(made).toMatchObject({ title: 'Original (copy)', labels: ['web'], project: '/work/app' })
    // A copy is yours; the agent comes along as one of the people, and is not started again.
    expect(made.assignee.identity).toBe('me')
    const bundle = await call<{ bundle: { subtasks: Array<{ title: string }>; people: { others: Array<{ id: string }> } } }>('fetchTaskDetailBundle', copy.id)
    expect(bundle.bundle.subtasks.map((s) => s.title)).toEqual(['Sub'])
    expect(bundle.bundle.people.others.map((p) => p.id)).toEqual(['builder'])

    expect(await call('setArchived', task.id, true)).toEqual({ ok: true })
    expect((await call<{ more: { archivedAt: string | null } }>('fetchTaskMore', task.id)).more.archivedAt).not.toBeNull()
    expect(await call('moveTask', task.id, 'Launch')).toEqual({ ok: true })
    expect(task.board).toBe('Launch')
    expect(await call('moveTask', task.id, '')).toEqual({ ok: true })
    expect(task.board).toBeNull()
    expect(await call('setTaskType', task.id, 'milestone')).toEqual({ ok: true })
    expect(await call('setTaskType', task.id, 'epic')).toEqual({ ok: false, error: 'Invalid task type' })
    expect(await call('setTaskLabels', task.id, ['web', 'Docs', 'docs'])).toEqual({ ok: true })
    expect(task.labels).toEqual(['web', 'Docs'])
    expect(await call('setTaskTimes', task.id, { startTime: '09:30' })).toEqual({ ok: true })
    expect(await call('setTaskTimes', task.id, { startTime: '9am' })).toEqual({ ok: false, error: 'Invalid time' })
    const kinds = (await activity(task)).map((r) => r.kind)
    expect(kinds).toEqual(expect.arrayContaining(['archived', 'moved', 'task_type', 'tags', 'dates']))
    expect(await call('setTaskLinks', task.id, [])).toEqual({ ok: false, error: 'Related records live in a CRM; local tasks cannot link to them.' })
  })

  it('merges one task into another and converts a task into a subtask; each source leaves the list', async () => {
    const source = await make('Source')
    const target = await make('Target')
    await call('addTaskSubtask', source.id, 'Moved subtask')
    await call('addTaskComment', source.id, 'Moved comment')
    await call('addTaskAssignee', source.id, 'tester')
    const up = await call<{ attachment: TaskAttachment }>('uploadTaskFile', source.id, { name: 'keep.txt', type: 'text/plain', bytes: PNG })
    expect(await call('mergeTaskInto', source.id, source.id)).toEqual({ ok: false, error: 'Pick another task' })
    expect(await call('mergeTaskInto', source.id, target.id)).toEqual({ ok: true })
    expect(store.byId(source.id)).toBeNull()
    const bundle = await call<{ bundle: { subtasks: Array<{ title: string }>; attachments: TaskAttachment[]; people: { others: Array<{ id: string }> } } }>('fetchTaskDetailBundle', target.id)
    expect(bundle.bundle.subtasks.map((s) => s.title)).toEqual(['Moved subtask'])
    expect(bundle.bundle.people.others.map((p) => p.id)).toEqual(['tester'])
    expect(bundle.bundle.attachments.map((a) => a.fileName)).toEqual(['keep.txt'])
    expect(existsSync(join(dir, 'remote', 'task-files', up.attachment.storagePath as string))).toBe(true)
    expect((await call<{ comments: TaskComment[] }>('listTaskComments', target.id)).comments.map((c) => c.body)).toEqual(['Moved comment'])
    expect((await activity(target)).find((r) => r.kind === 'merged')?.payload).toMatchObject({ title: 'Source', people_added: ['tester'] })

    const child = await make('Becomes a subtask\nwith more text')
    await call('setTaskStatus', child.id, 'Done')
    expect(await call('convertToSubtask', child.id, target.id)).toEqual({ ok: true })
    expect(store.byId(child.id)).toBeNull()
    const subs = (await call<{ bundle: { subtasks: Array<{ title: string; done: boolean; assigneeUserId: string | null }> } }>('fetchTaskDetailBundle', target.id)).bundle.subtasks
    expect(subs[1]).toMatchObject({ title: 'Becomes a subtask', done: true, assigneeUserId: 'me' })
  })

  it('syncs the task’s dates with its subtasks when asked', async () => {
    const task = await make('Span')
    const one = await call<{ id: string }>('addTaskSubtask', task.id, 'One')
    const two = await call<{ id: string }>('addTaskSubtask', task.id, 'Two')
    await call('setSubtaskMeta', task.id, one.id, { dueDate: '2026-10-12' })
    await call('setSubtaskMeta', task.id, two.id, { dueDate: '2026-10-20' })
    expect(await call('setSyncSubtaskDates', task.id, true)).toEqual({ ok: true, startDate: '2026-10-12', dueDate: '2026-10-20' })
    expect(task).toMatchObject({ startDate: '2026-10-12', dueDate: '2026-10-20' })
    await call('setSubtaskMeta', task.id, two.id, { dueDate: '2026-10-25' })
    expect(task.dueDate).toBe('2026-10-25')
    expect((await call<{ more: { syncSubtaskDates: boolean } }>('fetchTaskMore', task.id)).more.syncSubtaskDates).toBe(true)
  })

  it('has only you as a follower, offers no reminders when nothing delivers them, colours tags everywhere and deletes a tag everywhere', async () => {
    const a = await make('A', { labels: ['urgent'] })
    const b = await make('B', { labels: ['Urgent', 'web'] })
    type More = { iFollow: boolean; followers: Array<{ userId: string }>; remindersLive: boolean; canColorTags: boolean; canRemoveFollowers: boolean; reminders: Array<{ note: string | null }>; labelColors: Record<string, string> }
    const more = async (task: TaskRecord): Promise<More> => (await call<{ more: More }>('fetchTaskMore', task.id)).more
    expect(await more(a)).toMatchObject({ iFollow: true, followers: [{ userId: 'me' }], remindersLive: false, canColorTags: true, canRemoveFollowers: false })
    // Only you see a task here: nobody to add as a follower, nothing to unfollow — said, never pretended.
    for (const [fn, ...args] of [['setFollowing', a.id, false], ['addFollower', a.id, 'hoot'], ['removeFollower', a.id, 'me']] as const) {
      expect(await call(fn, ...args)).toEqual({ ok: false, error: 'Only you see tasks on this computer, so there is nobody else to follow this one — and nothing to unfollow.' })
    }
    expect(await more(a)).toMatchObject({ iFollow: true, followers: [{ userId: 'me' }] })
    // This rig delivers no reminders (no `notify`): one is refused in words, never kept to never come.
    expect(await call('setReminder', a.id, new Date(clock + 3_600_000).toISOString(), 'Ping')).toEqual({ ok: false, error: 'Nothing on this computer delivers reminders.' })
    expect((await more(a)).reminders).toEqual([])

    expect(await call('setLabelColor', 'Urgent', 'red')).toEqual({ ok: true })
    expect(await call('setLabelColor', 'Urgent', 'neon')).toEqual({ ok: false, error: 'Invalid colour' })
    expect((await more(b)).labelColors).toEqual({ urgent: 'red' })
    // Kept beside the task records: a fresh instance reads the colours back.
    expect(existsSync(join(dir, 'remote', 'task-detail.json'))).toBe(true)
    const fresh = new LocalTaskDetail({ store, config: new TaskConfig({ dir }), local, filesDir: join(dir, 'remote', 'task-files'), chooseFiles: async () => [], chooseFolder: async () => null, openPath: async () => '' })
    expect(((await fresh.call('fetchTaskMore', [b.id])) as { more: More }).more.labelColors).toEqual({ urgent: 'red' })

    expect(await call('deleteLabelEverywhere', 'URGENT')).toEqual({ ok: true, removed: 2, keptElsewhere: 0, taskIds: [a.id, b.id] })
    expect(a.labels).toEqual([])
    expect(b.labels).toEqual(['web'])
    expect((await more(b)).labelColors).toEqual({})
  })
})

describe('routines', () => {
  it('keeps a routine’s rule, version, pause and stop, and says which dates come next', async () => {
    const task = await make('Weekly report', { dueDate: '2026-10-09' })
    const empty = await call<{ routine: { rule: unknown; next: string[]; version: number } }>('fetchRoutine', task.id)
    expect(empty.routine).toMatchObject({ rule: null, next: [], version: 0 })
    const saved = await call<{ ok: true; rootTaskId: string; version: number }>('saveRoutine', task.id, { frequency: 'weekly', interval: 1, unit: 'week', weekdays: [5], monthly: null, trigger: 'status', triggerStatus: 'Done', timeOfDay: '08:00', ends: { type: 'never' }, createNew: true, updateStatusTo: 'To-Do', syncToDue: true, skipWeekends: false, perAssignee: false, missedPolicy: 'leave_open', pausedAt: null, stoppedAt: null, rootTaskId: null, anchor: null }, 0)
    expect(saved).toEqual({ ok: true, rootTaskId: task.id, version: 1 })
    expect(task.recurrence).toBe('weekly')
    const view = await call<{ routine: { next: string[]; rule: { anchor: string } } }>('fetchRoutine', task.id)
    expect(view.routine.next).toEqual(['2026-10-16', '2026-10-23', '2026-10-30'])
    expect(view.routine.rule.anchor).toBe('2026-10-09')
    expect(await call('saveRoutine', task.id, null, 0)).toMatchObject({ ok: false })
    expect(await call('pauseRoutine', task.id, true)).toEqual({ ok: true })
    expect((await call<{ routine: { next: string[] } }>('fetchRoutine', task.id)).routine.next).toEqual([])
    expect(await call('stopRoutine', task.id)).toEqual({ ok: true })
    expect(task.recurrence).toBeNull()
    expect(await call('stopRoutine', task.id)).toEqual({ ok: false, error: 'This task does not repeat.' })
    expect(await call('setTaskRecurrence', task.id, 'daily', null)).toEqual({ ok: true })
    expect(task.recurrence).toBe('daily')
    expect(await call('updateTask', task.id, { recurrence: null })).toEqual({ ok: true })
    expect(task.recurrence).toBeNull()
    expect((await activity(task)).filter((r) => r.kind === 'recurrence').length).toBeGreaterThan(2)
  })
})

describe('search, the project folder and the door', () => {
  it('finds your people and tasks, from two characters', async () => {
    const task = await make('Refactor the parser')
    expect(await call('searchTags', 'person', 'b')).toEqual({ ok: true, hits: [] })
    expect((await call<{ hits: Array<{ id: string }> }>('searchTags', 'person', 'bui')).hits.map((h) => h.id)).toEqual(['builder'])
    const tasks = await call<{ hits: Array<{ id: string; href: string; status: string }> }>('searchTags', 'task', 'pars')
    expect(tasks.hits).toEqual([expect.objectContaining({ id: task.id, status: 'To-Do', href: `/tasks?task=${encodeURIComponent(task.id)}` })])
    expect(await call('searchTags', 'listing', 'anything')).toEqual({ ok: true, hits: [] })
  })

  it('chooses the project folder with the Mac’s chooser, and a cancel changes nothing', async () => {
    const task = await make('Needs a folder')
    expect(await call('chooseTaskProject', task.id)).toEqual({ ok: true, project: '', chosen: false })
    chosenFolder = '/work/site'
    expect(await call('chooseTaskProject', task.id)).toEqual({ ok: true, project: '/work/site', chosen: true })
    expect(await call('setTaskProject', task.id, 'relative/path')).toEqual({ ok: false, error: 'relative/path is not a full folder path.' })
  })

  it('refuses a task that is not yours, and redraws the page after a write but not a read', async () => {
    store.put({ ...(await make('temp')), id: 'k1:crm', keyId: 'k1', externalTaskId: 'crm', local: undefined })
    expect(await call('fetchTaskDetailBundle', 'k1:crm')).toEqual({ ok: false, error: 'That task no longer exists.' })
    expect(await call('fetchTaskDetailBundle', 'local:nope')).toEqual({ ok: false, error: 'That task no longer exists.' })
    const task = await make('Count changes')
    changes = 0
    await call('listTaskComments', task.id)
    expect(changes).toBe(0)
    await call('addTaskComment', task.id, 'hi')
    expect(changes).toBe(1)
    expect(await call('addTaskSubtask', 42, 'x')).toEqual({ ok: false, error: 'That request was not understood.' })
  })
})
