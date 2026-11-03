import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { panelSpec } from '../shell/panels'
import { toTasksState } from './tasks-model'
import { TasksPage, TasksPageBody, tasksActions, type TasksActions } from './TasksPage'

/**
 * Tasks, the sidebar page: every state it can be in, rendered from fixed data
 * the way the other page tests are, and its changes sent through a fake bridge.
 * No preload, no CRM, no session.
 */

const NOW = 1_800_000_000_000
const noop = (): void => undefined
const STATUSES = ['To-Do', 'Working on it', 'In Progress', 'Done', 'Stuck']

function state(over: Record<string, unknown> = {}) {
  const parsed = toTasksState({
    agents: [{ id: 'builder', name: 'Builder' }],
    connections: [],
    keys: [{ id: 'k1', name: 'CRM smoke' }],
    tasks: [],
    outbox: { pending: 0, undelivered: 0 },
    localStatuses: STATUSES,
    ...over,
  })
  if (parsed === null) throw new Error('not a state')
  return parsed
}

const fakeActions: TasksActions = {
  create: async () => ({ ok: true, message: null, state: null, secret: null }),
  update: async () => ({ ok: true, message: null, state: null, secret: null }),
  reply: async () => ({ ok: true, message: null, state: null, secret: null }),
  remove: async () => ({ ok: true, message: null, state: null, secret: null }),
  restore: async () => ({ ok: true, message: null, state: null, secret: null }),
  closeSession: async () => ({ ok: true, message: null, state: null, secret: null }),
}

const page = (s: ReturnType<typeof state> | null | undefined, available = true, withSettings = true) =>
  renderToStaticMarkup(
    <TasksPageBody available={available} state={s} now={NOW} actions={fakeActions} onOpenSettings={withSettings ? noop : undefined} />,
  )

function localTask(over: Record<string, unknown> = {}) {
  return {
    id: 'local:a', keyId: 'local', externalTaskId: 'a', title: 'Write the release notes', agent: 'Me', project: '',
    crmStatus: 'To-Do', process: 'idle', keepOpenUntil: null, verified: null, updatedAt: NOW - 60_000,
    local: true, assignee: 'me', instructions: 'For 0.18.0.', handedFrom: null, notes: [],
    ...over,
  }
}

describe('the Tasks page', () => {
  it('is a sidebar page in the project group, beside Simulators, with no shortcut of its own', () => {
    expect(panelSpec('tasks')).toMatchObject({ id: 'tasks', label: 'Tasks', group: 'project' })
    expect(panelSpec('tasks').command).toBeUndefined()
  })

  it('says so when this build has no task channels, and waits quietly for the first read', () => {
    expect(page(undefined, false)).toContain('Tasks are not available in this build')
    expect(page(undefined)).toContain('aria-busy="true"')
    expect(page(null)).toContain('Tasks could not be read')
  })

  it('with nothing yet, offers New task without any CRM, and the table, board and calendar', () => {
    const html = page(state({ agents: [] }))
    expect(html).toContain('Your tasks')
    expect(html).toContain('No tasks yet.')
    expect(html).toContain('>New task<')
    for (const tab of ['Table', 'Board', 'Calendar']) expect(html).toContain(`>${tab}</button>`)
    expect(html).toContain('0 task agents — add one in Settings to give tasks to an agent')
    expect(html).toContain('Agents and connections')
    expect(html).not.toContain('From your CRM')
  })

  it('shows your own task in its stage with the CRM row: status, who has it, due, priority, next step', () => {
    const html = page(state({ tasks: [localTask()] }))
    expect(html).toContain('aria-label="To-Do"')
    expect(html).toContain('Write the release notes')
    const status = /<select class="mw-status"[^>]*aria-label="Status of Write the release notes"[^>]*>(.*?)<\/select>/.exec(html)?.[1] ?? ''
    for (const s of STATUSES) expect(status).toContain(`>${s}</option>`)
    expect(status).toContain('<option value="To-Do" selected="">To-Do</option>')
    const who = /aria-label="Who has Write the release notes"[^>]*>(.*?)<\/select>/.exec(html)?.[1] ?? ''
    expect(who).toContain('<option value="none">Unassigned</option>')
    expect(who).toContain('<option value="me" selected="">Me</option>')
    expect(who).toContain('<option value="builder">Builder</option>')
    expect(html).toContain('aria-label="Move Write the release notes to Working on it"')
    expect(html).toContain('aria-label="Priority of Write the release notes"')
    expect(html).toContain('>+ Add task<')
  })

  it('marks a task an agent handed back to you on its row', () => {
    const html = page(state({ tasks: [localTask({ crmStatus: 'Stuck', handedFrom: 'Builder', project: '/work/app' })] }))
    expect(html).toContain('aria-label="Stuck"')
    expect(html).toContain('from Builder')
  })

  it('keeps CRM tasks apart and read-only', () => {
    const html = page(
      state({
        connections: [{ keyId: 'k1', enabled: true, allowedSenders: ['u-asad'], folders: ['/work'], maxHops: 3 }],
        tasks: [
          localTask(),
          {
            id: 'k1:T-7', keyId: 'k1', externalTaskId: 'T-7', title: 'Fix the login bug', agent: 'Builder', project: '/work/app',
            crmStatus: 'Done', process: 'exited', keepOpenUntil: null, verified: true, updatedAt: NOW - 5 * 60_000,
          },
        ],
        outbox: { pending: 2, undelivered: 1 },
      }),
    )
    expect(html).toContain('From your CRM')
    expect(html).toContain('Fix the login bug')
    expect(html).toContain('finished and checked')
    expect(html).not.toContain('Status of Fix the login bug')
    expect(html).toContain('2 updates on the way to the CRM · 1 could not be delivered')
  })

  it('renders from a fixed state without a preload', () => {
    expect(renderToStaticMarkup(<TasksPage bridge={{ tasksState: () => Promise.resolve({}) }} state={state()} now={NOW} />)).toContain('Your tasks')
  })
})

