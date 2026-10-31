import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { parseFrontMatter } from '../copilot-inspect'
import type { ToolContext, ToolSpec } from '../deck-control/catalogue'
import { advertisedCatalogue, areaOf, asListedFor, TOOL_AREAS } from '../deck-control/describe-tool'
import { ELSEWHERE_TOOLS, SESSION_TOOLS } from '../deck-control/session-tools'
import { fakeSurface } from '../deck-control/sessions-lane.fixture'
import { ALL_TIERS, LOCAL_CALLER, type Caller } from '../deck-control/surface'
import type { SessionMeta } from '../../shared/types'
import { createKnowledge, type Knowledge } from './index'
import { knowledgeTools, taskScopeOf, type KnowledgeToolDeps } from './knowledge-tools'

/**
 * Knowledge as tools: Hoot's four, scoped to a project the app has open; a
 * worker's note, scoped to its own session's project and only ever a claim;
 * and who may call — and see — which.
 */

let dir = ''
let api = ''
let web = ''
let other = ''
let knowledge: Knowledge
let surface: ReturnType<typeof fakeSurface>
let tasks: Map<string, ReturnType<NonNullable<KnowledgeToolDeps['taskOfSession']>>>
let tools: ToolSpec[]
const T0 = Date.UTC(2026, 9, 1, 12)

const HOOT: Caller = LOCAL_CALLER
const KEY: Caller = { kind: 'key', keyId: 'k1', keyName: 'Claude Desktop', tiers: ALL_TIERS }
const REMOTE: Caller = { kind: 'remote', deviceId: 'phone', tiers: ALL_TIERS }
const WORKER: Caller = { kind: 'session', sessionId: 'w1', machineId: '', tiers: ALL_TIERS }
const TASK_WORKER: Caller = { kind: 'session', sessionId: 'w2', machineId: '', tiers: ALL_TIERS }
const ELSEWHERE: Caller = { kind: 'session', sessionId: 'w1', machineId: 'server-1', tiers: ALL_TIERS }

function sessionMeta(id: string, cwd: string): SessionMeta {
  return { ...surface.state.sessions[0], id, cwd, agentSessionId: `conv-${id}` }
}

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'td-knowledge-tools-')))
  api = join(dir, 'api')
  web = join(dir, 'web')
  other = join(dir, 'other')
  for (const folder of [api, web, other]) mkdirSync(folder)
  knowledge = createKnowledge({ userData: join(dir, 'userData'), now: () => T0, statMtime: () => null, consent: async () => true })
  surface = fakeSurface()
  surface.state.projects = [
    { path: api, lastOpenedAt: 2 },
    { path: web, lastOpenedAt: 1 },
  ]
  surface.state.sessions = [sessionMeta('w1', api), sessionMeta('w2', join(dir, 'workspace'))]
  tasks = new Map([['w2', { taskId: 'local:9', project: web, agentId: 'builder', goalId: 'g1' }]])
  tools = knowledgeTools({ knowledge: () => knowledge, taskOfSession: (id) => tasks.get(id) ?? null })
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

function context(caller: Caller): ToolContext {
  return { surface: surface.surface, callId: 'c1', caller, attended: true, startedByCopilot: () => false, noteStarted: () => undefined, now: () => T0 }
}

function tool(id: string): ToolSpec {
  const spec = tools.find((one) => one.id === id)
  if (spec === undefined) throw new Error(`no tool ${id}`)
  return spec
}

/** One call as the dispatcher makes it: precheck, then run. */
async function call(id: string, args: Record<string, unknown>, caller: Caller = HOOT): Promise<Record<string, unknown>> {
  const spec = tool(id)
  spec.precheck?.(args, context(caller))
  return (await spec.run(args, context(caller))).value as Record<string, unknown>
}

