/**
 * One of your own tasks, opened in the reference CRM's task popup.
 *
 * The popup (`task-detail-panel.tsx` and everything under this folder) is the
 * CRM's, copied: same layout, sections and controls, drawn in Terminal Deck's
 * colours by `crm-task.css`. This file is the local wiring around it and
 * nothing else:
 *
 * - your task as the CRM's `Task` shape (`crmTaskOf`) — details are the CRM's
 *   description, the board is the CRM's board, the person at this Mac is `me`;
 * - the people: you, Hoot and your task agents (`localPeople`);
 * - every read and write through `local-actions.ts` to the main process;
 * - ▲ ▼ walk the list the popup was opened from, in its order;
 * - the "Project folder" row an agent needs (the CRM has none);
 * - a file's address opens the file in the Mac's own app, and a task link opens
 *   that task here, instead of navigating the window away.
 */

import { useMemo, useState, type MouseEvent, type ReactElement } from 'react'
import { TaskDetailPanel } from './task-detail-panel'
import { localDetailActions, localFieldActions, localProjectActions, windowDetailBridge, type DetailBridge } from './local-actions'
import type { DetailActions } from './detail-actions'
import type { TaskFieldActions } from './task-fields-section'
import { parseTaskAttachmentHref } from '../../shared/crm/attachment-rules'
import { ME_ID, localPeople } from '../../shared/crm/detail-contract'
import type { Task, TaskAssignee, TaskPriority, TaskRecurrence, TaskStatus } from '../../shared/crm/tasks-data'
import type { TaskRow } from '../tasks/tasks-model'
import './crm-task.css'

const NOBODY: Pick<Task, 'assigneeName' | 'assigneeInitials' | 'assigneeColor' | 'assigneeAvatarUrl'> = {
  assigneeName: 'Unassigned',
  assigneeInitials: '—',
  assigneeColor: 'bg-slate-300',
  assigneeAvatarUrl: null,
}

/** Your task as the CRM's `Task`. */
export function crmTaskOf(row: TaskRow, team: readonly TaskAssignee[]): Task {
  const person = row.assignee === 'none' ? null : (team.find((one) => one.id === row.assignee) ?? null)
  return {
    id: row.id,
    title: row.title,
    group: row.crmStatus as TaskStatus,
    board: row.board ?? '',
    priority: (row.priority as TaskPriority | null) ?? null,
    startDate: row.startDate ?? '',
    dueDate: row.dueDate ?? '',
    recurrence: (row.recurrence as TaskRecurrence | null) ?? null,
    description: row.instructions,
    assigneeUserId: row.assignee === 'none' ? null : row.assignee,
    ...(person
      ? { assigneeName: person.name, assigneeInitials: person.initials, assigneeColor: person.color, assigneeAvatarUrl: person.avatarUrl }
      : NOBODY),
    createdBy: ME_ID,
    createdAt: new Date(row.createdAt).toISOString(),
    sortOrder: row.position,
    links: [],
    labels: row.labels,
    taskType: row.taskType,
    archivedAt: row.archivedAt === null ? null : new Date(row.archivedAt).toISOString(),
    startTime: row.startTime,
    dueTime: row.dueTime,
  }
}