describe('what the page sends', () => {
  it('creates, changes and replies through the bridge with exactly what was typed, and checks first', async () => {
    const sent: Array<[string, ...unknown[]]> = []
    const ok = { ok: true, state: { agents: [], connections: [], keys: [], tasks: [], outbox: { pending: 0, undelivered: 0 } } }
    const actions = tasksActions({
      tasksLocalCreate: async (input) => (sent.push(['create', input]), ok),
      tasksLocalUpdate: async (id, patch) => (sent.push(['update', id, patch]), ok),
      tasksLocalReply: async (id, text) => (sent.push(['reply', id, text]), ok),
    })
    expect(await actions.create({ title: ' ', instructions: '', project: '', assignee: 'none', status: 'To-Do' })).toMatchObject({
      ok: false,
      message: 'Give the task a title.',
    })
    expect(await actions.create({ title: 'Fix it', instructions: '', project: '', assignee: 'builder', status: 'To-Do' })).toMatchObject({
      ok: false,
      message: 'Choose the project folder the agent should work in.',
    })
    expect(await actions.reply('local:a', '   ')).toMatchObject({ ok: false, message: 'Write a reply first.' })
    expect(sent).toEqual([])

    expect((await actions.create({ title: ' Fix it ', instructions: ' Now ', project: '/work/app', assignee: 'builder', status: 'To-Do' })).ok).toBe(true)
    expect((await actions.update('local:a', { status: 'Done' })).ok).toBe(true)
    expect((await actions.update('local:a', { assignee: 'me' })).ok).toBe(true)
    expect((await actions.reply('local:a', ' Yes, go ahead. ')).ok).toBe(true)
    expect(sent).toEqual([
      ['create', { title: 'Fix it', instructions: 'Now', project: '/work/app', assignee: 'builder', status: 'To-Do' }],
      ['update', 'local:a', { status: 'Done' }],
      ['update', 'local:a', { assignee: 'me' }],
      ['reply', 'local:a', 'Yes, go ahead.'],
    ])
  })

  it('hands back a refusal from the main process as its sentence', async () => {
    const actions = tasksActions({ tasksLocalUpdate: async () => ({ ok: false, message: 'That task no longer exists.', state: null }) })
    expect(await actions.update('local:gone', { status: 'Done' })).toMatchObject({ ok: false, message: 'That task no longer exists.' })
    expect(await tasksActions({}).update('x', {})).toMatchObject({ ok: false, message: 'This build cannot change tasks.' })
  })
})
