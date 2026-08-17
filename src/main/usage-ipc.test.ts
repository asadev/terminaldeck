import type { IpcMain } from 'electron'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import { dropPlanSession, notePlanOutput } from './plan-limit'
import { installPaths, resetPaths } from './platform/paths'
import { createProfile, resetProfilesCache, systemProfileFor } from './profiles'
import type { SessionMeta } from '../shared/types'
import { accountFor, dropUsageSession, readUsage, registerUsageIpc } from './usage-ipc'
import type { UsageReport } from './usage-window'

/*
 * Same trick `profiles.test.ts` uses: profiles ask `platform/paths.ts` where
 * userData is, so a test says where rather than mocking Electron.
 */
const USER_DATA = join(tmpdir(), `terminaldeck-usage-test-${process.pid}`)

beforeEach(() => {
  resetPaths()
  installPaths({
    userData: () => USER_DATA,
    home: () => USER_DATA,
    downloads: () => USER_DATA,
    appRoot: () => USER_DATA,
  })
  rmSync(USER_DATA, { recursive: true, force: true })
  mkdirSync(USER_DATA, { recursive: true })
  resetProfilesCache()
})

afterAll(() => {
  resetPaths()
  rmSync(USER_DATA, { recursive: true, force: true })
})

/* ------------------------------------------------------------------ wiring */

interface Pushed {
  sessionId: string
  report: UsageReport
}

function fakeContents(sink: Pushed[] = []): unknown {
  return {
    isDestroyed: () => false,
    once: () => {},
    send: (_channel: string, sessionId: string, report: UsageReport) => {
      sink.push({ sessionId, report })
    },
  }
}

function wire(describeSession?: (id: string) => SessionMeta | null): {
  invoke: (channel: string, sender: unknown, ...args: unknown[]) => unknown
} {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  registerUsageIpc(
    {
      handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
        handlers.set(channel, fn)
      },
      on: () => {},
    } as unknown as IpcMain,
    describeSession ? { describeSession } : {},
  )
  return {
    invoke: (channel, sender, ...args) => {
      const fn = handlers.get(channel)
      if (!fn) throw new Error(`no handler for ${channel}`)
      return fn({ sender }, ...args)
    },
  }
}

function session(patch: Partial<SessionMeta> = {}): SessionMeta {
  return {
    id: 'sess-1',
    cwd: '/tmp/project',
    title: 'project',
    provider: 'claude',
    exitCode: null,
    createdAt: 0,
    ...patch,
  }
}

/** The `/usage` panel, as a PTY delivers it. Transcribed in `plan-limit.test.ts`. */
const USAGE_PANEL = [
  'Current session',
  '██▌                                                5% used',
  'Resets 4am (Asia/Dubai)',
  '',
  'Current week (all models)',
  '████████████████████████████████████████           80% used',
  'Resets Aug 14 at 2pm (Asia/Dubai)',
].join('\r\n')

/** Longer than the tracker's settle window, so the screen has been read. */
function settle(ms = 800): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function codexLine(timestamp: string, percent: number, minutes: number, resetsAt: number): string {
  return JSON.stringify({
    timestamp,
    type: 'event_msg',
    payload: {
      type: 'token_count',
      info: null,
      rate_limits: {
        limit_id: 'codex',
        limit_name: null,
        primary: { used_percent: percent, window_minutes: minutes, resets_at: resetsAt },
        secondary: null,
        credits: null,
        plan_type: 'prolite',
        rate_limit_reached_type: null,
      },
    },
  })
}

/* ------------------------------------------------------------- attribution */

