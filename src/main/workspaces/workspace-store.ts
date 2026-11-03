/**
 * The task workspaces this app has made, and why a task that asked for one has
 * none.
 *
 * `<userData>/workspaces/workspaces.json`, written through `writeFileAtomic`, so
 * a crash mid-save leaves the last whole file rather than a truncated one that
 * reads as "no workspaces" — which would orphan real folders holding someone's
 * uncommitted work, with nothing left that knows where they are.
 *
 * One record per task. A removed workspace keeps its record (state `removed`,
 * with the branch it left behind) until the task asks for a new one, so the task
 * can still say where its work went.
 */

import { existsSync, mkdirSync, readFileSync, renameSync } from 'node:fs'
import { dirname } from 'node:path'
import type { TaskWorkspace, TaskWorkspaceState } from '../../shared/agent-stack'
import { writeFileAtomic } from '../atomic-write'

export interface WorkspaceRecord extends TaskWorkspace {
  /** The project folder the task named, real path. */
  project: string
  /** The commit it was made from. */
  base: string
  /** In words: why it is `kept`, or what removing it left behind. Null while `active`. */
  reason: string | null
  updatedAt: number
}

/** A task that asked for a workspace and runs in its project folder instead, and why. */
export interface WorkspaceRefusal {
  taskId: string
  project: string
  reason: string
  at: number
}

interface StoredFile {
  v: 1
  workspaces: WorkspaceRecord[]
  refused: WorkspaceRefusal[]
}

/** Removed records kept for the tasks they belonged to; the oldest go first. */
export const MAX_REMOVED = 200

/** Refusals kept; the oldest go first. */
export const MAX_REFUSED = 200

const STATES: readonly TaskWorkspaceState[] = ['active', 'kept', 'removed']

function isString(value: unknown): value is string {
  return typeof value === 'string'
}

function recordOf(value: unknown): WorkspaceRecord | null {
  if (typeof value !== 'object' || value === null) return null
  const r = value as Record<string, unknown>
  if (![r.taskId, r.repo, r.path, r.branch, r.project, r.base].every(isString)) return null
  if (typeof r.createdAt !== 'number' || !STATES.includes(r.state as TaskWorkspaceState)) return null
  return {
    taskId: r.taskId as string,
    repo: r.repo as string,
    path: r.path as string,
    branch: r.branch as string,
    project: r.project as string,
    base: r.base as string,
    createdAt: r.createdAt,
    state: r.state as TaskWorkspaceState,
    reason: isString(r.reason) ? r.reason : null,
    updatedAt: typeof r.updatedAt === 'number' ? r.updatedAt : r.createdAt,
  }
}

function refusalOf(value: unknown): WorkspaceRefusal | null {
  if (typeof value !== 'object' || value === null) return null
  const r = value as Record<string, unknown>
  if (!isString(r.taskId) || !isString(r.project) || !isString(r.reason) || typeof r.at !== 'number') return null
  return { taskId: r.taskId, project: r.project, reason: r.reason, at: r.at }
}

export class WorkspaceStore {
  private readonly workspaces = new Map<string, WorkspaceRecord>()
  private readonly refused = new Map<string, WorkspaceRefusal>()

  constructor(private readonly file: string) {
    this.load()
  }

  /**
   * An unreadable file is moved aside, never written over: its records are the
   * only map to folders that may hold work, and a person can still read it.
   */
  private load(): void {
    if (!existsSync(this.file)) return
    let parsed: unknown
    try {
      parsed = JSON.parse(readFileSync(this.file, 'utf8'))
    } catch (error) {
      console.error('[workspaces] could not read the records; moved aside:', error)
      try {
        renameSync(this.file, `${this.file}.unreadable-${Date.now()}`)
      } catch {
        /* it stays where it is, and the next save replaces it */
      }
      return
    }
    const stored = parsed as Partial<StoredFile> | null
    for (const value of Array.isArray(stored?.workspaces) ? stored.workspaces : []) {
      const record = recordOf(value)
      if (record !== null) this.workspaces.set(record.taskId, record)
    }
    for (const value of Array.isArray(stored?.refused) ? stored.refused : []) {
      const refusal = refusalOf(value)
      if (refusal !== null) this.refused.set(refusal.taskId, refusal)
    }
  }

  private persist(): void {
    mkdirSync(dirname(this.file), { recursive: true })
    const removed = [...this.workspaces.values()].filter((one) => one.state === 'removed').sort((a, b) => a.updatedAt - b.updatedAt)
    for (const old of removed.slice(0, Math.max(0, removed.length - MAX_REMOVED))) this.workspaces.delete(old.taskId)
    const refused = [...this.refused.values()].sort((a, b) => a.at - b.at)
    for (const old of refused.slice(0, Math.max(0, refused.length - MAX_REFUSED))) this.refused.delete(old.taskId)
    const file: StoredFile = { v: 1, workspaces: [...this.workspaces.values()], refused: [...this.refused.values()] }
    writeFileAtomic(this.file, `${JSON.stringify(file, null, 2)}\n`)
  }

  get(taskId: string): WorkspaceRecord | null {
    const found = this.workspaces.get(taskId)
    return found === undefined ? null : { ...found }
  }

  all(): WorkspaceRecord[] {
    return [...this.workspaces.values()].map((one) => ({ ...one }))
  }

  /** Save a task's workspace; a task that has one is no longer refused. */
  put(record: WorkspaceRecord): void {
    this.workspaces.set(record.taskId, { ...record })
    this.refused.delete(record.taskId)
    this.persist()
  }

  refusal(taskId: string): WorkspaceRefusal | null {
    const found = this.refused.get(taskId)
    return found === undefined ? null : { ...found }
  }

  refuse(refusal: WorkspaceRefusal): void {
    this.refused.set(refusal.taskId, { ...refusal })
    this.persist()
  }

  clearRefusal(taskId: string): void {
    if (this.refused.delete(taskId)) this.persist()
  }
}
