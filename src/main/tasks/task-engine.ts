/**
 * Running CRM tasks: on the right agent, one session each, told back to the
 * CRM on the task they came from.
 *
 * ## Who does the work
 *
 * A task assigned to one of the owner's agents starts a session with that
 * agent's coding agent, account and model, in the task's project, with the
 * task's instructions as its brief — through `sessions.start`, so the copilot's
 * own rules hold: one session per folder, at most five, never in the app's
 * state folder. A task assigned to Hoot is put to Hoot as a message in its own
 * session; Hoot hands parts to agents (`tasks_delegate`, which asks the CRM to
 * create the child task) and says when the work is right (`tasks_verify`).
 *
 * ## What it hears
 *
 * Finished turns, questions and exits come from a second `NotifyDetector`, the
 * same class that tells AI apps about their sessions — unchanged, given task
 * sessions as its only recipients. So a turn here is decided exactly as it is
 * there: by the agent's own hooks, a settled screen, and an answer newer than
 * the turn.
 *
 * ## What it tells the CRM
 *
 * Statuses are the CRM's own, from the connection: its "on start" status when
 * an agent starts (by default: Working on it), its "verified" one after a verified
 * completion (Done), its "blocked" one on a question, a failed run or a failed
 * check (Stuck). A status is sent only as an identity the CRM lets change it —
 * the task's main assignee or its creator — and never when the task is already
 * in it. Everything else is a comment, as the agent that did it, on the task
 * the work was first asked for on.
 *
 * Verified means the agent's check command passed in the project, or, when the
 * agent has none, that Hoot looked at the result and said so.
 *
 * ## Kept open, then resumed exactly
 *
 * A finished session stays open for the agent's keep-open time, so a reply
 * continues in the same context; any new work in it restarts the clock. When
 * the time is up the session is closed and the agent's conversation id is
 * kept, so a later reply resumes exactly that conversation. One timer for every
 * deadline here — keep-open and longest-run alike — armed for the earliest and
 * not at all when there is none.
 *
 * ## After a restart
 *
 * A task whose session is gone is let go, keeps its conversation, and — if it
 * had not finished — is told to the CRM as Stuck with a line saying a reply
 * continues it. Nothing is left showing as running.
 */

import { exec } from 'node:child_process'
import type { SessionMeta, SessionStatus } from '../../shared/types'
import { deliverBrief, specsDir, writeSpec } from '../deck-control/brief'
import { MAX_SEND_CHARS } from '../deck-control/catalogue'
import type { ActionRow } from '../deck-control/action-log'
import type { CallResult } from '../deck-control/control'
import { REAL_CLOCK, type HubClock, type NotificationEvent } from '../deck-control/notify-hub'
import { NotifyDetector } from '../deck-control/notify-detect'
import type { Answer } from '../deck-control/session-more-tools'
import type { DeckSurface } from '../deck-control/surface'
import { DEFAULT_MAX_HOPS, folderAllowed, LOCAL_STATUSES, type AgentProfile, type CrmConnection, type TaskConfig } from './task-config'
import { newLocalTask } from './task-local'
import type { CommentKind, TaskEventBody, TaskOutbox } from './task-outbox'
import { LOCAL_KEY, ME, TO_ME, type TaskRecord, type TaskStore } from './task-store'

/** How long a check command may take. */
export const CHECK_TIMEOUT_MS = 10 * 60 * 1000

/** How much of a check's output a blocker comment carries. */
export const CHECK_OUTPUT_CHARS = 1_500

/** How much of an answer a completion comment carries. */
export const COMMENT_ANSWER_CHARS = 3_000

export type EngineSurface = Pick<
  DeckSurface,
  | 'listSessions'
  | 'sessionScreen'
  | 'writeToSession'
  | 'transcriptsIn'
  | 'transcriptBytes'
  | 'readTranscriptFrom'
  | 'copilotRoot'
>

export interface CheckResult {
  ok: boolean
  output: string
}

export interface TaskEngineDeps {
  config: TaskConfig
  store: TaskStore
  outbox: TaskOutbox
  surface: EngineSurface
  /** Run one deck-control tool as the copilot — the same gate Hoot's own calls go through. */
  /** `options`: only the owner's enforced limits for a session a start makes. */
  call(tool: string, args: Record<string, unknown>, options?: { sessionLimits?: { deniedTools?: string[]; noSkills?: boolean } }): Promise<CallResult>
  /** Hoot's session, started if it is not running. Null when it cannot be. */
  hoot(): Promise<string | null>
  /** Run a check command in a folder. */
  check?(command: string, cwd: string): Promise<CheckResult>
  /** Type one line into a session once it is ready. `deliverBrief`, unless a test hands one in. */
  deliver?(sessionId: string, line: string): Promise<unknown>
  /** The newest thing a session's agent said. `latestAnswerOn`, unless a test hands one in. */
  answer?(meta: SessionMeta): Promise<Answer | null>
  clock?: HubClock
  onChange?(): void
  /** A local task's status was set here (an agent finished it): its routine may make the next one. */
  onLocalStatus?(taskId: string): void
}

