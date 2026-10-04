/**
 * Tasks: the page in the sidebar for your own tasks and the work a CRM gives
 * Hoot and the task agents, beside Simulators.
 *
 * ## Your own tasks
 *
 * Made here, with no CRM: a title, details, the project folder an agent works
 * in, one of five statuses, and who has it — nobody, you, Hoot, or one of your
 * agents. Given to an agent it starts at once; when the agent has a question,
 * gets stuck, or finishes without a check to run, the task comes back to you
 * with what it said, and a reply sends you both back to work in the same
 * conversation. Everything is kept on this Mac and survives a restart.
 *
 * ## From your CRM
 *
 * The CRM is the task master for those, so they are listed and never edited
 * here: what each is, who has it, its status in the CRM spelt as the CRM spells
 * it, and what Terminal Deck is doing about it. Agents and CRM connections are
 * set up in Settings → Tasks, one press away.
 */

import { useEffect, useMemo, useState, type ReactElement } from 'react'
import { PageEmpty } from '../components/PageEmpty'
import { CrmTasksBody, watchTasks } from '../dashboard/CrmTasks'
import '../dashboard/CrmTasks.css'
import { useEvery } from '../schedule'
import {
  assigneeChoices,
  localDraftOf,
  localPayload,
  resolveTasksBridge,
  toTasksResult,
  type LocalDraft,
  type TaskRow,
  type TasksBridge,
  type TasksResult,
  type TasksState,
} from './tasks-model'
import { MyWork } from './MyWork'
import { LocalTaskPopup } from '../crm-task/LocalTaskPopup'
import './TasksPage.css'

/** The sidebar row's icon too: a list with ticks. */
export const TASKS_ICON = 'M9.5 6.5h10M9.5 12h10M9.5 17.5h10M4.5 6.5l1 1 2-2M4.5 12l1 1 2-2M4.5 17.5l1 1 2-2'

const TICK_MS = 30_000

/** What the page can ask of the main process; each answers with the new state or a sentence. */
export interface TasksActions {
  create(input: LocalDraft | Record<string, unknown>): Promise<TasksResult>
  update(id: string, patch: Record<string, unknown>): Promise<TasksResult>
  remove(id: string): Promise<TasksResult>
  /** Back from the Trash. */
  restore(id: string): Promise<TasksResult>
  reply(id: string, text: string): Promise<TasksResult>
  closeSession(id: string): Promise<TasksResult>
}

export interface TasksPageProps {
  bridge?: Partial<TasksBridge>
  /** Open Settings at the Tasks section, where agents and connections live. */
  onOpenSettings?(): void
  /** A fixed state, for tests; no subscription is made. */
  state?: TasksState | null
  now?: number
  /** A task to open, as `<id>@<when asked>` — a reminder for it was clicked. */
  openTask?: string | null
}

const NOT_HERE: TasksResult = { ok: false, message: 'This build cannot change tasks.', state: null, secret: null }

export function tasksActions(bridge: Partial<TasksBridge>): TasksActions {
  const call = async (run: (() => Promise<unknown>) | undefined): Promise<TasksResult> => {
    if (run === undefined) return NOT_HERE
    try {
      return toTasksResult(await run())
    } catch (error) {
      return { ok: false, message: error instanceof Error ? error.message : String(error), state: null, secret: null }
    }
  }
  return {
    create: (input) => {
      const draft = { ...localDraftOf(null, []), ...(input as Record<string, unknown>) } as LocalDraft & Record<string, unknown>
      const checked = localPayload(draft)
      if (!checked.ok) return Promise.resolve({ ok: false, message: checked.message, state: null, secret: null })
      const create = bridge.tasksLocalCreate
      return call(create && (() => create({ ...draft, ...checked.payload })))
    },
    remove: (id) => {
      const remove = bridge.tasksLocalDelete
      return call(remove && (() => remove(id)))
    },
    restore: (id) => {
      const restore = bridge.tasksLocalRestore
      return call(restore && (() => restore(id)))
    },
    update: (id, patch) => {
      const update = bridge.tasksLocalUpdate
      return call(update && (() => update(id, patch)))
    },
    reply: (id, text) => {
      const send = bridge.tasksLocalReply
      if (text.trim() === '') return Promise.resolve({ ok: false, message: 'Write a reply first.', state: null, secret: null })
      return call(send && (() => send(id, text.trim())))
    },
    closeSession: (id) => {
      const close = bridge.tasksCloseSession
      return call(close && (() => close(id)))
    },
  }
}

