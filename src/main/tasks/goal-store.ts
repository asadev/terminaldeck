/**
 * Goals: what a set of your tasks is for, kept on this Mac beside the tasks.
 *
 * ## A tree of plain records
 *
 * A goal is the shared {@link Goal} shape — a title, a description, a status
 * and an optional parent — so a goal can serve a bigger one ("Ship 0.18" under
 * "A Mac release every fortnight"). Local tasks point at the goal they serve
 * with `goalId` (`task-store.ts`); a goal never lists its tasks, so there is one
 * record of the link and it cannot disagree with itself.
 *
 * The tree is checked on every write: a parent has to exist, and a goal can
 * never become its own ancestor. {@link GoalStore.chain} walks from a goal up to
 * the root, which is what a worker's brief carries — the why behind the task —
 * and it is bounded by {@link MAX_GOAL_DEPTH}, so even a file edited by hand
 * into a loop answers.
 *
 * ## Kept the way tasks are kept
 *
 * `<userData>/remote/goals.json`, beside `tasks.json`, through the same atomic
 * 0600 writer: a description is the owner's own words about their work, and it
 * reaches every brief written under it.
 *
 * ## Removing one
 *
 * A removed goal's sub-goals move up to its parent, and so do its tasks
 * ({@link GoalStore.remove} answers which parent that is; the caller relinks
 * the tasks). Nothing under it is lost, and a top-level goal's tasks simply
 * serve no goal any more.
 */

import { randomUUID } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { isAbsolute, join } from 'node:path'
import type { Goal, GoalStatus } from '../../shared/agent-stack'
import { writeSecretFile } from '../remote/secret-file'
import { TaskConfigProblem } from './task-config'

export const GOALS_FILE = 'goals.json'

export const GOAL_STATUSES: readonly GoalStatus[] = ['planned', 'active', 'achieved', 'cancelled']

/** Most goals kept; a write past it is refused rather than dropping one. */
export const MAX_GOALS = 500
export const MAX_GOAL_TITLE = 200
export const MAX_GOAL_DESCRIPTION = 4_000
/** Deepest a goal may sit under others — and the most a chain walks. */
export const MAX_GOAL_DEPTH = 8

interface StoredFile {
  v: 1
  goals: Goal[]
}

export interface GoalStoreOptions {
  dir: string | null
  now?: () => number
}

function text(value: unknown, what: string, max: number, required: boolean): string | undefined {
  if (value === undefined || value === null) {
    if (required) throw new TaskConfigProblem(`${what} cannot be empty.`)
    return undefined
  }
  if (typeof value !== 'string') throw new TaskConfigProblem(`${what} has to be text.`)
  const trimmed = value.trim()
  if (required && trimmed === '') throw new TaskConfigProblem(`${what} cannot be empty.`)
  if (trimmed.length > max) throw new TaskConfigProblem(`${what} is longer than ${max} characters.`)
  return trimmed
}

function isGoal(raw: unknown): raw is Goal {
  const g = raw as Partial<Goal> | null
  return (
    typeof g === 'object' &&
    g !== null &&
    typeof g.id === 'string' &&
    typeof g.title === 'string' &&
    typeof g.description === 'string' &&
    GOAL_STATUSES.includes(g.status as GoalStatus) &&
    (g.parentId === null || typeof g.parentId === 'string') &&
    (g.project === null || typeof g.project === 'string') &&
    typeof g.createdAt === 'number' &&
    typeof g.updatedAt === 'number'
  )
}

export class GoalStore {
  private goals = new Map<string, Goal>()
  private saveQueued = false
  private readonly now: () => number
  private readonly listeners = new Set<() => void>()

  constructor(private readonly options: GoalStoreOptions) {
    this.now = options.now ?? Date.now
    this.load()
  }

  all(): Goal[] {
    return [...this.goals.values()].sort((a, b) => a.createdAt - b.createdAt)
  }

  byId(id: string): Goal | null {
    return this.goals.get(id) ?? null
  }

  has(id: string): boolean {
    return this.goals.has(id)
  }

  children(id: string): Goal[] {
    return this.all().filter((goal) => goal.parentId === id)
  }

  /** The goal and every goal under it, at any depth. */
  subtree(id: string): Goal[] {
    const root = this.byId(id)
    if (root === null) return []
    const out: Goal[] = [root]
    for (let i = 0; i < out.length && out.length <= MAX_GOALS; i += 1) out.push(...this.children(out[i].id))
    return out
  }

  /** From this goal up to its root, this goal first. Empty for a goal that does not exist. */
  chain(id: string): Goal[] {
    const out: Goal[] = []
    let at = this.byId(id)
    while (at !== null && out.length < MAX_GOAL_DEPTH && !out.includes(at)) {
      out.push(at)
      at = at.parentId === null ? null : this.byId(at.parentId)
    }
    return out
  }

  /** A new goal from what a person or Hoot typed. Throws {@link TaskConfigProblem} with what to fix. */
  create(raw: unknown): Goal {
    const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
    if (this.goals.size >= MAX_GOALS) throw new TaskConfigProblem(`There are already ${MAX_GOALS} goals. Remove one you no longer need first.`)
    const now = this.now()
    const goal: Goal = {
      id: `goal-${randomUUID()}`,
      title: text(input.title, 'The goal’s title', MAX_GOAL_TITLE, true) as string,
      description: text(input.description, 'The description', MAX_GOAL_DESCRIPTION, false) ?? '',
      status: this.statusOf(input.status) ?? 'active',
      parentId: null,
      project: this.projectOf(input.project) ?? null,
      createdAt: now,
      updatedAt: now,
    }
    if (input.parentId !== undefined) goal.parentId = this.parentOf(goal.id, input.parentId)
    this.goals.set(goal.id, goal)
    this.changed()
    return goal
  }