/** The real check: a shell, in the project, with a hard limit. */
export function runCheck(command: string, cwd: string): Promise<CheckResult> {
  return new Promise((resolve) => {
    exec(command, { cwd, timeout: CHECK_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 }, (error, stdout, stderr) => {
      const output = `${stdout}${stderr}`.trim()
      resolve({ ok: error === null, output: output.slice(-CHECK_OUTPUT_CHARS) })
    })
  })
}

/**
 * The agent's own settings, as a section of its brief: standing instructions,
 * the tools it is asked to prefer or avoid, and the skills to use. Tools are a
 * request, said so in the brief itself — what the agent may do is still decided
 * by its own permission prompts.
 */
/**
 * The owner's enforced limits, as the start's options. Undefined when there are
 * none, so an agent without them is started exactly as before.
 */
export function limitsOfAgent(agent: AgentProfile): { sessionLimits: { deniedTools?: string[]; noSkills?: boolean } } | undefined {
  if (agent.blockedTools.length === 0 && !agent.skillsOff) return undefined
  return {
    sessionLimits: {
      ...(agent.blockedTools.length > 0 ? { deniedTools: [...agent.blockedTools] } : {}),
      ...(agent.skillsOff ? { noSkills: true } : {}),
    },
  }
}

export function stackOf(agent: AgentProfile): string {
  const parts: string[] = []
  if (agent.instructions !== null) parts.push(agent.instructions)
  if (agent.toolsPreferred.length > 0) parts.push(`Prefer these tools: ${agent.toolsPreferred.join(', ')}.`)
  if (agent.toolsAvoided.length > 0) parts.push(`Do not use these tools: ${agent.toolsAvoided.join(', ')}.`)
  if (agent.toolsPreferred.length > 0 || agent.toolsAvoided.length > 0) {
    parts.push('These tool choices are what the owner asked for; your own permission settings still apply.')
  }
  if (agent.skills.length > 0) parts.push(`Use these skills when they fit: ${agent.skills.join(', ')}.`)
  if (agent.blockedTools.length > 0) parts.push(`These tools are switched off for you: ${agent.blockedTools.join(', ')}.`)
  if (agent.skillsOff) parts.push('Skills are switched off for you.')
  return parts.length === 0 ? '' : `\n\n## How you work (${agent.name}, ${agent.role})\n\n${parts.join('\n\n')}`
}

function tail(text: string, max: number): string {
  const trimmed = text.trim()
  return trimmed.length <= max ? trimmed : `…${trimmed.slice(-max)}`
}

function head(text: string, max: number): string {
  const trimmed = text.trim()
  return trimmed.length <= max ? trimmed : `${trimmed.slice(0, max)}…`
}

export class TaskEngine {
  private readonly clock: HubClock
  private readonly detector: NotifyDetector
  /** Tasks being started right now, so a second pump never starts one twice. */
  private readonly starting = new Set<string>()
  /** Sessions this engine is closing on purpose; their exit is not news. */
  private readonly closing = new Set<string>()
  /** Exits already handled here, whose news from the detector is dropped. */
  private readonly quietExits = new Set<string>()
  private timer: unknown = null
  private timerAt: number | null = null
  private stopped = false

  constructor(private readonly deps: TaskEngineDeps) {
    this.clock = deps.clock ?? REAL_CLOCK
    this.detector = new NotifyDetector({
      surface: deps.surface as DeckSurface,
      // A task session's news goes to its task, and nobody else's session is one.
      starterOf: (sessionId) => {
        const task = deps.store.bySession(sessionId)
        // Still the task's session after it was handed to you: a question answered later is its.
        return task !== null && task.assignee.kind !== 'hoot' ? `key:${task.id}` : null
      },
      enqueue: (taskId, event, turn) => {
        void this.news(taskId, event, turn)
        return true
      },
      clock: this.clock,
      ...(deps.answer === undefined ? {} : { answer: deps.answer }),
    })
  }

  /* ------------------------------------------------------------ events -- */

  /** Every session's status change, from the same hook that colours the sidebar. */
  noteStatus(sessionId: string, status: SessionStatus): void {
    if (this.stopped) return
    const task = this.deps.store.bySession(sessionId)
    if (task === null) return
    // New work in a kept-open session: it is running again, and the clock waits for the next finish.
    if (status === 'working' && task.keepOpenUntil !== null) {
      this.deps.store.update(task, { keepOpenUntil: null, runStartedAt: this.clock.now() })
      this.arm()
    }
    this.detector.noteStatus(sessionId, status)
  }

