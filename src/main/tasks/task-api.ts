/**
 * The task API a CRM talks to: the same seven operations whichever road the
 * request came by — a web request on this Mac (`task-http.ts`) or an MCP tool
 * call through the relay (`task-tools.ts`).
 *
 * ## The CRM is the task master
 *
 * A task exists here because the CRM created or assigned it, and it is
 * assigned to whoever the CRM says. This app adds nothing to that: it accepts
 * work for Hoot and for the agents mapped on the connection, refuses work for
 * anybody else (`not_mine` — Dot, a colleague, an identity it does not know),
 * and reports back. A status the CRM sets is recorded and never starts or stops
 * a run; only an assignment does, or a reply addressed to the agent.
 *
 * ## Checked before anything runs
 *
 *  1. The access key is valid (the road checked it) and its connection is on.
 *  2. The sender is on the connection's allowed list. Only those CRM users can
 *     give these agents work, mention them, reply or cancel — enforced here, so
 *     a CRM that showed the agents to somebody else still could not use them.
 *     The one other sender accepted is Hoot itself, for a child task it asked
 *     for under a task an allowed sender gave it.
 *  3. The project folder is one the connection allows, resolved first.
 *  4. The hand-off limit for the task tree is not reached.
 *
 * ## Once each, and no loops
 *
 * Every changing request carries the CRM's own event id; the answer to an id
 * already seen is given again and nothing happens twice. A comment written by
 * one of this app's own identities — or carrying an id this app posted — is
 * ignored, whatever it mentions, so an agent's comment can never assign work.
 * A refusal is not remembered: once the owner fixes the setting, the same
 * request goes through.
 */

import type { TaskConfig, CrmConnection } from './task-config'
import { folderAllowed } from './task-config'
import type { TaskEngine } from './task-engine'
import type { TaskAssignee, TaskRecord, TaskStore } from './task-store'
import { TaskStore as Store } from './task-store'

export const MAX_TITLE = 300
export const MAX_INSTRUCTIONS = 20_000
export const MAX_ID = 200
export const MAX_COMMENT = 20_000

export type ApiCode =
  | 'disabled'
  | 'not_allowed'
  | 'not_mine'
  | 'not_found'
  | 'bad_request'
  | 'folder_not_allowed'
  | 'too_many_hops'

export type ApiAnswer = { ok: true; value: Record<string, unknown> } | { ok: false; code: ApiCode; message: string }

/** What a CRM reads about one task. */
export interface TaskSnapshot {
  externalTaskId: string
  originExternalTaskId: string
  assignee: string
  agent: string
  crmStatus: string
  /** Terminal Deck's own: queued, running or exited. Never a CRM status. */
  process: TaskRecord['process']
  keptOpenUntil: string | null
  finished: boolean
  verified: boolean | null
  updatedAt: string
}

export interface TaskApiDeps {
  config: TaskConfig
  store: TaskStore
  engine: Pick<TaskEngine, 'accept' | 'reply' | 'cancel' | 'reassign'>
  now?: () => number
  /** Told after a request changed something the board shows. */
  onChange?(): void
}

class Bad extends Error {
  constructor(
    readonly code: ApiCode,
    message: string,
  ) {
    super(message)
  }
}

function record(raw: unknown): Record<string, unknown> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) throw new Bad('bad_request', 'The request has to be a JSON object.')
  return raw as Record<string, unknown>
}

function str(input: Record<string, unknown>, field: string, max: number): string {
  const value = input[field]
  if (typeof value !== 'string' || value.trim() === '') throw new Bad('bad_request', `${field} is required.`)
  if (value.length > max) throw new Bad('bad_request', `${field} is longer than ${max} characters.`)
  return value.trim()
}

function optStr(input: Record<string, unknown>, field: string, max: number): string | null {
  const value = input[field]
  if (value === undefined || value === null || value === '') return null
  return str(input, field, max)
}

function idList(input: Record<string, unknown>, field: string): string[] {
  const value = input[field]
  if (value === undefined || value === null) return []
  if (!Array.isArray(value)) throw new Bad('bad_request', `${field} has to be a list.`)
  return value.filter((entry): entry is string => typeof entry === 'string' && entry !== '' && entry.length <= MAX_ID)
}

