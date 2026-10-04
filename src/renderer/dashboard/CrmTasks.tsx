import { useEffect, useMemo, useState, type ReactElement } from 'react'
import { useEvery } from '../schedule'
import {
  keptOpenMinutes,
  processLabel,
  resolveTasksBridge,
  showMirror,
  toTasksResult,
  toTasksState,
  type TasksBridge,
  type TasksState,
} from '../tasks/tasks-model'
import './CrmTasks.css'

/**
 * The Overview's CRM tasks: a read-only mirror of what this app is doing about
 * each task a CRM sent.
 *
 * Not a second task list. The CRM is the task master — it creates, assigns and
 * closes tasks — so nothing here changes a task. Each row says what this app
 * knows: the CRM status exactly as the CRM spells it, and this app's own
 * process state (queued, running, finished), which is never called a status.
 * The one control is closing a finished session that is being kept open, which
 * is this app's own resource, not the task.
 *
 * Drawn only once there is something to show: at least one task, or at least
 * one CRM connection. Someone who never connects a CRM never sees it.
 */

/** A minute is the finest a "kept open for N min" line moves. */
const TICK_MS = 30_000

export interface CrmTasksProps {
  /** Defaults to the preload bridge. */
  bridge?: Partial<TasksBridge>
  /** A fixed state, for tests and the harness; no subscription is made. */
  state?: TasksState | null
  /** Clock, so the kept-open line can be asserted at a fixed instant. */
  now?: number
}

/**
 * Read the tasks once, and again every time the main process says they changed
 * — a CRM status recorded, a task started or finished, a session closed.
 * Returns the unsubscribe. Outside the component so the refresh can be tested
 * without a DOM.
 */
export function watchTasks(bridge: Partial<TasksBridge>, set: (state: TasksState | null) => void): () => void {
  let live = true
  const load = async (): Promise<void> => {
    if (!bridge.tasksState) return
    try {
      const next = toTasksState(await bridge.tasksState())
      if (live) set(next)
    } catch {
      // A window the main process does not answer (not the app's own) shows nothing.
      if (live) set(null)
    }
  }
  void load()
  const off = bridge.onTasksChanged?.(() => void load())
  return () => {
    live = false
    off?.()
  }
}

export function CrmTasks(props: CrmTasksProps): ReactElement | null {
  const bridge = useMemo(() => props.bridge ?? resolveTasksBridge(), [props.bridge])
  const [loaded, setLoaded] = useState<TasksState | null>(null)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const supplied = props.state !== undefined
  const state = supplied ? (props.state ?? null) : loaded

  useEffect(() => (supplied ? undefined : watchTasks(bridge, setLoaded)), [bridge, supplied])

  const ticking = state?.tasks.some((task) => task.keepOpenUntil !== null) ?? false
  const [clock, setClock] = useState(() => Date.now())
  useEvery(props.now === undefined && ticking ? TICK_MS : null, () => setClock(Date.now()))
  const now = props.now ?? clock

  const closeSession = async (taskId: string): Promise<void> => {
    if (!bridge.tasksCloseSession) return
    setBusy(true)
    try {
      const result = toTasksResult(await bridge.tasksCloseSession(taskId))
      if (result.state) setLoaded(result.state)
      setProblem(result.ok ? null : result.message)
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(false)
    }
  }

  if (state === null || !showMirror(state)) return null
  return (
    <CrmTasksBody
      state={state}
      now={now}
      busy={busy}
      problem={problem}
      onCloseSession={bridge.tasksCloseSession ? (taskId) => void closeSession(taskId) : undefined}
    />
  )
}

/** Whether a finished task was checked: by its check command, or by Hoot. */
export function checkLabel(verified: boolean | null): string {
  if (verified === null) return 'not finished'
  return verified ? 'finished and checked' : 'finished, not checked yet'
}

/** "just now", "5 min ago", "3 h ago", "2 d ago". */
export function agoLabel(at: number, now: number): string {
  const minutes = Math.floor(Math.max(now - at, 0) / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} min ago`
  if (minutes < 48 * 60) return `${Math.floor(minutes / 60)} h ago`
  return `${Math.floor(minutes / (24 * 60))} d ago`
}

/** The list without its subscription, so every row can be rendered from a fixed state. */
export function CrmTasksBody({
  state,
  now,
  busy = false,
  problem = null,
  onCloseSession,
  heading = 'CRM tasks',
  detailed = false,
}: {
  state: TasksState
  now: number
  busy?: boolean
  problem?: string | null
  onCloseSession?: (taskId: string) => void
  /** Null on a page that already has the title. */
  heading?: string | null
  /** Each task's CRM id, project, check state and last change too — the Tasks page. */
  detailed?: boolean
}): ReactElement {
  const running = state.tasks.filter((task) => task.process === 'running').length
  const queued = state.tasks.filter((task) => task.process === 'queued').length
  const summary = [running > 0 ? `${running} running` : null, queued > 0 ? `${queued} queued` : null].filter(Boolean).join(' · ')

  return (
    <section className="crm-tasks" aria-label="CRM tasks">
      {(heading !== null || summary !== '') && (
        <header className="crm-tasks-head">
          {heading !== null && <h2 className="crm-tasks-heading">{heading}</h2>}
          {summary !== '' && <p className="crm-tasks-summary">{summary}</p>}
        </header>
      )}
      {problem && <p className="crm-tasks-problem" role="status">{problem}</p>}
      {state.tasks.length === 0 ? (
        <p className="crm-tasks-empty">No tasks from your CRM yet. They appear here as it sends them.</p>
      ) : (
        <ul className="crm-tasks-list">
          {state.tasks.map((task) => {
            const minutes = keptOpenMinutes(task.keepOpenUntil, now)
            return (
              <li key={task.id} className="crm-task" data-process={task.process}>
                <div className="crm-task-main">
                  <span className="crm-task-title">{task.title}</span>
                  <span className="crm-task-meta">
                    <span>{task.agent}</span>
                    {task.crmStatus !== '' && (
                      <span className="crm-task-status" title="Status in the CRM">
                        {task.crmStatus}
                      </span>
                    )}
                    <span className="crm-task-process">{processLabel(task.process)}</span>
                    {minutes !== null && <span>kept open for {minutes} min</span>}
                  </span>
                  {detailed && (
                    <span className="crm-task-meta crm-task-details">
                      <span title="The task’s id in the CRM">{task.externalTaskId}</span>
                      <span title="Project folder">{task.project}</span>
                      <span>{checkLabel(task.verified)}</span>
                      <span>changed {agoLabel(task.updatedAt, now)}</span>
                    </span>
                  )}
                </div>
                {minutes !== null && onCloseSession && (
                  <button
                    type="button"
                    className="dashboard-btn crm-task-close"
                    disabled={busy}
                    title="Close the finished session now. Its conversation can still be resumed."
                    onClick={() => onCloseSession(task.id)}
                  >
                    Close session
                  </button>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
