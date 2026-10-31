/**
 * The window's view of CRM tasks: the agents, the connections, and a read-only
 * mirror of the work in hand.
 *
 * The mirror is not a second task list. The CRM owns tasks; this shows what
 * Terminal Deck is doing about each one — the CRM status it last set or heard,
 * and its own process state — so the person can see it without opening the CRM.
 * Only the app's own window may change anything, the same guard as Settings →
 * Connect an AI app, because a connection decides who can run agents here.
 */

import type { InvokeRegistrar } from '../deck-control/ai-apps-ipc'
import type { AccessKeyView } from '../deck-control/access-keys'
import { isLocalDetailFn } from '../../shared/crm/detail-contract'
import { LOCAL_STATUSES, TaskConfigProblem, type AgentProfile, type CrmConnectionView, type TaskConfig } from './task-config'
import type { LocalTaskDetail } from './task-detail-local'
import type { LocalTasks } from './task-local'
import type { AgentInventory } from './agent-inventory'
import type { GoalStore } from './goal-store'
import { blockersOf, goalProgress, type GoalProgress } from './goal-progress'
import type { TaskOutbox } from './task-outbox'
import type { ProcessState, TaskNote, TaskRecord, TaskStall, TaskStore } from './task-store'

export const TASKS_CHANGED_CHANNEL = 'tasks:changed'
/** Main → window: open this task (a reminder was clicked). */
export const TASKS_OPEN_CHANNEL = 'tasks:open'

/** One task as the board shows it. */
export interface TaskView {
  id: string
  keyId: string
  externalTaskId: string
  title: string
  /** The agent's name, or Hoot. */
  agent: string
  project: string
  crmStatus: string
  process: ProcessState
  /** When a finished session closes; null when none is open. */
  keepOpenUntil: number | null
  /** True once verified, false when finished unverified, null while not finished. */
  verified: boolean | null
  updatedAt: number
  /** Made here, with no CRM: editable on the Tasks page. */
  local: boolean
  /** Who has it: `none`, `me`, `hoot`, or an agent's id. */
  assignee: string
  instructions: string
  /** The agent that handed it to you, by name, while you have it. */
  handedFrom: string | null
  /** A local task's own record, newest last. */
  notes: TaskNote[]
  /* The CRM's task fields, for a local task. */
  priority: string | null
  startDate: string | null
  dueDate: string | null
  startTime: string | null
  dueTime: string | null
  labels: string[]
  board: string | null
  taskType: 'task' | 'milestone'
  estimateMinutes: number | null
  archivedAt: number | null
  /** Set while in the Trash. */
  deletedAt: number | null
  completedAt: number | null
  position: number | null
  /** How often it comes back — the reference CRM's frequency word; null: a one-off. */
  recurrence: string | null
  /** The goal it serves; null for none. */
  goalId: string | null
  /** Asked to run in a workspace of its own. */
  useWorkspace: boolean
  /** Its worker went quiet or ended without finishing; null while it has not. */
  stalled: TaskStall | null
  /** The titles of the open tasks it waits for before an agent can start it. */
  waitingOn: string[]
  createdAt: number
}

/** One goal as the Tasks page lists it: the goal and where its tasks stand. */
export interface GoalView {
  id: string
  title: string
  description: string
  status: string
  parentId: string | null
  project: string | null
  progress: Pick<GoalProgress, 'total' | 'done' | 'verified' | 'unverified' | 'stalled' | 'blocked'>
}

export interface TasksState {
  agents: AgentProfile[]
  connections: CrmConnectionView[]
  /** Access keys a connection can be made for. `lastApp`: the AI app last seen using it. */
  keys: Array<Pick<AccessKeyView, 'id' | 'name' | 'crmOnly' | 'lastApp'>>
  tasks: TaskView[]
  /** Your deleted tasks, newest first — kept whole until restored. */
  trash: TaskView[]
  outbox: { pending: number; undelivered: number }
  /** The statuses a local task can have. */
  localStatuses: string[]
  /** Your goals, oldest first, each with how far its tasks have got. */
  goals: GoalView[]
}

export type TasksResult =
  | { ok: true; state: TasksState; secret?: string | null }
  | { ok: false; message: string; state: TasksState }

export interface TasksIpcDeps {
  config: TaskConfig
  store: TaskStore
  outbox: TaskOutbox
  keys(): AccessKeyView[]
  isApprover(sender: Electron.WebContents): boolean
  /** Close a task's kept-open session now. Its conversation stays resumable. */
  closeSession(taskId: string): boolean
  /** Tasks made here. Absent: the local channels refuse. */
  local?: LocalTasks
  /** The task popup's calls on a local task (the reference CRM's task page). Absent: they refuse. */
  detail?: Pick<LocalTaskDetail, 'call'>
  /** What is installed for an agent's account, for its pickers. Absent: the pickers show what is saved. */
  inventory?(agent: { provider: string | null; account: string | null }): AgentInventory & { account: string }
  /** Make a key that only sends tasks, for one CRM. Called only from the owner's confirmed press. */
  makeCrmKey?(name: string): { id: string; key: string }
  /** Your goals. Absent: none are listed. */
  goals?: GoalStore
}

