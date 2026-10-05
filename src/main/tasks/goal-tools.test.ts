import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ToolContext, ToolSpec } from '../deck-control/catalogue'
import { fakeSurface } from '../deck-control/sessions-lane.fixture'
import { ALL_TIERS, LOCAL_CALLER, type Caller } from '../deck-control/surface'
import { createKnowledge } from '../knowledge'
import { blockersOf } from './goal-progress'
import { GoalStore } from './goal-store'
import { goalTools } from './goal-tools'
import { TASK_CONFIG_FILE, TaskConfig } from './task-config'
import { LocalTaskDetail } from './task-detail-local'
import { LocalTasks } from './task-local'
import { TaskStore, type TaskRecord } from './task-store'

/**
 * Hoot's orchestration tools against the real goal store, task store,
 * LocalTasks and task page, with the engine faked — so no agent starts, and
 * what each tool asked of the engine is read back.
 */

let dir = ''
let project = ''
let store: TaskStore
let goals: GoalStore
let config: TaskConfig
let local: LocalTasks
let detail: LocalTaskDetail
let started: string[]
let retried: Array<{ task: string; note: string }>
let reviewed: Array<{ task: string; pass: boolean; evidence: string[]; reasons: string }>
let tools: ToolSpec[]
let surface: ReturnType<typeof fakeSurface>

const HOOT: Caller = LOCAL_CALLER
const APP: Caller = { kind: 'key', keyId: 'k1', keyName: 'Claude Desktop', tiers: ALL_TIERS, tasks: true }

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-goal-tools-'))
  project = join(dir, 'app')
  mkdirSync(project)
  writeFileSync(
    join(dir, TASK_CONFIG_FILE),
    JSON.stringify({ v: 1, agents: [{ id: 'builder', name: 'Builder' }, { id: 'tester', name: 'Tester' }], connections: [] }),
  )
  store = new TaskStore({ dir: null })
  goals = new GoalStore({ dir: null })
  config = new TaskConfig({ dir })
  started = []
  retried = []
  reviewed = []
  local = new LocalTasks({
    store,
    config,
    goals,
    engine: {
      accept: async (task) => {
        if (task.assignee.kind === 'agent') started.push(task.id)
        store.update(task, { process: task.assignee.kind === 'agent' ? 'queued' : 'idle' })
      },
      reassign: async (task, assignee) => {
        store.update(task, { assignee, mainAssignee: assignee.identity })
        if (assignee.kind === 'agent') started.push(task.id)
      },
      reply: async () => undefined,
      cancel: async () => undefined,
    },
  })
  detail = new LocalTaskDetail({
    store,
    config,
    local,
    filesDir: join(dir, 'task-files'),
    chooseFiles: async () => [],
    chooseFolder: async () => null,
    openPath: async () => '',
  })
  surface = fakeSurface()
  surface.state.projects = [{ path: project, lastOpenedAt: 1 }]
  tools = goalTools({
    goals: () => goals,
    store: () => store,
    config: () => config,
    local: () => local,
    detail: () => detail,
    engine: () => ({
      retry: async (task, note) => {
        retried.push({ task: task.id, note })
        return { ok: true }
      },
      review: async (task, verdict) => {
        reviewed.push({ task: task.id, ...verdict })
        return { ok: true }
      },
    }),
  })
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

function context(caller: Caller): ToolContext {
  return { surface: surface.surface, callId: 'c1', caller, attended: true, startedByCopilot: () => false, noteStarted: () => undefined, now: () => Date.now() }
}

function tool(id: string): ToolSpec {
  const spec = tools.find((t) => t.id === id)
  if (spec === undefined) throw new Error(`no tool ${id}`)
  return spec
}

async function call(id: string, args: Record<string, unknown>, caller: Caller = HOOT): Promise<Record<string, unknown>> {
  const spec = tool(id)
  spec.precheck?.(args, context(caller))
  const out = await spec.run(args, context(caller))
  return out.value as Record<string, unknown>
}