export function TasksPage(props: TasksPageProps): ReactElement {
  const bridge = useMemo(() => props.bridge ?? resolveTasksBridge(), [props.bridge])
  const actions = useMemo(() => tasksActions(bridge), [bridge])
  const supplied = props.state !== undefined
  // Undefined until the first read answers.
  const [loaded, setLoaded] = useState<TasksState | null | undefined>(undefined)
  useEffect(() => (supplied ? undefined : watchTasks(bridge, setLoaded)), [bridge, supplied])
  const state = supplied ? (props.state ?? null) : loaded

  const ticking = state?.tasks.some((task) => task.keepOpenUntil !== null) ?? false
  const [clock, setClock] = useState(() => Date.now())
  useEvery(props.now === undefined && ticking ? TICK_MS : null, () => setClock(Date.now()))

  return (
    <TasksPageBody
      available={bridge.tasksState !== undefined}
      state={state}
      now={props.now ?? clock}
      actions={actions}
      onState={setLoaded}
      onOpenSettings={props.onOpenSettings}
      openTask={props.openTask ?? null}
    />
  )
}

/** One line on each connection: which key, on or off, and whether it can take work yet. */
export function connectionLine(state: TasksState): string | null {
  if (state.connections.length === 0) return null
  return state.connections
    .map((connection) => {
      const key = state.keys.find((one) => one.id === connection.keyId)?.name ?? 'a removed key'
      if (!connection.enabled) return `CRM on “${key}” is off`
      if (connection.allowedSenders.length === 0 || connection.folders.length === 0) {
        return `CRM on “${key}” is on, but needs an allowed sender and a project folder`
      }
      return `CRM on “${key}” is on`
    })
    .join(' · ')
}

/** What has not reached the CRM yet, or null when everything has. */
export function outboxLine(state: TasksState): string | null {
  const parts = [
    state.outbox.pending > 0 ? `${state.outbox.pending} update${state.outbox.pending === 1 ? '' : 's'} on the way to the CRM` : null,
    state.outbox.undelivered > 0 ? `${state.outbox.undelivered} could not be delivered` : null,
  ].filter((part): part is string => part !== null)
  return parts.length === 0 ? null : parts.join(' · ')
}

export function TasksPageBody({
  available,
  state,
  now,
  actions,
  onState,
  onOpenSettings,
  openTask = null,
}: {
  available: boolean
  state: TasksState | null | undefined
  now: number
  actions?: TasksActions
  onState?(state: TasksState): void
  onOpenSettings?(): void
  /** A task to open, as `<id>@<when asked>` — a reminder for it was clicked. */
  openTask?: string | null
}): ReactElement {
  const [creating, setCreating] = useState(false)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  if (!available) return <PageEmpty icon={TASKS_ICON} title="Tasks are not available in this build" />
  if (state === undefined) return <div className="tasks-page tasks-page-loading" aria-busy="true" />
  if (state === null) {
    return (
      <PageEmpty icon={TASKS_ICON} title="Tasks could not be read">
        Terminal Deck did not answer. Reopen this page in a moment.
      </PageEmpty>
    )
  }

  /** Run one change; the new state redraws the page, a refusal is shown as written. */
  const run = async (work: () => Promise<TasksResult>): Promise<boolean> => {
    setBusy(true)
    try {
      const result = await work()
      if (result.state) onState?.(result.state)
      setProblem(result.ok ? null : (result.message ?? 'That did not save.'))
      return result.ok
    } finally {
      setBusy(false)
    }
  }

  const mine = state.tasks.filter((task) => task.local)
  const crm = { ...state, tasks: state.tasks.filter((task) => !task.local) }
  const agents = state.agents.length
  const facts = [
    connectionLine(state),
    `${agents} task agent${agents === 1 ? '' : 's'}${agents === 0 ? ' — add one in Settings to give tasks to an agent' : ''}`,
    outboxLine(state),
  ].filter((line): line is string => line !== null)

  return (
    <div className="tasks-page">
      <header className="tasks-page-head">
        <div className="tasks-page-facts">
          {facts.map((fact) => (
            <p key={fact} className="tasks-page-fact">
              {fact}
            </p>
          ))}
        </div>
        <div className="tasks-page-actions">
          {actions && !creating && (
            <button type="button" className="dashboard-btn tasks-page-new" onClick={() => setCreating(true)}>
              New task
            </button>
          )}
          {onOpenSettings && (
            <button type="button" className="dashboard-btn" onClick={onOpenSettings}>
              Agents and connections
            </button>
          )}
        </div>
      </header>
      {problem && (
        <p className="tasks-page-problem" role="status">
          {problem}
        </p>
      )}
      {creating && actions && (
        <LocalTaskForm
          task={null}
          state={state}
          busy={busy}
          onSave={async (draft) => {
            if (await run(() => actions.create(draft))) setCreating(false)
          }}
          onCancel={() => {
            setCreating(false)
            setProblem(null)
          }}
        />
      )}

      <section className="tasks-page-section" aria-label="Your tasks">
        <h2 className="tasks-page-heading">Your tasks</h2>
        {actions ? (
          <MyWork
            state={state}
            now={now}
            openRequest={openTask}
            busy={busy}
            actions={actions}
            run={run}
            renderPopup={(task, siblings, open, close) => (
              <LocalTaskPopup
                task={task}
                tasks={mine}
                siblings={siblings}
                agents={state.agents}
                onNavigate={open}
                onClose={close}
                onDelete={(id) => {
                  close()
                  void run(() => actions.remove(id))
                }}
              />
            )}
          />
        ) : mine.length === 0 ? (
          <p className="tasks-page-empty">No tasks yet.</p>
        ) : null}
      </section>

      {(crm.tasks.length > 0 || state.connections.length > 0) && (
        <section className="tasks-page-section" aria-label="From your CRM">
          <h2 className="tasks-page-heading">From your CRM</h2>
          {crm.tasks.length === 0 ? (
            <p className="tasks-page-empty">No tasks from your CRM yet. They appear here when it gives work to Hoot or an agent.</p>
          ) : (
            <CrmTasksBody
              state={crm}
              now={now}
              busy={busy}
              onCloseSession={actions ? (id) => void run(() => actions.closeSession(id)) : undefined}
              heading={null}
              detailed
            />
          )}
        </section>
      )}
    </div>
  )
}