export function tasksState(deps: Pick<TasksIpcDeps, 'config' | 'store' | 'outbox' | 'keys' | 'goals'>): TasksState {
  const agents = deps.config.agents()
  const nameOf = (agentId: string): string =>
    agentId === 'hoot'
      ? 'Hoot'
      : agentId === 'me'
        ? 'Me'
        : agentId === 'none'
          ? 'Unassigned'
          : (agents.find((agent) => agent.id === agentId)?.name ?? agentId)
  const outbox = deps.outbox.list()
  const all = deps.store.all()
  const view = (task: TaskRecord): TaskView => ({
    id: task.id,
    keyId: task.keyId,
    externalTaskId: task.externalTaskId,
    title: task.title,
    agent: nameOf(task.assignee.agentId),
    project: task.project,
    crmStatus: task.crmStatus,
    process: task.process,
    keepOpenUntil: task.keepOpenUntil,
    verified: task.result === null ? null : task.result.verified,
    updatedAt: task.updatedAt,
    local: task.local === true,
    assignee: task.assignee.agentId,
    instructions: task.instructions,
    handedFrom: task.assignee.kind === 'human' && task.handedFrom ? nameOf(task.handedFrom) : null,
    notes: (task.notes ?? []).slice(-30),
    priority: task.priority ?? null,
    startDate: task.startDate ?? null,
    dueDate: task.dueDate ?? null,
    startTime: task.startTime ?? null,
    dueTime: task.dueTime ?? null,
    labels: task.labels ?? [],
    board: task.board ?? null,
    taskType: task.taskType ?? 'task',
    estimateMinutes: task.estimateMinutes ?? null,
    archivedAt: task.archivedAt ?? null,
    deletedAt: task.deletedAt ?? null,
    completedAt: task.completedAt ?? null,
    position: task.position ?? null,
    recurrence: task.recurrence ?? null,
    goalId: task.goalId ?? null,
    useWorkspace: task.useWorkspace === true,
    stalled: task.stalled ?? null,
    waitingOn: task.process === 'queued' ? blockersOf(task, all).map((other) => other.title) : [],
    createdAt: task.createdAt,
  })
  const goals = deps.goals?.all() ?? []
  return {
    agents,
    connections: deps.config.connections(),
    keys: deps.keys().map((key) => ({ id: key.id, name: key.name, crmOnly: key.crmOnly, lastApp: key.lastApp })),
    tasks: [...all]
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .map(view),
    trash: deps.store
      .inTrash()
      .filter((task) => task.local === true)
      .sort((a, b) => (b.deletedAt ?? 0) - (a.deletedAt ?? 0))
      .map(view),
    outbox: {
      pending: outbox.filter((item) => item.state === 'pending').length,
      undelivered: outbox.filter((item) => item.state === 'undelivered').length,
    },
    localStatuses: [...LOCAL_STATUSES.statuses],
    goals: goals.map((goal) => {
      const { total, done, verified, unverified, stalled, blocked } = goalProgress(goal, goals, all)
      return { ...goal, progress: { total, done, verified, unverified, stalled, blocked } }
    }),
  }
}

