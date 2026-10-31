/**
 * What Terminal Deck remembers about each CRM task it is working on, and every
 * request it has already answered.
 *
 * ## An execution record, never a second task list
 *
 * The CRM owns whether a task exists, who it is assigned to and its status.
 * This keeps only what running it needs: which session holds it, the agent's
 * conversation id for an exact resume, when a kept-open session closes, the
 * result, and the last status this app knows the CRM has. Keyed by the CRM's
 * own task id within one connection, so the CRM's id is what every event and
 * comment carries back.
 *
 * ## The claim
 *
 * A task is held by at most one session. {@link TaskStore.claim} is the only way
 * to take it: it succeeds only when nothing holds the task, or what held it is
 * gone. One process, so a check-and-set in one synchronous call is atomic — the
 * same compare-and-set Paperclip does in one SQL UPDATE, without the database.
 *
 * ## Requests answered once
 *
 * Every request a CRM sends carries its own event id. The answer to each is
 * kept for {@link SEEN_MAX_AGE_MS}, so a retried request gets the same answer
 * and changes nothing, however many times it arrives or across a restart.
 * Comment ids the CRM gave back for comments this app posted are kept the same
 * way, so a comment that echoes back is recognised as our own.
 *
 * `<userData>/remote/tasks.json`, 0600 and atomic: it holds task instructions
 * and agents' answers.
 */

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from '../remote/secret-file'
import type { LocalTaskDetailData } from './task-detail-local'

export const TASKS_FILE = 'tasks.json'

/** How long an answered request, or a comment id of ours, is remembered. */
export const SEEN_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

/** Most remembered answers; the oldest go first. */
export const MAX_SEEN = 5_000

/**
 * Most CRM task records kept; finished ones go first, oldest first. Your own
 * tasks (`local`) are never dropped to make room — nor anything in the Trash.
 */
export const MAX_TASKS = 500

/** Terminal Deck's own states. Never sent to a CRM as a task status. `idle`: with nobody's session — you, or nobody. */
export type ProcessState = 'queued' | 'running' | 'exited' | 'idle'

/**
 * The connection a task made here, with no CRM, belongs to. Its ids start
 * `local:`, its statuses are {@link LOCAL_STATUSES}, and everything a CRM would
 * be told is kept on the task itself as {@link TaskNote}s instead.
 */
export const LOCAL_KEY = 'local'

/** The person at this Mac, as an assignee. */
export const ME = 'me'

export interface TaskAssignee {
  /** `human`: you. `none`: nobody yet. */
  kind: 'hoot' | 'agent' | 'human' | 'none'
  /** The agent's id, `hoot`, `me`, or `none`. */
  agentId: string
  /** The CRM identity this was assigned to; for a local task the same as `agentId`. */
  identity: string
}

export const UNASSIGNED: TaskAssignee = Object.freeze({ kind: 'none', agentId: 'none', identity: 'none' }) as TaskAssignee
export const TO_ME: TaskAssignee = Object.freeze({ kind: 'human', agentId: ME, identity: ME }) as TaskAssignee

/** The CRM's four priorities, highest last here and first on screen. */
export const PRIORITIES = ['Low', 'Medium', 'High', 'Critical'] as const
export type TaskPriority = (typeof PRIORITIES)[number]

/** One line of a local task's own record: what an agent, Hoot or you said or did. */
export interface TaskNote {
  at: number
  /** `me`, `hoot`, or an agent's id. */
  by: string
  kind: 'progress' | 'blocker' | 'question' | 'completion' | 'status' | 'assigned' | 'edited' | 'reply'
  text: string
}

/** Most notes kept on one task; the oldest go first. */
export const MAX_NOTES = 100

/** Why a task's worker stopped moving: it went quiet, or its session ended before the work was done. */
export interface TaskStall {
  at: number
  reason: 'quiet' | 'exited'
  /** One sentence, as the task's record and Hoot were told it. */
  text: string
}

