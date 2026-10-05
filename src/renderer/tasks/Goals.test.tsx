import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { saveWorkspaceChoice, WorkspaceToggle } from '../crm-task/workspace-toggle'
import { goalActions, goalOptions, GoalsSection, progressLine } from './Goals'
import { DEFAULT_VIEW, MyWork, type MyWorkActions } from './MyWork'
import { TasksPageBody, type TasksActions } from './TasksPage'
import { goalPayload, goalTree, parentChoices, resolveTasksBridge, toTasksState, type GoalRow, type TaskRow, type TasksResult } from './tasks-model'

/** Goals on the Tasks page, a task's goal and stall on its row, and the workspace choice — rendered from fixed data. */

const NOW = new Date(2026, 9, 7, 10, 0).getTime()
const OK: TasksResult = { ok: true, message: null, state: null, secret: null }
const ok = async (): Promise<TasksResult> => OK

function goal(id: string, over: Partial<GoalRow> = {}): Record<string, unknown> {
  return { id, title: id, description: '', status: 'active', parentId: null, project: null, progress: { total: 0, done: 0, verified: 0, unverified: 0, stalled: 0, blocked: 0 }, ...over }
}

function row(over: Partial<TaskRow>): Record<string, unknown> {
  return {
    id: `local:${String(over.title)}`, keyId: 'local', externalTaskId: 'x', agent: 'Me', project: '', crmStatus: 'To-Do', process: 'idle',
    keepOpenUntil: null, verified: null, updatedAt: NOW, local: true, assignee: 'me', instructions: '', handedFrom: null, notes: [],
    priority: null, startDate: null, dueDate: null, startTime: null, dueTime: null, labels: [], board: null, taskType: 'task',
    estimateMinutes: null, archivedAt: null, completedAt: null, position: null, recurrence: null, createdAt: NOW,
    ...over,
  }
}

const state = toTasksState({
  agents: [{ id: 'builder', name: 'Builder' }],
  connections: [],
  keys: [],
  outbox: { pending: 0, undelivered: 0 },
  localStatuses: ['To-Do', 'Working on it', 'In Progress', 'Done', 'Stuck'],
  goals: [
    goal('g-root', { title: 'Fortnightly releases', progress: { total: 5, done: 2, verified: 1, unverified: 1, stalled: 1, blocked: 1 } }),
    goal('g-ship', { title: 'Ship 0.18', parentId: 'g-root', description: 'Mac only.' }),
    goal('g-other', { title: 'Docs', status: 'achieved' }),
  ],
  tasks: [
    row({ title: 'Build', goalId: 'g-ship', crmStatus: 'Stuck', assignee: 'builder', stalled: { at: 1, reason: 'quiet', text: 'No sign of work for 15 minutes.' } }),
    row({ title: 'Test', goalId: 'g-ship', process: 'queued', waitingOn: ['Build', 'Package'] }),
  ],
})!

describe('the goals model', () => {
  it('reads goals and the new task fields from what main answers', () => {
    expect(state.goals?.map((one) => one.id)).toEqual(['g-root', 'g-ship', 'g-other'])
    expect(state.tasks[0]).toMatchObject({ goalId: 'g-ship', useWorkspace: false, stalled: { reason: 'quiet' }, waitingOn: [] })
    expect(state.tasks[1].waitingOn).toEqual(['Build', 'Package'])
  })

  it('draws the tree in order, offers parents that make no loop, and checks a draft before it is sent', () => {
    const goals = state.goals ?? []
    expect(goalTree(goals).map(({ goal: one, depth }) => `${depth}:${one.title}`)).toEqual(['0:Fortnightly releases', '1:Ship 0.18', '0:Docs'])
    expect(parentChoices(goals, 'g-root').map((one) => one.id)).toEqual(['g-other'])
    expect(goalOptions(goals).map((one) => one.label)).toEqual(['Fortnightly releases', '  ↳ Ship 0.18', 'Docs'])
    expect(goalPayload({ title: ' ', description: '', status: 'active', parentId: '' }, null)).toEqual({ ok: false, message: 'Give the goal a title.' })
    expect(goalPayload({ title: ' Ship ', description: ' x ', status: 'planned', parentId: 'g-root' }, 'g-ship')).toEqual({
      ok: true,
      payload: { id: 'g-ship', title: 'Ship', description: 'x', status: 'planned', parentId: 'g-root' },
    })
    expect(progressLine({ total: 5, done: 2, verified: 1, unverified: 1, stalled: 1, blocked: 1 })).toBe('2 of 5 done · 1 verified · 1 to check · 1 stalled · 1 waiting')
    expect(progressLine({ total: 0, done: 0, verified: 0, unverified: 0, stalled: 0, blocked: 0 })).toBe('No tasks yet')
  })

  it('sends goals through the bridge the preload exposes', async () => {
    const sent: unknown[] = []
    const bridge = resolveTasksBridge({
      tasksGoalSave: async (input: unknown) => (sent.push(['save', input]), { ok: true, state: null }),
      tasksGoalRemove: async (id: string) => (sent.push(['remove', id]), { ok: false, message: 'That goal no longer exists.' }),
    })
    const acts = goalActions(bridge)
    expect((await acts?.save({ title: 'Ship' }))?.ok).toBe(true)
    expect((await acts?.remove('g-x'))?.message).toBe('That goal no longer exists.')
    expect(sent).toEqual([['save', { title: 'Ship' }], ['remove', 'g-x']])
    expect(goalActions({})).toBeUndefined()
  })
})

