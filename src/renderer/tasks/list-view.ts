/**
 * The task list's pure rules, ported from a CRM's My Work task list: the
 * grouping options, the due buckets, the row's relative dates, and the fold of
 * closed tasks.
 *
 * What changed in the port, and why:
 *  - Days are this Mac's own calendar, not one fixed office time zone:
 *    Terminal Deck runs wherever its owner is.
 *  - "Board" keeps its place as a category, but of your own naming rather
 *    than the CRM's fixed Leads/Viewings/…; a task need not have one. The
 *    project folder is a separate grouping — not every task is code work.
 *  - Assignees are nobody, you, Hoot or one of your task agents — there is no
 *    team directory to sort by name.
 * Everything else — the order of statuses and priorities, the buckets, the
 * folded Done group, the Today-only reorder — is the CRM's, unchanged.
 */

import type { TaskRow } from './tasks-model'

export const LIST_GROUPINGS = ['none', 'status', 'assignee', 'priority', 'tags', 'due', 'type', 'board', 'project'] as const
export type ListGroupBy = (typeof LIST_GROUPINGS)[number]

export const LIST_GROUP_LABEL: Record<ListGroupBy, string> = {
  none: 'None',
  status: 'Status',
  assignee: 'Assignee',
  priority: 'Priority',
  tags: 'Tags',
  due: 'Due date',
  type: 'Task type',
  board: 'Board',
  project: 'Project',
}

export const STATUS_ORDER = ['To-Do', 'Working on it', 'In Progress', 'Stuck', 'Done'] as const
export const PRIORITY_ORDER: Array<string | null> = ['Critical', 'High', 'Medium', 'Low', null]

/** What a "+ Add task" under a group pre-fills, so the new task lands in that group. */
export type GroupDefaults = { status?: string; priority?: string | null; dueDate?: string | null; assignee?: string; board?: string | null }

export interface ListGroup {
  key: string
  label: string
  /** `overdue` red, `today` the accent. */
  accent?: 'overdue' | 'today'
  items: TaskRow[]
  defaults?: GroupDefaults
  /** Starts collapsed: the closed tasks' group. */
  folded?: boolean
}

export const MONTH_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

export function isYmd(value: unknown): value is string {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
}