export interface TaskResult {
  at: number
  /** Passed its check command, or Hoot said so. Only a verified result sets the completed status. */
  verified: boolean
  answer: string | null
  /** The last lines of a failed check. */
  check: string | null
}

export interface TaskRecord {
  /** `<keyId>:<externalTaskId>`. */
  id: string
  keyId: string
  externalTaskId: string
  /** Where comments go: the task the work was first asked for on. */
  originExternalTaskId: string
  externalThreadId: string | null
  parentExternalTaskId: string | null
  title: string
  instructions: string
  project: string
  assignee: TaskAssignee
  /** CRM identities allowed to change its status, as the CRM said. */
  mainAssignee: string | null
  creator: string | null
  requestedBy: string
  /** The last status this app knows the CRM has. */
  crmStatus: string
  process: ProcessState
  /** The session holding it — the claim. Null when nothing does. */
  sessionId: string | null
  /** The agent's own conversation id, for resuming exactly this conversation. */
  conversationId: string | null
  runStartedAt: number | null
  /** When the finished session is closed. Null while running, or when none is open. */
  keepOpenUntil: number | null
  /** Agent-to-agent hand-offs on this tree so far. */
  hops: number
  result: TaskResult | null
  /** An agent asked something and nobody has answered: a reply reaches it without a mention. */
  questionOpen: boolean
  /** The last finished turn handled, so one turn is never handled twice. */
  lastTurn: string | null
  /** Which finished children Hoot was last told about, so it is told once per set. */
  childrenTold: string | null
  /** Set when the CRM cancelled it or took it away from this app's agents. */
  stopped: boolean
  /** Next outgoing event's sequence number. */
  seq: number
  /** Made here with no CRM. Absent on records from before local tasks. */
  local?: boolean
  /** A local task's own record. */
  notes?: TaskNote[]
  /** The agent that handed this task to you, so a reply goes back to it in its own conversation. */
  handedFrom?: string | null
  /*
   * The CRM's own task fields (the reference CRM's task table), for tasks made here. Each
   * is optional so records from before them still read.
   */
  priority?: TaskPriority | null
  /** "YYYY-MM-DD" on this Mac's calendar. */
  startDate?: string | null
  dueDate?: string | null
  /** "HH:MM", this Mac's time of day. */
  startTime?: string | null
  dueTime?: string | null
  labels?: string[]
  /** A board, or category, of your own naming — the CRM's `board` without its fixed list. Null: none. */
  board?: string | null
  taskType?: 'task' | 'milestone'
  estimateMinutes?: number | null
  /** Epoch ms; set while archived. */
  archivedAt?: number | null
  /** Epoch ms; set while in the Trash (a local task deleted, merged or made a subtask). */
  deletedAt?: number | null
  /** Epoch ms; set while Done, as the CRM's `completed_at`. */
  completedAt?: number | null
  /** Your own order in the Today group; lowest first. */
  position?: number | null
  /** How often it comes back — the reference CRM's frequency word (`daily`, `weekly`…); null or absent: a one-off. */
  recurrence?: string | null
  /** What the task popup adds to a local task: subtasks, checklists, files, fields, comments, time and more. */
  detail?: LocalTaskDetailData
  /** The goal a local task serves (`goal-store.ts`); null or absent: none. */
  goalId?: string | null
  /**
   * A local task asked to run in a workspace of its own (a git worktree), so
   * agents on one project do not share a checkout. Read by the workspace part
   * when an agent starts; once a task has a workspace it keeps using it.
   */
  useWorkspace?: boolean
  /**
   * Set when its worker went quiet without finishing, or ended without
   * finishing (`TaskEngine`'s stall check). Cleared when the worker works again
   * or the task is started again.
   */
  stalled?: TaskStall | null
  /** The last time it was tried again with the same agent and brief, and what that try was told. */
  retry?: { note: string; at: number; count: number } | null
  createdAt: number
  updatedAt: number
}

