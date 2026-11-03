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
 *
 * ## What a worker is told
 *
 * A fresh brief carries the task and, around it, the goals it serves (root
 * first), what is already on it — subtasks, linked tasks, the latest comments
 * and notes — a note when it is being tried again, and what the project's
 * knowledge says about it (`task-brief.ts`, each part bounded). Knowledge and a
 * workspace of its own are optional seams ({@link TaskEngineDeps.knowledge},
 * {@link TaskEngineDeps.workspaces}); without them a task runs exactly as it did.
 * The task flow's moments — handed to a worker, finished, verified, rejected,
 * reassigned, stalled — are told to the knowledge seam as they happen.
 *
 * A local task blocked by another that is not Done waits in the queue, and is
 * started by the first pump after that one is.
 *
 * ## Stalled
 *
 * A worker's session that sits quiet — not working, with no finished turn and
 * no question — for {@link STALL_AFTER_MS} has stalled, and so has one that
 * ended before the work was finished. Quiet is read off the session's own status
 * changes; the deadline is one moment the task clock is aimed at
 * ({@link TaskEngine.stallDueAt}), so nothing here polls. A stalled task says so
 * on its record and in its status, is told to Hoot when Hoot is coordinating it,
 * and clears itself the moment its worker works again.
 */

import { exec } from 'node:child_process'
import type { Goal, KnowledgeProvider, TaskKnowledgeEvent, WorkspaceProvider } from '../../shared/agent-stack'
import { HOOT_ID } from '../../shared/crm/detail-contract'
import type { SessionMeta, SessionStatus } from '../../shared/types'
import { deliverBrief, specsDir, writeSpec } from '../deck-control/brief'
import { MAX_SEND_CHARS } from '../deck-control/catalogue'
import type { ActionRow } from '../deck-control/action-log'
import type { CallResult, SessionLimits } from '../deck-control/control'
import { limitsFor, stackText } from '../agents/agent-briefing'
import { delegationRefusal } from '../agents/agent-lifecycle'
import { REAL_CLOCK, type HubClock, type NotificationEvent } from '../deck-control/notify-hub'
import { NotifyDetector } from '../deck-control/notify-detect'
import type { Answer } from '../deck-control/session-more-tools'
import type { DeckSurface } from '../deck-control/surface'
import { actorNow } from './task-actor'
import { blockersOf, isDone } from './goal-progress'
import { contextSection, goalSection, retrySection } from './task-brief'
import { DEFAULT_MAX_HOPS, folderAllowed, LOCAL_STATUSES, type AgentProfile, type CrmConnection, type TaskConfig } from './task-config'
import { newLocalTask } from './task-local'
import type { CommentKind, TaskEventBody, TaskOutbox } from './task-outbox'
import { LOCAL_KEY, ME, TO_ME, type TaskRecord, type TaskStall, type TaskStore } from './task-store'

/** How long a check command may take. */
export const CHECK_TIMEOUT_MS = 10 * 60 * 1000

/**
 * How long a worker's session may sit quiet — not working, not finished, not
 * asking anything — before its task counts as stalled. Quiet, not busy: an
 * agent working flat out for an hour is the longest-run limit's business.
 */
export const STALL_AFTER_MS = 15 * 60_000

/** How much project knowledge a brief carries. */
export const KNOWLEDGE_BRIEF_CHARS = 4_000

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
  /** The goal chain for a `goalId`, that goal first (`GoalStore.chain`). Absent: briefs carry no goals. */
  goals?: { chain(goalId: string): Goal[] }
  /** Knowledge for a fresh brief, and where the task flow's events go. Absent: neither happens. */
  knowledge?: KnowledgeProvider
  /** The folder a worker runs in. Absent, or answering null: the task's project folder. */
  workspaces?: WorkspaceProvider
  /** A stall deadline moved: the task clock aims again ({@link TaskEngine.stallDueAt}). */
  onDueChange?(): void
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
 * The owner's enforced settings, as the start's options — blocked tools, skills
 * off, and the instructions file where the coding agent takes one. Undefined
 * when there are none, so an agent without them is started exactly as before.
 * What each provider can keep is `shared/agent-capabilities.ts`'s to say.
 */
export function limitsOfAgent(agent: AgentProfile): { sessionLimits: SessionLimits } | undefined {
  return limitsFor(agent)
}

/**
 * The agent's own settings, as a section of its brief: standing instructions,
 * the tools it is asked to prefer or avoid, and the skills to use. Requests are
 * said to be requests in the brief itself — what the agent may do is still
 * decided by its own permission prompts.
 */