describe('which account a reading belongs to', () => {
  it("uses the session's own profile when the session runs that agent", () => {
    const profile = createProfile('Work', { provider: 'claude' })
    const account = accountFor('claude', session({ profileId: profile.id, profileName: 'Work' }))
    expect(account).toEqual({
      provider: 'claude',
      id: profile.id,
      name: 'Work',
      configDir: profile.configDir,
    })
  })

  /*
   * A plain shell spawns with no `CLAUDE_CONFIG_DIR` — `sessionEnv` returns
   * nothing for a provider it cannot redirect — so a `/usage` panel printed
   * inside one really is describing the machine's own install. Attributing it
   * to the shell's resolved profile would be a claim about isolation that is
   * not true.
   */
  it("uses the machine's own install for a session running a different agent", () => {
    const profile = createProfile('Work', { provider: 'claude' })
    const account = accountFor('claude', session({ provider: 'shell', profileId: profile.id }))
    expect(account.configDir).toBe(systemProfileFor('claude').configDir)
  })

  it('refuses a profile of the wrong agent, however the state file got that way', () => {
    const codex = createProfile('Side', { provider: 'codex' })
    const account = accountFor('claude', session({ profileId: codex.id }))
    expect(account.configDir).toBe(systemProfileFor('claude').configDir)
  })

  it('attributes to the machine when nothing describes the session', () => {
    expect(accountFor('claude', null).configDir).toBe(systemProfileFor('claude').configDir)
  })
})

/* ------------------------------------------------------------ the read side */