/** One remembered answer. */
interface Seen {
  at: number
  answer: unknown
}

interface StoredFile {
  v: 1
  tasks: TaskRecord[]
  /** Deleted local tasks, kept whole until restored — never purged. Absent in files from before the Trash. */
  trash?: TaskRecord[]
  seen: Array<[string, Seen]>
  ours: Array<[string, number]>
}

export interface TaskStoreOptions {
  dir: string | null
  now?: () => number
}

export class TaskStore {
  private tasks = new Map<string, TaskRecord>()
  /** The Trash: out of every list and lookup, kept whole, never pruned. */
  private trashed = new Map<string, TaskRecord>()
  private seen = new Map<string, Seen>()
  /** Comment ids and event ids this app posted, per connection: `<keyId>:<id>`. */
  private ours = new Map<string, number>()
  private saveQueued = false
  private readonly now: () => number

  constructor(private readonly options: TaskStoreOptions) {
    this.now = options.now ?? Date.now
    this.load()
    this.prune()
  }

  static idOf(keyId: string, externalTaskId: string): string {
    return `${keyId}:${externalTaskId}`
  }

  get(keyId: string, externalTaskId: string): TaskRecord | null {
    return this.tasks.get(TaskStore.idOf(keyId, externalTaskId)) ?? null
  }

  byId(id: string): TaskRecord | null {
    return this.tasks.get(id) ?? null
  }

  bySession(sessionId: string): TaskRecord | null {
    for (const task of this.tasks.values()) if (task.sessionId === sessionId) return task
    return null
  }

  all(): TaskRecord[] {
    return [...this.tasks.values()]
  }

  children(keyId: string, parentExternalTaskId: string): TaskRecord[] {
    return this.all().filter((task) => task.keyId === keyId && task.parentExternalTaskId === parentExternalTaskId)
  }

  put(task: TaskRecord): void {
    task.updatedAt = this.now()
    this.tasks.set(task.id, task)
    this.prune()
    this.save()
  }

  /** Into the Trash: out of every list and lookup, kept whole — files, notes and all — until restored. */
  trash(id: string): TaskRecord | null {
    const task = this.tasks.get(id)
    if (task === undefined) return null
    this.tasks.delete(id)
    task.deletedAt = this.now()
    task.updatedAt = task.deletedAt
    this.trashed.set(id, task)
    this.save()
    return task
  }

  /** Out of the Trash, as it went in. */
  restore(id: string): TaskRecord | null {
    const task = this.trashed.get(id)
    if (task === undefined || this.tasks.has(id)) return null
    this.trashed.delete(id)
    task.deletedAt = null
    task.updatedAt = this.now()
    this.tasks.set(id, task)
    this.save()
    return task
  }

  /** What is in the Trash. */
  inTrash(): TaskRecord[] {
    return [...this.trashed.values()]
  }

  trashedById(id: string): TaskRecord | null {
    return this.trashed.get(id) ?? null
  }

  /** Forget a task altogether. */
  remove(id: string): boolean {
    const had = this.tasks.delete(id)
    if (had) this.save()
    return had
  }

  /** Add one line to a task's own record. */
  note(task: TaskRecord, note: Omit<TaskNote, 'at'>): void {
    const notes = [...(task.notes ?? []), { ...note, at: this.now() }].slice(-MAX_NOTES)
    this.update(task, { notes })
  }

  /** Change a task and keep it. */
  update(task: TaskRecord, change: Partial<TaskRecord>): TaskRecord {
    Object.assign(task, change, { updatedAt: this.now() })
    this.save()
    return task
  }

  /**
   * Take a task for one session. True only when nothing holds it, or what held
   * it is gone (`alive` says no). The one way a session comes to hold a task.
   */
  claim(task: TaskRecord, sessionId: string, alive: (sessionId: string) => boolean): boolean {
    if (task.sessionId !== null && task.sessionId !== sessionId && alive(task.sessionId)) return false
    this.update(task, { sessionId, process: 'running' })
    return true
  }

