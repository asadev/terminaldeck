/**
 * Your own tasks, laid out the way a CRM's My Work lays its tasks out:
 * summary tiles, piles, search,
 * filters, grouping with the Done group folded, one row per task with the
 * CRM's cells, "+ Add task" under every group, bulk actions, and a week
 * calendar beside the table.
 *
 * The CRM's rules come through `list-view.ts`; the drawing is Terminal Deck's
 * own — its tokens and its plain controls, no Tailwind — and the data is the
 * main process's local tasks, through the same bridge as the rest of the page.
 * Nothing here talks to a CRM.
 *
 * The owner also asked for cards in stages, so a Board view sits beside the
 * table: one column per status, a card per task, dragged between columns to
 * change its status. The CRM itself has no kanban; the table's status groups
 * are its stages, and both views read the same rules.
 */

import { FAVORITES_EVENT, readFavorites } from '../crm-task/page/page-header'
import { useEffect, useMemo, useRef, useState, type ReactElement } from 'react'
import {
  DUE_FILTERS,
  DUE_FILTER_LABEL,
  LIST_GROUPINGS,
  LIST_GROUP_LABEL,
  NO_FILTERS,
  PILES,
  PILE_LABEL,
  REORDERABLE_GROUP_KEY,
  STATUS_ORDER,
  createdLabel,
  filterTasks,
  groupTasks,
  isOverdue,
  nextStatus,
  relativeDue,
  reorderWithinSlots,
  summary,
  weekOf,
  ymdAddDays,
  ymdOf,
  type GroupDefaults,
  type ListFilters,
  type ListGroupBy,
} from './list-view'
import { assigneeChoices, type TaskRow, type TasksResult, type TasksState } from './tasks-model'
import './MyWork.css'

export const PRIORITIES = ['Critical', 'High', 'Medium', 'Low'] as const

/** What the table asks of the main process. */
export interface MyWorkActions {
  create(input: Record<string, unknown>): Promise<TasksResult>
  update(id: string, patch: Record<string, unknown>): Promise<TasksResult>
  remove(id: string): Promise<TasksResult>
  /** Back from the Trash. */
  restore(id: string): Promise<TasksResult>
}

export type Columns = { assignee: boolean; due: boolean; priority: boolean; created: boolean; project: boolean }
const ALL_COLUMNS: Columns = { assignee: true, due: true, priority: true, created: false, project: true }
const COLUMN_LABEL: Record<keyof Columns, string> = {
  assignee: 'Assignee',
  due: 'Due date',
  priority: 'Priority',
  created: 'Date created',
  project: 'Project',
}

export interface ViewState {
  tab: 'table' | 'board' | 'calendar'
  groupBy: ListGroupBy
  showClosed: boolean
  columns: Columns
  filters: ListFilters
}

export const DEFAULT_VIEW: ViewState = { tab: 'table', groupBy: 'status', showClosed: false, columns: ALL_COLUMNS, filters: NO_FILTERS }
const VIEW_KEY = 'td.tasks.viewState.v1'

/** The view as you left it, kept per window in this browser's storage — which may not be there. */
export function readView(): ViewState {
  try {
    const raw = JSON.parse(globalThis.localStorage?.getItem(VIEW_KEY) ?? 'null') as Partial<ViewState> | null
    if (raw === null || typeof raw !== 'object') return DEFAULT_VIEW
    return {
      tab: raw.tab === 'calendar' || raw.tab === 'board' ? raw.tab : 'table',
      groupBy: LIST_GROUPINGS.includes(raw.groupBy as ListGroupBy) ? (raw.groupBy as ListGroupBy) : DEFAULT_VIEW.groupBy,
      showClosed: raw.showClosed === true,
      columns: { ...ALL_COLUMNS, ...(raw.columns ?? {}) },
      filters: { ...NO_FILTERS, ...(raw.filters ?? {}) },
    }
  } catch {
    return DEFAULT_VIEW
  }
}

function writeView(view: ViewState): void {
  try {
    globalThis.localStorage?.setItem(VIEW_KEY, JSON.stringify(view))
  } catch {
    // Storage can be missing or full; the view simply is not remembered.
  }
}