  noteExit(sessionId: string, exitCode: number): void {
    if (this.stopped) return
    const task = this.deps.store.bySession(sessionId)
    if (task === null) {
      // Any session ending may free the slot a queued task is waiting for.
      if (this.hasQueued()) void this.pump()
      return
    }
    // A close asked for here is let go here, and its exit is not news; a crash is the detector's.
    if (this.closing.delete(sessionId)) {
      this.quietExits.add(sessionId)
      this.deps.store.release(task)
      this.changed()
      void this.pump()
    }
    this.detector.noteExit(sessionId, exitCode)
  }

  /* -------------------------------------------------------------- work -- */

  /** A task arrived or was assigned here: Hoot is told, an agent's waits for a slot. */
  async accept(task: TaskRecord): Promise<void> {
    if (task.assignee.kind === 'human' || task.assignee.kind === 'none') {
      // Yours, or nobody's yet: nothing to start.
      this.deps.store.update(task, { process: 'idle' })
      this.changed()
      return
    }
    if (task.assignee.kind === 'hoot') {
      this.deps.store.update(task, { process: 'running', runStartedAt: this.clock.now() })
      this.setStatus(task, this.connectionOf(task)?.statuses.onStarted ?? null)
      await this.tellHoot(task, this.hootBrief(task))
      this.changed()
      return
    }
    this.deps.store.update(task, { process: 'queued' })
    this.changed()
    await this.pump()
  }

  /** Start whatever queued work now has a slot. */
  async pump(): Promise<void> {
    if (this.stopped) return
    const queued = this.deps.store
      .all()
      .filter((task) => task.process === 'queued' && !task.stopped && task.assignee.kind === 'agent')
      .sort((a, b) => a.createdAt - b.createdAt)
    for (const task of queued) {
      if (this.starting.has(task.id)) continue
      const agent = this.deps.config.agent(task.assignee.agentId)
      if (agent === null) {
        this.block(task, 'The agent this task was assigned to no longer exists in Terminal Deck.')
        continue
      }
      if (this.working(agent.id) >= agent.maxConcurrent) continue
      if (!this.makeRoom(task.project)) continue
      await this.start(task, agent, null)
    }
  }

  /** A reply on the CRM task from an allowed sender: continue, in the same conversation. */
  async reply(task: TaskRecord, text: string): Promise<void> {
    this.deps.store.update(task, { questionOpen: false })
    // A local task an agent handed you: your reply gives it back to that agent, in its own conversation.
    if (task.local === true && task.assignee.kind !== 'agent' && task.assignee.kind !== 'hoot') {
      const back = task.handedFrom ? this.deps.config.agent(task.handedFrom) : null
      if (back === null) return
      this.deps.store.update(task, { assignee: { kind: 'agent', agentId: back.id, identity: back.id }, mainAssignee: back.id, handedFrom: null })
      this.deps.store.note(task, { by: ME, kind: 'reply', text })
    }
    if (task.assignee.kind === 'hoot') {
      await this.tellHoot(task, `Reply on CRM task ${task.id} ("${head(task.title, 80)}"): ${this.flatten(task, text)}`)
      return
    }
    const live = task.sessionId !== null && this.alive(task.sessionId)
    if (live && task.sessionId !== null) {
      const sent = await this.deps.call('sessions.send', { sessionId: task.sessionId, text: this.flatten(task, text) })
      if (sent.ok) {
        this.turnFor(task, task.sessionId)
        this.deps.store.update(task, { keepOpenUntil: null, runStartedAt: this.clock.now(), result: null })
        this.setStatus(task, this.connectionOf(task)?.statuses.onStarted ?? null)
        this.arm()
        this.changed()
        return
      }
    }
    // Closed, or the send was refused: start again, resuming its own conversation when there is one.
    const agent = this.deps.config.agent(task.assignee.agentId)
    if (agent === null) {
      this.block(task, 'The agent this task was assigned to no longer exists in Terminal Deck.')
      return
    }
    this.deps.store.update(task, { process: 'queued', result: null })
    if (this.working(agent.id) >= agent.maxConcurrent || !this.makeRoom(task.project)) {
      this.changed()
      return
    }
    await this.start(task, agent, text)
  }

  /** The CRM cancelled it, or gave it to somebody who is not one of ours. */
  async cancel(task: TaskRecord, why: string): Promise<void> {
    this.deps.store.update(task, { stopped: true, questionOpen: false })
    if (task.sessionId !== null && this.alive(task.sessionId)) await this.close(task)
    else this.deps.store.release(task)
    this.comment(task, 'progress', `Stopped: ${why}`)
    this.changed()
    await this.pump()
  }

  /** Assigned to another of ours: whatever runs stops, and the new agent gets it from the start. */
  async reassign(task: TaskRecord, assignee: TaskRecord['assignee']): Promise<void> {
    if (task.sessionId !== null && this.alive(task.sessionId)) await this.close(task)
    this.deps.store.update(task, {
      assignee,
      mainAssignee: assignee.identity,
      sessionId: null,
      conversationId: null,
      result: null,
      lastTurn: null,
      stopped: false,
      keepOpenUntil: null,
    })
    await this.accept(task)
  }

