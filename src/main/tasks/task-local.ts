/**
 * Tasks made here, with no CRM: create one, change it, set its status, give it
 * to nobody, to yourself, to Hoot or to one of your agents — and answer an
 * agent that handed it back to you.
 *
 * ## The same records, the same engine
 *
 * A local task is a {@link TaskRecord} under the connection {@link LOCAL_KEY},
 * kept in the same file as CRM tasks, so it survives a restart the same way.
 * Given to an agent it runs exactly as a CRM task does — its account, model,
 * instructions, limits and keep-open time — and what a CRM would be told
 * (progress, a question, a blocker, the result) becomes a line of the task's
 * own record instead (`TaskEngine` keeps it locally).
 *
 * ## You are the task master here
 *
 * Nothing a CRM would check is needed: the person at this Mac is the only one
 * who makes or changes these, through the app's own window. The statuses are
 * the same five a CRM task has ({@link LOCAL_STATUSES}). When an agent cannot
 * go on — a question, a blocker, a failed check, or a finish with no check to
 * run — the task comes back to you, and your reply goes back to that agent in
 * its own conversation.
 */

import { randomUUID } from 'node:crypto'
import { isAbsolute } from 'node:path'
import { LOCAL_STATUSES, TaskConfigProblem, type TaskConfig } from './task-config'
import type { TaskEngine } from './task-engine'
import { LOCAL_KEY, ME, PRIORITIES, TaskStore, TO_ME, UNASSIGNED, type TaskAssignee, type TaskNote, type TaskPriority, type TaskRecord } from './task-store'

export const MAX_LOCAL_TITLE = 300
export const MAX_LOCAL_INSTRUCTIONS = 20_000
export const MAX_REPLY = 20_000
/** The CRM's limits on tags (`tasks-validate.ts`). */
export const MAX_LABELS = 20
export const MAX_LABEL = 40
export const MAX_ESTIMATE_MINUTES = 100_000

/** The CRM fields a local task carries, as `create` and `update` take them. */
interface CrmFields {
  priority?: TaskPriority | null
  startDate?: string | null
  dueDate?: string | null
  startTime?: string | null
  dueTime?: string | null
  labels?: string[]
  board?: string | null
  taskType?: 'task' | 'milestone'
  estimateMinutes?: number | null
  position?: number | null
}

/** How long a board's name may be. */
export const MAX_BOARD = 40

function isYmd(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false
  const [y, m, d] = value.split('-').map(Number)
  const date = new Date(Date.UTC(y, m - 1, d))
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d
}

/** Whichever of the CRM's fields `input` names, checked; anything not named is left out. */
export function crmFieldsOf(input: Record<string, unknown>): CrmFields {
  const out: CrmFields = {}
  if ('priority' in input) {
    const value = input.priority
    if (value === null || value === '' || value === undefined) out.priority = null
    else if (typeof value === 'string' && (PRIORITIES as readonly string[]).includes(value)) out.priority = value as TaskPriority
    else throw new TaskConfigProblem(`The priority has to be one of: ${PRIORITIES.join(', ')}, or none.`)
  }
  for (const key of ['startDate', 'dueDate'] as const) {
    if (!(key in input)) continue
    const value = input[key]
    if (value === null || value === '' || value === undefined) out[key] = null
    else if (typeof value === 'string' && isYmd(value)) out[key] = value
    else throw new TaskConfigProblem(`${key === 'dueDate' ? 'The due date' : 'The start date'} has to be a date.`)
  }
  for (const key of ['startTime', 'dueTime'] as const) {
    if (!(key in input)) continue
    const value = input[key]
    if (value === null || value === '' || value === undefined) out[key] = null
    else if (typeof value === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(value)) out[key] = value
    else throw new TaskConfigProblem(`${key === 'dueTime' ? 'The due time' : 'The start time'} has to be a time like 09:30.`)
  }
  if ('labels' in input) {
    const raw = input.labels
    if (!Array.isArray(raw)) throw new TaskConfigProblem('Tags have to be a list.')
    const labels: string[] = []
    for (const entry of raw) {
      if (typeof entry !== 'string') continue
      const label = entry.trim()
      if (label === '' || labels.includes(label)) continue
      if (label.length > MAX_LABEL) throw new TaskConfigProblem(`A tag can be at most ${MAX_LABEL} characters.`)
      labels.push(label)
    }
    if (labels.length > MAX_LABELS) throw new TaskConfigProblem(`A task can have at most ${MAX_LABELS} tags.`)
    out.labels = labels
  }
  if ('board' in input) {
    const value = input.board
    if (value === null || value === undefined || (typeof value === 'string' && value.trim() === '')) out.board = null
    else if (typeof value === 'string' && value.trim().length <= MAX_BOARD) out.board = value.trim()
    else throw new TaskConfigProblem(`A board's name can be at most ${MAX_BOARD} characters.`)
  }
  if ('taskType' in input) {
    if (input.taskType !== 'task' && input.taskType !== 'milestone') throw new TaskConfigProblem('The type is a task or a milestone.')
    out.taskType = input.taskType
  }
  if ('estimateMinutes' in input) {
    const value = input.estimateMinutes
    if (value === null || value === '' || value === undefined) out.estimateMinutes = null
    else if (typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= MAX_ESTIMATE_MINUTES) out.estimateMinutes = value
    else throw new TaskConfigProblem(`The estimate is a whole number of minutes, at most ${MAX_ESTIMATE_MINUTES}.`)
  }
  if ('position' in input) {
    const value = input.position
    if (value === null || value === undefined) out.position = null
    else if (typeof value === 'number' && Number.isFinite(value)) out.position = value
    else throw new TaskConfigProblem('The position has to be a number.')
  }
  return out
}

