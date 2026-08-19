import type { IpcMain } from 'electron'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import { dropPlanSession, notePlanOutput } from './plan-limit'
import { installPaths, resetPaths } from './platform/paths'
import { createProfile, resetProfilesCache, systemProfileFor } from './profiles'
import type { SessionMeta } from '../shared/types'
import type { AccountLimitMemory } from './account-limits'
import type { AccountLimitFact } from './store'
import type { ProbeAnswer } from './usage-probe'
import {
  accountFor,
  dropUsageSession,
  readUsage,
  registerUsageIpc,
  resetSharedUsage,
  resetUsageProbes,
  type UsageOptions,
  type UsageRefreshResult,
} from './usage-ipc'
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
  /*
   * A Claude reading belongs to the login, not to the pty it was printed in, so
   * one is pooled per account and handed to every session on it — which is the
   * whole of `shareClaudeReadings`. That pool is module state, and a suite that
   * left it standing would have one test's `/usage` panel turn up in the next
   * test's report under the same system account, which is a leak between tests
   * rather than anything the app does.
   */
  resetSharedUsage()
  // And the probe floor, for the same reason: it is keyed by configuration
  // directory, and two tests using the system account would otherwise have the
  // first one's minute-long floor refuse the second one's refresh.
  resetUsageProbes()
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

