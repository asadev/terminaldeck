import type { IpcMain } from 'electron'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, describe, expect, it, vi } from 'vitest'
import { installPaths, resetPaths } from './platform/paths'
import { createProfile, resetProfilesCache } from './profiles'
import type { SessionMeta } from '../shared/types'
import type { ProbeAnswer } from './usage-probe'
import {
  dropUsageSession,
  registerUsageIpc,
  resetSharedUsage,
  resetUsageProbes,
  settleUsageWatch,
  type UsageOptions,
  type UsageRefreshResult,
} from './usage-ipc'

/**
 * The twelve-minute flake, made to happen on demand.
 *
 * `usage:watch` answers in the same tick and lets the disk read it started land
 * a few milliseconds later — the right behaviour for a bar, which must not flash
 * empty while a file is opened. What lands is a reading written into
 * `claudeByAccount`, module state shared by every session on that login, and
 * nothing in the app cares when it arrives.
 *
 * A suite cares. `usage-ipc.test.ts` wipes its scratch directory and clears that
 * pool between tests, and a read still in flight crosses the boundary: it
 * finishes after the clear and drops the *previous* test's figure, stamped
 * seconds ago, into a pool the next test believes is empty. That test then asks
 * whether a probe could tell it anything new, is told the login already has a
 * figure younger than the CLI's own five-minute write throttle, and answers
 * `cached` without starting one. On screen that is nothing at all; in the suite
 * it is "goes and asks once the CLI would fetch again" failing with
 * `probe.calls()` of 0 — under full-suite load, and never when run alone, which
 * is the worst shape a test can have.
 *
 * It is a race about *ordering*, not about elapsed time — the figures involved
 * are minutes apart and no clock drift can confuse them — so there is no fake
 * clock here. What there is instead is a hold on one `readFile`, which is the
 * only free variable the race has: released before the boundary the pool stays
 * honest, released after it does not. `settleUsageWatch` is what makes the first
 * one true, and these three cases pin it from both sides.
 */
const gate = vi.hoisted(() => {
  let held: Promise<void> | null = null
  let release: (() => void) | null = null
  let caught: Promise<void> = Promise.resolve()
  let arrived: (() => void) | null = null
  return {
    /** Hold the next `.claude.json` read open, once, until {@link letGo}. */
    catchNextRead(): void {
      held = new Promise<void>((settle) => {
        release = settle
      })
      caught = new Promise<void>((settle) => {
        arrived = settle
      })
    },
    /**
     * Resolves once that read has its bytes and is being held.
     *
     * Waited on before the scratch directory is wiped, and that is not
     * pedantry: the hold is applied *after* the real read, so a wipe that got
     * in first would leave the read failing with ENOENT, publishing nothing,
     * and the case below passing for want of a defect rather than because of a
     * fix. It did exactly that in twelve of thirty-two loaded runs before this
     * existed.
     */
    get caught(): Promise<void> {
      return caught
    },
    /** Let the held read finish. Safe to call when nothing is held. */
    letGo(): void {
      const go = release
      held = null
      release = null
      go?.()
    },
    /** The mock's half: claim the hold, so only the first read is caught. */
    claim(): Promise<void> | null {
      const taken = held
      held = null
      if (taken) arrived?.()
      return taken
    },
  }
})

/*
 * The real filesystem, with one seam in it.
 *
 * The bytes are read first and the hold applied afterwards, which is exactly the
 * ordering that does the damage: the content is the one the file had *before*
 * the next test rewrote it, and it is the continuation — the part that writes
 * into the shared pool — that arrives late.
 */
vi.mock('node:fs/promises', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs/promises')>()
  const readFile = async (path: unknown, encoding: unknown): Promise<unknown> => {
    const bytes = await (actual.readFile as (p: unknown, e: unknown) => Promise<unknown>)(
      path,
      encoding,
    )
    if (typeof path === 'string' && path.endsWith('.claude.json')) {
      const wait = gate.claim()
      if (wait) await wait
    }
    return bytes
  }
  return { ...actual, readFile, default: { ...actual, readFile } }
})

const USER_DATA = join(tmpdir(), `terminaldeck-usage-race-${process.pid}`)

/** Exactly what `usage-ipc.test.ts` does between tests, in one place. */
function boundary(): void {
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
  resetSharedUsage()
  resetUsageProbes()
}

afterEach(async () => {
  // Never leave a read held: the next file's `beforeEach` would join it and wait
  // for a release that is not coming.
  gate.letGo()
  await settleUsageWatch()
})

afterAll(() => {
  resetPaths()
  rmSync(USER_DATA, { recursive: true, force: true })
})

function utilization(fiveHour: number, weekly: number): Record<string, unknown> {
  return {
    five_hour: { utilization: fiveHour, resets_at: new Date(Date.now() + 3 * 3_600_000).toISOString() },
    seven_day: { utilization: weekly, resets_at: new Date(Date.now() + 4 * 86_400_000).toISOString() },
    seven_day_sonnet: null,
    limits: [],
  }
}

const ANSWERS: ProbeAnswer = {
  usage: { subscription_type: 'max', rate_limits_available: true, rate_limits: utilization(12, 40) },
  error: null,
  killed: false,
}

