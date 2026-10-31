import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { KnowledgeProvider, TaskKnowledgeEvent, WorkspaceProvider } from '../../shared/agent-stack'
import type { SessionMeta } from '../../shared/types'
import type { CallResult } from '../deck-control/control'
import type { HubClock } from '../deck-control/notify-hub'
import { GoalStore } from './goal-store'
import { TaskClock } from './task-clock'
import { TaskConfig } from './task-config'
import type { LocalTaskDetailData } from './task-detail-local'
import { STALL_AFTER_MS, TaskEngine, type CheckResult } from './task-engine'
import { LocalTasks } from './task-local'
import { TaskOutbox } from './task-outbox'
import { TaskStore, type TaskRecord } from './task-store'

/**
 * The agent stack's half of the engine, on fake sessions and a fake clock:
 * what a worker's brief carries, the knowledge and workspace seams, the events
 * the task flow tells, tasks that wait for others, stalls found through the
 * task clock, and Hoot's retry and review.
 */

class ManualClock implements HubClock {
  at = 1_800_000_000_000
  private seq = 0
  private readonly timers = new Map<number, { due: number; run: () => void }>()
  now(): number {
    return this.at
  }
  setTimeout(run: () => void, ms: number): unknown {
    const id = (this.seq += 1)
    this.timers.set(id, { due: this.at + ms, run })
    return id
  }
  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number)
  }
  pending(): number {
    return this.timers.size
  }
  advance(ms: number): void {
    const target = this.at + ms
    for (;;) {
      const next = [...this.timers.entries()].filter(([, t]) => t.due <= target).sort((a, b) => a[1].due - b[1].due)[0]
      if (!next) break
      this.at = next[1].due
      this.timers.delete(next[0])
      next[1].run()
    }
    this.at = target
  }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 30; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

function ok(value: unknown): CallResult {
  return { ok: true, value, error: null, refusal: null, row: {} } as unknown as CallResult
}

let dir = ''
let clock: ManualClock
let config: TaskConfig
let store: TaskStore
let outbox: TaskOutbox
let goals: GoalStore
let engine: TaskEngine
let local: LocalTasks
let taskClock: TaskClock
let sessions: SessionMeta[]
let calls: Array<{ tool: string; args: Record<string, unknown> }>
let told: string[]
let answers: Map<string, { at: number; text: string }>
let checkResult: CheckResult
let events: TaskKnowledgeEvent[]
let asked: Array<{ project: string; query: string; goalId?: string }>
let started = 0

const knowledge: KnowledgeProvider = {
  forBrief: async (input) => {
    asked.push(input)
    return { text: '- This project builds with pnpm (verified).', records: [] }
  },
  noteTaskEvent: async (event) => {
    events.push(event)
  },
}