  /** Change what is named; anything left out stays. */
  update(id: unknown, raw: unknown): Goal {
    const goal = typeof id === 'string' ? this.byId(id) : null
    if (goal === null) throw new TaskConfigProblem('That goal no longer exists.')
    const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
    const title = text(input.title, 'The goal’s title', MAX_GOAL_TITLE, 'title' in input)
    const description = text(input.description, 'The description', MAX_GOAL_DESCRIPTION, false)
    const status = this.statusOf(input.status)
    const project = 'project' in input ? (this.projectOf(input.project) ?? null) : undefined
    const parentId = 'parentId' in input ? this.parentOf(goal.id, input.parentId) : undefined
    Object.assign(goal, {
      ...(title === undefined ? {} : { title }),
      ...(description === undefined ? {} : { description }),
      ...(status === undefined ? {} : { status }),
      ...(project === undefined ? {} : { project }),
      ...(parentId === undefined ? {} : { parentId }),
      updatedAt: this.now(),
    })
    this.changed()
    return goal
  }

  /**
   * Take a goal out. Its sub-goals move up to its parent; the answer is that
   * parent (null at the top), which the caller moves the goal's tasks to.
   */
  remove(id: unknown): { removed: Goal; parentId: string | null } {
    const goal = typeof id === 'string' ? this.byId(id) : null
    if (goal === null) throw new TaskConfigProblem('That goal no longer exists.')
    for (const child of this.children(goal.id)) {
      child.parentId = goal.parentId
      child.updatedAt = this.now()
    }
    this.goals.delete(goal.id)
    this.changed()
    return { removed: goal, parentId: goal.parentId }
  }

  /** Told after every change, once the change is made. */
  onChange(listener: () => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /* ----------------------------------------------------------- checks -- */

  private statusOf(raw: unknown): GoalStatus | undefined {
    if (raw === undefined || raw === null || raw === '') return undefined
    if (typeof raw !== 'string' || !GOAL_STATUSES.includes(raw as GoalStatus)) {
      throw new TaskConfigProblem(`A goal’s status is one of: ${GOAL_STATUSES.join(', ')}.`)
    }
    return raw as GoalStatus
  }

  private projectOf(raw: unknown): string | null | undefined {
    if (raw === undefined) return undefined
    if (raw === null || raw === '') return null
    const project = text(raw, 'The project folder', 1024, false) ?? ''
    if (project === '') return null
    if (!isAbsolute(project)) throw new TaskConfigProblem(`${project} is not a full folder path.`)
    return project
  }

  /** A parent that exists, is not this goal or under it, and leaves the tree no deeper than allowed. */
  private parentOf(id: string, raw: unknown): string | null {
    if (raw === null || raw === '' || raw === undefined) return null
    if (typeof raw !== 'string') throw new TaskConfigProblem('The parent goal has to be a goal’s id.')
    const parent = this.byId(raw)
    if (parent === null) throw new TaskConfigProblem('That parent goal no longer exists.')
    const above = this.chain(parent.id)
    if (above.some((goal) => goal.id === id)) throw new TaskConfigProblem('A goal cannot sit under itself or under one of its own sub-goals.')
    const below = this.depthBelow(id)
    if (above.length + 1 + below > MAX_GOAL_DEPTH) throw new TaskConfigProblem(`Goals can be nested at most ${MAX_GOAL_DEPTH} deep.`)
    return parent.id
  }

  /** How many levels sit under a goal — zero for a leaf, or for one not made yet. */
  private depthBelow(id: string): number {
    let deepest = 0
    let level = this.children(id)
    while (level.length > 0 && deepest < MAX_GOAL_DEPTH) {
      deepest += 1
      level = level.flatMap((goal) => this.children(goal.id))
    }
    return deepest
  }

  /* ---------------------------------------------------------- keeping -- */

  private changed(): void {
    this.save()
    for (const listener of this.listeners) {
      try {
        listener()
      } catch (error) {
        console.error('[goals] a change listener threw:', error)
      }
    }
  }

  private file(): string | null {
    return this.options.dir === null ? null : join(this.options.dir, GOALS_FILE)
  }

  private save(): void {
    if (this.file() === null || this.saveQueued) return
    this.saveQueued = true
    queueMicrotask(() => this.flush())
  }

  flush(): void {
    this.saveQueued = false
    const file = this.file()
    if (file === null || this.options.dir === null) return
    try {
      const state: StoredFile = { v: 1, goals: this.all() }
      writeSecretFile(this.options.dir, file, `${JSON.stringify(state)}\n`)
    } catch (error) {
      console.error('[goals] could not save the goals:', error)
    }
  }

  private load(): void {
    const file = this.file()
    if (file === null || !existsSync(file)) return
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8')) as Partial<StoredFile>
      if (raw.v !== 1) return
      for (const goal of Array.isArray(raw.goals) ? raw.goals : []) {
        if (isGoal(goal)) this.goals.set(goal.id, { ...goal })
      }
      // A parent that is gone reads as none, so a hand-edited file cannot strand a goal.
      for (const goal of this.goals.values()) if (goal.parentId !== null && !this.goals.has(goal.parentId)) goal.parentId = null
    } catch (error) {
      console.error('[goals] could not read the goals; starting empty:', error)
    }
  }
}
