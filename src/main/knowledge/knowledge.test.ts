import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { KNOWLEDGE_DIR, KNOWLEDGE_KEYS, KNOWLEDGE_PROJECT_FILE, KNOWLEDGE_SHARES_FILE, type KnowledgeRecord } from '../../shared/agent-stack'
import { parseFrontMatter } from '../copilot-inspect'
import { parseNote } from '../memory/note'
import { createKnowledge, type Knowledge, type ShareRequest } from './index'
import { DEFAULT_STALE_AFTER_MS, viewsOf } from './status'
import { DAY_MS, KNOWLEDGE_LOG_FILE, parseRecord, serializeRecord } from './store'

/**
 * The knowledge store and its rules, against a real temp folder and a clock the
 * test moves: the on-disk layout the memory view reads, isolation between
 * projects, sharing only through consent, superseding that keeps history, a
 * delete that needs a reason, and the stale and conflicting statuses worked out
 * on read.
 */

let dir = ''
let userData = ''
let api = ''
let web = ''
let at = 0
let mtimes: Map<string, number>
let statted: string[]
let knowledge: Knowledge

const T0 = Date.UTC(2026, 9, 1, 12)

function make(consent?: (request: ShareRequest) => Promise<boolean>): Knowledge {
  return createKnowledge({
    userData,
    now: () => at,
    statMtime: (path) => {
      statted.push(path)
      return mtimes.get(path) ?? null
    },
    ...(consent === undefined ? {} : { consent }),
    onError: (error) => {
      throw error
    },
  })
}

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'td-knowledge-')))
  userData = join(dir, 'userData')
  api = join(dir, 'api')
  web = join(dir, 'web')
  mkdirSync(api)
  mkdirSync(web)
  at = T0
  mtimes = new Map()
  statted = []
  knowledge = make()
})

afterEach(() => rmSync(dir, { recursive: true, force: true }))

const claim = (project: string, subject: string, statement: string, extra: Partial<Parameters<Knowledge['record']>[1]> = {}) =>
  knowledge.record(project, { kind: 'decision', subject, statement, provenance: { source: 'hoot' }, ...extra })

describe('on disk', () => {
  it('makes nothing until a call needs it', () => {
    createKnowledge({ userData })
    expect(existsSync(join(userData, KNOWLEDGE_DIR))).toBe(false)
  })

  it('keeps one folder per project, keyed by the hash of its real path, with project.json and one file per record', () => {
    const view = claim(api, 'Database', 'SQLite for local state.')
    const key = createHash('sha256').update(api).digest('hex').slice(0, 16)
    const folder = join(userData, KNOWLEDGE_DIR, key)
    expect(knowledge.dirOf(api)).toBe(folder)
    expect(readdirSync(folder).sort()).toEqual([`${view.id}.md`, KNOWLEDGE_PROJECT_FILE].sort())
    expect(JSON.parse(readFileSync(join(folder, KNOWLEDGE_PROJECT_FILE), 'utf8'))).toEqual({ project: api })
    // No temp file left behind by the atomic write.
    expect(readdirSync(folder).some((name) => name.endsWith('.tmp'))).toBe(false)
  })

  it('writes flat front matter of the shared keys and the statement as the body, as the memory view reads any note', () => {
    const view = knowledge.record(api, {
      kind: 'architecture',
      subject: 'Renderer',
      statement: 'React with one store.\nNo Redux.',
      provenance: { source: 'owner', goalId: 'g1', taskId: 't1', evidence: [join(api, 'src/store.ts'), 'npm test, all green'] },
      staleAfterMs: 3 * DAY_MS,
    })
    const text = readFileSync(join(knowledge.dirOf(api), `${view.id}.md`), 'utf8')
    const data = parseFrontMatter(text)
    for (const key of Object.keys(data)) expect(KNOWLEDGE_KEYS as readonly string[]).toContain(key)
    expect(data).toMatchObject({ id: view.id, kind: 'architecture', subject: 'Renderer', status: 'claim', source: 'owner', goal: 'g1', task: 't1' })
    // Paths inside the project are kept relative; a comma inside one item cannot split the list.
    expect(data.evidence).toBe('src/store.ts, npm test; all green')
    expect(data['stale-after-days']).toBe('3')
    expect(data.created).toBe(new Date(T0).toISOString())
    expect(parseNote(text, `${view.id}.md`).body.trim()).toBe('React with one store.\nNo Redux.')
  })

  it('reads back exactly what it wrote, quotes, odd stale periods and all', () => {
    const record: KnowledgeRecord = {
      id: 'kabc',
      project: api,
      kind: 'result',
      subject: '"quoted" subject',
      statement: 'It works: really.\n---\nStill the body.',
      status: 'verified',
      provenance: { source: 'review', taskId: 'local:7', agentId: 'builder', sessionId: 's1', conversationId: 'c1', evidence: ['a.ts', 'b.ts'] },
      createdAt: T0,
      verifiedAt: T0 + 5,
      staleAfterMs: 3_600_000,
      supersedes: 'kold',
    }
    expect(parseRecord(serializeRecord(record), 'kabc.md', api)).toEqual(record)
  })

  it('leaves out a file that is not a record rather than guessing at it', () => {
    expect(parseRecord('---\nkind: decision\n---\nno status, no source', 'kx.md', api)).toBeNull()
    expect(parseRecord('just text', 'ky.md', api)).toBeNull()
  })

  it('writes only claims through record, whatever it is handed', () => {
    const sneaky = { kind: 'result', subject: 's', statement: 'done', provenance: { source: 'worker' }, status: 'verified', verifiedAt: T0 }
    const view = knowledge.record(api, sneaky as unknown as Parameters<Knowledge['record']>[1])
    expect(view.status).toBe('claim')
    expect(view.verifiedAt).toBeUndefined()
    expect(parseFrontMatter(readFileSync(join(knowledge.dirOf(api), `${view.id}.md`), 'utf8')).status).toBe('claim')
  })

  it('refuses a relative project and an empty statement in words', () => {
    expect(() => claim('api', 's', 'x')).toThrow(/absolute folder path/)
    expect(() => claim(api, 's', '  ')).toThrow(/statement is required/)
  })
})