function build(
  seams: { knowledge?: KnowledgeProvider; workspaces?: WorkspaceProvider; goals?: boolean; check?(command: string, cwd: string): Promise<CheckResult> } = {},
): void {
  engine = new TaskEngine({
    config,
    store,
    outbox,
    surface: {
      listSessions: () => sessions,
      sessionScreen: async () => '',
      writeToSession: () => undefined,
      transcriptsIn: async () => [],
      transcriptBytes: async () => 0,
      readTranscriptFrom: async () => [],
      copilotRoot: () => dir,
    },
    call: async (tool, args) => {
      calls.push({ tool, args })
      if (tool === 'sessions.start') {
        started += 1
        const id = `s-${started}`
        sessions.push({ id, cwd: String(args.cwd), title: 'task', provider: 'claude', exitCode: null, createdAt: clock.now(), agentSessionId: `conv-${started}` })
        return ok({ session: { id } })
      }
      if (tool === 'sessions.stop') {
        const session = sessions.find((one) => one.id === args.sessionId)
        if (session) session.exitCode = 0
      }
      return ok({})
    },
    hoot: async () => 'hoot-session',
    deliver: async (_sessionId, line) => {
      told.push(line)
    },
    answer: async (meta) => {
      const said = answers.get(meta.id)
      return said === undefined ? null : { ...said, truncated: false }
    },
    check: seams.check ?? (async () => checkResult),
    clock,
    onChange: () => engine.nudge(),
    onDueChange: () => taskClock.poke(),
    ...(seams.goals === false ? {} : { goals }),
    ...(seams.knowledge === undefined ? {} : { knowledge: seams.knowledge }),
    ...(seams.workspaces === undefined ? {} : { workspaces: seams.workspaces }),
  })
  local = new LocalTasks({ store, config, engine, goals, now: () => clock.now(), onChange: () => engine.nudge() })
  taskClock = new TaskClock({ nextDueAt: () => engine.stallDueAt(), runDue: async () => engine.checkStalls(), clock })
  taskClock.start()
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-engine-goals-'))
  clock = new ManualClock()
  config = new TaskConfig({ dir: null })
  config.saveAgent({ id: 'builder', name: 'Builder', role: 'builder', provider: 'claude' })
  config.saveAgent({ id: 'fixer', name: 'Fixer', role: 'builder', provider: 'claude' })
  config.saveAgent({ id: 'tester', name: 'Tester', role: 'tester', provider: 'claude', verifyCommand: 'npm test' })
  store = new TaskStore({ dir: null, now: () => clock.now() })
  outbox = new TaskOutbox({ dir: null, target: () => null, clock, post: async () => ({ status: 200, body: '' }) })
  goals = new GoalStore({ dir: null, now: () => clock.now() })
  sessions = []
  calls = []
  told = []
  answers = new Map()
  checkResult = { ok: true, output: '' }
  events = []
  asked = []
  started = 0
})

afterEach(() => {
  taskClock.stop()
  engine.stop()
  outbox.stop()
  rmSync(dir, { recursive: true, force: true })
})

const starts = (): Array<Record<string, unknown>> => calls.filter((call) => call.tool === 'sessions.start').map((call) => call.args)
const record = (id: string): TaskRecord => store.byId(id) as TaskRecord
const kinds = (): string[] => events.map((event) => event.kind)
const notes = (id: string): string[] => (record(id).notes ?? []).map((note) => `${note.by}/${note.kind}: ${note.text}`)

async function finishTurn(sessionId: string, text: string): Promise<void> {
  answers.set(sessionId, { at: clock.now(), text })
  engine.noteStatus(sessionId, 'working')
  engine.noteStatus(sessionId, 'completed')
  await settle()
}