export class TaskApi {
  private readonly now: () => number

  constructor(private readonly deps: TaskApiDeps) {
    this.now = deps.now ?? Date.now
  }

  /* ------------------------------------------------------- operations -- */

  async create(keyId: string, raw: unknown): Promise<ApiAnswer> {
    return this.once(keyId, raw, async (connection, input) => {
      const externalTaskId = str(input, 'externalTaskId', MAX_ID)
      const requestedBy = str(input, 'requestedBy', MAX_ID)
      const assignee = this.assigneeOf(connection, str(input, 'assignee', MAX_ID))
      const parentId = optStr(input, 'parentExternalTaskId', MAX_ID)
      const parent = parentId === null ? null : this.deps.store.get(keyId, parentId)
      if (parentId !== null && parent === null) throw new Bad('not_found', `There is no task ${parentId} here to be a parent.`)
      this.sender(connection, requestedBy, parent)

      const existing = this.deps.store.get(keyId, externalTaskId)
      if (existing !== null) {
        // The same task sent again under a new event id: what it is, not a second one.
        if (existing.assignee.identity !== assignee.identity) await this.deps.engine.reassign(existing, assignee)
        return { outcome: 'accepted', task: this.snapshot(existing) }
      }

      const hops = parent === null ? 0 : parent.hops + 1
      if (hops > connection.maxHops) {
        throw new Bad('too_many_hops', `This task tree has reached its limit of ${connection.maxHops} hand-offs.`)
      }
      const project = optStr(input, 'project', 1024) ?? parent?.project ?? null
      if (project === null) throw new Bad('bad_request', 'project is required.')
      if (!folderAllowed(connection, project)) {
        throw new Bad('folder_not_allowed', `${project} is not a folder this connection allows work in.`)
      }
      const status = optStr(input, 'status', 60)
      const now = this.now()
      const task: TaskRecord = {
        id: Store.idOf(keyId, externalTaskId),
        keyId,
        externalTaskId,
        originExternalTaskId: parent?.originExternalTaskId ?? externalTaskId,
        externalThreadId: optStr(input, 'externalThreadId', MAX_ID) ?? parent?.externalThreadId ?? null,
        parentExternalTaskId: parentId,
        title: str(input, 'title', MAX_TITLE),
        instructions: optStr(input, 'instructions', MAX_INSTRUCTIONS) ?? '',
        project,
        assignee,
        mainAssignee: optStr(input, 'mainAssignee', MAX_ID) ?? assignee.identity,
        creator: optStr(input, 'creator', MAX_ID),
        requestedBy,
        crmStatus: status !== null && connection.statuses.statuses.includes(status) ? status : connection.statuses.initial,
        process: 'queued',
        sessionId: null,
        conversationId: null,
        runStartedAt: null,
        keepOpenUntil: null,
        hops,
        result: null,
        questionOpen: false,
        lastTurn: null,
        childrenTold: null,
        stopped: false,
        seq: 0,
        createdAt: now,
        updatedAt: now,
      }
      this.deps.store.put(task)
      await this.deps.engine.accept(task)
      return { outcome: 'accepted', task: this.snapshot(task) }
    })
  }

  async assign(keyId: string, raw: unknown): Promise<ApiAnswer> {
    return this.once(keyId, raw, async (connection, input) => {
      const task = this.task(keyId, input)
      this.sender(connection, str(input, 'requestedBy', MAX_ID), null)
      const wanted = str(input, 'assignee', MAX_ID)
      const mine = this.tryAssignee(connection, wanted)
      if (mine === null) {
        // Given to somebody who is not one of ours: whatever runs here stops.
        if (!task.stopped) await this.deps.engine.cancel(task, 'it was assigned to somebody else in the CRM.')
        return { outcome: 'released', task: this.snapshot(task) }
      }
      if (mine.identity !== task.assignee.identity || task.stopped) await this.deps.engine.reassign(task, mine)
      return { outcome: 'accepted', task: this.snapshot(task) }
    })
  }