  /** Close a kept-open session now. Its conversation stays resumable. */
  closeSession(taskId: string): boolean {
    const task = this.deps.store.byId(taskId)
    if (task === null || task.sessionId === null || !this.alive(task.sessionId)) return false
    void this.close(task)
    return true
  }

  /* ---------------------------------------------------------- Hoot's half -- */

  /** Hoot asks the CRM for a child task for one of its agents. */
  delegate(
    task: TaskRecord,
    agent: AgentProfile,
    work: { title: string; instructions: string; project: string | null },
  ): { ok: true } | { ok: false; why: string } {
    const connection = this.connectionOf(task)
    if (connection === null || !connection.enabled) return { ok: false, why: 'The CRM connection is off.' }
    if (connection.hootIdentity === null) return { ok: false, why: 'Hoot has no CRM identity on this connection.' }
    const identity = Object.entries(connection.identities).find(([, agentId]) => agentId === agent.id)?.[0]
    if (identity === undefined) return { ok: false, why: `${agent.name} has no CRM identity on this connection.` }
    if (task.hops + 1 > connection.maxHops) {
      this.block(task, `Stopped handing work on: this task tree reached its limit of ${connection.maxHops} hand-offs.`, connection.hootIdentity)
      return { ok: false, why: 'The hand-off limit for this task tree is reached.' }
    }
    const project = work.project ?? task.project
    if (task.local !== true && !folderAllowed(connection, project)) {
      return { ok: false, why: `${project} is not a folder this connection allows.` }
    }
    this.send(task, {
      type: 'task.delegate_requested',
      ...this.where(task, connection.hootIdentity),
      delegate: { assignee: identity, title: work.title, instructions: work.instructions, project },
    })
    this.comment(task, 'progress', `Asked ${agent.name} to: ${head(work.title, 200)}`, connection.hootIdentity)
    return { ok: true }
  }

  /** Hoot's verdict on a finished task: verified sets the completed status, otherwise it is blocked. */
  verify(task: TaskRecord, verified: boolean, note: string): void {
    const connection = this.connectionOf(task)
    const result = task.result ?? { at: this.clock.now(), verified: false, answer: null, check: null }
    this.deps.store.update(task, { result: { ...result, verified } })
    const hoot = connection?.hootIdentity ?? task.assignee.identity
    if (verified) {
      this.comment(task, 'completion', note === '' ? 'Checked and complete.' : note, hoot)
      this.setStatus(task, connection?.statuses.onVerified ?? null)
      if (task.assignee.kind === 'hoot') this.deps.store.update(task, { process: 'exited', runStartedAt: null })
    } else {
      this.block(task, note === '' ? 'Checked: not complete yet.' : note, hoot)
    }
    this.changed()
  }

  /** Hoot or the person sets one of the CRM's own statuses. */
  setTaskStatus(task: TaskRecord, status: string): { ok: true } | { ok: false; why: string } {
    const connection = this.connectionOf(task)
    if (connection === null) return { ok: false, why: 'The CRM connection is gone.' }
    if (!connection.statuses.statuses.includes(status)) {
      return { ok: false, why: `${status} is not one of: ${connection.statuses.statuses.join(', ')}.` }
    }
    if (this.statusActor(task, connection) === null) {
      return { ok: false, why: 'None of Terminal Deck’s identities is this task’s main assignee or creator.' }
    }
    this.setStatus(task, status)
    return { ok: true }
  }

  /** A comment from Hoot or an agent, on the task the work came from. */
  postComment(task: TaskRecord, kind: CommentKind, body: string, actor?: string): void {
    this.comment(task, kind, body, actor)
  }

  /* -------------------------------------------------------------- lifecycle -- */

  /** After a restart: let go of what no longer runs, then start what waits. */
  recover(): void {
    for (const task of this.deps.store.all()) {
      if (task.sessionId === null || this.alive(task.sessionId)) continue
      const unfinished = task.result === null && !task.stopped
      this.deps.store.release(task)
      if (unfinished) {
        this.block(task, 'Terminal Deck restarted while this was running. Reply on this task to continue where it left off.')
      }
    }
    // Hoot's own tasks are not tied to a session; they keep running in Hoot's conversation.
    this.arm()
    void this.pump()
  }

  stop(): void {
    this.stopped = true
    this.detector.stop()
    if (this.timer !== null) this.clock.clearTimeout(this.timer)
    this.timer = null
    this.timerAt = null
  }

  /** Is the one timer armed? For the test that says nothing pending costs nothing. */
  armed(): boolean {
    return this.timer !== null
  }

  /* ----------------------------------------------------------------- inside -- */