describe('what a worker is told', () => {
  it('carries the goal chain, what is already on the task, and the project’s knowledge', async () => {
    build({ knowledge })
    const root = goals.create({ title: 'Fortnightly Mac releases', description: 'One every two weeks.' })
    const release = goals.create({ title: 'Ship 0.18', parentId: root.id, description: 'Mac only.' })
    const task = await local.create({ title: 'Fix sign-in', instructions: 'It throws on an empty password.', project: '/work/app', goalId: release.id })
    store.update(task, {
      detail: { subtasks: [], checklists: [], dependencies: [], comments: [{ id: 'c1', authorUserId: 'me', body: 'Keep the old error text.', at: 1 }] } as unknown as LocalTaskDetailData,
    })
    await local.update(task.id, { assignee: 'builder' })
    await settle()
    const brief = String(starts()[0]?.brief)
    expect(brief).toContain('## The goal this serves')
    expect(brief.indexOf('Fortnightly Mac releases')).toBeLessThan(brief.indexOf('Ship 0.18'))
    expect(brief).toContain('It throws on an empty password.')
    expect(brief).toContain('- You: Keep the old error text.')
    expect(brief).toContain('## What is known about this project\n\n- This project builds with pnpm (verified).')
    expect(asked).toEqual([{ project: '/work/app', query: 'Fix sign-in\nIt throws on an empty password.', goalId: release.id }])
    expect(events[0]).toMatchObject({ kind: 'delegated', project: '/work/app', taskId: task.id, goalId: release.id, agentId: 'builder', sessionId: 's-1' })
  })

  it('runs exactly as before without the seams', async () => {
    build({ goals: false })
    const goal = goals.create({ title: 'Ship 0.18' })
    const task = await local.create({ title: 'Fix sign-in', project: '/work/app', goalId: goal.id, assignee: 'builder' })
    await settle()
    expect(starts()[0]).toMatchObject({ cwd: '/work/app' })
    expect(String(starts()[0]?.brief)).not.toContain('## The goal this serves')
    expect(String(starts()[0]?.brief)).not.toContain('What is known')
    expect(record(task.id).process).toBe('running')
  })

  it('a part Hoot hands on serves the goal its whole serves', async () => {
    build()
    const goal = goals.create({ title: 'Ship 0.18' })
    const parent = await local.create({ title: 'Ship it', project: '/work/app', assignee: 'hoot', goalId: goal.id })
    const done = engine.delegate(record(parent.id), config.agent('builder')!, { title: 'Fix the bug', instructions: 'Now.', project: null })
    expect(done).toEqual({ ok: true })
    const child = store.all().find((one) => one.title === 'Fix the bug')
    expect(child?.goalId).toBe(goal.id)
  })
})