/** A probe transport that counts how many times it was actually asked. */
function countingProbe(): { probe: UsageOptions['probe']; calls: () => number } {
  let calls = 0
  return {
    calls: () => calls,
    probe: {
      ask: async () => {
        calls += 1
        return ANSWERS
      },
    },
  }
}

function contents(): unknown {
  return { isDestroyed: () => false, once: () => {}, send: () => {} }
}

function session(id: string, profileId: string): SessionMeta {
  return {
    id,
    cwd: '/tmp/project',
    title: 'project',
    provider: 'claude',
    exitCode: null,
    createdAt: 0,
    profileId,
  }
}

function wire(
  profileId: string,
  probe: UsageOptions['probe'],
): (channel: string, ...args: unknown[]) => unknown {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  registerUsageIpc(
    {
      handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
        handlers.set(channel, fn)
      },
      on: () => {},
    } as unknown as IpcMain,
    { describeSession: (id: string) => session(id, profileId), ...(probe ? { probe } : {}) },
  )
  return (channel, ...args) => {
    const fn = handlers.get(channel)
    if (!fn) throw new Error(`no handler for ${channel}`)
    return fn({ sender: contents() }, ...args)
  }
}

/**
 * Write the block Claude Code keeps in `.claude.json`, aged as asked.
 *
 * The account is created with the same name every time on purpose: the pool is
 * keyed by configuration directory and `Work` slugs to the same one, which is
 * what makes one test's figure answerable for another's in the first place.
 */
function loginWithCachedFigure(ageMs: number): { id: string; configDir: string } {
  const profile = createProfile('Work', { provider: 'claude' })
  writeFileSync(
    join(profile.configDir, '.claude.json'),
    JSON.stringify({
      cachedUsageUtilization: { fetchedAtMs: Date.now() - ageMs, utilization: utilization(7, 21) },
    }),
  )
  return { id: profile.id, configDir: profile.configDir }
}

describe('a read that outlives the session that started it', () => {
  it('is what `settleUsageWatch` waits for', async () => {
    boundary()
    gate.catchNextRead()
    const login = loginWithCachedFigure(0)
    const probe = countingProbe()
    const invoke = wire(login.id, probe.probe)
    invoke('usage:watch', 'held-1')
    await gate.caught

    /*
     * The read is open, so the join must not be. Raced against a short timer and
     * not asserted after one: the hold is a promise nobody has resolved, so a
     * slow machine cannot make this resolve early — there is nothing for it to
     * resolve *to*. A broken join loses the race on any machine.
     */
    const settling = settleUsageWatch().then(() => 'joined')
    const raced = await Promise.race([
      settling,
      new Promise<string>((r) => setTimeout(() => r('still running'), 20)),
    ])
    expect(raced).toBe('still running')

    gate.letGo()
    expect(await settling).toBe('joined')
    dropUsageSession('held-1')
  })

  it('cannot answer for the login the next test asks about', async () => {
    boundary()
    // A test whose login has a figure the CLI fetched a moment ago.
    gate.catchNextRead()
    const first = loginWithCachedFigure(0)
    const probe = countingProbe()
    wire(first.id, probe.probe)('usage:watch', 'disk-1')
    dropUsageSession('disk-1')
    await gate.caught

    // The boundary, as `usage-ipc.test.ts` now spells it: join first, wipe after.
    const joined = settleUsageWatch()
    gate.letGo()
    await joined
    boundary()

    // And the test that follows, whose login was last fetched twelve minutes ago
    // — past the CLI's own five-minute write throttle, so a probe can genuinely
    // move the number and one has to be started.
    const second = loginWithCachedFigure(12 * 60_000)
    expect(second.configDir).toBe(first.configDir)
    const invoke = wire(second.id, probe.probe)
    invoke('usage:watch', 'twelve-1')
    const result = (await invoke('usage:refresh', 'twelve-1')) as UsageRefreshResult

    expect(result.ok).toBe(true)
    expect(probe.calls(), `outcome was ${result.outcome}`).toBe(1)
    dropUsageSession('twelve-1')
  })

  it('answers for it when the boundary does not join, which is the whole defect', async () => {
    /*
     * The same sequence with the join taken out, kept because it is what makes
     * the case above mean anything: without it, a change that quietly stopped
     * `settleUsageWatch` from covering the watch's own read would leave that test
     * passing for the wrong reason.
     *
     * It pins a defect rather than a behaviour, so it is honest about that in its
     * name and it dies with the defect: if the shared pool ever stops being
     * module state, or the seed learns to check that its session is still
     * watched before publishing, this is the test that should be deleted.
     */
    boundary()
    gate.catchNextRead()
    const first = loginWithCachedFigure(0)
    const probe = countingProbe()
    wire(first.id, probe.probe)('usage:watch', 'disk-2')
    dropUsageSession('disk-2')
    await gate.caught

    // No join: the wipe happens with the read still open, and the read lands
    // afterwards — carrying a figure from a login that no longer exists.
    boundary()
    const second = loginWithCachedFigure(12 * 60_000)
    gate.letGo()
    await settleUsageWatch()

    const invoke = wire(second.id, probe.probe)
    invoke('usage:watch', 'twelve-2')
    const result = (await invoke('usage:refresh', 'twelve-2')) as UsageRefreshResult

    expect(result.outcome).toBe('cached')
    expect(probe.calls()).toBe(0)
    dropUsageSession('twelve-2')
  })
})