function wire(
  describeSession?: (id: string) => SessionMeta | null,
  extra: Omit<UsageOptions, 'describeSession'> = {},
): {
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
    { ...(describeSession ? { describeSession } : {}), ...extra },
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

/**
 * One login, one figure — however many terminals are looking at it.
 *
 * The half of the 2026-08-18 defect that nothing in the main process could see.
 * `Current session` and `Current week` are windows on a *subscription*: they are
 * the same number whichever pty prints them, and `readingId` has always built
 * their identity out of the account rather than out of the session. Holding them
 * per session anyway meant every bar waited for its own figure to go stale and
 * then typed `/usage` into its own terminal to learn what the bar beside it
 * already knew — which is what Asad saw as *"it keeps coming in the running
 * sessions"*.
 */
describe('a reading belongs to the login, not to the terminal', () => {
  it('hands a second session the figure the first one read', async () => {
    const profile = createProfile('Work', { provider: 'claude' })
    const first = session({ id: 'share-a', profileId: profile.id })
    const second = session({ id: 'share-b', profileId: profile.id })
    const { invoke } = wire((id) => (id === 'share-a' ? first : second))

    invoke('usage:watch', fakeContents(), 'share-a')
    notePlanOutput('share-a', `${USAGE_PANEL}\r\n`)
    await settle()

    // A second terminal on the same login, which has printed nothing at all and
    // has never been typed into. Under the old arrangement its bar sat empty
    // until it had spent a `/usage` panel of its own.
    const report = invoke('usage:watch', fakeContents(), 'share-b') as UsageReport
    expect(report.readings.map((entry) => entry.window)).toEqual(['five-hour', 'weekly'])
    expect(report.readings[0].used).toEqual({ state: 'reported', fraction: 0.05 })
    // And it is honest about its age: the timestamps are the moment the CLI
    // actually printed it, in the other session, so it goes stale on schedule
    // rather than looking freshly read here.
    expect(report.readings[0].account.configDir).toBe(profile.configDir)

    dropUsageSession('share-a')
    dropUsageSession('share-b')
    dropPlanSession('share-a')
    dropPlanSession('share-b')
  })

  it('tells a session that is already open, rather than only one that arrives later', async () => {
    /*
     * The delivery half. A bar that mounted before the reading existed is
     * subscribed to its *own* session and to nothing else, so without a push it
     * would sit on an empty — or stale — figure until its own screen said
     * something, which for a session parked at its prompt is never. And a bar
     * with a stale figure is a bar that goes and types `/usage` for a number
     * this process is already holding.
     */
    const profile = createProfile('Work', { provider: 'claude' })
    const { invoke } = wire((id) => session({ id, profileId: profile.id }))

    const seen: Pushed[] = []
    invoke('usage:watch', fakeContents(seen), 'live-b')
    invoke('usage:watch', fakeContents(), 'live-a')
    expect(seen).toHaveLength(0)

    notePlanOutput('live-a', `${USAGE_PANEL}\r\n`)
    await settle()

    const pushed = seen.filter((entry) => entry.sessionId === 'live-b').at(-1)
    expect(pushed?.report.readings.map((entry) => entry.window)).toEqual(['five-hour', 'weekly'])

    dropUsageSession('live-a')
    dropUsageSession('live-b')
    dropPlanSession('live-a')
    dropPlanSession('live-b')
  })

  it('never hands it to a different login', async () => {
    const mine = createProfile('Mine', { provider: 'claude' })
    const theirs = createProfile('Theirs', { provider: 'claude' })
    const { invoke } = wire((id) =>
      id === 'sep-a'
        ? session({ id: 'sep-a', profileId: mine.id })
        : session({ id: 'sep-b', profileId: theirs.id }),
    )

    invoke('usage:watch', fakeContents(), 'sep-a')
    notePlanOutput('sep-a', `${USAGE_PANEL}\r\n`)
    await settle()

    // Two accounts sharing one bar is the same class of bug as two accounts
    // sharing one credential, and this app has already had that one.
    const report = invoke('usage:watch', fakeContents(), 'sep-b') as UsageReport
    expect(report.readings).toEqual([])

    dropUsageSession('sep-a')
    dropUsageSession('sep-b')
    dropPlanSession('sep-a')
    dropPlanSession('sep-b')
  })

  it('does not put a Claude figure on a Codex session', async () => {
    /*
     * A session running another agent has its own subscription and its own
     * windows. Folding the machine's Claude limits into it would not merely be
     * noise — the bar draws the five-hour and weekly windows first, so it would
     * push the reading that session actually has off the bar.
     */
    const codex = createProfile('Codex', { provider: 'codex' })
    const { invoke } = wire((id) =>
      id === 'mix-a'
        ? session({ id: 'mix-a', provider: 'claude' })
        : session({ id: 'mix-b', provider: 'codex', profileId: codex.id }),
    )

    invoke('usage:watch', fakeContents(), 'mix-a')
    notePlanOutput('mix-a', `${USAGE_PANEL}\r\n`)
    await settle()

    const report = invoke('usage:watch', fakeContents(), 'mix-b') as UsageReport
    expect(report.readings).toEqual([])

    dropUsageSession('mix-a')
    dropUsageSession('mix-b')
    dropPlanSession('mix-a')
    dropPlanSession('mix-b')
  })
})

/* ------------------------------------------------------- refreshing it ---- */

/**
 * The app's account memory, in a Map.
 *
 * A Map and not `state.json`, because what is being proved below is a *rule* —
 * a login that has answered is not asked again — and a test that had to install
 * a user-data directory to prove it would be proving that a file can be
 * written. `storedAccountLimits()` in `account-limits.ts` is the same interface
 * over the real store and is covered by `store.test.ts`.
 */
function fakeAccounts(): AccountLimitMemory & { held: Map<string, AccountLimitFact> } {
  const held = new Map<string, AccountLimitFact>()
  return {
    held,
    read: (key) => held.get(key) ?? null,
    write: (key, patch) => {
      held.set(key, { ...held.get(key), ...patch, at: Date.now() })
    },
    forget: (key) => {
      held.delete(key)
    },
  }
}

/** The `rate_limits` struct as `get_usage` returns it, trimmed to what is read. */
function utilization(fiveHour: number, weekly: number): Record<string, unknown> {
  return {
    five_hour: { utilization: fiveHour, resets_at: new Date(Date.now() + 3 * 3_600_000).toISOString() },
    seven_day: { utilization: weekly, resets_at: new Date(Date.now() + 4 * 86_400_000).toISOString() },
    seven_day_sonnet: null,
    limits: [],
  }
}

/** A probe transport that counts how many times it was actually asked. */
function fakeProbe(answer: ProbeAnswer): { probe: UsageOptions['probe']; calls: () => number } {
  let calls = 0
  return {
    calls: () => calls,
    probe: {
      // Nothing is looked up on this machine: `probeUsage` skips its binary
      // check whenever a transport is injected, which is what keeps this suite
      // from depending on whether `claude` happens to be installed on a runner.
      ask: async () => {
        calls += 1
        return answer
      },
    },
  }
}

const ANSWERS: ProbeAnswer = {
  usage: { subscription_type: 'max', rate_limits_available: true, rate_limits: utilization(12, 40) },
  error: null,
  killed: false,
}

describe('refreshing the figure without touching a session', () => {
  it('does not type into anything, which is the whole requirement', () => {
    /*
     * Asserted over the source, because it is the requirement in his own words
     * and the one thing every other test here takes for granted:
     *
     *   > *"find out some other way to keep the bar refresh otherwise we will
     *   > remove it completely if it will be heavy"*
     *
     * `plan:refresh` was the channel that typed `/usage` into a session and read
     * the panel Claude Code drew over it. It is gone from the main process, from
     * the preload and from the renderer, and this fails if any of the three
     * brings it back.
     */
    const root = join(__dirname, '..')
    // The channel as a *string literal* — how it would have to be spelled to be
    // registered or invoked. The words appear in the prose in all three files,
    // explaining what used to be there and why it is not, which is the point of
    // writing any of this down.
    const literal = `'plan:refresh'`
    for (const file of ['main/usage-ipc.ts', 'main/plan-limit.ts', 'preload/index.ts']) {
      expect(readFileSync(join(root, file), 'utf8')).not.toContain(literal)
    }
  })

  it('answers from what the CLI already wrote, without starting anything', async () => {
    /*
     * The free path, and the commonest one on a machine with more than one
     * session open. Claude Code keeps its own `cachedUsageUtilization` in
     * `.claude.json` — measured on this Mac against 2.1.234 — so a login another
     * session has already read, or that his own terminal `claude` read by
     * running `/usage`, is answered by a file read and nothing else.
     */
    const profile = createProfile('Work', { provider: 'claude' })
    writeFileSync(
      join(profile.configDir, '.claude.json'),
      JSON.stringify({ cachedUsageUtilization: { fetchedAtMs: Date.now(), utilization: utilization(7, 21) } }),
    )
    const probe = fakeProbe(ANSWERS)
    const { invoke } = wire((id) => session({ id, profileId: profile.id }), { probe: probe.probe })

    invoke('usage:watch', fakeContents(), 'disk-1')
    const result = (await invoke('usage:refresh', fakeContents(), 'disk-1')) as UsageRefreshResult
    expect(result).toMatchObject({ ok: true, outcome: 'cached', spawned: false })
    expect(probe.calls()).toBe(0)

    const report = invoke('usage:watch', fakeContents(), 'disk-1') as UsageReport
    expect(report.readings.map((entry) => entry.used)).toContainEqual({ state: 'reported', fraction: 0.07 })

    dropUsageSession('disk-1')
    dropPlanSession('disk-1')
  })

  it('goes and asks when what is on disk has gone stale', async () => {
    /*
     * The other half of the same rule. A block the CLI fetched two hours ago
     * describes a five-hour window two hours ago, and `readCachedUsage` stamps
     * every reading with that instant precisely so it cannot pass for current.
     * Past the CLI's own one-hour ceiling it is not even parsed.
     */
    const profile = createProfile('Work', { provider: 'claude' })
    writeFileSync(
      join(profile.configDir, '.claude.json'),
      JSON.stringify({
        cachedUsageUtilization: { fetchedAtMs: Date.now() - 2 * 3_600_000, utilization: utilization(7, 21) },
      }),
    )
    const probe = fakeProbe(ANSWERS)
    const { invoke } = wire((id) => session({ id, profileId: profile.id }), { probe: probe.probe })

    invoke('usage:watch', fakeContents(), 'stale-1')
    const result = (await invoke('usage:refresh', fakeContents(), 'stale-1')) as UsageRefreshResult
    expect(result).toMatchObject({ ok: true, outcome: 'ok', spawned: true })
    expect(probe.calls()).toBe(1)

    const report = invoke('usage:watch', fakeContents(), 'stale-1') as UsageReport
    expect(report.readings.map((entry) => entry.used)).toContainEqual({ state: 'reported', fraction: 0.12 })

    dropUsageSession('stale-1')
    dropPlanSession('stale-1')
  })

  it('starts one process for a window full of bars on one login', async () => {
    /*
     * Bringing the window forward wakes every usage bar in it in the same tick,
     * and a four-pane split on one login would otherwise be four `claude`
     * processes to learn one number. Pooled by configuration directory, which is
     * what an account is everywhere else in this app.
     */
    const profile = createProfile('Work', { provider: 'claude' })
    const probe = fakeProbe(ANSWERS)
    const { invoke } = wire((id) => session({ id, profileId: profile.id }), { probe: probe.probe })

    const seen: Pushed[] = []
    invoke('usage:watch', fakeContents(seen), 'pool-a')
    invoke('usage:watch', fakeContents(seen), 'pool-b')

    const results = (await Promise.all([
      invoke('usage:refresh', fakeContents(), 'pool-a'),
      invoke('usage:refresh', fakeContents(), 'pool-b'),
    ])) as UsageRefreshResult[]

    // One process for the two of them, and both of them answered. Which of the
    // two ways the second one is answered — sharing the in-flight promise, or
    // finding the figure already pooled a moment later — is a matter of
    // scheduling and is deliberately not asserted; what matters is that neither
    // started a second `claude` and neither was told to come back later.
    expect(probe.calls()).toBe(1)
    expect(results.every((entry) => entry.ok)).toBe(true)
    // And the one answer reached the bar that did not ask for it.
    expect(seen.some((entry) => entry.sessionId === 'pool-b' && entry.report.readings.length > 0)).toBe(true)

    dropUsageSession('pool-a')
    dropUsageSession('pool-b')
    dropPlanSession('pool-a')
    dropPlanSession('pool-b')
  })

  it('remembers a login with no subscription limits, and a press reaches past it', async () => {
    /*
     * An account billed through the API will not grow a rolling window, so
     * asking again every half hour is four seconds of somebody's CPU for a fact
     * this app already has. Written against the account rather than the session,
     * and to the same memory `plan-limit.ts` uses, because it is one fact.
     */
    const profile = createProfile('Work', { provider: 'claude' })
    const accounts = fakeAccounts()
    const probe = fakeProbe({
      usage: { subscription_type: 'max', rate_limits_available: false },
      error: null,
      killed: false,
    })
    const { invoke } = wire((id) => session({ id, profileId: profile.id }), {
      accounts,
      probe: probe.probe,
    })

    invoke('usage:watch', fakeContents(), 'none-1')
    const first = (await invoke('usage:refresh', fakeContents(), 'none-1')) as UsageRefreshResult
    expect(first.outcome).toBe('no-limits')
    expect(accounts.held.get(profile.configDir)?.answer).toBe('no-limits')

    // A second session on the same login, which has never asked anything. This
    // is the one 0.5.0 got wrong: it remembered per session and per launch, so
    // every terminal got a free attempt at the same settled question.
    invoke('usage:watch', fakeContents(), 'none-2')
    const second = (await invoke('usage:refresh', fakeContents(), 'none-2')) as UsageRefreshResult
    expect(second).toMatchObject({ outcome: 'settled', spawned: false })
    expect(probe.calls()).toBe(1)

    // And the one thing that overrides it, which is a person pressing.
    const pressed = (await invoke('usage:refresh', fakeContents(), 'none-2', true)) as UsageRefreshResult
    expect(pressed.outcome).toBe('no-limits')
    expect(probe.calls()).toBe(2)

    dropUsageSession('none-1')
    dropUsageSession('none-2')
    dropPlanSession('none-1')
    dropPlanSession('none-2')
  })

  it('takes the CLI’s own banner as the answer, before starting anything', async () => {
    /*
     * The cheapest gate in the feature. Claude Code prints `· Claude API ·` on
     * its own welcome banner, `plan-limit.ts` has been reading that line off the
     * session's screen all along, and a login billed that way has no rolling
     * window for anything to report. So the answer is known from a line the CLI
     * printed unasked, and no process is started at all — the first time and
     * every time.
     */
    const profile = createProfile('Work', { provider: 'claude' })
    const accounts = fakeAccounts()
    const probe = fakeProbe(ANSWERS)
    const { invoke } = wire((id) => session({ id, profileId: profile.id }), {
      accounts,
      probe: probe.probe,
    })

    invoke('usage:watch', fakeContents(), 'banner-1')
    notePlanOutput('banner-1', 'Claude Code v2.1.224 · Opus 5 with xhigh effort · Claude API\r\n')
    await settle()

    const result = (await invoke('usage:refresh', fakeContents(), 'banner-1')) as UsageRefreshResult
    expect(result).toMatchObject({ outcome: 'no-limits', spawned: false })
    expect(probe.calls()).toBe(0)
    expect(accounts.held.get(profile.configDir)?.billing).toBe('api')

    dropUsageSession('banner-1')
    dropPlanSession('banner-1')
  })

  it('says why, in a sentence, when it could not read anything', async () => {
    /*
     * The failure this feature is allowed to have. `get_usage` is experimental
     * surface and could be renamed; when it is, this is what the reader sees —
     * a sentence on the bar and a figure with its age on it. Nothing else in the
     * app changes, which is what makes building on it acceptable at all.
     */
    const profile = createProfile('Work', { provider: 'claude' })
    const probe = fakeProbe({ usage: null, error: null, killed: true })
    const { invoke } = wire((id) => session({ id, profileId: profile.id }), { probe: probe.probe })

    invoke('usage:watch', fakeContents(), 'dead-1')
    const result = (await invoke('usage:refresh', fakeContents(), 'dead-1')) as UsageRefreshResult
    expect(result.ok).toBe(false)
    expect(result.outcome).toBe('unreadable')
    expect(result.detail.length).toBeGreaterThan(0)

    dropUsageSession('dead-1')
    dropPlanSession('dead-1')
  })

  it('has nothing to fetch for a session running another agent', async () => {
    const codex = createProfile('Codex', { provider: 'codex' })
    const probe = fakeProbe(ANSWERS)
    const { invoke } = wire(
      (id) => session({ id, provider: 'codex', profileId: codex.id }),
      { probe: probe.probe },
    )
    const result = (await invoke('usage:refresh', fakeContents(), 'codex-1')) as UsageRefreshResult
    expect(result).toMatchObject({ ok: false, outcome: 'unwatched', spawned: false })
    expect(probe.calls()).toBe(0)
  })
})