describe('a workspace of its own', () => {
  const workspaces: WorkspaceProvider = {
    folderFor: async (task) => {
      if (task.project === '/work/broken') throw new Error('the repository has no commits yet')
      return task.useWorkspace ? `/work/.workspaces/${task.id.slice(6, 14)}` : null
    },
  }

  it('starts the worker in the folder the workspace part gives, the project when it gives none, and holds it when that fails', async () => {
    build({ workspaces })
    const own = await local.create({ title: 'In a worktree', project: '/work/a', assignee: 'builder', useWorkspace: true })
    const shared = await local.create({ title: 'In the checkout', project: '/work/b', assignee: 'fixer' })
    const broken = await local.create({ title: 'Cannot', project: '/work/broken', assignee: 'tester', useWorkspace: true })
    await settle()
    expect(starts().map((args) => args.cwd)).toEqual([`/work/.workspaces/${own.id.slice(6, 14)}`, '/work/b'])
    expect(record(shared.id).useWorkspace).toBeUndefined()
    expect(notes(broken.id).some((line) => line.includes('Could not prepare the folder Tester works in: the repository has no commits yet'))).toBe(true)
  })

  it('a check runs where the work was done', async () => {
    let checkedIn = ''
    build({
      workspaces,
      check: async (_command, cwd) => {
        checkedIn = cwd
        return { ok: true, output: '' }
      },
    })
    await local.create({ title: 'Tested', project: '/work/a', assignee: 'tester', useWorkspace: true })
    await settle()
    await finishTurn('s-1', 'Done.')
    expect(checkedIn).toMatch(/^\/work\/\.workspaces\//)
  })
})

describe('the task flow’s events', () => {
  it('finished, then verified with the check as its evidence', async () => {
    build({ knowledge })
    const task = await local.create({ title: 'Run the suite', project: '/work/app', assignee: 'tester' })
    await settle()
    await finishTurn('s-1', 'All green.')
    expect(kinds()).toEqual(['delegated', 'finished', 'verified'])
    expect(events[2]).toMatchObject({ taskId: task.id, evidence: ['check: npm test'] })
  })

  it('reassigned only from one worker to another', async () => {
    build({ knowledge })
    const task = await local.create({ title: 'Fix it', project: '/work/app' })
    await local.update(task.id, { assignee: 'builder' })
    await settle()
    await local.update(task.id, { assignee: 'fixer' })
    await settle()
    expect(kinds()).toEqual(['delegated', 'reassigned', 'delegated'])
    expect(events[1].summary).toBe('From Builder to Fixer.')
  })

  it('a knowledge seam that throws never holds the work up', async () => {
    build({
      knowledge: {
        forBrief: async () => {
          throw new Error('index is rebuilding')
        },
        noteTaskEvent: () => Promise.reject(new Error('disk full')),
      },
    })
    const task = await local.create({ title: 'Fix it', project: '/work/app', assignee: 'builder' })
    await settle()
    expect(record(task.id).process).toBe('running')
    expect(String(starts()[0]?.brief)).not.toContain('What is known')
  })
})

describe('tasks that wait for others', () => {
  it('stays queued while what it waits for is open, and starts once that is Done', async () => {
    build()
    const first = await local.create({ title: 'Build the API', project: '/work/api' })
    const second = await local.create({ title: 'Build the page', project: '/work/web' })
    store.update(record(second.id), { detail: { subtasks: [], checklists: [], comments: [], dependencies: [{ kind: 'blocked_by', otherTaskId: first.id, at: 1 }] } as unknown as LocalTaskDetailData })
    await local.update(second.id, { assignee: 'fixer' })
    await local.update(first.id, { assignee: 'builder' })
    await settle()
    expect(starts().map((args) => args.cwd)).toEqual(['/work/api'])
    expect(record(second.id).process).toBe('queued')
    await local.update(first.id, { status: 'Done' })
    await settle()
    expect(starts().map((args) => args.cwd)).toEqual(['/work/api', '/work/web'])
  })
})

describe('stalls, found through the task clock', () => {
  it('a worker quiet past the limit stalls — told, Stuck, an event — and clears the moment it works again', async () => {
    build({ knowledge })
    const task = await local.create({ title: 'Fix it', project: '/work/app', assignee: 'builder' })
    await settle()
    // The task clock is aimed at one moment, not polling.
    expect(engine.stallDueAt()).toBe(clock.now() + STALL_AFTER_MS)
    clock.advance(STALL_AFTER_MS - 1)
    await settle()
    expect(record(task.id).stalled ?? null).toBeNull()
    clock.advance(1)
    await settle()
    expect(record(task.id).stalled).toMatchObject({ reason: 'quiet' })
    expect(record(task.id).crmStatus).toBe('Stuck')
    expect(notes(task.id).some((line) => line.startsWith('builder/blocker: Stalled: No sign of work for 15 minutes'))).toBe(true)
    expect(kinds()).toContain('stalled')
    expect(engine.stallDueAt()).toBeNull()

    engine.noteStatus('s-1', 'working')
    expect(record(task.id).stalled).toBeNull()
    expect(record(task.id).crmStatus).toBe('Working on it')
    expect(notes(task.id)).toContain('builder/progress: Working again.')
  })

  it('a reply into a kept-open session starts its quiet clock afresh', async () => {
    build()
    const task = await local.create({ title: 'Fix it', project: '/work/app', assignee: 'builder' })
    await settle()
    await finishTurn('s-1', 'Fixed.')
    clock.advance(20 * 60_000)
    await local.reply(task.id, 'Also the logout button.')
    await settle()
    expect(engine.stallDueAt()).toBe(clock.now() + STALL_AFTER_MS)
    clock.advance(60_000)
    await settle()
    expect(record(task.id).stalled ?? null).toBeNull()
  })

  it('a worker that is working costs no deadline at all', async () => {
    build()
    await local.create({ title: 'Long build', project: '/work/app', assignee: 'builder' })
    await settle()
    engine.noteStatus('s-1', 'working')
    expect(engine.stallDueAt()).toBeNull()
    clock.advance(STALL_AFTER_MS * 3)
    await settle()
    expect(store.all()[0].stalled ?? null).toBeNull()
  })

  it('a worker that ends before finishing has stalled too, and Hoot is told when it planned the task', async () => {
    build({ knowledge })
    const task = await local.create({ title: 'Fix it', project: '/work/app', assignee: 'none' })
    store.update(record(task.id), { requestedBy: 'hoot' })
    await local.update(task.id, { assignee: 'builder' })
    await settle()
    sessions[0].exitCode = 1
    engine.noteExit('s-1', 1)
    await settle()
    expect(record(task.id).stalled).toMatchObject({ reason: 'exited' })
    expect(record(task.id).assignee.kind).toBe('human')
    expect(kinds()).toContain('stalled')
    expect(told.at(-1)).toContain('has stalled')
    expect(told.at(-1)).toContain('tasks_retry')
  })
})

describe('Hoot’s moves', () => {
  it('retry: the same agent and brief, plus the note, from the start', async () => {
    build()
    const task = await local.create({ title: 'Fix it', instructions: 'The login bug.', project: '/work/app', assignee: 'builder' })
    await settle()
    sessions[0].exitCode = 1
    engine.noteExit('s-1', 1)
    await settle()
    expect(await engine.retry(record(task.id), 'Run the migration first.')).toEqual({ ok: true })
    await settle()
    const again = starts()[1]
    expect(again).toMatchObject({ cwd: '/work/app' })
    expect(again.conversation).toBeUndefined()
    expect(String(again.brief)).toContain('The login bug.')
    expect(String(again.brief)).toContain('## Tried again')
    expect(String(again.brief)).toContain('Run the migration first.')
    expect(record(task.id)).toMatchObject({ stalled: null, assignee: { kind: 'agent', agentId: 'builder' }, retry: { count: 1 } })
  })

  it('a task Hoot planned is put to Hoot to review; a pass needs evidence and marks it verified and Done', async () => {
    build({ knowledge })
    const task = await local.create({ title: 'Fix it', project: '/work/app' })
    store.update(record(task.id), { requestedBy: 'hoot' })
    await local.update(task.id, { assignee: 'builder' })
    await settle()
    await finishTurn('s-1', 'Fixed the login bug.')
    expect(told.at(-1)).toContain('tasks_review')
    expect(record(task.id).assignee.kind).toBe('agent')
    expect(await engine.review(record(task.id), { pass: true, evidence: [], reasons: '' })).toMatchObject({ ok: false })
    expect(await engine.review(record(task.id), { pass: true, evidence: ['src/login.ts', 'npm test: 120 passed'], reasons: '' })).toEqual({ ok: true })
    expect(record(task.id)).toMatchObject({ crmStatus: 'Done', result: { verified: true } })
    expect(events.at(-1)).toMatchObject({ kind: 'verified', evidence: ['src/login.ts', 'npm test: 120 passed'] })
  })

  it('a fail reopens it with the reasons, back to its agent in its own conversation', async () => {
    build({ knowledge })
    const task = await local.create({ title: 'Fix it', project: '/work/app', assignee: 'builder' })
    await settle()
    await finishTurn('s-1', 'Fixed.')
    // Finished with no check: it came back to you, and Hoot's verdict sends it back to the agent.
    expect(record(task.id).assignee.kind).toBe('human')
    expect(await engine.review(record(task.id), { pass: false, evidence: ['src/login.ts'], reasons: 'The empty password still throws.' })).toEqual({ ok: true })
    await settle()
    const sent = calls.filter((call) => call.tool === 'sessions.send').at(-1)
    expect(String(sent?.args.text)).toContain('The empty password still throws.')
    expect(record(task.id)).toMatchObject({ assignee: { kind: 'agent', agentId: 'builder' }, result: null, crmStatus: 'Working on it' })
    expect(events.at(-1)).toMatchObject({ kind: 'rejected', summary: 'The empty password still throws.' })
    expect(await engine.review(record(task.id), { pass: true, evidence: ['x'], reasons: '' })).toMatchObject({ ok: false, why: expect.stringContaining('not finished') })
  })
})
