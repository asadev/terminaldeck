import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { SessionMeta } from '../../shared/types'
import type { CallResult } from '../deck-control/control'
import type { HubClock } from '../deck-control/notify-hub'
import { TaskApi } from './task-api'
import { TaskConfig } from './task-config'
import { TaskEngine, type CheckResult } from './task-engine'
import { TaskOutbox, type TaskEvent } from './task-outbox'
import { LocalTasks } from './task-local'
import { TaskStore } from './task-store'

/**
 * The engine against fake sessions on a fake clock: what it starts, what it
 * tells the CRM, and when — through the real API, store, outbox and the same
 * detector AI-app notifications use.
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
  for (let i = 0; i < 20; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

const KEY = 'key-1'
const SECRET = `whsec_${Buffer.alloc(32, 3).toString('base64')}`

let dir = ''
let clock: ManualClock
let config: TaskConfig
let store: TaskStore
let outbox: TaskOutbox
let engine: TaskEngine
let api: TaskApi
let sessions: SessionMeta[]
let calls: Array<{ tool: string; args: Record<string, unknown> }>
let posts: TaskEvent[]
let told: Array<[string, string]>
let answers: Map<string, { at: number; text: string }>
let checkResult: CheckResult
let started = 0
let event = 0

function ok(value: unknown): CallResult {
  return { ok: true, value, error: null, refusal: null, row: {} } as unknown as CallResult
}

function build(): void {
  engine = new TaskEngine({
    config,
    store,
    outbox,
    surface: {
      listSessions: () => sessions,
      sessionScreen: async () => 'Allow this edit? 1. Yes  2. No',
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
        sessions.push({
          id,
          cwd: String(args.cwd),
          title: 'task',
          provider: 'claude',
          exitCode: null,
          createdAt: clock.now(),
          agentSessionId: `conv-${started}`,
        })
        return ok({ session: { id } })
      }
      if (tool === 'sessions.stop') {
        const session = sessions.find((one) => one.id === args.sessionId)
        if (session) session.exitCode = 0
        return ok({})
      }
      return ok({})
    },
    hoot: async () => 'hoot-session',
    deliver: async (sessionId, line) => {
      told.push([sessionId, line])
    },
    answer: async (meta) => {
      const said = answers.get(meta.id)
      return said === undefined ? null : { ...said, truncated: false }
    },
    check: async () => checkResult,
    clock,
  })
  api = new TaskApi({ config, store, engine, now: () => clock.now() })
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-task-engine-'))
  clock = new ManualClock()
  config = new TaskConfig({ dir: null })
  config.saveAgent({ id: 'builder', name: 'Builder', role: 'builder', provider: 'claude', account: 'Work', model: 'opus' })
  config.saveAgent({ id: 'tester', name: 'Tester', role: 'tester', provider: 'codex', verifyCommand: 'npm test' })
  config.saveConnection(KEY, {
    enabled: true,
    eventsUrl: 'https://crm.example.com/td-events',
    hootIdentity: 'u-hoot',
    identities: { 'u-builder': 'builder', 'u-tester': 'tester' },
    allowedSenders: ['u-asad'],
    folders: ['/work'],
  })
  store = new TaskStore({ dir: null, now: () => clock.now() })
  posts = []
  outbox = new TaskOutbox({
    dir: null,
    target: () => ({ url: 'https://crm.example.com/td-events', secret: SECRET }),
    clock,
    post: async (_url, _headers, body) => {
      posts.push(JSON.parse(body) as TaskEvent)
      return { status: 200, body: '' }
    },
  })
  sessions = []
  calls = []
  told = []
  answers = new Map()
  checkResult = { ok: true, output: 'all tests passed' }
  started = 0
  build()
})

afterEach(() => {
  engine.stop()
  outbox.stop()
  rmSync(dir, { recursive: true, force: true })
})

async function give(assignee: string, over: Record<string, unknown> = {}): Promise<string> {
  event += 1
  const externalTaskId = String(over.externalTaskId ?? `t-${event}`)
  const answer = await api.create(KEY, {
    eventId: `e-${event}`,
    externalTaskId,
    externalThreadId: `th-${externalTaskId}`,
    title: `Task ${externalTaskId}`,
    instructions: 'Fix the login bug.',
    project: '/work/app',
    assignee,
    requestedBy: 'u-asad',
    ...over,
  })
  expect(answer.ok, JSON.stringify(answer)).toBe(true)
  await settle()
  return externalTaskId
}

function record(externalTaskId: string) {
  const task = store.get(KEY, externalTaskId)
  if (task === null) throw new Error(`no task ${externalTaskId}`)
  return task
}

async function finishTurn(sessionId: string, text: string): Promise<void> {
  answers.set(sessionId, { at: clock.now(), text })
  engine.noteStatus(sessionId, 'working')
  engine.noteStatus(sessionId, 'completed')
  await settle()
}

const statuses = (): string[] => posts.filter((post) => post.type === 'task.status').map((post) => (post as { status: string }).status)
const comments = (kind?: string): Array<{ kind: string; body: string; actor: string; externalTaskId: string; originExternalTaskId: string }> =>
  posts
    .filter((post) => post.type === 'task.comment')
    .map((post) => {
      const comment = post as Extract<TaskEvent, { type: 'task.comment' }>
      return { ...comment.comment, actor: comment.actor, externalTaskId: comment.externalTaskId, originExternalTaskId: comment.originExternalTaskId }
    })
    .filter((comment) => kind === undefined || comment.kind === kind)

describe('starting work', () => {
  it('starts an agent’s task on its coding agent, account and model, and says Working on it as that agent', async () => {
    const id = await give('u-builder')
    const start = calls.find((call) => call.tool === 'sessions.start')
    expect(start?.args).toMatchObject({ cwd: '/work/app', provider: 'claude', account: 'Work', title: `crm-${id}` })
    expect(String(start?.args.brief)).toContain('Fix the login bug.')
    expect(calls).toContainEqual({ tool: 'agents.set_control', args: { sessionId: 's-1', control: 'model', value: 'opus' } })
    expect(posts.find((post) => post.type === 'task.status')).toMatchObject({ status: 'Working on it', actor: 'u-builder', externalTaskId: id })
    expect(comments('progress')[0]).toMatchObject({ actor: 'u-builder', body: 'Builder started on this.' })
    expect(record(id)).toMatchObject({ process: 'running', sessionId: 's-1', conversationId: 'conv-1' })
  })

  it('runs one task at a time per agent, and starts the next once the first has finished', async () => {
    const first = await give('u-builder', { project: '/work/a' })
    const second = await give('u-builder', { project: '/work/b' })
    expect(calls.filter((call) => call.tool === 'sessions.start')).toHaveLength(1)
    expect(record(second).process).toBe('queued')
    await finishTurn('s-1', 'Fixed it.')
    // Hoot was asked to verify; meanwhile the kept-open first session does not count as working.
    await engine.pump()
    await settle()
    expect(calls.filter((call) => call.tool === 'sessions.start').map((call) => call.args.cwd)).toEqual(['/work/a', '/work/b'])
    expect(record(first).keepOpenUntil).not.toBeNull()
  })
})

describe('finishing', () => {
  it('sets Done only after the check passes, and Stuck with its output when it fails', async () => {
    const good = await give('u-tester', { project: '/work/a' })
    await finishTurn('s-1', 'All green.')
    expect(statuses()).toEqual(['Working on it', 'Done'])
    expect(comments('completion')[0].body).toContain('the check passed')
    expect(record(good).result).toMatchObject({ verified: true, answer: 'All green.' })

    checkResult = { ok: false, output: '2 tests failed: login.spec.ts' }
    const bad = await give('u-tester', { project: '/work/b' })
    await finishTurn('s-2', 'Done, I think.')
    expect(statuses()).toEqual(['Working on it', 'Done', 'Working on it', 'Stuck'])
    expect(comments('blocker').at(-1)?.body).toContain('2 tests failed: login.spec.ts')
    expect(record(bad).result?.verified).toBe(false)
  })

  it('asks Hoot when the agent has no check, and Hoot’s verdict sets Done', async () => {
    const id = await give('u-builder')
    await finishTurn('s-1', 'The login bug is fixed.')
    expect(statuses()).toEqual(['Working on it'])
    expect(comments('completion')[0].body).toContain('Hoot is checking it')
    expect(told.at(-1)?.[0]).toBe('hoot-session')
    expect(told.at(-1)?.[1]).toContain('tasks_verify')
    engine.verify(record(id), true, 'Checked the diff and the tests.')
    await settle()
    expect(statuses()).toEqual(['Working on it', 'Done'])
    expect(comments('completion').at(-1)).toMatchObject({ actor: 'u-hoot', body: 'Checked the diff and the tests.' })
  })

  it('handles one finished turn once, however often the hook fires', async () => {
    await give('u-builder')
    await finishTurn('s-1', 'Fixed.')
    engine.noteStatus('s-1', 'completed')
    await settle()
    expect(comments('completion')).toHaveLength(1)
  })
})

describe('questions and replies', () => {
  it('sets Stuck on a question, and an allowed reply goes into the same session', async () => {
    const id = await give('u-builder')
    engine.noteStatus('s-1', 'working')
    engine.noteStatus('s-1', 'input')
    await settle()
    expect(comments('question')[0].body).toContain('Allow this edit?')
    expect(statuses()).toEqual(['Working on it', 'Stuck'])
    const answered = await api.comment(KEY, {
      eventId: 'c-1',
      externalTaskId: id,
      externalCommentId: 'crm-c-1',
      author: 'u-asad',
      body: 'Yes, go ahead.',
    })
    expect(answered).toMatchObject({ ok: true, value: { outcome: 'answered' } })
    await settle()
    expect(calls).toContainEqual({ tool: 'sessions.send', args: { sessionId: 's-1', text: 'Yes, go ahead.' } })
    expect(statuses()).toEqual(['Working on it', 'Stuck', 'Working on it'])
  })
})

describe('kept open, then resumed exactly', () => {
  it('closes a finished session after its keep-open time, keeps the conversation, and resumes exactly it', async () => {
    const id = await give('u-builder')
    await finishTurn('s-1', 'Fixed.')
    expect(record(id).keepOpenUntil).toBe(clock.now() + 30 * 60_000)
    clock.advance(30 * 60_000)
    await settle()
    expect(calls.filter((call) => call.tool === 'sessions.stop')).toEqual([{ tool: 'sessions.stop', args: { sessionId: 's-1' } }])
    expect(record(id)).toMatchObject({ sessionId: null, conversationId: 'conv-1', process: 'exited' })
    expect(engine.armed()).toBe(false)

    await api.comment(KEY, {
      eventId: 'c-2',
      externalTaskId: id,
      externalCommentId: 'crm-c-2',
      author: 'u-asad',
      body: 'Also fix the logout button.',
      mentions: ['u-builder'],
    })
    await settle()
    const resumed = calls.filter((call) => call.tool === 'sessions.start').at(-1)
    expect(resumed?.args).toMatchObject({ conversation: 'conv-1', cwd: '/work/app' })
    expect(String(resumed?.args.brief)).toContain('Also fix the logout button.')
  })

  it('restarts the keep-open clock when the session works again', async () => {
    const id = await give('u-builder')
    await finishTurn('s-1', 'Fixed.')
    clock.advance(20 * 60_000)
    engine.noteStatus('s-1', 'working')
    expect(record(id).keepOpenUntil).toBeNull()
    clock.advance(20 * 60_000)
    expect(calls.some((call) => call.tool === 'sessions.stop')).toBe(false)
  })
})

describe('limits and recovery', () => {
  it('stops a run at its limit and says so', async () => {
    const id = await give('u-builder')
    clock.advance(60 * 60_000)
    await settle()
    expect(calls.some((call) => call.tool === 'sessions.stop')).toBe(true)
    expect(comments('blocker').at(-1)?.body).toContain('Stopped after 60 minutes')
    expect(statuses().at(-1)).toBe('Stuck')
    expect(record(id).sessionId).toBeNull()
  })

  it('after a restart, lets go of a task whose session is gone and says a reply continues it', async () => {
    const id = await give('u-builder')
    engine.stop()
    sessions = []
    posts.length = 0
    build()
    engine.recover()
    await settle()
    expect(record(id)).toMatchObject({ sessionId: null, process: 'exited', conversationId: 'conv-1' })
    expect(comments('blocker')[0].body).toContain('Terminal Deck restarted')
    expect(statuses()).toEqual(['Stuck'])
  })

  it('sends a status only as the main assignee or creator, and never the one the task already has', async () => {
    await give('u-builder', { mainAssignee: 'u-someone', creator: 'u-asad' })
    expect(statuses()).toEqual([])
    expect(comments('progress')).toHaveLength(1)
    await give('u-builder', { project: '/work/b', status: 'Working on it' })
    expect(statuses()).toEqual([])
  })

  it('costs no timer when nothing is due', () => {
    expect(engine.armed()).toBe(false)
  })
})

describe('Hoot', () => {
  it('is told a task given to it, hands part to an agent through the CRM, and is told when the children are done', async () => {
    const parent = await give('u-hoot', { externalTaskId: 'root' })
    expect(told[0][0]).toBe('hoot-session')
    expect(told[0][1]).toContain('tasks_delegate')
    expect(statuses()).toEqual(['Working on it'])

    const delegated = engine.delegate(record(parent), config.findAgent('tester')!, { title: 'Run the tests', instructions: 'npm test', project: null })
    expect(delegated).toEqual({ ok: true })
    await settle()
    expect(posts.find((post) => post.type === 'task.delegate_requested')).toMatchObject({
      actor: 'u-hoot',
      externalTaskId: 'root',
      delegate: { assignee: 'u-tester', title: 'Run the tests', project: '/work/app' },
    })

    // The CRM creates the child, from Hoot, under the root.
    const child = await api.create(KEY, {
      eventId: 'e-child',
      externalTaskId: 'child-1',
      parentExternalTaskId: 'root',
      title: 'Run the tests',
      instructions: 'npm test',
      assignee: 'u-tester',
      requestedBy: 'u-hoot',
      creator: 'u-hoot',
    })
    expect(child).toMatchObject({ ok: true, value: { outcome: 'accepted' } })
    await settle()
    expect(record('child-1')).toMatchObject({ hops: 1, originExternalTaskId: 'root', externalThreadId: 'th-root' })
    await finishTurn('s-1', 'All 40 tests pass.')
    // The child's comments land on the task the work was asked for on.
    expect(comments('completion').at(-1)).toMatchObject({ externalTaskId: 'child-1', originExternalTaskId: 'root', actor: 'u-tester' })
    expect(told.at(-1)?.[1]).toContain('Every task you handed on')
    expect(told.at(-1)?.[1]).toContain('All 40 tests pass.')
  })
})

describe('the CRM’s operations, end to end on fake sessions', () => {
  it('create once per event id, then result before and after a checked finish', async () => {
    const first = await api.create(KEY, { eventId: 'dup', externalTaskId: 'R-1', title: 'Run it', project: '/work/app', assignee: 'u-tester', requestedBy: 'u-asad' })
    const again = await api.create(KEY, { eventId: 'dup', externalTaskId: 'R-1', title: 'Run it', project: '/work/app', assignee: 'u-tester', requestedBy: 'u-asad' })
    await settle()
    expect(first).toMatchObject({ ok: true, value: { outcome: 'accepted' } })
    expect(again).toMatchObject({ ok: true, value: { duplicate: true } })
    expect(calls.filter((call) => call.tool === 'sessions.start')).toHaveLength(1)
    expect(api.result(KEY, { externalTaskId: 'R-1' })).toMatchObject({ ok: true, value: { finished: false, answer: null } })
    await finishTurn('s-1', '40 passed, 0 failed.')
    expect(api.result(KEY, { externalTaskId: 'R-1' })).toMatchObject({
      ok: true,
      value: { finished: true, verified: true, answer: '40 passed, 0 failed.', crmStatus: 'Done' },
    })
    expect(api.read(KEY, { externalTaskId: 'R-1' })).toMatchObject({ ok: true, value: { task: { crmStatus: 'Done', finished: true, verified: true } } })
  })

  it('assign to another of ours: the running session stops and the new agent starts from the beginning', async () => {
    const id = await give('u-builder')
    const moved = await api.assign(KEY, { eventId: 'as-1', externalTaskId: id, assignee: 'u-tester', requestedBy: 'u-asad' })
    await settle()
    expect(moved).toMatchObject({ ok: true, value: { outcome: 'accepted' } })
    expect(calls).toContainEqual({ tool: 'sessions.stop', args: { sessionId: 's-1' } })
    const starts = calls.filter((call) => call.tool === 'sessions.start')
    expect(starts.map((call) => call.args.provider)).toEqual(['claude', 'codex'])
    expect(record(id)).toMatchObject({ assignee: { agentId: 'tester', identity: 'u-tester' }, sessionId: 's-2', mainAssignee: 'u-tester' })
    // Already Working on it, so no second status; the new agent says it started, under its own name.
    expect(statuses()).toEqual(['Working on it'])
    expect(comments('progress').at(-1)).toMatchObject({ actor: 'u-tester', body: 'Tester started on this.' })
  })

  it('assign to somebody who is not ours: the work stops, says so, and sets no status', async () => {
    const id = await give('u-builder')
    const before = statuses().length
    const released = await api.assign(KEY, { eventId: 'as-2', externalTaskId: id, assignee: 'u-dot', requestedBy: 'u-asad' })
    await settle()
    expect(released).toMatchObject({ ok: true, value: { outcome: 'released' } })
    expect(calls).toContainEqual({ tool: 'sessions.stop', args: { sessionId: 's-1' } })
    expect(comments('progress').at(-1)?.body).toBe('Stopped: it was assigned to somebody else in the CRM.')
    expect(statuses()).toHaveLength(before)
    expect(record(id)).toMatchObject({ stopped: true, sessionId: null })
  })

  it('cancel stops the session, keeps the CRM status, and later comments no longer reach an agent', async () => {
    const id = await give('u-builder')
    const cancelled = await api.cancel(KEY, { eventId: 'cx-1', externalTaskId: id, requestedBy: 'u-asad', reason: 'not needed' })
    await settle()
    expect(cancelled).toMatchObject({ ok: true, value: { outcome: 'cancelled' } })
    expect(calls).toContainEqual({ tool: 'sessions.stop', args: { sessionId: 's-1' } })
    expect(comments('progress').at(-1)?.body).toBe('Stopped: cancelled in the CRM: not needed')
    expect(statuses()).toEqual(['Working on it'])
    const late = await api.comment(KEY, { eventId: 'cm-9', externalTaskId: id, externalCommentId: 'crm-9', author: 'u-asad', body: 'Go on', mentions: ['u-builder'] })
    expect(late).toMatchObject({ ok: true, value: { outcome: 'ignored_not_addressed' } })
    expect(calls.filter((call) => call.tool === 'sessions.start')).toHaveLength(1)
  })

  it('a CRM status change is recorded and starts or stops nothing', async () => {
    const id = await give('u-builder')
    const callsBefore = calls.length
    const recorded = await api.status(KEY, { eventId: 'st-1', externalTaskId: id, status: 'In Progress', changedBy: 'u-asad' })
    await settle()
    expect(recorded).toMatchObject({ ok: true, value: { outcome: 'recorded', task: { crmStatus: 'In Progress' } } })
    expect(calls).toHaveLength(callsBefore)
    expect(record(id).sessionId).toBe('s-1')
  })

  it('an allowed comment addressed to the agent goes into its session; its own agent’s comment does not', async () => {
    const id = await give('u-builder')
    const own = await api.comment(KEY, { eventId: 'cm-1', externalTaskId: id, externalCommentId: 'crm-1', author: 'u-builder', body: 'Working on it', mentions: ['u-builder'] })
    expect(own).toMatchObject({ ok: true, value: { outcome: 'ignored_own_agent' } })
    const asked = await api.comment(KEY, { eventId: 'cm-2', externalTaskId: id, externalCommentId: 'crm-2', author: 'u-asad', body: 'Use the new API.', mentions: ['u-builder'] })
    await settle()
    expect(asked).toMatchObject({ ok: true, value: { outcome: 'answered' } })
    expect(calls.filter((call) => call.tool === 'sessions.send')).toEqual([{ tool: 'sessions.send', args: { sessionId: 's-1', text: 'Use the new API.' } }])
  })
})

describe('an agent’s own settings, applied every time it starts', () => {
  beforeEach(() => {
    config.saveAgent({
      id: 'builder',
      name: 'Builder',
      role: 'builder',
      provider: 'claude',
      account: 'Work',
      model: 'opus',
      effort: 'high',
      instructions: 'Work on a branch. Run the tests before you finish.',
      toolsPreferred: ['Read', 'Grep'],
      toolsAvoided: ['WebFetch'],
      skills: ['frontend-design'],
    })
  })

  it('puts the instructions, tool choices and skills in the brief, and sets model and effort on the new session', async () => {
    await give('u-builder')
    const brief = String(calls.find((call) => call.tool === 'sessions.start')?.args.brief)
    expect(brief).toContain('## How you work (Builder, builder)')
    expect(brief).toContain('Work on a branch. Run the tests before you finish.')
    expect(brief).toContain('Prefer these tools: Read, Grep.')
    expect(brief).toContain('Do not use these tools: WebFetch.')
    // Said as a request in the brief itself, never as a lock.
    expect(brief).toContain('your own permission settings still apply')
    expect(brief).toContain('Use these skills when they fit: frontend-design.')
    expect(brief.indexOf('## How you work')).toBeLessThan(brief.indexOf('## The task'))
    expect(calls.filter((call) => call.tool === 'agents.set_control').map((call) => call.args)).toEqual([
      { sessionId: 's-1', control: 'model', value: 'opus' },
      { sessionId: 's-1', control: 'effort', value: 'high' },
    ])
  })

  it('applies the settings as they are now when it resumes its own conversation', async () => {
    const id = await give('u-builder')
    await finishTurn('s-1', 'Done.')
    clock.advance(30 * 60_000)
    await settle()
    config.saveAgent({ ...config.agent('builder')!, effort: 'max', instructions: 'Keep commits small.' })
    calls.length = 0
    await api.comment(KEY, { eventId: 'rs-1', externalTaskId: id, externalCommentId: 'crm-rs-1', author: 'u-asad', body: 'One more fix.', mentions: ['u-builder'] })
    await settle()
    const resumed = calls.find((call) => call.tool === 'sessions.start')
    expect(resumed?.args).toMatchObject({ conversation: 'conv-1', provider: 'claude', account: 'Work' })
    expect(String(resumed?.args.brief)).toContain('One more fix.')
    expect(String(resumed?.args.brief)).toContain('Keep commits small.')
    expect(calls.filter((call) => call.tool === 'agents.set_control').map((call) => call.args)).toEqual([
      { sessionId: 's-2', control: 'model', value: 'opus' },
      { sessionId: 's-2', control: 'effort', value: 'max' },
    ])
  })

  it('says on the task when the coding agent refuses a setting, and carries on', async () => {
    build()
    // A session whose agent has no effort control: set_control is refused for effort.
    const original = (engine as unknown as { deps: { call: (tool: string, args: Record<string, unknown>) => Promise<unknown> } }).deps
    const inner = original.call
    original.call = async (tool, args) => {
      if (tool === 'agents.set_control' && args.control === 'effort') {
        calls.push({ tool, args })
        return { ok: false, value: null, error: 'this agent has no effort setting', refusal: null, row: {} }
      }
      return inner(tool, args)
    }
    await give('u-builder')
    expect(comments('progress').some((comment) => comment.body === 'Could not set effort high: this agent has no effort setting.')).toBe(true)
    expect(statuses()).toEqual(['Working on it'])
  })
})

describe('your own tasks, with no CRM', () => {
  let local: LocalTasks
  beforeEach(() => {
    local = new LocalTasks({ store, config, engine, now: () => clock.now() })
  })
  const notes = (id: string) => (store.byId(id)?.notes ?? []).map((note) => `${note.by}/${note.kind}: ${note.text.split('\n')[0]}`)

  it('makes a task for nobody or for you, starts nothing, and changes its title, details, folder and status', async () => {
    const nobody = await local.create({ title: 'Plan the release', instructions: 'Dates and owners.' })
    const mine = await local.create({ title: 'Write the notes', assignee: 'me', status: 'In Progress' })
    expect(nobody).toMatchObject({ local: true, assignee: { kind: 'none' }, crmStatus: 'To-Do', process: 'idle', keyId: 'local' })
    expect(mine).toMatchObject({ assignee: { kind: 'human', agentId: 'me' }, crmStatus: 'In Progress', process: 'idle' })
    expect(calls.filter((call) => call.tool === 'sessions.start')).toEqual([])

    await local.update(nobody.id, { title: 'Plan the 0.18 release', instructions: 'Dates, owners, risks.', project: '/work/app', status: 'Done' })
    expect(store.byId(nobody.id)).toMatchObject({ title: 'Plan the 0.18 release', instructions: 'Dates, owners, risks.', project: '/work/app', crmStatus: 'Done' })
    expect(notes(nobody.id)).toEqual(['me/edited: Created, assigned to nobody.', 'me/edited: Changed the title, details, project.', 'me/status: Status: Done'])
    // Nothing is sent anywhere: there is no CRM.
    expect(posts).toEqual([])
  })

  it('refuses what cannot be done, and says why', async () => {
    await expect(local.create({ title: ' ' })).rejects.toThrow(/title cannot be empty/)
    await expect(local.create({ title: 'x', assignee: 'builder' })).rejects.toThrow(/project folder the agent should work in/)
    await expect(local.create({ title: 'x', assignee: 'nobody-here' })).rejects.toThrow(/one of your task agents/)
    await expect(local.create({ title: 'x', status: 'Cancelled' })).rejects.toThrow(/status has to be one of/)
    await expect(local.create({ title: 'x', project: 'relative/path' })).rejects.toThrow(/not a full folder path/)
    await expect(local.update('local:missing', { status: 'Done' })).rejects.toThrow(/no longer exists/)
  })

  it('given to an agent: starts it with its own settings; a question comes back to you, and your reply goes back to it', async () => {
    const task = await local.create({ title: 'Fix the login bug', instructions: 'It throws on an empty password.', project: '/work/app', assignee: 'builder' })
    await settle()
    expect(calls.find((call) => call.tool === 'sessions.start')?.args).toMatchObject({ cwd: '/work/app', provider: 'claude', account: 'Work' })
    expect(store.byId(task.id)).toMatchObject({ assignee: { kind: 'agent', agentId: 'builder' }, crmStatus: 'Working on it', sessionId: 's-1' })

    // The agent asks something: the task is yours, stuck, with what it asked.
    engine.noteStatus('s-1', 'working')
    engine.noteStatus('s-1', 'input')
    await settle()
    expect(store.byId(task.id)).toMatchObject({ assignee: { kind: 'human', agentId: 'me' }, handedFrom: 'builder', crmStatus: 'Stuck', sessionId: 's-1' })
    expect(notes(task.id).slice(-3)).toEqual([
      'builder/question: The agent is asking something. Reply on this task to answer.',
      'builder/status: Status: Stuck',
      'builder/assigned: Handed to you.',
    ])

    // Your reply: back to the agent, in its own session, working again.
    await local.reply(task.id, 'Yes, allow it.')
    await settle()
    expect(calls).toContainEqual({ tool: 'sessions.send', args: { sessionId: 's-1', text: 'Yes, allow it.' } })
    expect(store.byId(task.id)).toMatchObject({ assignee: { kind: 'agent', agentId: 'builder' }, handedFrom: null, crmStatus: 'Working on it' })
    expect(notes(task.id)).toContain('me/reply: Yes, allow it.')
    expect(posts).toEqual([])
  })

  it('finished with no check: comes back to you to check, and a reply continues in the same session', async () => {
    const task = await local.create({ title: 'Fix it', project: '/work/app', assignee: 'builder' })
    await finishTurn('s-1', 'Fixed: the empty password is refused now.')
    expect(store.byId(task.id)).toMatchObject({ assignee: { kind: 'human' }, handedFrom: 'builder', result: { verified: false } })
    expect(notes(task.id)).toContain('builder/completion: Finished. Check it and mark it Done.')
    // No Hoot is asked: you are the checker for your own task.
    expect(told).toEqual([])
    await local.reply(task.id, 'Add a test for it too.')
    await settle()
    expect(calls).toContainEqual({ tool: 'sessions.send', args: { sessionId: 's-1', text: 'Add a test for it too.' } })
    await local.update(task.id, { status: 'Done' })
    expect(store.byId(task.id)?.crmStatus).toBe('Done')
  })

  it('finished with a check that passes: Done, and stays with the agent', async () => {
    const task = await local.create({ title: 'Run the tests', project: '/work/app', assignee: 'tester' })
    await finishTurn('s-1', '40 passed.')
    expect(store.byId(task.id)).toMatchObject({ crmStatus: 'Done', assignee: { kind: 'agent', agentId: 'tester' }, result: { verified: true } })
    expect(notes(task.id)).toContain('tester/completion: Finished, and the check passed.')
  })

  it('taken back from an agent mid-run: its session stops and the task is yours', async () => {
    const task = await local.create({ title: 'Fix it', project: '/work/app', assignee: 'builder' })
    await local.update(task.id, { assignee: 'me' })
    await settle()
    expect(calls).toContainEqual({ tool: 'sessions.stop', args: { sessionId: 's-1' } })
    expect(store.byId(task.id)).toMatchObject({ assignee: { kind: 'human' }, process: 'idle', sessionId: null })
    expect(notes(task.id)).toContain('me/assigned: Assigned to you.')
    // And back to nobody, then to an agent again: a fresh start.
    await local.update(task.id, { assignee: 'none' })
    await local.update(task.id, { assignee: 'builder' })
    await settle()
    expect(calls.filter((call) => call.tool === 'sessions.start')).toHaveLength(2)
  })

  it('Hoot handing part of your task to an agent makes a local child task and starts it — nothing goes to a CRM', async () => {
    const parent = await local.create({ title: 'Ship 0.18', project: '/work/app', assignee: 'hoot' })
    expect(told.at(-1)?.[0]).toBe('hoot-session')
    expect(engine.delegate(store.byId(parent.id)!, config.findAgent('builder')!, { title: 'Fix the bug', instructions: 'Now.', project: null })).toEqual({ ok: true })
    await settle()
    const child = store.all().find((task) => task.parentExternalTaskId === parent.externalTaskId)
    expect(child).toMatchObject({ local: true, title: 'Fix the bug', assignee: { kind: 'agent', agentId: 'builder' }, project: '/work/app', hops: 1 })
    expect(calls.filter((call) => call.tool === 'sessions.start')).toHaveLength(1)
    expect(posts).toEqual([])
  })
})

describe('the CRM’s task fields, on your own tasks', () => {
  let local: LocalTasks
  beforeEach(() => {
    local = new LocalTasks({ store, config, engine, now: () => clock.now() })
  })

  it('keeps priority, dates and times, tags, board, type and estimate, and logs each change once', async () => {
    const task = await local.create({ title: 'Launch page', priority: 'High', dueDate: '2026-10-09', board: 'Launch', labels: ['web', 'web', ' ops '] })
    expect(store.byId(task.id)).toMatchObject({ priority: 'High', dueDate: '2026-10-09', board: 'Launch', labels: ['web', 'ops'], taskType: 'task', completedAt: null })
    await local.update(task.id, { priority: null, startDate: '2026-10-08', startTime: '09:30', dueTime: '17:00', taskType: 'milestone', estimateMinutes: 90, board: null })
    expect(store.byId(task.id)).toMatchObject({ priority: null, startDate: '2026-10-08', startTime: '09:30', dueTime: '17:00', taskType: 'milestone', estimateMinutes: 90, board: null })
    expect(store.byId(task.id)?.notes?.at(-1)?.text).toBe('Changed the priority, start date, start time, due time, board, type, estimate.')
    // Saving what it already has writes nothing.
    const before = store.byId(task.id)?.notes?.length
    await local.update(task.id, { priority: null, taskType: 'milestone' })
    expect(store.byId(task.id)?.notes?.length).toBe(before)
  })

  it('stamps when it was done, clears it when reopened, and archives and restores', async () => {
    const task = await local.create({ title: 'Ship', status: 'Done' })
    expect(store.byId(task.id)?.completedAt).toBe(clock.now())
    await local.update(task.id, { status: 'In Progress' })
    expect(store.byId(task.id)?.completedAt).toBeNull()
    await local.update(task.id, { archived: true })
    expect(store.byId(task.id)?.archivedAt).toBe(clock.now())
    await local.update(task.id, { archived: false })
    expect(store.byId(task.id)?.archivedAt).toBeNull()
    expect((store.byId(task.id)?.notes ?? []).map((note) => note.text).slice(-2)).toEqual(['Archived.', 'Restored from the archive.'])
  })

  it('refuses what the CRM refuses', async () => {
    await expect(local.create({ title: 'x', priority: 'Urgent' })).rejects.toThrow(/priority has to be one of/)
    await expect(local.create({ title: 'x', dueDate: '2026-02-30' })).rejects.toThrow(/due date has to be a date/)
    await expect(local.create({ title: 'x', dueTime: '25:00' })).rejects.toThrow(/due time has to be a time/)
    await expect(local.create({ title: 'x', labels: Array.from({ length: 21 }, (_, n) => `t${n}`) })).rejects.toThrow(/at most 20 tags/)
    await expect(local.create({ title: 'x', labels: ['x'.repeat(41)] })).rejects.toThrow(/at most 40 characters/)
    await expect(local.create({ title: 'x', taskType: 'epic' })).rejects.toThrow(/task or a milestone/)
    await expect(local.create({ title: 'x', estimateMinutes: -1 })).rejects.toThrow(/whole number of minutes/)
    await expect(local.create({ title: 'x', board: 'b'.repeat(41) })).rejects.toThrow(/at most 40 characters/)
  })

  it('deletes a task, stopping the agent on it first', async () => {
    const task = await local.create({ title: 'Fix it', project: '/work/app', assignee: 'builder' })
    await settle()
    await local.remove(task.id)
    await settle()
    expect(calls).toContainEqual({ tool: 'sessions.stop', args: { sessionId: 's-1' } })
    expect(store.byId(task.id)).toBeNull()
  })
})

describe('your own tasks are kept', () => {
  it('survive a restart: title, details, status, who has it, and everything that happened', async () => {
    const disk = mkdtempSync(join(tmpdir(), 'td-local-tasks-'))
    try {
      const first = new TaskStore({ dir: disk, now: () => clock.now() })
      const keep = new LocalTasks({ store: first, config, engine: { accept: async () => undefined, reassign: async () => undefined, reply: async () => undefined, cancel: async () => undefined }, now: () => clock.now() })
      const task = await keep.create({ title: 'Book the venue', instructions: 'Friday.', assignee: 'me' })
      await keep.update(task.id, { status: 'In Progress' })
      first.flush()

      const second = new TaskStore({ dir: disk, now: () => clock.now() })
      expect(second.byId(task.id)).toMatchObject({
        local: true,
        title: 'Book the venue',
        instructions: 'Friday.',
        crmStatus: 'In Progress',
        assignee: { kind: 'human', agentId: 'me' },
      })
      expect(second.byId(task.id)?.notes?.map((note) => note.text)).toEqual(['Created, assigned to you.', 'Status: In Progress'])
    } finally {
      rmSync(disk, { recursive: true, force: true })
    }
  })
})

