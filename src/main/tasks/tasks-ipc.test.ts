import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { AccessKeyView } from '../deck-control/access-keys'
import { LOCAL_DETAIL_CHANNEL } from '../../shared/crm/detail-contract'
import { DEFAULT_CRM_STATUSES, TASK_CONFIG_FILE, TaskConfig } from './task-config'
import { LocalTasks } from './task-local'
import { TaskOutbox } from './task-outbox'
import { TaskStore } from './task-store'
import { registerTasksIpc, type TasksResult, type TasksState } from './tasks-ipc'

/**
 * Settings → Tasks saving, end to end without a window: the patch the form
 * sends (its shape is pinned on the window's side, `tasks-model.test.ts`)
 * through the real IPC handlers into the real store, and back out as the state
 * the form redraws from.
 *
 * Inert throughout: the connection is read from a fixture file that already
 * holds a fixed placeholder secret, so nothing here generates a key or a
 * secret, and the outbox has no address to post to.
 */

const KEY = 'k1'
const PLACEHOLDER_SECRET = `whsec_${Buffer.alloc(32, 0).toString('base64')}`
const WINDOW = {} as Electron.WebContents
const STRANGER = {} as Electron.WebContents

let dir = ''
let handlers: Map<string, (event: { sender: Electron.WebContents }, ...args: unknown[]) => unknown>
let config: TaskConfig

function call<T>(channel: string, ...args: unknown[]): T {
  const handler = handlers.get(channel)
  if (!handler) throw new Error(`no handler for ${channel}`)
  return handler({ sender: WINDOW }, ...args) as T
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-tasks-ipc-'))
  writeFileSync(
    join(dir, TASK_CONFIG_FILE),
    JSON.stringify({
      v: 1,
      agents: [
        { id: 'builder', name: 'Builder' },
        { id: 'tester', name: 'Tester' },
      ],
      connections: [
        {
          keyId: KEY,
          enabled: false,
          eventsUrl: null,
          eventsSecret: PLACEHOLDER_SECRET,
          statuses: DEFAULT_CRM_STATUSES,
          hootIdentity: null,
          identities: {},
          allowedSenders: [],
          folders: [],
          maxHops: 3,
        },
      ],
    }),
  )
  config = new TaskConfig({ dir })
  handlers = new Map()
  const store = new TaskStore({ dir: null })
  registerTasksIpc(
    { handle: (channel, listener) => void handlers.set(channel, listener) },
    {
      config,
      store,
      local: new LocalTasks({
        store,
        config,
        engine: {
          accept: async (task) => void store.update(task, { process: 'idle' }),
          reassign: async (task, assignee) => void store.update(task, { assignee }),
          reply: async () => undefined,
          cancel: async () => undefined,
        },
      }),
      outbox: new TaskOutbox({ dir: null, target: () => null }),
      keys: () => [{ id: KEY, name: 'CRM' } as AccessKeyView],
      isApprover: (sender) => sender === WINDOW,
      closeSession: () => false,
    },
  )
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

/** The connection as the form reads it back. */
function shown() {
  return call<TasksState>('tasks:state').connections[0]
}

/** What the form's Save sends: every field, the statuses as they are. */
function formPatch(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    eventsUrl: null,
    hootIdentity: null,
    allowedSenders: [],
    folders: [],
    maxHops: 3,
    identities: {},
    statuses: DEFAULT_CRM_STATUSES,
    ...over,
  }
}

function save(patch: Record<string, unknown>): TasksResult {
  return call<TasksResult>('tasks:connection-save', KEY, patch)
}