  private async start(task: TaskRecord, agent: AgentProfile, reply: string | null): Promise<void> {
    if (this.starting.has(task.id)) return
    this.starting.add(task.id)
    try {
      const brief =
        reply === null || task.conversationId === null
          ? `${this.agentBrief(task, agent)}${reply === null ? '' : `\n\n## Reply on the task\n\n${reply}`}`
          : // Resumed in its own conversation: the reply, and the agent's settings as they are now.
            `A reply came in on CRM task ${task.externalTaskId} ("${task.title}"):\n\n${reply}${stackOf(agent)}`
      const started = await this.deps.call('sessions.start', {
        cwd: task.project,
        ...(agent.provider === null ? {} : { provider: agent.provider }),
        ...(agent.account === null ? {} : { account: agent.account }),
        ...(reply !== null && task.conversationId !== null ? { conversation: task.conversationId } : {}),
        brief,
        title: `crm-${task.externalTaskId}`,
      }, limitsOfAgent(agent))
      const session = (started.value as { session?: { id?: unknown } } | null)?.session
      if (!started.ok || typeof session?.id !== 'string') {
        // A busy folder or a full house waits for the next slot; anything else is a blocker.
        const error = started.error ?? ''
        if (/already have a session running in/.test(error)) {
          this.deps.store.update(task, { process: 'queued' })
          return
        }
        if (/sessions running, which is the limit/.test(error)) {
          this.deps.store.update(task, { process: 'queued' })
          this.closeOldestKeptOpen()
          return
        }
        this.block(task, `Could not start ${agent.name}: ${started.error ?? 'the session did not start'}.`)
        return
      }
      const sessionId = session.id
      if (!this.deps.store.claim(task, sessionId, (id) => this.alive(id))) {
        // Somebody else holds it: this session is not needed.
        this.closing.add(sessionId)
        await this.deps.call('sessions.stop', { sessionId })
        return
      }
      this.deps.store.update(task, {
        runStartedAt: this.clock.now(),
        keepOpenUntil: null,
        questionOpen: false,
        conversationId: this.conversationOf(sessionId) ?? task.conversationId,
      })
      this.turnFor(task, sessionId)
      // A model and an effort belong to the process, so they are set on every start — a resumed one too.
      for (const [control, value] of [
        ['model', agent.model],
        ['effort', agent.effort],
      ] as const) {
        if (value === null) continue
        const set = await this.deps.call('agents.set_control', { sessionId, control, value })
        if (!set.ok) this.comment(task, 'progress', `Could not set ${control} ${value}: ${set.error ?? 'refused'}.`)
      }
      this.setStatus(task, this.connectionOf(task)?.statuses.onStarted ?? null)
      this.comment(task, 'progress', reply === null ? `${agent.name} started on this.` : `${agent.name} is continuing with the reply.`)
      this.arm()
      this.changed()
    } finally {
      this.starting.delete(task.id)
    }
  }

  /** One piece of news from a task's session. */
  private async news(taskId: string, event: NotificationEvent, turn: string | undefined): Promise<void> {
    const task = this.deps.store.byId(taskId)
    if (task === null || task.stopped || this.stopped) return
    if (event.type === 'needs-input') {
      this.deps.store.update(task, { questionOpen: true })
      const screen = event.screen?.text ?? ''
      this.comment(task, 'question', `The agent is asking something. Reply on this task to answer.\n\n${tail(screen, 1_200)}`)
      this.setStatus(task, this.connectionOf(task)?.statuses.onBlocked ?? null)
      this.handToHuman(task)
      this.changed()
      return
    }
    if (event.type === 'exited') {
      if (this.quietExits.delete(event.sessionId)) return
      const finished = task.result !== null
      this.deps.store.release(task)
      if (!finished) this.block(task, `The session ended${event.crashed === true ? ` with exit code ${event.exitCode}` : ''} before the work was finished. Reply on this task to continue.`)
      this.changed()
      void this.pump()
      return
    }
    // A finished turn — once each.
    if (turn !== undefined && turn === task.lastTurn) return
    const answer = event.answer?.text ?? event.screen?.text ?? ''
    const conversationId = task.sessionId === null ? null : this.conversationOf(task.sessionId)
    this.deps.store.update(task, {
      lastTurn: turn ?? null,
      questionOpen: false,
      ...(conversationId === null ? {} : { conversationId }),
    })
    const agent = this.deps.config.agent(this.agentIdOf(task) ?? '')
    const connection = this.connectionOf(task)
    if (agent?.verifyCommand) {
      const check = await (this.deps.check ?? runCheck)(agent.verifyCommand, task.project)
      this.deps.store.update(task, { result: { at: this.clock.now(), verified: check.ok, answer, check: check.ok ? null : check.output } })
      if (check.ok) {
        this.comment(task, 'completion', `Finished, and the check passed.\n\n${head(answer, COMMENT_ANSWER_CHARS)}`)
        this.setStatus(task, connection?.statuses.onVerified ?? null)
      } else {
        this.block(task, `Finished, but the check failed:\n\n${check.output}`)
      }
    } else if (task.local === true) {
      // No check to run and no CRM: the person who made the task checks it.
      this.deps.store.update(task, { result: { at: this.clock.now(), verified: false, answer, check: null } })
      this.comment(task, 'completion', `Finished. Check it and mark it Done.\n\n${head(answer, COMMENT_ANSWER_CHARS)}`)
      this.handToHuman(task)
    } else {
      this.deps.store.update(task, { result: { at: this.clock.now(), verified: false, answer, check: null } })
      this.comment(task, 'completion', `Finished. Hoot is checking it.\n\n${head(answer, COMMENT_ANSWER_CHARS)}`)
      await this.tellHoot(
        task,
        `${agent?.name ?? 'An agent'} finished CRM task ${task.id} ("${head(task.title, 80)}"). Read its result with ` +
          `tasks_get, then call tasks_verify with verified true if it is right, or false with what is missing.`,
      )
    }
    this.keepOpen(task, agent)
    this.childrenDone(task)
    this.changed()
  }