  read(keyId: string, raw: unknown): ApiAnswer {
    return this.plain(keyId, raw, (_connection, input) => ({ task: this.snapshot(this.task(keyId, input)) }))
  }

  result(keyId: string, raw: unknown): ApiAnswer {
    return this.plain(keyId, raw, (_connection, input) => {
      const task = this.task(keyId, input)
      return {
        externalTaskId: task.externalTaskId,
        finished: task.result !== null,
        verified: task.result?.verified ?? null,
        answer: task.result?.answer ?? null,
        check: task.result?.check ?? null,
        crmStatus: task.crmStatus,
      }
    })
  }

  async cancel(keyId: string, raw: unknown): Promise<ApiAnswer> {
    return this.once(keyId, raw, async (connection, input) => {
      const task = this.task(keyId, input)
      this.sender(connection, str(input, 'requestedBy', MAX_ID), null)
      const reason = optStr(input, 'reason', 500)
      if (!task.stopped) await this.deps.engine.cancel(task, reason === null ? 'cancelled in the CRM.' : `cancelled in the CRM: ${reason}`)
      return { outcome: 'cancelled', task: this.snapshot(task) }
    })
  }

  /** A comment on a task. Reaches the agent only when it is addressed to it, from an allowed sender. */
  async comment(keyId: string, raw: unknown): Promise<ApiAnswer> {
    return this.once(keyId, raw, async (connection, input) => {
      const author = str(input, 'author', MAX_ID)
      const commentId = optStr(input, 'externalCommentId', MAX_ID)
      const body = str(input, 'body', MAX_COMMENT)
      // Our own, whatever it says: an agent's comment never assigns or answers anything.
      if (this.ownIdentity(connection, author) || this.deps.store.isOurs(keyId, commentId)) {
        return { outcome: 'ignored_own_agent' }
      }
      if (commentId !== null) {
        const before = this.deps.store.answered(keyId, `comment:${commentId}`)
        if (before !== undefined) return before as Record<string, unknown>
      }
      if (!connection.allowedSenders.includes(author)) return { outcome: 'ignored_not_allowed' }
      const task = this.deps.store.get(keyId, str(input, 'externalTaskId', MAX_ID))
      if (task === null) return { outcome: 'ignored_not_ours' }
      const mentions = idList(input, 'mentions')
      const inReplyTo = optStr(input, 'inReplyTo', MAX_ID)
      const addressed =
        mentions.includes(task.assignee.identity) || this.deps.store.isOurs(keyId, inReplyTo) || task.questionOpen
      if (!addressed || task.stopped) return { outcome: 'ignored_not_addressed' }
      await this.deps.engine.reply(task, body)
      const answer = { outcome: 'answered', task: this.snapshot(task) }
      if (commentId !== null) this.deps.store.remember(keyId, `comment:${commentId}`, answer)
      return answer
    })
  }

  /** The CRM says a status changed. Recorded; never starts or stops work. */
  async status(keyId: string, raw: unknown): Promise<ApiAnswer> {
    return this.once(keyId, raw, async (connection, input) => {
      const task = this.task(keyId, input)
      const status = str(input, 'status', 60)
      const changedBy = optStr(input, 'changedBy', MAX_ID)
      if (changedBy !== null && this.ownIdentity(connection, changedBy)) return { outcome: 'ignored_own_agent' }
      if (!connection.statuses.statuses.includes(status)) {
        throw new Bad('bad_request', `${status} is not one of: ${connection.statuses.statuses.join(', ')}.`)
      }
      this.deps.store.update(task, { crmStatus: status })
      return { outcome: 'recorded', task: this.snapshot(task) }
    })
  }

  /* ----------------------------------------------------------- checks -- */

  /** A changing request: the connection, the event id, the answer given once. */
  private async once(
    keyId: string,
    raw: unknown,
    work: (connection: CrmConnection, input: Record<string, unknown>) => Promise<Record<string, unknown>>,
  ): Promise<ApiAnswer> {
    try {
      const connection = this.connection(keyId)
      const input = record(raw)
      const eventId = str(input, 'eventId', MAX_ID)
      const before = this.deps.store.answered(keyId, eventId)
      if (before !== undefined) return { ok: true, value: { ...(before as Record<string, unknown>), duplicate: true } }
      const value = await work(connection, input)
      this.deps.store.remember(keyId, eventId, value)
      this.changed()
      return { ok: true, value }
    } catch (error) {
      if (error instanceof Bad) return { ok: false, code: error.code, message: error.message }
      throw error
    }
  }

