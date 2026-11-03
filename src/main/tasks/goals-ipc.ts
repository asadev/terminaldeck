/**
 * The window's goal channels: make or change a goal, and remove one. A task is
 * linked to a goal through `tasks:local-update` with `goalId`, the same change
 * every other field of a task goes through.
 *
 * Only the app's own window may call them — the guard every task channel has —
 * and each answers with the whole task state, so the page redraws from one
 * answer.
 */

import type { InvokeRegistrar } from '../deck-control/ai-apps-ipc'
import type { GoalStore } from './goal-store'
import { TaskConfigProblem } from './task-config'
import type { TasksResult, TasksState } from './tasks-ipc'
import type { TaskStore } from './task-store'

export interface GoalsIpcDeps {
  goals: GoalStore
  store: TaskStore
  isApprover(sender: Electron.WebContents): boolean
  state(): TasksState
}

/**
 * Take a goal out: its sub-goals move up (the store does that) and so do its
 * tasks, to the removed goal's parent — or to no goal, at the top.
 */
export function removeGoal(goals: GoalStore, store: TaskStore, id: unknown): void {
  const { removed, parentId } = goals.remove(id)
  for (const task of [...store.all(), ...store.inTrash()]) if (task.goalId === removed.id) store.update(task, { goalId: parentId })
}

export function registerGoalsIpc(ipcMain: InvokeRegistrar, deps: GoalsIpcDeps): void {
  const guard = (event: { sender: Electron.WebContents }): void => {
    if (!deps.isApprover(event.sender)) throw new Error('tasks: only the app’s own window may change goals')
  }
  const change = (run: () => void): TasksResult => {
    try {
      run()
      return { ok: true, state: deps.state() }
    } catch (error) {
      const message = error instanceof TaskConfigProblem ? error.message : `That did not save: ${error instanceof Error ? error.message : String(error)}`
      return { ok: false, message, state: deps.state() }
    }
  }

  /** A goal with no `id` is made; one with an `id` is changed — fields left out stay. */
  ipcMain.handle('tasks:goal-save', (event, raw: unknown) => {
    guard(event)
    return change(() => {
      const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
      const { id, ...fields } = input
      if (id === undefined || id === null || id === '') deps.goals.create(fields)
      else deps.goals.update(id, fields)
    })
  })
  ipcMain.handle('tasks:goal-remove', (event, id: unknown) => {
    guard(event)
    return change(() => removeGoal(deps.goals, deps.store, id))
  })
}