async function refused(id: string, args: Record<string, unknown>, caller: Caller = HOOT): Promise<string> {
  try {
    await call(id, args, caller)
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
  throw new Error(`${id} ${JSON.stringify(args)} was not refused`)
}

const tierOf = (id: string, args: Record<string, unknown>) => tool(id).escalate?.(args, context(HOOT)) ?? tool(id).tier
const task = (id: string): TaskRecord => store.byId(id) as TaskRecord

describe('the schemas', () => {
  it('six tools, Hoot’s alone, each one index line, tiered like the task tools', () => {
    expect(tools.map((t) => t.wire)).toEqual(['tasks_goals', 'tasks_plan', 'tasks_progress', 'tasks_retry', 'tasks_reassign', 'tasks_review'])
    for (const spec of tools) {
      expect(spec.audience).toBe('copilot')
      expect(spec.index?.length ?? 0).toBeGreaterThan(20)
      expect(spec.id.startsWith('tasks.')).toBe(true)
    }
    expect(tierOf('tasks.goals', { do: 'list' })).toBe('read')
    expect(tierOf('tasks.goals', { do: 'create' })).toBe('act')
    expect(tierOf('tasks.goals', { do: 'remove' })).toBe('alter')
    expect(tierOf('tasks.plan', {})).toBe('alter')
    expect(tierOf('tasks.retry', {})).toBe('alter')
    expect(tierOf('tasks.reassign', {})).toBe('alter')
    expect(tierOf('tasks.review', {})).toBe('act')
    expect(tierOf('tasks.progress', {})).toBe('read')
  })

  it('refuses an AI app on a key, however its key is set', async () => {
    for (const id of ['tasks.goals', 'tasks.plan', 'tasks.progress', 'tasks.retry', 'tasks.reassign', 'tasks.review']) {
      expect(await refused(id, { do: 'list', goal: 'x', task: 'x', tasks: [], verdict: 'pass', evidence: ['x'] }, APP)).toMatch(/Hoot’s own tool/)
    }
  })
})

describe('goals', () => {
  it('makes, reads, changes, links and removes — a removed goal’s tasks move up to its parent', async () => {
    const root = ((await call('tasks.goals', { do: 'create', title: 'Fortnightly releases' })).created as { id: string }).id
    const release = ((await call('tasks.goals', { do: 'create', title: 'Ship 0.18', parent: root, project })).created as { id: string }).id
    const made = await local.create({ title: 'Write the notes', project })
    await call('tasks.goals', { do: 'link', task: made.id, goal: release })
    expect(task(made.id).goalId).toBe(release)
    expect((task(made.id).notes ?? []).at(-1)).toMatchObject({ by: 'hoot', text: 'Part of the goal “Ship 0.18”.' })

    const got = await call('tasks.goals', { do: 'get', goal: release })
    expect(got.above).toEqual([{ goal: root, title: 'Fortnightly releases', status: 'active' }])
    expect((got.goal as { progress: { total: number } }).progress.total).toBe(1)
    await call('tasks.goals', { do: 'update', goal: release, status: 'achieved' })
    expect(goals.byId(release)?.status).toBe('achieved')

    await call('tasks.goals', { do: 'remove', goal: release })
    expect(goals.has(release)).toBe(false)
    expect(task(made.id).goalId).toBe(root)
    expect(await refused('tasks.goals', { do: 'create', title: 'x', project: '/somewhere/else' })).toMatch(/not inside a folder Terminal Deck has open/)
    expect(await refused('tasks.goals', { do: 'link', task: made.id, goal: 'goal-gone' })).toMatch(/there is no goal goal-gone/)
  })
})

describe('a plan', () => {
  it('makes the tasks under the goal, sets each to wait for its waits, then hands them out — Hoot’s, written as Hoot', async () => {
    const goal = goals.create({ title: 'Ship 0.18', project })
    const answer = await call('tasks.plan', {
      goal: goal.id,
      tasks: [
        { key: 'api', title: 'Build the API', details: 'REST, two routes.', agent: 'Builder' },
        { key: 'page', title: 'Build the page', agent: 'builder', after: ['api'], workspace: true },
        { key: 'test', title: 'Test it end to end', agent: 'Tester', after: ['api', 'page'] },
        { key: 'notes', title: 'Write the notes' },
      ],
    })
    const made = answer.tasks as Array<{ key: string; task: string; agent: string | null; waitsFor: string[] }>
    expect(made.map((one) => [one.key, one.agent, one.waitsFor])).toEqual([
      ['api', 'Builder', []],
      ['page', 'Builder', ['api']],
      ['test', 'Tester', ['api', 'page']],
      ['notes', null, []],
    ])
    const [api, page, test, notes] = made.map((one) => task(one.task))
    for (const one of [api, page, test, notes]) expect(one).toMatchObject({ goalId: goal.id, requestedBy: 'hoot', project })
    expect(api.instructions).toBe('REST, two routes.')
    expect(page.useWorkspace).toBe(true)
    expect(started).toEqual([api.id, page.id, test.id])
    expect(blockersOf(test, store.all()).map((one) => one.title)).toEqual(['Build the API', 'Build the page'])
    expect(notes.assignee.kind).toBe('none')
    expect((api.notes ?? []).every((note) => note.by === 'hoot')).toBe(true)
  })

  it('refuses a plan that could not run, before anything is made', async () => {
    const goal = goals.create({ title: 'Ship 0.18' })
    const base = { goal: goal.id, project }
    expect(await refused('tasks.plan', { ...base, tasks: [{ title: 'x', agent: 'Nobody' }] })).toMatch(/no task agent called Nobody/)
    expect(await refused('tasks.plan', { ...base, tasks: [{ key: 'a', title: 'x', after: ['b'] }] })).toMatch(/waits for b, which is not in this plan/)
    expect(
      await refused('tasks.plan', { ...base, tasks: [{ key: 'a', title: 'x', after: ['b'] }, { key: 'b', title: 'y', after: ['a'] }] }),
    ).toMatch(/loop back/)
    expect(await refused('tasks.plan', { goal: goal.id, tasks: [{ title: 'x', agent: 'Builder' }] })).toMatch(/project is required/)
    expect(await refused('tasks.plan', { ...base, project: '/elsewhere', tasks: [{ title: 'x' }] })).toMatch(/not inside a folder/)
    expect(store.all()).toEqual([])
  })
})

describe('progress', () => {
  it('reports a goal’s tasks with who has them, and every goal’s totals when none is named', async () => {
    const goal = goals.create({ title: 'Ship 0.18', project })
    await call('tasks.plan', { goal: goal.id, tasks: [{ key: 'a', title: 'Build', agent: 'Builder' }, { key: 'b', title: 'Check', after: ['a'] }] })
    const report = await call('tasks.progress', { goal: goal.id })
    expect(report).toMatchObject({ total: 2, done: 0, blocked: 1 })
    expect((report.tasks as Array<{ title: string; assigneeName: string }>).map((line) => `${line.title}:${line.assigneeName}`)).toEqual([
      'Build:Builder',
      'Check:Nobody',
    ])
    const all = await call('tasks.progress', {})
    expect((all.goals as Array<{ progress: { total: number } }>)[0].progress.total).toBe(2)
  })
})

describe('what the project already knows', () => {
  function withKnowledge(): ReturnType<typeof createKnowledge> {
    const knowledge = createKnowledge({ userData: join(dir, 'user-data') })
    tools = goalTools({
      goals: () => goals,
      store: () => store,
      config: () => config,
      local: () => local,
      detail: () => detail,
      engine: () => null,
      knowledge: () => knowledge,
    })
    return knowledge
  }

  it('comes with a goal’s progress and with a plan, labelled and sourced', async () => {
    const knowledge = withKnowledge()
    knowledge.record(project, {
      kind: 'constraint',
      subject: 'release.mobile-versions',
      statement: 'A release that bumps the version needs the owner to approve the phone version lines.',
      provenance: { source: 'owner' },
    })
    const goal = goals.create({ title: 'Ship the release', description: 'release build and version', project })
    const report = await call('tasks.progress', { goal: goal.id })
    const known = report.knowledge as { text: string; counts: Record<string, number> }
    expect(known.text).toContain('phone version lines')
    expect(known.text).toContain('owner')
    expect(known.counts.claim).toBe(1)
    const plan = await call('tasks.plan', { goal: goal.id, tasks: [{ key: 'a', title: 'Bump the version' }] })
    expect((plan.knowledge as { text: string }).text).toContain('phone version lines')
  })

  it('carries nothing for a project that knows nothing, or when no store is given', async () => {
    withKnowledge()
    const goal = goals.create({ title: 'Ship the release', project })
    expect(await call('tasks.progress', { goal: goal.id })).not.toHaveProperty('knowledge')
    tools = goalTools({ goals: () => goals, store: () => store, config: () => config, local: () => local, detail: () => detail, engine: () => null })
    expect(await call('tasks.progress', { goal: goal.id })).not.toHaveProperty('knowledge')
  })

  it('never reads another project’s records', async () => {
    const knowledge = withKnowledge()
    const other = join(dir, 'other')
    mkdirSync(other, { recursive: true })
    knowledge.record(other, {
      kind: 'decision',
      subject: 'release.channel',
      statement: 'Releases go out on the beta channel first.',
      provenance: { source: 'owner' },
    })
    const goal = goals.create({ title: 'Ship the release', description: 'release channel', project })
    expect(await call('tasks.progress', { goal: goal.id })).not.toHaveProperty('knowledge')
  })
})

describe('retry, reassign, review', () => {
  it('retry hands the engine the task and the note; a CRM task is refused', async () => {
    const made = await local.create({ title: 'Fix it', project, assignee: 'builder' })
    await call('tasks.retry', { task: made.id, note: 'Run the migration first.' })
    expect(retried).toEqual([{ task: made.id, note: 'Run the migration first.' }])
    store.put({ ...task(made.id), id: 'key-1:crm-1', keyId: 'key-1', externalTaskId: 'crm-1', local: false })
    expect(await refused('tasks.retry', { task: 'key-1:crm-1', note: 'x' })).toMatch(/CRM task/)
  })

  it('reassign gives it to another agent with a note, and refuses the agent that already has it', async () => {
    const made = await local.create({ title: 'Fix it', project, assignee: 'builder' })
    started = []
    expect(await refused('tasks.reassign', { task: made.id, agent: 'Builder' })).toMatch(/already has it.*tasks_retry/)
    await call('tasks.reassign', { task: made.id, agent: 'Tester', note: 'Builder is stuck on the database.' })
    expect(started).toEqual([made.id])
    expect(task(made.id).assignee.agentId).toBe('tester')
    expect((task(made.id).notes ?? []).some((note) => note.by === 'hoot' && note.text === 'Given to Tester: Builder is stuck on the database.')).toBe(true)
  })

  it('review: a pass names its evidence, a fail its reasons — checked before the engine hears it', async () => {
    const made = await local.create({ title: 'Fix it', project })
    expect(await refused('tasks.review', { task: made.id, verdict: 'pass' })).toMatch(/must name its evidence/)
    expect(await refused('tasks.review', { task: made.id, verdict: 'fail', evidence: ['a.ts'] })).toMatch(/must give reasons/)
    await call('tasks.review', { task: made.id, verdict: 'pass', evidence: ['src/login.ts', ' ', 'npm test: 120 passed'] })
    expect(reviewed).toEqual([{ task: made.id, pass: true, evidence: ['src/login.ts', 'npm test: 120 passed'], reasons: '' }])
  })
})
