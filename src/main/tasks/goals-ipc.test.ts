import { describe, expect, it } from 'vitest'
import { GoalStore } from './goal-store'
import { registerGoalsIpc } from './goals-ipc'
import { TaskConfig } from './task-config'
import { LocalTasks } from './task-local'
import { TaskOutbox } from './task-outbox'
import { TaskStore } from './task-store'
import { tasksState, type TasksResult } from './tasks-ipc'

/**
 * The Tasks page's goal channels, end to end without a window: through the real
 * handlers into the real stores, and back out as the state the page redraws
 * from — goals with their progress, tasks with their goal, stall and waits.
 */

const WINDOW = {} as Electron.WebContents
const STRANGER = {} as Electron.WebContents

function rig() {
  const handlers = new Map<string, (event: { sender: Electron.WebContents }, ...args: unknown[]) => unknown>()
  const config = new TaskConfig({ dir: null })
  config.saveAgent({ id: 'builder', name: 'Builder' })
  const store = new TaskStore({ dir: null })
  const goals = new GoalStore({ dir: null })
  const outbox = new TaskOutbox({ dir: null, target: () => null })
  const local = new LocalTasks({
    store,
    config,
    goals,
    engine: { accept: async () => undefined, reassign: async () => undefined, reply: async () => undefined, cancel: async () => undefined },
  })
  const state = () => tasksState({ config, store, outbox, keys: () => [], goals })
  registerGoalsIpc({ handle: (channel: string, run: never) => void handlers.set(channel, run) } as never, {
    goals,
    store,
    isApprover: (sender) => sender === WINDOW,
    state,
  })
  const call = (channel: string, ...args: unknown[]): TasksResult => {
    const handler = handlers.get(channel)
    if (!handler) throw new Error(`no handler for ${channel}`)
    return handler({ sender: WINDOW }, ...args) as TasksResult
  }
  return { handlers, store, goals, local, outbox, state, call }
}

describe('the goal channels', () => {
  it('makes a goal, changes it, and answers with every goal and its progress', async () => {
    const { call, local, outbox } = rig()
    const made = call('tasks:goal-save', { title: 'Ship 0.18', description: 'Mac only.' })
    expect(made.ok).toBe(true)
    const goal = made.state?.goals[0]
    expect(goal).toMatchObject({ title: 'Ship 0.18', description: 'Mac only.', status: 'active', parentId: null, progress: { total: 0 } })
    await local.create({ title: 'Write the notes', goalId: goal?.id, status: 'Done' })
    const changed = call('tasks:goal-save', { id: goal?.id, status: 'achieved' })
    expect(changed.state?.goals[0]).toMatchObject({ status: 'achieved', progress: { total: 1, done: 1, unverified: 1 } })
    expect(changed.state?.tasks[0]).toMatchObject({ goalId: goal?.id, useWorkspace: false, stalled: null, waitingOn: [] })
    outbox.stop()
  })

  it('says what is wrong, in the page’s words, and refuses any window but the app’s', () => {
    const { call, handlers, outbox } = rig()
    expect(call('tasks:goal-save', { title: ' ' })).toMatchObject({ ok: false, message: 'The goal’s title cannot be empty.' })
    expect(call('tasks:goal-remove', 'goal-gone')).toMatchObject({ ok: false, message: 'That goal no longer exists.' })
    expect(() => handlers.get('tasks:goal-save')?.({ sender: STRANGER }, { title: 'x' })).toThrow(/only the app’s own window/)
    outbox.stop()
  })

  it('removing a goal moves its sub-goals and its tasks up to its parent', async () => {
    const { call, goals, local, store, outbox } = rig()
    const root = goals.create({ title: 'Releases' })
    const release = goals.create({ title: 'Ship 0.18', parentId: root.id })
    const below = goals.create({ title: 'Notes', parentId: release.id })
    const made = await local.create({ title: 'Write them', goalId: release.id })
    const trashed = await local.create({ title: 'Old draft', goalId: release.id })
    store.trash(trashed.id)
    expect(call('tasks:goal-remove', release.id).ok).toBe(true)
    expect(goals.byId(below.id)?.parentId).toBe(root.id)
    expect(store.byId(made.id)?.goalId).toBe(root.id)
    expect(store.trashedById(trashed.id)?.goalId).toBe(root.id)
    outbox.stop()
  })

  it('a task in the queue says which open tasks it waits for', async () => {
    const { local, store, state, outbox } = rig()
    const first = await local.create({ title: 'Build the API' })
    const second = await local.create({ title: 'Build the page' })
    store.update(second, { process: 'queued', detail: { dependencies: [{ kind: 'blocked_by', otherTaskId: first.id, at: 1 }] } as never })
    expect(state().tasks.find((task) => task.id === second.id)?.waitingOn).toEqual(['Build the API'])
    outbox.stop()
  })
})