  /** The finished session stays open for the agent's keep-open time, or closes now. */
  private keepOpen(task: TaskRecord, agent: AgentProfile | null): void {
    if (task.sessionId === null) return
    const minutes = agent?.keepAliveMinutes ?? 0
    if (minutes <= 0) {
      void this.close(task)
      return
    }
    this.deps.store.update(task, { keepOpenUntil: this.clock.now() + minutes * 60_000, runStartedAt: null })
    this.arm()
  }

  /** When every child of a Hoot task has finished, Hoot is told once, with each one's result. */
  private childrenDone(task: TaskRecord): void {
    if (task.parentExternalTaskId === null) return
    const parent = this.deps.store.get(task.keyId, task.parentExternalTaskId)
    if (parent === null || parent.assignee.kind !== 'hoot') return
    const children = this.deps.store.children(task.keyId, parent.externalTaskId)
    if (children.some((child) => child.result === null && !child.stopped)) return
    const digest = children.map((child) => `${child.externalTaskId}:${child.result?.verified ?? 'stopped'}`).sort().join(',')
    if (digest === parent.childrenTold) return
    this.deps.store.update(parent, { childrenTold: digest })
    const lines = children.map((child) => {
      const state = child.stopped ? 'stopped' : child.result?.verified === true ? 'verified' : 'finished, not verified'
      return `${child.externalTaskId} (${state}): ${head(child.result?.answer ?? '', 300).replace(/\s+/g, ' ')}`
    })
    void this.tellHoot(parent, `Every task you handed on for CRM task ${parent.id} has finished. ${lines.join(' | ')}`)
  }

  private async close(task: TaskRecord): Promise<void> {
    const sessionId = task.sessionId
    if (sessionId === null || this.closing.has(sessionId)) return
    this.closing.add(sessionId)
    const conversationId = this.conversationOf(sessionId)
    if (conversationId !== null) this.deps.store.update(task, { conversationId })
    const stopped = await this.deps.call('sessions.stop', { sessionId })
    if (!stopped.ok || !this.alive(sessionId)) {
      this.closing.delete(sessionId)
      this.deps.store.release(task)
      this.changed()
      void this.pump()
    }
  }

  /**
   * Make a slot for a session in this folder: a kept-open session of another
   * task there is closed early, and the task waits for it to go. A folder where
   * a task is still working is waited for. Somebody's own terminal in the
   * folder is not ours to count.
   */
  private makeRoom(folder: string): boolean {
    const holder = this.deps.store
      .all()
      .find((task) => task.project === folder && task.sessionId !== null && this.alive(task.sessionId))
    if (holder === undefined) return true
    if (holder.keepOpenUntil !== null) void this.close(holder)
    return false
  }

  /** Five sessions open: the kept-open one that finished longest ago makes way. */
  private closeOldestKeptOpen(): void {
    const oldest = this.deps.store
      .all()
      .filter((task) => task.keepOpenUntil !== null && task.sessionId !== null)
      .sort((a, b) => (a.keepOpenUntil ?? 0) - (b.keepOpenUntil ?? 0))[0]
    if (oldest !== undefined) void this.close(oldest)
  }

  private hasQueued(): boolean {
    return this.deps.store.all().some((task) => task.process === 'queued' && !task.stopped)
  }

  /**
   * This engine just started a turn in a task's session: the detector is told
   * whose it is, the way an app's send is, so the turn expects an answer and a
   * session whose transcript cannot be found still reports from its screen.
   */
  private turnFor(task: TaskRecord, sessionId: string): void {
    this.detector.noteRow({
      outcome: 'ok',
      tool: 'sessions.send',
      sessionId,
      caller: { kind: 'key', keyId: task.id },
    } as unknown as ActionRow)
  }

  /** Tasks an agent is working on right now — kept-open sessions are not working. */
  private working(agentId: string): number {
    return this.deps.store
      .all()
      .filter(
        (task) =>
          task.assignee.agentId === agentId &&
          (this.starting.has(task.id) || (task.sessionId !== null && task.keepOpenUntil === null && this.alive(task.sessionId))),
      ).length
  }