function nowHmOf(at: number): string {
  const d = new Date(at)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

/** The status a ring and a pill are drawn in. */
export function statusTone(status: string): string {
  if (status === 'Done') return 'done'
  if (status === 'Stuck') return 'stuck'
  if (status === 'In Progress') return 'progress'
  if (status === 'Working on it') return 'working'
  return 'todo'
}

export function MyWork({
  state,
  now,
  busy,
  actions,
  run,
  renderPopup,
  initialView,
  initialOpen,
  openRequest = null,
}: {
  state: TasksState
  now: number
  busy: boolean
  actions: MyWorkActions
  run(work: () => Promise<TasksResult>): Promise<boolean>
  /**
   * The task's own popup — the reference CRM's task page — for the task open
   * now; `siblings` is the list it was opened from, in order (▲ ▼ walk it).
   */
  renderPopup(task: TaskRow, siblings: string[], open: (id: string) => void, close: () => void): ReactElement
  initialView?: ViewState
  /** The task open at first, for tests. */
  initialOpen?: string | null
  /** Open this task now — `<id>@<when asked>`, so asking again for the same task opens it again. */
  openRequest?: string | null
}): ReactElement {
  const [view, setView] = useState<ViewState>(() => initialView ?? readView())
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [open, setOpen] = useState<string | null>(initialOpen ?? null)
  const [trashOpen, setTrashOpen] = useState(false)
  useEffect(() => {
    if (openRequest === null) return
    const at = openRequest.lastIndexOf('@')
    setOpen(at > 0 ? openRequest.slice(0, at) : openRequest)
  }, [openRequest])
  const [unfolded, setUnfolded] = useState<Set<string>>(new Set())
  const [folded, setFolded] = useState<Set<string>>(new Set())
  const [week, setWeek] = useState(() => ymdOf(now))
  const today = ymdOf(now)
  const nowHm = nowHmOf(now)
  const local = useMemo(() => state.tasks.filter((task) => task.local), [state.tasks])
  const choices = useMemo(() => assigneeChoices(state.agents), [state.agents])
  const nameOf = (id: string): string => choices.find((choice) => choice.id === id)?.label ?? id

  useEffect(() => writeView(view), [view])
  const change = (patch: Partial<ViewState>): void => setView((was) => ({ ...was, ...patch }))
  const filter = (patch: Partial<ListFilters>): void => setView((was) => ({ ...was, filters: { ...was.filters, ...patch } }))

  const [favorites, setFavorites] = useState<ReadonlySet<string>>(() => new Set(readFavorites()))
  useEffect(() => {
    const follow = (): void => setFavorites(new Set(readFavorites()))
    window.addEventListener(FAVORITES_EVENT, follow)
    return () => window.removeEventListener(FAVORITES_EVENT, follow)
  }, [])
  const shown = filterTasks(local, view.filters, today, nowHm, favorites)
  const groups = groupTasks(shown, view.groupBy, today, { showClosed: view.showClosed, assigneeName: nameOf, nowHm })
  const tiles = summary(local, today, nowHm)
  const boards = [...new Set(local.map((task) => task.board).filter((board): board is string => board !== null))].sort((a, b) => a.localeCompare(b))
  const pick = [...selected].filter((id) => shown.some((task) => task.id === id))
  /** The tasks in the order the open view draws them — the popup's ▲ ▼. */
  const order =
    view.tab === 'board'
      ? STATUS_ORDER.flatMap((status) => shown.filter((task) => task.crmStatus === status))
      : view.tab === 'calendar'
        ? weekOf(week).flatMap((day) => shown.filter((task) => task.dueDate === day))
        : groups.flatMap((group) => group.items)
  const openTask = open === null ? undefined : local.find((task) => task.id === open)

  const update = (id: string, patch: Record<string, unknown>): void => void run(() => actions.update(id, patch))
  const bulk = async (work: (id: string) => Promise<TasksResult>): Promise<void> => {
    for (const id of pick) await run(() => work(id))
    setSelected(new Set())
  }
  const isFolded = (key: string, startsFolded: boolean | undefined): boolean =>
    folded.has(key) || (startsFolded === true && !unfolded.has(key))
  const toggleFold = (key: string, startsFolded: boolean | undefined): void => {
    const nowFolded = isFolded(key, startsFolded)
    setFolded((was) => {
      const next = new Set(was)
      if (nowFolded) next.delete(key)
      else next.add(key)
      return next
    })
    setUnfolded((was) => {
      const next = new Set(was)
      if (nowFolded) next.add(key)
      else next.delete(key)
      return next
    })
  }
  /** A drop in the Today group: the visible order, swapped among the slots it held, written as positions. */
  const reorder = async (fullIds: string[], visible: string[]): Promise<void> => {
    const order = reorderWithinSlots(fullIds, visible)
    for (const [index, id] of order.entries()) {
      const task = local.find((one) => one.id === id)
      if (task !== undefined && task.position !== index) await run(() => actions.update(id, { position: index }))
    }
  }

  return (
    <div className="mw">
      <div className="mw-tiles" role="group" aria-label="Your tasks at a glance">
        <Tile label="Open" value={tiles.open} active={view.filters.statuses.length === 4} onClick={() => filter({ statuses: ['To-Do', 'Working on it', 'In Progress', 'Stuck'], due: 'any' })} />
        <Tile label="Overdue" value={tiles.overdue} tone="overdue" active={view.filters.due === 'overdue'} onClick={() => filter({ due: view.filters.due === 'overdue' ? 'any' : 'overdue', statuses: [] })} />
        <Tile label="Due today" value={tiles.today} active={view.filters.due === 'today'} onClick={() => filter({ due: view.filters.due === 'today' ? 'any' : 'today', statuses: [] })} />
        <Tile label="Done" value={tiles.done} active={view.filters.statuses.length === 1 && view.filters.statuses[0] === 'Done'} onClick={() => change({ showClosed: true, filters: { ...view.filters, statuses: ['Done'], due: 'any' } })} />
      </div>

      <div className="mw-bar">
        <div className="mw-tabs" role="tablist" aria-label="Views">
          {(['table', 'board', 'calendar'] as const).map((tab) => (
            <button key={tab} type="button" role="tab" aria-selected={view.tab === tab} className="mw-tab" data-on={view.tab === tab || undefined} onClick={() => change({ tab })}>
              {tab === 'table' ? 'Table' : tab === 'board' ? 'Board' : 'Calendar'}
            </button>
          ))}
        </div>
        <select aria-label="Whose tasks" className="mw-select" value={view.filters.pile} onChange={(event) => filter({ pile: event.target.value as ListFilters['pile'] })}>
          {PILES.map((pile) => (
            <option key={pile} value={pile}>
              {PILE_LABEL[pile]}
            </option>
          ))}
        </select>
        <input className="mw-search" type="search" placeholder="Search tasks" aria-label="Search tasks" value={view.filters.search} onChange={(event) => filter({ search: event.target.value })} />
        {view.tab === 'table' && (
          <>
            <label className="mw-inline">
              Group by
              <select className="mw-select" value={view.groupBy} onChange={(event) => change({ groupBy: event.target.value as ListGroupBy })}>
                {LIST_GROUPINGS.map((by) => (
                  <option key={by} value={by}>
                    {LIST_GROUP_LABEL[by]}
                  </option>
                ))}
              </select>
            </label>
            <label className="mw-inline">
              <input type="checkbox" checked={view.showClosed} onChange={(event) => change({ showClosed: event.target.checked })} />
              Show closed
            </label>
          </>
        )}
        <label className="mw-inline">
          <input type="checkbox" checked={view.filters.archived} onChange={(event) => filter({ archived: event.target.checked })} />
          Archived
        </label>
        <label className="mw-inline">
          <input type="checkbox" checked={trashOpen} onChange={(event) => setTrashOpen(event.target.checked)} />
          Trash{state.trash.length > 0 ? ` (${state.trash.length})` : ''}
        </label>
      </div>

      <div className="mw-filters" aria-label="Filters">
        <span className="mw-filter-label">Status</span>
        {STATUS_ORDER.map((status) => (
          <Chip key={status} on={view.filters.statuses.includes(status)} onClick={() => filter({ statuses: toggled(view.filters.statuses, status) })}>
            {status}
          </Chip>
        ))}
        <span className="mw-filter-label">Priority</span>
        {[...PRIORITIES, 'none'].map((priority) => (
          <Chip key={priority} on={view.filters.priorities.includes(priority)} onClick={() => filter({ priorities: toggled(view.filters.priorities, priority) })}>
            {priority === 'none' ? 'No priority' : priority}
          </Chip>
        ))}
        {boards.length > 0 && <span className="mw-filter-label">Board</span>}
        {boards.length > 0 &&
          [...boards, 'none'].map((board) => (
            <Chip key={board} on={view.filters.boards.includes(board)} onClick={() => filter({ boards: toggled(view.filters.boards, board) })}>
              {board === 'none' ? 'No board' : board}
            </Chip>
          ))}
        <label className="mw-inline">
          Due
          <select className="mw-select" value={view.filters.due} onChange={(event) => filter({ due: event.target.value as ListFilters['due'] })}>
            {DUE_FILTERS.map((due) => (
              <option key={due} value={due}>
                {DUE_FILTER_LABEL[due]}
              </option>
            ))}
          </select>
        </label>
        {view.tab === 'table' && (
          <details className="mw-columns">
            <summary>Columns</summary>
            {(Object.keys(COLUMN_LABEL) as Array<keyof Columns>).map((column) => (
              <label key={column} className="mw-inline">
                <input type="checkbox" checked={view.columns[column]} onChange={(event) => change({ columns: { ...view.columns, [column]: event.target.checked } })} />
                {COLUMN_LABEL[column]}
              </label>
            ))}
          </details>
        )}
        {(view.filters.statuses.length > 0 || view.filters.priorities.length > 0 || view.filters.boards.length > 0 || view.filters.due !== 'any' || view.filters.search !== '' || view.filters.pile !== 'all') && (
          <button type="button" className="mw-link" onClick={() => change({ filters: { ...NO_FILTERS, archived: view.filters.archived } })}>
            Clear filters
          </button>
        )}
      </div>

      {pick.length > 0 && (
        <div className="mw-bulk" role="toolbar" aria-label="Selected tasks">
          <span>{pick.length} selected</span>
          <button type="button" className="dashboard-btn" disabled={busy} onClick={() => void bulk((id) => actions.update(id, { status: 'Done' }))}>
            Mark done
          </button>
          <button type="button" className="dashboard-btn" disabled={busy} onClick={() => void bulk((id) => actions.update(id, { archived: !view.filters.archived }))}>
            {view.filters.archived ? 'Restore' : 'Archive'}
          </button>
          <button type="button" className="dashboard-btn" disabled={busy} onClick={() => void bulk((id) => actions.remove(id))}>
            Delete
          </button>
          <button type="button" className="mw-link" onClick={() => setSelected(new Set())}>
            Clear
          </button>
        </div>
      )}

      {trashOpen ? (
        <TrashList tasks={state.trash} now={now} busy={busy} onRestore={(id) => run(() => actions.restore(id))} />
      ) : view.tab === 'board' ? (
        <StageBoard
          tasks={shown}
          today={today}
          nowHm={nowHm}
          busy={busy}
          assigneeName={nameOf}
          openId={open}
          onOpen={(id) => setOpen(id)}
          onMove={(task, status) => update(task.id, { status })}
          onAdd={(input) => run(() => actions.create(input))}
          archived={view.filters.archived}
        />
      ) : view.tab === 'calendar' ? (
        <WeekCalendar tasks={shown} week={week} today={today} busy={busy} openId={open} onWeek={setWeek} onOpen={(id) => setOpen(id)} onToggle={(task) => update(task.id, { status: task.crmStatus === 'Done' ? 'To-Do' : 'Done' })} onAdd={(dueDate, title) => run(() => actions.create({ title, dueDate, assignee: 'me' }))} />
      ) : groups.length === 0 ? (
        <p className="mw-empty">{local.length === 0 ? 'No tasks yet. Add one below, or with New task.' : 'No tasks match these filters.'}</p>
      ) : (
        <div className="mw-groups">
          {groups.map((group) => {
            const isOpen = !isFolded(group.key, group.folded)
            const orderable = group.key === REORDERABLE_GROUP_KEY
            return (
              <section key={group.key} className="mw-group" aria-label={group.label}>
                <header className="mw-group-head" data-accent={group.accent}>
                  <button type="button" className="mw-fold" aria-expanded={isOpen} onClick={() => toggleFold(group.key, group.folded)}>
                    <span aria-hidden="true">{isOpen ? '▾' : '▸'}</span> {group.label}
                  </button>
                  <span className="mw-count">{group.items.length}</span>
                </header>
                {isOpen && (
                  <ul className="mw-rows">
                    {group.items.map((task) => (
                      <TaskRowView
                        key={task.id}
                        task={task}
                        today={today}
                        nowHm={nowHm}
                        busy={busy}
                        columns={view.columns}
                        choices={choices}
                        assigneeName={nameOf(task.assignee)}
                        selected={selected.has(task.id)}
                        open={open === task.id}
                        orderable={orderable}
                        onSelect={(on) => setSelected((was) => toggledSet(was, task.id, on))}
                        onOpen={() => setOpen(task.id)}
                        onUpdate={(patch) => update(task.id, patch)}
                        onRemove={() => void run(() => actions.remove(task.id))}
                        onDrop={(draggedId) => {
                          const visible = group.items.map((one) => one.id).filter((id) => id !== draggedId)
                          visible.splice(visible.indexOf(task.id), 0, draggedId)
                          const full = local
                            .filter((one) => group.items.some((item) => item.id === one.id) || (one.dueDate === today && one.crmStatus !== 'Done'))
                            .map((one) => one.id)
                          void reorder(group.items.map((one) => one.id).concat(full.filter((id) => !group.items.some((item) => item.id === id))), visible)
                        }}
                      />
                    ))}
                    {!view.filters.archived && <AddTaskRow defaults={group.defaults} busy={busy} onAdd={(input) => run(() => actions.create(input))} />}
                  </ul>
                )}
              </section>
            )
          })}
        </div>
      )}
      {openTask !== undefined &&
        renderPopup(
          openTask,
          order.some((task) => task.id === openTask.id) ? order.map((task) => task.id) : [openTask.id],
          (id) => setOpen(id),
          () => setOpen(null),
        )}
    </div>
  )
}

function toggled(list: string[], value: string): string[] {
  return list.includes(value) ? list.filter((one) => one !== value) : [...list, value]
}

function toggledSet(set: Set<string>, value: string, on: boolean): Set<string> {
  const next = new Set(set)
  if (on) next.add(value)
  else next.delete(value)
  return next
}

function Tile({ label, value, tone, active, onClick }: { label: string; value: number; tone?: 'overdue'; active: boolean; onClick(): void }) {
  return (
    <button type="button" className="mw-tile" data-tone={tone} data-on={active || undefined} onClick={onClick}>
      <span className="mw-tile-value">{value}</span>
      <span className="mw-tile-label">{label}</span>
    </button>
  )
}

function Chip({ on, onClick, children }: { on: boolean; onClick(): void; children: string }) {
  return (
    <button type="button" className="mw-chip" aria-pressed={on} data-on={on || undefined} onClick={onClick}>
      {children}
    </button>
  )
}

/** One task, in the CRM's order of cells. */
export function TaskRowView({
  task,
  today,
  nowHm,
  busy,
  columns,
  choices,
  assigneeName,
  selected,
  open,
  orderable,
  onSelect,
  onOpen,
  onUpdate,
  onRemove,
  onDrop,
}: {
  task: TaskRow
  today: string
  nowHm: string | null
  busy: boolean
  columns: Columns
  choices: Array<{ id: string; label: string }>
  assigneeName: string
  selected: boolean
  open: boolean
  orderable: boolean
  onSelect(on: boolean): void
  onOpen(): void
  onUpdate(patch: Record<string, unknown>): void
  onRemove(): void
  onDrop(draggedId: string): void
}) {
  const done = task.crmStatus === 'Done'
  const overdue = isOverdue(task, today, nowHm)
  const due = relativeDue(task.dueDate, today)
  const tags = task.labels.slice(0, 3)
  const next = nextStatus(task.crmStatus)
  return (
    <li
      className="mw-row"
      data-status={statusTone(task.crmStatus)}
      data-open={open || undefined}
      onDragOver={orderable ? (event) => event.preventDefault() : undefined}
      onDrop={
        orderable
          ? (event) => {
              const dragged = event.dataTransfer.getData('text/x-td-task')
              if (dragged !== '' && dragged !== task.id) onDrop(dragged)
            }
          : undefined
      }
    >
      <div className="mw-row-main">
        <input type="checkbox" aria-label={`Select ${task.title}`} checked={selected} onChange={(event) => onSelect(event.target.checked)} />
        {orderable && (
          <span
            className="mw-handle"
            draggable
            role="img"
            aria-label={`Drag ${task.title} to reorder`}
            title="Drag to reorder your Today"
            onDragStart={(event) => event.dataTransfer.setData('text/x-td-task', task.id)}
          >
            ⋮⋮
          </span>
        )}
        <button
          type="button"
          className="mw-ring"
          data-shape={task.taskType === 'milestone' ? 'diamond' : 'ring'}
          title={done ? 'Done — click to reopen' : 'Mark done'}
          aria-label={done ? `Reopen ${task.title}` : `Mark ${task.title} done`}
          disabled={busy}
          onClick={() => onUpdate({ status: done ? 'To-Do' : 'Done' })}
        />
        <button type="button" className="mw-title" data-done={done || undefined} aria-haspopup="dialog" onClick={onOpen}>
          {task.title}
        </button>
        <span className="mw-badges">
          {task.instructions !== '' && (
            <span className="mw-badge" title="Has details" aria-label="Has details">
              ¶
            </span>
          )}
          {task.handedFrom !== null && (
            <span className="mw-badge" data-tone="attention" title={`${task.handedFrom} handed this to you`}>
              from {task.handedFrom}
            </span>
          )}
          {tags.map((tag) => (
            <span key={tag} className="mw-tag">
              {tag}
            </span>
          ))}
          {task.labels.length > 3 && <span className="mw-tag">+{task.labels.length - 3}</span>}
        </span>
        <span className="mw-cells">
          {columns.assignee && (
            <select className="mw-cell-select" aria-label={`Who has ${task.title}`} value={task.assignee} disabled={busy} onChange={(event) => onUpdate({ assignee: event.target.value })} title={assigneeName}>
              {choices.map((choice) => (
                <option key={choice.id} value={choice.id}>
                  {choice.label}
                </option>
              ))}
            </select>
          )}
          {columns.due && (
            <label className="mw-due" data-overdue={overdue || undefined} title={task.dueDate ?? 'No due date'}>
              <span>{due === '' ? 'No date' : `${due}${task.dueTime ? `, ${task.dueTime}` : ''}`}</span>
              <input type="date" aria-label={`Due date of ${task.title}`} value={task.dueDate ?? ''} disabled={busy} onChange={(event) => onUpdate({ dueDate: event.target.value || null })} />
            </label>
          )}
          {columns.priority && (
            <select className="mw-cell-select" data-priority={task.priority ?? 'none'} aria-label={`Priority of ${task.title}`} value={task.priority ?? ''} disabled={busy} onChange={(event) => onUpdate({ priority: event.target.value || null })}>
              <option value="">No priority</option>
              {PRIORITIES.map((priority) => (
                <option key={priority} value={priority}>
                  ⚑ {priority}
                </option>
              ))}
            </select>
          )}
          {columns.project && task.project !== '' && (
            <span className="mw-project" title={task.project}>
              {task.project.split('/').filter(Boolean).pop()}
            </span>
          )}
          {columns.created && <span className="mw-created">{createdLabel(task.createdAt, today)}</span>}
          <select className="mw-status" data-status={statusTone(task.crmStatus)} aria-label={`Status of ${task.title}`} value={task.crmStatus} disabled={busy} onChange={(event) => onUpdate({ status: event.target.value })}>
            {STATUS_ORDER.map((status) => (
              <option key={status} value={status}>
                {status}
              </option>
            ))}
          </select>
          {next !== null && (
            <button type="button" className="mw-next" title={`Move to ${next}`} aria-label={`Move ${task.title} to ${next}`} disabled={busy} onClick={() => onUpdate({ status: next })}>
              ▸
            </button>
          )}
          <button type="button" className="mw-delete" title="Delete" aria-label={`Delete ${task.title}`} disabled={busy} onClick={onRemove}>
            ×
          </button>
        </span>
      </div>
    </li>
  )
}

/** "+ Add task" under a group: Enter saves and keeps the row open, pre-filled with the group's own values. */
export function AddTaskRow({ defaults, busy, onAdd }: { defaults?: GroupDefaults; busy: boolean; onAdd(input: Record<string, unknown>): Promise<boolean> }) {
  const [adding, setAdding] = useState(false)
  const [title, setTitle] = useState('')
  const field = useRef<HTMLInputElement | null>(null)
  if (!adding) {
    return (
      <li className="mw-add">
        <button type="button" className="mw-link" onClick={() => setAdding(true)}>
          + Add task
        </button>
      </li>
    )
  }
  const save = async (): Promise<void> => {
    if (title.trim() === '') return
    const input: Record<string, unknown> = { title: title.trim(), assignee: defaults?.assignee ?? 'me' }
    if (defaults?.status !== undefined) input.status = defaults.status
    if (defaults?.priority !== undefined) input.priority = defaults.priority
    if (defaults?.dueDate !== undefined) input.dueDate = defaults.dueDate
    if (defaults?.board !== undefined) input.board = defaults.board
    if (await onAdd(input)) {
      setTitle('')
      field.current?.focus()
    }
  }
  return (
    <li className="mw-add">
      <input
        ref={field}
        autoFocus
        className="mw-search"
        aria-label="New task title"
        placeholder="Task name — Enter to add, Esc to stop"
        value={title}
        disabled={busy}
        onChange={(event) => setTitle(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter') {
            event.preventDefault()
            void save()
          } else if (event.key === 'Escape') {
            setAdding(false)
            setTitle('')
          }
        }}
      />
    </li>
  )
}