describe('watching a session', () => {
  it('answers "not reported" before anything has been printed', () => {
    const { invoke } = wire(() => session())
    const report = invoke('usage:watch', fakeContents(), 'sess-empty') as UsageReport
    expect(report.readings).toEqual([])
    // Not zero, and not an empty bar: a sentence saying why there is nothing —
    // and the most specific one available, which here is the reader's own.
    expect(report.reason).toContain('has not printed a plan-limit line')
    dropUsageSession('sess-empty')
    dropPlanSession('sess-empty')
  })

  it('still says whose session reported nothing', () => {
    /*
     * The empty report is not the edge case, it is the ordinary one — Claude
     * Code prints nothing about its limits until it is near one or is asked —
     * so this is the state the chrome bar spends most of its life in. A bar
     * that says "not reported" without saying by whom cannot be checked against
     * the account chip sitting beside it, which is the entire reason the bar
     * was put on that bar.
     */
    const profile = createProfile('Work', { provider: 'claude' })
    const { invoke } = wire(() => session({ id: 'sess-whose', profileId: profile.id }))
    const report = invoke('usage:watch', fakeContents(), 'sess-whose') as UsageReport
    expect(report.readings).toEqual([])
    expect(report.account?.name).toBe('Work')
    expect(report.account?.configDir).toBe(profile.configDir)
    dropUsageSession('sess-whose')
    dropPlanSession('sess-whose')
  })

  it("pushes Claude's screen reading with its account, window, fraction and reset", async () => {
    const profile = createProfile('Work', { provider: 'claude' })
    const meta = session({ id: 'sess-claude', profileId: profile.id, profileName: 'Work' })
    const seen: Pushed[] = []
    const { invoke } = wire(() => meta)
    invoke('usage:watch', fakeContents(seen), 'sess-claude')

    notePlanOutput('sess-claude', `${USAGE_PANEL}\r\n`)
    await settle()

    const report = seen.at(-1)?.report
    expect(report?.reason).toBeNull()
    expect(report?.readings.map((entry) => entry.window)).toEqual(['five-hour', 'weekly'])

    const five = report?.readings[0]
    expect(five?.account.name).toBe('Work')
    expect(five?.account.configDir).toBe(profile.configDir)
    // The CLI's own words survive, and the fraction is a fraction.
    expect(five?.label).toBe('Current session')
    expect(five?.used).toEqual({ state: 'reported', fraction: 0.05 })
    expect(five?.resets).toEqual({ state: 'described', text: '4am (Asia/Dubai)' })
    expect(five?.source).toBe('claude-usage-panel')
    expect(five?.reportedAt).toBeGreaterThan(0)
    expect(five?.reportedAt).toBeLessThanOrEqual(five?.observedAt ?? 0)

    dropUsageSession('sess-claude')
    dropPlanSession('sess-claude')
  })

  /*
   * The screen is a terminal and Claude Code prints a limit line whether or not
   * the session was started as a Claude session. A shell session's reading is
   * still real; it just belongs to the machine's own login.
   */
  it('reads a Claude panel printed inside a shell session', async () => {
    const meta = session({ id: 'sess-shell', provider: 'shell' })
    const seen: Pushed[] = []
    const { invoke } = wire(() => meta)
    invoke('usage:watch', fakeContents(seen), 'sess-shell')

    notePlanOutput('sess-shell', `${USAGE_PANEL}\r\n`)
    await settle()

    const first = seen.at(-1)?.report.readings[0]
    expect(first?.account.provider).toBe('claude')
    expect(first?.account.configDir).toBe(systemProfileFor('claude').configDir)

    dropUsageSession('sess-shell')
    dropPlanSession('sess-shell')
  })

  it("reads a Codex session's own rollouts and nobody else's", async () => {
    const profile = createProfile('Codex work', { provider: 'codex' })
    const day = join(profile.configDir, 'sessions', '2026', '04', '30')
    mkdirSync(day, { recursive: true })
    writeFileSync(
      join(day, 'rollout-a.jsonl'),
      `${codexLine('2026-04-30T01:58:04.123Z', 33, 300, 1_777_519_084)}\n`,
      'utf8',
    )

    const meta = session({ id: 'sess-codex', provider: 'codex', profileId: profile.id })
    const report = await readUsage('sess-codex', { describeSession: () => meta })
    expect(report.readings).toHaveLength(1)
    expect(report.readings[0].account.id).toBe(profile.id)
    expect(report.readings[0].used).toEqual({ state: 'reported', fraction: 0.33 })
    expect(report.readings[0].resets).toEqual({ state: 'at', at: 1_777_519_084_000 })
    expect(report.readings[0].source).toBe('codex-rollout')

    // The same rollouts exist on disk, but they say nothing about a Claude
    // session's subscription, so that session's report must not carry them.
    const claude = await readUsage('sess-claude-2', {
      describeSession: () => session({ id: 'sess-claude-2', provider: 'claude' }),
    })
    expect(claude.readings).toEqual([])
  })

  it('says a session it has never heard of is not running here', async () => {
    const report = await readUsage('ghost', { describeSession: () => null })
    expect(report.readings).toEqual([])
    expect(report.reason).toContain('not running here')
  })

  it('lists every Codex account in the machine-wide read, each under its own name', async () => {
    // `CODEX_HOME` is what decides where the machine's *own* install lives, so
    // pointing it at an empty temp directory keeps this test off the real
    // `~/.codex` — otherwise it would pass or fail depending on whether the
    // person running it has used Codex lately.
    const before = process.env.CODEX_HOME
    process.env.CODEX_HOME = join(USER_DATA, 'system-codex')
    try {
      const work = createProfile('Work', { provider: 'codex' })
      const day = join(work.configDir, 'sessions', '2026', '04', '30')
      mkdirSync(day, { recursive: true })
      writeFileSync(
        join(day, 'rollout-a.jsonl'),
        `${codexLine('2026-04-30T01:58:04.123Z', 44, 300, 1_777_519_084)}\n`,
        'utf8',
      )

      const report = await readUsage(null)
      expect(report.sessionId).toBeNull()
      // The machine's own install has never run Codex here, so it contributes
      // nothing — not a zero — and the one reading names the account it is from.
      expect(report.readings.map((entry) => entry.account.name)).toEqual(['Work'])
      expect(report.readings[0].used).toEqual({ state: 'reported', fraction: 0.44 })
    } finally {
      if (before === undefined) delete process.env.CODEX_HOME
      else process.env.CODEX_HOME = before
    }
  })

  it('keeps two accounts apart in one report by keying on the account', async () => {
    const a = createProfile('One', { provider: 'codex' })
    const b = createProfile('Two', { provider: 'codex' })
    for (const profile of [a, b]) {
      const day = join(profile.configDir, 'sessions', '2026', '04', '30')
      mkdirSync(day, { recursive: true })
      writeFileSync(
        join(day, 'rollout-a.jsonl'),
        `${codexLine('2026-04-30T01:58:04.123Z', 11, 300, 1_777_519_084)}\n`,
        'utf8',
      )
    }
    const first = await readUsage('s-a', {
      describeSession: () => session({ id: 's-a', provider: 'codex', profileId: a.id }),
    })
    const second = await readUsage('s-b', {
      describeSession: () => session({ id: 's-b', provider: 'codex', profileId: b.id }),
    })
    expect(first.readings[0].id).not.toBe(second.readings[0].id)
  })
})