/** A new local task, ready to keep. Used here and for the children Hoot hands on. */
export function newLocalTask(
  fields: {
    title: string
    instructions: string
    project: string
    assignee: TaskAssignee
    status: string
    parent?: TaskRecord
  },
  now: number,
): TaskRecord {
  const externalTaskId = randomUUID()
  const parent = fields.parent
  return {
    id: TaskStore.idOf(LOCAL_KEY, externalTaskId),
    keyId: LOCAL_KEY,
    externalTaskId,
    originExternalTaskId: parent?.originExternalTaskId ?? externalTaskId,
    externalThreadId: null,
    parentExternalTaskId: parent?.externalTaskId ?? null,
    title: fields.title,
    instructions: fields.instructions,
    project: fields.project,
    assignee: { ...fields.assignee },
    mainAssignee: fields.assignee.identity,
    creator: ME,
    requestedBy: ME,
    crmStatus: fields.status,
    process: 'idle',
    sessionId: null,
    conversationId: null,
    runStartedAt: null,
    keepOpenUntil: null,
    hops: parent === undefined ? 0 : parent.hops + 1,
    result: null,
    questionOpen: false,
    lastTurn: null,
    childrenTold: null,
    stopped: false,
    seq: 0,
    createdAt: now,
    updatedAt: now,
    local: true,
    notes: [],
    handedFrom: null,
  }
}

/** One field an update changed, before and after — what the task's Activity column tells. */
export interface LocalChange {
  field: 'title' | 'instructions' | 'project' | 'status' | 'archived' | 'assignee' | Exclude<keyof CrmFields, 'position'>
  from: unknown
  to: unknown
}

export interface LocalTasksDeps {
  store: TaskStore
  config: TaskConfig
  engine: Pick<TaskEngine, 'accept' | 'reassign' | 'reply' | 'cancel'>
  now?: () => number
  onChange?(): void
  /**
   * After an update: every field it changed, and the notes it wrote for them,
   * so the task popup can tell each change in the CRM's own words (from → to)
   * and not tell it twice.
   */
  onUpdated?(task: TaskRecord, changes: LocalChange[], notes: TaskNote[]): void
}

/** The fields an update can change, as they were before it. */
const TRACKED: ReadonlyArray<LocalChange['field']> = [
  'title',
  'instructions',
  'project',
  'status',
  'archived',
  'assignee',
  'priority',
  'startDate',
  'dueDate',
  'startTime',
  'dueTime',
  'labels',
  'board',
  'taskType',
  'estimateMinutes',
]

function trackedValue(task: TaskRecord, field: LocalChange['field']): unknown {
  if (field === 'status') return task.crmStatus
  if (field === 'archived') return task.archivedAt != null
  if (field === 'assignee') return task.assignee.identity
  if (field === 'labels') return [...(task.labels ?? [])]
  if (field === 'taskType') return task.taskType ?? 'task'
  return task[field] ?? null
}

/** How each field is named in a "Changed the …" line. */
const FIELD_WORDS: Record<keyof CrmFields, string> = {
  priority: 'priority',
  startDate: 'start date',
  dueDate: 'due date',
  startTime: 'start time',
  dueTime: 'due time',
  labels: 'tags',
  board: 'board',
  taskType: 'type',
  estimateMinutes: 'estimate',
  position: 'order',
}

function field(input: Record<string, unknown>, name: string): unknown {
  return input[name]
}