  /** The one timer: the earliest keep-open close or longest-run stop. */
  private arm(): void {
    if (this.stopped) return
    let next: number | null = null
    for (const task of this.deps.store.all()) {
      const due = this.dueAt(task)
      if (due !== null && (next === null || due < next)) next = due
    }
    if (next === this.timerAt) return
    if (this.timer !== null) this.clock.clearTimeout(this.timer)
    this.timer = null
    this.timerAt = next
    if (next === null) return
    this.timer = this.clock.setTimeout(() => {
      this.timer = null
      this.timerAt = null
      this.due()
    }, Math.max(next - this.clock.now(), 0))
  }

  private dueAt(task: TaskRecord): number | null {
    if (task.sessionId === null) return null
    if (task.keepOpenUntil !== null) return task.keepOpenUntil
    if (task.runStartedAt === null) return null
    const agent = this.deps.config.agent(this.agentIdOf(task) ?? '')
    if (agent === null || agent.maxRunMinutes === 0) return null
    return task.runStartedAt + agent.maxRunMinutes * 60_000
  }

  private due(): void {
    const now = this.clock.now()
    for (const task of this.deps.store.all()) {
      const at = this.dueAt(task)
      if (at === null || at > now) continue
      if (task.keepOpenUntil !== null) {
        // Off the clock first, so the timer is not armed for it again while it closes.
        this.deps.store.update(task, { keepOpenUntil: null })
        void this.close(task)
        continue
      }
      const minutes = this.deps.config.agent(this.agentIdOf(task) ?? '')?.maxRunMinutes ?? 0
      this.deps.store.update(task, { runStartedAt: null })
      void this.close(task)
      this.block(task, `Stopped after ${minutes} minutes, the longest this agent may run. Reply on this task to continue.`)
    }
    this.arm()
  }

  /* ----------------------------------------------------------- telling -- */

  private async tellHoot(task: TaskRecord, message: string): Promise<void> {
    const hoot = await this.deps.hoot()
    if (hoot === null) {
      this.block(task, 'Hoot is not running on this Mac, so this task is waiting for it.', this.connectionOf(task)?.hootIdentity ?? undefined)
      return
    }
    const line = message.replace(/\s*\n\s*/g, ' ')
    await (this.deps.deliver ?? ((sessionId, text) => deliverBrief(this.deps.surface, sessionId, text)))(hoot, line)
  }

  private hootBrief(task: TaskRecord): string {
    const agents = this.deps.config.agents().map((agent) => `${agent.name} (${agent.role})`)
    const spec = writeSpec(specsDir(this.deps.surface.copilotRoot()), {
      title: `crm-${task.externalTaskId}`,
      brief: `# ${task.title}\n\nCRM task ${task.externalTaskId}, in ${task.project}.\n\n${task.instructions}`,
      cwd: task.project,
      provider: null,
      callId: task.id,
      at: this.clock.now(),
    })
    return (
      `CRM task ${task.id} ("${head(task.title, 80)}") is assigned to you; its instructions are in ${spec.path}. ` +
      `Hand parts to your agents with tasks_delegate (${agents.length === 0 ? 'none are set up yet' : agents.join(', ')}), ` +
      `post updates with tasks_comment, and when it is done and right, call tasks_verify.`
    )
  }

  private agentBrief(task: TaskRecord, agent: AgentProfile): string {
    return (
      `# ${task.title}\n\n` +
      `This is CRM task ${task.externalTaskId}. Terminal Deck reports your progress and your final answer back to ` +
      `the CRM for you. End with a short summary of what you did and anything left.${stackOf(agent)}\n\n` +
      `## The task\n\n${task.instructions}`
    )
  }

  /** A reply as one printable line; a long one goes to a file the agent is told to read. */
  private flatten(task: TaskRecord, text: string): string {
    const line = text.replace(/\s*\n\s*/g, ' ').replace(/[\u0000-\u001f\u007f]/g, '').trim()
    if (line.length <= MAX_SEND_CHARS) return line
    const spec = writeSpec(specsDir(this.deps.surface.copilotRoot()), {
      title: `reply-${task.externalTaskId}`,
      brief: text,
      cwd: task.project,
      provider: null,
      callId: task.id,
      at: this.clock.now(),
    })
    return `A long reply came in on the task; read ${spec.path}.`
  }

  private block(task: TaskRecord, why: string, actor?: string): void {
    this.comment(task, 'blocker', why, actor)
    this.setStatus(task, this.connectionOf(task)?.statuses.onBlocked ?? null)
    this.handToHuman(task)
    if (task.sessionId === null && task.process !== 'exited') this.deps.store.update(task, { process: 'exited' })
    this.changed()
  }

  private comment(task: TaskRecord, kind: CommentKind, body: string, actor?: string): void {
    const who = actor ?? task.assignee.identity
    this.send(task, {
      type: 'task.comment',
      ...this.where(task, who),
      comment: { kind, body: head(body, 8_000), inReplyTo: null },
    })
  }