  /** Let go of a task's session. Its conversation id is kept for a later exact resume. */
  release(task: TaskRecord, process: ProcessState = 'exited'): void {
    this.update(task, { sessionId: null, process, keepOpenUntil: null })
  }

  /** The next sequence number for one task's outgoing events. */
  nextSeq(task: TaskRecord): number {
    const seq = task.seq
    this.update(task, { seq: seq + 1 })
    return seq
  }

  /* ---------------------------------------------- requests answered once -- */

  /** The answer given to this request before, or undefined when it is new. */
  answered(keyId: string, eventId: string): unknown {
    return this.seen.get(`${keyId}:${eventId}`)?.answer
  }

  remember(keyId: string, eventId: string, answer: unknown): void {
    this.seen.set(`${keyId}:${eventId}`, { at: this.now(), answer })
    this.prune()
    this.save()
  }

  /** A comment or event id this app posted on this connection. */
  markOurs(keyId: string, id: string): void {
    this.ours.set(`${keyId}:${id}`, this.now())
    this.save()
  }

  isOurs(keyId: string, id: string | null | undefined): boolean {
    return typeof id === 'string' && id !== '' && this.ours.has(`${keyId}:${id}`)
  }

  /* --------------------------------------------------------- keeping -- */

  private prune(): void {
    const cutoff = this.now() - SEEN_MAX_AGE_MS
    for (const map of [this.seen, this.ours] as Array<Map<string, { at: number } | number>>) {
      for (const [key, value] of map) {
        const at = typeof value === 'number' ? value : value.at
        if (at >= cutoff && map.size <= MAX_SEEN) break
        map.delete(key)
      }
    }
    const mirrored = this.all().filter((task) => task.local !== true)
    if (mirrored.length > MAX_TASKS) {
      // CRM records only — the CRM keeps them; finished and closed ones first, oldest first; never one still holding a session.
      const idle = mirrored.filter((task) => task.sessionId === null && task.process !== 'queued').sort((a, b) => a.updatedAt - b.updatedAt)
      for (const task of idle.slice(0, mirrored.length - MAX_TASKS)) this.tasks.delete(task.id)
    }
  }

  private file(): string | null {
    return this.options.dir === null ? null : join(this.options.dir, TASKS_FILE)
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
      const state: StoredFile = { v: 1, tasks: this.all(), trash: this.inTrash(), seen: [...this.seen], ours: [...this.ours] }
      writeSecretFile(this.options.dir, file, `${JSON.stringify(state)}\n`)
    } catch (error) {
      console.error('[tasks] could not save the task records:', error)
    }
  }

  private load(): void {
    const file = this.file()
    if (file === null || !existsSync(file)) return
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8')) as Partial<StoredFile>
      if (raw.v !== 1) return
      for (const task of Array.isArray(raw.tasks) ? raw.tasks : []) {
        if (typeof task?.id === 'string' && typeof task.keyId === 'string' && typeof task.externalTaskId === 'string') {
          this.tasks.set(task.id, task)
        }
      }
      for (const task of Array.isArray(raw.trash) ? raw.trash : []) {
        if (typeof task?.id === 'string' && typeof task.keyId === 'string' && typeof task.externalTaskId === 'string' && !this.tasks.has(task.id)) {
          this.trashed.set(task.id, task)
        }
      }
      for (const entry of Array.isArray(raw.seen) ? raw.seen : []) {
        if (Array.isArray(entry) && typeof entry[0] === 'string' && typeof entry[1]?.at === 'number') {
          this.seen.set(entry[0], entry[1])
        }
      }
      for (const entry of Array.isArray(raw.ours) ? raw.ours : []) {
        if (Array.isArray(entry) && typeof entry[0] === 'string' && typeof entry[1] === 'number') {
          this.ours.set(entry[0], entry[1])
        }
      }
    } catch (error) {
      console.error('[tasks] could not read the task records; starting empty:', error)
    }
  }
}
