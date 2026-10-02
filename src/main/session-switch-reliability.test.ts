import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type { SessionMeta } from '../shared/types'
import { argsForSpawn } from './one-conversation'
import { installPaths, resetPaths } from './platform/paths'
import { createProfile, resetProfilesCache, type Profile } from './profiles'
import { resetConversationStores, type SavedSession } from './session-restore'
import { createSessionSwitch, type SwitchCore } from './session-switch-run'
import { transcriptDir } from './transcript'

/**
 * Why switching a session's account was not reliable, one cause per block, each
 * against the path the window actually takes (`switchAccount` over a core).
 *
 * Asad, 2026-10-03: *"currently accounts switching is not that reliable."* The
 * causes were found in the code, not guessed: a fixed 1.5-second wait standing
 * in for "the replacement works"; the conversation dropped whenever another tab
 * of the same agent was open in the folder; restored tabs with no conversation
 * id; Codex quietly continuing some other conversation. Every block below was
 * run against the code before the fix and failed there.
 *
 * Nothing real is touched. `CLAUDE_CONFIG_DIR` points the machine's "own
 * install" at a scratch folder for the whole file, so no listing, link or
 * transcript lookup reaches `~/.claude`; the core is a double; no agent runs.
 */

let dir = ''
let own = ''
let project = ''
let work: Profile
let codexWork: Profile
const previousConfigDir = process.env.CLAUDE_CONFIG_DIR

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-switch-reliable-'))
  own = join(dir, 'own-claude')
  mkdirSync(join(own, 'projects'), { recursive: true })
  process.env.CLAUDE_CONFIG_DIR = own
  resetPaths()
  installPaths({ userData: () => dir, home: () => dir, downloads: () => dir, appRoot: () => dir })
  resetProfilesCache()
  resetConversationStores()
  project = join(dir, 'project')
  mkdirSync(project, { recursive: true })
  work = createProfile('Work')
  codexWork = createProfile('Codex Work', { provider: 'codex' })
})