function text(value: unknown, what: string, max: number, required: boolean): string | undefined {
  if (value === undefined) {
    if (required) throw new TaskConfigProblem(`${what} cannot be empty.`)
    return undefined
  }
  if (typeof value !== 'string') throw new TaskConfigProblem(`${what} has to be text.`)
  const trimmed = value.trim()
  if (required && trimmed === '') throw new TaskConfigProblem(`${what} cannot be empty.`)
  if (trimmed.length > max) throw new TaskConfigProblem(`${what} is longer than ${max} characters.`)
  return trimmed
}

export class LocalTasks {
  private readonly now: () => number

  constructor(private readonly deps: LocalTasksDeps) {
    this.now = deps.now ?? Date.now
  }

  /** Who `raw` names: `none`, `me`, `hoot`, or an agent's id. */
  assigneeOf(raw: unknown): TaskAssignee {
    if (raw === undefined || raw === null || raw === '' || raw === 'none') return { ...UNASSIGNED }
    if (raw === ME) return { ...TO_ME }
    if (raw === 'hoot') return { kind: 'hoot', agentId: 'hoot', identity: 'hoot' }
    if (typeof raw === 'string') {
      const agent = this.deps.config.agent(raw)
      if (agent !== null) return { kind: 'agent', agentId: agent.id, identity: agent.id }
    }
    throw new TaskConfigProblem('Assign it to nobody, to yourself, to Hoot or to one of your task agents.')
  }

  async create(raw: unknown): Promise<TaskRecord> {
    const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
    const title = text(field(input, 'title'), 'The title', MAX_LOCAL_TITLE, true) as string
    const instructions = text(field(input, 'instructions'), 'The details', MAX_LOCAL_INSTRUCTIONS, false) ?? ''
    const project = text(field(input, 'project'), 'The project folder', 1024, false) ?? ''
    const assignee = this.assigneeOf(field(input, 'assignee'))
    const status = this.statusOf(field(input, 'status')) ?? LOCAL_STATUSES.initial
    this.checkProject(project, assignee)
    const fields = crmFieldsOf(input)
    const task = newLocalTask({ title, instructions, project, assignee, status }, this.now())
    Object.assign(task, { labels: [], taskType: 'task', ...fields, completedAt: status === LOCAL_STATUSES.completed ? this.now() : null })
    this.deps.store.put(task)
    this.deps.store.note(task, { by: ME, kind: 'edited', text: `Created, assigned to ${this.nameOf(assignee)}.` })
    await this.deps.engine.accept(task)
    this.changed()
    return task
  }

  /** Change what you named; anything left out stays. A new assignee stops whatever runs and starts the new one. */
  async update(id: unknown, raw: unknown): Promise<TaskRecord> {
    const task = this.task(id)
    const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
    const title = text(field(input, 'title'), 'The title', MAX_LOCAL_TITLE, 'title' in input)
    const instructions = text(field(input, 'instructions'), 'The details', MAX_LOCAL_INSTRUCTIONS, false)
    const project = text(field(input, 'project'), 'The project folder', 1024, false)
    const status = this.statusOf(field(input, 'status'))
    const assignee = 'assignee' in input ? this.assigneeOf(field(input, 'assignee')) : null
    this.checkProject(project ?? task.project, assignee ?? task.assignee)
    const fields = crmFieldsOf(input)
    const archive = 'archived' in input ? input.archived === true : null
    const before = new Map(TRACKED.map((key) => [key, trackedValue(task, key)] as const))
    let written = 0
    const note = (line: Omit<TaskNote, 'at'>): void => {
      written += 1
      this.deps.store.note(task, line)
    }

    const edited: string[] = []
    if (title !== undefined && title !== task.title) edited.push('title')
    if (instructions !== undefined && instructions !== task.instructions) edited.push('details')
    if (project !== undefined && project !== task.project) edited.push('project')
    this.deps.store.update(task, {
      ...(title === undefined ? {} : { title }),
      ...(instructions === undefined ? {} : { instructions }),
      ...(project === undefined ? {} : { project }),
    })
    // The CRM's fields: one line for what changed, as its activity log writes "from → to".
    const changed = (Object.keys(fields) as Array<keyof CrmFields>).filter(
      (key) => key !== 'position' && JSON.stringify(fields[key] ?? null) !== JSON.stringify(task[key] ?? null),
    )
    if (Object.keys(fields).length > 0) this.deps.store.update(task, fields)
    for (const key of changed) edited.push(FIELD_WORDS[key])
    if (edited.length > 0) note({ by: ME, kind: 'edited', text: `Changed the ${edited.join(', ')}.` })
    if (status !== undefined && status !== task.crmStatus) {
      // Done alone is completed, and stamps when; every other status clears it (the CRM's rule).
      this.deps.store.update(task, { crmStatus: status, completedAt: status === LOCAL_STATUSES.completed ? this.now() : null })
      note({ by: ME, kind: 'status', text: `Status: ${status}` })
    }
    if (archive !== null && archive !== (task.archivedAt != null)) {
      this.deps.store.update(task, { archivedAt: archive ? this.now() : null })
      note({ by: ME, kind: 'edited', text: archive ? 'Archived.' : 'Restored from the archive.' })
    }
    if (assignee !== null && assignee.identity !== task.assignee.identity) {
      note({ by: ME, kind: 'assigned', text: `Assigned to ${this.nameOf(assignee)}.` })
      await this.deps.engine.reassign(task, assignee)
      this.deps.store.update(task, { handedFrom: null })
    }
    const changes = TRACKED.flatMap((field): LocalChange[] => {
      const from = before.get(field)
      const to = trackedValue(task, field)
      return JSON.stringify(from) === JSON.stringify(to) ? [] : [{ field, from, to }]
    })
    if (changes.length > 0) {
      try {
        this.deps.onUpdated?.(task, changes, written > 0 ? (task.notes ?? []).slice(-written) : [])
      } catch (error) {
        console.error('[tasks] an update listener threw:', error)
      }
    }
    this.changed()
    return task
  }