/** This Mac's calendar date for an instant, "YYYY-MM-DD". */
export function ymdOf(at: number): string {
  const d = new Date(at)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function utc(ymd: string): number {
  const [y, m, d] = ymd.split('-').map(Number)
  return Date.UTC(y, m - 1, d)
}

/** Whole days from `a` to `b`. */
export function ymdDiff(a: string, b: string): number {
  return Math.round((utc(b) - utc(a)) / 86_400_000)
}

export function ymdAddDays(ymd: string, days: number): string {
  const d = new Date(utc(ymd) + days * 86_400_000)
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`
}

/** 0 = Sunday. */
export function ymdWeekday(ymd: string): number {
  return new Date(utc(ymd)).getUTCDay()
}

/** The due cell: "Today" · "Tomorrow" · "Yesterday" · "15 Sep" (· 2027 when not this year). */
export function relativeDue(ymd: string | null, today: string): string {
  if (!isYmd(ymd) || !isYmd(today)) return ''
  const delta = ymdDiff(today, ymd)
  if (delta === 0) return 'Today'
  if (delta === 1) return 'Tomorrow'
  if (delta === -1) return 'Yesterday'
  const [y, m, d] = ymd.split('-').map(Number)
  const label = `${d} ${MONTH_SHORT[m - 1]}`
  return y === Number(today.slice(0, 4)) ? label : `${label} ${y}`
}

/** Due today at a time that has come — the row's red due cell. */
export function isDueTimePassed(dueDate: string | null, dueTime: string | null, today: string, nowHm: string | null): boolean {
  return !!nowHm && !!dueTime && dueDate === today && dueTime <= nowHm
}

export function isOverdue(task: Pick<TaskRow, 'dueDate' | 'dueTime' | 'crmStatus'>, today: string, nowHm: string | null): boolean {
  if (task.crmStatus === 'Done' || !isYmd(task.dueDate)) return false
  return task.dueDate < today || isDueTimePassed(task.dueDate, task.dueTime, today, nowHm)
}

/** "Date created": "Today" · "Yesterday" · "Sep 12" · "Sep 12, 2025". */
export function createdLabel(at: number, today: string): string {
  const ymd = ymdOf(at)
  const delta = ymdDiff(today, ymd)
  if (delta === 0) return 'Today'
  if (delta === -1) return 'Yesterday'
  const [y, m, d] = ymd.split('-').map(Number)
  const label = `${MONTH_SHORT[m - 1]} ${d}`
  return y === Number(today.slice(0, 4)) ? label : `${label}, ${y}`
}

/** Overdue · Today · Next (to the end of next week) · Later · Unscheduled. */
export const DUE_BUCKETS = ['Overdue', 'Today', 'Next', 'Later', 'Unscheduled'] as const
export type DueBucket = (typeof DUE_BUCKETS)[number]

export function dueBucket(dueDate: string | null, today: string, time: { dueTime?: string | null; nowHm?: string | null } = {}): DueBucket {
  if (!isYmd(dueDate)) return 'Unscheduled'
  if (dueDate < today) return 'Overdue'
  if (dueDate === today) return isDueTimePassed(dueDate, time.dueTime ?? null, today, time.nowHm ?? null) ? 'Overdue' : 'Today'
  const dow = (ymdWeekday(today) + 6) % 7 // Monday = 0
  return dueDate <= ymdAddDays(today, 13 - dow) ? 'Next' : 'Later'
}

/** The one group you can drag to reorder: Today, in your own order. */
export const REORDERABLE_GROUP_KEY = 'due:Today'

/** Placed tasks first, lowest position on top; the rest keep the order they came in. */
export function sortByPosition<T extends { position: number | null }>(items: T[]): T[] {
  const placed = items.filter((task) => typeof task.position === 'number')
  const rest = items.filter((task) => typeof task.position !== 'number')
  placed.sort((a, b) => (a.position as number) - (b.position as number))
  return [...placed, ...rest]
}

/**
 * A drag in a filtered list moves only what you can see: the visible tasks swap
 * among the slots they already held, so a hidden task keeps its place.
 */
export function reorderWithinSlots(fullIds: string[], newVisibleIds: string[]): string[] {
  const inFull = new Set(fullIds)
  const queue = newVisibleIds.filter((id) => inFull.has(id))
  const moving = new Set(queue)
  let next = 0
  return fullIds.map((id) => (moving.has(id) ? queue[next++] : id))
}

/** Due date ascending, no date last — the order the CRM's server lists them in. */
export function byDue(a: TaskRow, b: TaskRow): number {
  const ad = a.dueDate ?? '9999-99-99'
  const bd = b.dueDate ?? '9999-99-99'
  if (ad !== bd) return ad < bd ? -1 : 1
  return (a.dueTime ?? '99:99') < (b.dueTime ?? '99:99') ? -1 : (a.dueTime ?? '99:99') > (b.dueTime ?? '99:99') ? 1 : 0
}

/**
 * The list, grouped. Done tasks are pulled into one folded "Done" group at the
 * bottom unless `showClosed` puts them back; grouped by Status, Done is its own
 * group, folded the same way. Empty groups are left out.
 */
export function groupTasks(
  tasks: TaskRow[],
  by: ListGroupBy,
  today: string,
  opts: { showClosed: boolean; assigneeName(id: string): string; nowHm?: string | null },
): ListGroup[] {
  const sorted = [...tasks].sort(byDue)
  const closed = sorted.filter((task) => task.crmStatus === 'Done')
  const pool = opts.showClosed || by === 'status' ? sorted : sorted.filter((task) => task.crmStatus !== 'Done')
  const groups: ListGroup[] = []
  const push = (key: string, label: string, items: TaskRow[], extra: Partial<ListGroup> = {}): void => {
    if (items.length > 0) groups.push({ key, label, items, ...extra })
  }
  switch (by) {
    case 'none':
      push('all', `${pool.length} ${pool.length === 1 ? 'Task' : 'Tasks'}`, pool)
      break
    case 'status':
      for (const status of STATUS_ORDER) {
        push(`status:${status}`, status, pool.filter((task) => task.crmStatus === status), {
          defaults: { status },
          folded: status === 'Done' && !opts.showClosed,
        })
      }
      break
    case 'assignee': {
      const ids = [...new Set(pool.map((task) => task.assignee))].sort((a, b) =>
        a === 'none' ? 1 : b === 'none' ? -1 : opts.assigneeName(a).localeCompare(opts.assigneeName(b)),
      )
      for (const id of ids) {
        push(`assignee:${id}`, opts.assigneeName(id), pool.filter((task) => task.assignee === id), { defaults: { assignee: id } })
      }
      break
    }
    case 'priority':
      for (const priority of PRIORITY_ORDER) {
        push(`priority:${priority ?? 'none'}`, priority ?? 'No priority', pool.filter((task) => (task.priority ?? null) === priority), {
          defaults: { priority },
        })
      }
      break
    case 'tags': {
      // A task with two tags sits in both groups.
      const all = [...new Set(pool.flatMap((task) => task.labels))].sort((a, b) => a.localeCompare(b))
      for (const label of all) push(`tag:${label}`, label, pool.filter((task) => task.labels.includes(label)))
      push('tag:none', 'No tags', pool.filter((task) => task.labels.length === 0))
      break
    }
    case 'due':
      for (const bucket of DUE_BUCKETS) {
        const inBucket = pool.filter((task) => dueBucket(task.dueDate, today, { dueTime: task.dueTime, nowHm: opts.nowHm }) === bucket)
        push(`due:${bucket}`, bucket, `due:${bucket}` === REORDERABLE_GROUP_KEY ? sortByPosition(inBucket) : inBucket, {
          ...(bucket === 'Overdue' ? { accent: 'overdue' as const } : bucket === 'Today' ? { accent: 'today' as const } : {}),
          ...(bucket === 'Today' ? { defaults: { dueDate: today } } : bucket === 'Unscheduled' ? { defaults: { dueDate: null } } : {}),
        })
      }
      break
    case 'type':
      push('type:task', 'Task', pool.filter((task) => task.taskType !== 'milestone'))
      push('type:milestone', 'Milestone', pool.filter((task) => task.taskType === 'milestone'))
      break
    case 'board': {
      const boards = [...new Set(pool.map((task) => task.board ?? ''))].sort((a, b) => (a === '' ? 1 : b === '' ? -1 : a.localeCompare(b)))
      for (const board of boards) {
        push(`board:${board || 'none'}`, board === '' ? 'No board' : board, pool.filter((task) => (task.board ?? '') === board), {
          defaults: { board: board === '' ? null : board },
        })
      }
      break
    }
    case 'project': {
      const projects = [...new Set(pool.map((task) => task.project))].sort((a, b) => (a === '' ? 1 : b === '' ? -1 : a.localeCompare(b)))
      for (const project of projects) {
        push(`project:${project || 'none'}`, project === '' ? 'No project' : (project.split('/').filter(Boolean).pop() ?? project), pool.filter((task) => task.project === project))
      }
      break
    }
  }
  if (!opts.showClosed && by !== 'status') push('__closed', 'Done', closed, { folded: true, defaults: { status: 'Done' } })
  return groups
}

/* --------------------------------------------------------------- filters -- */

/**
 * The piles: everything, yours, your agents', nobody's — the CRM's "Assigned to
 * me / Raised by me / Team" for one person — and the ones you starred (the
 * CRM's Favorites).
 */
export const PILES = ['all', 'mine', 'agents', 'unassigned', 'favorites'] as const
export type Pile = (typeof PILES)[number]
export const PILE_LABEL: Record<Pile, string> = { all: 'All tasks', mine: 'Assigned to me', agents: 'With Hoot and agents', unassigned: 'Unassigned', favorites: 'Favorites' }

export const DUE_FILTERS = ['any', 'overdue', 'today', 'week', 'none'] as const
export type DueFilter = (typeof DUE_FILTERS)[number]
export const DUE_FILTER_LABEL: Record<DueFilter, string> = {
  any: 'Any time',
  overdue: 'Overdue',
  today: 'Due today',
  week: 'Next 7 days',
  none: 'No due date',
}

export interface ListFilters {
  pile: Pile
  search: string
  statuses: string[]
  /** `none` stands for "no priority". */
  priorities: string[]
  /** `none` stands for "no board". */
  boards: string[]
  due: DueFilter
  archived: boolean
}

export const NO_FILTERS: ListFilters = { pile: 'all', search: '', statuses: [], priorities: [], boards: [], due: 'any', archived: false }

export function filterTasks(tasks: TaskRow[], filters: ListFilters, today: string, nowHm: string | null, favorites: ReadonlySet<string> = new Set()): TaskRow[] {
  const search = filters.search.trim().toLowerCase()
  return tasks.filter((task) => {
    if ((task.archivedAt !== null) !== filters.archived) return false
    if (filters.pile === 'favorites' && !favorites.has(task.id)) return false
    if (filters.pile === 'mine' && task.assignee !== 'me') return false
    if (filters.pile === 'agents' && (task.assignee === 'me' || task.assignee === 'none')) return false
    if (filters.pile === 'unassigned' && task.assignee !== 'none') return false
    if (filters.statuses.length > 0 && !filters.statuses.includes(task.crmStatus)) return false
    if (filters.priorities.length > 0 && !filters.priorities.includes(task.priority ?? 'none')) return false
    if (filters.boards.length > 0 && !filters.boards.includes(task.board ?? 'none')) return false
    if (filters.due === 'overdue' && !isOverdue(task, today, nowHm)) return false
    if (filters.due === 'today' && task.dueDate !== today) return false
    if (filters.due === 'week' && !(isYmd(task.dueDate) && task.dueDate >= today && task.dueDate <= ymdAddDays(today, 7))) return false
    if (filters.due === 'none' && task.dueDate !== null) return false
    if (search !== '' && !`${task.title} ${task.board ?? ''} ${task.project} ${task.labels.join(' ')}`.toLowerCase().includes(search)) return false
    return true
  })
}

/** The summary tiles: open, overdue, due today, done. */
export function summary(tasks: TaskRow[], today: string, nowHm: string | null): { open: number; overdue: number; today: number; done: number } {
  const live = tasks.filter((task) => task.archivedAt === null)
  return {
    open: live.filter((task) => task.crmStatus !== 'Done').length,
    overdue: live.filter((task) => isOverdue(task, today, nowHm)).length,
    today: live.filter((task) => task.crmStatus !== 'Done' && task.dueDate === today).length,
    done: live.filter((task) => task.crmStatus === 'Done').length,
  }
}

/** The status the ▸ arrow moves to: To-Do → Working on it → In Progress → Done; Stuck → In Progress; Done has none. */
export function nextStatus(status: string): string | null {
  if (status === 'To-Do') return 'Working on it'
  if (status === 'Working on it') return 'In Progress'
  if (status === 'In Progress') return 'Done'
  if (status === 'Stuck') return 'In Progress'
  return null
}

/** The Monday-to-Sunday week holding `ymd`. */
export function weekOf(ymd: string): string[] {
  const monday = ymdAddDays(ymd, -((ymdWeekday(ymd) + 6) % 7))
  return Array.from({ length: 7 }, (_, n) => ymdAddDays(monday, n))
}