/** A task link inside the popup (`task:<id>`, or the CRM's `/tasks?task=<id>`), as the id it names. */
export function linkedTaskId(href: string): string | null {
  if (href.startsWith('task:')) return decodeURIComponent(href.slice('task:'.length))
  const match = /[?&]task=([^&#]+)/.exec(href)
  return href.startsWith('/tasks') && match ? decodeURIComponent(match[1]) : null
}

export interface LocalTaskPopupProps {
  /** The task open now. */
  task: TaskRow
  /** Every local task, for ⋯ Merge / Convert and the boards in use. */
  tasks: readonly TaskRow[]
  /** The ids of the list it was opened from, in that list's order — ▲ ▼ walk it. */
  siblings: string[]
  agents: ReadonlyArray<{ id: string; name: string }>
  onNavigate(taskId: string): void
  onClose(): void
  /** ⋯ Delete task. */
  onDelete(taskId: string): void
  /** A test hands in its own; otherwise everything goes to the main process. */
  bridge?: DetailBridge | null
  actions?: DetailActions
  fieldActions?: TaskFieldActions
}

export function LocalTaskPopup(props: LocalTaskPopupProps): ReactElement {
  const bridge = props.bridge === undefined ? windowDetailBridge() : props.bridge
  const actions = useMemo(() => props.actions ?? localDetailActions(bridge), [props.actions, bridge])
  const fieldActions = useMemo(() => props.fieldActions ?? localFieldActions(bridge), [props.fieldActions, bridge])
  const team = useMemo(() => localPeople(props.agents), [props.agents])
  // What the popup changed, shown at once; the main process's next state replaces it.
  const [patches, setPatches] = useState<{ id: string; at: number; patch: Partial<Task> } | null>(null)
  const base = crmTaskOf(props.task, team)
  const task = patches && patches.id === props.task.id && patches.at === props.task.updatedAt ? { ...base, ...patches.patch } : base
  const boards = useMemo(
    () => [...new Set(props.tasks.map((one) => one.board).filter((board): board is string => board !== null && board !== ''))].sort((a, b) => a.localeCompare(b)),
    [props.tasks],
  )
  const taskOptions = useMemo(
    () => props.tasks.filter((one) => one.id !== props.task.id && one.archivedAt === null).map((one) => ({ id: one.id, title: one.title })),
    [props.tasks, props.task.id],
  )

  /** A file opens in the Mac's own app; a task link opens that task here; nothing navigates the window away. */
  const onClickCapture = (event: MouseEvent<HTMLDivElement>): void => {
    const anchor = (event.target as Element | null)?.closest?.('a[href]')
    if (!anchor) return
    const href = anchor.getAttribute('href') ?? ''
    // A file: its task-file: address, or the file search's `/files/<task>/<attachment>`.
    const searched = /^\/files\/([^/]+)\/([^/?#]+)/.exec(href)
    const file = parseTaskAttachmentHref(href) ?? (searched ? { taskId: decodeURIComponent(searched[1]), attachmentId: decodeURIComponent(searched[2]) } : null)
    if (file) {
      event.preventDefault()
      void actions.openTaskFile?.(file.taskId, file.attachmentId)
      return
    }
    const linked = linkedTaskId(href)
    if (linked) {
      event.preventDefault()
      if (props.tasks.some((one) => one.id === linked)) props.onNavigate(linked)
      return
    }
    if (!/^(https?:|mailto:|tel:)/i.test(href)) event.preventDefault()
  }

  return (
    <div className="crm-task-host" onClickCapture={onClickCapture}>
      <TaskDetailPanel
        task={task}
        team={team}
        currentUserId={ME_ID}
        onClose={props.onClose}
        onPatched={(id, patch) => {
          if (id === props.task.id) {
            setPatches((was) => ({ id, at: props.task.updatedAt, patch: { ...(was && was.id === id ? was.patch : {}), ...patch } }))
          }
        }}
        onDelete={(id) => props.onDelete(id)}
        onDuplicated={(newId) => props.onNavigate(newId)}
        siblings={props.siblings}
        onNavigate={props.onNavigate}
        taskOptions={taskOptions}
        onGone={(_id, openId) => (openId ? props.onNavigate(openId) : props.onClose())}
        actions={actions}
        fieldActions={fieldActions}
        boards={boards}
        projectField={<ProjectCell key={props.task.id} task={props.task} bridge={bridge} />}
      />
    </div>
  )
}

/** The folder an agent works in: click to type it, or choose it in the Mac's folder chooser. */
export function ProjectCell({ task, bridge }: { task: TaskRow; bridge: DetailBridge | null }): ReactElement {
  const project = useMemo(() => localProjectActions(bridge), [bridge])
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(task.project)
  const [problem, setProblem] = useState<string | null>(null)
  const save = async (): Promise<void> => {
    setEditing(false)
    if (draft.trim() === task.project) return
    const result = await project.setTaskProject(task.id, draft.trim())
    setProblem(result.ok ? null : result.error)
    if (!result.ok) setDraft(task.project)
  }
  const choose = async (): Promise<void> => {
    const result = await project.chooseTaskProject(task.id)
    if (result.ok) {
      setDraft(result.project)
      setProblem(null)
    } else if (result.error) setProblem(result.error)
  }
  return (
    <span className="flex min-w-0 flex-1 items-center gap-2" data-testid="project-cell">
      {editing ? (
        <input
          autoFocus
          value={draft}
          spellCheck={false}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={() => void save()}
          onKeyDown={(event) => {
            if (event.key === 'Enter') void save()
            if (event.key === 'Escape') {
              event.stopPropagation()
              setDraft(task.project)
              setEditing(false)
            }
          }}
          placeholder="/Users/you/Projects/app"
          aria-label="Project folder"
          className="h-7 min-w-0 flex-1 rounded-md border border-slate-200 bg-white px-2 text-sm text-slate-900 focus:border-violet-500 focus:outline-none"
        />
      ) : (
        <button
          type="button"
          onClick={() => setEditing(true)}
          title={task.project || 'Needed before Hoot or an agent can work on it'}
          className={`min-w-0 flex-1 truncate text-left text-sm ${task.project ? 'text-slate-800' : 'text-slate-400'}`}
        >
          {task.project || 'Empty'}
        </button>
      )}
      <button type="button" onClick={() => void choose()} className="btn btn-secondary btn-sm shrink-0">
        Choose…
      </button>
      {problem && (
        <span role="alert" className="truncate text-xs text-rose-700" title={problem}>
          {problem}
        </span>
      )}
    </span>
  )
}