/**
 * One Monday-to-Sunday week by due date. A click on a task opens it; its ring
 * marks it done or reopens it; "+ Add" puts a task on that day.
 */
export function WeekCalendar({
  tasks,
  week,
  today,
  busy,
  openId,
  onWeek,
  onOpen,
  onToggle,
  onAdd,
}: {
  tasks: TaskRow[]
  week: string
  today: string
  busy: boolean
  openId?: string | null
  onWeek(ymd: string): void
  onOpen(id: string): void
  onToggle(task: TaskRow): void
  onAdd(dueDate: string, title: string): Promise<boolean>
}) {
  const days = weekOf(week)
  const [adding, setAdding] = useState<string | null>(null)
  const [title, setTitle] = useState('')
  const label = (ymd: string): string => {
    const [, m, d] = ymd.split('-').map(Number)
    return `${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][days.indexOf(ymd)]} ${d}/${m}`
  }
  return (
    <div className="mw-calendar">
      <div className="mw-calendar-bar">
        <button type="button" className="dashboard-btn" onClick={() => onWeek(ymdAddDays(days[0], -7))}>
          ‹ Previous week
        </button>
        <button type="button" className="dashboard-btn" onClick={() => onWeek(today)}>
          This week
        </button>
        <button type="button" className="dashboard-btn" onClick={() => onWeek(ymdAddDays(days[0], 7))}>
          Next week ›
        </button>
      </div>
      <div className="mw-week">
        {days.map((day) => (
          <section key={day} className="mw-day" data-today={day === today || undefined} aria-label={label(day)}>
            <h3 className="mw-day-head">{label(day)}</h3>
            {tasks
              .filter((task) => task.dueDate === day)
              .map((task) => (
                <span key={task.id} className="mw-day-item" data-open={openId === task.id || undefined}>
                  <button
                    type="button"
                    className="mw-ring"
                    data-shape={task.taskType === 'milestone' ? 'diamond' : 'ring'}
                    data-status={statusTone(task.crmStatus)}
                    disabled={busy}
                    title={task.crmStatus === 'Done' ? 'Done — click to reopen' : 'Mark done'}
                    aria-label={task.crmStatus === 'Done' ? `Reopen ${task.title}` : `Mark ${task.title} done`}
                    onClick={() => onToggle(task)}
                  />
                  <button type="button" className="mw-day-task" data-status={statusTone(task.crmStatus)} aria-haspopup="dialog" onClick={() => onOpen(task.id)}>
                    {task.title}
                  </button>
                </span>
              ))}
            {adding === day ? (
              <input
                autoFocus
                className="mw-search"
                aria-label={`New task on ${label(day)}`}
                value={title}
                disabled={busy}
                onChange={(event) => setTitle(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' && title.trim() !== '') {
                    void onAdd(day, title.trim()).then((ok) => {
                      if (ok) {
                        setTitle('')
                        setAdding(null)
                      }
                    })
                  } else if (event.key === 'Escape') setAdding(null)
                }}
              />
            ) : (
              <button type="button" className="mw-link" onClick={() => setAdding(day)}>
                + Add
              </button>
            )}
          </section>
        ))}
      </div>
    </div>
  )
}

