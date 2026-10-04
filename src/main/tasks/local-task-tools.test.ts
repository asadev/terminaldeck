import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { TaskActivityRow } from '../../shared/crm/task-activity'
import type { TaskComment } from '../../shared/crm/tasks-data'
import type { ToolContext, ToolSpec } from '../deck-control/catalogue'
import { keyGrantOk } from '../deck-control/describe-tool'
import { fakeSurface } from '../deck-control/sessions-lane.fixture'
import { ALL_TIERS, LOCAL_CALLER, Refused, type Caller } from '../deck-control/surface'
import { TASK_CONFIG_FILE, TaskConfig } from './task-config'
import { LocalTaskDetail } from './task-detail-local'
import { LocalTasks } from './task-local'
import { localTaskTools } from './local-task-tools'
import { TaskStore, type TaskRecord } from './task-store'

/**
 * Your own tasks as MCP tools: their schemas and tiers, who may call them and
 * what they may see, and that each verb does what the window's own call does —
 * against the real LocalTasks, LocalTaskDetail and store, with the engine (which
 * would start an agent), the notification and the island faked. No agent runs,
 * nothing is shown, nothing leaves this process.
 */

let dir = ''
let project = ''
let store: TaskStore
let config: TaskConfig
let local: LocalTasks
let detail: LocalTaskDetail
let started: string[]
let island: { enabled: boolean }
let tools: ToolSpec[]
let surface: ReturnType<typeof fakeSurface>

const HOOT: Caller = LOCAL_CALLER
const KEY_OFF: Caller = { kind: 'key', keyId: 'k1', keyName: 'Claude Desktop', tiers: ALL_TIERS }
const KEY_ON: Caller = { ...KEY_OFF, tasks: true }

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-task-tools-'))
  project = join(dir, 'app')
  mkdirSync(project)
  writeFileSync(join(dir, TASK_CONFIG_FILE), JSON.stringify({ v: 1, agents: [{ id: 'builder', name: 'Builder' }], connections: [] }))
  store = new TaskStore({ dir: null })
  config = new TaskConfig({ dir })
  started = []
  local = new LocalTasks({
    store,
    config,
    engine: {
      accept: async (task) => {
        if (task.assignee.kind === 'agent') started.push(task.id)
        store.update(task, { process: 'idle' })
      },
      reassign: async (task, assignee) => {
        if (assignee.kind === 'agent') started.push(task.id)
        store.update(task, { assignee, mainAssignee: assignee.identity })
      },
      reply: async () => undefined,
      cancel: async () => undefined,
    },
    onUpdated: (task, list, notes) => detail.noteUpdate(task, list, notes),
  })
  detail = new LocalTaskDetail({
    store,
    config,
    local,
    filesDir: join(dir, 'task-files'),
    chooseFiles: async () => [],
    chooseFolder: async () => null,
    openPath: async () => '',
    notify: async () => ({ delivered: true }),
  })
  island = { enabled: true }
  surface = fakeSurface()
  surface.state.projects = [{ path: project, lastOpenedAt: 1 }]
  tools = localTaskTools({
    local: () => local,
    detail: () => detail,
    store: () => store,
    config: () => config,
    island: () => ({ get: () => ({ ...island }), set: (enabled) => ((island.enabled = enabled), { ...island }) }),
  })
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

function context(caller: Caller): ToolContext {
  return { surface: surface.surface, callId: 'c1', caller, attended: true, startedByCopilot: () => false, noteStarted: () => undefined, now: () => Date.now() }
}

function tool(id: string): ToolSpec {
  const spec = tools.find((t) => t.id === id)
  if (spec === undefined) throw new Error(`no tool ${id}`)
  return spec
}

/** One call as the dispatcher makes it: precheck, then run. */
async function call(id: string, args: Record<string, unknown>, caller: Caller = HOOT): Promise<Record<string, unknown>> {
  const spec = tool(id)
  spec.precheck?.(args, context(caller))
  const out = await spec.run(args, context(caller))
  return out.value as Record<string, unknown>
}