afterAll(() => {
  if (previousConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR
  else process.env.CLAUDE_CONFIG_DIR = previousConfigDir
  resetPaths()
  resetProfilesCache()
  resetConversationStores()
  rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
})

beforeEach(() => {
  resetConversationStores()
  // Each case writes its own conversations; none may see the last one's.
  rmSync(transcriptDir(project, own), { recursive: true, force: true })
})

/** How a replacement behaves once started. */
interface Replacement {
  /** Milliseconds after the spawn at which it exits. Absent: never. */
  diesAfterMs?: number
  /** What it shows on screen. */
  screen: string
}

/** A conversation file in the shared history for the project folder. */
function transcript(id: string, modifiedAt: number): void {
  const folder = transcriptDir(project, own)
  mkdirSync(folder, { recursive: true })
  const file = join(folder, `${id}.jsonl`)
  writeFileSync(file, '{"type":"user"}\n')
  utimesSync(file, modifiedAt / 1000, modifiedAt / 1000)
}

function core(options: {
  old: SessionMeta
  others?: SessionMeta[]
  saved: SavedSession
  otherSaved?: Array<{ id: string; saved: SavedSession }>
  replacement: Replacement
}): {
  core: SwitchCore
  started: Parameters<SwitchCore['startSession']>[0][]
  killed: string[]
} {
  const started: Parameters<SwitchCore['startSession']>[0][] = []
  const killed: string[] = []
  const live = new Map<string, SessionMeta>([[options.old.id, options.old]])
  for (const other of options.others ?? []) live.set(other.id, other)
  const records = new Map<string, SavedSession>([[options.old.id, options.saved]])
  for (const other of options.otherSaved ?? []) records.set(other.id, other.saved)
  let spawnedAt = 0
  const replacementAlive = (): boolean =>
    options.replacement.diesAfterMs === undefined || Date.now() - spawnedAt < options.replacement.diesAfterMs
  const value: SwitchCore = {
    ptys: {
      list: () =>
        [...live.values()].filter((session) => session.id !== 'replacement' || replacementAlive()),
      kill: (id: string) => {
        killed.push(id)
        live.delete(id)
      },
      scrollback: (id: string) => (id === 'replacement' ? options.replacement.screen : ''),
      screen: (id: string) => Promise.resolve(id === 'replacement' ? options.replacement.screen : ''),
    } as unknown as SwitchCore['ptys'],
    ledger: {
      get: (id: string) => records.get(id) ?? null,
      entries: () => [...records].map(([id, saved]) => ({ id, saved })),
      forget: (id: string) => {
        records.delete(id)
      },
    } as unknown as SwitchCore['ledger'],
    startSession: (input) => {
      started.push(input)
      spawnedAt = Date.now()
      const meta = {
        id: 'replacement',
        cwd: input.cwd,
        title: 'replacement',
        provider: input.provider,
        exitCode: null,
        createdAt: spawnedAt,
        resumed: input.resume === true,
      } as SessionMeta
      live.set('replacement', meta)
      return Promise.resolve(meta)
    },
    statablePath: (cwd) => cwd,
    canContinue: () => true,
  }
  return { core: value, started, killed }
}

const claudeTab = (id: string, over: Partial<SessionMeta> = {}): SessionMeta => ({
  id,
  cwd: project,
  title: 'project',
  provider: 'claude',
  exitCode: null,
  createdAt: Date.now() - 60_000,
  profileId: 'system',
  profileName: 'Default',
  ...over,
})

const savedTab = (over: Partial<SavedSession> = {}): SavedSession => ({
  cwd: project,
  provider: 'claude',
  profileId: 'system',
  cols: 100,
  rows: 30,
  lastSeenAt: 1,
  ...over,
})

/** Claude Code's prompt, as the classifier reads it. */
const PROMPT = 'Welcome back\n\n❯ \n────────\n? for shortcuts'

const fast = { readiness: { pollMs: 50, ceilingMs: 4_000 } }

/* -------------------------------------------- (a) a real readiness signal -- */

describe('the switch waits for the replacement to be ready, not for 1.5 seconds', () => {
  it('moves on the moment the replacement shows its prompt', async () => {
    const { core: value, killed } = core({
      old: claudeTab('old'),
      saved: savedTab(),
      replacement: { screen: PROMPT },
    })
    const startedAt = Date.now()
    const answer = await createSessionSwitch(value, fast).switchAccount('old', work.id)
    expect(answer.ok).toBe(true)
    expect(Date.now() - startedAt).toBeLessThan(1_000)
    expect(killed).toEqual(['old'])
  })

  it('keeps the session when the replacement dies after the old fixed wait would have passed it', async () => {
    const { core: value, killed } = core({
      old: claudeTab('old'),
      saved: savedTab(),
      // Alive, drawing nothing conclusive, then gone at two seconds.
      replacement: { screen: 'Resuming conversation…', diesAfterMs: 2_000 },
    })
    const answer = await createSessionSwitch(value, fast).switchAccount('old', work.id)
    expect(answer.ok).toBe(false)
    expect(answer.message).toContain('started and stopped straight away')
    expect(killed).not.toContain('old')
  }, 10_000)

  it('keeps the session when the replacement comes up at a sign-in screen', async () => {
    const { core: value, killed } = core({
      old: claudeTab('old'),
      saved: savedTab(),
      replacement: { screen: 'Not logged in · Please run /login' },
    })
    const answer = await createSessionSwitch(value, fast).switchAccount('old', work.id)
    expect(answer.ok).toBe(false)
    expect(answer.message).toContain('is not signed in')
    expect(killed).toEqual(['replacement'])
  })
})

/* ------------------------- (c) another tab in the folder, a named conversation -- */

describe('the conversation on screen is carried by its id, whatever else is open in the folder', () => {
  it('resumes it even with another Claude tab open in the same folder on another conversation', async () => {
    transcript('conv-ours', Date.now() - 5_000)
    transcript('conv-other', Date.now() - 1_000)
    const { core: value, started } = core({
      old: claudeTab('old', { agentSessionId: 'conv-ours' }),
      others: [claudeTab('other-tab', { agentSessionId: 'conv-other' })],
      saved: savedTab(),
      otherSaved: [{ id: 'other-tab', saved: savedTab() }],
      replacement: { screen: PROMPT },
    })
    const answer = await createSessionSwitch(value, fast).switchAccount('old', work.id)
    expect(answer.ok).toBe(true)
    expect(started[0]).toMatchObject({ resume: true, resumeConversationId: 'conv-ours' })
  })

  it('and the spawn guard keeps a named resume unless a tab is on that very conversation', () => {
    const live = [{ id: 'other', cwd: project, provider: 'claude', exitCode: null, agentSessionId: 'conv-other' }]
    const named = { resume: true, resumeArgs: ['--resume', 'conv-ours'], args: ['claude'], cwd: project, provider: 'claude' }
    expect(argsForSpawn({ ...named, live, conversationId: 'conv-ours' })).toEqual(['--resume', 'conv-ours'])
    const same = [{ ...live[0], agentSessionId: 'conv-ours' }]
    expect(argsForSpawn({ ...named, live: same, conversationId: 'conv-ours' })).toEqual(['claude'])
  })
})

/* -------------------------------------- (d) a tab restored at launch has an id -- */

describe('a tab restored at launch switches with its own conversation', () => {
  it('recovers the id from the transcripts and carries it', async () => {
    const restoredAt = Date.now() - 30_000
    // What `--continue` attached the restored tab to: the newest conversation
    // when it started. Another tab has since started — and is on — a newer one.
    transcript('conv-restored', restoredAt - 10_000)
    transcript('conv-newer-other', Date.now() - 2_000)
    const { core: value, started } = core({
      old: claudeTab('restored', { createdAt: restoredAt }),
      others: [claudeTab('other-tab', { agentSessionId: 'conv-newer-other' })],
      saved: savedTab(),
      otherSaved: [{ id: 'other-tab', saved: savedTab() }],
      replacement: { screen: PROMPT },
    })
    const answer = await createSessionSwitch(value, fast).switchAccount('restored', work.id)
    expect(answer.ok).toBe(true)
    expect(started[0]).toMatchObject({ resume: true, resumeConversationId: 'conv-restored' })
  })
})

/* ------------------------------------- (f) Codex keeps conversations apart -- */

describe('a Codex switch says plainly that the conversation does not come', () => {
  it('starts fresh — never another conversation of the new account — and the plan says why', async () => {
    const { core: value, started } = core({
      old: claudeTab('codex-tab', { provider: 'codex', profileId: 'system:codex', profileName: 'Default (Codex CLI)' }),
      saved: savedTab({ provider: 'codex', profileId: 'system:codex' }),
      replacement: { screen: '› ' },
    })
    const switching = createSessionSwitch(value, fast)
    const { plan } = await switching.subject('codex-tab', codexWork.id)
    expect(plan.refusal).toBeNull()
    expect(plan.conversation).toBe('separate')
    expect(plan.resume).toBe(false)
    await switching.switchAccount('codex-tab', codexWork.id)
    expect(started[0]?.resume).toBe(false)
  })
})
