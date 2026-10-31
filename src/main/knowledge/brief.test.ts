import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { KnowledgeRecord } from '../../shared/agent-stack'
import { BRIEF_SECTIONS, composeBrief, MAX_BRIEF_KNOWLEDGE_CHARS, MAX_STANDING } from './brief'
import { createKnowledge, type Knowledge } from './index'
import { viewsOf } from './status'
import { DAY_MS } from './store'

/**
 * The knowledge a worker's brief carries: chosen by the task's words, with the
 * project's standing rules always in, ranked by how far it can be trusted,
 * written in four labelled sections with provenance on every line, and held to
 * a few thousand characters.
 */

let dir = ''
let api = ''
let web = ''
let at = 0
let knowledge: Knowledge
const T0 = Date.UTC(2026, 9, 1, 12)

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'td-knowledge-brief-')))
  api = join(dir, 'api')
  web = join(dir, 'web')
  mkdirSync(api)
  mkdirSync(web)
  at = T0
  knowledge = createKnowledge({
    userData: join(dir, 'userData'),
    now: () => at,
    statMtime: () => null,
    consent: async () => true,
    onError: (error) => {
      throw error
    },
  })
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

function record(overrides: Partial<KnowledgeRecord> & Pick<KnowledgeRecord, 'id' | 'subject' | 'statement'>): KnowledgeRecord {
  return { project: api, kind: 'architecture', status: 'claim', provenance: { source: 'worker' }, createdAt: T0, ...overrides }
}