export function registerTasksIpc(ipcMain: InvokeRegistrar, deps: TasksIpcDeps): void {
  const state = (): TasksState => tasksState(deps)

  const guard = (event: { sender: Electron.WebContents }): void => {
    if (!deps.isApprover(event.sender)) throw new Error('tasks: only the app’s own window may change task settings')
  }

  const change = (run: () => string | null | void): TasksResult => {
    try {
      const secret = run()
      return { ok: true, state: state(), ...(typeof secret === 'string' ? { secret } : {}) }
    } catch (error) {
      const message =
        error instanceof TaskConfigProblem
          ? error.message
          : `That did not save: ${error instanceof Error ? error.message : String(error)}`
      return { ok: false, message, state: state() }
    }
  }

  ipcMain.handle('tasks:state', (event) => {
    guard(event)
    return state()
  })
  ipcMain.handle('tasks:agent-save', (event, raw: unknown) => {
    guard(event)
    return change(() => {
      deps.config.saveAgent(raw)
    })
  })
  /** Pause, resume, archive or restore one agent: `action` is one of those four words. */
  ipcMain.handle('tasks:agent-status', (event, id: unknown, action: unknown) => {
    guard(event)
    return change(() => {
      if (typeof id !== 'string') throw new TaskConfigProblem('That agent no longer exists.')
      deps.config.setAgentStatus(id, action)
    })
  })
  ipcMain.handle('tasks:agent-remove', (event, id: unknown) => {
    guard(event)
    return change(() => {
      if (typeof id !== 'string' || !deps.config.removeAgent(id)) throw new TaskConfigProblem('That agent no longer exists.')
    })
  })
  ipcMain.handle('tasks:connection-save', (event, keyId: unknown, raw: unknown) => {
    guard(event)
    return change(() => {
      if (typeof keyId !== 'string' || !deps.keys().some((key) => key.id === keyId)) {
        throw new TaskConfigProblem('That access key no longer exists.')
      }
      return deps.config.saveConnection(keyId, raw).secret
    })
  })
  /**
   * A new CRM with a key of its own. Only from the app's window, on the owner's
   * confirmed press: the key is made here, shown once in the answer, and can
   * send tasks and nothing else.
   */
  ipcMain.handle('tasks:connection-create', (event, raw: unknown) => {
    guard(event)
    let key: string | null = null
    const result = change(() => {
      const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
      if (input.confirmed !== true) throw new TaskConfigProblem('Confirm making a new key for this CRM first.')
      const name = typeof input.name === 'string' ? input.name.replace(/\s+/g, ' ').trim() : ''
      if (name === '') throw new TaskConfigProblem('Give the CRM a name first.')
      if (name.length > 50) throw new TaskConfigProblem('Keep the CRM name under 50 characters.')
      if (deps.makeCrmKey === undefined) throw new TaskConfigProblem('This build cannot make a key for a CRM.')
      const made = deps.makeCrmKey(name)
      key = made.key
      return deps.config.saveConnection(made.id, { name }).secret
    })
    return result.ok ? { ...result, key } : result
  })
  ipcMain.handle('tasks:inventory', (event, raw: unknown) => {
    guard(event)
    const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
    const text = (value: unknown): string | null => (typeof value === 'string' && value.trim() !== '' ? value.trim() : null)
    if (deps.inventory === undefined) return null
    return deps.inventory({ provider: text(input.provider), account: text(input.account) })
  })
  ipcMain.handle('tasks:connection-remove', (event, keyId: unknown) => {
    guard(event)
    return change(() => {
      if (typeof keyId !== 'string' || !deps.config.removeConnection(keyId)) {
        throw new TaskConfigProblem('That connection no longer exists.')
      }
    })
  })
  /** The same as `change`, for the local operations, which start and stop agents and so take a moment. */
  const changeAsync = async (run: () => Promise<unknown>): Promise<TasksResult> => {
    try {
      await run()
      return { ok: true, state: state() }
    } catch (error) {
      const message =
        error instanceof TaskConfigProblem
          ? error.message
          : `That did not save: ${error instanceof Error ? error.message : String(error)}`
      return { ok: false, message, state: state() }
    }
  }
  const local = (): LocalTasks => {
    if (deps.local === undefined) throw new TaskConfigProblem('Tasks are not running on this computer right now.')
    return deps.local
  }
  ipcMain.handle('tasks:local-create', (event, input: unknown) => {
    guard(event)
    return changeAsync(() => local().create(input))
  })
  ipcMain.handle('tasks:local-update', (event, id: unknown, patch: unknown) => {
    guard(event)
    return changeAsync(() => local().update(id, patch))
  })
  ipcMain.handle('tasks:local-delete', (event, id: unknown) => {
    guard(event)
    return changeAsync(() => local().remove(id))
  })
  /** Back from the Trash. */
  ipcMain.handle('tasks:local-restore', (event, id: unknown) => {
    guard(event)
    return changeAsync(() => local().restore(id))
  })
  ipcMain.handle('tasks:local-reply', (event, id: unknown, text: unknown) => {
    guard(event)
    return changeAsync(() => local().reply(id, text))
  })
  /**
   * The task popup: one CRM function by name with its arguments, answered with
   * that function's own result — never thrown across, so the popup can put
   * the sentence on screen. Only the app's own window may call it. The
   * channel is spelt out (it is `LOCAL_DETAIL_CHANNEL`) so the preload's
   * contract test can see it is handled.
   */
  ipcMain.handle('tasks:local-detail', async (event, fn: unknown, args: unknown) => {
    guard(event)
    if (!isLocalDetailFn(fn)) return { ok: false, error: 'That is not something the task popup can do.' }
    if (!Array.isArray(args)) return { ok: false, error: 'That request was not understood.' }
    if (deps.detail === undefined) return { ok: false, error: 'Tasks are not running on this computer right now.' }
    return deps.detail.call(fn, args)
  })
  ipcMain.handle('tasks:close-session', (event, taskId: unknown) => {
    guard(event)
    return change(() => {
      if (typeof taskId !== 'string' || !deps.closeSession(taskId)) {
        throw new TaskConfigProblem('That task has no open session.')
      }
    })
  })
}