/**
 * Cards in stages: one column per status, in the CRM's order. A card is the
 * task at a glance — title, tags, who has it, when it is due, its priority and
 * board — and dragging it to another column changes its status. "+ Add" under
 * a column makes a task in that stage.
 */
export function StageBoard({
  tasks,
  today,
  nowHm,
  busy,
  assigneeName,
  openId,
  onOpen,
  onMove,
  onAdd,
  archived,
}: {
  tasks: TaskRow[]
  today: string
  nowHm: string | null
  busy: boolean
  assigneeName(id: string): string
  openId: string | null
  onOpen(id: string): void
  onMove(task: TaskRow, status: string): void
  onAdd(input: Record<string, unknown>): Promise<boolean>
  archived: boolean
}) {
  const [over, setOver] = useState<string | null>(null)
  return (
    <div className="mw-board-wrap">
      <div className="mw-board" role="list" aria-label="Stages">
        {STATUS_ORDER.map((status) => {
          const cards = tasks.filter((task) => task.crmStatus === status)
          return (
            <section
              key={status}
              role="listitem"
              className="mw-stage"
              data-status={statusTone(status)}
              data-over={over === status || undefined}
              aria-label={`${status}, ${cards.length}`}
              onDragOver={(event) => {
                event.preventDefault()
                setOver(status)
              }}
              onDragLeave={() => setOver((was) => (was === status ? null : was))}
              onDrop={(event) => {
                setOver(null)
                const id = event.dataTransfer.getData('text/x-td-task')
                const task = tasks.find((one) => one.id === id)
                if (task !== undefined && task.crmStatus !== status) onMove(task, status)
              }}
            >
              <header className="mw-stage-head">
                <span className="mw-stage-dot" aria-hidden="true" />
                {status}
                <span className="mw-count">{cards.length}</span>
              </header>
              <ul className="mw-cards">
                {cards.map((task) => {
                  const due = relativeDue(task.dueDate, today)
                  return (
                    <li
                      key={task.id}
                      className="mw-card"
                      data-open={openId === task.id || undefined}
                      draggable={!busy}
                      onDragStart={(event) => event.dataTransfer.setData('text/x-td-task', task.id)}
                    >
                      <button type="button" className="mw-card-title" aria-haspopup="dialog" onClick={() => onOpen(task.id)}>
                        {task.taskType === 'milestone' ? '◆ ' : ''}
                        {task.title}
                      </button>
                      {task.labels.length > 0 && (
                        <span className="mw-badges">
                          {task.labels.slice(0, 3).map((tag) => (
                            <span key={tag} className="mw-tag">
                              {tag}
                            </span>
                          ))}
                          {task.labels.length > 3 && <span className="mw-tag">+{task.labels.length - 3}</span>}
                        </span>
                      )}
                      <span className="mw-card-meta">
                        <span>{assigneeName(task.assignee)}</span>
                        {due !== '' && (
                          <span className="mw-card-due" data-overdue={isOverdue(task, today, nowHm) || undefined}>
                            {due}
                            {task.dueTime ? `, ${task.dueTime}` : ''}
                          </span>
                        )}
                        {task.priority !== null && (
                          <span className="mw-card-priority" data-priority={task.priority}>
                            ⚑ {task.priority}
                          </span>
                        )}
                        {task.board !== null && <span className="mw-card-board">{task.board}</span>}
                      </span>
                      {task.handedFrom !== null && <span className="mw-badge" data-tone="attention">from {task.handedFrom}</span>}
                    </li>
                  )
                })}
                {!archived && <AddTaskRow defaults={{ status }} busy={busy} onAdd={onAdd} />}
              </ul>
            </section>
          )
        })}
      </div>
    </div>
  )
}