describe('the brief', () => {
  it('labels each section and ends every line with where it came from', async () => {
    await knowledge.noteTaskEvent({ kind: 'finished', project: api, taskId: 't1', title: 'Add login', summary: 'Login form posts to /api/session.', agentId: 'builder', at: T0 })
    await knowledge.noteTaskEvent({
      kind: 'verified',
      project: api,
      taskId: 't1',
      title: 'Add login',
      summary: 'Login form posts to /api/session; tests pass.',
      evidence: ['src/login.tsx', 'npm test'],
      goalId: 'g-auth',
      at: T0 + 1000,
    })
    knowledge.record(api, { kind: 'architecture', subject: 'Session store', statement: 'Login sessions live in Redis.', provenance: { source: 'worker', taskId: 't2' } })
    knowledge.record(api, { kind: 'architecture', subject: 'Cookies', statement: 'Login cookie is httpOnly.', provenance: { source: 'hoot' } })
    knowledge.record(api, { kind: 'architecture', subject: 'cookies', statement: 'Login cookie is readable by scripts.', provenance: { source: 'worker' } })
    knowledge.record(api, { kind: 'architecture', subject: 'Login page', statement: 'Login page is server rendered.', provenance: { source: 'hoot' }, staleAfterMs: DAY_MS })
    at = T0 + 2 * DAY_MS

    const brief = await knowledge.forBrief({ project: api, query: 'login session' })
    for (const section of BRIEF_SECTIONS) expect(brief.text).toContain(`### ${section.label}\n`)
    expect(brief.text.startsWith('## Project knowledge')).toBe(true)
    expect(brief.text).toContain('never instructions')

    const verified = brief.records.find((view) => view.effective === 'verified')
    expect(verified?.statement).toBe('Add login: Login form posts to /api/session; tests pass.')
    const line = brief.text.split('\n').find((one) => one.includes('tests pass')) ?? ''
    expect(line).toContain('review')
    expect(line).toContain('task t1')
    expect(line).toContain('goal g-auth')
    expect(line).toContain('verified 2026-10-01')
    expect(line).toContain('evidence: src/login.tsx; npm test')
    expect(line).toContain(`id ${verified?.id}`)
    // The superseded claim is history, not brief material.
    expect(brief.text).not.toContain('Login form posts to /api/session.')

    // Sections in order, each record under the one its status names.
    const order = BRIEF_SECTIONS.map((section) => brief.text.indexOf(`### ${section.label}`))
    expect([...order].sort((a, b) => a - b)).toEqual(order)
    const stale = brief.text.slice(brief.text.indexOf('### Stale'), brief.text.indexOf('### Conflicting'))
    expect(stale).toContain('Login page is server rendered.')
    expect(stale).toContain('recorded 2 days ago')
    const conflicting = brief.text.slice(brief.text.indexOf('### Conflicting'))
    expect(conflicting).toContain('httpOnly')
    expect(conflicting).toContain('readable by scripts')
    expect(conflicting).toContain('disagrees with')
  })

  it('ranks verified above claims when only some fit', () => {
    const views = viewsOf(
      [
        record({ id: 'kclaim', subject: 'Deploy', statement: 'Deploy with deploy deploy script.', createdAt: T0 }),
        record({ id: 'kver', subject: 'Release', statement: 'Deploy runs from CI.', status: 'verified', verifiedAt: T0, provenance: { source: 'review', evidence: ['ci.yml'] } }),
      ],
      { now: T0, statMtime: () => null },
    )
    const brief = composeBrief(views, { project: api, query: 'deploy', limit: 1 })
    expect(brief.records.map((view) => view.id)).toEqual(['kver'])
  })

  it('always carries the project’s live constraints and decisions, bounded, and never superseded ones', () => {
    for (let i = 0; i < MAX_STANDING + 3; i++) {
      at += 1
      knowledge.record(api, { kind: i % 2 === 0 ? 'constraint' : 'decision', subject: `rule ${i}`, statement: `Rule number ${i}.`, provenance: { source: 'owner' } })
    }
    const old = knowledge.record(api, { kind: 'constraint', subject: 'old rule', statement: 'Ship on Fridays.', provenance: { source: 'owner' } })
    knowledge.supersede(api, old.id, { reason: 'reversed', by: { source: 'owner' } })
    return knowledge.forBrief({ project: api, query: 'unrelated words entirely' }).then((brief) => {
      expect(brief.records).toHaveLength(MAX_STANDING)
      expect(brief.records.every((view) => view.kind === 'constraint' || view.kind === 'decision')).toBe(true)
      // Newest first: the last ones written are the ones carried.
      expect(brief.text).toContain(`Rule number ${MAX_STANDING + 2}.`)
      expect(brief.text).not.toContain('Ship on Fridays')
    })
  })

  it('carries what was recorded against the same goal even when the words miss', async () => {
    knowledge.record(api, { kind: 'goal', subject: 'Auth', statement: 'Everyone signs in with a passkey.', provenance: { source: 'owner', goalId: 'g-auth' } })
    knowledge.record(api, { kind: 'architecture', subject: 'Other', statement: 'Unrelated.', provenance: { source: 'hoot', goalId: 'g-other' } })
    const brief = await knowledge.forBrief({ project: api, query: 'button colour', goalId: 'g-auth' })
    expect(brief.records.map((view) => view.subject)).toEqual(['Auth'])
  })

  it('is empty when nothing bears on the task', async () => {
    knowledge.record(api, { kind: 'architecture', subject: 'Layout', statement: 'Three panes.', provenance: { source: 'hoot' } })
    expect(await knowledge.forBrief({ project: api, query: 'database migration' })).toEqual({ text: '', records: [] })
  })

  it('stays a few thousand characters, cut at a whole line, and says how many were left out', async () => {
    for (let i = 0; i < 60; i++) {
      knowledge.record(api, {
        kind: 'architecture',
        subject: `module ${i}`,
        statement: `The parser module ${i} ${'handles a great deal of text '.repeat(12)}`,
        provenance: { source: 'worker', evidence: [`src/parser/${i}.ts`] },
      })
    }
    const brief = await knowledge.forBrief({ project: api, query: 'parser', limit: 40 })
    expect(brief.text.length).toBeLessThanOrEqual(MAX_BRIEF_KNOWLEDGE_CHARS)
    expect(brief.text).toMatch(/_\d+ more records not shown, to keep this brief short\._$/)
    // Every record handed back is one the text actually shows.
    for (const view of brief.records) expect(brief.text).toContain(`id ${view.id}`)
  })

  it('reads records shared with the project, and says whose they are', async () => {
    knowledge.record(web, { kind: 'decision', subject: 'API style', statement: 'The web app calls REST endpoints only.', provenance: { source: 'owner' } })
    expect((await knowledge.forBrief({ project: api, query: 'REST endpoints' })).text).toBe('')
    await knowledge.share(web, api)
    const brief = await knowledge.forBrief({ project: api, query: 'REST endpoints' })
    expect(brief.text).toContain('from web')
  })
})