  /** Set one of the CRM's statuses — only as an identity it lets change it, and never to the one it has. */
  private setStatus(task: TaskRecord, status: string | null): void {
    if (status === null || status === task.crmStatus) return
    const connection = this.connectionOf(task)
    if (connection === null || !connection.statuses.statuses.includes(status)) return
    const actor = this.statusActor(task, connection)
    if (actor === null) return
    this.send(task, { type: 'task.status', ...this.where(task, actor), status })
    this.deps.store.update(task, {
      crmStatus: status,
      ...(task.local === true ? { completedAt: status === connection.statuses.completed ? this.clock.now() : null } : {}),
    })
    if (task.local === true) this.deps.onLocalStatus?.(task.id)
  }

  /**
   * A local task an agent cannot go on with is yours: assigned to you, with the
   * agent remembered so your reply goes back to it in its own conversation.
   * A CRM task is never reassigned here — the CRM is its task master.
   */
  private handToHuman(task: TaskRecord): void {
    if (task.local !== true || task.assignee.kind === 'human') return
    const from = task.assignee.kind === 'agent' ? task.assignee.agentId : (task.handedFrom ?? null)
    this.deps.store.update(task, { assignee: { ...TO_ME }, mainAssignee: ME, handedFrom: from })
    this.deps.store.note(task, { by: from ?? 'hoot', kind: 'assigned', text: 'Handed to you.' })
    this.changed()
  }

  /** The agent whose session a task is in: its assignee, or the one that handed it to you. */
  private agentIdOf(task: TaskRecord): string | null {
    return task.assignee.kind === 'agent' ? task.assignee.agentId : (task.handedFrom ?? null)
  }

  private statusActor(task: TaskRecord, connection: CrmConnection): string | null {
    if (task.local === true) return task.assignee.identity
    const allowed = [task.mainAssignee, task.creator].filter((id): id is string => id !== null)
    const candidates = [task.assignee.identity, connection.hootIdentity].filter((id): id is string => id !== null)
    return candidates.find((id) => allowed.includes(id)) ?? null
  }

  private send(task: TaskRecord, body: TaskEventBody): void {
    if (task.local === true) {
      this.keepLocally(task, body)
      return
    }
    const event = this.deps.outbox.send(task.keyId, body, this.deps.store.nextSeq(task))
    this.deps.store.markOurs(task.keyId, event.eventId)
  }

  /**
   * What a CRM would be told, for a task with no CRM: a comment becomes a line
   * of the task's own record, a status is already on the task, and a hand-off
   * Hoot asks for becomes a local child task, assigned and started here.
   */
  private keepLocally(task: TaskRecord, body: TaskEventBody): void {
    if (body.type === 'task.comment') {
      this.deps.store.note(task, { by: body.actor, kind: body.comment.kind, text: body.comment.body })
    } else if (body.type === 'task.status') {
      this.deps.store.note(task, { by: body.actor, kind: 'status', text: `Status: ${body.status}` })
    } else {
      const agent = this.deps.config.agent(body.delegate.assignee)
      if (agent === null) return
      const child = newLocalTask(
        {
          title: body.delegate.title,
          instructions: body.delegate.instructions,
          project: body.delegate.project,
          assignee: { kind: 'agent', agentId: agent.id, identity: agent.id },
          status: LOCAL_STATUSES.initial,
          parent: task,
        },
        this.clock.now(),
      )
      this.deps.store.put(child)
      void this.accept(child)
    }
  }

  private where(task: TaskRecord, actor: string): {
    externalTaskId: string
    originExternalTaskId: string
    externalThreadId: string | null
    actor: string
  } {
    return {
      externalTaskId: task.externalTaskId,
      originExternalTaskId: task.originExternalTaskId,
      externalThreadId: task.externalThreadId,
      actor,
    }
  }

  private connectionOf(task: TaskRecord): CrmConnection | null {
    if (task.local === true) return this.localConnection()
    return this.deps.config.connection(task.keyId)
  }

  /** What a local task works under: always on, its five statuses, every agent by its own id, and you. */
  private localConnection(): CrmConnection {
    return {
      keyId: LOCAL_KEY,
      name: null,
      enabled: true,
      eventsUrl: null,
      eventsSecret: null,
      statuses: LOCAL_STATUSES,
      hootIdentity: 'hoot',
      identities: Object.fromEntries(this.deps.config.agents().map((agent) => [agent.id, agent.id])),
      allowedSenders: [ME],
      folders: [],
      maxHops: DEFAULT_MAX_HOPS,
    }
  }

  private alive(sessionId: string): boolean {
    return this.deps.surface.listSessions().some((session) => session.id === sessionId && session.exitCode === null)
  }

  private conversationOf(sessionId: string): string | null {
    const meta: SessionMeta | undefined = this.deps.surface.listSessions().find((session) => session.id === sessionId)
    return meta?.agentSessionId ?? null
  }

  private changed(): void {
    try {
      this.deps.onChange?.()
    } catch (error) {
      console.error('[tasks] a change listener threw:', error)
    }
  }
}