/**
 * The Trash: your deleted tasks — deleted, merged into another, or made a
 * subtask — each kept whole, files and history included, until you restore it.
 * Nothing empties it.
 */
export function TrashList({ tasks, now, busy, onRestore }: { tasks: TaskRow[]; now: number; busy: boolean; onRestore(id: string): void }): ReactElement {
  if (tasks.length === 0) return <p className="mw-empty">The Trash is empty. A task you delete, merge or make a subtask waits here until you restore it.</p>
  return (
    <ul className="mw-trash" aria-label="Trash">
      {tasks.map((task) => (
        <li key={task.id} className="mw-trash-row">
          <span className="mw-trash-title">{task.title}</span>
          <span className="mw-trash-when">{task.deletedAt === null ? '' : `Deleted ${relativeAgo(now - task.deletedAt)}`}</span>
          <button type="button" className="dashboard-btn" disabled={busy} onClick={() => onRestore(task.id)}>
            Restore
          </button>
        </li>
      ))}
    </ul>
  )
}

/** "just now", "5 minutes ago", "3 hours ago", "2 days ago". */
function relativeAgo(ms: number): string {
  const minutes = Math.floor(Math.max(0, ms) / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`
  const days = Math.floor(hours / 24)
  return `${days} day${days === 1 ? '' : 's'} ago`
}