describe('the goals list', () => {
  const run = async (): Promise<boolean> => true
  const actions = { save: ok, remove: ok }

  it('lists each goal with its progress, sub-goals stepped in, and the controls that change it', () => {
    const html = renderToStaticMarkup(<GoalsSection goals={state.goals ?? []} busy={false} actions={actions} run={run} creating={false} onCreating={() => undefined} />)
    expect(html).toContain('aria-label="Goals"')
    expect(html).toContain('2 of 5 done · 1 verified · 1 to check · 1 stalled · 1 waiting')
    expect(html).toContain('aria-valuenow="40"')
    expect(html).toContain('--depth:1')
    expect(html).toContain('Mac only.')
    expect(html).toContain('aria-label="Status of the goal Ship 0.18"')
    expect(html).toContain('Add a goal under it')
    expect(html).toContain('Remove')
  })

  it('is not drawn with no goals, and opens its form when asked', () => {
    expect(renderToStaticMarkup(<GoalsSection goals={[]} busy={false} actions={actions} run={run} creating={false} onCreating={() => undefined} />)).toBe('')
    const form = renderToStaticMarkup(<GoalsSection goals={[]} busy={false} actions={actions} run={run} creating onCreating={() => undefined} />)
    expect(form).toContain('aria-label="New goal"')
    expect(form).toContain('No bigger goal')
  })

  it('sits on the Tasks page with a New goal button, and the new-task form offers the goals', () => {
    const fake: TasksActions = { create: ok, update: ok, reply: ok, remove: ok, restore: ok, closeSession: ok }
    const html = renderToStaticMarkup(<TasksPageBody available state={state} now={NOW} actions={fake} goalActions={actions} />)
    expect(html).toContain('New goal')
    expect(html.indexOf('aria-label="Goals"')).toBeLessThan(html.indexOf('aria-label="Your tasks"'))
  })
})

describe('a task’s row', () => {
  const actions: MyWorkActions = { create: ok, update: ok, remove: ok, restore: ok }
  const html = renderToStaticMarkup(
    <MyWork state={state} now={NOW} busy={false} actions={actions} run={async () => true} renderPopup={() => <div />} initialView={DEFAULT_VIEW} />,
  )

  it('has a Goal cell set to the goal it serves', () => {
    expect(html).toContain('aria-label="Goal of Build"')
    expect(html).toMatch(/<option value="g-ship" selected="">  ↳ Ship 0.18<\/option>/)
  })

  it('says when its worker stalled, and what a queued task waits for', () => {
    expect(html).toContain('title="No sign of work for 15 minutes."')
    expect(html).toContain('>stalled<')
    expect(html).toContain('waits for Build +1')
  })
})

describe('the workspace choice', () => {
  const task = toTasksState({ agents: [], connections: [], tasks: [row({ title: 'Build', useWorkspace: true })] })!.tasks[0]

  it('shows beside the project folder, checked from the task, and not at all without a way to save it', () => {
    expect(renderToStaticMarkup(<WorkspaceToggle task={task} save={ok} />)).toContain('<input type="checkbox" aria-label="Own workspace" checked=""/>Own workspace')
    expect(renderToStaticMarkup(<WorkspaceToggle task={task} save={null} />)).toBe('')
  })

  it('saves through tasks:local-update with useWorkspace, and a refusal comes back as its sentence', async () => {
    const sent: unknown[] = []
    expect(await saveWorkspaceChoice(async (id, patch) => (sent.push([id, patch]), { ok: true, state: null }), 'local:a', false)).toEqual({ ok: true, message: null })
    expect(sent).toEqual([['local:a', { useWorkspace: false }]])
    expect(await saveWorkspaceChoice(async () => ({ ok: false, message: 'That task no longer exists.' }), 'local:a', true)).toEqual({
      ok: false,
      message: 'That task no longer exists.',
    })
    expect(
      await saveWorkspaceChoice(async () => {
        throw new Error('the window closed')
      }, 'local:a', true),
    ).toEqual({ ok: false, message: 'the window closed' })
  })
})