async function refused(id: string, args: Record<string, unknown>, caller: Caller): Promise<string> {
  try {
    await call(id, args, caller)
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
  throw new Error(`${id} ${JSON.stringify(args)} was not refused`)
}

const tierOf = (id: string, args: Record<string, unknown>) => {
  const spec = tool(id)
  return spec.escalate?.(args, context(HOOT)) ?? spec.tier
}

const created = async (title: string, extra: Record<string, unknown> = {}, caller: Caller = HOOT) =>
  ((await call('tasks.local_change', { do: 'create', title, ...extra }, caller)).created as { task: string }).task

describe('the schemas', () => {
  it('six tools, each one index line behind tools_describe, with a closed verb list and no stray arguments', () => {
    expect(tools.map((t) => t.id)).toEqual(['tasks.local', 'tasks.local_change', 'tasks.local_parts', 'tasks.local_schedule', 'tasks.agents', 'hoot.island'])
    for (const spec of tools) {
      expect(spec.wire).toBe(spec.id.replace(/\./g, '_'))
      expect(spec.index?.length).toBeGreaterThan(20)
      const schema = spec.inputSchema as { type: string; properties: Record<string, { enum?: unknown[] }>; required: string[]; additionalProperties: boolean }
      expect(schema.type).toBe('object')
      expect(schema.additionalProperties).toBe(false)
      expect(schema.required).toContain('do')
      expect(Array.isArray(schema.properties.do.enum)).toBe(true)
    }
    // The five task tools need the key's switch; the island is Hoot's alone.
    expect(tools.filter((t) => t.keyGrant === 'tasks').map((t) => t.id)).toEqual(['tasks.local', 'tasks.local_change', 'tasks.local_parts', 'tasks.local_schedule', 'tasks.agents'])
    expect(tool('hoot.island').audience).toBe('copilot')
  })

  it('reading is read; everyday moves are act; creating, removing, assigning, repeating and agents are alter', () => {
    expect(tierOf('tasks.local', { do: 'list' })).toBe('read')
    for (const v of ['status', 'comment', 'reply']) expect(tierOf('tasks.local_change', { do: v })).toBe('act')
    for (const v of ['create', 'update', 'assign', 'archive', 'unarchive', 'delete', 'restore']) expect(tierOf('tasks.local_change', { do: v })).toBe('alter')
    for (const v of ['subtask_add', 'subtask_done', 'checklist_item_done', 'field_set', 'time_start', 'time_add']) expect(tierOf('tasks.local_parts', { do: v })).toBe('act')
    for (const v of ['subtask_remove', 'checklist_remove', 'field_remove', 'attach_file', 'attachment_remove', 'time_remove']) expect(tierOf('tasks.local_parts', { do: v })).toBe('alter')
    for (const v of ['reminder_set', 'comment_schedule']) expect(tierOf('tasks.local_schedule', { do: v })).toBe('act')
    for (const v of ['repeat_set', 'repeat_stop', 'repeat_restart']) expect(tierOf('tasks.local_schedule', { do: v })).toBe('alter')
    expect(tierOf('tasks.agents', { do: 'list' })).toBe('read')
    expect(tierOf('tasks.agents', { do: 'save' })).toBe('alter')
    expect(tierOf('hoot.island', { do: 'set', enabled: false })).toBe('alter')
  })
})

describe('who may call them, and what they see', () => {
  it('an app whose key has “Your tasks” off cannot find or use them; Hoot always can', async () => {
    for (const spec of tools.filter((t) => t.keyGrant === 'tasks')) {
      expect(keyGrantOk(spec, KEY_OFF)).toBe(false)
      expect(keyGrantOk(spec, KEY_ON)).toBe(true)
      expect(keyGrantOk(spec, HOOT)).toBe(true)
    }
    expect(await refused('tasks.local', { do: 'list' }, KEY_OFF)).toMatch(/may not use your tasks.*Settings → Connect an AI app → Your tasks/)
    expect(await refused('hoot.island', { do: 'get' }, KEY_ON)).toMatch(/Hoot’s own tool/)
    expect((await call('tasks.local', { do: 'list' }, KEY_ON)).tasks).toEqual([])
  })

  it('a key limited to folders sees only tasks in them, and one outside answers like one that does not exist', async () => {
    const inside = await created('Inside', { project })
    const outside = await created('No folder')
    const scoped: Caller = { ...KEY_ON, folders: [project] }
    const listed = (await call('tasks.local', { do: 'list' }, scoped)).tasks as Array<{ task: string }>
    expect(listed.map((t) => t.task)).toEqual([inside])
    expect(await refused('tasks.local', { do: 'get', task: outside }, scoped)).toBe(`there is no task ${outside}`)
    expect(await refused('tasks.local', { do: 'get', task: 'local:nope' }, scoped)).toBe('there is no task local:nope')
    expect(await refused('tasks.local_change', { do: 'create', title: 'Loose' }, scoped)).toMatch(/limited to some folders/)
    expect(await created('Scoped one', { project }, scoped)).toMatch(/^local:/)
  })

  it('a project must be inside a folder the app has open; a CRM task is the CRM’s', async () => {
    expect(await refused('tasks.local_change', { do: 'create', title: 'Elsewhere', project: '/etc' }, HOOT)).toMatch(/not inside a folder Terminal Deck has open/)
    const seed = store.byId(await created('Seed')) as TaskRecord
    store.put({ ...seed, id: 'k1:42', keyId: 'k1', externalTaskId: '42', local: false })
    expect(await refused('tasks.local_change', { do: 'status', task: 'k1:42', status: 'Done' }, HOOT)).toMatch(/CRM task: the CRM owns it/)
  })
})

describe('what each verb does', () => {
  it('creates, edits, sets a status, assigns (starting the agent), comments — written down as the caller, never as you', async () => {
    const id = await created('Ship the notes', { details: 'For 0.19', priority: 'High', labels: ['docs'] })
    expect(store.byId(id)).toMatchObject({ title: 'Ship the notes', instructions: 'For 0.19', priority: 'High', labels: ['docs'], crmStatus: 'To-Do' })
    expect(store.byId(id)?.notes?.[0]).toMatchObject({ by: 'hoot', text: 'Created, assigned to you.' })
    await call('tasks.local_change', { do: 'update', task: id, due_date: '2026-10-20', board: 'Release' })
    await call('tasks.local_change', { do: 'status', task: id, status: 'In Progress' })
    expect(store.byId(id)).toMatchObject({ dueDate: '2026-10-20', board: 'Release', crmStatus: 'In Progress' })
    expect(await refused('tasks.local_change', { do: 'assign', task: id, assignee: 'builder' }, HOOT)).toMatch(/project folder/)
    await call('tasks.local_change', { do: 'assign', task: id, assignee: 'builder', project })
    expect(started).toEqual([id])
    const comment = await call('tasks.local_change', { do: 'comment', task: id, text: 'Started on it' })
    const comments = ((await call('tasks.local', { do: 'comments', task: id })).comments as TaskComment[]).filter((c) => c.id === comment.comment)
    expect(comments).toEqual([expect.objectContaining({ authorUserId: 'hoot', body: 'Started on it' })])
    const appMade = await created('From the app', {}, KEY_ON)
    const rows = (await call('tasks.local', { do: 'activity', task: appMade }, KEY_ON)).activity as TaskActivityRow[]
    expect(store.byId(appMade)?.notes?.[0].by).toBe('app:Claude Desktop')
    expect(JSON.stringify(rows)).not.toContain('"by":"me"')
  })

  it('archives and restores; delete moves to the Trash and restore brings it back — nothing is purged', async () => {
    const id = await created('Old idea')
    await call('tasks.local_change', { do: 'archive', task: id })
    expect(store.byId(id)?.archivedAt).not.toBeNull()
    expect(((await call('tasks.local', { do: 'list', archived: true })).tasks as Array<{ task: string }>).map((t) => t.task)).toEqual([id])
    await call('tasks.local_change', { do: 'unarchive', task: id })
    const gone = await call('tasks.local_change', { do: 'delete', task: id })
    expect(gone).toMatchObject({ trashed: id })
    expect(store.byId(id)).toBeNull()
    expect(((await call('tasks.local', { do: 'trash' })).trash as Array<{ task: string }>).map((t) => t.task)).toEqual([id])
    await call('tasks.local_change', { do: 'restore', task: id })
    expect(store.byId(id)?.title).toBe('Old idea')
  })

  it('works every part of the task page through the window’s own calls', async () => {
    const id = await created('Launch', { project })
    const other = await created('Write the post', { project })
    const sub = (await call('tasks.local_parts', { do: 'subtask_add', task: id, text: 'Book the venue' })).id as string
    await call('tasks.local_parts', { do: 'subtask_done', task: id, item: sub, done: true })
    const list = (await call('tasks.local_parts', { do: 'checklist_add', task: id, text: 'Before' })).id as string
    const item = (await call('tasks.local_parts', { do: 'checklist_item_add', task: id, checklist: list, text: 'Send invites' })).id as string
    await call('tasks.local_parts', { do: 'checklist_item_done', task: id, item, done: true })
    await call('tasks.local_parts', { do: 'dependency_add', task: id, other, kind: 'blocked_by' })
    const field = (await call('tasks.local_parts', { do: 'field_create', task: id, label: 'Venue', kind: 'text' })).field as { id: string }
    await call('tasks.local_parts', { do: 'field_set', task: id, field: field.id, value: 'North hall' })
    writeFileSync(join(project, 'plan.txt'), 'the plan')
    const attached = await call('tasks.local_parts', { do: 'attach_file', task: id, path: join(project, 'plan.txt') })
    await call('tasks.local_parts', { do: 'time_add', task: id, duration: '1h 20m' })
    const full = await call('tasks.local', { do: 'get', task: id })
    expect(full).toMatchObject({ subtasks: [expect.objectContaining({ title: 'Book the venue', done: true })], dependencies: [expect.objectContaining({ kind: 'blocked_by' })] })
    expect((full.checklists as Array<{ items: Array<{ done: boolean }> }>)[0].items[0].done).toBe(true)
    expect((full.fields as Array<{ label: string; value: unknown }>)[0]).toMatchObject({ label: 'Venue', value: 'North hall' })
    expect((full.attachments as Array<{ fileName: string }>).map((a) => a.fileName)).toEqual(['plan.txt'])
    expect(full.timeEntries).toEqual([expect.objectContaining({ seconds: 4800, userId: 'hoot' })])
    expect(attached.attachment).toBeDefined()
    // A part of another task, or a file outside the open folders, is refused.
    expect(await refused('tasks.local_parts', { do: 'subtask_done', task: other, item: sub, done: false }, HOOT)).toMatch(/has no subtask/)
    expect(await refused('tasks.local_parts', { do: 'attach_file', task: id, path: '/etc/hosts' }, HOOT)).toMatch(/not inside a folder/)
  })

  it('Hoot’s timer never stops yours', async () => {
    const id = await created('Pair on it')
    await detail.call('startTaskTimer', [id])
    await call('tasks.local_parts', { do: 'time_start', task: id })
    const running = () => store.byId(id)?.detail?.time.filter((e) => e.endedAt === null).map((e) => e.userId).sort()
    expect(running()).toEqual(['hoot', 'me'])
    // And stopping Hoot's leaves yours running.
    await call('tasks.local_parts', { do: 'time_stop', task: id })
    expect(running()).toEqual(['me'])
  })

  it('repeats, reminders and scheduled comments', async () => {
    const id = await created('Weekly report', { due_date: '2026-10-09' })
    await call('tasks.local_schedule', {
      do: 'repeat_set',
      task: id,
      rule: { frequency: 'weekly', interval: 1, unit: 'week', weekdays: [], monthly: null, trigger: 'status', triggerStatus: 'Done', timeOfDay: '08:00', ends: { type: 'never' }, createNew: true, updateStatusTo: 'To-Do', syncToDue: true, skipWeekends: false, perAssignee: false, missedPolicy: 'leave_open', pausedAt: null, stoppedAt: null, rootTaskId: null, anchor: null },
    })
    expect(((await call('tasks.local', { do: 'routine', task: id })).routine as { rule: { frequency: string } }).rule.frequency).toBe('weekly')
    await call('tasks.local_schedule', { do: 'repeat_pause', task: id })
    await call('tasks.local_schedule', { do: 'reminder_set', task: id, at: new Date(Date.now() + 3_600_000).toISOString(), note: 'Check' })
    expect(((await call('tasks.local', { do: 'get', task: id })).reminders as unknown[]).length).toBe(1)
    const later = await call('tasks.local_schedule', { do: 'comment_schedule', task: id, text: 'Reminder for the team', at: new Date(Date.now() + 7_200_000).toISOString() })
    expect(later.id).toEqual(expect.any(String))
  })

  it('reads and changes the task agents, and shows or hides the island', async () => {
    expect(((await call('tasks.agents', { do: 'list' })).agents as Array<{ id: string }>).map((a) => a.id)).toEqual(['builder'])
    await call('tasks.agents', { do: 'save', agent: { name: 'Reviewer', role: 'review', instructions: 'Read before you write.' } })
    expect(config.agents().map((a) => a.name)).toEqual(['Builder', 'Reviewer'])
    await call('tasks.agents', { do: 'save', agent: { id: 'builder', model: 'opus' } })
    expect(config.agent('builder')).toMatchObject({ name: 'Builder', model: 'opus' })
    const reviewer = config.agents().find((a) => a.name === 'Reviewer')!
    await call('tasks.agents', { do: 'remove', id: reviewer.id })
    expect(config.agents().map((a) => a.id)).toEqual(['builder'])
    expect(await call('hoot.island', { do: 'get' })).toEqual({ enabled: true })
    expect(await call('hoot.island', { do: 'set', enabled: false })).toEqual({ enabled: false })
    expect(island.enabled).toBe(false)
  })

  it('refuses a verb that is not on the list, before anything runs', async () => {
    expect(await refused('tasks.local_change', { do: 'purge', task: 'x' }, HOOT)).toMatch(/do must be one of/)
    expect(Refused).toBeDefined()
  })
})