  /**
   * Delete a task: into the Trash, whole — its notes, files and history kept
   * until it is restored; nothing purges it. Whatever runs on it stops first.
   */
  async remove(id: unknown): Promise<void> {
    const task = this.task(id)
    if (task.sessionId !== null) await this.deps.engine.cancel(task, 'the task was deleted.')
    this.deps.store.note(task, { by: ME, kind: 'edited', text: 'Moved to Trash.' })
    this.deps.store.trash(task.id)
    this.changed()
  }

  /** Back from the Trash, as it was. No agent starts: give it to one again to run it. */
  async restore(id: unknown): Promise<TaskRecord> {
    const task = typeof id === 'string' ? this.deps.store.trashedById(id) : null
    if (task === null || task.local !== true) throw new TaskConfigProblem('That task is not in the Trash.')
    this.deps.store.restore(task.id)
    this.deps.store.note(task, { by: ME, kind: 'edited', text: 'Restored from Trash.' })
    this.changed()
    return task
  }

  /** Answer the agent that handed this task to you; it carries on in its own conversation. */
  async reply(id: unknown, raw: unknown): Promise<TaskRecord> {
    const task = this.task(id)
    const reply = text(raw, 'The reply', MAX_REPLY, true) as string
    const agentId = task.assignee.kind === 'agent' ? task.assignee.agentId : task.handedFrom
    // Hoot holding the task hears a reply too: the engine puts it to Hoot in its own session.
    if (task.assignee.kind === 'hoot') {
      await this.deps.engine.reply(task, reply)
      this.changed()
      return task
    }
    if (!agentId || this.deps.config.agent(agentId) === null) {
      throw new TaskConfigProblem('No agent is waiting on this task. Assign it to one instead.')
    }
    await this.deps.engine.reply(task, reply)
    this.changed()
    return task
  }

  private task(id: unknown): TaskRecord {
    const task = typeof id === 'string' ? this.deps.store.byId(id) : null
    if (task === null || task.local !== true) throw new TaskConfigProblem('That task no longer exists.')
    return task
  }

  private statusOf(raw: unknown): string | undefined {
    if (raw === undefined || raw === null || raw === '') return undefined
    if (typeof raw !== 'string' || !LOCAL_STATUSES.statuses.includes(raw)) {
      throw new TaskConfigProblem(`The status has to be one of: ${LOCAL_STATUSES.statuses.join(', ')}.`)
    }
    return raw
  }

  /** An agent or Hoot works in a folder, so it needs one; yours or nobody's does not. */
  private checkProject(project: string, assignee: TaskAssignee): void {
    if (project !== '' && !isAbsolute(project)) throw new TaskConfigProblem(`${project} is not a full folder path.`)
    if ((assignee.kind === 'agent' || assignee.kind === 'hoot') && project === '') {
      throw new TaskConfigProblem('Choose the project folder the agent should work in.')
    }
  }

  private nameOf(assignee: TaskAssignee): string {
    if (assignee.kind === 'none') return 'nobody'
    if (assignee.kind === 'human') return 'you'
    if (assignee.kind === 'hoot') return 'Hoot'
    return this.deps.config.agent(assignee.agentId)?.name ?? assignee.agentId
  }

  private changed(): void {
    try {
      this.deps.onChange?.()
    } catch (error) {
      console.error('[tasks] a change listener threw:', error)
    }
  }
}