  /** A read: the connection, nothing remembered. */
  private plain(
    keyId: string,
    raw: unknown,
    work: (connection: CrmConnection, input: Record<string, unknown>) => Record<string, unknown>,
  ): ApiAnswer {
    try {
      return { ok: true, value: work(this.connection(keyId), record(raw)) }
    } catch (error) {
      if (error instanceof Bad) return { ok: false, code: error.code, message: error.message }
      throw error
    }
  }

  private changed(): void {
    try {
      this.deps.onChange?.()
    } catch (error) {
      console.error('[tasks] a change listener threw:', error)
    }
  }

  private connection(keyId: string): CrmConnection {
    const connection = this.deps.config.connection(keyId)
    if (connection === null || !connection.enabled) {
      throw new Bad('disabled', 'Tasks are switched off for this connection in Terminal Deck.')
    }
    return connection
  }

  /**
   * Only an allowed sender — or Hoot, for a child task it asked for under a
   * task an allowed sender gave it.
   */
  private sender(connection: CrmConnection, who: string, parent: TaskRecord | null): void {
    if (connection.allowedSenders.includes(who)) return
    if (
      parent !== null &&
      connection.hootIdentity !== null &&
      who === connection.hootIdentity &&
      parent.assignee.kind === 'hoot' &&
      this.rootRequestedByAllowed(connection, parent)
    ) {
      return
    }
    throw new Bad('not_allowed', 'That CRM user is not allowed to give these agents work.')
  }

  private rootRequestedByAllowed(connection: CrmConnection, task: TaskRecord): boolean {
    let current: TaskRecord | null = task
    for (let depth = 0; current !== null && depth <= connection.maxHops + 1; depth += 1) {
      if (current.parentExternalTaskId === null) return connection.allowedSenders.includes(current.requestedBy)
      current = this.deps.store.get(current.keyId, current.parentExternalTaskId)
    }
    return false
  }

  private tryAssignee(connection: CrmConnection, identity: string): TaskAssignee | null {
    if (connection.hootIdentity !== null && identity === connection.hootIdentity) {
      return { kind: 'hoot', agentId: 'hoot', identity }
    }
    const agentId = connection.identities[identity]
    if (agentId !== undefined && this.deps.config.agent(agentId) !== null) return { kind: 'agent', agentId, identity }
    return null
  }

  private assigneeOf(connection: CrmConnection, identity: string): TaskAssignee {
    const assignee = this.tryAssignee(connection, identity)
    if (assignee === null) {
      throw new Bad('not_mine', 'That assignee is not Hoot or one of the agents on this Terminal Deck.')
    }
    return assignee
  }

  private ownIdentity(connection: CrmConnection, identity: string): boolean {
    return identity === connection.hootIdentity || identity in connection.identities
  }

  private task(keyId: string, input: Record<string, unknown>): TaskRecord {
    const externalTaskId = str(input, 'externalTaskId', MAX_ID)
    const task = this.deps.store.get(keyId, externalTaskId)
    if (task === null) throw new Bad('not_found', `There is no task ${externalTaskId} here.`)
    return task
  }

  private snapshot(task: TaskRecord): TaskSnapshot {
    const agent = task.assignee.kind === 'hoot' ? 'Hoot' : (this.deps.config.agent(task.assignee.agentId)?.name ?? task.assignee.agentId)
    return {
      externalTaskId: task.externalTaskId,
      originExternalTaskId: task.originExternalTaskId,
      assignee: task.assignee.identity,
      agent,
      crmStatus: task.crmStatus,
      process: task.process,
      keptOpenUntil: task.keepOpenUntil === null ? null : new Date(task.keepOpenUntil).toISOString(),
      finished: task.result !== null,
      verified: task.result?.verified ?? null,
      updatedAt: new Date(task.updatedAt).toISOString(),
    }
  }
}