describe('isolation', () => {
  it('reads only a project’s own records', () => {
    const a = claim(api, 'Database', 'SQLite.')
    claim(web, 'Framework', 'Next.js.')
    expect(knowledge.list(api).map((view) => view.id)).toEqual([a.id])
    expect(knowledge.get(web, a.id)).toBeNull()
    expect(knowledge.list(web, { shared: true }).map((view) => view.subject)).toEqual(['Framework'])
  })

  it('treats two spellings of one folder as one project', () => {
    const link = join(dir, 'api-link')
    symlinkSync(api, link)
    const a = claim(link, 'Database', 'SQLite.')
    expect(a.project).toBe(api)
    expect(knowledge.get(api, a.id)?.id).toBe(a.id)
  })
})

describe('sharing', () => {
  it('is refused when nothing was handed in to ask', async () => {
    claim(api, 'Database', 'SQLite.')
    expect(await knowledge.share(api, web)).toBe(false)
    expect(existsSync(join(userData, KNOWLEDGE_DIR, KNOWLEDGE_SHARES_FILE))).toBe(false)
    expect(knowledge.list(web, { shared: true })).toEqual([])
  })

  it('crosses only when consent says yes, one way, and is asked once', async () => {
    const asked: ShareRequest[] = []
    let answer = false
    knowledge = make(async (request) => {
      asked.push(request)
      return answer
    })
    const a = claim(api, 'Database', 'SQLite.')
    expect(await knowledge.share(api, web)).toBe(false)
    expect(knowledge.list(web, { shared: true })).toEqual([])

    answer = true
    expect(await knowledge.share(api, web)).toBe(true)
    expect(asked).toEqual([
      { from: api, to: web, records: 1 },
      { from: api, to: web, records: 1 },
    ])
    const seen = knowledge.list(web, { shared: true })
    expect(seen.map((view) => [view.id, view.project])).toEqual([[a.id, api]])
    expect(knowledge.get(web, a.id)?.project).toBe(api)
    // Without `shared`, and in the other direction, nothing crosses.
    expect(knowledge.list(web)).toEqual([])
    claim(web, 'Framework', 'Next.js.')
    expect(knowledge.list(api, { shared: true }).map((view) => view.subject)).toEqual(['Database'])

    // Already shared: not asked again.
    expect(await knowledge.share(api, web)).toBe(true)
    expect(asked).toHaveLength(2)
    expect(knowledge.changes(api).map((entry) => entry.action)).toEqual(['share'])
  })

  it('takes a share away without asking, because that only narrows', async () => {
    let asks = 0
    knowledge = make(async () => {
      asks += 1
      return true
    })
    claim(api, 'Database', 'SQLite.')
    await knowledge.share(api, web)
    expect(knowledge.unshare(api, web)).toBe(true)
    expect(asks).toBe(1)
    expect(knowledge.list(web, { shared: true })).toEqual([])
    expect(knowledge.unshare(api, web)).toBe(false)
  })

  it('reads a damaged share list as no sharing at all', async () => {
    knowledge = make(async () => true)
    claim(api, 'Database', 'SQLite.')
    await knowledge.share(api, web)
    const file = join(userData, KNOWLEDGE_DIR, KNOWLEDGE_SHARES_FILE)
    writeFileSync(file, '{ not json')
    expect(knowledge.sharedInto(web)).toEqual([])
    expect(knowledge.list(web, { shared: true })).toEqual([])
  })
})