/** Who has a task, as the row says it. */
export function assigneeLabel(task: TaskRow, state: TasksState): string {
  return assigneeChoices(state.agents).find((choice) => choice.id === task.assignee)?.label ?? task.agent
}

/** New or edited: title, details, folder — and for a new one, who has it and its status. */
export function LocalTaskForm({
  task,
  state,
  busy,
  onSave,
  onCancel,
}: {
  task: TaskRow | null
  state: TasksState
  busy: boolean
  onSave(draft: LocalDraft): void
  onCancel(): void
}) {
  const [draft, setDraft] = useState<LocalDraft>(() => localDraftOf(task, state.localStatuses))
  const set = (field: keyof LocalDraft) => (event: { target: { value: string } }) => setDraft((was) => ({ ...was, [field]: event.target.value }))
  const fresh = task === null
  return (
    <form
      className="tasks-local-form"
      aria-label={fresh ? 'New task' : `Edit ${task.title}`}
      onSubmit={(event) => {
        event.preventDefault()
        onSave(draft)
      }}
    >
      <label className="tasks-local-field">
        <span>Title</span>
        <input className="tasks-page-input" value={draft.title} maxLength={300} disabled={busy} onChange={set('title')} />
      </label>
      <label className="tasks-local-field">
        <span>Details</span>
        <textarea className="tasks-page-input tasks-page-area" value={draft.instructions} disabled={busy} onChange={set('instructions')} />
      </label>
      <label className="tasks-local-field">
        <span>Project folder</span>
        <input
          className="tasks-page-input"
          placeholder="Needed when an agent works on it, e.g. /Users/you/Projects/app"
          value={draft.project}
          spellCheck={false}
          disabled={busy}
          onChange={set('project')}
        />
      </label>
      {fresh && (
        <div className="tasks-local-pair">
          <label className="tasks-local-field">
            <span>Assigned to</span>
            <select value={draft.assignee} disabled={busy} onChange={set('assignee')}>
              {assigneeChoices(state.agents).map((choice) => (
                <option key={choice.id} value={choice.id}>
                  {choice.label}
                </option>
              ))}
            </select>
          </label>
          <label className="tasks-local-field">
            <span>Status</span>
            <select value={draft.status} disabled={busy} onChange={set('status')}>
              {state.localStatuses.map((status) => (
                <option key={status} value={status}>
                  {status}
                </option>
              ))}
            </select>
          </label>
        </div>
      )}
      <div className="tasks-local-buttons">
        <button type="submit" className="dashboard-btn tasks-page-new" disabled={busy || draft.title.trim() === ''}>
          {fresh ? 'Add task' : 'Save'}
        </button>
        <button type="button" className="dashboard-btn" disabled={busy} onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  )
}