async function refused(id: string, args: Record<string, unknown>, caller: Caller = HOOT): Promise<string> {
  try {
    await call(id, args, caller)
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
  throw new Error(`${id} ${JSON.stringify(args)} was not refused`)
}

describe('the schemas', () => {
  it('five tools, each one index line in an area of its own, never listed to an app on a key', () => {
    expect(tools.map((spec) => spec.id)).toEqual(['knowledge.search', 'knowledge.get', 'knowledge.record', 'knowledge.supersede', 'knowledge.note'])
    for (const spec of tools) {
      expect(spec.wire).toBe(spec.id.replace('.', '_'))
      expect(spec.audience).toBe('copilot')
      expect(asListedFor(spec, true)).toBeNull()
      expect(spec.index?.length).toBeGreaterThan(60)
      expect(spec.index?.length).toBeLessThan(200)
      expect(spec.index).toMatch(/\.$/)
      expect(TOOL_AREAS.map((area) => area.id)).toContain(areaOf(spec))
      expect((spec.inputSchema as { additionalProperties: boolean }).additionalProperties).toBe(false)
    }
    expect(tools.filter((spec) => spec.tier === 'read').map((spec) => spec.id)).toEqual(['knowledge.search', 'knowledge.get'])
  })

  it('gives a session in this app the note and nothing else of knowledge, and a session elsewhere none of it', () => {
    for (const spec of tools) {
      const worker = spec.id === 'knowledge.note'
      expect(SESSION_TOOLS.has(spec.id), spec.id).toBe(worker)
      expect(SESSION_TOOLS.has(spec.wire), spec.wire).toBe(worker)
      expect(ELSEWHERE_TOOLS.has(spec.id) || ELSEWHERE_TOOLS.has(spec.wire), spec.id).toBe(false)
    }
    // Of all five, a session is shown the note alone.
    const visible = tools.filter((spec) => SESSION_TOOLS.has(spec.id))
    expect(advertisedCatalogue(visible).map((spec) => spec.id)).toEqual(['knowledge.note'])
  })
})

describe('Hoot’s four', () => {
  it('records a claim — Hoot’s or the owner’s — and finds it by its words', async () => {
    const recorded = (await call('knowledge.record', {
      project: api,
      kind: 'constraint',
      subject: 'CI',
      statement: 'Never ship on a red CI.',
      as: 'owner',
      evidence: ['.github/workflows/ci.yml'],
    })) as { record: { id: string; status: string; source: string } }
    expect(recorded.record).toMatchObject({ status: 'claim', source: 'owner' })
    await call('knowledge.record', { project: api, kind: 'decision', subject: 'Font', statement: 'Inter everywhere.' })

    const found = (await call('knowledge.search', { project: api, query: 'ship CI' })) as { records: Array<{ id: string }>; of: number }
    expect(found.records.map((one) => one.id)).toEqual([recorded.record.id])
    expect(found.of).toBe(2)
    const newest = (await call('knowledge.search', { project: api })) as { records: unknown[] }
    expect(newest.records).toHaveLength(2)

    const got = (await call('knowledge.get', { project: api, id: recorded.record.id })) as { record: { statement: string; evidence: string[] }; history: unknown[] }
    expect(got.record.statement).toBe('Never ship on a red CI.')
    expect(got.record.evidence).toEqual(['.github/workflows/ci.yml'])
    expect(got.history).toEqual([])
  })

  it('cannot write verified, or a result, or task history', async () => {
    expect(await refused('knowledge.record', { project: api, kind: 'decision', subject: 's', statement: 'x', status: 'verified' })).toMatch(/only a task’s review/)
    expect(await refused('knowledge.record', { project: api, kind: 'result', subject: 's', statement: 'x' })).toMatch(/kind must be one of/)
    expect(await refused('knowledge.record', { project: api, kind: 'task-history', subject: 's', statement: 'x' })).toMatch(/kind must be one of/)
    expect(knowledge.list(api)).toEqual([])
  })

  it('supersedes with a reason, keeping the old record as history', async () => {
    const first = (await call('knowledge.record', { project: api, kind: 'decision', subject: 'DB', statement: 'SQLite.' })) as { record: { id: string } }
    const done = (await call('knowledge.supersede', { project: api, id: first.record.id, reason: 'the owner moved it', statement: 'Postgres.', as: 'owner' })) as {
      superseded: { status: string }
      replacement: { id: string; status: string; supersedes: string; source: string }
    }
    expect(done.superseded.status).toBe('superseded')
    expect(done.replacement).toMatchObject({ status: 'claim', supersedes: first.record.id, source: 'owner' })
    const got = (await call('knowledge.get', { project: api, id: done.replacement.id })) as { history: Array<{ id: string }> }
    expect(got.history.map((one) => one.id)).toEqual([first.record.id])
    expect(await refused('knowledge.supersede', { project: api, id: done.replacement.id })).toMatch(/reason is required/)
  })

  it('names only folders the app has open, reads shared records, and never supersedes them', async () => {
    expect(await refused('knowledge.search', { project: other })).toMatch(/not a folder this app has open/)
    expect(await refused('knowledge.record', { project: '/etc', kind: 'decision', subject: 's', statement: 'x' })).toMatch(/not a folder this app has open/)
    const theirs = knowledge.record(web, { kind: 'decision', subject: 'REST', statement: 'REST only.', provenance: { source: 'owner' } })
    expect(((await call('knowledge.search', { project: api, query: 'REST' })) as { records: unknown[] }).records).toEqual([])
    expect(await refused('knowledge.get', { project: api, id: theirs.id })).toMatch(/no record/)
    await knowledge.share(web, api)
    const found = (await call('knowledge.search', { project: api, query: 'REST' })) as { records: Array<{ sharedFrom?: string }>; sharedFrom: string[] }
    expect(found.records[0].sharedFrom).toBe(web)
    expect(found.sharedFrom).toEqual([web])
    expect(await refused('knowledge.supersede', { project: api, id: theirs.id, reason: 'mine now' })).toMatch(/no record/)
  })

  it('answers to Hoot only', async () => {
    for (const caller of [KEY, REMOTE, WORKER]) {
      for (const id of ['knowledge.search', 'knowledge.get', 'knowledge.record', 'knowledge.supersede']) {
        expect(await refused(id, { project: api, id: 'k1', kind: 'decision', subject: 's', statement: 'x', reason: 'r' }, caller)).toMatch(/Hoot’s own tool/)
      }
    }
  })
})

describe('a worker’s note', () => {
  it('lands in its own session’s project as a worker’s claim, whatever project it names', async () => {
    const noted = (await call('knowledge.note', { kind: 'decision', subject: 'Retries', statement: 'Network calls retry three times.', project: web, evidence: [join(api, 'src/net.ts')] }, WORKER)) as {
      noted: { id: string; status: string }
    }
    expect(noted.noted.status).toBe('claim')
    expect(knowledge.list(web)).toEqual([])
    const [view] = knowledge.list(api)
    expect(view.provenance).toEqual({ source: 'worker', sessionId: 'w1', conversationId: 'conv-w1', evidence: ['src/net.ts'] })
  })

  it('lands in the project of the task the session runs, with the task, agent and goal on it', async () => {
    await call('knowledge.note', { kind: 'architecture', subject: 'Queue', statement: 'Jobs go through one queue.' }, TASK_WORKER)
    const [view] = knowledge.list(web)
    expect(view.provenance).toMatchObject({ source: 'worker', taskId: 'local:9', agentId: 'builder', goalId: 'g1', sessionId: 'w2' })
    expect(knowledge.list(api)).toEqual([])
  })

  it('can never create verified', async () => {
    for (const sneak of [{ status: 'verified' }, { verified: true }, { verifiedAt: T0 }]) {
      expect(await refused('knowledge.note', { kind: 'decision', subject: 's', statement: 'Tests pass.', ...sneak }, WORKER)).toMatch(/only a task’s review/)
    }
    expect(await refused('knowledge.note', { kind: 'result', subject: 's', statement: 'Verified.' }, WORKER)).toMatch(/kind must be one of/)
    await call('knowledge.note', { kind: 'decision', subject: 's', statement: 'Verified: tests pass.' }, WORKER)
    const [view] = knowledge.list(api)
    expect(view.status).toBe('claim')
    expect(parseFrontMatter(readFileSync(join(knowledge.dirOf(api), `${view.id}.md`), 'utf8'))).toMatchObject({ status: 'claim', source: 'worker' })
  })

  it('is refused to Hoot, an app on a key, a phone and a session on another computer', async () => {
    const args = { kind: 'decision', subject: 's', statement: 'x' }
    expect(await refused('knowledge.note', args, HOOT)).toMatch(/knowledge_record/)
    expect(await refused('knowledge.note', args, KEY)).toMatch(/session in this app/)
    expect(await refused('knowledge.note', args, REMOTE)).toMatch(/session in this app/)
    expect(await refused('knowledge.note', args, ELSEWHERE)).toMatch(/another one/)
    expect(knowledge.list(api)).toEqual([])
  })

  it('says so when knowledge is not running rather than pretending', async () => {
    tools = knowledgeTools({ knowledge: () => null })
    expect(await refused('knowledge.note', { kind: 'decision', subject: 's', statement: 'x' }, WORKER)).toMatch(/not running/)
    expect(await refused('knowledge.search', { project: api })).toMatch(/not running/)
  })
})

describe('the task a session runs', () => {
  it('is read off the task store’s record', () => {
    expect(taskScopeOf(null)).toBeNull()
    const task = { id: 'local:1', project: api, assignee: { kind: 'agent', agentId: 'builder', identity: 'builder' }, conversationId: 'c9' }
    expect(taskScopeOf(task as never)).toEqual({ taskId: 'local:1', project: api, agentId: 'builder', conversationId: 'c9' })
  })
})