describe('superseding and deleting', () => {
  it('keeps the whole chain on disk, newest first in history, with each reason in the log', () => {
    const first = claim(api, 'Database', 'SQLite.')
    at += 1000
    const second = knowledge.supersede(api, first.id, { reason: 'moved to Postgres', by: { source: 'owner' }, replacement: { statement: 'Postgres.' } })
    at += 1000
    const third = knowledge.supersede(api, second.replacement?.id ?? '', {
      reason: 'back to SQLite for the desktop build',
      by: { source: 'hoot' },
      replacement: { statement: 'SQLite again.', evidence: ['docs/db.md'] },
    })
    const last = third.replacement as NonNullable<typeof third.replacement>
    expect(last.supersedes).toBe(second.replacement?.id)
    expect(last.subject).toBe('Database')
    expect(last.kind).toBe('decision')
    expect(last.status).toBe('claim')
    expect(knowledge.history(api, last.id).map((view) => view.statement)).toEqual(['Postgres.', 'SQLite.'])
    expect(knowledge.list(api).map((view) => view.id)).toEqual([last.id])
    expect(knowledge.list(api, { superseded: true }).map((view) => view.effective)).toEqual(['claim', 'superseded', 'superseded'])
    expect(knowledge.supersededBy(api, first.id)).toBe(second.replacement?.id)
    expect(knowledge.changes(api).map((entry) => [entry.action, entry.id, entry.reason])).toEqual([
      ['supersede', first.id, 'moved to Postgres'],
      ['supersede', second.replacement?.id, 'back to SQLite for the desktop build'],
    ])
  })

  it('withdraws without a replacement, needs a reason, and will not supersede twice', () => {
    const one = claim(api, 'Database', 'SQLite.')
    expect(() => knowledge.supersede(api, one.id, { reason: ' ', by: { source: 'hoot' } })).toThrow(/reason is required/)
    const done = knowledge.supersede(api, one.id, { reason: 'no longer true', by: { source: 'hoot' } })
    expect(done.replacement).toBeNull()
    expect(done.superseded.effective).toBe('superseded')
    expect(knowledge.list(api)).toEqual([])
    expect(() => knowledge.supersede(api, one.id, { reason: 'again', by: { source: 'hoot' } })).toThrow(/already superseded/)
  })

  it('cannot supersede a record that belongs to another project, shared or not', async () => {
    knowledge = make(async () => true)
    const theirs = claim(api, 'Database', 'SQLite.')
    await knowledge.share(api, web)
    expect(() => knowledge.supersede(web, theirs.id, { reason: 'mine now', by: { source: 'hoot' } })).toThrow(/no record/)
  })

  it('deletes only on purpose, with a reason, copying the whole record into the log first', () => {
    const one = claim(api, 'Database', 'SQLite.')
    expect(() => knowledge.remove(api, one.id, { reason: '', by: { source: 'owner' } })).toThrow(/reason is required/)
    knowledge.remove(api, one.id, { reason: 'written by mistake', by: { source: 'owner' } })
    expect(knowledge.get(api, one.id)).toBeNull()
    const [entry] = knowledge.changes(api)
    expect(entry).toMatchObject({ action: 'delete', id: one.id, reason: 'written by mistake', by: { source: 'owner' } })
    expect(entry.record).toContain('SQLite.')
    expect(existsSync(join(knowledge.dirOf(api), KNOWLEDGE_LOG_FILE))).toBe(true)
  })
})