describe('saving a CRM connection from the form', () => {
  it('saves every field the form sends, keeps the secret it had, and reads back the same', () => {
    const saved = save(
      formPatch({
        eventsUrl: 'https://crm.example.com/td-events',
        allowedSenders: ['u-asad', 'u-asad'],
        hootIdentity: ' u-hoot ',
        folders: ['/work/app', '/work/site'],
        maxHops: 2,
        identities: { 'u-builder': 'builder', 'u-tester': 'tester' },
      }),
    )
    expect(saved.ok).toBe(true)
    expect('secret' in saved ? saved.secret : undefined).toBeUndefined()
    expect(shown()).toMatchObject({
      eventsUrl: 'https://crm.example.com/td-events',
      allowedSenders: ['u-asad'],
      hootIdentity: 'u-hoot',
      folders: ['/work/app', '/work/site'],
      maxHops: 2,
      identities: { 'u-builder': 'builder', 'u-tester': 'tester' },
      statuses: DEFAULT_CRM_STATUSES,
      hasEventsSecret: true,
    })
    expect(JSON.stringify(call<TasksState>('tasks:state'))).not.toContain(PLACEHOLDER_SECRET)
    const onDisk = JSON.parse(readFileSync(join(dir, TASK_CONFIG_FILE), 'utf8')) as { connections: Array<{ eventsSecret: string; enabled: boolean }> }
    expect(onDisk.connections[0].eventsSecret).toBe(PLACEHOLDER_SECRET)
    expect(onDisk.connections[0].enabled).toBe(false)
  })

  it('refuses what the store refuses, says why, and changes nothing', () => {
    const cases: Array<[Record<string, unknown>, RegExp]> = [
      [{ eventsUrl: 'http://crm.example.com/hook' }, /https/],
      [{ folders: ['work/app'] }, /not a full folder path/],
      [{ hootIdentity: 'u-builder', identities: { 'u-builder': 'builder' } }, /cannot also be an agent/],
      [{ identities: { 'u-ghost': 'nobody' } }, /does not exist/],
      [{ maxHops: 9 }, /1 to 5/],
      [{ statuses: { ...DEFAULT_CRM_STATUSES, onStarted: 'Doing' } }, /has to be one of/],
    ]
    for (const [change, why] of cases) {
      const result = save(formPatch(change))
      expect(result.ok).toBe(false)
      expect(result.ok ? '' : result.message).toMatch(why)
    }
    expect(config.connection(KEY)).toMatchObject({ eventsUrl: null, folders: [], hootIdentity: null, identities: {} })
  })

  it('switches on and off by itself, without touching the other fields', () => {
    expect(save({ enabled: true }).ok).toBe(true)
    expect(config.connection(KEY)).toMatchObject({ enabled: true, eventsSecret: PLACEHOLDER_SECRET, allowedSenders: [] })
    expect(save({ enabled: false }).ok).toBe(true)
    expect(config.connection(KEY)?.enabled).toBe(false)
  })

  it('takes changes only from the app’s own window', () => {
    const handler = handlers.get('tasks:connection-save')!
    expect(() => handler({ sender: STRANGER }, KEY, { enabled: true })).toThrow(/only the app’s own window/)
    expect(config.connection(KEY)?.enabled).toBe(false)
  })
})

describe('pausing, archiving and restoring an agent from the window', () => {
  it('moves an agent along its status and sends back the state, refusing what makes no sense', () => {
    const paused = call<TasksResult>('tasks:agent-status', 'builder', 'pause')
    expect(paused.ok).toBe(true)
    expect(paused.state.agents.find((agent) => agent.id === 'builder')).toMatchObject({ status: 'paused' })
    expect(call<TasksResult>('tasks:agent-status', 'builder', 'pause')).toMatchObject({ ok: false, message: 'Builder is already paused.' })
    expect(call<TasksResult>('tasks:agent-status', 'builder', 'archive').state.agents.find((agent) => agent.id === 'builder')?.status).toBe('archived')
    expect(call<TasksResult>('tasks:agent-status', 'builder', 'restore').state.agents.find((agent) => agent.id === 'builder')?.status).toBe('active')
    expect(call<TasksResult>('tasks:agent-status', 'ghost', 'pause')).toMatchObject({ ok: false, message: 'That agent no longer exists.' })
    expect(call<TasksResult>('tasks:agent-status', 7, 'pause')).toMatchObject({ ok: false })
  })

  it('takes changes only from the app’s own window', () => {
    const handler = handlers.get('tasks:agent-status')!
    expect(() => handler({ sender: STRANGER }, 'builder', 'pause')).toThrow(/only the app/)
    expect(config.agent('builder')?.status).toBe('active')
  })
})