export function stackOf(agent: AgentProfile): string {
  return stackText(agent)
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
  /** A worker's session, and since when it has not been working. Absent while it works. */
  private readonly quietSince = new Map<string, number>()
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
    this.noteActivity(task, sessionId, status)
    this.detector.noteStatus(sessionId, status)
  }

  noteExit(sessionId: string, exitCode: number): void {
    if (this.stopped) return
    if (this.quietSince.delete(sessionId)) this.deps.onDueChange?.()
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
    const all = this.deps.store.all()
    for (const task of queued) {
      if (this.starting.has(task.id)) continue
      // Waiting for a task it is blocked by: started by the first pump after that one is Done.
      if (blockersOf(task, all).length > 0) continue
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

  /**
   * Something changed somewhere in the tasks — a status, a link, a task gone to
   * the Trash: queued work may be free to start. Costs one scan when nothing is
   * queued, and starts nothing twice (`pump` holds its own guard).
   */
  nudge(): void {
    if (this.stopped || !this.hasQueued()) return
    queueMicrotask(() => void this.pump())
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
        this.deps.store.update(task, { keepOpenUntil: null, runStartedAt: this.clock.now(), result: null, stalled: null })
        // Its quiet clock starts with this turn, not with the calm after the last one.
        this.quietSince.set(task.sessionId, this.clock.now())
        this.deps.onDueChange?.()
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
    this.deps.store.update(task, { process: 'queued', result: null, stalled: null })
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
    // From one worker to another — not a first hand-out, and not to you or nobody.
    const before = this.agentIdOf(task) ?? (task.assignee.kind === 'hoot' ? 'hoot' : null)
    const worker = assignee.kind === 'agent' || assignee.kind === 'hoot'
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
      stalled: null,
      retry: null,
    })
    if (worker && before !== null && before !== assignee.agentId) {
      this.event(task, 'reassigned', { summary: `From ${this.workerName(before)} to ${this.workerName(assignee.agentId)}.` })
    }
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

  /**
   * Hoot's verdict on a finished task: verified sets the completed status,
   * otherwise it is blocked. `evidence`, when the verdict names it, goes to the
   * knowledge seam with the event.
   */
  verify(task: TaskRecord, verified: boolean, note: string, evidence: string[] = []): void {
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
    this.event(task, verified ? 'verified' : 'rejected', { summary: note, evidence })
    this.changed()
  }

  /**
   * Try a local task again: the same agent, the same brief, and a note saying
   * why — after a stall, an exit or a failed check. Whatever still runs on it
   * stops first, and it starts fresh rather than in the conversation that did
   * not get there.
   */
  async retry(task: TaskRecord, note: string): Promise<{ ok: true } | { ok: false; why: string }> {
    if (task.local !== true) return { ok: false, why: 'That is a CRM task: the CRM decides who runs it again.' }
    const agentId = this.agentIdOf(task)
    const agent = agentId === null ? null : this.deps.config.agent(agentId)
    if (agent === null) return { ok: false, why: 'No task agent has worked on this task yet. Give it to one with tasks_reassign.' }
    if (task.sessionId !== null && this.alive(task.sessionId)) await this.close(task)
    this.deps.store.update(task, {
      assignee: { kind: 'agent', agentId: agent.id, identity: agent.id },
      mainAssignee: agent.id,
      handedFrom: null,
      sessionId: null,
      result: null,
      lastTurn: null,
      stopped: false,
      keepOpenUntil: null,
      questionOpen: false,
      stalled: null,
      retry: { note: note.trim(), at: this.clock.now(), count: (task.retry?.count ?? 0) + 1 },
    })
    this.deps.store.note(task, { by: actorNow(), kind: 'progress', text: `Tried again with ${agent.name}${note.trim() === '' ? '.' : `: ${note.trim()}`}` })
    await this.accept(task)
    return { ok: true }
  }

  /**
   * A review of a finished local task. A pass has to name its evidence — files,
   * commands, output — and marks it verified and Done. A fail says what is wrong
   * and reopens it: back to the agent that did it, in its own conversation, with
   * the reasons; with no such agent, back to To-Do for somebody to pick up.
   */
  async review(
    task: TaskRecord,
    verdict: { pass: boolean; evidence: string[]; reasons: string },
  ): Promise<{ ok: true } | { ok: false; why: string }> {
    if (task.local !== true) return { ok: false, why: 'That is a CRM task: use tasks_verify for it.' }
    if (task.result === null && !isDone(task)) return { ok: false, why: 'It has not finished yet. Review it once its worker says it is done.' }
    const evidence = verdict.evidence.map((item) => item.trim()).filter((item) => item !== '')
    const reasons = verdict.reasons.trim()
    if (verdict.pass) {
      if (evidence.length === 0) return { ok: false, why: 'A pass has to name its evidence: the files, commands or output that show it is done.' }
      this.verify(task, true, `Reviewed and verified. Evidence: ${evidence.join('; ')}`, evidence)
      return { ok: true }
    }
    if (reasons === '') return { ok: false, why: 'A fail has to say what is wrong, so the worker can fix it.' }
    const result = task.result ?? { at: this.clock.now(), verified: false, answer: null, check: null }
    this.deps.store.update(task, { result: { ...result, verified: false } })
    this.comment(task, 'blocker', `Reviewed: not done yet. ${reasons}`, this.connectionOf(task)?.hootIdentity ?? undefined)
    this.event(task, 'rejected', { summary: reasons, evidence })
    const agentId = this.agentIdOf(task)
    const agent = agentId === null ? null : this.deps.config.agent(agentId)
    if (agent === null) {
      this.deps.store.update(task, { result: null })
      this.setStatus(task, LOCAL_STATUSES.initial)
      this.changed()
      return { ok: true }
    }
    // Back to its agent first, so the reply below continues its conversation rather than handing it to you.
    this.deps.store.update(task, { assignee: { kind: 'agent', agentId: agent.id, identity: agent.id }, mainAssignee: agent.id, handedFrom: null })
    const seen = evidence.length === 0 ? '' : ` What was looked at: ${evidence.join('; ')}.`
    await this.reply(task, `A review found this is not done yet: ${reasons}${seen} Fix it, then finish with a short summary of what changed.`)
    this.changed()
    return { ok: true }
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
    // A paused or archived agent takes no new work; a reply on work it already has still reaches it.
    const refused = reply === null ? delegationRefusal(agent) : null
    if (refused !== null) {
      this.block(task, refused)
      return
    }
    this.starting.add(task.id)
    try {
      const fresh = reply === null || task.conversationId === null
      const brief = fresh
        ? `${this.agentBrief(task, agent, await this.knowledgeFor(task))}${reply === null ? '' : `\n\n## Reply on the task\n\n${reply}`}`
        : // Resumed in its own conversation: the reply, and the agent's settings as they are now.
          `A reply came in on CRM task ${task.externalTaskId} ("${task.title}"):\n\n${reply}${stackOf(agent)}`
      let cwd: string
      try {
        cwd = await this.folderFor(task)
      } catch (error) {
        this.block(task, `Could not prepare the folder ${agent.name} works in: ${error instanceof Error ? error.message : String(error)}`)
        return
      }
      const started = await this.deps.call('sessions.start', {
        cwd,
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
        stalled: null,
        conversationId: this.conversationOf(sessionId) ?? task.conversationId,
      })
      // Quiet until it first works: a brief that never lands is a stall like any other.
      this.quietSince.set(sessionId, this.clock.now())
      this.deps.onDueChange?.()
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
      if (reply === null) this.event(task, 'delegated', { summary: head(task.instructions, 500) })
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
      if (!finished) {
        const why = `The session ended${event.crashed === true ? ` with exit code ${event.exitCode}` : ''} before the work was finished.`
        this.block(task, `${why} Reply on this task to continue.`)
        this.stall(task, 'exited', why, false)
      }
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
    this.event(task, 'finished', { summary: head(answer, COMMENT_ANSWER_CHARS) })
    if (agent?.verifyCommand) {
      // In the folder the work was done in — its own workspace, when it had one.
      const check = await (this.deps.check ?? runCheck)(agent.verifyCommand, this.folderOfSession(task) ?? task.project)
      this.deps.store.update(task, { result: { at: this.clock.now(), verified: check.ok, answer, check: check.ok ? null : check.output } })
      if (check.ok) {
        this.comment(task, 'completion', `Finished, and the check passed.\n\n${head(answer, COMMENT_ANSWER_CHARS)}`)
        this.setStatus(task, connection?.statuses.onVerified ?? null)
      } else {
        this.block(task, `Finished, but the check failed:\n\n${check.output}`)
      }
      this.event(task, check.ok ? 'verified' : 'rejected', {
        summary: check.ok ? `The check passed: ${agent.verifyCommand}` : check.output,
        evidence: [`check: ${agent.verifyCommand}`],
      })
    } else if (task.local === true && task.requestedBy === HOOT_ID) {
      // Hoot planned it, so Hoot reviews it: the work stays with its agent until the verdict.
      this.deps.store.update(task, { result: { at: this.clock.now(), verified: false, answer, check: null } })
      this.comment(task, 'completion', `Finished. Hoot is reviewing it.\n\n${head(answer, COMMENT_ANSWER_CHARS)}`)
      await this.tellHoot(
        task,
        `${agent?.name ?? 'An agent'} finished task ${task.id} ("${head(task.title, 80)}"). Look at what it did, then call ` +
          `tasks_review with pass and the evidence you checked, or fail with what is wrong.`,
      )
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
    const agents = this.deps.config.pickableAgents().map((agent) => `${agent.name} (${agent.role}${agent.status === 'paused' ? ', paused' : ''})`)
    const spec = writeSpec(specsDir(this.deps.surface.copilotRoot()), {
      title: `crm-${task.externalTaskId}`,
      brief: `# ${task.title}\n\nCRM task ${task.externalTaskId}, in ${task.project}.${this.goalsOf(task)}\n\n${task.instructions}`,
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

  /**
   * A fresh brief: the task, the agent's own settings, the goals it serves, what
   * is already on it, a note when it is tried again, and `knowledge` — the
   * project knowledge section, already bounded, or empty.
   */
  private agentBrief(task: TaskRecord, agent: AgentProfile, knowledge = ''): string {
    return (
      `# ${task.title}\n\n` +
      `This is CRM task ${task.externalTaskId}. Terminal Deck reports your progress and your final answer back to ` +
      `the CRM for you. End with a short summary of what you did and anything left.${stackOf(agent)}` +
      `${this.goalsOf(task)}\n\n` +
      `## The task\n\n${task.instructions}` +
      `${contextSection(task, this.deps.store.all(), (id) => this.workerName(id))}${retrySection(task)}${knowledge}`
    )
  }

  /** The goal chain section for a task's goal; empty with no goal or no goal source. */
  private goalsOf(task: TaskRecord): string {
    if (typeof task.goalId !== 'string' || this.deps.goals === undefined) return ''
    return goalSection(this.deps.goals.chain(task.goalId))
  }

  /** What the project's knowledge says about this task, as a bounded section; empty when there is none or it fails. */
  private async knowledgeFor(task: TaskRecord): Promise<string> {
    const knowledge = this.deps.knowledge
    if (knowledge === undefined || task.project === '') return ''
    try {
      const found = await knowledge.forBrief({
        project: task.project,
        query: `${task.title}\n${task.instructions}`,
        ...(typeof task.goalId === 'string' ? { goalId: task.goalId } : {}),
      })
      const text = found.text.trim()
      return text === '' ? '' : `\n\n## What is known about this project\n\n${head(text, KNOWLEDGE_BRIEF_CHARS)}`
    } catch (error) {
      // A brief without knowledge is still a brief; the work is not held up for it.
      console.error('[tasks] project knowledge could not be read for a brief:', error)
      return ''
    }
  }

  /** The folder a worker runs in: its workspace when the workspace part gives one, else the project. */
  private async folderFor(task: TaskRecord): Promise<string> {
    const workspaces = this.deps.workspaces
    if (workspaces === undefined) return task.project
    const folder = await workspaces.folderFor({
      id: task.id,
      project: task.project,
      useWorkspace: task.useWorkspace === true,
    })
    return folder ?? task.project
  }

  /** Where a task's session actually runs, while it has one. */
  private folderOfSession(task: TaskRecord): string | null {
    if (task.sessionId === null) return null
    return this.deps.surface.listSessions().find((session) => session.id === task.sessionId)?.cwd ?? null
  }

  /* ------------------------------------------------------------ stalls -- */

  /** The next moment a quiet worker counts as stalled; null when none can. What the task clock is aimed at. */
  stallDueAt(): number | null {
    let next: number | null = null
    for (const task of this.deps.store.all()) {
      const since = this.quietOf(task)
      if (since !== null && (next === null || since + STALL_AFTER_MS < next)) next = since + STALL_AFTER_MS
    }
    return next
  }

  /** Called by the task clock: every worker quiet past {@link STALL_AFTER_MS} has stalled. */
  checkStalls(): void {
    if (this.stopped) return
    const now = this.clock.now()
    for (const task of this.deps.store.all()) {
      const since = this.quietOf(task)
      if (since === null || since + STALL_AFTER_MS > now) continue
      const minutes = Math.round(STALL_AFTER_MS / 60_000)
      this.stall(task, 'quiet', `No sign of work for ${minutes} minutes, and it has neither finished nor asked anything.`, true)
    }
  }

  /** Since when a running worker has been quiet; null for a task that is not a worker mid-run. */
  private quietOf(task: TaskRecord): number | null {
    if (task.sessionId === null || (task.stalled ?? null) !== null || task.assignee.kind !== 'agent') return null
    if (task.stopped || task.questionOpen || task.result !== null || task.keepOpenUntil !== null) return null
    if (!this.alive(task.sessionId)) return null
    return this.quietSince.get(task.sessionId) ?? null
  }

  /** A status from a task's session: working clears the quiet clock (and a quiet stall), anything calm starts it. */
  private noteActivity(task: TaskRecord, sessionId: string, status: SessionStatus): void {
    if (status === 'working') {
      const was = this.quietSince.delete(sessionId)
      if (task.stalled?.reason === 'quiet') {
        this.deps.store.update(task, { stalled: null })
        this.deps.store.note(task, { by: task.assignee.agentId, kind: 'progress', text: 'Working again.' })
        this.setStatus(task, this.connectionOf(task)?.statuses.onStarted ?? null)
        this.changed()
      }
      if (was) this.deps.onDueChange?.()
      return
    }
    if (status === 'exited' || this.quietSince.has(sessionId)) return
    this.quietSince.set(sessionId, this.clock.now())
    this.deps.onDueChange?.()
  }

  /**
   * A task's worker has stalled: kept on its record, told as an event, and told
   * to Hoot when Hoot is coordinating it. `say`: also comment and set the
   * blocked status — false when the caller has already said why.
   */
  private stall(task: TaskRecord, reason: TaskStall['reason'], text: string, say: boolean): void {
    this.deps.store.update(task, { stalled: { at: this.clock.now(), reason, text } })
    if (say) {
      this.comment(task, 'blocker', `Stalled: ${text}`)
      this.setStatus(task, this.connectionOf(task)?.statuses.onBlocked ?? null)
    }
    this.event(task, 'stalled', { summary: text })
    if (this.coordinatedByHoot(task)) {
      const next =
        task.local === true
          ? 'Look at it with tasks_progress, then try it again with tasks_retry or give it to another agent with tasks_reassign.'
          : 'Its CRM task is marked as stuck; post what happens next with tasks_comment.'
      void this.tellHoot(task, `Task ${task.id} ("${head(task.title, 80)}") has stalled: ${text} ${next}`)
    }
    this.changed()
  }

  /** Hoot planned it, or it is part of a task Hoot holds. */
  private coordinatedByHoot(task: TaskRecord): boolean {
    if (task.requestedBy === HOOT_ID) return true
    if (task.parentExternalTaskId === null) return false
    return this.deps.store.get(task.keyId, task.parentExternalTaskId)?.assignee.kind === 'hoot'
  }

  /** Tell the knowledge seam, when there is one, without ever holding the task flow up on it. */
  private event(task: TaskRecord, kind: TaskKnowledgeEvent['kind'], extra: { summary?: string; evidence?: string[] } = {}): void {
    const knowledge = this.deps.knowledge
    if (knowledge === undefined || task.project === '') return
    const agentId = this.agentIdOf(task)
    const summary = extra.summary?.trim() ?? ''
    const event: TaskKnowledgeEvent = {
      kind,
      project: task.project,
      taskId: task.id,
      title: task.title,
      ...(typeof task.goalId === 'string' ? { goalId: task.goalId } : {}),
      ...(agentId === null ? {} : { agentId }),
      ...(task.sessionId === null ? {} : { sessionId: task.sessionId }),
      ...(summary === '' ? {} : { summary: head(summary, COMMENT_ANSWER_CHARS) }),
      ...(extra.evidence !== undefined && extra.evidence.length > 0 ? { evidence: [...extra.evidence] } : {}),
      at: this.clock.now(),
    }
    try {
      void knowledge.noteTaskEvent(event).catch((error: unknown) => console.error('[tasks] the knowledge seam refused an event:', error))
    } catch (error) {
      console.error('[tasks] the knowledge seam refused an event:', error)
    }
  }

  /** `hoot`, `me`, `none` or an agent's id, as a name. */
  private workerName(id: string): string {
    if (id === HOOT_ID) return 'Hoot'
    if (id === ME) return 'You'
    if (id === 'none') return 'Nobody'
    return this.deps.config.agent(id)?.name ?? id
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
      // A part of a task serves the goal the whole of it serves.
      if (typeof task.goalId === 'string') child.goalId = task.goalId
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