describe('worked-out status', () => {
  it('ages results and architecture by default, and never constraints or decisions unless they say so', () => {
    const arch = knowledge.record(api, { kind: 'architecture', subject: 'Layout', statement: 'Three panes.', provenance: { source: 'hoot' } })
    const rule = knowledge.record(api, { kind: 'constraint', subject: 'CI', statement: 'Never ship on red.', provenance: { source: 'owner' } })
    const short = knowledge.record(api, { kind: 'decision', subject: 'Font', statement: 'Inter.', provenance: { source: 'owner' }, staleAfterMs: 2 * DAY_MS })
    at = T0 + (DEFAULT_STALE_AFTER_MS.architecture as number) + DAY_MS
    const byId = new Map(knowledge.list(api).map((view) => [view.id, view]))
    expect(byId.get(arch.id)?.effective).toBe('stale')
    expect(byId.get(arch.id)?.notes[0]).toMatch(/recorded 91 days ago \(2026-10-01\)/)
    expect(byId.get(rule.id)?.effective).toBe('claim')
    expect(byId.get(rule.id)?.notes).toEqual([])
    expect(byId.get(short.id)?.effective).toBe('stale')
  })

  it('ages a verified record from when it was verified', () => {
    const record: KnowledgeRecord = {
      id: 'kv',
      project: api,
      kind: 'result',
      subject: 'task 1',
      statement: 'Builds.',
      status: 'verified',
      provenance: { source: 'review', evidence: ['npm run build'] },
      createdAt: T0 - 100 * DAY_MS,
      verifiedAt: T0 - 10 * DAY_MS,
    }
    const [view] = viewsOf([record], { now: T0, statMtime: () => null })
    expect(view.effective).toBe('verified')
    const [later] = viewsOf([record], { now: T0 + 25 * DAY_MS, statMtime: () => null })
    expect(later.effective).toBe('stale')
    expect(later.notes[0]).toMatch(/^verified 35 days ago/)
  })

  it('reads stale when an evidence file in the project changed after it was verified, naming the file', () => {
    const record: KnowledgeRecord = {
      id: 'kv',
      project: api,
      kind: 'constraint',
      subject: 'Ports',
      statement: 'Port 3002.',
      status: 'verified',
      provenance: { source: 'review', evidence: ['src/server.ts:42', 'https://example.com/a', '../web/x.ts', '/etc/hosts', 'npm test'] },
      createdAt: T0,
      verifiedAt: T0,
    }
    mtimes.set(join(api, 'src/server.ts'), T0 - 1)
    expect(viewsOf([record], { now: T0, statMtime: (path) => (statted.push(path), mtimes.get(path) ?? null) })[0].effective).toBe('verified')
    mtimes.set(join(api, 'src/server.ts'), T0 + DAY_MS)
    const [view] = viewsOf([record], { now: T0 + DAY_MS, statMtime: (path) => (statted.push(path), mtimes.get(path) ?? null) })
    expect(view.effective).toBe('stale')
    expect(view.notes).toEqual(['src/server.ts changed after it was verified (2026-10-02 > 2026-10-01)'])
    // Nothing outside the project, and no URL, is ever looked at.
    for (const path of statted) expect(path.startsWith(`${api}/`)).toBe(true)
    expect(statted).not.toContain('/etc/hosts')
  })

  it('reads conflicting when two live records share a subject and disagree, each naming the other', () => {
    const a = claim(api, 'Database', 'SQLite.')
    at += 1
    const b = knowledge.record(api, { kind: 'decision', subject: '  database ', statement: 'Postgres.', provenance: { source: 'worker' } })
    at += 1
    const same = claim(api, 'Logging', 'pino.')
    claim(api, 'logging', '  pino. ')
    const byId = new Map(knowledge.list(api).map((view) => [view.id, view]))
    expect(byId.get(a.id)?.effective).toBe('conflicting')
    expect(byId.get(a.id)?.notes[0]).toContain(`disagrees with ${b.id}`)
    expect(byId.get(b.id)?.notes[0]).toContain(`disagrees with ${a.id}`)
    // The same statement twice is a duplicate, not a disagreement.
    expect(byId.get(same.id)?.effective).toBe('claim')
    // Superseding one side resolves it.
    knowledge.supersede(api, b.id, { reason: 'wrong', by: { source: 'owner' } })
    expect(knowledge.get(api, a.id)?.effective).toBe('claim')
  })

  it('finds conflicts only inside a project, and never between lines of task history', async () => {
    knowledge = make(async () => true)
    claim(api, 'Database', 'SQLite.')
    claim(web, 'Database', 'Postgres.')
    await knowledge.share(api, web)
    expect(knowledge.list(web, { shared: true }).map((view) => view.effective)).toEqual(['claim', 'claim'])
    knowledge.record(api, { kind: 'task-history', subject: 'task 1', statement: 'Delegated.', provenance: { source: 'task' } })
    knowledge.record(api, { kind: 'task-history', subject: 'task 1', statement: 'Stalled.', provenance: { source: 'task' } })
    expect(knowledge.list(api).filter((view) => view.kind === 'task-history').map((view) => view.effective)).toEqual(['claim', 'claim'])
  })
})