describe('your own tasks, from the window', () => {
  it('creates, changes and refuses through the three channels, and the state shows them as editable', async () => {
    const made = await call<Promise<TasksResult>>('tasks:local-create', { title: 'Write the notes', assignee: 'me', status: 'To-Do' })
    expect(made.ok).toBe(true)
    const task = made.state.tasks[0]
    expect(task).toMatchObject({ local: true, title: 'Write the notes', assignee: 'me', agent: 'Me', crmStatus: 'To-Do', process: 'idle' })
    expect(made.state.localStatuses).toEqual(['To-Do', 'Working on it', 'In Progress', 'Done', 'Stuck'])

    // An agent needs a folder to work in: refused without one, taken with one.
    const noFolder = await call<Promise<TasksResult>>('tasks:local-update', task.id, { assignee: 'tester' })
    expect(noFolder.ok ? '' : noFolder.message).toBe('Choose the project folder the agent should work in.')
    const moved = await call<Promise<TasksResult>>('tasks:local-update', task.id, { status: 'Done', assignee: 'tester', project: '/work/app' })
    expect(moved.state.tasks[0]).toMatchObject({ crmStatus: 'Done', assignee: 'tester', agent: 'Tester' })
    expect(moved.state.tasks[0].notes.map((note) => note.text)).toEqual([
      'Created, assigned to you.',
      'Changed the project.',
      'Status: Done',
      'Assigned to Tester.',
    ])

    const refused = await call<Promise<TasksResult>>('tasks:local-update', task.id, { status: 'Cancelled' })
    expect(refused).toMatchObject({ ok: false })
    expect(refused.ok ? '' : refused.message).toMatch(/status has to be one of/)
    const noAgent = await call<Promise<TasksResult>>('tasks:local-reply', task.id, 'hello')
    expect(noAgent.ok).toBe(true)
    expect(() => handlers.get('tasks:local-create')!({ sender: STRANGER }, { title: 'x' })).toThrow(/only the app’s own window/)
  })
})


describe('the Trash, from the window', () => {
  it('a deleted task leaves the list for the Trash, and the restore channel brings it back — only from the app’s own window', async () => {
    const made = await call<Promise<TasksResult>>('tasks:local-create', { title: 'Disposable', assignee: 'me' })
    const id = made.state.tasks[0].id
    const deleted = await call<Promise<TasksResult>>('tasks:local-delete', id)
    expect(deleted.state.tasks.map((t) => t.id)).not.toContain(id)
    expect(deleted.state.trash).toEqual([expect.objectContaining({ id, title: 'Disposable', deletedAt: expect.any(Number) })])
    expect(() => handlers.get('tasks:local-restore')!({ sender: STRANGER }, id)).toThrow(/only the app’s own window/)
    const restored = await call<Promise<TasksResult>>('tasks:local-restore', id)
    expect(restored.ok).toBe(true)
    expect(restored.state.tasks.map((t) => t.id)).toContain(id)
    expect(restored.state.trash).toEqual([])
    const again = await call<Promise<TasksResult>>('tasks:local-restore', id)
    expect(again.ok ? '' : again.message).toBe('That task is not in the Trash.')
  })
})

