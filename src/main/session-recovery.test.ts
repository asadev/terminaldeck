import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterAll, describe, expect, it, vi } from 'vitest'
import { conversationOnDisk, planRestore, restoreOpenSessions, type SavedSession } from './session-restore'
import { HeldSessions, savedFrom } from './session-held'
import { transcriptDir } from './transcript'
import type { SessionMeta } from '../shared/types'

const dir = mkdtempSync(join(tmpdir(), 'td-exact-recovery-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
const saved = (tabKey: string, agentSessionId = tabKey): SavedSession => ({
  tabKey, agentSessionId, cwd: dir, provider: 'claude', profileId: 'login-b',
  homeProfileId: 'login-a', model: 'sonnet', cols: 112, rows: 38, lastSeenAt: 123,
})
const probes = {
  requireExactConversation: true,
  folderExists: async () => true,
  canContinue: () => true,
  configDir: () => dir,
  conversation: async () => 'found' as const,
}

describe('exact conversation recovery', () => {
  it('resumes two conversations in the same folder and account by their own ids', async () => {
    const a = saved('tab-a', 'conversation-a'), b = saved('tab-b', 'conversation-b')
    const decisions = await planRestore([a, b], probes)
    const spawn = vi.fn(async (input) => ({ id: input.tabKey } as SessionMeta))
    await restoreOpenSessions({ saved: () => [a, b], enabled: () => true, plan: async () => decisions,
      spawn, announce: () => undefined, report: () => undefined })
    expect(decisions.map((d) => d.outcome)).toEqual(['resume', 'resume'])
    expect(spawn.mock.calls.map(([input]) => input)).toEqual([a, b].map((s) => ({
      cwd: s.cwd, provider: s.provider, profileId: s.profileId, homeProfileId: s.homeProfileId,
      model: s.model, cols: s.cols, rows: s.rows, tabKey: s.tabKey, resume: true, resumeConversationId: s.agentSessionId,
    })))
  })

  it('keeps ambiguous legacy tabs, missing transcripts and duplicate claims without fresh replacements', async () => {
    const { agentSessionId: _id, ...legacy } = saved('legacy')
    const decisions = await planRestore([legacy, saved('one', 'shared'), saved('two', 'shared'), saved('missing')], {
      ...probes, conversation: async (s: SavedSession) => s.tabKey === 'missing' ? 'none' : 'found',
    })
    expect(decisions.map((d) => d.outcome)).toEqual(['skip', 'resume', 'skip', 'skip'])
    expect(decisions.filter((d) => d.outcome === 'skip').every((d) => d.reason.includes('kept'))).toBe(true)
  })

  it('does not take a newer sibling transcript when the exact saved one is missing', async () => {
    const session = saved('tab', 'original')
    const transcripts = transcriptDir(dir, dir)
    mkdirSync(transcripts, { recursive: true })
    writeFileSync(join(transcripts, 'newer.jsonl'), '{"type":"user","message":"other conversation"}\n')
    await expect(conversationOnDisk(session, dir, 'darwin')).resolves.toBe('none')
    writeFileSync(join(transcripts, 'original.jsonl'), '{"type":"user","message":"original conversation"}\n')
    await expect(conversationOnDisk(session, dir, 'darwin')).resolves.toBe('found')
  })

  it('plans tabs that never record an id as before: Codex continues, Gemini and shells start again', async () => {
    const tab = (tabKey: string, provider: SavedSession['provider']): SavedSession => {
      const { agentSessionId: _id, ...rest } = saved(tabKey)
      return { ...rest, provider }
    }
    const decisions = await planRestore([tab('codex', 'codex'), tab('gemini', 'gemini'), tab('shell', 'shell'), tab('claude', 'claude')], {
      ...probes,
      canContinue: (provider) => provider === 'claude' || provider === 'codex',
      conversation: async (s: SavedSession) => s.provider === 'codex' ? 'unknown' : 'found',
    })
    expect(decisions.map((d) => [d.session.tabKey, d.outcome])).toEqual([
      ['codex', 'resume'], ['gemini', 'fresh'], ['shell', 'fresh'], ['claude', 'skip'],
    ])
    expect(decisions[3].reason).toContain('/resume')
  })

  it('restarts a session with the enforced limits it had, and never adds them to one that had none', async () => {
    const limited = { ...saved('limited', 'conversation-l'), deniedTools: ['WebFetch'], noSkills: true }
    const plain = saved('plain', 'conversation-p')
    const spawn = vi.fn(async (input) => ({ id: input.tabKey } as SessionMeta))
    await restoreOpenSessions({ saved: () => [limited, plain], enabled: () => true, plan: (list) => planRestore(list, probes),
      spawn, announce: () => undefined, report: () => undefined })
    const [first, second] = spawn.mock.calls.map(([input]) => input)
    expect(first).toMatchObject({ deniedTools: ['WebFetch'], noSkills: true })
    expect(second).not.toHaveProperty('deniedTools')
    expect(second).not.toHaveProperty('noSkills')
    // Held and tried again: the same limits.
    expect(savedFrom(new HeldSessions().hold(limited, 'offline'))).toMatchObject({ deniedTools: ['WebFetch'], noSkills: true })
  })

  it('keeps conversation, model and original account folder through hold and retry', () => {
    const held = new HeldSessions()
    const original = saved('held')
    expect(savedFrom(held.hold(original, 'offline'))).toEqual(original)
  })
})

async function ledgerAt(root: string) {
  vi.resetModules()
  const paths = await import('./platform/paths')
  paths.installPaths({ userData: () => root, home: () => root, downloads: () => root, appRoot: () => root })
  const { OpenSessionLedger } = await import('./host-core')
  return new OpenSessionLedger()
}
const disk = (root: string): SavedSession[] => JSON.parse(readFileSync(join(root, 'state.json'), 'utf8')).openSessions

describe('interrupted and repeated restart with isolated app data', () => {
  it('migrates an anonymous shell tab once without duplicating it across restarts', async () => {
    const root = join(dir, 'legacy-shell-data')
    mkdirSync(root)
    const { tabKey: _key, agentSessionId: _id, model: _model, ...legacy } = saved('old')
    writeFileSync(join(root, 'state.json'), JSON.stringify({ openSessions: [{ ...legacy, provider: 'shell' }] }))
    let ledger = await ledgerAt(root)
    const [migrated] = disk(root)
    expect(migrated.tabKey).toBeTruthy()
    ledger.note('shell-process-1', { ...migrated, lastSeenAt: 200 })
    ledger = await ledgerAt(root)
    ledger.note('shell-process-2', { ...disk(root)[0], lastSeenAt: 300 })
    expect(disk(root)).toHaveLength(1)
    expect(disk(root)[0].tabKey).toBe(migrated.tabKey)
    expect(disk(root)[0].cwd).toBe(legacy.cwd)
  }, 15_000)

  it('keeps a tab\'s enforced limits on disk across a restart that has not restored it yet', async () => {
    const root = join(dir, 'limits-data')
    mkdirSync(root)
    const limited = { ...saved('limited'), deniedTools: ['Bash', 'mcp__deck-control'], noSkills: true }
    writeFileSync(join(root, 'state.json'), JSON.stringify({ openSessions: [limited] }))
    const ledger = await ledgerAt(root)
    ledger.flush()
    expect(disk(root)[0]).toMatchObject({ deniedTools: ['Bash', 'mcp__deck-control'], noSkills: true })
  }, 15_000)

  it('stops keeping the previous launch when reopening is switched off', async () => {
    const root = join(dir, 'restore-off-data')
    mkdirSync(root)
    writeFileSync(join(root, 'state.json'), JSON.stringify({ openSessions: [saved('old-a'), saved('old-b')] }))
    const ledger = await ledgerAt(root)
    expect(disk(root)).toHaveLength(2)
    ledger.dropPending()
    ledger.note('process-new', saved('new'))
    expect(disk(root).map((s) => s.tabKey)).toEqual(['new'])
  }, 15_000)

  it('retains unrestored tabs before first paint, after partial restore, after another restart, and after a failed restore', async () => {
    const root = join(dir, 'app-data')
    mkdirSync(root)
    const originals = [saved('a'), saved('b'), saved('c')]
    writeFileSync(join(root, 'state.json'), JSON.stringify({ openSessions: originals }))
    let ledger = await ledgerAt(root)
    ledger.flush() // A background session can flush before renderer hydration.
    expect(disk(root)).toEqual(originals)
    ledger.note('process-a-1', { ...originals[0], lastSeenAt: 200 })
    expect(disk(root).map((s) => s.tabKey)).toEqual(['a', 'b', 'c'])
    ledger = await ledgerAt(root) // Interrupted after only the first spawn.
    ledger.note('process-a-2', { ...originals[0], lastSeenAt: 300 })
    ledger.held.hold(originals[1], 'conversation volume offline')
    ledger.note('process-c-2', originals[2])
    expect(disk(root).map((s) => s.agentSessionId)).toEqual(['a', 'b', 'c'])
    expect(disk(root)[1]).toEqual(originals[1])
    ledger.freeze()
    ledger.forget('process-a-2') // Shutdown callbacks must not change the disk.
    expect(disk(root)).toHaveLength(3)
    ledger = await ledgerAt(root)
    ledger.held.hold(disk(root)[1], 'still offline')
    ledger.flush()
    expect(disk(root).map((s) => s.tabKey)).toEqual(['a', 'b', 'c'])
  }, 15_000)
})
