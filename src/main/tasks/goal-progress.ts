/**
 * Where a goal stands, read off its tasks: how many are in each state, which
 * are waiting on others, which have stalled, and which were finished and
 * checked against the ones only claimed.
 *
 * Pure, over the task records and the goal tree, so the Tasks page, Hoot's
 * progress tool and the engine's dependency check all read one answer.
 *
 * ## Links between tasks
 *
 * The task page keeps a link once, on the task it was made from
 * (`task-detail-local.ts`): "A is blocked by B" may be written on A as
 * `blocked_by B`, or on B as `blocks A`. {@link blockersOf} reads both sides,
 * the way the page shows them, and counts a blocker as cleared once it is
 * Done.
 */

import type { Goal } from '../../shared/agent-stack'
import type { DependencyKind } from '../../shared/crm/collab-types'
import { LOCAL_STATUSES } from './task-config'
import type { TaskRecord, TaskStall } from './task-store'

/** Done is the one finished status; a CRM's own spelling of it is read the same way. */
export function isDone(task: TaskRecord): boolean {
  return task.crmStatus === LOCAL_STATUSES.completed
}

const MIRROR: Record<DependencyKind, DependencyKind> = { blocks: 'blocked_by', blocked_by: 'blocks', linked: 'linked' }

/** Every link of a local task, from its own side and the other side, once each, as this task reads it. */
export function linksOf(task: TaskRecord, all: readonly TaskRecord[]): Array<{ kind: DependencyKind; other: TaskRecord }> {
  if (task.local !== true) return []
  const byId = new Map(all.map((one) => [one.id, one]))
  const seen = new Set<string>()
  const out: Array<{ kind: DependencyKind; other: TaskRecord }> = []
  const add = (kind: DependencyKind, otherId: string): void => {
    const other = byId.get(otherId)
    const key = `${kind}:${otherId}`
    if (other === undefined || other.id === task.id || other.local !== true || seen.has(key)) return
    seen.add(key)
    out.push({ kind, other })
  }
  for (const dep of task.detail?.dependencies ?? []) add(dep.kind, dep.otherTaskId)
  for (const other of all) {
    if (other.id === task.id) continue
    for (const dep of other.detail?.dependencies ?? []) if (dep.otherTaskId === task.id) add(MIRROR[dep.kind], other.id)
  }
  return out
}

/** The open tasks this one waits for: every unfinished task it is blocked by, from either side of the link. */
export function blockersOf(task: TaskRecord, all: readonly TaskRecord[]): TaskRecord[] {
  return linksOf(task, all)
    .filter((link) => link.kind === 'blocked_by' && !isDone(link.other))
    .map((link) => link.other)
}

/** One task, as a progress report lists it. */
export interface GoalTaskLine {
  task: string
  title: string
  goal: string
  status: string
  process: TaskRecord['process']
  /** `none`, `me`, `hoot`, or an agent's id. */
  assignee: string
  /** True once verified, false when finished unverified, null while not finished. */
  verified: boolean | null
  stalled: TaskStall | null
  /** The open tasks it waits for. */
  blockedBy: Array<{ task: string; title: string }>
}

export interface GoalProgress {
  goal: string
  title: string
  status: Goal['status']
  /** Every task under the goal and its sub-goals, archived ones left out. */
  total: number
  done: number
  /** Finished and checked: a passing check, or a review that named its evidence. */
  verified: number
  /** Finished, or marked Done, without a check or a review saying it is right. */
  unverified: number
  stalled: number
  blocked: number
  /** Count by status, in the statuses' own order. */
  byStatus: Record<string, number>
  /** Count by Terminal Deck's own process state. */
  byProcess: Record<string, number>
  tasks: GoalTaskLine[]
  /** The goals directly under it. */
  children: Array<{ goal: string; title: string; status: Goal['status'] }>
}

/** The goals a tree reaches from `root`, by walking `parentId` downwards. */
function subtreeIds(rootId: string, goals: readonly Goal[]): Set<string> {
  const ids = new Set([rootId])
  let grew = true
  while (grew) {
    grew = false
    for (const goal of goals) {
      if (goal.parentId !== null && ids.has(goal.parentId) && !ids.has(goal.id)) {
        ids.add(goal.id)
        grew = true
      }
    }
  }
  return ids
}

export function taskLine(task: TaskRecord, all: readonly TaskRecord[]): GoalTaskLine {
  return {
    task: task.id,
    title: task.title,
    goal: task.goalId ?? '',
    status: task.crmStatus,
    process: task.process,
    assignee: task.assignee.agentId,
    verified: task.result === null ? null : task.result.verified,
    stalled: task.stalled ?? null,
    blockedBy: blockersOf(task, all).map((other) => ({ task: other.id, title: other.title })),
  }
}

export function goalProgress(goal: Goal, goals: readonly Goal[], tasks: readonly TaskRecord[]): GoalProgress {
  const ids = subtreeIds(goal.id, goals)
  const mine = tasks.filter((task) => task.local === true && task.archivedAt == null && typeof task.goalId === 'string' && ids.has(task.goalId))
  const lines = mine.map((task) => taskLine(task, tasks))
  const byStatus: Record<string, number> = Object.fromEntries(LOCAL_STATUSES.statuses.map((status) => [status, 0]))
  const byProcess: Record<string, number> = { queued: 0, running: 0, exited: 0, idle: 0 }
  for (const task of mine) {
    byStatus[task.crmStatus] = (byStatus[task.crmStatus] ?? 0) + 1
    byProcess[task.process] = (byProcess[task.process] ?? 0) + 1
  }
  const finished = (task: TaskRecord): boolean => task.result !== null || isDone(task)
  return {
    goal: goal.id,
    title: goal.title,
    status: goal.status,
    total: mine.length,
    done: mine.filter(isDone).length,
    verified: mine.filter((task) => task.result?.verified === true).length,
    unverified: mine.filter((task) => finished(task) && task.result?.verified !== true).length,
    stalled: mine.filter((task) => (task.stalled ?? null) !== null).length,
    blocked: lines.filter((line) => line.blockedBy.length > 0 && line.status !== LOCAL_STATUSES.completed).length,
    byStatus,
    byProcess,
    tasks: lines,
    children: goals.filter((one) => one.parentId === goal.id).map((one) => ({ goal: one.id, title: one.title, status: one.status })),
  }
}