describe('the task popup’s channel', () => {
  function register(detail?: { call(fn: string, args: unknown[]): Promise<unknown> }) {
    const own = new Map<string, (event: { sender: Electron.WebContents }, ...args: unknown[]) => unknown>()
    const store = new TaskStore({ dir: null })
    registerTasksIpc(
      { handle: (channel, listener) => void own.set(channel, listener) },
      {
        config,
        store,
        outbox: new TaskOutbox({ dir: null, target: () => null }),
        keys: () => [],
        isApprover: (sender) => sender === WINDOW,
        closeSession: () => false,
        ...(detail === undefined ? {} : { detail: detail as never }),
      },
    )
    return own.get(LOCAL_DETAIL_CHANNEL)!
  }

  it('is the channel the window calls', () => {
    expect(LOCAL_DETAIL_CHANNEL).toBe('tasks:local-detail')
    expect(handlers.has('tasks:local-detail')).toBe(true)
  })

  it('passes the function and its arguments through, and answers with its result', async () => {
    const seen: Array<[string, unknown[]]> = []
    const handler = register({ call: async (fn, args) => (seen.push([fn, args]), { ok: true, id: 'sub-1' }) })
    expect(await handler({ sender: WINDOW }, 'addTaskSubtask', ['local:a', 'Write it'])).toEqual({ ok: true, id: 'sub-1' })
    expect(seen).toEqual([['addTaskSubtask', ['local:a', 'Write it']]])
  })

  it('refuses another window, a function it does not know, and arguments that are not a list', async () => {
    const seen: string[] = []
    const handler = register({ call: async (fn) => (seen.push(fn), { ok: true }) })
    await expect(Promise.resolve(handler({ sender: STRANGER }, 'addTaskSubtask', ['local:a', 'x']))).rejects.toThrow(/only the app’s own window/)
    expect(await handler({ sender: WINDOW }, 'dropDatabase', [])).toEqual({ ok: false, error: 'That is not something the task popup can do.' })
    expect(await handler({ sender: WINDOW }, 'addTaskSubtask', 'local:a')).toEqual({ ok: false, error: 'That request was not understood.' })
    expect(seen).toEqual([])
  })

  it('says so when tasks are not running', async () => {
    const handler = register()
    expect(await handler({ sender: WINDOW }, 'listTaskComments', ['local:a'])).toEqual({ ok: false, error: 'Tasks are not running on this computer right now.' })
  })
})

describe('a CRM with a key of its own', () => {
  it('is made only on a confirmed press, named, and its key handed back once', () => {
    const made: string[] = []
    const local: typeof handlers = new Map()
    registerTasksIpc(
      { handle: (channel, listener) => void local.set(channel, listener) },
      {
        config,
        store: new TaskStore({ dir: null }),
        outbox: new TaskOutbox({ dir: null, target: () => null }),
        keys: () => made.map((id) => ({ id, name: 'Sales CRM (CRM)', crmOnly: true, lastApp: null }) as unknown as AccessKeyView),
        isApprover: (sender) => sender === WINDOW,
        closeSession: () => false,
        makeCrmKey: (name) => {
          made.push(`crm-${made.length + 1}`)
          return { id: made[made.length - 1], key: `ak_secret_for_${name.replace(/ /g, '_')}` }
        },
      },
    )
    const create = (input: unknown) => local.get('tasks:connection-create')!({ sender: WINDOW }, input) as TasksResult & { key?: string }
    expect(create({ name: 'Sales CRM' })).toMatchObject({ ok: false })
    expect(create({ name: '  ', confirmed: true })).toMatchObject({ ok: false })
    expect(made).toEqual([])
    const answer = create({ name: 'Sales CRM', confirmed: true })
    expect(answer).toMatchObject({ ok: true, key: 'ak_secret_for_Sales_CRM' })
    expect(answer.state.connections.find((one) => one.keyId === 'crm-1')).toMatchObject({ name: 'Sales CRM', enabled: false })
    expect(() => local.get('tasks:connection-create')!({ sender: {} as Electron.WebContents }, { name: 'X', confirmed: true })).toThrow(/only the app/)
    expect(made).toEqual(['crm-1'])
  })
})
